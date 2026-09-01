<*
 The interface layer: a cui canvas drawn over the finished frame.

 `c3c test --trust=full --test-noleak --test-filter three_tests::ui`

 ## Where it sits

 Fourth in `Renderer.record_scene`'s list, after the post chain and before
 `target.close`:

     prepare -> shadow -> scene -> [post chain] -> [UI] -> close

 After post, because an interface that gets bloomed and tonemapped is not an
 interface. Into `target.color`, because that is the image the blit reads, the
 readback copies and the MCP screenshot returns — so what an agent sees and what
 a person sees are the same picture, and neither needs a window.

 ## The one file that imports cui

 Everything in this project is `module three`, and cui has a `Cursor`, a `Camera`
 and a `Texture` of its own. Keeping the import here means one file has to
 qualify rather than every file having to. Nothing below leaks a `cui::` type
 into a signature the rest of the project calls: the tree crosses as `UiNodeSpec`
 and `UiOp`, which are numbers, strings and enums of this project's own, and the
 callbacks leave through a function pointer. `js/bind_ui.c3` is written entirely
 against that vocabulary and never mentions cui.

 ## Nothing exists until something asks

 `Renderer.init` does not build this. A run with no interface allocates no
 buffers, parses no font and records no commands, so every existing frame is
 byte-identical to one from before this file — which is what makes the whole
 layer safe to carry in the headless tests. `set_overlay`, `set_tree` and
 `measure` are what bring it up.

 ## The root has two floors

 `ensure` builds a fixed frame that nothing below replaces:

     Stack (root, transparent to the pointer)
       |- Stack (content, transparent)   <- three.ui.set / three.ui.draw live here
       |- Anchored > Label               <- three.debug.overlay

 Two floors rather than one because the two verbs have different owners and
 different lifetimes: the overlay is one line the host wipes every frame, and the
 content is a script's snapshot that stays until it is replaced. Later siblings
 paint later, so the debug line is always legible over whatever a script drew.

 Both stacks set `ignores_pointer`. A full-frame container that did not would win
 every hit test in the window and turn the whole scene into a dead zone — cui
 tests the deepest rect containing the point whether or not its widget handles
 anything, which is the same reason `Label` sets the flag for itself.

 ## What it costs, and where that shows

 The interface's GPU time lands inside `stats().presentMs` rather than a phase of
 its own: the marks in `gpu/timing.c3` are BEGIN..POST..END and this draws
 between the last two. Worth a `uiMs` of its own once an interface is more than a
 panel.
*>
module three;

import std::collections::list;
import std::math;
import cui;
import cui::vulkan;
import cui::widgets;
import c3w;
import vk;

<*
 What the interface refuses.

 `UI_NO_SUCH_KEY` is the only one a script can provoke by writing a name wrong,
 and it is the reason `patch` is a fault rather than a silent no-op: a key that
 stopped matching after a `set` renamed a node is a HUD that quietly freezes, and
 finding out why costs an afternoon.
*>
faultdef UI_NO_SUCH_KEY, UI_NO_TREE, UI_BAD_PARENT, UI_NO_DEVICE;

<*
 The font the interface draws with, in the binary rather than on disk.

 The same argument `js/runtime.c3` makes for the prelude: a renderer that needs
 a file beside it to draw a line of text is a renderer that draws nothing from a
 different working directory, and the headless tests and the MCP server both run
 from wherever they were started. DejaVu Sans, under its own permissive licence.
*>
const char[*] UI_FONT = $embed("fonts/DejaVuSans.ttf");

// ============================================================================
// The drawing IR
// ============================================================================

<*
 The seven things cui can draw, and the whole of them.

 Every built-in widget's `paint` is some arrangement of these calls and nothing
 else, which is what makes a script handed this list as capable as a widget
 rather than a reduced version of one. All of them are antialiased SDFs and all
 of them land in the same single instanced draw call.
*>
enum UiOpKind : char
{
	RECT,
	CIRCLE,
	ELLIPSE,
	LINE,
	ARC,
	TEXT,
	SHADOW,
}

<*
 One drawing, in the coordinates of the element that holds it.

 A single flat struct rather than seven, because the list is homogeneous and a
 union keyed by `kind` would cost a tag anyway. Fields that mean nothing for a
 kind are zero, and `push_op` is the one place that decides what a kind reads.

 `text` is borrowed from the owning node's string list — see `UiNode.owned`. It
 outlives the element because the node does, and it is the reason `push_op`
 copies rather than storing what the caller passed.
*>
struct UiOp
{
	UiOpKind kind;
	// Rect top-left, circle/ellipse/arc centre, line start, text top-left.
	Vec2 at;
	// Rect size, ellipse radii, line end.
	Vec2 to;
	float radius;
	float thickness;
	// Arc angles, radians, 0 = +x and increasing clockwise (y points down).
	float start;
	float sweep;
	float blur;
	// Text em size in px; 0 uses cui's default.
	float size;
	uint font;
	Vec4 color;
	Vec4 border_color;
	float border_width;
	// Per-corner radius {TL, TR, BR, BL}.
	Vec4 corners;
	String text;
}

<*
 A list of drawings as an element: `{ type: 'draw' }`, and what
 `three.ui.draw(ops)` is a tree of one.

 Written here rather than composed out of built-ins because there is no built-in
 for it — this is the widget that turns the `Painter` surface into data. It sizes
 by `size` per axis with zero meaning fill, so the screen-space verb is this node
 filling the root and the element-local case is the same widget under a Column.

 It takes the pointer only when a script asked it to. Decoration that swallowed
 clicks would be worse than useless over a viewport, and `Label` sets the same
 flag for the same reason.
*>
struct UiPainting (cui::Widget)
{
	Vec2 size;
	// Index into `UiLayer.nodes`, so a click can say which painting it was.
	uint node;
	bool clickable;
	bool hoverable;
	// The whole pointer — position, buttons, modifiers, wheel — rather than the
	// fact of a click. What a dopesheet, a curve editor or a gizmo is made of,
	// and the reason those are writable in JavaScript at all.
	bool pointing;
	// `solid` on a `draw` node. Carried here because `layout` below decides this
	// element's `ignores_pointer` every pass and would otherwise overwrite what
	// `push_node` set — so without it `solid` would mean one thing on every kind
	// and nothing on this one.
	bool blocking;
	// Re-pointed by `commit_tree` once the node's op list has stopped growing.
	UiOp[] ops;
}

fn Vec2 UiPainting.layout(&self, cui::Element* elem, cui::Constraints constraints) @dynamic
{
	elem.ignores_pointer = !self.clickable && !self.hoverable && !self.pointing && !self.blocking;
	return constraints.constrain(
		{
			self.size.x > 0 ? self.size.x : constraints.max.x,
			self.size.y > 0 ? self.size.y : constraints.max.y,
		}
	);
}

fn void UiPainting.paint(&self, cui::Element* elem, cui::Painter* painter) @dynamic
{
	foreach (op : self.ops)
	{
		switch (op.kind)
		{
			case RECT:
				painter.rect(
					op.at,
					op.to,
					{
						.color = (cui::Color)op.color,
						.border_color = (cui::Color)op.border_color,
						.border_width = op.border_width,
						.border_radius = op.corners,
					}
				);
			case CIRCLE:
				painter.circle(
					op.at,
					op.radius,
					{
						.color = (cui::Color)op.color,
						.border_color = (cui::Color)op.border_color,
						.border_width = op.border_width,
					}
				);
			case ELLIPSE:
				painter.ellipse(
					op.at,
					op.to,
					{
						.color = (cui::Color)op.color,
						.border_color = (cui::Color)op.border_color,
						.border_width = op.border_width,
					}
				);
			case LINE:
				painter.line(op.at, op.to, op.thickness, (cui::Color)op.color);
			case ARC:
				painter.arc(op.at, op.radius, op.start, op.sweep, op.thickness, (cui::Color)op.color);
			case TEXT:
				painter.text(op.at, op.text, { .font = op.font, .size = op.size, .color = (cui::Color)op.color });
			case SHADOW:
				painter.rect_shadow(op.at, op.to, op.blur, (cui::Color)op.color, op.corners);
		}
	}
}

<*
 The pointer, on the two terms a `draw` node can ask for it.

 `onClick` is the small one: a press is consumed so the pointer is captured and a
 release outside still resolves, and so the scene under it does not also get the
 click.

 `onPointer` is the whole thing — position, buttons, modifiers and wheel, every
 frame the pointer is here or captured. It is what makes a timeline, a curve
 editor or a gizmo writable in JavaScript, and the reason it is delivered HERE
 rather than read off `three.input.pointer` is that this is inside the hit test.
 A script polling the global pointer is told about a drag that started on an open
 menu, on a modal, on whatever the host painted over it; a script handed this one
 is not, because cui gave the event to the menu instead.

 What is consumed, and why it is not the same for every phase:

 - **PRESS** consumes, which is also what captures the pointer — a drag that
   leaves the node must keep arriving or every drag ends at the first edge.
 - **RELEASE** consumes, so the press and its release are one gesture.
 - **MOVE** does not, the rule `FileBrowser` follows: a pointer merely passing
   over a panel must still reach a `Scroll` above it. A move during a capture
   arrives regardless, which is the half a drag needs.
 - **SCROLL** consumes when the node asked for the pointer. A panel that draws
   its own timeline owns the wheel over it — that is what zooming a dopesheet is
   — and a node that wanted the wheel to fall through would not have asked.

 @return `True when this element took the event.`
*>
fn bool UiPainting.on_mouse(&self, cui::Element* elem, cui::MouseEvent event) @dynamic
{
	if (self.pointing) ui_fire(elem, ui_pointer_event(elem, event));

	if (self.clickable && event.button == cui::MouseButton.LEFT)
	{
		switch (event.kind)
		{
			case PRESS:
				return true;
			case RELEASE:
				bool inside = event.pos.x >= 0 && event.pos.y >= 0
					&& event.pos.x < elem.size.x && event.pos.y < elem.size.y;
				if (inside) ui_fire(elem, { .kind = UiEventKind.CLICK });
				return true;
			default:
				break;
		}
	}

	if (!self.pointing) return false;
	return event.kind != cui::MouseEventKind.MOVE;
}

<*
 One cui mouse event as the flat `UiEvent` everything here crosses on.

 The position is the ELEMENT's, not the window's. A hit-tested widget is told
 where the pointer is inside itself, and a script handed window coordinates would
 have to subtract an origin — which is `three.ui.slot` all over again, on a node
 whose whole point is that it does not have to know where it was put.

 Buttons and modifiers are read off the frame's input rather than off the event,
 because `MouseEvent.button` says which button this edge is about and says
 nothing about the other two. A drag with the right button held is one test on
 `buttons`, and shift-dragging is one test on `modifiers`.
*>
fn UiEvent ui_pointer_event(cui::Element* elem, cui::MouseEvent event) @local
{
	cui::Input* input = &elem.ui.input;

	UiPointerPhase phase;
	switch (event.kind)
	{
		case PRESS:   phase = UiPointerPhase.DOWN;
		case RELEASE: phase = UiPointerPhase.UP;
		case SCROLL:  phase = UiPointerPhase.WHEEL;
		default:      phase = UiPointerPhase.MOVE;
	}

	uint buttons;
	if (input.down[0]) buttons |= 1;
	if (input.down[1]) buttons |= 2;
	if (input.down[2]) buttons |= 4;

	uint modifiers;
	if (input.key_down((cui::Key)cui::Key.LEFT_SHIFT) || input.key_down((cui::Key)cui::Key.RIGHT_SHIFT))
	{
		modifiers |= 1;
	}
	if (input.key_down((cui::Key)cui::Key.LEFT_CTRL) || input.key_down((cui::Key)cui::Key.RIGHT_CTRL))
	{
		modifiers |= 2;
	}
	if (input.key_down((cui::Key)cui::Key.LEFT_ALT) || input.key_down((cui::Key)cui::Key.RIGHT_ALT))
	{
		modifiers |= 4;
	}
	if (input.key_down((cui::Key)cui::Key.LEFT_SUPER) || input.key_down((cui::Key)cui::Key.RIGHT_SUPER))
	{
		modifiers |= 8;
	}

	return {
		.kind = UiEventKind.POINTER,
		.phase = phase,
		.at = event.pos,
		.buttons = buttons,
		.modifiers = modifiers,
		// Which button this edge is about, for DOWN and UP. `MouseButton`'s own
		// order, which is the order `Cursor` already carries them in.
		.index = (usz)event.button.ordinal,
		.value = event.scroll,
		.wheel_x = event.scroll_x,
	};
}

fn void UiPainting.on_hover(&self, cui::Element* elem, bool entered) @dynamic
{
	if (!self.hoverable) return;
	ui_fire(elem, { .kind = UiEventKind.HOVER, .flag = entered });
}

<*
 A stack that hugs what is in it: `{ type: 'stack', wrap: true }`.

 cui's `Stack` fills, which is right for a scrim and for the root and wrong for a
 panel. A card with a background is a `Rectangle` behind a `Padding`, and a Stack
 that fills makes that card the size of the window — so what a script is left
 with is arithmetic: measure the line height, add up the rows, add the insets and
 write the total into the stack by hand. That total stops being true the moment a
 row is added, which is the kind of wrong that looks like a layout bug.

 So the LAST child is the content and everything before it is decoration. The
 content is measured against the space on offer, the decoration is then laid out
 TIGHT to what came back, and the element is the content's size. It is
 `DialogFrame`'s shape — cui builds its own panels this way — with the title bar
 left out.
*>
struct UiWrap (cui::Widget)
{
	// A fixed axis still wins; zero hugs the content child on that axis.
	Vec2 size;
}

<*
 Measures the content child and fits everything else to it.

 @param elem : `The element this widget is attached to.`
 @param constraints : `The size range offered by the parent.`
 @return `The content's size, with any fixed axis substituted in.`
