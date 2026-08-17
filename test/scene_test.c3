<*
 The scene graph, the instance table and the raycast.

	`c3c test --trust=full --test-noleak --test-filter three_tests::scene`

 Most of this runs with no GPU and no window, which is the point. `plan.md` §7:
 the silent failures are the expensive ones, and the two that matter here —
 a stale world matrix and a raycast that disagrees with the projection — both
 render a perfectly valid picture with things in the wrong place. Nothing about
 either produces an error, a validation message or a black screen, so the only
 way to catch them is to assert on the numbers.

 **Assert on the thing, not on the flag.** The bucketing check reads the bucket
 list rather than a `instanced = true` field, the culling check reads the
 instance count rather than a `culled` bool, and the picking checks name the
 instance they expect to be hit.
*>
module three_tests::scene;

import three;
import vk;
import image;
import collision;
import std::core::test;
import std::io;
import std::io::file;
import std::math;
import std::math::vector;
import std::math::matrix;

const String FIXTURE = "test/fixtures/textured.glb";

const uint W = 200;
const uint H = 150;

macro @with_pass(; @body(three::Renderer* renderer))
{
	vk::Instance instance = three::create_instance(false, headless: true)!!;
	defer instance.free();

	three::Renderer renderer;
	renderer.init(instance, (vk::SurfaceKHR)null, W, H)!!;
	defer renderer.free();

	renderer.pass.init(&renderer.gpu, &renderer.target)!!;

	@body(&renderer);
}

fn bool close(float a, float b, float tolerance = 0.001) => math::abs(a - b) < tolerance;

fn bool vec_close(Vec3 a, Vec3 b, float tolerance = 0.001)
{
	return close(a.x, b.x, tolerance) && close(a.y, b.y, tolerance) && close(a.z, b.z, tolerance);
}

<*
 How many pixels are not the clear colour. The same blunt instrument
 `asset_test.c3` uses, and for the same reason: it answers "did anything draw at
 all", which no success return value can.
*>
fn uint count_drawn(image::Image* shot, float[4] clear)
{
	char[3] background = {
		(char)(uint)(clear[0] * 255.0 + 0.5),
		(char)(uint)(clear[1] * 255.0 + 0.5),
		(char)(uint)(clear[2] * 255.0 + 0.5),
	};

	uint drawn = 0;
	for (sz i = 0; i < shot.pixels.len; i += 4)
	{
		int dr = (int)shot.pixels[i] - (int)background[0];
		int dg = (int)shot.pixels[i + 1] - (int)background[1];
		int db = (int)shot.pixels[i + 2] - (int)background[2];
		if (dr * dr + dg * dg + db * db > 12) drawn++;
	}
	return drawn;
}

// ============================================================================
// Scene math — no GPU, no assets
// ============================================================================

<*
 A child's world transform is its parent's, applied to its own.

 Hand-predictable on purpose: the parent turns a quarter turn about +Y, and a
 child one unit along +X ends up one unit along -Z. Any of the three ways to get
 a rotation backwards — the wrong Euler order, a transposed matrix, a
 left-handed rotation — moves it somewhere else, and all of them still render.
*>
fn void a_child_inherits_its_parents_transform() @test
{
	three::Scene scene;
	scene.init();
	defer scene.free();

	three::NodeId parent = scene.add_group();
	three::NodeId child = scene.add_group(parent);

	scene.set_position(child, { 1, 0, 0 });
	scene.update_world_matrices();
	test::@check(vec_close(scene.node(child).world_position(), { 1, 0, 0 }), "an untransformed parent moved its child");

	scene.set_rotation(parent, { 0, (float)math::PI * 0.5f, 0 });
	scene.update_world_matrices();

	Vec3 world = scene.node(child).world_position();
	test::@check(
		vec_close(world, { 0, 0, -1 }, 0.0001),
		"a quarter turn about +Y put the child at (%f, %f, %f), expected (0, 0, -1)",
		world.x, world.y, world.z
	);

	scene.set_position(parent, { 10, 0, 0 });
	scene.update_world_matrices();
	world = scene.node(child).world_position();
	test::@check(
		vec_close(world, { 10, 0, -1 }, 0.0001),
		"translation did not compose with rotation: got (%f, %f, %f)",
		world.x, world.y, world.z
	);
}

