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
import std::math::quaternion;

const String FIXTURE = "test/fixtures/textured.glb";

const uint W = 200;
const uint H = 150;

<*
 The asset `load_triangle` files first: slot zero, first occupant.

 Spelled out rather than passed as a bare `0` because an asset handle is two
 numbers since G2 — an index and a generation, mirroring `NodeId`, so that a
 handle to an unloaded asset is detectable rather than silently valid. In the
 checks below that build a `Scene` with no asset table behind it at all, this
 names nothing and the node simply never reaches the draw list, which is what
 those checks want.
*>
const three::AssetId TRIANGLE = { 0, 0 };

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
 A rotation handed to JavaScript as Euler angles comes back as the same rotation.

 `euler_from_quat` is the only backwards conversion in the codebase and it exists
 for `asset.instantiate()`, which has to give an `Object3D` a `rotation` triple.
 What has to survive the trip is the *rotation*, not the three numbers — the
 decomposition is not unique — so this asserts on matrices.

 The last two poses are the ones that matter. A pitch of exactly ±90° is the
 singularity where X and Z become the same axis and the split between them is
 arbitrary; a naive implementation returns NaN there, from an `asin` of a value
 that floating point pushed just past 1. NaN in a rotation is invisible until it
 reaches a world matrix and takes every descendant with it.
*>
fn void a_quaternion_survives_being_read_as_euler_angles() @test
{
	Vec3[] poses = {
		{ 0, 0, 0 },
		{ 0.3f, 0.7f, 1.1f },
		{ -1.2f, 0.4f, -0.9f },
		{ 2.5f, -1.9f, 0.2f },
		{ 0.4f, (float)math::PI * 0.5f, 0.9f },   // gimbal lock, +90 pitch
		{ 0.4f, (float)math::PI * -0.5f, 0.9f },  // and -90
	};

	foreach (euler : poses)
	{
		Quaternionf original = three::quat_from_euler(euler);
		Vec3 read_back = three::euler_from_quat(original);
		Quaternionf rebuilt = three::quat_from_euler(read_back);

		test::@check(
			math::is_finite(read_back.x) && math::is_finite(read_back.y) && math::is_finite(read_back.z),
			"(%.2f, %.2f, %.2f) read back as (%f, %f, %f)",
			euler.x, euler.y, euler.z, read_back.x, read_back.y, read_back.z
		);

		Matrix4f before = original.to_matrix();
		Matrix4f after = rebuilt.to_matrix();
		for (usz i = 0; i < 16; i++)
		{
			test::@check(
				math::abs(before.m[i] - after.m[i]) < 0.0005f,
				"element %d of (%.2f, %.2f, %.2f) changed from %f to %f through the Euler round trip",
				i, euler.x, euler.y, euler.z, before.m[i], after.m[i]
			);
		}
	}
}

<*
 The Euler order survived becoming a quaternion.

 `Node.rotation` was an XYZ Euler triple until G3 and `local_matrix` composed it
 by hand as `translate · rotate_x · rotate_y · rotate_z · scale`. It is a
 quaternion now, because a glTF node's TRS and a sampled animation channel are
 both quaternions and storing them as Euler angles is lossy at exactly the poses
 that matter. `quat_from_euler` is the conversion that stands where the chain
 used to.

 This is that chain, written out literally, compared against what
 `quat_from_euler` produces. Not a property of quaternions — a property of
 *this* conversion agreeing with *that* order, which is a thing an agent
 pasting Three.js code depends on and which nothing else in the suite would
 notice going wrong. `from_euler` in the standard library documents itself as
 ZYX and would pass a "rotations compose" test while failing this one.

 The angles are deliberately all-different and none of them a right angle: a
 wrong order is invisible when two of three are zero, and 90° hides sign errors
 by putting sines and cosines on 0 and 1.
*>
fn void euler_order_survived_the_quaternion() @test
{
	Vec3[] poses = {
		{ 0.3f, 0.7f, 1.1f },
		{ -1.2f, 0.4f, -0.9f },
		{ 2.5f, -1.9f, 0.2f },
		{ (float)math::PI * 0.5f, 0.6f, -0.35f }, // gimbal-locked in Euler terms
	};

	foreach (euler : poses)
	{
		Matrix4f chain = matrix::IDENTITY4{float}
			.rotate_x(euler.x)
			.rotate_y(euler.y)
			.rotate_z(euler.z);

		Matrix4f viaq = three::quat_from_euler(euler).to_matrix();

		for (usz i = 0; i < 16; i++)
		{
			test::@check(
				math::abs(chain.m[i] - viaq.m[i]) < 0.0001f,
				"element %d of (%.2f, %.2f, %.2f) is %f through the old chain and %f through the quaternion",
				i, euler.x, euler.y, euler.z, chain.m[i], viaq.m[i]
			);
		}
	}
}

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

		three::Scene* scene = renderer.pass.scene;
		for (uint i = 0; i < 1000; i++)
		{
			three::NodeId node = scene.add_mesh(TRIANGLE, 0);
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

		three::Scene* scene = renderer.pass.scene;
		for (uint i = 0; i < 20; i++)
		{
			three::NodeId node = scene.add_mesh(TRIANGLE, i % 2);
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
 One mesh under two materials is two draws and one mesh.

 The exact moment `SceneStats`' header predicted from M2 — "`draw_calls` and
 `unique_meshes` will stop being the same number the moment one mesh can be drawn
 under two materials". Until M5 `unique_meshes` was literally `buckets.len()`, so
 it would have answered two here and been wrong while looking right.

 No GPU shader is compiled: the material indices are written straight onto the
 nodes, because what is under test is the bucket key and the count, not the
 pipeline behind them. Index 1 and 2 need not resolve for this — `stats()` never
 looks a material up, and the draw loop that does is not running.
*>
fn void one_mesh_under_two_materials_is_two_draws_and_one_mesh() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		renderer.pass.load_triangle(&renderer.gpu)!!;

		three::Scene* scene = renderer.pass.scene;
		three::NodeId first = scene.add_mesh(TRIANGLE, 0);
		three::NodeId second = scene.add_mesh(TRIANGLE, 0);
		three::NodeId third = scene.add_mesh(TRIANGLE, 0);

		three::SceneStats shared = renderer.pass.stats();
		test::@check(shared.draw_calls == 1, "four copies on one material took %d draws", shared.draw_calls);
		test::@check(shared.unique_meshes == 1, "and are %d unique meshes", shared.unique_meshes);

		// Two of them move to a second material, one to a third.
		scene.set_material(first, 1);
		scene.set_material(second, 1);
		scene.set_material(third, 2);

		three::SceneStats split = renderer.pass.stats();
		test::@check(split.draw_calls == 3, "three materials over one mesh took %d draws", split.draw_calls);
		test::@check(
			split.unique_meshes == 1,
			"the mesh was drawn three ways and is still one mesh, got %d",
			split.unique_meshes
		);
		test::@check(split.instances == 4, "no instance was lost or invented, got %d", split.instances);

		// The slices must still tile the instance array exactly, or a bucket's
		// pointer offset lands in another material's transforms.
		uint total = 0;
		foreach (bucket : scene.buckets)
		{
			test::@check(bucket.first == total, "bucket starts at %d, expected %d", bucket.first, total);
			total += bucket.count;
		}
		test::@check(total == split.instances, "the buckets cover %d of %d", total, split.instances);
	};
}

