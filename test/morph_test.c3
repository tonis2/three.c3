<*
 Morph targets — `plan.md` §3.

	`c3c test --trust=full --test-noleak --test-filter three_tests::morph`

 The fixture is `test/fixtures/morph.glb`, written by
 `test/fixtures/make_morph.py`, and every number in it was chosen so a check here
 can be done by hand:

 - the base is a unit quad in the XY plane,
 - target 0 (`slide`) moves every vertex two units along **X**,
 - target 1 (`rise`) moves every vertex three units along **Y**,
 - the clip `open` drives target 0 from 0 to 1 over one second and leaves target 1
   alone.

 Two axes and one clip that touches only one of them, because the failures worth
 catching all look like "it morphed": a weight written into the wrong element, a
 target read from the wrong block, or a displacement applied as an absolute
 position would each move the quad — and only one of them moves it the right way.
*>
module three_tests::morph;

import three;
import vk;
import image;
import std::core::test;
import std::io;
import std::io::file;
import std::math;
import std::math::vector;

const String FIXTURE = "test/fixtures/morph.glb";

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

<*
 The same device, with a script runtime over it — for the half of this that has
 to go through the prelude.
*>
macro @with_gpu_js(; @body(three::JsRuntime* run))
{
	vk::Instance instance = three::create_instance(false, headless: true)!!;
	defer instance.free();

	three::Renderer renderer;
	renderer.init(instance, (vk::SurfaceKHR)null, W, H)!!;
	defer renderer.free();

	renderer.pass.init(&renderer.gpu, &renderer.target)!!;

	three::JsRuntime runtime;
	runtime.open(&renderer.pass, &renderer)!!;
	defer runtime.close();

	@body(&runtime);
}

// ============================================================================
// The data
// ============================================================================

<*
 The targets are read off the file and uploaded with the geometry.

 The cheap half, and the one everything else indexes through: a mesh that came
 back with one target, or none, poses correctly and displaces by the wrong block.
*>
fn void the_targets_are_read_from_the_file() @test
{
	test::@check(file::is_file(FIXTURE), "%s is missing — regenerate it with test/fixtures/make_morph.py", FIXTURE);

	@with_pass(; three::Renderer* renderer)
	{
		three::AssetId id = renderer.pass.assets.load(&renderer.gpu, FIXTURE)!!;
		// A file is described at load and uploaded when something draws it, so the
		// buffer is not there until a node names the mesh.
		renderer.pass.scene.instantiate(id);
		renderer.render_offscreen()!!;

		three::GpuMesh* mesh = renderer.pass.assets.mesh(id, 0);
		test::@check(mesh != null, "the fixture's mesh uploaded");
		if (mesh == null) return;

		test::@check(mesh.morph_targets == 2, "two targets, got %d", mesh.morph_targets);
		test::@check(mesh.morph.buffer != null, "and the displacements reached the device");
		test::@check(mesh.vertex_count == 4, "the quad has four vertices, got %d", mesh.vertex_count);
	};
}

<*
 The mesh's box opens up by as much as a target can move it.

 A box measured from the base positions alone culls a fully-morphed quad the
 moment the camera looks slightly away from it — and the bug that produces is a
 face that vanishes at the edge of the screen, which reads as a renderer fault
 rather than as a bounds one.

 The reach is the componentwise maximum over targets — two along X from `slide`
 and three along Y from `rise` — rather than their sum, and
 `grow_bounds_by_morph` has the argument for why.
*>
fn void the_bounds_open_up_by_the_targets() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::AssetId id = renderer.pass.assets.load(&renderer.gpu, FIXTURE)!!;
		renderer.pass.scene.instantiate(id);
		renderer.render_offscreen()!!;

		three::GpuMesh* mesh = renderer.pass.assets.mesh(id, 0);
		if (mesh == null) return;

		// Base is 0..1 on both axes; the reach is 2 on X and 3 on Y.
		test::@check(
			math::abs(mesh.bounds.min.x + 2.0f) < 0.001f && math::abs(mesh.bounds.max.x - 3.0f) < 0.001f,
			"x runs %f..%f, expected -2..3", mesh.bounds.min.x, mesh.bounds.max.x
		);
		test::@check(
			math::abs(mesh.bounds.min.y + 3.0f) < 0.001f && math::abs(mesh.bounds.max.y - 4.0f) < 0.001f,
			"y runs %f..%f, expected -3..4", mesh.bounds.min.y, mesh.bounds.max.y
		);
	};
}