<*
 A change to a node reaches every descendant, not just the first.

 The dirty flag is an optimisation, and the failure mode of an optimisation that
 is wrong is a *stale* world matrix — geometry drawn where it used to be. Three
 levels, because a propagation that only carries one level deep passes a
 two-level test.
*>
fn void dirt_propagates_all_the_way_down() @test
{
	three::Scene scene;
	scene.init();
	defer scene.free();

	three::NodeId a = scene.add_group();
	three::NodeId b = scene.add_group(a);
	three::NodeId c = scene.add_group(b);

	scene.set_position(b, { 0, 1, 0 });
	scene.set_position(c, { 0, 1, 0 });
	scene.update_world_matrices();
	test::@check(vec_close(scene.node(c).world_position(), { 0, 2, 0 }), "the initial walk did not compose two levels");

	// Only `a` is touched. If dirt stopped at `b`, `c` keeps the old matrix.
	scene.set_position(a, { 5, 0, 0 });
	scene.update_world_matrices();

	Vec3 world = scene.node(c).world_position();
	test::@check(
		vec_close(world, { 5, 2, 0 }),
		"grandchild is at (%f, %f, %f) after moving the grandparent, expected (5, 2, 0) — the dirty flag stopped short",
		world.x, world.y, world.z
	);
}

<*
 Hiding a group hides everything under it.

 Three.js does this and an agent will assume it. A flat scan of the node pool
 cannot see it, which is why `world_visible` is resolved in the same walk the
 matrices are.
*>
fn void hiding_a_parent_hides_its_children() @test
{
	three::Scene scene;
	scene.init();
	defer scene.free();

	three::NodeId parent = scene.add_group();
	three::NodeId child = scene.add_group(parent);

	scene.update_world_matrices();
	test::@check(scene.node(child).world_visible, "a visible child under a visible parent came back hidden");

	scene.set_visible(parent, false);
	scene.update_world_matrices();
	test::@check(!scene.node(child).world_visible, "hiding the parent left the child visible");
	test::@check(scene.node(child).visible, "hiding the parent should not clear the child's own flag");
}

<*
 A removed node's handle stops resolving, even after its slot is reused.

 `plan.md` §1 requires that a JS handle throws rather than dereferencing freed
 memory. A bare index cannot tell "slot 7" from "slot 7 after something else was
 put in it", and the generation is what closes that — so the second half of this
 check, after the slot has been handed out again, is the one that matters.
*>
fn void a_removed_node_leaves_a_stale_handle() @test
{
	three::Scene scene;
	scene.init();
	defer scene.free();

	three::NodeId first = scene.add_group(three::NO_NODE, "first");
	test::@check(scene.node(first) != null, "a freshly added node did not resolve");

	scene.remove(first);
	test::@check(scene.node(first) == null, "a removed node still resolves");

	three::NodeId second = scene.add_group(three::NO_NODE, "second");
	test::@check(second.index == first.index, "the test needs the slot to be reused; it was not");
	test::@check(scene.node(second) != null, "the reused slot does not resolve under its new handle");
	test::@check(scene.node(first) == null, "the old handle came back valid once its slot was reused");
}

<*
 Removing a node removes its children with it.
*>
fn void removing_a_group_removes_its_subtree() @test
{
	three::Scene scene;
	scene.init();
	defer scene.free();

	three::NodeId parent = scene.add_group();
	three::NodeId child = scene.add_group(parent);
	three::NodeId grandchild = scene.add_group(child);

	scene.remove(parent);
	test::@check(scene.node(child) == null, "the child outlived its parent");
	test::@check(scene.node(grandchild) == null, "the grandchild outlived its grandparent");
}

