<*
 The keyboard, as a script sees it: two ways to ask, and one way to be told.

 ```js
 three.input.isDown('w')          // level — polled inside the frame callback
 three.input.pressed('space')     // edge — went down during this frame
 three.onKeyDown('e', () => {})   // edge — the host calls you
 three.onClick(hit => {})         // the mouse, which only has the second kind
 ```

 ## Why both

 They answer different questions and neither substitutes for the other. Holding W
 to walk is a level question asked once per frame; jumping is an edge that
 happens once and must not be missed or repeated. A script could build the second
 out of the first — poll `pressed` in the animation callback — and a script that
 binds ten keys would then be writing a dispatcher. It exists here once instead
 of once per script.

 The callbacks ride the frame: dispatched from `JsRuntime.tick`, before the
 animation callback, under the same budget, into the same frame log, and with the
 same policy when one misbehaves. There is no second mechanism, which is the
 point — see `js/frame_loop.c3`.

 ## This is not a Three.js API

 Three.js has no input layer at all. `OrbitControls` lives in `examples/jsm` and
 takes a DOM element; key handling is the browser's `addEventListener`. So the
 names here are the browser's where the browser has one —
 `KeyboardEvent.key`, lowercased, in `scene/input.c3`'s table — and the shape is
 an invention, listed as one in `prelude.js`'s `differences`.

 ## The mouse is only ever told

 `three.input.pointer` is where the cursor is, how far it moved this frame, which
 of the three buttons are down and what the wheel did — level state a script
 wants in the animation callback, all read once per frame from one reading of one
 instant.

 The edge API is still one click and only one. A press edge is a thing a stuck
 latch cannot fabricate, and a script polling `down` may be told the button is
 held forever; that is why the click — which needs an edge — is the whole of what
 is *dispatched*, and comes with what is under it already raycast.

 `dx`/`dy` stop at the edge of the screen, not at the edge of the window. The
 window goes on reporting a position after the cursor has left it, so a look
 keeps turning across the desktop; where it genuinely ends is where the platform
 stops the cursor, and getting past that is pointer lock.

 ## And the mouse can be taken away from the camera

 `three.controls.enabled = false` stops the turntable reading the window at all
 — the one thing in this file that writes *out* rather than reporting in. It
 lives here rather than beside the camera verbs because what it turns off is a
 hand on a window, and the camera is only where the hand was going.

 ## And the window it all arrives through

 `three.window` is the last thing in here that is not input at all: the drawable's
 size, the display scale, and a way to ask for a different size. It lives beside
 the pointer lock because the runtime holds exactly one `c3w::Window` and this is
 the file that reaches for it — see `js_window_size`.

 ## One handler per key per edge

 Registering `'space'` twice replaces the first, exactly as `setAnimationLoop`
 does. A list would be a lifetime problem — nothing hands back a token to
 unregister with — and a script that genuinely wants two things on one key has a
 JavaScript array and a function that calls both.
*>
module three;

import std::io;
import std::math;
import c3w;
import qjs;

// Enough for a control scheme, small enough that running out means a script is
// registering in a loop — a bug worth a message rather than an allocation.
const usz MAX_KEY_HANDLERS = 32;

struct KeyHandler
{
	// The row from `KEY_NAMES`, whose `name` points into static storage and so
	// outlives everything here.
	KeyName row;
	// False for the release edge. The pair (row.name, on_press) is the identity a
	// registration replaces.
	bool on_press;
	// Named `body` because `fn` is a keyword.
	qjs::Value body;
}

fn void JsRuntime.bind_input_verbs(&self, qjs::Value host)
{
	self.bind(host, "inputDown", &js_input_down, 1);
	self.bind(host, "inputPressed", &js_input_pressed, 1);
	self.bind(host, "inputReleased", &js_input_released, 1);
	self.bind(host, "inputText", &js_input_text, 0);
	self.bind(host, "inputHold", &js_input_hold, 2);
	self.bind(host, "inputMove", &js_input_move, 2);
	self.bind(host, "inputButtonHold", &js_input_button_hold, 2);
	self.bind(host, "inputScroll", &js_input_scroll, 2);
	self.bind(host, "inputReleaseAll", &js_input_release_all, 0);
	self.bind(host, "keyNames", &js_key_names, 0);
	self.bind(host, "onKey", &js_on_key, 3);
	self.bind(host, "pointer", &js_pointer, 0);
	self.bind(host, "pointerLockGet", &js_pointer_lock_get, 0);
	self.bind(host, "pointerLockSet", &js_pointer_lock_set, 1);
	self.bind(host, "onClick", &js_on_click, 1);
	self.bind(host, "controlsGet", &js_controls_get, 0);
	self.bind(host, "controlsSet", &js_controls_set, 1);
	self.bind(host, "windowSize", &js_window_size, 0);
	self.bind(host, "windowResize", &js_window_resize, 2);
	self.bind(host, "windowTitleGet", &js_window_title_get, 0);
	self.bind(host, "windowTitleSet", &js_window_title_set, 1);
	self.bind(host, "windowFullscreenGet", &js_window_fullscreen_get, 0);
	self.bind(host, "windowFullscreenSet", &js_window_fullscreen_set, 1);
}