// ============================================================================
// The weights
// ============================================================================

<*
 A mesh with no targets has no weights to set, and says so.
*>
fn void a_mesh_without_targets_takes_no_weights() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Scene* scene = renderer.pass.scene;
		three::AssetId box = renderer.pass.assets.primitive(&renderer.gpu, three::box_shape(1, 1, 1))!!;
		three::NodeId node = scene.add_mesh(box, 0);

		test::@check(scene.morph_target_count(node) == 0, "a box reports morph targets");
		test::@check(!scene.set_morph_weights(node, (float[]) { 1 }), "and it took a weight anyway");
	};
}

<*
 An all-zero vector takes the copy back off the morph path.

 Not tidiness: `Instance.morph` of zero is what the shader tests to skip the loop
 entirely, so a face that has finished its expression stops costing anything at
 all rather than costing a loop over multiplications by zero. A weight table that
 kept every mesh that had ever morphed would make that test useless.
*>
fn void clearing_the_weights_leaves_the_morph_path() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Scene* scene = renderer.pass.scene;
		three::AssetId id = renderer.pass.assets.load(&renderer.gpu, FIXTURE)!!;
		three::NodeId root = scene.instantiate(id);
		three::NodeId face = node_at(scene, root, "Face");

		test::@check(scene.morph_target_count(face) == 2, "the face has two targets");
		test::@check(scene.set_morph_weights(face, (float[]) { 0.5f, 0 }), "and takes a weight");
		test::@check(scene.morphs.len() == 1, "one entry in the table, got %d", scene.morphs.len());

		scene.set_morph_weights(face, (float[]) { 0, 0 });
		test::@check(scene.morphs.len() == 0, "back to nothing, got %d entries", scene.morphs.len());
	};
}

<*
 A weight vector shorter than the target list leaves the rest where they are.

 What makes `set([1])` on a twenty-target face one call rather than twenty numbers
 a script has to carry along.
*>
fn void a_short_weight_vector_leaves_the_rest() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Scene* scene = renderer.pass.scene;
		three::AssetId id = renderer.pass.assets.load(&renderer.gpu, FIXTURE)!!;
		three::NodeId face = node_at(scene, scene.instantiate(id), "Face");

		scene.set_morph_weights(face, (float[]) { 0.25f, 0.75f });
		scene.set_morph_weights(face, (float[]) { 1.0f });

		float[] held = scene.morph_weights(face);
		test::@check(held.len == 2, "two weights are held, got %d", held.len);
		if (held.len < 2) return;
		test::@check(held[0] == 1.0f, "the first was written, got %f", held[0]);
		test::@check(held[1] == 0.75f, "and the second was left, got %f", held[1]);
	};
}

// ============================================================================
// The displacement, all the way through
// ============================================================================

<*
 A weight moves what is drawn.

 **The check the whole feature rests on**, and the only one that goes through the
 shader: every check above could pass with a renderer that reads the targets,
 uploads them and never displaces a vertex.

 The camera is fitted once, before either capture, so the comparison is about the
 quad rather than about the fit. `slide` moves it two units along +X and nothing
 else, so both edges of the silhouette have to move right — the whole quad
 translates rather than stretching, which is what having two edges to check
 separates.

 A *fraction* of the target rather than all of it, because the fit is around the
 neutral quad and two units is more than a viewport: at full weight the quad is
 correctly displaced right off the side of the picture, and "drew nothing" is not
 an answer this can read.
