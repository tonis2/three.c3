<*
 The engine's API surface, and loading a native plugin onto it.

 `plugin_abi.md` is the design. This is the host half: the implementations behind
 `three_abi::HostApi`, plus `dlopen`, one `dlsym` and a version check.

 ## The table is not the plugin's

 §5: *`install_bindings` is the vtable's first consumer, not its sibling.* So
 `engine_api` is filled at its declaration and live in every process, including
 one with no plugin and including the test runner — `js/bind_scene.c3` calls
 through it, and a table that only existed under `--plugin` would make the JS
 tests test a different code path from the one a plugin uses. Which is the whole
 thing §5 is written to prevent.

 ## Why the verbs take no context

 Every entry in `HostApi` is a bare function pointer with no engine argument, so
 the engine they reach is a file-private global set once at load. That is a
 single-engine assumption and it is deliberate — `plugin_abi.md` §10 says the
 host loads one plugin, and one process has one `Renderer` for the same reason
 the JS runtime holds one `MeshPass*`.

 The alternative is a `void* host` first parameter on two hundred verbs, paid by
 every call for a second engine nobody has asked for. If one is ever wanted, this
 is the file that changes and the ABI version is what makes that safe.

 ## Handles

 The verbs are the boundary where `AssetId` and `NodeId` become `ulong` and back.
 Nothing above this file deals in packed handles and nothing below it deals in
 the engine's structs, which is what keeps the ABI free of three's layout.
*>
module three;

import std::io;
import std::math::vector;
import libc;
import collision;
import three_abi;

faultdef
	// `dlopen` refused the file. Its own message is printed beside this.
	PLUGIN_NOT_LOADABLE,
	// The image has no `three_plugin_main`.
	PLUGIN_NO_ENTRY,
	// `three_plugin_main` answered false. It has already said why.
	PLUGIN_REFUSED,
	// Built against a different ABI_VERSION.
	PLUGIN_ABI_MISMATCH;

<*
 What the verbs reach, set by `engine_open` and cleared by `engine_close`.

 Two rather than one because they have different lifetimes and different
 availability: every process that runs a script has a `MeshPass`, and a
 scene-math runtime has no `Renderer` at all — `JsRuntime.open` documents the
 null. So the node verbs reach for the pass and only the ones that touch the
 device or the window reach for the renderer, and both check.
*>
MeshPass* api_pass @local = null;
Renderer* api_renderer @local = null;

// The loaded plugin's name, for the log prefix. Borrowed from `PluginDesc`.
ZString plugin_name @local = "plugin";

<*
 Whether the plugin has asked for another iteration since the loop last looked.

 A latch rather than a level, and read-clears rather than read: the loop asks once
 per iteration and a request made during `frame` must survive to the `quiet`
 decision at the end of the same one. `UiLayer.idle` is the same shape for the
 same reason, and its comment says so.
*>
bool plugin_frame_requested @local = false;

<*
 The one table: three's own API, and what a plugin is handed a pointer to.

 Filled at its declaration rather than built by a function, which settles two
 things at once. It is live before anything runs, so `js/bind_scene.c3` may call
 through it from a test that never loaded a plugin. And its address is a module
 static, which is the whole of what the first spike run got wrong: `load_plugin`
 built the table in a local, handed out its address and then returned the struct
 by value, so the plugin's copy pointed into a dead stack frame and every verb was
 null by the time `shutdown` ran.

 `ToolHost` in `main.c3` carries the same rule for the same reason — "addressed
 by pointer from every tool, so it must not move while the server lives".

 The JavaScript and MCP halves are function pointers into files that own quickjs
 and mcp respectively, so they are filled by `engine_open` rather than named here
 — see `fill_js_api` and `fill_mcp_api`.
*>
three_abi::HostApi engine_api = {
	.abi_version = three_abi::ABI_VERSION,

	.log           = &host_log,
	.load          = &host_load,
	.place         = &host_place,
	.set_position  = &host_set_position,
	.set_color     = &host_set_color,
	.frame_camera  = &host_frame_camera,
	.active_scene  = &host_active_scene,
	.node_scene    = &host_node_scene,
	.node_children = &host_node_children,
	.request_frame = &host_request_frame,

	.set_transform     = &host_set_transform,
	.set_quaternion    = &host_set_quaternion,
	.transform_refusal = &host_transform_refusal,
	.set_visible       = &host_set_visible,
	.set_collides      = &host_set_collides,
	.set_static        = &host_set_static,
	.set_name          = &host_set_name,
	.set_variant       = &host_set_variant,
	.world_position    = &host_world_position,
	.object_bounds     = &host_object_bounds,
	.remove_node       = &host_remove_node,
	.set_parent        = &host_set_parent,
	.add_group         = &host_add_group,
	.add_mesh          = &host_add_mesh,

	.ui_context  = &host_ui_context,
	.ui_set_root = &host_ui_set_root,
};

