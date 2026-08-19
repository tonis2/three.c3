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
	self.bind(host, "primitive", &js_primitive, 8);
	self.bind(host, "convex", &js_convex, 1);
	self.bind(host, "lines", &js_lines, 2);
	self.bind(host, "wireframe", &js_wireframe, 3);
	self.bind(host, "assetPath", &js_asset_path, 2);
	self.bind(host, "meshNames", &js_mesh_names, 2);
	self.bind(host, "meshBounds", &js_mesh_bounds, 3);
	self.bind(host, "assetNodes", &js_asset_nodes, 2);
	self.bind(host, "assetClips", &js_asset_clips, 2);
	self.bind(host, "bindAnimation", &js_bind_animation, 5);
	self.bind(host, "playAnimation", &js_play_animation, 5);
	self.bind(host, "stopAnimation", &js_stop_animation, 2);
	self.bind(host, "inventory", &js_inventory, 0);
	self.bind(host, "exportScene", &js_export, 1);

	// The graph
	self.bind(host, "root", &js_root, 0);
	self.bind(host, "reset", &js_reset, 0);
	self.bind(host, "epoch", &js_epoch, 0);
	self.bind(host, "add", &js_add, 6);
	self.bind(host, "remove", &js_remove, 2);
	self.bind(host, "setParent", &js_set_parent, 4);
	self.bind(host, "setTransform", &js_set_transform, 11);
	self.bind(host, "setQuaternion", &js_set_quaternion, 6);
	self.bind(host, "setVisible", &js_set_visible, 3);
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

	// The animation loop (js/frame_loop.c3)
	self.bind_frame_verbs(host);

	// The keyboard (js/bind_input.c3)
	self.bind_input_verbs(host);

	// Physics (js/bind_physics.c3)
	self.bind_physics_verbs(host);

	// The frame
	self.bind(host, "stats", &js_stats, 0);
	self.bind(host, "unloadUnused", &js_unload_unused, 0);
	self.bind(host, "render", &js_render, 0);
	self.bind(host, "renderSize", &js_render_size, 0);
	self.bind(host, "backgroundGet", &js_background_get, 0);
	self.bind(host, "backgroundSet", &js_background_set, 3);
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
	// `Scene.remove` releases every asset reference under the root on its own
	// since G2 — see `Scene.attach_assets`. This used to walk the subtree here
	// as well, which was a second implementation of the count and is exactly
	// what stopped being safe once the count decides what gets freed.
	self.pass.scene.remove(self.pass.scene.root);
	// The bodies named nodes that have just gone. Emptied rather than left to
	// throw one frame later, which is the same rule handles into the previous
	// scene follow.
	self.physics.close();
	// The background goes back to the default, unlike materials and assets, which
	// survive a reset on purpose. It is a property of the Scene in Three.js and
	// this keeps that true: `new three.Scene()` starts on the default sky rather
	// than on whatever the last scene painted, so a script that sets a background
	// and a script that does not render the same first frame.
	if (self.renderer != null) self.renderer.clear = DEFAULT_CLEAR;

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
 `add(asset, assetGeneration, mesh, parentIndex, parentGeneration, name)`.

 A negative `asset` is a group: traversed and transformed, never drawn — and it
 is read before the handle is resolved, so a group never has to carry a
 generation for an asset it does not name.
