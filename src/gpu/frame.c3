<*
 Command submission, per-frame sync, and the one frame path everything runs
 through.

 ## Two frames in flight

 `MAX_FRAMES_IN_FLIGHT` is 2, which means anything the GPU may still be reading
 must be double-buffered — the per-frame instance buffer above all. A host-visible
 buffer rewritten while the previous frame is still reading it tears.

 ## The semaphore layout

 - Acquire semaphores and fences are per frame slot (2 of each).
 - Render-finished semaphores are per swapchain image.

 A render-finished semaphore shared across slots can be re-signalled while a
 presentation of the same image is still waiting on it. That is a genuine hazard,
 and validation catches it only sometimes.

 ## The frame

 wait fence  ->  acquire  ->  record  ->  submit  ->  present
 |                                    |
 +------- OUT_OF_DATE / resized ------+
 |
 rebuild

 Recording is the same one call whether or not there is a window, because the
 target is offscreen either way: `record_scene` begins the target, draws and ends
 it. The blit and the readback are optional consumers appended after.
*>
module three;

import vk;
import image;
import std::time;

const uint MAX_FRAMES_IN_FLIGHT = 2;

// Where every picture key starts. FNV-1a's offset basis.
const ulong KEY_SEED = 0xcbf29ce484222325;

<*
 FNV-1a over a run of bytes, eight at a time.

 A byte at a time over the instance array is a million iterations on a large
 scene; a word at a time is an eighth of that for the same fold. The tail is
 taken a byte at a time, so a run that is not a multiple of eight still hashes
 all of it.

 Not cryptographic and does not need to be: a collision costs one frame that
 looks unchanged and is not, on a scheme where the alternative — a dirty flag per
 mutation — misses far more often.
*>
fn ulong hash_bytes(ulong hash, void* data, usz bytes)
{
	if (data == null || bytes == 0) return hash;
	// Every buffer this is given is a device mapping or a heap array, so the
	// branch is taken every time in practice; it is here because a misaligned
	// pointer is a fault rather than a slow path.
	if ((uptr)data % 8 != 0) return hash_octets(hash, data, bytes);

	usz words = bytes / 8;
	ulong* word = (ulong*)data;
	for (usz i = 0; i < words; i++)
	{
		hash ^= word[i];
		hash *= 0x100000001b3;
	}
	char* tail = (char*)data;
	for (usz i = words * 8; i < bytes; i++)
	{
		hash ^= (ulong)tail[i];
		hash *= 0x100000001b3;
	}
	return hash;
}

<*
 The same fold a byte at a time, whatever the pointer is aligned to.

 What the scalars go through, and the alignment is the reason rather than the
 size: `&&value` is a stack temporary whose alignment is the compiler's business,
 and a fold that read it eight bytes at a time when it happened to land on eight
 would answer differently on the frame it did not — which is a key that moves
 while the picture stands still.
*>
fn ulong hash_octets(ulong hash, void* data, usz bytes)
{
	char* at = (char*)data;
	for (usz i = 0; i < bytes; i++)
	{
		hash ^= (ulong)at[i];
		hash *= 0x100000001b3;
	}
	return hash;
}