<*
 Takes the frame's keyboard, and keeps the typed text rather than borrowing it.

 `InputState.text` points into the window's own buffer, which the next `getEvent`
 clears — so a script reading `three.input.text` between frames would be reading
 whatever the window has accumulated since. Copying is a few bytes a frame and
 makes the value mean one thing.
*>
fn void JsRuntime.take_input(&self, InputState input)
{
	self.input = input;
	self.input_text.clear();
	self.input_text.append_string(input.text);
	self.input.text = self.input_text.str_view();
}

<*
 `inputHold(key, down)` — press or release a key from a script.

 A headless boot has no keyboard, so a scene whose whole subject is input could
 not otherwise be exercised at all; the alternative is a scene leaking its own
 state through a global in order to be testable.

 The key stays down until it is released, exactly as a finger does, and the edges
 fall out of the same difference a real key's do. So `three.input.pressed`,
 `isDown`, `released` and every `onKeyDown` handler behave identically — there is
 one keyboard, not a second path through the input system. `SyntheticKeys` argues
 the whole design.

 It adds to the window rather than replacing it, so a scripted demo works with a
 person still at the keyboard.
*>
fn void js_input_hold(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	KeyName? row = named_key(self, &js, argc, args, 0, out);
	if (catch err = row) return;

	self.synthetic.hold(row, arg_truth(&js, argc, args, 1));
}

<*
 `inputMove(x, y)` — put the pointer somewhere, in the rendered image's pixels.

 `inputHold`'s argument, for the mouse, and the half of it that is worth stating
 separately: a headless boot has no pointer either, so an interface — the thing a
 pointer is mostly for — could not be exercised at all. A panel's buttons, its
 menus and its drags were reachable only by a person with a window open, which is
 to say not reachable from a test.

 The coordinates are the ones `three.input.pointer` answers in, `scene.pick`
 takes and the PNG starts at, so a place read off a screenshot can be pressed
 without conversion.

 It goes in above cui's hit test rather than beside it — `SyntheticPointer.merge`
 is called once per frame per host, before anything reads the pointer — so
 `three.input.pointer`, `onClick`, a widget's `onClick` and a `draw` node's
 `onPointer` cannot tell this from a hand. That is the whole claim, and it is
 what makes a press under an open menu correctly reach nothing.

 It stands in for the window's position rather than adding to it, because two
 positions are not a third; the buttons and the wheel below do add. A hand on the
 real mouse takes the cursor straight back — `SyntheticPointer` says how.
*>
fn void js_input_move(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	float x = arg_float(&js, argc, args, 0);
	float y = arg_float(&js, argc, args, 1);
	// A NaN would place the pointer nowhere at all: every comparison against it is
	// false, so it is never inside, never over a widget and never the same place
	// twice — a pointer that silently does nothing, which is the failure
	// `named_key` refuses a typo for.
	if (!math::is_finite(x) || !math::is_finite(y))
	{
		*out = js.raise("three.input.movePointer(x, y) wants two numbers in image pixels");
		return;
	}

	self.pointer.place(x, y);
}

<*
 `inputButtonHold(button, down)` — press or release a mouse button from a script.

 A held button, not a click, for the reason `inputHold` holds a key: a drag is
 `movePointer(a)`, `pressButton(0)`, `movePointer(b)`, `releaseButton(0)`, and
 every frame in between sees a button that is down. A `click(x, y)` verb would
 have to invent those frames, and inventing them is exactly how a synthesised
 gesture stops being indistinguishable from a real one.

 The edges fall out of the same `MouseTracker` a real button's do, so `clicked`,
 `three.onClick` and cui's press-and-release are reached identically.

 A number nobody has is refused by name rather than taken as the left button, for
 `named_key`'s reason: a control that silently does nothing looks like every
 other reason a control might do nothing.
