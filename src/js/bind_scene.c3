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

import std::io;
import std::math;
import std::math::vector;
import qjs;

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
	self.bind(host, "assetPath", &js_asset_path, 1);
	self.bind(host, "meshNames", &js_mesh_names, 1);

	// The graph
	self.bind(host, "root", &js_root, 0);
	self.bind(host, "reset", &js_reset, 0);
	self.bind(host, "epoch", &js_epoch, 0);
	self.bind(host, "add", &js_add, 5);
	self.bind(host, "remove", &js_remove, 2);
	self.bind(host, "setParent", &js_set_parent, 4);
	self.bind(host, "setTransform", &js_set_transform, 11);
	self.bind(host, "setVisible", &js_set_visible, 3);
	self.bind(host, "setName", &js_set_name, 3);
	self.bind(host, "worldPosition", &js_world_position, 2);

	// The frame
	self.bind(host, "stats", &js_stats, 0);
	self.bind(host, "render", &js_render, 0);
	self.bind(host, "cameraGet", &js_camera_get, 0);
	self.bind(host, "cameraSet", &js_camera_set, 7);
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
 A node handle as JavaScript sees it: `[index, generation]`.
*>
fn qjs::Value handle_value(qjs::Context* js, NodeId id)
{
	qjs::Value pair = js.array();
	js.set_index(pair, 0, qjs::int_value((int)id.index));
	js.set_index(pair, 1, qjs::int_value((int)id.generation));
	return pair;
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
 Read `(index, generation)` from `args[at]` and `args[at + 1]` and resolve it.

 @return `The id, or NO_NODE with a JS exception left pending, in which case the caller must write out and return immediately.`
*>
fn NodeId arg_handle(JsRuntime* self, qjs::Context* js, int argc, qjs::Value* args, int at, qjs::Value* out)
{
	NodeId id = {
		.index = (uint)arg_int(js, argc, args, at),
		.generation = (uint)arg_int(js, argc, args, at + 1),
	};
	if (self.pass == null || self.pass.scene.node(id) == null)
	{
		*out = js.raise(
			"that object is no longer in the scene — it was removed, or a later new three.Scene() replaced it"
		);
		return NO_NODE;
	}
	return id;
}

// ============================================================================
// The graph
// ============================================================================

fn void js_root(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);
	if (!self.pass.scene.started) self.pass.scene.init();
	*out = handle_value(&js, self.pass.scene.root);
}

<*
 Empty the scene and answer with the new epoch — `new three.Scene()`.

 The root survives, so a `Scene` is never left without somewhere to add to, and
 the epoch is what makes the previous `Scene` object throw rather than quietly
 operate on this one's nodes.
*>
fn void js_reset(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	if (!self.pass.scene.started) self.pass.scene.init();
	self.release_subtree(self.pass.scene.root);
	self.pass.scene.remove(self.pass.scene.root);

	self.epoch += 1;
	*out = qjs::number_value(self.epoch);
}

fn void js_epoch(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	*out = qjs::number_value(self.epoch);
}

<*
 Give back one asset reference per drawable node in a subtree.

 `Assets.refs` is bookkeeping — dropping to zero does not unload anything before
 M6 — but it is bookkeeping that is either right or worthless, and a `remove`
 that skipped it would make an unused asset permanently look used.
*>
fn void JsRuntime.release_subtree(&self, NodeId id)
{
	@pool()
	{
		self.pass.scene.@traverse(id; NodeId child, Node* node)
		{
			if (node.asset != NO_ASSET) self.pass.assets.release(node.asset);
		};
	};
}

<*
 `add(asset, mesh, parentIndex, parentGeneration, name)`.

 A negative `asset` is a group: traversed and transformed, never drawn.
*>
fn void js_add(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	int asset = arg_int(&js, argc, args, 0);
	int mesh = arg_int(&js, argc, args, 1);

	NodeId parent = arg_handle(self, &js, argc, args, 2, out);
	if (!parent.is_set()) return;

	@pool()
	{
		String name = arg_text(&js, argc, args, 4, tmem);

		if (asset < 0)
		{
			*out = handle_value(&js, self.pass.scene.add_group(parent, name));
			return;
		}

		if (self.pass.assets.mesh((uint)asset, (uint)mesh) == null)
		{
			*out = js.raise(string::tformat("there is no mesh %d in asset %d", mesh, asset));
			return;
		}

		NodeId id = self.pass.scene.add_mesh((uint)asset, (uint)mesh, parent, name);
		self.pass.assets.retain((uint)asset);
		*out = handle_value(&js, id);
	};
}

fn void js_remove(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	NodeId id = arg_handle(self, &js, argc, args, 0, out);
	if (!id.is_set()) return;

	// The root is the scene itself; emptying it is `new three.Scene()`.
	if (id == self.pass.scene.root)
	{
		*out = js.raise("the Scene cannot be removed — make a new three.Scene() to empty it");
		return;
	}

	self.release_subtree(id);
	self.pass.scene.remove(id);
}