// One FNV-1a step over a value of any width, for the scalars a key folds in.
macro ulong @hash_value(ulong hash, value) => hash_octets(hash, &&(value), (usz)@sizeof(value));

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
	// Every list here is given the heap explicitly. A List left zero-initialised
	// has a null allocator, and `list_ensure_capacity` resolves null to `tmem` —
	// so the first push backs it with temp-arena memory and any `@pool()` open up
	// the stack frees it on the way out. Nothing faults at that point; the crash
	// arrives later, wherever the list is next walked.
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
 Tops up the per-image semaphores after a rebuild handed back more images than
 last time.

 Never shrinks: a semaphore that might still be waited on by a presentation in
 flight is not ours to destroy, and a spare costs nothing.
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
	// What the last frame cost the GPU. Beside `frames` because its query pool is
	// indexed by frame slot and shares that lifetime exactly — see
	// `gpu/timing.c3` for which frame "the last" means on which path.
	FrameTimer timer;
	// The scene graph, the asset table and the one pipeline that draws them. The
	// frame path above does not know any of that is in there.
	MeshPass pass;
	// The one agent-written shader that runs over the finished frame, and the
	// image the scene goes into while it does. Inert until something calls `set`
	// — see `render/post.c3`.
	PostPass post;
	// The interface drawn over the finished frame — `render/ui.c3`. Inert until
	// something asks for it, the same way `post` is inert until a script sets a
	// shader.
	UiLayer ui;
	// Where the frame is composed at the window's own resolution so the
	// interface can be drawn into it sharp. Only the present path touches it,
	// and only while there is an interface — see `gpu/swapchain.c3`.
	Composite composite;
	bool windowed;
	<*
	 Whether the offscreen target tracks the window's drawable.

	 True until a script pins it. A window and a picture that disagree about how
	 many pixels there are is a picture stretched over a window, which is what a
	 person dragging an edge sees as blur and what "make the window bigger"
	 obviously does not mean.

	 So the target follows: `rebuild` moves it to whatever the surface settled
	 on, whether that came from a drag, a `three.window.resize`, a fullscreen
	 transition or a monitor change. `--width`/`--height` are then the size the
	 window OPENS at, and go on being the target's own size under `--headless`,
	 where there is no window to follow.

	 `three.setRenderSize` pins it, because the other reason to set a render size
	 is to make it deliberately smaller than the window and upscale — the
	 performance knob — and a follow would undo that on the next configure.
	 `three.setRenderSize(null)` unpins.

	 Spelled as the pin rather than as the follow so that the zero value is the
	 default: a `Renderer` is built by assignment in a dozen tests, and a field
	 whose useful value is `true` would be off in every one of them.
	*>
	bool render_size_pinned;

	<*
	 The fraction of the window's pixels the target follows at —
	 `three.window.renderScale`.

	 The other half of the same knob `render_size_pinned` is: a pin says "this
	 many pixels whatever the window does", a scale says "this share of whatever
	 the window is", so a resize or a fullscreen transition keeps the ratio
	 instead of throwing it away. Only the second is a setting a game can ship,
	 because the window's size is the player's to change.

	 Zero means one, for `render_size_pinned`'s reason: a `Renderer` is built by
	 assignment in a dozen tests and a field whose useful value is 1.0 would be
	 an unscaled 0 in every one of them.
	*>
	float render_scale;

	// What every render begins with. Reachable from a script as
	// `scene.background`.
	float[4] clear;

	<*
	 The key of the last frame actually drawn, and whether there is one.

	 A frame whose key matches this one would put back exactly the picture already
	 in `target.color`, so it is not drawn at all — see `Renderer.picture_key`.
	*>
	ulong rendered_key;
	bool rendered_once;
	// Shaded scene colour and depth survive between compatible window frames.
	SceneCache scene_cache;
	// Test and diagnostic escape hatch: force the traditional full redraw.
	bool scene_cache_disabled;

	<*
	 Draw every frame, whatever the key says — `three.alwaysRender`.

	 For a script whose picture depends on something no buffer of this frame
	 carries: a shader reading a clock this engine does not own, an external
	 texture written behind the asset table's back. False by default, and false is
	 the zero value, which is what a `Renderer` built by assignment in a test gets.
	*>
	bool always_render;

	// Frames the key said were already on screen — `stats().skippedFrames`.
	ulong skipped_frames;
	// Frames that were drawn — `stats().renderedFrames`.
	ulong rendered_frames;
	// Scene pixels rebuilt and preserved across submitted frames.
	ulong scene_cache_pixels;
	ulong scene_cache_reused;
}

<*
 The clear colour a renderer starts on, and the one `scene.background = null`
 goes back to.

 Named rather than written twice, because "the default" is something a script can
 ask to be restored to and two spellings of it would drift.
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
	// Before anything can push a stage — an uninitialised `List` falls back to
	// the temp allocator on its first push. `PostPass.init` has the note.
	self.post.init();

	uint image_count = 0;
	if (self.windowed)
	{
		self.viewer.init(&self.gpu, surface, width, height)!;
		image_count = self.viewer.image_count;

		// The picture follows the window from the first frame and not from the
		// first resize. `width` and `height` are logical points where a window is
		// concerned, so on a display that is not 1:1 the drawable that comes back
		// is already bigger than the target just built — and without this the run
		// would open stretched and only become sharp when somebody dragged an edge.
		if (self.viewer.extent.width > 0 && self.viewer.extent.height > 0)
		{
			self.resize_target(self.viewer.extent.width, self.viewer.extent.height)!;
		}
	}
	self.frames.init(&self.gpu, image_count)!;
	self.timer.init(&self.gpu)!;
	// Every scene renders into the float post input. The identity tone map is the
	// ordinary no-post path and performs only the final sRGB encode.
	self.post.ensure_images(&self.gpu, &self.target, 0)!;
	self.post.ensure_tonemap(&self.gpu, &self.target)!;

	return *self;
}