*>
fn void js_input_button_hold(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	int button = arg_int(&js, argc, args, 0);
	if (button < 0 || button > 2)
	{
		@pool()
		{
			*out = js.raise(
				string::tformat(
					"three.input.pressButton(button) takes 0 (left), 1 (right) or 2 (middle); got %d",
					button
				)
			);
		};
		return;
	}

	self.pointer.hold((uint)button, arg_truth(&js, argc, args, 1));
}

<*
 `inputScroll(dy, dx)` — turn the wheel.

 One frame's worth, added to whatever the window turned, and spent by the frame
 that reads it. Not a latch: `Cursor.scroll` is a total accumulated over one
 frame's events and gone at the end of it, and a scripted wheel that stayed would
 be a scroll that never stopped.

 `dy` is positive *away* from the user, which is `c3w`'s convention and the
 camera zoom's, and the opposite of the browser's `deltaY` — see `Cursor.scroll`.
*>
fn void js_input_scroll(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	float dy = arg_float(&js, argc, args, 0);
	float dx = arg_float(&js, argc, args, 1);
	if (!math::is_finite(dy) || !math::is_finite(dx))
	{
		*out = js.raise("three.input.scroll(dy, dx) wants numbers of wheel notches");
		return;
	}

	self.pointer.turn(dy, dx);
}

<*
 `inputReleaseAll()` — let go of everything a script is holding.

 What a test calls between cases so one does not leak a held key into the next,
 and what a scripted sequence calls when it hands control back to a person. The
 releases are still reported as edges on the next frame, because that is what
 happened.

 The mouse buttons go with the keys, and they are the half that matters more: a
 held button *captures*, so one leaked into the next case does not merely read as
 held — the next case's first press lands inside a drag somebody else started,
 and the widget it was aimed at never hears about it. The unspent wheel goes too.

 The pointer is not moved. A pointer is always somewhere, and letting go of a
 button leaves the cursor where it was let go of; a case that wants it elsewhere
 says so with `movePointer`.
*>
fn void js_input_release_all(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	self.synthetic.release_all();
	self.pointer.release_all();
}

<*
 One frame of pointer, on a host that has no window.

 ## Why there is a second place at all

 There is one merge and two callers, and they are the two hosts rather than two
 paths. A window's pointer is folded in by `drive_window`, which is where a
 window's pointer is built and — crucially — where cui hit-tests it, above the
 camera and above everything a script is told. A host with no window has no
 `drive_window`; the tick is the whole of its frame, so the same three steps
 happen here in the same order. What must never exist is a *second arbitration*,
 which is why the hit test and `Cursor.behind_ui` are shared rather than
 restated.

 ## The interface first

 cui sees the pointer before anything else does, so a press under an open menu or
 a modal reaches the panel beneath it exactly as often here as it does with a
 window open, which is never. `Cursor.behind_ui` is then what the script is told:
 the position, and none of the buttons that a widget has already answered for.

 The keys go with it. They are the frame's, `SyntheticKeys.merge` having already
 folded in whatever a script is holding, so a scripted `press('a')` reaches a
 focused text field on a host that has no keyboard either.

 A no-op until a script has used the pointer at all — a headless run that never
 touches it feeds cui nothing, which is what it did before this existed.

 @param frame : `This frame's input, keys already merged. Its mouse is what this replaces.`
 @param now_ms : `The host's clock, for telling a click from a hold.`
 @param dt_ms : `What this frame is worth to the interface's own animations.`
*>
fn InputState JsRuntime.scripted_pointer_frame(&self, InputState frame, double now_ms, float dt_ms)
{
	if (!self.pointer.active) return frame;

	uint image_wide = self.renderer != null ? self.renderer.target.extent.width : 0;
	uint image_high = self.renderer != null ? self.renderer.target.extent.height : 0;

	Cursor cursor = self.pointer.merge({ }, image_wide, image_high);

	bool taken = false;
	if (self.renderer != null)
	{
		self.renderer.ui.feed(cursor, frame.down, frame.text, dt_ms);
		taken = self.renderer.ui.wants_pointer;
		// A handler that asked for a new tree was held while cui was walking the
		// old one, and this is the first moment it is not — the same call
		// `main.c3`'s loop makes the instant `drive_window` returns.
		self.flush_ui();
	}

	frame.mouse = self.scripted_mouse.step(cursor.behind_ui(taken), now_ms);
	return frame;
}

<*
 Calls every handler whose edge happened this frame.

 Walked by index rather than by iterator because a handler that fails is removed
 from under the walk — the ordinary path, not the exceptional one, since a
 handler is stopped the first time it misbehaves.
