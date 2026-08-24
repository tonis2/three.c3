<*
 How long the GPU spent on a frame, and on each phase of it, measured on the
 GPU rather than guessed from the wall clock.

 ## Why not the wall clock

 A CPU-side stopwatch around `Renderer.frame` measures the submission, not the
 work: the queue is asynchronous, so the number it produces is "how long the
 driver took to accept this", which on a healthy frame is microseconds and on a
 stalled one is whatever the *previous* frame had left to do. `capture()` and
 `render_offscreen()` do wait for their own fence, so a stopwatch around those
 would at least be measuring something — but it would be measuring the fence
 wait, the readback and the process's scheduling as well as the draw.

 Two timestamps written into a query pool by the GPU itself measure the span
 between them on the GPU's own clock, and nothing else.

 ## The span

 The outer pair goes into the frame's one command buffer: the first as the first
 command recorded, the last as the last. **That covers the blit and the
 readback copy on the paths that have them, deliberately** — the question a
 caller is asking is "what did this frame cost me", and a present that costs
 more than the draw is exactly the answer that should not be hidden.

 ## Six marks, five spans

 Between those two there are four more, one at the end of each phase
 `Renderer.record_scene` records, and the reason is `plan.md` §18.3: the first
 outdoor scene built on this engine spent 68 % of its frame in the shadow map,
 and finding that out took six runs of the same village with the scene edited
 between them. A frame that reports its own phases answers it in one call.

	 begin ──prepare──▶ ──shadow──▶ ──scene──▶ ──post──▶ ──present──▶ end

 - **prepare** — the scene update, the frame's buffer writes and the compute
   skinning dispatch. Everything before the first rendering begins.
 - **shadow** — the depth-only pass. 0 with shadows off.
 - **scene** — the pass that draws the picture, into the target or into the post
   chain's first image.
 - **post** — the chain, and 0 when no post shader is active.
 - **present** — getting the finished image out: the blit on a windowed frame,
   the readback copy on a `capture()`, the closing layout transition on all
   three. This is the one that is not a phase of `record_scene` but the
   remainder of the outer span, which is what makes the five add up to `total`
   rather than to something a caller has to reconcile.

 **Every mark is written every frame, including the ones bounding a phase that
 recorded nothing.** A query the GPU never wrote has no result, and a read of
 the set would come back `VK_NOT_READY` for all of it — so a timer that skipped
 the shadow mark on an unshadowed frame would report no timings at all rather
 than a zero for that phase. Writing it unconditionally costs one timestamp and
 makes "this phase cost nothing" and "this phase did not run" the same honest 0.

 **The marks sit between renderings, never inside one.** That is where
 `record_scene` puts its phase boundaries anyway, and it is also the only place
 a timestamp is portable: an implementation is entitled to defer a write issued
 inside a render pass to the end of the encoder, which would silently move the
 boundary.

 ## Two answers, one number

 The timings mean different things depending on which frame path produced them,
 and both are honest:

 - **`Renderer.frame()` (windowed) reports the last *completed* frame**, which
   with two frames in flight is a frame or two behind the one on screen, and is
   0 before the first one has completed. That is the same shape as
   `culled_last_frame` and for the same reason: a windowed frame does not wait
   for its own submission, so its own time does not exist yet when it returns.
 - **`capture()` and `render_offscreen()` report the frame they just drew.**
   Both already wait on their own fence before returning — the instance buffer
   rule at the top of `gpu/frame.c3` — so the result is available by the time
   the call is over, and "render, then read the stats" sees the render it just
   asked for rather than the one before it.

 ## Availability without a WAIT flag

 `vkGetQueryPoolResults` is called without `VK_QUERY_RESULT_WAIT_BIT`, which
 would otherwise be a second, redundant block. Every call site reads a slot's
 results *after* waiting on that slot's fence, and a fence signalled means every
 command in that submission — including the timestamp writes — has completed.
 The wait flag would be asking the driver to wait for something that has already
 happened.

 ## Why the reset is a host call

 `vkResetQueryPool` needs `hostQueryReset`, which this device has and
 `GpuLimits.timestamps` insists on. The alternative — `vkCmdResetQueryPool`
 recorded at the top of the command buffer — would work too, but it would put
 the reset *inside* the same submission whose results the next frame reads, and
 the ordering argument for that is subtler than the one above. Resetting from
 the host next to the fence wait means the set is provably idle at the moment
 it is recycled.

 ## What is not measured

 A device that reports `timestamps == false` gets a `FrameTimer` that owns no
 pool and does nothing, and every span stays 0 forever. **No machine available
 to this project reports that**, so that path is written to be obviously inert
 rather than tested — see the note in `test/gpu_test.c3`.
