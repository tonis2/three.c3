<*
 `three.ui` — the interface, as a script describes it.

 `render/ui.c3` owns the cui tree and everything cui-typed; this file is the
 crossing. It reads a normalised snapshot out of QuickJS, pushes it through
 `UiLayer`'s `UiNodeSpec` / `UiOp` vocabulary, and holds the JavaScript functions
 the widgets call back into.

 ## The shape, and why it is a snapshot

 `three.ui.set(tree)` when the structure changes, `three.ui.patch(key, props)`
 when a value does. Retained handles would put element lifetimes into JavaScript
 where a disposed one is a runtime fault; immediate mode would spend every frame
 making a retained library pretend to be an immediate one. A snapshot has neither
 problem, and the one thing it would otherwise break — the text under somebody's
 fingers, the scroll position, the open popup — is what `key` is for.

 ## Normalisation happens in JavaScript

 The QuickJS shim this project vendors can read a property by name and cannot
 enumerate one, which is the same constraint `bind_post.c3` works under. So
 `js/prelude/ui.js` does the enumerating, the type names, the colour spellings
 and the error messages, and hands over a canonical object whose field names are
 fixed. Everything below reads by name and never guesses.

 ## Callbacks run mid-dispatch

 A widget's handler is called from inside `Ui.process_input`, before the tree is
 flushed. A handler that called `three.ui.set` would restructure the tree cui is
 walking, which cui's own documentation says a handler must not do — so a `set`
 arriving during a dispatch is retained and applied by `flush_ui` once
 `process_input` has returned. A `patch` needs no such thing: it writes a field
 and asks for paint, and restructures nothing.

 ## Strings

 Every string a cui widget holds is borrowed and must outlive the element, and
 everything here came out of QuickJS. `UiLayer` copies at the boundary — see
 `UiNode.keep` — so nothing below ever hands a widget a pointer into engine
 memory. This is the memory rule that fails quietly: a freed label reads as
 garbage glyphs, never as a crash.
*>
module three;

import std::collections::list;
import std::math;
import qjs;

<*
 The JavaScript functions one node attached, indexed by that node's position in
 `UiLayer.nodes`.

 Parallel to the node table rather than inside it, because `render/ui.c3` is
 written to know nothing about QuickJS — the layer answers with an index and this
 is what the index means.
*>
struct UiHandlers
{
	qjs::Value click;
	qjs::Value change;
	qjs::Value commit;
	qjs::Value submit;
	qjs::Value select;
	qjs::Value toggle;
	qjs::Value hover;
	// The three cui's application widgets need and nothing else does. `confirm`
	// and `dismiss` are a question's two answers — and `dismiss` is a `dialog`
	// being put away as well, since to a script that is the same event — and
	// `choose` is a file browser row being activated as opposed to merely
	// selected, the distinction that makes a browser usable with single clicks.
	qjs::Value confirm;
	qjs::Value dismiss;
	qjs::Value choose;
	// The pointer on a `draw` node — position, buttons, modifiers and wheel,
	// inside the hit test. `onClick` is the same pointer with everything but the
	// fact of it thrown away, and the two are separate because most panels want
	// only the small one.
	qjs::Value pointer;
	bool has_click;
	bool has_change;
	bool has_commit;
	bool has_submit;
	bool has_select;
	bool has_toggle;
	bool has_hover;
	bool has_confirm;
	bool has_dismiss;
	bool has_choose;
	bool has_pointer;
}

fn void UiHandlers.release(&self, qjs::Context* js)
{
	if (self.has_click) js.release(self.click);
	if (self.has_change) js.release(self.change);
	if (self.has_commit) js.release(self.commit);
	if (self.has_submit) js.release(self.submit);
	if (self.has_select) js.release(self.select);
	if (self.has_toggle) js.release(self.toggle);
	if (self.has_hover) js.release(self.hover);
	if (self.has_confirm) js.release(self.confirm);
	if (self.has_dismiss) js.release(self.dismiss);
	if (self.has_choose) js.release(self.choose);
	if (self.has_pointer) js.release(self.pointer);
	*self = { };
}

<*
 Registers the interface verbs on the host object.

 Called from `install_bindings` beside `bind_post_verbs`, so there is still
 exactly one place that lists what JavaScript can reach.
*>
fn void JsRuntime.bind_ui_verbs(&self, qjs::Value host)
{
	self.bind(host, "uiSet", &js_ui_set, 1);
	self.bind(host, "uiPatch", &js_ui_patch, 2);
	self.bind(host, "uiClear", &js_ui_clear, 0);
	self.bind(host, "uiMeasure", &js_ui_measure, 3);
	self.bind(host, "uiSlot", &js_ui_slot, 0);
	self.bind(host, "uiScale", &js_ui_scale, 1);
}