<*
 The normal matrix is the inverse transpose, not the model matrix.

 Under a scale of (1, 2, 1) the inverse transpose is (1, 0.5, 1): a surface
 stretched twice as tall has its normals *squashed*. Using the model matrix
 instead gives (1, 2, 1) and lights a stretched object as though it were not
 stretched — which is a shading bug with correct geometry, and reads as a light
 in the wrong place rather than as a broken transform.
*>
fn void the_normal_matrix_undoes_a_non_uniform_scale() @test
{
	Matrix4f scaled = matrix::IDENTITY4{float}.scale({ 1, 2, 1 });
	Matrix4f normal = three::normal_matrix(scaled);

	test::@check(close(normal.m[0], 1.0), "x scale came back %f, expected 1", normal.m[0]);
	test::@check(close(normal.m[5], 0.5), "y scale came back %f, expected 0.5 — this is the model matrix, not its inverse transpose", normal.m[5]);
	test::@check(close(normal.m[10], 1.0), "z scale came back %f, expected 1", normal.m[10]);

	// A rotation is its own inverse transpose, so this must come back unchanged
	// — an implementation that transposed one time too many passes the scale
	// check above and fails this one.
	Matrix4f rotated = matrix::IDENTITY4{float}.rotate_y(0.7f);
	Matrix4f rotation_normal = three::normal_matrix(rotated);
	for (usz i = 0; i < 16; i++)
	{
		test::@check(close(rotation_normal.m[i], rotated.m[i], 0.0001), "element %d of a rotation's normal matrix changed: %f vs %f", i, rotation_normal.m[i], rotated.m[i]);
	}
}

// ============================================================================
// Bucketing — the thesis
// ============================================================================

<*
 A thousand instances of one mesh is one draw call.

 **This is the project's whole claim** (`plan.md` §"What it is"): every scene the
 API can express is optimized by construction, because an instance is an asset
 reference plus a transform and there is nothing else it can be. If this ever
 returns a thousand, the thesis is gone and nothing else in the plan is worth
 building.

 Asserted on the bucket list rather than on a count, so a `stats()` that
 computed the right number the wrong way cannot satisfy it.
*>
fn void a_thousand_instances_are_one_draw_call() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		renderer.pass.load_triangle(&renderer.gpu)!!;

		three::Scene* scene = &renderer.pass.scene;
		for (uint i = 0; i < 1000; i++)
		{
			three::NodeId node = scene.add_mesh(0, 0);
			scene.set_position(node, { (float)i * 2.0f, 0, 0 });
		}

		three::SceneStats stats = renderer.pass.stats();
		test::@check(stats.instances == 1001, "1000 added to the 1 already there is %d instances", stats.instances);
		test::@check(stats.draw_calls == 1, "1001 copies of one mesh took %d draw calls", stats.draw_calls);
		test::@check(scene.buckets.len() == 1, "the bucket list has %d entries, expected 1", scene.buckets.len());
		test::@check(scene.buckets[0].count == 1001, "the single bucket holds %d instances", scene.buckets[0].count);
		test::@check(scene.buckets[0].first == 0, "the single bucket starts at %d, expected 0", scene.buckets[0].first);
	};
}

<*
 Two different meshes are two buckets, however they are interleaved.

 The instances are added alternating between the two meshes, so a bucketer that
 relies on traversal order rather than actually grouping produces four buckets
 or worse. The sort is what makes this exact.
*>
fn void interleaved_meshes_still_bucket() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		renderer.pass.load(&renderer.gpu, FIXTURE)!!;

		three::Scene* scene = &renderer.pass.scene;
		for (uint i = 0; i < 20; i++)
		{
			three::NodeId node = scene.add_mesh(0, i % 2);
			scene.set_position(node, { (float)i, 0, 0 });
		}

		three::SceneStats stats = renderer.pass.stats();
		test::@check(stats.draw_calls == 2, "two meshes interleaved 20 times took %d draw calls", stats.draw_calls);
		test::@check(stats.instances == 22, "expected 22 instances, got %d", stats.instances);

		// Every instance in a bucket must be contiguous, or the pointer offset
		// the pass hands the shader points at another mesh's transforms.
		uint total = 0;
		foreach (bucket : scene.buckets)
		{
			test::@check(bucket.first == total, "bucket starts at %d, expected %d — the slices overlap or leave a gap", bucket.first, total);
			total += bucket.count;
		}
		test::@check(total == stats.instances, "the buckets cover %d of %d instances", total, stats.instances);
	};
}

