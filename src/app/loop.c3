<*
 The window and the frame loop.

 Two loops rather than one, and the split is what they have to wait for.
 `run`'s own loop at the bottom of `boot.c3` has nothing to wait for but the
 mouse, so it sleeps between gestures. `live` here has a server, a script, a
 game's animation callback and a screenshot schedule to service, and cannot.

 Everything between them is shared and lives here: `drive_window` polls one
 frame's worth of input and answers what changed, `drive_camera` turns that into
 `pass.camera`, `ask_hover` decides the cursor, and `window_view` hands the
 window's own size to the swapchain in device pixels.

 Separated from `main.c3` for `boot.c3`'s reason — an application that links
 these sources drives its own loop out of these pieces, and none of them should
 need three's argv to exist. `live` already took plain arguments rather than an
 `Options`, which is why this was the cheapest half of the seam to cut.

 ## One thread

 The server's handlers run on *this* thread — `Listener` moves bytes on its own
 and `pump` runs the work on the caller's — so a script, the scene it builds and
 the device it draws with are all touched from one place, and none of the three
 needs a lock. An application driving its own loop out of these pieces inherits
 that guarantee and the obligation behind it: pump where `live` pumps.
*>
module three;

import std::io;
import std::thread;
import std::time;
import c3w;
import mcp;
<*
 Hands the window's own size to the swapchain, in device pixels.

 Read every frame and written straight through, because both numbers are latches
 on this side of the call and the comparison that matters happens in
 `Renderer.frame`, against what the surface reports.

 The scale is what makes it device pixels: `Window.width` is logical points, and
 a swapchain image is physical. They differ on a retina display and on any
 Wayland session with a scaled output, and agreeing at startup is a coincidence
 of both being 1.

 It only reaches anything on a surface that declines to report its own size —
 Wayland — so on X11 and macOS this is two multiplications and a store.
*>
fn void want_surface(Renderer* renderer, c3w::Window* window)
{
	float scale = window.get_scale();
	if (scale <= 0.0f) scale = 1.0f;
	renderer.want_surface((uint)(window.width * scale), (uint)(window.height * scale));
}

<*
 Asks the window for a cursor, once the shape has actually changed.

 Setting it every frame would be an objc call sixty times a second to say the
 same thing, and — worse — it would overrule whatever AppKit put there for the
 resize edges the instant the pointer touched one.
*>
fn void show_cursor(c3w::Window* window, c3w::CursorShape* shown, c3w::CursorShape want)
{
	if (want == *shown) return;
	*shown = want;
	window.set_cursor(want);
}

<*
 Whether there is anything under the pointer, asked as rarely as the answer
 allows.

 `Hover` owns the rule and this owns the raycast, the same split everything else
 here uses: the decision is checkable without a GPU and the call needs one.
 Nothing is asked while a drag is running — the cursor is a closed hand then
 whatever the answer would be — and nothing is asked with the pointer off the
 image.
*>
fn bool ask_hover(Renderer* renderer, Hover* hover, Cursor cursor, bool dragging)
{
	if (!cursor.inside || dragging)
	{
		hover.forget();
		return false;
	}

	if (hover.stale(cursor))
	{
		hover.keep(
			cursor,
			renderer.pass.hits(cursor.x, cursor.y, renderer.target.extent.width, renderer.target.extent.height)
		);
	}

	return hover.over;
}

<*
 Reads the pointer and lets it move the camera. One call per frame, in every loop
 that has a window.

 The units are the whole content of this function. `c3w` reports the cursor in
 the platform's own coordinates — logical points on macOS — and `viewer.extent`
 is in device pixels, which on a retina display is twice as many. Handing the raw
 extent to `Controls.apply` would halve the pan speed on exactly the machines
 this is developed on, and it would look like a taste problem rather than a units
 bug. `get_scale` is the ratio, and the same number `c3w` sets the Metal layer's
 `contentsScale` to.

 The extent is read rather than the window's own size because the frame loop
 keeps it current through a live resize drag and `Window.width` is only what
 `new` was asked for.

 The cursor and the wheel arrive as arguments rather than being read here,
 because the caller needs them too — in image pixels, for the click — and one
 reading answering two questions is one fewer way for the camera and the picker
 to disagree about where the mouse was.

 @param at : `The window's own answer, in its own units. Read once by the caller and shared.`
 @param dt_ms : `Milliseconds since the last call, for the coast.`
 @param scroll : `The wheel over this frame, read once by the caller and shared.`
 @return `true when the camera moved — a drag, a scroll, or a coast still running.`
