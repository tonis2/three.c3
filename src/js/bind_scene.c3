<*
 `globalThis.__three` — the flat verbs `prelude.js` is written against.

 ## Why this layer is flat and boring

 Everything Three.js-shaped — classes, prototype chains, `children` arrays,
 getters that write through, `add`/`remove`/`traverse` — lives in `prelude.js`,
 because in JavaScript those are ordinary and in a host binding each one is a
 function. What is left here is the set of things JavaScript genuinely cannot do:
 reach the scene graph, the asset table, the camera and the device. Each is one
 verb, takes numbers, and answers with numbers.

 ## Handles are (index, generation), revalidated on every call

 `plan.md` §1 requires a JS handle to revalidate on access and *throw* rather
 than dereference a freed node, which is what `NodeId`'s generation was built for
 at M2. Every verb below that names a node resolves it through `Scene.node`
 first, and a stale one raises a JS `Error` naming what happened — a script that
 keeps a mesh across a `new three.Scene()` gets a sentence, not a corrupted
 neighbour.

 The pair crosses as two plain numbers rather than as an opaque object because
 the shim has no way to hang host data off a JS object: `JS_SetOpaque` needs a
 class id, and `Context.function`'s opaque is per function, not per instance.
 A script can read and forge them; forging one produces the stale-handle throw,
 which is why revalidation is the guard rather than concealment.
*>
module three;

import std::math;
import std::math::vector;
import collision;
import qjs;
import std::collections::list;

<*
 Install `__three` on the global object.

 Called before `prelude.js` is evaluated — it opens by reading `__three` and
 throws if it is missing.
*>
fn void JsRuntime.install_bindings(&self)
{
	qjs::Value global = self.js.global();
	defer self.js.release(global);

	qjs::Value host = self.js.object();

	// Assets (js/bind_asset.c3)
	self.bind(host, "load", &js_load, 1);
	self.bind(host, "texture", &js_texture, 4);
	self.bind(host, "dataTexture", &js_data_texture, 6);
	self.bind(host, "textureDispose", &js_texture_dispose, 1);
	self.bind(host, "textureRead", &js_texture_read, 2);
	self.bind(host, "textureSave", &js_texture_save, 2);
	self.bind(host, "primitive", &js_primitive, 9);
	self.bind(host, "convex", &js_convex, 1);
	self.bind(host, "extrude", &js_extrude, 4);
	self.bind(host, "ribbon", &js_ribbon, 5);
	self.bind(host, "terrain", &js_terrain, 5);
	self.bind(host, "terrainAt", &js_terrain_at, 4);
	self.bind(host, "lines", &js_lines, 2);
	self.bind(host, "wireframe", &js_wireframe, 3);
	self.bind(host, "checkAsset", &js_check_asset, 2);
	self.bind(host, "assetPath", &js_asset_path, 2);
	self.bind(host, "meshNames", &js_mesh_names, 2);
	self.bind(host, "meshBounds", &js_mesh_bounds, 3);
	self.bind(host, "assetImages", &js_asset_images, 2);
	self.bind(host, "assetImage", &js_asset_image, 5);
	self.bind(host, "uploadMesh", &js_upload_mesh, 5);
	self.bind(host, "meshLayers", &js_mesh_layers, 3);
	self.bind(host, "meshMaterial", &js_mesh_material, 3);
	self.bind(host, "splitMesh", &js_split_mesh, 3);
	self.bind(host, "merge", &js_merge, 5);
	self.bind(host, "assetNodes", &js_asset_nodes, 3);
	self.bind(host, "assetClips", &js_asset_clips, 2);
	self.bind(host, "assetBones", &js_asset_bones, 2);
	self.bind(host, "bindAnimation", &js_bind_animation, 6);
	self.bind(host, "bindSkin", &js_bind_skin, 4);
	self.bind(host, "bindSocket", &js_bind_socket, 5);
	self.bind(host, "unbindSocket", &js_unbind_socket, 2);
	self.bind(host, "setMorphWeights", &js_set_morph_weights, 3);
	self.bind(host, "meshMorphs", &js_mesh_morphs, 3);
	self.bind(host, "playAnimation", &js_play_animation, 7);
	self.bind(host, "stopAnimation", &js_stop_animation, 2);
	self.bind(host, "inventory", &js_inventory, 0);
	self.bind(host, "assetText", &js_asset_text, 1);
	self.bind(host, "assetWriteText", &js_asset_write_text, 2);
	self.bind(host, "exportScene", &js_export, 4);

	// The graph
	self.bind(host, "sceneCreate", &js_scene_create, 0);
	self.bind(host, "sceneActivate", &js_scene_activate, 1);
	self.bind(host, "sceneDispose", &js_scene_dispose, 1);
	self.bind(host, "sceneAlive", &js_scene_alive, 1);
	self.bind(host, "sceneActive", &js_scene_active, 0);
	self.bind(host, "sceneIds", &js_scene_ids, 0);
	self.bind(host, "disposeInactive", &js_dispose_inactive, 0);
	self.bind(host, "add", &js_add, 6);
	self.bind(host, "remove", &js_remove, 2);
	self.bind(host, "setParent", &js_set_parent, 4);
	self.bind(host, "setTransform", &js_set_transform, 11);
	self.bind(host, "setQuaternion", &js_set_quaternion, 6);
	self.bind(host, "setVisible", &js_set_visible, 3);
	self.bind(host, "setStatic", &js_set_static, 3);
	self.bind(host, "setCollides", &js_set_collides, 3);
	self.bind(host, "setName", &js_set_name, 3);
	self.bind(host, "setColor", &js_set_color, 6);
	self.bind(host, "setVariant", &js_set_variant, 3);
	self.bind(host, "worldPosition", &js_world_position, 2);
	self.bind(host, "objectBounds", &js_object_bounds, 2);

	// Picking
	self.bind(host, "pick", &js_pick, 2);
	self.bind(host, "raycast", &js_raycast, 6);

	// Materials (js/bind_shader.c3)
	self.bind_shader_verbs(host);

	// The one post shader (js/bind_post.c3)
	self.bind_post_verbs(host);

	// The interface (js/bind_ui.c3)
	self.bind_ui_verbs(host);

	// The animation loop (js/frame_loop.c3)
	self.bind_frame_verbs(host);

	// The keyboard (js/bind_input.c3)
	self.bind_input_verbs(host);

	// Saving (js/bind_save.c3)
	self.bind_save_verbs(host);

	// Physics (js/bind_physics.c3)
	self.bind_physics_verbs(host);

	// Bulk queries, the character controller and the batched write
	// (js/bind_query.c3)
	self.bind_query_verbs(host);

	// Navigation and steering (js/bind_nav.c3)
	self.bind_nav_verbs(host);

	// The frame
	self.bind(host, "stats", &js_stats, 1);
	self.bind(host, "debugWrite", &js_debug_write, 1);
	self.bind(host, "debugOverlay", &js_debug_overlay, 1);
	self.bind(host, "unloadUnused", &js_unload_unused, 0);
	// Hot reload (reload.c3), and closing the window (main.c3)
	self.bind(host, "reload", &js_reload, 0);
	self.bind(host, "quit", &js_quit, 0);
	self.bind(host, "render", &js_render, 0);
	self.bind(host, "screenshot", &js_screenshot, 1);
	self.bind(host, "renderSize", &js_render_size, 0);
	self.bind(host, "renderResize", &js_render_resize, 2);
	self.bind(host, "renderFollowWindow", &js_render_follow_window, 0);
	self.bind(host, "backgroundGet", &js_background_get, 1);
	self.bind(host, "backgroundSet", &js_background_set, 4);
	self.bind(host, "skyGet", &js_sky_get, 1);
	self.bind(host, "skySet", &js_sky_set, 6);
	self.bind(host, "budgetGet", &js_budget_get, 0);
	self.bind(host, "budgetSet", &js_budget_set, 1);
	self.bind(host, "clockTime", &js_clock_time, 0);
	self.bind(host, "clockWall", &js_clock_wall, 0);
	self.bind(host, "clockDelta", &js_clock_delta, 0);
	self.bind(host, "clockScaleGet", &js_clock_scale_get, 0);
	self.bind(host, "clockScaleSet", &js_clock_scale_set, 1);
	self.bind(host, "clockRateGet", &js_clock_rate_get, 0);
	self.bind(host, "clockRateSet", &js_clock_rate_set, 1);
	self.bind(host, "clockAdvance", &js_clock_advance, 1);
	self.bind(host, "lightCount", &js_light_count, 0);
	self.bind(host, "lightGet", &js_light_get, 1);
	self.bind(host, "lightSet", &js_light_set, 8);
	self.bind(host, "lightAdd", &js_light_add, 7);
	self.bind(host, "lightRemove", &js_light_remove, 1);
	self.bind(host, "ambientGet", &js_ambient_get, 0);
	self.bind(host, "ambientSet", &js_ambient_set, 1);
	self.bind(host, "shadowGet", &js_shadow_get, 0);
	self.bind(host, "shadowSet", &js_shadow_set, 6);
	self.bind(host, "shadowFit", &js_shadow_fit, 0);
	self.bind(host, "debugViewGet", &js_debug_view_get, 0);
	self.bind(host, "debugViewSet", &js_debug_view_set, 1);
	self.bind(host, "cameraGet", &js_camera_get, 0);
	self.bind(host, "cameraSet", &js_camera_set, 8);
	self.bind(host, "cameraAttach", &js_camera_attach, 8);
	self.bind(host, "cameraDetach", &js_camera_detach, 0);
	self.bind(host, "cameraAttached", &js_camera_attached, 0);
	self.bind(host, "cameraRay", &js_camera_ray, 2);
	self.bind(host, "frameAll", &js_frame_all, 0);

	self.js.set_property(global, "__three", host);
}

fn void JsRuntime.bind(&self, qjs::Value host, ZString name, qjs::HostFn body, int arity)
{
	self.js.set_property(host, name, self.js.function(body, name, arity, self));
}

// ============================================================================
// Reading arguments
// ============================================================================

fn double arg_number(qjs::Context* js, int argc, qjs::Value* args, int at)
{
	if (at >= argc) return 0;
	return js.number(args[at]);
}

fn int arg_int(qjs::Context* js, int argc, qjs::Value* args, int at)
{
	return (int)arg_number(js, argc, args, at);
}

fn float arg_float(qjs::Context* js, int argc, qjs::Value* args, int at)
{
	return (float)arg_number(js, argc, args, at);
}

fn String arg_text(qjs::Context* js, int argc, qjs::Value* args, int at, Allocator allocator)
{
	if (at >= argc) return "".copy(allocator);
	return js.text(args[at], allocator);
}

fn bool arg_truth(qjs::Context* js, int argc, qjs::Value* args, int at)
{
	if (at >= argc) return false;
	return js.truth(args[at]);
}

<*
 A flag whose absence means something other than false.

 `arg_truth` answers false for an argument that is not there, which is right for
 a flag that switches something on and exactly wrong for one that switches
 something off. `generateMipmaps` defaults to true, so reading it with
 `arg_truth` would build no chain for every caller that did not mention it —
 which is every caller written before the argument existed, and a regression that
 looks like nothing at all until a floor is seen at a distance.
*>
fn bool arg_truth_or(qjs::Context* js, int argc, qjs::Value* args, int at, bool fallback)
{
	if (at >= argc) return fallback;
	return js.truth(args[at]);
}

<*
 A node handle as JavaScript sees it: `[index, generation]`.
*>
fn qjs::Value handle_value(qjs::Context* js, NodeId id)
{
	qjs::Value pair = js.array();
	js.set_index(pair, 0, qjs::int_value((int)id.index));
	js.set_index(pair, 1, qjs::int_value((int)id.generation));
	return pair;
}

<*
 An `AssetId` as `[index, generation]`, the same shape a `NodeId` crosses in.

 Two numbers rather than an object because the prelude immediately destructures
 it, and because an object would allocate a shape per load.
*>
fn qjs::Value asset_value(qjs::Context* js, AssetId id)
{
	qjs::Value pair = js.array();
	js.set_index(pair, 0, qjs::int_value((int)id.index));
	js.set_index(pair, 1, qjs::int_value((int)id.generation));
	return pair;
}

<*
 Read `(index, generation)` from `args[at]` and `args[at + 1]` and resolve it.

 The asset half of `arg_handle`, and the sentence is the one an unloaded asset
 earns: since G2 a slot is reused, so "no such asset" and "that asset was
 unloaded and something else is there now" are different things to have done,
 and only the second one is worth a word about `unloadUnused`.

 @return `The handle, or NO_ASSET with a JS exception left pending, in which case the caller must write out and return immediately.`
*>
fn AssetId arg_asset(JsRuntime* self, qjs::Context* js, int argc, qjs::Value* args, int at, qjs::Value* out)
{
	AssetId id = {
		.index = (uint)arg_int(js, argc, args, at),
		.generation = (uint)arg_int(js, argc, args, at + 1),
	};
	if (self.pass == null || self.pass.assets.slot(id) == null)
	{
		*out = js.raise(
			"that asset is no longer loaded — three.unloadUnused() or scene.unload() freed it, "
				"and loading the file again gives a fresh handle"
		);
		return NO_ASSET;
	}
	return id;
}

fn qjs::Value vec3_value(qjs::Context* js, Vec3 v)
{
	qjs::Value triple = js.array();
	js.set_index(triple, 0, qjs::number_value(v.x));
	js.set_index(triple, 1, qjs::number_value(v.y));
	js.set_index(triple, 2, qjs::number_value(v.z));
	return triple;
}

