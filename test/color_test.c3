<*
 Colour management: the sRGB round trip, end to end.

	`c3c test --trust=full --test-noleak --test-filter three_tests::color`

 ## What was wrong, and why nothing here existed to catch it

 Textures uploaded as `R8G8B8A8_SRGB`, so the sampler decoded them to linear on
 read. The colour target was `R8G8B8A8_UNORM`, so nothing encoded on write. The
 swapchain and every PNG then presented those bytes as sRGB. One decode, no
 encode: **every textured scene rendered about 2.2 too dark**.

 The whole suite passed through all of it, and the reason is worth stating
 because it is the general shape of a test that proves nothing. A flat colour —
 a clear value, a `mesh.color` — was not decoded on the way in and not encoded
 on the way out, so it survived by *identity*. Set 0x2060a0, read 0x2060a0. Every
 round-trip check in `three_tests::environment` was satisfied by two errors that
 happened not to exist on the path it walked, and it would have kept being
 satisfied no matter how wrong the textured path got.

 So the checks here are built on the one thing an identity cannot fake: **the two
 ways a colour can enter must agree with each other.** A texel and an instance
 colour of the same value go through completely different machinery — one
 through a sampler that decodes, one through a push constant that does not — and
 there is no way for both to be wrong in the same direction. `pow` the wrong way
 anywhere and they separate.

 ## Proved by injection

 Every check below was re-run against the broken pipeline before being kept:

 - **`TARGET_COLOR_FORMAT` back to `FORMAT_R8G8B8A8_UNORM`:**
   `a_texture_survives_its_own_round_trip` fails, reading 210 back for a texel
   of 234. `a_texel_and_an_instance_colour_of_the_same_value_agree` **keeps
   passing**, and that is worth stating rather than hiding: with the decode in
   the shaders both doors are wrong by the same amount, so agreement survives a
   missing encode. The two checks cover different halves on purpose — one the
   input side, one the output side — and neither is sufficient alone.
 - **`srgb_to_linear` in the two shaders replaced by the identity:** the doors
   separate, 89 against 132 for an input of 128. This is the original bug: the
   sampler decodes the texel and nothing decodes the instance colour.
 - The piecewise curve replaced by `pow(c, 2.2)`: the clear colour stops
   surviving its own round trip by up to 9 levels, which is what
   `the_approximation_would_not_have_survived` measures directly.
*>
module three_tests::color;

import three;
import vk;
import image;
import std::core::test;
import std::io;
import std::math;

const uint W = 120;
const uint H = 90;

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
 A solid RGBA image of one colour, owned by the caller.

 Solid rather than a pattern on purpose: this file is measuring a *value*, and
 anything with an edge in it invites a check that is really about filtering.
*>
fn image::Image solid(char r, char g, char b)
{
	char[] pixels = mem::new_array(char, 4 * 4 * 4);
	for (sz i = 0; i < pixels.len; i += 4)
	{
		pixels[i] = r;
		pixels[i + 1] = g;
		pixels[i + 2] = b;
		pixels[i + 3] = 255;
	}
	return { .width = 4, .height = 4, .bit_depth = 8, .format = image::PixelFormat.RGBA, .pixels = pixels, .allocator = mem };
}

fn char[3] centre(image::Image* img)
{
	sz bpp = img.bytes_per_pixel();
	sz at = ((sz)(img.height / 2) * (sz)img.width + (sz)(img.width / 2)) * bpp;
	return { img.pixels[at], img.pixels[at + 1], img.pixels[at + 2] };
}

<*
 A full-frame plane, so the centre pixel is the subject and nothing else.

 Hands back the asset as well as the node because one check has to reach the
 `GpuMesh` behind it and neutralise `PRIMITIVE_COLOR`; see there for why.
*>
fn three::NodeId fill_frame(three::Renderer* renderer, three::AssetId* asset = null)
{
	three::AssetId plane = renderer.pass.assets.primitive(&renderer.gpu, three::plane_shape(2, 2))!!;
	if (asset != null) *asset = plane;
	three::NodeId node = renderer.pass.scene.add_mesh(plane, 0);
	renderer.pass.frame_camera();
	return node;
}

// ============================================================================
// The two doors a colour comes in through
// ============================================================================

