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
 The same device, with the Khronos layer loaded and the messenger installed.

 Kept apart from `@with_gpu` rather than made a parameter of it, because the
 unvalidated path is the one that ships: a suite that only ever ran with the
 layer loaded would stop saying anything about the configuration users get.

 The layer is not on every machine, and `create_instance` skips it rather than
 failing when it is missing. So `gpu.validation` is the honest answer to "is
 there a messenger at all", and every check below reads it instead of assuming.
*>
macro @with_validating_gpu(; @body(three::Gpu* gpu))
{
	vk::Instance instance = three::create_instance(true, headless: true)!!;
	defer instance.free();

	three::Gpu gpu;
	gpu.init(instance, (vk::SurfaceKHR)null, validate: true)!!;
	defer gpu.free();

	@body(&gpu);
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
		test::@check(
			gpu.limits.buffer_device_address,
			"bufferDeviceAddress is off; geometry has no route to the shader"
		);
		test::@check(gpu.limits.dynamic_rendering, "dynamicRendering is off; this project has no VkRenderPass path");
		test::@check(
			gpu.limits.max_push_constants_size >= 128,
			"maxPushConstantsSize is %d, below the 128 every device must offer",
			gpu.limits.max_push_constants_size
		);
		test::@check(
			gpu.limits.push_descriptor,
			"pushDescriptor is off; since M5 there are no descriptor sets to fall back to"
		);
	};
}

// ============================================================================
// Validation reaches the caller
// ============================================================================

<*
 Without the Khronos layer, none of the checks below are checks.

 Six of them here and five in `mcp_test.c3` open with `if (!gpu.validation)
 return;`, because the product has to work on a machine that has no Vulkan SDK.
 On such a machine every one of them passes without executing a line — `plan.md`
 §7's unexercised regression test exactly: a green suite that has quietly stopped
 asking the question. Measured, not feared: renaming the layer to something not
 installed leaves this file at 92 passed, 0 failed.

 So the absence is reported here instead of being inferred from nothing. This is
 about the machine the suite runs on, not about the product —
 `asking_for_validation_never_costs_the_device` is what says the product copes.

 **A release build is the third case and is not a failure.** Without `-D DEBUG`
 the layer is compiled out on purpose, so every check below is inert by design
 rather than by accident. Failing here would make the default `c3c test` red on
 a working tree, which is the fastest way to teach everyone to ignore this one
 line. It says so and returns instead — and `a_release_build_loads_no_validation_layer`
 is the check that has something to assert in that configuration.
*>
fn void without_the_validation_layer_none_of_these_are_tests() @test
{
	if (three::DEBUG_BUILD)
	{
		test::@check(
			three::validation_layer_present(),
			"VK_LAYER_KHRONOS_validation is not installed, so every validation check in this "
				"suite passed without running. Install the Vulkan SDK, or read this one failure as "
				"'the validation half of M5 is untested on this machine'."
		);
	}
}

<*
 A real validation error, and a safe one.

 A zero-size buffer breaks VUID-VkBufferCreateInfo-size-00912, which the layer
 checks *before* it forwards the call — so the message is a genuine one from the
 Khronos layer about a real device, and nothing invalid ever reaches the driver.
 That second half is why this and not a bad descriptor binding: `plan.md` §4's
 own example of a validation bug is a hang, and a test suite is the wrong place
 to find one.
*>
fn void provoke_validation_error(three::Gpu* gpu)
{
	vk::Buffer? refused = vk::bufferCreateInfo().setSize(0)
		.setUsage((vk::BufferUsageFlags)vk::BufferUsageFlagBits.BUFFER_USAGE_TRANSFER_SRC_BIT)
		.build(gpu.handle);
	// The layer refuses it, so there is normally nothing here. Guarded rather
	// than assumed: without the layer the call succeeds and this would leak.
	if (try made = refused) vk::destroyBuffer(gpu.handle, made, null);
}