*>
fn Vec2 UiWrap.layout(&self, cui::Element* elem, cui::Constraints constraints) @dynamic
{
	sz count = elem.children.len();
	if (count == 0) return constraints.constrain(self.size);

	// A fixed axis is what the content is OFFERED and not merely what this
	// element reports: measuring against the whole window and then shrinking
	// afterwards is how a slider in a 220-wide card comes out window-wide.
	// `Column` caps its children the same way and for the same reason.
	Vec2 room = {
		self.size.x > 0 ? math::min(self.size.x, constraints.max.x) : constraints.max.x,
		self.size.y > 0 ? math::min(self.size.y, constraints.max.y) : constraints.max.y,
	};

	Vec2 content = elem.layout_child(count - 1, cui::loose(room));
	Vec2 own     = constraints.constrain(
		{
			self.size.x > 0 ? self.size.x : content.x,
			self.size.y > 0 ? self.size.y : content.y,
		}
	);

	// Tight rather than loose: a background `Rectangle` fills what it is offered,
	// and what it must be offered is the panel rather than the window.
	for (sz i = 0; i < count - 1; i++) elem.layout_child(i, cui::tight(own));
	return own;
}

// ============================================================================
// The node IR
// ============================================================================

<*
 Every node type a snapshot may name.

 The first eight are layout and hold nothing but numbers; the next three paint;
 the six after those are the interactive built-ins, and the only thing they add
 is a function. The last four are cui's application widgets — a confirmation, a
 menu bar, a directory listing and a floating panel. `js/prelude/ui.js` maps the
 `type` string onto these and refuses anything else by name, so a typo is a
 message rather than a missing panel.

 Those four were once absent under the note that cui's application widgets "are
 not snapshot-shaped: their contents are function pointers cui evaluates rather
 than subtrees it holds". Of the three that hold no children it was never true:
 a `ConfirmDialog` is four strings and two callbacks, a `MenuBar` is `Select`'s
 options one level deeper, and a `FileBrowser` is a path and a list of patterns.

 Of `DIALOG` it *was* true, and it stopped being true when cui grew
 `Dialog.content` — an element the dialog BORROWS in place of the `ViewBuilder`
 it would otherwise call. The subtree that builder returns is released wholesale
 on close, which a snapshot cannot survive: cui would free elements this layer
 still keeps `UiNode` records for and hand the freed pointers back on the next
 open. A borrowed one is detached instead, kept whole with its widget state and
 its paint cache, and attached again unchanged. See `UiNode.content`.

 `AreaHost` is still absent. It is the same shape with the same answer, and it
 is item 9 rather than this one.

 Appended rather than inserted, and that is a rule rather than a preference:
 `js/prelude/ui.js`'s `KIND` table is these ordinals written out in JavaScript,
 and `bind_ui.c3` bounds-checks an incoming `k` against the last of them.
*>
enum UiNodeKind : char
{
	COLUMN,
	ROW,
	STACK,
	PADDING,
	GRID,
	CLIP,
	ANCHORED,
	SCROLL,
	RECT,
	LABEL,
	DRAW,
	BUTTON,
	CHECKBOX,
	SLIDER,
	SELECT,
	TREE,
	TEXTFIELD,
	CONFIRM_DIALOG,
	MENU,
	FILE_BROWSER,
	DIALOG,
}

<*
 Whether a kind takes the pointer on its own account.

 Everything else is decoration and gets `ignores_pointer` unless the snapshot
 said `solid`. The default is that way round because the interface is drawn over
 a scene somebody is looking at: a caption, a panel background and a health bar
 must not become dead zones, and the one that genuinely wants to block — a modal
 scrim — is rare enough to ask for it.

 `DRAW` is the one kind this cannot answer for, and it is not an omission: a
 painting takes the pointer when the SNAPSHOT attached a handler to it, which is
 a fact about a node rather than about a kind. `UiPainting.layout` decides it
 there, from the same three flags, and overwrites what this decided here.
*>
fn bool UiNodeKind.interactive(self)
{
	switch (self)
	{
		case SCROLL:
		case BUTTON:
		case CHECKBOX:
		case SLIDER:
		case SELECT:
		case TREE:
		case TEXTFIELD:
		case CONFIRM_DIALOG:
		case MENU:
		case FILE_BROWSER:
		case DIALOG:
			return true;
		default:
			return false;
	}
}

<*
 One node of a snapshot, as the binding hands it over.

 Flat and by value: every field is a number, an enum or a borrowed string, and
 the arrays a node needs — a Select's options, a Tree's rows, a painting's ops —
 arrive afterwards through `push_option` / `push_row` / `push_op`, because a
 widget borrows those and the list they live in must stop moving first.

 ## The `has_` flags

 A snapshot may leave a stateful field unsaid, and that is different from saying
 zero. `three.ui.set` rebuilds the tree, so a `TextField` whose text the snapshot
 does not name keeps what somebody typed into it and one that names an empty
 string is cleared. The five flags are the whole of that distinction; every other
 field is declarative and the snapshot always wins.
*>
struct UiNodeSpec
{
	UiNodeKind kind;
	// Borrowed for the call; `push_node` copies it. Empty for an unkeyed node.
	String key;

	// Layout
	float gap;
	float gap_y;
	Vec2 size;
	Vec2 cell;
	// Ordinals of cui::widgets::MainAlign and ::CrossAlign — `js/prelude/ui.js`
	// maps the names.
	uint main_align;
	uint cross_align;
	// {left, top, right, bottom}
	Vec4 insets;
	// {TL, TR, BR, BL}
	Vec4 radii;
	Vec2 margin;
	// Anchored's edges, as CrossAlign ordinals.
	uint anchor_h;
	uint anchor_v;
	// Blocks the pointer even though the kind is decoration — a modal scrim, or
	// a panel that must not let a drag through to the scene behind it.
	bool solid;
	// A `stack` that sizes to its last child instead of filling — see `UiWrap`.
	bool wrap;

	// A `dialog`'s two behaviours, and they belong to that one kind.
	//
	// `modal` makes the element itself the backdrop: it fills what it is
	// offered, dims it and swallows the presses that land on it.
	// `close_outside` is modal-only, and makes a press on that backdrop the
	// dismissal.
	//
	// **A `dialog` belongs in a `stack`**, and that is a rule rather than a
	// preference — see the DIALOG arm of `push_node` for the two reasons, both
	// of which are cui's rather than this file's.
	//
	// A modal inside the application's slot dims THE PANE and not the window, because
	// cui places and scrims a dialog against `Element.media` — the nearest
	// screen at or above it, which is the pane the application offered. That is the
	// right answer for a panel drawn inside an editor, and it is a fact about
	// cui rather than something to work around here.
	bool modal;
	bool close_outside;

	// Paint. The common theme rather than every field of every style struct:
	// a colour whose alpha is zero was not named, and the widget's own default
	// stands. `UI.md` §8.2 has the full field lists, and a style nobody can
	// reach from here is one more field on this struct rather than a redesign.
	Vec4 color;
	Vec4 border_color;
	float border_width;
	// The colour that says "on": checked, filled, selected, the handle.
	Vec4 accent;
	Vec4 hover_color;
	Vec4 press_color;
	Vec4 text_color;

	// Text
	String text;
	String suffix;
	// A `confirmDialog`'s heading and the words on its two answers — and, for a
	// `dialog`, the one line written across its bar. Fields of their own rather
	// than three more meanings for `text`, which is already the question being
	// asked: all four strings are present at once, and a snapshot that had to
	// spell three of them positionally would be unreadable.
	String title;
	String confirm_label;
	String decline_label;
	uint font;
	float text_size;

	// Values
	float value;
	float min;
	float max;
	float step;
	float curve;
	float offset;
	uint decimals;
	bool checked;
	bool disabled;
	usz selected;

	// A `fileBrowser`'s confinement, and the only field on this struct that is a
	// policy rather than a description. `root` is the absolute directory it opens
	// under and may not climb out of; `scheme` is the prefix its paths are
	// written back to JavaScript with. `js/bind_ui.c3` decides both — it is the
	// file that knows what an assets directory is — and `ui_file_directory`
	// enforces them, because cui's `FileBrowser` has no notion of a root and this
	// binding does not change cui to give it one.
	//
	// An empty `root` is no confinement, which is not an oversight: it is the
	// same answer `JsRuntime.resolve_asset` gives a process with no assets
	// directory, where confining to nothing would refuse every path there is.
	String root;
	String scheme;

	// Which of the five stateful fields the snapshot actually named.
	bool has_text;
	bool has_value;
	bool has_checked;
	bool has_selected;
	bool has_offset;

	// Which callbacks the script attached. The widget gets a function pointer
	// only for the ones it did — an unhandled slider is a readout, and cui skips
	// the call rather than the binding refusing it.
	bool on_click;
	bool on_change;
	bool on_commit;
	bool on_submit;
	bool on_select;
	bool on_toggle;
	bool on_hover;
	bool on_confirm;
	bool on_dismiss;
	bool on_choose;
	bool on_pointer;
}

<*
 What a widget did, on its way out to whoever is listening.

 One struct for every kind rather than one per callback, because the far side is
 a table lookup either way and a script's handler signature is decided by the
 node type it attached to, not by this.
*>
enum UiEventKind : char
{
	CLICK,
	HOVER,
	TOGGLE,
	SLIDE,
	COMMIT,
	PICK,
	ROW_SELECT,
	ROW_TOGGLE,
	TEXT_CHANGE,
	TEXT_SUBMIT,
	CONFIRM,
	DISMISS,
	MENU_PICK,
	FILE_CHOOSE,
	FILE_SELECT,
	FILE_DIRECTORY,
	POINTER,
	// A `dialog` the USER put away — the close glyph, ESC, or a press on the
	// backdrop of one that closes outside. Not the script's own
	// `patch({ open: false })`, which is a thing the script already knows about;
	// see `ui_dialog_close`.
	DIALOG_DISMISS,
}

<*
 Which edge of the pointer a POINTER event is.

 Four rather than one flag apiece, because a script switches on this once and a
 panel that had to work out "a press this frame that was not a press last frame"
 is a panel reimplementing the edge detection cui already did.
*>
enum UiPointerPhase : char
{
	MOVE,
	DOWN,
	UP,
	WHEEL,
}

struct UiEvent
{
	UiEventKind kind;
	// TOGGLE's new state, HOVER's entered/left.
	bool flag;
	// SLIDE and COMMIT, and POINTER's vertical wheel delta.
	float value;
	// POINTER's horizontal wheel delta. A field of its own rather than a second
	// meaning for something: a trackpad sends both at once, and a timeline that
	// pans on one axis and zooms on the other needs to tell them apart.
	float wheel_x;
	// POINTER, in the node's OWN coordinates — see `ui_pointer_event`.
	Vec2 at;
	// POINTER's phase, and the only field that says which edge this is.
	UiPointerPhase phase;
	// POINTER: which buttons are held, as bits in `cui::MouseButton` order —
	// 1 left, 2 right, 4 middle. The state during the event, so a drag is one
	// test rather than a flag the script has to keep itself.
	uint buttons;
	// POINTER: shift, ctrl, alt, super, as bits in that order.
	uint modifiers;
	// PICK, ROW_SELECT and ROW_TOGGLE. MENU_PICK's is which title on the bar,
	// and POINTER's is which button a DOWN or an UP is about.
	usz index;
	// MENU_PICK's entry under that title, and the only event with two ordinals.
	// A bar is a list of lists, and a flat item number would make a script that
	// wanted to know what was clicked count the length of every menu before it —
	// which is a thing it would then have to keep in step with its own data.
	usz item;
	// TEXT_CHANGE, TEXT_SUBMIT and the three FILE_ events. Borrowed for the call
	// only — it is the widget's own buffer and the next keystroke rewrites it,
	// or a temporary that the frame's pool takes back.
	String text;
}

<*
 Where an event goes. `js/bind_ui.c3` installs one; a layer with none drops
 every callback, which is what the tests without a script want.
*>
alias UiListener = fn void(void* host, uint node, UiEvent event);

<*
 One live node: its element, its key, and everything the widget borrows.

 The strings are `DString` rather than a shared arena because a `DString` in C3
 is a pointer to the block — so a `List{DString}` can grow without moving what a
 widget is pointing at, and a `patch` can rewrite one label without touching the
 rest. An arena would have to be rebuilt on every patch or leak on every frame.
*>
struct UiNode
{
	UiNodeKind kind;
	cui::Element* element;
	DString key;
	// The widget's own strings — a label, a placeholder, a suffix. They live as
	// long as the node.
	List{DString} owned;
	// The strings the three arrays below borrow, kept apart from `owned` because
	// a `patch` that replaces a list must free exactly those and not the label
	// the widget is still holding.
	List{DString} listed;
	// The one string `patch` writes, reused rather than appended to `owned`. A
	// HUD patches its readout every frame, and a copy per patch would be a leak
	// that only shows up after an hour of play.
	DString patched;
	// Views into `listed`, re-pointed at the widget by `repoint`.
	List{String} options;
	List{cui::widgets::TreeRow} rows;
	List{UiOp} ops;
	// A `menu`'s two levels. The bar borrows `menus`, and each `Menu` in it
	// borrows a run of `items` — one list for every dropdown rather than a list
	// per menu, because a `Menu[]` has to be contiguous and a list of lists would
	// be a second allocation per title that `drop_list` would then have to walk.
	// Which run belongs to which title is carried in `Menu.items.len` while the
	// pushes are happening; `repoint` is where the pointers are filled in.
	List{cui::widgets::Menu} menus;
	List{cui::widgets::MenuItem} items;

	// A `fileBrowser`'s confinement, copied off the spec and pointing into
	// `owned` — the directory it may not climb out of and the prefix its paths
	// are written back with. Empty on every other kind.
	String root;
	String scheme;

	// A `dialog`'s body: the element its children hang from, built by this layer
	// and BORROWED by cui through `Dialog.content`. Null on every other kind.
	//
	// It exists because a `Dialog` is the one kind here whose contents cui would
	// otherwise own. Closing the panel detaches this element rather than
	// releasing it and re-opening attaches the same one, so every `UiNode.element`
	// underneath a dialog stays valid across a close — and with it the text in a
	// field, the offset of a list and the paint cache of everything in between.
	//
	// cui never frees it; `release_borrowed` does, and it has to run after the
	// subtree holding it has gone. `Ui.release` reaching a borrowed child through
	// its parent detaches it and `Ui.release` called ON it frees it — one
	// function told apart by which side of the recursion it is on, which is
	// exactly how the owner gives a borrowed element back.
	cui::Element* content;
}

