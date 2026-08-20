<*
 The graph root, traversal, the instance table and `stats()`.

 ## The thesis, as code

 `plan.md`'s central claim is that an instance is an immutable asset reference
 plus a transform, and that this makes every scene the API can express optimized
 by construction. `build_draw_list` is where that stops being a claim: a
 traversal produces one `Instance` record per drawn node, records sharing an
 `(asset, mesh)` key land next to each other, and each run of them becomes one
 `vkCmdDrawIndexed` with an instance count. A thousand copies of a wall are a
 thousand 128-byte transforms and one draw. There is no fast path and no
 batching heuristic — there is no other path.

 ## Three passes, and why they are separate

	update_world_matrices   parent-relative TRS -> world matrix, dirty-driven
	build_draw_list         traverse, cull, sort by bucket key, write instances
	MeshPass.record         upload, bind, draw

 The first is the only one that touches the hierarchy, and it is the only one
 that can be skipped — a scene where nothing moved recomputes nothing. The
 second is rebuilt every frame because culling depends on the camera. The third
 is in `render/pass.c3` and knows nothing about nodes.

 ## Culling is on by default and it changes the numbers

 An instance outside the frustum is dropped from the draw list, so
 `stats()` deliberately does *not* read the last frame's list — it rebuilds with
 culling off, so that "1000 instances is 1 draw call" is a statement about the
 scene rather than about where the camera happened to be pointing.
*>
module three;

import std::collections::list;
import std::sort;
import std::math;
import std::math::vector;
import std::math::matrix;
import std::math::quaternion;
import collision;

<*
 One instance, exactly as the GPU reads it. Mirrored in `shaders/mesh.slang`.

 148 bytes: two `float4x4`, a `float4` and a `uint` under scalar layout, which is
 4-byte aligned, so an array of these is tightly packed and indexable by
 `SV_InstanceID` with no padding rules to get wrong. `normal` carries the inverse
 transpose in its upper 3x3 — see `normal_matrix` for why the model matrix will
 not do.

 ## Why `color` and `variant` are here rather than in the material

 **This is the only per-copy channel a draw call has.** Everything else a mesh
 draws with — the pipeline, the uniforms, the texture — is bucket state, pushed
 once for the whole `vkCmdDrawIndexed`, so two copies that disagree about any of
 it are two buckets and two draws. These two disagree for free: they are read
 out of this array by `SV_InstanceID`, so a thousand differently coloured copies
 of one mesh stay one draw call.

 That is the shape the API needs, because before this the only way to give two
 boxes different colours was two materials, which is two pipelines' worth of
 bucket state and two draws. `a_thousand_colours_are_still_one_draw_call` is the
 check.

 `variant` selects a row of the material's uniform table (`shader/material_source.c3`)
 and is nothing at all to the default shader. `color` multiplies albedo in both.
*>
struct Instance
{
	Matrix4f model;
	Matrix4f normal;
	// Multiplies albedo. The alpha is carried for a `shade()` body to read; the
	// opaque pipeline does not blend with it.
	float[4] color;
	// Which row of the material's table. Clamped in the shader against the row
	// count the material declared, so a variant past the end is the last row
	// rather than a read off the end of the push block.
	uint variant;
}

<*
 One instanced draw.

 `first` and `count` index `Scene.instances`. The pass hands the shader
 `instances + first * sizeof(Instance)` rather than passing `first` as a push
 constant, so `SV_InstanceID` starts at zero in every bucket and the
 firstInstance-versus-InstanceIndex question never has to be answered.
*>
struct Bucket
{
	AssetId asset;
	uint mesh;
	uint material;
	uint first;
	uint count;
}