<*
 Culling drops instances outside the frustum, and `stats()` does not see it.

 Two triangles a kilometre apart with the camera on one of them. Culling on:
 one instance survives. Culling off: two. `stats()` reports two either way,
 because "how many instances does this scene have" must not depend on where the
 camera happens to point.
*>
fn void culling_drops_what_is_off_screen() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		renderer.pass.load_triangle(&renderer.gpu)!!;

		three::Scene* scene = &renderer.pass.scene;
		three::NodeId far_away = scene.add_mesh(0, 0);
		scene.set_position(far_away, { 1000, 0, 0 });

		three::Camera camera = three::default_camera();
		camera.frame_bounds({ -0.5, -0.5, 0 }, { 0.5, 0.5, 0 });
		Matrix4f view_projection = camera.view_projection((float)W / (float)H);

		scene.cull = true;
		scene.update(&renderer.pass.assets, view_projection);
		test::@check(scene.instances.len() == 1, "with culling on, %d instances survived; expected 1", scene.instances.len());
		test::@check(scene.culled == 1, "%d instances were reported culled, expected 1", scene.culled);

		scene.cull = false;
		scene.update(&renderer.pass.assets, view_projection);
		test::@check(scene.instances.len() == 2, "with culling off, %d instances survived; expected 2", scene.instances.len());

		three::SceneStats stats = renderer.pass.stats();
		test::@check(stats.instances == 2, "stats() reported %d instances; it must not depend on the camera", stats.instances);
	};
}

<*
 Two different files sharing an image upload it once.

 The fixture is copied to a second path, so the two loads are genuinely two
 assets — a dedup keyed on the file path would report two textures here, and a
 dedup that only looked inside one file would too. Only a content hash compared
 across everything already loaded gets one, and that is the rule `plan.md` §2
 asks for and the one the M6 exporter needs.
*>
fn void two_assets_sharing_an_image_upload_it_once() @test
{
	String copy = "build/scene_test_copy.glb";
	char[]? source = file::load_temp(FIXTURE);
	test::@check(@ok(source), "could not read %s — regenerate it with test/fixtures/make_textured.py", FIXTURE);
	file::save(copy, source!!)!!;
	defer (void)file::delete(copy);

	@with_pass(; three::Renderer* renderer)
	{
		renderer.pass.load(&renderer.gpu, FIXTURE)!!;
		renderer.pass.load(&renderer.gpu, copy)!!;

		three::Assets* assets = &renderer.pass.assets;
		test::@check(assets.assets.len() == 2, "two different paths produced %d assets", assets.assets.len());
		test::@check(assets.textures.len() == 1, "two assets sharing one image uploaded %d textures", assets.textures.len());

		// Four, not two, and that is the rule rather than a shortfall: `plan.md`
		// §2 deduplicates *materials and textures* across assets and uploads
		// each asset's own meshes once. Two files are two sets of geometry even
		// when the triangles match, because proving they match means comparing
		// them — and the image hash is a hash of one blob, not of a mesh whose
		// equality depends on winding, indexing and vertex order agreeing too.
		three::SceneStats stats = renderer.pass.stats();
		test::@check(stats.draw_calls == 4, "two two-mesh assets should bucket into 4 draws, got %d", stats.draw_calls);
		test::@check(stats.instances == 4, "expected 4 instances, got %d", stats.instances);
	};
}

<*
 The same path loaded twice is the same asset.
