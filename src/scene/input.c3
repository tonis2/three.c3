<*
 The keyboard, as two questions and one table.

 ## Level and edge are different questions

 Holding W to walk forward and pressing space to jump are not the same kind of
 input, and a single answer serves neither well. `c3w` reports a **latch** — a
 map of what is down right now, which persists across frames — so "is W down"
 is a read and "did space go down *this* frame" is a one-frame difference
 against the previous read. The difference has to be taken here, beside the
 latch, because it is only meaningful once per frame and JavaScript has no way
 to know when a frame happened.

 ## The names are the API

 `c3w::EventKey` is an enum of X11 keycodes, which is the right identity for a
 host and the wrong one for a script. `KEY_NAMES` maps the strings an agent will
 actually type — the browser's `KeyboardEvent.key`, lowercased — onto it, and
 the same table is what `get_api_docs` lists. One table, or the docs describe a
 keyboard nobody has.

 An unknown name **throws** rather than reporting a key that is never down. A
 typo that silently never fires is the worst possible failure here: nothing is
 broken, nothing is logged, and the only symptom is a control that does nothing.

 ## Where the window is, and is not

 `read_events` is the only function here that knows what a window is, and it is
 six lines. Everything else — the bits, the difference, the lookup — is reached
 by `InputTracker.step`, which takes what is down and answers with what changed.
 That is the same seam `controls.c3` uses and it is there for the same reason:
 the suite is headless, and a keyboard verified by nobody is a keyboard that
 drifts.

 **No mouse buttons are named here**, although the same latch carries them.
 `controls.c3` documents why: AppKit swallows the mouse-up that ends a title-bar
 drag, so the button stays latched for the rest of the session. A script polling
 `isDown('mouseleft')` would have no gate against that and would be told the
 button is held forever. The mouse is at the bottom of this file instead, where
 it is a *click* rather than a button — an edge, which a stuck latch cannot
 produce.

 ## The pointer, at the bottom

 The same two questions with different answers. Level state is where the cursor
 is, and it is a conversion rather than a difference: the window reports points
 counted from the bottom-left and the picker takes image pixels counted from the
 top-left, and `WindowView.cursor` is the one place both of those are undone.
 The edge is the click, which is a press and a release that stayed together.
*>
module three;

import std::math;
import c3w;

// 124 keys today, and the room is free: this is four words of stack, copied
// once a frame.
const usz KEY_SLOTS = 4;
const usz KEY_BITS = KEY_SLOTS * 64;

$assert c3w::EventKey::values.len <= KEY_BITS : "c3w has more keys than KeyBits has room for";

<*
 Which keys are down, one bit each, indexed by the ordinal of `c3w::EventKey`.

 A bitset rather than the map it came from, because the whole point is the
 difference between two frames and `a & ~b` is the difference. A pair of hash
 maps would be an allocation and a lookup per key per frame to answer a question
 that is thirty-two bytes wide.
*>
struct KeyBits
{
	ulong[KEY_SLOTS] word;
}

fn void KeyBits.set(&self, c3w::EventKey key)
{
	usz at = key.ordinal;
	self.word[at / 64] |= 1UL << (at % 64);
}

fn bool KeyBits.has(&self, c3w::EventKey key)
{
	usz at = key.ordinal;
	return (self.word[at / 64] & (1UL << (at % 64))) != 0;
}

// The bits set here and not in `other` — which is every edge this file reports,
// in one direction or the other.
fn KeyBits KeyBits.without(&self, KeyBits other)
{
	KeyBits out;
	for (usz i = 0; i < KEY_SLOTS; i++) { out.word[i] = self.word[i] & ~other.word[i]; }
	return out;
}

// The bits set in either. What joins the two sources an edge can come from —
// see `InputTracker.step`.
fn KeyBits KeyBits.with(&self, KeyBits other)
{
	KeyBits out;
	for (usz i = 0; i < KEY_SLOTS; i++) { out.word[i] = self.word[i] | other.word[i]; }
	return out;
}

<*
 Set a key by the name a script would use. Unknown names are ignored, which is
 right for a host filling one in and wrong for a script asking about one — see
 `find_key`, which throws instead.
*>
fn bool KeyBits.add(&self, String name)
{
	KeyName? row = find_key(name);
	if (catch err = row) return false;
	self.set(row.key);
	if (row.also != c3w::EventKey.EMPTY_KEY) self.set(row.also);
	return true;
}

