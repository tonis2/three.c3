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
 drag, so the button stays latched for the rest of the session. `Controls` has a
 release gate for that; a script polling `isDown('mouseleft')` would have no such
 thing and would be told the button is held forever. Clicking belongs with the
 picking work, where it can be given the same gate.
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
}

<*
 What the previous frame had down, which is the entire state an edge needs.
*>
struct InputTracker
{
	KeyBits previous;
}

<*
 Fold one frame's latch into level state and the two edges.

 @param down : `What is held right now. The host reads this from its window; a test says so directly.`
 @param text : `What was typed this frame, borrowed for the frame.`
*>
fn InputState InputTracker.step(&self, KeyBits down, String text = "")
{
	InputState state = {
		.down = down,
		.pressed = down.without(self.previous),
		.released = self.previous.without(down),
		.text = text,
	};
	self.previous = down;
	return state;
}

<*
 The window's latched map as bits.

 Iterating the map rather than asking it about all 124 keys: it only holds keys
 that have ever been seen, which on a real keyboard is a handful.
*>
fn KeyBits read_events(c3w::EventMap events)
{
	KeyBits down;
	events.@each(; c3w::EventKey key, bool held)
	{
		if (held) down.set(key);
	};
	return down;
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
