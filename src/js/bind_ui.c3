<*
 `three.ui` — the interface, as a script describes it.

 `render/ui.c3` owns the cui tree and everything cui-typed; this file is the
 crossing. It reads the snapshot `js/prelude/ui.js` checked, pushes it through
 `UiLayer`'s `UiNodeSpec` / `UiOp` vocabulary, and holds the JavaScript functions
 the widgets call back into.

 ## The shape, and why it is a snapshot

 `three.ui.set(tree)` when the structure changes, `three.ui.patch(key, props)`
 when a value does. Retained handles would put element lifetimes into JavaScript
 where a disposed one is a runtime fault; immediate mode would spend every frame
 making a retained library pretend to be an immediate one. A snapshot has neither
 problem, and the one thing it would otherwise break — the text under somebody's
 fingers, the scroll position, the open popup — is what `key` is for.

 ## What crosses

 `ui.js` validates, resolves the aliases (`label` for `text`, `padding` for
 `insets`, …), turns every colour, pair and inset spelling into an array of
 numbers and leaves out whatever the script did not say. Names stay names: a
 node's `type`, an op's `op` and the alignments arrive as strings and are mapped
 here. An absent field is how "leave this alone" differs from "set it to zero".

 ## Callbacks run mid-dispatch

 A widget's handler is called from inside `Ui.process_input`, before the tree is
 flushed. A handler that called `three.ui.set` would restructure the tree cui is
 walking, which cui's own documentation says a handler must not do — so a `set`
 arriving during a dispatch is held and applied by `flush_ui` once
 `process_input` has returned. A `patch` needs no such thing: it writes a field
 and asks for paint, and restructures nothing.

 ## Strings

 Every string a cui widget holds is borrowed and must outlive the element, and
 everything here came out of the engine. `UiLayer` copies at the boundary — see
 `UiNode.keep` — so nothing below ever hands a widget a pointer into engine
 memory. This is the memory rule that fails quietly: a freed label reads as
 garbage glyphs, never as a crash.
*>
module three;

import std::collections::list;
import std::math;
import fastjs::js;
import fastjs::js::opt;

<*
 The JavaScript functions one node attached, indexed by that node's position in
 `UiLayer.nodes`. NO_ROOT is a handler the node does not have.

 Parallel to the node table rather than inside it, because `render/ui.c3` is
 written to know nothing about the engine — the layer answers with an index and
 this is what the index means.
*>
struct UiHandlers
{
	js::Root on_click;
	js::Root on_change;
	js::Root on_commit;
	js::Root on_submit;
	js::Root on_select;
	js::Root on_toggle;
	js::Root on_hover;
	// The three cui's application widgets need and nothing else does. `confirm`
	// and `dismiss` are a question's two answers — and `dismiss` is a `dialog`
	// being put away as well, since to a script that is the same event — and
	// `choose` is a file browser row being activated as opposed to merely
	// selected, the distinction that makes a browser usable with single clicks.
	js::Root on_confirm;
	js::Root on_dismiss;
	js::Root on_choose;
	// The pointer on a `draw` node — position, buttons, modifiers and wheel,
	// inside the hit test. `onClick` is the same pointer with everything but the
	// fact of it thrown away, and the two are separate because most panels want
	// only the small one.
	js::Root on_pointer;
	// A `nodeGraph`'s two: everything it reports goes to `on_graph` as one event
	// object, which `js/prelude/ui.js` fans out to the named handlers, and
	// `can_connect` answers whether a wire may run between two ports.
	js::Root on_graph;
	js::Root can_connect;
}

fn void UiHandlers.drop(&self, js::Engine* js)
{
	$foreach $m : UiHandlers::members:
		js.drop(&self.$m);
	$endforeach
}

<*
 Which handler an event goes to, and its name for the sentence that stops it.
*>
fn js::Root* UiHandlers.for_event(&self, UiEventKind kind, String* name)
{
	switch (kind)
	{
		case CLICK:
			*name = "onClick";
			return &self.on_click;
		case HOVER:
			*name = "onHover";
			return &self.on_hover;
		// FILE_DIRECTORY too: where a file browser is IS its value — the thing a
		// breadcrumb beside it displays — so it is `onChange` and not a fourth name.
		case TOGGLE:
		case SLIDE:
		case PICK:
		case TEXT_CHANGE:
		case FILE_DIRECTORY:
			*name = "onChange";
			return &self.on_change;
		case COMMIT:
			*name = "onCommit";
			return &self.on_commit;
		case ROW_SELECT:
		case MENU_PICK:
		case FILE_SELECT:
			*name = "onSelect";
			return &self.on_select;
		case ROW_TOGGLE:
			*name = "onToggle";
			return &self.on_toggle;
		case TEXT_SUBMIT:
			*name = "onSubmit";
			return &self.on_submit;
		case CONFIRM:
			*name = "onConfirm";
			return &self.on_confirm;
		// A dialog put away is the same event to a script as a question
		// dismissed: the panel is gone and nobody pressed anything that means yes.
		case DISMISS:
		case DIALOG_DISMISS:
			*name = "onDismiss";
			return &self.on_dismiss;
		case FILE_CHOOSE:
		case MENU_CHOOSE:
			*name = "onChoose";
			return &self.on_choose;
		case POINTER:
			*name = "onPointer";
			return &self.on_pointer;
		case GRAPH:
			*name = "nodeGraph";
			return &self.on_graph;
	}
}

<*
 Every property name the tree walk reads, interned once per engine. A field
 `gap_y` is the key `gapY`.
