<*
 The XR frame loop: OpenXR's wait, begin, locate, draw and end around the
 engine's own tick, with both eyes drawn side by side in one pass.

 The right eye is an extra `SceneView` beside the main camera, so geometry,
 lights and shadows are prepared once for both. Each eye gets its own light
 clusters, AO and depth prepass over its half of the target.
*>
module three @feat(ANDROID);

import std::io;
import std::time;
import std::math::vector;
import xr;
import vk;
import three::ndk;

// Of the runtime's recommended eye size, 1680x1760 on Quest 3.
const float XR_RENDER_SCALE = 0.7f;

<*
 Draws one frame and hands it to `dst`, an image of the XR swapchain.
 `render_offscreen` with a blit at the end, left in the layout the runtime
 expects to be given back.
*>
fn void? Renderer.render_xr(&self, vk::Image dst, vk::Extent2D dst_extent, long* wait_ns = null)
{
	if (wait_ns != null) *wait_ns = 0;
	uint slot       = self.frames.slot;
	vk::Fence fence = self.frames.fences[slot];
	@timed(wait_ns) { fence.wait(self.gpu.handle)!; };
	fence.reset(self.gpu.handle)!;
	self.gpu.begin_frame();

	vk::CommandBuffer cmd = self.frames.buffers[slot];
	vk::resetCommandBuffer(cmd, (vk::CommandBufferResetFlags)0)!;
	vk::beginCommandBuffer(cmd, &&vk::commandBufferBeginInfo())!;

	self.timer.begin(&self.gpu, cmd, slot)!;
	self.record_scene(cmd)!;
	record_blit(cmd, self.target.color, self.target.extent, dst, dst_extent, {
		...IMAGE_BARRIER,
		.image = dst,
		.srcStageMask = PIPELINE_STAGE_2_ALL_TRANSFER_BIT,
		.srcAccessMask = ACCESS_2_TRANSFER_WRITE_BIT,
		.dstStageMask = PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
		.dstAccessMask = (vk::AccessFlags2)0,
		.oldLayout = IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
		.newLayout = IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
	});
	self.timer.end(cmd, slot);

	vk::endCommandBuffer(cmd)!;
	// Not waited on: the runtime orders its reads after this submit on the same
	// queue, and the slot's fence guards its buffers when the slot comes round.
	self.gpu.submit(cmd, fence, (vk::Semaphore)null, (vk::Semaphore)null)!;
	self.frames.slot = (slot + 1) % MAX_FRAMES_IN_FLIGHT;
}

<*
 Runs the session until the runtime or the activity ends it.

 @param [&inout] app : "The glue's app"
 @param [&inout] host : "An open XR host with a started session"
 @return? xr::CALL_FAILED
*>
fn void? run_xr(ndk::App* app, XrHost* host, Renderer* renderer, JsRuntime* runtime)
{
	DString said;
	said.init(mem, 256);
	defer said.free();

	// Frames are left in flight, so the swapchain must not go before they finish.
	defer renderer.gpu.wait_idle();

	xr::Time first_time = 0;
	// For the once-every-few-seconds line saying how it is going.
	Clock report_since = clock::now();
	uint frames_drawn;
	long busy_ns;
	long waited_ns;
	FrameTiming gpu_sum;

	while (app.destroy_requested == 0 && !host.exit_wanted)
	{
		// Without a running session nothing paces the loop, so the looper does.
		ndk::pump(app, host.running ? 0 : 50);
		host.poll();
		if (host.exit_wanted || app.destroy_requested != 0) break;
		if (!host.running) continue;

		xr::FrameWaitInfo wait_info = { .type = xr::TYPE_FRAME_WAIT_INFO };
		xr::FrameState frame = { .type = xr::TYPE_FRAME_STATE };
		xr::check(xr::cmd.wait_frame(host.session, &wait_info, &frame), "xrWaitFrame")!;
		xr::FrameBeginInfo begin_info = { .type = xr::TYPE_FRAME_BEGIN_INFO };
		xr::check(xr::cmd.begin_frame(host.session, &begin_info), "xrBeginFrame")!;

		Clock busy = clock::now();
		if (first_time == 0) first_time = frame.predicted_display_time;
		double elapsed_ms = (double)(frame.predicted_display_time - first_time) / 1_000_000.0;
		Clock host_started = clock::now();
		runtime.tick(elapsed_ms);

		xr::View[2] views = { { .type = xr::TYPE_VIEW }, { .type = xr::TYPE_VIEW } };
		bool drawn = false;
		long wait_ns;
		if (frame.should_render != 0)
		{
			xr::ViewState view_state = { .type = xr::TYPE_VIEW_STATE };
			xr::ViewLocateInfo locate = {
				.type = xr::TYPE_VIEW_LOCATE_INFO,
				.view_configuration_type = xr::VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO,
				.display_time = frame.predicted_display_time,
				.space = host.space,
			};
			uint count;
			xr::check(xr::cmd.locate_views(host.session, &locate, &view_state, 2, &count, &views[0]), "xrLocateViews")!;
			if (count == 2 && (view_state.view_state_flags & xr::VIEW_STATE_ORIENTATION_VALID_BIT) != 0)
			{
				aim_eyes(renderer, views);
				draw_to_swapchain(host, renderer, &wait_ns)!;
				drawn = true;
			}
		}
		runtime.complete_host_frame((long)host_started.to_now(), wait_ns);

		end_frame(host, &frame, &views, drawn)!;
		print_frame_output(runtime, &said);
		if (runtime.quit_wanted) host.request_exit();

		if (drawn)
		{
			frames_drawn++;
			FrameTiming gpu = renderer.timing();
			gpu_sum.total += gpu.total;
			gpu_sum.prepare += gpu.prepare;
			gpu_sum.shadow += gpu.shadow;
			gpu_sum.occlusion += gpu.occlusion;
			gpu_sum.prepass += gpu.prepass;
			gpu_sum.scene += gpu.scene;
			gpu_sum.post += gpu.post;
			gpu_sum.present += gpu.present;
		}
		busy_ns += (long)busy.to_now() - wait_ns;
		waited_ns += wait_ns;
		long since_ns = (long)report_since.to_now();
		if (since_ns >= 5_000_000_000)
		{
			double seconds = (double)since_ns / 1e9;
			double n = frames_drawn > 0 ? (double)frames_drawn : 1.0;
			io::printfn("xr: %.1f fps, cpu %.2f ms, fence wait %.2f ms, gpu %.2f ms (prepare %.2f, shadow %.2f, ao %.2f, prepass %.2f, scene %.2f, post %.2f, present %.2f)",
				frames_drawn / seconds, (double)busy_ns / 1e6 / n, (double)waited_ns / 1e6 / n,
				gpu_sum.total / n, gpu_sum.prepare / n, gpu_sum.shadow / n, gpu_sum.occlusion / n,
				gpu_sum.prepass / n, gpu_sum.scene / n, gpu_sum.post / n, gpu_sum.present / n);
			report_since = clock::now();
			frames_drawn = 0;
			busy_ns = 0;
			waited_ns = 0;
			gpu_sum = {};
		}
	}
}

