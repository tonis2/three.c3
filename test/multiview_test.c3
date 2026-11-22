<*
 Multiview: both eyes of a headset drawn with one set of draws, each into a
 layer of its own, and put side by side in the picture by the tonemap.

 Every check draws the same stereo pair twice, once through a two-layer target
 and once side by side on an ordinary one, and asks for the same picture. The
 side-by-side path is the one the rest of the suite already pins.
*>
module three_tests::multiview;

import std::core::test;
import three;
import image;
import three_tests::device;

// Each eye 96 wide, so the half-resolution AO grid lines up on both paths.
const uint W = 192;
const uint H = 96;

// Lit boxes on a floor, with AO, clustered lights, a highlight that depends on
// where each eye is, and one alpha-tested box for the cut-out depth pipelines.
const String SCENE = `
	const scene = new three.Scene();
	scene.background = 0x101820;
	three.light.ambient = 0.35;
	three.light.occlusion.enabled = true;
	const shiny = new three.MeshLambertMaterial();
	shiny.roughness = 0.35;
	shiny.reflectance = 0.5;
	const floor = new three.Mesh(new three.BoxGeometry(10, .2, 10), shiny);
	floor.position.y = -.1;
	scene.add(floor);
	for (let i = 0; i < 5; i++) {
		const box = new three.Mesh(new three.BoxGeometry(.8, .8 + i * .3, .8), shiny);
		box.position.set(i - 2, .4 + i * .15, (i % 2) - .5);
		scene.add(box);
	}
	const leaf = new three.MeshLambertMaterial();
	leaf.alphaTest = 0.5;
	const card = new three.Mesh(new three.BoxGeometry(.6, .6, .6), leaf);
	card.position.set(0, .3, 1.4);
	scene.add(card);
	for (let i = 0; i < 12; i++) {
		three.lights.add({ position: [Math.sin(i) * 2.5, 0.4 + (i % 3) * 0.5, Math.cos(i) * 2.5],
			range: 2.5, color: 0x40ff * (i + 1), intensity: 2 });
	}
	three.camera.target.set(0, .5, 0);
	three.camera.orbit(30, 20, 7);
`;

// The same depth-reading pass for both paths.
const String FOG = `
	three.setPost({ fragment: 'return mix(p.color, float3(0.2, 0.3, 0.4), clamp(p.depth * 0.06, 0.0, 0.8));' });
`;

// Where a pass thinks it is: u in red, and the frame's width in green, a
// thousandth of it.
const String WHERE = `
	three.setPost({ fragment: 'return float3(p.uv.x, p.resolution.x / 1000.0, 0.0);' });
`;

// Half of this frame and half of the last one, through a history the size of
// the frame. By the second frame of a still scene it is this frame, but only if
// each eye's history held that eye's last frame.
const String HISTORY = `
	three.addPass({
		compute: "fn void main(PostThread t) @compute @threads(8, 8, 1) { int2 px = int2(t.id.xy); "
			+ "if (!inside(px)) return; float4 was = history[px]; float4 now = float4(color_at(px).rgb, 1.0); "
			+ "history[px] = now; output[px] = now * 0.5 + was * 0.5; }",
		images: { history: 'rgba16f' },
	});
`;

struct Drawn
{
	image::Image shot;
	uint views;
	uint prepass_draws;
	bool occlusion;
	// A multiview target's AO depth has a cut-out pipeline of its own.
	bool occlusion_cuts;
}

<*
 Draws `script` as a stereo pair: the script's camera for the left eye, the
 same turned a few degrees for the right. `views` 2 is a multiview target,
 1 the same pair side by side.