<*
 Hand a message of any severity to the loader, which routes it to every
 registered messenger whose mask matches.

 Not the same thing as calling the callback: this goes through
 `vkSubmitDebugUtilsMessageEXT`, so what is under test is the *registration* —
 the severity and type masks, and whether `pUserData` reached the callback — and
 not just the function body. It is the only way to ask about a severity this
 project has deliberately not subscribed to.
*>
fn void submit_message(three::Gpu* gpu, vk::DebugUtilsMessageSeverityFlagBitsEXT severity, ZString id, ZString text)
{
	vk::DebugUtilsMessengerCallbackDataEXT data = vk::debugUtilsMessengerCallbackDataEXT().setMessageIdName((char*)id)
		.setMessage((char*)text);
	vk::submitDebugUtilsMessageEXT(
		gpu.instance,
		severity,
		(vk::DebugUtilsMessageTypeFlagsEXT)vk::DebugUtilsMessageTypeFlagBitsEXT
			.DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT,
		&data
	);
}

<*
 Asking for validation never costs the device, whether or not the layer is there.

 `vkCreateInstance` fails outright with ERROR_LAYER_NOT_PRESENT when it is handed
 a layer that is not installed, so the naive version of this feature is a
 three.c3 that will not start on a machine without the Vulkan SDK. Refusing to
 run because the *diagnostics* are missing is the wrong trade.

 The second check is the one that keeps the first honest: `gpu.validation` has to
 agree with what is actually installed. A flag stuck on `true` would leave
 `js/runtime.c3` arming a capture against a messenger that does not exist, and
 every run would report a clean device it never heard from.
*>
fn void asking_for_validation_never_costs_the_device() @test
{
	@with_validating_gpu(; three::Gpu* gpu)
	{
		bool installed = three::validation_layer_present();

		test::@check(gpu.handle != null, "asking for validation lost the device");
		test::@check(
			gpu.validation == installed,
			"validation reports %s while the layer is installed: %s",
			gpu.validation,
			installed
		);
		test::@check(
			(gpu.debug != null) == gpu.validation,
			"the messenger and the flag disagree: messenger %s, flag %s",
			gpu.debug != null,
			gpu.validation
		);
	};
}

<*
 A message the layer really produced lands in the sink, with enough of it left to
 act on.

 The assertion is on the captured text, not on `gpu.validation` — a flag says the
 messenger was asked for, and this says the whole chain works: the layer is
 loaded, the messenger is registered at ERROR severity, `pUserData` arrived, the
 by-value/by-pointer cast in the callback signature is right, and the VUID
 survived. Every one of those can be broken on its own.
*>
fn void a_real_validation_error_lands_in_the_sink() @test
{
	@with_validating_gpu(; three::Gpu* gpu)
	{
		if (!gpu.validation)
		{
			// Nothing to say on a machine with no layer, and saying it loudly
			// beats a green test that checked nothing.
			io::printn("  (skipped: VK_LAYER_KHRONOS_validation is not installed)");
			return;
		}

		gpu.begin_capture();
		provoke_validation_error(gpu);
		String captured = gpu.sink.errors.str_view();
		gpu.end_capture();

		test::@check(captured.len > 0, "nothing was captured from a call the layer rejects");
		test::@check(captured.contains("validation ERROR"), "the severity is in the text: %s", captured);
		test::@check(
			captured.contains("VUID-VkBufferCreateInfo-size"),
			"and the VUID, which is the part that can be looked up: %s",
			captured
		);
		test::@check(gpu.sink.warnings.str_view().len == 0, "and it did not also arrive as a warning");
	};
}

<*
 A warning is not an error, and the sink keeps them apart.

 The whole reason there are two buffers: `js/runtime.c3` fails a run on the first
 and only logs the second, so a warning that landed in `errors` would fail runs
 for advice.
*>
fn void a_warning_does_not_land_where_the_errors_go() @test
{
	@with_validating_gpu(; three::Gpu* gpu)
	{
		if (!gpu.validation) return;

		gpu.begin_capture();
		submit_message(
			gpu,
			vk::DebugUtilsMessageSeverityFlagBitsEXT.DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT,
			"THREE-TEST-WARNING",
			"a warning the loader was asked to deliver"
		);
		String warnings = gpu.sink.warnings.str_view();
		String errors   = gpu.sink.errors.str_view();
		gpu.end_capture();

		test::@check(warnings.contains("validation WARNING"), "it is labelled a warning: %s", warnings);
		test::@check(warnings.contains("THREE-TEST-WARNING"), "and named: %s", warnings);
		test::@check(errors.len == 0, "and nothing reached the errors: %s", errors);
	};
}