*>
fn void js_add(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	int index = arg_int(&js, argc, args, 0);
	int mesh = arg_int(&js, argc, args, 2);

	NodeId parent = arg_handle(self, &js, argc, args, 3, out);
	if (!parent.is_set()) return;

	@pool()
	{
		String name = arg_text(&js, argc, args, 5, tmem);

		if (index < 0)
		{
			*out = handle_value(&js, self.pass.scene.add_group(parent, name));
			return;
		}

		AssetId asset = arg_asset(self, &js, argc, args, 0, out);
		if (!asset.is_set()) return;

		if (self.pass.assets.mesh(asset, (uint)mesh) == null)
		{
			*out = js.raise(string::tformat("there is no mesh %d in asset %d", mesh, index));
			return;
		}

		// No retain here since G2: `Scene.create_slot` takes the reference, so
		// the count has one implementation rather than one per caller.
		*out = handle_value(&js, self.pass.scene.add_mesh(asset, (uint)mesh, parent, name));
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

	// `game.md` G5/S6. The camera resolves a script and a drag by
	// last-writer-wins because both describe the same intent; a solver and a
	// script writing the same transform every frame describe two, and the
	// result is jitter rather than a compromise. So this is a refusal and not
	// a merge.
	if (self.physics.owns_transform(id))
	{
		*out = js.raise(PHYSICS_OWNS_TRANSFORM);
		return;
	}

	Node* node = self.pass.scene.node(id);
	node.position = { arg_float(&js, argc, args, 2), arg_float(&js, argc, args, 3), arg_float(&js, argc, args, 4) };
	// Euler in, quaternion stored — the one-way conversion `node.c3`'s header
	// describes. JavaScript keeps the triple it sent, so nothing converts back.
	node.rotation = quat_from_euler({ arg_float(&js, argc, args, 5), arg_float(&js, argc, args, 6), arg_float(&js, argc, args, 7) });
	node.scale    = { arg_float(&js, argc, args, 8), arg_float(&js, argc, args, 9), arg_float(&js, argc, args, 10) };
	node.dirty = true;
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
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	NodeId id = arg_handle(self, &js, argc, args, 0, out);
	if (!id.is_set()) return;

	// The same refusal `js_set_transform` makes, and it has to be here too: a
	// script that only ever wrote `.quaternion` would otherwise fight the
	// solver through the one door that was left open.
	if (self.physics.owns_transform(id))
	{
		*out = js.raise(PHYSICS_OWNS_TRANSFORM);
		return;
	}

	self.pass.scene.set_quaternion(id, {
		arg_float(&js, argc, args, 2),
		arg_float(&js, argc, args, 3),
		arg_float(&js, argc, args, 4),
		arg_float(&js, argc, args, 5),
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
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	NodeId root = arg_handle(self, &js, argc, args, 0, out);
	if (!root.is_set()) return;

	AssetId asset = arg_asset(self, &js, argc, args, 2, out);
	if (!asset.is_set()) return;

	if (argc < 5) return;
	qjs::Value pairs = args[4];
	uint length = (uint)js.length(pairs);

	List{uint} sources;
	List{NodeId} nodes;
	sources.init(mem, (sz)(length / 3) + 1);
	nodes.init(mem, (sz)(length / 3) + 1);
	defer sources.free();
	defer nodes.free();

	for (uint i = 0; i + 2 < length; i += 3)
	{
		sources.push((uint)js.number(js.index(pairs, i)));
		nodes.push({
			.index = (uint)js.number(js.index(pairs, i + 1)),
			.generation = (uint)js.number(js.index(pairs, i + 2)),
		});
	}

	self.pass.scene.bind_player(asset, root, sources.array_view(), nodes.array_view());
}

<*
 `playAnimation(index, generation, name, loop, speed)` — start a clip on an
 instantiated subtree.

 Answers with a boolean rather than throwing on an unknown clip: `mesh.animations`
 is the list, so naming something that is not on it is a mistake a script can see
 and correct, and an exception raised inside an animation callback is a stopped
 game rather than a wrong pose.
*>
fn void js_play_animation(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	NodeId root = arg_handle(self, &js, argc, args, 0, out);
	if (!root.is_set()) return;

	@pool()
	{
		String name = arg_text(&js, argc, args, 2, tmem);
		bool loop = argc > 3 ? arg_truth(&js, argc, args, 3) : true;
		float speed = argc > 4 ? arg_float(&js, argc, args, 4) : 1.0f;
		*out = qjs::bool_value(self.pass.scene.play(root, name, loop, speed));
	};
}

<*
 `stopAnimation(index, generation)` — hold the pose. See `Scene.stop`.
*>
fn void js_stop_animation(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	NodeId root = arg_handle(self, &js, argc, args, 0, out);
	if (!root.is_set()) return;

	*out = qjs::bool_value(self.pass.scene.stop(root));
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
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	NodeId id = arg_handle(self, &js, argc, args, 0, out);
	if (!id.is_set()) return;

	self.pass.scene.set_color(id, {
		arg_float(&js, argc, args, 2),
		arg_float(&js, argc, args, 3),
		arg_float(&js, argc, args, 4),
		arg_float(&js, argc, args, 5),
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
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	NodeId id = arg_handle(self, &js, argc, args, 0, out);
	if (!id.is_set()) return;

	int variant = arg_int(&js, argc, args, 2);
	self.pass.scene.set_variant(id, variant < 0 ? 0 : (uint)variant);
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
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	NodeId id = arg_handle(self, &js, argc, args, 0, out);
	if (!id.is_set()) return;

	bool found = false;
	collision::Aabb3 box = self.pass.scene.subtree_bounds(&self.pass.assets, id, &found);
	*out = found ? aabb_value(&js, box) : qjs::null_value();
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
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
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
 `raycast(ox, oy, oz, dx, dy, dz)` — a world-space ray.

 No device is needed and none is asked for: with nothing loaded there is nothing
 to hit and the answer is `null`, which is the truth rather than an error.

 The direction is normalised here rather than being required to arrive that way.
 `Hit.distance` is measured along a unit ray, so an unnormalised direction would
 silently return a distance in units of its own length — the same class of
 mistake `Scene.raycast` already guards against between instance scales.
*>
fn void js_raycast(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	Vec3 origin = {
		arg_float(&js, argc, args, 0), arg_float(&js, argc, args, 1), arg_float(&js, argc, args, 2)
	};
	Vec3 direction = {
		arg_float(&js, argc, args, 3), arg_float(&js, argc, args, 4), arg_float(&js, argc, args, 5)
	};

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
	js.set_property(object, "assets", qjs::int_value((int)stats.assets));
	js.set_property(object, "triangles", qjs::int_value((int)stats.triangles));
	js.set_property(object, "vertices", qjs::int_value((int)stats.vertices));
	js.set_property(object, "textures", qjs::int_value((int)stats.textures));
	js.set_property(object, "textureBytes", qjs::number_value((double)stats.texture_bytes));
	js.set_property(object, "culledLastFrame", qjs::int_value((int)stats.culled_last_frame));
	*out = object;
}

<*
 `unloadUnused()` — free every asset no live node names, and say what went.

 `game.md` G2/S3, and the reason it is a verb rather than a finalizer is written
 there: a collector-driven free makes resident memory depend on when QuickJS felt
 like collecting, which is the worst possible property for the one number a game
 watches. A level boundary is an explicit moment and this is what happens at it.

 Answers with `{ assets, textures, bytes }` rather than nothing, because an agent
 that cannot see the number move has no way to tell a working unload from a
 no-op — and `stats()` afterwards is the independent confirmation.

 Costs a full device idle when there is anything to free and nothing at all when
 there is not, so calling it every level is right and calling it every frame is
 merely wasteful.
*>
fn void js_unload_unused(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	// A null device is a scene-math runtime: nothing was ever uploaded, so there
	// is nothing to give back and an exception would make a script written for a
	// game fail under a test harness.
	Gpu* gpu = self.renderer != null ? &self.renderer.gpu : null;
	UnloadReport report = self.pass.assets.unload_unused(gpu);

	qjs::Value object = js.object();
	js.set_property(object, "assets", qjs::int_value((int)report.assets));
	js.set_property(object, "meshes", qjs::int_value((int)report.meshes));
	js.set_property(object, "textures", qjs::int_value((int)report.textures));
	js.set_property(object, "bytes", qjs::number_value((double)report.bytes));
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

<*
 `renderSize()` — the offscreen target's extent, as `[width, height]`.

 Without it `pick(x, y)` would take pixels of an image whose size a script has
 no way to ask for: the agent driving over MCP learns it from `screenshot`, and
 a script running inside one call would have to be told. `pick(w / 2, h / 2)`
 is the line this exists for.
*>
fn void js_render_size(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
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

<*
 `backgroundGet()` — the colour every frame starts on, as `[r, g, b]`.
*>
fn void js_background_get(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	if (self.renderer == null)
	{
		*out = js.raise("there is nothing to clear without a GPU device, so there is no background colour");
		return;
	}

	qjs::Value list = js.array();
	for (uint i = 0; i < 3; i++) js.set_index(list, i, qjs::number_value(self.renderer.clear[i]));
	*out = list;
}

<*
 `backgroundSet(r, g, b)` — what every frame starts on.

 ## The alpha stays at one, and is not an argument

 A clear alpha of zero would only mean something if what the image is composited
 onto were a question, and it is not: the offscreen target is blitted to an
 opaque swapchain image and encoded to a PNG that nothing is behind. Taking an
 alpha here would let a script write a number that changes no pixel, which is
 worse than not offering it — `plan.md` §4's half-match rule applied to a
 parameter rather than to a name.

 ## Components, not a hex value

 The same contract `mesh.color` has, and the same reason: the components are
 what the pixel gets and there is no colour management anywhere in this project.
 `prelude.js` does the hex arithmetic so both doors divide by 255 identically.
*>
fn void js_background_set(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	if (self.renderer == null)
	{
		*out = js.raise("there is nothing to clear without a GPU device, so there is no background colour");
		return;
	}

	for (int i = 0; i < 3; i++)
	{
		self.renderer.clear[i] = math::clamp(arg_float(&js, argc, args, i), 0.0f, 1.0f);
	}
	self.renderer.clear[3] = 1.0f;
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
	// Reported since M6, and read-only on the JS side. They are still derived
	// rather than set — `Camera.derive_planes` argues that at length — but derived
	// is not the same as secret, and while they were neither reported nor settable
	// there was no way at all to find out that the sky had fallen outside the far
	// plane except by rendering and guessing.
	js.set_index(list, 7, qjs::number_value(camera.near_plane));
	js.set_index(list, 8, qjs::number_value(camera.far_plane));
	*out = list;
}

<*
 `cameraSet(tx, ty, tz, yaw, pitch, distance, fov)`.

 The near and far planes are re-derived from the distance and the scene's own
 bounds rather than taken from the caller — see `Camera.derive_planes` for why —
 and the angles are clamped the same way a mouse drag clamps them, so a script
 and a hand on the window cannot put the camera in two different sets of states.
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

	camera.clamp_angles();
	// Through the pass rather than `camera.derive_planes()` directly, so the far
	// plane is fitted to the scene the script has built instead of to a multiple
	// of the distance it just asked for. `MeshPass.derive_camera_planes` has the
	// argument; the short version is that a script that dollies in used to lose
	// its sky.
	self.pass.derive_camera_planes();
}

fn void js_frame_all(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	self.pass.frame_camera();
}
