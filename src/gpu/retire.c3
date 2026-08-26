<*
 The frame-tagged deletion queue — how a GPU object outlives the frames that may
 still be reading it.

 ## The hazard

 `MAX_FRAMES_IN_FLIGHT` is 2, so at any moment up to two command buffers have
 been submitted and not yet completed. Destroying a `VkPipeline` one of them
 binds is undefined behaviour, and the symptom is not a crash at the call — it
 is a corrupted draw or a device loss some frames later, in whichever scene
 happened to be on screen.

 ## How it works

 `Gpu.wait_idle` is the blunt answer, and still the right one at a level
 boundary or at teardown, which are stalls anyway. It is wrong for anything that
 happens while a game is running, because it trades a hitch for a hazard the
 player can see.

 So a retired object records the frame ordinal it was given back at and is
 destroyed once that many frames have *started* since:

     retire_at = frame + MAX_FRAMES_IN_FLIGHT

 What makes the arithmetic right is the fence wait at the top of every frame
 path. Frame N waits on slot `N % 2`'s fence, and the last thing submitted on
 that slot was frame N - 2 — so by the time frame N begins recording, every
 submission from frame N - 2 and earlier has completed. An object retired at
 frame F can only be referenced by submissions at or before F, so `N >= F + 2`
 is exactly the condition for it to be unreachable.

 `begin_frame` is therefore called after the fence wait and only on a path that
 goes on to submit. A frame that bails out between the wait and the record — a
 minimised window, an out-of-date swapchain — must not advance the ordinal,
 because it did not wait on the fence belonging to the submission the
 next-but-one frame would be crediting.

 ## What is in here

 Two lists and one ordinal: pipelines, and everything backed by a `vk::Memory`.

 The second list is not a tagged union and there is nothing to switch on. A
 buffer, a texture and a chain image are given back by the same three calls in
 the same order — destroy the sampler, destroy the view, free the memory — each
 guarded by its own handle being non-null; a buffer is the case where the first
 two are null. `vk::Memory.free` destroys the image or buffer it was bound to,
 which is why neither is held separately: holding both would be a double free.

 The queue is bounded on its own account as well as by the frame counter. A
 headless run that disposes materials and never renders would otherwise grow it
 forever, since nothing there advances a frame — so past `MAX_PENDING_DELETES`
 it falls back to the stall.

 ## What still stalls

 Teardown (`Assets.free`, `Gpu.free`), `Assets.unload_unused`,
 `MeshPass.set_material_map`, and the swapchain — which has to, because the
 images it replaces belong to the presentation engine rather than to this queue.
*>
module three;

import std::collections::list;
import vk;

<*
 One pipeline waiting out the frames in flight.
*>
struct RetiredPipeline @local
{
	// The frame ordinal at which this becomes safe to destroy. Compared with
	// `>=` against the ordinal of the frame just started — see the header.
	ulong retire_at;
	// Held by value. The `CachedPipeline` it came out of is freed the moment it
	// leaves the cache, so a pointer would outlive its storage.
	MeshPipeline pipeline;
}

<*
 One `vk::Memory` and whatever wrapped it, waiting out the frames in flight.

 Held by value for `RetiredPipeline`'s reason: the struct these came out of — a
 `Texture` slot, a `GpuMesh` stream, a `ChainImage` — is overwritten or zeroed
 the moment it gives them back.
*>
struct RetiredMemory @local
{
	ulong retire_at;
	// Null for a buffer, and for an image that nothing samples.
	vk::Sampler sampler;
	vk::ImageView view;
	// Destroys the image or the buffer it was bound to. Never null: a caller
	// with nothing to give back does not reach the queue.
	vk::Memory memory;
}

<*
 How many pipelines may sit in the queue before it stops being lazy.

 Reached only by a caller that retires without rendering, since two frames of
 any kind drain everything older. Far above what a frame-driven workload ever
 holds and far below anything that matters as a leak.
*>
const uint MAX_PENDING_DELETES = 32;

<*
 The same bound for the memory list, and much larger because the unit is much
 smaller.

 One unloaded mesh is up to seven vertex streams and an index buffer; one
 unloaded asset is that per mesh plus its images. At `MAX_PENDING_DELETES` an
 ordinary sweep would fall back to the stall this list exists to avoid, making
 the bound the behaviour rather than the backstop.
*>
const uint MAX_PENDING_MEMORY_DELETES = 512;

struct DeletionQueue
{
	List{RetiredPipeline} pipelines;
	List{RetiredMemory} memory;
	// Monotonic across the process, not the two-slot index. `Frames.slot`
	// cycles and this does not — a comparison against a value that wraps every
	// second frame would retire things two frames early half the time.
	ulong frame;
}

fn void DeletionQueue.init(&self)
{
	// The heap, explicitly. A `List` left zero-initialised resolves its null
	// allocator to `tmem` on the first push, and any `@pool()` up the stack then
	// frees the queue's storage out from under it.
	self.pipelines.init(mem, 4);
	// Larger, because one unloaded mesh is seven streams and an index buffer.
	self.memory.init(mem, 16);
	self.frame = 0;
}