fn void UiNode.free(&self)
{
	foreach (str : self.owned) str.free();
	self.owned.free();
	if (self.patched) self.patched.free();
	self.drop_list();
	self.listed.free();
	self.options.free();
	self.rows.free();
	self.ops.free();
	self.menus.free();
	self.items.free();
	if (self.key) self.key.free();
	*self = { };
}

<*
 Empties the arrays and the strings only they were holding.

 What a `patch` that replaces a draw list, a set of options or a set of rows does
 first. The widget's own label is in `owned` and survives, which is the whole
 reason the two lists are separate.
*>
fn void UiNode.drop_list(&self)
{
	foreach (str : self.listed) str.free();
	self.listed.clear();
	self.options.clear();
	self.rows.clear();
	self.ops.clear();
	self.menus.clear();
	self.items.clear();
}

<*
 Copies a string into the node and answers with a view that outlives the frame.

 Every string a cui widget holds is borrowed and must outlive the element, and
 everything reaching this file came from a QuickJS value, a temp format or a
 stack buffer. One copy here is the whole of that rule.
*>
fn String UiNode.keep(&self, String text)
{
	DString held;
	held.init(mem, text.len);
	held.append(text);
	self.owned.push(held);
	return held.str_view();
}

<*
 The same copy, for a string one of the node's arrays borrows. Freed by
 `drop_list` rather than living as long as the node.
*>
fn String UiNode.keep_listed(&self, String text)
{
	DString held;
	held.init(mem, text.len);
	held.append(text);
	self.listed.push(held);
	return held.str_view();
}

// ============================================================================
// The layer
// ============================================================================

<*
 The UI, the pass that draws it, and the answer to "did the interface take that
 click".

 Hangs off `Renderer` beside `post`, and like `post` it is inert until something
 uses it — see `active`. Its address is given to cui through `Ui.provide`, so it
 must not move while the interface is up; `Renderer` is already addressed by
 pointer everywhere for the MCP server's sake, which is what makes that true.
*>
struct UiLayer
{
	// Null until `ensure`. The whole of "is there an interface" — there is no
	// second enabled flag that could disagree with it.
	cui::Ui* ui;
	cui::vulkan::CanvasPass pass;
	cui::FontId font;

	// The lower floor of the fixed root: where a script's snapshot is grafted.
	// Never released, so `set_tree` is one unmount and one append rather than a
	// rebuild of everything including the debug line.
	cui::Element* content;

	// The one-line overlay: `three.debug.overlay` in pixels rather than in the
	// run's `debug` array. Owned here rather than built as a value widget,
	// because a `Label` borrows its string and this is the thing that keeps it
	// alive — see `set_overlay`.
	cui::widgets::Label overlay;
	DString overlay_text;
	// The label's own element, kept because invalidation is per element: cui
	// caches each element's paint output, so marking the root dirty relayouts
	// the tree and leaves the old glyphs exactly where they were.
	cui::Element* overlay_element;
	// Whether anything set the line since the last `expire_overlay`. What makes
	// the overlay *this frame's* — see there.
	bool overlay_fresh;

	// The live snapshot: one record per node, in the order they were pushed, and
	// the element the whole thing hangs from.
	List{UiNode} nodes;
	cui::Element* tree;

	// The application's tree, grafted onto the same floor. Separate from `tree`
	// because the two have different owners: this one has no `UiNode` records
	// behind it and nothing here built it. Only one of the two is mounted at a
	// time — see `set_root` — unless there is a `slot`, which is the
	// arrangement where they compose instead.
	cui::Element* foreign;

	// Where a script's snapshot is grafted when the application has offered a place for
	// it *inside* its own layout. Null is the original arrangement: the snapshot
	// hangs from `content` and whichever of the two wrote last holds the floor.
	// See `set_slot`.
	cui::Element* slot;
	// Bumped whenever the offer is made or withdrawn. A slot going away takes
	// the snapshot with it, so a script reads this through `three.ui.slot` and
	// re-`set`s when the number moves — there is no callback, because a panel
	// that redraws itself from a frame system already has the one loop it needs.
	uint slot_generation;

	// The snapshot being built, between `begin_tree` and `commit_tree`. Separate
	// from the live one so a tree that fails halfway leaves the interface exactly
	// as it was — a panel that half-disappeared because a colour was malformed is
	// worse than one that did not change.
	List{UiNode} building;
	cui::Element* pending;
	bool open;
	// Which node of the build had the keyboard before it, or -1. Focus is the one
	// piece of interactivity a rebuild would silently drop: `Ui.release` hands it
	// to the parent, so typing would stop dead on the first `set` a HUD made.
	int pending_focus;

	// Where a widget's callback goes. Null is a perfectly good answer — the
	// tests build trees with no script behind them.
	UiListener listener;
	void* host;
	// True only while `process_input` is on the stack. A handler that calls
	// `three.ui.set` would otherwise restructure the tree cui is mid-dispatch on,
	// which is the one thing cui's own docs say a handler must not do.
	bool dispatching;

	// True only while `patch` is closing a `dialog`. `Dialog.set_open` runs
	// `on_close` for every dismissal — cui's own wording is "whoever asked for
	// the close" — and a script that has just written `open: false` does not
	// need to be told that the panel it closed is closed. cui guards
	// `ConfirmDialog.withdraw` the same way with its `answering` flag; `Dialog`
	// has no such guard, so the guard lives here. See `ui_dialog_close`.
	bool closing_dialog;

	// Whether the interface took this frame's pointer and keyboard. Recomputed
	// by `feed`, read by the window loop — the click that presses a button must
	// not also orbit the camera or reach a script.
	bool wants_pointer;
	bool wants_keys;

	// Held keys, rebuilt each `feed` from the window's bitset. A field so the
	// list's storage is reused instead of reallocated sixty times a second.
	List{cui::Key} held;
}

<*
 Whether there is an interface at all.

 The one question `record_scene` asks. False costs nothing: no upload, no
 rendering, no draw.
*>
fn bool UiLayer.active(&self) => self.ui != null;

<*
 Brings the layer up, once.

 @param gpu : `Borrowed by the pass — device, allocator and queue. Must outlive the layer, which it does: both are fields of Renderer.`
 @param target : `The interface's coordinate space. A Cursor already arrives in these pixels, so nothing converts.`
*>
fn void? UiLayer.ensure(&self, Gpu* gpu, Target* target)
{
	if (self.ui != null) return;

	Vec2 size = { (float)target.extent.width, (float)target.extent.height };

	self.ui = cui::new_ui(size);
	// From here on a failure has to take the Ui down with it, or the next
	// `ensure` finds a half-built layer and returns happily.
	defer catch
	{
		self.ui.free();
		self.ui = null;
	}

	// The heap by name. A zeroed `DString` or `List` takes the *temp* allocator
	// on its first write, and all of these are written from a script callback
	// that runs inside a `@pool()` — the string a widget borrows would then point
	// into memory the frame gave back. `init(mem, 0)` names the allocator and
	// allocates nothing.
	self.overlay_text.init(mem, 0);
	self.held.init(mem, 0);
	self.nodes.init(mem, 0);
	self.building.init(mem, 0);

	self.font = self.ui.load_font_bytes(UI_FONT[..])!;

	// FORMAT_UNDEFINED because `begin_overlay` gives the rendering no depth
	// attachment: cui never tests or writes depth, and the pass is compiled
	// against the attachments it will be recorded into.
	self.pass = cui::vulkan::new_canvas_pass(
		gpu.handle,
		&gpu.allocator,
		gpu.graphics,
		target.color_format,
		FORMAT_UNDEFINED,
		size
	)!;

	// Reachable by type from every widget hook in the tree, which is how a
	// Button's callback finds its way back here — cui has no app type to name,
	// and this is its answer to that.
	self.ui.provide(self);

	// An empty label pinned to the top-left. It measures to nothing and paints
	// nothing until `set_overlay` gives it a string, so bringing the layer up
	// does not put a mark on the frame.
	self.overlay = { .font = self.font, .size = 16.0, .color = cui::WHITE };
	self.overlay_element = self.ui.@node(&self.overlay);

	self.content = self.ui.@node((cui::widgets::Stack){ });
	// Both floors are transparent: a full-frame container that took the pointer
	// would win every hit test in the window and make the scene unclickable.
	self.content.ignores_pointer = true;

	cui::Element* root = self.ui.@node(
		(cui::widgets::Stack){ },
		self.content,
		self.ui.@node(
			(cui::widgets::Anchored){
				.h = cui::widgets::CrossAlign.START,
				.v = cui::widgets::CrossAlign.START,
				.margin = { 12, 12 },
			},
			self.overlay_element
		)
	);
	root.ignores_pointer = true;
	self.ui.build(root);
}

fn void UiLayer.free(&self)
{
	if (self.ui == null) return;
	self.pass.free();
	// The dialog bodies first, and this is not tidiness. `Ui.free` releases from
	// the root and then frees the element ALLOCATIONS, and a borrowed child is
	// detached by that walk rather than recycled — so a body still hanging in an
	// open panel would have its widgets, its children list and its paint cache
	// freed by nobody. Handing them back here is the same handover `drop_tree`
	// makes, and the last one this layer gets to make.
	self.release_borrowed(&self.nodes);
	self.release_borrowed(&self.building);
	self.ui.free();
	self.ui = null;
	// Freed with every other element by `Ui.free` above, whichever image built it.
	self.foreign = null;
	self.slot = null;
	self.overlay_text.free();
	self.held.free();
	foreach (i, node : self.nodes) self.nodes[i].free();
	self.nodes.free();
	foreach (i, node : self.building) self.building[i].free();
	self.building.free();
	self.tree = null;
	self.pending = null;
	self.content = null;
	self.open = false;
}

<*
 Points the layer at whoever wants to hear about clicks.

 A function pointer rather than a field of a known type, so this file stays free
 of `JsRuntime` and a test can listen without a JavaScript context.

 @param listener : `Called from inside feed. Null unbinds.`
 @param host : `Handed back to the listener untouched.`
*>
fn void UiLayer.on_event(&self, UiListener listener, void* host)
{
	self.listener = listener;
	self.host = host;
}

// ============================================================================
// The one-line overlay
// ============================================================================

<*
 One line over the frame, replaced whenever it changes.

 The string is copied. A `cui::widgets::Label` borrows its text and must outlive the
 element, and the caller's is a QuickJS string, a temp-allocated format or a
 stack buffer — so this owns the only copy the widget ever sees, and re-points
 the widget at it because a `DString` moves when it grows.

 Empty text on a layer nothing has brought up stays inert: a run that never asks
 for an overlay never pays for one.

 @param gpu : `Only used to bring the layer up on the first non-empty line.`
*>
fn void? UiLayer.set_overlay(&self, Gpu* gpu, Target* target, String text)
{
	if (self.ui == null)
	{
		if (text.len == 0) return;
		self.ensure(gpu, target)!;
	}

	self.overlay_fresh = true;
	if (self.overlay_text.str_view() == text) return;

	self.overlay_text.clear();
	self.overlay_text.append(text);
	self.overlay.text = self.overlay_text.str_view();

	// On the label, not on the root. The text decides the label's size, so this
	// is a relayout rather than a repaint — and `request_layout` marks the
	// ancestors on its way up, which is the half that makes it correct to ask the
	// child rather than the parent.
	self.overlay_element.request_layout();
}

<*
 Drops the line unless the frame that just ran set it again.

 `three.debug.overlay` is documented as *one line, this frame, gone the next*,
 and a retained tree keeps whatever it was last given — so something has to take
 it away. Called at the top of the script frame in `js/frame_loop.c3`: a line set
 during the previous frame is still standing when this runs and survives, and one
 set two frames ago does not.

 Cheap to call every frame and cheap to feed every frame: a script writing the
 same string sixty times a second re-points nothing and invalidates nothing,
 because `set_overlay` compares before it copies.
*>
fn void UiLayer.expire_overlay(&self)
{
	if (self.ui == null) return;

	if (!self.overlay_fresh && self.overlay_text.len() > 0)
	{
		self.overlay_text.clear();
		self.overlay.text = "";
		self.overlay_element.request_layout();
	}
	self.overlay_fresh = false;
}

// ============================================================================
// The snapshot
// ============================================================================

<*
 Opens a build. Everything pushed until `commit_tree` goes into a tree nothing
 is looking at yet.

 Re-entrant only in the sense that it forgives a caller who abandoned the last
 one: an open build is discarded rather than being an error, because the
 alternative is a binding that can wedge the interface by throwing halfway
 through a tree.
*>
fn void? UiLayer.begin_tree(&self, Gpu* gpu, Target* target)
{
	self.ensure(gpu, target)!;
	if (self.open) self.abandon_tree();
	self.open = true;
	self.pending = null;
	self.pending_focus = -1;
}

<*
 Throws the half-built tree away and leaves the live one alone.

 The elements built so far are released back to the free-list; the *live* nodes
 were never touched, because a build only ever reads them.
*>
fn void UiLayer.abandon_tree(&self)
{
	if (self.ui == null) return;
	if (self.pending) self.ui.release(self.pending);
	// After the tree, never before: a dialog that reached a build has its body
	// hanging inside the subtree above, and releasing it first would leave the
	// panel holding a recycled element.
	self.release_borrowed(&self.building);
	foreach (i, node : self.building) self.building[i].free();
	self.building.clear();
	self.pending = null;
	self.open = false;
	self.pending_focus = -1;
}

<*
 Swaps the built tree in for the live one.

 The order is the whole of it: the old subtree is unmounted *first*, so its
 elements are back on the free-list before the new one is grafted and the two
 never coexist; then the array views every widget borrows are re-pointed, now
 that the lists behind them have stopped growing; then the keyboard is put back
 where it was.