*>
fn void a_weight_moves_what_is_drawn() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Scene* scene = renderer.pass.scene;
		three::AssetId id = renderer.pass.assets.load(&renderer.gpu, FIXTURE)!!;
		three::NodeId face = node_at(scene, scene.instantiate(id), "Face");
		renderer.pass.frame_camera();

		image::Image neutral_shot = renderer.capture()!!;
		Silhouette neutral = measure(&neutral_shot, renderer.clear);
		neutral_shot.free();
		test::@check(neutral.drawn > 0, "the neutral quad rasterises something");

		scene.set_morph_weights(face, (float[]) { 0.15f, 0 });

		image::Image slid_shot = renderer.capture()!!;
		Silhouette slid = measure(&slid_shot, renderer.clear);
		slid_shot.free();

		test::@check(slid.drawn > 0, "and so does the morphed one");
		test::@check(
			slid.leftmost > neutral.leftmost && slid.rightmost > neutral.rightmost,
			"the quad ran %d..%d neutral and %d..%d displaced — if these are equal the weight never reached the shader",
			neutral.leftmost, neutral.rightmost, slid.leftmost, slid.rightmost
		);
	};
}

<*
 The second target is a different target, not the first one again.

 A shader indexing the displacement table without the per-target stride reads
 target 0's block whichever weight is set, and every check above still passes.
 `rise` moves along Y where `slide` moves along X, so this separates them.
*>
fn void the_second_target_moves_the_other_way() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Scene* scene = renderer.pass.scene;
		three::AssetId id = renderer.pass.assets.load(&renderer.gpu, FIXTURE)!!;
		three::NodeId face = node_at(scene, scene.instantiate(id), "Face");
		renderer.pass.frame_camera();

		scene.set_morph_weights(face, (float[]) { 0.2f, 0 });
		image::Image slid_shot = renderer.capture()!!;
		Silhouette slid = measure(&slid_shot, renderer.clear);
		slid_shot.free();

		scene.set_morph_weights(face, (float[]) { 0, 0.2f });
		image::Image risen_shot = renderer.capture()!!;
		Silhouette risen = measure(&risen_shot, renderer.clear);
		risen_shot.free();

		test::@check(slid.drawn > 0 && risen.drawn > 0, "both morphs rasterise something");
		test::@check(
			risen.topmost < slid.topmost,
			"`rise` reaches higher than `slide` does: %d against %d — if these are equal both weights read one block",
			risen.topmost, slid.topmost
		);
	};
}

<*
 Two copies of one mesh wear different expressions and stay one draw call.

 **The thesis, stated for this feature.** The displacements are on the asset and
 the weights are on the instance, so the only thing two morphing copies disagree
 about is one `uint` — exactly as with `Instance.pose` for a crowd. If this ever
 reports more than one call, a weight has become bucket state.
*>
fn void two_expressions_are_one_draw_call() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Scene* scene = renderer.pass.scene;
		three::AssetId id = renderer.pass.assets.load(&renderer.gpu, FIXTURE)!!;

		for (uint i = 0; i < 8; i++)
		{
			three::NodeId face = node_at(scene, scene.instantiate(id), "Face");
			scene.set_position(face, { (float)i * 2, 0, 0 });
			// Half of them morphing and half not, which is the arrangement that
			// would split a bucket if the weights had gone on the draw record.
			if (i % 2 == 0) scene.set_morph_weights(face, (float[]) { (float)i / 8.0f, 0 });
		}
		renderer.pass.frame_camera();
		renderer.render_offscreen()!!;

		three::SceneStats stats = renderer.pass.stats();
		test::@check(stats.draw_calls == 1, "eight faces at different expressions drew %d calls", stats.draw_calls);
	};
}

// ============================================================================
// The clip
// ============================================================================

<*
 A WEIGHTS channel drives the weights.

 The clip takes target 0 from 0 to 1 over a second and never touches target 1,
 which is what separates "the channel was applied" from "the channel was applied
 to the right element": a sampler that reads the pair with the wrong stride writes
 target 1 instead, and the quad rises rather than sliding.