*>
fn bool drive_camera(
	Renderer* renderer,
	c3w::Window* window,
	Controls* controls,
	c3w::EventMap events,
	float[<2>] at,
	float dt_ms,
	float scroll = 0
)
{
	PointerState pointer = {
		.orbit = events.is_pressed(
			LEFT_MOUSE
		), // Middle alongside right because a trackpad has no third button and a
		// three-button mouse has no natural second drag; both spellings are in use
		// and neither is worth making somebody look up.
		.pan = events.is_pressed(RIGHT_MOUSE) || events.is_pressed(MIDDLE_MOUSE),
		.x = at[0],
		.y = at[1],
		.scroll = scroll,
	};

	float scale  = window.get_scale();
	// Zero while minimised, and negative never — but the division is guarded rather
	// than assumed, because the fallback is "pan does nothing this frame" and the
	// alternative is an infinity in the camera target.
	float height = scale > 0.0f ? (float)renderer.viewer.extent.height / scale : 0.0f;

	if (!controls.apply(&renderer.pass.camera, pointer, height, dt_ms)) return false;

	// `Controls.apply` has already derived the planes from the distance, which is
	// the right answer for a `Controls` that has never been shown a scene. This is
	// the caller that has one, so it derives them again against the geometry — a
	// scroll toward the model must not pull the far plane in front of the sky.
	renderer.pass.derive_camera_planes();
	return true;
}

<*
 One iteration of window, as everything downstream of it needs it.

 `closed` is the only field that means "stop"; the rest are what the loop hands
 on to the frame and to the runtime.
*>
struct WindowFrame
{
	bool closed;
	long now_ns;
	float dt_ms;
	// True when the camera moved — a drag, a scroll, or a coast still running.
	bool camera_moved;
	// Where the pointer is, before the interface's claim on it was applied. The
	// picker and the loop want the truth; a script wants the gated version, which
	// is what `input.mouse` carries.
	Cursor cursor;
	InputState input;
}

<*
 Poll, drive the interface, drive the camera, decide the cursor, latch the
 keyboard. One frame of window, in one place.

 ## Why this is a function

 It used to be a block, twice: once in `run`'s loop and once in `live`'s. Adding
 a fourth participant to both copies is how they start to disagree, and the
 interface is exactly that fourth participant — a click that presses a button
 must not also orbit the camera, and that rule has to hold in both loops or it
 does not hold at all.

 ## Who gets the pointer

 The interface sees every frame first, because only it can say whether the
 pointer is over a widget. Then:

 - **A camera drag wins over a hover.** `controls.dragging` is checked as well as
   `wants_pointer`, because a drag that began on the scene must not stop when the
   pointer passes over a panel on its way across the window. cui's own `captured`
   is the mirror of that rule for a widget's drag.
 - **A hovered widget takes the pointer**, so the camera does not orbit under a
   panel and a script's `three.input.mouse` reports `inside: false` — a click on a
   button does not also fire the gun.
 - **A focused widget takes the keyboard**, so typing in a text field is not also
   WASD.

 The typed text goes to the interface unconditionally: cui only reads it when
 something is focused, and gating it on last frame's answer would swallow the
 first character of every field.

 @param quiet : `Whether this fetch may sleep in the kernel. The caller decides; every term is in its own comment there.`
 @param [inout] last_ns : `The previous iteration's timestamp, for the delta.`