<*
 A node built in a recycled slot does not inherit the last tenant's material.

 `create_slot` resets every field but `children` and `generation`, and a field
 left out of that block is a stale value from whoever held the slot before —
 invisible until the slot is actually reused, which `a_removed_node_leaves_a_stale_handle`
 proves does happen. For a material the symptom would be a new mesh silently
 drawing with a stranger's shader.
*>
fn void a_reused_slot_does_not_inherit_a_material() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		renderer.pass.load_triangle(&renderer.gpu)!!;
		three::Scene* scene = renderer.pass.scene;

		three::NodeId first = scene.add_mesh(TRIANGLE, 0);
		scene.set_material(first, 3);
		uint slot = first.index;
		scene.remove(first);

		three::NodeId second = scene.add_mesh(TRIANGLE, 0);
		test::@check(second.index == slot, "the slot was not reused, so this test proved nothing");

		three::Node* node = scene.node(second);
		test::@check(node != null, "the new node resolves");
		test::@check(
			node.material == three::DEFAULT_MATERIAL,
			"a recycled slot came back on material %d instead of the default",
			node.material
		);
		test::@check(
			node.color[0] == 1 && node.color[1] == 1 && node.color[2] == 1 && node.color[3] == 1,
			"a recycled slot came back tinted (%s, %s, %s, %s) instead of white",
			node.color[0], node.color[1], node.color[2], node.color[3]
		);
		test::@check(node.variant == 0, "a recycled slot came back on row %d instead of 0", node.variant);
	};
}

<*
 The per-copy channels reach the instance record, and do not split a bucket.

 **This is the claim the whole feature rests on.** A colour that cost a draw
 call would be no better than a second material, and a colour that never reached
 the `Instance` array would render as white with nothing to say so. So both
 halves are asserted at once: a hundred nodes in a hundred colours, one bucket,
 and the bytes the GPU will read checked against what was set.

 **The instance array is asked for explicitly**, which it did not used to be:
 `stats()` rebuilt the whole list including the records, and reading them off it
 afterwards was free. Since `plan.md` §19.5 it rebuilds the buckets and writes no
 records at all — a query has no reader for 148 bytes a drawable — so this asks
 for a writing build of its own. `stats()` still answers the draw-call half.
*>
fn void a_colour_per_copy_costs_no_draw_call() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		renderer.pass.load_triangle(&renderer.gpu)!!;
		three::Scene* scene = renderer.pass.scene;

		three::NodeId[100] made;
		for (uint i = 0; i < 100; i++)
		{
			made[i] = scene.add_mesh(TRIANGLE, 0);
			scene.set_position(made[i], { (float)i * 2.0f, 0, 0 });
			scene.set_color(made[i], { (float)i / 100.0f, 0.25f, 1.0f - (float)i / 100.0f, 1.0f });
			scene.set_variant(made[i], i % 4);
		}

		three::SceneStats stats = renderer.pass.stats();
		test::@check(stats.draw_calls == 1, "a hundred colours took %d draw calls", stats.draw_calls);
		test::@check(scene.buckets.len() == 1, "and %d buckets", scene.buckets.len());

		// A writing build, with no frustum, which is what `stats()` used to leave
		// behind and now deliberately does not.
		scene.build_draw_list(&renderer.pass.assets, null);

		// The triangle loaded above is instance 0 and is white; the hundred
		// follow it in add order, which is the order `build_draw_list` walks.

		test::@check(scene.instances.len() == 101, "%d instances were written", scene.instances.len());
		for (uint i = 0; i < 100; i++)
		{
			three::Instance* record = &scene.instances[(sz)i + 1];
			test::@check(
				close(record.color[0], (float)i / 100.0f) && close(record.color[2], 1.0f - (float)i / 100.0f),
				"instance %d carries its own colour, got (%s, %s, %s)",
				i, record.color[0], record.color[1], record.color[2]
			);
			test::@check(record.variant == i % 4, "instance %d carries row %d, got %d", i, i % 4, record.variant);
		}
	};
}

<*
 A node starts white on row zero, which is the identity for both channels.

 Worth its own check rather than being assumed by the one above: these are the
 values every scene built before this feature existed implicitly had, and a
 default of black or of an uninitialised slot's leftovers would change how every
 existing scene renders without changing a line of it.
*>
fn void a_node_starts_white_and_on_row_zero() @test
{
	three::Scene scene;
	scene.init();
	defer scene.free();

	three::Node* node = scene.node(scene.add_mesh(TRIANGLE, 0));
	test::@check(node != null, "the node resolves");
	test::@check(
		node.color[0] == 1 && node.color[1] == 1 && node.color[2] == 1 && node.color[3] == 1,
		"a new node is white, got (%s, %s, %s, %s)",
		node.color[0], node.color[1], node.color[2], node.color[3]
	);
	test::@check(node.variant == 0, "a new node is on row 0, got %d", node.variant);
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

		three::Scene* scene = renderer.pass.scene;
		three::NodeId far_away = scene.add_mesh(TRIANGLE, 0);
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
 `stats()` reports what the last frame culled, not what its own rebuild did.

 The defect this pins answered zero from M2 until M6 went looking: `stats()`
 rebuilds the draw list with no frustum on purpose, and the counter it read was
 the one that rebuild had just zeroed. So `culledLastFrame` was zero however much
 the camera dropped, under a field comment promising the last `update`'s number.

 Three injections, and what each one actually did rather than what it looked
 like it would do:

 - **`stats()` reads the working counter** — the original defect. Caught by the
   first check, reporting 0.
 - **The promotion moved inside `build_draw_list`** instead of `update`. Also
   caught by the first check, not the second as expected: zeroing at the top of
   that function means `stats()`'s own rebuild zeroes the field before reading
   it, so it fails in exactly the same place.
 - **One counter that is simply never reset.** Passes the first two checks and
   is caught only by the third, at 1 where 0 is correct — which is why "culling
   off reports zero" is asserted at all.

 The second check — asking twice answers the same — caught nothing the first one
 did not. It is kept as a cheap guard on the specific future mistake of letting
 `stats()` write the field, and it is worth being clear that it is a guard
 rather than a proven catch.

 The instance count is re-checked beside them so a fix that made the cull count
 honest by quietly culling during `stats()` cannot pass.
*>
fn void stats_reports_what_the_last_frame_culled() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		renderer.pass.load_triangle(&renderer.gpu)!!;

		three::Scene* scene = renderer.pass.scene;
		three::NodeId far_away = scene.add_mesh(TRIANGLE, 0);
		scene.set_position(far_away, { 1000, 0, 0 });

		three::Camera camera = three::default_camera();
		camera.frame_bounds({ -0.5, -0.5, 0 }, { 0.5, 0.5, 0 });
		Matrix4f view_projection = camera.view_projection((float)W / (float)H);

		scene.cull = true;
		scene.update(&renderer.pass.assets, view_projection);

		three::SceneStats stats = renderer.pass.stats();
		test::@check(stats.culled_last_frame == 1, "stats() reported %d culled; the frame before it dropped 1", stats.culled_last_frame);
		test::@check(stats.instances == 2, "stats() reported %d instances; it must not depend on the camera", stats.instances);

		// Asking twice must answer the same. `stats()` rebuilds the draw list,
		// so a fix that let that rebuild write the field would read 1 then 0.
		stats = renderer.pass.stats();
		test::@check(stats.culled_last_frame == 1, "the second stats() call reported %d culled; asking is not a frame", stats.culled_last_frame);

		// Culling off is not "no news". Nothing was dropped, and the number has
		// to follow rather than keep reporting a camera that stopped being asked.
		scene.cull = false;
		scene.update(&renderer.pass.assets, view_projection);
		stats = renderer.pass.stats();
		test::@check(stats.culled_last_frame == 0, "with culling off, stats() still reported %d culled", stats.culled_last_frame);
	};
}

