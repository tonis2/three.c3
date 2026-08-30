<*
 How long the GPU spent on a frame, and on each phase of it, measured on the GPU
 rather than guessed from the wall clock.

 A CPU-side stopwatch around `Renderer.frame` measures the submission, not the
 work: the queue is asynchronous, so it reports how long the driver took to
 accept the frame — microseconds on a healthy one, and whatever the *previous*
 frame had left to do on a stalled one. Two timestamps written into a query pool
 by the GPU itself measure the span between them on the GPU's own clock, and
 nothing else.

 ## Six marks, five spans

 begin ──prepare──▶ ──shadow──▶ ──scene──▶ ──post──▶ ──present──▶ end

 - prepare — the scene update, the frame's buffer writes and the compute
 skinning dispatch. Everything before the first rendering begins.
 - shadow — the depth-only pass. 0 with shadows off.
 - scene — the pass that draws the picture, into the target or into the post
 chain's first image.
 - post — the chain, and 0 when no post shader is active.
 - present — getting the finished image out: the blit on a windowed frame, the
 readback copy on a `capture()`, the closing layout transition on all three.
 Not a phase of `record_scene` but the remainder of the outer span, which is
 what makes the five add up to `total`.

 The outer pair is the first and last command in the frame's buffer, so it
 covers the blit and the readback — deliberately, since "what did this frame
 cost me" should not hide a present that costs more than the draw.

 Every mark is written every frame, including ones bounding a phase that
 recorded nothing. A query the GPU never wrote has no result, and the whole set
 then reads back `VK_NOT_READY` — so skipping the shadow mark on an unshadowed
 frame would report no timings at all rather than a zero for that phase.

 The marks sit between renderings, never inside one. That is the only place a
 timestamp is portable: an implementation may defer a write issued inside a
 render pass to the end of the encoder, silently moving the boundary.

 ## Which frame a reading describes

 - `Renderer.frame()` (windowed) reports the last *completed* frame, which with
 two frames in flight is a frame or two behind the one on screen, and 0 before
 the first has completed. A windowed frame does not wait for its own
 submission, so its own time does not exist yet when it returns.
 - `capture()` and `render_offscreen()` report the frame they just drew — both
 wait on their own fence before returning, so "render, then read the stats"
 sees the render it asked for.

 ## Two implementation notes

 `vkGetQueryPoolResults` is called without `VK_QUERY_RESULT_WAIT_BIT`. Every
 call site reads a slot's results after waiting on that slot's fence, and a
 signalled fence means every command in the submission — timestamp writes
 included — has completed, so the flag would wait for something already done.

 The reset is a host call (`vkResetQueryPool`, needing `hostQueryReset`) rather
 than `vkCmdResetQueryPool` at the top of the buffer. Recording it would put the
 reset inside the same submission whose results the next frame reads; resetting
 from the host beside the fence wait means the set is provably idle when it is
 recycled.

 A device reporting `timestamps == false` gets a `FrameTimer` that owns no pool
 and does nothing, and every span stays 0. No machine available to this project
 reports that, so the path is written to be obviously inert rather than tested.
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

 `total` is the outer span and the five phases sum to it exactly, since each is
 the difference between two consecutive marks of the same pair. A phase missing
 from the sum is a bug here, not a gap in the frame.

 `double` rather than `float` because the arithmetic runs through a tick count
 comfortably past 2^24.
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
 were still being read.
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
	// Nothing reads them before `begin` resets its own run, but putting the whole
	// pool into a known state costs one call at startup.
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
 wraparound is the worst way to report that.
*>
fn double FrameTimer.span(
	&self,
	ulong from,
	ulong to
) => to > from ? (double)(to - from) * (double)self.period / 1_000_000.0 : 0.0;

<*
 Reads back a slot's run, if it has one, and turns it into `timing`.

 Called from `begin` — the previous frame on this slot, two frames back — and
 again from the two paths that wait on their own fence before returning. Both
 are the same operation, and `armed` keeps the second from reading a run the
 first has consumed or one that was never written.

 The caller must have waited on this slot's fence; that is why there is no WAIT
 flag here.

 A run whose outer stamps do not advance leaves the last reading standing rather
 than reporting zeroes — inventing a 0 would look exactly like a frame that cost
 nothing. The test is on the outer pair and the phases are written with it, so a
 reading is always one frame's worth and never a mixture of two.
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
		.total = self.span(stamps[FrameMark.BEGIN.ordinal], stamps[FrameMark.END.ordinal]),
		.prepare = self.span(stamps[FrameMark.BEGIN.ordinal], stamps[FrameMark.PREPARE.ordinal]),
		.shadow = self.span(stamps[FrameMark.PREPARE.ordinal], stamps[FrameMark.SHADOW.ordinal]),
		.scene = self.span(stamps[FrameMark.SHADOW.ordinal], stamps[FrameMark.SCENE.ordinal]),
		.post = self.span(stamps[FrameMark.SCENE.ordinal], stamps[FrameMark.POST.ordinal]),
		.present = self.span(stamps[FrameMark.POST.ordinal], stamps[FrameMark.END.ordinal]),
	};
}

<*
 Collects what this slot last measured, then starts measuring again.

 Must be called after the slot's fence wait and before anything else is recorded
 into `cmd`: the first stamp is meant to be the first command in the buffer, and
 the reset below is only safe because the fence says this slot's previous
 submission is done.

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
 Closes a phase, at `ALL_COMMANDS` so everything recorded since the previous
 mark has finished before the stamp is taken.

 Every mark between `BEGIN` and `END` goes through here, and every one must be
 recorded on every frame — see the header.
*>
fn void FrameTimer.mark(&self, vk::CommandBuffer cmd, uint slot, FrameMark at)
{
	if (self.pool == null) return;

	vk::cmdWriteTimestamp2(cmd, PIPELINE_STAGE_2_ALL_COMMANDS_BIT, self.pool, slot * FRAME_MARKS + at.ordinal);
}

<*
 Writes the closing stamp.

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