<*
 How long the GPU spent on a frame, measured on the GPU rather than guessed
 from the wall clock.

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

 Both stamps go into the frame's one command buffer: the first as the first
 command recorded, the second as the last. **That covers the blit and the
 readback copy on the paths that have them, deliberately** — the question a
 caller is asking is "what did this frame cost me", and a present that costs
 more than the draw is exactly the answer that should not be hidden.

 ## Two answers, one number

 `gpu_ms` means different things depending on which frame path produced it, and
 both are honest:

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
 the host next to the fence wait means the pair is provably idle at the moment
 it is recycled.

 ## What is not measured

 A device that reports `timestamps == false` gets a `FrameTimer` that owns no
 pool and does nothing, and `gpu_ms` stays 0 forever. **No machine available to
 this project reports that**, so that path is written to be obviously inert
 rather than tested — see the note in `test/gpu_test.c3`.
*>
module three;

import vk;

<*
 One timestamp pair per frame slot, and the last reading taken off them.

 The pool is `2 * MAX_FRAMES_IN_FLIGHT` queries laid out as consecutive pairs:
 slot `s` owns queries `2s` and `2s + 1`. Per slot rather than one shared pair
 because two frames are in flight — a single pair would be reset and rewritten
 by the next frame while the previous one's stamps were still the thing being
 read.
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
	// Whether slot `i` has a written, uncollected pair sitting in the pool.
	// Cleared by `collect`, set by `end` — so a frame path that begins without
	// ending, or ends twice, cannot leave a stale pair to be read as a fresh one.
	bool[MAX_FRAMES_IN_FLIGHT] armed;
	// Milliseconds. `double` rather than `float` because the arithmetic runs
	// through a tick count that is comfortably past 2^24.
	double gpu_ms;
}

fn FrameTimer? FrameTimer.init(&self, Gpu* gpu)
{
	*self = { };
	if (!gpu.limits.timestamps) return *self;

	self.period = gpu.limits.timestamp_period;
	self.pool = vk::queryPoolCreateInfo().setQueryType(QUERY_TYPE_TIMESTAMP)
		.setQueryCount(2 * MAX_FRAMES_IN_FLIGHT)
		.build(gpu.handle)!;

	// A fresh pool's queries are in an undefined state, and reading or writing
	// one that has never been reset is undefined behaviour rather than a zero.
	// Nothing reads them before `begin` resets its own pair, but the whole pool
	// is put into a known state here anyway: it costs one call at startup and it
	// is the difference between an invariant and a habit.
	vk::resetQueryPool(gpu.handle, self.pool, 0, 2 * MAX_FRAMES_IN_FLIGHT);
	return *self;
}

fn void FrameTimer.free(&self, Gpu* gpu)
{
	if (self.pool != null && gpu.handle != null) vk::destroyQueryPool(gpu.handle, self.pool, null);
	*self = { };
}

<*
 Read back a slot's pair, if it has one, and turn it into `gpu_ms`.

 Called from `begin` — the previous frame on this slot, two frames back — and
 again from the two paths that wait on their own fence before returning. Both
 are the same operation, and `armed` is what keeps the second one from reading
 a pair the first has already consumed or a pair that was never written.

 **The caller must have waited on this slot's fence.** That is the availability
 argument in the header, and it is the reason there is no WAIT flag here.

 A pair whose stamps do not advance leaves the last reading standing rather
 than reporting zero: the only way to get here without a real span is a driver
 answering `VK_NOT_READY` — which the fence rules out — and inventing a 0 for
 that would look exactly like a frame that cost nothing.
*>
fn void? FrameTimer.collect(&self, Gpu* gpu, uint slot)
{
	if (self.pool == null || !self.armed[slot]) return;
	self.armed[slot] = false;

	ulong[2] stamps;
	vk::getQueryPoolResults(
		gpu.handle,
		self.pool,
		slot * 2,
		2,
		(sz)@sizeof(stamps),
		&stamps,
		(vk::DeviceSize)@sizeof(stamps[0]),
		QUERY_RESULT_64_BIT
	)!;

	if (stamps[1] > stamps[0]) self.gpu_ms = (double)(stamps[1] - stamps[0]) * (double)self.period / 1_000_000.0;
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

	vk::resetQueryPool(gpu.handle, self.pool, slot * 2, 2);
	vk::cmdWriteTimestamp2(cmd, PIPELINE_STAGE_2_TOP_OF_PIPE_BIT, self.pool, slot * 2);
}

<*
 Write the closing stamp, at `ALL_COMMANDS` so that everything recorded since
 `begin` has finished before it is taken.

 Must be the last thing recorded into `cmd`. Nothing is read here — the pair is
 only marked as worth reading, and whoever next waits on this slot's fence does
 the reading.
*>
fn void FrameTimer.end(&self, vk::CommandBuffer cmd, uint slot)
{
	if (self.pool == null) return;

	vk::cmdWriteTimestamp2(cmd, PIPELINE_STAGE_2_ALL_COMMANDS_BIT, self.pool, slot * 2 + 1);
	self.armed[slot] = true;
}