// ============================================================================
// Transparent draw ordering
// ============================================================================

<*
 Where a material's bucket landed in the draw list, or -1 if it drew nothing.

 Every ordering check below is "this material is recorded before that one", and
 the bucket index is the only honest handle on it: `Bucket.material` is what
 `MeshPass.record` binds a pipeline from, so this is the same identity the frame
 itself works in rather than a restatement of the sort.
*>
fn int bucket_of(three::Scene* scene, uint material)
{
	foreach (i, bucket : scene.buckets)
	{
		if (bucket.material == material) return (int)i;
	}
	return -1;
}

<*
 A frame with transparency in it may take more draws than `stats()` reports, and
 `stats()` reports the same number whichever way the camera is pointing.

 The number `stats()` answers is a fact about the scene — `culling_drops_what_is_off_screen`
 pinned that against the frustum and this pins it against the sort, which is the
 same claim one axis further along. Back-to-front ordering interleaves two
 transparent materials by depth, and interleaving splits buckets: three
 transparent draws that are two buckets in material order become three when the
 middle one sits between the other two along the view axis. Turn the camera 90
 degrees and the same three stop interleaving and collapse back to two.

 So the frame's bucket count is 4 from one side and 3 from the other, and both
 are correct — that divergence is asserted here rather than assumed, because
 without it the test would pass against a `stats()` that had started depth
 sorting and simply never been given a fixture that noticed.

 What must not move is `stats()`: 3 both times. A `drawCalls` that changed when
 an agent orbited the camera would be unusable as the cost number `plan.md`'s
 second thesis says it is — the reading would depend on where somebody was
 standing when they asked. The price is that `stats()` under-reports a
 transparent scene, and it is a floor rather than an estimate: depth interleaving
 can only ever split a bucket, never merge two.

 **Proved by injection.** `Scene` given `bool[] stats_transparent` and
 `Plane stats_near` fields, written by `update` and read by `stats` in place of
 its `{}` and `null` — which is what "let the query see what the frame saw"
 amounts to: "the camera moved and stats() changed its mind: 4 draws then 3".

 A second injection lands here as well, from the other direction:
 `sorting_transparency_does_not_depend_on_culling`'s — the near plane gated on
 `self.cull` — leaves this fixture unsorted, and it is caught one check earlier
 at "seen along x the interleaved panes are 4 buckets, got 3". Which is the check
 that exists to keep the fixture honest doing its job.
*>
fn void stats_stays_camera_free_with_transparency() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		renderer.pass.load_triangle(&renderer.gpu)!!;

		three::Scene* scene = renderer.pass.scene;
		// Two transparent materials over one mesh. `NO_TEXTURE` is deliberate: the
		// picture is not under test, the ordering is, and this way the fixture
		// needs no image and no shader compile.
		uint glass = renderer.pass.create_texture_material(three::NO_TEXTURE, three::SIDE_FRONT, three::BLENDING_NORMAL)!!;
		uint water = renderer.pass.create_texture_material(three::NO_TEXTURE, three::SIDE_FRONT, three::BLENDING_NORMAL)!!;

		// Laid out so the two axes disagree. Along x the `water` pane sits between
		// the two `glass` ones and the run of glass is broken; along z it sits
		// outside them and the two glass panes are adjacent. Same three nodes,
		// same materials, different number of draws.
		three::NodeId first = scene.add_mesh(TRIANGLE, 0);
		scene.set_material(first, glass);
		scene.set_position(first, { 0, 0, 1 });

		three::NodeId second = scene.add_mesh(TRIANGLE, 0);
		scene.set_material(second, glass);
		scene.set_position(second, { 2, 0, 2 });

		three::NodeId between = scene.add_mesh(TRIANGLE, 0);
		scene.set_material(between, water);
		scene.set_position(between, { 1, 0, 0 });

		// One bool per material index, exactly as `MeshPass.record` builds it.
		// Eight is past the end of a table holding the two built-ins and these two.
		bool[8] table;
		table[glass] = true;
		table[water] = true;

		// Off, so that a node leaving the frustum cannot be mistaken for a bucket
		// the sort merged. The near plane reaches the sort either way — that is
		// `sorting_transparency_does_not_depend_on_culling`'s claim, asserted
		// there rather than relied on here.
		scene.cull = false;

		three::Camera camera = three::default_camera();
		camera.target = { 0, 0, 0 };
		camera.distance = 20;
		camera.pitch = 0;

		camera.yaw = 90;
		scene.update(&renderer.pass.assets, camera.view_projection((float)W / (float)H), table[..]);
		uint along_x = (uint)scene.buckets.len();
		three::SceneStats from_x = renderer.pass.stats();

		camera.yaw = 0;
		scene.update(&renderer.pass.assets, camera.view_projection((float)W / (float)H), table[..]);
		uint along_z = (uint)scene.buckets.len();
		three::SceneStats from_z = renderer.pass.stats();

		test::@check(along_x == 4, "seen along x the interleaved panes are 4 buckets, got %d", along_x);
		test::@check(along_z == 3, "seen along z they collapse to 3, got %d", along_z);

		test::@check(
			from_x.draw_calls == from_z.draw_calls,
			"the camera moved and stats() changed its mind: %d draws then %d",
			from_x.draw_calls, from_z.draw_calls
		);
		test::@check(
			from_x.draw_calls == 3,
			"stats() counts a scene of one opaque triangle and two transparent materials as 3 draws, got %d",
			from_x.draw_calls
		);
		test::@check(from_x.instances == 4, "and finds every instance whatever the camera did, got %d", from_x.instances);
	};
}