<*
 Moves the offscreen target to a new extent, between frames.

 The render size is otherwise a boot argument — `--width`/`--height` reach
 `Target.init` once — and this is what a settings screen changes. It is not the
 window: the swapchain goes on stretching whatever the target holds over
 whatever the window is, so this is the call that moves *pixels* and
 `three.window.resize` is the one that moves the frame around them.

 ## Everything that has to hear about it

 The target's own two images, the post chain's, and the interface's root
 constraints — `UiLayer.resize` re-lays the tree out against the new extent, or
 the menu bar and every anchored widget would stay sized for the old one while
 the picture around them grew. Nothing else: the scene's pipelines take their
 viewport and scissor dynamically, so no pipeline is rebuilt; the swapchain
 reads `target.extent` when it records the blit, so the destination rect
 follows on the next frame; the composite is the window's size and not this
 one; and the shadow map has a size of its own.

 The chain is told through `ensure_images`, which already compares its own
 extent against the target's and rebuilds when they differ — the path a window
 resize used to be the only caller of. Only when there is a chain: an inactive
 post pass holding images at the old extent is one the next `set` rebuilds
 anyway, and creating them here would be paying for a chain nobody is running.

 ## Why the device is idled

 This is the only place outside `free` that destroys an attachment, and the
 command buffers that reference it may still be executing. `retire.c3`'s
 deferred queue is for objects a frame in flight may name; the target is named
 by *every* frame in flight, so waiting is both simpler and no slower — a
 resolution change is a menu click, not a per-frame cost.

 @param width : `Device pixels. Nothing about the window is consulted.`
 @require width > 0 && height > 0
*>
fn void? Renderer.resize_target(&self, uint width, uint height)
{
	if (width == self.target.extent.width && height == self.target.extent.height) return;

	// The new one before the old one goes, so a size the device will not
	// allocate leaves the renderer exactly as it was rather than with no target
	// at all. Both are resident for the length of this call, which is the price
	// of the failure being recoverable.
	Target next;
	next.init(&self.gpu, width, height)!;

	self.gpu.handle.waitIdle();
	self.target.free(&self.gpu);
	self.target = next;
	self.ui.resize(&self.target);

	self.post.ensure_images(&self.gpu, &self.target, self.post.stages.len())!;
}

fn void Renderer.free(&self)
{
	if (self.gpu.handle != null) self.gpu.handle.waitIdle();
	// Before the target, because it holds an image created at the target's
	// extent, and after the idle, because it frees a pipeline outright rather
	// than retiring it.
	// 
	// Also before the mesh pass: the post shader's own samplers hold references
	// into `pass.assets`, and `MeshPass.free` frees every texture slot outright,
	// so giving them back afterwards would be reading a table that no longer
	// exists.
	// Before `gpu.free()`, because the canvas pass borrows the allocator. Its
	// textures are its own rather than slots in `pass.assets`, so there is no
	// ordering dance here — only the idle above, which the pass needs for the
	// same reason `post` does.
	self.ui.free();
	self.post.release_textures(&self.gpu, &self.pass.assets);
	self.post.free(&self.gpu);
	self.scene_cache.free();
	self.pass.free(&self.gpu);
	self.timer.free(&self.gpu);
	self.frames.free(&self.gpu);
	self.composite.free(&self.gpu);
	self.viewer.free(&self.gpu);
	self.target.free(&self.gpu);
	self.gpu.free();
}

<*
 One number standing for everything this frame would put on screen.

 `MeshPass.frame_key` is most of it — the bytes `prepare` uploaded. This adds
 what lives outside the pass and still reaches the picture: the clear colour, the
 two extents, the interface, and the post chain's own settings, whose push blocks
 a script writes between frames and which no per-frame buffer carries.

 The clock is folded in when there is a script post pass, for the reason
 `MeshPass.reads_clock_time` states about material bodies: `p.time` comes from
 the same reading, and a chain that animates off it draws a new picture every
 frame with nothing else moving.

 Conservative by construction: it is a fold over *content*, so anything that
 reaches the GPU moves it. What it cannot see is a change that reaches the device
 by some other door — that is what `always_render` is for.
*>
fn ulong Renderer.picture_key(&self)
{
	ulong key = self.pass.frame_key;
	key = @hash_value(key, self.clear);
	key = @hash_value(key, self.target.extent);
	key = @hash_value(key, self.viewer.extent);
	key = @hash_value(key, self.ui.active());
	key = @hash_value(key, self.ui.picture_serial());
	key = @hash_value(key, self.ui.slot_generation);
	key = @hash_value(key, self.post.tonemap_mode.ordinal);
	key = @hash_value(key, self.post.tonemap_exposure);
	key = @hash_value(key, self.post.stages.len());
	foreach (stage : self.post.stages)
	{
		key = hash_bytes(key, &stage.block[0], (usz)PUSH_BUDGET);
		key = @hash_value(key, stage.textures);
		key = @hash_value(key, stage.tap);
		key = @hash_value(key, stage.kept);
		key = @hash_value(key, (ulong)(uptr)stage.fragment.ptr);
		key = @hash_value(key, stage.fragment.len);
	}
	if (self.post.stages.len() > 0) key = @hash_value(key, self.pass.clock.time);
	return key;
}

