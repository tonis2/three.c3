<*
 Command submission, per-frame sync, and the one frame path everything runs
 through.

 ## Two frames in flight

 `MAX_FRAMES_IN_FLIGHT` is 2, which means **anything the GPU may still be
 reading must be double-buffered.** crig's pose palette tore for exactly this
 reason, and the per-frame instance buffer arriving at M2 has the same shape and
 would have the same bug. Nothing in the base stage is per-frame-mutable yet;
 the rule is written here because the first uniform buffer is where it starts
 being possible to get wrong.

 ## The semaphore layout, taken from cui and not re-derived

 - **Acquire semaphores and fences are per frame slot** (2 of each).
 - **Render-finished semaphores are per swapchain image.**

 A render-finished semaphore shared across slots can be re-signalled while a
 presentation of the same image is still waiting on it. That is a genuine
 hazard, and validation catches it only sometimes.

 ## The frame

	  wait fence  ->  acquire  ->  record  ->  submit  ->  present
	                     |                                    |
	                     +------- OUT_OF_DATE / resized ------+
	                                      |
	                                   rebuild

 Recording is the same one call whether or not there is a window, because the
 target is offscreen either way (`plan.md` §1): `record_scene` begins the
 target, draws and ends it. The blit and the readback are optional consumers
 appended after.
*>
module three;

import std::io;
import vk;
import image;

const uint MAX_FRAMES_IN_FLIGHT = 2;

struct Frames
{
	vk::CommandPool pool;
	vk::CommandBufferList buffers; // per frame slot
	vk::FenceList fences; // per frame slot
	vk::SemaphoreList image_available; // per frame slot
	vk::SemaphoreList render_finished; // per swapchain image
	uint slot;
}

fn Frames? Frames.init(&self, Gpu* gpu, uint image_count)
{
	// Every list here is given the heap explicitly. A List left
	// zero-initialised has a null allocator, and `list_ensure_capacity`
	// resolves null to `tmem` — so the first push backs it with temp-arena
	// memory and any `@pool()` open up the stack frees it on the way out.
	// Nothing faults at that point; the crash arrives later, wherever the list
	// is next walked. See vulkan.c3l's MemoryAllocator, which was bitten by it.
	self.buffers.init(mem, MAX_FRAMES_IN_FLIGHT);
	self.fences.init(mem, MAX_FRAMES_IN_FLIGHT);
	self.image_available.init(mem, MAX_FRAMES_IN_FLIGHT);
	self.render_finished.init(mem, 8);

	self.pool = gpu.handle.createCommandPool(queue: gpu.graphics.index)!;

	// `createCommandBuffers` builds its own list, which has the null-allocator
	// problem above and is not ours to fix, so its contents are copied into a
	// list that does own its storage and the original is released here.
	vk::CommandBufferList allocated = gpu.handle.createCommandBuffers(self.pool, count: MAX_FRAMES_IN_FLIGHT)!;
	foreach (buffer : allocated) self.buffers.push(buffer);
	allocated.free();

	for (uint i = 0; i < MAX_FRAMES_IN_FLIGHT; i++)
	{
		// Created signalled: the first frame waits on it before it has been
		// submitted to anything.
		self.fences.push(vk::fenceCreateInfo().setFlags(FENCE_CREATE_SIGNALED_BIT).build(gpu.handle))!;
		if (image_count > 0) self.image_available.push(vk::semaphoreCreateInfo().build(gpu.handle))!;
	}

	self.ensure_present_semaphores(gpu, image_count)!;
	return *self;
}

<*
 Top up the per-image semaphores after a rebuild handed back more images than
 last time. Never shrinks: a semaphore that might still be waited on by a
 presentation in flight is not ours to destroy, and a spare costs nothing.
*>
fn void? Frames.ensure_present_semaphores(&self, Gpu* gpu, uint image_count)
{
	while (self.render_finished.len() < image_count)
	{
		self.render_finished.push(vk::semaphoreCreateInfo().build(gpu.handle))!;
	}
}

