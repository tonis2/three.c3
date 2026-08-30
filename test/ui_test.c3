<*
 The interface layer — `src/render/ui.c3` and `Target.begin_overlay`.

	`c3c test --trust=full --test-noleak --test-filter three_tests::ui`

 **Two claims, and they are the ones that would be quietly wrong.**

 The first is that the overlay draws *over* the finished frame rather than
 instead of it. `LOAD_OP_CLEAR` where `LOAD_OP_LOAD` belongs, or a barrier from
 `UNDEFINED` where the current layout belongs, both produce a frame that is
 exactly the interface on a black field — and neither is a validation error,
 because discarding an attachment is a legal thing to ask for. So the check is a
 pixel one: the scene has to still be there underneath.

 The second is that it is in `target.color` and therefore in `capture()`. The
 whole argument for drawing before the blit rather than after it is that
 `--screenshot`, the MCP screenshot tool and the window all show the same
 picture. *For free* is exactly the kind of claim that needs a test under it.

 Everything else is the validation layer's job, and it is armed here: a wrong
 load op is silent, but a missing barrier, a second `close`, or a rendering left
 open is not.
*>
module three_tests::ui;

import three;
import vk;
import image;
import std::core::test;
import std::math;
import std::io;

const uint W = 200;
const uint H = 120;

macro @with_renderer(; @body(three::Renderer* renderer))
{
	vk::Instance instance = three::create_instance(true, headless: true)!!;
	defer instance.free();

	three::Renderer renderer;
	renderer.init(instance, (vk::SurfaceKHR)null, W, H, validate: true)!!;
	defer renderer.free();

	renderer.pass.init(&renderer.gpu, &renderer.target)!!;

	@body(&renderer);
}

// A line, through the same entry point `three.debug.overlay` reaches.
fn void set(three::Renderer* renderer, String line)
{
	renderer.ui.set_overlay(&renderer.gpu, &renderer.target, line)!!;
}

// How much of the top-left corner is not the background — the band the overlay
// is anchored into. Counted rather than sampled: a glyph is thin, and the exact
// pixel a stem lands on is a fact about the font and not about the renderer.
fn uint lit_pixels(image::Image* img)
{
	sz bpp   = img.bytes_per_pixel();
	uint lit = 0;
	sz rows  = math::min((sz)img.height, (sz)40);
	for (sz y = 0; y < rows; y++)
	{
		for (sz x = 0; x < (sz)img.width; x++)
		{
			if (img.pixels[(y * (sz)img.width + x) * bpp] > 128) lit++;
		}
	}
	return lit;
}

// ============================================================================
// Nothing until something asks
// ============================================================================

<*
 A renderer nobody asked for an interface is a renderer with no interface.

 The claim the headless tests rest on: `Renderer.init` builds no `Ui`, no
 buffers and no pipeline, so every frame in every other file is byte-identical to
 one drawn before this layer existed.
*>
fn void the_layer_does_not_exist_until_it_is_used() @test
{
	@with_renderer(; three::Renderer* renderer)
	{
		test::@check(!renderer.ui.active(), "a fresh renderer already had an interface layer");

		image::Image shot = renderer.capture()!!;
		defer shot.free();
		test::@check(shot.width == W, "the frame came back the wrong size");

		test::@check(!renderer.ui.active(), "drawing a frame brought the interface layer up on its own");
	};
}

<*
 An empty line is not a line.

 `three.debug.overlay('')` is how a script takes the overlay away, and taking
 away something that was never there must not build a font atlas and a pipeline
 to do it.
*>
fn void an_empty_line_never_brings_the_layer_up() @test
{
	@with_renderer(; three::Renderer* renderer)
	{
		set(renderer, "");
		test::@check(!renderer.ui.active(), "an empty overlay built the whole layer");
	};
}

// ============================================================================
// The pixels
// ============================================================================

<*
 The line appears, and the frame under it survives.

 Both halves in one check, because they fail in opposite directions and a test
 for either one alone passes on the other's bug: an overlay that clears first
 shows *more* text on a *black* frame, which a "did anything appear" check
 cannot tell from success.
*>
fn void the_overlay_draws_over_the_frame_and_not_instead_of_it() @test
{
	@with_renderer(; three::Renderer* renderer)
	{
		// Not the default: a background this test picked, so "the scene survived"
		// is a fact about a specific colour rather than about whatever the default
		// happens to be today.
		renderer.clear = { 0.20, 0.05, 0.05, 1.0 };

		image::Image bare = renderer.capture()!!;
		defer bare.free();
		uint before = lit_pixels(&bare);

		set(renderer, "HELLO OVERLAY 12345");
		image::Image with = renderer.capture()!!;
		defer with.free();

		test::@check(lit_pixels(&with) > before, "the overlay put no bright pixels in the top band");

		// The bottom of the frame is nowhere near the overlay, so it is the half of
		// the picture a clear would have taken and a draw-over cannot touch.
		// 0.20 is written as sRGB and stored as sRGB, so the byte is 0.20 * 255 and
		// not the linear value — see `TARGET_COLOR_FORMAT`. A cleared frame reads 0
		// here, so anything near 51 is the background still being there.
		sz bpp    = with.bytes_per_pixel();
		sz bottom = ((sz)with.height - 4) * (sz)with.width + (sz)with.width / 2;
		test::@check(
			with.pixels[bottom * bpp] > 40,
			"the frame under the overlay was cleared — the red background is gone (r = %d)",
			(int)with.pixels[bottom * bpp]
		);
	};
}