<*
 Transparent buckets are sorted farthest first, sit above every opaque bucket and
 below the lines, and the instance array they index is still a clean tiling.

 Three claims and they fail in three different ways, none of which is an error:

 - **Ordering between the transparent buckets.** `ALPHA_STATE` writes no depth,
   so the only thing deciding which pane shows through which is the order they
   were recorded in. Get it backwards and the near pane is blended under the far
   one, which is a picture — just the wrong one.
 - **Transparent above opaque.** A pane recorded before the wall behind it is not
   blended with the wall, it is *overwritten* by it, because the wall does write
   depth and does test it. What that looks like is glass that vanished.
 - **The tiling.** `MeshPass.record` hands the shader `instances + first`, so a
   bucket whose slice overlaps its neighbour draws another bucket's transforms.
   The sort produces the buckets and the instances in one pass, so a comparator
   that reorders the draws without the instances following would show up here and
   nowhere else.

 The near material is created *before* the far one, so its index is lower and
 material order and depth order disagree — a sort that never looked at the depth
 puts them the other way round rather than accidentally right.

 The expectation is computed from `camera.eye()` rather than written down, so
 the check is "the farther one is recorded first" and not "the one at negative z
 is recorded first", which would agree with the implementation for a reason that
 has nothing to do with the camera.

 **Proved by injection.** The comparator's depth branch flipped to nearest-first
 (`a.depth < b.depth` returning -1): "the farther pane is drawn first, got it at
 bucket 2 and the nearer at 1".
*>
fn void a_transparent_scene_sorts_without_moving_instances() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		renderer.pass.load_triangle(&renderer.gpu)!!;

		three::Scene* scene = renderer.pass.scene;
		// Nearer first, so that the lower material index is the one that must sort
		// second. See the doc block.
		uint nearer = renderer.pass.create_texture_material(three::NO_TEXTURE, three::SIDE_FRONT, three::BLENDING_NORMAL)!!;
		uint farther = renderer.pass.create_texture_material(three::NO_TEXTURE, three::SIDE_FRONT, three::BLENDING_NORMAL)!!;

		Vec3 near_at = { 0, 0, 4 };
		Vec3 far_at = { 0, 0, -4 };

		three::NodeId near_pane = scene.add_mesh(TRIANGLE, 0);
		scene.set_material(near_pane, nearer);
		scene.set_position(near_pane, near_at);

		three::NodeId far_pane = scene.add_mesh(TRIANGLE, 0);
		scene.set_material(far_pane, farther);
		scene.set_position(far_pane, far_at);

		// A debug helper, which has to stay on top of the glass as well as on top
		// of the scene — `draw_order` has the argument, and this is the node that
		// makes the transparent band's upper edge assertable.
		three::NodeId helper = scene.add_mesh(TRIANGLE, 0);
		scene.set_material(helper, three::LINE_MATERIAL);

		bool[8] table;
		table[nearer] = true;
		table[farther] = true;

		three::Camera camera = three::default_camera();
		camera.target = { 0, 0, 0 };
		camera.distance = 10;
		camera.yaw = 0;
		camera.pitch = 0;
		Matrix4f view_projection = camera.view_projection((float)W / (float)H);

		scene.update(&renderer.pass.assets, view_projection, table[..]);

		// Which one is actually farther, asked of the camera rather than assumed.
		Vec3 eye = camera.eye();
		test::@check(
			(far_at - eye).length() > (near_at - eye).length(),
			"the fixture puts one pane behind the other: %f against %f",
			(far_at - eye).length(), (near_at - eye).length()
		);

		test::@check(scene.instances.len() == 4, "four nodes drew %d instances", scene.instances.len());
		test::@check(scene.buckets.len() == 4, "four materials over one mesh are 4 buckets, got %d", scene.buckets.len());

		// The slices must tile the instance array exactly once and in order, or a
		// bucket draws somebody else's transforms.
		uint total = 0;
		foreach (bucket : scene.buckets)
		{
			test::@check(bucket.first == total, "bucket starts at %d, expected %d — the slices overlap or leave a gap", bucket.first, total);
			total += bucket.count;
		}
		test::@check(total == (uint)scene.instances.len(), "the buckets cover %d of %d instances", total, scene.instances.len());

		int opaque_at = bucket_of(scene, three::DEFAULT_MATERIAL);
		int near_at_bucket = bucket_of(scene, nearer);
		int far_at_bucket = bucket_of(scene, farther);
		int line_at = bucket_of(scene, three::LINE_MATERIAL);
		test::@check(
			opaque_at >= 0 && near_at_bucket >= 0 && far_at_bucket >= 0 && line_at >= 0,
			"every material drew: opaque %d, near %d, far %d, line %d",
			opaque_at, near_at_bucket, far_at_bucket, line_at
		);

		test::@check(
			far_at_bucket < near_at_bucket,
			"the farther pane is drawn first, got it at bucket %d and the nearer at %d",
			far_at_bucket, near_at_bucket
		);
		test::@check(
			opaque_at < far_at_bucket && opaque_at < near_at_bucket,
			"the opaque triangle is drawn before both panes, got it at bucket %d",
			opaque_at
		);
		test::@check(
			line_at > far_at_bucket && line_at > near_at_bucket,
			"and the helper after both of them, got it at bucket %d",
			line_at
		);
	};
}

<*
 Turning culling off does not turn the depth sort off with it.

 The two share a frustum and nothing else. Culling asks whether a box is inside
 six planes and is a performance choice a script is free to make — `Scene.cull`
 is public and `culling_drops_what_is_off_screen` is what it means. The sort asks
 how far along the view direction a transparent draw sits, and switching it off
 does not make the frame cheaper, it makes it wrong.

 So the near plane goes into `build_draw_list` unconditionally and `self.cull`
 gates the frustum pointer alone. That is one `?:` away from being wrong in a way
 that would be almost impossible to find from the picture: transparency would
 come out correctly ordered in every default scene and reverse itself the moment
 somebody turned culling off to debug something else.

 The same fixture as `a_transparent_scene_sorts_without_moving_instances` and the
 same assertion, made twice with `cull` on and off. The near material's index is
 lower than the far one's, so the fallback the injection produces — no near
 plane, so every transparent draw at depth zero and the tie broken by material —
 is the exact reverse of the right answer rather than a coin flip.

 **Proved by injection.** `Scene.update` passing `self.cull ? &frustum.planes[4] : null`:
 "with culling off the farther pane is still drawn first, got it at bucket 2 and
 the nearer at 1".