fn void Frames.free(&self, Gpu* gpu)
{
	self.image_available.release(gpu.handle);
	self.render_finished.release(gpu.handle);
	self.fences.release(gpu.handle);
	self.buffers.free();
	if (self.pool != null)
	{
		self.pool.free(gpu.handle);
		self.pool = (vk::CommandPool)null;
	}
}

<*
 One command buffer, optionally gated on an acquire and optionally signalling a
 presentation.

 `ALL_COMMANDS` as the wait stage rather than `COLOR_ATTACHMENT_OUTPUT`: what
 touches the acquired image here is a layout transition and a blit, not an
 attachment write, and the barrier's own source scope is broader than transfer.
 The precision would buy nothing measurable and the narrow version is a
 write-after-acquire hazard waiting to be got wrong.
*>
fn void? Gpu.submit(&self, vk::CommandBuffer cmd, vk::Fence fence, vk::Semaphore wait, vk::Semaphore signal)
{
	vk::CommandBufferSubmitInfo cmd_info = vk::commandBufferSubmitInfo().setCommandBuffer(cmd);
	vk::SubmitInfo2 submit               = vk::submitInfo2().setCommandBufferInfos({ cmd_info });

	vk::SemaphoreSubmitInfo wait_info;
	if (wait != null)
	{
		wait_info = vk::semaphoreSubmitInfo().setSemaphore(wait).setStageMask(PIPELINE_STAGE_2_ALL_COMMANDS_BIT);
		submit = submit.setWaitSemaphoreInfos({ wait_info });
	}

	vk::SemaphoreSubmitInfo signal_info;
	if (signal != null)
	{
		signal_info = vk::semaphoreSubmitInfo().setSemaphore(signal).setStageMask(PIPELINE_STAGE_2_ALL_COMMANDS_BIT);
		submit = submit.setSignalSemaphoreInfos({ signal_info });
	}

	return vk::queueSubmit2(self.graphics.handle, 1, &submit, fence);
}

// ============================================================================
// Renderer — device, target, viewer and frames as one thing
// ============================================================================

struct Renderer
{
	Gpu gpu;
	Target target;
	Viewer viewer;
	Frames frames;
	// What the last frame cost the GPU. Beside `frames` because its query pool
	// is indexed by frame slot and shares that lifetime exactly — see
	// `gpu/timing.c3` for which frame "the last" means on which path.
	FrameTimer timer;
	// The scene graph, the asset table and the one pipeline that draws them.
	// The frame path above does not know any of that is in there.
	MeshPass pass;
	// The one agent-written shader that runs over the finished frame, and the
	// image the scene goes into while it does. Inert until something calls
	// `set` — see `render/post.c3`, which is also where the argument for it
	// being a field of the renderer rather than of the pass is.
	PostPass post;
	bool windowed;
	// What every render begins with. Reachable from a script since M6 as
	// `scene.background` — a daylight scene against this was rendering itself a
	// night sky, and the only way round it was to build one out of geometry.
	float[4] clear;
}

<*
 The clear colour a renderer starts on, and the one `scene.background = null`
 goes back to.

 Named rather than written twice, because "the default" is now something a
 script can ask to be restored to and two spellings of it would drift.
*>
const float[4] DEFAULT_CLEAR = { 0.10, 0.11, 0.13, 1.0 };

<*
 @param surface : `Null for headless: no viewer, no swapchain, and render + screenshot still work.`
 @param width : `The offscreen target's extent. Not the window's, ever.`
*>
fn Renderer? Renderer.init(
	&self,
	vk::Instance instance,
	vk::SurfaceKHR surface,
	uint width,
	uint height,
	bool validate = false
)
{
	self.windowed = surface != null;
	self.clear = DEFAULT_CLEAR;

	self.gpu.init(instance, surface, validate)!;
	self.target.init(&self.gpu, width, height)!;

	uint image_count = 0;
	if (self.windowed)
	{
		self.viewer.init(&self.gpu, surface, width, height)!;
		image_count = self.viewer.image_count;
	}
	self.frames.init(&self.gpu, image_count)!;
	self.timer.init(&self.gpu)!;

	return *self;
}