*>
fn void JsRuntime.dispatch_keys(&self)
{
	usz at = 0;
	while (at < self.key_handler_count)
	{
		KeyHandler handler = self.key_handlers[at];
		bool fired         = handler.on_press ? self.input.went_down(handler.row) : self.input.went_up(handler.row);

		if (!fired)
		{
			at++;
			continue;
		}

		if (self.call_key_handler(handler))
		{
			at++;
		}
		else
		{
			// Removed, so the slot now holds the next handler and the index stays
			// where it is.
			self.drop_key_handler(at);
		}

		// The budget belongs to the whole frame. Once it is gone every later call
		// would be interrupted on its first instruction and stopped for a failure
		// that is not its own.
		if (self.timed_out) break;
	}
}

<*
 One handler, called with the name it was registered under.

 The name rather than an event object: one function bound to `'w'`, `'a'`, `'s'`
 and `'d'` is the ordinary shape and needs to know which arrived. There is no
 event here to hand it — the host has a latch, not a queue.

 @return `false when the handler failed and has been stopped.`
*>
fn bool JsRuntime.call_key_handler(&self, KeyHandler handler)
{
	bool kept = true;

	@pool()
	{
		qjs::Value[1] args = { self.js.string(handler.row.name) };
		defer self.js.release(args[0]);

		qjs::Value? answer = self.js.call(handler.body, qjs::undefined_value(), args[..]);
		if (catch err = answer)
		{
			self.report_frame_failure(
				self.timed_out ? self.frame_timeout_message()
					: string::tformat(
						"the '%s' key handler threw and was stopped: %s",
						handler.row.name,
						self.js.exception(tmem)
					)
			);
			kept = false;
		}
		else
		{
			bool promised = self.is_thenable(answer);
			self.js.release(answer);
			if (promised)
			{
				self.report_frame_failure(
					string::tformat(
						"the '%s' key handler returned a promise. It has to finish inside the frame, "
							"so it must be synchronous — do the awaiting in a run_script instead",
						handler.row.name
					)
				);
				kept = false;
			}
		}
	};

	return kept;
}

<*
 Releases a handler's function and closes the gap.

 Kept dense rather than tombstoned so that registering a key, losing it to a
 throw, and registering it again cannot exhaust the table.
*>
fn void JsRuntime.drop_key_handler(&self, usz at)
{
	if (at >= self.key_handler_count) return;
	self.js.release(self.key_handlers[at].body);
	for (usz i = at + 1; i < self.key_handler_count; i++)
	{
		self.key_handlers[i - 1] = self.key_handlers[i];
	}
	self.key_handler_count--;
	self.key_handlers[self.key_handler_count] = { };
}

<*
 Forgets every key handler. Called by `JsRuntime.close`, and so bound by the same
 rule as `clear_frame`: before the context goes, never after.
*>
fn void JsRuntime.clear_key_handlers(&self)
{
	while (self.key_handler_count > 0) self.drop_key_handler(0);
}

// ============================================================================
// The click
// ============================================================================

<*
 Calls the click handler, if this frame ended a click and there is one.

 The raycast happens here rather than in the script, which is the whole of what
 "click to pick" buys over `three.input.pointer` plus `scene.pick`. It costs a
 BVH walk per gesture — once per click, not once per frame.
*>
fn void JsRuntime.dispatch_click(&self)
{
	if (!self.click_active || !self.input.mouse.clicked) return;

	bool kept = true;

	@pool()
	{
		float x = self.input.mouse.x;
		float y = self.input.mouse.y;

		// `pick_at` answers null with no device, which is what a miss answers too —
		// so a handler written against a window still runs headless, and what it is
		// told is the truth rather than an error nobody caused.
		qjs::Value[3] args = {
			self.pick_at(&self.js, x, y),
			qjs::number_value((double)x),
			qjs::number_value((double)y),
		};
		defer self.js.release(args[0]);

		qjs::Value? answer = self.js.call(self.click_fn, qjs::undefined_value(), args[..]);
		if (catch err = answer)
		{
			self.report_frame_failure(
				self.timed_out ? self.frame_timeout_message()
					: string::tformat("the click handler threw and was stopped: %s", self.js.exception(tmem))
			);
			kept = false;
		}
		else
		{
			bool promised = self.is_thenable(answer);
			self.js.release(answer);
			if (promised)
			{
				self.report_frame_failure(
					"the click handler returned a promise. It has to finish inside the frame, "
						"so it must be synchronous — do the awaiting in a run_script instead"
				);
				kept = false;
			}
		}
	};

	if (!kept) self.clear_click_handler();
}

