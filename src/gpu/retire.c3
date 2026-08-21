<*
 The frame-tagged deletion queue — how a GPU object outlives the frames that
 may still be reading it.

 ## The hazard

 `MAX_FRAMES_IN_FLIGHT` is 2, so at any moment up to two command buffers have
 been submitted and not yet completed. Destroying a `VkPipeline` one of them
 binds is undefined behaviour, and the symptom is not a crash at the call — it
 is a corrupted draw or a device loss some frames later, in whichever scene
 happened to be on screen.

 ## The two answers, and why this is the second one

 `Gpu.wait_idle` is the first: stall until the device has finished everything,
 then free. That is right at a level boundary, which is already a stall, and it
 is what `Assets.unload_unused` and `MeshPass.set_material_map` still use. It is
 wrong for anything that can happen while a game is running, because it trades a
 hitch for a hazard the player can see.

 This is the second. A retired object records the frame ordinal it was given
 back at and is destroyed once that many frames have *started* since:

     retire_at = frame + MAX_FRAMES_IN_FLIGHT

 The invariant that makes the arithmetic right is the fence wait at the top of
 every frame path. Frame N waits on slot `N % 2`'s fence, and the last thing
 submitted on that slot was frame N - 2 — so by the time frame N begins
 recording, every submission from frame N - 2 and earlier has completed. An
 object retired at frame F can only be referenced by submissions from frames at
 or before F, so `N >= F + 2` is exactly the condition for it to be unreachable.

 **`begin_frame` is therefore called after the fence wait and only on a path
 that goes on to submit.** A frame that bails out between the wait and the
 record — a minimised window, an out-of-date swapchain — must not advance the
 ordinal, because it did not wait on the fence belonging to the submission the
 next-but-one frame would be crediting.

 ## What is in here, and what is not

 One list, of pipelines, because a pipeline is the only thing anything retires
 today. `plan.md` §2 wants buffers on the same mechanism when something streams
 chunks mid-play; that is a second list beside this one and the same ordinal,
 not a tagged union built before there are two tags to carry.

 The queue is bounded on its own account as well as by the frame counter. A
 headless run that disposes materials and never renders would otherwise grow it
 forever, since nothing there ever advances a frame — so past
 `MAX_PENDING_DELETES` it falls back to the stall, which is the honest thing to
 do when the cheap mechanism has nothing to work with.
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
 How many pipelines may sit in the queue before it stops being lazy.

 Reached only by a caller that retires without rendering, since two frames of
 any kind drain everything older. The number is not a budget anybody tuned: it
 is far above what a frame-driven workload ever holds and far below anything
 that matters as a leak.
*>
const uint MAX_PENDING_DELETES = 32;

struct DeletionQueue
{
	List{RetiredPipeline} pipelines;
	// Monotonic across the process, not the two-slot index. `Frames.slot` cycles
	// and this does not, which is the whole point — a comparison against a value
	// that wraps every second frame would retire things two frames early half
	// the time.
	ulong frame;
}

fn void DeletionQueue.init(&self)
{
	// The heap, explicitly. A `List` left zero-initialised resolves its null
	// allocator to `tmem` on the first push, and any `@pool()` up the stack then
	// frees the queue's storage out from under it — `Frames.init` has the same
	// note and the same reason.
	self.pipelines.init(mem, 4);
	self.frame = 0;
}

<*
 Give a pipeline back, to be destroyed once the frames that may bind it are done.

 The caller must already have removed it from wherever it was reachable: this
 takes the object by value and owns it from here.
*>
fn void Gpu.retire_pipeline(&self, MeshPipeline pipeline)
{
	if (self.handle == null)
	{
		// No device, nothing in flight, nothing to wait for. Freeing here rather
		// than queueing keeps a scene-math runtime from accumulating a queue that
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
 Start a frame: advance the ordinal, then destroy whatever has come due.

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
}

<*
 Destroy everything queued, after waiting for the device.

 The stall is what makes it unconditional: nothing is in flight afterwards, so
 the frame ordinals every entry is holding out for are moot. Used by `Gpu.free`
 at teardown and by `retire_pipeline` when the queue has outgrown a mechanism
 that needs frames to make progress.
*>
fn void Gpu.drain_deletions(&self)
{
	if (self.deletions.pipelines.len() == 0) return;
	if (self.handle != null) self.handle.waitIdle();

	foreach (&entry : self.deletions.pipelines) entry.pipeline.free(self);
	self.deletions.pipelines.clear();
}