*>
fn void sorting_transparency_does_not_depend_on_culling() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		renderer.pass.load_triangle(&renderer.gpu)!!;

		three::Scene* scene = renderer.pass.scene;
		uint nearer = renderer.pass.create_texture_material(three::NO_TEXTURE, three::SIDE_FRONT, three::BLENDING_NORMAL)!!;
		uint farther = renderer.pass.create_texture_material(three::NO_TEXTURE, three::SIDE_FRONT, three::BLENDING_NORMAL)!!;

		three::NodeId near_pane = scene.add_mesh(TRIANGLE, 0);
		scene.set_material(near_pane, nearer);
		scene.set_position(near_pane, { 0, 0, 4 });

		three::NodeId far_pane = scene.add_mesh(TRIANGLE, 0);
		scene.set_material(far_pane, farther);
		scene.set_position(far_pane, { 0, 0, -4 });

		bool[8] table;
		table[nearer] = true;
		table[farther] = true;

		three::Camera camera = three::default_camera();
		camera.target = { 0, 0, 0 };
		camera.distance = 10;
		camera.yaw = 0;
		camera.pitch = 0;
		Matrix4f view_projection = camera.view_projection((float)W / (float)H);

		scene.cull = true;
		scene.update(&renderer.pass.assets, view_projection, table[..]);
		test::@check(scene.culled == 0, "the fixture is entirely on screen, %d instances were culled", scene.culled);
		test::@check(
			bucket_of(scene, farther) < bucket_of(scene, nearer),
			"with culling on the farther pane is drawn first, got it at bucket %d and the nearer at %d",
			bucket_of(scene, farther), bucket_of(scene, nearer)
		);

		scene.cull = false;
		scene.update(&renderer.pass.assets, view_projection, table[..]);
		test::@check(
			bucket_of(scene, farther) < bucket_of(scene, nearer),
			"with culling off the farther pane is still drawn first, got it at bucket %d and the nearer at %d",
			bucket_of(scene, farther), bucket_of(scene, nearer)
		);
	};
}

<*
 A rendered frame sorts by what the materials actually are, not by what the
 scene was told.

 The other three checks in this section hand `Scene.update` a table they built
 themselves, which pins the sort and says nothing about where a real frame's
 table comes from. This one renders through `MeshPass.record` and never mentions
 transparency to the scene at all: the only thing that can put these two buckets
 in the right order is `record` reading `Material.blend` off its own table and
 handing the answer across.

 The transparent material is created **first**, so it holds the lower index. That
 is what makes the failure visible rather than lucky: with no table the sort falls
 back to the material index, which puts the glass before the wall it is supposed
 to be seen through — and since `ALPHA_STATE` writes no depth, the wall then
 overwrites the glass entirely. A frame that renders with no error and no glass
 in it is the failure mode this whole ordering exists to prevent.

 `Scene` still knows nothing about `MeshPass.materials` — the boundary
 `Scene.set_material` documents — and that is the point of asserting on the
 finished bucket order instead of on the slice: what crosses is one bit per
 index, and this is the check that it crosses at all.

 **Proved by injection.** The table dropped from the call in `MeshPass.record`,
 leaving `self.scene.update(&self.assets, view_projection)` — the frame as it was
 written before blending existed: "the wall is drawn before the glass, got the
 wall at bucket 2 and the glass at 1".
*>
fn void a_rendered_frame_learns_which_materials_blend() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		renderer.pass.load_triangle(&renderer.gpu)!!;
		three::Scene* scene = renderer.pass.scene;

		uint glass = renderer.pass.create_texture_material(three::NO_TEXTURE, three::SIDE_FRONT, three::BLENDING_NORMAL)!!;
		uint wall = renderer.pass.create_texture_material(three::NO_TEXTURE, three::SIDE_FRONT, three::BLENDING_NONE)!!;
		test::@check(glass < wall, "the transparent material holds the lower index, %d against %d", glass, wall);

		three::NodeId pane = scene.add_mesh(TRIANGLE, 0);
		scene.set_material(pane, glass);
		scene.set_position(pane, { 0, 0, 1 });

		three::NodeId behind = scene.add_mesh(TRIANGLE, 0);
		scene.set_material(behind, wall);
		scene.set_position(behind, { 0, 0, -1 });

		// The camera was fitted to the triangle `load_triangle` placed, not to
		// these two. Culling off keeps the fixture about ordering.
		scene.cull = false;
		renderer.render_offscreen()!!;

		test::@check(
			bucket_of(scene, wall) < bucket_of(scene, glass),
			"the wall is drawn before the glass, got the wall at bucket %d and the glass at %d",
			bucket_of(scene, wall), bucket_of(scene, glass)
		);
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

		three::Scene* scene = renderer.pass.scene;
		three::NodeId behind = scene.add_mesh(TRIANGLE, 0);
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

		three::Scene* scene = renderer.pass.scene;
		three::NodeId only = scene.buckets.len() >= 0 ? scene.add_mesh(TRIANGLE, 0) : three::NO_NODE;
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

		three::Scene* scene = renderer.pass.scene;
		// `place` instantiates into a group since G3, so the drawing node is a
		// level further down than it was.
		three::NodeId placed = scene.node(scene.root).children[0];
		three::NodeId centred = scene.node(placed).children[0];

		// A second copy well off to the left, so a raycast that ignores the
		// screen position entirely still has something wrong to return.
		three::NodeId beside = scene.add_mesh(TRIANGLE, 0);
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

<*
 A ray cast through a pixel comes back to the middle of that pixel.

 `screen_ray` unprojects and `view_projection` projects, so sending a hit point
 back through the matrix the renderer draws with has to land where the pick
 started. That makes the check exact — no rasterizer, no tolerance beyond
 floating point — and it pins the half-pixel that the rest of this suite cannot
 see: the rasterizer decides coverage at a pixel's *centre*, so a picker that
 casts through its corner is biased by half a pixel, always the same way.

 That bias is what this was written against. Comparing picks against rendered
 pixels catches it too, but only when a triangle edge happens to fall in the
 right half of a pixel — one column in a hundred and sixty, on one particular
 camera. This catches it on every pixel it tries.

 Several pixels rather than one, and none of them the centre: at the exact
 middle of an even-sized image the half cancels against the symmetry and a
 picker with no half at all passes.