<*
 VERBOSE is not subscribed to, and this is the assertion on the subscription
 rather than on the code that reads it.

 `vk::setupDebugMessenger` asks for VERBOSE and then prints it, which on a
 validating instance is a running commentary on every object created. None of it
 is a defect, so none of it belongs in a run's answer — and the way to keep it
 out is to never be told, not to filter after the fact.
*>
fn void verbose_messages_are_not_delivered_at_all() @test
{
	@with_validating_gpu(; three::Gpu* gpu)
	{
		if (!gpu.validation) return;

		gpu.begin_capture();
		submit_message(
			gpu,
			vk::DebugUtilsMessageSeverityFlagBitsEXT.DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT,
			"THREE-TEST-VERBOSE",
			"chatter that should never reach a script"
		);
		String warnings = gpu.sink.warnings.str_view();
		String errors   = gpu.sink.errors.str_view();
		gpu.end_capture();

		test::@check(warnings.len == 0, "verbose reached the warnings: %s", warnings);
		test::@check(errors.len == 0, "verbose reached the errors: %s", errors);
	};
}

<*
 With nothing capturing, a message is printed and the buffer is left as it was
 found.

 Two things at once, and both matter. The printing is what an unarmed debug
 build has always done, and this project may not quietly take it away.
 The rewind is what keeps a server that has been up for a week from accumulating
 every message it ever saw between runs — and what stops the *next* run
 inheriting the previous one's complaints, which would be a validation error
 attributed to the wrong script.
*>
fn void a_message_outside_a_capture_does_not_stay_in_the_sink() @test
{
	@with_validating_gpu(; three::Gpu* gpu)
	{
		if (!gpu.validation) return;

		// No begin_capture: this is the CLI's state, not a run's.
		provoke_validation_error(gpu);

		test::@check(gpu.sink.errors.str_view()
			.len == 0, "the sink kept a message nobody was capturing: %s", gpu.sink.errors.str_view());
		test::@check(gpu.sink.warnings.str_view().len == 0, "and the same for warnings");

		// **The same call again, capturing.** Without this the check above holds
		// just as well for a provocation the layer never looked at, and an empty
		// sink would prove nothing. The runner swallows stdout, so the printing
		// half cannot be asserted here — only that the buffer was left clean.
		gpu.begin_capture();
		provoke_validation_error(gpu);
		String caught = gpu.sink.errors.str_view();
		gpu.end_capture();
		test::@check(caught.len > 0, "the provocation produces no message at all, so nothing above was tested");
	};
}

<*
 A new capture does not inherit the last one's messages.

 The failure this catches is a run reporting the *previous* run's validation
 error, which is worse than reporting none: the agent fixes the script it is
 holding and the error does not move.
*>
fn void a_capture_starts_empty_even_after_a_noisy_one() @test
{
	@with_validating_gpu(; three::Gpu* gpu)
	{
		if (!gpu.validation) return;

		gpu.begin_capture();
		provoke_validation_error(gpu);
		test::@check(gpu.sink.errors.str_view().len > 0, "the first capture caught something to inherit");
		gpu.end_capture();

		gpu.begin_capture();
		String second = gpu.sink.errors.str_view();
		gpu.end_capture();
		test::@check(second.len == 0, "the second capture began holding the first one's error: %s", second);
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
		test::@check(
			small.extent.width == 320 && small.extent.height == 240,
			"the target did not take the extent it was given"
		);
		test::@check(
			small.color_format == three::TARGET_COLOR_FORMAT,
			"the colour format is not the one three.c3 chose"
		);

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

		test::@check(
			shot.width == W && shot.height == H,
			"read back %dx%d, expected %dx%d",
			shot.width,
			shot.height,
			W,
			H
		);
		test::@check(
			shot.pixels.len == (sz)W * H * 4,
			"read back %d bytes for a %dx%d RGBA image",
			shot.pixels.len,
			W,
			H
		);

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
			test::@check(
				byte == second.pixels[i],
				"byte %d differs between two captures: %d then %d",
				i,
				byte,
				second.pixels[i]
			);
		}
	};
}