<*
 Taking the line away puts the frame back exactly as it was.

 The other direction, and the one that catches an overlay that leaves its last
 glyphs in the display list: an empty label paints nothing, so the frame has to
 be identical to the one drawn before the layer existed at all.
*>
fn void clearing_the_line_restores_the_frame() @test
{
	@with_renderer(; three::Renderer* renderer)
	{
		renderer.clear = { 0.20, 0.05, 0.05, 1.0 };

		image::Image bare = renderer.capture()!!;
		defer bare.free();

		set(renderer, "gone in a moment");
		image::Image with = renderer.capture()!!;
		defer with.free();
		test::@check(lit_pixels(&with) > lit_pixels(&bare), "nothing was drawn to take away");

		set(renderer, "");
		image::Image after = renderer.capture()!!;
		defer after.free();

		test::@check(
			lit_pixels(&after) == lit_pixels(&bare),
			"the frame did not come back: %d lit pixels against %d",
			lit_pixels(&after),
			lit_pixels(&bare)
		);
	};
}

// ============================================================================
// The line's lifetime
// ============================================================================

<*
 One line, this frame, gone the next.

 `expire_overlay` runs at the top of the script frame, so a line set during the
 frame that just ran survives one expiry and not two. A script writing the same
 string every frame is the case that has to keep working, and it is the first
 half of this.
*>
fn void the_line_lasts_exactly_one_frame() @test
{
	@with_renderer(; three::Renderer* renderer)
	{
		renderer.clear = { 0.20, 0.05, 0.05, 1.0 };

		image::Image bare = renderer.capture()!!;
		defer bare.free();

		set(renderer, "hp 100");

		// The frame the line was set in.
		renderer.ui.expire_overlay();
		image::Image kept = renderer.capture()!!;
		defer kept.free();
		test::@check(lit_pixels(&kept) > lit_pixels(&bare), "the line was dropped by the frame that set it");

		// The next one, with nothing having written it again.
		renderer.ui.expire_overlay();
		image::Image dropped = renderer.capture()!!;
		defer dropped.free();
		test::@check(
			lit_pixels(&dropped) == lit_pixels(&bare),
			"the line outlived the frame it belonged to"
		);
	};
}

// ============================================================================
// Under the validation layer
// ============================================================================

<*
 Four frames with an interface on them, and the layer has nothing to say.

 Four rather than one because `CANVAS_SLOTS` is 2: a host that writes the copy a
 queued draw is still reading tears the display list, and the second time round
 the rotation is the first frame that could. The changing text is what makes each
 upload a real one — an unchanged canvas uploads nothing, which would leave the
 rotation untested.

 `render_offscreen` is here rather than assumed: it is the second of the three
 paths into `record_scene`, and "they all go through one function" is the claim
 being checked rather than repeated.
*>
fn void the_overlay_is_silent_under_validation() @test
{
	@with_renderer(; three::Renderer* renderer)
	{
		if (!renderer.gpu.validation) return;

		// One frame before the sink is armed, so anything the layer objects to
		// afterwards belongs to the overlay and not to the setup.
		image::Image warmup = renderer.capture()!!;
		warmup.free();

		renderer.gpu.begin_capture();

		set(renderer, "frame one");
		image::Image one = renderer.capture()!!;
		one.free();

		set(renderer, "frame two, a longer line");
		image::Image two = renderer.capture()!!;
		two.free();

		set(renderer, "3");
		renderer.render_offscreen()!!;

		set(renderer, "");
		image::Image bare = renderer.capture()!!;
		bare.free();

		String errors   = renderer.gpu.sink.errors.str_view();
		String warnings = renderer.gpu.sink.warnings.str_view();
		renderer.gpu.end_capture();

		test::@check(errors.len == 0, "the overlay produced validation errors: %s", errors);
		test::@check(warnings.len == 0, "and warnings: %s", warnings);
	};
}

<*
 The same, with a post chain running.

 The one ordering that is not exercised by any other check here: with a chain
 active it is the tonemap that leaves `target.color` in
 `COLOR_ATTACHMENT_OPTIMAL`, not the scene, and `begin_overlay` barriers from
 that layout on both paths. A wrong `oldLayout` is a validation error rather than
 a wrong picture, which is why this is a silence check and not a pixel one.
*>
fn void the_overlay_is_silent_over_a_post_chain() @test
{
	@with_renderer(; three::Renderer* renderer)
	{
		if (!renderer.gpu.validation) return;

		renderer.post.set(&renderer.gpu, &renderer.target, `float3 post(Post p) { return p.color.bgr; }`, {})!!;

		image::Image warmup = renderer.capture()!!;
		warmup.free();

		renderer.gpu.begin_capture();

		set(renderer, "over the chain");
		image::Image one = renderer.capture()!!;
		one.free();
		image::Image two = renderer.capture()!!;
		two.free();

		String errors   = renderer.gpu.sink.errors.str_view();
		String warnings = renderer.gpu.sink.warnings.str_view();
		renderer.gpu.end_capture();

		test::@check(errors.len == 0, "the overlay over a post chain produced validation errors: %s", errors);
		test::@check(warnings.len == 0, "and warnings: %s", warnings);
	};
}