*>
struct UiKeys
{
	// A node
	js::Key type;
	js::Key key;
	js::Key children;
	js::Key gap;
	js::Key gap_y;
	js::Key size;
	js::Key cell;
	js::Key main;
	js::Key cross;
	js::Key insets;
	js::Key radii;
	js::Key margin;
	js::Key h;
	js::Key v;
	js::Key solid;
	js::Key wrap;
	js::Key multiline;
	js::Key modal;
	js::Key close_outside;
	js::Key color;
	js::Key border_color;
	js::Key border_width;
	js::Key accent;
	js::Key hover_color;
	js::Key press_color;
	js::Key text_color;
	js::Key text;
	js::Key suffix;
	js::Key title;
	js::Key confirm;
	js::Key decline;
	js::Key font;
	js::Key text_size;
	js::Key value;
	js::Key min;
	js::Key max;
	js::Key step;
	js::Key curve;
	js::Key offset;
	js::Key decimals;
	js::Key checked;
	js::Key disabled;
	js::Key selected;
	js::Key pan;
	js::Key zoom;
	js::Key searchable;
	js::Key plane_color;
	js::Key grid_color;
	js::Key card_color;
	js::Key header_color;
	js::Key card_border;
	js::Key graph_view;
	// Its handlers
	js::Key on_click;
	js::Key on_change;
	js::Key on_commit;
	js::Key on_submit;
	js::Key on_select;
	js::Key on_toggle;
	js::Key on_hover;
	js::Key on_confirm;
	js::Key on_dismiss;
	js::Key on_choose;
	js::Key on_pointer;
	js::Key on_graph;
	js::Key can_connect;
	// Its lists
	js::Key ops;
	js::Key options;
	js::Key rows;
	js::Key menus;
	js::Key items;
	js::Key nodes;
	js::Key ports;
	js::Key wires;
	// Their entries
	js::Key op;
	js::Key at;
	js::Key to;
	js::Key radius;
	js::Key thickness;
	js::Key start;
	js::Key sweep;
	js::Key blur;
	js::Key corners;
	js::Key texture;
	js::Key label;
	js::Key shortcut;
	js::Key separator;
	js::Key trailing;
	js::Key depth;
	js::Key expandable;
	js::Key expanded;
	js::Key pos;
	js::Key width;
	js::Key tag;
	js::Key header;
	js::Key flags;
	js::Key progress;
	js::Key node;
	js::Key output;
	js::Key square;
	js::Key hollow;
	js::Key from;
	js::Key category;
	js::Key hint;
}

<*
 @return? js::THREW
*>
fn void? UiKeys.init(&self, js::Engine* js)
{
	@pool()
	{
		$foreach $m : UiKeys::members:
			self.$m = js.key(js::camel_case($m.name))!;
		$endforeach
	};
}

<*
 Registers the interface verbs on the host object.

 @return? js::THREW
*>
fn void? JsRuntime.bind_ui_verbs(&self, js::Value host)
{
	self.ui_keys.init(self.js)!;
	self.js.@bind(host, "uiSet", &js_ui_set, self)!;
	self.js.@bind(host, "uiPatch", &js_ui_patch, self)!;
	self.js.@bind(host, "uiClear", &js_ui_clear, self)!;
	self.js.@bind(host, "uiMeasure", &js_ui_measure, self)!;
	self.js.@bind(host, "uiSlot", &js_ui_slot, self)!;
	self.js.@bind(host, "uiScale", &js_ui_scale, self)!;
	self.js.@bind(host, "uiTexture", &js_ui_texture, self)!;
	self.js.@bind(host, "uiTextureFree", &js_ui_texture_free, self)!;
}

// ============================================================================
// Reading a checked value
// ============================================================================

// The node kinds by name, in the order `UiNodeKind` declares them.
const String[*] UI_KIND_NAMES = {
	"column", "row", "stack", "padding", "grid", "clip", "anchored", "scroll",
	"rect", "label", "draw",
	"button", "checkbox", "slider", "select", "tree", "textfield",
	"confirmDialog", "menu", "fileBrowser", "dialog",
	"nodeGraph", "nodeCard", "portRow", "contextMenu",
};
$assert UI_KIND_NAMES.len == UiNodeKind::len;

// The drawing ops by name, in the order `UiOpKind` declares them.
const String[*] UI_OP_NAMES = { "rect", "circle", "ellipse", "line", "arc", "text", "shadow", "image" };
$assert UI_OP_NAMES.len == UiOpKind::len;

<*
 The position of name in names.

 @return? UI_BAD_PARENT
*>
fn usz? ordinal_named(String[] names, String name) @local
{
	foreach (i, n : names)
	{
		if (n == name) return (usz)i;
	}
	return UI_BAD_PARENT~;
}

<*
 An alignment as cui orders `MainAlign` and `CrossAlign`. `ui.js` has already
 turned every spelling into one of these, and `stretch` is cui's `start`.
*>
fn uint align_ordinal(String name) @local
{
	switch (name)
	{
		case "center": return 1;
		case "end": return 2;
		case "between": return 3;
		default: return 0;
	}
}

<*
 Whether the property is there at all: the whole of the difference between
 "leave this alone" and "set it to zero".

 @return? js::THREW
*>
fn bool? has_field(js::Engine* js, js::Value obj, js::Key key) @local
{
	return !js.get(obj, key)!.is_nullish();
}

<*
 @return? js::THREW
*>
fn double? field_number(js::Engine* js, js::Value obj, js::Key key, double fallback = 0) @local
{
	js::Value v = js.get(obj, key)!;
	if (v.is_nullish()) return fallback;
	double n = js.number(v)!;
	return n == n ? n : fallback;
}

<*
 @return? js::THREW
*>
fn float? field_float(js::Engine* js, js::Value obj, js::Key key) @local
{
	return (float)field_number(js, obj, key)!;
}

<*
 A count or an index: negative is 0.

 @return? js::THREW
*>
fn uint? field_uint(js::Engine* js, js::Value obj, js::Key key) @local
{
	return (uint)math::max(field_number(js, obj, key)!, 0.0);
}

<*
 @return? js::THREW
*>
fn bool? field_truth(js::Engine* js, js::Value obj, js::Key key) @local
{
	return js.truth(js.get(obj, key)!);
}

<*
 A string property in temp memory; empty when absent.

 @return? js::THREW
*>
fn String? field_text(js::Engine* js, js::Value obj, js::Key key) @local
{
	js::Value v = js.get(obj, key)!;
	if (v.is_nullish()) return "";
	return js.text(v, tmem);
}

<*
 A fixed-width array of numbers, zero-filled when absent. `ui.js` has turned
 every spelling a script may use into exactly this.

 @return? js::THREW
*>
macro field_numbers(js::Engine* js, js::Value obj, js::Key key, $Type) @local
{
	$Type out;
	js::Value list = js.get(obj, key)!;
	if (list.is_nullish()) return out;
	for (int i = 0; i < $Type::len; i++)
	{
		double n = js.number(js.get(list, i)!)!;
		out[i] = (float)(n == n ? n : 0);
	}
	return out;
}

<*
 @return? js::THREW
*>
fn Vec2? field_vec2(js::Engine* js, js::Value obj, js::Key key) @local => field_numbers(js, obj, key, Vec2);

<*
 @return? js::THREW
*>
fn Vec4? field_vec4(js::Engine* js, js::Value obj, js::Key key) @local => field_numbers(js, obj, key, Vec4);

<*
 A callback property, held when it is a function. Held because a widget calls
 back on some later frame, from inside `process_input`, long after the tree the
 script wrote is gone.

 @return? js::THREW
*>
fn js::Root? take_handler(js::Engine* js, js::Value obj, js::Key key) @local
{
	js::Value v = js.get(obj, key)!;
	return v.is_function() ? js.hold(v) : js::NO_ROOT;
}

