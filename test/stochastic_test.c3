<*
 `material.stochastic` — sampling a tiled map so that it stops having a period.

	`c3c test --trust=full --test-noleak --test-filter three_tests::stochastic`

 `plan.md` §27, and `stochastic_sample` in `shaders/surface.slang` is the whole
 of the arithmetic: three taps of one image at three per-cell random offsets,
 blended by the barycentric weight of a triangular lattice over the uv.

 ## The measurement, and why it needs no geometry

 A repeat *is* a period, and a period is a thing that can be measured without
 knowing where anything is on screen: shift the map by exactly one whole repeat
 and a straight-sampled surface renders **the same frame**, texel for texel,
 because `Sample(uv + 1)` and `Sample(uv)` are the same texel under a repeating
 sampler. That equality is the artefact. Under `stochastic` it has to break — the
 lattice lives in the tiled uv, so a shift of one repeat moves every point into
 different cells — and nothing about where the plane lands in the frame enters
 the check.

 So every test here compares one surface against itself, twice, and the control
 is in the test rather than in a remembered number.

 ## Proved by injection

 - `stochastic_sample` returning the one un-jittered tap — the feature present,
   wired, and doing nothing: "shifting a stochastic surface by one whole repeat
   drew the same frame back: 0 of 9 samples moved", with the flat-image check
   still passing beside it, which is what makes the pair worth having.
 - the barycentric weights scaled by 1.5, so they no longer sum to one: "a flat
   image is the same flat image: 124 straight, 149 scattered" — the surface gets
   brighter, which is a mistake invisible on anything textured and wrong
   everywhere.
*>
module three_tests::stochastic;

import three;
import three_tests::device;
import vk;
import image;
import std::core::test;
import std::math;

const uint W = 120;
const uint H = 90;

macro @with_pass(; @body(three::Renderer* renderer))
{
	three::Renderer* renderer = device::borrow(W, H);
	defer device::release();

	@body(renderer);
}

// A 16x16 field of pseudo-random greys, and nothing regular in it — the content
// this is for, and the content a period is most visible in.
fn image::Image noise_image()
{
	char[] pixels = mem::new_array(char, 16 * 16 * 4);
	uint seed = 12345;
	for (sz i = 0; i < pixels.len; i += 4)
	{
		seed = seed * 1664525 + 1013904223;
		char value = (char)(60 + (seed >> 24) % 190);
		pixels[i] = value;
		pixels[i + 1] = value;
		pixels[i + 2] = value;
		pixels[i + 3] = 255;
	}
	return {
		.width = 16, .height = 16, .bit_depth = 8,
		.format = image::PixelFormat.RGBA, .pixels = pixels, .allocator = mem,
	};
}

fn image::Image flat_image(char value)
{
	char[] pixels = mem::new_array(char, 4 * 4 * 4);
	for (sz i = 0; i < pixels.len; i += 4)
	{
		pixels[i] = value;
		pixels[i + 1] = value;
		pixels[i + 2] = value;
		pixels[i + 3] = 255;
	}
	return {
		.width = 4, .height = 4, .bit_depth = 8,
		.format = image::PixelFormat.RGBA, .pixels = pixels, .allocator = mem,
	};
}

fn uint material_wearing(three::Renderer* renderer, image::Image made)
{
	int texture = renderer.pass.assets.claim_texture(&renderer.gpu, made, three::ColorSpace.SRGB)!!;
	return renderer.pass.create_texture_material(texture)!!;
}

// A plane filling as much of the frame as `frame_camera` gives it, lit down its
// own normal so a pixel is the albedo and nothing else.
fn void lit_plane(three::Renderer* renderer, uint material)
{
	three::AssetId plane = renderer.pass.assets.primitive(&renderer.gpu, three::plane_shape(2, 2))!!;
	three::NodeId node   = renderer.pass.scene.add_mesh(plane, 0);
	renderer.pass.scene.set_material(node, material);
	renderer.pass.frame_camera();
	renderer.pass.lighting = {
		.count = 1,
		.ambient = 0,
		.lights = { { .direction = { 0, 0, 1, 0 }, .color = { 1, 1, 1, 1 } }, { }, { }, { } },
	};
}