*>
fn void a_pick_returns_to_the_middle_of_the_pixel_it_named() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		renderer.pass.load(&renderer.gpu, FIXTURE)!!;

		three::Camera camera = three::default_camera();
		camera.target = { 0, 0, 0 };
		camera.yaw = 0;
		camera.pitch = 0;
		camera.distance = 4;

		float aspect = (float)W / (float)H;
		Matrix4f view_projection = camera.view_projection(aspect);

		uint[4] columns = { 0, 37, 100, W - 1 };
		uint[4] rows = { 0, 22, 75, H - 1 };

		foreach (i, column : columns)
		{
			uint row = rows[i];
			collision::Ray ray = three::screen_ray(&camera, (float)column, (float)row, W, H);

			// One unit along the ray is as good as any other point on it: the
			// projection of every point on a ray through the eye is the same
			// pixel, which is what makes this independent of what is in the way.
			Vec3 point = ray.origin + ray.direction;
			float[<4>] homogeneous = { point.x, point.y, point.z, 1.0f };
			float[<4>] clip = view_projection * homogeneous;

			test::@check(math::abs(clip[3]) > 1e-6f, "pixel (%d, %d) projected to a degenerate w", column, row);

			// Vulkan's viewport transform, with the viewport `gpu/target.c3`
			// actually binds: `.y = height, .height = -height`. That gives
			//
			//     y_framebuffer = y_vp + h_vp * (ndc_y + 1) / 2
			//                   = height - height * (ndc_y + 1) / 2
			//                   = height * (1 - ndc_y) / 2
			//
			// so the row axis runs *opposite* to NDC +Y. Writing the y mapping
			// the same way as the x one is what let a flipped `screen_ray` pass
			// this check for a whole milestone: the round trip cancelled a sign
			// error that both halves of it shared. See
			// `a_pick_agrees_with_the_pixels_it_was_counted_in`, which asks the
			// rendered frame instead of asking this test's own arithmetic.
			float back_x = ((clip[0] / clip[3]) * 0.5f + 0.5f) * (float)W;
			float back_y = (1.0f - (clip[1] / clip[3])) * 0.5f * (float)H;

			test::@check(
				close(back_x, (float)column + 0.5f, 0.01f),
				"a ray through column %d came back at %f, expected %f — the ray is not going through the pixel's centre",
				column, back_x, (float)column + 0.5f
			);
			test::@check(
				close(back_y, (float)row + 0.5f, 0.01f),
				"a ray through row %d came back at %f, expected %f",
				row, back_y, (float)row + 0.5f
			);
		}
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

		three::Scene* scene = renderer.pass.scene;
		for (uint i = 0; i < 200; i++)
		{
			three::NodeId node = scene.add_mesh(TRIANGLE, 0);
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

		three::Scene* scene = renderer.pass.scene;
		three::NodeId towards = scene.node(scene.root).children[0];
		three::NodeId away = scene.add_mesh(TRIANGLE, 0);

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

		three::Scene* scene = renderer.pass.scene;
		three::NodeId left = scene.node(scene.root).children[0];
		three::NodeId right = scene.add_mesh(TRIANGLE, 0);
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

<*
 Two draws with different descriptors each get the one they pushed.

 `plan.md`'s M0/M1 findings recorded that KosmicKrisp's `vkCmdPushDescriptorSetKHR`
 "breaks subsequent draws when descriptorWriteCount > 0". M5 moved the entire
 texture path onto that call, so that finding has to be re-measured rather than
 assumed stale — it was the stated reason the extension was left out.

 The sharpest case available: the 1x1 white stand-in and a real texture, which
 are two genuinely different descriptors pushed back to back. A driver that let
 the first push leak into the second would draw the textured quads white, or the
 triangle textured.

 Self-calibrating rather than asserting colour constants. Each half is rendered
 alone to learn what it looks like, then both together, and every pixel either
 half painted must be unchanged by the other's presence. That needs the two not
 to overlap, which is what the triangle's offset is for.
*>
fn void two_draws_with_different_textures_do_not_bleed() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		renderer.pass.load(&renderer.gpu, FIXTURE)!!;
		three::AssetId triangle = renderer.pass.assets.load_triangle(&renderer.gpu)!!;

		three::Scene* scene = renderer.pass.scene;
		three::NodeId tri = scene.add_mesh(triangle, 0);
		scene.set_position(tri, { 0, 2.2, 0 });

		// Every node the fixture placed, so they can be hidden as a group.
		three::NodeId[2] quads;
		uint found = 0;
		foreach (slot, &node : scene.nodes)
		{
			if (!node.alive || node.asset.index != 0 || node.mesh == three::NO_MESH) continue;
			if (found < 2) quads[found++] = { .index = (uint)slot, .generation = node.generation };
		}
		test::@check(found == 2, "the fixture placed %d quads, expected 2", found);

		renderer.pass.camera.target = { 0, 1, 0 };
		renderer.pass.camera.yaw = 0;
		renderer.pass.camera.pitch = 0;
		renderer.pass.camera.distance = 8;

		// The triangle alone.
		foreach (id : quads) scene.set_visible(id, false);
		renderer.render_offscreen()!!;
		image::Image alone_tri = renderer.capture()!!;
		defer alone_tri.free();

		// The textured quads alone.
		scene.set_visible(tri, false);
		foreach (id : quads) scene.set_visible(id, true);
		renderer.render_offscreen()!!;
		image::Image alone_quads = renderer.capture()!!;
		defer alone_quads.free();

		// Both, which is two buckets and two different descriptors.
		scene.set_visible(tri, true);
		renderer.render_offscreen()!!;
		image::Image both = renderer.capture()!!;
		defer both.free();

		float[4] clear = renderer.clear;
		uint tri_pixels = count_drawn(&alone_tri, clear);
		uint quad_pixels = count_drawn(&alone_quads, clear);
		test::@check(tri_pixels > 100, "the triangle drew %d pixels on its own", tri_pixels);
		test::@check(quad_pixels > 100, "the quads drew %d pixels on their own", quad_pixels);

		uint changed_tri = 0;
		uint changed_quads = 0;
		for (sz i = 0; i < both.pixels.len; i += 4)
		{
			bool tri_here = alone_tri.pixels[i] != both.pixels[i]
				|| alone_tri.pixels[i + 1] != both.pixels[i + 1]
				|| alone_tri.pixels[i + 2] != both.pixels[i + 2];
			bool quad_here = alone_quads.pixels[i] != both.pixels[i]
				|| alone_quads.pixels[i + 1] != both.pixels[i + 1]
				|| alone_quads.pixels[i + 2] != both.pixels[i + 2];

			// A pixel the triangle painted must look the same with the quads there.
			int dr = (int)alone_tri.pixels[i] - (int)(char)(uint)(clear[0] * 255.0 + 0.5);
			int dg = (int)alone_tri.pixels[i + 1] - (int)(char)(uint)(clear[1] * 255.0 + 0.5);
			int db = (int)alone_tri.pixels[i + 2] - (int)(char)(uint)(clear[2] * 255.0 + 0.5);
			if (dr * dr + dg * dg + db * db > 12 && tri_here) changed_tri++;

			int qr = (int)alone_quads.pixels[i] - (int)(char)(uint)(clear[0] * 255.0 + 0.5);
			int qg = (int)alone_quads.pixels[i + 1] - (int)(char)(uint)(clear[1] * 255.0 + 0.5);
			int qb = (int)alone_quads.pixels[i + 2] - (int)(char)(uint)(clear[2] * 255.0 + 0.5);
			if (qr * qr + qg * qg + qb * qb > 12 && quad_here) changed_quads++;
		}

		test::@check(
			changed_tri == 0,
			"%d of the triangle's pixels changed once a textured draw joined it — the pushed descriptor bled",
			changed_tri
		);
		test::@check(
			changed_quads == 0,
			"%d of the quads' pixels changed once the untextured draw joined them — the pushed descriptor bled",
			changed_quads
		);
	};
}

// ============================================================================
// The vertex stage, where it meets the draw list
//
// Two claims that only pixels can settle: that a `displace` body moves geometry
// on the screen without moving the node, and that `material.bounds` is what keeps
// the moved geometry from being culled. The second is the one with no other
// symptom — a body with no bounds renders perfectly until the camera turns.
// ============================================================================