<*
 A box as six numbers, `[minX, minY, minZ, maxX, maxY, maxZ]`.

 Flat rather than `{min, max}` because `prelude.js` derives `size` and `center`
 from it anyway, and one array of six is one allocation where a nested pair is
 three. The shape a script sees is built there.
*>
fn qjs::Value aabb_value(qjs::Context* js, collision::Aabb3 box)
{
	qjs::Value six = js.array();
	js.set_index(six, 0, qjs::number_value(box.min.x));
	js.set_index(six, 1, qjs::number_value(box.min.y));
	js.set_index(six, 2, qjs::number_value(box.min.z));
	js.set_index(six, 3, qjs::number_value(box.max.x));
	js.set_index(six, 4, qjs::number_value(box.max.y));
	js.set_index(six, 5, qjs::number_value(box.max.z));
	return six;
}

<*
 A resolved handle: the node, and the scene it turned out to be in.

 A pair rather than a `NodeId` on purpose. There is more than one scene now, so
 "which graph does this verb operate on" is an answer a verb has to be *given*
 rather than one it can assume — and a verb that reached for `self.pass.scene`
 instead would write into whichever world happened to be on screen. Making
 `arg_handle` answer with a type that is not a `NodeId` is what turns every one
 of those into a compile error rather than into a silent wrong-scene write.
*>
struct NodeRef
{
	Scene* scene;
	NodeId id;
}

<*
 Read `(index, generation)` from `args[at]` and `args[at + 1]` and resolve it.

 Searched across every scene, active one first, because a script holding an
 object from the level it is building has a perfectly good handle and the verb
 should work. The search is safe because node generations come from one
 process-wide counter — see `next_node_generation` — so a handle matches in at
 most one scene, and a handle into a disposed scene matches in none.

 Linear over the scene list, which is a handful of pointers and two bounds checks
 apiece. A game has one scene; a transition has two.

 @return `The node and its scene, or a null scene with a JS exception left pending, in which case the caller must write out and return immediately.`
*>
fn NodeRef arg_handle(JsRuntime* self, qjs::Context* js, int argc, qjs::Value* args, int at, qjs::Value* out)
{
	NodeId id = {
		.index = (uint)arg_int(js, argc, args, at),
		.generation = (uint)arg_int(js, argc, args, at + 1),
	};
	if (self.pass != null)
	{
		if (self.pass.scene != null && self.pass.scene.node(id) != null)
		{
			return { .scene = self.pass.scene, .id = id };
		}
		foreach (each : self.pass.scenes)
		{
			if (each.node(id) != null) return { .scene = each, .id = id };
		}
	}
	*out = js.raise("that object is no longer in the scene — it was removed, or the scene it was in was disposed");
	return { };
}

<*
 Read a scene id from `args[at]` and resolve it.

 For the verbs that are about a whole scene rather than about a node in one —
 gravity, the body count, a nav bake. Those have no handle to find the scene
 from, so the id crosses explicitly.

 @return `The scene, or null with a JS exception left pending.`
*>
fn Scene* arg_scene(JsRuntime* self, qjs::Context* js, int argc, qjs::Value* args, int at, qjs::Value* out)
{
	uint id      = (uint)arg_int(js, argc, args, at);
	Scene* found = self.pass == null ? null : self.pass.scene_by_id(id);
	if (found == null)
	{
		*out = js.raise("that Scene was disposed — its objects, its bodies and its nav bake are gone");
		return null;
	}
	return found;
}

<*
 The same, refused unless the node is in the scene being rendered.

 For the verbs that are about the frame rather than about the graph — physics,
 the camera follow, the spatial index. Those reach for one world per frame, and
 a handle from a scene that is not being drawn has no answer they could give that
 would not be a lie.
*>
fn NodeRef arg_live_handle(
	JsRuntime* self,
	qjs::Context* js,
	int argc,
	qjs::Value* args,
	int at,
	qjs::Value* out,
	String verb
)
{
	NodeRef ref = arg_handle(self, js, argc, args, at, out);
	if (ref.scene == null) return ref;
	if (ref.scene != self.pass.scene)
	{
		*out = js.raise(
			string::tformat(
				"%s needs an object in the scene being rendered — call scene.activate() on the one it is in first",
				verb
			)
		);
		return { };
	}
	return ref;
}

// ============================================================================
// The graph
// ============================================================================

<*
 A new scene, made active — `new three.Scene()`.

 Three.js's meaning, and the divergence this removes: the scene that was active
 stays exactly as it was, with its nodes, its bodies and its asset references. A
 script holding it can go on building it, and `scene.activate()` shows it again.

 What that costs is a world nobody frees, so `SceneStats.scenes` counts them and
 `MeshPass.note_scene_created` says something when the count starts to look like
 a level transition that forgot `scene.dispose()`.

 @return `The triple [sceneId, rootIndex, rootGeneration]. The root comes back with the id because a Scene needs both, and asking twice would be two crossings.`
*>
fn void js_scene_create(
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

	Scene* fresh = self.pass.claim_scene();
	self.activate_scene(fresh);

	qjs::Value triple = js.array();
	js.set_index(triple, 0, qjs::number_value((double)fresh.id));
	js.set_index(triple, 1, qjs::number_value((double)fresh.root.index));
	js.set_index(triple, 2, qjs::number_value((double)fresh.root.generation));
	*out = triple;
}

<*
 Makes a scene the one being rendered — `scene.activate()`.

 The switch, and the whole of what it resets. Everything that belongs to a scene
 travels with it: the nodes, the physics world, the nav bake. Everything that is
 a property of *the world being shown* rather than of the scene goes back to its
 default, so that a script which sets a background and a script which does not
 render the same first frame — the rule `new three.Scene()` has always followed,
 kept here because this is now where the change of world happens.

 @return `false if the id names no live scene.`
*>
fn void js_scene_activate(
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

	Scene* target = self.pass.scene_by_id((uint)arg_int(&js, argc, args, 0));
	if (target == null)
	{
		*out = qjs::bool_value(false);
		return;
	}
	self.activate_scene(target);
	*out = qjs::bool_value(true);
}

<*
 Frees a scene and everything it owns — `scene.dispose()`.

 Refuses the active one; `MeshPass.dispose_scene` has the argument. The asset
 references its nodes held go back here, so a `three.unloadUnused()` afterwards
 is what actually reclaims memory — and two scenes over one kit means this frees
 nothing, which is right.

 @return `false if the id names nothing, or names the scene being rendered.`
*>
fn void js_scene_dispose(
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
	*out = qjs::bool_value(self.pass.dispose_scene((uint)arg_int(&js, argc, args, 0)));
}

// Whether a scene id still names a scene. What `Scene._check()` in the prelude
// asks before every call, in place of the epoch comparison it used to make.
fn void js_scene_alive(
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
	*out = qjs::bool_value(self.pass.scene_by_id((uint)arg_int(&js, argc, args, 0)) != null);
}

// The id of the scene being rendered.
fn void js_scene_active(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	*out = qjs::number_value(self.pass.scene == null ? 0 : (double)self.pass.scene.id);
}

<*
 Every live scene, as `[id, rootIndex, rootGeneration]` — `three.scenes`.

 The list is the thing an agent could not see. A `Scene` in JavaScript is a
 wrapper around `_sid` and nothing else, so a scene built inside a `run_script`
 scope that then ended is alive, counted, holding a node pool and a set of asset
 references, and named by no handle in existence — the exact shape of the leak
 `note_scene_created` warns about. The host knew all of them the whole time.

 The root travels with the id for `js_scene_create`'s reason: a `Scene` needs
 both, and asking twice would be two crossings. It is what lets the prelude hand
 back a usable handle for a scene whose wrapper is gone.
*>
fn void js_scene_ids(
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

	qjs::Value list = js.array();
	foreach (i, each : self.pass.scenes)
	{
		qjs::Value triple = js.array();
		js.set_index(triple, 0, qjs::number_value((double)each.id));
		js.set_index(triple, 1, qjs::number_value((double)each.root.index));
		js.set_index(triple, 2, qjs::number_value((double)each.root.generation));
		js.set_index(list, (uint)i, triple);
	}
	*out = list;
}

<*
 Frees every scene except the one being rendered — `three.disposeInactive()`.

 Safe by construction, and `MeshPass.dispose_scene` is why: it refuses the active
 one, so the loop cannot leave the frame with nothing to draw however many scenes
 it walks. The list is copied over by index from the back, because disposing
 removes from it.

 The verb exists because the transition is three steps — activate the next one,
 dispose the rest, `unloadUnused` — and the middle one is the one that gets
 forgotten. Nothing here reclaims memory on its own: the asset references go back
 when the scenes do, and the sweep afterwards is what frees them.

 @return `How many were disposed.`
*>
fn void js_dispose_inactive(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;

	uint disposed = 0;
	// Backwards: `dispose_scene` removes from the list it is walking.
	sz at         = self.pass.scenes.len();
	while (at > 0)
	{
		at--;
		if (self.pass.dispose_scene(self.pass.scenes[at].id)) disposed++;
	}
	*out = qjs::int_value((int)disposed);
}

<*
 Points the frame at a scene and puts that scene's look on.

 One function because there is one list, and it is the same argument
 `Scene.invalidate` makes: a switch that remembered two of these three would be a
 bug that only shows in the one it forgot.

 The look is *loaded*, not defaulted. Nothing has to be saved on the way out
 because `Scene.look` is where a script's writes land in the first place — the
 renderer's `clear`, `lighting` and `shadows` are the frame's live copy of the
 active scene's, refreshed here and nowhere else.
*>
fn void JsRuntime.activate_scene(&self, Scene* target)
{
	self.pass.scene = target;
	// A scene brings its own background, light and shadow settings back — a level
	// looks the way it looked when it was last on screen, which is the whole point
	// of being able to go back to it. Materials, assets and the camera are not
	// here: they are the machine rather than the world, and they survive a switch
	// on purpose.
	if (self.renderer != null) self.renderer.clear = target.look.clear;
	self.pass.lighting = target.look.lighting;
	// The image and the pipeline are **not** freed — see `ShadowMap.apply`, which
	// keeps them and forgets only what the outgoing scene's fit meant.
	self.pass.shadows.apply(target.look.shadow);
	// The camera stops tracking a node in a scene it is no longer looking at. The
	// follow names a `NodeId`, and one from the outgoing scene would resolve to
	// nothing every frame — a camera that silently stopped following rather than
	// one that said so.
	self.pass.follow = { };
}

<*
 The lights and the ambient floor, on the frame and on the scene that owns them.

 Two writes because there are two copies and they have different jobs: the pass
 shades this frame from its own, and the scene keeps the one that outlives not
 being on screen. Written here rather than at each of the five call sites, so that
 a sixth cannot set one and forget the other.
*>
fn void JsRuntime.set_lighting(&self, Lighting lighting)
{
	self.pass.lighting = lighting;
	if (self.pass.scene != null) self.pass.scene.look.lighting = lighting;
}

// The shadow settings, on the frame and on the scene, for `set_lighting`'s reason.
// The live copy is assigned rather than `apply`-ed: `apply` forgets the cached
// static half, which is right when the world changes and wrong when a script
// nudges the bias.
fn void JsRuntime.set_shadow(&self, ShadowSettings settings)
{
	self.pass.shadows.settings = settings;
	if (self.pass.scene != null) self.pass.scene.look.shadow = settings;
}

<*
 The clear colour of one scene, which is only this frame's if that scene is
 active.

 Unlike the light and the shadows, `scene.background` names a scene in the
 script, so setting it on the level being built has to land on that level rather
 than repainting the one on screen.
*>
fn void JsRuntime.set_clear(&self, Scene* scene, float[4] clear)
{
	scene.look.clear = clear;
	if (self.renderer != null && scene == self.pass.scene) self.renderer.clear = clear;
}

<*
 `add(asset, assetGeneration, mesh, parentIndex, parentGeneration, name)`.

 A negative `asset` is a group: traversed and transformed, never drawn — and it
 is read before the handle is resolved, so a group never has to carry a
 generation for an asset it does not name.
*>
fn void js_add(
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

	int index = arg_int(&js, argc, args, 0);
	int mesh  = arg_int(&js, argc, args, 2);

	// The parent's handle is what names the scene — an object is added to the
	// graph its parent is in, which is what lets a script build the next level
	// while the current one is on screen.
	NodeRef parent = arg_handle(self, &js, argc, args, 3, out);
	if (parent.scene == null) return;

	@pool()
	{
		String name = arg_text(&js, argc, args, 5, tmem);

		if (index < 0)
		{
			*out = handle_value(&js, parent.scene.add_group(parent.id, name));
			return;
		}

		AssetId asset = arg_asset(self, &js, argc, args, 0, out);
		if (!asset.is_set()) return;

		// The one refusal here is a mesh index the asset does not have, and it is
		// worth a sentence rather than a null handle: it is the mistake a script
		// makes, and an unset id would surface three lines later as a missing
		// object with no reason attached.
		if (self.pass.assets.mesh(asset, (uint)mesh) == null)
		{
			*out = js.raise(string::tformat("there is no mesh %d in asset %d", mesh, index));
			return;
		}

		// No retain here since G2: `Scene.create_slot` takes the reference, so
		// the count has one implementation rather than one per caller.
		*out = handle_value(&js, parent.scene.add_mesh(asset, (uint)mesh, parent.id, name));
	};
}