*>
fn WindowFrame drive_window(
	Renderer* renderer,
	c3w::Window* window,
	Controls* controls,
	InputTracker* keyboard,
	c3w::CursorShape* shown,
	Hover* hover,
	Clock since_start,
	long* last_ns,
	bool quiet,
	SyntheticPointer* scripted = null
)
{
	if (window.should_close()) return { .closed = true };

	c3w::EventMap events = window.getEvent(wait: quiet);
	// Only while diagnosing. Escape is the key a game binds to its pause menu, and
	// a key that closes the process out from under that menu is the engine reaching
	// past the game to the player. `three.quit()` is how a game closes itself, and
	// the title bar is how a person does; this is the developer's third way and it
	// exists because a `--headless`-less window with a broken script has no other.
	if (debugging && events.is_pressed(ESCAPE)) return { .closed = true };
	want_surface(renderer, window);

	long now_ns = (long)since_start.to_now();
	float dt_ms = (float)(now_ns - *last_ns) / 1_000_000.0f;
	*last_ns = now_ns;

	// Read once and handed to everything: the camera wants a delta in points and
	// the click wants a position in image pixels, and two readings of the same
	// instant are two chances for them to disagree.
	float[<2>] at = window.getMousePos();
	float scroll  = window.get_scroll();
	Cursor cursor = window_view(renderer, window)
		.cursor(
			at,
			events.is_pressed(LEFT_MOUSE),
			right: events.is_pressed(RIGHT_MOUSE),
			middle: events.is_pressed(MIDDLE_MOUSE),
			scroll: scroll,
			scroll_x: window
				.get_scroll_x(), // The platform's own movement, and whether it is the reading that
				// counts this frame — `three.input.pointerLock`. Asked of the window
				// rather than of the runtime, because the runtime records what a
				// script *wanted* and only the window knows whether the platform
				// gave it.
			raw: window.getMouseDelta(),
			locked: window.pointerLocked()
		);

	// What a script is holding, folded in before anything reads the pointer — so
	// cui's hit test, the cursor shape and the script are all told about one
	// pointer rather than about two. This is the window's half of a pair; the
	// windowless one is in `JsRuntime.tick`, because a host with no window has no
	// `drive_window` to put it in. A no-op until `three.input.movePointer` or a
	// scripted button has been used at all.
	//
	// The camera is deliberately not in it: `drive_camera` reads the window's own
	// points and its own button latches, so a scripted pointer drives the
	// interface and the script and leaves the turntable to the hand that is
	// actually on the mouse.
	if (scripted != null)
	{
		cursor = scripted.merge(cursor, renderer.target.extent.width, renderer.target.extent.height);
	}

	// The queue as well as the latch: a key pressed and released between two
	// frames is in one and not the other.
	FrameKeys keys = read_events(events, window.events());
	String typed   = window.get_text();

	// First, and this is the whole of the arbitration: nothing else can answer
	// "is the pointer over a widget" until cui has hit-tested this frame.
	renderer.ui.feed(cursor, keys.down, typed, dt_ms);

	bool ui_pointer = renderer.ui.wants_pointer && !controls.dragging;
	bool ui_keys    = renderer.ui.wants_keys;

	// Before `pump` in the caller, so a drag and a script that arrive in the same
	// iteration resolve in the order they happened rather than the script's
	// camera being overwritten by a stale anchor.
	bool moved;
	if (!ui_pointer)
	{
		moved = drive_camera(
			renderer: renderer,
			window: window,
			controls: controls,
			events: events,
			at: at,
			dt_ms: dt_ms,
			scroll: scroll
		);
	}

	if (ui_pointer)
	{
		// No raycast while the interface has the pointer — the answer would be
		// about something nobody can see, and it costs a BVH walk to get it.
		hover.forget();
		show_cursor(window, shown, renderer.ui.cursor_shape());
	}
	else
	{
		show_cursor(
			window,
			shown,
			cursor_shape(cursor.inside, controls.dragging, ask_hover(renderer, hover, cursor, controls.dragging))
		);
	}

	// What a script is told. The pointer is emptied rather than moved: `inside`
	// false is what stops `MouseTracker` resolving a click, and the buttons going
	// with it is what stops a press over a panel from ever starting one.
	//
	// The rule is `Cursor.behind_ui` rather than six lines here, because the
	// windowless loop has to apply the same one — a scripted press under an open
	// menu must be refused the same way a real one is.
	Cursor to_script = cursor.behind_ui(ui_pointer);

	return {
		.now_ns = now_ns,
		.dt_ms = dt_ms,
		.camera_moved = moved,
		.cursor = cursor,
		// Sampled here rather than at the tick, because this is where the events
		// are: `getEvent` clears the typed text on its next call, and the edges are
		// a difference against what the *previous* call saw.
		// 
		// The clock is this iteration's own, and not the tick's. A click is timed
		// from when the button was *sampled*, and what happens between here and the
		// tick is a whole `pump` — which on the iteration that runs a slow tool call
		// is seconds, and would turn every click that straddled it into a hold.
		.input = keyboard.step(
			ui_keys ? (FrameKeys){ } : keys,
			ui_keys ? "" : typed,
			to_script,
			(double)now_ns / 1_000_000.0
		),
	};
}