// Unlit and flat on purpose: the light is straight down the view axis at full
// ambient, so the quad is exactly its own colour and a pixel test is about where
// the geometry is rather than about how it is shaded.
const String FLAT_GREEN = `float3 shade(Surface s) { return float3(0.1, 0.95, 0.2); }`;
const String SHIFT_X = `void displace(inout Vertex v) { v.position.x += shift; }`;

<*
 The mean x of everything that drew, as a fraction of the frame's width, and how
 many pixels that was.

 A centroid rather than `count_drawn` because the question here is *where* the
 geometry is: a displacement that moved a quad and one that did nothing both draw
 the same number of pixels.
*>
fn float drawn_centroid_x(image::Image* shot, uint* count)
{
	sz bpp = shot.bytes_per_pixel();
	double total = 0;
	uint drawn = 0;
	for (sz y = 0; y < (sz)shot.height; y++)
	{
		for (sz x = 0; x < (sz)shot.width; x++)
		{
			if (shot.pixels[(y * (sz)shot.width + x) * bpp + 1] < 100) continue;
			total += (double)x;
			drawn++;
		}
	}
	*count = drawn;
	return drawn == 0 ? 0 : (float)(total / (double)drawn / (double)shot.width);
}

<*
 A vertex body moves geometry on the screen, and the node does not move with it.

 The second half is what makes this a test of the vertex stage rather than of
 anything else: `Node.position` is untouched throughout, so a displacement that
 was quietly happening on the CPU — or not happening at all — cannot produce this.
 The quad is drawn three times through one material and one geometry, with a
 4-byte uniform write between them.

 Symmetric offsets rather than one, because a body that ignored the uniform and a
 body that applied it to a fixed direction both survive a single check.

 **Proved by injection.** `vertexMain` building `sv_position` from `world` rather
 than from `v.position` — the quad stays at 0.5 in all three frames, which is
 exactly what a vertex stage nobody wired up looks like.
*>
fn void a_vertex_body_moves_geometry_without_moving_the_node() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::MeshPass* pass = &renderer.pass;
		pass.lighting = { .count = 1, .ambient = 1, .lights = { { .direction = { 0, 0, 1, 0 }, .color = { 1, 1, 1, 1 } }, {}, {}, {} } };

		uint material;
		@pool()
		{
			three::MaterialUniform[1] uniforms = { { "shift", 1, 1 } };
			material = pass.create_material(
				&renderer.gpu, &renderer.target, FLAT_GREEN, uniforms[..],
				three::SIDE_DOUBLE, three::BLENDING_NONE, {}, SHIFT_X, 8.0
			)!!;
		};

		three::AssetId quad = pass.assets.primitive(&renderer.gpu, three::plane_shape(2, 2))!!;
		three::NodeId node = pass.scene.add_mesh(quad, 0);
		pass.scene.set_material(node, material);
		pass.camera.target = { 0, 0, 0 };
		pass.camera.yaw = 0;
		pass.camera.pitch = 0;
		pass.camera.distance = 14;

		uint at_rest;
		image::Image centred = renderer.capture()!!;
		defer centred.free();
		float x0 = drawn_centroid_x(&centred, &at_rest);
		test::@check(at_rest > 100, "the quad drew at all: %d pixels", at_rest);
		test::@check(math::abs(x0 - 0.5) < 0.02, "and starts centred, at %f", x0);

		uint moved_count;
		pass.material(material).set_uniform("shift", (float[]) { 3.0 })!!;
		image::Image right = renderer.capture()!!;
		defer right.free();
		float x1 = drawn_centroid_x(&right, &moved_count);

		pass.material(material).set_uniform("shift", (float[]) { -3.0 })!!;
		image::Image left = renderer.capture()!!;
		defer left.free();
		uint back_count;
		float x2 = drawn_centroid_x(&left, &back_count);

		test::@check(x1 > x0 + 0.08, "a positive shift moved the quad right: %f -> %f", x0, x1);
		test::@check(x2 < x0 - 0.08, "and a negative one moved it left: %f -> %f", x0, x2);
		// The same amount of geometry throughout: this moved the quad rather than
		// scaling, skewing or clipping it.
		test::@check(
			moved_count > at_rest * 9 / 10 && moved_count < at_rest * 11 / 10,
			"drawing the same quad either way: %d against %d", moved_count, at_rest
		);

		// The node never moved. A displacement that had leaked into the transform
		// would read identically on screen and completely differently here.
		test::@check(pass.scene.node(node).position.x == 0,
			"the node is still at the origin: %f", pass.scene.node(node).position.x);
	};
}

<*
 `material.bounds` is what keeps displaced geometry from being culled.

 **The failure this exists for has no other symptom.** `build_draw_list` tests a
 mesh's own bounds against the frustum, and those describe the geometry as it was
 uploaded — so a body that pushes vertices outside them draws something the
 frustum was never told about. Nothing errors; the draw is simply dropped, and
 what an agent sees is geometry vanishing near the edge of the view and returning
 when the camera turns.

 The fixture makes it total rather than marginal: the node sits thirty units off
 to the left, entirely outside the frustum, and the body brings it back to the
 middle of the screen. With no margin the frustum sees a box thirty units away and
 drops it — the frame is empty. With a margin wider than the displacement the box
 reaches the camera and the quad draws where the body put it.

 **Proved by injection.** The margin lookup removed from `build_draw_list`: the
 second half of this drops to zero pixels while every other check in the suite
 stays green, because nothing else in it displaces anything.
*>
fn void a_displacement_is_culled_unless_the_material_says_how_far() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::MeshPass* pass = &renderer.pass;
		pass.lighting = { .count = 1, .ambient = 1, .lights = { { .direction = { 0, 0, 1, 0 }, .color = { 1, 1, 1, 1 } }, {}, {}, {} } };
		pass.camera.target = { 0, 0, 0 };
		pass.camera.yaw = 0;
		pass.camera.pitch = 0;
		pass.camera.distance = 14;

		three::AssetId quad = pass.assets.primitive(&renderer.gpu, three::plane_shape(2, 2))!!;

		// Two materials over one body, differing only in what they claim about how
		// far it moves things — which is the whole variable under test.
		uint unbounded;
		uint bounded;
		@pool()
		{
			three::MaterialUniform[1] uniforms = { { "shift", 1, 1 } };
			unbounded = pass.create_material(
				&renderer.gpu, &renderer.target, FLAT_GREEN, uniforms[..],
				three::SIDE_DOUBLE, three::BLENDING_NONE, {}, SHIFT_X, 0.0
			)!!;
			bounded = pass.create_material(
				&renderer.gpu, &renderer.target, FLAT_GREEN, uniforms[..],
				three::SIDE_DOUBLE, three::BLENDING_NONE, {}, SHIFT_X, 32.0
			)!!;
		};
		pass.material(unbounded).set_uniform("shift", (float[]) { 30.0 })!!;
		pass.material(bounded).set_uniform("shift", (float[]) { 30.0 })!!;

		three::NodeId node = pass.scene.add_mesh(quad, 0);
		pass.scene.set_position(node, { -30, 0, 0 });
		pass.scene.set_material(node, unbounded);

		image::Image dropped = renderer.capture()!!;
		defer dropped.free();
		uint without = count_drawn(&dropped, renderer.clear);
		test::@check(without == 0,
			"a material claiming no displacement is culled where its geometry is: %d pixels", without);

		pass.scene.set_material(node, bounded);

		image::Image kept = renderer.capture()!!;
		defer kept.free();
		uint with = count_drawn(&kept, renderer.clear);
		test::@check(with > 100,
			"and one that says how far survives to draw where the body put it: %d pixels", with);
	};
}