<*
 Forgets the click handler. Same rule as `clear_key_handlers`, same reason.
*>
fn void JsRuntime.clear_click_handler(&self)
{
	if (!self.click_active) return;
	self.click_active = false;
	self.js.release(self.click_fn);
	self.click_fn = qjs::undefined_value();
}

// ============================================================================
// The bindings
// ============================================================================

<*
 Resolves a name argument, raising a JS error when there is no such key.

 A typo must not be a key that is simply never down: nothing is broken, nothing
 is logged, and the only symptom is a control that does nothing — which is
 indistinguishable from every other reason a control might do nothing. The
 message names `three.input.keys()` because the answer is always in that list.
*>
fn KeyName? named_key(JsRuntime* self, qjs::Context* js, int argc, qjs::Value* args, int at, qjs::Value* out)
{
	KeyName? row;
	@pool()
	{
		String name = arg_text(js, argc, args, at, tmem);
		row = find_key(name);
		if (catch err = row)
		{
			*out = js.raise(
				string::tformat("there is no key called '%s' — three.input.keys() lists every name there is", name)
			);
		}
	};
	return row;
}

fn void js_input_down(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);
	KeyName? row    = named_key(self, &js, argc, args, 0, out);
	if (catch err = row) return;
	*out = qjs::bool_value(self.input.is_down(row));
}

fn void js_input_pressed(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);
	KeyName? row    = named_key(self, &js, argc, args, 0, out);
	if (catch err = row) return;
	*out = qjs::bool_value(self.input.went_down(row));
}

fn void js_input_released(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);
	KeyName? row    = named_key(self, &js, argc, args, 0, out);
	if (catch err = row) return;
	*out = qjs::bool_value(self.input.went_up(row));
}

fn void js_input_text(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);
	*out = js.string(self.input.text);
}

<*
 Every name, in table order, as an array of strings.

 Answered from the table rather than written out beside it, which is the whole
 reason it exists: `get_api_docs` calls this, so the list an agent reads and the
 list `find_key` searches cannot drift.
*>
fn void js_key_names(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	qjs::Context js = qjs::wrap(ctx);

	qjs::Value names = js.array();
	uint at          = 0;
	foreach (KeyName row : KEY_NAMES)
	{
		js.set_index(names, at++, js.string(row.name));
	}
	*out = names;
}

<*
 `__three.onKey(name, onPress, fn)` — register, replace, or with null remove.

 The type checking a caller sees is in `prelude.js` beside the name they typed.
 What is left is the pair of checks that cannot be spelled there: that the key
 exists, and that the table has room.
*>
fn void js_on_key(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	bool on_press = arg_truth(&js, argc, args, 1);
	bool clearing = argc < 3 || args[2].is_undefined() || args[2].is_null();

	if (!clearing && !js.is_function(args[2]))
	{
		*out = js.raise("three.onKeyDown(key, fn) wants a function, or null to unbind");
		return;
	}

	KeyName? row = named_key(self, &js, argc, args, 0, out);
	if (catch err = row) return;

	// Whatever was on this key and edge is gone, whether it is being replaced or
	// removed — an old handler left behind by a rejected registration would keep
	// firing under a name the script believes it has rebound.
	for (usz i = 0; i < self.key_handler_count; i++)
	{
		if (self.key_handlers[i].on_press != on_press) continue;
		if (self.key_handlers[i].row.name != row.name) continue;
		self.drop_key_handler(i);
		break;
	}

	if (clearing) return;

	if (self.key_handler_count >= MAX_KEY_HANDLERS)
	{
		@pool()
		{
			*out = js.raise(
				string::tformat(
					"there is room for %d key handlers and they are all taken — "
						"unbind one with three.onKeyDown(key, null)",
					MAX_KEY_HANDLERS
				)
			);
		};
		return;
	}

	self.key_handlers[self.key_handler_count] = {
		.row = row,
		.on_press = on_press,
		.body = js.retain(args[2]),
	};
	self.key_handler_count++;
}

<*
 `__three.pointer()` — where the cursor is and what it is doing.

 One object rather than five verbs, because the five are read together and
 correlated: `clicked` without the pixel it happened at is not usable, and a
 pixel from a different sample than the flag is a bug that only shows up when the
 mouse is moving.
