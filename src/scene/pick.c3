<*
 Scene raycasting, in instance-local space.

 One BVH per unique mesh, never one per instance. The tree is built when the
 asset is uploaded and lives beside the geometry; a raycast walks the instance
 table, transforms the ray into each instance's own space by the inverse world
 matrix, and tests against the shared tree. A thousand copies of a wall cost one
 tree — the same "linked, not duplicated" rule the renderer and exporter follow.

 The broad phase is an index, not a walk: an instance whose world AABB the ray
 misses is skipped without touching its tree, and which instances are reached at
 all comes from `scene/query.c3`'s grid. See `Scene.raycast`.

 Picking is also how projection and raycasting are kept honest with each other.
 A ray that disagrees with the camera fails silently — everything still renders,
 it just puts things somewhere other than where they were asked for — and a test
 asserting "a ray through this screen point hits instance 7" is exact, needs no
 GPU and catches that class of bug.
*>
module three;

import std::math;
import std::math::vector;
import std::math::matrix;
import collision;

<*
 What a ray hit, in world space.

 `distance` is along the ray in world units, so hits from different instances
 stay comparable however each is scaled. Comparing local-space parameters from
 differently scaled objects is the classic way to get this wrong.
*>
struct Hit
{
	bool hit;
	NodeId node;
	AssetId asset;
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
	Hit best = { .hit = false, .distance = float::max, .node = NO_NODE };
	if (assets == null) { best.distance = 0; return best; }

	// The walk is over cells, not over nodes. Testing every node's broad phase
	// first cost 42 µs in a 500-node scene for a ray that could only ever have
	// hit what is in front of it — a hundred agents casting one ground ray
	// apiece measured 2.1 ms. The index is rebuilt by the first query after
	// anything moved and by nothing else, so the first cast in a frame costs
	// what a cast used to and the ninety-ninth costs a cell walk.
	//
	// The broad phase itself is unchanged: the same world box from the same
	// `world_mesh_bounds`, tested with the same `intersect_ray`. What changed is
	// which boxes are reached.
	self.ensure_query_index(assets);
	QueryIndex* index = &self.query;
	index.stamp_now++;

	index.@walk_ray(ray, float::max; uint i, float cell_near)
	{
		// Nearest cell first, so a cell beginning beyond the best hit so far
		// cannot improve on it. That is what makes the walk sublinear rather
		// than merely indexed: a ground ray finds its floor in the second cell
		// and does no narrow-phase work after it. Oversized entries arrive with
		// a `cell_near` of zero and are never skipped here — they have no cell
		// to be ordered by, and neither do entries left loose by a re-file.
		if (cell_near < best.distance && index.stamp[(sz)i] != index.stamp_now)
		{
			index.stamp[(sz)i] = index.stamp_now;
			QueryEntry entry = index.entries[(sz)i];
			collision::HitInfo broad = entry.box.intersect_ray(ray);
			if (broad.collided && broad.depth <= best.distance && self.query_node(entry) != null)
			{
				Hit hit;
				if (self.ray_hits_node(assets, entry.node, ray, best.distance, &hit)) best = hit;
			}
		}
	};

	if (!best.hit) best.distance = 0;
	return best;
}

<*
 A ray through a point on the screen, in the same projection the renderer used.

 Unprojects the near and far planes and joins them, rather than building the ray
 from the camera's eye and a field-of-view derivation. The two agree only if
 every convention agrees — the [0,1] depth range, the aspect, the near plane,
 the handedness — so deriving the ray from the matrix the renderer draws with
 makes "the ray goes where the picture goes" true by construction.

 The ray goes through the *centre* of the named pixel — that is the half added
 below. The rasterizer decides coverage by testing the same centre, so without
 it the picker is biased half a pixel against the picture it must agree with.
 A row of 160 picks across a rendered fixture disagreed on exactly one column,
 the left edge of a quad; `a_pick_returns_to_the_middle_of_the_pixel_it_named`
 is the check.

 @param x : `The pixel's column, counted from the left.`
 @param y : `The pixel's row, counted from the top — the way a window reports a cursor.`
*>
fn collision::Ray screen_ray(Camera* camera, float x, float y, uint width, uint height)
{
	float aspect = (float)width / (float)height;
	Matrix4f inverse_view_projection = invert(camera.view_projection(aspect));

	// To normalised device coordinates. Y is flipped because `gpu/target.c3`
	// binds a negative-height viewport (`.y = height, .height = -height`), which
	// puts NDC +Y at the *top* row of the image; a pixel row counted from the
	// top therefore runs from +1 down to -1, opposite to the column.
	//
	// Getting this backwards is invisible to every test that asks the picker to
	// agree with itself — a round trip, a pick at the centre, a symmetric
	// fixture — because the centre row is the one row a flip leaves alone. It
	// shows up only against the rendered image, which is what
	// `a_pick_agrees_with_the_pixels_it_was_counted_in` compares against.
	float ndc_x = ((x + 0.5f) / (float)width) * 2.0f - 1.0f;
	float ndc_y = 1.0f - ((y + 0.5f) / (float)height) * 2.0f;

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

<*
 A point through a column-major 4x4.

 Not `@local`: `scene/query.c3`'s sweep and bulk raycast do exactly this
 arithmetic, and a second copy is a second place for a row/column mix-up to hide.
*>
fn Vec3 transform_point(Matrix4f m, Vec3 point)
{
	float[<16>] v = m.m;
	return {
		v[0] * point.x + v[4] * point.y + v[8] * point.z + v[12],
		v[1] * point.x + v[5] * point.y + v[9] * point.z + v[13],
		v[2] * point.x + v[6] * point.y + v[10] * point.z + v[14],
	};
}

// A direction through the same matrix: the translation column must not reach it.
fn Vec3 transform_direction(Matrix4f m, Vec3 direction)
{
	float[<16>] v = m.m;
	return {
		v[0] * direction.x + v[4] * direction.y + v[8] * direction.z,
		v[1] * direction.x + v[5] * direction.y + v[9] * direction.z,
		v[2] * direction.x + v[6] * direction.y + v[10] * direction.z,
	};
}

<*
 Whether anything is under this pixel.

 The question a hover asks, which wants no hit — only whether there was one.
 Separate from `pick` so a caller asking sixty times a second is not building an
 answer nobody reads.

 `x` and `y` are the rendered image's pixels counted from its top-left corner:
 the same coordinates `scene.pick` takes and `WindowView.cursor` answers in.
*>
fn bool MeshPass.hits(&self, float x, float y, uint width, uint height)
{
	return self.scene.raycast(&self.assets, screen_ray(&self.camera, x, y, width, height)).hit;
}