// ============================================================================
// What a frame stopped paying for — plan.md §19.5
// ============================================================================

<*
 The world-matrix walk skips itself when there is nothing to walk.

 **`Node.dirty` never saved the walk, only the arithmetic**, and a frame does
 this three to five times: once for `Scene.bounds`, once for a follow camera,
 once inside `Scene.update`, and once more for every bounding box a script asks
 for. On the reference village that is several thousand recursive calls with a
 64-byte matrix copied by value into each one, four times over, to discover that
 nothing moved.

 Asserted behaviourally rather than by reading the flag: the world matrix is
 written by hand between two walks, and the second walk has to leave it alone.
 A walk that ran would overwrite it from the local transform, which is exactly
 what makes this a check on the skip rather than on a bool.

 The last two lines are the other half and the one that matters more: `touch`
 has to bring the walk back. Since §19.5 it is what makes a hand-written
 transform land at all — `Scene.touch` says so at length — and a version of this
 change that skipped correctly and never came back would pass every check above
 it in this file.
*>
fn void the_world_matrix_walk_skips_itself() @test
{
	three::Scene scene;
	scene.init();
	defer scene.free();

	three::NodeId node = scene.add_group();
	scene.set_position(node, { 1, 0, 0 });
	scene.update_world_matrices();
	test::@check(scene.node(node).world.m[12] == 1.0f, "the first walk placed it");

	// Nothing has moved, so the second walk has nothing to do — and proving that
	// means catching it doing something.
	scene.node(node).world = matrix::IDENTITY4{float};
	scene.update_world_matrices();
	test::@check(
		scene.node(node).world.m[12] == 0.0f,
		"the repeat walked anyway and rewrote the matrix to %s", scene.node(node).world.m[12]
	);

	scene.touch(node);
	scene.update_world_matrices();
	test::@check(
		scene.node(node).world.m[12] == 1.0f,
		"and touch brought the walk back, got %s", scene.node(node).world.m[12]
	);
}

<*
 The cached bounds notice every way a scene can move.

 **The invalidation is the whole of the risk**, which is why `plan.md` §19.5
 wrote the fix down and did not make it: `Scene.bounds` transforms every vertex
 of every drawable node, so caching it is worth 100k–370k matrix multiplies a
 frame, and getting the invalidation wrong is a shadow fitted around the wrong
 region and a camera framed on the wrong thing — neither of which announces
 itself.

 So this walks the five doors a scene changes through, and each one has to move
 the answer: a setter, a hand-written transform followed by `touch`, a node
 added, a *parent* moved, and a subtree removed. The fourth is the one a naive
 version gets wrong, because the node that moved is not the node that draws.
*>
fn void the_bounds_cache_notices_every_way_a_scene_moves() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		renderer.pass.load_triangle(&renderer.gpu)!!;
		three::Scene* scene = renderer.pass.scene;
		three::Assets* assets = &renderer.pass.assets;

		three::NodeId first = scene.add_mesh(TRIANGLE, 0);
		collision::Aabb3 start = scene.bounds(assets);
		test::@check(start.max.x < 5.0f, "the triangle starts near the origin: %s", start.max.x);

		scene.set_position(first, { 10, 0, 0 });
		test::@check(scene.bounds(assets).max.x > 9.0f, "a setter moved the box: %s", scene.bounds(assets).max.x);

		// Written by hand, which is legal and is what `touch` exists for.
		scene.node(first).position = { 30, 0, 0 };
		scene.touch(first);
		test::@check(scene.bounds(assets).max.x > 29.0f, "and touch moved it: %s", scene.bounds(assets).max.x);

		three::NodeId second = scene.add_mesh(TRIANGLE, 0);
		scene.set_position(second, { 0, 50, 0 });
		test::@check(scene.bounds(assets).max.y > 49.0f, "a new node grew it: %s", scene.bounds(assets).max.y);

		// The case a version that only asked the node it was handed would miss:
		// the group is not drawable and has no bounds of its own.
		three::NodeId yard = scene.add_group();
		scene.set_parent(second, yard);
		scene.set_position(yard, { 0, 0, 70 });
		test::@check(scene.bounds(assets).max.z > 69.0f, "moving a parent moved it: %s", scene.bounds(assets).max.z);

		scene.remove(yard);
		test::@check(scene.bounds(assets).max.z < 5.0f, "and removing the subtree shrank it: %s", scene.bounds(assets).max.z);
	};
}

<*
 `stats()` counts the buckets and writes no instance records.

 **A query has no reader for 148 bytes a drawable.** `plan.md` §19.5 found this
 call building the whole instance array — 635 KB on the reference village — to
 report numbers every one of which comes off the buckets, after every script an
 agent runs. The array is left empty now, and the numbers are the same numbers.

 Both halves are asserted together on purpose. "It reports the same counts" alone
 would pass if nothing had changed; "the array is empty" alone would pass if the
 build had simply stopped working. The frame at the end is the third: a query
 that left the draw list in a state the next frame could not use would be a much
 worse trade than the one it saves.
*>
fn void stats_counts_without_writing_the_instance_array() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		renderer.pass.load_triangle(&renderer.gpu)!!;
		three::Scene* scene = renderer.pass.scene;

		for (uint i = 0; i < 100; i++)
		{
			three::NodeId made = scene.add_mesh(TRIANGLE, 0);
			scene.set_position(made, { (float)i * 2.0f, 0, 0 });
		}

		three::SceneStats stats = renderer.pass.stats();
		test::@check(stats.draw_calls == 1, "a hundred and one copies took %d draw calls", stats.draw_calls);
		test::@check(stats.instances == 101, "over %d instances", stats.instances);
		test::@check(
			scene.instances.len() == 0,
			"and wrote %d instance records for a query that reads none", scene.instances.len()
		);

		// The list the query did not build is the list the next frame builds.
		// Culling off so the number is about the rebuild rather than about where
		// the camera happens to point — which is the same reason `stats()` turns
		// it off, one function over.
		scene.cull = false;
		image::Image shot = renderer.capture()!!;

		defer shot.free();
		test::@check(
			scene.instances.len() == 101,
			"the frame after built them, %d of them", scene.instances.len()
		);
	};
}
