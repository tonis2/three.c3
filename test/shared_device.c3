<*
 One headless device per test binary, instead of one per `@test`.

 No checks of its own: this is what every `@with_*` macro in this directory
 borrows from.

 Each of those used to open a `vk::Instance`, bring up a `Renderer` and build a
 `MeshPass` of its own. Measured on this machine that is 3ms for the instance,
 12ms for the device and 8ms for the pass — 23ms before the check itself runs,
 and about nine hundred tests pay it. The device and everything under it is state
 no test can dirty, so it is built once here; the pass, the post chain and the
 interface are what get rebuilt.

 ## What is shared and what is not

 Shared: the instance, the logical device, its memory pages, the offscreen
 target, the frame ring and the timer. None of it carries anything a test wrote.

 Not shared: `MeshPass` — the scene graph, the asset table, the materials and the
 pipeline cache — plus `PostPass` and `UiLayer`. `borrow` builds them and
 `release` gives them back, so a test still starts from an empty scene with no
 pipelines compiled, and `three_tests::js`'s claim that an agent iterating on a
 shader does not accumulate pipelines is still a claim about a fresh cache.

 ## Why the setup runs off the tracking allocator

 `runtime_test.c3` installs a fresh `TrackingAllocator` for the length of each
 `@test` and reports whatever is still live when it returns. A device that
 outlives every test would therefore be reported as a leak *of whichever test
 happened to be first* — several hundred entries, each symbolicated through
 `atos`, which turns a two second module into a three minute one.

 So `real_heap` is the process heap captured before the runner installs
 anything, and everything with a lifetime longer than one test is allocated
 against it: the device, the target across a resize, and the memory pages
 `warm_uploads` forces into existence. Everything a test allocates on top goes on
 being tracked, which is the whole point of running the suite leak-checked.

 **A slot is never freed.** There is no process-exit hook that runs before the
 last test's leak check, and freeing a device the next test would rebuild is the
 cost this file exists to remove. The pages go back to the OS with the process.
*>
module three_tests::device;
import three;
import vk;

alias HeapAlloc = std::core::mem::alloc::Allocator;

// Captured before `main`, and therefore before the test runner has swapped
// anything in over the top of it.
HeapAlloc real_heap;
fn void capture_heap() @init { real_heap = mem; }

struct Slot
{
	vk::Instance instance;
	three::Renderer renderer;
	bool up;
}

// [0] is the plain device, [1] the one with the validation layer on. Two rather
// than one because `create_instance` cannot be asked afterwards what it enabled
// — the layer is an instance property — and the handful of suites that arm it
// are checking the layer's own output.
Slot[2] slots;

// Which slot `release` has to give back, or -1 between tests. Guards the case of
// a macro whose body threw before it borrowed.
int borrowed = -1;

<*
 Which slot the process-wide dispatch tables currently point at.

 `vk::loadExtensions` and `vk::loadDeviceCommands` fill in globals, not
 per-instance tables — so bringing the second slot up leaves every instance and
 device entry point aimed at *it*, and a call made afterwards on the first slot
 goes through the wrong trampoline. With the validation layer in the picture
 that is not a subtle failure: the layer only knows the device its own instance
 created, and answers a call about the other one with "The VkDevice dispatch
 handle was not found and Validation will crash".

 So the tables are reloaded whenever the borrowed slot changes. It costs a run
 of `getInstanceProcAddr` calls and happens only on a switch.
*>
int loaded = -1;

<*
 The shared renderer, with a fresh `MeshPass`, post chain and interface on it.

 Pair every call with `release`, inside the same `@test`: the pass is allocated
 against the runner's tracker, so a pass freed in the *next* test is a leak
 reported against this one.

 @param with_pass : `False for a suite that only wants a device — the pass is left zeroed rather than built.`
