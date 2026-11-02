<*
 `globalThis.__three` — the flat verbs `prelude.js` is written against.

 ## Why this layer is flat and boring

 Everything Three.js-shaped — classes, prototype chains, `children` arrays,
 getters that write through, `add`/`remove`/`traverse` — lives in `prelude.js`,
 because in JavaScript those are ordinary and in a host binding each one is a
 function. What is left here is the set of things JavaScript genuinely cannot do:
 reach the scene graph, the asset table, the camera and the device.

 ## Nodes are handles, revalidated on every call

 `plan.md` §1 requires a JS handle to revalidate on access and *throw* rather
 than dereference a freed node, which is what `NodeId`'s generation was built for
 at M2. A node crosses as its `Node` handle (bind_args.c3), and every verb below
 that names one resolves it through `NodeRef.from_js` first: a stale one raises a
 JS `Error` naming what happened, so a script that keeps a mesh across a
 `scene.dispose()` gets a sentence, not a corrupted neighbour.

 The verbs about one node are methods of the `Node` class — `obj._h.setName(n)` —
 and the rest are functions on `__three`.
*>
module three;

import std::math;
import std::math::vector;
import collision;
import fastjs::js;
import fastjs::js::opt;
import std::collections::list;

<*
 Install `__three` on the global object.

 Called before `prelude.js` is evaluated — it opens by reading `__three` and
 throws if it is missing.
*>
fn void JsRuntime.install_bindings(&self)
{
	js::Value host = self.js.object()!!;
	self.install_handles(host)!!;
	self.bind_node_methods()!!;

	// Assets (js/bind_asset.c3)
	self.bind_asset_verbs(host)!!;

	// Scenes, picking, the frame, the clock, lights, shadows and the camera
	self.bind_scene_verbs(host)!!;

	// Materials (js/bind_shader.c3)
	self.bind_shader_verbs(host)!!;

	// The one post shader (js/bind_post.c3)
	self.bind_post_verbs(host)!!;

	// The interface (js/bind_ui.c3)
	self.bind_ui_verbs(host)!!;

	// The animation loop (js/frame_loop.c3)
	self.bind_frame_verbs(host)!!;

	// The keyboard (js/bind_input.c3)
	self.bind_input_verbs(host)!!;

	// Saving (js/bind_save.c3)
	self.bind_save_verbs(host)!!;

	// Physics (js/bind_physics.c3)
	self.bind_physics_verbs(host)!!;

	// Bulk queries, the character controller and the batched write
	// (js/bind_query.c3)
	self.bind_query_verbs(host)!!;

	// Navigation and steering (js/bind_nav.c3)
	self.bind_nav_verbs(host)!!;

	// Buffers, kernels and dispatches (js/bind_compute.c3)
	self.bind_compute_verbs(host)!!;

	self.js.set(self.js.global(), "__three", host)!!;
}

<*
 The verbs about one node, as methods of `Node`: `this` is the node.

 @return? js::THREW
*>
fn void? JsRuntime.bind_node_methods(&self)
{
	js::NativeClass* node = self.node_class;
	// The graph
	self.js.@method(node, "remove", &js_remove, self)!;
	self.js.@method(node, "setParent", &js_set_parent, self)!;
	self.js.@method(node, "setTransform", &js_set_transform, self)!;
	self.js.@method(node, "setQuaternion", &js_set_quaternion, self)!;
	self.js.@method(node, "setVisible", &js_set_visible, self)!;
	self.js.@method(node, "setStatic", &js_set_static, self)!;
	self.js.@method(node, "setCollides", &js_set_collides, self)!;
	self.js.@method(node, "setCollisionOnly", &js_set_collision_only, self)!;
	self.js.@method(node, "setBlocks", &js_set_blocks, self)!;
	self.js.@method(node, "setName", &js_set_name, self)!;
	self.js.@method(node, "setColor", &js_set_color, self)!;
	self.js.@method(node, "setVariant", &js_set_variant, self)!;
	self.js.@method(node, "worldPosition", &js_world_position, self)!;
	self.js.@method(node, "objectBounds", &js_object_bounds, self)!;
	// Animation
	self.js.@method(node, "bindAnimation", &js_bind_animation, self)!;
	self.js.@method(node, "bindSkin", &js_bind_skin, self)!;
	self.js.@method(node, "bindSocket", &js_bind_socket, self)!;
	self.js.@method(node, "unbindSocket", &js_unbind_socket, self)!;
	self.js.@method(node, "setMorphWeights", &js_set_morph_weights, self)!;
	self.js.@method(node, "playAnimation", &js_play_animation, self)!;
	self.js.@method(node, "stopAnimation", &js_stop_animation, self)!;
	self.js.@method(node, "animationState", &js_animation_state, self)!;
	self.js.@method(node, "blendAnimation", &js_blend_animation, self)!;
}

<*
 @return? js::THREW
*>
fn void? JsRuntime.bind_scene_verbs(&self, js::Value host)
{
	// The graph
	self.js.@bind(host, "sceneCreate", &js_scene_create, self)!;
	self.js.@bind(host, "sceneActivate", &js_scene_activate, self)!;
	self.js.@bind(host, "sceneDispose", &js_scene_dispose, self)!;
	self.js.@bind(host, "sceneAlive", &js_scene_alive, self)!;
	self.js.@bind(host, "sceneActive", &js_scene_active, self)!;
	self.js.@bind(host, "sceneIds", &js_scene_ids, self)!;
	self.js.@bind(host, "disposeInactive", &js_dispose_inactive, self)!;
	self.js.@bind(host, "add", &js_add, self)!;
	self.js.@bind(host, "meshMorphs", &js_mesh_morphs, self)!;

	// Picking
	self.js.@bind(host, "pick", &js_pick, self)!;
	self.js.@bind(host, "raycast", &js_raycast, self)!;

	// The frame
	self.js.@bind(host, "stats", &js_stats, self)!;
	self.js.set(host, "debugWrite", self.js.function(&js_debug_write, "debugWrite", 1, self)!)!;
	self.js.@bind(host, "debugOverlay", &js_debug_overlay, self)!;
	self.js.@bind(host, "unloadUnused", &js_unload_unused, self)!;
	// Hot reload (reload.c3), and closing the window (app/boot.c3)
	self.js.@bind(host, "reload", &js_reload, self)!;
	self.js.@bind(host, "quit", &js_quit, self)!;
	self.js.@bind(host, "render", &js_render, self)!;
	self.js.@bind(host, "screenshot", &js_screenshot, self)!;
	self.js.@bind(host, "renderSize", &js_render_size, self)!;
	self.js.@bind(host, "renderResize", &js_render_resize, self)!;
	self.js.@bind(host, "renderFollowWindow", &js_render_follow_window, self)!;
	self.js.@bind(host, "renderScaleGet", &js_render_scale_get, self)!;
	self.js.@bind(host, "renderScaleSet", &js_render_scale_set, self)!;
	self.js.@bind(host, "backgroundGet", &js_background_get, self)!;
	self.js.@bind(host, "backgroundSet", &js_background_set, self)!;
	self.js.@bind(host, "skyGet", &js_sky_get, self)!;
	self.js.@bind(host, "skySet", &js_sky_set, self)!;
	self.js.@bind(host, "budgetGet", &js_budget_get, self)!;
	self.js.@bind(host, "budgetSet", &js_budget_set, self)!;

	// The clock
	self.js.@bind(host, "clockTime", &js_clock_time, self)!;
	self.js.@bind(host, "clockWall", &js_clock_wall, self)!;
	self.js.@bind(host, "clockDelta", &js_clock_delta, self)!;
	self.js.@bind(host, "clockScaleGet", &js_clock_scale_get, self)!;
	self.js.@bind(host, "clockScaleSet", &js_clock_scale_set, self)!;
	self.js.@bind(host, "clockRateGet", &js_clock_rate_get, self)!;
	self.js.@bind(host, "clockAlpha", &js_clock_alpha, self)!;
	self.js.@bind(host, "clockRateSet", &js_clock_rate_set, self)!;
	self.js.@bind(host, "clockAdvance", &js_clock_advance, self)!;

	// Lights
	self.js.@bind(host, "lightCount", &js_light_count, self)!;
	self.js.@bind(host, "lightGet", &js_light_get, self)!;
	self.js.@bind(host, "lightIndex", &js_light_index, self)!;
	self.js.@bind(host, "lightSet", &js_light_set, self)!;
	self.js.@bind(host, "lightAdd", &js_light_add, self)!;
	self.js.@bind(host, "lightRemove", &js_light_remove, self)!;
	self.js.@bind(host, "lightShadowGet", &js_light_shadow_get, self)!;
	self.js.@bind(host, "lightShadowSet", &js_light_shadow_set, self)!;
	self.js.@bind(host, "lightBakedGet", &js_light_baked_get, self)!;
	self.js.@bind(host, "lightBakedSet", &js_light_baked_set, self)!;
	self.js.@bind(host, "lightsBake", &js_lights_bake, self)!;
	self.js.@bind(host, "lightsBakeBudget", &js_lights_bake_budget, self)!;
	self.js.@bind(host, "lightsSaveBake", &js_lights_save_bake, self)!;
	self.js.@bind(host, "lightsLoadBake", &js_lights_load_bake, self)!;
	self.js.@bind(host, "ambientGet", &js_ambient_get, self)!;
	self.js.@bind(host, "ambientSet", &js_ambient_set, self)!;
	self.js.@bind(host, "worldGet", &js_world_get, self)!;
	self.js.@bind(host, "worldSet", &js_world_set, self)!;

	// Shadows and the renderer's switches
	self.js.@bind(host, "shadowGet", &js_shadow_get, self)!;
	self.js.@bind(host, "shadowSet", &js_shadow_set, self)!;
	self.js.@bind(host, "pointShadowGet", &js_point_shadow_get, self)!;
	self.js.@bind(host, "pointShadowSet", &js_point_shadow_set, self)!;
	self.js.@bind(host, "shadowBudgetGet", &js_shadow_budget_get, self)!;
	self.js.@bind(host, "shadowBudgetSet", &js_shadow_budget_set, self)!;
	self.js.@bind(host, "occlusionGet", &js_occlusion_get, self)!;
	self.js.@bind(host, "occlusionSet", &js_occlusion_set, self)!;
	self.js.@bind(host, "depthPrepassGet", &js_depth_prepass_get, self)!;
	self.js.@bind(host, "depthPrepassSet", &js_depth_prepass_set, self)!;
	self.js.@bind(host, "alwaysRenderGet", &js_always_render_get, self)!;
	self.js.@bind(host, "alwaysRenderSet", &js_always_render_set, self)!;
	self.js.@bind(host, "sceneCacheGet", &js_scene_cache_get, self)!;
	self.js.@bind(host, "sceneCacheSet", &js_scene_cache_set, self)!;
	self.js.@bind(host, "shadowFit", &js_shadow_fit, self)!;
	self.js.@bind(host, "debugViewGet", &js_debug_view_get, self)!;
	self.js.@bind(host, "debugViewSet", &js_debug_view_set, self)!;

	// The camera
	self.js.@bind(host, "cameraGet", &js_camera_get, self)!;
	self.js.@bind(host, "cameraSet", &js_camera_set, self)!;
	self.js.@bind(host, "cameraAttach", &js_camera_attach, self)!;
	self.js.@bind(host, "cameraDetach", &js_camera_detach, self)!;
	self.js.@bind(host, "cameraAttached", &js_camera_attached, self)!;
	self.js.@bind(host, "cameraRay", &js_camera_ray, self)!;
	self.js.@bind(host, "cameraProject", &js_camera_project, self)!;
	self.js.@bind(host, "frameAll", &js_frame_all, self)!;
}

<*
 The scene a scene id names, for the verbs about a whole scene rather than a
 node in one.

 @return? js::THREW
*>
fn Scene*? scene_named(JsRuntime* self, uint id) @local
{
	Scene* found = self.pass == null ? null : self.pass.scene_by_id(id);
	if (found == null)
	{
		return self.js.fail("that Scene was disposed — its objects, its bodies and its nav bake are gone")~;
	}
	return found;
}