fn void Renderer.free(&self)
{
	if (self.gpu.handle != null) self.gpu.handle.waitIdle();
	self.pass.free(&self.gpu);
	// Before the target, because it holds an image created at the target's
	// extent — and after the idle, because it frees a pipeline outright rather
	// than retiring it.
	self.post.free(&self.gpu);
	self.timer.free(&self.gpu);
	self.frames.free(&self.gpu);
	self.viewer.free(&self.gpu);
	self.target.free(&self.gpu);
	self.gpu.free();
}

<*
 Everything drawn into the target, between `begin_render` and `end_render`.

 One call, on purpose: the frame path should not grow a branch per kind of
 thing that can be drawn. M2 made `MeshPass.record` a loop over buckets with an
 instance array behind it, and this stayed one line.

 `frames.slot` is passed down because the instance array is per frame in flight
 (see the rule at the top of this file). It is read here rather than threaded
 through a parameter because every frame path advances it only *after*
 recording, so it is the current slot on all of them.

 A pass that was never given a pipeline records nothing, which is what lets the
 M0 tests and a headless clear-colour render work with no shader on disk.
*>
fn void? Renderer.draw(&self, vk::CommandBuffer cmd)
{
	return self.pass.record(&self.gpu, cmd, &self.target, self.frames.slot);
}

<*
 A whole frame of scene, recorded into `cmd`: begin the target, draw, end the
 target.

 The one description of what a frame contains, and the reason it is a function
 is that there are three callers. `frame()`, `capture()` and
 `render_offscreen()` were the same three calls written out three times, which
 is the shape every "the window shows something the screenshot does not" bug
 has: nothing enforced that the three stayed identical except that they
 currently were. They cannot disagree now.

 What the three paths legitimately differ by stays with them — the acquire, the
 blit, the readback, the timestamps that span all of it. This is only the part
 that must be the same.

 ## The post branch

 With a post shader set, the scene is drawn into `PostPass.image` instead and
 the post pass writes `target.color` from it. **The branch is here and nowhere
 else**, which is the payoff for there being one recording function: window,
 screenshot and `render()` get post-processing at the same moment and cannot
 disagree about it. Everything downstream of `target.color` — the blit, the
 readback, the layout contract — is unchanged and unaware.

 With no post shader the two calls below are the same two calls this function
 has always made, so an unposted frame is byte-identical to one from before the
 pass existed rather than merely equivalent to it.
*>
fn void? Renderer.record_scene(&self, vk::CommandBuffer cmd)
{
	// Read once: `active` must not be allowed to change between the begin and
	// the end of one recording, and reading it twice is how that becomes
	// possible.
	bool posted = self.post.active;

	if (posted)
	{
		self.target.begin_render_to(cmd, self.post.image, self.post.view, self.clear);
	}
	else
	{
		self.target.begin_render(cmd, self.clear);
	}

	self.draw(cmd)!;

	if (posted)
	{
		self.post.record(cmd, &self.target);
	}
	else
	{
		self.target.end_render(cmd);
	}
}

<*
 What the GPU spent on a frame, in milliseconds.

 **Which frame depends on how it was drawn**, and `gpu/timing.c3` is where that
 is argued rather than here: `capture()` and `render_offscreen()` leave behind
 the frame they just drew, `frame()` leaves behind the last one to have
 completed. 0 before anything has been rendered, and 0 for the whole run on a
 device that cannot write timestamps.

 A method rather than a public field so that the one place that decides what
 "the last frame" means stays inside this module — the same shape as
 `Scene.stats().culled_last_frame`, which is also a number about the past that
 callers may only read.
*>
fn double Renderer.gpu_ms(&self) => self.timer.gpu_ms;

<*
 Rebuild the swapchain for the window's current size.

 @return `false when the window is minimised — skip the frame and wait for the next event.`