<*
 The window and the image, as a cursor sees them.

 Three extents and a scale, and the interesting one is the third: the picture in
 the window is the *offscreen target* stretched onto the swapchain image, so a
 click maps to it by fraction and never by the backing scale. `WindowView`
 carries the argument.

 Read from the renderer rather than the window for the same reason `drive_camera`
 does: `Window.width` is what `new` was asked for and the extents are what a live
 resize drag has left behind.
*>
fn WindowView window_view(Renderer* renderer, c3w::Window* window)
{
	return {
		.width = renderer.viewer.extent.width,
		.height = renderer.viewer.extent.height,
		.scale = window.get_scale(),
		.image_width = renderer.target.extent.width,
		.image_height = renderer.target.extent.height,
	};
}

<*
 The live loop: a JS context, a frame, and — optionally — the tool server and a
 game booted from a directory.

 One loop for all three, and that is the point rather than an economy. `--mcp`
 wants a context that answers tool calls; `--assets` wants a context that runs
 `main.js` and keeps ticking; `--script` wants one that has run a file and keeps
 ticking. They are the same loop with the same frame, so `--assets ./game --mcp`
 needs no arbitration at all: the agent's `run_script` and the game's
 `setAnimationLoop` are already the two things `JsRuntime` interleaves every
 frame, and an agent attaches to a game that is *playing*.

 The handlers run on this loop's thread. `Listener` gives its own thread to
 moving bytes — accept, read one message, queue it — and `pump` is where
 `handle_message` actually runs, which is what makes the scene, the JS context
 and the Vulkan device reachable from a tool without a lock between them.

 @param window : `Null when headless: the loop then only serves, and there is nothing to present.`
 @param port : `Zero to run without a listener, which is a game with no agent attached.`
 @param assets : `A game directory, or empty. The entry module is evaluated once, as a module, before the first frame.`
 @param script : `One .js file, or empty. Run once, as a script, before the first frame — see boot_script.`
 @param boot : `False for --no-boot: take the assets directory as a root and leave its main.js alone.`
 @param entry_module : `One .js file, or empty. Evaluated as an ES module before the first frame — see boot_module.`
 @require port > 0 || assets.len > 0 || script.len > 0 || entry_module.len > 0 : "a loop that neither serves nor plays has nothing to do"
