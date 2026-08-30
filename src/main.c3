<*
 three.c3 — boot, CLI, the window loop, and the MCP server.

 three [options]

 --mcp [port]          serve run_script/screenshot/get_api_docs (default 8808)
 --mcp-stdio [port]    relay stdin/stdout to a three that is already serving
 --screenshot <path>   render one frame, write a PNG, exit
 --width <n>           offscreen render width  (default 1280)
 --height <n>          offscreen render height (default 720)
 --headless            no window, no surface, no swapchain
 --script <file.js>    boot one script, then keep the window running
 --assets <dir>        boot a game: evaluate <dir>/main.js as a module
 --frames <n>          run n frames, then stop. Implies --headless
 --every <n>           with --frames, also shoot every n frames — see frame_path
 --camera <y,p,d>      yaw, pitch, distance, applied over whatever the script set

 There is no file argument. A model is loaded from JavaScript — `three.load`
 hands the script an object it can place, parent and dispose — and a model the
 command line put on screen was none of those things: nothing named it, nothing
 could free it, and it sat in a scene of its own for the life of the process.
 `--script` and `--assets` are the two ways in.

 The window is a viewer and also a control: drag to orbit, right-drag to pan,
 scroll to zoom. It writes the same `pass.camera` a script writes through
 `three.camera`, so the two compose with no arbitration — see
 `scene/controls.c3`.

 Validation is not on this list, and that is the whole of its interface: a
 validation error only reaches `run_script`'s answer if the layer that produces
 it is loaded, so the build answers the question rather than the CLI. `-D DEBUG`
 runs the layers, always; a release build has none in it to run, and `--validate`
 is refused as an unknown option. See `src/debug.c3`.

 The server's handlers run on *this* thread — `Listener` moves bytes on its own
 and `pump` runs the work on the caller's — so a script, the scene it builds and
 the device it draws with are all touched from one place, and none of the three
 needs a lock.
*>
module three;

import std::io;
import std::io::file;
import std::math;
import std::thread;
import std::time;
import c3w;
import vk;
import image;
import mcp;

const String VERSION = "0.1.0";

struct Options
{
	// The game directory: `.js` to run, `.glb` to describe.
	String assets;
	// One `.js` file, run the way `run_script` runs one — see `boot_script`.
	String script;
	String screenshot;
	uint width;
	uint height;
	bool headless;
	<*
	 How many frames to run before stopping. 0 is "not asked for", which is the
	 window's endless loop or — with `--screenshot` — the single frame that mode
	 has always rendered.

	 A headless render is one frame, and a frame loop is what physics, the
	 animation callback and the keyboard latch are all downstream of: nothing that
	 moves can be tested against a still.
	*>
	uint frames;
	// With `frames`, write a numbered shot every n of them as well as the last. 0
	// writes only the last one. `frame_path` says how the number gets in.
	uint every;
	// yaw,pitch,distance — applied after the script has run and again before every
	// capture. Empty means the scene keeps its own camera.
	String camera;
	// 0 for "do not serve". The port is only ever bound on 127.0.0.1 — and under
	// `--mcp-stdio` it is the port *connected to* rather than bound, which is what
	// makes `--mcp 9000 --mcp-stdio` relay to 9000.
	int mcp_port;
	// Be the stdio end of somebody else's server rather than a server: no window,
	// no device, no scene. See `serve_relay`.
	bool relay_stdio;
	bool help;
}

const int DEFAULT_MCP_PORT = 8808;

faultdef BAD_ARGUMENT, MISSING_VALUE, SCRIPT_NOT_READABLE;

