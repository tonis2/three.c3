<*
 The shared halves of every host verb: reading its arguments and building what
 it answers with.
*>
module three;

import std::math;
import collision;
import qjs;

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

// Three numbers from `args[at]` on, missing ones as zero.
fn Vec3 arg_vec3(qjs::Context* js, int argc, qjs::Value* args, int at)
{
	return { arg_float(js, argc, args, at), arg_float(js, argc, args, at + 1), arg_float(js, argc, args, at + 2) };
}

// An ArrayBuffer's bytes, or none when the argument is not there.
fn char[] arg_bytes(qjs::Context* js, int argc, qjs::Value* args, int at)
{
	return at < argc ? js.bytes(args[at]) : { };
}

// An array's length, or -1 when the argument is not there.
fn long arg_length(qjs::Context* js, int argc, qjs::Value* args, int at)
{
	return at < argc ? js.length(args[at]) : -1;
}

<*
 One number out of a flat array argument, with a finite backstop: the prelude
 refuses a non-finite component with a sentence naming its index, and `fallback`
 is what a forged call gets instead of spreading a NaN into its neighbours.
*>
fn float index_float(qjs::Context* js, qjs::Value array, uint idx, float fallback = 0)
{
	qjs::Value value = js.index(array, idx);
	double number    = js.number(value);
	js.release(value);
	return math::is_finite(number) ? (float)number : fallback;
}

// One whole number out of a flat array argument, zero for anything that is not one.
fn uint index_uint(qjs::Context* js, qjs::Value array, uint idx)
{
	float number = index_float(js, array, idx);
	return number > 0 ? (uint)number : 0;
}

// ============================================================================
// Building values
// ============================================================================

<*
 A flat JavaScript array of numbers. The shape every vector, box and matrix
 crosses back in, since the prelude builds the object a script sees.
*>
fn qjs::Value numbers_value(qjs::Context* js, double[] numbers)
{
	qjs::Value array = js.array();
	foreach (i, n : numbers) js.set_index(array, (uint)i, qjs::number_value(n));
	return array;
}

// Writes `numbers` into `array` from index `at` on, and answers the next free index.
fn uint put_numbers(qjs::Context* js, qjs::Value array, uint at, double[] numbers)
{
	foreach (n : numbers) js.set_index(array, at++, qjs::number_value(n));
	return at;
}

<*
 `raise` with a formatted message, which is how nearly every refusal is spelled.
*>
fn qjs::Value qjs::Context.raisef(&self, String format, args...) @format(1)
{
	return self.raise(string::tformat(format, ...args));
}

<*
 Whether the context has a device, raising `what needs a GPU device` when not.
*>
fn bool JsRuntime.needs_device(&self, qjs::Context* js, String what, qjs::Value* out)
{
	if (self.renderer != null) return true;
	*out = js.raisef("%s needs a GPU device and this context has none", what);
	return false;
}

<*
 A handle as JavaScript sees it: `[index, generation]`, for a node or an asset.

 Two numbers rather than an object because the prelude immediately destructures
 it, and because an object would allocate a shape per load.
*>
fn qjs::Value pair_value(qjs::Context* js, uint index, uint generation)
{
	qjs::Value pair = js.array();
	js.set_index(pair, 0, qjs::int_value((int)index));
	js.set_index(pair, 1, qjs::int_value((int)generation));
	return pair;
}

fn qjs::Value handle_value(qjs::Context* js, NodeId id) => pair_value(js, id.index, id.generation);

fn qjs::Value asset_value(qjs::Context* js, AssetId id) => pair_value(js, id.index, id.generation);

// A node handle, or `null` for no node.
fn qjs::Value node_handle_or_null(qjs::Context* js, NodeId id)
{
	return id.is_set() ? handle_value(js, id) : qjs::null_value();
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

fn qjs::Value vec3_value(qjs::Context* js, Vec3 v) => numbers_value(js, { v.x, v.y, v.z });

<*
 A box as six numbers, `[minX, minY, minZ, maxX, maxY, maxZ]`.

 Flat rather than `{min, max}` because `prelude.js` derives `size` and `center`
 from it anyway, and one array of six is one allocation where a nested pair is
 three. The shape a script sees is built there.
*>
fn qjs::Value aabb_value(qjs::Context* js, collision::Aabb3 box)
{
	return numbers_value(js, { box.min.x, box.min.y, box.min.z, box.max.x, box.max.y, box.max.z });
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
		*out = js.raisef("%s needs an object in the scene being rendered — call scene.activate() on the one it is in first",
			verb);
		return { };
	}
	return ref;
}