*>
fn void the_same_file_loads_once() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		renderer.pass.load(&renderer.gpu, FIXTURE)!!;
		renderer.pass.load(&renderer.gpu, FIXTURE)!!;

		test::@check(renderer.pass.assets.assets.len() == 1, "the same path loaded %d times", renderer.pass.assets.assets.len());
	};
}

// ============================================================================
// Picking
// ============================================================================

<*
 A ray hits the nearer of two overlapping copies of one mesh.

 The overlap is the whole point: a raycast that returns the first hit it finds
 rather than the closest passes on a scene where nothing overlaps, and every
 real scene has overlaps.
*>
fn void a_ray_hits_the_nearer_instance() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		renderer.pass.load_triangle(&renderer.gpu)!!;

		three::Scene* scene = &renderer.pass.scene;
		three::NodeId behind = scene.add_mesh(0, 0);
		scene.set_position(behind, { 0, 0, -5 });

		collision::Ray ray = { .origin = { 0, 0, 10 }, .direction = { 0, 0, -1 } };
		three::Hit hit = scene.raycast(&renderer.pass.assets, ray);

		test::@check(hit.hit, "a ray straight through the triangle missed it");
		test::@check(close(hit.distance, 10.0, 0.01), "hit at %f, expected 10 — the nearer instance is at z = 0", hit.distance);
		test::@check(!(hit.node == behind), "the ray returned the instance five units further away");

		// And off to the side it misses entirely, rather than hitting the AABB.
		collision::Ray beside = { .origin = { 5, 0, 10 }, .direction = { 0, 0, -1 } };
		test::@check(!scene.raycast(&renderer.pass.assets, beside).hit, "a ray well clear of the geometry reported a hit");
	};
}

<*
 A scaled instance is hit where the *scale* puts it, and at the right distance.

 Two separate failures live here and both look plausible:

 - A ray transformed into local space without the scale misses geometry that a
   three-times-larger copy plainly covers.
 - A hit distance read straight out of the local-space test is in local units.
   Under a scale of two, a hit reported at 7 is really 14 away, so the *nearer*
   of two instances loses to a further one whenever they are scaled differently.

 The second is what makes hit distances comparable at all, and it is invisible
 in any scene where everything happens to be the same size.
*>
fn void picking_respects_an_instance_scale() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		renderer.pass.load_triangle(&renderer.gpu)!!;

		three::Scene* scene = &renderer.pass.scene;
		three::NodeId only = scene.buckets.len() >= 0 ? scene.add_mesh(0, 0) : three::NO_NODE;
		scene.set_visible(scene.root, true);

		// Hide the one `load_triangle` placed; this test wants one instance.
		foreach (child : scene.node(scene.root).children.array_view())
		{
			if (!(child == only)) scene.set_visible(child, false);
		}

		// (0, 1) is outside the unit triangle, whose apex is at y = 0.5.
		collision::Ray ray = { .origin = { 0, 1, 10 }, .direction = { 0, 0, -1 } };
		test::@check(!scene.raycast(&renderer.pass.assets, ray).hit, "the unscaled triangle was hit above its apex");

		scene.set_scale(only, { 3, 3, 3 });
		three::Hit scaled_hit = scene.raycast(&renderer.pass.assets, ray);
		test::@check(scaled_hit.hit, "a triangle scaled 3x was not hit at a point it plainly covers");

		// Moved back four units and scaled two: the plane is at world z = -4, so
		// the hit is 14 away from z = 10. Read straight out of local space it
		// would be 7.
		scene.set_scale(only, { 2, 2, 2 });
		scene.set_position(only, { 0, 0, -4 });
		collision::Ray centred = { .origin = { 0, 0, 10 }, .direction = { 0, 0, -1 } };
		three::Hit far_hit = scene.raycast(&renderer.pass.assets, centred);

		test::@check(far_hit.hit, "the moved-and-scaled instance was not hit");
		test::@check(
			close(far_hit.distance, 14.0, 0.01),
			"hit reported at %f, expected 14 — a local-space parameter is being returned as a world distance",
			far_hit.distance
		);
	};
}