fn void js_remove(
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

	NodeRef ref = arg_handle(self, &js, argc, args, 0, out);
	if (ref.scene == null) return;

	// The root is the scene itself; emptying it is `scene.unload()` and freeing it
	// is `scene.dispose()`.
	if (ref.id == ref.scene.root)
	{
		*out = js.raise("the Scene cannot be removed — scene.unload() empties it, scene.dispose() frees it");
		return;
	}
	ref.scene.remove(ref.id);
}

fn void js_set_parent(
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

	NodeRef ref = arg_handle(self, &js, argc, args, 0, out);
	if (ref.scene == null) return;
	NodeRef parent = arg_handle(self, &js, argc, args, 2, out);
	if (parent.scene == null) return;

	// Two scenes are two node pools, so this would have to destroy the subtree and
	// rebuild it under the other root — which is exactly what re-parenting is
	// documented *not* to do, since a rebuild invalidates every handle into
	// something that never left the graph. Refused rather than half-done, and the
	// test is whether the parent is a node of the child's own scene at all.
	if (ref.scene != parent.scene || ref.scene.node(parent.id) == null)
	{
		*out = js.raise("an object cannot be moved between scenes — rebuild it in the one you want it in");
		return;
	}
	ref.scene.set_parent(ref.id, parent.id);
}

<*
 `setTransform(index, generation, px, py, pz, rx, ry, rz, sx, sy, sz)`.

 All nine at once rather than one verb per channel: `prelude.js` holds the local
 transform as JavaScript numbers and pushes the whole thing on any write, so
 there is never a partial state to reason about and `m.position.set(...)` is one
 crossing instead of three.
*>
fn void js_set_transform(
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

	NodeRef ref = arg_handle(self, &js, argc, args, 0, out);
	if (ref.scene == null) return;

	// `game.md` G5/S6. The camera resolves a script and a drag by
	// last-writer-wins because both describe the same intent; a solver and a
	// script writing the same transform every frame describe two, and the
	// result is jitter rather than a compromise. So this is a refusal and not
	// a merge — and the vtable answers while this side throws, because a table of
	// function pointers has no way to raise a JavaScript exception.
	if (ref.scene.physics.owns_transform(ref.id))
	{
		*out = raise_refusal(&js, ref);
		return;
	}

	Node* target = ref.scene.node(ref.id);
	target.position = {
		arg_float(&js, argc, args, 2), arg_float(&js, argc, args, 3), arg_float(&js, argc, args, 4)
	};
	// Euler in, quaternion stored — the one-way conversion `scene/node.c3`
	// describes. A caller keeps whatever triple it sent; nothing converts back.
	target.rotation = quat_from_euler({
		arg_float(&js, argc, args, 5), arg_float(&js, argc, args, 6), arg_float(&js, argc, args, 7)
	});
	target.scale = {
		arg_float(&js, argc, args, 8), arg_float(&js, argc, args, 9), arg_float(&js, argc, args, 10)
	};
	say_nan_transform(ref.scene, ref.id, target, argc, args);
	// Not `dirty = true`: the world-matrix walk gained the right to skip itself,
	// so the flag alone stopped being enough. See `Scene.mark_moved`.
	ref.scene.mark_moved(ref.id);
}

<*
 The advice a transform holding a non-finite component is owed.

 Accepted rather than refused — the write happens — because a game that runs one
 frame behind an exception is worse than one that runs with one mesh adrift, and
 because the ordinary source of this is an arithmetic slip (`undefined` in a
 `set`, a degenerate `normalize`) that the script will notice the moment it
 looks. What it cannot do without a sentence is find it: a NaN position rides
 `follow()` into a physics body and out the other side of every distance test,
 which is how it costs an afternoon instead of a minute.

 Deduplicated upstream by the advice sink, so a loop that writes NaN sixty times
 a second is one line in the log.
*>
fn void say_nan_transform(Scene* scene, NodeId id, Node* node, int argc, qjs::Value* args) @local
{
	if (math::is_finite(node.position.x) && math::is_finite(node.position.y)
		&& math::is_finite(node.position.z)
		&& math::is_finite(node.scale.x) && math::is_finite(node.scale.y)
		&& math::is_finite(node.scale.z))
	{
		return;
	}
	String what = node.name.len > 0 ? node.name.copy(tmem) : string::tformat("node %d", (int)id.index);
	@advise(
		"three: a NaN or infinite transform was written to '%s' — an undefined or non-numeric "
			"component in a position.set(), scale or rotation? It draws nowhere and every distance "
			"test against it answers NaN.",
		what);
}

<*
 Turns the vtable's `false` into the sentence a script sees.

 Asked for only after a refusal, so the second call costs nothing in the ordinary
 case — and it keeps the *reason* with the solver that owns it rather than
 duplicating the wording on this side.
*>
fn qjs::Value raise_refusal(qjs::Context* js, NodeRef ref) @local
{
	if (!ref.scene.physics.owns_transform(ref.id)) return js.raise("that object cannot be moved");
	String why = ref.scene.physics.transform_refusal(ref.id);
	if (why.len == 0) return js.raise("that object cannot be moved");
	return js.raise(why);
}

<*
 `setQuaternion(index, generation, x, y, z, w)` — a rotation that did not come
 from Euler angles.

 Sent after `setTransform` and overwriting the rotation it just wrote, by an
 object that was handed an exact quaternion — today that means one out of
 `asset.instantiate()`. Two crossings rather than one, and only for those
 objects: the Euler triple is what a script reads back off `.rotation`, and the
 quaternion is what actually rotates the node. `bind_asset.c3`'s `js_asset_nodes`
 has the number that makes the second one worth paying for.

 Writing any Euler component drops the quaternion, so a script that touches
 `.rotation` gets exactly what it typed and nothing left over from the file.
*>
fn void js_set_quaternion(
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

	NodeRef ref = arg_handle(self, &js, argc, args, 0, out);
	if (ref.scene == null) return;

	// The same refusal `js_set_transform` makes, and it has to be here too: a
	// script that only ever wrote `.quaternion` would otherwise fight the
	// solver through the one door that was left open.
	if (ref.scene.physics.owns_transform(ref.id))
	{
		*out = raise_refusal(&js, ref);
		return;
	}
	ref.scene.set_quaternion(ref.id, {
		arg_float(&js, argc, args, 2),
		arg_float(&js, argc, args, 3),
		arg_float(&js, argc, args, 4),
		arg_float(&js, argc, args, 5)
	});
}

<*
 `bindAnimation(index, generation, asset, assetGeneration, pairs)` — tell the
 host which of a subtree's nodes came from which glTF node.

 The map an `AnimationPlayer` needs, and the reason it has to come from
 JavaScript at all: `asset.instantiate()` builds `Object3D`s and lets the
 ordinary `add` path materialize them, so the host performed the tree walk one
 node at a time through `js_add` and never saw the correspondence.
 `Scene.instantiate` on the host has the same map for free; both hand it to
 `Scene.bind_player`.

 `pairs` is flat — glTF node index, node index, node generation, repeating —
 rather than an array of objects, because it is written once per instantiated
 prop and read once, and three numbers per node in one typed pass beats an
 object allocation per node.

 Called lazily, on the first `play`. A prop that never animates never sends it.
*>
fn void js_bind_animation(
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

	NodeRef ref = arg_handle(self, &js, argc, args, 0, out);
	if (ref.scene == null) return;

	AssetId asset = arg_asset(self, &js, argc, args, 2, out);
	if (!asset.is_set()) return;

	if (argc < 5) return;
	qjs::Value pairs = args[4];
	uint length      = (uint)js.length(pairs);

	List{uint} sources;
	List{NodeId} nodes;
	sources.init(mem, (sz)(length / 3) + 1);
	nodes.init(mem, (sz)(length / 3) + 1);
	defer sources.free();
	defer nodes.free();

	for (uint i = 0; i + 2 < length; i += 3)
	{
		sources.push((uint)js.number(js.index(pairs, i)));
		nodes.push(
			{
				.index = (uint)js.number(js.index(pairs, i + 1)),
				.generation = (uint)js.number(js.index(pairs, i + 2)),
			}
		);
	}

	// Whether this character is posed from its bone nodes. The script asked for a
	// skeleton, and a skeleton that drives nothing would be the read-only version
	// of the flag rather than the useful one. See `AnimationPlayer.live_skin`.
	bool live_skin = argc > 5 ? arg_truth(&js, argc, args, 5) : false;
	ref.scene.bind_player(asset, ref.id, sources.array_view(), nodes.array_view(), live_skin);
}

<*
 `playAnimation(index, generation, name, loop, speed, time, fade)` — start a clip
 on an instantiated subtree.

 Answers with a boolean rather than throwing on an unknown clip: `mesh.animations`
 is the list, so naming something that is not on it is a mistake a script can see
 and correct, and an exception raised inside an animation callback is a stopped
 game rather than a wrong pose.
*>
fn void js_play_animation(
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

	NodeRef ref = arg_handle(self, &js, argc, args, 0, out);
	if (ref.scene == null) return;

	@pool()
	{
		String name = arg_text(&js, argc, args, 2, tmem);
		bool loop   = argc > 3 ? arg_truth(&js, argc, args, 3) : true;
		float speed = argc > 4 ? arg_float(&js, argc, args, 4) : 1.0f;
		// The start phase. What a crowd needs and the only new argument since the
		// binding was written: a hundred characters on one walk cycle at a hundred
		// phases are a hundred values of this over one baked clip.
		float time  = argc > 5 ? arg_float(&js, argc, args, 5) : 0;
		// Seconds of crossfade out of whatever was playing. Zero is the snap this
		// binding did for its whole life before the argument existed, which is why
		// it is the default and not a sentinel.
		float fade  = argc > 6 ? arg_float(&js, argc, args, 6) : 0;
		*out = qjs::bool_value(ref.scene.play(ref.id, name, loop, speed, time, fade));
	};
}

<*
 `setMorphWeights(index, generation, weights)` — how much of each blend shape this
 copy wears.

 The whole vector every time rather than one element, which is the same choice
 `setTransform` makes: a face has a handful of targets, and a crossing per element
 per frame would cost more than the numbers do.

 An all-zero vector takes the copy off the morph path entirely — see
 `Scene.set_morph_weights` — so a face that has finished its expression stops
 costing a loop rather than looping over zeroes.

 Answers with a boolean rather than throwing on a mesh with no targets, for
 `playAnimation`'s reason: `mesh.morphs` is the count, so asking a box to smile is
 a mistake a script can see.
*>
fn void js_set_morph_weights(
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

	NodeRef ref = arg_handle(self, &js, argc, args, 0, out);
	if (ref.scene == null) return;
	if (argc < 3) return;

	qjs::Value values = args[2];
	uint length       = (uint)js.length(values);

	List{float} weights;
	weights.init(mem, (sz)length + 1);
	defer weights.free();
	for (uint i = 0; i < length; i++)
	{
		weights.push((float)js.number(js.index(values, i)));
	}

	*out = qjs::bool_value(ref.scene.set_morph_weights(ref.id, weights.array_view()));
}

<*
 `meshMorphs(asset, generation, mesh)` — how many morph targets a geometry has.

 Read off the uploaded mesh, so it answers zero for a file whose meshes have not
 reached the device yet — which is why the prelude asks it lazily, on the first
 look at `mesh.weights`, rather than in the `Mesh` constructor.
*>
fn void js_mesh_morphs(
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

	AssetId id = arg_asset(self, &js, argc, args, 0, out);
	if (!id.is_set()) return;

	uint index    = (uint)arg_int(&js, argc, args, 2);
	GpuMesh* mesh = self.pass.assets.mesh(id, index);
	*out = qjs::int_value(mesh == null ? 0 : (int)mesh.morph_targets);
}

<*
 `bindSocket(index, generation, rootIndex, rootGeneration, bone)` — keep a node on
 a bone of a baked character.

 Answers with a boolean rather than throwing, for `playAnimation`'s reason: the
 bone names belong to the file, so naming one the rig does not have is a mistake a
 script can see and correct. The prelude turns the false into a sentence that
 lists what the rig does have.
*>
fn void js_bind_socket(
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

	NodeRef holder = arg_handle(self, &js, argc, args, 0, out);
	if (holder.scene == null) return;

	NodeId root = {
		.index = (uint)arg_int(&js, argc, args, 2),
		.generation = (uint)arg_int(&js, argc, args, 3),
	};

	@pool()
	{
		String bone = arg_text(&js, argc, args, 4, tmem);
		*out = qjs::bool_value(holder.scene.attach_socket(holder.id, root, bone));
	};
}

<*
 `unbindSocket(index, generation)` — take a node off whatever bone it was on.

 It stays where the bone last left it. Nothing in the prelude calls this yet; it
 is here because attaching without a way to detach is a one-way door, and the host
 side of it is three lines.
*>
fn void js_unbind_socket(
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

	NodeRef ref = arg_handle(self, &js, argc, args, 0, out);
	if (ref.scene == null) return;

	*out = qjs::bool_value(ref.scene.detach_socket(ref.id));
}

<*
 `bindSkin(index, generation, skin, compute)` — tell a node which skin poses it.

 **The JavaScript path needs this and the host path does not.** `Scene.instantiate`
 creates every node itself and sets the skin as it goes; `asset.instantiate()` in
 a script hands back `Object3D`s that materialize later through the ordinary
 `add`, so by the time a host node exists nothing remembers that it came from a
 skinned entry. `Object3D._materialize` calls this straight after `H.add`, which
 is the first moment there is a node to tell.

 A skin of -1 clears it, which is what every ordinary mesh is.