*>
fn bool? Renderer.rebuild(&self)
{
	if (!self.windowed) return false;
	if (!self.viewer.rebuild(&self.gpu)!) return false;
	// A rebuild can hand back more images than the last one did.
	self.frames.ensure_present_semaphores(&self.gpu, self.viewer.image_count)!;
	return true;
}

<*
 Draw one frame into the target and blit it to the window.

 The size poll at the top is the primary resize path, not a backstop: on macOS
 a live drag routinely resizes the surface without either the acquire or the
 present ever reporting `OUT_OF_DATE`, so waiting to be told means a stretched
 picture for the whole drag. `SUBOPTIMAL_KHR` is read off the raw result
 because it is a *success* code — the binding does not turn it into a fault, so
 there is nothing to catch.

 @return `false when nothing was presented (minimised, or the swapchain was rebuilt instead).`
*>
fn bool? Renderer.frame(&self)
{
	if (!self.windowed) return false;

	vk::Extent2D surface_size = self.viewer.surface_extent(&self.gpu)!;
	if (surface_size.width != self.viewer.extent.width || surface_size.height != self.viewer.extent.height)
	{
		self.rebuild()!;
		return false;
	}

	uint slot        = self.frames.slot;
	vk::Fence fence  = self.frames.fences[slot];
	vk::Semaphore acquired = self.frames.image_available[slot];

	fence.wait(self.gpu.handle)!;

	uint index;
	vk::Result acquire = vk::extensions.vkAcquireNextImageKHR(
		self.gpu.handle,
		self.viewer.handle,
		ulong::max,
		acquired,
		(vk::Fence)null,
		&index
	);
	// The fence is deliberately still signalled here: nothing was submitted, so
	// resetting it would deadlock the next frame's wait.
	if (acquire == ERROR_OUT_OF_DATE_KHR)
	{
		self.rebuild()!;
		return false;
	}
	if (acquire != SUCCESS && acquire != SUBOPTIMAL_KHR) return vk::E_ERROR_UNKNOWN~;

	fence.reset(self.gpu.handle)!;

	// Here rather than beside the fence wait above, and this is load-bearing: the
	// acquire between them can bail out to `rebuild` without submitting anything,
	// and an ordinal advanced by a frame that never submitted would credit the
	// next-but-one frame's fence wait with work it did not cover. `gpu/retire.c3`
	// has the invariant in full.
	self.gpu.begin_frame();

	vk::CommandBuffer cmd = self.frames.buffers[slot];
	vk::resetCommandBuffer(cmd, (vk::CommandBufferResetFlags)0)!;
	vk::beginCommandBuffer(cmd, &&vk::commandBufferBeginInfo())!;

	// First and last commands in the buffer. The blit is inside the span on
	// purpose — `gpu/timing.c3` says why.
	self.timer.begin(&self.gpu, cmd, slot)!;
	self.record_scene(cmd)!;
	self.viewer.record_blit(cmd, &self.target, index);
	self.timer.end(cmd, slot);

	vk::endCommandBuffer(cmd)!;

	vk::Semaphore finished = self.frames.render_finished[index];
	self.gpu.submit(cmd, fence, acquired, finished)!;

	vk::PresentInfoKHR present = vk::presentInfoKHR().setWaitSemaphores({ finished })
		.setSwapchains({ self.viewer.handle })
		.setImageIndices({ index });

	vk::Result presented = vk::extensions.vkQueuePresentKHR(self.gpu.graphics.handle, &present);

	self.frames.slot = (slot + 1) % MAX_FRAMES_IN_FLIGHT;

	// Rebuilt last, after the frame's own bookkeeping: the swapchain is
	// replaced under a device that has just been idled, and the acquired image
	// has been returned by the present above either way.
	if (presented == ERROR_OUT_OF_DATE_KHR || presented == SUBOPTIMAL_KHR)
	{
		self.rebuild()!;
		return false;
	}
	if (presented != SUCCESS) return vk::E_ERROR_UNKNOWN~;

	return true;
}