<*
 What the window said about the keyboard this frame: the latch, and the
 transitions behind it.

 Two sources for the same fact, and they disagree in exactly one case, which is
 the case the second one exists for. See `InputTracker.step`.
*>
struct FrameKeys
{
	// What is held right now, from the latch.
	KeyBits down;
	// Every key that was seen going down during the frame, from the queue —
	// including ones that were let go again before anybody looked.
	KeyBits fired_down;
	KeyBits fired_up;
}

<*
 One frame of keyboard, as the two questions and the text.

 `text` is borrowed from the window and is only valid for the frame it was
 sampled in. It is separate from the keys on purpose: a script that wants a text
 field wants what was typed, with the modifier chords and the function-key range
 already filtered out, and not a key map it would have to reassemble a keyboard
 layout from.
*>
struct InputState
{
	KeyBits down;
	KeyBits pressed;
	KeyBits released;
	String text;
	MouseState mouse;
}

<*
 What the previous frame had down, which is the entire state an edge needs —
 and the pointer's version of the same thing.
*>
struct InputTracker
{
	KeyBits previous;
	MouseTracker mouse;
}

<*
 Fold one frame's keyboard into level state and the two edges.

 ## An edge has two sources, and the union is the answer

 The difference against the previous frame — `down & ~previous` — is the edge as
 far as the latch can describe it, and it misses the press that began and ended
 inside one frame: the flag is set and cleared before anything samples it. The
 window's own event queue has that press, and `keys.fired_down` is it.

 They are **or**-ed rather than one replacing the other, and that is deliberate.
 A backend with no queue reports nothing there and keeps exactly today's
 behaviour rather than losing every edge it had; a backend with one adds the
 presses the difference could not see. Neither can produce a false edge — the
 difference needs a real transition and the queue needs a real event — so the
 union is not a compromise between two answers, it is two ways of noticing the
 same thing and taking whichever noticed.

 A key that goes down and up inside one frame is then reported as both pressed
 and released in that frame, which is what happened.

 The mouse rides along rather than having a tracker of its own to be stepped
 beside this one. There is one input per frame and forgetting half of it would
 be a silent half — a window whose keyboard works and whose clicks do nothing.

 @param keys : `What the window said. The host reads this from its window; a test says so directly.`
 @param text : `What was typed this frame, borrowed for the frame.`
 @param cursor : `Where the pointer is, already in image pixels. Default-empty for a host with no window.`
 @param now_ms : `The host's clock, for telling a click from a hold.`
*>
fn InputState InputTracker.step(&self, FrameKeys keys, String text = "", Cursor cursor = {}, double now_ms = 0)
{
	InputState state = {
		.down = keys.down,
		.pressed = keys.down.without(self.previous).with(keys.fired_down),
		.released = self.previous.without(keys.down).with(keys.fired_up),
		.text = text,
		.mouse = self.mouse.step(cursor, now_ms),
	};
	self.previous = keys.down;
	return state;
}

<*
 The window's latched map and its event queue, as bits.

 Iterating the map rather than asking it about all 124 keys: it only holds keys
 that have ever been seen, which on a real keyboard is a handful. The queue is
 shorter still — it is one frame of transitions, and an idle frame has none.

 @param log : `What c3w drained this frame. Empty is a perfectly good answer and means "the latch is all there is".`
*>
fn FrameKeys read_events(c3w::EventMap events, c3w::Event[] log = {})
{
	FrameKeys keys;

	events.@each(; c3w::EventKey key, bool held)
	{
		if (held) keys.down.set(key);
	};

	foreach (c3w::Event event : log)
	{
		switch (event.type)
		{
			case KEY_PRESSED: keys.fired_down.set(event.value);
			case KEY_RELEASED: keys.fired_up.set(event.value);
			// The queue carries the mouse buttons too. They are not keys and
			// `MouseTracker` has the latch it needs, so they are skipped here
			// rather than turned into keyboard edges nobody asked for.
			default: break;
		}
	}

	return keys;
}

// ============================================================================
// Names
// ============================================================================

faultdef NO_SUCH_KEY;

<*
 One row of the table: a name, and the one or two keys it means.

 `also` is what makes `'shift'` mean either shift. The browser's `key` reports
 both as `Shift` and an agent will write that; `'shiftleft'` is there for the
 rare script that means one of them.