<*
 A whole frame of scene, recorded into `cmd`: begin the target, draw, end the
 target.

 One description of what a frame contains, for three callers. `frame()`,
 `capture()` and `render_offscreen()` would otherwise be the same three calls
 written out three times, which is the shape every "the window shows something
 the screenshot does not" bug has. What the three legitimately differ by — the
 acquire, the blit, the readback, the timestamps spanning all of it — stays with
 them.

 ## A sequence, with the destination decided once at the top

 The invariant the sequence exists to hold is:

 > Exactly one stage writes `target.color`, and the close happens exactly once,
 > here.

 With a post chain running, the scene is drawn into image A instead and the
 chain's tonemap is the stage that writes `target.color`. The branch is here and
 nowhere else, which is the payoff for there being one recording function: window,
 screenshot and `render()` get post-processing at the same moment and cannot
 disagree about it. Everything downstream of `target.color` — the blit, the
 readback, the layout contract — is unchanged and unaware.

 Written as nested `if (posted)` blocks it would be exact for one optional stage
 and wrong for three: with shadows, a post chain and a UI layer, "who writes
 `target.color`, and who closes it" has two-by-two-by-N answers.

 The invariant is enforced, not just documented. A second close is a layout
 transition out of COLOR_ATTACHMENT_OPTIMAL on an image the layer knows is in
 TRANSFER_SRC, so the validation checks in `three_tests::post` fail on it
 ("VUID-VkImageMemoryBarrier2-oldLayout-01197"). Verified by injecting a second
 `self.target.close(cmd)` here: both fail.

 @param may_skip : `Whether a frame identical to the last one drawn may be left undrawn. Only the window path passes true - a screenshot and a headless batch ask for each frame explicitly, and one that answered with the last one would be a lie.`