<*
 Points the table at an engine.

 Called from `run` once the renderer exists, and again from `JsRuntime.open` —
 idempotent, and both because neither covers the other: a plugin runs before any
 runtime opens, and a test opens a runtime with no `run` above it.

 @param pass : `The world every node verb resolves against. Required.`
 @param renderer : `Null in a scene-math runtime, and the verbs that need a device check.`
*>
fn void engine_open(MeshPass* pass, Renderer* renderer)
{
	api_pass = pass;
	api_renderer = renderer;
	fill_js_api(&engine_api);
	fill_mcp_api(&engine_api);
}

// After this every verb answers nothing rather than reading a freed engine.
fn void engine_close()
{
	api_pass = null;
	api_renderer = null;
}

struct PluginHost
{
	// `dlopen`'s handle. Null when nothing is loaded — `active` is that question.
	void* image;
	three_abi::PluginDesc desc;
}

fn bool PluginHost.active(&self) => self.image != null;

<*
 Opens a plugin and lets it register.

 The order matters and is the same as `plugin_abi.md` §11: the engine is fully
 up before the image is opened, so the first thing a plugin does may be to load
 an asset. Nothing here is undone on failure except the `dlopen` itself — a
 plugin that got as far as refusing has not been given anything to leak.

 @param path : `The dynamic library. Passed to dlopen unchanged, so a bare name goes through the loader's search path and a relative one is resolved against the working directory.`
 @param renderer : `Borrowed for the life of the run. Every verb reaches it.`
 @param args : `Everything after -- on three's command line.`
*>
fn void? load_plugin(PluginHost* host, String path, Renderer* renderer, String[] args)
{
	ZString cpath = path.zstr_tcopy();
	// RTLD_NOW rather than lazy: a plugin with an unresolved symbol should fail
	// here, naming the symbol, rather than during a frame six minutes in. This is
	// also what surfaces a missing force-linked symbol — see plugin_abi.md §2.
	host.image = libc::dlopen(cpath, libc::RTLD_NOW | libc::RTLD_LOCAL);
	if (host.image == null)
	{
		io::eprintfn("three: cannot load plugin %s", path);
		ZString why = dl_error();
		if (why != null) io::eprintfn("  %s", why);
		return PLUGIN_NOT_LOADABLE~;
	}

	void* symbol = libc::dlsym(host.image, three_abi::PLUGIN_ENTRY);
	if (symbol == null)
	{
		io::eprintfn("three: %s has no %s", path, three_abi::PLUGIN_ENTRY.str_view());
		libc::dlclose(host.image);
		host.image = null;
		return PLUGIN_NO_ENTRY~;
	}

	engine_open(&renderer.pass, renderer);

	// Borrowed by the plugin for the duration of the call only — it copies what
	// it wants. Nothing here outlives `load_plugin`.
	ZString[] argv = mem::temp_array(ZString, args.len);
	foreach (i, arg : args) argv[i] = arg.zstr_tcopy();

	three_abi::PluginMainFn entry = (three_abi::PluginMainFn)symbol;
	if (!entry(&engine_api, (int)args.len, argv.ptr, &host.desc))
	{
		io::eprintfn("three: plugin %s refused to start", path);
		unload(host);
		return PLUGIN_REFUSED~;
	}

	if (host.desc.abi_version != three_abi::ABI_VERSION)
	{
		io::eprintfn(
			"three: plugin %s was built against ABI %d; this engine is ABI %d",
			path,
			host.desc.abi_version,
			three_abi::ABI_VERSION
		);
		unload(host);
		return PLUGIN_ABI_MISMATCH~;
	}

	if (host.desc.name != null) plugin_name = host.desc.name;
	io::printfn("three: plugin %s (ABI %d)", plugin_name.str_view(), host.desc.abi_version);
}

// One iteration's worth. Null is "nothing to do" rather than an error, so a
// plugin that only wants `shutdown` costs one branch a frame.
fn void PluginHost.frame(&self, float dt)
{
	if (self.desc.frame != null) self.desc.frame(self.desc.ctx, dt);
}

<*
 Whether the plugin owes the window a frame, clearing the request.

 Called unconditionally by the loop, not from inside an `&&` chain — a
 short-circuit would leave the latch standing and the next iteration would think
 it had been asked again.
*>
fn bool PluginHost.take_frame_request(&self)
{
	bool wanted = plugin_frame_requested;
	plugin_frame_requested = false;
	return wanted;
}