*>
fn void js_pointer(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	MouseState mouse = self.input.mouse;

	qjs::Value object = js.object();
	js.set_property(object, "x", qjs::number_value((double)mouse.x));
	js.set_property(object, "y", qjs::number_value((double)mouse.y));
	js.set_property(object, "dx", qjs::number_value((double)mouse.dx));
	js.set_property(object, "dy", qjs::number_value((double)mouse.dy));
	js.set_property(object, "inside", qjs::bool_value(mouse.inside));
	js.set_property(object, "down", qjs::bool_value(mouse.down));
	js.set_property(object, "right", qjs::bool_value(mouse.right));
	js.set_property(object, "middle", qjs::bool_value(mouse.middle));
	js.set_property(object, "clicked", qjs::bool_value(mouse.clicked));
	// Whether `dx`/`dy` came from the platform rather than from a difference of
	// positions — the same thing as "this look will not stop at the edge of the
	// screen". Beside the deltas rather than only on `three.input.pointerLock`,
	// because it is a fact about *these numbers*, and a script correlating them
	// with a flag read at another moment is the bug this object exists to prevent.
	js.set_property(object, "locked", qjs::bool_value(mouse.locked));
	js.set_property(object, "scroll", qjs::number_value((double)mouse.scroll));
	js.set_property(object, "scrollX", qjs::number_value((double)mouse.scroll_x));
	*out = object;
}

<*
 `controlsGet()` — whether the mouse still reaches the camera.

 A real boolean rather than the number-in-an-array shape `shadowGet` and
 `lightGet` use: those pack four fields so assigning one is a single crossing,
 and there is only one field here to pack.
*>
fn void js_controls_get(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	*out = qjs::bool_value(self.controls.enabled);
}

<*
 `controlsSet(enabled)` — hand the mouse to the script, or give it back.

 The flag is on the runtime and not on the window's loop, so a headless `--mcp`
 script sets it and reads it back unchanged. A property that quietly reports
 something other than what was written to it is the failure `api.js` throws on
 assignment three separate times to avoid, and "there is no window today" is not
 a reason to reintroduce it. What it *does* with no window is nothing, because
 there was no hand on it either.

 Nothing is stopped mid-gesture: a drag in progress when this is turned off does
 not finish, `Controls.apply` drops the anchor and the coast on the first
 disabled frame, and turning the controls back on begins from wherever the camera
 was left, waiting for a fresh press.
*>
fn void js_controls_set(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);
	self.controls.enabled = arg_truth(&js, argc, args, 0);
}

<*
 `__three.onClick(fn)` — register, replace, or with null remove.

 One handler, not a table. A click has no name to key a table by — every click is
 the same event at a different pixel — so the choice a key binding has, of which
 of thirty-two rows to replace, does not exist here. It is `setAnimationLoop`'s
 shape rather than `onKey`'s.
*>
fn void js_on_click(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	bool clearing = argc < 1 || args[0].is_undefined() || args[0].is_null();

	if (!clearing && !js.is_function(args[0]))
	{
		*out = js.raise("three.onClick(fn) wants a function, or null to unbind");
		return;
	}

	// Released before the new one is retained, so replacing cannot leak and cannot
	// leave the old handler firing under a script that believes it has been
	// replaced.
	self.clear_click_handler();
	if (clearing) return;

	self.click_fn = js.retain(args[0]);
	self.click_active = true;
}

<*
 `pointerLockGet()` — whether the pointer is locked *right now*.

 Not what a script asked for: what the platform actually did. `--headless` has no
 window and answers false, and so does a backend that has no implementation. A
 script that needs a look either way reads this back after setting it and falls
 back to a drag-look when it comes back false.
*>
fn void js_pointer_lock_get(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	*out = qjs::bool_value(self.window != null && self.window.pointerLocked());
}

<*
 `pointerLockSet(on)` — ask for the pointer, and answer with whether it was
 given.

 Answering with the result rather than with nothing is the whole of the error
 handling here. There is no exception to raise: a headless run and a Wayland
 session are not mistakes a script made, and throwing would make a perfectly
 reasonable game refuse to start on a platform where the look merely has to be
 worse.
*>
fn void js_pointer_lock_set(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	if (self.window == null)
	{
		*out = qjs::bool_value(false);
		return;
	}

	self.window.setPointerLock(arg_truth(&js, argc, args, 0));
	*out = qjs::bool_value(self.window.pointerLocked());
}

// ============================================================================
// The window itself
// ============================================================================

// Past this a window manager is being asked for something no display has, and
// the `int` the backends take would be the only thing objecting.
const int WINDOW_MAX_SIDE = 16384;