*>
struct KeyName
{
	String name;
	c3w::EventKey key;
	c3w::EventKey also;
}

<*
 The names a script may use, and the only ones.

 Lowercased `KeyboardEvent.key`, because that is the spelling an agent has
 memorized: letters and digits are themselves, punctuation is the character it
 prints, and the rest are the browser's words. Three aliases are included for
 the spellings people actually type — `ctrl`, `cmd`, `esc` — and are listed as
 aliases rather than as separate keys.

 **The numpad is deliberately missing.** `c3w` reports it, and adding it is
 sixteen rows; nothing in an agent-driven 3D API has ever wanted it, and every
 row here is a line in the docs an agent reads.
*>
const KeyName[*] KEY_NAMES = {
	{ "a", A, EMPTY_KEY }, { "b", B, EMPTY_KEY }, { "c", C, EMPTY_KEY }, { "d", D, EMPTY_KEY },
	{ "e", E, EMPTY_KEY }, { "f", F, EMPTY_KEY }, { "g", G, EMPTY_KEY }, { "h", H, EMPTY_KEY },
	{ "i", I, EMPTY_KEY }, { "j", J, EMPTY_KEY }, { "k", K, EMPTY_KEY }, { "l", L, EMPTY_KEY },
	{ "m", M, EMPTY_KEY }, { "n", N, EMPTY_KEY }, { "o", O, EMPTY_KEY }, { "p", P, EMPTY_KEY },
	{ "q", Q, EMPTY_KEY }, { "r", R, EMPTY_KEY }, { "s", S, EMPTY_KEY }, { "t", T, EMPTY_KEY },
	{ "u", U, EMPTY_KEY }, { "v", V, EMPTY_KEY }, { "w", W, EMPTY_KEY }, { "x", X, EMPTY_KEY },
	{ "y", Y, EMPTY_KEY }, { "z", Z, EMPTY_KEY },

	{ "0", KEY_0, EMPTY_KEY }, { "1", KEY_1, EMPTY_KEY }, { "2", KEY_2, EMPTY_KEY }, { "3", KEY_3, EMPTY_KEY },
	{ "4", KEY_4, EMPTY_KEY }, { "5", KEY_5, EMPTY_KEY }, { "6", KEY_6, EMPTY_KEY }, { "7", KEY_7, EMPTY_KEY },
	{ "8", KEY_8, EMPTY_KEY }, { "9", KEY_9, EMPTY_KEY },

	{ "space", SPACE, EMPTY_KEY },
	{ "enter", RETURN, EMPTY_KEY },
	{ "escape", ESCAPE, EMPTY_KEY },
	{ "esc", ESCAPE, EMPTY_KEY },
	{ "tab", TAB, EMPTY_KEY },
	{ "backspace", BACKSPACE, EMPTY_KEY },
	{ "delete", DELETE, EMPTY_KEY },
	{ "insert", INSERT, EMPTY_KEY },
	{ "capslock", CAPS_LOCK, EMPTY_KEY },

	{ "shift", LEFT_SHIFT, RIGHT_SHIFT },
	{ "shiftleft", LEFT_SHIFT, EMPTY_KEY },
	{ "shiftright", RIGHT_SHIFT, EMPTY_KEY },
	{ "control", LEFT_CTRL, RIGHT_CTRL },
	{ "ctrl", LEFT_CTRL, RIGHT_CTRL },
	{ "controlleft", LEFT_CTRL, EMPTY_KEY },
	{ "controlright", RIGHT_CTRL, EMPTY_KEY },
	{ "alt", LEFT_ALT, RIGHT_ALT },
	{ "altleft", LEFT_ALT, EMPTY_KEY },
	{ "altright", RIGHT_ALT, EMPTY_KEY },
	{ "meta", LEFT_SUPER, RIGHT_SUPER },
	{ "cmd", LEFT_SUPER, RIGHT_SUPER },
	{ "metaleft", LEFT_SUPER, EMPTY_KEY },
	{ "metaright", RIGHT_SUPER, EMPTY_KEY },

	{ "arrowup", UP_ARROW, EMPTY_KEY },
	{ "arrowdown", DOWN_ARROW, EMPTY_KEY },
	{ "arrowleft", LEFT_ARROW, EMPTY_KEY },
	{ "arrowright", RIGHT_ARROW, EMPTY_KEY },
	{ "up", UP_ARROW, EMPTY_KEY },
	{ "down", DOWN_ARROW, EMPTY_KEY },
	{ "left", LEFT_ARROW, EMPTY_KEY },
	{ "right", RIGHT_ARROW, EMPTY_KEY },

	{ "f1", F1, EMPTY_KEY }, { "f2", F2, EMPTY_KEY }, { "f3", F3, EMPTY_KEY }, { "f4", F4, EMPTY_KEY },
	{ "f5", F5, EMPTY_KEY }, { "f6", F6, EMPTY_KEY }, { "f7", F7, EMPTY_KEY }, { "f8", F8, EMPTY_KEY },
	{ "f9", F9, EMPTY_KEY }, { "f10", F10, EMPTY_KEY }, { "f11", F11, EMPTY_KEY }, { "f12", F12, EMPTY_KEY },

	{ "home", HOME, EMPTY_KEY },
	{ "end", END, EMPTY_KEY },
	{ "pageup", PAGE_UP, EMPTY_KEY },
	{ "pagedown", PAGE_DOWN, EMPTY_KEY },

	{ "-", MINUS, EMPTY_KEY },
	{ "=", EQUALS, EMPTY_KEY },
	{ "[", LEFT_BRACKET, EMPTY_KEY },
	{ "]", RIGHT_BRACKET, EMPTY_KEY },
	{ "\\", BACKSLASH, EMPTY_KEY },
	{ ";", SEMICOLON, EMPTY_KEY },
	{ "'", APOSTROPHE, EMPTY_KEY },
	{ "`", GRAVE, EMPTY_KEY },
	{ ",", COMMA, EMPTY_KEY },
	{ ".", PERIOD_KEY, EMPTY_KEY },
	{ "/", SLASH_KEY, EMPTY_KEY },
};

