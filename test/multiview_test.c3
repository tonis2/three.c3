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
import vk;
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

// A white card turned across a black background: every pixel is one or the
// other unless something blends the edge.
const String CARD = `
	const scene = new three.Scene();
	scene.background = 0x000000;
	const card = new three.Mesh(new three.PlaneGeometry(2, 2), new three.MeshLambertMaterial({ emissive: 0xffffff }));
	card.rotation.z = 0.5;
	scene.add(card);
	three.camera.target.set(0, 0, 0);
	three.camera.orbit(0, 0, 5);
`;

struct Drawn
{
	image::Image shot;
	uint views;
	uint samples;
	uint prepass_draws;
	bool occlusion;
	// A multiview target's AO depth has a cut-out pipeline of its own.
	bool occlusion_cuts;
}

<*
 Draws `script` as a stereo pair: the script's camera for the left eye, the
 same turned a few degrees for the right. `views` 2 is a multiview target,
 1 the same pair side by side. `samples` above one draws it with MSAA.
*>
fn Drawn draw_pair(String script, uint views, bool sky = false, uint samples = 1)
{
	// Under the validation layer: a layer count or a view mask that disagrees with
	// an attachment is invisible to a picture check.
	three::Renderer* renderer = device::borrow(W, H, validate: true, views: views, samples: samples);
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
		.samples = (uint)renderer.target.samples,
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

// Pixels whose red is well clear of both the darkest and the brightest: an edge
// a resolve blended.
fn uint blended(image::Image* shot)
{
	char low = 255;
	char high = 0;
	for (sz p = 0; p < shot.pixels.len; p += 4)
	{
		if (shot.pixels[p] < low) low = shot.pixels[p];
		if (shot.pixels[p] > high) high = shot.pixels[p];
	}
	uint margin = ((uint)high - (uint)low) / 8;
	uint count = 0;
	for (sz p = 0; p < shot.pixels.len; p += 4)
	{
		uint red = shot.pixels[p];
		if (red > (uint)low + margin && red + margin < (uint)high) count++;
	}
	return count;
}

<*
 4x MSAA blends the edges of a card that is otherwise black or white, in both
 eyes, and leaves no blend where it is off.
*>
fn void msaa_blends_the_edges_it_draws() @test
{
	Drawn plain = draw_pair(CARD, 2);
	defer plain.shot.free();
	Drawn smooth = draw_pair(CARD, 2, samples: 4);
	defer smooth.shot.free();

	test::@check(smooth.samples == 4 && plain.samples == 1, "the targets drew with %d and %d samples", smooth.samples, plain.samples);
	test::@check(drawn_in(&smooth.shot, 0, W / 2) > 500 && drawn_in(&smooth.shot, W / 2, W) > 500,
		"each eye drew the card");
	uint hard = blended(&plain.shot);
	uint soft = blended(&smooth.shot);
	test::@check(hard < 10, "one sample blended %d pixels", hard);
	test::@check(soft > 100, "four samples blended only %d pixels", soft);
}

<*
 The MSAA pair agrees with itself side by side: the multiview one has its
 prepass inside the scene rendering, the side-by-side one has none, and both
 resolve the same samples.

 Under a sky, so every pixel is drawn. RADV (Mesa 26.0) loses the clear of a
 multiview MSAA image's second layer in the resolve, and the right eye's bare
 background comes out black; `RADV_DEBUG=nofastclears` puts it back.
*>
fn void an_msaa_pair_draws_what_side_by_side_draws() @test
{
	Drawn layered = draw_pair(SCENE, 2, sky: true, samples: 4);
	defer layered.shot.free();
	Drawn beside = draw_pair(SCENE, 1, sky: true, samples: 4);
	defer beside.shot.free();

	test::@check(layered.views == 2 && layered.samples == 4 && beside.samples == 4, "both targets drew with MSAA");
	test::@check(layered.prepass_draws > 0, "the multiview prepass drew nothing");
	test::@check(beside.prepass_draws == 0, "a one-view MSAA target has no prepass");
	uint difference = max_rgb_difference(&layered.shot, &beside.shot);
	test::@check(difference <= 2, "multiview and side by side differ by %d with MSAA", difference);
}

<*
 A pass that reads depth reads the resolved samples, on both paths.
*>
fn void an_msaa_pair_resolves_depth_for_a_post_pass() @test
{
	String script = string::tformat("%s%s", SCENE, FOG);
	Drawn layered = draw_pair(script, 2, sky: true, samples: 4);
	defer layered.shot.free();
	Drawn beside = draw_pair(script, 1, sky: true, samples: 4);
	defer beside.shot.free();

	uint difference = max_rgb_difference(&layered.shot, &beside.shot);
	test::@check(difference <= 2, "multiview and side by side differ by %d with MSAA and a depth fog", difference);
}

<*
 Draws the pair into eye images the way a headset gets it, a layer per eye
 through `render_into`, and reads both layers back side by side. Then the same
 pair through `capture`, the float scene image and the post chain. Under the
 validation layer, like every pair.
*>
struct EyeFrames
{
	image::Image eyes;
	image::Image captured;
	three::SceneTone tone;
}

fn EyeFrames draw_eyes(String script, uint samples = 1)
{
	three::Renderer* renderer = device::borrow(W, H, validate: true, views: 2, samples: samples);
	defer device::release();
	three::JsRuntime runtime;
	runtime.open(&renderer.pass, renderer)!!;
	defer runtime.close();
	three::RunResult built = runtime.run(script);
	defer built.free();
	test::@check(built.ok, "the scene built: %s", built.error);
	test::@check(renderer.target.views == 2, "the device has multiview");

	// A sky, so every pixel is drawn and toned: a clear colour the chain tones is
	// written as given by the scene.
	image::Image picture = gradient();
	defer picture.free();
	int slot = renderer.pass.assets.claim_texture(&renderer.gpu, picture)!!;
	renderer.pass.set_scene_sky(renderer.pass.scene, true, slot);
	three::Camera right = renderer.pass.camera;
	right.yaw += 6;
	renderer.pass.view_rect = { 0, 0, 1, 1 };
	three::SceneView[1] extra = { { .camera = right, .rect = { 0, 0, 1, 1 } } };
	renderer.pass.set_extra_views(extra[..]);

	three::Gpu* gpu = &renderer.gpu;
	vk::Extent2D eye = renderer.target.view_extent;
	three::LayeredImage target = gpu.create_layered_image(three::TARGET_COLOR_FORMAT, eye, 2,
		IMAGE_USAGE_COLOR_ATTACHMENT_BIT | IMAGE_USAGE_TRANSFER_SRC_BIT | IMAGE_USAGE_TRANSFER_DST_BIT)!!;
	defer target.destroy(gpu);
	vk::Memory readback = renderer.target.create_readback(gpu)!!;
	defer readback.free();

	gpu.begin_capture();
	// The second frame is the one read: the first builds the variants.
	renderer.render_into(target.whole.image, target.whole.view, eye, eyes: true)!!;
	renderer.render_into(target.whole.image, target.whole.view, eye, eyes: true)!!;
	gpu.handle.waitIdle();
	three::SceneTone tone = renderer.pass.scene_tone;
	gpu.handle.@single_time_command(queue: gpu.graphics ; vk::CommandBuffer cmd)
	{
		vk::ImageMemoryBarrier2 readable = {
			...three::IMAGE_BARRIER,
			.image = target.whole.image,
			.srcStageMask = PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
			.srcAccessMask = ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT | ACCESS_2_TRANSFER_WRITE_BIT,
			.dstStageMask = PIPELINE_STAGE_2_ALL_TRANSFER_BIT,
			.dstAccessMask = ACCESS_2_TRANSFER_READ_BIT,
			.oldLayout = IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
			.newLayout = IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
		};
		vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo().setImageMemoryBarriers({ readable }));
		// Each layer into its half of every row, so the buffer reads as the eyes
		// side by side.
		vk::BufferImageCopy[2] regions;
		for (uint i = 0; i < 2; i++)
		{
			regions[i] = {
				.bufferOffset = (vk::DeviceSize)(i * eye.width * 4),
				.bufferRowLength = eye.width * 2,
				.imageSubresource = { .aspectMask = IMAGE_ASPECT_COLOR_BIT, .baseArrayLayer = i, .layerCount = 1 },
				.imageExtent = { eye.width, eye.height, 1 },
			};
		}
		vk::cmdCopyImageToBuffer(cmd, target.whole.image, IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, readback.buffer, 2, &regions[0]);
	}!!;
	image::Image eyes = renderer.target.decode_readback(&readback);

	renderer.capture()!!.free();
	image::Image captured = renderer.capture()!!;
	String errors = gpu.sink.errors.str_view();
	String warnings = gpu.sink.warnings.str_view();
	test::@check(errors.len == 0, "drawing into eye images produced validation errors: %s", errors);
	test::@check(warnings.len == 0, "and warnings: %s", warnings);
	gpu.end_capture();
	return { .eyes = eyes, .captured = captured, .tone = tone };
}