<*
 Runs the body for each entry of the array at obj[key]; nothing when absent.

 @return? js::THREW
*>
macro void? @each_entry(js::Engine* js, js::Value obj, js::Key key; @body(js::Value entry)) @local
{
	js::Value list = js.get(obj, key)!;
	if (list.is_nullish()) return;
	long count = js.length(list)!;
	for (long i = 0; i < count; i++)
	{
		@body(js.get(list, i)!);
	}
}

// ============================================================================
// The verbs
// ============================================================================

<*
 The layer, with this runtime installed as its listener.

 Every verb goes through here, so there is exactly one place that says "an
 interface needs a device" and one place the listener is wired — a `reload`
 builds a new runtime against the same `Renderer`, and the layer must end up
 pointing at the new one rather than at the address the old one had.

 @return? js::THREW
*>
fn UiLayer*? JsRuntime.ui_layer(&self)
{
	if (self.renderer == null) return self.js.fail("drawing an interface needs a GPU device and this context has none")~;
	if (catch self.renderer.ui.ensure(&self.renderer.gpu, &self.renderer.target))
	{
		return self.js.fail("the interface layer could not start — the font or its pipeline failed to load")~;
	}
	self.renderer.ui.on_event(&js_ui_event, self);
	self.renderer.ui.on_query(&js_ui_query);
	return &self.renderer.ui;
}

<*
 `three.ui.set(tree)` — replace the whole interface with this snapshot.

 Null empties it. A tree that fails to read leaves the live one exactly as it
 was: `begin_tree` builds into a table nothing is looking at, and `abandon_tree`
 throws that away without the interface flickering.

 @return? js::THREW
*>
fn void? js_ui_set(JsRuntime* self, js::Value tree)
{
	// A handler that rebuilds the tree it was called from would restructure the
	// one cui is dispatching on. Held instead, and applied by `flush_ui` the
	// moment `process_input` returns — which is the same frame, so a button that
	// swaps the panel still swaps it before anything is drawn.
	if (self.ui_dispatching)
	{
		self.hold_ui_tree(tree);
		return;
	}
	if (tree.is_nullish())
	{
		self.drop_ui_tree();
		return;
	}
	@pool()
	{
		self.apply_ui_tree(tree)!;
	};
}

// `three.ui.clear()` — take the interface down, leaving the debug line alone.
fn void js_ui_clear(JsRuntime* self)
{
	if (self.ui_dispatching)
	{
		self.hold_ui_tree(js::UNDEFINED);
		return;
	}
	self.drop_ui_tree();
}

<*
 `three.ui.measure(text, font, size)` — what a string will take, in pixels, as
 `[width, height]`.

 Drawing text by hand is useless without it: centring a readout inside an arc is
 arithmetic on a measured width, and this is the measurement cui itself uses when
 it lays the glyphs down.

 @return? js::THREW
*>
fn Vec2? js_ui_measure(JsRuntime* self, String text, int font, float size)
{
	UiLayer* layer = self.ui_layer()!;
	return layer.measure(&self.renderer.gpu, &self.renderer.target, text, (uint)math::max(font, 0), size) ?? (Vec2){ 0, 0 };
}

<*
 `three.ui.slot` — whether the application has offered a place to draw, and how
 big it is.

 The read half of `UiLayer.set_slot`. A snapshot does not survive the slot it
 was grafted into, so a panel written against an editor watches `generation` and
 re-`set`s when it moves — a pane switched away from and back is a different
 element, and the number is how a script hears about it.
*>
struct UiSlot
{
	bool present;
	// Reported whether or not there is a slot, because the bump that matters
	// most is the one where an offer was withdrawn.
	uint generation;
	// The pane's corner in window points, which is what turns a `three.input`
	// pointer reading into a position inside a panel — see `UiLayer.slot_origin`.
	float x;
	float y;
	float width;
	float height;
}

<*
 Deliberately not routed through `ui_layer`: asking where a panel may go must
 not bring a GPU device up, because the answer for a context without one is
 "nowhere" and that is not an error.
*>
fn UiSlot js_ui_slot(JsRuntime* self)
{
	bool present = self.renderer != null && self.renderer.ui.slot != null;
	Vec2 size = present ? self.renderer.ui.slot_size() : (Vec2){ 0, 0 };
	Vec2 origin = present ? self.renderer.ui.slot_origin() : (Vec2){ 0, 0 };
	return {
		.present = present,
		.generation = self.renderer == null ? 0 : self.renderer.ui.slot_generation,
		.x = origin.x,
		.y = origin.y,
		.width = size.x,
		.height = size.y,
	};
}

<*
 `three.ui.scale` — how big the interface is drawn, read with no argument and
 written with one.

 The layout runs in a space that much smaller and the pass stretches it back
 over the target, so a 1.25 makes every widget, glyph and margin a quarter
 bigger — the built-in chrome a script cannot reach with its own numbers
 included. Glyphs stay sharp; they are rasterised at the target's density
 whatever the interface was laid out in.

 Deliberately not routed through `ui_layer`, for `js_ui_slot`'s reason: asking
 how big the interface is drawn must not bring a GPU device up. A context with
 no renderer answers 1 and remembers nothing, because it has nothing to draw.

 @return? js::THREW
*>
fn double? js_ui_scale(JsRuntime* self, js::Call* c, js::Value wanted)
{
	if (self.renderer == null) return 1.0;
	if (c.args.len > 0)
	{
		float scale = (float)self.js.number(wanted)!;
		if (!(scale > 0)) return self.js.fail("three.ui.scale wants a positive number — 1 is the size everything else is written against")~;
		self.renderer.ui.set_scale(scale);
	}
	float now = self.renderer.ui.scale;
	return now > 0 ? now : 1.0;
}

<*
 `three.ui.patch(key, props)` — write the named fields of one keyed node.

 The retained half of the API, keyed by string rather than by handle: a HUD that
 rebuilt its tree to change one number would be spending every frame doing the
 one thing a retained interface exists to avoid.

 @return? js::THREW