<*
 Render one frame into the target and read it back.

 Identical to `frame()` minus the acquire, the blit and the present — which is
 the whole argument for the offscreen decision: this works with no window, no
 surface and no window server, and what it returns is the rendered image rather
 than an OS window grab. Byte-identical across runs and across window sizes,
 because nothing about a window reaches it.

 @return `An Image owning its pixels — free it with Image.free.`
*>
fn image::Image? Renderer.capture(&self, alloc::Allocator allocator = mem)
{
	vk::Memory readback = self.target.create_readback(&self.gpu)!;
	defer readback.free();

	uint slot       = self.frames.slot;
	vk::Fence fence = self.frames.fences[slot];
	fence.wait(self.gpu.handle)!;
	fence.reset(self.gpu.handle)!;
	self.gpu.begin_frame();

	vk::CommandBuffer cmd = self.frames.buffers[slot];
	vk::resetCommandBuffer(cmd, (vk::CommandBufferResetFlags)0)!;
	vk::beginCommandBuffer(cmd, &&vk::commandBufferBeginInfo())!;

	self.timer.begin(&self.gpu, cmd, slot)!;
	self.record_scene(cmd)!;
	self.target.record_readback(cmd, &readback);
	self.timer.end(cmd, slot);

	vk::endCommandBuffer(cmd)!;
	self.gpu.submit(cmd, fence, (vk::Semaphore)null, (vk::Semaphore)null)!;

	// The buffer is host-coherent and the fence covers the copy, so there is
	// nothing to invalidate and nothing to map — vk::Memory pages stay mapped.
	fence.wait(self.gpu.handle)!;

	// Collected here rather than left to this slot's next `begin`, which is two
	// frames away: a caller that captures and then asks what it cost should be
	// told about the capture it just took, not the one before it.
	self.timer.collect(&self.gpu, slot)!;

	self.frames.slot = (slot + 1) % MAX_FRAMES_IN_FLIGHT;
	return self.target.decode_readback(&readback, allocator);
}

<*
 Render one frame into the target and stop there.

 `capture` without the readback, which is what `three.render(scene)` from a
 script wants: the pixels are read back once at the end of a run, and a script
 that calls `render()` in a loop should not pay for a buffer allocation and a
 host copy each time. It exists at all — rather than `render()` being a no-op
 that lets the final capture do the work — so that a scene which cannot be drawn
 says so at the line that asked for it.
*>
fn void? Renderer.render_offscreen(&self)
{
	uint slot       = self.frames.slot;
	vk::Fence fence = self.frames.fences[slot];
	fence.wait(self.gpu.handle)!;
	fence.reset(self.gpu.handle)!;
	self.gpu.begin_frame();

	vk::CommandBuffer cmd = self.frames.buffers[slot];
	vk::resetCommandBuffer(cmd, (vk::CommandBufferResetFlags)0)!;
	vk::beginCommandBuffer(cmd, &&vk::commandBufferBeginInfo())!;

	self.timer.begin(&self.gpu, cmd, slot)!;
	self.record_scene(cmd)!;
	self.timer.end(cmd, slot);

	vk::endCommandBuffer(cmd)!;
	self.gpu.submit(cmd, fence, (vk::Semaphore)null, (vk::Semaphore)null)!;

	// Waited on here rather than left to the next frame's fence: the instance
	// buffer for this slot is rewritten on the next record, and the rule at the
	// top of this file is that it may not be while the GPU is still reading it.
	fence.wait(self.gpu.handle)!;
	// The wait is already paid for, so the frame's own timing is free to take —
	// same argument as in `capture`.
	self.timer.collect(&self.gpu, slot)!;
	self.frames.slot = (slot + 1) % MAX_FRAMES_IN_FLIGHT;
}

<*
 Render one frame and write it to `path` as a PNG.
*>
fn void? Renderer.screenshot(&self, String path)
{
	image::Image shot = self.capture()!;
	defer shot.free();
	write_png(&shot, path)!;
}