<*
 Left eye on the main camera over the left half of the target, right eye as an
 extra view over the right half, both seen from the rig the script's camera is.
*>
fn void aim_eyes(Renderer* renderer, xr::View[2] views) @local
{
	Camera* camera = &renderer.pass.camera;
	Vec3 rig = camera.target;
	float yaw = camera.yaw;
	Camera right = *camera;
	head_lock(camera, rig, yaw, views[0]);
	head_lock(&right, rig, yaw, views[1]);
	renderer.pass.view_rect = { 0, 0, 0.5f, 1 };
	SceneView[1] extra = { { .camera = right, .rect = { 0.5f, 0, 0.5f, 1 } } };
	renderer.pass.set_extra_views(extra[..]);
}

<*
 @return? xr::CALL_FAILED
*>
fn void? draw_to_swapchain(XrHost* host, Renderer* renderer, long* wait_ns) @local
{
	uint index;
	xr::SwapchainImageAcquireInfo acquire = { .type = xr::TYPE_SWAPCHAIN_IMAGE_ACQUIRE_INFO };
	xr::check(xr::cmd.acquire_swapchain_image(host.swapchain, &acquire, &index), "xrAcquireSwapchainImage")!;
	xr::SwapchainImageWaitInfo wait = { .type = xr::TYPE_SWAPCHAIN_IMAGE_WAIT_INFO, .timeout = xr::INFINITE_DURATION };
	xr::check(xr::cmd.wait_swapchain_image(host.swapchain, &wait), "xrWaitSwapchainImage")!;

	// Released whatever the draw did: a swapchain with an image never given back
	// cannot be acquired from again.
	defer
	{
		xr::SwapchainImageReleaseInfo release = { .type = xr::TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO };
		(void)xr::check(xr::cmd.release_swapchain_image(host.swapchain, &release), "xrReleaseSwapchainImage");
	}
	renderer.render_xr(host.images[index], { host.eye_width * 2, host.eye_height }, wait_ns)!;
}

<*
 @return? xr::CALL_FAILED
*>
fn void? end_frame(XrHost* host, xr::FrameState* frame, xr::View[2]* views, bool drawn) @local
{
	xr::CompositionLayerProjectionView[2] eyes;
	foreach (i, &eye : eyes)
	{
		*eye = {
			.type = xr::TYPE_COMPOSITION_LAYER_PROJECTION_VIEW,
			.pose = (*views)[i].pose,
			.fov = (*views)[i].fov,
			.sub_image = {
				.swapchain = host.swapchain,
				.image_rect = {
					.offset = { (int)(i * host.eye_width), 0 },
					.extent = { (int)host.eye_width, (int)host.eye_height },
				},
			},
		};
	}
	xr::CompositionLayerProjection layer = {
		.type = xr::TYPE_COMPOSITION_LAYER_PROJECTION,
		.space = host.space,
		.view_count = 2,
		.views = &eyes[0],
	};
	xr::CompositionLayerBaseHeader*[1] layers = { (xr::CompositionLayerBaseHeader*)&layer };
	xr::FrameEndInfo end_info = {
		.type = xr::TYPE_FRAME_END_INFO,
		.display_time = frame.predicted_display_time,
		.environment_blend_mode = xr::ENVIRONMENT_BLEND_MODE_OPAQUE,
		.layer_count = drawn ? 1 : 0,
		.layers = drawn ? &layers[0] : null,
	};
	xr::check(xr::cmd.end_frame(host.session, &end_info), "xrEndFrame")!;
}