*>
fn void? js_ui_patch(JsRuntime* self, js::Call* c, String key, js::Value props)
{
	UiLayer* layer = self.ui_layer()!;
	if (c.args.len < 2) return self.js.fail("three.ui.patch(key, props) wants a key and the fields to write")~;

	uint? node = layer.node_for(key);
	if (catch node)
	{
		return self.js.fail("three.ui.patch: nothing in the interface is keyed '%s'. "
			"A key only exists between the three.ui.set that named it and the next one",
			key)~;
	}

	js::Engine* js = self.js;
	UiKeys* k = &self.ui_keys;
	UiPatch fields = {
		.has_text = has_field(js, props, k.text)!,
		.text = field_text(js, props, k.text)!,
		.has_value = has_field(js, props, k.value)!,
		.value = field_float(js, props, k.value)!,
		.has_checked = has_field(js, props, k.checked)!,
		.checked = field_truth(js, props, k.checked)!,
		.has_selected = has_field(js, props, k.selected)!,
		.selected = field_uint(js, props, k.selected)!,
		.has_offset = has_field(js, props, k.offset)!,
		.offset = field_float(js, props, k.offset)!,
		.has_disabled = has_field(js, props, k.disabled)!,
		.disabled = field_truth(js, props, k.disabled)!,
		.has_color = has_field(js, props, k.color)!,
		.color = field_vec4(js, props, k.color)!,
		.has_min = has_field(js, props, k.min)!,
		.min = field_float(js, props, k.min)!,
		.has_max = has_field(js, props, k.max)!,
		.max = field_float(js, props, k.max)!,
		.has_size = has_field(js, props, k.size)!,
		.size = field_vec2(js, props, k.size)!,
		.has_view = has_field(js, props, k.pan)!,
		.pan = field_vec2(js, props, k.pan)!,
		.zoom = field_float(js, props, k.zoom)!,
		.has_at = has_field(js, props, k.at)!,
		.at = field_vec2(js, props, k.at)!,
	};
	layer.patch(node, fields);

	// The list-valued fields, which are a replacement rather than a write: the
	// node's old strings go, the new ones are copied in, and the widget is
	// re-pointed at an array that has stopped growing.
	bool relist = true;
	if (has_field(js, props, k.ops)!)
	{
		layer.reset_list(node);
		self.read_ops(props, node)!;
	}
	else if (has_field(js, props, k.options)!)
	{
		layer.reset_list(node);
		self.read_options(props, node)!;
	}
	else if (has_field(js, props, k.rows)!)
	{
		layer.reset_list(node);
		self.read_rows(props, node)!;
	}
	else if (has_field(js, props, k.menus)!)
	{
		layer.reset_list(node);
		self.read_menus(props, node)!;
	}
	else if (has_field(js, props, k.items)!)
	{
		layer.reset_list(node);
		self.read_entries(props, node)!;
	}
	else if (has_field(js, props, k.nodes)! || has_field(js, props, k.ports)! || has_field(js, props, k.wires)!)
	{
		// The three share the node's strings, so a patch naming one is a reset
		// of all three — the two it did not name are put back as they were.
		self.relist_graph(props, node)!;
	}
	else
	{
		relist = false;
	}
	if (relist) layer.relist(node);
}

// ============================================================================
// Reading a tree
// ============================================================================

<*
 Builds the whole snapshot and swaps it in, or leaves the interface untouched.

 The handler table is built alongside the nodes and installed only on success,
 which is what makes a half-read tree cost nothing: the held functions are
 dropped and the node table is thrown away together.

 @return? js::THREW
*>
fn void? JsRuntime.apply_ui_tree(&self, js::Value tree)
{
	UiLayer* layer = self.ui_layer()!;
	if (catch layer.begin_tree(&self.renderer.gpu, &self.renderer.target))
	{
		return self.js.fail("the interface layer could not start")~;
	}

	List{UiHandlers} handlers;
	handlers.tinit(8);

	if (catch self.read_node(tree, -1, &handlers))
	{
		foreach (&handler : handlers) handler.drop(self.js);
		layer.abandon_tree();
		return self.js.fail(
			"three.ui.set was handed a node the interface does not recognise — every node needs a type, "
			"and a child list has to be an array of nodes"
		)~;
	}

	layer.commit_tree();
	self.clear_ui_handlers();
	foreach (handler : handlers) self.ui_handlers.push(handler);
}

<*
 Where a `fileBrowser` may look, and how its paths are written back.

 **A browser rooted anywhere is a script reading the whole disk**, one directory
 listing at a time, so it is confined by exactly the rule every other path a
 script names is confined by — `resolve_asset`'s. The start is resolved through
 that call, so `models` is the assets directory's `models` and `../..` is refused;
 the root that resolution landed in becomes the browser's own, and
 `render/ui.c3` sends any move outside it straight back.

 A refused start opens at the root rather than raising. A browser is how somebody
 recovers from a bad path — cui's own listing survives being pointed at one — and
 refusing the whole node would take the panel down instead.

 Paths come back the way the script would have written them: root-relative, with
 the scheme they opened under, so a path out of `onChoose` is a path `three.load`
 accepts. That is the same promise `three.inventory` makes about the paths it
 hands back, and it is what makes the two verbs compose.

 **A process with no assets directory is not confined**, and that
 is deliberate rather than a hole left open: it is the `--mcp` and CLI case,
 where `locate` already uses a path as written because there is no directory to
 be relative to and confining to nothing would refuse every path there is. A run
 that wants the rule is a run that was given a root.
*>
fn void JsRuntime.confine_browser(&self, UiNodeSpec* spec)
{
	String asked = spec.text;
	// A host whose scripts already reach the whole disk — a desktop tool whose
	// plugins read model files wherever they are — confines nothing here either.
	String root = self.browse_anywhere ? "" : self.modules.root;

	spec.root = root;
	spec.scheme = "";

	if (root.len == 0)
	{
		// Empty is cui's "wherever the process started".
		spec.text = asked;
		return;
	}

	// Nothing said: the root itself, which is what "open the browser" means when
	// nowhere in particular was asked for.
	if (asked.len == 0)
	{
		spec.text = root;
		return;
	}

	String? where = self.resolve_asset(asked, tmem);
	if (catch where)
	{
		spec.text = root;
		return;
	}
	spec.text = where;
}

<*
 Every handler a node attached, held. On a failure nothing stays held.

 @return? js::THREW
*>
fn UiHandlers? JsRuntime.take_ui_handlers(&self, js::Value value)
{
	js::Engine* js = self.js;
	UiKeys* k = &self.ui_keys;
	UiHandlers taken;
	defer (catch err) taken.drop(js);
	taken.on_click = take_handler(js, value, k.on_click)!;
	taken.on_change = take_handler(js, value, k.on_change)!;
	taken.on_commit = take_handler(js, value, k.on_commit)!;
	taken.on_submit = take_handler(js, value, k.on_submit)!;
	taken.on_select = take_handler(js, value, k.on_select)!;
	taken.on_toggle = take_handler(js, value, k.on_toggle)!;
	taken.on_hover = take_handler(js, value, k.on_hover)!;
	taken.on_confirm = take_handler(js, value, k.on_confirm)!;
	taken.on_dismiss = take_handler(js, value, k.on_dismiss)!;
	taken.on_choose = take_handler(js, value, k.on_choose)!;
	taken.on_pointer = take_handler(js, value, k.on_pointer)!;
	taken.on_graph = take_handler(js, value, k.on_graph)!;
	taken.can_connect = take_handler(js, value, k.can_connect)!;
	return taken;
}