*>
fn Drawn draw_pair(String script, uint views, bool sky = false)
{
	// Under the validation layer: a layer count or a view mask that disagrees with
	// an attachment is invisible to a picture check.
	three::Renderer* renderer = device::borrow(W, H, validate: true, views: views);
	defer device::release();
	three::JsRuntime runtime;
	runtime.open(&renderer.pass, renderer)!!;
	defer runtime.close();

	three::RunResult built = runtime.run(script);
	defer built.free();
	test::@check(built.ok, "the scene built: %s", built.error);
	if (sky)
	{
		image::Image picture = gradient();
		defer picture.free();
		int slot = renderer.pass.assets.claim_texture(&renderer.gpu, picture)!!;
		renderer.pass.set_scene_sky(renderer.pass.scene, true, slot);
	}

	three::Camera right = renderer.pass.camera;
	right.yaw += 6;
	bool layered = renderer.target.views > 1;
	float[4] whole = { 0, 0, 1, 1 };
	float[4] left_half = { 0, 0, 0.5f, 1 };
	float[4] right_half = { 0.5f, 0, 0.5f, 1 };
	renderer.pass.view_rect = layered ? whole : left_half;
	three::SceneView[1] extra = { { .camera = right, .rect = layered ? whole : right_half } };
	renderer.pass.set_extra_views(extra[..]);

	// The second frame is the one compared: the first is where a multiview
	// target finds its cut-outs and builds the depth pipelines that cut them.
	renderer.capture()!!.free();
	renderer.gpu.begin_capture();
	image::Image shot = renderer.capture()!!;
	String errors = renderer.gpu.sink.errors.str_view();
	String warnings = renderer.gpu.sink.warnings.str_view();
	test::@check(errors.len == 0, "drawing the pair produced validation errors: %s", errors);
	test::@check(warnings.len == 0, "and warnings: %s", warnings);
	renderer.gpu.end_capture();
	return {
		.shot = shot,
		.views = renderer.target.views,
		.prepass_draws = renderer.pass.prepass.draws,
		.occlusion = renderer.pass.ambient_occlusion.live,
		.occlusion_cuts = renderer.pass.ambient_occlusion.eyes_cutout_pipeline.handle != null,
	};
}

// A sky with no two directions alike, so a ray from the wrong eye shows.
fn image::Image gradient()
{
	const uint SW = 64;
	const uint SH = 32;
	char[] pixels = mem::new_array(char, (sz)SW * SH * 4);
	for (uint y = 0; y < SH; y++)
	{
		for (uint x = 0; x < SW; x++)
		{
			sz at = ((sz)y * SW + x) * 4;
			pixels[at + 0] = (char)(x * 4);
			pixels[at + 1] = (char)(y * 8);
			pixels[at + 2] = (char)(255 - x * 2);
			pixels[at + 3] = (char)0xff;
		}
	}
	return {
		.width = SW, .height = SH, .bit_depth = 8,
		.format = image::PixelFormat.RGBA, .pixels = pixels, .allocator = mem,
	};
}

fn uint max_rgb_difference(image::Image* a, image::Image* b)
{
	uint largest = 0;
	for (sz p = 0; p < a.pixels.len; p += 4)
	{
		for (sz c = 0; c < 3; c++)
		{
			int d = (int)(char)a.pixels[p + c] - (int)(char)b.pixels[p + c];
			uint diff = (uint)(d < 0 ? -d : d);
			if (diff > largest) largest = diff;
		}
	}
	return largest;
}

// How many pixels of a half are not the clear colour: proof that eye drew anything.
fn uint drawn_in(image::Image* shot, uint from, uint to)
{
	uint drawn = 0;
	for (uint y = 0; y < shot.height; y++)
	{
		for (uint x = from; x < to; x++)
		{
			sz at = ((sz)y * shot.width + x) * 4;
			if (shot.pixels[at] > 30 || shot.pixels[at + 1] > 40) drawn++;
		}
	}
	return drawn;
}

fn void a_multiview_pair_draws_what_side_by_side_draws() @test
{
	Drawn layered = draw_pair(SCENE, 2);
	defer layered.shot.free();
	Drawn beside = draw_pair(SCENE, 1);
	defer beside.shot.free();

	test::@check(layered.views == 2, "the device has multiview, so the target should have two layers");
	test::@check(beside.views == 1, "and the comparison draws on one");
	test::@check(layered.occlusion && beside.occlusion, "AO ran on both paths");
	test::@check(layered.occlusion_cuts, "the multiview AO depth pass had no cut-out pipeline for the leaf");
	test::@check(beside.prepass_draws > 0, "the side-by-side prepass drew nothing");
	test::@check(layered.prepass_draws * 2 == beside.prepass_draws,
		"one set of prepass draws serves both eyes: %d against %d", layered.prepass_draws, beside.prepass_draws);
	test::@check(drawn_in(&layered.shot, 0, W / 2) > 1000 && drawn_in(&layered.shot, W / 2, W) > 1000,
		"each eye drew its half of the picture");
	uint difference = max_rgb_difference(&layered.shot, &beside.shot);
	test::@check(difference <= 2, "multiview and side by side differ by %d", difference);
}