<*
 `windowSize()` — the drawable and the display density, as
 `[width, height, scale]`.

 ## Device pixels, and read off the surface

 `width` and `height` are the swapchain's extent: physical pixels, and current
 through a live resize drag. `Window.width` is only ever what `new` was asked
 for and is stale on Linux besides, so asking the window would answer a
 different question badly. `WindowView` reads the same number for the same
 reason.

 That makes these the same unit `renderSize()` answers in, which is the
 comparison anybody asking has in mind: the window is where the picture is
 shown and `renderSize()` is how many pixels the picture has.

 `scale` is device pixels per logical point — 1.0 on an ordinary display, 2.0 on
 a retina one. It is here because `--width`/`--height` at boot mean logical
 points to the window and device pixels to the target, so the two agree at
 startup only where the scale is 1.

 Zeros with no window, which is `--headless` and every test in this repo. Zero
 is an answer a script can branch on and there is nothing here worth throwing
 over — `pointerLockGet` reports the same kind of absence the same way.

 ## It does not move on Wayland

 Measured, on the two Linux backends. Under X11 a `windowResize` lands and this
 reads the new size back a frame or two later. Under Wayland it stays whatever
 the process booted at, and the reason is one branch in `Viewer.surface_extent`:
 Wayland answers `currentExtent` with `0xFFFFFFFF`, meaning "whatever the
 swapchain asks for", so the swapchain goes on asking for the size it was
 created at and never rebuilds. That is the surface contract rather than anything
 this verb does — the compositor scales the buffer into whatever the toplevel
 became — and it is the same reason a live resize drag does not sharpen the
 picture there either.
*>
fn void js_window_size(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	uint width  = 0;
	uint height = 0;
	float scale = 0;
	if (self.window != null && self.renderer != null && self.renderer.windowed)
	{
		width = self.renderer.viewer.extent.width;
		height = self.renderer.viewer.extent.height;
		scale = self.window.get_scale();
	}

	qjs::Value triple = js.array();
	js.set_index(triple, 0, qjs::int_value((int)width));
	js.set_index(triple, 1, qjs::int_value((int)height));
	js.set_index(triple, 2, qjs::number_value((double)scale));
	*out = triple;
}

<*
 `windowResize(width, height)` — ask the window to be that many device pixels,
 and answer with whether there was a window to ask.

 ## A request, not a setting

 Nothing is recorded here and `windowSize()` does not change on the way out. X11
 configures the window and the manager may adjust the request; Wayland cannot ask
 at all — it constrains its own geometry and the compositor answers with a
 configure some time later. The size that arrives back is the one that counts, so
 a script that cares reads `windowSize()` on a later frame rather than on the
 next line.

 ## Device pixels in, logical units out

 The arguments match what `windowSize()` reports, so asking for a size and
 reading it back agrees. `Window.set_size` takes the window's own logical units
 on every backend, so the scale is divided out here — one place rather than in
 each of the three callers a prelude property would become.

 False with no window rather than a raise, for `pointerLockSet`'s reason: a
 headless run is not a mistake a script made, and a game that resizes its window
 on a machine that has one should still start on a machine that does not.
*>
fn void js_window_resize(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	int width  = arg_int(&js, argc, args, 0);
	int height = arg_int(&js, argc, args, 1);
	if (width < 1 || height < 1 || width > WINDOW_MAX_SIDE || height > WINDOW_MAX_SIDE)
	{
		*out = js.raise(
			string::tformat(
				"three.window.resize(width, height) wants two sizes between 1 and %d device pixels; got %dx%d",
				WINDOW_MAX_SIDE,
				width,
				height
			)
		);
		return;
	}

	if (self.window == null)
	{
		*out = qjs::bool_value(false);
		return;
	}

	float scale = self.window.get_scale();
	if (scale <= 0.0f) scale = 1.0f;
	int points_wide = (int)((float)width / scale);
	int points_high = (int)((float)height / scale);
	self.window.set_size(points_wide < 1 ? 1 : points_wide, points_high < 1 ? 1 : points_high);

	say_window_stretch(self.renderer, (uint)width, (uint)height);
	*out = qjs::bool_value(true);
}

<*
 Says that a bigger window will be a stretched picture, when it is about to be.

 Only reachable with the render size PINNED. The target follows the window
 otherwise, so a bigger window is a bigger picture and there is nothing to warn
 about; once `three.setRenderSize` has pinned it, "make the window bigger" no
 longer renders more pixels and the difference is invisible from a script — a
 screenshot comes back at the size it was pinned to.

 Only on the way up, because a window smaller than the target is the same
 stretch in the direction nobody complains about.