<*
 One node and everything under it, depth first.

 Pre-order because that is the order `push_node` hands out the indices children
 name, and because a parent's element has to exist before anything can be
 appended to it.

 @param parent : `The index this node hangs under, or -1 for the tree's own root.`
 @return? js::THREW, UI_BAD_PARENT
*>
fn void? JsRuntime.read_node(&self, js::Value value, int parent, List{UiHandlers}* handlers)
{
	UiLayer* layer = &self.renderer.ui;
	js::Engine* js = self.js;
	UiKeys* k = &self.ui_keys;

	if (!value.is_object()) return UI_BAD_PARENT~;
	usz kind = ordinal_named(&UI_KIND_NAMES, field_text(js, value, k.type)!)!;

	UiNodeSpec spec = {
		.kind = UiNodeKind::from_ordinal(kind),
		.key = field_text(js, value, k.key)!,

		.gap = field_float(js, value, k.gap)!,
		.gap_y = field_float(js, value, k.gap_y)!,
		.size = field_vec2(js, value, k.size)!,
		.cell = field_vec2(js, value, k.cell)!,
		.main_align = align_ordinal(field_text(js, value, k.main)!),
		.cross_align = align_ordinal(field_text(js, value, k.cross)!),
		.insets = field_vec4(js, value, k.insets)!,
		.radii = field_vec4(js, value, k.radii)!,
		.margin = field_vec2(js, value, k.margin)!,
		.anchor_h = align_ordinal(field_text(js, value, k.h)!),
		.anchor_v = align_ordinal(field_text(js, value, k.v)!),
		.solid = field_truth(js, value, k.solid)!,
		.wrap = field_truth(js, value, k.wrap)!,
		.multiline = field_truth(js, value, k.multiline)!,
		.modal = field_truth(js, value, k.modal)!,
		.close_outside = field_truth(js, value, k.close_outside)!,

		.color = field_vec4(js, value, k.color)!,
		.border_color = field_vec4(js, value, k.border_color)!,
		.border_width = field_float(js, value, k.border_width)!,
		.accent = field_vec4(js, value, k.accent)!,
		.hover_color = field_vec4(js, value, k.hover_color)!,
		.press_color = field_vec4(js, value, k.press_color)!,
		.text_color = field_vec4(js, value, k.text_color)!,

		.text = field_text(js, value, k.text)!,
		.suffix = field_text(js, value, k.suffix)!,
		.title = field_text(js, value, k.title)!,
		.confirm_label = field_text(js, value, k.confirm)!,
		.decline_label = field_text(js, value, k.decline)!,
		.font = field_uint(js, value, k.font)!,
		.text_size = field_float(js, value, k.text_size)!,

		.value = field_float(js, value, k.value)!,
		.min = field_float(js, value, k.min)!,
		.max = field_float(js, value, k.max)!,
		.step = field_float(js, value, k.step)!,
		.curve = field_float(js, value, k.curve)!,
		.offset = field_float(js, value, k.offset)!,
		.decimals = field_uint(js, value, k.decimals)!,
		.checked = field_truth(js, value, k.checked)!,
		.disabled = field_truth(js, value, k.disabled)!,
		.selected = field_uint(js, value, k.selected)!,

		.has_text = has_field(js, value, k.text)!,
		.has_value = has_field(js, value, k.value)!,
		.has_checked = has_field(js, value, k.checked)!,
		.has_selected = has_field(js, value, k.selected)!,
		.has_offset = has_field(js, value, k.offset)!,

		.pan = field_vec2(js, value, k.pan)!,
		.zoom = field_float(js, value, k.zoom)!,
		.has_view = has_field(js, value, k.pan)!,
		.searchable = field_truth(js, value, k.searchable)!,
		.graph_plane = field_vec4(js, value, k.plane_color)!,
		.graph_grid = field_vec4(js, value, k.grid_color)!,
		.graph_card = field_vec4(js, value, k.card_color)!,
		.graph_header = field_vec4(js, value, k.header_color)!,
		.graph_border = field_vec4(js, value, k.card_border)!,
	};
	bool graph_view = field_truth(js, value, k.graph_view)!;

	// Where a `fileBrowser` may look, decided here and enforced in
	// `render/ui.c3`. This file is the one that knows what an assets directory
	// is, and that is the whole reason the policy is written here rather than
	// beside the widget it confines.
	if (spec.kind == UiNodeKind.FILE_BROWSER) self.confine_browser(&spec);

	// Last of the reads, so nothing that can fail runs while they are held
	// outside the table.
	UiHandlers taken = self.take_ui_handlers(value)!;
	spec.on_click = taken.on_click != js::NO_ROOT;
	spec.on_change = taken.on_change != js::NO_ROOT;
	spec.on_commit = taken.on_commit != js::NO_ROOT;
	spec.on_submit = taken.on_submit != js::NO_ROOT;
	spec.on_select = taken.on_select != js::NO_ROOT;
	spec.on_toggle = taken.on_toggle != js::NO_ROOT;
	spec.on_hover = taken.on_hover != js::NO_ROOT;
	spec.on_confirm = taken.on_confirm != js::NO_ROOT;
	spec.on_dismiss = taken.on_dismiss != js::NO_ROOT;
	spec.on_choose = taken.on_choose != js::NO_ROOT;
	spec.on_pointer = taken.on_pointer != js::NO_ROOT;
	spec.on_graph = taken.on_graph != js::NO_ROOT;
	spec.on_query = taken.can_connect != js::NO_ROOT;
	// A pan reported only to a graph that asked: it fires every frame of a
	// drag, and a script that does not keep the view would re-render for
	// nothing on each one.
	spec.on_view = spec.on_graph && graph_view;

	uint? index = layer.push_node(spec, parent);
	if (catch err = index)
	{
		taken.drop(js);
		return err~;
	}

	// One entry per node, in the order the nodes were pushed. The table has to
	// stay aligned even for a node that attached nothing, or every index after it
	// names the wrong widget.
	handlers.push(taken);

	switch (spec.kind)
	{
		case DRAW:
			self.read_ops(value, index)!;
		case SELECT:
			self.read_options(value, index)!;
		case TREE:
			self.read_rows(value, index)!;
		case MENU:
			self.read_menus(value, index)!;
		case FILE_BROWSER:
			// The mask rides on `options` because it is the same thing: a
			// borrowed `String[]` the snapshot fills in, and a second pair of
			// push verbs for it would differ from `push_option` by nothing.
			self.read_options(value, index)!;
		case NODE_GRAPH:
			self.read_graph_nodes(value, index)!;
			self.read_graph_ports(value, index)!;
			self.read_graph_wires(value, index)!;
		case CONTEXT_MENU:
			self.read_entries(value, index)!;
		default:
			break;
	}

	@each_entry(js, value, k.children; js::Value child)
	{
		self.read_node(child, (int)index, handlers)!;
	}!;
}