<*
 Find a key by name, case-insensitively.

 A linear walk over ninety-odd rows, once per `isDown` and once per
 registration. A map would be faster and would have to be built, kept and freed;
 this is a few hundred byte comparisons inside a call that has already crossed
 the JavaScript boundary.

 @return? NO_SUCH_KEY : `No row has that name. The caller says so out loud — a key that is silently never down is a control that silently does nothing.`
*>
fn KeyName? find_key(String name)
{
	foreach (KeyName row : KEY_NAMES)
	{
		if (name_matches(name, row.name)) return row;
	}
	return NO_SUCH_KEY~;
}

<*
 `written` against a row's name, which is already lowercase.

 Folded a character at a time rather than by lowercasing a copy: `'W'` is what
 an agent writes half the time and this is on the path of every `isDown` call.
*>
fn bool name_matches(String written, String row) @local
{
	if (written.len != row.len) return false;
	for (usz i = 0; i < written.len; i++)
	{
		char c = written[i];
		if (c >= 'A' && c <= 'Z') c += 32;
		if (c != row[i]) return false;
	}
	return true;
}

// ============================================================================
// Asking
// ============================================================================

<*
 Whether either of the row's keys is down.

 A two-key row answers for both, which is what `'shift'` has to mean. The edge
 questions do the same, so pressing one shift while the other is already held
 reports a second `'shift'` press — predictable, and the alternative is a rule
 nobody could state.
*>
fn bool InputState.is_down(&self, KeyName row)
{
	return self.down.has(row.key)
		|| (row.also != c3w::EventKey.EMPTY_KEY && self.down.has(row.also));
}

fn bool InputState.went_down(&self, KeyName row)
{
	return self.pressed.has(row.key)
		|| (row.also != c3w::EventKey.EMPTY_KEY && self.pressed.has(row.also));
}

fn bool InputState.went_up(&self, KeyName row)
{
	return self.released.has(row.key)
		|| (row.also != c3w::EventKey.EMPTY_KEY && self.released.has(row.also));
}

// ============================================================================
// The pointer
// ============================================================================

<*
 How far a press may travel, and how long it may last, and still be a click.

 **In the rendered image's pixels**, which is the unit the question is actually
 asked in: the slop exists to decide whether the person aimed somewhere else,
 and "somewhere else" is a place in the picture rather than a distance the hand
 moved. Four is about the tremor of a careful trackpad click, and half a second
 is longer than any click and shorter than any deliberate hold.
*>
const float CLICK_SLOP = 4.0;
const double CLICK_HOLD_MS = 500.0;

