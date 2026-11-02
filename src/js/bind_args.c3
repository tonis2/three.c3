<*
 The shared halves of every host verb: reading its arguments and building what
 it answers with.
*>
module three;

import std::math;
import collision;
import qjs;
import fastjs::js;
import std::collections::map;
import std::collections::list;

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

// TEMPORARY: old-API doors to bind_asset.c3's helpers, for bind_compute.c3 and
// bind_scene.c3 until they are converted (`texture_handle`, `writable_path`,
// `written_image` are the new ones).
fn qjs::Value texture_value(JsRuntime* self, qjs::Context* js, int index, Texture* uploaded)
{
	js::Value? fields = self.texture_handle(index, uploaded);
	if (catch fields) return qjs::EXCEPTION;
	return (qjs::Value)fields;
}

fn String? JsRuntime.open_for_write(
	&self,
	qjs::Context* js,
	String asked,
	String verb,
	Allocator allocator,
	qjs::Value* out
)
{
	String? writing = self.writable_path(asked, verb, allocator);
	if (catch err = writing)
	{
		*out = qjs::EXCEPTION;
		return err~;
	}
	return writing;
}

fn qjs::Value wrote_image(qjs::Context* js, String path, uint width, uint height) @private
{
	js::Value? described = js.engine().@object_of(written_image(path, width, height));
	if (catch described) return qjs::EXCEPTION;
	return (qjs::Value)described;
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


// ============================================================================
// Handles: nodes and assets as host objects
// ============================================================================

<*
 A node or an asset as a script holds it: an instance of the host class `Node` or
 `Asset`, carrying the packed id. There is one handle object per live id, so `===`
 is identity, and a script can hang its own object off it (`h.owner`), which is how
 a hit, an event or a query answer turns back into the Object3D a script built.

 The table holds every handle a script was given while its node lives. Entries for
 nodes or assets that are gone are dropped by `prune_handles`, after each run and
 every few frames; until then a stale handle is harmless, because the generation in
 it never matches again.
*>
const ulong HANDLE_TAG = 1ul << 63;

fn void* pack_id(uint index, uint generation) @inline => (void*)(uptr)(HANDLE_TAG | (ulong)generation << 32 | index);

fn ulong id_key(uint index, uint generation) @inline => (ulong)generation << 32 | index;

macro unpack_id(void* data, $Id) => ($Id){ (uint)((ulong)(uptr)data & 0xFFFF_FFFF), (uint)(((ulong)(uptr)data & ~HANDLE_TAG) >> 32) };

<*
 The handle for a live node: the same object every time it is asked for.

 @return? js::THREW
*>
fn js::Value? JsRuntime.node_handle(&self, NodeId id)
{
	if (!id.is_set()) return js::NULL;
	ulong key = id_key(id.index, id.generation);
	if (try root = self.node_handles.get(key)) return self.js.held(root);
	js::Value h = self.js.instance(self.node_class, pack_id(id.index, id.generation))!;
	self.node_handles.set(key, self.js.hold(h));
	return h;
}

<*
 The handle for a loaded asset, the same way.

 @return? js::THREW
*>
fn js::Value? JsRuntime.asset_handle(&self, AssetId id)
{
	if (!id.is_set()) return js::NULL;
	ulong key = id_key(id.index, id.generation);
	if (try root = self.asset_handles.get(key)) return self.js.held(root);
	js::Value h = self.js.instance(self.asset_class, pack_id(id.index, id.generation))!;
	self.asset_handles.set(key, self.js.hold(h));
	return h;
}

<*
 Forget the handles of nodes and assets that are gone, so their objects (and the
 Object3D a script hung on them) can be collected.
*>
fn void JsRuntime.prune_handles(&self)
{
	@pool()
	{
		List {ulong} dead;
		dead.tinit();
		self.node_handles.@each(; ulong key, js::Root root)
		{
			NodeId id = { (uint)(key & 0xFFFF_FFFF), (uint)(key >> 32) };
			if (!self.find_node(id).scene) dead.push(key);
		};
		foreach (key : dead)
		{
			js::Root root = self.node_handles.get(key)!!;
			self.js.drop(&root);
			self.node_handles.remove(key);
		}
		dead.clear();
		self.asset_handles.@each(; ulong key, js::Root root)
		{
			AssetId id = { (uint)(key & 0xFFFF_FFFF), (uint)(key >> 32) };
			if (self.pass == null || self.pass.assets.slot(id) == null) dead.push(key);
		};
		foreach (key : dead)
		{
			js::Root root = self.asset_handles.get(key)!!;
			self.js.drop(&root);
			self.asset_handles.remove(key);
		}
	};
}

<*
 Where a node is: the active scene first, then every other. Node generations come
 from one process-wide counter, so an id matches in at most one scene, and an id
 into a disposed scene matches in none.

 @return `The node and its scene, or a null scene.`
*>
fn NodeRef JsRuntime.find_node(&self, NodeId id)
{
	if (self.pass == null) return { };
	if (self.pass.scene != null && self.pass.scene.node(id) != null) return { .scene = self.pass.scene, .id = id };
	foreach (each : self.pass.scenes)
	{
		if (each.node(id) != null) return { .scene = each, .id = id };
	}
	return { };
}

<*
 A Node handle argument (or `this`), resolved to its live node.

 @return? js::THREW
*>
fn void? NodeRef.from_js(&self, js::Call* c, int at)
{
	JsRuntime* rt = c.js.user;
	void* data = js::data_of(c.get(at), rt.node_class);
	if (!data) return c.type_error(at, "a scene object")~;
	*self = rt.find_node(unpack_id(data, NodeId));
	if (!self.scene) return c.fail("that object is no longer in the scene — it was removed, or the scene it was in was disposed")~;
}

// A Node handle argument that may also be null or undefined, for "no node".
struct MaybeNode
{
	NodeRef ref;
}

<*
 @return? js::THREW
*>
fn void? MaybeNode.from_js(&self, js::Call* c, int at)
{
	if (c.get(at).is_nullish()) return;
	self.ref.from_js(c, at)!;
}

fn bool MaybeNode.is_set(self) => self.ref.scene != null;

fn js::Value? NodeId.to_js(&self, js::Engine* js) => ((JsRuntime*)js.user).node_handle(*self);

<*
 An Asset handle argument, checked to be still loaded. Since G2 a slot is reused,
 so the sentence names `unloadUnused`.

 @return? js::THREW
*>
fn void? AssetId.from_js(&self, js::Call* c, int at)
{
	JsRuntime* rt = c.js.user;
	void* data = js::data_of(c.get(at), rt.asset_class);
	if (!data) return c.type_error(at, "an asset")~;
	*self = unpack_id(data, AssetId);
	if (rt.pass == null || rt.pass.assets.slot(*self) == null)
	{
		return c.fail("that asset is no longer loaded — three.unloadUnused() or scene.unload() freed it, "
			"and loading the file again gives a fresh handle")~;
	}
}

fn js::Value? AssetId.to_js(&self, js::Engine* js) => ((JsRuntime*)js.user).asset_handle(*self);

// The id inside a handle, for the getters.
fn double js_handle_index(JsRuntime* rt, js::Value h)
{
	void* data = js::data_of(h, rt.node_class) ?: js::data_of(h, rt.asset_class);
	return data ? (double)unpack_id(data, NodeId).index : -1;
}

fn double js_handle_generation(JsRuntime* rt, js::Value h)
{
	void* data = js::data_of(h, rt.node_class) ?: js::data_of(h, rt.asset_class);
	return data ? (double)unpack_id(data, NodeId).generation : -1;
}

<*
 `__three.nodeAt(index, generation)`: the handle for a node a bulk query wrote into a
 typed array as two ints. Null for a node that is gone.

 @return? js::THREW
*>
fn js::Value? js_node_at(JsRuntime* rt, int index, int generation)
{
	if (index < 0) return js::NULL;
	NodeId id = { (uint)index, (uint)generation };
	if (!rt.find_node(id).scene) return js::NULL;
	return rt.node_handle(id);
}

<*
 The handle classes and the verbs every file shares. Before any verbs that take or
 give handles.

 @return? js::THREW
*>
fn void? JsRuntime.install_handles(&self, js::Value host)
{
	self.node_class = self.js.class("Node")!;
	self.asset_class = self.js.class("Asset")!;
	foreach (cls : (js::NativeClass*[]){ self.node_class, self.asset_class })
	{
		self.js.@getter(cls, "index", &js_handle_index, self)!;
		self.js.@getter(cls, "generation", &js_handle_generation, self)!;
	}
	self.js.@bind(host, "nodeAt", &js_node_at, self)!;
}