fn void PluginHost.event(&self, three_abi::HostEvent event)
{
	if (self.desc.event != null) self.desc.event(self.desc.ctx, &event);
}

<*
 Lets the plugin give things back, then closes the image.

 Called before the device is torn down, so a plugin holding GPU handles still has
 somewhere to give them back to.
*>
fn void PluginHost.close(&self)
{
	if (!self.active()) return;
	if (self.desc.shutdown != null) self.desc.shutdown(self.desc.ctx);
	plugin_js_closed();
	plugin_tools_closed();
	unload(self);
	// Last, and only here: `run` defers this to after the loop has returned and
	// the runtime has closed, so nothing is still calling through the table. A
	// verb reached after this reads a null engine rather than a freed one.
	engine_close();
}

fn void unload(PluginHost* host) @local
{
	// The table stays live and pointed at the engine: three's own bindings call
	// through it, and this only ends the plugin's use of it.
	plugin_name = "plugin";
	plugin_frame_requested = false;
	if (host.image != null)
	{
		libc::dlclose(host.image);
		host.image = null;
	}
	host.desc = {};
}

extern fn ZString dlerror() @local;

fn ZString dl_error() @local => dlerror();

// ---------------------------------------------------------------- the verbs

fn void host_log(ZString message) @local
{
	io::printfn("[%s] %s", plugin_name.str_view(), message.str_view());
}

<*
 The scene a handle names, or null.

 Every node verb starts here. The check is what makes a stale handle a no-op
 rather than a write into a recycled slot: `scene_by_id` answers null for a
 disposed scene, and `Scene.node` answers null for a node whose generation has
 moved on.
*>
fn Scene* scene_of(three_abi::Scene scene) @local
{
	if (api_pass == null || scene == three_abi::NO_SCENE) return null;
	return api_pass.scene_by_id((uint)scene);
}

// The scene and the node together, since no verb wants one without the other.
// Null scene means "nothing to do" and every caller treats it that way.
fn Scene* resolve(three_abi::Scene scene, three_abi::Node node, NodeId* out) @local
{
	Scene* found = scene_of(scene);
	if (found == null) return null;
	NodeId id = to_node_id(node);
	if (found.node(id) == null) return null;
	*out = id;
	return found;
}

fn three_abi::Asset host_load(ZString path) @local
{
	if (api_pass == null || api_renderer == null) return three_abi::NO_ASSET;
	AssetId? asset = api_pass.assets.load(&api_renderer.gpu, path.str_view());
	if (catch err = asset)
	{
		io::eprintfn("[%s] load(%s) failed: %s", plugin_name.str_view(), path.str_view(), err);
		return three_abi::NO_ASSET;
	}
	return three_abi::pack(asset.index, asset.generation);
}

fn three_abi::Scene host_active_scene() @local
{
	if (api_pass == null || api_pass.scene == null) return three_abi::NO_SCENE;
	return (three_abi::Scene)api_pass.scene.id;
}

<*
 The scene a node is in.

 The active one first and then the rest, which is `bind_scene.c3`'s `arg_handle`
 order and for its reason: a script or a plugin working on the level being drawn
 is the common case, and generations are process-wide so at most one scene can
 answer.
*>
fn three_abi::Scene host_node_scene(three_abi::Node node) @local
{
	if (api_pass == null) return three_abi::NO_SCENE;
	NodeId id = to_node_id(node);
	if (api_pass.scene != null && api_pass.scene.node(id) != null)
	{
		return (three_abi::Scene)api_pass.scene.id;
	}
	foreach (each : api_pass.scenes)
	{
		if (each.node(id) != null) return (three_abi::Scene)each.id;
	}
	return three_abi::NO_SCENE;
}

fn three_abi::Node host_place(three_abi::Asset asset, three_abi::Scene scene, three_abi::Node parent) @local
{
	Scene* into = scene_of(scene);
	if (into == null)
	{
		// No scene named: the one being drawn, which is what `three.load` means by
		// having no scene argument at all.
		if (api_pass == null) return three_abi::NO_NODE;
		AssetId id = { three_abi::unpack_index(asset), three_abi::unpack_generation(asset) };
		NodeId group = api_pass.place(id, to_node_id(parent));
		return group.is_set() ? three_abi::pack(group.index, group.generation) : three_abi::NO_NODE;
	}
	AssetId id = { three_abi::unpack_index(asset), three_abi::unpack_generation(asset) };
	NodeId group = into.instantiate(id, to_node_id(parent));
	return group.is_set() ? three_abi::pack(group.index, group.generation) : three_abi::NO_NODE;
}

