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
import std::io;
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
	// Re-pointed by `commit_tree` once the node's op list has stopped growing.
	UiOp[] ops;
}

fn Vec2 UiPainting.layout(&self, cui::Element* elem, cui::Constraints constraints) @dynamic
{
	elem.ignores_pointer = !self.clickable && !self.hoverable;
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
 Consumes a press when the script asked for clicks, so the pointer is captured
 and a release outside still resolves — and so the scene under it does not also
 get the click.

 @return `True for a left press or release once the node declared onClick.`
*>
fn bool UiPainting.on_mouse(&self, cui::Element* elem, cui::MouseEvent event) @dynamic
{
	if (!self.clickable) return false;
	if (event.button != cui::MouseButton.LEFT) return false;

	switch (event.kind)
	{
		case PRESS:
			return true;
		case RELEASE:
			bool inside = event.pos.x >= 0 && event.pos.y >= 0 && event.pos.x < elem.size.x && event.pos.y < elem.size.y;
			if (inside) ui_fire(elem, { .kind = UiEventKind.CLICK });
			return true;
		default:
			return false;
	}
}

fn void UiPainting.on_hover(&self, cui::Element* elem, bool entered) @dynamic
{
	if (!self.hoverable) return;
	ui_fire(elem, { .kind = UiEventKind.HOVER, .flag = entered });
}

// ============================================================================
// The node IR
// ============================================================================

<*
 Every node type a snapshot may name.

 The first eight are layout and hold nothing but numbers; the next three paint;
 the last six are the interactive built-ins, and the only thing they add is a
 function. `js/prelude/ui.js` maps the `type` string onto these and refuses
 anything else by name, so a typo is a message rather than a missing panel.

 `MenuBar`, `Dialog`, `FileBrowser` and the `AreaHost` family are deliberately
 absent — see UI.md §8.3. They are not snapshot-shaped: their contents are
 function pointers cui evaluates rather than subtrees it holds.
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
}

<*
 Whether a kind takes the pointer on its own account.

 Everything else is decoration and gets `ignores_pointer` unless the snapshot
 said `solid`. The default is that way round because the interface is drawn over
 a scene somebody is looking at: a caption, a panel background and a health bar
 must not become dead zones, and the one that genuinely wants to block — a modal
 scrim — is rare enough to ask for it.
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
}

struct UiEvent
{
	UiEventKind kind;
	// TOGGLE's new state, HOVER's entered/left.
	bool flag;
	// SLIDE and COMMIT.
	float value;
	// PICK, ROW_SELECT and ROW_TOGGLE.
	usz index;
	// TEXT_CHANGE and TEXT_SUBMIT. Borrowed for the call only — it is the
	// widget's own buffer and the next keystroke rewrites it.
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
	self.ui.free();
	self.ui = null;
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

	if (self.tree) self.ui.unmount(self.tree);
	self.tree = self.pending;
	self.pending = null;

	foreach (i, node : self.nodes) self.nodes[i].free();
	self.nodes.clear();
	foreach (node : self.building) self.nodes.push(node);
	self.building.clear();

	self.repoint();

	if (self.tree) self.content.append(self.tree);
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
	if (self.tree)
	{
		self.ui.unmount(self.tree);
		self.tree = null;
	}
	foreach (i, node : self.nodes) self.nodes[i].free();
	self.nodes.clear();
	self.ui.request_frame();
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
fn bool ui_named(Vec4 color) @local => color.w > 0;

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
	UiNode* prior = self.carry(spec.key, spec.kind);
	bool keep_open;
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
	if (spec.key.len > 0)
	{
		node.key.init(mem, spec.key.len);
		node.key.append(spec.key);
	}
	self.building.push(node);
	UiNode* held = &self.building[index];

	// Every string a widget borrows, copied before the widget exists.
	String text   = spec.text.len > 0 ? held.keep(spec.text) : "";
	String suffix = spec.suffix.len > 0 ? held.keep(spec.suffix) : "";
	if (spec.kind == UiNodeKind.TEXTFIELD && !spec.has_text && carried.len > 0) carried = held.keep(carried);

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
			element = self.ui.@node((cui::widgets::Stack){ .size = spec.size });
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

	self.building[index].element = element;
	if (parent >= 0)
	{
		self.building[parent].element.append(element);
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
 One option of a `select`, in order.

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
 against a negative one, and a `-D DEBUG` build would turn a script's typo into
 a panic in the renderer.

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