// ============================================================================
// The deletion queue
// ============================================================================

<*
 A retired pipeline outlives the frames that may still bind it.

 `MAX_FRAMES_IN_FLIGHT` is 2, so a command buffer submitted two frames ago may
 still be reading an object handed back now. This is the arithmetic in
 `gpu/retire.c3` asserted from the outside: queued, still queued one frame
 later, gone the frame after that.

 **The middle check is the one that matters, and nothing else can make it.**
 Destroying on the next frame rather than the one after is undefined behaviour
 that surfaces as a corrupted draw under load, and no picture here catches it —
 nor does the validation layer, which is usually the answer when a picture
 cannot. Both
 headless frame paths wait on their own fence immediately after submitting, so
 by the time either returns the device has finished with everything it bound.
 The hazard is only reachable through `Renderer.frame`, which needs a window.
 The ordinal is therefore asserted directly, because it is the only part of this
 that a headless suite can see at all.

 A zeroed `MeshPipeline` stands in for a real one. Its `free` is a no-op on null
 handles, which keeps this about the queue's arithmetic rather than about
 building a pipeline to throw away.

 **Proved by injection.** `retire_at` set to `frame + 1` rather than
 `frame + MAX_FRAMES_IN_FLIGHT`: "still held after one frame: 0". Nothing else
 in the suite notices, which is the argument for the check.
*>
fn void a_retired_pipeline_waits_out_the_frames_in_flight() @test
{
	@with_renderer(; three::Renderer* renderer)
	{
		three::Gpu* gpu = &renderer.gpu;
		three::MeshPipeline nothing;

		gpu.retire_pipeline(nothing);
		test::@check(
			gpu.deletions.pipelines.len() == 1,
			"queued rather than destroyed: %d",
			(int)gpu.deletions.pipelines.len()
		);

		renderer.render_offscreen()!!;
		test::@check(
			gpu.deletions.pipelines.len() == 1,
			"still held after one frame: %d",
			(int)gpu.deletions.pipelines.len()
		);

		renderer.render_offscreen()!!;
		test::@check(
			gpu.deletions.pipelines.len() == 0,
			"and destroyed after two: %d",
			(int)gpu.deletions.pipelines.len()
		);
	};
}

<*
 A caller that retires and never renders does not grow the queue forever.

 The lazy mechanism needs frames to make progress and a headless script that
 builds and disposes materials without drawing gives it none. Past
 `MAX_PENDING_DELETES` the queue falls back to `wait_idle` and empties itself,
 which is the honest answer: the stall is the thing the frame ordinal exists to
 avoid, not a thing it must never do.

 **Proved by injection.** The bound removed from `retire_pipeline`: "the queue
 drained itself rather than growing past 32, and holds 33".
*>
fn void a_queue_nothing_is_draining_falls_back_to_the_stall() @test
{
	@with_renderer(; three::Renderer* renderer)
	{
		three::Gpu* gpu = &renderer.gpu;
		three::MeshPipeline nothing;

		for (uint i = 0; i <= three::MAX_PENDING_DELETES; i++) gpu.retire_pipeline(nothing);

		test::@check(
			gpu.deletions.pipelines.len() == 0,
			"the queue drained itself rather than growing past %d, and holds %d",
			three::MAX_PENDING_DELETES,
			(int)gpu.deletions.pipelines.len()
		);
	};
}

// ============================================================================
// GPU frame timing
// ============================================================================