*>
fn void UiLayer.commit_tree(&self)
{
	if (!self.open) return;
	self.open = false;

	// A slot that went away since the last `set` — its pane was closed, or its
	// tab switched, and the application did not withdraw. Falling back to the floor is
	// the pre-slot arrangement rather than a panel that quietly fails to appear.
	if (self.slot && !self.attached(self.slot))
	{
		self.slot = null;
		self.slot_generation++;
	}

	// The application's tree loses the floor to a script's, by the same last-writer rule
	// `set_root` states from the other side. With a slot they compose
	// instead: the application keeps the floor and the snapshot lands inside it.
	if (self.slot == null) self.drop_foreign();

	// Conditional because in a slot the old snapshot can be gone already,
	// recycled with the application's subtree that held it — see `drop_tree`.
	if (self.tree && self.attached(self.tree)) self.ui.unmount(self.tree);
	self.tree = self.pending;
	self.pending = null;

	// The bodies the outgoing dialogs borrowed, now that the tree that held them
	// has been unmounted and cui has detached rather than freed them.
	self.release_borrowed(&self.nodes);
	foreach (i, node : self.nodes) self.nodes[i].free();
	self.nodes.clear();
	foreach (node : self.building) self.nodes.push(node);
	self.building.clear();

	self.repoint();

	if (self.tree) (self.slot ? self.slot : self.content).append(self.tree);
	if (self.pending_focus >= 0 && (sz)self.pending_focus < self.nodes.len())
	{
		self.nodes[self.pending_focus].element.request_focus();
	}
	self.pending_focus = -1;
	self.ui.request_frame();
}

<*
 Hands every widget the array it borrows.

 Deferred to here because a `List` moves its storage when it grows, and a
 `Select` handed `options.array_view()` halfway through the pushes would be
 pointing at a freed block by the last one. This is the single moment the lists
 are known to be finished.
*>
fn void UiLayer.repoint(&self)
{
	foreach (i, node : self.nodes) repoint_node(&self.nodes[i]);
}

fn void repoint_node(UiNode* node) @local
{
	if (node.element == null) return;
	switch (node.kind)
	{
		case SELECT:
			node.element.widget_as(cui::widgets::Select).options = node.options.array_view();
		case TREE:
			node.element.widget_as(cui::widgets::Tree).rows = node.rows.array_view();
		case DRAW:
			node.element.widget_as(UiPainting).ops = node.ops.array_view();
		case MENU:
			// Two levels, and the inner one first: each `Menu` was given a slice
			// whose length is right and whose pointer was into a block the next
			// push may have freed. The runs are contiguous and in push order, so
			// walking a cursor along them recovers where each one starts without
			// storing it.
			usz at = 0;
			foreach (i, menu : node.menus)
			{
				usz count = menu.items.len;
				node.menus[i].items = node.items.array_view()[at : count];
				at += count;
			}
			node.element.widget_as(cui::widgets::MenuBar).menus = node.menus.array_view();
		case FILE_BROWSER:
			node.element.widget_as(cui::widgets::FileBrowser).mask = node.options.array_view();
		default:
			break;
	}
}

<*
 The node an index names, in whichever table is the live one.

 A build in progress owns the indices `push_node` handed out; with none open the
 indices are the committed tree's, which is what a `patch` addresses. One
 accessor rather than two sets of functions, because the alternative is
 `push_option` and `add_option` differing by a single field lookup.
*>
fn UiNode* UiLayer.at(&self, uint node)
{
	if (self.open) return (sz)node < self.building.len() ? &self.building[node] : null;
	return (sz)node < self.nodes.len() ? &self.nodes[node] : null;
}

<*
 Clears the script's half of the interface, leaving the debug line alone.
*>
fn void UiLayer.clear_tree(&self)
{
	if (self.ui == null) return;
	if (self.open) self.abandon_tree();
	self.drop_tree();
}

<*
 Takes the snapshot down, releasing it only if it is still in a tree.

 On `content` the check never fails and this is the plain unmount it has always
 been: the layer put the snapshot there and nothing else can take it away. In a
 slot it can be gone already — cui releases a subtree children-first, so a pane
 that rebuilt recycled the snapshot before the application's own widget was told, and
 unmounting it a second time would corrupt the free-list.

 Reading a released element is defined rather than lucky: cui zeroes it and keeps
 the allocation on `all_elements`, so an orphan answers `parent == null` and the
 walk stops there. It cannot have been handed out again either, because cui only
 allocates elements in the build pass and a widget's `unmount` fires in the
 release that runs immediately before it.
*>
fn void UiLayer.drop_tree(&self)
{
	if (self.tree)
	{
		if (self.attached(self.tree)) self.ui.unmount(self.tree);
		self.tree = null;
	}
	self.release_borrowed(&self.nodes);
	foreach (i, node : self.nodes) self.nodes[i].free();
	self.nodes.clear();
	self.ui.request_frame();
}

<*
 Hands cui back every body a `dialog` in this table borrowed.

 The counterpart of `Dialog.content`, and the whole of this layer's half of the
 borrowing contract: cui detaches a borrowed child and never frees one, so the
 element goes back to the free-list here or it does not go back at all.

 It has to run AFTER whatever was holding the body has been released — and it is
 safe either way round for a dialog that never opened, whose body has no parent
 at all. `Ui.release` on a borrowed element frees it like any other; only the
 recursion through a parent is filtered.

 @param table : `The live nodes or the half-built ones, whichever is going away.`
*>
fn void UiLayer.release_borrowed(&self, List{UiNode}* table)
{
	if (self.ui == null) return;
	for (sz i = 0; i < table.len(); i++)
	{
		cui::Element* body = (*table)[i].content;
		if (body == null) continue;
		self.ui.release(body);
		(*table)[i].content = null;
	}
}

<*
 Takes the application's tree off the floor, releasing it only if it is still on one.

 Conditional for the same reason `drop_tree` is, and against a narrower mistake:
 an application that released its own root without saying so. That was always a
 contract violation and is not one this can repair — the pointer is gone either
 way — but unmounting a recycled element would corrupt cui's free-list, and
 forgetting it merely loses a tree that is already lost.
*>
fn void UiLayer.drop_foreign(&self)
{
	if (self.foreign == null) return;
	if (self.attached(self.foreign)) self.ui.unmount(self.foreign);
	self.foreign = null;
}

// Whether an element still hangs from this Ui at all. Linear in the depth of the
// tree and asked once per `set`, not per frame.
fn bool UiLayer.attached(&self, cui::Element* element)
{
	for (cui::Element* walk = element; walk != null; walk = walk.parent)
	{
		if (walk == self.ui.root) return true;
	}
	return false;
}

<*
 The `cui::Ui` an application builds its own interface into.

 The one verb that hands the caller something of cui's rather than a value of
 this project's: `UiNodeSpec` exists so `js/bind_ui.c3` never names a cui type,
 and an application linked against the same cui has no such problem.

 This was a `void*` for as long as three loaded applications as native plugins,
 because `plugin/abi.c3` was compiled into images that had no cui at all and the
 far side had to cast it back. Nothing is compiled twice any more, so the type
 is the type.

 Brings the layer up on the first call, so an application that wants an interface
 pays for one and one that does not never allocates a buffer.

 @return `The Ui, or null if the layer could not be brought up.`
*>
fn cui::Ui* UiLayer.context(&self, Gpu* gpu, Target* target)
{
	if (catch self.ensure(gpu, target)) return null;
	return self.ui;
}

<*
 Grafts the application's widget tree onto the content floor.

 The script's snapshot and the application's tree are exclusive rather than
 composited: both would claim the same floor and the same pointer, and a HUD
 half-owned by two writers is a question with no good answer. Whichever set last
 is the one mounted, and the debug overlay is above both either way. `set_slot`
 is the one way to have both, and says how.

 `root` is built with the Ui `context` answered. Nothing here takes ownership of
 the widgets behind it — cui already owns every element it built, and unmounting
 returns them to its free-list.

 @param root : `The tree to mount, or null to clear.`
*>
fn void UiLayer.set_root(&self, cui::Element* root)
{
	if (self.ui == null) return;

	// The slot is an element of the tree being replaced, so it goes with it. It
	// goes *first* and by hand rather than through `set_slot`, so that the
	// snapshot below is released while it is still attached to something — this
	// is the withdrawal an application that rebuilds wholesale does not have to
	// make.
	if (self.slot)
	{
		self.slot = null;
		self.slot_generation++;
	}

	// The script's half goes first, and completely: `clear_tree` also drops the
	// `UiNode` records, so a later `three.ui.patch` faults on a missing key
	// rather than editing a tree that is no longer on screen.
	if (self.tree) self.clear_tree();

	self.drop_foreign();

	self.foreign = root;
	if (self.foreign) self.content.append(self.foreign);
	self.ui.request_frame();
}

<*
 Offers a place inside the application's own layout for a script's snapshot, or
 withdraws it.

 The one verb that gets past the last-writer rule above. Without it an application and
 a script are two writers arguing over one floor, so an editor written natively
 can host no scripted panel at all and every `three.ui.set` under it blanks the
 application. With it the two compose: the application keeps the floor, names an
 element of its tree, and a snapshot lands there — laid out by the pane that
 holds it, clipped by it, hit-tested in its order.

 `element` is a `cui::Element*` built with the Ui `context` answered, already in
 the mounted tree. Nothing here takes ownership of it: cui owns every element it
 built, which is the same rule and the same reason as `set_root`.

 ## What the application owes

 One thing: withdraw before the element goes. cui releases a subtree
 children-first, so a widget's own `unmount` fires *after* the snapshot beneath
 it has been recycled — too late to release it properly, though `drop_tree`
 makes it safe. `set_root` withdraws on the application's behalf, which covers
 a rebuild of the whole tree; a pane that comes and goes has to say so itself.

 ## One slot, and the snapshot does not survive it

 One, because the layer keeps exactly one `nodes` table and one `tree`, and a
 second mount point would mean a second of each along with a way for `set` to
 say which it meant. It is the change to make when an application wants two panels,
 and not before.

 Withdrawing clears the snapshot rather than moving it back to the floor: cui has
 no detach that keeps an element alive, so a move is a rebuild either way. The
 script is told by `slot_generation` and re-`set`s — a pane switched away from
 and back is a different element, and its panel is drawn again.

 @param element : `The mount point, or null to withdraw.`
*>
fn void UiLayer.set_slot(&self, void* element)
{
	if (self.ui == null) return;

	cui::Element* offered = (cui::Element*)element;
	if (offered == self.slot) return;

	// Either way the snapshot goes: into a slot it would have to be moved, out of
	// one it is already gone. One rule instead of two, and the generation is what
	// tells the script to draw it again.
	self.drop_tree();
	self.slot = offered;
	self.slot_generation++;
	self.ui.request_frame();
}

<*
 How big the offered mount point came out, in logical points.

 What a script needs to fit a panel to a pane it did not lay out. Zero until the
 element has been through a layout pass, which is one frame after the application
 built it.
*>
fn Vec2 UiLayer.slot_size(&self)
{
	if (self.slot == null) return { 0, 0 };
	return self.slot.size;
}

<*
 Where the offered mount point sits, in the same logical points `slot_size` is in.

 The reason it is reported at all is `three.input.pointer`, which is the window's
 and knows nothing about panes: a script drawing its own controls with
 `three.ui.draw` has to subtract this to hit-test them. Widgets in a snapshot
 never need it — they are laid out by cui and hit-tested by cui.

 cui's `absolute` and so written by the *emit* pass rather than by layout: zero
 until the element has been painted once, which is the same one-frame caveat
 `slot_size` carries and for the same reason.
*>
fn Vec2 UiLayer.slot_origin(&self)
{
	if (self.slot == null) return { 0, 0 };
	return self.slot.absolute;
}

<*
 The live node a key names, or null.

 Linear, and deliberately: a snapshot is tens of nodes, the scan runs on a
 `patch` or a click rather than per frame, and an index would be one more thing
 to keep in step with a rebuild.
*>
fn UiNode* UiLayer.find(&self, String key)
{
	if (key.len == 0) return null;
	foreach (i, node : self.nodes)
	{
		if (node.key && node.key.str_view() == key) return &self.nodes[i];
	}
	return null;
}

<*
 The live node a key names, if it is also the right kind.

 The kind has to match for a carry-over to be sound: a `slider` renamed into a
 `checkbox` under the same key is a different control, and handing it the old
 one's value would be a number appearing in a tick box.
*>
fn UiNode* UiLayer.carry(&self, String key, UiNodeKind kind)
{
	UiNode* found = self.find(key);
	if (found == null || found.kind != kind) return null;
	return found;
}

// The palette the built-in widgets already use, named here because a snapshot
// that styles one field of a control must not lose the other ten to a zeroed
// struct — cui's style structs are all-or-nothing and `resolved()` is what makes
// them so. Starting from these and overriding what the snapshot named is what
// gives a script partial styling at all.
const cui::Color UI_SURFACE = { 0.20, 0.22, 0.28, 1.0 };
const cui::Color UI_HOVER   = { 0.28, 0.31, 0.40, 1.0 };
const cui::Color UI_ACCENT  = { 0.95, 0.60, 0.20, 1.0 };
const cui::Color UI_TEXT    = { 0.92, 0.93, 0.95, 1.0 };

// A colour is "named" when its alpha is above zero. Fully transparent is not a
// colour anybody draws with, and it saves a `has_` flag per colour on a struct
// that already has five.
fn cui::Color ui_color(Vec4 color, cui::Color fallback) @local
{
	return color.w > 0 ? (cui::Color)color : fallback;
}

<*
 Adds one node to the build, under `parent`.

 Pre-order: a parent is pushed before its children and answers with the index
 they name. Elements are created detached and grafted at `commit_tree`, so a
 build that fails halfway has changed nothing anybody can see.

 @param spec : `The node. Strings on it are borrowed for the call and copied here.`
 @param parent : `The index this node hangs under, or -1 for the tree's own root.`
 @return `The index of the new node, for its children to name.`
 @return? UI_NO_TREE : `No build is open — begin_tree first.`
 @return? UI_BAD_PARENT : `The parent index names no node in this build, or a second root was pushed.`