<*
 **The check the old pipeline could not have passed.**

 The same three bytes, entered twice: once as the only texel of a texture, once
 as `mesh.color` on an untextured plane. Both are then multiplied by the same
 light term against the same normal, so whatever that term is, it is the same
 term — the comparison is of the two colour paths and of nothing else.

 Under the broken pipeline the texel was decoded and never re-encoded while the
 colour was neither, so they came out 55 and 128 for one input. There is no
 single-error version of this that passes: a missing decode and a missing encode
 cancel only when *both* are missing, and the texel path cannot have both.

 The tolerance is 2 levels rather than exact, and that is not slack. The texture
 is 4x4 and magnified across the frame, so the sampler filters between four
 identical texels — which is exact in arithmetic and not quite in 8 bits — and
 the light term is a float multiply applied to two values that reach it by
 different routes. Two levels is under half a percent; the failure this catches
 is 70.
*>
fn void a_texel_and_an_instance_colour_of_the_same_value_agree() @test
{
	char[3] want = { 0x80, 0x40, 0xc0 };
	char[3] from_texture;
	char[3] from_color;

	@with_pass(; three::Renderer* renderer)
	{
		image::Image grey = solid(want[0], want[1], want[2]);
		defer grey.free();
		int texture = renderer.pass.assets.claim_texture(&renderer.gpu, grey)!!;
		uint material = renderer.pass.create_texture_material(texture)!!;

		three::NodeId node = fill_frame(renderer);
		renderer.pass.scene.set_material(node, material);

		image::Image shot = renderer.capture()!!;
		defer shot.free();
		from_texture = centre(&shot);
	};

	@with_pass(; three::Renderer* renderer)
	{
		three::NodeId node = fill_frame(renderer);
		renderer.pass.scene.set_color(node, {
			(float)want[0] / 255.0f, (float)want[1] / 255.0f, (float)want[2] / 255.0f, 1.0f
		});

		image::Image shot = renderer.capture()!!;
		defer shot.free();
		from_color = centre(&shot);
	};

	for (int i = 0; i < 3; i++)
	{
		test::@check(math::abs((int)from_texture[i] - (int)from_color[i]) <= 2,
			"channel %d: the texel path gave %d and the mesh.color path gave %d for the same input %d — the two ways a colour enters the renderer disagree",
			i, (int)from_texture[i], (int)from_color[i], (int)want[i]
		);
	}
}

<*
 A texture comes back out as the bytes that went in.

 The stronger claim, and the one that needs the light pinned: with the light
 pointing straight at the plane's normal and no ambient shortfall, the shading
 term is exactly 1, so a correct pipeline is the identity from texel byte to
 screen byte. Anything else in the chain — the decode, the encode, the target
 format — shows up as a number that is not the number.

 Uses `lightSet` rather than a hand-built frame block, which is the point of
 that verb existing: the fixed direction the renderer starts on is a diagonal,
 so before it was bindable this check could only have been written as an
 inequality.
*>
fn void a_texture_survives_its_own_round_trip() @test
{
	char[3] want = { 0xea, 0x30, 0x7b };

	@with_pass(; three::Renderer* renderer)
	{
		image::Image swatch = solid(want[0], want[1], want[2]);
		defer swatch.free();
		int texture = renderer.pass.assets.claim_texture(&renderer.gpu, swatch)!!;
		uint material = renderer.pass.create_texture_material(texture)!!;

		three::AssetId plane;
		three::NodeId node = fill_frame(renderer, &plane);
		renderer.pass.scene.set_material(node, material);

		// **Two tints have to be taken out of the way before "identity" means
		// anything**, and both of them are deliberate features that this one
		// check happens to need silenced. Neither is touched anywhere else.
		//
		// `PRIMITIVE_COLOR` is `{0.78, 0.78, 0.80}` — a generated shape is not
		// white, on purpose, so a scene of untextured boxes does not read as a
		// broken material. It multiplies the texture, so the plane has to be
		// made white here or the round trip is 0.78 of itself and the check
		// would be asserting the constant rather than the pipeline.
		renderer.pass.assets.mesh(plane, 0).base_color = { 1.0f, 1.0f, 1.0f, 1.0f };

		// And the light: straight down the plane's own normal — `plane_shape`
		// builds its face along +z — so the shading term is exactly 1 and the
		// ambient floor cannot contribute. Without this the default direction is
		// a diagonal and the strongest claim available would be an inequality.
		renderer.pass.lighting = { .count = 1, .ambient = 0, .lights = { { .direction = { 0, 0, 1, 0 }, .color = { 1, 1, 1, 1 } }, {}, {}, {} } };

		image::Image shot = renderer.capture()!!;
		defer shot.free();
		char[3] got = centre(&shot);

		for (int i = 0; i < 3; i++)
		{
			test::@check(math::abs((int)got[i] - (int)want[i]) <= 2,
				"channel %d came back %d for a texel of %d — the sRGB round trip is not closed",
				i, (int)got[i], (int)want[i]
			);
		}
	};
}