// ============================================================================
// Reading a normalised value
// ============================================================================

<*
 Whether the property is there at all.

 The whole of the difference between "leave this alone" and "set it to zero",
 which is what `patch` and the keyed carry-over both turn on. `undefined` is
 JavaScript's own answer for an absent field, so the check is the natural one.
*>
fn bool has_prop(qjs::Context* js, qjs::Value object, ZString name) @local
{
	qjs::Value value = js.property(object, name);
	defer js.release(value);
	return !value.is_undefined() && !value.is_null();
}

fn double prop_number(qjs::Context* js, qjs::Value object, ZString name, double fallback = 0) @local
{
	qjs::Value value = js.property(object, name);
	defer js.release(value);
	if (value.is_undefined() || value.is_null()) return fallback;
	double answer = js.number(value);
	return answer == answer ? answer : fallback;
}

fn float prop_float(qjs::Context* js, qjs::Value object, ZString name, float fallback = 0) @local
{
	return (float)prop_number(js, object, name, (double)fallback);
}

fn bool prop_truth(qjs::Context* js, qjs::Value object, ZString name) @local
{
	qjs::Value value = js.property(object, name);
	defer js.release(value);
	return js.truth(value);
}

<*
 A string property, allocated from `allocator`. Empty when absent.
*>
fn String prop_text(qjs::Context* js, qjs::Value object, ZString name, Allocator allocator) @local
{
	qjs::Value value = js.property(object, name);
	defer js.release(value);
	if (value.is_undefined() || value.is_null()) return "".copy(allocator);
	return js.text(value, allocator);
}

<*
 A fixed-width array of numbers, zero-filled when the property is absent.

 The prelude has already turned every spelling a script may use — a hex number, a
 `{r, g, b}`, a `Vector3`, a bare number for a square inset — into exactly this,
 so there is one shape to read and no guessing about which one arrived.
*>
macro read_numbers(qjs::Context* js, qjs::Value object, ZString name, $Type, $count) @local
{
	$Type out;
	qjs::Value value = js.property(object, name);
	defer js.release(value);
	if (value.is_undefined() || value.is_null()) return out;
	for (uint i = 0; i < $count; i++)
	{
		qjs::Value slot = js.index(value, i);
		defer js.release(slot);
		double n = js.number(slot);
		out[i] = (float)(n == n ? n : 0);
	}
	return out;
}

fn Vec2 prop_vec2(qjs::Context* js, qjs::Value object, ZString name) @local
{
	return read_numbers(js, object, name, Vec2, 2);
}

fn Vec4 prop_vec4(qjs::Context* js, qjs::Value object, ZString name) @local
{
	return read_numbers(js, object, name, Vec4, 4);
}

<*
 A callback property, retained when it is a function.

 Retained here rather than by the caller because the reference has to outlive the
 call that installed it — a widget calls back on some later frame, from inside
 `process_input`, and by then the tree the script wrote is long gone.