*>
fn void say_window_stretch(Renderer* renderer, uint width, uint height) @local
{
	if (renderer == null || !renderer.render_size_pinned) return;
	uint image_wide = renderer.target.extent.width;
	uint image_high = renderer.target.extent.height;
	if (width <= image_wide && height <= image_high) return;

	@advise(
		"three: the window was asked for %dx%d and the picture in it is %dx%d stretched to fit. The "
			"render size is pinned by three.setRenderSize, so the window no longer moves it — pass null "
			"to three.setRenderSize to let the picture follow the window again.",
		width,
		height,
		image_wide,
		image_high
	);
}

<*
 The window's title, kept here because the window outlives every context that
 names it.

 `c3w` has no `get_title` and two of its four backends could not implement one —
 Wayland never reads a title back, and Windows would answer with whatever a
 screen reader last saw. So the value is remembered on the way past, at process
 scope rather than on `JsRuntime`: a `three.reload()` closes the context and
 builds a new one while the window stays up with the name it already has, and a
 title that read back empty after a reload would be reporting the context's
 memory rather than the window's state.

 A fixed buffer for `disk_cache.c3`'s reason: process-global state with no owner,
 where a heap copy nothing frees is a leak in a leak-tracked run.
*>
const usz WINDOW_TITLE_MAX = 256;

char[WINDOW_TITLE_MAX] window_title_storage @local;
String window_title @local = WINDOW_DEFAULT_TITLE;

<*
 `windowTitleGet()` — what the title bar says.

 Answers with the name even under `--headless`, where there is no title bar to
 put it on. A game reading back what it configured should get what it
 configured; whether anything is displaying it is `three.window.width`'s
 question, not this one.
*>
fn void js_window_title_get(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	qjs::Context js = qjs::wrap(ctx);
	*out = js.string(window_title);
}

<*
 `windowTitleSet(text)` — rename the window, and answer with whether there was
 one to rename.

 The name is remembered either way, so a `--headless` run that titles itself and
 a windowed one that does read back the same. False means only "nothing is
 showing this", which is the same shape `three.window.resize` and
 `three.input.pointerLock` already use.
*>
fn void js_window_title_set(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	@pool()
	{
		String wanted = arg_text(&js, argc, args, 0, tmem);
		if (wanted.len == 0)
		{
			*out = js.raise("three.window.title wants a name; the empty string would leave the title bar blank");
			return;
		}
		if (wanted.len > WINDOW_TITLE_MAX)
		{
			*out = js.raise(
				string::tformat(
					"three.window.title takes at most %d bytes and was given %d",
					WINDOW_TITLE_MAX,
					wanted.len
				)
			);
			return;
		}

		mem::copy(&window_title_storage[0], wanted.ptr, (sz)wanted.len);
		window_title = (String)window_title_storage[:wanted.len];

		if (self.window == null)
		{
			*out = qjs::bool_value(false);
			return;
		}
		self.window.set_title(window_title);
		*out = qjs::bool_value(true);
	};
}

<*
 `windowFullscreenGet()` — whether the window is filling a display.

 False under `--headless`, where it is the only true answer.

 What each platform means by it differs and is worth knowing. macOS reads the
 style mask, so a person using the green button or Mission Control is reflected
 here without this process being told. The other three report what was last
 asked for: Windows because there is no OS state that says "fullscreen" — the
 window is merely borderless and the size of a monitor — and X11 and Wayland
 because the true answer belongs to a window manager that is free to refuse.
*>
fn void js_window_fullscreen_get(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	*out = qjs::bool_value(self.window != null && self.window.fullscreen());
}

<*
 `windowFullscreenSet(on)` — go fullscreen, or come back.

 Answers with whether there was a window to ask, not with whether it worked: on
 three of four platforms the answer arrives later, as a resize, and on X11 it may
 never arrive at all because a window manager is entitled to say no. A settings
 screen that wants the truth reads `three.window.fullscreen` back on a later
 frame, exactly as it would after `resize`.

 The render size does not move. Everything draws into the offscreen target
 `--width`/`--height` fixed at boot and the swapchain stretches it over whatever
 the window becomes, so going fullscreen makes the picture bigger and not
 sharper. `three.setRenderSize` is the other half of that, and a settings screen
 offering a resolution wants both.
*>
fn void js_window_fullscreen_set(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	bool wanted = arg_truth(&js, argc, args, 0);
	if (self.window == null)
	{
		*out = qjs::bool_value(false);
		return;
	}
	self.window.set_fullscreen(wanted);
	*out = qjs::bool_value(true);
}
