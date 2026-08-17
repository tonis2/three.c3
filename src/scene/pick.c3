<*
 Scene raycasting, in instance-local space.

 **One BVH per unique mesh, never one per instance** (`plan.md` §2). The tree is
 built when the asset is uploaded and lives beside the geometry; a scene raycast
 walks the instance table, transforms the ray into each instance's own space by
 the inverse world matrix, and tests against the shared tree. A thousand copies
 of a wall cost one tree — the same "linked, not duplicated" rule the renderer
 and the exporter follow.

 ## Why this exists before anything calls it

 `plan.md` §7: picking is "the suite that catches a projection and a raycast that
 disagree, which is the half of a 3D app that fails *silently*: everything still
 renders, it just puts things somewhere other than where they were asked for."
 A test that asserts "a ray through this screen point hits instance 7" is exact,
 needs no GPU and no window, and catches the class of bug that a pixel comparison
 cannot describe and a matrix comparison cannot notice. That is worth more now,
 as the check on M2's world-matrix propagation, than it will be at M5 when it
 becomes `scene.raycast()` in JS.

 ## Broad phase first

 An instance whose world AABB the ray misses is skipped without touching its
 tree. `transform_aabb` is the same function frustum culling uses, which is the
 point of `plan.md` §2 saying the broad phase is shared.
*>
module three;

import std::math;
import std::math::vector;
import std::math::matrix;
import collision;

<*
 What a ray hit, in world space.

 `distance` is along the ray in world units, so hits from different instances
 are comparable however each of them is scaled — which is exactly the thing a
 naive implementation gets wrong, by comparing local-space parameters from
 differently scaled objects against each other.
*>
struct Hit
{
	bool hit;
	NodeId node;
	uint asset;
	uint mesh;
	float distance;
	Vec3 point;
	Vec3 normal;
}

<*
 The closest drawable node a ray hits.

 Invisible nodes are skipped, and so is anything under an invisible parent:
 picking what cannot be seen is never what was meant. Frustum culling is *not*
 applied — that is a property of where the camera is, and a raycast is not.

 @param ray : `Origin and a unit direction, world space.`
*>
fn Hit Scene.raycast(&self, Assets* assets, collision::Ray ray)
{
	self.update_world_matrices();

	Hit best = { .hit = false, .distance = float::max, .node = NO_NODE };

	foreach (slot, &node : self.nodes)
	{
		if (!node.alive || !node.world_visible) continue;
		if (node.asset == NO_ASSET || node.mesh == NO_MESH) continue;

		GpuMesh* mesh = assets.mesh(node.asset, node.mesh);
		if (mesh == null || mesh.bvh == null) continue;

		// Broad phase, in world space: shared with frustum culling.
		collision::Aabb3 world_box = transform_aabb(node.world, mesh.bounds);
		collision::HitInfo broad = world_box.intersect_ray(ray);
		if (!broad.collided || broad.depth > best.distance) continue;

		Matrix4f inverse_world = invert(node.world);

		// A direction is a vector, not a point: the translation column must not
		// reach it. Transforming it as a point puts the ray's far end at the
		// inverse-transformed origin instead, which aims every ray at the model
		// and produces hits that look plausible and are wrong.
		Vec3 local_origin = transform_point(inverse_world, ray.origin);
		Vec3 local_direction = transform_direction(inverse_world, ray.direction);

		// The tree wants a unit direction, and normalising changes what the
		// returned parameter *means*: under a scale of 2, one local unit is two
		// world units. Dividing the local parameter by the length undoes exactly
		// that, and is what makes `distance` comparable across instances.
		float length = local_direction.length();
		if (length < 1e-12f) continue;

		collision::Ray local_ray = { .origin = local_origin, .direction = local_direction / length };
		collision::HitInfo narrow = mesh.bvh.ray_intersects(local_ray);
		if (!narrow.collided) continue;

		float distance = narrow.depth / length;
		if (distance >= best.distance) continue;

		best = {
			.hit = true,
			.node = { .index = (uint)slot, .generation = node.generation },
			.asset = node.asset,
			.mesh = node.mesh,
			.distance = distance,
			.point = ray.origin + ray.direction * distance,
			// The normal transforms by the inverse transpose, which the node
			// already caches for the shader. Using the world matrix instead
			// would tilt normals on any non-uniformly scaled instance.
			.normal = transform_direction(node.normal, narrow.normal).normalize(),
		};
	}

	if (!best.hit) best.distance = 0;
	return best;
}

<*
 A ray through a point on the screen, in the same projection the renderer used.

 Unprojects the near and far planes and joins them, rather than building the ray
 from the camera's eye and a field-of-view derivation. The two agree only if
 every convention agrees — the [0,1] depth range, the aspect, the near plane,
 the handedness — so deriving the ray from the matrix the renderer draws with is
 what makes "the ray goes where the picture goes" true by construction rather
 than by two implementations staying in step.

 @param x : `Pixels from the left edge.`
 @param y : `Pixels from the top edge, the way a window reports a cursor.`
*>
fn collision::Ray screen_ray(Camera* camera, float x, float y, uint width, uint height)
{
	float aspect = (float)width / (float)height;
	Matrix4f inverse_view_projection = invert(camera.view_projection(aspect));

	// To normalised device coordinates. Y is *not* flipped: `gpu/target.c3`
	// binds a negative-height viewport, so a pixel row counted from the top maps
	// to NDC +Y up without a second flip — the same reasoning that keeps
	// `Camera.projection` free of one.
	float ndc_x = (x / (float)width) * 2.0f - 1.0f;
	float ndc_y = (y / (float)height) * 2.0f - 1.0f;

	Vec3 near_point = unproject(inverse_view_projection, ndc_x, ndc_y, 0.0f);
	Vec3 far_point  = unproject(inverse_view_projection, ndc_x, ndc_y, 1.0f);

	return { .origin = near_point, .direction = (far_point - near_point).normalize() };
}

fn Vec3 unproject(Matrix4f inverse_view_projection, float x, float y, float z) @local
{
	float[<4>] clip = { x, y, z, 1.0f };
	float[<4>] world = inverse_view_projection * clip;
	if (math::abs(world[3]) < 1e-12f) return { world[0], world[1], world[2] };
	return { world[0] / world[3], world[1] / world[3], world[2] / world[3] };
}

fn Vec3 transform_point(Matrix4f m, Vec3 point) @local
{
	float[<16>] v = m.m;
	return {
		v[0] * point.x + v[4] * point.y + v[8] * point.z + v[12],
		v[1] * point.x + v[5] * point.y + v[9] * point.z + v[13],
		v[2] * point.x + v[6] * point.y + v[10] * point.z + v[14],
	};
}

fn Vec3 transform_direction(Matrix4f m, Vec3 direction) @local
{
	float[<16>] v = m.m;
	return {
		v[0] * direction.x + v[4] * direction.y + v[8] * direction.z,
		v[1] * direction.x + v[5] * direction.y + v[9] * direction.z,
		v[2] * direction.x + v[6] * direction.y + v[10] * direction.z,
	};
}
