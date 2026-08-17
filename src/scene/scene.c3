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
import collision;

<*
 One instance, exactly as the GPU reads it. Mirrored in `shaders/mesh.slang`.

 128 bytes: two `float4x4` under scalar layout, which is 4-byte aligned, so an
 array of these is tightly packed and indexable by `SV_InstanceID` with no
 padding rules to get wrong. `normal` carries the inverse transpose in its upper
 3x3 — see `normal_matrix` for why the model matrix will not do.
*>
struct Instance
{
	Matrix4f model;
	Matrix4f normal;
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
	uint asset;
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
	self.draws.init(mem, 64);
	self.instances.init(mem, 64);
	self.buckets.init(mem, 16);

	self.cull = true;
	self.started = true;
	self.root = self.create_slot(NO_NODE, NO_ASSET, NO_MESH, "root");
	return self;
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

 @param asset : `Index into Assets.assets.`
 @param mesh : `Index into that asset's meshes.`
*>
fn NodeId Scene.add_mesh(&self, uint asset, uint mesh, NodeId parent = NO_NODE, String name = "")
{
	return self.attach(parent, asset, mesh, name);
}

fn NodeId Scene.attach(&self, NodeId parent, uint asset, uint mesh, String name)
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

fn NodeId Scene.create_slot(&self, NodeId parent, uint asset, uint mesh, String name)
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
	node.rotation = { 0, 0, 0 };
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
	node.visible = true;
	node.world_visible = true;
	node.dirty = true;
	node.generation = generation;
	node.alive = true;

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

fn void Scene.set_rotation(&self, NodeId id, Vec3 rotation)
{
	Node* node = self.node(id);
	if (node == null) return;
	node.rotation = rotation;
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
		if (node.asset == NO_ASSET || node.mesh == NO_MESH) continue;

		GpuMesh* mesh = assets.mesh(node.asset, node.mesh);
		if (mesh == null) continue;

		if (frustum != null && !frustum.contains(transform_aabb(node.world, mesh.bounds)))
		{
			self.culled++;
			continue;
		}

		self.draws.push({
			.material = node.material,
			.key = bucket_key(node.asset, node.mesh),
			.slot = (uint)slot,
		});
	}

	if (self.draws.len() == 0) return;

	quicksort(self.draws.array_view(), fn int(Draw a, Draw b) {
		if (a.material < b.material) return -1;
		if (a.material > b.material) return 1;
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
		if (draw.key != open || draw.material != open_material)
		{
			open = draw.key;
			open_material = draw.material;
			self.buckets.push({
				.asset = (uint)(draw.key >> 32),
				.mesh = (uint)(draw.key & 0xffffffff),
				.material = draw.material,
				.first = (uint)self.instances.len(),
				.count = 0,
			});
		}

		Node* node = &self.nodes[draw.slot];
		self.instances.push({ .model = node.world, .normal = node.normal });
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
			if (buckets[j].asset == bucket.asset && buckets[j].mesh == bucket.mesh)
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
		.textures = (uint)assets.textures.len(),
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
		if (!node.alive || node.asset == NO_ASSET || node.mesh == NO_MESH) continue;
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