*>
fn uint? UiLayer.push_node(&self, UiNodeSpec spec, int parent)
{
	if (!self.open) return UI_NO_TREE~;
	if (parent >= 0 && (sz)parent >= self.building.len()) return UI_BAD_PARENT~;
	if (parent < 0 && self.pending != null) return UI_BAD_PARENT~;

	uint index = (uint)self.building.len();

	// What a rebuild would otherwise destroy, taken off the live node with the
	// same key and kind. Only the fields the snapshot left unsaid: a script that
	// writes `value: 0.5` means it, and one that omits it means "leave what the
	// drag left there".
	String carried;
	String browsing;
	UiNode* prior = self.carry(spec.key, spec.kind);
	bool keep_open;
	Vec2 dragged_to;
	bool dragged;
	if (prior != null && prior.element != null)
	{
		switch (spec.kind)
		{
			case SLIDER:
				if (!spec.has_value) spec.value = prior.element.widget_as(cui::widgets::Slider).value;
			case CHECKBOX:
				if (!spec.has_checked) spec.checked = prior.element.widget_as(cui::widgets::Checkbox).checked;
			case SCROLL:
				if (!spec.has_offset) spec.offset = prior.element.widget_as(cui::widgets::Scroll).scroll_offset;
			case SELECT:
				cui::widgets::Select* was = prior.element.widget_as(cui::widgets::Select);
				if (!spec.has_selected) spec.selected = was.selected;
				keep_open = was.open;
			case TREE:
				if (!spec.has_selected) spec.selected = prior.element.widget_as(cui::widgets::Tree).selected;
			case TEXTFIELD:
				if (!spec.has_text) carried = prior.element.widget_as(cui::widgets::TextField).value();
			case CONFIRM_DIALOG:
				// Whether a question is up is the one thing about a confirmation
				// the user decides, so it carries like a scroll offset does: a
				// snapshot that names `open` means it, and one that does not
				// leaves the answer the user has not given yet on screen.
				if (!spec.has_checked)
				{
					spec.checked = prior.element
						.widget_as(cui::widgets::ConfirmDialog)
						.asking(prior.element);
				}
			case FILE_BROWSER:
				// Where the user has walked to, which is the browser's whole
				// state: without this, a panel that re-renders for any other
				// reason snaps the listing back to wherever it opened.
				browsing = prior.element.widget_as(cui::widgets::FileBrowser).directory.str_view();
			case DIALOG:
				cui::widgets::Dialog* shown = prior.element.widget_as(cui::widgets::Dialog);
				// Whether the panel is up, carried for the reason a
				// confirmation's is: a re-render provoked by something else
				// entirely must not close a dialog the snapshot said nothing
				// about, and the user is the one who decides it is finished with.
				if (!spec.has_checked) spec.checked = shown.open;
				// And where it was dragged to. There is no snapshot field for a
				// dialog's position — cui centres it until somebody moves it —
				// so this can contradict nothing the script said, and without it
				// every rebuild snaps a moved panel back into the middle.
				dragged_to = shown.at;
				dragged = shown.placed;
			default:
				break;
		}
	}

	UiNode node;
	node.kind = spec.kind;
	node.owned.init(mem, 0);
	node.listed.init(mem, 0);
	node.options.init(mem, 0);
	node.rows.init(mem, 0);
	node.ops.init(mem, 0);
	node.menus.init(mem, 0);
	node.items.init(mem, 0);
	if (spec.key.len > 0)
	{
		node.key.init(mem, spec.key.len);
		node.key.append(spec.key);
	}
	self.building.push(node);
	UiNode* held = &self.building[index];

	// Every string a widget borrows, copied before the widget exists.
	String text    = spec.text.len > 0 ? held.keep(spec.text) : "";
	String suffix  = spec.suffix.len > 0 ? held.keep(spec.suffix) : "";
	String title   = spec.title.len > 0 ? held.keep(spec.title) : "";
	String confirm = spec.confirm_label.len > 0 ? held.keep(spec.confirm_label) : "";
	String decline = spec.decline_label.len > 0 ? held.keep(spec.decline_label) : "";
	if (spec.kind == UiNodeKind.TEXTFIELD && !spec.has_text && carried.len > 0) carried = held.keep(carried);

	// The confinement outlives the call the same way a label does, because it is
	// read from a widget callback on some later frame — see `ui_file_directory`.
	if (spec.kind == UiNodeKind.FILE_BROWSER)
	{
		if (spec.root.len > 0) held.root = held.keep(spec.root);
		if (spec.scheme.len > 0) held.scheme = held.keep(spec.scheme);
		// Where the browser opens: what the user was last looking at if this is a
		// rebuild of one, and what the snapshot asked for otherwise. Confined
		// either way, so a carried directory from a snapshot whose root has since
		// changed cannot outlive the rule that let it in.
		if (browsing.len > 0 && ui_inside(browsing, held.root)) text = held.keep(browsing);
		// A confined browser always opens inside its root: `FileBrowser.mount`
		// falls back to the *working directory* for an empty start, and a game's
		// working directory is wherever somebody typed the command.
		if (text.len == 0) text = held.root;
	}

	cui::widgets::MainAlign main   = cui::widgets::MainAlign::from_ordinal(spec.main_align > 3 ? 0 : (usz)spec.main_align);
	cui::widgets::CrossAlign cross = cui::widgets::CrossAlign::from_ordinal(
		spec.cross_align > 2 ? 0 : (usz)spec.cross_align
	);
	cui::widgets::CrossAlign anchor_h = cui::widgets::CrossAlign::from_ordinal(
		spec.anchor_h > 2 ? 0 : (usz)spec.anchor_h
	);
	cui::widgets::CrossAlign anchor_v = cui::widgets::CrossAlign::from_ordinal(
		spec.anchor_v > 2 ? 0 : (usz)spec.anchor_v
	);

	cui::RectStyle surface = {
		.color = (cui::Color)spec.color,
		.border_color = (cui::Color)spec.border_color,
		.border_width = spec.border_width,
		.border_radius = spec.radii,
	};
	cui::TextStyle label_style = {
		.font = spec.font,
		.size = spec.text_size,
		.color = ui_color(spec.text_color, UI_TEXT),
	};

	cui::Element* element;
	switch (spec.kind)
	{
		case COLUMN:
			element = self.ui.@node(
				(cui::widgets::Column){ .gap = spec.gap, .size = spec.size, .main_align = main, .cross_align = cross }
			);
		case ROW:
			element = self.ui.@node(
				(cui::widgets::Row){ .gap = spec.gap, .size = spec.size, .main_align = main, .cross_align = cross }
			);
		case STACK:
			if (spec.wrap)
			{
				element = self.ui.@node((UiWrap){ .size = spec.size });
			}
			else
			{
				element = self.ui.@node((cui::widgets::Stack){ .size = spec.size });
			}
		case PADDING:
			element = self.ui.@node(
				(cui::widgets::Padding){
					.insets = {
						.left = spec.insets.x,
						.top = spec.insets.y,
						.right = spec.insets.z,
						.bottom = spec.insets.w,
					},
				}
			);
		case GRID:
			element = self.ui.@node(
				(cui::widgets::Grid){ .cell = spec.cell, .gap_x = spec.gap, .gap_y = spec.gap_y, .size = spec.size }
			);
		case CLIP:
			element = self.ui.@node((cui::widgets::Clip){ .radii = spec.radii });
		case ANCHORED:
			element = self.ui.@node(
				(cui::widgets::Anchored){ .h = anchor_h, .v = anchor_v, .margin = spec.margin }
			);
		case SCROLL:
			element = self.ui.@node(
				(cui::widgets::Scroll){
					.size = spec.size,
					.scroll_offset = spec.offset,
					.step = spec.step,
					.radii = spec.radii,
					.thumb_color = (cui::Color)spec.accent,
				}
			);
		case RECT:
			element = self.ui.@node((cui::widgets::Rectangle){ .size = spec.size, .style = surface });
		case LABEL:
			element = self.ui.@node(
				(cui::widgets::Label){
					.text = text,
					.font = spec.font,
					.size = spec.text_size,
					.color = ui_color(spec.color, UI_TEXT),
				}
			);
		case DRAW:
			element = self.ui.@node(
				(UiPainting){
					.size = spec.size,
					.node = index,
					.clickable = spec.on_click,
					.hoverable = spec.on_hover,
					.pointing = spec.on_pointer,
					.blocking = spec.solid,
				}
			);
		case BUTTON:
			element = self.ui.@node(
				(cui::widgets::Button){
					.size = spec.size,
					.style = { ...surface, .color = ui_color(spec.color, UI_SURFACE) },
					.hover_style = { ...surface, .color = ui_color(spec.hover_color, UI_HOVER) },
					.press_style = { ...surface, .color = ui_color(spec.press_color, UI_ACCENT) },
					.on_click = spec.on_click ? &ui_click : null,
					.label = text,
					.label_style = label_style,
				}
			);
		case CHECKBOX:
			element = self.ui.@node(
				(cui::widgets::Checkbox){
					.label = text,
					.checked = spec.checked,
					.size = spec.size,
					.on_change = spec.on_change ? &ui_toggle : null,
					.style = {
						...cui::widgets::DEFAULT_CHECKBOX_STYLE,
						.color = ui_color(spec.color, cui::widgets::DEFAULT_CHECKBOX_STYLE.color),
						.hover_color = ui_color(spec.hover_color, cui::widgets::DEFAULT_CHECKBOX_STYLE.hover_color),
						.checked_color = ui_color(spec.accent, cui::widgets::DEFAULT_CHECKBOX_STYLE.checked_color),
						.text_color = ui_color(spec.text_color, cui::widgets::DEFAULT_CHECKBOX_STYLE.text_color),
						.font = spec.font,
						.text_size = spec.text_size > 0
							? spec.text_size
							: cui::widgets::DEFAULT_CHECKBOX_STYLE.text_size,
					},
				}
			);
		case SLIDER:
			element = self.ui.@node(
				(cui::widgets::Slider){
					.label = text,
					.suffix = suffix,
					.value = spec.value,
					.min = spec.min,
					.max = spec.max,
					.step = spec.step,
					.curve = spec.curve,
					.decimals = spec.decimals,
					.disabled = spec.disabled,
					.size = spec.size,
					.on_change = spec.on_change ? &ui_slide : null,
					.on_commit = spec.on_commit ? &ui_commit : null,
					.style = {
						...cui::widgets::DEFAULT_SLIDER_STYLE,
						.track = ui_color(spec.color, cui::widgets::DEFAULT_SLIDER_STYLE.track),
						.fill = ui_color(spec.accent, cui::widgets::DEFAULT_SLIDER_STYLE.fill),
						.hover_fill = ui_color(spec.hover_color, cui::widgets::DEFAULT_SLIDER_STYLE.hover_fill),
						.label_color = ui_color(spec.text_color, cui::widgets::DEFAULT_SLIDER_STYLE.label_color),
						.font = spec.font,
						.text_size = spec.text_size > 0
							? spec.text_size
							: cui::widgets::DEFAULT_SLIDER_STYLE.text_size,
					},
				}
			);
		case SELECT:
			element = self.ui.@node(
				(cui::widgets::Select){
					.selected = spec.selected,
					.width = spec.size.x,
					.open = keep_open,
					.on_change = spec.on_change ? &ui_pick : null,
				}
			);
		case TREE:
			element = self.ui.@node(
				(cui::widgets::Tree){
					.selected = spec.selected,
					.on_select = spec.on_select ? &ui_row_select : null,
					.on_toggle = spec.on_toggle ? &ui_row_toggle : null,
					.style = {
						...cui::widgets::DEFAULT_TREE_STYLE,
						.text = ui_color(spec.text_color, cui::widgets::DEFAULT_TREE_STYLE.text),
						.selected = ui_color(spec.accent, cui::widgets::DEFAULT_TREE_STYLE.selected),
						.hover = ui_color(spec.hover_color, cui::widgets::DEFAULT_TREE_STYLE.hover),
						.text_size = spec.text_size > 0 ? spec.text_size : cui::widgets::DEFAULT_TREE_STYLE.text_size,
					},
				}
			);
		case TEXTFIELD:
			element = self.ui.@node(
				(cui::widgets::TextField){
					.placeholder = suffix,
					.width = spec.size.x,
					.on_change = spec.on_change ? &ui_typed : null,
					.on_submit = spec.on_submit ? &ui_submit : null,
					.style = {
						...cui::widgets::DEFAULT_TEXT_FIELD_STYLE,
						.background = ui_color(spec.color, cui::widgets::DEFAULT_TEXT_FIELD_STYLE.background),
						.border = ui_color(spec.border_color, cui::widgets::DEFAULT_TEXT_FIELD_STYLE.border),
						.border_focused = ui_color(spec.accent, cui::widgets::DEFAULT_TEXT_FIELD_STYLE.border_focused),
						.text = ui_color(spec.text_color, cui::widgets::DEFAULT_TEXT_FIELD_STYLE.text),
						.text_size = spec.text_size > 0
							? spec.text_size
							: cui::widgets::DEFAULT_TEXT_FIELD_STYLE.text_size,
					},
				}
			);
		case CONFIRM_DIALOG:
			// The message and the two callbacks are NOT set here: a
			// `ConfirmDialog` takes them through `ask`, which copies the sentence
			// into a buffer of its own — the whole reason the widget exists is
			// that the question is decided when it is asked rather than when the
			// tree is built. Opening it is below, once the element is on the node.
			element = self.ui.@node(
				(cui::widgets::ConfirmDialog){
					.title = title,
					.confirm_label = confirm,
					.decline_label = decline,
					.style = {
						...cui::widgets::DEFAULT_DIALOG_STYLE,
						.panel_color = ui_color(spec.color, cui::widgets::DEFAULT_DIALOG_STYLE.panel_color),
						.panel_border = ui_color(spec.border_color, cui::widgets::DEFAULT_DIALOG_STYLE.panel_border),
						.text_color = ui_color(spec.text_color, cui::widgets::DEFAULT_DIALOG_STYLE.text_color),
						.font = spec.font,
						.text_size = spec.text_size > 0
							? spec.text_size
							: cui::widgets::DEFAULT_DIALOG_STYLE.text_size,
					},
					.buttons = {
						...cui::widgets::DEFAULT_CONFIRM_BUTTONS,
						.accent = ui_color(spec.accent, cui::widgets::DEFAULT_CONFIRM_BUTTONS.accent),
						.hover = ui_color(spec.hover_color, cui::widgets::DEFAULT_CONFIRM_BUTTONS.hover),
						.press = ui_color(spec.press_color, cui::widgets::DEFAULT_CONFIRM_BUTTONS.press),
						.font = spec.font,
					},
				}
			);
		case MENU:
			// `menus` is empty until `repoint`, for the reason a Select's options
			// are: `push_menu` is still growing the list a `Menu[]` would point
			// into. A bar with nothing in it is a strip of background, which is
			// exactly what a snapshot that named no menus asked for.
			element = self.ui.@node(
				(cui::widgets::MenuBar){
					.style = {
						...cui::widgets::DEFAULT_MENU_STYLE,
						.bar_color = ui_color(spec.color, cui::widgets::DEFAULT_MENU_STYLE.bar_color),
						.panel_color = ui_color(spec.color, cui::widgets::DEFAULT_MENU_STYLE.panel_color),
						.bar_border = ui_color(spec.border_color, cui::widgets::DEFAULT_MENU_STYLE.bar_border),
						.panel_border = ui_color(spec.border_color, cui::widgets::DEFAULT_MENU_STYLE.panel_border),
						.hover_color = ui_color(spec.hover_color, cui::widgets::DEFAULT_MENU_STYLE.hover_color),
						.open_color = ui_color(spec.accent, cui::widgets::DEFAULT_MENU_STYLE.open_color),
						.text_color = ui_color(spec.text_color, cui::widgets::DEFAULT_MENU_STYLE.text_color),
						.font = spec.font,
						.text_size = spec.text_size > 0
							? spec.text_size
							: cui::widgets::DEFAULT_MENU_STYLE.text_size,
						.bar_height = spec.size.y > 0 ? spec.size.y : cui::widgets::DEFAULT_MENU_STYLE.bar_height,
					},
				}
			);
		case DIALOG:
			// The body is built here and lent to cui, and that is the whole of
			// what makes this kind snapshot-shaped. `Dialog.body` is a
			// `ViewBuilder` cui calls on every open and whose subtree cui
			// releases wholesale on close; handing it the snapshot's children
			// would have cui free elements this layer still has `UiNode` records
			// for, and hand the freed pointers back the next time the panel went
			// up. `Dialog.content` is borrowed instead — see `UiNode.content`.
			//
			// A `Column` for the body rather than a `Stack`, because it is a
			// panel's contents rather than a floor: a Stack fills what it is
			// offered and the dialog frame offers it the whole screen less its
			// margins, which would make every dialog window-sized. A Column hugs
			// what is in it, so the panel comes out the size of its body — and
			// the node's own `gap`, `size` and alignments are the body's, which
			// is the only reading of them that means anything on this kind.
			held.content = self.ui.@node(
				(cui::widgets::Column){
					.gap = spec.gap,
					.size = spec.size,
					.main_align = main,
					.cross_align = cross,
				}
			);
			// Transparent for the same reason a `column` node is: it is a
			// container, and cui hit-tests the deepest rect containing the point
			// whether or not the widget handles anything. Its children are still
			// hit — `ignores_pointer` makes only this element see-through.
			held.content.ignores_pointer = true;

			element = self.ui.@node(
				(cui::widgets::Dialog){
					.title = title,
					.content = held.content,
					.modal = spec.modal,
					.close_outside = spec.close_outside,
					// Carried off the panel this one replaces, so a rebuild does
					// not undo a drag. `placed` false is "centre it", which is
					// what a dialog nobody has moved wants.
					.at = dragged_to,
					.placed = dragged,
					// `on_close` is wired whether or not the script asked, the
					// way a browser's `on_directory` is: it is one function per
					// kind and `ui_dialog_close` drops the event when nobody is
					// listening. Wiring it conditionally would buy nothing and
					// cost the script the ability to attach a handler by patch.
					.on_close = &ui_dialog_close,
					.style = {
						...cui::widgets::DEFAULT_DIALOG_STYLE,
						.panel_color = ui_color(spec.color, cui::widgets::DEFAULT_DIALOG_STYLE.panel_color),
						.panel_border = ui_color(spec.border_color, cui::widgets::DEFAULT_DIALOG_STYLE.panel_border),
						.title_color = ui_color(spec.accent, cui::widgets::DEFAULT_DIALOG_STYLE.title_color),
						.text_color = ui_color(spec.text_color, cui::widgets::DEFAULT_DIALOG_STYLE.text_color),
						.hover_color = ui_color(spec.hover_color, cui::widgets::DEFAULT_DIALOG_STYLE.hover_color),
						// The scrim rides on `press_color` because a dialog has
						// no pressed state of its own and a modal's dim IS the
						// colour a script wants to name; `js/prelude/ui.js`
						// spells it `scrim`.
						.scrim_color = ui_color(spec.press_color, cui::widgets::DEFAULT_DIALOG_STYLE.scrim_color),
						.font = spec.font,
						.text_size = spec.text_size > 0
							? spec.text_size
							: cui::widgets::DEFAULT_DIALOG_STYLE.text_size,
					},
				}
			);

			// **Where this node goes in the snapshot is not free: it belongs in a
			// `stack`.** Two reasons, and neither is fixable from this side.
			//
			// The panel is placed against the element's `absolute`, which is the
			// PREVIOUS emit's value — cui says as much and says to mount a dialog
			// somewhere that does not move. A snapshot makes that sharper than it
			// sounds: an element whose parent puts it at y=400 places its panel
			// 400 short on the first layout, and the layout cache means there is
			// no second one to correct it. The panel is simply off screen, for
			// good. A `stack` puts every child at the same origin, so it does not
			// move and there is nothing to lag behind.
			//
			// And a modal fills what it is offered, so in a `column` it takes a
			// row of the column's whole height — or, if an earlier child already
			// filled, is offered none of it. Overlapping children is what a stack
			// is, which is the same answer twice.
			//
			// Raised only while modal, and the asymmetry is the point.
			// `Ui.hit_test_element` walks raised children before plain ones, so
			// a raise puts an element above every sibling under the same parent
			// however early it was built — which is what "everything behind it
			// is blocked" has to mean for a backdrop that would otherwise lose
			// the pointer to any sibling mounted after it. A non-modal dialog
			// keeps cui's own rule instead, where a later sibling paints over it
			// on purpose: that is how an application's menu bar keeps its
			// dropdowns above a panel built before it. Note the limit either
			// way — a raise reorders one parent's children and never lifts a
			// subtree above a whole floor mounted after it.
			element.raised = spec.modal;
		case FILE_BROWSER:
			// `on_directory` is wired whether or not the script asked for it: it
			// is what enforces the root, and a browser that only reported where it
			// had gone when somebody was listening would be confined only when
			// somebody was listening. `ui_file_directory` drops the event itself
			// when there is no handler.
			element = self.ui.@node(
				(cui::widgets::FileBrowser){
					.start = text,
					.on_choose = spec.on_choose ? &ui_file_choose : null,
					.on_select = spec.on_select ? &ui_file_select : null,
					.on_directory = &ui_file_directory,
					.style = {
						...cui::widgets::DEFAULT_FILE_BROWSER_STYLE,
						.text = ui_color(spec.text_color, cui::widgets::DEFAULT_FILE_BROWSER_STYLE.text),
						.selected = ui_color(spec.accent, cui::widgets::DEFAULT_FILE_BROWSER_STYLE.selected),
						.hover = ui_color(spec.hover_color, cui::widgets::DEFAULT_FILE_BROWSER_STYLE.hover),
						.text_size = spec.text_size > 0
							? spec.text_size
							: cui::widgets::DEFAULT_FILE_BROWSER_STYLE.text_size,
					},
				}
			);
	}

	// Decoration is transparent to the pointer, and it has to be opt-out rather
	// than opt-in: cui hit-tests the deepest rect containing the point whether or
	// not its widget handles anything, so a caption or a panel background over
	// the viewport would otherwise be a dead zone that also takes the cursor
	// shape down with it. `solid` is the modal scrim's way back in.
	if (!spec.kind.interactive() && !spec.solid) element.ignores_pointer = true;

	// A text field starts with whatever the snapshot said, or with whatever was
	// in the one this replaced. `set_text` rather than the literal because the
	// widget creates its own DString in `mount` and would then own two.
	if (spec.kind == UiNodeKind.TEXTFIELD)
	{
		String start = spec.has_text ? text : carried;
		if (start.len > 0) element.widget_as(cui::widgets::TextField).set_text(element, start);
	}

	// A question goes up through `ask` rather than through fields, because `ask`
	// is where the sentence is copied into the widget's own buffer and where the
	// two answers are attached — the whole reason `ConfirmDialog` exists is that
	// the message is decided when the question is asked. It is safe on an element
	// with no children, which is every element at this point: it records the
	// request and asks for a build, the path a hand-written one takes on its
	// first frame.
	//
	// Asked and then withdrawn when the snapshot says the question is down,
	// rather than skipped: that loads the sentence and both callbacks without
	// showing anything, so `patch({ open: true })` later has something to put up
	// and somewhere to send the answer. Withdrawing before the first build runs
	// neither callback — there is no panel yet to close.
	if (spec.kind == UiNodeKind.CONFIRM_DIALOG)
	{
		cui::widgets::ConfirmDialog* dialog = element.widget_as(cui::widgets::ConfirmDialog);
		dialog.ask(
			element,
			text,
			spec.on_confirm ? &ui_confirm : null,
			spec.on_dismiss ? &ui_decline : null
		);
		if (!spec.checked) dialog.withdraw(element);
	}

	// A `dialog` goes up through `set_open` rather than through the field, and
	// the difference is the keyboard: opening focuses the panel, which is what
	// puts ESC within reach of somebody who has not clicked in it yet. Closed is
	// the constructed state, so this runs on the way up only and never fires the
	// close callback on the way past.
	if (spec.kind == UiNodeKind.DIALOG && spec.checked)
	{
		element.widget_as(cui::widgets::Dialog).set_open(element, true);
	}

	self.building[index].element = element;
	if (parent >= 0)
	{
		// Into the parent's BODY where it has one, which is a `dialog` and
		// nothing else: a composite is built with exactly the one node its
		// `build` returned, so a dialog's children cannot hang off its own
		// element and hang off the element cui borrows instead.
		UiNode* above = &self.building[parent];
		cui::Element* into = above.content != null ? above.content : above.element;
		into.append(element);
	}
	else
	{
		self.pending = element;
	}

	// The keyboard follows the key across a rebuild. Without this, typing stops
	// dead the first time a HUD calls `set` — `Ui.release` hands focus to the
	// parent, which is a container that does not read keys.
	if (prior != null && prior.element != null && self.ui.focused == prior.element)
	{
		self.pending_focus = (int)index;
	}

	return index;
}