*>
fn void js_bind_skin(
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

	NodeRef ref = arg_handle(self, &js, argc, args, 0, out);
	if (ref.scene == null) return;

	int skin = argc > 2 ? (int)arg_float(&js, argc, args, 2) : -1;
	ref.scene.set_skin(ref.id, skin);

	Node* node = ref.scene.node(ref.id);
	if (node != null) node.preskinned = skin >= 0 && argc > 3 && arg_truth(&js, argc, args, 3);
}

<*
 `stopAnimation(index, generation)` — hold the pose. See `Scene.stop`.
*>
fn void js_stop_animation(
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

	NodeRef ref = arg_handle(self, &js, argc, args, 0, out);
	if (ref.scene == null) return;

	*out = qjs::bool_value(ref.scene.stop(ref.id));
}

fn void js_set_visible(
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

	NodeRef ref = arg_handle(self, &js, argc, args, 0, out);
	if (ref.scene == null) return;

	ref.scene.set_visible(ref.id, arg_truth(&js, argc, args, 2));
}

<*
 `setCollides(index, generation, on)` — whether this node is collision geometry.

 Returns nothing, like `setVisible` and unlike `setStatic`: there is no node this
 can be refused on. `Node.collides` has what it is for.
*>
fn void js_set_collides(
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

	NodeRef ref = arg_handle(self, &js, argc, args, 0, out);
	if (ref.scene == null) return;

	ref.scene.set_collides(ref.id, arg_truth(&js, argc, args, 2));
}

<*
 `setStatic(index, generation, on)` — put this node in the cached half of the
 shadow map, and say whether it went.

 **Answers rather than returning nothing**, unlike `setVisible` beside it, and
 the reason is that this one can be refused: a node with a skin is not something
 "it does not move" can be true of, so the host says no and the shim keeps the
 answer. `Scene.set_static_caster` has the argument.
*>
fn void js_set_static(
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

	NodeRef ref = arg_handle(self, &js, argc, args, 0, out);
	if (ref.scene == null) return;

	*out = qjs::bool_value(ref.scene.set_static_caster(ref.id, arg_truth(&js, argc, args, 2)));
}

fn void js_set_name(
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

	NodeRef ref = arg_handle(self, &js, argc, args, 0, out);
	if (ref.scene == null) return;

	@pool()
	{
		ref.scene.set_name(ref.id, arg_text(&js, argc, args, 2, tmem));
	};
}

<*
 `setColor(index, generation, r, g, b, a)` — this copy's own tint.

 Four scalars rather than an array for `setTransform`'s reason: the shim reads
 numbers cheaply and arrays through a property walk, and a colour is written far
 more often than it is read.

 **This is one of the two verbs that do not cost a draw call**, which is the
 whole point of them: the value lands in the node's `Instance` record and is read
 by `SV_InstanceID`, so two copies of one mesh may disagree about it and stay in
 one bucket. Everything else that changes how a mesh looks is bucket state.
*>
fn void js_set_color(
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

	NodeRef ref = arg_handle(self, &js, argc, args, 0, out);
	if (ref.scene == null) return;

	ref.scene.set_color(ref.id, {
		arg_float(&js, argc, args, 2),
		arg_float(&js, argc, args, 3),
		arg_float(&js, argc, args, 4),
		arg_float(&js, argc, args, 5)
	});
}

<*
 `setVariant(index, generation, row)` — which row of the material's table.

 Negative is clamped to zero rather than refused: the row is a `uint` on the way
 to the GPU, and a script that computed `i - 1` at `i = 0` should get the first
 row rather than four billion. The far end is clamped in the shader against the
 rows the material actually declared — see `shaders/material.slang`.
*>
fn void js_set_variant(
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

	NodeRef ref = arg_handle(self, &js, argc, args, 0, out);
	if (ref.scene == null) return;

	int variant = arg_int(&js, argc, args, 2);
	ref.scene.set_variant(ref.id, variant < 0 ? 0 : (uint)variant);
}

<*
 Where a node ended up in world space.

 The world matrices are brought up to date first: a script that sets a position
 and immediately asks where something is would otherwise read the transform from
 before its own write, which is the shape of bug that renders fine and reports
 the wrong number.
*>
fn void js_world_position(
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

	NodeRef ref = arg_handle(self, &js, argc, args, 0, out);
	if (ref.scene == null) return;

	// First: a caller that sets a position and immediately asks where something is
	// would otherwise read the transform from before its own write.
	ref.scene.update_world_matrices();
	*out = vec3_value(&js, ref.scene.node(ref.id).world_position());
}

<*
 `objectBounds(handle, generation)` — the world-space box of a subtree, or
 `null` when nothing under it draws.

 The world-space half of what `meshBounds` answers in mesh-local space, and the
 reason both exist: a script placing a piece against a wall needs to know where
 the piece's *faces* end up, which is its own bounds run through every transform
 between it and the root. Doing that arithmetic in JavaScript would mean
 re-deriving world matrices the host already keeps.

 Null rather than a zero box for an empty subtree — see `Scene.subtree_bounds`.
*>
fn void js_object_bounds(
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

	NodeRef ref = arg_handle(self, &js, argc, args, 0, out);
	if (ref.scene == null) return;

	// `drawn` is the bool separating "nothing under it draws" from a zero-sized box
	// at the origin, which is a distinction the box alone cannot carry.
	bool drawn = false;
	collision::Aabb3 box = ref.scene.subtree_bounds(&self.pass.assets, ref.id, &drawn);
	if (!drawn)
	{
		*out = qjs::null_value();
		return;
	}
	*out = aabb_value(&js, box);
}

// ============================================================================
// Picking
// ============================================================================

<*
 A `Hit` as JavaScript sees it, or `null` for a miss.

 **A miss is `null` rather than an empty list**, which is where this diverges
 from Three.js's `intersectObjects`. `Scene.raycast` answers with the closest
 drawable node and nothing behind it, so a list would never hold more than one
 thing and its length would be a fact about this implementation rather than
 about the scene. A name Three.js does not have (`pick`) and a shape that cannot
 be mistaken for its array is `plan.md` §4's rule for a divergence.

 The node handle rides along so `prelude.js` can hand back the `Object3D` a
 script built rather than an index, and the name rides along because a scene
 opened from the command line has nodes no script ever made an object for —
 `object: null` with nothing beside it would be a dead end.
*>
fn qjs::Value hit_value(JsRuntime* self, qjs::Context* js, Hit hit)
{
	if (!hit.hit) return qjs::null_value();

	qjs::Value found = js.object();
	js.set_property(found, "node", handle_value(js, hit.node));
	js.set_property(found, "distance", qjs::number_value(hit.distance));
	js.set_property(found, "point", vec3_value(js, hit.point));
	js.set_property(found, "normal", vec3_value(js, hit.normal));

	Node* node = self.pass.scene.node(hit.node);
	js.set_property(found, "name", js.string(node == null ? "" : node.name));
	return found;
}

<*
 `pick(x, y)` — what is under a pixel of the rendered image.

 The extent is the **offscreen target's**, which is the image `screenshot` hands
 back, so the coordinates an agent reads off the PNG it was given are the
 coordinates this takes. A window, if there is one, never comes into it —
 `plan.md` §1's decision that the swapchain is a consumer and not the target is
 what makes that true without a second code path.

 `screen_ray` derives the ray from the same view-projection the renderer draws
 with, so "the ray goes where the picture goes" holds by construction.
*>
fn void js_pick(
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
		*out = js.raise("picking by screen position needs a GPU device and this context has none");
		return;
	}

	*out = self.pick_at(&js, arg_float(&js, argc, args, 0), arg_float(&js, argc, args, 1));
}

<*
 One pixel of the rendered image, raycast.

 Factored out because the click handler asks the same question, and a second
 copy of these four lines is a second chance to disagree with the picture about
 which way rows are counted. `js_pick` keeps its own device check because a
 script that asked has to be told; a click with no device is not a mistake
 anyone made, so it answers `null` — the same thing a click on empty space
 answers, which is the truth in both cases.
*>
fn qjs::Value JsRuntime.pick_at(&self, qjs::Context* js, float x, float y)
{
	if (self.renderer == null) return qjs::null_value();

	collision::Ray ray = screen_ray(
		&self.pass.camera,
		x,
		y,
		self.renderer.target.extent.width,
		self.renderer.target.extent.height,
	);
	return hit_value(self, js, self.pass.scene.raycast(&self.pass.assets, ray));
}

<*
 `cameraRay(x, y)` — the world-space ray through a pixel, as
 `[ox, oy, oz, dx, dy, dz]`.

 The same `screen_ray` a pick casts, called the same way with the same extent,
 because agreeing with `pick` is the whole job. Deriving it a second time from
 the eye, the field of view and the aspect would agree at the centre pixel and
 drift everywhere else — and an editor calls both on one cursor position, so a
 drift between them reads as the piece landing next to where it was dropped.

 It exists because `pick` can only answer about something already under the
 cursor. Dragging a piece over bare ground and dropping one where nothing is yet
 have nothing to pick, and both are answered by intersecting this ray with a
 plane the script chose.

 The origin is on the near plane rather than at the eye. That is what `pick`
 uses, so the two rays are the same ray and `Hit.distance` means the same number
 for both; it also means what is in front of the near plane — invisible — is not
 hit here either, which is the honest answer for a ray derived from a picture.
*>
fn void js_camera_ray(
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

	// Same refusal as `renderSize`, and for the same reason: a pixel coordinate
	// only means something against a target that has a size, and without a
	// device there is none to count in.
	if (self.renderer == null)
	{
		*out = js.raise("a ray through a pixel needs a render target and this context has none");
		return;
	}

	collision::Ray ray = screen_ray(
		&self.pass.camera,
		arg_float(&js, argc, args, 0),
		arg_float(&js, argc, args, 1),
		self.renderer.target.extent.width,
		self.renderer.target.extent.height,
	);

	// Flat, like `aabb_value`: one array of six where a nested pair would be
	// three, and `api.js` builds the `{ origin, direction }` a script sees.
	qjs::Value six = js.array();
	js.set_index(six, 0, qjs::number_value(ray.origin.x));
	js.set_index(six, 1, qjs::number_value(ray.origin.y));
	js.set_index(six, 2, qjs::number_value(ray.origin.z));
	js.set_index(six, 3, qjs::number_value(ray.direction.x));
	js.set_index(six, 4, qjs::number_value(ray.direction.y));
	js.set_index(six, 5, qjs::number_value(ray.direction.z));
	*out = six;
}

<*
 `raycast(ox, oy, oz, dx, dy, dz)` — a world-space ray.

 No device is needed and none is asked for: with nothing loaded there is nothing
 to hit and the answer is `null`, which is the truth rather than an error.

 The direction is normalised here rather than being required to arrive that way.
 `Hit.distance` is measured along a unit ray, so an unnormalised direction would
 silently return a distance in units of its own length — the same class of
 mistake `Scene.raycast` already guards against between instance scales.
*>
fn void js_raycast(
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

	Vec3 origin = { arg_float(&js, argc, args, 0), arg_float(&js, argc, args, 1), arg_float(&js, argc, args, 2) };
	Vec3 direction = { arg_float(&js, argc, args, 3), arg_float(&js, argc, args, 4), arg_float(&js, argc, args, 5) };

	float length = direction.length();
	if (length < 1e-12f)
	{
		*out = js.raise("raycast wants a direction with a length — (0, 0, 0) points nowhere");
		return;
	}

	collision::Ray ray = { .origin = origin, .direction = direction / length };
	*out = hit_value(self, &js, self.pass.scene.raycast(&self.pass.assets, ray));
}

// ============================================================================
// The frame
// ============================================================================