// ============================================================================
// The graph
// ============================================================================

// A scene as `sceneCreate` and `sceneIds` describe it: its id and its root's handle.
struct SceneEntry
{
	uint id;
	NodeId root;
}

<*
 A new scene, made active — `new three.Scene()`.

 Three.js's meaning, and the divergence this removes: the scene that was active
 stays exactly as it was, with its nodes, its bodies and its asset references. A
 script holding it can go on building it, and `scene.activate()` shows it again.

 What that costs is a world nobody frees, so `SceneStats.scenes` counts them and
 `MeshPass.note_scene_created` says something when the count starts to look like
 a level transition that forgot `scene.dispose()`.

 @return `{ id, root }: the scene id and its root's Node handle, because a Scene needs both.`
*>
fn SceneEntry js_scene_create(JsRuntime* self)
{
	Scene* fresh = self.pass.claim_scene();
	self.activate_scene(fresh);
	return { .id = (uint)fresh.id, .root = fresh.root };
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
fn bool js_scene_activate(JsRuntime* self, uint id)
{
	Scene* target = self.pass.scene_by_id(id);
	if (target == null) return false;
	self.activate_scene(target);
	return true;
}

<*
 Frees a scene and everything it owns — `scene.dispose()`.

 Refuses the active one; `MeshPass.dispose_scene` has the argument. The asset
 references its nodes held go back here, so a `three.unloadUnused()` afterwards
 is what actually reclaims memory — and two scenes over one kit means this frees
 nothing, which is right.

 @return `false if the id names nothing, or names the scene being rendered.`
*>
fn bool js_scene_dispose(JsRuntime* self, uint id) => self.pass.dispose_scene(id);

// Whether a scene id still names a scene. What `Scene._check()` in the prelude
// asks before every call.
fn bool js_scene_alive(JsRuntime* self, uint id) => self.pass.scene_by_id(id) != null;

// The id of the scene being rendered.
fn uint js_scene_active(JsRuntime* self) => self.pass.scene == null ? 0 : (uint)self.pass.scene.id;

<*
 Every live scene, as `{ id, root }` — `three.scenes`.

 The list is the thing an agent could not see. A `Scene` in JavaScript is a
 wrapper around `_sid` and nothing else, so a scene built inside a `run_script`
 scope that then ended is alive, counted, holding a node pool and a set of asset
 references, and named by no handle in existence — the exact shape of the leak
 `note_scene_created` warns about. The host knew all of them the whole time.

 The root travels with the id for `js_scene_create`'s reason: it is what lets the
 prelude hand back a usable handle for a scene whose wrapper is gone.

 @return? js::THREW
*>
fn js::Value? js_scene_ids(JsRuntime* self)
{
	js::Value list = self.js.array()!;
	foreach (each : self.pass.scenes)
	{
		SceneEntry entry = { .id = (uint)each.id, .root = each.root };
		self.js.push(list, self.js.@object_of(entry)!);
	}
	return list;
}

<*
 Frees every scene except the one being rendered — `three.disposeInactive()`.

 Safe by construction, and `MeshPass.dispose_scene` is why: it refuses the active
 one, so the loop cannot leave the frame with nothing to draw however many scenes
 it walks.

 The verb exists because the transition is three steps — activate the next one,
 dispose the rest, `unloadUnused` — and the middle one is the one that gets
 forgotten. Nothing here reclaims memory on its own: the asset references go back
 when the scenes do, and the sweep afterwards is what frees them.

 @return `How many were disposed.`
*>
fn uint js_dispose_inactive(JsRuntime* self)
{
	uint disposed = 0;
	// Backwards: `dispose_scene` removes from the list it is walking.
	sz at = self.pass.scenes.len();
	while (at > 0)
	{
		at--;
		if (self.pass.dispose_scene(self.pass.scenes[at].id)) disposed++;
	}
	return disposed;
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
	self.pass.point_shadows.apply(target.look.point_shadow);
	self.pass.shadow_view_set.budget = target.look.shadow_budget;
	self.pass.ambient_occlusion.apply(target.look.ambient_occlusion);
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
	// Before the assignment, because it needs both readings of a light that moved
	// — see `MeshPass.note_lighting_change`.
	self.pass.note_lighting_change(lighting);
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

fn void JsRuntime.set_point_shadow(&self, PointShadowSettings settings)
{
	self.pass.point_shadows.settings = settings;
	if (self.pass.scene != null) self.pass.scene.look.point_shadow = settings;
}

fn void JsRuntime.set_shadow_budget(&self, ShadowBudget budget)
{
	self.pass.shadow_view_set.budget = budget;
	if (self.pass.scene != null) self.pass.scene.look.shadow_budget = budget;
}

fn void JsRuntime.set_ambient_occlusion(&self, AmbientOcclusionSettings settings)
{
	self.pass.ambient_occlusion.settings = settings;
	if (self.pass.scene != null) self.pass.scene.look.ambient_occlusion = settings;
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

// An Asset handle argument that may be null, which `add` reads as "a group".
struct MaybeAsset
{
	AssetId id;
	bool given;
}

<*
 @return? js::THREW
*>
fn void? MaybeAsset.from_js(&self, js::Call* c, int at)
{
	if (c.get(at).is_nullish()) return;
	self.id.from_js(c, at)!;
	self.given = true;
}

<*
 `add(asset, mesh, parent, name)` — a new node under `parent`, as its Node handle.

 A null `asset` is a group: traversed and transformed, never drawn. The parent's
 handle is what names the scene — an object is added to the graph its parent is
 in, which is what lets a script build the next level while the current one is
 on screen.

 @return? js::THREW
*>
fn NodeId? js_add(JsRuntime* self, MaybeAsset asset, int mesh, NodeRef parent, String name)
{
	if (!asset.given) return parent.scene.add_group(parent.id, name);

	// The one refusal here is a mesh index the asset does not have, and it is
	// worth a sentence rather than a null handle: it is the mistake a script
	// makes, and an unset id would surface three lines later as a missing
	// object with no reason attached.
	if (self.pass.assets.mesh(asset.id, (uint)mesh) == null)
	{
		return self.js.fail("there is no mesh %d in asset %d", mesh, asset.id.index)~;
	}

	// No retain here since G2: `Scene.create_slot` takes the reference, so the
	// count has one implementation rather than one per caller.
	return parent.scene.add_mesh(asset.id, (uint)mesh, parent.id, name);
}

<*
 `node.remove()`.

 @return? js::THREW
*>
fn void? js_remove(JsRuntime* self, NodeRef ref)
{
	// The root is the scene itself; emptying it is `scene.unload()` and freeing it
	// is `scene.dispose()`.
	if (ref.id == ref.scene.root)
	{
		return self.js.fail("the Scene cannot be removed — scene.unload() empties it, scene.dispose() frees it")~;
	}
	ref.scene.remove(ref.id);
}

<*
 `node.setParent(parent)`.

 @return? js::THREW
*>
fn void? js_set_parent(JsRuntime* self, NodeRef ref, NodeRef parent)
{
	// Two scenes are two node pools, so this would have to destroy the subtree and
	// rebuild it under the other root — which is exactly what re-parenting is
	// documented *not* to do, since a rebuild invalidates every handle into
	// something that never left the graph. Refused rather than half-done, and the
	// test is whether the parent is a node of the child's own scene at all.
	if (ref.scene != parent.scene || ref.scene.node(parent.id) == null)
	{
		return self.js.fail("an object cannot be moved between scenes — rebuild it in the one you want it in")~;
	}
	ref.scene.set_parent(ref.id, parent.id);
}

<*
 `node.setTransform(px, py, pz, rx, ry, rz, sx, sy, sz)`.

 All nine at once rather than one verb per channel: `prelude.js` holds the local
 transform as JavaScript numbers and pushes the whole thing on any write, so
 there is never a partial state to reason about and `m.position.set(...)` is one
 call instead of three.

 @return? js::THREW
*>
fn void? js_set_transform(JsRuntime* self, NodeRef ref, Vec3 position, Vec3 rotation, Vec3 scale)
{
	// `game.md` G5/S6. The camera resolves a script and a drag by
	// last-writer-wins because both describe the same intent; a solver and a
	// script writing the same transform every frame describe two, and the
	// result is jitter rather than a compromise. So this is a refusal and not
	// a merge — and the vtable answers while this side throws, because a table of
	// function pointers has no way to raise a JavaScript exception.
	if (ref.scene.physics.owns_transform(ref.id)) return refusal(self, ref)~;

	Node* target = ref.scene.node(ref.id);
	target.position = position;
	// Euler in, quaternion stored — the one-way conversion `scene/node.c3`
	// describes. A caller keeps whatever triple it sent; nothing converts back.
	target.rotation = quat_from_euler(rotation);
	target.scale = scale;
	say_nan_transform(ref.id, target);
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
fn void say_nan_transform(NodeId id, Node* node) @local
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
fn fault refusal(JsRuntime* self, NodeRef ref) @local
{
	if (!ref.scene.physics.owns_transform(ref.id)) return self.js.fail("that object cannot be moved");
	String why = ref.scene.physics.transform_refusal(ref.id);
	if (why.len == 0) return self.js.fail("that object cannot be moved");
	return self.js.fail("%s", why);
}

<*
 `node.setQuaternion(x, y, z, w)` — a rotation that did not come from Euler
 angles.

 Sent after `setTransform` and overwriting the rotation it just wrote, by an
 object that was handed an exact quaternion — today that means one out of
 `asset.instantiate()`. Two calls rather than one, and only for those objects:
 the Euler triple is what a script reads back off `.rotation`, and the
 quaternion is what actually rotates the node.

 Writing any Euler component drops the quaternion, so a script that touches
 `.rotation` gets exactly what it typed and nothing left over from the file.

 @return? js::THREW
*>
fn void? js_set_quaternion(JsRuntime* self, NodeRef ref, float x, float y, float z, float w)
{
	// The same refusal `js_set_transform` makes, and it has to be here too: a
	// script that only ever wrote `.quaternion` would otherwise fight the
	// solver through the one door that was left open.
	if (ref.scene.physics.owns_transform(ref.id)) return refusal(self, ref)~;
	ref.scene.set_quaternion(ref.id, { x, y, z, w });
}

// One number out of a JS array, with a finite backstop: a forged call gets
// `fallback` instead of spreading a NaN into its neighbours.
fn float? element(JsRuntime* self, js::Value array, long at, float fallback = 0) @local
{
	double number = self.js.get_number(array, at)!;
	return math::is_finite(number) ? (float)number : fallback;
}

<*
 `node.bindAnimation(asset, pairs, liveSkin)` — tell the host which of a
 subtree's nodes came from which glTF node.

 The map an `AnimationPlayer` needs, and the reason it has to come from
 JavaScript at all: `asset.instantiate()` builds `Object3D`s and lets the
 ordinary `add` path materialize them, so the host performed the tree walk one
 node at a time through `js_add` and never saw the correspondence.
 `Scene.instantiate` on the host has the same map for free; both hand it to
 `Scene.bind_player`.

 `pairs` is flat — glTF node index, node index, node generation, repeating —
 because it is written once per instantiated prop and read once, and three
 numbers per node beats an object per node.

 Called lazily, on the first `play`. A prop that never animates never sends it.

 @return `Whether it took, so the prelude caches only a bind that happened — see Object3D._bindAnimation.`
 @return? js::THREW
*>
fn bool? js_bind_animation(JsRuntime* self, NodeRef ref, AssetId asset, js::Value pairs, bool live_skin)
{
	long length = self.js.length(pairs)!;
	if (length < 0) length = 0;

	List {uint} sources;
	List {NodeId} nodes;
	sources.init(mem, (sz)(length / 3) + 1);
	nodes.init(mem, (sz)(length / 3) + 1);
	defer sources.free();
	defer nodes.free();

	for (long i = 0; i + 2 < length; i += 3)
	{
		sources.push(whole(element(self, pairs, i)!));
		nodes.push({ .index = whole(element(self, pairs, i + 1)!), .generation = whole(element(self, pairs, i + 2)!) });
	}

	// `live_skin`: whether this character is posed from its bone nodes. The script
	// asked for a skeleton, and a skeleton that drives nothing would be the
	// read-only version of the flag rather than the useful one. See
	// `AnimationPlayer.live_skin`.
	return ref.scene.bind_player(asset, ref.id, sources.array_view(), nodes.array_view(), live_skin);
}

// A whole number out of an array element, zero for anything that is not one.
fn uint whole(float number) @local => number > 0 ? (uint)number : 0;

<*
 `node.playAnimation(name, loop, speed, time, fade, sync)` — start a clip on an
 instantiated subtree.

 Answers with a boolean rather than throwing on an unknown clip: `mesh.animations`
 is the list, so naming something that is not on it is a mistake a script can see
 and correct, and an exception raised inside an animation callback is a stopped
 game rather than a wrong pose.

 `time` is the start phase: a hundred characters on one walk cycle at a hundred
 phases are a hundred values of it over one baked clip. `fade` is seconds of
 crossfade out of whatever was playing, zero for a snap. `sync` is the phase
 offset `sync` asked for, already folded into [0, 1) by the prelude; negative is
 no sync.
*>
fn bool js_play_animation(
	JsRuntime* self,
	NodeRef ref,
	String name,
	Opt {bool} loop,
	Opt {float} speed,
	Opt {float} time,
	Opt {float} fade,
	Opt {float} sync
)
{
	return ref.scene.play(ref.id, name, loop.or(true), speed.or(1.0f), time.or(0), fade.or(0), sync.or(-1));
}

<*
 `node.setMorphWeights(weights)` — how much of each blend shape this copy wears.

 The whole vector every time rather than one element, which is the same choice
 `setTransform` makes: a face has a handful of targets, and a call per element
 per frame would cost more than the numbers do.

 An all-zero vector takes the copy off the morph path entirely — see
 `Scene.set_morph_weights` — so a face that has finished its expression stops
 costing a loop rather than looping over zeroes.

 Answers with a boolean rather than throwing on a mesh with no targets, for
 `playAnimation`'s reason: `mesh.morphs` is the count, so asking a box to smile is
 a mistake a script can see.

 @return? js::THREW
*>
fn bool? js_set_morph_weights(JsRuntime* self, NodeRef ref, js::Value values)
{
	long length = self.js.length(values)!;
	if (length < 0) length = 0;

	List {float} weights;
	weights.init(mem, (sz)length + 1);
	defer weights.free();
	for (long i = 0; i < length; i++) weights.push(element(self, values, i)!);

	return ref.scene.set_morph_weights(ref.id, weights.array_view());
}

<*
 `meshMorphs(asset, mesh)` — how many morph targets a geometry has.

 Read off the uploaded mesh, so it answers zero for a file whose meshes have not
 reached the device yet — which is why the prelude asks it lazily, on the first
 look at `mesh.weights`, rather than in the `Mesh` constructor.
*>
fn uint js_mesh_morphs(JsRuntime* self, AssetId asset, uint mesh)
{
	GpuMesh* found = self.pass.assets.mesh(asset, mesh);
	return found == null ? 0 : (uint)found.morph_targets;
}

<*
 `holder.bindSocket(root, bone)` — keep a node on a bone of a baked character.

 Answers with a boolean rather than throwing, for `playAnimation`'s reason: the
 bone names belong to the file, so naming one the rig does not have is a mistake a
 script can see and correct. The prelude turns the false into a sentence that
 lists what the rig does have.
*>
fn bool js_bind_socket(JsRuntime* self, NodeRef holder, NodeRef root, String bone)
{
	return holder.scene.attach_socket(holder.id, root.id, bone);
}

<*
 `node.unbindSocket()` — take a node off whatever bone it was on.

 It stays where the bone last left it. Nothing in the prelude calls this yet; it
 is here because attaching without a way to detach is a one-way door, and the host
 side of it is three lines.
*>
fn bool js_unbind_socket(JsRuntime* self, NodeRef ref) => ref.scene.detach_socket(ref.id);

<*
 `node.bindSkin(skin, compute)` — tell a node which skin poses it.

 **The JavaScript path needs this and the host path does not.** `Scene.instantiate`
 creates every node itself and sets the skin as it goes; `asset.instantiate()` in
 a script hands back `Object3D`s that materialize later through the ordinary
 `add`, so by the time a host node exists nothing remembers that it came from a
 skinned entry. `Object3D._materialize` calls this straight after `H.add`, which
 is the first moment there is a node to tell.

 A skin of -1 clears it, which is what every ordinary mesh is.
*>
fn void js_bind_skin(JsRuntime* self, NodeRef ref, Opt {float} skin, bool compute)
{
	int index = (int)skin.or(-1);
	ref.scene.set_skin(ref.id, index);

	Node* node = ref.scene.node(ref.id);
	if (node != null) node.preskinned = index >= 0 && compute;
}

// `node.stopAnimation()` — hold the pose. See `Scene.stop`.
fn bool js_stop_animation(JsRuntime* self, NodeRef ref) => ref.scene.stop(ref.id);

<*
 `node.blendAnimation(fade, speed, name, weight, offset, ...)` — hold several clips
 at once.

 Up to four `(name, weight, offset)` triples after the two numbers, positional
 rather than an array because the prelude has already validated and flattened
 them and four is the most there can be. An offset below zero is a clip on its
 own clock. See `Scene.blend`.

 @return? js::THREW
*>
fn bool? js_blend_animation(JsRuntime* self, NodeRef ref, float fade, float speed, js::Call* c)
{
	@pool()
	{
		String[ANIMATION_LAYERS] names;
		float[ANIMATION_LAYERS] weights;
		float[ANIMATION_LAYERS] offsets;
		usz count = 0;
		int argc  = (int)c.args.len;
		for (int at = 2; at + 2 < argc && count < ANIMATION_LAYERS; at += 3)
		{
			names[count] = c.text(at);
			weights[count] = (float)c.number(at + 1)!;
			offsets[count] = (float)c.number(at + 2)!;
			count++;
		}
		return ref.scene.blend(ref.id, names[:count], weights[:count], fade, offsets[:count], speed);
	};
}

// One layer as a script reads it, `time` measured from the clip's own start the
// way `play` takes it.
struct AnimationLayerState
{
	String name;
	double time;
	double duration;
	double speed;
	bool loop;
	bool playing;
	double weight;
}

fn AnimationLayerState layer_state(AnimationLayer* layer, AnimationClip* clip) @local
{
	return {
		.name = clip.name,
		.time = (double)layer.time - clip.start,
		.duration = clip.duration,
		.speed = layer.speed,
		.loop = layer.loop,
		.playing = layer.playing,
		.weight = layer.weight,
	};
}

<*
 `node.animationState()` — where the clip on a subtree is, or null before
 anything has played.

 A state machine needs the playhead to know where a one-shot is and when it has
 run out; without it a script keeps a second clock that drifts from this one the
 first time the game clock is scaled or capped. `time` is seconds into the clip
 from its own start, the same measure `play`'s `time` takes, and `playing` is
 false on a one-shot that has finished as well as after `stop()`.

 The dominant layer's fields, plus `layers`: every layer on the stack, the same
 shape.

 @return? js::THREW
*>
fn js::Value? js_animation_state(JsRuntime* self, NodeRef ref)
{
	if (ref.scene.assets == null) return js::NULL;
	AnimationPlayer* player = ref.scene.player(ref.id);
	if (player == null || player.layer_count == 0) return js::NULL;
	Asset* loaded = ref.scene.assets.slot(player.asset);
	if (loaded == null) return js::NULL;

	int top = player.dominant();
	js::Value layers = self.js.array()!;
	js::Value state = js::NULL;
	for (uint i = 0; i < player.layer_count; i++)
	{
		AnimationLayer* layer = &player.layers[i];
		if (layer.clip < 0 || layer.clip >= loaded.clips.len()) continue;
		AnimationLayerState entry = layer_state(layer, &loaded.clips[layer.clip]);
		if ((int)i == top) state = self.js.@object_of(entry)!;
		self.js.push(layers, self.js.@object_of(entry)!);
	}
	if (state.is_null()) return js::NULL;
	self.js.set(state, "layers", layers)!;
	return state;
}

// `node.setVisible(on)`.
fn void js_set_visible(JsRuntime* self, NodeRef ref, bool on) => ref.scene.set_visible(ref.id, on);

<*
 `node.setCollides(on)` — whether this node is collision geometry.

 Returns nothing, like `setVisible` and unlike `setStatic`: there is no node this
 can be refused on. `Node.collides` has what it is for.
*>
fn void js_set_collides(JsRuntime* self, NodeRef ref, bool on) => ref.scene.set_collides(ref.id, on);

<*
 `node.setBlocks(on)` — whether this node stands in a mover's way.

 Returns nothing, like `setCollides`. `Node.blocks` has what it is for.
*>
fn void js_set_blocks(JsRuntime* self, NodeRef ref, bool on) => ref.scene.set_blocks(ref.id, on);

<*
 `node.setCollisionOnly(on)` — whether this node is swept against and never drawn.

 The half of `setCollides` that has no opposite: a node with this on is in every
 query and in no draw list, which is what a `KHR_implicit_shapes` box needs to be
 and what nothing else here can be. `Node.collision_only` has the argument.
*>
fn void js_set_collision_only(JsRuntime* self, NodeRef ref, bool on) => ref.scene.set_collision_only(ref.id, on);

<*
 `node.setStatic(on)` — put this node in the cached half of the shadow map, and
 say whether it went.

 **Answers rather than returning nothing**, unlike `setVisible` beside it, and
 the reason is that this one can be refused: a node with a skin is not something
 "it does not move" can be true of, so the host says no and the prelude keeps the
 answer. `Scene.set_static_caster` has the argument.
*>
fn bool js_set_static(JsRuntime* self, NodeRef ref, bool on) => ref.scene.set_static_caster(ref.id, on);

// `node.setName(name)`.
fn void js_set_name(JsRuntime* self, NodeRef ref, String name) => ref.scene.set_name(ref.id, name);

<*
 `node.setColor(r, g, b, a)` — this copy's own tint.

 **This is one of the two verbs that do not cost a draw call**, which is the
 whole point of them: the value lands in the node's `Instance` record and is read
 by `SV_InstanceID`, so two copies of one mesh may disagree about it and stay in
 one bucket. Everything else that changes how a mesh looks is bucket state.
*>
fn void js_set_color(JsRuntime* self, NodeRef ref, float r, float g, float b, float a)
{
	ref.scene.set_color(ref.id, { r, g, b, a });
}

<*
 `node.setVariant(row)` — which row of the material's table.

 Negative is clamped to zero rather than refused: the row is a `uint` on the way
 to the GPU, and a script that computed `i - 1` at `i = 0` should get the first
 row rather than four billion. The far end is clamped in the shader against the
 rows the material actually declared — see `shaders/material.shady`.
*>
fn void js_set_variant(JsRuntime* self, NodeRef ref, int variant)
{
	ref.scene.set_variant(ref.id, variant < 0 ? 0 : (uint)variant);
}

<*
 `node.worldPosition()` — where a node ended up in world space, as `[x, y, z]`.

 The world matrices are brought up to date first: a script that sets a position
 and immediately asks where something is would otherwise read the transform from
 before its own write, which is the shape of bug that renders fine and reports
 the wrong number.
*>
fn Vec3 js_world_position(JsRuntime* self, NodeRef ref)
{
	ref.scene.update_world_matrices();
	return ref.scene.node(ref.id).world_position();
}

<*
 `node.objectBounds()` — the world-space box of a subtree as
 `[minX, minY, minZ, maxX, maxY, maxZ]`, or `null` when nothing under it draws.

 The world-space half of what `meshBounds` answers in mesh-local space, and the
 reason both exist: a script placing a piece against a wall needs to know where
 the piece's *faces* end up, which is its own bounds run through every transform
 between it and the root. Doing that arithmetic in JavaScript would mean
 re-deriving world matrices the host already keeps.

 Flat because `boxFromSix` in the prelude builds the `Box3` a script sees. Null
 rather than a zero box for an empty subtree — see `Scene.subtree_bounds`.

 @return? js::THREW
*>
fn js::Value? js_object_bounds(JsRuntime* self, NodeRef ref)
{
	// `drawn` is the bool separating "nothing under it draws" from a zero-sized box
	// at the origin, which is a distinction the box alone cannot carry.
	bool drawn = false;
	collision::Aabb3 box = ref.scene.subtree_bounds(&self.pass.assets, ref.id, &drawn);
	if (!drawn) return js::NULL;
	return self.js.numbers({ box.min.x, box.min.y, box.min.z, box.max.x, box.max.y, box.max.z });
}

// ============================================================================
// Picking
// ============================================================================

<*
 `pick(x, y)` — what is under a pixel of the rendered image, as a `PickHit`, or
 `null` for a miss.

 **A miss is `null` rather than an empty list**, which is where this diverges
 from Three.js's `intersectObjects`. `Scene.raycast` answers with the closest
 drawable node and nothing behind it, so a list would never hold more than one
 thing and its length would be a fact about this implementation rather than
 about the scene.

 The extent is the **offscreen target's**, which is the image `screenshot` hands
 back, so the coordinates an agent reads off the PNG it was given are the
 coordinates this takes. `JsRuntime.pick_hit` is the click handler's question
 too; this one refuses without a device because a script that asked has to be
 told.

 @return? js::THREW
*>
fn js::Value? js_pick(JsRuntime* self, float x, float y)
{
	self.require_gpu("picking by screen position")!;
	return self.pick_hit(x, y);
}

<*
 `raycast(ox, oy, oz, dx, dy, dz)` — a world-space ray, answered like `pick`.

 No device is needed and none is asked for: with nothing loaded there is nothing
 to hit and the answer is `null`, which is the truth rather than an error.

 The direction is normalised here rather than being required to arrive that way.
 `Hit.distance` is measured along a unit ray, so an unnormalised direction would
 silently return a distance in units of its own length — the same class of
 mistake `Scene.raycast` already guards against between instance scales.

 @return? js::THREW
*>
fn js::Value? js_raycast(JsRuntime* self, Vec3 origin, Vec3 direction)
{
	float length = direction.length();
	if (length < 1e-12f) return self.js.fail("raycast wants a direction with a length — (0, 0, 0) points nowhere")~;

	collision::Ray ray = { .origin = origin, .direction = direction / length };
	Hit hit = self.pass.scene.raycast(&self.pass.assets, ray);
	if (!hit.hit) return js::NULL;

	// The name rides along because a scene opened from the command line has nodes
	// no script ever made an object for, and `object: null` alone would be a dead end.
	Node* node = self.pass.scene.node(hit.node);
	PickHit found = {
		.node = hit.node,
		.name = node == null ? "" : node.name,
		.distance = hit.distance,
		.point = hit.point,
		.normal = hit.normal,
	};
	return self.js.@object_of(found);
}

// The world-space ray through a pixel.
struct PixelRay
{
	Vec3 origin;
	Vec3 direction;
}

<*
 `cameraRay(x, y)` — the world-space ray through a pixel, as `{ origin, direction }`.

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

 @return? js::THREW
*>
fn PixelRay? js_camera_ray(JsRuntime* self, float x, float y)
{
	// Same refusal as `renderSize`, and for the same reason: a pixel coordinate
	// only means something against a target that has a size, and without a
	// device there is none to count in.
	if (self.renderer == null)
	{
		return self.js.fail("a ray through a pixel needs a render target and this context has none")~;
	}

	collision::Ray ray = screen_ray(
		&self.pass.camera,
		x,
		y,
		self.renderer.target.extent.width,
		self.renderer.target.extent.height,
	);
	return { .origin = ray.origin, .direction = ray.direction };
}

<*
 `cameraProject(x, y, z)` — the pixel a world point is drawn at, as
 `[column, row, depth]`, or null for a point behind the eye.

 `cameraRay` backwards, through the same `screen_point` arithmetic and the same
 extent, so a point on the ray through a pixel comes back as that pixel. An
 overlay that drew its labels from a second derivation — eye, forward, right
 and field of view — would agree at the centre and drift at the edges, which is
 a name drawn beside the character it names.

 @return? js::THREW
*>
fn js::Value? js_camera_project(JsRuntime* self, Vec3 point)
{
	if (self.renderer == null)
	{
		return self.js.fail("a pixel for a point needs a render target and this context has none")~;
	}

	float[<3>] pixel;
	if (!screen_point(
		&self.pass.camera,
		point,
		self.renderer.target.extent.width,
		self.renderer.target.extent.height,
		&pixel,
	))
	{
		return js::NULL;
	}
	return self.js.numbers({ pixel[0], pixel[1], pixel[2] });
}

// ============================================================================
// The frame
// ============================================================================

<*
 What `three.stats()` answers. The keys are the fields in camelCase, and scripts
 and `docs/stats.md` read them by name, so a field here is renamed nowhere else.
*>
struct FrameStatsAnswer
{
	uint draw_calls;
	uint unique_meshes;
	uint instances;
	uint nodes;
	// Beside `nodes` rather than beside `drawCalls`, because the pair is the point:
	// the gap between them is what a level's author has said `collides = false`
	// about. `SceneStats.colliders` has the rest.
	uint colliders;
	uint assets;
	uint triangles;
	uint vertices;
	uint textures;
	double texture_bytes;
	// The share of those bytes that is BC7 blocks. The difference is the RGBA8
	// share, which is four times the bandwidth the same picture would cost
	// compressed — a number about the exporter rather than about the engine.
	double texture_compressed_bytes;
	// The device-wide texture array: slots holding a live image, and how many it
	// holds. Both 0 on a device without descriptor indexing.
	uint texture_slots;
	uint texture_slot_capacity;
	// Beside `assets`, because it is the same kind of number as `assets` and
	// `materials`: something a script has to hand back. See `SceneStats.scenes`.
	uint scenes;
	uint materials;
	uint culled_last_frame;
	// The light's cull beside the camera's — §18.2. Zero with shadows off.
	uint shadow_culled;
	// What skinning costs, apart from everything else — see `SceneStats`.
	uint skinned_draws;
	uint skinned_instances;
	uint preskinned_instances;
	double pose_bytes;
	// The memory the RENDERER owns, which is where nearly all of it actually is —
	// `SceneStats` has why. Process-wide rather than per scene, including when the
	// call names a scene that is not the rendered one.
	double shadow_bytes;
	double occlusion_bytes;
	double target_bytes;
	double post_bytes;
	double geometry_bytes;
	double cluster_bytes;
	uint cluster_overflow;
	// The draws the shadow pass made last frame, which is the only place a script
	// can see that turning shadows on roughly doubled the frame's draw calls —
	// `drawCalls` counts the scene pass.
	uint shadow_draws;
	uint prepass_draws;
	// What the cached half cost, on the frames it was rebuilt — §19.3. Zero is the
	// number to want: the shadow map held from one frame to the next.
	uint shadow_static_draws;
	uint shadow_views;
	uint shadow_rejected;
	uint shadow_updates;
	double shadow_update_texels;
	uint shadow_deferred;
	// Whether anything in the scene has asked for a cut-out shadow — §28. It
	// reports a pipeline that exists, not one that was used this frame.
	bool shadow_cutout;
	// What the last `three.lights.bake()` covered, and what it did not — a static
	// receiver whose uvs cannot carry a tile is counted rather than dropped
	// silently, because that is the number that explains a bake with no effect.
	uint lightmap_receivers;
	uint lightmap_skipped;
	double lightmap_bytes;
	uint lightmap_dirty;
	// The frame's sweeps, as the one nested object: the four are ratios of each
	// other. See `SweepCounters`.
	SweepCounters sweep;
	double gpu_ms;
	double prepare_ms;
	double shadow_ms;
	double scene_ms;
	double post_ms;
	double present_ms;
	double fragments_shaded;
	// Frames the renderer decided were already on screen and did not draw again,
	// and the frames it did draw. The pair, because what a script wants to know is
	// the ratio.
	double skipped_frames;
	double rendered_frames;
	double scene_cache_pixels;
	double scene_cache_reused;
}

<*
 `stats(sceneId)`, or `stats()` for the rendered scene — the numbers an agent
 reads its own cost off (`plan.md`'s second thesis).

 The scene being asked about is not always the one being rendered: a script
 building the next level wants to know how big it has got before it shows it.

 ## The GPU numbers are merged in here rather than living in `SceneStats`

 Every other number is a fact about the scene: it is the same whatever device is
 behind it, and the same from every camera angle — which is what
 `stats_stays_camera_free_with_transparency` pins. GPU milliseconds are a fact
 about a *device* that drew a *frame*, so they are joined to the answer at this
 boundary instead, where both halves are in scope.

 **Always set, even at zero.** A runtime with no device answers 0, not
 `undefined`: a missing key makes `ms > 16` false and `ms.toFixed(2)` throw, and
 neither failure names the reason. The five phase milliseconds sum to `gpuMs` —
 `gpu/timing.c3` writes the marks and `plan.md` §18.3 has why they exist.

 @return? js::THREW
*>
fn FrameStatsAnswer? js_stats(JsRuntime* self, Opt {int} id)
{
	Scene* scene = self.pass.scene;
	if (id.given) scene = scene_named(self, (uint)id.value)!;

	SceneStats stats = self.scene_stats(scene);
	Renderer* renderer = self.renderer;
	FrameTiming timing = renderer != null ? renderer.timing() : (FrameTiming) { };
	return {
		.draw_calls = (uint)stats.draw_calls,
		.unique_meshes = (uint)stats.unique_meshes,
		.instances = (uint)stats.instances,
		.nodes = (uint)stats.nodes,
		.colliders = (uint)stats.colliders,
		.assets = (uint)stats.assets,
		.triangles = (uint)stats.triangles,
		.vertices = (uint)stats.vertices,
		.textures = (uint)stats.textures,
		.texture_bytes = (double)stats.texture_bytes,
		.texture_compressed_bytes = (double)stats.texture_compressed_bytes,
		.texture_slots = (uint)stats.texture_slots,
		.texture_slot_capacity = (uint)stats.texture_slot_capacity,
		.scenes = (uint)stats.scenes,
		.materials = (uint)stats.materials,
		.culled_last_frame = (uint)stats.culled_last_frame,
		.shadow_culled = (uint)stats.shadow_culled_last_frame,
		.skinned_draws = (uint)stats.skinned_draws,
		.skinned_instances = (uint)stats.skinned_instances,
		.preskinned_instances = (uint)stats.preskinned_instances,
		.pose_bytes = (double)stats.pose_bytes,
		.shadow_bytes = (double)stats.shadow_bytes,
		.occlusion_bytes = (double)stats.occlusion_bytes,
		.target_bytes = (double)stats.target_bytes,
		.post_bytes = (double)stats.post_bytes,
		.geometry_bytes = (double)stats.geometry_bytes,
		.cluster_bytes = (double)stats.cluster_bytes,
		.cluster_overflow = (uint)stats.cluster_overflow,
		.shadow_draws = (uint)stats.shadow_draws,
		.prepass_draws = (uint)stats.prepass_draws,
		.shadow_static_draws = (uint)stats.shadow_static_draws,
		.shadow_views = (uint)stats.shadow_views,
		.shadow_rejected = (uint)stats.shadow_rejected,
		.shadow_updates = (uint)stats.shadow_updates,
		.shadow_update_texels = (double)stats.shadow_update_texels,
		.shadow_deferred = (uint)stats.shadow_deferred,
		.shadow_cutout = stats.shadow_cutout,
		.lightmap_receivers = (uint)stats.lightmap_receivers,
		.lightmap_skipped = (uint)stats.lightmap_skipped,
		.lightmap_bytes = (double)stats.lightmap_bytes,
		.lightmap_dirty = (uint)stats.lightmap_dirty,
		.sweep = stats.sweep,
		.gpu_ms = timing.total,
		.prepare_ms = timing.prepare,
		.shadow_ms = timing.shadow,
		.scene_ms = timing.scene,
		.post_ms = timing.post,
		.present_ms = timing.present,
		// Same join and the same unconditional zero as `gpuMs`: a device without
		// `pipelineStatisticsQuery`, and a runtime with no device at all, both
		// answer 0 rather than dropping the key.
		.fragments_shaded = renderer != null ? (double)renderer.fragments_shaded() : 0.0,
		.skipped_frames = renderer != null ? (double)renderer.skipped_frames : 0.0,
		.rendered_frames = renderer != null ? (double)renderer.rendered_frames : 0.0,
		.scene_cache_pixels = renderer != null ? (double)renderer.scene_cache_pixels : 0.0,
		.scene_cache_reused = renderer != null ? (double)renderer.scene_cache_reused : 0.0,
	};
}

<*
 `unloadUnused()` — free every asset no live node names, and say what went.

 `game.md` G2/S3, and the reason it is a verb rather than a finalizer is written
 there: a collector-driven free makes resident memory depend on when the
 collector felt like running, which is the worst possible property for the one
 number a game watches. A level boundary is an explicit moment and this is what
 happens at it.

 Answers with `{ assets, meshes, textures, bytes }` rather than nothing, because
 an agent that cannot see the number move has no way to tell a working unload
 from a no-op — and `stats()` afterwards is the independent confirmation. `bytes`
 is texture bytes alone, so a sweep that gave back geometry and no images answers
 0; `stats().geometryBytes` across the call is that half.

 Costs a full device idle when there is anything to free and nothing at all when
 there is not, so calling it every level is right and calling it every frame is
 merely wasteful.
*>
fn UnloadReport js_unload_unused(JsRuntime* self)
{
	// A null device is a scene-math runtime: nothing was ever uploaded, so there
	// is nothing to give back and an exception would make a script written for a
	// game fail under a test harness.
	Gpu* gpu = self.renderer != null ? &self.renderer.gpu : null;
	return self.pass.assets.unload_unused(gpu);
}

<*
 `render()` — draw one frame now.

 @return? js::THREW
*>
fn void? js_render(JsRuntime* self)
{
	self.require_gpu("three.render")!;
	if (catch err = self.renderer.render_offscreen())
	{
		return self.js.fail("the frame could not be drawn: %s", err)~;
	}
}

<*
 `screenshot(path)` — draw one frame and write it to a `.png`.

 The `--screenshot` flag as a verb, and the reason it is one is that the flag
 cannot answer a script that wants *several* pictures of one run: the CLI writes
 a frame it was told to write, on a schedule made of `--frames` and `--every`, so
 a script that wanted six different images had to arrange for the state of each
 one to fall on the frame the flag would capture. `examples/trimsheet.js` was
 exactly that until this existed.

 One frame, drawn here. It is `Renderer.capture` — `render()` plus the readback —
 so this both draws and writes, and a `three.render()` immediately before it is
 a wasted frame rather than a required one. Post-processing, the interface and
 `three.debug.overlay` are all in it, because there is one recording path and
 this goes down it.

 Called from inside the animation callback it still happens *now*: the capture
 submits and waits on its own command buffer, the same way `three.render()` does.
 That costs a device round trip in the middle of a tick, so a script writing one
 file per frame of a real game is doing something it should know it is doing.

 The path is `writable_path`'s — under `--assets` inside the game directory and
 nowhere else — and a folder that is not there yet is made, exactly as
 `scene.export` makes one.

 @return `{ path, width, height, bytes } — see written_image.`
 @return? js::THREW
*>
fn WrittenImage? js_screenshot(JsRuntime* self, String asked)
{
	self.require_gpu("three.screenshot")!;
	if (asked.len == 0) return self.js.fail("three.screenshot(path) wants a path to write a .png to")~;

	String writing = self.writable_path(asked, "three.screenshot()", tmem)!;
	if (catch err = self.renderer.screenshot(writing))
	{
		return self.js.fail("three.screenshot() could not write %s: %s", asked, err)~;
	}
	return written_image(writing, self.renderer.target.extent.width, self.renderer.target.extent.height);
}

// The offscreen target's extent.
struct RenderSize
{
	uint width;
	uint height;
}

<*
 `renderSize()` — the offscreen target's extent, as `{ width, height }`.

 Without it `pick(x, y)` would take pixels of an image whose size a script has
 no way to ask for: the agent driving over MCP learns it from `screenshot`, and
 a script running inside one call would have to be told. `pick(w / 2, h / 2)`
 is the line this exists for.

 @return? js::THREW
*>
fn RenderSize? js_render_size(JsRuntime* self)
{
	if (self.renderer == null)
	{
		return self.js.fail("there is no render target without a GPU device, so it has no size")~;
	}
	return { .width = self.renderer.target.extent.width, .height = self.renderer.target.extent.height };
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

 @return? js::THREW
*>
fn bool? js_render_resize(JsRuntime* self, int width, int height)
{
	if (width < 1 || height < 1 || width > RENDER_MAX_SIDE || height > RENDER_MAX_SIDE)
	{
		return self.js.fail("three.setRenderSize(width, height) wants two sizes between 1 and %d pixels; got %dx%d",
			RENDER_MAX_SIDE, width, height)~;
	}

	if (self.renderer == null)
	{
		return self.js.fail("there is no render target without a GPU device, so there is nothing to resize")~;
	}

	// Pinned before the resize rather than after, and before the deferral too: a
	// queued resize that only pinned when it landed would spend the frames in
	// between still following the window, and a drag inside that window would
	// arrive after the pin and be honoured.
	self.renderer.render_size_pinned = true;
	// And the scale goes with it: an absolute size and a fraction of the window
	// are two answers to the same question, and leaving the fraction behind would
	// make `three.setRenderSize(null)` come back to a resolution nobody asked for.
	self.renderer.render_scale = 0.0f;

	if (self.in_frame)
	{
		self.render_width_wanted = (uint)width;
		self.render_height_wanted = (uint)height;
		return false;
	}

	if (catch err = self.renderer.resize_target((uint)width, (uint)height))
	{
		return self.js.fail("three.setRenderSize could not make a %dx%d target: %s", width, height, err)~;
	}
	return true;
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
fn bool js_render_follow_window(JsRuntime* self)
{
	if (self.renderer == null) return false;
	self.renderer.render_size_pinned = false;
	self.render_width_wanted = 0;
	self.render_height_wanted = 0;
	return true;
}

// What `three.window.renderScale` may be set to. A quarter of the pixels a side
// is the bottom of what any game ships as a slider, and 2.0 is supersampling —
// past either the picture is not a render scale any more, it is a different
// intent that `three.setRenderSize` already spells.
const double RENDER_SCALE_MIN = 0.25;
const double RENDER_SCALE_MAX = 2.0;

<*
 `renderScaleGet()` — the fraction of the window the target follows at.

 One rather than zero when nothing has set it, so a script reads the identity
 and never has to know that the field's default is spelled as "unset".
*>
fn double js_render_scale_get(JsRuntime* self)
{
	float scale = self.renderer == null ? 0.0f : self.renderer.render_scale;
	return scale > 0.0f ? (double)scale : 1.0;
}

<*
 `renderScaleSet(scale)` — follow the window at a fraction of its pixels.

 The setting a game ships. `three.setRenderSize` pins a resolution, which a
 player's next window drag or fullscreen key makes wrong; this keeps the ratio
 across every one of them, because it is applied where the follow already is.

 So it unpins, and it drops a queued pin along with it, for
 `renderFollowWindow`'s reason: a size asked for from inside a frame and then
 replaced by a scale would land a frame later and pin what the scale just
 unpinned.

 Applied on the call when there is no frame on the stack, so a boot script or a
 tool call gets the size it asked for in the very next screenshot; inside a
 frame the per-frame reconcile at the top of `Renderer.frame` picks it up, which
 is between frames and therefore safe. Under `--headless` there is no window to
 take a share of, and it is remembered and does nothing.

 @return? js::THREW
*>
fn bool? js_render_scale_set(JsRuntime* self, double scale)
{
	if (scale < RENDER_SCALE_MIN || scale > RENDER_SCALE_MAX)
	{
		return self.js.fail("three.window.renderScale wants a fraction between %s and %s, or null for full resolution; got %s",
			RENDER_SCALE_MIN, RENDER_SCALE_MAX, scale)~;
	}

	if (self.renderer == null)
	{
		return self.js.fail("there is no render target without a GPU device, so there is nothing to scale")~;
	}

	self.renderer.render_scale = (float)scale;
	self.renderer.render_size_pinned = false;
	self.render_width_wanted = 0;
	self.render_height_wanted = 0;
	if (!self.in_frame) self.renderer.follow_window();
	return true;
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

 @return? js::THREW
*>
fn js::Value? js_background_get(JsRuntime* self, uint id)
{
	if (self.renderer == null)
	{
		return self.js.fail("there is nothing to clear without a GPU device, so there is no background colour")~;
	}
	Scene* scene = scene_named(self, id)!;
	return self.js.numbers({ scene.look.clear[0], scene.look.clear[1], scene.look.clear[2] });
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

 **These components are sRGB.** `gpu/color.c3` has the argument. What it means
 for this verb is the thing a caller wants to be true: `0x2060a0` clears to
 `0x2060a0`, and `backgroundGet` gives back what `backgroundSet` was handed,
 because the decode happens at the attachment and not to the stored value.

 @return? js::THREW
*>
fn void? js_background_set(JsRuntime* self, uint id, float r, float g, float b)
{
	if (self.renderer == null)
	{
		return self.js.fail("there is nothing to clear without a GPU device, so there is no background colour")~;
	}
	Scene* scene = scene_named(self, id)!;
	float[4] clear = {
		math::clamp(r, 0.0f, 1.0f),
		math::clamp(g, 0.0f, 1.0f),
		math::clamp(b, 0.0f, 1.0f),
		1.0f,
	};
	self.set_clear(scene, clear);
}

<*
 A scene's sky. The two textures are indices into `Assets.textures`, or -1 for
 none: the prelude keeps the `Texture` object a script assigned and hands that
 same object back, so what this is for is the numbers beside them.
*>
struct SkyState
{
	int background;
	int environment;
	float background_intensity;
	float environment_intensity;
	float rotation;
}

<*
 `skyGet(sceneId)` — the scene's sky, as a `SkyState`.

 @return? js::THREW
*>
fn SkyState? js_sky_get(JsRuntime* self, uint id)
{
	Scene* scene = scene_named(self, id)!;
	SkyLook sky = scene.look.sky;
	return {
		.background = sky.background,
		.environment = sky.environment,
		.background_intensity = sky.background_intensity,
		.environment_intensity = sky.environment_intensity,
		.rotation = sky.rotation,
	};
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

 @return? js::THREW
*>
fn void? js_sky_set(
	JsRuntime* self,
	uint id,
	int background,
	int environment,
	float background_intensity,
	float environment_intensity,
	float rotation
)
{
	if (self.renderer == null)
	{
		return self.js.fail("a sky needs a GPU device to sample its image, and this context has none")~;
	}
	Scene* scene = scene_named(self, id)!;

	if (background != NO_TEXTURE && !self.pass.assets.texture_alive(background))
	{
		return self.js.fail("scene.background was given a texture that has been disposed")~;
	}
	if (environment != NO_TEXTURE && !self.pass.assets.texture_alive(environment))
	{
		return self.js.fail("scene.environment was given a texture that has been disposed")~;
	}

	self.pass.set_scene_sky(scene, true, background);
	self.pass.set_scene_sky(scene, false, environment);
	scene.look.sky.background_intensity = math::max(background_intensity, 0.0f);
	scene.look.sky.environment_intensity = math::max(environment_intensity, 0.0f);
	scene.look.sky.rotation = rotation;
}

// `budgetGet()` — how long this script may run, in milliseconds.
fn double js_budget_get(JsRuntime* self) => (double)(self.script_budget_ns / 1_000_000);

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

 @return? js::THREW
*>
fn void? js_budget_set(JsRuntime* self, float asked)
{
	if (asked <= 0)
	{
		return self.js.fail(
			"three.budget wants a positive number of milliseconds — there is no way to turn the interrupt off"
		)~;
	}

	long ms = (long)asked;
	if (ms > JS_BUDGET_CEILING_MS) ms = JS_BUDGET_CEILING_MS;

	self.script_budget_ns = ms * 1_000_000;
	self.budget_ns = self.script_budget_ns;
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

 @return? js::THREW
*>
fn void? js_debug_overlay(JsRuntime* self, String line)
{
	if (self.renderer == null) return;
	if (catch self.renderer.ui.set_overlay(&self.renderer.gpu, &self.renderer.target, line))
	{
		return self.js.fail("the overlay could not be drawn — the interface layer failed to start")~;
	}
}

// ============================================================================
// The clock
// ============================================================================

<*
 The clock this runtime drives.

 `open(null)` is a context with no `MeshPass` — the module-loader checks, and
 nothing that boots. It has no scene, no camera and no frames, so it has no
 clock; saying so is better than the alternative both ways round, because a
 getter answering zero and a setter quietly dropping the write is the property
 `api.js` throws on assignment three separate times to avoid.

 @return? js::THREW
*>
fn GameClock*? JsRuntime.game_clock(&self)
{
	if (self.pass == null) return self.js.fail("there is no clock here — this runtime was opened with no scene")~;
	return &self.pass.clock;
}

<*
 `clockTime()` — the game clock, in seconds.

 The clock is several scalar verbs rather than one object, because these are read
 *per frame by gameplay* — `three.clock.dt` is the argument to every integration
 in a script — and a verb that allocates to answer would pay for an object on
 every one of those reads.

 @return? js::THREW
*>
fn double? js_clock_time(JsRuntime* self) => self.game_clock()!.time;

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
 `three.systems.report()` is built on.

 Milliseconds as a double rather than nanoseconds as an integer, because the
 consumer is JavaScript and every other duration this API hands out is
 milliseconds. A double holds microsecond resolution for about three hundred
 years of uptime, so the precision that matters here survives the units.

 **Not the same origin as `elapsed_ms`.** That one is the host's, from whenever
 the host started counting; this one starts at `JsRuntime.open`. Differences
 are what either is for, and mixing them is a difference of two origins.
*>
fn double js_clock_wall(JsRuntime* self) => (double)self.wall_clock.to_now() / 1_000_000.0;

<*
 `clockDelta()` — what the frame being drawn is worth, in game seconds.

 Zero before the first tick and zero while paused, which is the answer a script
 wants in both cases: an integration multiplied by it does nothing, with no flag
 to test and no branch to forget.

 @return? js::THREW
*>
fn double? js_clock_delta(JsRuntime* self) => self.game_clock()!.dt;

<*
 `clockScaleGet()` — the multiplier from wall time to game time.

 @return? js::THREW
*>
fn double? js_clock_scale_get(JsRuntime* self) => self.game_clock()!.scale;

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

 @return? js::THREW
*>
fn void? js_clock_scale_set(JsRuntime* self, double asked)
{
	GameClock* clock = self.game_clock()!;
	if (!math::is_finite(asked) || asked < 0)
	{
		return self.js.fail(
			"three.clock.timeScale wants zero or more — zero is paused, and there is no way to run time backwards"
		)~;
	}
	clock.scale = asked;
}

<*
 `clockRateGet()` — how many fixed steps a second of game time is worth.

 @return? js::THREW
*>
fn double? js_clock_rate_get(JsRuntime* self) => self.game_clock()!.fixed_hz;

<*
 `clockAlpha()` — how far the frame is between two fixed steps, 0 to 1.

 @return? js::THREW
*>
fn double? js_clock_alpha(JsRuntime* self) => self.game_clock()!.fixed_alpha();

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

 @return? js::THREW
*>
fn void? js_clock_rate_set(JsRuntime* self, double asked)
{
	GameClock* clock = self.game_clock()!;
	if (!math::is_finite(asked) || asked < CLOCK_FIXED_HZ_MIN || asked > CLOCK_FIXED_HZ_MAX)
	{
		return self.js.fail("three.clock.fixedRate wants %d to %d steps a second — %g is not a rate a fixed loop can run at",
			(int)CLOCK_FIXED_HZ_MIN, (int)CLOCK_FIXED_HZ_MAX, asked)~;
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

 @return? js::THREW
*>
fn void? js_clock_advance(JsRuntime* self, double asked)
{
	GameClock* clock = self.game_clock()!;
	if (!math::is_finite(asked) || asked < 0)
	{
		return self.js.fail("three.clock.advance(seconds) wants zero or more — a clock does not run backwards")~;
	}
	clock.advance(asked);
}

// ============================================================================
// Lights
// ============================================================================

// `lightCount()` — how many lights are lit, 1 to `MAX_LIGHTS`.
fn uint js_light_count(JsRuntime* self) => (uint)self.pass.lighting.count;

<*
 Which slot a light verb was handed.

 One function because several verbs take an index and the message has to be the
 same one every time: a script that indexed past the end has a bug, and telling it
 how many there are is the whole of the answer.

 @param first : `The lowest slot this caller accepts. One for lightRemove, which will not take the sun; zero for everything else.`
 @return? js::THREW
*>
fn uint? light_slot(JsRuntime* self, int asked, uint first) @local
{
	if (asked < (int)first || asked >= (int)self.pass.lighting.count)
	{
		return self.js.fail("there is no light %d — this scene has %d, numbered 0 to %d",
			asked, self.pass.lighting.count, self.pass.lighting.count - 1)~;
	}
	return (uint)asked;
}

<*
 `lightGet(index)` — one light, as `[x, y, z, r, g, b, intensity, range, id]`.

 The colour is linear rgb and the intensity multiplies it. `range` says what the
 first three are: 0 is a directional light and they are a surface-to-light
 direction in world space, unnormalized; above 0 it is a point light, they are a
 world position and the number is how far it reaches. See `Light`. `id` is the
 light's stable registry id, which `lightIndex` turns back into a slot.

 An array because it is the argument list `lightSet` takes back: `api.js` reads
 it, changes one field and writes the lot.

 @return? js::THREW
*>
fn js::Value? js_light_get(JsRuntime* self, int asked)
{
	uint index  = light_slot(self, asked, 0)!;
	Light light = self.pass.lighting.lights[index];
	return self.js.numbers({
		light.direction[0], light.direction[1], light.direction[2],
		light.color[0], light.color[1], light.color[2], light.color[3],
		light.direction[3], (double)light.meta[0],
	});
}

// `lightIndex(id)` — the slot a stable light id is in now, or -1.
fn int js_light_index(JsRuntime* self, int id)
{
	for (uint i = 0; i < self.pass.lighting.count; i++)
	{
		if (self.pass.lighting.lights[i].meta[0] == (uint)id) return (int)i;
	}
	return -1;
}

<*
 `lightSet(index, x, y, z, r, g, b, intensity, range, kind, …area)` — one light,
 whole.

 `range` is optional and 0 — a directional light — is what its absence means, so
 every caller written before point lights existed still sets the light it set.

 ## Why lights are not Object3Ds

 `render/pass.c3` uploads the registry and clustered shading reads its local
 subset. The registry stays separate from the scene graph.

 Three.js's answer is `scene.add(new THREE.DirectionalLight(...))`, and this is
 still deliberately not that. A light here is not in the graph: it has no
 position, nothing can be parented to it, and `scene.remove` does not reach it.
 Putting it in the graph would promise all three. `three.lights` is a packed
 registry and says so.

 **Only light zero casts a shadow**, because only light zero is what the shadow
 map was fitted around. `Light` has the price of the second one.

 ## The direction is not normalized here

 The shaders normalize on read, so length has never meant anything, and
 normalizing at the door would make `lightGet` answer with numbers the script
 did not write. What is refused is the one direction that cannot be normalized
 at all: a zero vector makes `normalize` a NaN, the lambert term a NaN, and the
 frame either black or undefined depending on the driver — a failure with
 nothing anywhere pointing at the light.

 @return? js::THREW
*>
fn void? js_light_set(JsRuntime* self, int asked, LightArgs numbers)
{
	uint index = light_slot(self, asked, 0)!;

	Light light = read_light(self, numbers)!;
	Light previous = self.pass.lighting.lights[index];
	light.meta = previous.meta;
	if (light.direction[3] == 0.0f) light.meta[2] = 0;
	if (light.meta[2] >= 2)
	{
		light.area_right = previous.area_right;
		light.area_up = previous.area_up;
	}

	// **Light zero is a direction and stays one.** It is the light the shadow map
	// is fitted around, and the fit takes a direction — `MeshPass.plan_shadow`
	// hands `lights[0].direction` to `ShadowMap.fit`, which builds an orthographic
	// box along it. A position there is three numbers the fit would read as a
	// heading, which is a shadow map aimed somewhere nobody asked for and nothing
	// anywhere saying so. Refused by name rather than by quietly turning the
	// shadow pass off.
	if (index == 0 && light.direction[3] > 0.0f)
	{
		return self.js.fail(
			"three.lights[0] is the sun and is a direction — a local light goes in another registry slot"
		)~;
	}

	Lighting lighting = self.pass.lighting;
	lighting.lights[index] = light;
	self.set_lighting(lighting);
}

<*
 `lightAdd(x, y, z, r, g, b, intensity, range, kind, …area)` — a light in the
 next free slot, whose index it answers with. `range` above 0 makes it a point
 light standing at `x, y, z`.

 Refused rather than silently dropped once the registry ceiling is reached. A light that did
 nothing would be a scene lit differently from the one the script describes, with
 nothing anywhere saying which light went missing.

 @return? js::THREW
*>
fn uint? js_light_add(JsRuntime* self, LightArgs numbers)
{
	if (self.pass.lighting.count >= MAX_LIGHTS)
	{
		return self.js.fail("three.lights holds %d lights and all of them are in use — set one you already have, or remove it first",
			MAX_LIGHTS)~;
	}

	Light light = read_light(self, numbers)!;

	Lighting lighting = self.pass.lighting;
	light.meta[0] = lighting.next_light_id++;
	light.meta[1] = 0xffffffff;
	if (light.meta[2] < 2) light.meta[2] = light.direction[3] > 0.0f ? 1 : 0;
	lighting.lights[lighting.count] = light;
	lighting.count++;
	self.set_lighting(lighting);
	return lighting.count - 1;
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

 @return? js::THREW
*>
fn void? js_light_remove(JsRuntime* self, int asked)
{
	if (asked == 0)
	{
		return self.js.fail(
			"three.lights[0] is the light the shadow map is fitted around and cannot be removed — set its intensity to 0 to turn it off"
		)~;
	}

	uint index = light_slot(self, asked, 1)!;

	Lighting lighting = self.pass.lighting;
	for (uint i = index; i + 1 < lighting.count; i++) lighting.lights[i] = lighting.lights[i + 1];
	lighting.count--;
	self.set_lighting(lighting);
}

<*
 One light's shadow. `mode` is 0 when the light takes `three.lights.shadow` and
 1 or 2 when it says for itself; `size` is its own tile size, 0 when it takes the
 registry's. The last three are what that comes out as this frame.
*>
struct LightShadowState
{
	uint mode;
	uint size;
	bool enabled;
	uint effective_size;
	bool resident;
}

<*
 `lightShadowGet(index)` — one light's shadow, as a `LightShadowState`.

 @return? js::THREW
*>
fn LightShadowState? js_light_shadow_get(JsRuntime* self, int asked)
{
	uint index = light_slot(self, asked, 0)!;
	Light light = self.pass.lighting.lights[index];
	uint mode = light_shadow_mode(light);
	uint size = light_shadow_size(light);
	uint effective = size > 0 ? size : self.pass.point_shadows.size;
	bool enabled = index > 0 && mode != LIGHT_SHADOW_OFF
		&& (mode == LIGHT_SHADOW_ON || self.pass.point_shadows.enabled) && effective > 0;
	return {
		.mode = mode,
		.size = size,
		.enabled = enabled,
		.effective_size = enabled ? effective : 0,
		.resident = light.meta[1] != SHADOW_VIEW_NONE,
	};
}

<*
 `lightShadowSet(index, mode, size)` — one light's own shadow settings.

 They live in the light's free `meta.w`, so they travel with the registry
 through a scene switch. Light zero is the sun and is refused: its map is fitted
 rather than tiled, and `three.light.shadow` is where it is set.

 @return? js::THREW
*>
fn void? js_light_shadow_set(JsRuntime* self, int asked, int mode_asked, float requested)
{
	uint index = light_slot(self, asked, 0)!;
	if (index == 0)
	{
		return self.js.fail(
			"three.lights[0] is the sun and its shadow is fitted rather than tiled — set three.light.shadow"
		)~;
	}
	uint mode = (uint)math::clamp(mode_asked, 0, 2);
	uint wanted = requested > 0.0f
		? (uint)math::clamp(requested, (float)SHADOW_MIN_SIZE, (float)POINT_SHADOW_MAX_SIZE) : 0;
	uint rounded = wanted > 0 ? SHADOW_MIN_SIZE : 0;
	while (rounded > 0 && rounded * 2 <= wanted) rounded *= 2;
	if (mode == LIGHT_SHADOW_ON && rounded == 0 && self.pass.point_shadows.size == 0)
	{
		return self.js.fail(
			"enabling a light's shadow needs a size — set light.shadow = { enabled: true, size } or three.lights.shadow.size first"
		)~;
	}
	Lighting lighting = self.pass.lighting;
	// `light.baked` lives in the same field and is preserved: the two settings are
	// unrelated and a script that touched one must not clear the other.
	uint baked = lighting.lights[index].meta[3] & LIGHT_BAKED;
	lighting.lights[index].meta[3] = light_shadow_pack(mode, rounded) | baked;
	self.set_lighting(lighting);
}

<*
 `lightBakedGet(index)` and `lightBakedSet(index, value)` — `light.baked`.

 A light nothing has baked yet behaves exactly as an unbaked one: the flag says
 the lightmap *may* carry this light, and a receiver with no tile shades it in
 real time regardless. So setting it before `three.lights.bake()` changes no
 pixel, and clearing it afterwards puts the light back in the loop everywhere.

 @return? js::THREW
*>
fn bool? js_light_baked_get(JsRuntime* self, int asked)
{
	uint index = light_slot(self, asked, 0)!;
	return light_is_baked(self.pass.lighting.lights[index]);
}

<*
 @return? js::THREW
*>
fn void? js_light_baked_set(JsRuntime* self, int asked, bool baked)
{
	uint index = light_slot(self, asked, 0)!;
	Lighting lighting = self.pass.lighting;
	uint field = lighting.lights[index].meta[3] & ~LIGHT_BAKED;
	if (baked) field |= LIGHT_BAKED;
	lighting.lights[index].meta[3] = field;
	self.set_lighting(lighting);
}

<*
 `lightsBake(texelsPerMetre, maxBytes, budgetMs, progressive)` — the bake itself,
 as `{ receivers, skipped, texels, bytes, ms, dirty }`.

 Synchronous unless `progressive`, which bakes one budget's worth and answers
 with the rest as `dirty` — `MeshPass.bake_lightmaps`. Either way it reads the
 shadow atlas as the last frame left it — a light whose shadow was not resident
 bakes without one. A scene with no eligible receiver answers with zeros rather
 than raising: nothing eligible is a property of the file's uvs, not a mistake in
 the call.
*>
fn LightmapResult js_lights_bake(JsRuntime* self, float density, double bytes, float budget, bool progressive)
{
	LightmapOptions options = DEFAULT_LIGHTMAP_OPTIONS;
	if (density > 0) options.texels_per_metre = math::clamp(density, 0.05f, 512.0f);
	if (bytes > 0) options.max_bytes = (usz)math::clamp(bytes, 65536.0, 2048.0 * 1024.0 * 1024.0);
	// Only when the call said so: `bake.budgetMs` is the standing setting and a
	// bake with no options must not put it back to the default.
	if (budget > 0)
	{
		options.budget_ms = math::clamp(budget, 0.1f, 1000.0f);
		self.pass.lightmap.budget_ms = options.budget_ms;
	}
	options.progressive = progressive;

	if (try baked = self.pass.bake_lightmaps(options)) return baked;
	return { };
}

<*
 `lightsBakeBudget(ms)` — how much re-bake work a frame may do, read and written.

 A number at or below zero reads the budget without changing it, which is what
 the getter passes.
*>
fn double js_lights_bake_budget(JsRuntime* self, float wanted)
{
	if (wanted > 0) self.pass.lightmap.budget_ms = math::clamp(wanted, 0.1f, 1000.0f);
	float budget = self.pass.lightmap.budget_ms;
	return (double)(budget > 0 ? budget : LIGHTMAP_BUDGET_MS);
}

// What `lightsSaveBake` wrote, and where.
struct SavedBake
{
	String path;
	uint tiles;
	uint dirty;
	double bytes;
	double ms;
}

<*
 `lightsSaveBake(path)` — the atlas and its tile table, into the assets directory,
 as `{ path, tiles, dirty, bytes, ms }`.

 `three.writeText`'s door, so a path that climbs out of the assets directory is
 refused with the sentence every other writing verb uses.

 @return? js::THREW
*>
fn SavedBake? js_lights_save_bake(JsRuntime* self, String asked)
{
	if (asked.len == 0) asked = LIGHTMAP_DEFAULT_PATH;
	String writing = self.writable_path(asked, "three.lights.saveBake", tmem)!;
	LightmapFileResult? saved = self.pass.save_lightmap(writing);
	if (catch err = saved)
	{
		return self.js.fail("three.lights.saveBake could not write %s: %s — call three.lights.bake() first",
			self.blame(asked, writing), err)~;
	}
	return { .path = writing, .tiles = saved.tiles, .dirty = saved.dirty, .bytes = (double)saved.bytes, .ms = saved.ms };
}

<*
 `lightsLoadBake(path)` — a saved atlas back onto the device, as
 `{ tiles, dirty, bytes, ms }`, or null.

 Null rather than a raise for every way it can decline: no file yet, a file of
 another scene's lights, a file of another set of receivers. All three are the
 ordinary first run of a game that saves its bake, and the caller's answer to all
 three is the same — bake it now.

 @return? js::THREW
*>
fn js::Value? js_lights_load_bake(JsRuntime* self, String asked)
{
	if (asked.len == 0) asked = LIGHTMAP_DEFAULT_PATH;
	String? opening = self.resolve_asset(asked, tmem);
	if (catch opening) return js::NULL;
	if (try loaded = self.pass.load_lightmap(opening)) return self.js.@object_of(loaded);
	return js::NULL;
}

<*
 The numbers `lightSet` and `lightAdd` take for one light: direction or
 position, colour, intensity, range, kind, and the two area axes with their
 half-lengths. Missing ones are zero.
*>
alias LightArgs = float[<17>];

<*
 One light out of `LightArgs`.

 Shared by `lightSet` and `lightAdd` because the only difference between them is
 where the light goes, and a second copy of the zero-direction check is a second
 place for it to be forgotten.

 @return? js::THREW
*>
fn Light? read_light(JsRuntime* self, LightArgs n) @local
{
	float x = n[0];
	float y = n[1];
	float z = n[2];
	// The range, and so which kind of light this is — 0 is directional, which is
	// what a caller that passes seven numbers means and what every caller written
	// before there was an eighth one meant.
	float range = math::max(n[7], 0.0f);

	// Only a *direction* cannot be zero. A point light at the origin is a light at
	// the origin, and the three numbers are a place rather than a heading.
	if (range == 0.0f && x * x + y * y + z * z <= 0.0f)
	{
		return self.js.fail(
			"a light's direction cannot be zero — it is a direction, and normalizing it would be a NaN in every shading term"
		)~;
	}

	Light light = {
		.direction = { x, y, z, range },
		.color = {
			math::clamp(n[3], 0.0f, 1.0f),
			math::clamp(n[4], 0.0f, 1.0f),
			math::clamp(n[5], 0.0f, 1.0f),
			math::max(n[6], 0.0f),
		},
	};
	uint kind = (uint)math::max((int)n[8], 0);
	if (kind >= 2)
	{
		light.meta[2] = kind;
		light.area_right = { n[9], n[10], n[11], math::max(n[12], 0.0f) };
		light.area_up = { n[13], n[14], n[15], math::max(n[16], 0.0f) };
	}
	return light;
}

<*
 `ambientGet()` — the floor a face gets when it is turned right away from every
 light.
*>
fn double js_ambient_get(JsRuntime* self) => self.pass.lighting.ambient;

<*
 `ambientSet(a)` — that floor, clamped to 0..1.

 Frame-wide rather than per light, and not itself a light: it is what stands in
 for every bounce this renderer does not simulate, so four lights do not mean four
 floors. `Lighting.ambient` has the rest of that argument.
*>
fn void js_ambient_set(JsRuntime* self, float ambient)
{
	Lighting lighting = self.pass.lighting;
	lighting.ambient = math::clamp(ambient, 0.0f, 1.0f);
	self.set_lighting(lighting);
}

<*
 `worldGet()` — the world light, as `[r, g, b]` linear.

 @return? js::THREW
*>
fn js::Value? js_world_get(JsRuntime* self)
{
	return self.js.numbers({ self.pass.lighting.world[0], self.pass.lighting.world[1], self.pass.lighting.world[2] });
}

<*
 `worldSet(r, g, b)` — the world light, floored at zero and not ceilinged.

 Not clamped to 1, unlike a light's colour: this is Blender's world colour times
 its strength, which is a brightness rather than a swatch, and a bright sky over a
 dark scene is exactly the case it exists for. `Lighting.world` has why it is
 added rather than lerped.
*>
fn void js_world_set(JsRuntime* self, float r, float g, float b)
{
	Lighting lighting = self.pass.lighting;
	lighting.world[0] = math::max(r, 0.0f);
	lighting.world[1] = math::max(g, 0.0f);
	lighting.world[2] = math::max(b, 0.0f);
	self.set_lighting(lighting);
}

// ============================================================================
// Shadows and the renderer's switches
// ============================================================================

<*
 `shadowGet()` — the shadow settings, as
 `[enabled, size, bias, intensity, distance, follow]`.

 An array because it is the argument list `shadowSet` takes: `api.js` reads it,
 changes one field and writes the lot back, so `enabled` and `follow` are 1 or 0.

 **`size` is what a script asked for, already clamped**, and is not necessarily
 the size of the image on the device: an image is only created or recreated at
 the top of a frame, so reading this back immediately after setting it answers
 with the request. That is the right answer — the request is the setting, and the
 image is how it is honoured.

 @return? js::THREW
*>
fn js::Value? js_shadow_get(JsRuntime* self)
{
	ShadowMap* shadows = &self.pass.shadows;
	return self.js.numbers({
		shadows.enabled ? 1.0 : 0.0, (double)shadows.size, (double)shadows.bias, (double)shadows.intensity,
		(double)shadows.distance, shadows.follow ? 1.0 : 0.0,
	});
}

<*
 `pointShadowGet()` — the local lights' shadow settings, as
 `[enabled, size, bias, intensity, maxLocal]`, the argument list of
 `pointShadowSet`.

 @return? js::THREW
*>
fn js::Value? js_point_shadow_get(JsRuntime* self)
{
	PointShadowSettings settings = self.pass.point_shadows.settings;
	return self.js.numbers({
		settings.enabled ? 1.0 : 0.0, (double)settings.size, (double)settings.bias, (double)settings.intensity,
		(double)(settings.max_local > 0 ? settings.max_local : DEFAULT_LOCAL_SHADOWS),
	});
}

<*
 `pointShadowSet(enabled, size, bias, intensity, maxLocal)`. `maxLocal` is how
 many local lights may hold shadows at once; absent leaves the scene's.
*>
fn void js_point_shadow_set(JsRuntime* self, float enabled, float requested, float bias, float intensity, Opt {int} max_local)
{
	PointShadowSettings settings;
	settings.enabled = enabled != 0.0f;
	uint wanted = requested > 0.0f
		? (uint)math::clamp(requested, (float)SHADOW_MIN_SIZE, (float)POINT_SHADOW_MAX_SIZE) : 0;
	uint rounded = wanted > 0 ? SHADOW_MIN_SIZE : 0;
	while (rounded > 0 && rounded * 2 <= wanted) rounded *= 2;
	settings.size = rounded;
	if (rounded > 512)
	{
		@advise("three: lights.shadow.size = %d requests shared atlas tiles (six per point light); three.shadows.budget limits residency and stats().shadowBytes reports allocation", rounded);
	}
	settings.bias = bias > 0.0f ? bias : 0.0f;
	settings.intensity = math::clamp(intensity, 0.0f, 1.0f);
	settings.max_local = max_local.given
		? (uint)math::clamp(max_local.value, 1, (int)MAX_LIGHTS)
		: self.pass.point_shadows.max_local;
	if (settings.max_local == 0) settings.max_local = DEFAULT_LOCAL_SHADOWS;
	self.set_point_shadow(settings);
}

// `shadowBudgetGet()` — the shadow atlas's limits, as
// `{ maxViews, maxTexels, maxBytes, maxUpdates, maxUpdateTexels }`.
fn ShadowBudget js_shadow_budget_get(JsRuntime* self)
{
	ShadowBudget budget = self.pass.shadow_view_set.budget;
	return budget.max_views == 0 ? DEFAULT_SHADOW_BUDGET : budget;
}

<*
 `shadowBudgetSet(maxViews, maxTexels, maxBytes, maxUpdates, maxUpdateTexels)`.

 @return? js::THREW
*>
fn void? js_shadow_budget_set(JsRuntime* self, int views, int texels, int bytes, int updates, int update_texels)
{
	if (views < 1 || views > 64 || texels < 65536 || texels > 67108864
		|| bytes < 1048576 || bytes > 1073741824 || updates < 0 || updates > 64
		|| update_texels < 0 || update_texels > 67108864)
	{
		return self.js.fail("three.shadows.budget is outside its documented resource limits")~;
	}
	self.set_shadow_budget({ .max_views = (uint)views, .max_texels = (usz)texels,
		.max_bytes = (usz)bytes, .max_updates = (uint)updates,
		.max_update_texels = (usz)update_texels });
}

<*
 `shadowFit()` — what the last fit came out as: `{ live, centre, extent, near,
 far, texel }`.

 Read-only, and derived rather than stored: this is `ShadowMap.report`, which
 reads back the same numbers `fit` wrote. There is nothing to set here — the fit
 is a consequence of the light, the scene's bounds and `distance`, and a script
 that wants it somewhere else moves one of those.
*>
fn ShadowFit js_shadow_fit(JsRuntime* self) => self.pass.shadows.report();

<*
 `occlusionGet()` — ambient occlusion, as `[enabled, radius, intensity, bias]`,
 the argument list of `occlusionSet`.

 @return? js::THREW
*>
fn js::Value? js_occlusion_get(JsRuntime* self)
{
	AmbientOcclusionSettings s = self.pass.ambient_occlusion.settings;
	return self.js.numbers({ s.enabled ? 1 : 0, s.radius, s.intensity, s.bias });
}

fn void js_occlusion_set(JsRuntime* self, float enabled, float radius, float intensity, float bias)
{
	self.set_ambient_occlusion({ .enabled = enabled != 0, .radius = radius, .intensity = intensity, .bias = bias });
}

// `alwaysRenderGet()` — whether every frame is drawn regardless.
fn bool js_always_render_get(JsRuntime* self) => self.renderer != null && self.renderer.always_render;

<*
 `alwaysRenderSet(on)` — draw every frame even when nothing about the picture
 changed.

 A property of the renderer rather than of the scene, like the post chain and the
 depth prepass: a new `three.Scene()` does not put it back.
*>
fn void js_always_render_set(JsRuntime* self, bool on)
{
	if (self.renderer != null) self.renderer.always_render = on;
}

// `sceneCacheGet()` — whether submitted frames may preserve unchanged scene pixels.
fn bool js_scene_cache_get(JsRuntime* self) => self.renderer == null || !self.renderer.scene_cache_disabled;

// `sceneCacheSet(on)` — preserve unchanged scene pixels inside a submitted frame.
fn void js_scene_cache_set(JsRuntime* self, bool on)
{
	if (self.renderer == null) return;
	self.renderer.scene_cache_disabled = !on;
	if (!on) self.renderer.scene_cache.invalidate();
}

// `depthPrepassGet()` — whether the depth prepass is on.
fn bool js_depth_prepass_get(JsRuntime* self) => self.pass.prepass.enabled;

<*
 `depthPrepassSet(on)` — draw the opaque and cut-out buckets depth-only before
 the scene pass, or do not.

 A property of the renderer rather than of the scene, like the post chain: a new
 `three.Scene()` does not put it back.
*>
fn void js_depth_prepass_set(JsRuntime* self, bool on)
{
	self.pass.prepass.enabled = on;
	if (!on) self.pass.prepass.live = false;
}

<*
 `debugViewGet()` — which debug view the shading pass is drawing, as a number.

 The names live in `api.js` and the number lives here: the one place that has to
 know `'shadow'` is 1 is the one place a typo can be caught.
*>
fn uint js_debug_view_get(JsRuntime* self) => self.pass.debug_view;

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
fn void js_debug_view_set(JsRuntime* self, float mode)
{
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

	// D32, one texel per texel. The shared atlas reports the allocation once
	// they exist; this has to answer before there are any.
	usz each = (usz)now * now * 4;
	@advise(
		"three: shadow.size = %d requests a %d MiB depth tile (%d MiB with static cache), "
			"before atlas packing and alignment; three.shadows.budget may reduce resolution. "
			"stats().shadowBytes reports actual shared allocation.",
		now,
		each / (1024 * 1024),
		(each * 2) / (1024 * 1024)
	);
}

<*
 `shadowSet(enabled, size, bias, intensity, distance, follow)` — all six at once.

 ## Why all six rather than six setters

 The same shape `lightSet` has, for the same reason: `api.js` presents six
 independent properties and each one reads the other five back and writes the
 lot. It also makes the clamping happen in one place.

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
fn void js_shadow_set(JsRuntime* self, float enabled, float size, float bias, float intensity, float reach, float follow)
{
	ShadowSettings settings;
	settings.enabled = enabled != 0.0f;

	uint wanted  = (uint)math::clamp(size, (float)SHADOW_MIN_SIZE, (float)SHADOW_MAX_SIZE);
	uint rounded = SHADOW_MIN_SIZE;
	while (rounded * 2 <= wanted) rounded *= 2;
	settings.size = rounded;
	say_shadow_size(self.pass.shadows.settings.size, rounded);

	// The bias has no upper bound worth inventing — past a certain size every
	// shadow simply disappears, which is a visible answer to a value somebody
	// typed. It is floored at zero because a negative one is acne on purpose.
	settings.bias = bias > 0.0f ? bias : 0.0f;
	settings.intensity = math::clamp(intensity, 0.0f, 1.0f);
	// Floored at zero, where zero means "derive one from the orbit distance" —
	// see `ShadowMap.reach`. There is no ceiling: a distance past the far plane
	// is silently the far plane, because the fit takes the smaller of the two,
	// and refusing a number that already behaves sensibly would be noise.
	settings.distance = reach > 0.0f ? reach : 0.0f;
	// Stated rather than left to the zero fill, which is the one field here where
	// those differ — see `ShadowSettings.follow` and `DEFAULT_SHADOW`.
	settings.follow = follow != 0.0f;

	self.set_shadow(settings);
}

// ============================================================================
// The camera
// ============================================================================

<*
 The camera as `cameraGet` answers it. `near` and `far` are reported and
 read-only: they are derived rather than set — `Camera.derive_planes` argues that
 at length — but derived is not the same as secret, and while they were neither
 reported nor settable there was no way at all to find out that the sky had
 fallen outside the far plane except by rendering and guessing.
*>
struct CameraState
{
	Vec3 target;
	float yaw;
	float pitch;
	float distance;
	float fov;
	float near;
	float far;
	float roll;
}

fn CameraState js_camera_get(JsRuntime* self)
{
	Camera* camera = &self.pass.camera;
	return {
		.target = camera.target,
		.yaw = camera.yaw,
		.pitch = camera.pitch,
		.distance = camera.distance,
		.fov = camera.fov,
		.near = camera.near_plane,
		.far = camera.far_plane,
		.roll = camera.roll,
	};
}

<*
 `cameraSet(tx, ty, tz, yaw, pitch, distance, fov, roll)`.

 The near and far planes are re-derived from the distance and the scene's own
 bounds rather than taken from the caller — see `Camera.derive_planes` for why —
 and the angles are clamped the same way a mouse drag clamps them, so a script
 and a hand on the window cannot put the camera in two different sets of states.
*>
fn void js_camera_set(JsRuntime* self, Vec3 target, float yaw, float pitch, float distance, float fov, float roll)
{
	Camera* camera = &self.pass.camera;
	camera.target = target;
	camera.yaw = yaw;
	camera.pitch = pitch;
	// **Zero is allowed and is what first person is** — the eye sits on the point
	// it orbits, which is a character's head once `three.camera.attach` is
	// writing that point. `Camera.view` handles the degenerate boom directly, and
	// a floor would make `orbit(yaw, pitch)` — which passes the current distance
	// straight back — quietly leave first person for a value no script asked for.
	camera.distance = math::max(distance, 0.0f);
	camera.fov = math::clamp(fov, 1.0f, 179.0f);
	// Unclamped and unwrapped, unlike the other two angles. `clamp_angles` holds
	// pitch off the pole and wraps yaw because both protect `look_at` from a
	// degenerate basis; roll cannot make one — see `Camera.roll`. Wrapping it
	// anyway would make `camera.roll += 1` in a loop read back as a sawtooth,
	// which is worse than a large number for a value a script is integrating.
	camera.roll = roll;

	camera.clamp_angles();
	// Through the pass rather than `camera.derive_planes()` directly, so the far
	// plane is fitted to the scene the script has built instead of to a multiple
	// of the distance it just asked for. `MeshPass.derive_camera_planes` has the
	// argument; the short version is that a script that dollies in used to lose
	// its sky.
	self.pass.derive_camera_planes();
}

// `frameAll()` — aim at everything in the scene and back off far enough to see it.
fn void js_frame_all(JsRuntime* self) => self.pass.frame_camera();

<*
 `cameraAttach(node, ox, oy, oz, distance, lag, local)` — follow a node.

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

 `local` is `CameraFollow.local_offset` — whether the offset is read in the
 node's own frame. It is a flag rather than a second verb because everything
 else about the attachment is the same; see there for what the two frames mean
 and why a cockpit needs the second one.

 @return? js::THREW
*>
fn void? js_camera_attach(JsRuntime* self, NodeRef ref, Vec3 offset, float distance, float lag, bool local)
{
	// The rendered scene's, and refused otherwise: the follow is read once per
	// frame against one graph, and a handle from a scene that is not being drawn
	// would resolve to nothing every frame — a camera that silently stopped
	// following rather than one that said so.
	if (ref.scene != self.pass.scene)
	{
		return self.js.fail("%s needs an object in the scene being rendered — call scene.activate() on the one it is in first",
			"three.camera.attach(object)")~;
	}

	if (lag < 0.0f)
	{
		return self.js.fail("three.camera.attach(object, { lag }) wants seconds — 0 for rigid, and never a negative")~;
	}

	self.pass.follow = {
		.active = true,
		.node = ref.id,
		.offset = offset,
		.lag_ms = lag,
		.local_offset = local,
	};

	self.pass.camera.distance = math::max(distance, 0.0f);

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
fn bool js_camera_detach(JsRuntime* self)
{
	bool was = self.pass.follow.active;
	self.pass.follow = { };
	return was;
}

<*
 `cameraAttached()` — the followed node as a handle, or null.

 Null is also how a script learns that what it was following has been destroyed:
 `follow_camera` drops the attachment silently when the node goes, because the
 alternative is raising from inside a tick nobody called.
*>
fn NodeId js_camera_attached(JsRuntime* self)
{
	if (!self.pass.follow.active || self.pass.scene.node(self.pass.follow.node) == null) return NO_NODE;
	return self.pass.follow.node;
}
