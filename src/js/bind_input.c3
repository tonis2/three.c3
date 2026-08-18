<*
 The keyboard, as a script sees it: two ways to ask, and one way to be told.

 ```js
 three.input.isDown('w')          // level — polled inside the frame callback
 three.input.pressed('space')     // edge — went down during this frame
 three.onKeyDown('e', () => {})   // edge — the host calls you
 three.onClick(hit => {})         // the mouse, which only has the second kind
 ```

 ## Why both

 They answer different questions and neither substitutes for the other. Holding
 W to walk is a level question asked once per frame; jumping is an edge that
 happens once and must not be missed or repeated. A script could build the
 second out of the first — poll `pressed` in the animation callback — and a
 script that binds ten keys would then be writing a dispatcher. It exists here
 once instead of once per script.

 **The callbacks ride the frame.** They are dispatched from `JsRuntime.tick`,
 before the animation callback, under the same budget, into the same frame log,
 and with the same policy when one misbehaves: it is stopped, once, and the
 reason is kept for the next run. There is no second mechanism, which is the
 point — see `js/frame_loop.c3`, which owns all of that.

 ## This is not a Three.js API

 Three.js has no input layer at all. `OrbitControls` lives in `examples/jsm` and
 takes a DOM element; key handling is the browser's `addEventListener`. So the
 names here are chosen to be the browser's where the browser has one —
 `KeyboardEvent.key`, lowercased, in `scene/input.c3`'s table — and the shape is
 an invention, listed as one in `prelude.js`'s `differences`.

 ## The mouse is only ever told

 `three.input.pointer` is where the cursor is, and that is level state a script
 may want in the animation callback. There is no `mouseDown` beside it, and the
 omission is the same argument `scene/input.c3` makes about the key table: the
 latch that carries the button sticks, and a script polling it would be told the
 button is held forever. A click is an edge, and an edge a stuck latch cannot
 fabricate — so the click is the whole of the mouse's edge API, and it comes
 with what is under it already raycast.

 ## One handler per key per edge

 Registering `'space'` twice replaces the first, exactly as `setAnimationLoop`
 does. A list would be a lifetime problem — nothing hands back a token to
 unregister with — and a script that genuinely wants two things on one key has a
 JavaScript array and a function that calls both.
*>
module three;

import std::io;
import c3w;
import qjs;

// Enough for a control scheme, small enough that running out means a script is
// registering in a loop — which is a bug worth a message rather than an
// allocation.
const usz MAX_KEY_HANDLERS = 32;

struct KeyHandler
{
	// The row from `KEY_NAMES`, whose `name` points into static storage and so
	// outlives everything here.
	KeyName row;
	// False for the release edge. The pair (row.name, on_press) is the identity
	// a registration replaces.
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
	self.bind(host, "keyNames", &js_key_names, 0);
	self.bind(host, "onKey", &js_on_key, 3);
	self.bind(host, "pointer", &js_pointer, 0);
	self.bind(host, "onClick", &js_on_click, 1);
}

<*
 Take the frame's keyboard, and keep the typed text rather than borrow it.

 `InputState.text` points into the window's own buffer, which the next
 `getEvent` clears — so a script reading `three.input.text` between frames would
 be reading whatever the window has accumulated since, which is a different
 answer to the same question depending on when it was asked. Copying is a few
 bytes a frame and makes the value mean one thing.
*>
fn void JsRuntime.take_input(&self, InputState input)
{
	self.input = input;
	self.input_text.clear();
	self.input_text.append_string(input.text);
	self.input.text = self.input_text.str_view();
}

<*
 Call every handler whose edge happened this frame.

 Walked by index rather than by iterator because a handler that fails is removed
 from under the walk — which is the ordinary path, not the exceptional one, since
 a handler is stopped the first time it misbehaves.
*>
fn void JsRuntime.dispatch_keys(&self)
{
	usz at = 0;
	while (at < self.key_handler_count)
	{
		KeyHandler handler = self.key_handlers[at];
		bool fired = handler.on_press
			? self.input.went_down(handler.row)
			: self.input.went_up(handler.row);

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
			// Removed, so the slot now holds the next handler and the index
			// stays where it is.
			self.drop_key_handler(at);
		}

		// The budget belongs to the whole frame. Once it is gone every later
		// call would be interrupted on its first instruction and stopped for a
		// failure that is not its own.
		if (self.timed_out) break;
	}
}

