<*
 The sky: the image behind the scene, and the one metals reflect —
 `src/render/sky.c3` and `shaders/sky.slang`.

	`c3c test --trust=full --test-noleak --test-filter three_tests::sky`

 **Every check here is on pixels**, because every way this can be wrong renders a
 perfectly valid frame and reports nothing. A ray reconstructed from the wrong
 matrix is a sky that moves the wrong way when the camera turns; a viewport flip
 taken twice is a sky that is upside down; a depth compare a step off is a sky in
 front of the geometry or missing entirely. None of those is a validation
 message and none of them is a count.

 The images are built here rather than loaded, and are flat blocks of colour with
 no two alike, so an assertion can say *which* part of the sky landed where. An
 HDRI would make a prettier test and a much worse one: the failures above all
 produce a plausible-looking photograph.
*>
module three_tests::sky;

import three;
import vk;
import image;
import std::core::test;
import std::math::vector;

const uint W = 160;
const uint H = 120;

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
 An equirectangular image whose top half and bottom half are different colours.

 The horizon of an equirect is the middle row, so a camera looking level puts the
 seam across the middle of the screen — which makes "is the sky the right way up"
 a question two pixel counts can answer. A single flat colour cannot ask it, and
 a gradient would answer it only approximately.

 Sixteen wide so the longitude wrap has somewhere to happen, and eight tall
 because nothing here reads a mip.
*>
fn image::Image banded(char[3] top, char[3] bottom)
{
	const uint SW = 16;
	const uint SH = 8;
	char[] pixels = mem::new_array(char, (sz)SW * SH * 4);
	for (uint y = 0; y < SH; y++)
	{
		char[3] band = y < SH / 2 ? top : bottom;
		for (uint x = 0; x < SW; x++)
		{
			sz at = ((sz)y * SW + x) * 4;
			pixels[at + 0] = band[0];
			pixels[at + 1] = band[1];
			pixels[at + 2] = band[2];
			pixels[at + 3] = (char)0xff;
		}
	}
	return {
		.width = SW, .height = SH, .bit_depth = 8,
		.format = image::PixelFormat.RGBA, .pixels = pixels, .allocator = mem,
	};
}

<*
 How many pixels of a horizontal band of the frame are near a colour.

 A band rather than the whole frame, so "the top of the screen" and "the bottom
 of the screen" are separate numbers — which is the whole of the orientation
 check.

 The tolerance is generous on purpose. The colour goes through an sRGB decode at
 the sampler and an sRGB encode at the attachment, and the point of these counts
 is which *band* landed where rather than what a channel rounded to.
*>
fn uint count_near(image::Image* shot, char[3] want, float from, float to)
{
	uint first = (uint)((float)shot.height * from);
	uint last = (uint)((float)shot.height * to);
	uint found = 0;
	for (uint y = first; y < last && y < shot.height; y++)
	{
		for (uint x = 0; x < shot.width; x++)
		{
			sz at = ((sz)y * shot.width + x) * 4;
			int dr = (int)shot.pixels[at] - (int)want[0];
			int dg = (int)shot.pixels[at + 1] - (int)want[1];
			int db = (int)shot.pixels[at + 2] - (int)want[2];
			if (dr * dr + dg * dg + db * db <= 30 * 30) found++;
		}
	}
	return found;
}

// The mean brightness of the middle of the frame, which is where a test that
// puts one object at the origin puts it.
fn float middle_luminance(image::Image* shot)
{
	uint first = shot.height / 3;
	uint last = shot.height - shot.height / 3;
	double sum = 0;
	uint count = 0;
	for (uint y = first; y < last; y++)
	{
		for (uint x = shot.width / 3; x < shot.width - shot.width / 3; x++)
		{
			sz at = ((sz)y * shot.width + x) * 4;
			sum += (double)shot.pixels[at] + shot.pixels[at + 1] + shot.pixels[at + 2];
			count++;
		}
	}
	return count == 0 ? 0.0f : (float)(sum / (3.0 * count));
}

// ============================================================================
// The background
// ============================================================================

<*
 A scene with no sky renders exactly what it always did.

 First, because it is the claim every other change in this file has to leave
 standing: `scene.background` is a colour until somebody assigns an image, the
 sky pass records nothing for a scene without one, and the environment term is
 gated on an intensity that is zero. So an empty scene still clears to its clear
 colour and nothing about the frame moved.