*>
fn void? live(
	Renderer* renderer,
	c3w::Window* window,
	int port,
	String assets = "",
	String screenshot = "",
	String script = "",
	uint frames = 0,
	uint every = 0,
	String camera = "",
	bool boot = true,
	String entry_module = ""
)
{
	bool serving = port > 0;

	JsRuntime runtime;
	runtime.open(&renderer.pass, renderer)!;
	defer runtime.close();
	// The one thing a script may ask of the window rather than of the scene —
	// `three.input.pointerLock`. Null under `--headless`, which the verb reports
	// rather than pretends about.
	runtime.window = window;

	// Before the listener and before the first frame: a game that failed to boot
	// should say so before anything invites a tool call, and a scene an agent
	// attaches to should be the one `main.js` built.
	boot_world(&runtime, assets, script, boot, entry_module)!;

	// The bounded run, which is how a game is checked without a person watching it
	// — and the only path in this function that is not an endless loop. The ticks
	// are what make the frames the *game's*: a boot that only registered a callback
	// has drawn nothing yet, and capturing before it ran would picture an empty
	// scene and call it the game.
	if (frames > 0)
	{
		play_frames(renderer, &runtime, frames, screenshot, every, camera)!;
		return;
	}

	// Addressed by pointer from every tool, so it must not move while the server
	// lives — which is why it is a local of the function that owns the loop rather
	// than something returned from a builder.
	ToolHost host      = { .runtime = &runtime, .renderer = renderer };
	mcp::Server server = new_mcp_server(&host);

	mcp::Listener listener;
	// The wake is what lets the window sleep. Without it an idle loop parked in
	// `getEvent(wait: true)` would go on sleeping through every request, and the
	// whole tool surface would answer only when somebody moved the mouse.
	// `Window.wake` posts an application-defined event from the listener's own
	// thread, which is the one thing a foreign thread is allowed to do to a Cocoa
	// run loop.
	if (serving) listener.start(port, wake: &wake_window, wake_ctx: window)!;
	defer if (serving) listener.stop();

	if (serving)
	{
		io::printfn("mcp: http://127.0.0.1:%d/mcp", port);
		io::printn("     run_script, screenshot, get_api_docs");
	}
	// Named as a game only when there is an entry module to boot; otherwise the
	// directory is the root a `--script` loads out of, and naming a `main.js` that
	// is not there would be the startup line telling a small lie.
	if (assets.len > 0)
	{
		if (wants_entry_module(assets, script))
		{
			io::printfn("game: %s/%s", assets, ENTRY_MODULE);
		}
		else
		{
			io::printfn("assets: %s", assets);
		}
	}
	if (script.len > 0) io::printfn("script: %s", script);
	if (window == null)
	{
		io::printn("     headless — ctrl-c to stop");
	}
	else
	{
		io::printn("     drag to orbit, right-drag to pan, scroll to zoom");
		// Printed only when they work. A line offering two keys that do nothing is
		// worse than no line, and this is the only place a person finds out that
		// `--debug` is what turns them on.
		if (debugging) io::printn("     shift+R reloads the script, escape quits");
	}

	// No `Controls` of its own: the runtime holds the one this loop drives, so that
	// `three.controls.enabled` writes the same struct `apply` reads.
	InputTracker keyboard;
	InputState input;
	c3w::CursorShape shown;
	Hover hover;

	// What the frames have said, drained into the terminal once a frame when there
	// is no agent to read it instead — `JsRuntime.take_frame_output` has the
	// argument. One buffer for the whole loop, reused rather than allocated sixty
	// times a second.
	DString said;
	said.init(mem, 256);
	defer said.free();

	// What the animation callback is told the time is. Stamped once, here, so it is
	// monotonic across every registration a script makes — which is what Three.js's
	// `setAnimationLoop` argument is, and what a callback computing a rotation from
	// it assumes.
	Clock since_start  = clock::now();
	long last_tick_ns  = 0;
	long last_frame_ns = 0;

	// Whether the last iteration left nothing to do. Read at the top of the next
	// one, which is the only place the question can be asked: the answer has to be
	// known *before* the events are fetched, and everything that decides it happens
	// after.
	bool quiet        = false;
	bool camera_moved = false;

	while (true)
	{
		if (window != null)
		{
			// One call, and `run`'s loop makes the same one. Everything about a
			// frame of window — the events, the pointer, the interface, the camera,
			// the cursor shape and the keyboard a script sees — happens in there, so
			// a fifth participant is added once instead of twice.
			WindowFrame poll = drive_window(
				renderer,
				window,
				&runtime.controls,
				&keyboard,
				&shown,
				&hover,
				since_start,
				&last_frame_ns,
				quiet,
				// The runtime's own, for `controls`' reason: a script writes
				// `three.input.movePointer` into the same struct this loop reads,
				// so there is one pointer rather than two answers about one.
				&runtime.pointer
			);
			if (poll.closed) break;
			camera_moved = poll.camera_moved;
			input = poll.input;

			// A widget handler that asked for a new tree was held while cui was
			// walking the old one. This is the first moment it is not — see
			// `JsRuntime.flush_ui`.
			runtime.flush_ui();
		}

		// Nothing to pump when there is no listener; a game alone still ticks.
		usz handled = serving ? listener.pump(&server) : 0;

		// Read in the same place as the reload and for the same reason: the request
		// came from JavaScript, and acting on it while the call that made it is
		// still on the stack would free the engine underneath it. So the game's menu
		// closes the window on the next iteration rather than inside the click, and
		// the last frame it built is the last frame shown.
		if (runtime.quit_wanted) break;

		// Beside the two above and for their reason: a resize frees the images the
		// frame that asked for it was drawing into, so the animation callback's
		// request is performed here, where nothing of JavaScript's is on the stack.
		// A resize made from a tool call or a booting script never reaches this —
		// `js_render_resize` does those on the spot.
		runtime.take_render_resize();

		// After `pump` and before the tick, which is the one point in an iteration
		// with nothing of JavaScript's on the stack — a reload frees the engine the
		// call asking for it was made from. So a `three.reload()` in a tool call is
		// honoured on the iteration that answered it, one from a frame callback on
		// the next, and shift+R before the world it is replacing gets a last frame.
		//
		// The chord is the half that `--debug` gates, and the verb is not: a game
		// that calls `three.reload()` asked for it, while a player who happened to
		// hold shift and press R did not.
		//
		// `runtime` is a different object on the far side of this. Nothing below
		// holds a pointer into it — `controls` is read as `runtime.controls` every
		// frame for exactly this kind of reason.
		if (runtime.reload_wanted || (debugging && window != null && wants_reload(input)))
		{
			Clock took = clock::now();
			reload(&runtime, &renderer.pass, renderer, window, assets, script, boot, entry_module)!;
			io::printfn("three: reloaded in %d ms", (long)took.to_now() / 1_000_000);
		}

		long elapsed_ns = (long)since_start.to_now();

		if (window != null)
		{
			// After `pump` and before the draw: a script that registers a callback
			// gets its first frame on this iteration, and the frame presented is the
			// one the callback just built.
			runtime.tick((double)elapsed_ns / 1_000_000.0, input);

			// Kept running whether or not anything arrived: a window that only
			// redrew when a tool was called would stop responding between requests,
			// which reads as a hung application.
			bool ui_idle   = renderer.ui.idle();
			bool presented = renderer.frame()!;

			// When the next fetch is allowed to sleep in the kernel. Every term is
			// something that would be lost by sleeping through it:
			// 
			// - `presented` — a frame that rebuilt the swapchain instead of drawing
			//   has not shown the current state yet, so the loop owes one more
			//   iteration before it may rest.
			// - `is_animating` — a registered callback or handler means the runtime
			//   has work every frame by definition, and this is `tick`'s own
			//   early-return condition rather than a second copy of it.
			// - `is_simulating` — a body still falling. A scene with physics and no
			//   `setAnimationLoop` is not "animating" by any test above, so without
			//   this the world advanced only while the mouse was moving.
			// - `camera_moved` — a coast is still running, and a drag that ends is
			//   followed by a third of a second of frames nobody asked for.
			// - `handled` — a tool call may have changed the scene, and the answer
			//   went out before the frame that shows it.
			// - `ui_idle` — cui sets `frame_requested` on every invalidation, so a
			//   panel that a click has just changed still owes a frame. Read
			//   unconditionally rather than inside the `&&` chain, because reading
			//   is what clears it and a short-circuit would leave it standing.
			quiet = presented && !runtime.is_animating() && !runtime.is_simulating() && !camera_moved && handled == 0
				&& ui_idle;
		}
		else
		{
			// Headless ticks too, and paced. A callback that behaved differently
			// with `--headless` would be a difference an agent cannot see: it has no
			// window to look at and no way to ask whether there is one. Pacing is
			// what makes it the same difference rather than merely present — this
			// loop is bounded by a 4 ms sleep and would otherwise run a callback
			// four times for every frame a vsynced window gives it.
			if (elapsed_ns - last_tick_ns >= HEADLESS_FRAME_MS * 1_000_000)
			{
				last_tick_ns = elapsed_ns;
				// No window, so no keyboard: the default empty state, and
				// `three.input.isDown` answers false rather than throwing. A script
				// written for a window still runs here; it just gets no input.
				runtime.tick((double)elapsed_ns / 1_000_000.0);
			}
			if (handled == 0)
			{
				// A tight loop here would peg a core for as long as the server is
				// idle, which is most of its life.
				thread::sleep_ms(4)!!;
			}
		}

		// Only when nobody is serving, and that condition is the whole of the
		// decision: with a listener up, what the frames logged belongs to the next
		// `run_script`, and draining it here would take it away from the agent that
		// asked. With no listener there is no next run — the terminal is the only
		// reader there will ever be.
		if (!serving)
		{
			said.clear();
			runtime.take_frame_output(&said);
			if (said.len() > 0) io::print(said.str_view());
		}
	}
}