*>
fn void? Renderer.record_scene(&self, vk::CommandBuffer cmd, bool presenting = false, bool may_skip = false)
{
	// A shared test/device renderer may predate this frame path, and a resize can
	// retire A between frames. Make the always-on HDR input and display encoder
	// present at the recording boundary as well as at normal construction.
	self.post.ensure_images(&self.gpu, &self.target, self.post.stages.len())!;
	self.post.ensure_tonemap(&self.gpu, &self.target)!;
	// Read once: `active` must not change between the begin and the end of one
	// recording, and reading it twice is how that becomes possible.
	bool posted = self.post.active();

	// The same read `pass.prepare` makes below: the slot is advanced by the
	// caller *after* the submit, so every mark recorded here belongs to the run
	// `timer.begin` opened.
	uint slot = self.frames.slot;

	// Outside every rendering, and before the one below opens: this flushes the
	// interface, bakes glyphs and may grow a buffer or rebuild a pipeline. It
	// records nothing into `cmd` — see `UiLayer.upload` for the contract it
	// keeps with the fence wait each caller opens with.
	self.ui.upload(&self.target)!;

	// Before the render pass, because a dispatch cannot be inside one. This is
	// the scene update, the frame's buffers, and the compute skinning for any
	// character routed through it. A phase and not a branch: the frame path does
	// not grow a case per kind of thing that can be drawn.
	self.pass.prepare(&self.gpu, cmd, &self.target, slot)!;
	self.timer.mark(cmd, slot, FrameMark.PREPARE);

	// Nothing that reaches the picture has moved since the last frame was drawn,
	// so `target.color` still holds it, in the TRANSFER_SRC layout `close` left it
	// in and the blit expects. Every mark between BEGIN and END is still recorded,
	// because `gpu/timing.c3` requires all of them on every frame.
	ulong key = self.picture_key();
	if (may_skip && self.rendered_once && !self.always_render && key == self.rendered_key)
	{
		self.timer.mark(cmd, slot, FrameMark.SHADOW);
		self.timer.scene_begin(cmd, slot);
		self.timer.scene_end(cmd, slot);
		self.timer.mark(cmd, slot, FrameMark.SCENE);
		self.timer.mark(cmd, slot, FrameMark.POST);
		self.skipped_frames++;
		return;
	}
	self.rendered_key = key;
	// Only the window path leaves a picture the window path may re-present. A
	// screenshot draws the interface *into* the target where the window draws it
	// over the blit, so a frame recorded for one is not a frame the other may
	// stand on.
	self.rendered_once = may_skip;
	self.rendered_frames++;

	// The exact frame key changed, but most of the shaded scene may not have.
	// Explicit captures use the same cache when their target has an uncontaminated
	// scene image; `scene_cache_disabled` gives comparisons a forced-full path.
	ulong cache_global = KEY_SEED;
	cache_global = @hash_value(cache_global, self.clear);
	cache_global = @hash_value(cache_global, posted);
	// Extent alone cannot distinguish a target rebuilt at the same size.
	cache_global = @hash_value(cache_global, self.target.color);
	cache_global = @hash_value(cache_global, self.target.depth);
	if (posted) cache_global = @hash_value(cache_global, self.post.scene.image);
	vk::Rect2D cache_full = scene_cache_full(self.target.extent);
	bool cache_safe = !self.scene_cache_disabled && !self.pass.scene_rect_partial
		&& (posted || presenting || !self.ui.active());
	vk::Rect2D cache_dirty = cache_full;
	if (cache_safe) { cache_dirty = self.pass.scene_cache_update(&self.scene_cache, &self.target, cache_global); }
	else { self.scene_cache.invalidate(); }
	bool cache_partial = cache_safe
		&& self.scene_cache.valid && !scene_cache_empty(cache_dirty)
		&& !scene_cache_same(cache_dirty, cache_full);
	bool cache_reuse = cache_safe && self.scene_cache.valid && scene_cache_empty(cache_dirty);
	ulong frame_pixels = (ulong)self.target.extent.width * (ulong)self.target.extent.height;
	ulong dirty_pixels = cache_partial
		? (ulong)cache_dirty.extent.width * (ulong)cache_dirty.extent.height
		: (cache_reuse ? 0 : frame_pixels);
	self.scene_cache_pixels += dirty_pixels;
	self.scene_cache_reused += frame_pixels - dirty_pixels;

	// The shadow map, and it is a line rather than a branch. It begins and ends a
	// rendering of its own, so it has to be here and not inside the block below;
	// it records nothing at all in a frame with shadows off, so an unshadowed
	// frame is byte-identical to one from before this existed.
	// 
	// It does not touch `target.color` and so does not touch the invariant the
	// rest of this function holds.
	self.pass.record_shadow(cmd);
	// Recorded even when the call above recorded nothing, which is the one place
	// the byte-identity claim does not hold: with shadows off the buffer carries
	// this timestamp and `stats().shadowMs` reads 0. The alternative is a frame
	// that reports no timings at all — see `gpu/timing.c3`.
	self.timer.mark(cmd, slot, FrameMark.SHADOW);
	if (!cache_reuse) self.pass.record_ambient_occlusion(cmd);

	// The depth prepass, and outside the query below on purpose: it is what makes
	// `fragmentsShaded` mean "how many times the scene pass shaded a pixel" rather
	// than that plus the prepass's own cut-out fragments. `docs/stats.md` says so.
	self.pass.cache_rect = cache_dirty;
	bool prepassed = cache_reuse ? false
		: self.pass.record_depth_prepass(cmd, &self.target, cache_partial, posted);

	// Around the scene rendering and outside it — `gpu/timing.c3` says why.
	self.timer.scene_begin(cmd, slot);

	if (cache_reuse)
	{
		// The preserved scene attachment is already in the layout its next
		// consumer expects. There is no rendering to open or clear.
	}
	else if (cache_partial)
	{
		self.target.begin_cached_render_to(cmd,
			posted ? self.post.scene.image : self.target.color,
			posted ? self.post.scene.view : self.target.color_view,
			cache_dirty, self.clear, posted, prepassed);
	}
	else if (posted)
	{
		self.target.begin_render_to(cmd, self.post.scene.image, self.post.scene.view, self.clear, prepassed);
	}
	else
	{
		self.target.begin_render(cmd, self.clear, prepassed);
	}

	// Everything drawn into the target, between `begin_render` and `close`. One
	// call, on purpose: the frame path does not grow a branch per kind of thing
	// that can be drawn. A pass that was never given a pipeline records nothing,
	// which lets a headless clear-colour render work with no shader on disk.
	if (!cache_reuse)
	{
		self.pass.cache_rect = cache_dirty;
		self.pass.cache_partial = cache_partial;
		self.pass.record(cmd);
		self.pass.cache_partial = false;
		vk::cmdEndRendering(cmd);
	}

	// The scene's rendering ends here on both paths, which lets the chain below be
	// a list of passes rather than a thing that also has to know how the frame
	// started.
	self.timer.scene_end(cmd, slot);
	self.timer.mark(cmd, slot, FrameMark.SCENE);

	// The asset table comes down with it because each post shader's own samplers
	// resolve through it — bindings 0 and 1 are the chain's own images, and
	// everything above them is an image a script named.
	if (posted)
	{
		self.post.record_chain(
			cmd,
			&self.target,
			&self.pass.assets,
			self.pass.clock.time,
			self.pass.camera.near_plane,
			self.pass.camera.far_plane,
			cache_reuse
		)!;
	}

	self.timer.mark(cmd, slot, FrameMark.POST);

	// The interface, over the finished frame. A rendering of its own because it
	// must not clear what it is drawn over and has no depth to test — see
	// `Target.begin_overlay`. It writes `target.color` like the stages above it
	// and, like them, does not close it.
	//
	// Unless this frame is being presented, in which case `frame()` draws it
	// after the blit instead, at the window's own pixels — see `Composite`. It
	// has to be one or the other and never both: the two copies would composite
	// over each other, and a translucent panel would darken twice.
	if (!presenting && self.ui.active())
	{
		self.target.begin_overlay(cmd);
		self.ui.record(cmd, self.target.extent)!;
		vk::cmdEndRendering(cmd);
	}

	// With no post pass a reused target was already left in TRANSFER_SRC by the
	// previous frame. Closing it again would claim the wrong old layout.
	if (posted || !cache_reuse) self.target.close(cmd);
}