<*
 With nothing between the scene and the eyes, the scene writes them itself and
 the picture is the one the post chain's tonemap makes.
*>
fn void the_scene_writes_eye_images_as_the_tonemap_would() @test
{
	EyeFrames drawn = draw_eyes(SCENE);
	defer { drawn.eyes.free(); drawn.captured.free(); }
	test::@check(drawn.tone == three::SceneTone.DISPLAY, "the scene did not write the eyes itself: %s", drawn.tone);
	test::@check(drawn_in(&drawn.eyes, 0, W / 2) > 1000 && drawn_in(&drawn.eyes, W / 2, W) > 1000, "each eye drew");
	uint difference = max_rgb_difference(&drawn.eyes, &drawn.captured);
	test::@check(difference <= 2, "eye images and the tonemapped capture differ by %d", difference);
}

fn void the_scene_tones_eye_images_with_agx() @test
{
	String script = string::tformat("%s three.toneMapping = 'agx'; three.toneMappingExposure = 1.5;", SCENE);
	EyeFrames drawn = draw_eyes(script);
	defer { drawn.eyes.free(); drawn.captured.free(); }
	test::@check(drawn.tone == three::SceneTone.DISPLAY_AGX, "the scene did not tone the eyes with AgX: %s", drawn.tone);
	uint difference = max_rgb_difference(&drawn.eyes, &drawn.captured);
	test::@check(difference <= 2, "AgX in the scene and in the tonemap differ by %d", difference);
}