fn void host_set_position(three_abi::Scene scene, three_abi::Node node, float x, float y, float z) @local
{
	NodeId id;
	Scene* found = resolve(scene, node, &id);
	if (found == null) return;
	found.set_position(id, { x, y, z });
}

fn void host_set_color(three_abi::Scene scene, three_abi::Node node, float r, float g, float b, float a) @local
{
	NodeId id;
	Scene* found = resolve(scene, node, &id);
	if (found == null) return;
	found.set_color(id, { r, g, b, a });
}

fn void host_frame_camera() @local
{
	if (api_pass == null) return;
	api_pass.frame_camera();
}

fn usz host_node_children(three_abi::Scene scene, three_abi::Node parent, three_abi::Node* out, usz cap) @local
{
	NodeId id;
	Scene* found = resolve(scene, parent, &id);
	if (found == null) return 0;
	Node* node = found.node(id);

	// The full count regardless, so a plugin that guessed the buffer too small can
	// tell — see the ABI. Nothing is truncated silently.
	usz total = (usz)node.children.len();
	if (out == null) return total;
	foreach (i, child : node.children)
	{
		if ((usz)i >= cap) break;
		out[i] = three_abi::pack(child.index, child.generation);
	}
	return total;
}

fn void host_request_frame() @local
{
	plugin_frame_requested = true;
}

// ------------------------------------------------------------- node writes

<*
 The transform, all nine channels.

 False is the refusal `js_set_transform` raises and a plugin would log: a node a
 physics body owns has one writer, and a solver and a caller writing the same
 transform every frame is jitter rather than a compromise. `transform_refusal`
 has the sentence.
*>
fn bool host_set_transform(
	three_abi::Scene scene,
	three_abi::Node node,
	float px, float py, float pz,
	float rx, float ry, float rz,
	float scale_x, float scale_y, float scale_z
) @local
{
	NodeId id;
	Scene* found = resolve(scene, node, &id);
	if (found == null) return false;
	if (found.physics.owns_transform(id)) return false;

	Node* target = found.node(id);
	target.position = { px, py, pz };
	// Euler in, quaternion stored — the one-way conversion `scene/node.c3`
	// describes. A caller keeps whatever triple it sent; nothing converts back.
	target.rotation = quat_from_euler({ rx, ry, rz });
	target.scale = { scale_x, scale_y, scale_z };
	// Not `dirty = true`: the world-matrix walk gained the right to skip itself,
	// so the flag alone stopped being enough. See `Scene.mark_moved`.
	found.mark_moved(id);
	return true;
}

fn bool host_set_quaternion(three_abi::Scene scene, three_abi::Node node, float x, float y, float z, float w) @local
{
	NodeId id;
	Scene* found = resolve(scene, node, &id);
	if (found == null) return false;
	// The same refusal, and it has to be here too: a caller that only ever wrote
	// the quaternion would otherwise fight the solver through the one door left
	// open.
	if (found.physics.owns_transform(id)) return false;
	found.set_quaternion(id, { x, y, z, w });
	return true;
}

fn usz host_transform_refusal(three_abi::Scene scene, three_abi::Node node, char* buffer, usz cap) @local
{
	NodeId id;
	Scene* found = resolve(scene, node, &id);
	if (found == null || !found.physics.owns_transform(id))
	{
		if (buffer != null && cap > 0) buffer[0] = 0;
		return 0;
	}
	return fill(buffer, cap, found.physics.transform_refusal(id));
}

fn void host_set_visible(three_abi::Scene scene, three_abi::Node node, bool on) @local
{
	NodeId id;
	Scene* found = resolve(scene, node, &id);
	if (found == null) return;
	found.set_visible(id, on);
}

fn void host_set_collides(three_abi::Scene scene, three_abi::Node node, bool on) @local
{
	NodeId id;
	Scene* found = resolve(scene, node, &id);
	if (found == null) return;
	found.set_collides(id, on);
}

fn bool host_set_static(three_abi::Scene scene, three_abi::Node node, bool on) @local
{
	NodeId id;
	Scene* found = resolve(scene, node, &id);
	if (found == null) return false;
	return found.set_static_caster(id, on);
}

fn void host_set_name(three_abi::Scene scene, three_abi::Node node, ZString name) @local
{
	NodeId id;
	Scene* found = resolve(scene, node, &id);
	if (found == null) return;
	found.set_name(id, name == null ? "" : name.str_view());
}

fn void host_set_variant(three_abi::Scene scene, three_abi::Node node, uint row) @local
{
	NodeId id;
	Scene* found = resolve(scene, node, &id);
	if (found == null) return;
	found.set_variant(id, row);
}