// **The `timestamps == false` path is not tested, and cannot be here.** Every
// machine this project has run on reports `timestampComputeAndGraphics` and
// `hostQueryReset`, so a check for "a device without timestamps reports 0 and
// does not crash" would be a check that never executed a line of the branch it
// names — `plan.md` §7's unexercised regression test. What is written instead
// is a branch that is obviously inert: `FrameTimer` owns no query pool when the
// device says no, and every entry point returns on a null pool as its first
// statement. The checks below name the capability in their failure text, so a
// machine that does lack it says so rather than reading as a timing bug.
// 
// These are also the one place in this suite where a number rises and falls
// with the machine. They assert a *range*, not a value: a frame took some
// non-zero time and did not take a second. A tighter bound would be a
// benchmark, and a benchmark under the leak-tracked runner is noise.

<*
 A rendered frame leaves behind how long the GPU spent on it.

 Two renders rather than one so that both frame slots have been through
 `begin`/`end` at least once — a timer that only ever armed slot 0, or that read
 slot 0's pair for slot 1, passes a single-frame check and fails here.

 The upper bound is what makes this more than "is it non-zero". A 64x48 clear
 costs microseconds; a millisecond count above 1000 means the tick arithmetic is
 wrong (`timestampPeriod` dropped, nanoseconds mistaken for the answer, or the
 high half of a 64-bit stamp read as garbage), and every one of those failures
 produces a number that is enormous rather than absent.

 **Proved by injection.** `FrameTimer.end` returning before it sets
 `armed[slot]`: "the GPU time after two frames is 0.000000 ms (this device
 reports timestamps=true)". Restored, green again.
*>
fn void gpu_time_is_reported_after_a_frame() @test
{
	@with_renderer(; three::Renderer* renderer)
	{
		renderer.render_offscreen()!!;
		renderer.render_offscreen()!!;

		double ms = renderer.gpu_ms();
		test::@check(
			ms > 0.0,
			"the GPU time after two frames is %f ms (this device reports timestamps=%s)",
			ms,
			renderer.gpu.limits.timestamps
		);
		test::@check(
			ms < 1000.0,
			"a 64x48 clear was measured at %f ms, which is not a frame time but a unit mistake",
			ms
		);
	};
}

<*
 Nothing rendered, nothing to report.

 The zero is the documented answer rather than an accident: it is what a
 windowed run reports before its first frame completes, which is the semantics
 `gpu/timing.c3` writes down, and it is the only check here that a *plausible*
 number cannot satisfy by luck. The two checks above assert a range, so
 anything in range passes them.

 **Proved by injection.** `Renderer.gpu_ms` returning `timer.period` — the
 confusion between "nanoseconds per tick" and "milliseconds per frame", which
 is the mistake this arithmetic invites: "a renderer that has not drawn reports
 41.666668 ms". Both range checks above stayed green on it, which is the
 argument for this being a separate check. Restored, green again.
*>
fn void gpu_time_is_zero_before_the_first_frame() @test
{
	@with_renderer(; three::Renderer* renderer)
	{
		test::@check(renderer.gpu_ms() == 0.0, "a renderer that has not drawn reports %f ms", renderer.gpu_ms());
	};
}

<*
 One capture is enough: the number belongs to the frame just taken.

 This is the half of `gpu/timing.c3`'s contract that the two-frame check above
 cannot see. `capture` waits on its own fence before returning, so it can afford
 to collect its own timing rather than leaving it for this slot's next `begin` —
 which is two frames away, and may never come. A script that renders once and
 reads the stats is the common case, and previous-frame semantics would answer
 it with a zero.

 **Proved by injection.** The `timer.collect` after `capture`'s trailing fence
 wait removed: "one capture left the GPU time at 0.000000 ms". The two-frame
 check stayed green throughout — `render_offscreen` keeps its own collect —
 which is the argument for this being a separate check. Restored, green again.
*>
fn void capture_updates_the_gpu_time_it_measured() @test
{
	@with_renderer(; three::Renderer* renderer)
	{
		image::Image shot = renderer.capture()!!;
		defer shot.free();

		double ms = renderer.gpu_ms();
		test::@check(ms > 0.0, "one capture left the GPU time at %f ms", ms);
		test::@check(ms < 1000.0, "one capture was measured at %f ms", ms);
	};
}