<*
 Gives a pipeline back, to be destroyed once the frames that may bind it are
 done.

 The caller must already have removed it from wherever it was reachable: this
 takes the object by value and owns it from here.
*>
fn void Gpu.retire_pipeline(&self, MeshPipeline pipeline)
{
	if (self.handle == null)
	{
		// No device, nothing in flight, nothing to wait for. Freeing here rather
		// than queueing keeps a scene-math runtime from accumulating a queue
		// nothing will ever sweep.
		pipeline.free(self);
		return;
	}

	self.deletions.pipelines.push({
		.retire_at = self.deletions.frame + (ulong)MAX_FRAMES_IN_FLIGHT,
		.pipeline = pipeline,
	});

	// The fallback for a caller that never renders. See the header.
	if (self.deletions.pipelines.len() > MAX_PENDING_DELETES) self.drain_deletions();
}

<*
 Gives a `vk::Memory` back, with the view and the sampler that wrapped it.

 The one verb for every buffer and every image in this project. The caller must
 already have removed it from wherever it was reachable, and must zero its own
 handles: this owns them from here, and a struct still holding a copy is a
 struct that can free them twice.

 Freeing `memory` destroys the image or buffer bound to it, so the image handle
 is deliberately not a parameter — there would be nothing to do with it.

 @param view : `Null for a buffer.`
 @param sampler : `Null for a buffer, and for an image nothing samples.`
*>
fn void Gpu.retire_memory(
	&self,
	vk::Memory memory,
	vk::ImageView view = (vk::ImageView)null,
	vk::Sampler sampler = (vk::Sampler)null
)
{
	// A stream a mesh never had, a view an image was created without. Cheaper to
	// answer here than at each of the dozen call sites.
	if (memory.buffer == null && view == null && sampler == null) return;

	if (self.handle == null)
	{
		// `retire_pipeline`'s reason, and the same order the sweep uses.
		free_retired_memory(self, { .sampler = sampler, .view = view, .memory = memory });
		return;
	}

	self.deletions.memory.push({
		.retire_at = self.deletions.frame + (ulong)MAX_FRAMES_IN_FLIGHT,
		.sampler = sampler,
		.view = view,
		.memory = memory,
	});

	if (self.deletions.memory.len() > MAX_PENDING_MEMORY_DELETES) self.drain_deletions();
}

<*
 Sampler, then view, then memory, each guarded by its own handle.

 The order matters: the memory is what destroys the image, so a view outliving
 it would be a view of nothing.

 The last guard asks about *both* handles. A `vk::Memory` from `vk::new_buffer`
 fills in `.buffer` and leaves `.image` null; one from `vk::create_image_buffer`
 does the opposite. Asking only about `.buffer` meant every image reaching this
 queue was retired, dequeued, then silently skipped — `vkDestroyImage` never
 called and the page block never returned. It leaks at `vkDestroyDevice`, after
 the suite has disarmed its validation sink, so nothing caught it until a
 `-D DEBUG` build started validating unconditionally.
*>
fn void free_retired_memory(Gpu* gpu, RetiredMemory due) @local
{
	if (due.sampler != null && gpu.handle != null) vk::destroySampler(gpu.handle, due.sampler, null);
	if (due.view != null && gpu.handle != null) due.view.free(gpu.handle);
	if (due.memory.buffer != null || due.memory.image != null) due.memory.free();
}

<*
 Starts a frame: advances the ordinal, then destroys whatever has come due.

 Called after the frame's fence wait and only from a path that goes on to
 submit — the header says why both halves matter.
*>
fn void Gpu.begin_frame(&self)
{
	self.deletions.frame++;

	ulong now = self.deletions.frame;
	for (sz i = 0; i < self.deletions.pipelines.len(); )
	{
		if (self.deletions.pipelines[i].retire_at > now) { i++; continue; }
		// Freed out of a copy, because `remove_at` shifts the entry away under a
		// pointer into the list.
		MeshPipeline due = self.deletions.pipelines[i].pipeline;
		self.deletions.pipelines.remove_at(i);
		due.free(self);
	}
	for (sz i = 0; i < self.deletions.memory.len(); )
	{
		if (self.deletions.memory[i].retire_at > now) { i++; continue; }
		RetiredMemory due = self.deletions.memory[i];
		self.deletions.memory.remove_at(i);
		free_retired_memory(self, due);
	}
}

<*
 Destroys everything queued, after waiting for the device.

 The stall is what makes it unconditional: nothing is in flight afterwards, so
 the frame ordinals every entry is holding out for are moot. Used by `Gpu.free`
 at teardown and by `retire_pipeline` when the queue has outgrown a mechanism
 that needs frames to make progress.
*>
fn void Gpu.drain_deletions(&self)
{
	if (self.deletions.pipelines.len() == 0 && self.deletions.memory.len() == 0) return;
	if (self.handle != null) self.handle.waitIdle();

	foreach (&entry : self.deletions.pipelines) entry.pipeline.free(self);
	self.deletions.pipelines.clear();
	foreach (entry : self.deletions.memory) free_retired_memory(self, entry);
	self.deletions.memory.clear();
}