*>
module three;

import vk;

<*
 Where in the frame a timestamp is taken.

 The ordinal is the offset into the slot's run of queries, so the order of the
 members below *is* the order the command buffer writes them, and a span is the
 difference between two consecutive marks. Adding a phase means adding a member
 in the right place and a `mark` call in `record_scene`; nothing else counts.
*>
enum FrameMark : char
{
	// Top of pipe, first command in the buffer.
	BEGIN,
	// After `MeshPass.prepare` — uploads, buffer writes, compute skinning.
	PREPARE,
	// After the shadow pass.
	SHADOW,
	// After the rendering that draws the picture.
	SCENE,
	// After the post chain.
	POST,
	// All commands, last in the buffer: the blit or the readback is inside it.
	END,
}

const uint FRAME_MARKS = FrameMark.END.ordinal + 1;

<*
 What one frame cost, split by phase, in milliseconds.

 `total` is the outer span and the five phases sum to it — exactly, because each
 is the difference between two consecutive marks of the same pair. A caller may
 rely on that: a phase that is missing from the sum is a bug here and not a gap
 in the frame.

 `double` rather than `float` because the arithmetic runs through a tick count
 that is comfortably past 2^24.
*>
struct FrameTiming
{
	double total;
	double prepare;
	double shadow;
	double scene;
	double post;
	double present;
}

<*
 One run of marks per frame slot, and the last reading taken off them.

 The pool is `FRAME_MARKS * MAX_FRAMES_IN_FLIGHT` queries laid out as
 consecutive runs: slot `s` owns queries `s * FRAME_MARKS` upwards. Per slot
 rather than one shared run because two frames are in flight — a single run
 would be reset and rewritten by the next frame while the previous one's stamps
 were still the thing being read.
*>
struct FrameTimer
{
	// Null when the device cannot do this, and that is the only flag: every
	// entry point below returns early on it, so there is no second "enabled"
	// bool that could disagree with whether a pool exists.
	vk::QueryPool pool;
	// Nanoseconds per tick, copied from `GpuLimits` so a reading does not need
	// the device to be reachable.
	float period;
	// Whether slot `i` has a written, uncollected run sitting in the pool.
	// Cleared by `collect`, set by `end` — so a frame path that begins without
	// ending, or ends twice, cannot leave a stale run to be read as a fresh one.
	bool[MAX_FRAMES_IN_FLIGHT] armed;
	FrameTiming timing;
}

fn FrameTimer? FrameTimer.init(&self, Gpu* gpu)
{
	*self = { };
	if (!gpu.limits.timestamps) return *self;

	self.period = gpu.limits.timestamp_period;
	self.pool = vk::queryPoolCreateInfo().setQueryType(QUERY_TYPE_TIMESTAMP)
		.setQueryCount(FRAME_MARKS * MAX_FRAMES_IN_FLIGHT)
		.build(gpu.handle)!;

	// A fresh pool's queries are in an undefined state, and reading or writing
	// one that has never been reset is undefined behaviour rather than a zero.
	// Nothing reads them before `begin` resets its own run, but the whole pool
	// is put into a known state here anyway: it costs one call at startup and it
	// is the difference between an invariant and a habit.
	vk::resetQueryPool(gpu.handle, self.pool, 0, FRAME_MARKS * MAX_FRAMES_IN_FLIGHT);
	return *self;
}

fn void FrameTimer.free(&self, Gpu* gpu)
{
	if (self.pool != null && gpu.handle != null) vk::destroyQueryPool(gpu.handle, self.pool, null);
	*self = { };
}

<*
 Ticks between two marks, as milliseconds.

 Clamped at zero rather than trusted to be ordered. Two consecutive marks on one
 queue cannot run backwards, so a negative span would mean the run was read
 before it was resolved — and an enormous positive number from the unsigned
 wraparound is the worst possible way to report that.
*>
fn double FrameTimer.span(&self, ulong from, ulong to)
	=> to > from ? (double)(to - from) * (double)self.period / 1_000_000.0 : 0.0;