<*
 Runs a fixed number of frames with no window, printing what they logged and
 writing the ones that were asked for.

 Physics stepping, the animation callback running and `three.input.press`
 latching are not three features — they are three things downstream of a frame
 boundary, and a headless render that draws one frame has no boundaries in it at
 all. Without this, `three.input.press('w')` followed by `isDown('w')` answers
 false while `planarMove(1, 0)` answers a unit vector in the same breath: the
 movement code is fine and unreachable.

 The clock is counted, not measured. Frame `i` is told `i * HEADLESS_FRAME_MS`,
 so 600 frames is ten seconds of game time on every machine and the same run
 twice is the same run. A wall clock here would make every assertion about where
 something got to an assertion about how busy the laptop was.

 The first frame is told 0.0, which is what a one-frame `--screenshot` has always
 been told, so `--frames 1` is that mode unchanged rather than that mode plus a
 clock tick.

 Frame output is drained every frame, not at the end: a run that logs from its
 callback is the run somebody is reading, and a buffer that only reached the
 terminal at the end would lose everything if the last frame threw.

 @param frames : `How many ticks. At least one — parse_args refuses to reach here with zero.`
 @param screenshot : `Where to write, or empty to run the frames and write nothing. See frame_path for the numbering.`
 @param every : `Also write every n frames, not only the last. 0 writes the last only.`
 @param camera : `A yaw,pitch,distance override, applied before every capture so a follow camera cannot take the shot back.`