<*
 The numbers an agent reads its own cost off (`plan.md`'s second thesis).

 camelCase, because everything a script touches is JavaScript and `draw_calls`
 beside `drawCalls` in the same object graph is a seam an agent has to remember.

 ## `gpuMs` is merged in here rather than living in `SceneStats`

 Every other number in this object is a fact about the scene: it is the same
 whatever device is behind it, and the same from every camera angle — which is
 what `stats_stays_camera_free_with_transparency` pins. GPU milliseconds are a
 fact about a *device* that drew a *frame*, so putting the field in `SceneStats`
 would mean the scene layer either carrying a number it cannot produce or
 growing a renderer it does not have. It is joined to the answer at this
 boundary instead, where both halves are in scope.

 **Always set, even at zero.** A script reading `stats().gpuMs` on a runtime
 with no device gets 0, not `undefined`: a missing key makes `ms > 16` false and
 `ms.toFixed(2)` throw, and neither failure names the reason. Zero is the honest
 answer — nothing was measured — and it arrives in the shape the caller expects.

 ## The five phase millisecond counts

 Same join, same zero, and they sum to `gpuMs` — `gpu/timing.c3` writes the
 marks and `plan.md` §18.3 has why they exist: without them, "which pass is this
 frame" is answered by editing the scene and rendering it again, six times, and
 an optimisation of one pass is verified by the total. They are five properties
 rather than one object because every other number here is flat, and a script
 that wants to print a frame breakdown should not have to know which of the
 fifteen keys are nested.
*>
fn void js_stats(
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

	// `stats(sceneId)`, or `stats()` for the rendered one. The scene being asked
	// about is not always the one being rendered: a script building the next level
	// wants to know how big it has got before it shows it. `three.stats()` passes
	// nothing and means the frame's.
	Scene* scene = self.pass.scene;
	if (argc > 0)
	{
		scene = arg_scene(self, &js, argc, args, 0, out);
		if (scene == null) return;
	}

	SceneStats stats = self.scene_stats(scene);

	qjs::Value object = js.object();
	js.set_property(object, "drawCalls", qjs::int_value((int)stats.draw_calls));
	js.set_property(object, "uniqueMeshes", qjs::int_value((int)stats.unique_meshes));
	js.set_property(object, "instances", qjs::int_value((int)stats.instances));
	js.set_property(object, "nodes", qjs::int_value((int)stats.nodes));
	// Beside `nodes` rather than beside `drawCalls`, because the pair is the point:
	// the gap between them is what a level's author has said `collides = false`
	// about. `SceneStats.colliders` has the rest.
	js.set_property(object, "colliders", qjs::int_value((int)stats.colliders));
	js.set_property(object, "assets", qjs::int_value((int)stats.assets));
	js.set_property(object, "triangles", qjs::int_value((int)stats.triangles));
	js.set_property(object, "vertices", qjs::int_value((int)stats.vertices));
	js.set_property(object, "textures", qjs::int_value((int)stats.textures));
	js.set_property(object, "textureBytes", qjs::number_value((double)stats.texture_bytes));
	// Beside `assets` and not beside `nodes`, because it is the same kind of number
	// as `assets` and `materials`: something a script has to hand back. See
	// `SceneStats.scenes`.
	js.set_property(object, "scenes", qjs::int_value((int)stats.scenes));
	// The other resource a script has to give back by hand — `SceneStats.materials`
	// has why it is beside `assets` and not beside `drawCalls`.
	js.set_property(object, "materials", qjs::int_value((int)stats.materials));
	js.set_property(object, "culledLastFrame", qjs::int_value((int)stats.culled_last_frame));
	// The light's cull beside the camera's — §18.2. Zero with shadows off, which
	// is the honest answer rather than an absent property, and the same shape as
	// `shadowDraws` below.
	js.set_property(object, "shadowCulled", qjs::int_value((int)stats.shadow_culled_last_frame));
	// What skinning costs, apart from everything else — see `SceneStats`. A scene
	// with no character in it reports four zeroes, which is the honest answer and
	// costs four properties nobody reads.
	js.set_property(object, "skinnedDraws", qjs::int_value((int)stats.skinned_draws));
	js.set_property(object, "skinnedInstances", qjs::int_value((int)stats.skinned_instances));
	js.set_property(object, "preskinnedInstances", qjs::int_value((int)stats.preskinned_instances));
	js.set_property(object, "poseBytes", qjs::number_value((double)stats.pose_bytes));
	// The memory the RENDERER owns, which is where nearly all of it actually is —
	// `SceneStats` has the four and why `textureBytes` and `poseBytes` on their own
	// were answering a question about memory with a small fraction of the memory.
	// All four are process-wide rather than per scene, including when this call
	// names a scene that is not the rendered one.
	js.set_property(object, "shadowBytes", qjs::number_value((double)stats.shadow_bytes));
	js.set_property(object, "targetBytes", qjs::number_value((double)stats.target_bytes));
	js.set_property(object, "postBytes", qjs::number_value((double)stats.post_bytes));
	js.set_property(object, "geometryBytes", qjs::number_value((double)stats.geometry_bytes));
	// The draws the shadow pass made last frame, which is the only place a script
	// can see that turning shadows on roughly doubled the frame's draw calls —
	// `drawCalls` above counts the scene pass and always has. Zero with shadows
	// off, which is the honest answer rather than an absent property.
	js.set_property(object, "shadowDraws", qjs::int_value((int)stats.shadow_draws));
	// And what the cached half cost, on the frames it was rebuilt — §19.3. Zero
	// is the number to want here: it says the shadow map held from one frame to
	// the next, which is what marking things static is for. See
	// `SceneStats.shadow_static_draws`.
	js.set_property(object, "shadowStaticDraws", qjs::int_value((int)stats.shadow_static_draws));
	// Whether anything in the scene has asked for a cut-out shadow — §28. False
	// until the first frame a `material.alphaTest` caster is drawn, and true from
	// then on: it reports a pipeline that exists, not one that was used this frame.
	js.set_property(object, "shadowCutout", qjs::bool_value(stats.shadow_cutout));
	FrameTiming timing = self.renderer != null ? self.renderer.timing() : (FrameTiming) { };
	js.set_property(object, "gpuMs", qjs::number_value(timing.total));
	js.set_property(object, "prepareMs", qjs::number_value(timing.prepare));
	js.set_property(object, "shadowMs", qjs::number_value(timing.shadow));
	js.set_property(object, "sceneMs", qjs::number_value(timing.scene));
	js.set_property(object, "postMs", qjs::number_value(timing.post));
	js.set_property(object, "presentMs", qjs::number_value(timing.present));
	*out = object;
}

<*
 `unloadUnused()` — free every asset no live node names, and say what went.

 `game.md` G2/S3, and the reason it is a verb rather than a finalizer is written
 there: a collector-driven free makes resident memory depend on when QuickJS felt
 like collecting, which is the worst possible property for the one number a game
 watches. A level boundary is an explicit moment and this is what happens at it.

 Answers with `{ assets, meshes, textures, bytes }` rather than nothing, because
 an agent that cannot see the number move has no way to tell a working unload
 from a no-op — and `stats()` afterwards is the independent confirmation. `bytes`
 is texture bytes alone, so a sweep that gave back geometry and no images answers
 0; `stats().geometryBytes` across the call is that half.

 Costs a full device idle when there is anything to free and nothing at all when
 there is not, so calling it every level is right and calling it every frame is
 merely wasteful.
*>
fn void js_unload_unused(
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

	// A null device is a scene-math runtime: nothing was ever uploaded, so there
	// is nothing to give back and an exception would make a script written for a
	// game fail under a test harness.
	Gpu* gpu            = self.renderer != null ? &self.renderer.gpu : null;
	UnloadReport report = self.pass.assets.unload_unused(gpu);

	qjs::Value object = js.object();
	js.set_property(object, "assets", qjs::int_value((int)report.assets));
	js.set_property(object, "meshes", qjs::int_value((int)report.meshes));
	js.set_property(object, "textures", qjs::int_value((int)report.textures));
	js.set_property(object, "bytes", qjs::number_value((double)report.bytes));
	*out = object;
}

fn void js_render(
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
		*out = js.raise("three.render needs a GPU device and this context has none");
		return;
	}

	if (catch err = self.renderer.render_offscreen())
	{
		*out = js.raise(string::tformat("the frame could not be drawn: %s", err));
	}
}

<*
 `screenshot(path)` — draw one frame and write it to a `.png`.

 The `--screenshot` flag as a verb, and the reason it is one is that the flag
 cannot answer a script that wants *several* pictures of one run: the CLI writes
 a frame it was told to write, on a schedule made of `--frames` and `--every`, so
 a script that wanted six different images had to arrange for the state of each
 one to fall on the frame the flag would capture. That is a script written around
 the harness rather than around what it is doing. `examples/trimsheet.js` was
 exactly that until this existed.

 One frame, drawn here. It is `Renderer.capture` — `render()` plus the readback —
 so this both draws and writes, and a `three.render()` immediately before it is
 a wasted frame rather than a required one. Post-processing, the interface and
 `three.debug.overlay` are all in it, because there is one recording path and
 this goes down it.

 Called from inside the animation callback it still happens *now*: the capture
 submits and waits on its own command buffer, the same way `three.render()` does,
 and neither is the host loop's frame. That costs a device round trip in the
 middle of a tick, so a script writing one file per frame of a real game is doing
 something it should know it is doing.

 The path is `resolve_write`'s — under `--assets` inside the game directory and
 nowhere else — and a folder that is not there yet is made, exactly as
 `scene.export` makes one.

 @return `{ path, width, height, bytes } — see wrote_image.`
*>
fn void js_screenshot(
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
		*out = js.raise("three.screenshot needs a GPU device and this context has none");
		return;
	}

	@pool()
	{
		String asked = arg_text(&js, argc, args, 0, tmem);
		if (asked.len == 0)
		{
			*out = js.raise("three.screenshot(path) wants a path to write a .png to");
			return;
		}

		String? writing = self.open_for_write(&js, asked, "three.screenshot()", tmem, out);
		if (catch writing) return;

		if (catch err = self.renderer.screenshot(writing))
		{
			*out = js.raise(string::tformat("three.screenshot() could not write %s: %s", asked, err));
			return;
		}

		*out = wrote_image(
			&js,
			writing,
			self.renderer.target.extent.width,
			self.renderer.target.extent.height
		);
	};
}

<*
 `renderSize()` — the offscreen target's extent, as `[width, height]`.

 Without it `pick(x, y)` would take pixels of an image whose size a script has
 no way to ask for: the agent driving over MCP learns it from `screenshot`, and
 a script running inside one call would have to be told. `pick(w / 2, h / 2)`
 is the line this exists for.
*>
fn void js_render_size(
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
		*out = js.raise("there is no render target without a GPU device, so it has no size");
		return;
	}

	qjs::Value pair = js.array();
	js.set_index(pair, 0, qjs::int_value((int)self.renderer.target.extent.width));
	js.set_index(pair, 1, qjs::int_value((int)self.renderer.target.extent.height));
	*out = pair;
}

// The offscreen target's side limit, the same number `three.window.resize`
// takes for a window. Neither is a promise the device will allocate it — a
// 16384-square target is a gigabyte of colour before the depth buffer — and a
// size the driver refuses comes back as the fault it raised.
const int RENDER_MAX_SIDE = 16384;

<*
 `renderResize(width, height)` — move the offscreen target, which is the actual
 resolution.

 The other half of `three.window.resize`, and the one that changes how much is
 drawn rather than how large it is shown. Everything renders into a target fixed
 at `--width`/`--height` when the process started and the swapchain stretches it
 over the window; this moves that target. So a settings screen offering
 "resolution" wants this, and one offering "window size" wants the other.

 What follows it: `three.renderSize()`, the PNG a screenshot comes back as and
 the pixels `scene.pick(x, y)` counts in all become the new size, and a post
 chain's images are rebuilt at it.

 ## When it happens

 Immediately, unless the call came from inside a frame — the animation callback,
 a fixed step, a widget handler — in which case it happens between that frame and
 the next. The images a resize frees are the ones the frame around the call is
 drawing into, which is the same reason `three.reload()` is deferred.

 The return value says which of the two it was: `true` for done, `false` for
 queued. A script that wants to read the size back does it on a later frame
 either way, because a queued resize has not happened yet and
 `three.renderSize()` answers honestly about the present.

 A run with no host loop — a `--frames` batch past its last frame, a test — never
 performs a queued one, exactly as it never performs a queued reload.

 A device that will not allocate a target that size throws, and the old one is
 still there and still being drawn.
*>
fn void js_render_resize(
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
	if (width < 1 || height < 1 || width > RENDER_MAX_SIDE || height > RENDER_MAX_SIDE)
	{
		*out = js.raise(
			string::tformat(
				"three.setRenderSize(width, height) wants two sizes between 1 and %d pixels; got %dx%d",
				RENDER_MAX_SIDE,
				width,
				height
			)
		);
		return;
	}

	if (self.renderer == null)
	{
		*out = js.raise("there is no render target without a GPU device, so there is nothing to resize");
		return;
	}

	// Pinned before the resize rather than after, and before the deferral too: a
	// queued resize that only pinned when it landed would spend the frames in
	// between still following the window, and a drag inside that window would
	// arrive after the pin and be honoured.
	self.renderer.render_size_pinned = true;

	if (self.in_frame)
	{
		self.render_width_wanted = (uint)width;
		self.render_height_wanted = (uint)height;
		*out = qjs::bool_value(false);
		return;
	}

	if (catch err = self.renderer.resize_target((uint)width, (uint)height))
	{
		*out = js.raise(
			string::tformat("three.setRenderSize could not make a %dx%d target: %s", width, height, err)
		);
		return;
	}
	*out = qjs::bool_value(true);
}

<*
 `renderFollowWindow()` — go back to the render size tracking the window.

 What `three.setRenderSize(null)` calls, and the way out of the pin an explicit
 size puts on. The target moves on the next swapchain rebuild rather than here:
 that is where every other window size change is answered, and a second path
 that resized on the spot would be a second place for the two to disagree.

 Answers with whether there was a renderer to tell — false under a runtime with
 no device, which is the shape every other verb here uses.
*>
fn void js_render_follow_window(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;

	if (self.renderer == null)
	{
		*out = qjs::bool_value(false);
		return;
	}
	self.renderer.render_size_pinned = false;
	self.render_width_wanted = 0;
	self.render_height_wanted = 0;
	*out = qjs::bool_value(true);
}

<*
 Performs a resize a frame asked for, between frames.

 Called by the host loop beside the reload and the quit it sits with. Failure is
 reported and dropped rather than raised: there is no script on the stack to
 raise into — the call that asked for this returned a frame ago — and a run that
 stopped because a menu asked for a resolution the device refused would be worse
 than one that goes on drawing at the size it had.

 @return `True if a resize was pending, whether or not it worked.`