*>
fn three::Renderer* borrow(uint width = 200, uint height = 150, bool validate = false, bool with_pass = true)
{
	usz index = validate ? 1 : 0;
	Slot* slot = &slots[index];

	if (!slot.up)
	{
		HeapAlloc tracked = mem;
		mem = real_heap;
		defer mem = tracked;

		slot.instance = three::create_instance(validate, headless: true)!!;
		slot.renderer.init(slot.instance, (vk::SurfaceKHR)null, width, height, validate: validate)!!;

		// Build a pass, upload through it, and throw both away — so the device's
		// 64MB memory pages exist before the runner is watching. `find_or_create_page`
		// allocates through whatever `mem` currently is, and a page created under a
		// test's tracker is a page that test is blamed for, because the device that
		// owns it is never freed.
		slot.renderer.post.init();
		slot.renderer.pass.init(&slot.renderer.gpu, &slot.renderer.target)!!;
		warm_uploads(slot);
		reset(slot);

		slot.up = true;
		loaded = (int)index;
	}
	else
	{
		aim_dispatch(slot, index);

		// The target belongs to the device rather than to the test, so a suite
		// that renders at its own size moves it off the tracker too.
		HeapAlloc tracked = mem;
		mem = real_heap;
		defer mem = tracked;
		slot.renderer.resize_target(width, height)!!;
	}

	slot.renderer.post.init();
	if (with_pass) slot.renderer.pass.init(&slot.renderer.gpu, &slot.renderer.target)!!;

	borrowed = (int)index;
	return &slot.renderer;
}

<*
 Points the global dispatch tables at `slot`, if they are not already.
*>
fn void aim_dispatch(Slot* slot, usz index) @private
{
	if (loaded == (int)index) return;
	vk::loadExtensions(slot.instance);
	vk::loadDeviceCommands(slot.renderer.gpu.handle);
	loaded = (int)index;
}

<*
 Says the process-wide dispatch tables have been pointed somewhere else.

 For `three_tests::gpu::device_comes_up_headless`, which is the one check that
 still brings a device of its own up and down — `create_instance` and `Gpu.init`
 both write those tables, so the next `borrow` has to put them back rather than
 trust its own bookkeeping.
*>
fn void dispatch_moved() => loaded = -1;

<*
 Gives back everything `borrow` built on top of the device.
*>
fn void release()
{
	if (borrowed < 0) return;
	reset(&slots[borrowed]);
	borrowed = -1;
}

<*
 One upload of every shape a test makes, so a page for each memory property
 combination is resident before any test runs. `pass.init` asks for the
 device-local one; geometry reaching the GPU asks for the host-visible one; the
 interface layer asks for a third through `cui`.
*>
fn void warm_uploads(Slot* slot) @private
{
	three::JsRuntime warm;
	warm.open(&slot.renderer.pass, &slot.renderer)!!;
	defer warm.close();

	three::RunResult result = warm.run(`
		const scene = new three.Scene();
		scene.add(new three.Mesh(new three.BoxGeometry(1, 1, 1), new three.MeshBasicMaterial({ color: 0xffffff })));
		return 1;
	`);
	defer result.free();

	// The interface allocates buffers of its own the first time anything draws
	// one — `cui`'s canvas pass, reached from `three.ui` and from
	// `three.debug.overlay` alike. `reset` frees the layer, so a test still
	// starts without one; what has to happen here is the page underneath it.
	slot.renderer.ui.ensure(&slot.renderer.gpu, &slot.renderer.target)!!;
}

<*
 Everything above the device, in `Renderer.free`'s order and for its reasons.
*>
fn void reset(Slot* slot) @private
{
	three::Renderer* renderer = &slot.renderer;

	renderer.gpu.handle.waitIdle();
	renderer.ui.free();
	renderer.post.release_textures(&renderer.gpu, &renderer.pass.assets);
	renderer.post.free(&renderer.gpu);
	renderer.pass.free(&renderer.gpu);
	// `Gpu.free` is what normally empties the deferred deletion queue, and it is
	// exactly what a shared device never gets. A pipeline the test retired — an
	// eviction from `PipelineCache`, a shader an agent recompiled — is otherwise
	// still live when the runner counts what the test allocated, and is reported
	// as that test's leak.
	renderer.gpu.drain_deletions();

	renderer.pass = {};
	renderer.ui = {};
	renderer.post = {};
	// A reading belongs to the frame that produced it, and `gpu_ms` is asserted
	// to be zero before anything has drawn.
	renderer.timer.timing = {};
	renderer.timer.armed = {};
	renderer.clear = three::DEFAULT_CLEAR;
	renderer.render_size_pinned = false;
}
