<*
 The window walked through a spread of sizes, minimised and restored, rendering
 the whole way — swapchain recreation under real presentation.

 ## Not run, on purpose. `@test` is commented out below.

 **It belongs in `lib/window.c3l` and should move there.** Everything it
 actually exercises is that library's contract — `set_size`, `set_minimized`,
 and the surface reporting a new extent afterwards — and this project is only
 where it happens to have been written. Left here, compiling but never invoked,
 so the walk is not lost between now and the move; `c3c test` still type-checks
 every line of it.

 The reason it is off rather than merely tagged: it opens a real window and its
 frames are vsynced, so it costs a few seconds of somebody watching a window
 flicker — twice over, since a working session runs the suite under
 `--test-noleak` and then leak-tracked. That is a poor trade for a check on
 library behaviour that has not regressed.

 To run it by hand, put `@test` back and use the filter above.

 **It was the one test that opens a real window.** Everything else in the
 suite runs headless, and the bugs this exists for — the blit's destination
 rect, a swapchain image destroyed while a presentation still refers to it —
 are only reachable through `Renderer.frame`, which needs a surface. Both
 headless frame paths wait on their own fence after submitting, so neither can
 ever see them. This was `--stress-resize` on the CLI until the CLI stopped
 carrying dev probes; the walk is unchanged.

 The sizes are deliberately awkward — a near-square, a very wide one, a very
 tall one, one small enough to be mostly title bar — because both bugs hide at
 comfortable aspect ratios.

 The frames are vsynced, so the walk costs a few real seconds. That is the
 price of presentation actually happening, which is the thing under test.

 With the Khronos layer installed the walk runs validated and the sink's errors
 are asserted empty — the old probe's "run it validated; the pass condition is
 that nothing is printed", made checkable. The suite asks for the layer itself
 rather than inheriting the answer from a build flag, so this needs nothing of
 the command line. Without the layer the extent checks still run and the
 validation half says it was skipped, the way `gpu_test.c3` does.
*>
module three_tests::resize;

import three;
import vk;
import c3w;
import std::core::test;
import std::io;

const uint W = 640;
const uint H = 400;

// @test — deliberately off. See the header: this wants to live in window.c3l.
fn void the_swapchain_survives_awkward_sizes_minimise_and_restore()
{
	c3w::Window? opened = c3w::new(
		params: { .x = 0, .y = 0, .width = (int)W, .height = (int)H },
		name: "three.c3 resize test"
	);
	if (catch opened)
	{
		// No window server — an SSH session, a CI runner. Nothing here can run
		// without one, and saying so loudly beats a green test that checked
		// nothing.
		io::printn("  (skipped: no window could be opened)");
		return;
	}
	c3w::Window window = opened;
	defer window.free();

	vk::Instance instance = three::create_instance(true, headless: false)!!;
	defer instance.free();

	vk::SurfaceKHR surface = (vk::SurfaceKHR)window.create_vk_surface(
		instance,
		(c3w::VkGetInstanceProcAddrFn)vk::getInstanceProcAddr
	)!!;
	defer surface.free(instance);

	three::Renderer renderer;
	renderer.init(instance, surface, W, H, validate: true)!!;
	defer renderer.free();

	renderer.pass.init(&renderer.gpu, &renderer.target)!!;
	renderer.pass.load_triangle(&renderer.gpu)!!;

	// Captured rather than printed, so the walk's cleanliness is an assertion
	// and not a thing to eyeball in the runner's output. A no-op without the
	// layer, like every capture.
	renderer.gpu.begin_capture();

	int[2][*] sizes = {
		{ 900, 500 }, { 1600, 1000 }, { 320, 240 }, { 1440, 200 }, { 240, 900 }, { 1024, 768 },
	};

	// Checked, not assumed: a `set_size` that silently did nothing would leave
	// every frame below rendering at one extent, and "no validation errors"
	// would still hold. The test would pass by never testing anything.
	uint changes = 0;
	vk::Extent2D previous = renderer.viewer.extent;

	foreach (size : sizes)
	{
		window.set_size(size[0], size[1]);
		pump(&renderer, &window, 20);

		vk::Extent2D now = renderer.viewer.extent;
		if (now.width != previous.width || now.height != previous.height) changes++;
		previous = now;
	}

	test::@check(changes > 0, "no requested size ever changed the surface — set_size did nothing");

	// Minimised, the surface reports a zero extent and there is nothing to
	// build a swapchain for. The frame path has to notice and skip rather than
	// spin on an acquire that keeps failing.
	//
	// `set_minimized(false)` restores on macOS, X11 and Win32 but is a no-op on
	// Wayland, where xdg-shell has no un-minimise request — so on Wayland the
	// frames after this are the minimised case running twice, which is a
	// weaker check rather than a broken one.
	window.set_minimized(true);
	pump(&renderer, &window, 30);
	window.set_minimized(false);
	pump(&renderer, &window, 30);

	if (renderer.gpu.validation)
	{
		// Read before `end_capture`, which is the sink's own rule. Errors fail
		// the walk; warnings are advice and are surfaced without failing it,
		// because a driver's idea of advice changes between versions and this
		// test is about the swapchain, not the driver's mood.
		String errors = renderer.gpu.sink.errors.str_view();
		String warnings = renderer.gpu.sink.warnings.str_view();
		test::@check(errors.len == 0, "the walk produced validation errors: %s", errors);
		if (warnings.len > 0) io::printfn("  (validation warnings during the walk: %s)", warnings);
		renderer.gpu.end_capture();
	}
	else
	{
		io::printn("  (validation half skipped: no layer in this build or on this machine)");
	}
}

fn void pump(three::Renderer* renderer, c3w::Window* window, uint frames) @local
{
	for (uint i = 0; i < frames; i++)
	{
		window.getEvent();
		renderer.frame()!!;
	}
}