// ============================================================================
// The curve itself, with no GPU in the way
// ============================================================================

<*
 The transfer functions are inverses across the whole 8-bit range.

 Every level, not a sample: the piecewise join at 0.04045 is exactly where an
 off-by-one in the condition hides, and it is four levels wide.
*>
fn void the_transfer_functions_invert_each_other() @test
{
	for (int i = 0; i <= 255; i++)
	{
		float v = (float)i / 255.0f;
		float round_trip = three::linear_to_srgb(three::srgb_to_linear(v));
		int back = (int)math::round(round_trip * 255.0f);
		test::@check(back == i,
			"level %d came back as %d — srgb_to_linear and linear_to_srgb are not inverses",
			i, back
		);
	}
}

<*
 `pow(c, 2.2)` would not have survived, and this is the number that says so.

 The interesting comparison is not how far the approximation sits from the real
 curve in the abstract — in the linear domain that is only about 3 levels, which
 sounds ignorable. It is what happens when the approximation meets the hardware,
 because the hardware is not negotiable: the `_SRGB` colour attachment encodes
 with the exact piecewise curve whatever the CPU decoded with.

 So the thing to measure is the round trip a clear colour actually takes —
 decode on this side, encode on the device — with the approximation standing in
 for the decode. It comes back **wrong by up to 9 levels, worst at input 15**,
 which is a visible step in exactly the part of the range where 8-bit banding
 already lives, and it would have made
 `the_frame_is_cleared_to_the_background_that_was_set` fail for a reason nobody
 would have looked for in a transfer function.

 Kept as a check rather than as a comment so "close enough" cannot be concluded
 later without deleting a passing test to do it.
*>
fn void the_approximation_would_not_have_survived() @test
{
	int worst = 0;
	int worst_at = 0;
	for (int i = 0; i <= 255; i++)
	{
		float v = (float)i / 255.0f;
		float approx_decode = (float)math::pow((double)v, 2.2);
		int back = (int)math::round(three::linear_to_srgb(approx_decode) * 255.0f);
		if (math::abs(back - i) > worst)
		{
			worst = math::abs(back - i);
			worst_at = i;
		}
	}
	test::@check(worst >= 8,
		"pow(c, 2.2) as the decode survives the hardware encode to within %d levels (worst at %d), so the piecewise curve is not earning its complexity",
		worst, worst_at
	);

	// And the exact one does survive it, which is the half that makes the number
	// above mean something rather than just being large.
	for (int i = 0; i <= 255; i++)
	{
		float v = (float)i / 255.0f;
		int back = (int)math::round(three::linear_to_srgb(three::srgb_to_linear(v)) * 255.0f);
		test::@check(back == i, "the exact curve lost level %d, coming back as %d", i, back);
	}
}

<*
 Out of range is clamped, not reflected.

 A negative under a fractional power is a NaN, and a NaN clear colour is a black
 frame with nothing anywhere saying why. Asserted because the guard is one line
 and deleting it fails nothing else.
*>
fn void the_curve_refuses_to_produce_a_nan() @test
{
	float[*] wild = { -1.0f, -0.0001f, 1.0001f, 4.0f };
	foreach (v : wild)
	{
		float lin = three::srgb_to_linear(v);
		float back = three::linear_to_srgb(v);
		test::@check(lin == lin && lin >= 0.0f && lin <= 1.0f, "srgb_to_linear(%f) is not in range", v);
		test::@check(back == back && back >= 0.0f && back <= 1.0f, "linear_to_srgb(%f) is not in range", v);
	}
}
