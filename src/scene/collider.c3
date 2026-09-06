<*
 What a file says collides — `KHR_physics_rigid_bodies` and `KHR_implicit_shapes`
 read at load.

 Every drawable mesh here is collision geometry by default, which is the right
 answer for a scene a script builds and the wrong one for a level: 449 of the
 Evil Forest's 580 colliders are plants, and a character sweep gathers every
 triangle of every one of them. The fix is not a flag on the plants. It is the
 model every engine uses, where **nothing collides unless it was authored to**,
 and glTF already has the words for it — a node's `collider` is a mesh, a convex
 hull or an implicit box, sphere, capsule or cylinder; a `motion` makes it a
 body; `trigger` makes it a volume; `joint` makes it a constraint.

 So this is the file's half of the statement, read once at load and applied by
 `instantiate(name, { physics: true })`. Without the option nothing here is
 consulted and a file draws and collides exactly as it always did.

 ## Descriptions, not bodies

 Same bargain `AssetLight` strikes: what the file says is recorded, and what to
 do about it is a policy over the record. `asset.colliders` is what the policy
 reads, and `asset.js`'s `_placePhysics` is one policy over it — a script is
 free to write another.

 ## A shape that is not the drawing gets a proxy mesh

 A box collider on a barrel is a shape with no triangles, and nothing here can
 be in the spatial index without a mesh and a BVH. So each distinct implicit
 shape in the file becomes one low-poly `GpuMesh` on the asset — twelve
 triangles for a box, a modest lathe for the round three — and each node
 carrying that shape gets a child placed on it, flagged `collision_only` so the
 draw list steps over it and the index files it. That is where the soldiers
 become capsules and the barrels boxes.

 The proxy is built in the shape's own units and the child sits at identity, so
 the node's world transform scales it exactly as `Gltf.collider_world_shape`
 composes it.

 **A convex hull is a proxy too**, for the same reason from the other end: the
 file said the collision shape is the hull of the drawn triangles, and a hull is
 both smaller and simpler than the drawing — a rock of four thousand triangles is
 a hull of forty, and it is convex where the drawing is not. `hull_proxy` builds
 it with `build_convex`, which is `collision::quickhull` and is the same routine
 behind `three.physics.add({ shape: 'hull' })` and `ConvexGeometry`, so what a
 body rests on and what a sweep hits are one hull built once.

 Only a mesh collider is still swept as the drawing, which is what a mesh
 collider means.
*>
module three;

import std::math;
import std::math::vector;
import std::collections::list;
import gltf;

<*
 What a node's collider is made of.

 The two halves of glTF's own split: `MESH` and `HULL` are the drawn geometry
 (`geometry.mesh`, or `geometry.node` naming a node that draws), and the other
 four are `KHR_implicit_shapes` primitives that draw nothing.

 `HULL` is the file's `convexHull: true`, and it gets a proxy of its own — the
 hull of the drawn triangles, built at load by `hull_proxy` — so the index holds
 the shape the file named rather than the drawing it was measured from. `MESH` is
 the one shape that is still swept as the drawing, which is what it means.
*>
enum AssetShape : char
{
	MESH,
	HULL,
	BOX,
	SPHERE,
	CAPSULE,
	CYLINDER,
}

fn bool AssetShape.is_implicit(self) => self != AssetShape.MESH && self != AssetShape.HULL;