<*
 Where the cursor is, in the rendered image's pixels.

 `x` counts from the left and `y` from the **top** — which is neither of the two
 things the platform hands over. `c3w`'s contract is the window's own units with
 a bottom-left origin, and `scene.pick` takes image pixels from the top-left,
 the corner the PNG starts at. Both conversions happen in `WindowView.cursor`
 and nowhere else, so everything downstream is in one coordinate system and it
 is the picture's.
*>
struct Cursor
{
	bool inside;
	bool down;
	float x;
	float y;
}

<*
 The window and the image, as far as a cursor is concerned.

 **The picture is stretched, not scaled.** `Viewer.record_blit` copies the whole
 offscreen target onto the whole swapchain image — no letterbox, no crop, and no
 relationship between the two extents beyond the fraction. So the mapping is a
 fraction of the window and not a multiplication by the backing scale, which is
 the tempting version and is wrong twice over: the target is fixed at the size
 `--width`/`--height` asked for while the swapchain follows a live resize drag,
 and on a retina display the two agree at startup by coincidence and diverge the
 moment the window is touched. `plan.md` §1 — the window is a consumer, never
 the target — is what makes that true, and this is where it is paid for.
*>
struct WindowView
{
	// The drawable's extent, in device pixels: the swapchain's, which tracks a
	// live resize where `Window.width` is only ever what `new` was asked for.
	uint width;
	uint height;
	// Device pixels per window point. One everywhere but a retina display.
	float scale;
	// The offscreen target's extent — what `scene.pick` counts in and what a
	// screenshot comes back as.
	uint image_width;
	uint image_height;
}

<*
 Turn one reading of the cursor into image pixels.

 @param at : `The window's own answer: window-relative, bottom-left origin, in the platform's units.`
 @param down : `The left button's latch, as the window reports it.`
*>
fn Cursor WindowView.cursor(&self, float[<2>] at, bool down)
{
	// Minimised, or before the first frame. The fallback is a cursor that is
	// nowhere and the alternative is a division by zero in the one function the
	// whole gesture path runs through.
	if (self.width == 0 || self.height == 0 || self.scale <= 0.0f) return {};

	// The scale is what makes the pointer's unit and the extent's unit the same
	// one; after this line neither of them exists any more, only the fraction.
	float across = (at[0] * self.scale) / (float)self.width;
	float up = (at[1] * self.scale) / (float)self.height;

	bool inside = across >= 0.0f && across < 1.0f && up >= 0.0f && up < 1.0f;

	return {
		.inside = inside,
		.down = down,
		.x = across * (float)self.image_width,
		// The one flip, and the only place it happens. `screen_ray` counts rows
		// from the top because that is how an image is stored and how every
		// window but Cocoa's reports a cursor; `c3w` normalises all of them to
		// Cocoa's. Getting it backwards is invisible at the centre of the
		// window and wrong everywhere else, which is the same trap `screen_ray`
		// documents about its own flip.
		.y = (1.0f - up) * (float)self.image_height,
	};
}

<*
 One frame of mouse, as a script sees it.
*>
struct MouseState
{
	bool inside;
	bool down;
	// True for exactly the one frame a press and its release resolved to a
	// click. `x` and `y` are then where the release landed.
	bool clicked;
	float x;
	float y;
}

<*
 The press this tracker is waiting to see the end of.
*>
struct MouseTracker
{
	bool was_down;
	bool holding;
	float press_x;
	float press_y;
	double press_ms;
}

<*
 Fold one reading of the cursor into level state and, at the end of a press,
 a click.

 ## The edge is the gate

 `controls.c3` documents a latch that sticks: AppKit swallows the mouse-up that
 ends a title-bar drag, so the button reads as held for the rest of the session,
 and `Controls` waits for one button-free frame before believing it. Nothing of
 that sort is here, and adding it would be exactly the second mechanism
 `controls.c3` argues against. A click needs a press *edge* — a frame where the
 button was not down and now is — and a stuck latch produces no edges at all, so
 it produces no clicks rather than one a frame.

 It heals the same way and for the same reason. The first real click after a
 stuck latch is swallowed, because that click's release is what finally clears
 the latch and there was no press edge to match it; the click after that works.

 ## A drag is not a click

 The left button orbits the camera, so every click is also a drag of a few
 pixels and every drag ends in a release. The slop and the hold are what tell
 them apart, and they are deliberately generous in the direction of *not* being
 a click: a picked object that was not asked for is worse than a click that has
 to be repeated, because it changes the scene and the person has to find out
 what it changed.

 @param now_ms : `The host's clock — the same one the animation callback is told.`