<*
 One option of a `select`, in order — and one mask pattern of a `fileBrowser`,
 which wants the same thing: a borrowed `String[]` the snapshot fills in.

 Separate from the node because a widget borrows the array and the list has to
 stop growing before anything may point at it — `repoint` is where that happens.

 @param node : `The index push_node answered with.`
*>
fn void UiLayer.push_option(&self, uint node, String label)
{
	UiNode* held = self.at(node);
	if (held == null) return;
	held.options.push(held.keep_listed(label));
}

<*
 One title on a `menu` bar, in order. Its entries follow it.

 @param node : `The index push_node answered with.`
*>
fn void UiLayer.push_menu(&self, uint node, String title)
{
	UiNode* held = self.at(node);
	if (held == null) return;
	held.menus.push({ .title = held.keep_listed(title) });
}

<*
 One entry under the last title pushed.

 `MenuQuery` — the callback cui polls for an item's checked and disabled state
 each time its dropdown opens — deliberately does not cross. It exists so a check
 mark set by a keyboard shortcut is right without anyone pushing an update into
 the menu data, and a JavaScript panel is the case where there IS somebody
 pushing: it re-renders from its own state and the snapshot carries the answer.
 A function pointer that had to reach back into the interpreter to be asked a
 question mid-layout would be the one callback here that is not a *report* of
 something that happened.

 `on_select` is attached to every entry rather than only to a bar whose script
 asked for one. cui puts that function on the item and not on the bar, so making
 it conditional would mean pushing the node's handler set down into every entry;
 the listener already drops an event nobody is holding a handler for, and a
 chosen item closes its menu either way.

 @param node : `The index push_node answered with. Ignored before the first push_menu.`
 @param shortcut : `Drawn right-aligned and dim. A reminder only — nothing here binds a key.`
 @param separator : `A divider. Every other field of the entry is ignored, cui's own rule.`
*>
fn void UiLayer.push_menu_item(
	&self, uint node, String label, String shortcut, bool checked, bool disabled, bool separator
)
{
	UiNode* held = self.at(node);
	if (held == null || held.menus.len() == 0) return;

	held.items.push(
		{
			.label = separator ? "" : held.keep_listed(label),
			.shortcut = separator || shortcut.len == 0 ? "" : held.keep_listed(shortcut),
			.on_select = separator ? null : &ui_menu_pick,
			.checked = checked,
			.disabled = disabled,
			.separator = separator,
		}
	);

	// The run this entry belongs to, written as a slice of the list *as it
	// stands*. The pointer is stale the moment the list grows again and `repoint`
	// replaces it; the length is the part that is being recorded, and it is
	// recorded here because this is the only place that knows which title is
	// still open.
	sz last = held.menus.len() - 1;
	usz count = held.menus[last].items.len + 1;
	held.menus[last].items = held.items.array_view()[(usz)held.items.len() - count..];
}

<*
 One row of a `tree`, in order.

 @param node : `The index push_node answered with.`
 @param trailing : `Drawn right-aligned, and skipped when empty — a count beside a category.`
 @param depth : `Indent level. Nothing is hidden by expanded; it only points the disclosure mark.`
*>
fn void UiLayer.push_row(&self, uint node, String label, String trailing, usz depth, bool expandable, bool expanded)
{
	UiNode* held = self.at(node);
	if (held == null) return;
	String kept_label    = held.keep_listed(label);
	String kept_trailing = trailing.len > 0 ? held.keep_listed(trailing) : "";
	held.rows.push(
		{
			.label = kept_label,
			.trailing = kept_trailing,
			.depth = depth,
			.expandable = expandable,
			.expanded = expanded,
		}
	);
}

<*
 One drawing of a `draw` node, in paint order.

 The text is copied here for the same reason every other string is: a `Painter`
 call happens at paint time, long after the QuickJS string that named it is
 gone. Sizes are clamped rather than refused — `Painter.rect` has a contract
 against a negative one, and any build but `--safe=no` would turn a script's typo
 into a panic in the renderer.

 @param node : `The index push_node answered with.`