<*
 One node's `KHR_physics_rigid_bodies` block, as the file states it.

 A collider, a motion, or both — a node can carry a motion with no collider (a
 compound body's parent) and a collider with no motion (a wall). `shape` is only
 meaningful when `has_collider`.

 Units are the file's throughout, because translating them here would put the
 convention in two places: `three.physics.add` takes mass in kilograms and
 friction 0..1 and so does glTF.
*>
struct AssetBody
{
	// The glTF node this hangs on, and what a consumer matches an instantiated
	// object against.
	int gltf_node;

	// Whose mesh the collision geometry is. The same node in everything the
	// Blender addon writes — glTF's `geometry.mesh` is the node's own — and a
	// different one for the spec's other spelling, `geometry.node`, which points
	// at a node that draws the collision hull beside the art.
	int geometry_node;

	// The proxy node's name — `"<node>.collider"` — owned here, because
	// `PlacedNode.name` borrows from the asset and a name built per placement
	// would have nobody to free it.
	String name;

	AssetShape shape;
	bool has_collider;
	bool trigger;

	bool has_motion;
	bool kinematic;
	float mass;
	float gravity_factor;
	float linear_damping;
	float angular_damping;
	Vec3 linear_velocity;
	Vec3 angular_velocity;

	// `physicsMaterial`, or false and this engine's own defaults.
	bool has_material;
	float friction;
	float restitution;

	// The implicit shape, in its own units. `size` is a box's full extent; the
	// round three carry a height and radii, with `radius` the sphere's.
	Vec3 size;
	float radius;
	float height;
	float radius_top;
	float radius_bottom;

	// Index into `Asset.meshes` for the shape's proxy — an implicit shape's, or a
	// convex hull's. -1 for a mesh collider, for a file loaded into a runtime with
	// no device to upload one to, and for a hull whose points enclose no volume.
	//
	// It is also what decides the index: a body with a proxy is swept as the proxy
	// and its drawing is out — see `Assets.flatten_node`.
	int proxy;

	// The file named a `collisionFilter`. Reported rather than applied: this
	// solver has no layers or masks to put one in.
	bool filtered;
}

<*
 One limit of a joint, in the shape `three.physics.joint` already takes.

 `axes` is a bit mask — axis 0 is bit 1 — which is what the JS side packs and
 the host reads, so a limit out of a file and one written by hand are the same
 six numbers.
*>
struct AssetJointLimit
{
	// 0 linear, 1 angular. glTF states one limit over both and the solver takes
	// them apart, so the split happens here.
	uint kind;
	uint axes;
	float min;
	float max;
	float stiffness;
	float damping;
}

<*
 One `joint` block: which two nodes it holds and how.

 glTF puts the joint on a *pivot* node parented to body A and names a second
 pivot parented to body B, so both ends are known by their pivots and the bodies
 are their parents. Resolved here rather than by the consumer, because the
 parent chain is the asset's and the consumer only has the instantiated tree.
*>
struct AssetJoint
{
	// The two bodies, as glTF node indices, or -1 when the pivot has no parent
	// to belong to.
	int body_a;
	int body_b;
	// Where the joint sits, in the file's world space — the pivot node's own
	// placement, which is what `three.physics.joint`'s `pivot` takes.
	Vec3 pivot;
	bool collide;
	List{AssetJointLimit} limits;
}

<*
 How round a collision proxy is.

 Twelve triangles for a box and this many segments around the round three: a
 proxy is swept against, not looked at, and every extra ring is triangles
 gathered on every sweep whose box overlaps it. Sixteen around and four up a cap
 is 256 triangles for a capsule, against the 10,000 of the soldier it stands in
 for.
*>
const uint COLLIDER_PROXY_SEGMENTS = 16;
const uint COLLIDER_PROXY_RINGS = 4;

<*
 Read the file's physics into the asset, and build a proxy for every implicit
 shape it uses.

 Runs after `record_nodes`, because it writes `AssetNode.body` — and because a
 joint has to resolve a pivot's parent, which is the tree.

 **Nothing here can fail.** A collider naming a shape the file does not have, or
 a node index past the end, leaves that node without a body rather than failing
 the load — the same bargain `record_nodes` strikes with a broken mesh index.

 @param gpu : `Null in a runtime with no device; the shapes are then recorded without proxies and only the mesh colliders reach the index.`
*>
fn void Assets.record_physics(&self, Gpu* gpu, Asset* asset, gltf::GltfStream* stream)
{
	gltf::Gltf* doc = &stream.gltf;
	if (doc.colliders.len() == 0 && doc.motions.len() == 0) return;

	asset.bodies.init(mem, doc.colliders.len() + 4);
	asset.has_physics = true;

	// One proxy per distinct shape, not per node: a level of forty barrels
	// authored from one mesh has one box in `KHR_implicit_shapes` and gets one
	// twelve-triangle mesh here.
	int[] proxy_for_shape;
	sz shape_count = doc.shapes.len();
	if (shape_count > 0)
	{
		proxy_for_shape = mem::new_array(int, (usz)shape_count);
		foreach (i, unused : proxy_for_shape) proxy_for_shape[i] = -1;
	}
	defer if (shape_count > 0) free(proxy_for_shape);

	// The same, per glTF mesh, for the hulls: forty crates authored from one mesh
	// are one quickhull.
	int[] hull_for_mesh;
	sz mesh_count = doc.meshes.len();
	if (mesh_count > 0)
	{
		hull_for_mesh = mem::new_array(int, (usz)mesh_count);
		foreach (i, unused : hull_for_mesh) hull_for_mesh[i] = -1;
	}
	defer if (mesh_count > 0) free(hull_for_mesh);

	foreach (index, &source : doc.nodes)
	{
		if (!source.has_collider() && !source.has_motion()) continue;
		if (index >= asset.nodes.len()) continue;

		AssetBody body = {
			.gltf_node = (int)index,
			.geometry_node = (int)index,
			.proxy = -1,
			.gravity_factor = 1.0f,
			.mass = 1.0f,
		};
		body.name = collider_name(source.name);

		if (source.has_collider())
		{
			gltf::Collider* collider = &doc.colliders[(uint)source.collider];
			body.has_collider = true;
			body.trigger = collider.is_trigger;
			body.filtered = collider.has_filter();
			body.shape = collider.convex_hull ? AssetShape.HULL : AssetShape.MESH;

			if (collider.has_material() && collider.material < doc.physics_materials.len())
			{
				gltf::PhysicsMaterial* surface = &doc.physics_materials[(uint)collider.material];
				body.has_material = true;
				// One friction, because the solver holds one. glTF's static and
				// dynamic coefficients are the same number in everything the addon
				// writes, and the dynamic one is what a body sliding actually feels.
				body.friction = surface.dynamic_friction;
				body.restitution = surface.restitution;
			}

			// `geometry.node`: the collision geometry is somewhere else in the
			// tree. The node that draws it is what has to be in the index, so the
			// body is filed there as well as here — and the node that owns the
			// collider keeps its own art out of the index, which is the whole
			// reason a file spells it this way.
			if (collider.has_node() && collider.node < (int)asset.nodes.len())
			{
				body.geometry_node = collider.node;
				if (asset.nodes[(uint)collider.node].body < 0)
				{
					asset.nodes[(uint)collider.node].body = (int)asset.bodies.len();
				}
			}

			if (collider.has_shape() && collider.shape < shape_count)
			{
				gltf::Shape shape = doc.shapes[(uint)collider.shape];
				read_implicit_shape(&body, shape);
				body.proxy = shape_proxy(self, gpu, asset, shape, proxy_for_shape, collider.shape);
			}
			else if (collider.convex_hull && body.geometry_node == (int)index)
			{
				// The collider's own mesh where the file names one, and the node's
				// otherwise. A hull on a `geometry.node` collider is left as the
				// drawing: the proxy is a child of the node it is placed on, and
				// that spelling puts the geometry somewhere else in the tree.
				int mesh = collider.has_mesh() ? collider.mesh : source.mesh;
				body.proxy = hull_proxy(self, gpu, asset, stream, mesh, hull_for_mesh);
			}
		}

		if (source.has_motion())
		{
			gltf::Motion* motion = &doc.motions[(uint)source.motion];
			body.has_motion = true;
			body.kinematic = motion.is_kinematic;
			body.mass = motion.mass;
			body.gravity_factor = motion.gravity_factor;
			body.linear_damping = motion.linear_dampening;
			body.angular_damping = motion.angular_dampening;
			body.linear_velocity = motion.linear_velocity;
			body.angular_velocity = motion.angular_velocity;
		}

		asset.nodes[index].body = (int)asset.bodies.len();
		asset.bodies.push(body);
	}

	record_joints(asset, doc);
}

<*
 A proxy mesh's name, `"<node>.collider"`, or `"collider"` for an unnamed node.

 Owned by the `AssetBody`, freed with the asset.
*>
fn String collider_name(String node) @local
{
	if (node.len == 0) return "collider".copy(mem);
	return string::format(mem, "%s.collider", node);
}

// The shape's numbers, in its own units. Cylinder and capsule share the height
// and the two radii; a sphere has only its radius.
fn void read_implicit_shape(AssetBody* body, gltf::Shape shape) @local
{
	switch (shape.type)
	{
		case BOX:
			body.shape = AssetShape.BOX;
			body.size = shape.size;
		case SPHERE:
			body.shape = AssetShape.SPHERE;
			body.radius = shape.radius;
		case CAPSULE:
			body.shape = AssetShape.CAPSULE;
			body.height = shape.height;
			body.radius_top = shape.radius_top;
			body.radius_bottom = shape.radius_bottom;
			body.radius = math::max(shape.radius_top, shape.radius_bottom);
		case CYLINDER:
			body.shape = AssetShape.CYLINDER;
			body.height = shape.height;
			body.radius_top = shape.radius_top;
			body.radius_bottom = shape.radius_bottom;
			body.radius = math::max(shape.radius_top, shape.radius_bottom);
	}
}

<*
 The proxy mesh for one shape index, built on first use and cached.

 @return `An index into the asset's own meshes, or -1 when there is no device or the shape has no size worth a mesh.`
*>
fn int shape_proxy(
	Assets* assets,
	Gpu* gpu,
	Asset* asset,
	gltf::Shape shape,
	int[] cache,
	int index
) @local
{
	if (gpu == null || index < 0 || index >= cache.len) return -1;
	if (cache[index] >= 0) return cache[index];

	GeometryBuilder geometry;
	geometry.init();
	defer geometry.free();
	build_shape_proxy(&geometry, shape);
	if (geometry.indices.len() == 0) return -1;

	GpuMesh? built = assets.upload_geometry(gpu, shape_label(shape.type), &geometry);
	if (catch built) return -1;

	int at = (int)asset.meshes.len();
	asset.meshes.push(built);
	cache[index] = at;
	return at;
}

<*
 The convex hull of one glTF mesh, built on first use and cached.

 The positions come out of the stream rather than off `GpuMesh.hull_positions`,
 because a mesh has none until something draws it and this runs at load. One pass
 over the mesh's POSITION accessors per distinct hull, and a file authors hulls in
 tens.

 @return `An index into the asset's own meshes, or -1 when there is no device, no mesh, too many points to hull, or a cloud that encloses no volume.`
*>
fn int hull_proxy(
	Assets* assets,
	Gpu* gpu,
	Asset* asset,
	gltf::GltfStream* stream,
	int index,
	int[] cache
) @local
{
	if (gpu == null || index < 0 || index >= cache.len) return -1;
	if (cache[index] >= 0) return cache[index];

	int at = -1;
	@pool()
	{
		List{Vec3} points;
		points.tinit(256);

		gltf::Mesh mesh = stream.gltf.meshes[(uint)index];
		foreach (primitive : mesh.primitives)
		{
			stream.@each_position(primitive ; Vec3 position, sz i)
			{
				points.push(position);
			};
		}

		// `Assets.convex`'s cap, for its reason: quickhull is quadratic in the
		// adversarial case and a load must not become a stall. A hull that big is
		// left to be swept as the drawing.
		if (points.len() < MIN_CONVEX_POINTS || points.len() > MAX_CONVEX_POINTS) return -1;

		GeometryBuilder geometry;
		geometry.init();
		defer geometry.free();
		build_convex(&geometry, points.array_view());
		if (geometry.indices.len() == 0) return -1;

		GpuMesh? built = assets.upload_geometry(gpu, "convex hull collider", &geometry);
		if (catch built) return -1;

		at = (int)asset.meshes.len();
		asset.meshes.push(built);
		cache[index] = at;
	};
	return at;
}

fn String shape_label(gltf::ShapeType type) @local
{
	switch (type)
	{
		case BOX: return "box collider";
		case SPHERE: return "sphere collider";
		case CAPSULE: return "capsule collider";
		case CYLINDER: return "cylinder collider";
	}
}

<*
 One implicit shape as triangles, centred on the origin and about +Y.

 Straight onto the parametric builders for three of the four, which is what
 keeps a proxy's winding and its normals the same as every other generated
 shape's — a proxy that is inside out is a sweep that reports no hit and a
 raycast that passes through.
*>
fn void build_shape_proxy(GeometryBuilder* out, gltf::Shape shape) @local
{
	switch (shape.type)
	{
		case BOX:
			Primitive box = box_shape(shape.size.x, shape.size.y, shape.size.z);
			box.build(out);
		case SPHERE:
			Primitive ball = sphere_shape(shape.radius, COLLIDER_PROXY_SEGMENTS, COLLIDER_PROXY_SEGMENTS / 2);
			ball.build(out);
		case CYLINDER:
			Primitive tube = cylinder_shape(
				shape.radius_top,
				shape.radius_bottom,
				shape.height,
				COLLIDER_PROXY_SEGMENTS,
			);
			tube.build(out);
		case CAPSULE:
			build_capsule_proxy(out, shape.height, shape.radius_top, shape.radius_bottom);
	}
}

<*
 A capsule: a cylindrical band with a hemisphere on each end.

 There is no `CapsuleGeometry` here to borrow — the parametric shapes are
 Three.js's five and a capsule is not one of them — so it is a lathe of the
 profile, revolved the same way `build_sphere` sweeps its rings. The two caps
 may have different radii, which is what `KHR_implicit_shapes` allows and what
 Blender's capsule collider writes when the mesh it was measured from tapers.

 `height` is the cylindrical section alone, as the extension defines it, so the
 shape is `height + radius_top + radius_bottom` tall.
*>
fn void build_capsule_proxy(GeometryBuilder* out, float height, float radius_top, float radius_bottom) @local
{
	float half = height * 0.5f;
	if (radius_top <= 0 && radius_bottom <= 0) return;

	uint radial = COLLIDER_PROXY_SEGMENTS;
	uint rings  = COLLIDER_PROXY_RINGS;
	uint first  = (uint)out.positions.len();

	// The profile, north pole to south: the top cap's quarter arc down to its
	// equator, then the bottom cap's equator down to its pole. The two equators
	// are separate rows and the band between them is one quad ring, which is what
	// lets the two caps have different radii.
	uint rows   = rings * 2 + 2;
	uint stride = radial + 1;

	for (uint iy = 0; iy < rows; iy++)
	{
		bool top    = iy <= rings;
		float t     = top ? (float)iy / (float)rings : (float)(iy - rings - 1) / (float)rings;
		float theta = t * (float)math::PI * 0.5f;
		float r     = top ? radius_top : radius_bottom;
		// The cap's own centre, so a hemisphere is a hemisphere wherever the band
		// puts it: t = 0 is the equator of the bottom cap and the pole of the top.
		float centre = top ? half : -half;
		float ring   = top ? r * math::sin(theta) : r * math::cos(theta);
		float y      = top ? centre + r * math::cos(theta) : centre - r * math::sin(theta);

		for (uint ix = 0; ix <= radial; ix++)
		{
			float u       = (float)ix / (float)radial;
			float phi     = u * (float)math::TAU;
			float sin_phi = math::sin(phi);
			float cos_phi = math::cos(phi);
			Vec3 position = { ring * sin_phi, y, ring * cos_phi };
			// From the cap's own centre, which is the capsule's normal everywhere:
			// on the band the two centres are level with the vertex and the vector
			// comes out horizontal.
			Vec3 normal = ((Vec3) { position.x, y - centre, position.z }).normalize();
			out.vertex(position, normal, { u, 1.0f - (float)iy / (float)(rows - 1) });
		}
	}

	for (uint iy = 0; iy < rows - 1; iy++)
	{
		for (uint ix = 0; ix < radial; ix++)
		{
			uint a = first + iy * stride + ix + 1;
			uint b = first + iy * stride + ix;
			uint c = first + (iy + 1) * stride + ix;
			uint d = first + (iy + 1) * stride + ix + 1;
			// The poles are a row of one point wearing `radial` uvs, so the half of
			// each quad that collapses onto them is dropped — `build_sphere`'s rule.
			if (iy != 0) out.triangle(a, b, d);
			if (iy != rows - 2) out.triangle(b, c, d);
		}
	}
}

<*
 The file's joints, each resolved to the two bodies its pivots hang off.

 glTF hangs the joint on a pivot node parented to the first body and names a
 second pivot parented to the second — so the two bodies are the pivots'
 parents, and the pivot's own world placement is where the joint sits.
*>
fn void record_joints(Asset* asset, gltf::Gltf* doc) @local
{
	bool jointed = false;
	foreach (&source : doc.nodes)
	{
		if (source.joint >= 0) { jointed = true; break; }
	}
	if (!jointed) return;

	asset.joints.init(mem, 2);
	foreach (&source : doc.nodes)
	{
		if (source.joint < 0 || source.joint >= doc.physics_joints.len()) continue;

		AssetJoint joint = { .body_a = -1, .body_b = -1, .collide = source.enable_collision };
		joint.limits.init(mem, 4);

		if (source.parent != null) joint.body_a = (int)source.parent.index;
		if (source.connected_node >= 0 && source.connected_node < doc.nodes.len())
		{
			gltf::Node* other = &doc.nodes[(uint)source.connected_node];
			if (other.parent != null) joint.body_b = (int)other.parent.index;
		}

		Matrix4f world = source.global_matrix();
		joint.pivot = { world.m[12], world.m[13], world.m[14] };

		gltf::PhysicsJoint* description = &doc.physics_joints[(uint)source.joint];
		foreach (limit : description.linear_limits) joint.limits.push(read_joint_limit(0, limit));
		foreach (limit : description.angular_limits) joint.limits.push(read_joint_limit(1, limit));

		asset.joints.push(joint);
	}
}

// One limit's axis vector as the bit mask the solver's side reads.
fn AssetJointLimit read_joint_limit(uint kind, gltf::Limit limit) @local
{
	uint axes;
	if (limit.axes.x != 0) axes |= 1;
	if (limit.axes.y != 0) axes |= 2;
	if (limit.axes.z != 0) axes |= 4;
	return {
		.kind = kind,
		.axes = axes,
		.min = limit.min,
		.max = limit.max,
		.stiffness = limit.stiffness,
		.damping = limit.damping,
	};
}

<*
 Give back what `record_physics` allocated: the proxy names and the joints'
 limit lists.

 One helper rather than inline in both places that free an asset, for
 `free_nodes`' reason.
*>
fn void free_physics(Asset* asset)
{
	foreach (&body : asset.bodies)
	{
		if (body.name.len > 0) body.name.free(mem);
	}
	asset.bodies.free();
	foreach (&joint : asset.joints) joint.limits.free();
	asset.joints.free();
	// Zeroed rather than left dangling, exactly as `free_nodes` does: `free_slot`
	// and `Assets.free` are two doors onto the same slot and a freed `List` must
	// not look full to whichever runs second.
	asset.bodies = { };
	asset.joints = { };
	asset.has_physics = false;
}