fn void a_multiview_sky_and_script_pass_match_side_by_side() @test
{
	String script = string::tformat("%s%s", SCENE, FOG);
	Drawn layered = draw_pair(script, 2, sky: true);
	defer layered.shot.free();
	Drawn beside = draw_pair(script, 1, sky: true);
	defer beside.shot.free();

	test::@check(layered.views == 2, "the target should have two layers");
	uint difference = max_rgb_difference(&layered.shot, &beside.shot);
	test::@check(difference <= 2, "multiview and side by side differ by %d with a sky and a depth fog", difference);
}

fn void the_eyes_of_a_multiview_pair_differ() @test
{
	Drawn layered = draw_pair(SCENE, 2);
	defer layered.shot.free();
	// The right eye is turned, so its half must not be a copy of the left one.
	uint differing = 0;
	for (uint y = 0; y < H; y++)
	{
		for (uint x = 0; x < W / 2; x++)
		{
			sz left = ((sz)y * W + x) * 4;
			sz right = ((sz)y * W + x + W / 2) * 4;
			if (layered.shot.pixels[left] != layered.shot.pixels[right]) differing++;
		}
	}
	test::@check(differing > 500, "the two eyes drew the same picture: %d pixels differ", differing);
}

<*
 A post pass runs once per eye, and each eye is a frame of its own: `p.uv` runs
 0..1 across one eye, so it jumps from 1 to 0 at the seam, and the resolution is
 one eye's 96 pixels. Run once over both eyes side by side, a blur at the seam
 read the other eye.
*>
fn void each_eye_is_a_frame_of_its_own_to_a_post_pass() @test
{
	String script = string::tformat("%s%s", SCENE, WHERE);
	Drawn layered = draw_pair(script, 2);
	defer layered.shot.free();
	test::@check(layered.views == 2, "the target should have two layers");

	sz last_left = ((sz)(H / 2) * W + W / 2 - 1) * 4;
	sz first_right = ((sz)(H / 2) * W + W / 2) * 4;
	char[] px = layered.shot.pixels;
	// Half a pixel of u is 0.005, which the sRGB encode lifts to 17; the seam of
	// one frame over both eyes is 0.5, which is 188.
	test::@check(px[last_left] > 240 && px[first_right] < 30,
		"u ends the left eye and starts the right one: %d then %d", px[last_left], px[first_right]);
	// 0.096 linear is 87 encoded; the whole 192 would be 122.
	test::@check(px[last_left + 1] >= 84 && px[last_left + 1] <= 91 && px[first_right + 1] == px[last_left + 1],
		"each eye is 96 pixels wide to a pass: green %d and %d", px[last_left + 1], px[first_right + 1]);
}

<*
 A pass's own image is kept per eye: a history blended with this frame comes
 out as the side-by-side pair does, which it would not if the right eye read
 back what the left eye wrote. Under the validation layer, like every pair.
*>
fn void a_pass_history_is_kept_per_eye() @test
{
	String script = string::tformat("%s%s", SCENE, HISTORY);
	Drawn layered = draw_pair(script, 2);
	defer layered.shot.free();
	Drawn beside = draw_pair(script, 1);
	defer beside.shot.free();

	test::@check(layered.views == 2, "the target should have two layers");
	test::@check(drawn_in(&layered.shot, 0, W / 2) > 1000 && drawn_in(&layered.shot, W / 2, W) > 1000,
		"each eye drew its half of the picture");
	uint difference = max_rgb_difference(&layered.shot, &beside.shot);
	test::@check(difference <= 2, "multiview and side by side differ by %d through a history", difference);
}