*>
fn void UiLayer.push_op(&self, uint node, UiOp op)
{
	UiNode* held = self.at(node);
	if (held == null) return;
	if (op.text.len > 0) op.text = held.keep_listed(op.text);
	op.to.x = math::max(op.to.x, 0.0f);
	op.to.y = math::max(op.to.y, 0.0f);
	op.radius = math::max(op.radius, 0.0f);
	op.thickness = math::max(op.thickness, 0.0f);
	op.blur = math::max(op.blur, 0.0f);
	held.ops.push(op);
}

// ============================================================================
// Patching one node
// ============================================================================

<*
 The fields `three.ui.patch(key, props)` may write.

 Deliberately narrower than `UiNodeSpec`: a patch changes a *value*, and
 anything that would change the shape of the tree is a `set`. The `has_` flags
 are what makes "leave this alone" different from "set this to zero", which is
 the whole point of the verb — a HUD patches `text` sixty times a second and
 must not silently reset the colour it was given once.
*>
struct UiPatch
{
	bool has_text;
	String text;
	bool has_value;
	float value;
	bool has_checked;
	bool checked;
	bool has_selected;
	usz selected;
	bool has_offset;
	float offset;
	bool has_disabled;
	bool disabled;
	bool has_color;
	Vec4 color;
	bool has_min;
	float min;
	bool has_max;
	float max;
	bool has_size;
	Vec2 size;
}

<*
 The index a key names, for the list verbs below.

 @return? UI_NO_SUCH_KEY : `Nothing in the live tree carries that key.`
*>
fn uint? UiLayer.node_for(&self, String key)
{
	if (self.ui == null) return UI_NO_SUCH_KEY~;
	foreach (i, node : self.nodes)
	{
		if (node.key && node.key.str_view() == key) return (uint)i;
	}
	return UI_NO_SUCH_KEY~;
}

<*
 Writes the named fields of one live node and invalidates it.

 `request_layout` rather than `request_paint` wherever the value decides a size —
 a label's text and a checkbox's caption both do — and cui marks the ancestors on
 the way up, so asking the node is the correct direction.

 @param node : `The index node_for answered with.`
*>
fn void UiLayer.patch(&self, uint node, UiPatch fields)
{
	UiNode* live = self.at(node);
	if (live == null || live.element == null) return;
	cui::Element* elem = live.element;
	bool resize;

	switch (live.kind)
	{
		case LABEL:
			cui::widgets::Label* widget = elem.widget_as(cui::widgets::Label);
			if (fields.has_text)
			{
				widget.text = live.retext(fields.text);
				resize = true;
			}
			if (fields.has_color) widget.color = (cui::Color)fields.color;
		case RECT:
			cui::widgets::Rectangle* widget = elem.widget_as(cui::widgets::Rectangle);
			if (fields.has_color) widget.style.color = (cui::Color)fields.color;
			if (fields.has_size)
			{
				widget.size = fields.size;
				resize = true;
			}
		case BUTTON:
			cui::widgets::Button* widget = elem.widget_as(cui::widgets::Button);
			if (fields.has_text)
			{
				widget.label = live.retext(fields.text);
				resize = true;
			}
			if (fields.has_color) widget.style.color = (cui::Color)fields.color;
			if (fields.has_size)
			{
				widget.size = fields.size;
				resize = true;
			}
		case CHECKBOX:
			cui::widgets::Checkbox* widget = elem.widget_as(cui::widgets::Checkbox);
			if (fields.has_checked) widget.checked = fields.checked;
			if (fields.has_text)
			{
				widget.label = live.retext(fields.text);
				resize = true;
			}
		case SLIDER:
			cui::widgets::Slider* widget = elem.widget_as(cui::widgets::Slider);
			if (fields.has_value) widget.value = fields.value;
			if (fields.has_min) widget.min = fields.min;
			if (fields.has_max) widget.max = fields.max;
			if (fields.has_disabled) widget.disabled = fields.disabled;
			if (fields.has_text)
			{
				widget.label = live.retext(fields.text);
				resize = true;
			}
		case SELECT:
			cui::widgets::Select* widget = elem.widget_as(cui::widgets::Select);
			if (fields.has_selected) widget.selected = fields.selected;
			// A Select builds its own subtree, so a changed selection is a rebuild
			// of that subtree rather than a repaint of this element.
			elem.request_build();
		case TREE:
			cui::widgets::Tree* widget = elem.widget_as(cui::widgets::Tree);
			if (fields.has_selected) widget.selected = fields.selected;
		case TEXTFIELD:
			cui::widgets::TextField* widget = elem.widget_as(cui::widgets::TextField);
			if (fields.has_text) widget.set_text(elem, fields.text);
		case SCROLL:
			cui::widgets::Scroll* widget = elem.widget_as(cui::widgets::Scroll);
			if (fields.has_offset)
			{
				widget.scroll_offset = fields.offset;
				resize = true;
			}
		case DRAW:
			UiPainting* widget = elem.widget_as(UiPainting);
			if (fields.has_size)
			{
				widget.size = fields.size;
				resize = true;
			}
		case CONFIRM_DIALOG:
			// Putting the question up and taking it down is a patch and not a
			// rebuild, which is the only thing that makes a confirmation usable
			// from a class: a `set` would build a second `ConfirmDialog` element,
			// and the answer the user is halfway through giving would be to the
			// one that had just been thrown away.
			cui::widgets::ConfirmDialog* widget = elem.widget_as(cui::widgets::ConfirmDialog);
			if (fields.has_checked)
			{
				if (fields.checked)
				{
					@pool()
					{
						// Copied, and this is not defensive: `ask` clears its own
						// buffer before appending to it, so handing it a view OF
						// that buffer — which is what re-opening with nothing new
						// to say does — is an overlapping copy. cui guards
						// `FileBrowser.go_to` against exactly this case and does
						// not guard `ask`. The copy is gone at the end of the
						// call, by which time `ask` has finished reading it.
						String said = fields.has_text ? fields.text : widget.message.str_view().tcopy();

						// The callbacks the node was built with, again: `ask`
						// reads them at the moment the answer is given, so
						// re-asking with the pair already on the widget keeps
						// whichever of the two the snapshot attached and drops
						// neither.
						widget.ask(elem, said, widget.on_confirm, widget.on_decline);
					};
				}
				else
				{
					widget.withdraw(elem);
				}
			}
			else if (fields.has_text && widget.asking(elem))
			{
				widget.ask(elem, fields.text, widget.on_confirm, widget.on_decline);
			}
			// Returns rather than falling through to the invalidation below, and
			// that is load-bearing. A `ConfirmDialog` is a composite with no paint
			// of its own, so `request_paint` routes to `request_build` — and its
			// `build` reads `open_when_built` and clears it on the way past. So
			// asking politely for a repaint here would rebuild the panel `ask`
			// has just opened, closed. Both verbs invalidate correctly already.
			return;
		case DIALOG:
			// Up and down is a patch and not a rebuild, and on this kind that is
			// not a convenience: a `set` builds a new element and a NEW BODY, so
			// everything the panel was holding — the text in a field, where a
			// list was scrolled — would go with it. The borrowed body is what
			// makes closing cheap, and this is the verb that reaches it.
			cui::widgets::Dialog* widget = elem.widget_as(cui::widgets::Dialog);
			if (fields.has_checked)
			{
				// The flag is raised across the close and not the open, because
				// only the close has a callback behind it — see
				// `UiLayer.closing_dialog`.
				self.closing_dialog = true;
				widget.set_open(elem, fields.checked);
				self.closing_dialog = false;
			}
			if (fields.has_text)
			{
				// The bar reads the title at BUILD time and holds a copy of the
				// view, so a new one is a rebuild of the panel rather than a
				// repaint of it — which costs the focus of anything in the body,
				// since `Ui.release` hands the keyboard up on the way past. That
				// is the price of renaming a panel while it is open, and it is
				// cheaper than the alternative, which is doing nothing and saying
				// nothing about it.
				widget.title = live.retext(fields.text);
				elem.request_build();
			}
			// `set_open` asks for its own build, and a dialog that was handed
			// neither field wants no invalidation at all — the fall-through below
			// would repaint the backdrop and leave the panel exactly as it was.
			return;
		default:
			break;
	}

	if (resize)
	{
		elem.request_layout();
	}
	else
	{
		elem.request_paint();
	}
}

<*
 Replaces the one string a node's widget borrows, in place.

 One buffer per node rather than a copy per call, because this is the verb a
 readout uses sixty times a second. Safe to overwrite: the caller assigns the new
 view to the widget in the same breath, and cui's cached paint output holds glyph
 quads rather than the string they were measured from — so nothing is still
 reading the old bytes by the time the next layout runs.
*>
fn String UiNode.retext(&self, String text)
{
	if (!self.patched) self.patched.init(mem, text.len);
	self.patched.clear();
	self.patched.append(text);
	return self.patched.str_view();
}

<*
 Empties a live node's list — its ops, its options or its rows — so a patch can
 fill it again. `relist` is what puts the widget back in touch with it.
*>
fn void UiLayer.reset_list(&self, uint node)
{
	UiNode* live = self.at(node);
	if (live == null) return;
	live.drop_list();
}

<*
 Points a live node's widget at the array it has just been given, and asks for a
 frame.
*>
fn void UiLayer.relist(&self, uint node)
{
	UiNode* live = self.at(node);
	if (live == null || live.element == null) return;
	repoint_node(live);

	// A `fileBrowser` whose mask was replaced has to read the directory again:
	// the filter is applied when the listing is taken and nowhere else, so
	// re-pointing alone would change what the browser is allowed to show and not
	// what it is showing. Guarded on the widget having mounted, because the
	// buffer `rescan` reads the directory out of is made there.
	if (live.kind == UiNodeKind.FILE_BROWSER)
	{
		cui::widgets::FileBrowser* browser = live.element.widget_as(cui::widgets::FileBrowser);
		if (browser.directory.data() != null) browser.rescan();
	}

	live.element.request_layout();
	self.ui.request_frame();
}

// ============================================================================
// Measuring
// ============================================================================

<*
 What a string will take, in pixels.

 Drawing text by hand is useless without it — centring a readout inside an arc is
 arithmetic on a measured width — and this is the same measurement `Painter.text`
 returns, so a script positioning by it lands where cui puts the glyphs.

 Brings the layer up, because the answer needs the font.

 @param size : `Em size in px. Zero uses cui's default.`
 @return `Width and height of the line box.`
*>
fn Vec2? UiLayer.measure(&self, Gpu* gpu, Target* target, String text, uint font, float size)
{
	self.ensure(gpu, target)!;
	return self.ui.text.measure(font, text, size);
}

// ============================================================================
// Events, on their way out
// ============================================================================

<*
 Sends one event to whoever is listening, naming the node by its element.

 Used by the widgets this file writes, which know their own element.
*>
fn void ui_fire(cui::Element* elem, UiEvent event) @local
{
	if (elem == null) return;
	UiLayer* layer = elem.ui.inherit(UiLayer) ?? null;
	if (layer == null || layer.listener == null) return;
	foreach (i, node : layer.nodes)
	{
		if (node.element == elem)
		{
			layer.listener(layer.host, (uint)i, event);
			return;
		}
	}
}

<*
 Sends one event to whoever is listening, working out which node fired it.

 cui's widget callbacks take the `Ui` and nothing else — deliberately, because
 cui has no app type to name — so the firing node has to be recovered from the
 interactivity state, which is exactly what `process_input` has just finished
 setting. The three candidates are the three ways a widget can be talking:

 - `captured` for anything mid-gesture. A slider dragged past its own edge is
   still the captured element, which is the half that matters for a drag.
 - `hovered` for a press, which is dispatched before the capture is recorded.
 - `focused` for a key, which is the only thing a text field ever answers to.

 The kind is what disambiguates a nesting — a button inside a tree row finds the
 button, because the walk stops at the first ancestor of the kind that asked.
*>
fn void ui_signal(cui::Ui* ui, UiNodeKind kind, UiEvent event) @local
{
	UiLayer* layer = ui.inherit(UiLayer) ?? null;
	if (layer == null || layer.listener == null) return;

	int at = layer.locate(ui.captured, kind);
	if (at < 0) at = layer.locate(ui.hovered, kind);
	if (at < 0) at = layer.locate(ui.focused, kind);
	if (at < 0) return;

	layer.listener(layer.host, (uint)at, event);
}

<*
 The nearest node of this kind at or above `from`, or -1.
*>
fn int UiLayer.locate(&self, cui::Element* from, UiNodeKind kind)
{
	for (cui::Element* e = from; e != null; e = e.parent)
	{
		foreach (i, node : self.nodes)
		{
			if (node.element == e && node.kind == kind) return (int)i;
		}
	}
	return -1;
}

fn void ui_click(cui::Ui* ui) @local
{
	ui_signal(ui, UiNodeKind.BUTTON, { .kind = UiEventKind.CLICK });
}

fn void ui_toggle(cui::Ui* ui, bool checked) @local
{
	ui_signal(ui, UiNodeKind.CHECKBOX, { .kind = UiEventKind.TOGGLE, .flag = checked });
}

fn void ui_slide(cui::Ui* ui, float value) @local
{
	ui_signal(ui, UiNodeKind.SLIDER, { .kind = UiEventKind.SLIDE, .value = value });
}

fn void ui_commit(cui::Ui* ui, float value) @local
{
	ui_signal(ui, UiNodeKind.SLIDER, { .kind = UiEventKind.COMMIT, .value = value });
}

fn void ui_pick(cui::Ui* ui, usz index) @local
{
	ui_signal(ui, UiNodeKind.SELECT, { .kind = UiEventKind.PICK, .index = index });
}

fn void ui_row_select(cui::Ui* ui, usz row) @local
{
	ui_signal(ui, UiNodeKind.TREE, { .kind = UiEventKind.ROW_SELECT, .index = row });
}

fn void ui_row_toggle(cui::Ui* ui, usz row) @local
{
	ui_signal(ui, UiNodeKind.TREE, { .kind = UiEventKind.ROW_TOGGLE, .index = row });
}