*>
fn void a_scene_with_no_sky_is_the_frame_it_was() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		renderer.clear = { 0.1f, 0.2f, 0.6f, 1.0f };

		image::Image shot = renderer.capture()!!;
		defer shot.free();

		char[3] want = { 26, 51, 153 };
		uint matched = count_near(&shot, want, 0.0f, 1.0f);
		test::@check(matched > W * H * 9 / 10,
			"the clear colour is still the whole frame: %d of %d pixels", matched, W * H);
	};
}

<*
 A background image fills the frame.

 The blunt one, and it is the check that separates "the sky pass ran" from every
 subtler thing below: an empty scene with a sky assigned draws the sky and not
 the clear colour, everywhere.

 The clear colour is deliberately nothing like either band, so a frame that was
 merely cleared cannot pass.
*>
fn void a_background_image_fills_the_frame() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		renderer.clear = { 0.0f, 0.0f, 0.0f, 1.0f };

		// One colour, top to bottom. The banded image is what
		// `the_sky_is_the_right_way_up` needs and is the wrong fixture here: the
		// sampler blends across the seam, so a third of the frame is neither band
		// and this check would be counting the filter rather than the sky.
		image::Image sky = banded({ 220, 40, 40 }, { 220, 40, 40 });
		defer sky.free();
		int slot = renderer.pass.assets.claim_texture(&renderer.gpu, sky)!!;
		renderer.pass.set_scene_sky(renderer.pass.scene, true, slot);

		image::Image shot = renderer.capture()!!;
		defer shot.free();

		uint red = count_near(&shot, { 220, 40, 40 }, 0.0f, 1.0f);
		test::@check(red > W * H * 9 / 10,
			"the sky is the whole frame: %d of %d pixels", red, W * H);
	};
}

<*
 And it is the right way up.

 **The failure this exists to catch is a viewport flip counted twice.** Every
 other pass here renders with a flipped viewport, so a sky that reconstructed its
 ray from `SV_Position` and the extent — the obvious way to write it — comes out
 inverted in the main pass and upright in a bake, which is a bug that only one of
 the two ever shows. The shader carries the clip position as a varying instead,
 and this is the check that says so.

 The camera is level, so an equirect's middle row is the horizon and the seam
 lands across the middle of the screen: the top third must be the top band and
 the bottom third the bottom one.
*>
fn void the_sky_is_the_right_way_up() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		renderer.clear = { 0.0f, 0.0f, 0.0f, 1.0f };
		renderer.pass.camera.pitch = 0;
		renderer.pass.camera.yaw = 0;

		image::Image sky = banded({ 220, 40, 40 }, { 40, 60, 220 });
		defer sky.free();
		int slot = renderer.pass.assets.claim_texture(&renderer.gpu, sky)!!;
		renderer.pass.set_scene_sky(renderer.pass.scene, true, slot);

		image::Image shot = renderer.capture()!!;
		defer shot.free();

		uint above = count_near(&shot, { 220, 40, 40 }, 0.0f, 0.3f);
		uint below = count_near(&shot, { 40, 60, 220 }, 0.7f, 1.0f);
		uint band = W * (uint)((float)H * 0.3f);
		test::@check(above > band * 9 / 10,
			"the top of the sky is at the top of the screen: %d of %d", above, band);
		test::@check(below > band * 9 / 10,
			"and the bottom at the bottom: %d of %d", below, band);
	};
}

<*
 Geometry draws over the sky.

 The depth half of the pass. A sky at the far plane with depth writes off passes
 the test where nothing has been drawn and fails where anything has, and the
 order — sky first, geometry after — is what makes that come out as geometry in
 front. Getting the compare or the depth value wrong produces a frame that is
 entirely sky, which is what this counts.