*>
fn bool JsRuntime.take_render_resize(&self)
{
	if (self.render_width_wanted == 0 || self.renderer == null) return false;

	uint width  = self.render_width_wanted;
	uint height = self.render_height_wanted;
	self.render_width_wanted = 0;
	self.render_height_wanted = 0;

	if (catch err = self.renderer.resize_target(width, height))
	{
		@advise("three.setRenderSize(%d, %d) was refused by the device (%s); the size is unchanged", width, height, err);
	}
	return true;
}

<*
 `backgroundGet(sceneId)` — the colour that scene's frames start on, as
 `[r, g, b]`.

 The scene's own rather than the renderer's, so a level being built off screen
 reads back what was set on it instead of what the level on screen is showing.
*>
fn void js_background_get(
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
		*out = js.raise("there is nothing to clear without a GPU device, so there is no background colour");
		return;
	}

	Scene* scene = arg_scene(self, &js, argc, args, 0, out);
	if (scene == null) return;

	qjs::Value list = js.array();
	for (uint i = 0; i < 3; i++) js.set_index(list, i, qjs::number_value(scene.look.clear[i]));
	*out = list;
}

<*
 `backgroundSet(sceneId, r, g, b)` — what that scene's frames start on.

 ## The alpha stays at one, and is not an argument

 A clear alpha of zero would only mean something if what the image is composited
 onto were a question, and it is not: the offscreen target is blitted to an
 opaque swapchain image and encoded to a PNG that nothing is behind. Taking an
 alpha here would let a script write a number that changes no pixel, which is
 worse than not offering it — `plan.md` §4's half-match rule applied to a
 parameter rather than to a name.

 ## Components, not a hex value

 The same contract `mesh.color` has, and the same reason: `prelude.js` does the
 hex arithmetic so both doors divide by 255 identically.

 **These components are sRGB**, which used to be a distinction this project did
 not draw — the line here read "there is no colour management anywhere in this
 project", and the cost of that was every textured scene rendering about 2.2 too
 dark. `gpu/color.c3` has the argument. What it means for this verb is the thing
 a caller wants to be true and could not previously rely on: `0x2060a0` clears
 to `0x2060a0`, and `backgroundGet` gives back what `backgroundSet` was handed,
 because the decode happens at the attachment and not to the stored value.
*>
fn void js_background_set(
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
		*out = js.raise("there is nothing to clear without a GPU device, so there is no background colour");
		return;
	}

	Scene* scene = arg_scene(self, &js, argc, args, 0, out);
	if (scene == null) return;

	float[4] clear = { 0, 0, 0, 1.0f };
	for (int i = 0; i < 3; i++)
	{
		clear[i] = math::clamp(arg_float(&js, argc, args, i + 1), 0.0f, 1.0f);
	}
	self.set_clear(scene, clear);
}

<*
 `skyGet(sceneId)` — the scene's sky, as
 `[background, environment, backgroundIntensity, environmentIntensity, rotation]`.

 The two textures are indices into `Assets.textures`, or -1 for none. They cross
 as numbers rather than as handles because the prelude keeps the `Texture` object
 a script assigned and hands that same object back — what this is for is the
 numbers beside them and the check that the far side's cache has not drifted from
 the host's truth.
*>
fn void js_sky_get(
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

	Scene* scene = arg_scene(self, &js, argc, args, 0, out);
	if (scene == null) return;

	SkyLook sky     = scene.look.sky;
	qjs::Value list = js.array();
	js.set_index(list, 0, qjs::int_value(sky.background));
	js.set_index(list, 1, qjs::int_value(sky.environment));
	js.set_index(list, 2, qjs::number_value(sky.background_intensity));
	js.set_index(list, 3, qjs::number_value(sky.environment_intensity));
	js.set_index(list, 4, qjs::number_value(sky.rotation));
	*out = list;
}

<*
 `skySet(sceneId, background, environment, backgroundIntensity, environmentIntensity, rotation)`
 — the whole of a scene's sky, written at once.

 **One verb for five fields**, unlike the lights and the shadows next door, and
 for a reason those two do not have: two of the five are counted texture
 references. A verb per field would be five places that have to retain and
 release correctly, and the one that got it wrong would be a picture freed while
 a frame was still sampling it. `set_scene_sky` is the only door, and this calls
 it twice.

 -1 clears a texture. A script that only wanted to change the rotation reads the
 other four back first, which is what `prelude.js` does — it has them cached
 anyway, because it keeps the `Texture` objects.
*>
fn void js_sky_set(
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
		*out = js.raise("a sky needs a GPU device to sample its image, and this context has none");
		return;
	}

	Scene* scene = arg_scene(self, &js, argc, args, 0, out);
	if (scene == null) return;

	int background  = arg_int(&js, argc, args, 1);
	int environment = arg_int(&js, argc, args, 2);
	if (background != NO_TEXTURE && !self.pass.assets.texture_alive(background))
	{
		*out = js.raise("scene.background was given a texture that has been disposed");
		return;
	}
	if (environment != NO_TEXTURE && !self.pass.assets.texture_alive(environment))
	{
		*out = js.raise("scene.environment was given a texture that has been disposed");
		return;
	}

	self.pass.set_scene_sky(scene, true, background);
	self.pass.set_scene_sky(scene, false, environment);
	scene.look.sky.background_intensity = math::max(arg_float(&js, argc, args, 3), 0.0f);
	scene.look.sky.environment_intensity = math::max(arg_float(&js, argc, args, 4), 0.0f);
	scene.look.sky.rotation = arg_float(&js, argc, args, 5);
}

<*
 `budgetGet()` — how long this script may run, in milliseconds.
*>
fn void js_budget_get(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	*out = qjs::number_value((double)(self.script_budget_ns / 1_000_000));
}

<*
 `budgetSet(ms)` — raise or lower how long a script may run.

 ## Why a script may change this at all

 5,000 ms is generous for a script that builds a scene and short for one that
 *simulates* it. The check that proved `examples/village`'s character controller
 walked thirty thousand steps against a hundred and twenty colliders, and the
 first attempt at it was killed by the budget — so it had to be cut into pieces
 that fit five seconds rather than pieces that meant something, which is a worse
 test written for a reason that has nothing to do with what it tests.

 ## Why there is still a ceiling

 The budget exists so that a wedged agent loop is a pause rather than a hang, and
 a limit a script can lift entirely is not a limit. `JS_BUDGET_CEILING_MS` is ten
 minutes: longer than any legitimate scene build by two orders of magnitude,
 shorter than a person's patience with a stuck process. Asking for more is
 clamped rather than refused, because a caller asking for an hour wants "as long
 as possible" and a throw would leave them with the default instead.

 ## It takes effect immediately

 The interrupt handler compares against `budget_ns`, which this writes, and
 `started` was stamped before the script began — so raising it extends the run
 that raised it, which is the only useful behaviour. A test does not know it
 needs longer until it is already running.
*>
fn void js_budget_set(
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

	double asked = (double)arg_float(&js, argc, args, 0);
	if (asked <= 0)
	{
		*out = js.raise(
			"three.budget wants a positive number of milliseconds — there is no way to turn the interrupt off"
		);
		return;
	}

	long ms = (long)asked;
	if (ms > JS_BUDGET_CEILING_MS) ms = JS_BUDGET_CEILING_MS;

	self.script_budget_ns = ms * 1_000_000;
	self.budget_ns = self.script_budget_ns;
}

// ============================================================================
// The clock
// ============================================================================

<*
 The clock this runtime drives, or null with the refusal already raised.

 `open(null)` is a context with no `MeshPass` — the module-loader checks, and
 nothing that boots. It has no scene, no camera and no frames, so it has no
 clock; saying so is better than the alternative both ways round, because a
 getter answering zero and a setter quietly dropping the write is the property
 `api.js` throws on assignment three separate times to avoid.
*>
fn GameClock* JsRuntime.clock_or_raise(&self, qjs::Context* js, qjs::Value* out)
{
	if (self.pass == null)
	{
		*out = js.raise("there is no clock here — this runtime was opened with no scene");
		return null;
	}
	return &self.pass.clock;
}

<*
 `clockTime()` — the game clock, in seconds.

 ## Seven scalar verbs and not one object

 `pointer()` and `lightGet()` pack their fields into one JavaScript object so
 that reading four of them is one crossing. This does the opposite, and
 `plan.md` §17's measurements are why: a host call returning a number costs
 55 ns and one that allocates an object to answer costs 185, and unlike a light
 direction these are read *per frame by gameplay* — `three.clock.dt` is the
 argument to every integration in a script. The rule the measurements gave is
 that a verb returning a scalar is cheaper than the arithmetic it replaces and a
 verb that allocates to answer is a loss on every call forever, so the clock is
 seven scalar verbs.
*>
fn void js_clock_time(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self  = (JsRuntime*)opaque;
	qjs::Context js  = qjs::wrap(ctx);
	GameClock* clock = self.clock_or_raise(&js, out);
	if (clock == null) return;
	*out = qjs::number_value(clock.time);
}

<*
 `clockWall()` — the process's own monotonic clock, in milliseconds.

 ## The one reading the game clock cannot give

 Everything else here is GAME time: scaled by `timeScale`, stopped by a pause,
 and that is what makes `x += speed * three.clock.dt` need no `if`. It is also
 what makes it useless for the one question a profiler asks. A system timed on
 the game clock reads zero while paused and four times its true cost in slow
 motion — the measurement would be a function of the thing being measured's
 own settings.

 So this is a second clock and it answers a different question: **how long did
 that take**, in real milliseconds, whatever the game clock is doing. It is what
 `three.systems.report()` is built on, and the CPU side of a frame — which
 nothing else measures — is why that report is worth having:
 `three.stats()` already breaks the GPU frame into six numbers so a slow scene
 can be blamed on the shadow pass, and there has been nothing at all for the
 half of the frame a script owns.

 Milliseconds as a double rather than nanoseconds as an integer, because the
 consumer is JavaScript and every other duration this API hands out is
 milliseconds. A double holds microsecond resolution for about three hundred
 years of uptime, so the precision that matters here survives the units.

 **Not the same origin as `elapsed_ms`.** That one is the host's, from whenever
 the host started counting; this one starts at `JsRuntime.open`. Differences
 are what either is for, and mixing them is a difference of two origins.
*>
fn void js_clock_wall(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	*out = qjs::number_value((double)self.wall_clock.to_now() / 1_000_000.0);
}

<*
 `clockDelta()` — what the frame being drawn is worth, in game seconds.

 Zero before the first tick and zero while paused, which is the answer a script
 wants in both cases: an integration multiplied by it does nothing, with no flag
 to test and no branch to forget.
*>
fn void js_clock_delta(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self  = (JsRuntime*)opaque;
	qjs::Context js  = qjs::wrap(ctx);
	GameClock* clock = self.clock_or_raise(&js, out);
	if (clock == null) return;
	*out = qjs::number_value(clock.dt);
}

<*
 `clockScaleGet()` — the multiplier from wall time to game time.
*>
fn void js_clock_scale_get(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self  = (JsRuntime*)opaque;
	qjs::Context js  = qjs::wrap(ctx);
	GameClock* clock = self.clock_or_raise(&js, out);
	if (clock == null) return;
	*out = qjs::number_value(clock.scale);
}

<*
 `clockScaleSet(v)` — slow motion, fast forward, and zero for a pause.

 ## Why negative is refused rather than clamped

 A rewind is not a thing anything downstream of the clock can do. A clip would
 have to be sampled backwards, the solver cannot run backwards at all, and a
 fixed accumulator fed a negative delta would sit at a negative balance until
 enough forward time arrived to clear it — three different wrong behaviours from
 one assignment. Refusing by name is the only version of this that says which
 one you get.

 There is no ceiling, because the wall delta is clamped *before* the scale is
 applied: a scale of a thousand is a thousand times a hundred milliseconds at
 worst, which is a hundred seconds of clip in one frame — absurd, and absurd in
 the direction the caller asked for rather than in a direction the engine chose.
*>
fn void js_clock_scale_set(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self  = (JsRuntime*)opaque;
	qjs::Context js  = qjs::wrap(ctx);
	GameClock* clock = self.clock_or_raise(&js, out);
	if (clock == null) return;

	double asked = arg_number(&js, argc, args, 0);
	if (!math::is_finite(asked) || asked < 0)
	{
		*out = js.raise(
			"three.clock.timeScale wants zero or more — zero is paused, and there is no way to run time backwards"
		);
		return;
	}
	clock.scale = asked;
}

<*
 `clockRateGet()` — how many fixed steps a second of game time is worth.
*>
fn void js_clock_rate_get(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self  = (JsRuntime*)opaque;
	qjs::Context js  = qjs::wrap(ctx);
	GameClock* clock = self.clock_or_raise(&js, out);
	if (clock == null) return;
	*out = qjs::number_value(clock.fixed_hz);
}

<*
 `clockRateSet(hz)` — change what a fixed step is.

 **It does not change the solver's rate**, which stays at 60 Hz whatever this
 says. The two are separate on purpose: a physics rate is a property of that
 solver's stability rather than of a game's taste, and a script asking for 30 Hz
 gameplay must not quietly halve the accuracy of every contact in the scene.

 Refused outside `CLOCK_FIXED_HZ_MIN..CLOCK_FIXED_HZ_MAX` rather than clamped,
 because both ends are mistakes rather than requests: below one, a "fixed step"
 has stopped being a step of anything, and above the ceiling the answer is
 always `CLOCK_MAX_FIXED_STEPS` steps a frame and a fixed loop that silently
 runs slow.