<*
 What the GPU spent on a frame, in milliseconds.

 Which frame depends on how it was drawn: `capture()` and `render_offscreen()`
 leave behind the frame they just drew, `frame()` leaves behind the last one to
 have completed. 0 before anything has been rendered, and 0 for the whole run on
 a device that cannot write timestamps. See `gpu/timing.c3`.

 A method rather than a public field, so the one place that decides what "the
 last frame" means stays inside this module.
*>
fn double Renderer.gpu_ms(&self) => self.timer.timing.total;

<*
 The same frame, split into the phases that produced it.

 `total` is what `gpu_ms` returns and the five phases sum to it, so this is the
 whole of the answer rather than a sample of it. Same "which frame" rules as
 `gpu_ms`, because it is the same reading.
*>
fn FrameTiming Renderer.timing(&self) => self.timer.timing;

<*
 Fragment shader invocations of the last scene pass — the same "which frame"
 rules as `gpu_ms`, and 0 on a device without `pipelineStatisticsQuery`.

 Divided by the render size it is the frame's overdraw.
*>
fn ulong Renderer.fragments_shaded(&self) => self.timer.fragments;

<*
 Tell the swapchain how big the window says it is, in device pixels.

 Only consulted where the surface itself declines to answer, which is Wayland
 and nowhere else — see `Viewer.surface_extent`. Called every frame rather than
 on a resize event, because it is a comparison of two numbers and the loop that
 would have to notice a resize is the one this is protecting from having to.

 Zero is ignored, which is what a window reports before its first configure.
*>
fn void Renderer.want_surface(&self, uint width, uint height)
{
	if (!self.windowed || width == 0 || height == 0) return;
	self.viewer.wanted = { .width = width, .height = height };
}

<*
 Rebuilds the swapchain for the window's current size.

 @return `false when the window is minimised — skip the frame and wait for the next event.`
*>
fn bool? Renderer.rebuild(&self)
{
	if (!self.windowed) return false;
	if (!self.viewer.rebuild(&self.gpu)!) return false;
	// A rebuild can hand back more images than the last one did.
	self.frames.ensure_present_semaphores(&self.gpu, self.viewer.image_count)!;

	// The picture follows the window unless a script has pinned it. This is the
	// one place every window size change arrives — a drag, `three.window.resize`,
	// a fullscreen transition, a move to a display of a different density — so it
	// is the one place that has to be told.
	//
	self.follow_window();
	return true;
}

<*
 Brings the render size back to the window's, unless a script has pinned it.

 Called from `rebuild`, where a resize has just landed, and again at the top of
 every frame. The second call is not a backstop for the first: unpinning with
 `three.setRenderSize(null)` changes nothing about the swapchain, so there is no
 rebuild to carry it, and without a per-frame reconcile the follow would not
 resume until somebody happened to drag the window.

 Costs a comparison when the two already agree, which is every frame but the few
 that changed something — `resize_target` returns on the spot when the extent it
 is given is the extent it has.

 Failure is reported and dropped rather than raised: the swapchain is already
 rebuilt, so the frame can be presented at the render size it had, and a window
 dragged to something the device will not allocate should go blurry rather than
 take the process down. `resize_target` leaves the old target standing.
*>
fn void Renderer.follow_window(&self)
{
	if (self.render_size_pinned || !self.windowed) return;

	uint wide = self.viewer.extent.width;
	uint high = self.viewer.extent.height;
	// The raw drawable, before the scale: a minimised window is 0x0 and there is
	// nothing to make a target out of, whereas 0 scaled would round up to a 1x1.
	if (wide == 0 || high == 0) return;

	wide = scale_side(wide, self.render_scale);
	high = scale_side(high, self.render_scale);

	if (catch err = self.resize_target(wide, high))
	{
		@advise("three: the window is %dx%d and the device would not make a target that size (%s)", wide, high, err);
	}
}