fn Options? parse_args(String[] args)
{
	Options opts = { .width = 1280, .height = 720 };

	for (usz i = 1; i < args.len; i++)
	{
		String arg = args[i];
		switch (arg)
		{
			case "--help":
			case "-h":
				opts.help = true;
			case "--headless":
				opts.headless = true;
			case "--assets":
				if (i + 1 >= args.len) return MISSING_VALUE~;
				opts.assets = args[++i];
			case "--script":
				if (i + 1 >= args.len) return MISSING_VALUE~;
				opts.script = args[++i];
			case "--screenshot":
				if (i + 1 >= args.len) return MISSING_VALUE~;
				opts.screenshot = args[++i];
			case "--width":
				if (i + 1 >= args.len) return MISSING_VALUE~;
				opts.width = args[++i].to_uint()!;
			case "--height":
				if (i + 1 >= args.len) return MISSING_VALUE~;
				opts.height = args[++i].to_uint()!;
			case "--frames":
				if (i + 1 >= args.len) return MISSING_VALUE~;
				opts.frames = args[++i].to_uint()!;
			case "--every":
				if (i + 1 >= args.len) return MISSING_VALUE~;
				opts.every = args[++i].to_uint()!;
			case "--camera":
				if (i + 1 >= args.len) return MISSING_VALUE~;
				opts.camera = args[++i];
			case "--mcp":
				// The port is optional, so a following argument is consumed only
				// when it actually looks like one — otherwise `three --mcp
				// --headless` would swallow the flag beside it.
				opts.mcp_port = DEFAULT_MCP_PORT;
				if (i + 1 < args.len)
				{
					if (try port = args[i + 1].to_int())
					{
						opts.mcp_port = port;
						i++;
					}
				}
			case "--mcp-stdio":
				// The same optional port, for the same reason — and a port already
				// named by an earlier `--mcp` is kept, so the two flags compose in
				// either order.
				opts.relay_stdio = true;
				if (opts.mcp_port == 0) opts.mcp_port = DEFAULT_MCP_PORT;
				if (i + 1 < args.len)
				{
					if (try port = args[i + 1].to_int())
					{
						opts.mcp_port = port;
						i++;
					}
				}
			default:
				// Everything on the line is a flag. A bare path used to be loaded
				// and displayed, which is the one thing this cannot offer a script:
				// no handle to it, no way to dispose it, and a scene of its own for
				// the rest of the run. Loading is `three.load` inside a script.
				if (arg.starts_with("-"))
				{
					io::printfn("unknown option: %s", arg);
				}
				else
				{
					io::printfn("three takes no file argument: %s", arg);
					io::printn("  A model is loaded from a script: three.load(\"model.glb\").");
					io::printn("  --script <file.js> runs one; --assets <dir> boots <dir>/main.js.");
				}
				return BAD_ARGUMENT~;
		}
	}

	// A screenshot is a one-shot render and has no use for a window; asking for one
	// without --headless is the common case, so imply it rather than opening a
	// window that flashes for a frame.
	if (opts.screenshot.len > 0) opts.headless = true;
	// A bounded run is a batch, for the same reason and with one more: a window
	// that opened, played 600 frames at whatever rate the compositor felt like,
	// and closed is not something anybody asked to watch — and the point of
	// counting frames is that the same count means the same thing on every
	// machine, which a vsynced window is exactly what takes away.
	if (opts.frames > 0) opts.headless = true;
	// A server that rendered one frame and exited would be no server at all — and
	// one that played 600 and exited is the same mistake with a longer fuse.
	if (opts.mcp_port > 0)
	{
		opts.screenshot = "";
		opts.frames = 0;
	}
	// `--screenshot` on its own has always meant one frame. Saying so here is what
	// lets everything below read `frames` and never ask which mode it is in.
	if (opts.frames == 0 && opts.screenshot.len > 0) opts.frames = 1;

	return opts;
}

fn void usage()
{
	io::printn("three.c3 — a Three.js-shaped scene API over C3 and Vulkan");
	io::printfn("version %s", VERSION);
	io::printn("");
	io::printn("  three [options]");
	io::printn("");
	io::printn("  --mcp [port]          serve the agent tools on 127.0.0.1 (default 8808)");
	io::printn("  --mcp-stdio [port]    be the stdio end of a three that is already serving");
	io::printn("  --screenshot <path>   render one frame, write a PNG, exit");
	io::printn("  --width <n>           offscreen render width  (default 1280)");
	io::printn("  --height <n>          offscreen render height (default 720)");
	io::printn("  --headless            no window, no surface, no swapchain");
	io::printn("  --script <file.js>    run one script, then keep the window running");
	io::printn("  --assets <dir>        boot a game: evaluate <dir>/main.js as a module");
	io::printn("  --frames <n>          run n frames and stop — implies --headless");
	io::printn("  --every <n>           with --frames, shoot every n frames: shot-%03d.png");
	io::printn("  --camera <yaw,pitch,distance>   look from here, over whatever the script set");
	io::printn("  -h, --help            this");
	io::printn("");
	io::printn("  There is no file argument: a model is loaded from a script, with");
	io::printn("  three.load(\"model.glb\"), which is what hands it back as an object.");
	io::printn("");
	// Which binary this is, rather than a flag for changing it. The layers moved to
	// `-D DEBUG` and the shader search path to `shaders/`, so the two things the
	// line used to be able to say are now properties of the build and of the
	// working directory — and `--help` is where somebody goes to find that out.
	if (DEBUG_BUILD)
	{
		io::printn("  Built with -D DEBUG: Vulkan validation layers on, @debug_log compiled in.");
	}
	else
	{
		io::printn("  Built without -D DEBUG: no validation layers in this binary.");
	}
	io::printn("  Shaders are read from shaders/ — run from the project root.");
}