*>
fn bool take_handler(qjs::Context* js, qjs::Value object, ZString name, qjs::Value* out) @local
{
	qjs::Value value = js.property(object, name);
	if (!js.is_function(value))
	{
		js.release(value);
		return false;
	}
	*out = value;
	return true;
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
*>
fn UiLayer*? JsRuntime.ui_layer(&self, qjs::Context* js, qjs::Value* out)
{
	if (self.renderer == null)
	{
		*out = js.raise("drawing an interface needs a GPU device and this context has none");
		return UI_NO_DEVICE~;
	}
	if (catch self.renderer.ui.ensure(&self.renderer.gpu, &self.renderer.target))
	{
		*out = js.raise("the interface layer could not start — the font or its pipeline failed to load");
		return UI_NO_DEVICE~;
	}
	self.renderer.ui.on_event(&js_ui_event, self);
	return &self.renderer.ui;
}

<*
 `three.ui.set(tree)` — replace the whole interface with this snapshot.

 Null empties it. A tree that fails to read leaves the live one exactly as it
 was: `begin_tree` builds into a table nothing is looking at, and `abandon_tree`
 throws that away without the interface flickering.
*>
fn void js_ui_set(
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

	// A handler that rebuilds the tree it was called from would restructure the
	// one cui is dispatching on. Held instead, and applied by `flush_ui` the
	// moment `process_input` returns — which is the same frame, so a button that
	// swaps the panel still swaps it before anything is drawn.
	if (self.ui_dispatching)
	{
		self.hold_ui_tree(&js, argc > 0 ? args[0] : qjs::undefined_value());
		return;
	}

	if (argc < 1 || args[0].is_undefined() || args[0].is_null())
	{
		self.drop_ui_tree();
		return;
	}

	@pool()
	{
		self.apply_ui_tree(&js, args[0], out);
	};
}

<*
 `three.ui.clear()` — take the interface down, leaving the debug line alone.
*>
fn void js_ui_clear(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	if (self.ui_dispatching)
	{
		qjs::Context js = qjs::wrap(ctx);
		self.hold_ui_tree(&js, qjs::undefined_value());
		return;
	}
	self.drop_ui_tree();
}

<*
 `three.ui.measure(text, font, size)` — what a string will take, in pixels.

 Drawing text by hand is useless without it: centring a readout inside an arc is
 arithmetic on a measured width, and this is the measurement cui itself uses when
 it lays the glyphs down.
*>
fn void js_ui_measure(
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

	UiLayer* layer = self.ui_layer(&js, out) ?? null;
	if (layer == null) return;

	@pool()
	{
		String text = arg_text(&js, argc, args, 0, tmem);
		uint font   = (uint)math::max(arg_int(&js, argc, args, 1), 0);
		float size  = arg_float(&js, argc, args, 2);

		Vec2 taken = layer.measure(&self.renderer.gpu, &self.renderer.target, text, font, size) ?? (Vec2){ 0, 0 };
		qjs::Value pair = js.array();
		js.set_index(pair, 0, qjs::number_value((double)taken.x));
		js.set_index(pair, 1, qjs::number_value((double)taken.y));
		*out = pair;
	};
}

<*
 `three.ui.slot` — whether the application has offered a place to draw, and how
 big it is.

 The read half of `UiLayer.set_slot`. A snapshot does not survive
 the slot it was grafted into, so a panel written against an editor watches
 `generation` and re-`set`s when it moves — a pane switched away from and back
 is a different element, and the number is how a script hears about it.

 Deliberately not routed through `ui_layer`: asking where a panel may go must
 not bring a GPU device up, because the answer for a context without one is
 "nowhere" and that is not an error.
*>
fn void js_ui_slot(
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

	bool present = self.renderer != null && self.renderer.ui.slot != null;
	Vec2 size = present ? self.renderer.ui.slot_size() : (Vec2){ 0, 0 };
	// The pane's corner in window points, which is what turns a `three.input`
	// pointer reading into a position inside a panel — see `UiLayer.slot_origin`.
	Vec2 origin = present ? self.renderer.ui.slot_origin() : (Vec2){ 0, 0 };
	// Reported whether or not there is a slot, because the bump that matters most
	// is the one where an offer was withdrawn.
	uint generation = self.renderer == null ? 0 : self.renderer.ui.slot_generation;

	qjs::Value answer = js.object();
	js.set_property(answer, "present", qjs::bool_value(present));
	js.set_property(answer, "generation", qjs::number_value((double)generation));
	js.set_property(answer, "x", qjs::number_value((double)origin.x));
	js.set_property(answer, "y", qjs::number_value((double)origin.y));
	js.set_property(answer, "width", qjs::number_value((double)size.x));
	js.set_property(answer, "height", qjs::number_value((double)size.y));
	*out = answer;
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
*>
fn void js_ui_scale(
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

	if (self.renderer == null)
	{
		*out = qjs::number_value(1.0);
		return;
	}

	if (argc > 0)
	{
		float wanted = arg_float(&js, argc, args, 0);
		if (!(wanted > 0))
		{
			*out = js.raise("three.ui.scale wants a positive number — 1 is the size everything else is written against");
			return;
		}
		self.renderer.ui.set_scale(wanted);
	}

	float now = self.renderer.ui.scale;
	*out = qjs::number_value((double)(now > 0 ? now : 1.0));
}

<*
 `three.ui.patch(key, props)` — write the named fields of one keyed node.

 The retained half of the API, keyed by string rather than by handle: a HUD that
 rebuilt its tree to change one number would be spending every frame doing the
 one thing a retained interface exists to avoid.
*>
fn void js_ui_patch(
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

	UiLayer* layer = self.ui_layer(&js, out) ?? null;
	if (layer == null) return;
	if (argc < 2)
	{
		*out = js.raise("three.ui.patch(key, props) wants a key and the fields to write");
		return;
	}

	@pool()
	{
		String key = arg_text(&js, argc, args, 0, tmem);

		uint? node = layer.node_for(key);
		if (catch node)
		{
			*out = js.raise(
				string::tformat(
					"three.ui.patch: nothing in the interface is keyed '%s'. "
						"A key only exists between the three.ui.set that named it and the next one",
					key
				)
			);
			return;
		}

		qjs::Value props = args[1];
		UiPatch fields = {
			.has_text = has_prop(&js, props, "text"),
			.text = prop_text(&js, props, "text", tmem),
			.has_value = has_prop(&js, props, "value"),
			.value = prop_float(&js, props, "value"),
			.has_checked = has_prop(&js, props, "checked"),
			.checked = prop_truth(&js, props, "checked"),
			.has_selected = has_prop(&js, props, "selected"),
			.selected = (usz)math::max(prop_number(&js, props, "selected"), 0.0),
			.has_offset = has_prop(&js, props, "offset"),
			.offset = prop_float(&js, props, "offset"),
			.has_disabled = has_prop(&js, props, "disabled"),
			.disabled = prop_truth(&js, props, "disabled"),
			.has_color = has_prop(&js, props, "color"),
			.color = prop_vec4(&js, props, "color"),
			.has_min = has_prop(&js, props, "min"),
			.min = prop_float(&js, props, "min"),
			.has_max = has_prop(&js, props, "max"),
			.max = prop_float(&js, props, "max"),
			.has_size = has_prop(&js, props, "size"),
			.size = prop_vec2(&js, props, "size"),
		};
		layer.patch(node, fields);

		// The three list-valued fields, which are a replacement rather than a
		// write: the node's old strings go, the new ones are copied in, and the
		// widget is re-pointed at an array that has stopped growing.
		bool relist;
		if (has_prop(&js, props, "ops"))
		{
			layer.reset_list(node);
			read_ops(&js, layer, props, node);
			relist = true;
		}
		else if (has_prop(&js, props, "options"))
		{
			layer.reset_list(node);
			read_options(&js, layer, props, node);
			relist = true;
		}
		else if (has_prop(&js, props, "rows"))
		{
			layer.reset_list(node);
			read_rows(&js, layer, props, node);
			relist = true;
		}
		else if (has_prop(&js, props, "menus"))
		{
			layer.reset_list(node);
			read_menus(&js, layer, props, node);
			relist = true;
		}
		if (relist) layer.relist(node);
	};
}

// ============================================================================
// Reading a tree
// ============================================================================

<*
 Builds the whole snapshot and swaps it in, or leaves the interface untouched.

 The handler table is built alongside the nodes and installed only on success,
 which is what makes a half-read tree cost nothing: the retained functions are
 released and the node table is thrown away together.
*>
fn void JsRuntime.apply_ui_tree(&self, qjs::Context* js, qjs::Value tree, qjs::Value* out)
{
	UiLayer* layer = self.ui_layer(js, out) ?? null;
	if (layer == null) return;

	if (catch layer.begin_tree(&self.renderer.gpu, &self.renderer.target))
	{
		*out = js.raise("the interface layer could not start");
		return;
	}

	List{UiHandlers} handlers;
	handlers.tinit(8);

	if (catch err = self.read_node(js, tree, -1, &handlers))
	{
		foreach (i, handler : handlers) handlers[i].release(js);
		layer.abandon_tree();
		*out = js.raise(
			"three.ui.set was handed a node the interface does not recognise — every node needs a type, "
			"and a child list has to be an array of nodes"
		);
		return;
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
	String root = self.modules.root;

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
 One node and everything under it, depth first.

 Pre-order because that is the order `push_node` hands out the indices children
 name, and because a parent's element has to exist before anything can be
 appended to it.

 @param parent : `The index this node hangs under, or -1 for the tree's own root.`
*>
fn void? JsRuntime.read_node(&self, qjs::Context* js, qjs::Value value, int parent, List{UiHandlers}* handlers)
{
	UiLayer* layer = &self.renderer.ui;

	int kind = (int)prop_number(js, value, "k", -1);
	if (kind < 0 || kind > UiNodeKind.DIALOG.ordinal) return UI_BAD_PARENT~;

	UiNodeSpec spec = {
		.kind = UiNodeKind::from_ordinal((usz)kind),
		.key = prop_text(js, value, "key", tmem),

		.gap = prop_float(js, value, "gap"),
		.gap_y = prop_float(js, value, "gapY"),
		.size = prop_vec2(js, value, "size"),
		.cell = prop_vec2(js, value, "cell"),
		.main_align = (uint)math::max(prop_number(js, value, "main"), 0.0),
		.cross_align = (uint)math::max(prop_number(js, value, "cross"), 0.0),
		.insets = prop_vec4(js, value, "insets"),
		.radii = prop_vec4(js, value, "radii"),
		.margin = prop_vec2(js, value, "margin"),
		.anchor_h = (uint)math::max(prop_number(js, value, "ah"), 0.0),
		.anchor_v = (uint)math::max(prop_number(js, value, "av"), 0.0),
		.solid = prop_truth(js, value, "solid"),
		.wrap = prop_truth(js, value, "wrap"),
		.modal = prop_truth(js, value, "modal"),
		.close_outside = prop_truth(js, value, "closeOutside"),

		.color = prop_vec4(js, value, "color"),
		.border_color = prop_vec4(js, value, "borderColor"),
		.border_width = prop_float(js, value, "borderWidth"),
		.accent = prop_vec4(js, value, "accent"),
		.hover_color = prop_vec4(js, value, "hoverColor"),
		.press_color = prop_vec4(js, value, "pressColor"),
		.text_color = prop_vec4(js, value, "textColor"),

		.text = prop_text(js, value, "text", tmem),
		.suffix = prop_text(js, value, "suffix", tmem),
		.title = prop_text(js, value, "title", tmem),
		.confirm_label = prop_text(js, value, "confirm", tmem),
		.decline_label = prop_text(js, value, "decline", tmem),
		.font = (uint)math::max(prop_number(js, value, "font"), 0.0),
		.text_size = prop_float(js, value, "textSize"),

		.value = prop_float(js, value, "value"),
		.min = prop_float(js, value, "min"),
		.max = prop_float(js, value, "max"),
		.step = prop_float(js, value, "step"),
		.curve = prop_float(js, value, "curve"),
		.offset = prop_float(js, value, "offset"),
		.decimals = (uint)math::max(prop_number(js, value, "decimals"), 0.0),
		.checked = prop_truth(js, value, "checked"),
		.disabled = prop_truth(js, value, "disabled"),
		.selected = (usz)math::max(prop_number(js, value, "selected"), 0.0),

		.has_text = has_prop(js, value, "text"),
		.has_value = has_prop(js, value, "value"),
		.has_checked = has_prop(js, value, "checked"),
		.has_selected = has_prop(js, value, "selected"),
		.has_offset = has_prop(js, value, "offset"),
	};

	UiHandlers taken;
	taken.has_click  = take_handler(js, value, "onClick", &taken.click);
	taken.has_change = take_handler(js, value, "onChange", &taken.change);
	taken.has_commit = take_handler(js, value, "onCommit", &taken.commit);
	taken.has_submit = take_handler(js, value, "onSubmit", &taken.submit);
	taken.has_select = take_handler(js, value, "onSelect", &taken.select);
	taken.has_toggle = take_handler(js, value, "onToggle", &taken.toggle);
	taken.has_hover  = take_handler(js, value, "onHover", &taken.hover);
	taken.has_confirm = take_handler(js, value, "onConfirm", &taken.confirm);
	taken.has_dismiss = take_handler(js, value, "onDismiss", &taken.dismiss);
	taken.has_choose  = take_handler(js, value, "onChoose", &taken.choose);
	taken.has_pointer = take_handler(js, value, "onPointer", &taken.pointer);

	spec.on_click  = taken.has_click;
	spec.on_change = taken.has_change;
	spec.on_commit = taken.has_commit;
	spec.on_submit = taken.has_submit;
	spec.on_select = taken.has_select;
	spec.on_toggle = taken.has_toggle;
	spec.on_hover  = taken.has_hover;
	spec.on_confirm = taken.has_confirm;
	spec.on_dismiss = taken.has_dismiss;
	spec.on_choose  = taken.has_choose;
	spec.on_pointer = taken.has_pointer;

	// Where a `fileBrowser` may look, decided here and enforced in
	// `render/ui.c3`. This file is the one that knows what an assets directory
	// is, and that is the whole reason the policy is written here rather than
	// beside the widget it confines.
	if (spec.kind == UiNodeKind.FILE_BROWSER) self.confine_browser(&spec);

	// A Tree reports the two edges with different verbs; the JS side spells them
	// onSelect and onToggle, and `UiNodeSpec` keeps them apart for the same
	// reason a Slider's change and commit are apart — a binding that offered only
	// one would make the other impossible.
	uint? index = layer.push_node(spec, parent);
	if (catch index)
	{
		taken.release(js);
		return UI_BAD_PARENT~;
	}

	// One entry per node, in the order the nodes were pushed. The table has to
	// stay aligned even for a node that attached nothing, or every index after it
	// names the wrong widget.
	handlers.push(taken);

	switch (spec.kind)
	{
		case DRAW:
			read_ops(js, layer, value, index);
		case SELECT:
			read_options(js, layer, value, index);
		case TREE:
			read_rows(js, layer, value, index);
		case MENU:
			read_menus(js, layer, value, index);
		case FILE_BROWSER:
			// The mask rides on `options` because it is the same thing: a
			// borrowed `String[]` the snapshot fills in, and a second pair of
			// push verbs for it would differ from `push_option` by nothing.
			read_options(js, layer, value, index);
		default:
			break;
	}

	qjs::Value children = js.property(value, "ch");
	defer js.release(children);
	long count = children.is_undefined() || children.is_null() ? 0 : js.length(children);
	for (long i = 0; i < count; i++)
	{
		qjs::Value child = js.index(children, (uint)i);
		defer js.release(child);
		self.read_node(js, child, (int)index, handlers)!;
	}
}

<*
 A `draw` node's op list, in paint order.

 The `o` field is the op kind as `js/prelude/ui.js` numbered it; everything else
 is read by name whether or not the kind uses it, because a zero costs a read and
 a switch per field costs seven.
*>
fn void read_ops(qjs::Context* js, UiLayer* layer, qjs::Value node, uint index) @local
{
	qjs::Value ops = js.property(node, "ops");
	defer js.release(ops);
	long count = ops.is_undefined() || ops.is_null() ? 0 : js.length(ops);

	for (long i = 0; i < count; i++)
	{
		qjs::Value entry = js.index(ops, (uint)i);
		defer js.release(entry);

		int kind = (int)prop_number(js, entry, "o", -1);
		if (kind < 0 || kind > UiOpKind.SHADOW.ordinal) continue;

		layer.push_op(
			index,
			{
				.kind = UiOpKind::from_ordinal((usz)kind),
				.at = prop_vec2(js, entry, "at"),
				.to = prop_vec2(js, entry, "to"),
				.radius = prop_float(js, entry, "r"),
				.thickness = prop_float(js, entry, "th"),
				.start = prop_float(js, entry, "s"),
				.sweep = prop_float(js, entry, "sw"),
				.blur = prop_float(js, entry, "blur"),
				.size = prop_float(js, entry, "size"),
				.font = (uint)math::max(prop_number(js, entry, "font"), 0.0),
				.color = prop_vec4(js, entry, "color"),
				.border_color = prop_vec4(js, entry, "borderColor"),
				.border_width = prop_float(js, entry, "bw"),
				.corners = prop_vec4(js, entry, "corners"),
				.text = prop_text(js, entry, "text", tmem),
			}
		);
	}
}

fn void read_options(qjs::Context* js, UiLayer* layer, qjs::Value node, uint index) @local
{
	qjs::Value options = js.property(node, "options");
	defer js.release(options);
	long count = options.is_undefined() || options.is_null() ? 0 : js.length(options);

	for (long i = 0; i < count; i++)
	{
		qjs::Value entry = js.index(options, (uint)i);
		defer js.release(entry);
		layer.push_option(index, js.text(entry, tmem));
	}
}

<*
 A `menu` bar's two levels, in order.

 One pass rather than two verbs, because the nesting is the whole difference
 between this and `read_options`: an item belongs to the title above it, and the
 layer records that by which `push_menu` was last.
*>
fn void read_menus(qjs::Context* js, UiLayer* layer, qjs::Value node, uint index) @local
{
	qjs::Value menus = js.property(node, "menus");
	defer js.release(menus);
	long count = menus.is_undefined() || menus.is_null() ? 0 : js.length(menus);

	for (long i = 0; i < count; i++)
	{
		qjs::Value menu = js.index(menus, (uint)i);
		defer js.release(menu);
		layer.push_menu(index, prop_text(js, menu, "title", tmem));

		qjs::Value items = js.property(menu, "items");
		defer js.release(items);
		long entries = items.is_undefined() || items.is_null() ? 0 : js.length(items);
		for (long at = 0; at < entries; at++)
		{
			qjs::Value item = js.index(items, (uint)at);
			defer js.release(item);
			layer.push_menu_item(
				index,
				prop_text(js, item, "label", tmem),
				prop_text(js, item, "shortcut", tmem),
				prop_truth(js, item, "checked"),
				prop_truth(js, item, "disabled"),
				prop_truth(js, item, "separator")
			);
		}
	}
}

fn void read_rows(qjs::Context* js, UiLayer* layer, qjs::Value node, uint index) @local
{
	qjs::Value rows = js.property(node, "rows");
	defer js.release(rows);
	long count = rows.is_undefined() || rows.is_null() ? 0 : js.length(rows);

	for (long i = 0; i < count; i++)
	{
		qjs::Value entry = js.index(rows, (uint)i);
		defer js.release(entry);
		layer.push_row(
			index,
			prop_text(js, entry, "label", tmem),
			prop_text(js, entry, "trailing", tmem),
			(usz)math::max(prop_number(js, entry, "depth"), 0.0),
			prop_truth(js, entry, "expandable"),
			prop_truth(js, entry, "expanded")
		);
	}
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
fn qjs::Value JsRuntime.pointer_object(&self, UiEvent event)
{
	qjs::Value out = self.js.object();
	self.js.set_property(out, "phase", self.js.string(ui_phase_name(event.phase)));
	self.js.set_property(out, "x", qjs::number_value((double)event.at.x));
	self.js.set_property(out, "y", qjs::number_value((double)event.at.y));
	self.js.set_property(out, "buttons", qjs::int_value((int)event.buttons));
	self.js.set_property(out, "button", qjs::int_value((int)event.index));
	self.js.set_property(out, "wheel", qjs::number_value((double)event.value));
	self.js.set_property(out, "wheelX", qjs::number_value((double)event.wheel_x));
	self.js.set_property(out, "shift", qjs::bool_value((event.modifiers & 1) != 0));
	self.js.set_property(out, "ctrl", qjs::bool_value((event.modifiers & 2) != 0));
	self.js.set_property(out, "alt", qjs::bool_value((event.modifiers & 4) != 0));
	self.js.set_property(out, "meta", qjs::bool_value((event.modifiers & 8) != 0));
	return out;
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

	UiHandlers* handlers = &self.ui_handlers[node];

	qjs::Value callback;
	bool* alive;
	String what;
	int argc;
	qjs::Value[2] argv;

	switch (event.kind)
	{
		case CLICK:
			callback = handlers.click;
			alive = &handlers.has_click;
			what = "onClick";
		case HOVER:
			callback = handlers.hover;
			alive = &handlers.has_hover;
			what = "onHover";
			argc = 1;
			argv[0] = qjs::bool_value(event.flag);
		case TOGGLE:
			callback = handlers.change;
			alive = &handlers.has_change;
			what = "onChange";
			argc = 1;
			argv[0] = qjs::bool_value(event.flag);
		case SLIDE:
			callback = handlers.change;
			alive = &handlers.has_change;
			what = "onChange";
			argc = 1;
			argv[0] = qjs::number_value((double)event.value);
		case COMMIT:
			callback = handlers.commit;
			alive = &handlers.has_commit;
			what = "onCommit";
			argc = 1;
			argv[0] = qjs::number_value((double)event.value);
		case PICK:
			callback = handlers.change;
			alive = &handlers.has_change;
			what = "onChange";
			argc = 1;
			argv[0] = qjs::int_value((int)event.index);
		case ROW_SELECT:
			callback = handlers.select;
			alive = &handlers.has_select;
			what = "onSelect";
			argc = 1;
			argv[0] = qjs::int_value((int)event.index);
		case ROW_TOGGLE:
			callback = handlers.toggle;
			alive = &handlers.has_toggle;
			what = "onToggle";
			argc = 1;
			argv[0] = qjs::int_value((int)event.index);
		case TEXT_CHANGE:
			callback = handlers.change;
			alive = &handlers.has_change;
			what = "onChange";
			argc = 1;
			argv[0] = self.js.string(event.text);
		case TEXT_SUBMIT:
			callback = handlers.submit;
			alive = &handlers.has_submit;
			what = "onSubmit";
			argc = 1;
			argv[0] = self.js.string(event.text);
		case CONFIRM:
			callback = handlers.confirm;
			alive = &handlers.has_confirm;
			what = "onConfirm";
		case DISMISS:
			callback = handlers.dismiss;
			alive = &handlers.has_dismiss;
			what = "onDismiss";
		case DIALOG_DISMISS:
			// The same handler name as a confirmation's, because it is the same
			// event to a script: the panel is gone and nobody pressed anything
			// that means yes. A second spelling would only make a panel that
			// swapped one kind for the other rename its handler.
			callback = handlers.dismiss;
			alive = &handlers.has_dismiss;
			what = "onDismiss";
		case MENU_PICK:
			// The one handler here that takes two numbers: a bar is a list of
			// lists, and which title it was is not recoverable from the item.
			callback = handlers.select;
			alive = &handlers.has_select;
			what = "onSelect";
			argc = 2;
			argv[0] = qjs::int_value((int)event.index);
			argv[1] = qjs::int_value((int)event.item);
		case FILE_CHOOSE:
			callback = handlers.choose;
			alive = &handlers.has_choose;
			what = "onChoose";
			argc = 1;
			argv[0] = self.js.string(event.text);
		case FILE_SELECT:
			callback = handlers.select;
			alive = &handlers.has_select;
			what = "onSelect";
			argc = 1;
			argv[0] = self.js.string(event.text);
		case FILE_DIRECTORY:
			// `onChange` rather than a fourth name, because where the browser is
			// IS its value — the thing a breadcrumb beside it displays.
			callback = handlers.change;
			alive = &handlers.has_change;
			what = "onChange";
			argc = 1;
			argv[0] = self.js.string(event.text);
		case POINTER:
			// One object rather than nine positional arguments. Everything else
			// here hands over the one number the widget changed; this hands over
			// a pointer, and a panel reads two or three fields of it and ignores
			// the rest — which is what a named bag is for. Built only when there
			// is somebody to give it to, because this fires every frame the
			// pointer is over the node.
			callback = handlers.pointer;
			alive = &handlers.has_pointer;
			what = "onPointer";
			if (handlers.has_pointer)
			{
				argc = 1;
				argv[0] = self.pointer_object(event);
			}
	}

	if (!*alive)
	{
		for (int i = 0; i < argc; i++) self.js.release(argv[i]);
		return;
	}

	// Raised for the whole of the call, so a handler calling `three.ui.set` is
	// held rather than restructuring the tree cui is walking. The layer raises
	// its own flag around `process_input`; this one is narrower and is what the
	// verbs actually read, because a `patch` from a handler is perfectly safe and
	// only a rebuild is not.
	self.ui_dispatching = true;
	defer self.ui_dispatching = false;

	@pool()
	{
		qjs::Value? answer = self.js.call(callback, qjs::undefined_value(), argv[:argc]);
		for (int i = 0; i < argc; i++) self.js.release(argv[i]);

		if (catch err = answer)
		{
			self.report_frame_failure(
				self.timed_out ? self.frame_timeout_message()
					: string::tformat(
						"a three.ui %s handler threw and was stopped: %s",
						what,
						self.js.exception(tmem)
					)
			);
			self.js.release(callback);
			*alive = false;
			return;
		}

		bool promised = self.is_thenable(answer);
		self.js.release(answer);
		if (promised)
		{
			self.report_frame_failure(
				string::tformat(
					"a three.ui %s handler returned a promise. It has to finish inside the frame, "
						"so it must be synchronous — do the awaiting in a run_script instead",
					what
				)
			);
			self.js.release(callback);
			*alive = false;
		}
	};
}

// ============================================================================
// The queue, and cleanup
// ============================================================================

<*
 Holds a snapshot a handler asked for until the dispatch it came from is over.

 One slot, not a queue: two `set` calls in one dispatch mean the second is what
 the script wanted, exactly as two calls outside one do.
*>
fn void JsRuntime.hold_ui_tree(&self, qjs::Context* js, qjs::Value tree)
{
	if (self.ui_pending_held) js.release(self.ui_pending);
	self.ui_pending = tree.is_undefined() || tree.is_null() ? qjs::undefined_value() : js.retain(tree);
	self.ui_pending_held = !tree.is_undefined() && !tree.is_null();
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

	if (!self.ui_pending_held)
	{
		self.drop_ui_tree();
		return;
	}

	qjs::Value tree = self.ui_pending;
	self.ui_pending = qjs::undefined_value();
	self.ui_pending_held = false;
	defer self.js.release(tree);

	@pool()
	{
		qjs::Value thrown = qjs::undefined_value();
		self.apply_ui_tree(&self.js, tree, &thrown);
		if (!thrown.is_undefined())
		{
			self.report_frame_failure("three.ui.set from a widget handler could not be applied");
			self.js.release(thrown);
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
 Releases every retained widget callback.

 Bound by the same rule as `clear_key_handlers`: before the context goes, never
 after — each of these is a reference into an engine that would no longer be
 there to release it into.
*>
fn void JsRuntime.clear_ui_handlers(&self)
{
	foreach (i, handler : self.ui_handlers) self.ui_handlers[i].release(&self.js);
	self.ui_handlers.clear();
	if (self.ui_pending_held)
	{
		self.js.release(self.ui_pending);
		self.ui_pending = qjs::undefined_value();
		self.ui_pending_held = false;
	}
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
}