fn void ui_typed(cui::Ui* ui, String text) @local
{
	ui_signal(ui, UiNodeKind.TEXTFIELD, { .kind = UiEventKind.TEXT_CHANGE, .text = text });
}

fn void ui_submit(cui::Ui* ui, String text) @local
{
	ui_signal(ui, UiNodeKind.TEXTFIELD, { .kind = UiEventKind.TEXT_SUBMIT, .text = text });
}

fn void ui_confirm(cui::Ui* ui) @local
{
	ui_signal(ui, UiNodeKind.CONFIRM_DIALOG, { .kind = UiEventKind.CONFIRM });
}

<*
 Every way out of a confirmation that is not the confirming button — Cancel, the
 close glyph, ESC.

 It reaches the node the same way a click does even though the panel is on its
 way out, because cui defers the release to the build pass: the subtree the
 answer came from is still hanging off this node's element while the callback
 runs, which is exactly what `locate` walks.
*>
fn void ui_decline(cui::Ui* ui) @local
{
	ui_signal(ui, UiNodeKind.CONFIRM_DIALOG, { .kind = UiEventKind.DISMISS });
}

<*
 A `dialog` the user put away: the close glyph, ESC, or a press on a
 close-outside backdrop.

 `Dialog.set_open` runs `on_close` for every one of those AND for the script's
 own `patch({ open: false })` — cui says as much: "whoever asked for the close".
 That is the right contract for a widget, where "it went away" is the useful
 fact, and the wrong one for a binding: a script that has just closed a panel
 does not need to hear that the panel is closed, and a handler that answered by
 writing its own state again would be a re-render provoked by itself. So the one
 case that is not news is dropped, which is exactly what cui does one widget over
 with `ConfirmDialog.answering`.

 It reaches the node the same way a confirmation's dismissal does — cui defers
 the release to the build pass, so the panel the click came from is still hanging
 off this node's element while the callback runs, which is what `locate` walks.
 ESC arrives through `focused` instead, which `set_open` put on the dialog when
 it opened.
*>
fn void ui_dialog_close(cui::Ui* ui) @local
{
	UiLayer* layer = ui.inherit(UiLayer) ?? null;
	if (layer != null && layer.closing_dialog) return;
	ui_signal(ui, UiNodeKind.DIALOG, { .kind = UiEventKind.DIALOG_DISMISS });
}

<*
 Which title and which entry, worked out from the row the release landed on.

 cui puts `on_select` on the `MenuItem` and hands it nothing but the `Ui`, so an
 entry cannot say which of the hundred on a bar it is — and unlike every other
 widget here there is no per-node function to give it, because the function is
 per item. Both coordinates are recovered from the tree instead:

 - **the entry** is its position among its siblings. A dropdown's `Column` holds
   one element per entry, separators included and in push order, so the child
   index IS the index into the items the snapshot pushed.
 - **the title** is the bar's own `open`, which is still the menu being chosen
   from: `MenuItemRow` closes the bar after the callback returns, not before.

 Matching on the label instead was the obvious alternative and is worse: two
 menus may carry the same word, and `Edit > Copy` and `View > Copy` would then be
 one event.
*>
fn void ui_menu_pick(cui::Ui* ui) @local
{
	UiLayer* layer = ui.inherit(UiLayer) ?? null;
	if (layer == null || layer.listener == null) return;

	// Captured first for the same reason `ui_signal` reads it first: the press
	// that armed this release is what took the capture, and the pointer may have
	// left the row by the time the button came up.
	cui::Element* row = ui_menu_row(ui.captured);
	if (row == null) row = ui_menu_row(ui.hovered);
	if (row == null || row.parent == null) return;

	usz entry;
	bool found;
	foreach (i, sibling : row.parent.children)
	{
		if (sibling != row) continue;
		entry = (usz)i;
		found = true;
		break;
	}
	if (!found) return;

	cui::Element* bar = row.widget_as(cui::widgets::MenuItemRow).bar;
	if (bar == null) return;
	int at = layer.locate(bar, UiNodeKind.MENU);
	if (at < 0) return;

	usz open = bar.widget_as(cui::widgets::MenuBar).open;
	if (open == 0) return;

	layer.listener(layer.host, (uint)at, { .kind = UiEventKind.MENU_PICK, .index = open - 1, .item = entry });
}

// The nearest dropdown entry at or above `from`, or null. A walk rather than a
// cast because a menu row is a leaf today and need not stay one.
fn cui::Element* ui_menu_row(cui::Element* from) @local
{
	for (cui::Element* e = from; e != null; e = e.parent)
	{
		if (e.is_widget(cui::widgets::MenuItemRow)) return e;
	}
	return null;
}

<*
 Whether a path is at or under a root.

 An empty root is "no confinement" rather than "nothing is inside it", which is
 the reading a host with no assets directory needs — see `UiNodeSpec.root`. The
 separator test is what stops `/home/ada/models-old` counting as inside
 `/home/ada/models`.
*>
fn bool ui_inside(String path, String root) @local
{
	if (root.len == 0) return true;
	if (path.len < root.len || !path.starts_with(root)) return false;
	return path.len == root.len || path[root.len] == '/';
}

<*
 A path as the script would have written it: relative to the browser's root, with
 the scheme it opened under.

 So that a path out of `onChoose` is a path `three.load` accepts, which is the
 same promise `three.inventory` makes about the paths it hands back. The root
 itself comes out empty — there is no name for "here" that is also a filename.

 The answer either points into `path` or into the temp allocator, so it is good
 for the call and no longer, which is what `UiEvent.text` already says of itself.
*>
fn String UiNode.written(&self, String path)
{
	if (self.root.len == 0) return path;
	if (!ui_inside(path, self.root)) return "";
	String tail = path.len > self.root.len ? path[self.root.len + 1..] : "";
	return self.scheme.len == 0 ? tail : string::tformat("%s%s", self.scheme, tail);
}

fn void ui_file_choose(cui::Ui* ui, String path) @local
{
	ui_file_report(ui, UiEventKind.FILE_CHOOSE, path);
}

fn void ui_file_select(cui::Ui* ui, String path) @local
{
	ui_file_report(ui, UiEventKind.FILE_SELECT, path);
}

// A row's path, on its way out. Located like every other pointer-driven event,
// and rewritten by the node whose confinement it landed in.
fn void ui_file_report(cui::Ui* ui, UiEventKind kind, String path) @local
{
	UiLayer* layer = ui.inherit(UiLayer) ?? null;
	if (layer == null || layer.listener == null) return;

	int at = layer.locate(ui.captured, UiNodeKind.FILE_BROWSER);
	if (at < 0) at = layer.locate(ui.hovered, UiNodeKind.FILE_BROWSER);
	if (at < 0) at = layer.locate(ui.focused, UiNodeKind.FILE_BROWSER);
	if (at < 0) return;

	@pool()
	{
		layer.listener(layer.host, (uint)at, { .kind = kind, .text = layer.nodes[at].written(path) });
	};
}

<*
 The listing moved, and the one place the root is enforced.

 cui's `FileBrowser` walks wherever the rows take it — `..` at any depth, up to
 the filesystem root — and giving it a root of its own would be a change to cui,
 which is a library this repository shares. So the confinement is applied from
 outside, on the report every move already makes: a move that landed outside is
 sent straight back to the root and told nobody. The bounce recurses exactly
 once, because the root is inside itself.

 A browser is not the only thing this protects. A script cannot `three.load`
 outside the assets directory anyway — `resolve_asset` sees to that — so what
 would leak without this is the *listing*: the names of every file the user
 walked past, handed to a game's panel one directory at a time.

 Located by the identity of the string rather than by the pointer, because this
 one also fires from `mount`, where there is nothing hovered, captured or focused
 to work back from. Both of cui's call sites pass `directory.str_view()`, so the
 pointer names the widget exactly.
*>
fn void ui_file_directory(cui::Ui* ui, String path) @local
{
	UiLayer* layer = ui.inherit(UiLayer) ?? null;
	if (layer == null) return;

	int at = -1;
	foreach (i, node : layer.nodes)
	{
		if (node.kind != UiNodeKind.FILE_BROWSER || node.element == null) continue;
		if (node.element.widget_as(cui::widgets::FileBrowser).directory.str_view().ptr != path.ptr) continue;
		at = (int)i;
		break;
	}
	if (at < 0) return;

	UiNode* node = &layer.nodes[at];
	if (!ui_inside(path, node.root))
	{
		node.element.widget_as(cui::widgets::FileBrowser).go_to(node.element, node.root);
		return;
	}

	if (layer.listener == null) return;
	@pool()
	{
		layer.listener(
			layer.host,
			(uint)at,
			{ .kind = UiEventKind.FILE_DIRECTORY, .text = node.written(path) }
		);
	};
}

// ============================================================================
// The frame
// ============================================================================

<*
 One frame of input, and the two questions the rest of the loop asks afterwards.

 `Cursor` is already in the interface's coordinates — image pixels, top-left
 origin — because `WindowView.cursor` put it there for the raycast. The buttons
 are in `cui::MouseButton` order (LEFT, RIGHT, MIDDLE), which is the order
 `Cursor` already carries them in, and `cui::Key` values are the X11 codes
 `c3w::EventKey.code` already holds.

 Sets `wants_pointer` and `wants_keys`. `captured` is the half that matters for
 a drag — the pointer can leave the widget mid-gesture and the widget still owns
 it — and `focused` is the one that keeps typing in a text field out of WASD.

 Widget callbacks run from inside here, which is why `dispatching` is raised
 around the call: a handler that rebuilds the tree would be restructuring the
 one cui is dispatching on. The listener is expected to queue and to apply
 afterwards; `js/bind_ui.c3` is where that happens.

 @param cursor : `This frame's pointer, from WindowView.cursor.`
 @param keys : `What the window said about the keyboard.`
 @param text : `What was typed this frame. Borrowed for the call only.`
 @param dt_ms : `Milliseconds since the last frame.`
*>
fn void UiLayer.feed(&self, Cursor cursor, KeyBits keys, String text, float dt_ms)
{
	if (self.ui == null) return;

	self.held.clear();
	foreach (key : c3w::EventKey::values)
	{
		if (keys.has(key)) self.held.push((cui::Key)key.code);
	}

	cui::InputFrame frame = {
		.mouse = { cursor.x, cursor.y },
		.buttons = { cursor.down, cursor.right, cursor.middle },
		.scroll = cursor.scroll,
		.scroll_x = cursor.scroll_x,
		.text = text,
		.keys_down = self.held.array_view(),
	};

	self.dispatching = true;
	self.ui.process_input(frame, dt_ms / 1000.0f);
	self.dispatching = false;

	self.wants_pointer = self.ui.hovered != null || self.ui.captured != null;
	self.wants_keys    = self.ui.focused != null;
}

<*
 The pointer shape the interface is asking for, or ARROW when it has no opinion.

 Resolved by `process_input` from the hovered chain, so a handle that closes its
 hand on the press beginning a drag is right on the same frame. Read only while
 `wants_pointer` — off the interface, `cursor_shape` in `main.c3` still answers.
*>
fn c3w::CursorShape UiLayer.cursor_shape(&self)
{
	if (self.ui == null) return c3w::CursorShape.ARROW;
	switch (self.ui.cursor)
	{
		case cui::Cursor.POINTING_HAND: return c3w::CursorShape.POINTING_HAND;
		case cui::Cursor.IBEAM: return c3w::CursorShape.IBEAM;
		case cui::Cursor.CROSSHAIR: return c3w::CursorShape.CROSSHAIR;
		case cui::Cursor.OPEN_HAND: return c3w::CursorShape.OPEN_HAND;
		case cui::Cursor.CLOSED_HAND: return c3w::CursorShape.CLOSED_HAND;
		case cui::Cursor.RESIZE_H: return c3w::CursorShape.RESIZE_H;
		case cui::Cursor.RESIZE_V: return c3w::CursorShape.RESIZE_V;
		default: return c3w::CursorShape.ARROW;
	}
}

<*
 Whether the loop may sleep as far as the interface is concerned.

 cui sets `frame_requested` on every invalidation — paint, layout, transform,
 mount, unmount — and a running animation re-arms it every frame the way a
 Flutter `Ticker` does. Reading clears it, because the answer is about the frame
 that just went out.
*>
fn bool UiLayer.idle(&self)
{
	if (self.ui == null) return true;
	bool wanted = self.ui.frame_requested;
	self.ui.frame_requested = false;
	return !wanted;
}

<*
 Everything that has to happen outside a render pass: the flush, the glyph
 atlas, and the buffers the shader reads by address.

 `upload` bakes glyphs, may grow a buffer — which idles the GPU — and may
 rebuild the pipeline when the texture count changed, so it cannot be inside a
 rendering. It also calls `ui.flush()` between the two glyph-atlas syncs it has
 to sit between; that ordering is the classic embedding bug and cui deliberately
 does not leave it to the host.

 Its concurrency contract is *one upload per submitted frame, having waited for
 the frame `CANVAS_SLOTS` submissions back*. `CANVAS_SLOTS` is 2, which is
 `MAX_FRAMES_IN_FLIGHT`, and every path into `record_scene` opens with that
 fence wait — `frame()`, `capture()` and `render_offscreen()` alike. A fourth
 path has to keep it.
*>
fn void? UiLayer.upload(&self, Target* target)
{
	if (self.ui == null) return;
	self.pass.upload(self.ui, { (float)target.extent.width, (float)target.extent.height })!;
}

<*
 The draw, inside a rendering `Target.begin_overlay` or `Composite.begin_overlay`
 opened.

 One instanced draw call, whatever the interface contains. A frame with nothing
 to draw records nothing.

 `extent` is the ATTACHMENT'S size and need not be the target's. `upload` fixed
 the coordinates the interface was laid out in — the target's pixels, which are
 the pixels a `Cursor` arrives in — and cui's `ui_view` maps those onto whatever
 viewport this sets, so a bigger attachment rasterises the same interface at a
 higher density rather than drawing a bigger one. That is the whole of the
 window-density fix: see `Composite`.

 @param extent : `The size of the attachment being drawn into.`
*>
fn void? UiLayer.record(&self, vk::CommandBuffer cmd, vk::Extent2D extent)
{
	if (self.ui == null) return;
	self.pass.record(cmd, extent)!;
}