<*
 A `draw` node's op list, in paint order. Every field is read whether or not
 the op uses it: a missing one reads as zero, which is what the painter wants.

 @return? js::THREW
*>
fn void? JsRuntime.read_ops(&self, js::Value node, uint index)
{
	js::Engine* js = self.js;
	UiKeys* k = &self.ui_keys;
	UiLayer* layer = &self.renderer.ui;
	@each_entry(js, node, k.ops; js::Value entry)
	{
		// An op this build does not draw is skipped, not refused.
		usz? kind = ordinal_named(&UI_OP_NAMES, field_text(js, entry, k.op)!);
		if (try kind)
		{
			layer.push_op(index, {
				.kind = UiOpKind::from_ordinal(kind),
				.at = field_vec2(js, entry, k.at)!,
				.to = field_vec2(js, entry, k.to)!,
				.radius = field_float(js, entry, k.radius)!,
				.thickness = field_float(js, entry, k.thickness)!,
				.start = field_float(js, entry, k.start)!,
				.sweep = field_float(js, entry, k.sweep)!,
				.blur = field_float(js, entry, k.blur)!,
				.size = field_float(js, entry, k.size)!,
				.font = field_uint(js, entry, k.font)!,
				.color = field_vec4(js, entry, k.color)!,
				.border_color = field_vec4(js, entry, k.border_color)!,
				.border_width = field_float(js, entry, k.border_width)!,
				.corners = field_vec4(js, entry, k.corners)!,
				.text = field_text(js, entry, k.text)!,
				.texture = field_uint(js, entry, k.texture)!,
			});
		}
	}!;
}

<*
 @return? js::THREW
*>
fn void? JsRuntime.read_options(&self, js::Value node, uint index)
{
	@each_entry(self.js, node, self.ui_keys.options; js::Value entry)
	{
		self.renderer.ui.push_option(index, self.js.text(entry, tmem));
	}!;
}

<*
 A `menu` bar's two levels, in order.

 One pass rather than two verbs, because the nesting is the whole difference
 between this and `read_options`: an item belongs to the title above it, and the
 layer records that by which `push_menu` was last.

 @return? js::THREW
*>
fn void? JsRuntime.read_menus(&self, js::Value node, uint index)
{
	js::Engine* js = self.js;
	UiKeys* k = &self.ui_keys;
	UiLayer* layer = &self.renderer.ui;
	@each_entry(js, node, k.menus; js::Value menu)
	{
		layer.push_menu(index, field_text(js, menu, k.title)!);
		@each_entry(js, menu, k.items; js::Value item)
		{
			layer.push_menu_item(
				index,
				field_text(js, item, k.label)!,
				field_text(js, item, k.shortcut)!,
				field_truth(js, item, k.checked)!,
				field_truth(js, item, k.disabled)!,
				field_truth(js, item, k.separator)!
			);
		}!;
	}!;
}

<*
 @return? js::THREW
*>
fn void? JsRuntime.read_rows(&self, js::Value node, uint index)
{
	js::Engine* js = self.js;
	UiKeys* k = &self.ui_keys;
	@each_entry(js, node, k.rows; js::Value entry)
	{
		self.renderer.ui.push_row(
			index,
			field_text(js, entry, k.label)!,
			field_text(js, entry, k.trailing)!,
			(usz)field_uint(js, entry, k.depth)!,
			field_truth(js, entry, k.expandable)!,
			field_truth(js, entry, k.expanded)!
		);
	}!;
}

<*
 A `nodeGraph`'s nodes: `pos`, `width`, `title`, `tag`, `header` (a colour),
 `flags` as bits — selected 1, error 2, running 4, muted 8 — and `progress`.

 @return? js::THREW
*>
fn void? JsRuntime.read_graph_nodes(&self, js::Value node, uint index)
{
	js::Engine* js = self.js;
	UiKeys* k = &self.ui_keys;
	@each_entry(js, node, k.nodes; js::Value entry)
	{
		self.renderer.ui.push_graph_node(index, {
			.pos = field_vec2(js, entry, k.pos)!,
			.width = field_float(js, entry, k.width)!,
			.title = field_text(js, entry, k.title)!,
			.tag = field_text(js, entry, k.tag)!,
			.header = field_vec4(js, entry, k.header)!,
			.flags = field_uint(js, entry, k.flags)!,
			.progress = field_float(js, entry, k.progress)!,
		});
	}!;
}

<*
 A `nodeGraph`'s ports: `node`, `output`, `label`, `color`, `square`, `hollow`.

 @return? js::THREW
*>
fn void? JsRuntime.read_graph_ports(&self, js::Value node, uint index)
{
	js::Engine* js = self.js;
	UiKeys* k = &self.ui_keys;
	@each_entry(js, node, k.ports; js::Value entry)
	{
		self.renderer.ui.push_graph_port(index, {
			.node = field_uint(js, entry, k.node)!,
			.output = field_truth(js, entry, k.output)!,
			.label = field_text(js, entry, k.label)!,
			.color = field_vec4(js, entry, k.color)!,
			.square = field_truth(js, entry, k.square)!,
			.hollow = field_truth(js, entry, k.hollow)!,
		});
	}!;
}

<*
 A `nodeGraph`'s wires: `from` and `to` port indices, `color`, `selected`.

 @return? js::THREW
*>
fn void? JsRuntime.read_graph_wires(&self, js::Value node, uint index)
{
	js::Engine* js = self.js;
	UiKeys* k = &self.ui_keys;
	@each_entry(js, node, k.wires; js::Value entry)
	{
		self.renderer.ui.push_graph_wire(index, {
			.from = field_uint(js, entry, k.from)!,
			.to = field_uint(js, entry, k.to)!,
			.color = field_vec4(js, entry, k.color)!,
			.selected = field_truth(js, entry, k.selected)!,
		});
	}!;
}

<*
 Replaces whichever of a `nodeGraph`'s three lists a patch names, and keeps the
 others — see `UiLayer.reset_graph`.

 @return? js::THREW
*>
fn void? JsRuntime.relist_graph(&self, js::Value props, uint node)
{
	UiKeys* k = &self.ui_keys;
	bool nodes = has_field(self.js, props, k.nodes)!;
	bool ports = has_field(self.js, props, k.ports)!;
	bool wires = has_field(self.js, props, k.wires)!;
	self.renderer.ui.reset_graph(node, nodes, ports, wires);
	if (nodes) self.read_graph_nodes(props, node)!;
	if (ports) self.read_graph_ports(props, node)!;
	if (wires) self.read_graph_wires(props, node)!;
}

