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

 ## A quaternion here, Euler angles in JavaScript

 `m.rotation.y = Math.PI / 2` is what an agent who has memorized Three.js will
 write, so Euler angles have to be the API. They are not the *storage*: `Node`
 holds a quaternion, and `prelude.js` holds the Euler triple it was written from.

 That split is the whole trick, and it is why there is no second source of truth
 despite there being two representations. The Euler angles live on the
 JavaScript object, which is where they are read back from — so `rotation.z =
 2 * Math.PI` reads back as `2 * Math.PI` and not as `0`, exactly as in
 Three.js, because nothing ever converts backwards. The quaternion lives here,
 which is where rotations are composed, interpolated and — from G3 — sampled out
 of a glTF animation. Each side stores the form its own work needs and the
 conversion is one-way at the boundary (`js_set_transform`).

 It was Euler on both sides until G3, with `local_matrix` rebuilding
 `Rx·Ry·Rz` per node per frame. That is fine until something wants to *set* a
 rotation that did not come from Euler angles — a glTF node's TRS, or a sampled
 animation channel, both of which are quaternions. Converting those to Euler to
 store them and back to a matrix to use them is lossy at every gimbal-locked
 pose, and produces the class of bug that reads as "the arm flips once per
 cycle".
*>
module three;

import std::collections::list;
import std::math;
import std::math::vector;
import std::math::matrix;
import std::math::quaternion;

// A node that draws nothing — a group, or the scene root. `NO_ASSET` is an
// `AssetId` and lives in `scene/asset.c3` beside the handle it is the absence of.
const uint NO_MESH = uint::max;

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
	//
	// `rotation` is a quaternion and is always normalized; `quat_from_euler` is
	// the door Euler angles come in through. See the header for why it is not
	// stored as a triple.
	Vec3 position;
	Quaternionf rotation;
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
	//
	// A handle rather than an index since G2, because assets can be unloaded and
	// their slots reused. A node never outlives the asset it names — it holds a
	// reference for exactly as long as it is alive, and the sweep only takes
	// assets at zero — so the generation here is never the one that goes stale.
	// It is carried so that the handle a node hands *back* (to a raycast hit, to
	// the draw list) is a whole handle rather than half of one.
	AssetId asset;
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

	// Which of the asset's skins poses this node's mesh, or -1. The marker that
	// this is a character rather than a prop: it decides which box the node is
	// culled against and whether the draw sets a skin flag at all.
	int skin;

	// Where this node's joint matrices start, in matrices, with `POSE_LIVE` in the
	// top bit for a character posed from its bone nodes rather than from a baked
	// clip. Copied straight into `Instance.pose`.
	//
	// Seeded to the skin's rest offset, so a character that has never played
	// anything draws its bind pose — there is no "nothing is playing" case in the
	// shader or in the draw loop, because rest is a baked frame like any other.
	// `AnimationPlayer.advance` is what moves it afterwards.
	uint pose;

	<*
	 Whether the compute pass poses this node's vertices instead of the vertex
	 shader — `instantiate({ skinning: 'compute' })`.

	 **It splits the bucket**, which is the cost to know about before setting it:
	 pre-skinned vertices come out of a buffer the compute pass wrote, so a copy
	 with this set cannot share a `DrawRecord` with one that has not, and cannot
	 share a draw call either. It buys the blend being paid once per frame rather
	 than once per draw, which is worth nothing until the same character is drawn
	 in a second pass — see `shaders/skin.slang`, which says so at length.
	*>
	bool preskinned;

	<*
	 Whether this node is in the half of the shadow map that is drawn once and
	 kept — `mesh.static = true`, and `plan.md` §19.3.

	 **It does not split a draw bucket**, which is the difference between it and
	 `preskinned` one line up and the reason it can be set on ten thousand crates
	 without costing a draw call. It is a tiebreak in the sort rather than a key,
	 so it orders copies *inside* their bucket; `Bucket.static_first` is the
	 layout and the argument.

	 Off by default. A scene where everything is dynamic is exactly the renderer
	 as it was before this existed — the whole map is rebuilt every frame — and
	 guessing that a node is static because nothing has moved it *yet* is the one
	 way to get a building's shadow left behind after it moves.

	 `Scene.set_static_caster` is the only writer, and it refuses on a node the
	 compute skinning pass poses.
	*>
	bool static_caster;

	// `visible` is this node's own flag; `world_visible` is it AND every
	// ancestor's, resolved in the same walk that builds the world matrices.

	// Three.js hides a whole subtree by hiding its root, and a flat scan of the
	// node pool cannot see that on its own.
	bool visible;
	bool world_visible;
	bool dirty;

	<*
	 Whether this node is collision geometry.

	 **The flag that says a drawable is only a drawable** — `plan.md` §17. Every
	 mesh in the query index is swept against, so a pickup lying on a path was a
	 bollard and a field of grass was a fence; `trigger: true` does not help,
	 because that is a *physics* property and a sweep never sees a body. The
	 shape that worked without this was two nodes — the thing you can see, and
	 an invisible volume beside it — which is tolerable for one pickup and silly
	 for a hundred tufts.

	 On by default, because the surprising answer is a wall walked through
	 rather than a pickup that blocks. **Not inherited**, unlike `visible`: it
	 describes one piece of geometry rather than a subtree, and a script hiding
	 a whole character from one sweep wants `IgnoreSet`, which is per call.

	 `Scene.set_collides` is the only writer, and it drops the query index —
	 this is filed out at build time rather than tested at answer time, so
	 changing it is a rebuild. That is the right way round for a flag set when a
	 level is authored, and the wrong way round for one toggled per frame.
	*>
	bool collides;

	// Slot bookkeeping. `generation` is bumped when the slot is reused, which is
	// what makes a stale NodeId detectable rather than silently valid.
	uint generation;
	bool alive;
}