<*
 One handler, called with the name it was registered under.

 The name rather than an event object: one function bound to `'w'`, `'a'`, `'s'`
 and `'d'` is the ordinary shape, and it needs to know which arrived. There is
 no event here to hand it — the host has a latch, not a queue.

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
			self.report_frame_failure(self.timed_out
				? self.frame_timeout_message()
				: string::tformat(
					"the '%s' key handler threw and was stopped: %s",
					handler.row.name, self.js.exception(tmem)));
			kept = false;
		}
		else
		{
			bool promised = self.is_thenable(answer);
			self.js.release(answer);
			if (promised)
			{
				self.report_frame_failure(string::tformat(
					"the '%s' key handler returned a promise. It has to finish inside the frame, "
					"so it must be synchronous — do the awaiting in a run_script instead",
					handler.row.name));
				kept = false;
			}
		}
	};

	return kept;
}

<*
 Release a handler's function and close the gap.

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
	self.key_handlers[self.key_handler_count] = {};
}

<*
 Forget every key handler. Called by `JsRuntime.close`, and so bound by the same
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
 Call the click handler, if this frame ended a click and there is one.

 The raycast happens here rather than in the script, which is the whole of what
 "click to pick" buys over `three.input.pointer` plus `scene.pick`. It costs a
 BVH walk per gesture, which is once per click and not once per frame.
*>
fn void JsRuntime.dispatch_click(&self)
{
	if (!self.click_active || !self.input.mouse.clicked) return;

	bool kept = true;

	@pool()
	{
		float x = self.input.mouse.x;
		float y = self.input.mouse.y;

		// `pick_at` answers null with no device, which is what a miss answers
		// too — so a handler written against a window still runs headless, and
		// what it is told is the truth rather than an error nobody caused.
		qjs::Value[3] args = {
			self.pick_at(&self.js, x, y),
			qjs::number_value((double)x),
			qjs::number_value((double)y),
		};
		defer self.js.release(args[0]);

		qjs::Value? answer = self.js.call(self.click_fn, qjs::undefined_value(), args[..]);
		if (catch err = answer)
		{
			self.report_frame_failure(self.timed_out
				? self.frame_timeout_message()
				: string::tformat(
					"the click handler threw and was stopped: %s", self.js.exception(tmem)));
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
					"so it must be synchronous — do the awaiting in a run_script instead");
				kept = false;
			}
		}
	};

	if (!kept) self.clear_click_handler();
}

<*
 Forget the click handler. Same rule as `clear_key_handlers`, same reason.
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
 Resolve a name argument, raising a JS error when there is no such key.

 **A typo must not be a key that is simply never down.** Nothing is broken,
 nothing is logged, and the only symptom is a control that does nothing — which
 is indistinguishable from every other reason a control might do nothing. The
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
			*out = js.raise(string::tformat(
				"there is no key called '%s' — three.input.keys() lists every name there is",
				name));
		}
	};
	return row;
}

fn void js_input_down(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);
	KeyName? row = named_key(self, &js, argc, args, 0, out);
	if (catch err = row) return;
	*out = qjs::bool_value(self.input.is_down(row));
}

fn void js_input_pressed(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);
	KeyName? row = named_key(self, &js, argc, args, 0, out);
	if (catch err = row) return;
	*out = qjs::bool_value(self.input.went_down(row));
}

fn void js_input_released(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);
	KeyName? row = named_key(self, &js, argc, args, 0, out);
	if (catch err = row) return;
	*out = qjs::bool_value(self.input.went_up(row));
}

fn void js_input_text(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
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
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
) @local
{
	qjs::Context js = qjs::wrap(ctx);

	qjs::Value names = js.array();
	uint at = 0;
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
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
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
			*out = js.raise(string::tformat(
				"there is room for %d key handlers and they are all taken — "
				"unbind one with three.onKeyDown(key, null)",
				MAX_KEY_HANDLERS));
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
 pixel from a different sample than the flag is a bug that only shows up when
 the mouse is moving.
*>
fn void js_pointer(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	MouseState mouse = self.input.mouse;

	qjs::Value object = js.object();
	js.set_property(object, "x", qjs::number_value((double)mouse.x));
	js.set_property(object, "y", qjs::number_value((double)mouse.y));
	js.set_property(object, "inside", qjs::bool_value(mouse.inside));
	js.set_property(object, "down", qjs::bool_value(mouse.down));
	js.set_property(object, "clicked", qjs::bool_value(mouse.clicked));
	*out = object;
}

<*
 `__three.onClick(fn)` — register, replace, or with null remove.

 One handler, not a table. A click has no name to key a table by — every click
 is the same event at a different pixel — so the choice a key binding has, of
 which of thirty-two rows to replace, does not exist here. It is
 `setAnimationLoop`'s shape rather than `onKey`'s.
*>
fn void js_on_click(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
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

	// Released before the new one is retained, so replacing cannot leak and
	// cannot leave the old handler firing under a script that believes it has
	// been replaced.
	self.clear_click_handler();
	if (clearing) return;

	self.click_fn = js.retain(args[0]);
	self.click_active = true;
}