<*
 A `contextMenu`'s entries: `label`, `category`, `hint`, `disabled`.

 @return? js::THREW
*>
fn void? JsRuntime.read_entries(&self, js::Value node, uint index)
{
	js::Engine* js = self.js;
	UiKeys* k = &self.ui_keys;
	@each_entry(js, node, k.items; js::Value entry)
	{
		self.renderer.ui.push_context_item(index, {
			.label = field_text(js, entry, k.label)!,
			.category = field_text(js, entry, k.category)!,
			.hint = field_text(js, entry, k.hint)!,
			.disabled = field_truth(js, entry, k.disabled)!,
		});
	}!;
}

// ============================================================================
// Events, on their way in
// ============================================================================

<*
 A POINTER event as the object a script reads.

 `x` and `y` are the node's own coordinates, `phase` is which edge this is, and
 the four modifier flags are spelled out rather than handed over as the bitmask
 they arrived in — a script writing `event.shift` is the whole reason this is an
 object and not a number.

 `button` is only meaningful on a down or an up; `buttons` is the level state and
 is what a drag tests. Both are here because a script that had to reconstruct one
 from the other would be keeping input state of its own, which is the thing this
 event exists to stop it doing.
*>
struct UiPointerReport
{
	String phase;
	float x;
	float y;
	uint buttons;
	uint button;
	float wheel;
	float wheel_x;
	bool shift;
	bool ctrl;
	bool alt;
	bool meta;
}

<*
 A GRAPH event as the object `js/prelude/ui.js`'s fan-out reads: `type` says
 which, and the rest are the fields that type fills — see `UiGraphEvent`. A box
 selection adds `list`.
*>
struct UiGraphReport
{
	String type;
	usz index;
	usz item;
	sz target;
	float x;
	float y;
	float sx;
	float sy;
	float value;
	bool done;
}

<*
 @return? js::THREW
*>
fn js::Value? JsRuntime.graph_object(&self, UiEvent event)
{
	UiGraphReport report = {
		.type = ui_graph_name(event.graph),
		.index = event.index,
		.item = event.item,
		.target = event.target,
		.x = event.at.x,
		.y = event.at.y,
		.sx = event.screen.x,
		.sy = event.screen.y,
		.value = event.value,
		.done = event.flag,
	};
	js::Value out = self.js.@object_of(report)!;
	if (event.graph == UiGraphEvent.BOX)
	{
		js::Value list = self.js.array((uint)event.list.len)!;
		foreach (n : event.list) self.js.push(list, js::number((double)n));
		self.js.set(out, "list", list)!;
	}
	return out;
}

fn String ui_graph_name(UiGraphEvent kind) @local
{
	switch (kind)
	{
		case SELECT: return "select";
		case BOX: return "box";
		case MOVE: return "move";
		case CONNECT: return "connect";
		case DISCONNECT: return "disconnect";
		case WIRE_SELECT: return "wireSelect";
		case WIRE_DROPPED: return "wireDropped";
		case CONTEXT: return "context";
		case COMMAND: return "command";
		case ADD: return "add";
		case VIEW: return "view";
	}
}

fn String ui_phase_name(UiPointerPhase phase) @local
{
	switch (phase)
	{
		case DOWN: return "down";
		case UP: return "up";
		case WHEEL: return "wheel";
		default: return "move";
	}
}

<*
 What a handler is called with, written into argv; answers how many.

 Each event hands over the one value its widget changed, except MENU_PICK — a
 bar is a list of lists, and which title it was is not recoverable from the item
 — and the two that hand over an object: a pointer, of which a panel reads two
 or three fields, and a graph event, which the prelude fans out by name.

 @return? js::THREW
*>
fn usz? JsRuntime.ui_event_args(&self, UiEvent event, js::Value[] argv)
{
	switch (event.kind)
	{
		case CLICK:
		case CONFIRM:
		case DISMISS:
		case DIALOG_DISMISS:
			return 0;
		case HOVER:
		case TOGGLE:
			argv[0] = js::boolean(event.flag);
		case SLIDE:
		case COMMIT:
			argv[0] = js::number((double)event.value);
		case PICK:
		case ROW_SELECT:
		case ROW_TOGGLE:
		case MENU_CHOOSE:
			argv[0] = js::integer((int)event.index);
		case MENU_PICK:
			argv[0] = js::integer((int)event.index);
			argv[1] = js::integer((int)event.item);
			return 2;
		case TEXT_CHANGE:
		case TEXT_SUBMIT:
		case FILE_CHOOSE:
		case FILE_SELECT:
		case FILE_DIRECTORY:
			argv[0] = self.js.string(event.text)!;
		case GRAPH:
			argv[0] = self.graph_object(event)!;
		case POINTER:
			UiPointerReport report = {
				.phase = ui_phase_name(event.phase),
				.x = event.at.x,
				.y = event.at.y,
				.buttons = event.buttons,
				.button = (uint)event.index,
				.wheel = event.value,
				.wheel_x = event.wheel_x,
				.shift = (event.modifiers & 1) != 0,
				.ctrl = (event.modifiers & 2) != 0,
				.alt = (event.modifiers & 4) != 0,
				.meta = (event.modifiers & 8) != 0,
			};
			argv[0] = self.js.@object_of(report)!;
	}
	return 1;
}

<*
 A question from a widget, answered by the script: whether a `nodeGraph` wire
 may run from one port to the other. A handler that throws is stopped and every
 later question answered yes, the rule `js_ui_event` follows for every other
 callback.
*>
fn bool js_ui_query(void* host, uint node, UiEvent event) @local
{
	JsRuntime* self = (JsRuntime*)host;
	if (!self.ready) return true;
	if ((sz)node >= self.ui_handlers.len()) return true;
	UiHandlers* handlers = &self.ui_handlers[node];
	if (handlers.can_connect == js::NO_ROOT) return true;

	self.ui_dispatching = true;
	defer self.ui_dispatching = false;
	bool yes = true;
	@pool()
	{
		js::Value[2] argv = { js::number((double)event.index), js::number((double)event.item) };
		js::Value? answer = self.js.call(self.js.held(handlers.can_connect), js::UNDEFINED, &argv);
		if (catch answer)
		{
			self.report_frame_failure(
				string::tformat("a three.ui canConnect handler threw and was stopped: %s", self.js.take_error(tmem))
			);
			self.js.drop(&handlers.can_connect);
		}
		else
		{
			yes = self.js.truth(answer);
		}
	};
	return yes;
}