fn void js_set_parent(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	NodeId id = arg_handle(self, &js, argc, args, 0, out);
	if (!id.is_set()) return;
	NodeId parent = arg_handle(self, &js, argc, args, 2, out);
	if (!parent.is_set()) return;

	self.pass.scene.set_parent(id, parent);
}

<*
 `setTransform(index, generation, px, py, pz, rx, ry, rz, sx, sy, sz)`.

 All nine at once rather than one verb per channel: `prelude.js` holds the local
 transform as JavaScript numbers and pushes the whole thing on any write, so
 there is never a partial state to reason about and `m.position.set(...)` is one
 crossing instead of three.
*>
fn void js_set_transform(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	NodeId id = arg_handle(self, &js, argc, args, 0, out);
	if (!id.is_set()) return;

	Node* node = self.pass.scene.node(id);
	node.position = { arg_float(&js, argc, args, 2), arg_float(&js, argc, args, 3), arg_float(&js, argc, args, 4) };
	node.rotation = { arg_float(&js, argc, args, 5), arg_float(&js, argc, args, 6), arg_float(&js, argc, args, 7) };
	node.scale    = { arg_float(&js, argc, args, 8), arg_float(&js, argc, args, 9), arg_float(&js, argc, args, 10) };
	node.dirty = true;
}

fn void js_set_visible(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	NodeId id = arg_handle(self, &js, argc, args, 0, out);
	if (!id.is_set()) return;

	self.pass.scene.set_visible(id, arg_truth(&js, argc, args, 2));
}

fn void js_set_name(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	NodeId id = arg_handle(self, &js, argc, args, 0, out);
	if (!id.is_set()) return;

	@pool()
	{
		self.pass.scene.set_name(id, arg_text(&js, argc, args, 2, tmem));
	};
}

<*
 Where a node ended up in world space.

 The world matrices are brought up to date first: a script that sets a position
 and immediately asks where something is would otherwise read the transform from
 before its own write, which is the shape of bug that renders fine and reports
 the wrong number.
*>
fn void js_world_position(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	NodeId id = arg_handle(self, &js, argc, args, 0, out);
	if (!id.is_set()) return;

	self.pass.scene.update_world_matrices();
	*out = vec3_value(&js, self.pass.scene.node(id).world_position());
}

// ============================================================================
// The frame
// ============================================================================

<*
 The numbers an agent reads its own cost off (`plan.md`'s second thesis).

 camelCase, because everything a script touches is JavaScript and `draw_calls`
 beside `drawCalls` in the same object graph is a seam an agent has to remember.
*>
fn void js_stats(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	SceneStats stats = self.pass.stats();

	qjs::Value object = js.object();
	js.set_property(object, "drawCalls", qjs::int_value((int)stats.draw_calls));
	js.set_property(object, "uniqueMeshes", qjs::int_value((int)stats.unique_meshes));
	js.set_property(object, "instances", qjs::int_value((int)stats.instances));
	js.set_property(object, "nodes", qjs::int_value((int)stats.nodes));
	js.set_property(object, "triangles", qjs::int_value((int)stats.triangles));
	js.set_property(object, "vertices", qjs::int_value((int)stats.vertices));
	js.set_property(object, "textures", qjs::int_value((int)stats.textures));
	js.set_property(object, "textureBytes", qjs::number_value((double)stats.texture_bytes));
	js.set_property(object, "culledLastFrame", qjs::int_value((int)stats.culled_last_frame));
	*out = object;
}

fn void js_render(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
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

fn void js_camera_get(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	Camera* camera = &self.pass.camera;
	qjs::Value list = js.array();
	js.set_index(list, 0, qjs::number_value(camera.target.x));
	js.set_index(list, 1, qjs::number_value(camera.target.y));
	js.set_index(list, 2, qjs::number_value(camera.target.z));
	js.set_index(list, 3, qjs::number_value(camera.yaw));
	js.set_index(list, 4, qjs::number_value(camera.pitch));
	js.set_index(list, 5, qjs::number_value(camera.distance));
	js.set_index(list, 6, qjs::number_value(camera.fov));
	*out = list;
}

<*
 `cameraSet(tx, ty, tz, yaw, pitch, distance, fov)`.

 The near and far planes are re-derived from the distance rather than taken from
 the caller: a fixed near plane against a model a kilometre wide spends the whole
 depth buffer on the first few metres, which is z-fighting across the entire
 scene and reads as a rendering bug rather than as a camera setting. This is the
 same rule `Camera.frame_bounds` follows.
*>
fn void js_camera_set(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	Camera* camera = &self.pass.camera;
	camera.target = { arg_float(&js, argc, args, 0), arg_float(&js, argc, args, 1), arg_float(&js, argc, args, 2) };
	camera.yaw = arg_float(&js, argc, args, 3);
	camera.pitch = arg_float(&js, argc, args, 4);
	camera.distance = math::max(arg_float(&js, argc, args, 5), 0.0001f);
	camera.fov = math::clamp(arg_float(&js, argc, args, 6), 1.0f, 179.0f);

	camera.near_plane = math::max(camera.distance * 0.001f, 0.0001f);
	camera.far_plane = camera.distance * 8.0f;
}

fn void js_frame_all(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	self.pass.frame_camera();
}