*>
fn void geometry_draws_over_the_sky() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		renderer.clear = { 0.0f, 0.0f, 0.0f, 1.0f };

		image::Image sky = banded({ 220, 40, 40 }, { 220, 40, 40 });
		defer sky.free();
		int slot = renderer.pass.assets.claim_texture(&renderer.gpu, sky)!!;
		renderer.pass.set_scene_sky(renderer.pass.scene, true, slot);

		three::AssetId box = renderer.pass.assets.primitive(&renderer.gpu, three::box_shape(2, 2, 2))!!;
		renderer.pass.scene.add_mesh(box, 0);
		renderer.pass.frame_camera();

		image::Image shot = renderer.capture()!!;
		defer shot.free();

		uint red = count_near(&shot, { 220, 40, 40 }, 0.0f, 1.0f);
		test::@check(red > 0, "the sky is still visible around the box: %d pixels", red);
		test::@check(red < W * H * 8 / 10,
			"and the box is in front of it: %d of %d pixels are sky", red, W * H);
	};
}

// ============================================================================
// The environment
// ============================================================================

<*
 An environment is what makes a metal look like metal.

 **The actual reason for wanting a sky**, and it is measured rather than
 described: a fully metallic surface scatters nothing, so `standard` scales
 its albedo by `1 - metalness` and what is left is four punctual highlights over
 black. Give it something to reflect and the same surface, the same lights and
 the same camera come out bright.

 Two captures of one scene with one field changed between them, so the number
 being compared cannot be explained by anything else in the frame.
*>
fn void an_environment_lights_a_metal() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		renderer.clear = { 0.0f, 0.0f, 0.0f, 1.0f };

		three::AssetId sphere = renderer.pass.assets.primitive(
			&renderer.gpu, three::sphere_shape(1.0f, 24, 16)
		)!!;
		uint metal = renderer.pass.create_texture_material(three::NO_TEXTURE)!!;
		renderer.pass.set_material_surface(metal, 0.25f, 1.0f, 0.5f)!!;

		three::NodeId node = renderer.pass.scene.add_mesh(sphere, 0);
		renderer.pass.scene.set_material(node, metal);
		renderer.pass.frame_camera();

		image::Image dark = renderer.capture()!!;
		float without = middle_luminance(&dark);
		dark.free();

		image::Image sky = banded({ 240, 240, 240 }, { 240, 240, 240 });
		defer sky.free();
		int slot = renderer.pass.assets.claim_texture(&renderer.gpu, sky)!!;
		// The environment only. The background is left alone on purpose: a sky
		// drawn behind the sphere would raise the frame's brightness without the
		// reflection having done anything, and this measures the middle of the
		// frame.
		renderer.pass.set_scene_sky(renderer.pass.scene, false, slot);

		image::Image lit = renderer.capture()!!;
		defer lit.free();
		float with = middle_luminance(&lit);

		test::@check(with > without + 10.0f,
			"a metal reflects the environment: %f without it, %f with", without, with);
	};
}

<*
 And a surface that is not metal is barely touched by it.

 The other half, and the one that says the term is a *reflection* rather than a
 second ambient light. A dielectric with no reflectance reflects almost nothing,
 so setting an environment must not brighten a matte scene — which is the failure
 mode of adding a diffuse irradiance term beside `three.light.ambient`, and is
 exactly what `environment_light`'s header says this deliberately does not do.
*>
fn void an_environment_barely_touches_a_matte_surface() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		renderer.clear = { 0.0f, 0.0f, 0.0f, 1.0f };

		three::AssetId sphere = renderer.pass.assets.primitive(
			&renderer.gpu, three::sphere_shape(1.0f, 24, 16)
		)!!;
		renderer.pass.scene.add_mesh(sphere, 0);
		renderer.pass.frame_camera();

		image::Image before = renderer.capture()!!;
		float matte = middle_luminance(&before);
		before.free();

		image::Image sky = banded({ 240, 240, 240 }, { 240, 240, 240 });
		defer sky.free();
		int slot = renderer.pass.assets.claim_texture(&renderer.gpu, sky)!!;
		renderer.pass.set_scene_sky(renderer.pass.scene, false, slot);

		image::Image after = renderer.capture()!!;
		defer after.free();
		float reflected = middle_luminance(&after);

		test::@check(reflected - matte < 24.0f,
			"the default material is not lit by the sky: %f became %f", matte, reflected);
	};
}

// ============================================================================
// The references
// ============================================================================

<*
 A scene's sky is two counted references, and it gives them back.

 The failure without this is the one every texture in this project is counted to
 prevent, arriving through a new door: a script disposes the handle it loaded the
 sky with, the scene goes on drawing with a freed image, and nothing says
 anything until the slot is reused.

 Both directions, because the release is the half that is easy to leave out:
 assigning takes a reference, assigning something else gives the first one back,
 and clearing gives the last one back.