<*
 One side of the drawable through the render scale.

 Rounded to nearest so a 0.5 of an odd width lands on the even neighbour rather
 than always down, and held inside the same bounds `three.setRenderSize` takes,
 since this is the other way to arrive at a target extent.

 @param scale : `The fraction, or 0 for the drawable's own size.`
 @require side > 0
 @ensure return > 0
*>
fn uint scale_side(uint side, float scale)
{
	if (scale <= 0.0f || scale == 1.0f) return side;

	double want = (double)side * (double)scale + 0.5;
	if (want < 1.0) return 1;
	if (want > (double)RENDER_MAX_SIDE) return (uint)RENDER_MAX_SIDE;
	return (uint)want;
}

<*
 Draws one frame into the target and blits it to the window.

 The size poll at the top is the primary resize path, not a backstop: on macOS a
 live drag routinely resizes the surface without either the acquire or the
 present ever reporting `OUT_OF_DATE`, so waiting to be told means a stretched
 picture for the whole drag. `SUBOPTIMAL_KHR` is read off the raw result because
 it is a *success* code — the binding does not turn it into a fault, so there is
 nothing to catch.

 @return `false when nothing was presented (minimised, or the swapchain was rebuilt instead).`
*>
fn bool? Renderer.frame(&self, long* wait_ns = null)
{
	if (wait_ns != null) *wait_ns = 0;
	if (!self.windowed) return false;

	self.follow_window();

	vk::Extent2D surface_size = self.viewer.surface_extent(&self.gpu)!;
	if (surface_size.width != self.viewer.extent.width || surface_size.height != self.viewer.extent.height)
	{
		self.rebuild()!;
		return false;
	}

	uint slot              = self.frames.slot;
	vk::Fence fence        = self.frames.fences[slot];
	vk::Semaphore acquired = self.frames.image_available[slot];

	Clock waited = clock::now();
	fence.wait(self.gpu.handle)!;
	if (wait_ns != null) *wait_ns += (long)waited.to_now();

	uint index;
	waited = clock::now();
	vk::Result acquire = vk::extensions.vkAcquireNextImageKHR(
		self.gpu.handle,
		self.viewer.handle,
		ulong::max,
		acquired,
		(vk::Fence)null,
		&index
	);
	if (wait_ns != null) *wait_ns += (long)waited.to_now();
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
	// next-but-one frame's fence wait with work it did not cover. See
	// `gpu/retire.c3`.
	self.gpu.begin_frame();

	// Read once, for `posted`'s reason in `record_scene`: what decides where the
	// interface is drawn must not change between the two places that ask.
	// Nothing is allocated for a run that never brings an interface up, and the
	// image is only rebuilt when the window changes size.
	bool overlaid = self.ui.active();
	if (overlaid) self.composite.ensure(&self.gpu, self.viewer.extent)!;

	vk::CommandBuffer cmd = self.frames.buffers[slot];
	vk::resetCommandBuffer(cmd, (vk::CommandBufferResetFlags)0)!;
	vk::beginCommandBuffer(cmd, &&vk::commandBufferBeginInfo())!;

	// First and last commands in the buffer. The blits are inside the span on
	// purpose — `gpu/timing.c3` says why.
	self.timer.begin(&self.gpu, cmd, slot)!;
	self.record_scene(cmd, presenting: overlaid, may_skip: true)!;

	if (overlaid)
	{
		// Scale the scene up to the window FIRST, then draw the interface into
		// it. Same picture as the plain blit below for everything the scene
		// drew, and an interface rasterised at the window's pixels instead of
		// at the target's and stretched.
		self.composite.receive(cmd, &self.target);
		self.composite.begin_overlay(cmd);
		self.ui.record(cmd, self.composite.extent)!;
		vk::cmdEndRendering(cmd);
		self.composite.close(cmd);
		self.viewer.record_blit_from(cmd, self.composite.color, self.composite.extent, index);
	}
	else
	{
		self.viewer.record_blit(cmd, &self.target, index);
	}

	self.timer.end(cmd, slot);

	vk::endCommandBuffer(cmd)!;

	vk::Semaphore finished = self.frames.render_finished[index];
	self.gpu.submit(cmd, fence, acquired, finished)!;

	vk::PresentInfoKHR present = vk::presentInfoKHR().setWaitSemaphores({ finished })
		.setSwapchains({ self.viewer.handle })
		.setImageIndices({ index });

	waited = clock::now();
	vk::Result presented = vk::extensions.vkQueuePresentKHR(self.gpu.graphics.handle, &present);
	if (wait_ns != null) *wait_ns += (long)waited.to_now();

	self.frames.slot = (slot + 1) % MAX_FRAMES_IN_FLIGHT;

	// Rebuilt last, after the frame's own bookkeeping: the swapchain is replaced
	// under a device that has just been idled, and the acquired image has been
	// returned by the present above either way.
	if (presented == ERROR_OUT_OF_DATE_KHR || presented == SUBOPTIMAL_KHR)
	{
		self.rebuild()!;
		return false;
	}
	if (presented != SUCCESS) return vk::E_ERROR_UNKNOWN~;

	return true;
}