fn void the_scene_writes_msaa_eye_images() @test
{
	EyeFrames drawn = draw_eyes(SCENE, samples: 4);
	defer { drawn.eyes.free(); drawn.captured.free(); }
	test::@check(drawn.tone == three::SceneTone.DISPLAY, "the scene did not write the eyes itself");
	// The samples are clamped to the display before they are averaged, where the
	// chain averages light first: an edge against a surface brighter than 1.0
	// comes out darker, and nothing else differs.
	uint apart = pixels_apart(&drawn.eyes, &drawn.captured, 4);
	test::@check(apart < W * H / 50, "%d pixels differ by more than 4, more than the silhouettes", apart);
}

// How many pixels differ by more than `tolerance` in any channel.
fn uint pixels_apart(image::Image* a, image::Image* b, uint tolerance)
{
	uint count = 0;
	for (sz p = 0; p < a.pixels.len; p += 4)
	{
		for (sz c = 0; c < 3; c++)
		{
			int d = (int)(char)a.pixels[p + c] - (int)(char)b.pixels[p + c];
			if ((uint)(d < 0 ? -d : d) <= tolerance) continue;
			count++;
			break;
		}
	}
	return count;
}

<*
 A script's post pass sits between the scene and the eyes, so the frame goes
 through the chain and the target, and each half is copied into its layer.
*>
fn void a_post_pass_still_reaches_eye_images() @test
{
	String script = string::tformat("%s%s", SCENE, FOG);
	EyeFrames drawn = draw_eyes(script);
	defer { drawn.eyes.free(); drawn.captured.free(); }
	test::@check(drawn.tone == three::SceneTone.LINEAR, "a frame with a post pass wrote the eyes from the scene");
	uint difference = max_rgb_difference(&drawn.eyes, &drawn.captured);
	test::@check(difference <= 2, "the copied eyes and the capture differ by %d", difference);
}
