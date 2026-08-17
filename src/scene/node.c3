<*
 `Object3D`: a parent, a child list, a local TRS, a cached world matrix and a
 dirty flag. **Nothing else holds geometry** (`plan.md` §2) — a node that draws
 does it by naming an asset and a mesh inside it, never by owning vertices.
 That single refusal is what makes the instance table possible at all: N nodes
 pointing at one mesh are N transforms and one upload, by construction rather
 than by an optimisation pass.

 ## Nodes are addressed by id, not by pointer

 `Scene` owns every node in one `List`, so a `Node*` is invalidated the moment
 another node is created. Every reference between nodes is therefore a `NodeId`
 — an index and a generation — and `Scene.node` is the only way to turn one into
 a pointer.

 The generation is not defensive clutter. `plan.md` §1 requires that a JS handle
 revalidates on every access and *throws* rather than dereferencing a freed node,
 and a bare index cannot tell "slot 7" from "slot 7 after something else was put
 in it". Paying for it here means the M3 binding is a lookup rather than a
 lifetime redesign.

 ## Euler angles, in Three.js's order

 `rotation` is XYZ Euler in radians because `m.rotation.y = Math.PI / 2` is what
 an agent that has memorized Three.js will write. Three.js keeps a quaternion
 beside it and syncs the two; that is worth copying when there is something to
 interpolate, and is nothing but a second source of truth until then.
*>
module three;

import std::collections::list;
import std::math;
import std::math::vector;
import std::math::matrix;

// A node that draws nothing — a group, or the scene root.
const uint NO_ASSET = uint::max;
const uint NO_MESH  = uint::max;

<*
 A handle to a node in a particular `Scene`.

 Ids from one scene mean nothing in another; there is no tagging to catch that
 because a scene is not a thing an agent juggles two of. Staleness *within* a
 scene is caught, and that is the case that actually happens.
*>
struct NodeId
{
	uint index;
	uint generation;
}

const NodeId NO_NODE = { uint::max, 0 };

fn bool NodeId.is_set(self) => self.index != uint::max;
fn bool NodeId.equals(self, NodeId other) @operator(==) => self.index == other.index
	&& self.generation == other.generation;

struct Node
{
	String name;

	// The local transform. Applied scale-first, then rotation, then translation
	// — `local_matrix` is where that order is written down.
	Vec3 position;
	Vec3 rotation; // XYZ Euler, radians
	Vec3 scale;

	NodeId parent;
	List{NodeId} children;

	// Cached. Recomputed by `Scene.update_world_matrices` when this node is
	// dirty or an ancestor was.
	Matrix4f world;
	// The inverse transpose of `world`. Only the upper 3x3 means anything; the
	// rest is identity padding so the GPU record is two `float4x4` and needs no
	// packing rules of its own. See `normal_matrix`.
	Matrix4f normal;

	// What this node draws. `mesh` indexes that asset's `meshes`; a group
	// carries NO_ASSET and is traversed but never drawn.
	uint asset;
	uint mesh;

	// How this node draws. Indexes `MeshPass.materials`; `DEFAULT_MATERIAL` is
	// the built-in shader every node starts on, and it is a shared index rather
	// than a per-node copy because `a_thousand_instances_are_one_draw_call`
	// stops being true the moment two nodes with the same mesh disagree here.
	//
	// Deliberately *not* inherited, unlike `visible`. Three.js resolves a
	// child's material entirely on the child, and `plan.md` §4's rule is that a
	// name means what it means in Three.js or it is not called that. The
	// mechanism to inherit exists and is nearly free — `world_visible` is
	// recomputed on every walk anyway — so this is a semantic choice, not a cost
	// one.
	uint material;

	// The two per-copy channels, written straight into this node's `Instance`
	// and read by `SV_InstanceID`. **They are what a node may disagree with its
	// neighbours about without costing a draw call** — everything else that
	// changes how a mesh looks is bucket state. See `Instance`.
	//
	// Not inherited, for `material`'s reason: a name Three.js resolves on the
	// object itself is not one to resolve up the tree here.
	float[4] color;
	uint variant;

	// `visible` is this node's own flag; `world_visible` is it AND every
	// ancestor's, resolved in the same walk that builds the world matrices.
	// Three.js hides a whole subtree by hiding its root, and a flat scan of the
	// node pool cannot see that on its own.
	bool visible;
	bool world_visible;
	bool dirty;

	// Slot bookkeeping. `generation` is bumped when the slot is reused, which is
	// what makes a stale NodeId detectable rather than silently valid.
	uint generation;
	bool alive;
}

<*
 The local transform, scale-first.

 `Matrix4x4.translate`/`rotate_*`/`scale` all post-multiply, so this chain reads
 left to right as T·R·S and applies right to left to a vertex: scaled, then
 rotated, then moved. Any other order makes a rotated non-uniform scale shear,
 which looks like a broken mesh rather than a wrong multiply.
*>
fn Matrix4f Node.local_matrix(&self)
{
	return matrix::IDENTITY4{float}
		.translate(self.position)
		.rotate_x(self.rotation.x)
		.rotate_y(self.rotation.y)
		.rotate_z(self.rotation.z)
		.scale(self.scale);
}

<*
 Where this node ended up, in world space. Valid after
 `Scene.update_world_matrices`.
*>
fn Vec3 Node.world_position(&self) => { self.world.m[12], self.world.m[13], self.world.m[14] };

<*
 The matrix a normal has to be transformed by: the inverse transpose of the
 world matrix's linear part.

 **Not the upper 3x3 of the world matrix**, which is the shortcut that renders
 fine and lights wrong. It is only correct for rotation and uniform scale, and
 the API deliberately allows `scale.set(1, 2, 1)` — under which the shortcut
 leaves normals no longer perpendicular to the surface, so a stretched object is
 lit as though it were not. Nothing about that reads as an error: the geometry is
 the right shape and the shading is subtly wrong.

 `std::math::matrix` has no `inverse`, so this is `adjoint / determinant`, whose
 transpose is what a normal wants. A singular linear part — any scale component
 of zero — has no inverse at all and falls back to identity rather than to NaNs
 that would propagate into the colour.
*>
fn Matrix4f normal_matrix(Matrix4f world)
{
	Matrix3f linear = { .m = {
		world.m[0], world.m[1], world.m[2],
		world.m[4], world.m[5], world.m[6],
		world.m[8], world.m[9], world.m[10],
	} };

	float det = linear.determinant();
	if (math::abs(det) < 1e-8f) return matrix::IDENTITY4{float};

	Matrix3f adjugate = linear.adjoint();
	Matrix3f inverse_transpose = adjugate.transpose();
	inverse_transpose = inverse_transpose * (1.0f / det);

	float[<9>] n = inverse_transpose.m;
	return { .m = {
		n[0], n[1], n[2], 0,
		n[3], n[4], n[5], 0,
		n[6], n[7], n[8], 0,
		0, 0, 0, 1,
	} };
}

<*
 The inverse of a world matrix, for taking a ray from world space into an
 instance's own space (`scene/pick.c3`).

 `std::math::matrix` stops at `adjoint` and `determinant`, and the inverse is
 their quotient. A singular matrix returns identity — a raycast against a
 zero-scaled instance should miss, not produce NaN coordinates that then compare
 false against every subsequent hit and silently win.
*>
fn Matrix4f invert(Matrix4f m)
{
	float det = m.determinant();
	if (math::abs(det) < 1e-12f) return matrix::IDENTITY4{float};
	Matrix4f adjugate = m.adjoint();
	return adjugate * (1.0f / det);
}