*>
fn void js_clock_rate_set(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self  = (JsRuntime*)opaque;
	qjs::Context js  = qjs::wrap(ctx);
	GameClock* clock = self.clock_or_raise(&js, out);
	if (clock == null) return;

	double asked = arg_number(&js, argc, args, 0);
	if (!math::is_finite(asked) || asked < CLOCK_FIXED_HZ_MIN || asked > CLOCK_FIXED_HZ_MAX)
	{
		*out = js.raise(
			string::tformat(
				"three.clock.fixedRate wants %d to %d steps a second — %g is not a rate a fixed loop can run at",
				(int)CLOCK_FIXED_HZ_MIN,
				(int)CLOCK_FIXED_HZ_MAX,
				asked
			)
		);
		return;
	}
	clock.fixed_hz = asked;
}

<*
 `clockAdvance(seconds)` — move a stopped clock by hand.

 What makes `timeScale = 0` a pause rather than a freezer, and what §2's
 screenshot-reproducibility entry was waiting for: with the scale at zero the
 only time that passes is time somebody asked for, so two runs that ask for the
 same amount render the same frame — post pass included, because `p.time` is
 this clock now.

 It lands on the *next* tick rather than here, which is the property that makes
 it honest: everything that consumes a delta is downstream of one call in
 `tick`, so time moved on the spot would be time no clip, no body and no fixed
 step ever saw.
*>
fn void js_clock_advance(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self  = (JsRuntime*)opaque;
	qjs::Context js  = qjs::wrap(ctx);
	GameClock* clock = self.clock_or_raise(&js, out);
	if (clock == null) return;

	double asked = arg_number(&js, argc, args, 0);
	if (!math::is_finite(asked) || asked < 0)
	{
		*out = js.raise("three.clock.advance(seconds) wants zero or more — a clock does not run backwards");
		return;
	}
	clock.advance(asked);
}

<*
 `lightCount()` — how many lights are lit, 1 to `MAX_LIGHTS`.
*>
fn void js_light_count(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	*out = qjs::number_value((double)self.pass.lighting.count);
}

<*
 Which slot a light verb was handed, or `MAX_LIGHTS` and a raise on `out`.

 One function because five verbs take an index and the message has to be the
 same one every time: a script that indexed past the end has a bug, and telling it
 how many there are is the whole of the answer.

 @param first : `The lowest slot this caller accepts. One for lightRemove, which will not take the sun; zero for everything else.`
*>
fn uint arg_light(
	JsRuntime* self,
	qjs::Context* js,
	int argc,
	qjs::Value* args,
	int at,
	uint first,
	qjs::Value* out
) @local
{
	int asked = arg_int(js, argc, args, at);
	if (asked < (int)first || asked >= (int)self.pass.lighting.count)
	{
		*out = js.raise(
			string::tformat(
				"there is no light %d — this scene has %d, numbered 0 to %d",
				asked,
				self.pass.lighting.count,
				self.pass.lighting.count - 1
			)
		);
		return MAX_LIGHTS;
	}
	return (uint)asked;
}

<*
 `lightGet(index)` — one light, as `[x, y, z, r, g, b, intensity, range]`.

 The colour is linear rgb and the intensity multiplies it. The last number says
 what the first three are: 0 is a directional light and they are a surface-to-light
 direction in world space, unnormalized; above 0 it is a point light, they are a
 world position and the number is how far it reaches. See `Light`.

 Seven numbers and an eighth in one array rather than an object, for the reason
 `pointer()` gives: an array crosses in a third of the time an object does, and
 the JS side reads it positionally.
*>
fn void js_light_get(
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

	uint index = arg_light(self, &js, argc, args, 0, 0, out);
	if (index == MAX_LIGHTS) return;

	Light light     = self.pass.lighting.lights[index];
	qjs::Value list = js.array();
	for (uint i = 0; i < 3; i++) js.set_index(list, i, qjs::number_value(light.direction[i]));
	for (uint i = 0; i < 4; i++) js.set_index(list, i + 3, qjs::number_value(light.color[i]));
	// The eighth: the range, 0 for a directional light. Last so that every reader
	// written when there were seven still reads the seven it knows.
	js.set_index(list, 7, qjs::number_value(light.direction[3]));
	*out = list;
}

<*
 `lightSet(index, x, y, z, r, g, b, intensity, range)` — one light, whole.

 `range` is optional and 0 — a directional light — is what its absence means, so
 every caller written before point lights existed still sets the light it set.

 ## Why there is a list of four and why none of them is an Object3D

 `render/pass.c3` ships four `Light`s in `FrameBlock` and the shading shaders loop
 over as many as `lighting.y` says are lit. Four because the fifth is the trigger
 for clustered forward — `plan.md` §19 — and one was the whole model until this
 existed, which cost every scene that wanted a fill light a second material.

 Three.js's answer is `scene.add(new THREE.DirectionalLight(...))`, and this is
 still deliberately not that. A light here is not in the graph: it has no
 position, nothing can be parented to it, and `scene.remove` does not reach it.
 Putting it in the graph would promise all three. `three.lights` is a list of four
 slots and says so.

 **Only light zero casts a shadow**, because only light zero is what the shadow
 map was fitted around. `Light` has the price of the second one.

 ## The direction is not normalized here

 The shaders normalize on read, so length has never meant anything, and
 normalizing at the door would make `lightGet` answer with numbers the script
 did not write. What is refused is the one direction that cannot be normalized
 at all: a zero vector makes `normalize` a NaN, the lambert term a NaN, and the
 frame either black or undefined depending on the driver — a failure with
 nothing anywhere pointing at the light.
*>
fn void js_light_set(
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

	uint index = arg_light(self, &js, argc, args, 0, 0, out);
	if (index == MAX_LIGHTS) return;

	Light light;
	if (!read_light(&js, argc, args, 1, &light, out)) return;

	// **Light zero is a direction and stays one.** It is the light the shadow map
	// is fitted around, and the fit takes a direction — `MeshPass.plan_shadow`
	// hands `lights[0].direction` to `ShadowMap.fit`, which builds an orthographic
	// box along it. A position there is three numbers the fit would read as a
	// heading, which is a shadow map aimed somewhere nobody asked for and nothing
	// anywhere saying so. Refused by name rather than by quietly turning the
	// shadow pass off.
	if (index == 0 && light.direction[3] > 0.0f)
	{
		*out = js.raise(
			"three.lights[0] is the sun the shadow map is fitted around and is a direction — a point light goes in one of the other three slots"
		);
		return;
	}

	Lighting lighting = self.pass.lighting;
	lighting.lights[index] = light;
	self.set_lighting(lighting);
}

<*
 `lightAdd(x, y, z, r, g, b, intensity, range)` — a light in the next free slot,
 whose index it answers with. `range` above 0 makes it a point light standing at
 `x, y, z`.

 Refused rather than silently dropped once four are lit. A fifth light that did
 nothing would be a scene lit differently from the one the script describes, with
 nothing anywhere saying which light went missing.
*>
fn void js_light_add(
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

	if (self.pass.lighting.count >= MAX_LIGHTS)
	{
		*out = js.raise(
			string::tformat(
				"three.lights holds %d lights and all of them are in use — set one you already have, or remove it first",
				MAX_LIGHTS
			)
		);
		return;
	}

	Light light;
	if (!read_light(&js, argc, args, 0, &light, out)) return;

	Lighting lighting = self.pass.lighting;
	lighting.lights[lighting.count] = light;
	lighting.count++;
	self.set_lighting(lighting);
	*out = qjs::number_value((double)(lighting.count - 1));
}

<*
 `lightRemove(index)` — takes a light out and closes the gap.

 The slots above it move down, exactly as `Array.prototype.splice` does, which is
 what makes `three.lights[i]` mean the i-th light rather than the i-th slot that
 was ever filled. A script holding an index across a remove is holding a
 different light, and that is the same rule an array index has always had.

 **Light zero cannot be removed.** It is the one the shadow map is fitted around,
 so removing it would silently move every shadow in the scene onto whichever light
 happened to be next. Turning it off is `three.light.intensity = 0`.
*>
fn void js_light_remove(
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

	int asked = arg_int(&js, argc, args, 0);
	if (asked == 0)
	{
		*out = js.raise(
			"three.lights[0] is the light the shadow map is fitted around and cannot be removed — set its intensity to 0 to turn it off"
		);
		return;
	}

	uint index = arg_light(self, &js, argc, args, 0, 1, out);
	if (index == MAX_LIGHTS) return;

	Lighting lighting = self.pass.lighting;
	for (uint i = index; i + 1 < lighting.count; i++) lighting.lights[i] = lighting.lights[i + 1];
	lighting.count--;
	self.set_lighting(lighting);
}

<*
 One light off the argument list, or a raise on `out`.

 Shared by `lightSet` and `lightAdd` because the only difference between them is
 where the light goes, and a second copy of the zero-direction check is a second
 place for it to be forgotten.

 @param at : `Where the seven numbers start.`
 @param light : `Written only when this answers true.`
 @return `False when the direction was refused, with the raise already on out.`
*>
fn bool read_light(qjs::Context* js, int argc, qjs::Value* args, int at, Light* light, qjs::Value* out) @local
{
	float x = arg_float(js, argc, args, at);
	float y = arg_float(js, argc, args, at + 1);
	float z = arg_float(js, argc, args, at + 2);
	// The range, and so which kind of light this is — 0 is directional, which is
	// what a caller that passes seven numbers means and what every caller written
	// before there was an eighth one meant.
	float range = math::max(arg_float(js, argc, args, at + 7), 0.0f);

	// Only a *direction* cannot be zero. A point light at the origin is a light at
	// the origin, and the three numbers are a place rather than a heading.
	if (range == 0.0f && x * x + y * y + z * z <= 0.0f)
	{
		*out = js.raise(
			"a light's direction cannot be zero — it is a direction, and normalizing it would be a NaN in every shading term"
		);
		return false;
	}

	*light = {
		.direction = { x, y, z, range },
		.color = {
			math::clamp(arg_float(js, argc, args, at + 3), 0.0f, 1.0f),
			math::clamp(arg_float(js, argc, args, at + 4), 0.0f, 1.0f),
			math::clamp(arg_float(js, argc, args, at + 5), 0.0f, 1.0f),
			math::max(arg_float(js, argc, args, at + 6), 0.0f),
		},
	};
	return true;
}

<*
 `ambientGet()` — the floor a face gets when it is turned right away from every
 light.
*>
fn void js_ambient_get(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	*out = qjs::number_value(self.pass.lighting.ambient);
}

<*
 `ambientSet(a)` — that floor, clamped to 0..1.

 Frame-wide rather than per light, and not itself a light: it is what stands in
 for every bounce this renderer does not simulate, so four lights do not mean four
 floors. `Lighting.ambient` has the rest of that argument.
*>
fn void js_ambient_set(
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

	Lighting lighting = self.pass.lighting;
	lighting.ambient = math::clamp(arg_float(&js, argc, args, 0), 0.0f, 1.0f);
	self.set_lighting(lighting);
}

<*
 `shadowGet()` — the shadow settings, as
 `[enabled, size, bias, intensity, distance, follow]`.

 `enabled` comes back as 1 or 0 rather than as a boolean because this array is
 the same shape `lightGet` uses and the JS side reads it positionally; `api.js`
 turns it back into a boolean at the property.

 **`size` is what a script asked for, already clamped**, and is not necessarily
 the size of the image on the device: an image is only created or recreated at
 the top of a frame, so reading this back immediately after setting it answers
 with the request. That is the right answer — the request is the setting, and the
 image is how it is honoured.
*>
fn void js_shadow_get(
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

	ShadowMap* shadows = &self.pass.shadows;
	qjs::Value list    = js.array();
	js.set_index(list, 0, qjs::number_value(shadows.enabled ? 1.0 : 0.0));
	js.set_index(list, 1, qjs::number_value((double)shadows.size));
	js.set_index(list, 2, qjs::number_value((double)shadows.bias));
	js.set_index(list, 3, qjs::number_value((double)shadows.intensity));
	js.set_index(list, 4, qjs::number_value((double)shadows.distance));
	// 1 or 0 for `enabled`'s reason, and last for the reason every field added to
	// one of these arrays is last: a script destructuring the first five keeps
	// working.
	js.set_index(list, 5, qjs::number_value(shadows.follow ? 1.0 : 0.0));
	*out = list;
}

<*
 `shadowFit()` — what the last fit came out as, as
 `[live, cx, cy, cz, extent, near, far, texel]`.

 Read-only, and derived rather than stored: this is `ShadowMap.report`, which
 reads back the same nine numbers `fit` wrote. There is nothing to set here — the
 fit is a consequence of the light, the scene's bounds and `distance`, and a
 script that wants it somewhere else moves one of those.

 Positional for the same reason `shadowGet` is: `api.js` names the fields once,
 at the property, and one array is one host crossing.
*>
fn void js_shadow_fit(
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

	ShadowFit fit   = self.pass.shadows.report();
	qjs::Value list = js.array();
	js.set_index(list, 0, qjs::number_value(fit.live ? 1.0 : 0.0));
	js.set_index(list, 1, qjs::number_value((double)fit.centre.x));
	js.set_index(list, 2, qjs::number_value((double)fit.centre.y));
	js.set_index(list, 3, qjs::number_value((double)fit.centre.z));
	js.set_index(list, 4, qjs::number_value((double)fit.extent));
	js.set_index(list, 5, qjs::number_value((double)fit.near));
	js.set_index(list, 6, qjs::number_value((double)fit.far));
	js.set_index(list, 7, qjs::number_value((double)fit.texel));
	*out = list;
}