fn bool host_world_position(three_abi::Scene scene, three_abi::Node node, float* out_xyz) @local
{
	NodeId id;
	Scene* found = resolve(scene, node, &id);
	if (found == null || out_xyz == null) return false;
	// First: a caller that sets a position and immediately asks where something is
	// would otherwise read the transform from before its own write.
	found.update_world_matrices();
	Vec3 at = found.node(id).world_position();
	out_xyz[0] = at.x;
	out_xyz[1] = at.y;
	out_xyz[2] = at.z;
	return true;
}

fn bool host_object_bounds(three_abi::Scene scene, three_abi::Node node, float* out_min_max) @local
{
	NodeId id;
	Scene* found = resolve(scene, node, &id);
	if (found == null || out_min_max == null || api_pass == null) return false;
	bool drawn = false;
	collision::Aabb3 box = found.subtree_bounds(&api_pass.assets, id, &drawn);
	if (!drawn) return false;
	out_min_max[0] = box.min.x;
	out_min_max[1] = box.min.y;
	out_min_max[2] = box.min.z;
	out_min_max[3] = box.max.x;
	out_min_max[4] = box.max.y;
	out_min_max[5] = box.max.z;
	return true;
}

fn bool host_remove_node(three_abi::Scene scene, three_abi::Node node) @local
{
	NodeId id;
	Scene* found = resolve(scene, node, &id);
	if (found == null) return false;
	// The root is the scene itself; emptying it is `unload` and freeing it is
	// `dispose`.
	if (id == found.root) return false;
	found.remove(id);
	return true;
}

fn bool host_set_parent(three_abi::Scene scene, three_abi::Node node, three_abi::Node parent) @local
{
	NodeId id;
	Scene* found = resolve(scene, node, &id);
	if (found == null) return false;
	NodeId under = to_node_id(parent);
	// Refused rather than half-done across scenes: two scenes are two node pools,
	// so this would destroy the subtree and rebuild it under the other root, which
	// is exactly what re-parenting is documented not to do.
	if (found.node(under) == null) return false;
	found.set_parent(id, under);
	return true;
}

fn three_abi::Node host_add_group(three_abi::Scene scene, three_abi::Node parent, ZString name) @local
{
	NodeId id;
	Scene* found = resolve(scene, parent, &id);
	if (found == null) return three_abi::NO_NODE;
	NodeId made = found.add_group(id, name == null ? "" : name.str_view());
	return made.is_set() ? three_abi::pack(made.index, made.generation) : three_abi::NO_NODE;
}

fn three_abi::Node host_add_mesh(
	three_abi::Scene scene,
	three_abi::Asset asset,
	uint mesh,
	three_abi::Node parent,
	ZString name
) @local
{
	NodeId id;
	Scene* found = resolve(scene, parent, &id);
	if (found == null || api_pass == null) return three_abi::NO_NODE;
	AssetId of = { three_abi::unpack_index(asset), three_abi::unpack_generation(asset) };
	if (api_pass.assets.mesh(of, mesh) == null) return three_abi::NO_NODE;
	NodeId made = found.add_mesh(of, mesh, id, name == null ? "" : name.str_view());
	return made.is_set() ? three_abi::pack(made.index, made.generation) : three_abi::NO_NODE;
}

<*
 A string into the caller's buffer, answering the full length.

 The one shape every text answer in this file uses — §6's rule, so nothing here
 allocates on the caller's behalf and a truncation is visible rather than silent.
*>
fn usz fill(char* buffer, usz cap, String text) @local
{
	if (buffer != null && cap > 0)
	{
		usz room = text.len < cap - 1 ? text.len : cap - 1;
		if (room > 0) buffer[:room] = text[:room];
		buffer[room] = 0;
	}
	return text.len;
}

// --------------------------------------------------------------- interface

fn void* host_ui_context() @local
{
	if (api_renderer == null) return null;
	return api_renderer.ui.context(&api_renderer.gpu, &api_renderer.target);
}

fn void host_ui_set_root(void* element) @local
{
	if (api_renderer == null) return;
	api_renderer.ui.set_plugin_root(element);
}

// The empty handle is the engine's own NO_NODE rather than index `uint::max`
// reconstructed, so a zeroed plugin struct addresses nothing by construction.
fn NodeId to_node_id(three_abi::Node handle) @local
{
	if (handle == three_abi::NO_NODE) return NO_NODE;
	return { three_abi::unpack_index(handle), three_abi::unpack_generation(handle) };
}

// The log prefix, for the one other file that writes a plugin's diagnostics.
fn ZString plugin_label() => plugin_name;
