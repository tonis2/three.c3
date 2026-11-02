<*
 The shared halves of every host verb: nodes and assets as handles, and the
 argument types that read them.
*>
module three;

import std::math;
import collision;
import fastjs::js;
import std::collections::map;
import std::collections::list;

<*
 A resolved handle: the node, and the scene it turned out to be in.

 A pair rather than a `NodeId` on purpose. There is more than one scene now, so
 "which graph does this verb operate on" is an answer a verb has to be *given*
 rather than one it can assume — and a verb that reached for `self.pass.scene`
 instead would write into whichever world happened to be on screen. Making
 `NodeRef.from_js` answer with a type that is not a `NodeId` is what turns every one
 of those into a compile error rather than into a silent wrong-scene write.
*>
struct NodeRef
{
	Scene* scene;
	NodeId id;
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