<*
 `debugViewGet()` — which debug view the shading pass is drawing, as a number.

 The names live in `api.js` and the number lives here, which is the same split
 every enum in this binding uses: a host crossing carries a number, and the one
 place that has to know `'shadow'` is 1 is the one place a typo can be caught.
*>
fn void js_debug_view_get(
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
	*out = qjs::int_value((int)self.pass.debug_view);
}

<*
 `debugViewSet(mode)` — draw a diagnostic instead of the scene.

 **It is not scene state and `new three.Scene()` does not clear it**, which is
 the same rule the camera and `three.controls.enabled` follow: a script rebuilding
 the world is not a reason to switch off a diagnostic somebody is reading. An
 agent iterating on a level is exactly the caller here, and it rebuilds the scene
 every run.

 Out-of-range values clamp to off rather than throwing. The API surface that can
 produce one is `three.debug.view = 'shadwo'`, and `api.js` refuses that by name
 before it ever reaches a number — what arrives here is either a name it knew or
 a script reaching past the property, and the honest answer to the second is the
 scene.
*>
fn void js_debug_view_set(
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

	float mode = arg_float(&js, argc, args, 0);
	self.pass.debug_view = mode >= 1.0f && mode <= (float)DEBUG_VIEW_MAX ? (uint)mode : 0;
}

<*
 Says what a shadow map larger than the default costs, the once it is asked for.

 `three.light.shadow.size = 4096` is one assignment, one clamp away from 8192,
 and 134 MB — more than everything else in a frame put together, and the setter
 is the only place that knows both numbers before the allocation happens. It was
 the largest single thing in a process nobody could account for, and nothing
 anywhere said so.

 Only above the default, and only when the number moves. 2048 is the size this
 project chose and warning about a default is noise; a script that writes the
 same size every frame has not done anything worth a second sentence.

 Both images, because there are two: `image` and `static_image` are the same
 format at the same extent, and the second is allocated the moment a scene has a
 static caster — which is the ordinary thing to do to scenery, so the doubled
 figure is the one to plan for rather than the surprise afterwards.
*>
fn void say_shadow_size(uint was, uint now) @local
{
	if (now <= SHADOW_DEFAULT_SIZE || now == was) return;

	// D32, one texel per texel. `ShadowMap.bytes` reads the allocations back once
	// they exist; this has to answer before there are any.
	usz each = (usz)now * now * 4;
	@advise(
		"three: shadow.size = %d is %d MB of depth image, and %d MB once anything in the scene is "
			"static — image and static_image are the same format at the same extent. "
			"stats().shadowBytes is what it actually cost.",
		now,
		each / (1024 * 1024),
		(each * 2) / (1024 * 1024)
	);
}

<*
 `shadowSet(enabled, size, bias, intensity, distance, follow)` — all six at once.

 ## Why all five rather than five setters

 The same shape `lightSet` has, for the same reason: `api.js` presents six
 independent properties and each one reads the other five back and writes the
 lot, so there is one crossing per assignment instead of a getter and a setter per
 field. It also makes the clamping happen in one place.

 ## What is clamped and what is refused

 Everything is clamped and nothing is refused, which is the opposite of
 `lightSet`'s answer for a zero direction — and the difference is whether a bad
 value has a sensible neighbour. A zero light direction does not: every reading of
 it is a NaN, so the only honest response is to say so. A shadow map of 8 texels
 has one, and it is 256; an intensity of 4 has one, and it is 1. Refusing those
 would turn "I tried a number" into an exception in a script that is otherwise
 working.

 `size` is rounded to a power of two on the way down as well as clamped. Not
 because the device requires it — nothing here does — but because a shadow map is
 a memory footprint a script should be able to reason about in halvings, and
 2000 quietly costing what 2048 costs is a number that lies about itself.

 **Turning shadows off does not free anything.** The image and the pipeline stay,
 so a script toggling shadows in a menu pays the allocation once. What it does do
 is stop the pass recording, which is the whole cost — see `MeshPass.prepare`.
*>
fn void js_shadow_set(
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

	ShadowSettings settings;
	settings.enabled = arg_float(&js, argc, args, 0) != 0.0f;

	uint wanted  = (uint)math::clamp(arg_float(&js, argc, args, 1), (float)SHADOW_MIN_SIZE, (float)SHADOW_MAX_SIZE);
	uint rounded = SHADOW_MIN_SIZE;
	while (rounded * 2 <= wanted) rounded *= 2;
	settings.size = rounded;
	say_shadow_size(self.pass.shadows.settings.size, rounded);

	// The bias has no upper bound worth inventing — past a certain size every
	// shadow simply disappears, which is a visible answer to a value somebody
	// typed. It is floored at zero because a negative one is acne on purpose.
	float bias = arg_float(&js, argc, args, 2);
	settings.bias = bias > 0.0f ? bias : 0.0f;
	settings.intensity = math::clamp(arg_float(&js, argc, args, 3), 0.0f, 1.0f);
	// Floored at zero, where zero means "derive one from the orbit distance" —
	// see `ShadowMap.reach`. There is no ceiling: a distance past the far plane
	// is silently the far plane, because the fit takes the smaller of the two,
	// and refusing a number that already behaves sensibly would be noise.
	float reach = arg_float(&js, argc, args, 4);
	settings.distance = reach > 0.0f ? reach : 0.0f;
	// Stated rather than left to the zero fill, which is the one field here where
	// those differ — see `ShadowSettings.follow` and `DEFAULT_SHADOW`.
	settings.follow = arg_float(&js, argc, args, 5) != 0.0f;

	self.set_shadow(settings);
}

fn void js_camera_get(
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

	Camera* camera  = &self.pass.camera;
	qjs::Value list = js.array();
	js.set_index(list, 0, qjs::number_value(camera.target.x));
	js.set_index(list, 1, qjs::number_value(camera.target.y));
	js.set_index(list, 2, qjs::number_value(camera.target.z));
	js.set_index(list, 3, qjs::number_value(camera.yaw));
	js.set_index(list, 4, qjs::number_value(camera.pitch));
	js.set_index(list, 5, qjs::number_value(camera.distance));
	js.set_index(list, 6, qjs::number_value(camera.fov));
	// Reported since M6, and read-only on the JS side. They are still derived
	// rather than set — `Camera.derive_planes` argues that at length — but derived
	// is not the same as secret, and while they were neither reported nor settable
	// there was no way at all to find out that the sky had fallen outside the far
	// plane except by rendering and guessing.
	js.set_index(list, 7, qjs::number_value(camera.near_plane));
	js.set_index(list, 8, qjs::number_value(camera.far_plane));
	// Appended rather than slotted in beside the other two angles, because the
	// index is the wire format: `three.camera.yaw` is `H.cameraGet()[3]` in
	// `api.js`, and renumbering to put roll next to pitch would silently move
	// every reader after it.
	js.set_index(list, 9, qjs::number_value(camera.roll));
	*out = list;
}

<*
 `cameraSet(tx, ty, tz, yaw, pitch, distance, fov, roll)`.

 The near and far planes are re-derived from the distance and the scene's own
 bounds rather than taken from the caller — see `Camera.derive_planes` for why —
 and the angles are clamped the same way a mouse drag clamps them, so a script
 and a hand on the window cannot put the camera in two different sets of states.
*>
fn void js_camera_set(
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

	Camera* camera = &self.pass.camera;
	camera.target = { arg_float(&js, argc, args, 0), arg_float(&js, argc, args, 1), arg_float(&js, argc, args, 2) };
	camera.yaw = arg_float(&js, argc, args, 3);
	camera.pitch = arg_float(&js, argc, args, 4);
	// **Zero is allowed and is what first person is** — the eye sits on the point
	// it orbits, which is a character's head once `three.camera.attach` is
	// writing that point. The floor used to be 0.0001 to keep `look_at` from
	// dividing by a zero-length forward vector; `Camera.view` handles the
	// degenerate boom directly now, and the old floor would have made
	// `orbit(yaw, pitch)` — which passes the current distance straight back —
	// quietly leave first person for a value no script asked for.
	camera.distance = math::max(arg_float(&js, argc, args, 5), 0.0f);
	camera.fov = math::clamp(arg_float(&js, argc, args, 6), 1.0f, 179.0f);
	// Unclamped and unwrapped, unlike the other two angles. `clamp_angles` holds
	// pitch off the pole and wraps yaw because both protect `look_at` from a
	// degenerate basis; roll cannot make one — see `Camera.roll`. Wrapping it
	// anyway would make `camera.roll += 1` in a loop read back as a sawtooth,
	// which is worse than a large number for a value a script is integrating.
	camera.roll = arg_float(&js, argc, args, 7);

	camera.clamp_angles();
	// Through the pass rather than `camera.derive_planes()` directly, so the far
	// plane is fitted to the scene the script has built instead of to a multiple
	// of the distance it just asked for. `MeshPass.derive_camera_planes` has the
	// argument; the short version is that a script that dollies in used to lose
	// its sky.
	self.pass.derive_camera_planes();
}

fn void js_frame_all(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	self.pass.frame_camera();
}

<*
 `cameraAttach(index, generation, ox, oy, oz, distance, lag, local)` — follow a node.

 `plan.md` §17. Everything about what this does is in `CameraFollow`; what is
 here is the two things the boundary has to decide.

 **The distance is applied once, not held.** It is written straight onto the
 camera and the follow never looks at it again, so the wheel, a drag and
 `three.camera.orbit()` all go on working while attached — and a script that
 scrolls out of `distance: 0` has left first person, with no mode anywhere to
 keep in step. What the follow owns is the orbit *point*; what it deliberately
 does not own is where the eye stands relative to it.

 **A negative lag is refused rather than clamped.** Zero already means rigid, so
 a negative one cannot be a shorthand for anything — it is a sign error in the
 caller's arithmetic, and clamping it to zero would hide that behind a camera
 that merely feels wrong.

 `local` is the eighth argument and is `CameraFollow.local_offset` — whether the
 offset is read in the node's own frame. It is a flag rather than a second verb
 because everything else about the attachment is the same; see there for what
 the two frames mean and why a cockpit needs the second one.
*>
fn void js_camera_attach(
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

	// The rendered scene's, and refused otherwise: the follow is read once per
	// frame against one graph, and a handle from a scene that is not being drawn
	// would resolve to nothing every frame — a camera that silently stopped
	// following rather than one that said so.
	NodeRef ref = arg_live_handle(self, &js, argc, args, 0, out, "three.camera.attach(object)");
	if (ref.scene == null) return;
	NodeId node = ref.id;

	float lag = arg_float(&js, argc, args, 6);
	if (lag < 0.0f)
	{
		*out = js.raise("three.camera.attach(object, { lag }) wants seconds — 0 for rigid, and never a negative");
		return;
	}

	self.pass.follow = {
		.active = true,
		.node = node,
		.offset = {
			arg_float(&js, argc, args, 2),
			arg_float(&js, argc, args, 3),
			arg_float(&js, argc, args, 4),
		},
		.lag_ms = lag,
		.local_offset = arg_truth(&js, argc, args, 7),
	};

	self.pass.camera.distance = math::max(arg_float(&js, argc, args, 5), 0.0f);

	// Where the thing already is, before a frame has ticked. Without it a script
	// that attaches and screenshots in the same run pictures the camera at
	// whatever it was looking at before — and a rigid follow that is one frame
	// late on its very first frame is the bug this whole feature exists to avoid,
	// arriving at the one moment nobody would look for it.
	self.follow_camera(0);
}

<*
 `cameraDetach()` — stop following, and answer whether anything was.

 The camera is left exactly where the last frame put it, which is the only
 answer that does not move the picture at the moment a script says "stop moving
 the picture".
*>
fn void js_camera_detach(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	bool was        = self.pass.follow.active;
	self.pass.follow = { };
	*out = qjs::bool_value(was);
}

<*
 `cameraAttached()` — the followed node as a handle, or null.

 Null is also how a script learns that what it was following has been destroyed:
 `follow_camera` drops the attachment silently when the node goes, because the
 alternative is raising from inside a tick nobody called.
*>
fn void js_camera_attached(
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

	if (!self.pass.follow.active || self.pass.scene.node(self.pass.follow.node) == null)
	{
		*out = qjs::null_value();
		return;
	}
	*out = handle_value(&js, self.pass.follow.node);
}
<*
 The other half of `three.debug.overlay`: the line, in pixels.

 `debugWrite` puts it in the run's `debug` array for an agent to read; this puts
 it on the frame for a person. The interface layer is brought up by the first
 non-empty line and never before — a script that does not call this pays nothing
 for it, which is what keeps the headless tests unchanged.

 Silent with no renderer: `three.debug.overlay` still logs and still writes, and
 a scene with no GPU device is not a thing to raise about. The one failure worth
 telling a script about is the layer refusing to come up.
*>
fn void js_debug_overlay(
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

	if (self.renderer == null) return;

	String line = arg_text(&js, argc, args, 0, tmem);
	if (catch self.renderer.ui.set_overlay(&self.renderer.gpu, &self.renderer.target, line))
	{
		*out = js.raise("the overlay could not be drawn — the interface layer failed to start");
	}
}