<*
 The local transform, scale-first.

 `Matrix4x4.translate`/`mul`/`scale` all post-multiply, so this chain reads left
 to right as T·R·S and applies right to left to a vertex: scaled, then rotated,
 then moved. Any other order makes a rotated non-uniform scale shear, which looks
 like a broken mesh rather than a wrong multiply.
*>
fn Matrix4f Node.local_matrix(&self)
{
	return matrix::IDENTITY4{float}
		.translate(self.position)
		.mul(self.rotation.to_matrix())
		.scale(self.scale);
}

<*
 Three.js's default Euler order, XYZ, as a quaternion.

 The order is a promise this API makes, not a detail: `plan.md` §4 says a name
 means what it means in Three.js or it is not called that, and `rotation.x`
 followed by `rotation.y` composing in the other order is a rotation that looks
 right at 90° and wrong everywhere else. `std::math::quaternion::from_euler`
 exists and is deliberately not used — it documents itself as ZYX, which is the
 opposite composition and would silently disagree with every Three.js snippet an
 agent pastes in.

 XYZ names the *intrinsic* order, so the composed rotation is `Rx · Ry · Rz` and
 the Z rotation is the one a vertex meets first. That is what `local_matrix`
 built by hand before G3, and `euler_order_survived_the_quaternion` in
 `scene_test` is the check that it still does — a numeric comparison against the
 exact `rotate_x().rotate_y().rotate_z()` chain this replaced.
*>
fn Quaternionf quat_from_euler(Vec3 euler)
{
	// Half angles: a quaternion rotates by twice its own angle.
	float cos_x = math::cos(euler.x * 0.5f);
	float sin_x = math::sin(euler.x * 0.5f);
	float cos_y = math::cos(euler.y * 0.5f);
	float sin_y = math::sin(euler.y * 0.5f);
	float cos_z = math::cos(euler.z * 0.5f);
	float sin_z = math::sin(euler.z * 0.5f);

	return {
		sin_x * cos_y * cos_z + cos_x * sin_y * sin_z,
		cos_x * sin_y * cos_z - sin_x * cos_y * sin_z,
		cos_x * cos_y * sin_z + sin_x * sin_y * cos_z,
		cos_x * cos_y * cos_z - sin_x * sin_y * sin_z,
	};
}

<*
 The other direction: a quaternion as XYZ Euler angles, for handing a rotation
 to JavaScript.

 **Deliberately the only place that converts backwards**, and it exists for one
 reason: `asset.instantiate()` builds `Object3D`s, an `Object3D`'s `rotation` is
 an Euler triple, and a glTF node's rotation is a quaternion. Nothing on the
 host round-trips through this — see the header for why that matters.

 The decomposition is not unique and does not need to be. `quat_from_euler` of
 what this returns reproduces the *rotation*, which is what anything downstream
 can observe; the individual angles are one of several triples that name it, and
 at the singularity — the pitch at ±90° where X and Z become the same axis — the
 split between them is arbitrary. Three.js resolves it the same way, by giving
 the whole turn to X.

 Via the matrix rather than directly from the components, because that is the
 form in which the singularity is a single readable comparison instead of three.
*>
fn Vec3 euler_from_quat(Quaternionf rotation)
{
	Matrix4f m = rotation.to_matrix();

	// Column-major, so `m13` — row 1, column 3 — is element 8. The quaternion's
	// own `to_matrix` and Three.js's agree element for element, which is what
	// makes the case analysis below transplantable.
	float m13 = m.m[8];
	float y = math::asin(m13 < -1.0f ? -1.0f : (m13 > 1.0f ? 1.0f : m13));

	if (math::abs(m13) < 0.9999999f)
	{
		return { math::atan2(-m.m[9], m.m[10]), y, math::atan2(-m.m[4], m.m[0]) };
	}
	return { math::atan2(m.m[6], m.m[5]), y, 0 };
}

// A rotation of nothing. Named because `{ 0, 0, 0, 1 }` at a call site is the
// kind of literal that gets typed as `{ 0, 0, 0, 0 }` once and then normalizes
// to garbage.
const Quaternionf NO_ROTATION = { 0, 0, 0, 1 };

// White, and the same argument: `Node.color` multiplies albedo, so the identity
// is four ones and a zeroed struct literal is a node that draws black. Every
// place that fills in a colour it was not given says this rather than counting
// braces.
const float[4] NO_TINT = { 1, 1, 1, 1 };

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
