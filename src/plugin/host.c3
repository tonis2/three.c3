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
	.build_mesh        = &host_build_mesh,
	.unload_unused     = &host_unload_unused,
	.set_view_rect     = &host_set_view_rect,
	.set_camera        = &host_set_camera,

	.ui_context  = &host_ui_context,
	.ui_set_root = &host_ui_set_root,
	.ui_set_slot = &host_ui_set_slot,
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
	// `desc.scripts` made absolute against the image, or empty for a plugin that
	// ships none. Resolved once here rather than at every reload, because the
	// answer cannot change while the image is open. Owned; freed by `unload`.
	String scripts;
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
	host.scripts = plugin_scripts_dir(path, host.desc.scripts, mem);
	io::printfn("three: plugin %s (ABI %d)", plugin_name.str_view(), host.desc.abi_version);
	if (host.scripts.len > 0) io::printfn("three: plugin scripts %s", host.scripts);
}

<*
 Where a plugin's `scripts` directory actually is.

 A relative path is resolved against the *image*, not the working directory —
 `plugin_abi.md`'s `PluginDesc.scripts` says why: the `.js` and the `.dylib` are
 one bundle, and three is started from wherever the user happens to be. An
 absolute path is its own answer, and a bare filename with no directory in the
 image path leaves nothing to resolve against and is used as written.

 Not `realpath`'d. The join can hold a `..` — `build/../assets/js` is what a
 checkout produces — and the filesystem resolves those perfectly well; spending a
 syscall to make the diagnostic prettier would also make it lie about symlinks.