*>
fn void? play_frames(
	Renderer* renderer,
	JsRuntime* runtime,
	uint frames,
	String screenshot = "",
	uint every = 0,
	String camera = ""
)
{
	// Once here as well as before each shot: a callback that reads the camera on
	// its first frame should read the one that was asked for, and a scene with no
	// follow camera then never needs the second application at all.
	aim_camera(renderer, camera);

	DString said;
	said.init(mem, 256);
	defer said.free();

	uint shots = 0;
	for (uint i = 0; i < frames; i++)
	{
		runtime.tick((double)i * (double)HEADLESS_FRAME_MS);

		said.clear();
		runtime.take_frame_output(&said);
		if (said.len() > 0) io::print(said.str_view());

		// `three.quit()` is honoured here as anywhere: the request was made from
		// JavaScript and the tick that carried it is over, so nothing of the
		// engine's is on the stack. The run says it ended early rather than
		// pretending the frames asked for were the frames that ran — a probe that
		// asks to quit and then keeps seeing output for another nine hundred
		// frames reads as the verb doing nothing.
		if (runtime.quit_wanted)
		{
			io::eprintfn("three: three.quit() ended this --frames run at frame %d of %d", i + 1, frames);
			return;
		}

		bool last = i + 1 == frames;
		bool due  = every > 0 && (i + 1) % every == 0;
		bool shot = screenshot.len > 0 && (last || due);

		// The draw is not optional and it is not the screenshot. A tick without one
		// is what the headless loop has always done, and it is why
		// `stats().shadowDraws` and `three.light.shadow.fit` answered "nothing
		// happened" from inside a callback that had been running for four frames:
		// the fit is computed in `prepare`, and `prepare` is part of drawing.
		// 
		// Exactly one render per frame either way — `screenshot` draws before it
		// reads back, so a frame that is being captured must not also be drawn.
		if (!shot)
		{
			renderer.render_offscreen()!;
			continue;
		}

		// After the tick and immediately before the capture, so what lands in the
		// PNG is what was asked for rather than wherever `camera.attach` left it.
		aim_camera(renderer, camera);
		String out = frame_path(screenshot, shots);
		renderer.screenshot(out)!;
		io::printfn("wrote %s (frame %d)", out, i + 1);
		shots++;
	}

	if (screenshot.len == 0) io::printfn("ran %d frames", frames);
}