<*
 Renders one frame into the target and reads it back.

 Identical to `frame()` minus the acquire, the blit and the present — which is
 the whole argument for rendering offscreen: this works with no window, no
 surface and no window server, and what it returns is the rendered image rather
 than an OS window grab. Byte-identical across runs and across window sizes,
 because nothing about a window reaches it.

 @return `An Image owning its pixels — free it with Image.free.`
*>
fn image::Image? Renderer.capture(&self, alloc::Allocator allocator = mem, long* wait_ns = null)
{
	if (wait_ns != null) *wait_ns = 0;
	vk::Memory readback = self.target.create_readback(&self.gpu)!;
	defer readback.free();

	uint slot       = self.frames.slot;
	vk::Fence fence = self.frames.fences[slot];
	Clock waited = clock::now();
	fence.wait(self.gpu.handle)!;
	if (wait_ns != null) *wait_ns += (long)waited.to_now();
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
	waited = clock::now();
	fence.wait(self.gpu.handle)!;
	if (wait_ns != null) *wait_ns += (long)waited.to_now();

	// Collected here rather than left to this slot's next `begin`, which is two
	// frames away: a caller that captures and then asks what it cost should be
	// told about the capture it just took, not the one before it.
	self.timer.collect(&self.gpu, slot)!;

	self.frames.slot = (slot + 1) % MAX_FRAMES_IN_FLIGHT;
	return self.target.decode_readback(&readback, allocator);
}

<*
 Renders one frame into the target and stops there.

 `capture` without the readback, which is what `three.render(scene)` from a
 script wants: the pixels are read back once at the end of a run, and a script
 calling `render()` in a loop should not pay for a buffer allocation and a host
 copy each time. It exists rather than `render()` being a no-op so that a scene
 which cannot be drawn says so at the line that asked for it.

 @param may_skip : `Whether a frame identical to the last one drawn may be left undrawn - see record_scene. False for three.render(), which is an explicit ask; the offscreen half of a host driving its own loop is what passes true.`
*>
fn void? Renderer.render_offscreen(&self, long* wait_ns = null, bool may_skip = false)
{
	if (wait_ns != null) *wait_ns = 0;
	uint slot       = self.frames.slot;
	vk::Fence fence = self.frames.fences[slot];
	Clock waited = clock::now();
	fence.wait(self.gpu.handle)!;
	if (wait_ns != null) *wait_ns += (long)waited.to_now();
	fence.reset(self.gpu.handle)!;
	self.gpu.begin_frame();

	vk::CommandBuffer cmd = self.frames.buffers[slot];
	vk::resetCommandBuffer(cmd, (vk::CommandBufferResetFlags)0)!;
	vk::beginCommandBuffer(cmd, &&vk::commandBufferBeginInfo())!;

	self.timer.begin(&self.gpu, cmd, slot)!;
	self.record_scene(cmd, may_skip: may_skip)!;
	self.timer.end(cmd, slot);

	vk::endCommandBuffer(cmd)!;
	self.gpu.submit(cmd, fence, (vk::Semaphore)null, (vk::Semaphore)null)!;

	// Waited on here rather than left to the next frame's fence: the instance
	// buffer for this slot is rewritten on the next record, and it may not be
	// while the GPU is still reading it.
	waited = clock::now();
	fence.wait(self.gpu.handle)!;
	if (wait_ns != null) *wait_ns += (long)waited.to_now();
	// The wait is already paid for, so the frame's own timing is free to take —
	// same argument as in `capture`.
	self.timer.collect(&self.gpu, slot)!;
	self.frames.slot = (slot + 1) % MAX_FRAMES_IN_FLIGHT;
}

<*
 Renders one frame and writes it to `path` as a PNG.
*>
fn void? Renderer.screenshot(&self, String path, long* wait_ns = null)
{
	image::Image shot = self.capture(wait_ns: wait_ns)!;
	defer shot.free();
	write_png(&shot, path)!;
}