*>
fn MouseState MouseTracker.step(&self, Cursor cursor, double now_ms)
{
	bool clicked = false;

	if (cursor.down && !self.was_down)
	{
		// A press that begins outside the window starts nothing: the window
		// still reports a position when the cursor has left it, so `inside` is
		// the only thing that says the press was aimed at the picture.
		self.holding = cursor.inside;
		self.press_x = cursor.x;
		self.press_y = cursor.y;
		self.press_ms = now_ms;
	}
	else if (!cursor.down && self.was_down)
	{
		clicked = self.holding
			&& cursor.inside
			&& math::abs(cursor.x - self.press_x) <= CLICK_SLOP
			&& math::abs(cursor.y - self.press_y) <= CLICK_SLOP
			&& now_ms - self.press_ms <= CLICK_HOLD_MS;
		self.holding = false;
	}

	self.was_down = cursor.down;

	return {
		.inside = cursor.inside,
		.down = cursor.down,
		.clicked = clicked,
		.x = cursor.x,
		.y = cursor.y,
	};
}

<*
 What the cursor should look like, given where it is and what it is over.

 Three states in order of how much they override each other. A closed hand
 whenever something is being dragged, because that is true wherever the cursor
 has got to. Then the arrow off the image — the window's own edges and title bar
 are the platform's to dress, and asserting a hand over them would fight it.
 Then a pointing hand over something clickable and an open one over empty scene,
 which is the ordinary case and the only one anybody will look at for long.

 **The pointing hand is the one that carries information.** The other two say
 what the hand is doing, which the person already knows because it is their
 hand; this one says what would happen if they pressed, which they cannot know
 any other way — `onClick` picks, and nothing else on screen says whether there
 is anything to pick.

 A function rather than four lines at the call site because the call site is
 `main.c3`, which is the one file with no checks in it, and "the cursor is a
 closed hand while panning as well as while orbiting" is exactly the sort of
 claim that is true when written and false a milestone later.

 @param inside : `Whether the cursor is over the rendered image.`
 @param dragging : `Controls.dragging — a believed drag, not merely a held button.`
 @param over : `Whether the picker found something under it. See Hover, which decides when that is worth asking.`
*>
fn c3w::CursorShape cursor_shape(bool inside, bool dragging, bool over = false)
{
	if (dragging) return CLOSED_HAND;
	if (!inside) return ARROW;
	return over ? c3w::CursorShape.POINTING_HAND : c3w::CursorShape.OPEN_HAND;
}

<*
 The last answer the picker gave about the pointer, and where it was standing
 when it gave it.

 **A raycast per frame is the wrong price for a cursor shape.** The broad phase
 is one world-AABB test per instance, and a scene built to make the point that
 a thousand instances are one draw call is a scene where that is a thousand
 tests — to decide between two pictures of a hand. So it is asked once per
 *place* the pointer stops, not once per frame: a still cursor over a still
 scene costs nothing, and a moving one costs one raycast per frame it moves,
 which is bounded by the frame rate and by how fast a hand can move.

 What it deliberately does not do is notice the scene changing under a still
 cursor. A script that deletes what the pointer is resting on leaves a pointing
 hand over nothing until the hand moves a pixel, and that is the cheap half of
 the trade: the alternative is the raycast per frame this exists to avoid, for a
 wrong cursor that corrects itself the moment anybody does anything.
*>
struct Hover
{
	bool over;
	bool known;
	float x;
	float y;
}

// Whether the picker has to be asked again: the pointer has moved, or has never
// been asked about at all.
fn bool Hover.stale(&self, Cursor cursor)
{
	return !self.known || cursor.x != self.x || cursor.y != self.y;
}

fn void Hover.keep(&self, Cursor cursor, bool over)
{
	self.known = true;
	self.over = over;
	self.x = cursor.x;
	self.y = cursor.y;
}

// Called when the answer stops being wanted — the pointer left the image, or a
// drag started. Forgetting rather than keeping is what makes coming back ask
// again, which matters because the scene may have moved in between; a drag
// moves the camera by definition.
fn void Hover.forget(&self)
{
	self.known = false;
	self.over = false;
}