<*
 A ray through the middle of the screen hits what is in the middle of the
 screen.

 This is the check `plan.md` §7 calls the one that catches "a projection and a
 raycast that disagree" — the half of a 3D app that fails silently. The camera
 is the one the renderer would use, the ray comes from the same matrix, and the
 assertion is that the instance under the crosshair is the one that gets picked.
*>
fn void a_ray_through_the_screen_centre_hits_what_is_centred() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		renderer.pass.load_triangle(&renderer.gpu)!!;

		three::Scene* scene = &renderer.pass.scene;
		three::NodeId centred = scene.node(scene.root).children[0];

		// A second copy well off to the left, so a raycast that ignores the
		// screen position entirely still has something wrong to return.
		three::NodeId beside = scene.add_mesh(0, 0);
		scene.set_position(beside, { -20, 0, 0 });

		three::Camera camera = three::default_camera();
		camera.target = { 0, 0, 0 };
		camera.yaw = 0;
		camera.pitch = 0;
		camera.distance = 5;

		collision::Ray ray = three::screen_ray(&camera, (float)W * 0.5f, (float)H * 0.5f, W, H);
		three::Hit hit = scene.raycast(&renderer.pass.assets, ray);

		test::@check(hit.hit, "a ray through the centre of the screen hit nothing");
		test::@check(hit.node == centred, "the centre of the screen picked the instance twenty units to the left");
	};
}

// ============================================================================
// The instance buffer
// ============================================================================

<*
 More instances than the buffer started with still render, and render the same
 twice.

 The growth path frees and reallocates one frame slot's buffer, and the two
 captures land on different slots — so a buffer shared between slots, or one
 freed while the other frame was still reading it, shows up here as a difference
 between two frames of a scene that did not change. That is exactly how crig's
 pose palette tore.
*>
fn void the_instance_buffer_grows_and_stays_stable() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		renderer.pass.load_triangle(&renderer.gpu)!!;

		three::Scene* scene = &renderer.pass.scene;
		for (uint i = 0; i < 200; i++)
		{
			three::NodeId node = scene.add_mesh(0, 0);
			scene.set_position(node, { ((float)(i % 20) - 10.0f) * 1.5f, ((float)(i / 20) - 5.0f) * 1.5f, 0 });
		}
		renderer.pass.frame_camera();

		image::Image first = renderer.capture()!!;
		defer first.free();
		image::Image second = renderer.capture()!!;
		defer second.free();

		uint drawn = 0;
		for (sz i = 0; i < first.pixels.len; i += 4)
		{
			if (first.pixels[i] != second.pixels[i]) drawn = uint::max;
		}
		test::@check(drawn != uint::max, "two captures of an unchanging 201-instance scene differ — the instance buffer is shared between frames in flight");

		// Compared against the *same scene with one instance visible*, not
		// against a pixel count. An absolute threshold here would only be
		// measuring how the camera framed 201 one-unit triangles across 200
		// pixels, which says nothing about whether 201 of them drew. The ratio
		// says exactly that, and is what a shader reading instance zero for
		// every instance would fail.
		uint many = count_drawn(&first, renderer.clear);

		foreach (child : scene.node(scene.root).children.array_view())
		{
			scene.set_visible(child, false);
		}
		scene.set_visible(scene.node(scene.root).children[0], true);

		image::Image alone = renderer.capture()!!;
		defer alone.free();
		uint one = count_drawn(&alone, renderer.clear);

		test::@check(one > 0, "the single visible instance drew nothing, so the comparison below means nothing");
		test::@check(
			many > one * 20,
			"201 instances lit %d pixels and one lit %d — the instance array is not being indexed per instance",
			many, one
		);
	};
}