*>
fn String plugin_scripts_dir(String image, ZString declared, Allocator allocator) @local
{
	if (declared == null) return "";
	String named = declared.str_view();
	if (named.len == 0) return "";
	if (named[0] == '/') return named.copy(allocator);

	usz cut = 0;
	bool has_dir = false;
	foreach (i, c : image)
	{
		if (c == '/') { cut = (usz)i; has_dir = true; }
	}
	if (!has_dir) return named.copy(allocator);
	return string::format(allocator, "%s/%s", image[:cut], named);
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
	if (host.scripts.len > 0)
	{
		host.scripts.free(mem);
		host.scripts = "";
	}
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

<*
 The same, for a verb whose node argument is a *parent*: NO_NODE is the scene's
 root rather than nothing.

 A plugin cannot name the root any other way — the root's handle is never
 answered by anything, and `place` already reads a missing parent as "at the top
 of the scene". Without this, `add_mesh` and `add_group` refuse the only parent a
 plugin placing its first object has, which reads as the verb being broken.
*>
fn Scene* resolve_parent(three_abi::Scene scene, three_abi::Node node, NodeId* out) @local
{
	Scene* found = scene_of(scene);
	if (found == null) return null;
	if (node == three_abi::NO_NODE)
	{
		*out = found.root;
		return found;
	}
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
	// NO_NODE is the root, as it is for `add_group` and `add_mesh` — "take this
	// back to the top of the scene", which a plugin has no other way to say.
	NodeId under = parent == three_abi::NO_NODE ? found.root : to_node_id(parent);
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
	Scene* found = resolve_parent(scene, parent, &id);
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
	Scene* found = resolve_parent(scene, parent, &id);
	if (found == null || api_pass == null) return three_abi::NO_NODE;
	AssetId of = { three_abi::unpack_index(asset), three_abi::unpack_generation(asset) };
	if (api_pass.assets.mesh(of, mesh) == null) return three_abi::NO_NODE;
	NodeId made = found.add_mesh(of, mesh, id, name == null ? "" : name.str_view());
	return made.is_set() ? three_abi::pack(made.index, made.generation) : three_abi::NO_NODE;
}

<*
 Geometry from a plugin's arrays, as an asset.

 Copied into a `GeometryBuilder` and pushed through `upload_built`, so a mesh a
 plugin computed and one three.c3 tessellated are the same thing afterwards:
 same slot, same dedup by key, same picking tree, same unload path. The copy is
 the price of the ABI's no-ownership rule — the arrays are the caller's and are
 freed the moment this returns — and it is paid once per rebuild, not per frame.

 Indices are bounds-checked against the vertex count. That is not paranoia about
 the plugin: an out-of-range index is a device fault with no host-side symptom,
 which would be reported as "three crashed" rather than as "the plugin sent a bad
 mesh", and the walk is already being paid for by the copy beside it.
*>
fn three_abi::Asset host_build_mesh(
	ZString key,
	float* positions,
	float* normals,
	float* colors,
	uint vertex_count,
	uint* indices,
	uint index_count
) @local
{
	if (api_pass == null || api_renderer == null) return three_abi::NO_ASSET;
	if (positions == null || indices == null || vertex_count == 0) return three_abi::NO_ASSET;
	if (index_count < 3 || index_count % 3 != 0) return three_abi::NO_ASSET;

	String name = key == null ? "" : key.str_view();
	// The same dedup `Assets.primitive` does, and asked before the copy rather
	// than after it — the point of a key is that a rebuild under one costs
	// nothing, and a walk over the vertices first would spend most of that.
	if (try hit = api_pass.assets.built(name))
	{
		return three_abi::pack(hit.index, hit.generation);
	}

	for (uint i = 0; i < index_count; i++)
	{
		if (indices[i] >= vertex_count)
		{
			io::eprintfn(
				"[%s] build_mesh(%s): index %d at %d is past the %d vertices given",
				plugin_name.str_view(), name, indices[i], i, vertex_count);
			return three_abi::NO_ASSET;
		}
	}

	GeometryBuilder geometry;
	geometry.init();
	defer geometry.free();

	for (uint i = 0; i < vertex_count; i++)
	{
		usz at = (usz)i * 3;
		geometry.positions.push({ positions[at], positions[at + 1], positions[at + 2] });
	}
	// Both optional, and optional by *length* on the far side — `upload_built`
	// asks whether the stream is as long as the positions rather than whether a
	// flag was set, so leaving one empty here is the whole of switching it off.
	if (normals != null)
	{
		for (uint i = 0; i < vertex_count; i++)
		{
			usz at = (usz)i * 3;
			geometry.normals.push({ normals[at], normals[at + 1], normals[at + 2] });
		}
	}
	if (colors != null)
	{
		for (uint i = 0; i < vertex_count; i++)
		{
			usz at = (usz)i * 4;
			geometry.colors.push({ colors[at], colors[at + 1], colors[at + 2], colors[at + 3] });
		}
	}
	for (uint i = 0; i < index_count; i++) geometry.indices.push(indices[i]);

	AssetId? built = api_pass.assets.upload_built(&api_renderer.gpu, name, name, &geometry);
	if (catch err = built)
	{
		io::eprintfn("[%s] build_mesh(%s) failed: %s", plugin_name.str_view(), name, err);
		return three_abi::NO_ASSET;
	}
	return three_abi::pack(built.index, built.generation);
}

fn uint host_unload_unused() @local
{
	if (api_pass == null || api_renderer == null) return 0;
	UnloadReport report = api_pass.assets.unload_unused(&api_renderer.gpu);
	// Files, not meshes: a plugin rebuilding one mesh made one asset and wants to
	// know that one asset went. `report.meshes` counts pieces given back out of a
	// file that stayed, which is a kit's number rather than a generated mesh's.
	return report.assets;
}

fn void host_set_view_rect(float x, float y, float width, float height) @local
{
	if (api_pass == null) return;
	// Stored as given and resolved against the attachment at `prepare` — see
	// `MeshPass.resolve_view_rect`, which is where the clamping lives. A plugin
	// setting this from a laid-out element does not know the backing scale and
	// should not have to.
	api_pass.view_rect = { x, y, width, height };
}

<*
 The camera, from the plugin's own orbit.

 A follow is cleared, because the two are the same job: `CameraFollow` writes the
 target every frame, and a plugin pushing one every frame as well would produce a
 camera that snaps between two answers. The plugin asked most recently, so the
 plugin wins.

 `clamp_angles` runs, as it does for every other writer. Its pitch limit is 89°
 and so is crig's, so a plugin that clamped its own first is unchanged by this —
 which is the property that matters, since a plugin projecting its own overlays
 is relying on the two ends agreeing to the float.
*>
fn void host_set_camera(
	float target_x, float target_y, float target_z,
	float distance,
	float yaw, float pitch,
	float fov,
	float near_plane, float far_plane
) @local
{
	if (api_pass == null) return;
	api_pass.follow = {};
	Camera* camera = &api_pass.camera;
	camera.target = { target_x, target_y, target_z };
	camera.distance = distance;
	camera.yaw = yaw;
	camera.pitch = pitch;
	camera.fov = fov;
	camera.near_plane = near_plane;
	camera.far_plane = far_plane;
	camera.clamp_angles();
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

fn void host_ui_set_slot(void* element) @local
{
	if (api_renderer == null) return;
	api_renderer.ui.set_slot(element);
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