<*
 Points the camera where `--camera` said, if it said anything.

 Applied over the scene rather than under it, which is the flag's whole reason
 for existing: the alternative is a script that rewrites the scene file into a
 temporary copy with a different `orbit` call spliced in. A viewpoint is not a
 property of the scene.

 The planes are re-derived afterwards for the same reason `drive_camera` does it:
 a distance handed straight in is a near and a far plane computed for a different
 one.

 @param spec : `"yaw,pitch,distance" in degrees and world units. Empty does nothing; anything that does not parse says so and does nothing.`
 @return `true when the camera was moved.`
*>
fn bool aim_camera(Renderer* renderer, String spec)
{
	if (spec.len == 0) return false;

	@pool()
	{
		String[] parts = spec.tsplit(",");
		if (parts.len != 3)
		{
			io::printfn("--camera %s: expected yaw,pitch,distance", spec);
			return false;
		}

		float[3] value;
		foreach (i, part : parts)
		{
			double? number = part.trim().to_double();
			if (catch number)
			{
				io::printfn("--camera %s: '%s' is not a number", spec, part);
				return false;
			}
			value[i] = (float)number;
		}

		renderer.pass.camera.yaw = value[0];
		renderer.pass.camera.pitch = value[1];
		renderer.pass.camera.distance = value[2];
		renderer.pass.camera.clamp_angles();
		renderer.pass.derive_camera_planes();
		return true;
	};
}

<*
 A screenshot path with the shot number in it, for `--every`.

 `shot-%03d.png` becomes `shot-000.png`, `shot-001.png`, and a path with no `%d`
 in it is returned unchanged — which is what makes `--screenshot out.png` with no
 `--every` write `out.png` and not `out0.png`. A width pads with zeros whether or
 not the `0` was written, because these are filenames and a run of more than nine
 frames should still sort.

 One specifier, the first one found. A second `%d` in a screenshot path is
 somebody's typo, not a second counter.

 @param pattern : `The path as it was given on the command line.`
 @param index : `Which shot this is, counting from zero.`
 @return `A temp-allocated path, or the pattern itself when there is nothing to substitute.`
*>
fn String frame_path(String pattern, uint index)
{
	usz at     = 0;
	usz stop   = 0;
	usz width  = 0;
	bool found = false;

	for (usz i = 0; i + 1 < pattern.len && !found; i++)
	{
		if (pattern[i] != '%') continue;
		usz j      = i + 1;
		usz digits = 0;
		while (j < pattern.len && pattern[j] >= '0' && pattern[j] <= '9')
		{
			digits = digits * 10 + (usz)(pattern[j] - '0');
			j++;
		}
		if (j < pattern.len && pattern[j] == 'd')
		{
			at = i;
			stop = j + 1;
			width = digits;
			found = true;
		}
	}

	if (!found) return pattern;

	DString out;
	out.init(tmem);
	out.append(pattern[:at]);

	String number = string::tformat("%d", index);
	for (usz i = number.len; i < width; i++) out.append("0");
	out.append(number);
	out.append(pattern[stop..]);
	return out.str_view();
}