<*
 Whether this binary was built with `-D DEBUG`.

 A plain constant rather than a `$if` at every reading, so it can be branched on
 in ordinary code and asserted on in tests.
*>
const bool DEBUG_BUILD = $feat(DEBUG);

<*
 A log line that exists only in a debug build.

 The arguments are not evaluated without one, which makes this usable where
 composing the message costs more than printing it: `@debug_log("%s", describe())`
 does not call `describe` in a release build.

 That property is why the signature uses untyped varargs. A typed parameter list
 — `macro @debug_log(String format, args...)` — still evaluates everything at the
 call site even with the same `$if`'d body; only `$vaarg` inside the `$if`
 disappears with it.

 This is for the developer at the terminal, not the agent: what a `run_script`
 should see belongs in `log`, which comes back through `RunResult`, and advice
 about the scene belongs in `@advise`, which reaches the agent always and the
 terminal when no server is driving.
*>
macro @debug_log(format, ...)
{
	$if DEBUG_BUILD:
		io::printfn(format, ...$vaarg);
	$endif
}

fn int main(String[] args)
{
	Options? parsed = parse_args(args);
	if (catch err = parsed)
	{
		usage();
		return 1;
	}
	Options opts = parsed;

	if (opts.help)
	{
		usage();
		return 0;
	}

	// Before anything that opens a window or a device, and before anything that
	// could print: this process is the stdio end of another one's server, and the
	// only thing a client will tolerate on its stdout is JSON-RPC.
	if (opts.relay_stdio) return serve_relay(opts.mcp_port);

	if (catch err = run(opts))
	{
		io::printfn("three: %s", err);
		// The one failure with an obvious next step, and the one most likely to be
		// hit: the shaders are read from disk relative to the working directory, so
		// running from anywhere but the project root finds nothing. There is no
		// build step to suggest and no flag either — five templates are looked up
		// this way, and a flag naming one of them fixed nothing.
		if (err == SHADER_NOT_FOUND)
		{
			io::printn("  shaders/ is not on the search path — mesh, material, post,");
			io::printn("  shadow and skin are all read from it. Run from the project root.");
		}
		// The path is named here rather than in the fault, because this is the only
		// place that still has it: a `--script` typo is otherwise a bare fault name
		// over a path the shell may well have expanded.
		if (err == SCRIPT_NOT_READABLE)
		{
			io::printfn("  --script %s: not a file this can read.", opts.script);
			io::printn("  A directory is --assets, and it boots main.js as a module.");
		}
		// Not a shader error — a shader error is a Slang diagnostic, already printed
		// above this by the compiler with a line and a column.
		if (err == SLANG_UNAVAILABLE)
		{
			io::printn("  Slang would not start. It is linked into this binary, so this is");
			io::printn("  not a missing file — see the diagnostic above, if there was one.");
		}
		// Two different ways of saying "the only driver here is MoltenVK": the
		// loader refuses to make the instance when that is all it has, and the
		// device filter refuses the device if one reaches it anyway. Neither message
		// says what to do about it, so this does.
		if (err == PORTABILITY_DRIVER_ONLY || err == vk::E_ERROR_INCOMPATIBLE_DRIVER)
		{
			io::printn("  No supported Vulkan driver. three.c3 renders through KosmicKrisp,");
			io::printn("  which vulkan.c3l bundles; MoltenVK is not supported.");
			// The bundled driver failing to *open* looks identical to no driver at
			// all — `vk::findBundledDriver` reads a refused dlopen as "there is
			// none" and falls back — and the commonest reason it is refused is the
			// OS being older than the dylib. KosmicKrisp is built on Metal 4, so the
			// bundle carries a macOS 26 floor that nothing else in it does.
			$if env::DARWIN:
				io::printn("  It is a Metal 4 driver: macOS 26 or newer, on Apple Silicon.");
			$endif
		}
		return 1;
	}
	return 0;
}