<*
 The shader actually uses the per-instance normal matrix.

 `the_normal_matrix_undoes_a_non_uniform_scale` checks the arithmetic; this
 checks that the answer reaches the fragment. Two copies of the same triangle,
 tilted 60 degrees in opposite directions about +X, seen from +Z. The light is
 mostly +Y, so the one tilted towards it lights to roughly 0.95 and the one
 tilted away falls to the 0.25 ambient floor — a difference nothing subtle.

 If the normal matrix were ignored, or truncated out of the wrong three columns,
 both instances would shade with the mesh's own +Z normal and come out
 identical. The geometry is foreshortened the same amount either way, so this
 cannot be satisfied by a difference in coverage.
*>
fn void the_shader_rotates_normals_per_instance() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		renderer.pass.load_triangle(&renderer.gpu)!!;

		three::Scene* scene = &renderer.pass.scene;
		three::NodeId towards = scene.node(scene.root).children[0];
		three::NodeId away = scene.add_mesh(0, 0);

		float tilt = (float)math::PI / 3.0f; // 60 degrees
		scene.set_position(towards, { -1, 0, 0 });
		scene.set_rotation(towards, { -tilt, 0, 0 });
		scene.set_position(away, { 1, 0, 0 });
		scene.set_rotation(away, { tilt, 0, 0 });

		renderer.pass.frame_camera();
		three::Camera* camera = &renderer.pass.camera;
		camera.yaw = 0;
		camera.pitch = 0;

		image::Image shot = renderer.capture()!!;
		defer shot.free();

		uint lit_left = 0;
		uint lit_right = 0;
		uint any_left = 0;
		uint any_right = 0;
		for (uint y = 0; y < H; y++)
		{
			for (uint x = 0; x < W; x++)
			{
				sz i = ((sz)y * W + x) * 4;
				int red = (int)shot.pixels[i];
				if (red < 40) continue; // clear colour
				if (x < W / 2)
				{
					any_left++;
					if (red > 150) lit_left++;
				}
				else
				{
					any_right++;
					if (red > 150) lit_right++;
				}
			}
		}

		test::@check(any_left > 20 && any_right > 20, "both instances must be on screen: %d and %d pixels", any_left, any_right);
		test::@check(lit_left > any_left / 2, "the instance tilted into the light is not bright: %d of %d pixels", lit_left, any_left);
		test::@check(lit_right == 0, "the instance tilted away from the light has %d bright pixels — its normals were not rotated", lit_right);
	};
}

<*
 Instances are drawn where their transforms say, not all on top of each other.

 A shader reading instance zero for every instance — the shape of every
 instancing bug — renders one copy and a correct-looking picture. Two copies
 placed left and right of centre must light up both halves of the frame.
*>
fn void instances_land_where_their_transforms_say() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		renderer.pass.load_triangle(&renderer.gpu)!!;

		three::Scene* scene = &renderer.pass.scene;
		three::NodeId left = scene.node(scene.root).children[0];
		three::NodeId right = scene.add_mesh(0, 0);
		scene.set_position(left, { -2, 0, 0 });
		scene.set_position(right, { 2, 0, 0 });

		// Refit *after* moving them, then look straight down -Z. Setting the
		// distance by hand instead is the trap: `frame_bounds` derives the far
		// plane from the distance it chose, so a hand-set distance larger than
		// that puts the geometry behind the far plane and renders an empty frame
		// with nothing to say about it.
		renderer.pass.frame_camera();
		three::Camera* camera = &renderer.pass.camera;
		camera.yaw = 0;
		camera.pitch = 0;

		image::Image shot = renderer.capture()!!;
		defer shot.free();

		uint left_half = 0;
		uint right_half = 0;
		for (uint y = 0; y < H; y++)
		{
			for (uint x = 0; x < W; x++)
			{
				sz i = ((sz)y * W + x) * 4;
				// Anything brighter than the clear colour's red channel.
				if (shot.pixels[i] <= 60) continue;
				if (x < W / 2)
				{
					left_half++;
				}
				else
				{
					right_half++;
				}
			}
		}

		test::@check(left_half > 20, "only %d lit pixels on the left; the instance at x = -2 is missing", left_half);
		test::@check(right_half > 20, "only %d lit pixels on the right; both instances drew at the same transform", right_half);
	};
}