<*
 Read back a slot's run, if it has one, and turn it into `timing`.

 Called from `begin` — the previous frame on this slot, two frames back — and
 again from the two paths that wait on their own fence before returning. Both
 are the same operation, and `armed` is what keeps the second one from reading
 a run the first has already consumed or a run that was never written.

 **The caller must have waited on this slot's fence.** That is the availability
 argument in the header, and it is the reason there is no WAIT flag here.

 A run whose outer stamps do not advance leaves the last reading standing rather
 than reporting zeroes: the only way to get here without a real span is a driver
 answering `VK_NOT_READY` — which the fence rules out — and inventing a 0 for
 that would look exactly like a frame that cost nothing. The test is on the
 outer pair and the phases are written with it, so a reading is always one
 frame's worth and never a mixture of two.
*>
fn void? FrameTimer.collect(&self, Gpu* gpu, uint slot)
{
	if (self.pool == null || !self.armed[slot]) return;
	self.armed[slot] = false;

	ulong[FRAME_MARKS] stamps;
	vk::getQueryPoolResults(
		gpu.handle,
		self.pool,
		slot * FRAME_MARKS,
		FRAME_MARKS,
		(sz)@sizeof(stamps),
		&stamps,
		(vk::DeviceSize)@sizeof(stamps[0]),
		QUERY_RESULT_64_BIT
	)!;

	if (stamps[FrameMark.END.ordinal] <= stamps[FrameMark.BEGIN.ordinal]) return;

	self.timing = {
		.total   = self.span(stamps[FrameMark.BEGIN.ordinal],   stamps[FrameMark.END.ordinal]),
		.prepare = self.span(stamps[FrameMark.BEGIN.ordinal],   stamps[FrameMark.PREPARE.ordinal]),
		.shadow  = self.span(stamps[FrameMark.PREPARE.ordinal], stamps[FrameMark.SHADOW.ordinal]),
		.scene   = self.span(stamps[FrameMark.SHADOW.ordinal],  stamps[FrameMark.SCENE.ordinal]),
		.post    = self.span(stamps[FrameMark.SCENE.ordinal],   stamps[FrameMark.POST.ordinal]),
		.present = self.span(stamps[FrameMark.POST.ordinal],    stamps[FrameMark.END.ordinal]),
	};
}

<*
 Collect what this slot last measured, then start measuring again.

 Must be called after the slot's fence wait and before anything else is
 recorded into `cmd` — the first stamp is meant to be the first command in the
 buffer, and the reset below is only safe because the fence says this slot's
 previous submission is done.

 @param slot : `The frame slot the command buffer belongs to — Frames.slot at the time of recording.`
*>
fn void? FrameTimer.begin(&self, Gpu* gpu, vk::CommandBuffer cmd, uint slot)
{
	if (self.pool == null) return;

	self.collect(gpu, slot)!;

	vk::resetQueryPool(gpu.handle, self.pool, slot * FRAME_MARKS, FRAME_MARKS);
	vk::cmdWriteTimestamp2(cmd, PIPELINE_STAGE_2_TOP_OF_PIPE_BIT, self.pool, slot * FRAME_MARKS);
}

<*
 Close a phase, at `ALL_COMMANDS` so that everything recorded since the previous
 mark has finished before the stamp is taken.

 Every mark between `BEGIN` and `END` goes through here, and every one of them
 must be recorded on every frame — the header says why, and it is the difference
 between a phase reporting 0 and the whole frame reporting nothing.
*>
fn void FrameTimer.mark(&self, vk::CommandBuffer cmd, uint slot, FrameMark at)
{
	if (self.pool == null) return;

	vk::cmdWriteTimestamp2(cmd, PIPELINE_STAGE_2_ALL_COMMANDS_BIT, self.pool, slot * FRAME_MARKS + at.ordinal);
}

<*
 Write the closing stamp.

 Must be the last thing recorded into `cmd`. Nothing is read here — the run is
 only marked as worth reading, and whoever next waits on this slot's fence does
 the reading.
*>
fn void FrameTimer.end(&self, vk::CommandBuffer cmd, uint slot)
{
	if (self.pool == null) return;

	self.mark(cmd, slot, FrameMark.END);
	self.armed[slot] = true;
}
