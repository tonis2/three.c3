<*
 `three.UiPanel` — an interface on a quad in the scene, as a script reaches it.

 `render/ui_panel.c3` draws it; this file is the crossing. It owns what is the
 script's about a panel: the binding its widgets call back through, and the id
 the prelude's `UiPanel` holds it by (`js/prelude/panel.js`).

 A panel's tree is read by the same walk as `three.ui.set`'s, into the panel's
 own layer, and its handlers fire through the same listener, from inside the
 script's own `panel.pointer(...)` call: that is the one moment the panel is fed.
*>
module three;

import std::math;
import std::collections::list;
import fastjs::js;

<*
 One panel and the binding its widgets call back through. Heap-allocated, since
 the binding's address is the listener's host.
*>
struct PanelBinding
{
	UiPanel* panel;
	UiBinding ui;
}

<*
 What `panelCreate` answers: the id, and the image as a `Texture` wants it.
*>
struct PanelMade
{
	int id;
	int texture;
	uint width;
	uint height;
	uint levels;
}

<*
 What `panelPointer` answers. `hit` false is a miss, which was still fed.
*>
struct PanelReport
{
	bool hit;
	float x;
	float y;
	float distance;
	bool on_widget;
}

// The longest side a panel may have: its image is a texture like any other.
const int PANEL_SIDE_MAX = 4096;

<*
 @return? js::THREW
*>
fn void? JsRuntime.bind_panel_verbs(&self, js::Value host)
{
	self.js.@bind(host, "panelCreate", &js_panel_create, self)!;
	self.js.@bind(host, "panelSet", &js_panel_set, self)!;
	self.js.@bind(host, "panelPatch", &js_panel_patch, self)!;
	self.js.@bind(host, "panelPointer", &js_panel_pointer, self)!;
	self.js.@bind(host, "panelRedraws", &js_panel_redraws, self)!;
	self.js.@bind(host, "panelDispose", &js_panel_dispose, self)!;
}

<*
 The live panel an id names, or a throw naming the mistake.

 @return? js::THREW
*>
fn PanelBinding*? JsRuntime.panel_at(&self, int id)
{
	if (id < 0 || (sz)id >= self.panels.len() || self.panels[id] == null)
	{
		return self.js.fail("that UiPanel was disposed — make a new one")~;
	}
	return self.panels[id];
}

<*
 `panelCreate(width, height, scale, sizeX, sizeY)` — a panel and its image.

 The image starts at one reference, the panel's; the `Texture` the prelude
 wraps it in takes a second, so a material can go on wearing it after the panel
 is disposed and the script's handle is what finally lets it go.

 @return? js::THREW
*>
fn PanelMade? js_panel_create(JsRuntime* self, int width, int height, float scale, Vec2 size)
{
	if (self.renderer == null) return self.js.fail("a UiPanel needs a GPU device and this context has none")~;
	if (width < 1 || height < 1 || width > PANEL_SIDE_MAX || height > PANEL_SIDE_MAX)
	{
		return self.js.fail("a UiPanel's width and height are pixels from 1 to %d, and it was given %dx%d",
			PANEL_SIDE_MAX, width, height)~;
	}
	if (!(scale > 0) || !(size.x > 0) || !(size.y > 0))
	{
		return self.js.fail("a UiPanel wants a positive scale and size")~;
	}

	UiPanel*? made = self.renderer.create_panel((uint)width, (uint)height, scale, size);
	if (catch err = made) return self.js.fail("the UiPanel's image or its interface could not be made: %s", err)~;

	PanelBinding* bound = mem::new(PanelBinding);
	bound.panel = made;
	bound.ui = { .runtime = self, .layer = &made.layer, .name = "UiPanel" };
	bound.ui.handlers.init(mem, 0);
	bound.ui.listen();
	self.panels.push(bound);

	self.pass.assets.retain_texture(made.texture);
	self.hold_texture(made.texture);
	return {
		.id = (int)self.panels.len() - 1,
		.texture = made.texture,
		.width = made.extent.width,
		.height = made.extent.height,
		.levels = made.levels,
	};
}

<*
 `panelSet(id, tree)` — the panel's interface as one snapshot, read by the walk
 `three.ui.set` uses; null takes it down.

 @return? js::THREW
*>
fn void? js_panel_set(JsRuntime* self, int id, js::Value tree)
{
	PanelBinding* bound = self.panel_at(id)!;
	self.set_tree(&bound.ui, tree)!;
}

<*
 `panelPatch(id, key, props)` — one keyed node of the panel, as `three.ui.patch`.

 @return? js::THREW
*>
fn void? js_panel_patch(JsRuntime* self, int id, String key, js::Value props)
{
	PanelBinding* bound = self.panel_at(id)!;
	self.patch_tree(&bound.panel.layer, key, props, "UiPanel")!;
}

<*
 `panelPointer(id, node, origin, direction, down, scroll)` — one frame of
 pointer, from a ray in the world.

 The mesh's world matrix comes from its own branch of the scene rather than the
 whole walk, so a wrist panel asked every frame costs its few ancestors. A
 hidden panel is missed. Widget handlers run inside this call, and a `set` one
 of them asked for is applied before it returns.

 @return? js::THREW
*>
fn PanelReport? js_panel_pointer(JsRuntime* self, int id, NodeRef ref, Vec3 origin, Vec3 direction, bool down,
	float scroll)
{
	PanelBinding* bound = self.panel_at(id)!;
	ref.scene.update_subtree_matrices(ref.id);
	Node* node = ref.scene.node(ref.id);
	if (node == null) return self.js.fail("that UiPanel's mesh is not in a scene")~;

	// A hidden panel is fed a ray that meets nothing, so what it was hovering lets go.
	Vec3 aim = node.world_visible ? direction : (Vec3){ 0, 0, 0 };
	PanelHit hit = bound.panel.point(node.world, origin, aim, down, math::is_finite(scroll) ? scroll : 0);
	self.flush_tree(&bound.ui);
	return { .hit = hit.hit, .x = hit.x, .y = hit.y, .distance = hit.distance, .on_widget = hit.taken };
}

<*
 `panelRedraws(id)` — how many times the panel's image has been drawn.

 @return? js::THREW
*>
fn uint? js_panel_redraws(JsRuntime* self, int id)
{
	return self.panel_at(id)!.panel.redraws;
}

<*
 `panelDispose(id)` — the panel goes, and the id with it. Its image stays while
 the script's `Texture` or a material still holds it.
*>
fn void js_panel_dispose(JsRuntime* self, int id)
{
	if (id < 0 || (sz)id >= self.panels.len() || self.panels[id] == null) return;
	self.free_panel_binding(self.panels[id]);
	self.panels[id] = null;
}

<*
 One panel and its binding, gone: the handlers first, while the layer that calls
 them still exists.

 @param [&inout] bound : "Freed here"
*>
fn void JsRuntime.free_panel_binding(&self, PanelBinding* bound)
{
	self.drop_tree(&bound.ui);
	bound.ui.handlers.free();
	if (self.renderer != null) self.renderer.free_panel(bound.panel);
	free(bound);
}

<*
 Every panel this context made, on its way out: a reload builds a new context
 against the same renderer, which must not go on drawing the old one's panels.
*>
fn void JsRuntime.release_panels(&self)
{
	foreach (bound : self.panels)
	{
		if (bound != null) self.free_panel_binding(bound);
	}
	self.panels.clear();
}