*>
fn void a_scene_holds_its_sky_and_gives_it_back() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Assets* assets = &renderer.pass.assets;
		three::Scene* scene = renderer.pass.scene;

		image::Image first = banded({ 200, 0, 0 }, { 200, 0, 0 });
		defer first.free();
		image::Image second = banded({ 0, 200, 0 }, { 0, 200, 0 });
		defer second.free();

		int a = assets.claim_texture(&renderer.gpu, first)!!;
		int b = assets.claim_texture(&renderer.gpu, second)!!;
		test::@check(assets.textures[a].refs == 1 && assets.textures[b].refs == 1,
			"both start at one reference");

		renderer.pass.set_scene_sky(scene, true, a);
		test::@check(assets.textures[a].refs == 2,
			"assigning a background takes one, got %d", assets.textures[a].refs);

		renderer.pass.set_scene_sky(scene, true, a);
		test::@check(assets.textures[a].refs == 2,
			"assigning the same image again takes nothing, got %d", assets.textures[a].refs);

		renderer.pass.set_scene_sky(scene, true, b);
		test::@check(assets.textures[a].refs == 1 && assets.textures[b].refs == 2,
			"replacing it moves the reference, got %d and %d",
			assets.textures[a].refs, assets.textures[b].refs);

		renderer.pass.set_scene_sky(scene, true, three::NO_TEXTURE);
		test::@check(assets.textures[b].refs == 1,
			"and clearing it gives the last one back, got %d", assets.textures[b].refs);
	};
}

// ============================================================================
// The verbs a script uses
// ============================================================================

macro @with_js(; @body(three::JsRuntime* run))
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

<*
 `scene.background` takes an image as well as a colour, and `scene.environment`
 takes only an image.

 Three.js's two names, and the reason both are here rather than one: an interior
 lit through a window has an environment and a flat wall behind it, so a verb
 that set both together could not describe it.

 The read-back is on the Texture object rather than on an index, which is the
 contract the far side promises: what comes back is the very handle that was
 assigned, so `scene.background === sky` holds and a script can dispose it.
*>
fn void a_script_sets_a_sky_and_reads_it_back() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const px = new Uint8Array(4 * 4 * 4).fill(200);
			const sky = new three.DataTexture(px, 4, 4);
			const scene = new three.Scene();

			scene.background = sky;
			scene.environment = sky;
			scene.environmentIntensity = 0.5;
			scene.environmentRotation = 1.25;

			const same = scene.background === sky && scene.environment === sky;
			scene.background = 0x102030;
			return {
				same,
				intensity: scene.environmentIntensity,
				rotation: scene.environmentRotation,
				afterColor: scene.background,
				stillLit: scene.environment === sky,
			};
		`);
		defer result.free();
		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value.contains(`"same":true`),
			"both read back as the handle that was assigned: %s", result.value);
		test::@check(result.value.contains(`"intensity":0.5`),
			"and the intensity is what was set: %s", result.value);
		test::@check(result.value.contains(`"rotation":1.25`),
			"and so is the rotation: %s", result.value);
		test::@check(result.value.contains(`"stillLit":true`),
			"putting a colour back behind the scene leaves the environment alone: %s", result.value);
	};
}

<*
 A colour is refused where an image is wanted, with a sentence naming the two
 things it could have meant.

 `scene.environment = 0x87ceeb` is the mistake somebody makes exactly once, and
 the two right answers are next to each other — `scene.background` for a flat
 backdrop, `three.light.ambient` for a floor under the shading. Silently reading
 the number as a texture index would be the worst of it: index 0 is whatever
 image happened to load first.
*>
fn void an_environment_that_is_not_an_image_is_refused() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			let caught = "";
			try { scene.environment = 0x87ceeb; } catch (e) { caught = e.constructor.name + ": " + e.message; }
			let negative = "";
			try { scene.environmentIntensity = -1; } catch (e) { negative = e.constructor.name; }
			return { caught, negative };
		`);
		defer result.free();
		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value.contains("TypeError") && result.value.contains("scene.background"),
			"the message names the verb that does take a colour: %s", result.value);
		test::@check(result.value.contains(`"negative":"RangeError"`),
			"and a negative intensity is refused: %s", result.value);
	};
}