*>
fn void a_weights_channel_drives_the_expression() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Scene* scene = renderer.pass.scene;
		three::AssetId id = renderer.pass.assets.load(&renderer.gpu, FIXTURE)!!;
		three::NodeId root = scene.instantiate(id);
		three::NodeId face = node_at(scene, root, "Face");

		test::@check(scene.play(root, "open", loop: false), "the fixture's `open` clip plays");

		scene.step_animations(0.5f);
		float[] halfway = scene.morph_weights(face);
		test::@check(halfway.len == 2, "two weights are held, got %d", halfway.len);
		if (halfway.len < 2) return;
		test::@check(
			math::abs(halfway[0] - 0.5f) < 0.001f,
			"half a second into a one-second ramp target 0 is at %f, expected 0.5", halfway[0]
		);
		test::@check(halfway[1] == 0, "and target 1, which the clip never names, is at %f", halfway[1]);

		scene.step_animations(0.5f);
		float[] ended = scene.morph_weights(face);
		if (ended.len < 2) return;
		test::@check(
			math::abs(ended[0] - 1.0f) < 0.001f,
			"at the end of the ramp target 0 is at %f, expected 1", ended[0]
		);
	};
}

<*
 A script sets an expression and it reaches the frame.

 The prelude's half: `mesh.weights[i] = v` has to reach `setMorphWeights` with the
 right index, and `mesh.morphs` has to answer before anything is drawn.
*>
fn void a_script_can_wear_an_expression() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			const asset = await three.load('test/fixtures/morph.glb');
			const face = asset.instantiate();
			scene.add(face);
			three.camera.frameAll();
			three.render();

			const mesh = face.children[0];
			const before = mesh.morphs;
			mesh.weights[1] = 0.5;
			mesh.weights = [0.25];
			return { targets: before, weights: mesh.weights.toArray(), draws: three.stats().drawCalls };
		`);
		defer result.free();

		test::@check(result.ok, "the script ran: %s", result.error);
		test::@check(
			result.value == `{"targets":2,"weights":[0.25,0.5],"draws":1}`,
			"expected two targets, a partly-set pair and one draw call, got '%s'", result.value
		);
	};
}

// ---- helpers ---------------------------------------------------------------

fn three::NodeId node_at(three::Scene* scene, three::NodeId root, String name)
{
	three::Node* node = scene.node(root);
	if (node == null) return three::NO_NODE;
	if (node.name == name) return root;

	foreach (child : node.children)
	{
		three::NodeId found = node_at(scene, child, name);
		if (found.is_set()) return found;
	}
	return three::NO_NODE;
}

<*
 What a capture drew, in pixels: how many, and the extremes of the box holding
 them.

 The same shape `skinning_test.c3` measures with, and for the same reason: a
 deformation is a change of silhouette, and the cheapest honest way to see one is
 to ask where the drawn pixels stop.
*>
struct Silhouette
{
	uint drawn;
	int leftmost;
	int rightmost;
	int topmost;
}

fn Silhouette measure(image::Image* shot, float[4] clear)
{
	// A tolerance rather than an equality, and the same one `skinning_test.c3`
	// uses: the clear colour goes through a transfer function on its way into the
	// image, so the background is near what was asked for rather than exactly it.
	char[3] background = {
		(char)(uint)(clear[0] * 255.0 + 0.5),
		(char)(uint)(clear[1] * 255.0 + 0.5),
		(char)(uint)(clear[2] * 255.0 + 0.5),
	};

	Silhouette out = { .drawn = 0, .leftmost = (int)W, .rightmost = -1, .topmost = (int)H };
	for (uint y = 0; y < H; y++)
	{
		for (uint x = 0; x < W; x++)
		{
			sz i = (sz)(y * W + x) * 4;
			int dr = (int)shot.pixels[i] - (int)background[0];
			int dg = (int)shot.pixels[i + 1] - (int)background[1];
			int db = (int)shot.pixels[i + 2] - (int)background[2];
			if (dr * dr + dg * dg + db * db <= 12) continue;

			out.drawn++;
			if ((int)x < out.leftmost) out.leftmost = (int)x;
			if ((int)x > out.rightmost) out.rightmost = (int)x;
			if ((int)y < out.topmost) out.topmost = (int)y;
		}
	}
	return out;
}