<*
 What an agent reads its own cost off (`plan.md`'s second thesis).

 `draw_calls` and `unique_meshes` were the same number from M2 to M4 and the
 header said they would stop being so "the moment one mesh can be drawn under two
 materials". M5 is that moment. `draw_calls` is the bucket count; `unique_meshes`
 counts distinct (asset, mesh) pairs across those buckets, so one mesh drawn under
 two materials is now two draws and one mesh.

 Reporting them separately before they diverged is what made this a one-line
 change rather than a wire-format change — the day they diverged was not the day
 the field was added.
*>
struct SceneStats
{
	uint draw_calls;
	uint unique_meshes;
	uint instances;
	uint nodes;
	uint triangles;
	uint vertices;
	// How many assets are resident, which is the number a level transition has
	// to bring back down — see `Assets.resident`. Not the size of the asset
	// table: the free list is the difference, and a working unload that grew the
	// table would otherwise read as a leak.
	uint assets;
	uint textures;
	usz texture_bytes;
	// From the last `update`, not from this call — see the header.
	uint culled_last_frame;
}

// A drawable node, flattened out of the hierarchy and waiting to be sorted into
// buckets. `key` packs (asset, mesh); `material` is kept beside it rather than
// folded in because `bucket_key` already spends all 64 bits on two full-range
// uints and narrowing either half to make room would be a silent wrap rather
// than an error. Two compares instead of one is the cheaper price.
//
// Material leads the sort so that consecutive buckets share a pipeline wherever
// they can, which is what keeps the per-bucket `cmdBindPipeline` from thrashing
// once a scene uses more than one material.
struct Draw @local
{
	uint material;
	ulong key;
	uint slot;
}

struct Scene
{
	List{Node} nodes;
	List{uint} free_slots;
	NodeId root;

	// The asset table this scene's nodes count against, or null. See
	// `attach_assets`.
	Assets* assets;

	// One per instantiated subtree of an asset that has animation clips —
	// `scene/animation.c3`. **The first per-instance state that is not a
	// transform**, which is why it is a list beside the nodes rather than a
	// field on one: a `Node` is an asset reference plus a matrix, and paying a
	// player's worth of bytes on every node of every scene to animate a dozen
	// of them is the wrong trade.
	List{AnimationPlayer} players;

	// Rebuilt by `update`; read by `MeshPass.record`.
	List{Draw} draws;
	List{Instance} instances;
	List{Bucket} buckets;

	bool cull;
	uint culled;
	bool started;
}

<*
 An empty scene with a root node.

 The root is a plain group at the origin, so `scene.add(...)` with no parent
 lands under it and a whole scene can be moved by moving one node.
*>
fn Scene* Scene.init(&self)
{
	// Heap-backed explicitly. A List left zero-initialised has a null allocator
	// and `list_ensure_capacity` resolves null to `tmem`, so the first push
	// backs it with temp-arena memory that any enclosing `@pool()` frees on the
	// way out — see `Asset.init_lists`, which carries the same note.
	self.nodes.init(mem, 64);
	self.free_slots.init(mem, 16);
	self.players.init(mem, 4);
	self.draws.init(mem, 64);
	self.instances.init(mem, 64);
	self.buckets.init(mem, 16);

	self.cull = true;
	self.started = true;
	self.root = self.create_slot(NO_NODE, NO_ASSET, NO_MESH, "root");
	return self;
}

<*
 Point this scene at the asset table its nodes reference.

 **This is where `Asset.refs` comes from.** Every place a node can start naming
 an asset is `create_slot` and every place it can stop is `kill`, so counting
 there means there is one implementation of the count rather than one per caller
 — which matters now that being wrong by one means either a leak or a freed
 buffer, where before G2 it only meant a misleading number.

 Detached by default and a no-op then. A scene with no asset table is the
 scene-math test configuration: there is no device, nothing is uploaded, and
 there is nothing to count.

 The pointer is into the `MeshPass` that owns both, so a pass must not be copied
 after `init` — which nothing does, and which was already true of `Assets`'
 own interior pointers.
*>
fn void Scene.attach_assets(&self, Assets* assets)
{
	self.assets = assets;
}

<*
 Forget the player rooted at `id`, if there is one.

 Called from `kill` for every node of a removed subtree, so it has to be cheap
 for the overwhelmingly common case of "this node roots nothing". The shift
 `remove_at` does is over a list with one entry per animated prop in the scene,
 which is not the list worth writing a swap-with-last for.
*>
fn void Scene.drop_player(&self, NodeId root)
{
	foreach (i, &candidate : self.players)
	{
		if (candidate.root != root) continue;
		candidate.free();
		self.players.remove_at(i);
		return;
	}
}

<*
 The animation player for an instantiated subtree, or null.

 Looked up by the subtree's root, which is the handle `instantiate` returned and
 the thing a script has in hand when it calls `play`. A linear scan because the
 list holds one entry per *animated prop in the scene* — a dozen, not a
 thousand — and a map keyed by `NodeId` would cost more to maintain than the
 scan costs to run.
*>
fn AnimationPlayer* Scene.player(&self, NodeId root)
{
	foreach (&candidate : self.players)
	{
		if (candidate.root == root) return candidate;
	}
	return null;
}

fn void Scene.free(&self)
{
	foreach (&node : self.nodes)
	{
		node.children.free();
		if (node.name.len > 0) node.name.free(mem);
	}
	self.nodes.free();
	self.free_slots.free();
	foreach (&player : self.players) player.free();
	self.players.free();
	self.draws.free();
	self.instances.free();
	self.buckets.free();
	*self = { };
}

// ============================================================================
// The hierarchy
// ============================================================================

<*
 Resolve a handle.

 @return `The node, or null if the id is stale: the slot was freed and possibly reused. Valid only until the next add, which may reallocate the pool.`
*>
fn Node* Scene.node(&self, NodeId id)
{
	if (!id.is_set() || id.index >= self.nodes.len()) return null;
	Node* node = &self.nodes[id.index];
	if (!node.alive || node.generation != id.generation) return null;
	return node;
}

<*
 Add a group: a node that is traversed and transformed but never drawn.

 @param parent : `NO_NODE for the scene root.`
*>
fn NodeId Scene.add_group(&self, NodeId parent = NO_NODE, String name = "")
{
	return self.attach(parent, NO_ASSET, NO_MESH, name);
}

<*
 Add a mesh: an asset reference plus a transform, which is the whole of what an
 instance is (`plan.md` §"What it is").

 @param asset : `A handle from Assets.load, primitive or convex.`
 @param mesh : `Index into that asset's meshes.`
*>
fn NodeId Scene.add_mesh(&self, AssetId asset, uint mesh, NodeId parent = NO_NODE, String name = "")
{
	return self.attach(parent, asset, mesh, name);
}

<*
 Place an asset's node hierarchy under `parent`, transforms and all.

 This is Three.js's `gltf.scene`, and until G3 there was no equivalent: the
 loader flattened the file and `MeshPass.place` dropped every mesh at the origin.
 A file that bakes its transforms into the vertices rendered correctly and one
 that positions its pieces by node did not — a distinction nothing in the API
 could express, so nothing in the suite could catch.

 **What a glTF node becomes is `Assets.flatten`'s decision, not this
 function's.** JavaScript's `asset.instantiate()` reads the same walk and builds
 `Object3D`s from it, and the two producing different trees for one file would be
 a bug nobody would think to look for. This is one pass over that answer.

 ## The references take care of themselves

 Every drawing node goes through `create_slot`, which retains the asset (G2). So
 a prop instantiated twice is two subtrees over one upload, and dropping one
 subtree releases exactly its own references — **the thesis at a level the API
 could not previously state**. Nothing here counts anything.

 @return `The group everything was placed under, or NO_NODE if the handle names no asset.`
*>
fn NodeId Scene.instantiate(&self, AssetId asset, NodeId parent = NO_NODE, String name = "")
{
	if (self.assets == null) return NO_NODE;
	Asset* loaded = self.assets.slot(asset);
	if (loaded == null) return NO_NODE;

	NodeId group = self.add_group(parent, name.len > 0 ? name : basename(loaded.path));

	List{PlacedNode} placed;
	placed.init(mem, 16);
	defer placed.free();
	self.assets.flatten(asset, &placed);

	// Parents precede their children in the walk, so `created` always has the
	// entry a child needs by the time the child is reached. One pass, no fixups.
	List{NodeId} created;
	created.init(mem, placed.len() + 1);
	defer created.free();

	foreach (&entry : placed)
	{
		NodeId into = entry.parent < 0 ? group : created[entry.parent];
		NodeId id = entry.mesh < 0
			? self.add_group(into, entry.name)
			: self.add_mesh(asset, (uint)entry.mesh, into, entry.name);

		Node* node = self.node(id);
		node.position = entry.position;
		node.rotation = entry.rotation;
		node.scale = entry.scale;
		// White unless the file instanced this copy and gave it a `_COLOR_0`.
		// Written unconditionally rather than only when it differs: `add_mesh`
		// already left it white, so the branch would save an assignment and cost
		// a comparison.
		node.color = entry.color;
		node.dirty = true;

		created.push(id);
	}

	self.start_player(asset, group, placed.array_view(), created.array_view());
	return group;
}

<*
 Give a freshly instantiated subtree its animation player, if the asset has
 anything to play.

 The map from glTF node index to `NodeId` can only be built here: `flatten`
 carries the glTF index on each entry and this walk is the only thing that knows
 what each entry became. Nothing else in the codebase has both halves, which is
 why this is not a method on `Assets`.

 **A player is created even though nothing is playing.** The alternative is
 building the map on the first `play`, which would mean walking the tree a second
 time — and `play` is called from an animation callback, where a hidden tree walk
 is the kind of cost that shows up as a stutter the first time a character moves.

 Nothing happens for an asset with no clips, so a scene of ten thousand crates
 holds no players at all.
*>
fn void Scene.start_player(&self, AssetId asset, NodeId root, PlacedNode[] placed, NodeId[] created)
{
	List{uint} sources;
	List{NodeId} nodes;
	sources.init(mem, placed.len);
	nodes.init(mem, placed.len);
	defer sources.free();
	defer nodes.free();

	foreach (i, &entry : placed)
	{
		if (entry.gltf_node < 0) continue;
		sources.push((uint)entry.gltf_node);
		nodes.push(created[i]);
	}

	self.bind_player(asset, root, sources.array_view(), nodes.array_view());
}

<*
 Give a subtree an animation player from a map somebody else built.

 Two callers and they arrive from opposite directions. `start_player` above has
 just walked `Assets.flatten` and knows which entry became which node.
 `asset.instantiate()` in JavaScript built the same tree as `Object3D`s and let
 the ordinary `add` path materialize them — so the host never saw the walk, and
 JavaScript is the only thing that knows the correspondence. Both end up here,
 which is why this takes the map as two plain arrays rather than anything
 either side would have to be taught about.

 Replaces an existing player on the same root rather than adding a second: two
 players over one subtree would both write to the same nodes every frame, and
 which one won would depend on list order.

 Nothing happens for an asset with no clips, so a scene of ten thousand crates
 holds no players at all.

 @param gltf_nodes : `The glTF node index each node came from, one per entry and the same length as the node array.`
*>
fn void Scene.bind_player(&self, AssetId asset, NodeId root, uint[] gltf_nodes, NodeId[] nodes)
{
	if (self.assets == null) return;
	Asset* loaded = self.assets.slot(asset);
	if (loaded == null || loaded.clips.len() == 0) return;

	self.drop_player(root);

	AnimationPlayer player = { .root = root, .asset = asset, .clip = -1, .speed = 1 };
	player.targets.init(mem, loaded.nodes.len());
	for (sz i = 0; i < loaded.nodes.len(); i++) player.targets.push(NO_NODE);

	foreach (i, source : gltf_nodes)
	{
		if (i >= nodes.len) break;
		if (source >= player.targets.len()) continue;
		player.targets[source] = nodes[i];
	}

	self.players.push(player);
}

<*
 Start a clip on an instantiated subtree.

 The clip's curves are read here rather than at load — `Assets.ensure_clip`, and
 `game.md` G3/S3's rule one level up: a file describes itself cheaply and pays
 when it is used. A character with eleven clips reads the one that plays.

 The instance is **posed immediately**, before any frame is stepped, so a prop
 placed and played in the same breath looks like its first frame rather than like
 its rest pose for one frame.

 @param speed : `A multiplier on time. Negative plays backwards, and a non-looping clip run backwards stops at its start.`
 @return `False if the subtree has no player or the asset has no clip by that name, which is a question rather than an error — mesh.animations is where the list lives.`
*>
fn bool Scene.play(&self, NodeId root, String clip, bool loop = true, float speed = 1.0f)
{
	if (self.assets == null) return false;
	AnimationPlayer* player = self.player(root);
	if (player == null) return false;

	Asset* loaded = self.assets.slot(player.asset);
	if (loaded == null) return false;

	int found = -1;
	foreach (i, &candidate : loaded.clips)
	{
		if (candidate.name == clip) { found = (int)i; break; }
	}
	if (found < 0) return false;

	self.assets.ensure_clip(player.asset, (uint)found);

	player.clip = found;
	player.speed = speed;
	player.loop = loop;
	player.playing = true;
	player.time = self.assets.slot(player.asset).clips[found].start;

	player.apply(self, &self.assets.slot(player.asset).clips[found]);
	return true;
}

<*
 Stop a clip where it is.

 Deliberately not a rewind: a character that stops mid-stride and snaps to its
 rest pose is the thing `stop()` is usually reached for to *prevent*. Playing
 something else is how you leave the pose.
*>
fn bool Scene.stop(&self, NodeId root)
{
	AnimationPlayer* player = self.player(root);
	if (player == null) return false;
	player.playing = false;
	return true;
}

<*
 Advance every playing clip by `dt` seconds.

 `game.md` G3/S6: this runs in the host frame **before** the animation callback,
 so a callback can read where a character got to, and so animation runs with no
 `setAnimationLoop` registered at all.

 @return `Whether anything is still playing, which the sleep condition in main.c3 has to know or the window sleeps in the middle of a walk cycle.`
*>
fn bool Scene.step_animations(&self, float dt)
{
	if (self.assets == null) return false;

	bool playing = false;
	foreach (&player : self.players)
	{
		player.advance(self, self.assets, dt);
		if (player.playing) playing = true;
	}
	return playing;
}

<*
 Whether any clip is playing, without stepping anything.

 The same question `step_animations` answers, asked by a frame that has not
 stepped yet — the sleep condition is evaluated after the step, but a caller
 deciding whether to *start* a frame needs it before.
*>
fn bool Scene.is_animating(&self)
{
	foreach (&player : self.players)
	{
		if (player.playing) return true;
	}
	return false;
}

<*
 The file name out of a path, for naming the group an instantiation lands in.

 A group called `props/crate.glb` is not wrong, only unreadable in a hierarchy
 dump; `crate.glb` is what a `console.log` of a scene wants to show.
*>
fn String basename(String path) @local
{
	usz start = 0;
	foreach (i, c : path)
	{
		if (c == '/' || c == '\\') start = (usz)i + 1;
	}
	return path[start..];
}

fn NodeId Scene.attach(&self, NodeId parent, AssetId asset, uint mesh, String name)
{
	if (!self.started) self.init();

	NodeId use_parent = parent.is_set() ? parent : self.root;
	if (self.node(use_parent) == null) use_parent = self.root;

	NodeId id = self.create_slot(use_parent, asset, mesh, name);
	if (use_parent.is_set())
	{
		// Re-resolved *after* create_slot, which may have grown the pool and
		// invalidated every Node* taken before it.
		Node* parent_node = self.node(use_parent);
		if (parent_node != null) parent_node.children.push(id);
	}
	return id;
}

fn NodeId Scene.create_slot(&self, NodeId parent, AssetId asset, uint mesh, String name)
{
	uint index;
	if (self.free_slots.len() > 0)
	{
		index = self.free_slots.pop()!!;
	}
	else
	{
		index = (uint)self.nodes.len();
		Node fresh;
		fresh.children.init(mem, 4);
		self.nodes.push(fresh);
	}

	Node* node = &self.nodes[index];

	// Everything but `children` and `generation`: the child list is reused
	// rather than freed and rebuilt, and the generation must keep climbing or a
	// stale id would come back valid the moment its slot was reused.
	uint generation = node.generation;
	node.children.clear();

	node.name = name.len > 0 ? name.copy(mem) : "";
	node.position = { 0, 0, 0 };
	node.rotation = NO_ROTATION;
	node.scale = { 1, 1, 1 };
	node.parent = parent;
	node.world = matrix::IDENTITY4{float};
	node.normal = matrix::IDENTITY4{float};
	node.asset = asset;
	node.mesh = mesh;
	// Reset like everything else here, and for a sharper reason: this slot may
	// have belonged to a node with a `ShaderMaterial`, and a new node inheriting
	// it would draw with a stranger's shader. `a_reused_slot_does_not_inherit_a_material`
	// is the check.
	node.material = DEFAULT_MATERIAL;
	// White and row zero: the identity for both channels, so a node that never
	// touches them draws exactly as it did before they existed. Reset here for
	// `material`'s reason — a recycled slot must not hand a new node the last
	// one's colour.
	node.color = { 1, 1, 1, 1 };
	node.variant = 0;
	node.visible = true;
	node.world_visible = true;
	node.dirty = true;
	node.generation = generation;
	node.alive = true;

	// One of the two halves of `Asset.refs` — see `attach_assets`. Counted after
	// the slot is fully written, so a table that somehow reads back into the
	// scene sees a consistent node.
	if (self.assets != null && asset.is_set()) self.assets.retain(asset, mesh);

	return { .index = index, .generation = generation };
}

<*
 Remove a node and everything under it.

 Removing the root empties the scene but keeps the root itself, so a `Scene` is
 never left without somewhere to add to.
*>
fn void Scene.remove(&self, NodeId id)
{
	Node* node = self.node(id);
	if (node == null) return;

	if (id == self.root)
	{
		// Copy first: killing a child mutates `children` under the iteration.
		NodeId[] children = node.children.to_tarray();
		foreach (child : children) self.kill(child);
		node.children.clear();
		return;
	}

	NodeId parent = node.parent;
	Node* parent_node = self.node(parent);
	if (parent_node != null)
	{
		foreach (i, sibling : parent_node.children)
		{
			if (sibling == id)
			{
				parent_node.children.remove_at(i);
				break;
			}
		}
	}
	self.kill(id);
}

fn void Scene.kill(&self, NodeId id)
{
	Node* node = self.node(id);
	if (node == null) return;

	NodeId[] children = node.children.to_tarray();
	foreach (child : children) self.kill(child);

	// Re-resolved: `to_tarray` allocated, and the recursion above touched the
	// pool through `self`.
	node = self.node(id);
	if (node == null) return;

	// The other half of `Asset.refs`. Every path out of the scene ends here —
	// `remove`, `Scene.remove(root)` for `new three.Scene()`, and the recursion
	// above for a whole subtree — so there is nowhere else a reference can be
	// dropped from.
	if (self.assets != null && node.asset.is_set()) self.assets.release(node.asset, node.mesh);

	// An instantiated subtree's player goes with the subtree's root. Guarded on
	// the list being non-empty rather than searched unconditionally, because
	// `kill` runs once per node of every removal and almost no scene has
	// players at all.
	if (self.players.len() > 0) self.drop_player(id);

	if (node.name.len > 0) node.name.free(mem);
	node.name = "";
	node.children.clear();
	node.alive = false;
	// The bump is what makes every outstanding id to this slot stale.
	node.generation++;
	self.free_slots.push(id.index);
}

<*
 Re-parent, keeping the node's *local* transform.

 Three.js's `add` does the same and it is worth being explicit about: the object
 does not stay where it was on screen, it stays where it was relative to its new
 parent. Preserving world position is a different operation and does not exist
 yet.
*>
fn void Scene.set_parent(&self, NodeId id, NodeId parent)
{
	if (id == self.root) return;
	Node* node = self.node(id);
	if (node == null) return;

	NodeId target = parent.is_set() ? parent : self.root;
	if (self.node(target) == null) return;
	if (target == id) return;

	// A cycle would make `update_branch` recur until the stack runs out, and the
	// stack running out is a much worse error message than nothing happening.
	NodeId walk = target;
	while (walk.is_set())
	{
		if (walk == id) return;
		Node* step = self.node(walk);
		if (step == null) break;
		walk = step.parent;
	}

	Node* old_parent = self.node(node.parent);
	if (old_parent != null)
	{
		foreach (i, sibling : old_parent.children)
		{
			if (sibling == id)
			{
				old_parent.children.remove_at(i);
				break;
			}
		}
	}

	node = self.node(id);
	node.parent = target;
	node.dirty = true;
	self.node(target).children.push(id);
}

// The transform setters. Each marks the node dirty; `update_world_matrices`
// carries that down to every descendant. Mutating `Scene.node(id).position`
// directly is legal and faster in a loop, but then `touch` is not optional.
fn void Scene.set_position(&self, NodeId id, Vec3 position)
{
	Node* node = self.node(id);
	if (node == null) return;
	node.position = position;
	node.dirty = true;
}

<*
 Euler angles in, quaternion stored. `node.c3`'s header has the why; the order
 is XYZ, Three.js's default.
*>
fn void Scene.set_rotation(&self, NodeId id, Vec3 rotation)
{
	Node* node = self.node(id);
	if (node == null) return;
	node.rotation = quat_from_euler(rotation);
	node.dirty = true;
}

<*
 A rotation that did not come from Euler angles: a glTF node's TRS, or a sampled
 animation channel.

 Normalized on the way in rather than trusted. A file may store a quaternion
 that has drifted, and `to_matrix` normalizes anyway — doing it here means the
 node's own value is the one everything else reads back, instead of a
 nearly-unit quaternion that produces a correct matrix and a wrong slerp.
*>
fn void Scene.set_quaternion(&self, NodeId id, Quaternionf rotation)
{
	Node* node = self.node(id);
	if (node == null) return;
	node.rotation = rotation.normalize();
	node.dirty = true;
}

fn void Scene.set_scale(&self, NodeId id, Vec3 scale)
{
	Node* node = self.node(id);
	if (node == null) return;
	node.scale = scale;
	node.dirty = true;
}

fn void Scene.set_visible(&self, NodeId id, bool visible)
{
	Node* node = self.node(id);
	if (node == null) return;
	node.visible = visible;
	// Visibility is inherited, and inheritance is resolved in the same walk the
	// world matrices are, so a change to it is a dirty node like any other.
	node.dirty = true;
}

<*
 Draw this node with a different material.

 No `dirty` flag, unlike `set_visible` and the transform setters. Those three
 feed the world-matrix walk, which caches its result; the material feeds the
 bucket key, and `build_draw_list` throws the whole draw list away and rebuilds
 it from scratch every frame. Setting a flag for it would be a flag nothing ever
 reads.

 The index is not validated here — `Scene` has no view of `MeshPass.materials`,
 and reaching for one would put the render pass inside the scene graph. The JS
 verb validates before it calls, and `MeshPass.record` skips a bucket whose
 material does not resolve.
*>
fn void Scene.set_material(&self, NodeId id, uint material)
{
	Node* node = self.node(id);
	if (node == null) return;
	node.material = material;
}

<*
 Tint one copy, without costing a draw call.

 Neither this nor `set_variant` marks the node dirty: `dirty` drives the
 world-matrix walk, and these two are copied into the instance record on every
 `build_draw_list` regardless. Marking it would be a wasted subtree traversal
 per colour change, which for a script recolouring a thousand nodes is a
 thousand of them.

 @param color : `Linear rgb and an alpha. Multiplies albedo; the alpha reaches shade() and is not blended with.`
*>
fn void Scene.set_color(&self, NodeId id, float[4] color)
{
	Node* node = self.node(id);
	if (node == null) return;
	node.color = color;
}

<*
 Point one copy at a row of its material's table.

 Not validated against the material here, and deliberately: a node may be given
 a variant before it is given the material that gives the number meaning, and
 the shader clamps against the row count it was compiled with — so the failure
 mode is the last row rather than a refusal at the wrong moment.
*>
fn void Scene.set_variant(&self, NodeId id, uint variant)
{
	Node* node = self.node(id);
	if (node == null) return;
	node.variant = variant;
}

<*
 Rename a node.

 The scene owns every name — `create_slot` copies what it is given and `kill`
 frees it — so this frees the old one before taking a copy of the new. Anything
 else would either leak on every rename or leave `Scene.free` freeing a string
 that came from somewhere else.
*>
fn void Scene.set_name(&self, NodeId id, String name)
{
	Node* node = self.node(id);
	if (node == null) return;
	if (node.name.len > 0) node.name.free(mem);
	node.name = name.len > 0 ? name.copy(mem) : "";
}

fn void Scene.touch(&self, NodeId id)
{
	Node* node = self.node(id);
	if (node != null) node.dirty = true;
}

<*
 Run `#body` for every alive node under `id`, depth first, with the node's id
 and a pointer to it.

 The pointer is invalid the moment anything is added, so a traversal that
 creates nodes has to collect ids first and add afterwards.
*>
macro Scene.@traverse(&self, NodeId id; @body(NodeId child_id, Node* node))
{
	NodeId[] stack_seed = { id };
	List{NodeId} stack;
	stack.tinit(32);
	stack.push_all(stack_seed[..]);

	while (stack.len() > 0)
	{
		NodeId current = stack.pop()!!;
		Node* node = self.node(current);
		if (node == null) continue;
		@body(current, node);
		foreach (child : node.children) stack.push(child);
	}
}

// ============================================================================
// World matrices
// ============================================================================

<*
 Recompute the world matrix of every node whose local transform changed, and of
 everything below it.

 Depth-first and recursive: a scene deep enough to overflow the stack is a scene
 with tens of thousands of levels of parenting, which is not a shape this API
 encourages and would be a different bug. Nothing may add or remove a node
 during the walk — `node.children` is iterated in place.
*>
fn void Scene.update_world_matrices(&self)
{
	if (!self.root.is_set()) return;
	self.update_branch(self.root, matrix::IDENTITY4{float}, true, false);
}

fn void Scene.update_branch(&self, NodeId id, Matrix4f parent_world, bool parent_visible, bool parent_changed)
{
	Node* node = self.node(id);
	if (node == null) return;

	bool changed = parent_changed || node.dirty;
	if (changed)
	{
		node.world = parent_world * node.local_matrix();
		node.normal = normal_matrix(node.world);
		node.dirty = false;
	}
	node.world_visible = parent_visible && node.visible;

	// Copied out before recursing: the children list is walked by index because
	// `self.node` inside the recursion may not reallocate, but reading through a
	// pointer taken before a call that takes `&self` is exactly the habit that
	// stops being safe the day something does.
	Matrix4f world = node.world;
	bool visible = node.world_visible;
	sz count = node.children.len();
	for (sz i = 0; i < count; i++)
	{
		NodeId child = self.nodes[id.index].children[i];
		self.update_branch(child, world, visible, changed);
	}
}

// ============================================================================
// Culling
// ============================================================================

struct Plane
{
	Vec3 normal;
	float distance;
}

struct Frustum
{
	Plane[6] planes;
}

<*
 The six clip planes of a view-projection matrix (Gribb & Hartmann).

 The near plane is row 2 alone rather than `w + z` because this projection is
 the Vulkan/D3D [0,1] depth convention, not OpenGL's [-1,1]. Using the OpenGL
 form here culls nothing that should be culled and is invisible until something
 far away disappears — which is why it is written down rather than inferred.

 `gpu/target.c3`'s negative-height viewport does not enter into this: it flips Y
 in the viewport transform, after clipping, so the planes derived from the
 matrix are the ones the hardware will actually use.
*>
fn Frustum frustum_of(Matrix4f m)
{
	float[<16>] v = m.m;
	// Rows of a column-major matrix.
	float[<4>] r0 = { v[0], v[4], v[8], v[12] };
	float[<4>] r1 = { v[1], v[5], v[9], v[13] };
	float[<4>] r2 = { v[2], v[6], v[10], v[14] };
	float[<4>] r3 = { v[3], v[7], v[11], v[15] };

	Frustum frustum;
	frustum.planes[0] = plane_of(r3 + r0); // left
	frustum.planes[1] = plane_of(r3 - r0); // right
	frustum.planes[2] = plane_of(r3 + r1); // bottom
	frustum.planes[3] = plane_of(r3 - r1); // top
	frustum.planes[4] = plane_of(r2); // near
	frustum.planes[5] = plane_of(r3 - r2); // far
	return frustum;
}

fn Plane plane_of(float[<4>] v) @local
{
	Vec3 normal = { v[0], v[1], v[2] };
	float length = normal.length();
	// A degenerate plane accepts everything rather than rejecting everything: a
	// cull that hides the scene is far worse than a cull that does nothing.
	if (length < 1e-8f) return { .normal = { 0, 0, 0 }, .distance = 1.0f };
	return { .normal = normal / length, .distance = v[3] / length };
}

<*
 Is any part of `box` on the inside of every plane?

 The "positive vertex" test: only the box corner furthest along each plane's
 normal has to be checked, because if that one is behind the plane they all are.
 False positives are possible near the corners of the frustum and are harmless —
 they cost a draw, not a wrong picture.
*>
fn bool Frustum.contains(&self, collision::Aabb3 box)
{
	foreach (&plane : self.planes)
	{
		Vec3 positive = {
			plane.normal.x >= 0 ? box.max.x : box.min.x,
			plane.normal.y >= 0 ? box.max.y : box.min.y,
			plane.normal.z >= 0 ? box.max.z : box.min.z,
		};
		if (plane.normal.dot(positive) + plane.distance < 0) return false;
	}
	return true;
}

<*
 A box in world space, given a local box and the matrix that places it.

 Transforms the centre and the half-extent rather than eight corners: the
 extent along each world axis is the absolute row of the linear part dotted with
 the local extent. Same answer, a third of the arithmetic, and it is the form
 that stays correct under a rotation *and* a non-uniform scale.
*>
fn collision::Aabb3 transform_aabb(Matrix4f m, collision::Aabb3 box)
{
	float[<16>] v = m.m;
	Vec3 centre = box.center();
	Vec3 extent = box.extent();

	Vec3 world_centre = {
		v[0] * centre.x + v[4] * centre.y + v[8] * centre.z + v[12],
		v[1] * centre.x + v[5] * centre.y + v[9] * centre.z + v[13],
		v[2] * centre.x + v[6] * centre.y + v[10] * centre.z + v[14],
	};
	Vec3 world_extent = {
		math::abs(v[0]) * extent.x + math::abs(v[4]) * extent.y + math::abs(v[8]) * extent.z,
		math::abs(v[1]) * extent.x + math::abs(v[5]) * extent.y + math::abs(v[9]) * extent.z,
		math::abs(v[2]) * extent.x + math::abs(v[6]) * extent.y + math::abs(v[10]) * extent.z,
	};

	return { .min = world_centre - world_extent, .max = world_centre + world_extent };
}

// ============================================================================
// The instance table
// ============================================================================

<*
 Bring the world matrices up to date and rebuild the draw list for a camera.

 @param view_projection : `What the frustum is derived from. Culling is skipped entirely when Scene.cull is false.`
*>
fn void Scene.update(&self, Assets* assets, Matrix4f view_projection)
{
	self.update_world_matrices();
	Frustum frustum = frustum_of(view_projection);
	self.build_draw_list(assets, self.cull ? &frustum : null);
}

// ----------------------------------------------------------------------------

<*
 Where a material sits in the frame, as opposed to what its index is.

 Identity everywhere except the line material, which sorts last however low its
 index is. `LINE_MATERIAL` is 1 — it has to be a small number, because it is
 built before any script can ask for a material and indices are handed out in
 order — and 1 would otherwise put every debug line *underneath* the scene it is
 drawn to explain.

 That would not look like an ordering bug. `LINE_STATE` writes no depth and tests
 none, so a line drawn first is simply painted over by the next opaque triangle
 and vanishes — which reads as "the helper did not work".
*>
fn uint draw_order(uint material) @local
{
	return material == LINE_MATERIAL ? 0xffffffffu : material;
}

<*
 Flatten, cull, sort by bucket key, and write one `Instance` per drawn node.

 The sort is what makes the bucketing exact rather than approximate: after it,
 every node sharing an `(asset, mesh)` key is contiguous, so a single linear
 scan produces the buckets and there is no map, no hash and no per-bucket
 allocation. It also means the cost is `n log n` in *instances* rather than
 anything in unique meshes — a scene of ten thousand distinct meshes buckets as
 cheaply as a scene of one repeated ten thousand times.
*>
fn void Scene.build_draw_list(&self, Assets* assets, Frustum* frustum)
{
	self.draws.clear();
	self.instances.clear();
	self.buckets.clear();
	self.culled = 0;

	foreach (slot, &node : self.nodes)
	{
		if (!node.alive || !node.world_visible) continue;
		if (!node.asset.is_set() || node.mesh == NO_MESH) continue;

		GpuMesh* mesh = assets.mesh(node.asset, node.mesh);
		if (mesh == null) continue;
		// Described but not on the device: since G3/S3 that means an upload that
		// failed, because a node cannot exist without having retained the mesh
		// and retaining is what uploads. It draws nothing, which is the same
		// answer a material whose texture would not decode gets.
		if (!mesh.uploaded) continue;

		if (frustum != null && !frustum.contains(transform_aabb(node.world, mesh.bounds)))
		{
			self.culled++;
			continue;
		}

		self.draws.push({
			.material = node.material,
			.key = bucket_key(node.asset.index, node.mesh),
			.slot = (uint)slot,
		});
	}

	if (self.draws.len() == 0) return;

	quicksort(self.draws.array_view(), fn int(Draw a, Draw b) {
		uint left = draw_order(a.material);
		uint right = draw_order(b.material);
		if (left < right) return -1;
		if (left > right) return 1;
		if (a.key < b.key) return -1;
		if (a.key > b.key) return 1;
		return 0;
	});

	// Deliberately not equal to the first draw, so the first iteration always
	// opens a bucket. `open_material` has to be part of that sentinel now: two
	// materials over one mesh are adjacent in the sort and share a key.
	ulong open = self.draws[0].key + 1;
	uint open_material = self.draws[0].material;
	foreach (draw : self.draws)
	{
		Node* node = &self.nodes[draw.slot];
		if (draw.key != open || draw.material != open_material)
		{
			open = draw.key;
			open_material = draw.material;
			// Read off the node rather than unpacked from the key, which only
			// carries the slot index. Every node in a bucket names the same
			// live asset, so any of them supplies the generation.
			self.buckets.push({
				.asset = node.asset,
				.mesh = node.mesh,
				.material = draw.material,
				.first = (uint)self.instances.len(),
				.count = 0,
			});
		}

		self.instances.push({
			.model = node.world,
			.normal = node.normal,
			.color = node.color,
			.variant = node.variant,
		});
		self.buckets[self.buckets.len() - 1].count++;
	}
}

fn ulong bucket_key(uint asset, uint mesh) @inline => ((ulong)asset << 32) | (ulong)mesh;

<*
 How many distinct meshes the buckets cover.

 Was `buckets.len()` until M5, when it stopped meaning that: one mesh drawn under
 two materials is two buckets and one mesh. `SceneStats`' own header predicted
 this — "they are reported separately now so that the day they diverge is not the
 day the field is added" — and the divergence is the point of the field.

 A quadratic scan rather than a set, because the buckets are sorted
 material-major and (asset, mesh) pairs are therefore not adjacent, and because
 the count is bucket-sized: a scene with two hundred distinct meshes does forty
 thousand integer compares once per `stats()` call, which is not a number worth a
 hash table and an allocation.
*>
fn uint count_unique_meshes(Bucket[] buckets)
{
	uint unique = 0;
	foreach (i, bucket : buckets)
	{
		bool seen = false;
		for (sz j = 0; j < i; j++)
		{
			if (buckets[j].asset.index == bucket.asset.index && buckets[j].mesh == bucket.mesh)
			{
				seen = true;
				break;
			}
		}
		if (!seen) unique++;
	}
	return unique;
}

<*
 The numbers, computed fresh with culling off.

 Deliberately not a read of the last frame's draw list: "1000 instances is one
 draw call" has to be a fact about the scene, not about where the camera was
 pointing when it was last asked. The side effect is that the draw list is left
 uncalled — the next `update` rebuilds it, which it would have done anyway.
*>
fn SceneStats Scene.stats(&self, Assets* assets)
{
	self.update_world_matrices();
	self.build_draw_list(assets, null);

	SceneStats stats = {
		.draw_calls = (uint)self.buckets.len(),
		.unique_meshes = count_unique_meshes(self.buckets.array_view()),
		.instances = (uint)self.instances.len(),
		.assets = assets.resident(),
		.textures = assets.texture_count(),
		.texture_bytes = assets.texture_bytes(),
		.culled_last_frame = self.culled,
	};

	foreach (&node : self.nodes)
	{
		if (node.alive) stats.nodes++;
	}

	foreach (bucket : self.buckets)
	{
		GpuMesh* mesh = assets.mesh(bucket.asset, bucket.mesh);
		if (mesh == null) continue;
		stats.triangles += (mesh.index_count / 3) * bucket.count;
		stats.vertices += mesh.vertex_count * bucket.count;
	}

	return stats;
}

<*
 The world-space bounds of everything drawable in the scene.

 What the camera frames on. Derived from instance bounds rather than from the
 assets' own, because an asset placed a kilometre from the origin is a
 kilometre from the origin.
*>
fn collision::Aabb3 Scene.bounds(&self, Assets* assets)
{
	self.update_world_matrices();

	bool found = false;
	collision::Aabb3 total;

	foreach (&node : self.nodes)
	{
		if (!node.alive || !node.asset.is_set() || node.mesh == NO_MESH) continue;
		GpuMesh* mesh = assets.mesh(node.asset, node.mesh);
		if (mesh == null) continue;

		collision::Aabb3 box = transform_aabb(node.world, mesh.bounds);
		if (!found)
		{
			total = box;
			found = true;
		}
		else
		{
			total.expand_by_aabb(box);
		}
	}

	if (!found) return { .min = { -1, -1, -1 }, .max = { 1, 1, 1 } };
	return total;
}

<*
 The world-space bounds of one subtree, its root included.

 `Scene.bounds` is this over everything and is what the camera frames on. The
 restricted form is what a *script* needs, and for a different reason: a kit
 piece's origin is wherever its exporter left it, so "put this window on that
 wall" is a question about where the piece's faces are, not about where its
 transform is. Without this the answer has to be carried into the script as a
 hand-copied table of sizes, which is a table that goes stale silently.

 Empty rather than unit-sized when nothing under `root` draws. `Scene.bounds`
 answers with a unit box in that case because the camera must point *somewhere*;
 here the caller asked about a specific subtree and "it has no size" is the
 truthful answer, which is why `found` is out-of-band rather than encoded as a
 degenerate box a caller would have to recognise.

 @param found : `Out. False when nothing under root draws — a Group of Groups, or a node whose mesh is not resident. The box is not written then.`
*>
fn collision::Aabb3 Scene.subtree_bounds(&self, Assets* assets, NodeId root, bool* found)
{
	self.update_world_matrices();

	collision::Aabb3 total;
	*found = false;
	self.grow_bounds(assets, root, &total, found);
	return total;
}

<*
 One node's contribution to `subtree_bounds`, then its children's.

 Copies the child list before recursing for `Scene.kill`'s reason: the walk
 reaches the node pool through `self`, and a `Node*` held across it is a pointer
 into a list that may have moved.
*>
fn void Scene.grow_bounds(&self, Assets* assets, NodeId id, collision::Aabb3* total, bool* found)
{
	Node* node = self.node(id);
	if (node == null || !node.alive) return;

	if (assets != null && node.asset.is_set() && node.mesh != NO_MESH)
	{
		GpuMesh* mesh = assets.mesh(node.asset, node.mesh);
		if (mesh != null)
		{
			collision::Aabb3 box = transform_aabb(node.world, mesh.bounds);
			if (!*found)
			{
				*total = box;
				*found = true;
			}
			else
			{
				total.expand_by_aabb(box);
			}
		}
	}

	NodeId[] children = node.children.to_tarray();
	foreach (child : children) self.grow_bounds(assets, child, total, found);
}
