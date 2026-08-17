<*
 The base stage's renderer, checked with no window and no window server.

	`c3c test --trust=full --test-noleak --test-filter three_tests::gpu`

 Every check here runs headless, which is not a compromise — it is the whole
 argument for `plan.md` §1. The offscreen target is what `render()` draws into
 whether or not a window exists, so **a headless render into a buffer, asserted
 on pixels, tests the real renderer rather than a second code path built for
 testing.** If these pass, the picture in the window is the same picture.

 What is deliberately not here: anything that asserts on a mode flag. A flag
 says nothing about whether anything rendered. These compare pixels.

 Timings read off a leak-tracked run mean nothing — the runner installs a
 `TrackingAllocator` for the length of each check, which on this machine costs
 roughly 100x the real price of anything that allocates per element. Use
 `--test-noleak` while working and the leak-tracked run to check ownership.
*>
module three_tests::gpu;

import three;
import vk;
import image;
import std::core::test;
import std::io;

// Small on purpose: these check correctness, not throughput, and a 64x48
// target keeps a leak-tracked run quick.
const uint W = 64;
const uint H = 48;

<*
 A headless instance + device, torn down on the way out.

 Written as a macro rather than a fixture function because C3's `defer` is
 scoped to the function that declares it: a helper returning a live Gpu would
 have to hand back its cleanup too, and every check would then be one forgotten
 line away from leaking a device.
*>
macro @with_gpu(; @body(three::Gpu* gpu))
{
	vk::Instance instance = three::create_instance(false, headless: true)!!;
	defer instance.free();

	three::Gpu gpu;
	gpu.init(instance, (vk::SurfaceKHR)null)!!;
	defer gpu.free();

	@body(&gpu);
}

macro @with_renderer(; @body(three::Renderer* renderer))
{
	vk::Instance instance = three::create_instance(false, headless: true)!!;
	defer instance.free();

	three::Renderer renderer;
	renderer.init(instance, (vk::SurfaceKHR)null, W, H)!!;
	defer renderer.free();

	@body(&renderer);
}

<*
 Bring a device up and take it down again.

 Under leak tracking this is the check that says the instance, the device, the
 queue and the allocator's pages are all accounted for. It also asserts the two
 features the project cannot degrade without: there is no vertex-input fallback
 for buffer device addresses, and no `VkRenderPass` path to fall back to
 without dynamic rendering.
*>
fn void device_comes_up_headless() @test
{
	@with_gpu(; three::Gpu* gpu)
	{
		test::@check(gpu.handle != null, "no logical device");
		test::@check(gpu.graphics.handle != null, "no graphics queue");
		test::@check(gpu.limits.buffer_device_address, "bufferDeviceAddress is off; geometry has no route to the shader");
		test::@check(gpu.limits.dynamic_rendering, "dynamicRendering is off; this project has no VkRenderPass path");
		test::@check(gpu.limits.max_push_constants_size >= 128, "maxPushConstantsSize is %d, below the 128 every device must offer", gpu.limits.max_push_constants_size);
	};
}

<*
 Create and destroy the target at two different extents (`base_stage.md` S3).

 Two sizes rather than one because the interesting failure is a resource that
 outlives its extent — a view kept from the first size, or memory sized from
 the wrong one. Both live at once here so an allocator that hands the second
 target the first one's page has somewhere to go wrong.
*>
fn void target_at_two_extents() @test
{
	@with_gpu(; three::Gpu* gpu)
	{
		three::Target small;
		small.init(gpu, 320, 240)!!;
		test::@check(small.extent.width == 320 && small.extent.height == 240, "the target did not take the extent it was given");
		test::@check(small.color_format == three::TARGET_COLOR_FORMAT, "the colour format is not the one three.c3 chose");

		three::Target large;
		large.init(gpu, 1280, 720)!!;
		test::@check(large.extent.width == 1280, "the second target took the first one's extent");
		test::@check(large.color != small.color, "two targets share one image");

		large.free(gpu);
		small.free(gpu);
	};
}

<*
 Render one frame headless and read the pixels back.

 The assertion is on the pixels, not on a return code: the clear colour is
 known, so every pixel is known, and a renderer that submits happily while
 drawing nothing fails here. This is the check `base_stage.md` calls the one
 that makes M2 onward cheap.
*>
fn void headless_render_produces_the_clear_colour() @test
{
	@with_renderer(; three::Renderer* renderer)
	{
		renderer.clear = { 0.25, 0.50, 0.75, 1.0 };

		image::Image shot = renderer.capture()!!;
		defer shot.free();

		test::@check(shot.width == W && shot.height == H, "read back %dx%d, expected %dx%d", shot.width, shot.height, W, H);
		test::@check(shot.pixels.len == (sz)W * H * 4, "read back %d bytes for a %dx%d RGBA image", shot.pixels.len, W, H);

		// UNORM, so the byte is the float scaled by 255 and rounded. A
		// one-count tolerance covers the rounding the driver is entitled to
		// pick; anything larger is a format or a swizzle problem.
		char[4] want = { 64, 128, 191, 255 };
		foreach (p, byte : shot.pixels)
		{
			char expect = want[p % 4];
			int drift   = (int)byte - (int)expect;
			if (drift < 0) drift = -drift;
			test::@check(drift <= 1, "pixel %d channel %d read %d, expected %d", p / 4, p % 4, byte, expect);
		}
	};
}

<*
 Alpha is forced opaque on the way out.

 A half-transparent PNG of a finished frame is never what was wanted, and the
 failure is invisible until someone opens the file over a light background.
*>
fn void readback_alpha_is_opaque() @test
{
	@with_renderer(; three::Renderer* renderer)
	{
		renderer.clear = { 0.0, 0.0, 0.0, 0.0 };

		image::Image shot = renderer.capture()!!;
		defer shot.free();

		for (sz i = 3; i < shot.pixels.len; i += 4)
		{
			test::@check(shot.pixels[i] == 0xff, "pixel %d came back with alpha %d", i / 4, shot.pixels[i]);
		}
	};
}

<*
 Two captures of the same scene are identical, byte for byte.

 This is what makes an image comparison a legitimate test rather than a flaky
 one, and it is only true because the screenshot is the rendered image and not
 an OS window grab. It also exercises the frame slots: the two captures land on
 different slots, so a fence or command buffer reused across them shows up
 here.
*>
fn void captures_are_reproducible() @test
{
	@with_renderer(; three::Renderer* renderer)
	{
		image::Image first = renderer.capture()!!;
		defer first.free();
		image::Image second = renderer.capture()!!;
		defer second.free();

		test::@check(first.pixels.len == second.pixels.len, "two captures came back different sizes");
		foreach (i, byte : first.pixels)
		{
			test::@check(byte == second.pixels[i], "byte %d differs between two captures: %d then %d", i, byte, second.pixels[i]);
		}
	};
}