<*
 One widget callback, from inside `Ui.process_input`.

 Installed as the layer's listener by `ui_layer`. The node index is the position
 in `UiLayer.nodes`, which is the position in `ui_handlers` — the two tables are
 built in one pass and replaced in one call, which is what keeps them aligned.

 A handler that throws is stopped for good, the rule every other callback in this
 project follows: a click handler that fails once fails sixty times a second, and
 the second failure tells nobody anything the first did not.
*>
fn void js_ui_event(void* host, uint node, UiEvent event) @local
{
	JsRuntime* self = (JsRuntime*)host;
	if (!self.ready) return;
	if ((sz)node >= self.ui_handlers.len()) return;

	String what;
	js::Root* handler = self.ui_handlers[node].for_event(event.kind, &what);
	if (*handler == js::NO_ROOT) return;

	// Raised for the whole of the call, so a handler calling `three.ui.set` is
	// held rather than restructuring the tree cui is walking. The layer raises
	// its own flag around `process_input`; this one is narrower and is what the
	// verbs actually read, because a `patch` from a handler is perfectly safe and
	// only a rebuild is not.
	self.ui_dispatching = true;
	defer self.ui_dispatching = false;

	bool kept = true;
	@pool()
	{
		String who = string::tformat("a three.ui %s handler", what);
		js::Value[2] argv;
		usz? argc = self.ui_event_args(event, &argv);
		if (catch argc)
		{
			self.report_frame_failure(string::tformat("%s could not be called: %s", who, self.js.take_error(tmem)));
		}
		else
		{
			kept = self.call_handler(self.js.held(*handler), argv[:argc], who);
		}
	};
	if (!kept) self.js.drop(handler);
}

// ============================================================================
// The queue, and cleanup
// ============================================================================

<*
 Holds a snapshot a handler asked for until the dispatch it came from is over;
 null or undefined is a clear.

 One slot, not a queue: two `set` calls in one dispatch mean the second is what
 the script wanted, exactly as two calls outside one do.
*>
fn void JsRuntime.hold_ui_tree(&self, js::Value tree)
{
	if (tree.is_nullish())
	{
		self.js.drop(&self.ui_pending);
	}
	else
	{
		self.js.rehold(&self.ui_pending, tree);
	}
	self.ui_pending_active = true;
}

<*
 Applies whatever a handler asked for while it was being dispatched.

 Called by the window loop immediately after `UiLayer.feed`, which is the first
 moment cui is not walking the tree. A frame where no handler ran does nothing at
 all.
*>
fn void JsRuntime.flush_ui(&self)
{
	if (!self.ui_pending_active || !self.ready) return;
	self.ui_pending_active = false;

	if (self.ui_pending == js::NO_ROOT)
	{
		self.drop_ui_tree();
		return;
	}

	// Taken out of the runtime's slot first, because applying it clears the
	// handler table and the slot with it.
	js::Root pending = self.ui_pending;
	self.ui_pending = js::NO_ROOT;
	defer self.js.drop(&pending);

	@pool()
	{
		if (catch self.apply_ui_tree(self.js.held(pending)))
		{
			(void)self.js.take_exception();
			self.report_frame_failure("three.ui.set from a widget handler could not be applied");
		}
	};
}

<*
 Takes the interface down and forgets every function it was holding.
*>
fn void JsRuntime.drop_ui_tree(&self)
{
	if (self.renderer != null) self.renderer.ui.clear_tree();
	self.clear_ui_handlers();
}

<*
 Drops every held widget callback, and any snapshot waiting for a dispatch to end.
*>
fn void JsRuntime.clear_ui_handlers(&self)
{
	foreach (&handler : self.ui_handlers) handler.drop(self.js);
	self.ui_handlers.clear();
	self.js.drop(&self.ui_pending);
	self.ui_pending_active = false;
}

<*
 Hands the interface back to nobody.

 A `three.reload()` builds a new runtime against the same `Renderer`, so the
 layer would otherwise go on holding a listener pointing at the context that has
 just been closed — and the first click after a reload would call into freed
 memory. Called from `JsRuntime.close`.
*>
fn void JsRuntime.release_ui(&self)
{
	if (self.renderer == null) return;
	self.renderer.ui.clear_tree();
	self.renderer.ui.on_event(null, null);
	self.renderer.ui.on_query(null);
	self.renderer.ui.release_textures();
}

<*
 `three.ui.texture(pixels, width, height, channels, handle, linear)` — pixels for
 an `image` op. `ui.js` reads the image object; this is the crossing.

 One, three or four channels of bytes, widened to RGBA here: an image a pipeline
 made is RGB, and a copy in JavaScript to add the alpha would be a second
 full-size buffer on the JS heap for every preview.

 Answers the handle, or throws with the reason — a buffer that is not the size
 the dimensions say is a script's mistake, and silently drawing garbage from it
 is not a better answer.

 @return? js::THREW
*>
fn int? js_ui_texture(JsRuntime* self, char[] bytes, int width, int height, int channels, int handle, Opt {bool} linear)
{
	UiLayer* layer = self.ui_layer()!;

	if (width <= 0 || height <= 0 || (channels != 1 && channels != 3 && channels != 4))
	{
		return self.js.fail("three.ui.texture: an image is { width, height, channels: 1, 3 or 4, pixels }")~;
	}
	usz texels = (usz)width * (usz)height;
	if (bytes.len < texels * (usz)channels)
	{
		return self.js.fail("three.ui.texture: pixels holds fewer bytes than width * height * channels")~;
	}

	@pool()
	{
		char[] rgba = bytes;
		if (channels != 4)
		{
			rgba = mem::talloc_array(char, (sz)(texels * 4));
			for (usz i = 0; i < texels; i++)
			{
				char* src = &bytes[i * (usz)channels];
				char* dst = &rgba[i * 4];
				if (channels == 1)
				{
					dst[0] = dst[1] = dst[2] = src[0];
				}
				else
				{
					dst[0] = src[0];
					dst[1] = src[1];
					dst[2] = src[2];
				}
				dst[3] = 255;
			}
		}
		uint? made = layer.texture(rgba, (uint)width, (uint)height, (uint)math::max(handle, 0), linear.or(true));
		if (catch err = made)
		{
			if (err == UI_NO_SUCH_KEY)
			{
				return self.js.fail("three.ui.texture: that handle is not a live texture — it was freed, or came from another context")~;
			}
			return self.js.fail("three.ui.texture: the GPU could not take the image")~;
		}
		return (int)made;
	};
}

// `three.ui.freeTexture(handle)` — the handle goes back for reuse.
fn void js_ui_texture_free(JsRuntime* self, int handle)
{
	if (self.renderer == null) return;
	if (handle > 0) self.renderer.ui.release_texture((uint)handle);
}