fn void? run(Options opts)
{
	// The window is a viewer, never a render target. It is opened first only
	// because the surface has to come from somewhere; nothing about it reaches the
	// offscreen target's extent or format.
	c3w::Window window;
	bool windowed = !opts.headless;
	if (windowed)
	{
		window = c3w::new(
			params: { .x = 0, .y = 0, .width = (int)opts.width, .height = (int)opts.height },
			name: "three.c3"
		)!;
	}
	defer if (windowed) window.free();

	vk::Instance instance = create_instance(DEBUG_BUILD, headless: opts.headless)!;
	defer instance.free();

	vk::SurfaceKHR surface;
	if (windowed)
	{
		surface = (vk::SurfaceKHR)window.create_vk_surface(
			instance,
			(c3w::VkGetInstanceProcAddrFn)vk::getInstanceProcAddr
		)!;
	}
	defer if (windowed) surface.free(instance);

	Renderer renderer;
	renderer.init(instance, surface, opts.width, opts.height, DEBUG_BUILD)!;
	defer renderer.free();

	// The device table on every debug run, where it used to take a flag. A build
	// that carries the validation layers is a build somebody is diagnosing with,
	// and the first question a diagnosis asks is which device and which limits —
	// `Gpu.report` prints whether validation actually loaded, which is the one
	// thing `DEBUG_BUILD` cannot promise on its own.
	if (DEBUG_BUILD) renderer.gpu.report();

	// The shader is compiled here, from shaders/mesh.slang on disk. Editing it and
	// re-running changes the picture — no rebuild of this binary, and no build step
	// for the shader either.
	renderer.pass.init(&renderer.gpu, &renderer.target)!;

	if (opts.script.len == 0 && opts.assets.len == 0)
	{
		// The placeholder for "nothing was given", and only then. A script or a
		// game builds its own scene, and since `new three.Scene()` stopped emptying
		// the one before it, a triangle put here would be a scene nothing draws and
		// nothing can dispose — counted by `stats().scenes` for the rest of the run.
		renderer.pass.load_triangle(&renderer.gpu)!;
	}

	// The line an agent reads its own cost off. `instances` next to `draw calls` is
	// the whole claim in two numbers: a grid of a thousand is a thousand and one,
	// not a thousand and a thousand.
	SceneStats stats = renderer.pass.stats();
	io::printfn(
		"%s: %d draw calls, %d instances, %d unique meshes, %d textures (%d KiB), %d triangles",
		opts.script.len > 0 || opts.assets.len > 0 ? "empty scene" : "built-in triangle",
		stats.draw_calls,
		stats.instances,
		stats.unique_meshes,
		stats.textures,
		stats.texture_bytes / 1024,
		stats.triangles
	);

	// Before every one-shot path below: neither a server, a game nor a booted
	// script renders one frame and exits, and all three work with or without a
	// window. They compose — `--assets ./game --mcp` plays and answers tool calls
	// at the same time, and `--script` adds one more thing for the same loop to
	// have run before the first frame.
	if (opts.mcp_port > 0 || opts.assets.len > 0 || opts.script.len > 0)
	{
		live(
			&renderer,
			windowed ? &window : null,
			opts.mcp_port,
			assets: opts.assets,
			screenshot: opts.screenshot,
			script: opts.script,
			frames: opts.frames,
			every: opts.every,
			camera: opts.camera
		)!;
		return;
	}

	if (opts.screenshot.len > 0)
	{
		// No runtime on this path, so nothing can move and nothing can steal the
		// camera back: the override is applied once and the frame count is a count
		// of identical frames. It is still honoured, because `--every` over a static
		// scene is how the flipbook itself gets checked.
		aim_camera(&renderer, opts.camera);
		for (uint i = 0; i < math::max(opts.frames, (uint)1); i++)
		{
			String out = frame_path(opts.screenshot, i);
			renderer.screenshot(out)!;
			io::printfn("wrote %s (%dx%d)", out, opts.width, opts.height);
			if (opts.every == 0) break;
		}
		return;
	}

	// Headless with nothing to write is still worth running: it exercises the whole
	// render path with no window server, which is exactly what the tests do.
	if (!windowed)
	{
		image::Image frame = renderer.capture()!;
		defer frame.free();
		io::printfn("rendered %dx%d headless", frame.width, frame.height);
		return;
	}

	Controls controls = DEFAULT_CONTROLS;
	InputTracker keyboard;
	c3w::CursorShape shown;
	Hover hover;
	Clock since_start = clock::now();
	long last_ns;
	// Nothing but the mouse can change this window, so it sleeps between gestures —
	// see `serve`, which has more to wait for and says why there.
	bool quiet        = false;

	while (true)
	{
		WindowFrame poll = drive_window(
			&renderer,
			&window,
			&controls,
			&keyboard,
			&shown,
			&hover,
			since_start,
			&last_ns,
			quiet
		);
		if (poll.closed) break;

		bool ui_idle   = renderer.ui.idle();
		bool presented = renderer.frame()!;
		quiet = presented && !poll.camera_moved && ui_idle;
	}
}

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
	bool quiet
)
{
	if (window.should_close()) return { .closed = true };

	c3w::EventMap events = window.getEvent(wait: quiet);
	if (events.is_pressed(ESCAPE)) return { .closed = true };
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
	Cursor to_script = cursor;
	if (ui_pointer)
	{
		to_script.inside = false;
		to_script.down = false;
		to_script.right = false;
		to_script.middle = false;
		to_script.scroll = 0;
		to_script.scroll_x = 0;
	}

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
 @require port > 0 || assets.len > 0 || script.len > 0 : "a loop that neither serves nor plays has nothing to do"
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
	String camera = ""
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
	boot_world(&runtime, assets, script)!;

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
	if (assets.len > 0) io::printfn("game: %s/%s", assets, ENTRY_MODULE);
	if (script.len > 0) io::printfn("script: %s", script);
	if (window == null)
	{
		io::printn("     headless — ctrl-c to stop");
	}
	else
	{
		io::printn("     drag to orbit, right-drag to pan, scroll to zoom");
		io::printn("     shift+R reloads the script, escape quits");
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
				quiet
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

		// After `pump` and before the tick, which is the one point in an iteration
		// with nothing of JavaScript's on the stack — a reload frees the engine the
		// call asking for it was made from. So a `three.reload()` in a tool call is
		// honoured on the iteration that answered it, one from a frame callback on
		// the next, and shift+R before the world it is replacing gets a last frame.
		// 
		// `runtime` is a different object on the far side of this. Nothing below
		// holds a pointer into it — `controls` is read as `runtime.controls` every
		// frame for exactly this kind of reason.
		if (runtime.reload_wanted || (window != null && wants_reload(input)))
		{
			Clock took = clock::now();
			reload(&runtime, &renderer.pass, renderer, window, assets, script)!;
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

<*
 Runs whatever put a world on screen: a game directory, a script, or both.

 A function rather than two blocks inside `live`, because `reload` needs the same
 two things in the same order — a reload *is* this, with a teardown in front of
 it — and a second spelling of "how a game boots" is how the two would come to
 disagree about which of them runs first.

 Both orders are defensible and this one composes: `--assets ./game --script
 probe.js` runs the script against the world `main.js` built, which is what the
 same two things would do through the server.

 A game that failed to boot is printed and carried on with rather than returned
 as a fault. That is exactly when someone wants to look at it — with `--mcp` that
 means attaching and asking, and with a window it means seeing an empty scene
 beside the reason for it.

 @return ? SCRIPT_NOT_READABLE : `Only from --script: nothing at that path. A game directory that will not boot is reported and not raised.`
*>
fn void? boot_world(JsRuntime* runtime, String assets, String script)
{
	if (assets.len > 0)
	{
		runtime.set_assets_root(assets);
		RunResult booted = runtime.run_module(ENTRY_MODULE);
		defer booted.free();

		if (booted.log.len > 0) io::printn(booted.log);
		if (!booted.ok)
		{
			io::printfn("three: %s/%s did not run: %s", assets, ENTRY_MODULE, booted.error);
		}
	}

	if (script.len > 0) boot_script(runtime, script)!;
}

<*
 Runs one `.js` file the way `run_script` runs one, before the first frame.

 A script and not a module, which is the whole difference from `--assets`: the
 source is wrapped in an async function, so top-level `await` and top-level
 `return` both work and `import` does not. That makes `--script examples/vfx.js`
 mean exactly what pasting the same file into `run_script` means. A program in
 several files is what `--assets` is for.

 For the same reason there is no assets root: a path the script hands to
 `three.load` is relative to where the process was started, as it is for an
 agent, rather than to wherever the script happens to live.

 The frame policy is the game's, though. `game_frames` decides what happens when
 a callback runs long, and the choice is between stopping it for good and
 counting it. Stopping is right when an agent is sitting there to be told and a
 runaway loop would wedge the tool surface; a script booted from a command line
 is somebody watching a window, where the answer to one slow frame is not to kill
 the animation.

 A script that throws is printed and carried on with, exactly as a game that
 fails to boot is.

 @return ? SCRIPT_NOT_READABLE : `Nothing at that path, or it is a directory — a typo on the command line, not something to debug in a running scene.`
*>
fn void? boot_script(JsRuntime* runtime, String path)
{
	// The frame policy, before anything the script does can register a callback.
	runtime.play_frames();

	@pool()
	{
		if (!file::is_file(path)) return SCRIPT_NOT_READABLE~;
		char[]? source = file::load_temp(path);
		if (catch source) return SCRIPT_NOT_READABLE~;

		// Named by the path it was given, so a stack trace says `vfx.js:412` and not
		// `<script>:412`.
		RunResult ran = runtime.run((String)source, path);
		defer ran.free();

		if (ran.log.len > 0) io::printn(ran.log);
		// `value` is not printed and this is, which is the difference between them
		// here: a returned value is an answer to whoever CALLED, and over MCP there
		// is one. A `--script` run has no caller, so what the script wanted said out
		// loud is the only half of the pair that has a reader on this path.
		if (ran.debug.len > 0) io::printfn("debug: %s", ran.debug);
		if (!ran.ok) io::printfn("three: %s did not run: %s", path, ran.error);
	};
}

<*
 The file a `--assets` boot runs.

 Fixed rather than configurable, and named for the same reason `index.html` is: a
 directory that boots has to boot the same way on every machine, and a flag that
 changed the entry point would be one more thing to get wrong in a bug report
 that starts "it works here".
*>
const String ENTRY_MODULE = "main.js";

// What a frame is worth when there is no window to present one: 60Hz, the rate
// the vsynced loop above runs at on the displays this is developed on.
const long HEADLESS_FRAME_MS = 16;

<*
 Answers JSON-RPC on stdin and stdout by forwarding it to a `three --mcp` that is
 already running. This is `three --mcp-stdio`, and it is what `.mcp.json` names.

 What it buys over pointing a client at the port is lifetime. A client asks who a
 server is the moment it launches, and is entitled to write that server off for
 the whole of its run if the question fails — so a bare URL means three has to be
 up before the client and stay up for as long as it. A relay is up whether or not
 three is, and a call that cannot reach one comes back as an error naming the
 port rather than as a server that never started.

 It is not a second server. It binds nothing, opens no window, creates no device
 and holds no scene: `mcp::relay` makes one connection per message and closes it.
 Several may run at once beside a windowed three without any of them knowing
 about the others.

 The catalog answers the four questions a client asks before it has done anything
 — `initialize`, `ping`, `tools/list`, `resources/list` — out of the registration
 table, so those answers are the same whether or not three is up. It is
 registered over a zeroed `ToolHost` on this stack and nothing ever dereferences
 it: `Server.answers_offline` lets only those four through, and all three
 handlers begin by refusing a null runtime or renderer in any case.

 @return `0 when stdin ends, which is how the client says it is finished.`
*>
fn int serve_relay(int port)
{
	ToolHost catalog_host = { };
	mcp::Server catalog   = new_mcp_server(&catalog_host);
	mcp::relay("127.0.0.1", port, &catalog);
	return 0;
}

<*
 Pokes the window's event loop awake. Called on the listener's thread.

 The one thing a foreign thread may do to a Cocoa run loop: `Window.wake` posts
 an application-defined event, which `getEvent` falls through its switch and
 hands to `NSApp`, which ignores it. So a wake costs exactly one extra iteration
 and changes nothing else.

 Null for a headless server, where the parameter is the window itself and there
 is nothing to wake — the loop there paces itself with a sleep instead.
*>
fn void wake_window(void* ctx)
{
	c3w::Window* window = (c3w::Window*)ctx;
	if (window == null) return;
	window.wake();
}