// Nine samples in a grid across the middle of the frame, green channel only.
//
// A grid and not one pixel: a shift of one repeat under a stochastic sample
// moves most of the surface and is entitled to leave any single point of it
// alone, so a check reading one pixel would be a check that sometimes passes for
// the wrong reason.
fn char[9] grid(three::Renderer* renderer)
{
	image::Image shot = renderer.capture()!!;
	defer shot.free();
	sz bpp = shot.bytes_per_pixel();

	char[9] out;
	for (uint i = 0; i < 9; i++)
	{
		sz x = (sz)((0.35f + 0.15f * (float)(i % 3)) * (float)shot.width);
		sz y = (sz)((0.35f + 0.15f * (float)(i / 3)) * (float)shot.height);
		out[i] = shot.pixels[(y * (sz)shot.width + x) * bpp + 1];
	}
	return out;
}

fn uint differences(char[9] a, char[9] b)
{
	uint count = 0;
	for (uint i = 0; i < 9; i++) if (a[i] != b[i]) count++;
	return count;
}

<*
 A repeat is a period, and this is it being measured.

 The control, and it has to hold before the next test means anything: a straight
 sample shifted by one whole repeat is the same picture, because that is what
 tiling *is*. If this ever fails, the test below is measuring the sampler's wrap
 mode rather than the feature.
*>
fn void a_straight_repeat_is_a_period() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		image::Image made = noise_image();
		defer made.free();
		uint material = material_wearing(renderer, made);
		lit_plane(renderer, material);

		renderer.pass.set_material_uv(material, 4, 4, 0, 0)!!;
		char[9] first = grid(renderer);

		renderer.pass.set_material_uv(material, 4, 4, 1, 0)!!;
		char[9] shifted = grid(renderer);

		test::@check(
			differences(first, shifted) == 0,
			"a tiled surface shifted by one whole repeat is the same surface: %d of 9 samples moved",
			differences(first, shifted)
		);
	};
}

<*
 And `stochastic` takes it away.

 The whole feature, as a number: the same shift over the same surface with the
 same image has to change the picture, because the lattice is anchored in the
 tiled uv and one repeat of shift is several cells of it.
*>
fn void stochastic_sampling_removes_the_period() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		image::Image made = noise_image();
		defer made.free();
		uint material = material_wearing(renderer, made);
		lit_plane(renderer, material);
		renderer.pass.set_material_stochastic(material, true)!!;

		renderer.pass.set_material_uv(material, 4, 4, 0, 0)!!;
		char[9] first = grid(renderer);

		renderer.pass.set_material_uv(material, 4, 4, 1, 0)!!;
		char[9] shifted = grid(renderer);

		test::@check(
			differences(first, shifted) >= 7,
			"shifting a stochastic surface by one whole repeat drew the same frame back: "
				"%d of 9 samples moved",
			differences(first, shifted)
		);
	};
}

<*
 A flat image comes back exactly as it was.

 The correctness half, and the one that catches the arithmetic rather than the
 wiring: the three weights are barycentric and sum to one, so however far the
 three taps are moved they are three samples of the same value and the blend is
 that value. A surface that changes brightness here has weights that do not
 partition — which is invisible on anything textured and wrong everywhere.
*>
fn void a_flat_image_is_unchanged_by_scattering() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		image::Image made = flat_image(160);
		defer made.free();
		uint material = material_wearing(renderer, made);
		lit_plane(renderer, material);
		renderer.pass.set_material_uv(material, 7, 7, 0, 0)!!;

		char[9] straight = grid(renderer);
		renderer.pass.set_material_stochastic(material, true)!!;
		char[9] scattered = grid(renderer);

		test::@check(
			differences(straight, scattered) == 0,
			"a flat image is the same flat image: %d straight, %d scattered",
			straight[4],
			scattered[4]
		);
	};
}

<*
 It is a bit on the draw record, so turning it off puts the surface back.

 The half that says the flag is read per draw rather than latched when the
 material was made — the same claim `three_tests::maps` makes about each of its
 three maps, and for the same reason: a material a script animates has to be able
 to change its mind.
*>
fn void turning_it_off_puts_the_surface_back() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		image::Image made = noise_image();
		defer made.free();
		uint material = material_wearing(renderer, made);
		lit_plane(renderer, material);
		renderer.pass.set_material_uv(material, 4, 4, 0, 0)!!;

		char[9] before = grid(renderer);

		renderer.pass.set_material_stochastic(material, true)!!;
		char[9] on = grid(renderer);
		test::@check(
			differences(before, on) >= 5,
			"scattering a noisy surface changed it: %d of 9 samples moved",
			differences(before, on)
		);
		test::@check(
			renderer.pass.material_stochastic(material),
			"and the material says so"
		);

		renderer.pass.set_material_stochastic(material, false)!!;
		char[9] off = grid(renderer);
		test::@check(
			differences(before, off) == 0,
			"and turning it off put the surface back: %d of 9 samples still moved",
			differences(before, off)
		);
	};
}
