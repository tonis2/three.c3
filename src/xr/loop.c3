<*
 The XR frame loop: OpenXR's wait, begin, locate, draw and end around the
 engine's own tick, with both eyes drawn in one pass.

 The right eye is an extra `SceneView` beside the main camera, so geometry,
 lights and shadows are prepared once for both. Each eye gets its own light
 clusters and AO. On a multiview target every draw reaches both eyes, each
 into its own layer, and the tonemap puts them side by side in the swapchain
 image; otherwise each eye is drawn over its half of the target in turn.
*>
module three @feat(ANDROID);

import std::io;
import std::time;
import std::math;
import std::math::vector;
import xr;
import vk;
import three::ndk;

// Of the runtime's recommended eye size, 1680x1760 on Quest 3.
const float XR_RENDER_SCALE = 0.7f;

<*
 Draws one frame into `dst`, an image of the XR swapchain, and leaves it in the
 layout the runtime expects to be given back. The tonemap writes it directly;
 a frame with an interface over it goes through the target and a blit.
*>
fn void? Renderer.render_xr(&self, vk::Image dst, vk::ImageView dst_view, vk::Extent2D dst_extent,
	long* wait_ns = null)
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
	bool direct = self.record_scene(cmd, output: dst_view != null ? dst : (vk::Image)null, output_view: dst_view,
		see_through: self.xr_display.passthrough_active)!;
	if (!direct) record_blit(cmd, self.target.color, self.target.extent, dst, dst_extent, {
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
 @param [&inout] dev : "Tool calls and pushed scripts, served between frames"
 @return? xr::CALL_FAILED, HeadsetDev.between_frames!
*>
fn void? run_xr(ndk::App* app, XrHost* host, Renderer* renderer, JsRuntime* runtime, HeadsetDev* dev)
{
	DString said;
	said.init(mem, 256);
	defer said.free();

	// Frames are left in flight, so the swapchain must not go before they finish.
	defer renderer.gpu.wait_idle();
	io::printfn("xr: multiview %s", renderer.target.views > 1 ? "on" : "off");
	host.display = &renderer.xr_display;
	defer host.display = null;
	defer renderer.xr_display.presenting = false;

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
		// Served while the session is idle too, so the tools still answer with
		// the headset off.
		dev.between_frames(runtime, renderer)!;
		if (runtime.quit_wanted) host.request_exit();
		renderer.xr_display.presenting = host.running;
		if (!host.running) continue;
		host.apply_refresh_rate();
		host.apply_passthrough();

		xr::FrameWaitInfo wait_info = { .type = xr::TYPE_FRAME_WAIT_INFO };
		xr::FrameState frame = { .type = xr::TYPE_FRAME_STATE };
		xr::check(xr::cmd.wait_frame(host.session, &wait_info, &frame), "xrWaitFrame")!;
		xr::FrameBeginInfo begin_info = { .type = xr::TYPE_FRAME_BEGIN_INFO };
		xr::check(xr::cmd.begin_frame(host.session, &begin_info), "xrBeginFrame")!;

		Clock busy = clock::now();
		if (first_time == 0) first_time = frame.predicted_display_time;
		double elapsed_ms = (double)(frame.predicted_display_time - first_time) / 1_000_000.0;
		Clock host_started = clock::now();
		bool focused = host.state == xr::SESSION_STATE_FOCUSED;
		HandsReading hands;
		host.input.read(host.session, host.space, frame.predicted_display_time, focused, &hands);
		// The eyes before the tick, so the script reads the head this frame is drawn from.
		xr::View[2] views = { { .type = xr::TYPE_VIEW }, { .type = xr::TYPE_VIEW } };
		bool seen = false;
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
			seen = count == 2 && (view_state.view_state_flags & xr::VIEW_STATE_ORIENTATION_VALID_BIT) != 0;
			if (seen && (view_state.view_state_flags & xr::VIEW_STATE_POSITION_VALID_BIT) != 0)
			{
				hands.head = between_eyes(views);
				hands.head_tracked = true;
			}
		}
		runtime.tick(elapsed_ms, { }, &hands);
		host.input.send_haptics(host.session, &runtime.hands, focused);

		bool drawn = false;
		long wait_ns;
		if (seen)
		{
			aim_eyes(renderer, views);
			renderer.update_foveation(views)!;
			draw_to_swapchain(host, renderer, &wait_ns)!;
			drawn = true;
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
			io::printfn("xr: %.1f fps, cpu %.2f ms, fence wait %.2f ms, gpu %.2f ms (prepare %.2f, shadow %.2f, ao %.2f, prepass %.2f, scene %.2f, post %.2f, present %.2f), hands L:%s R:%s",
				frames_drawn / seconds, (double)busy_ns / 1e6 / n, (double)waited_ns / 1e6 / n,
				gpu_sum.total / n, gpu_sum.prepare / n, gpu_sum.shadow / n, gpu_sum.occlusion / n,
				gpu_sum.prepass / n, gpu_sum.scene / n, gpu_sum.post / n, gpu_sum.present / n,
				hand_word(&runtime.hands, Hand.LEFT), hand_word(&runtime.hands, Hand.RIGHT));
			report_since = clock::now();
			frames_drawn = 0;
			busy_ns = 0;
			waited_ns = 0;
			gpu_sum = {};
		}
	}
}

// The head as the point between the two eyes, turned the way the left one is.
fn HandPose between_eyes(xr::View[2] views) @local
{
	xr::Posef l = views[0].pose;
	xr::Posef r = views[1].pose;
	Vec3 middle = { (l.position.x + r.position.x) * 0.5f, (l.position.y + r.position.y) * 0.5f, (l.position.z + r.position.z) * 0.5f };
	return { .position = middle, .rotation = { l.orientation.x, l.orientation.y, l.orientation.z, l.orientation.w } };
}

// For the timing line: which controller a hand holds, or "-".
fn String hand_word(Hands* hands, Hand hand) @local
{
	HandReading now = hands.hand[hand.ordinal].now;
	if (!now.connected) return "-";
	return now.profile.len > 0 ? now.profile : "?";
}

<*
 Left eye on the main camera, right eye as an extra view, both seen from the rig
 the script's camera is. Each covers its own layer of a multiview target, or
 its half of a target that draws them side by side.
*>
fn void aim_eyes(Renderer* renderer, xr::View[2] views) @local
{
	Camera* camera = &renderer.pass.camera;
	Vec3 rig = camera.target;
	float yaw = camera.yaw;
	Camera right = *camera;
	head_lock(camera, rig, yaw, views[0]);
	head_lock(&right, rig, yaw, views[1]);
	bool layered = renderer.target.views > 1;
	float[4] whole = { 0, 0, 1, 1 };
	float[4] left_half = { 0, 0, 0.5f, 1 };
	float[4] right_half = { 0.5f, 0, 0.5f, 1 };
	renderer.pass.view_rect = layered ? whole : left_half;
	SceneView[1] extra = { { .camera = right, .rect = layered ? whole : right_half } };
	renderer.pass.set_extra_views(extra[..]);
}

<*
 Refills the foveation map when a script asked for another level or the lens
 centres moved - in practice once, on the first frame, and on each change of
 `three.xr.foveation`. Waits for the device, which is fine that rarely.
*>
fn void? Renderer.update_foveation(&self, xr::View[2] views)
{
	FoveationMap* map = &self.target.foveation;
	if (!map.exists()) return;
	Foveation level = map.level;
	if (self.xr_display.foveation_request != 0)
	{
		level = Foveation::from_ordinal(self.xr_display.foveation_request - 1);
		self.xr_display.foveation_request = 0;
	}
	float[2] left = lens_center(views[0].fov);
	float[2] right = lens_center(views[1].fov);
	float[4] centers = { left[0], left[1], right[0], right[1] };
	bool moved = false;
	foreach (i, c : centers) moved |= math::abs(c - map.centers[i]) > 0.01f;
	if (level == map.level && !moved) return;
	self.gpu.wait_idle();
	map.fill(&self.gpu, self.target.view_extent, level, centers)!;
	io::printfn("xr: foveation %s, lens centres %.2f %.2f and %.2f %.2f", level.name,
		centers[0], centers[1], centers[2], centers[3]);
}

<*
 Where straight ahead lands across an eye's view, 0..1 from its top left: the
 eye's projection is off-axis, so the lens centre is nearer the nose.
*>
fn float[2] lens_center(xr::Fovf fov) @local
{
	float left = math::tan(fov.angle_left);
	float right = math::tan(fov.angle_right);
	float up = math::tan(fov.angle_up);
	float down = math::tan(fov.angle_down);
	float x = -(right + left) / (right - left);
	float y = -(up + down) / (up - down);
	return { (1.0f + x) * 0.5f, (1.0f - y) * 0.5f };
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
	vk::ImageView view = index < host.views.len() ? host.views[index] : (vk::ImageView)null;
	renderer.render_xr(host.images[index], view, { host.eye_width * 2, host.eye_height }, wait_ns)!;
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
	// The room goes under the scene, which is premultiplied and covers it where
	// its alpha says. A frame not drawn still shows the room.
	xr::CompositionLayerPassthroughFB room = {
		.type = xr::TYPE_COMPOSITION_LAYER_PASSTHROUGH_FB,
		.flags = xr::COMPOSITION_LAYER_BLEND_TEXTURE_SOURCE_ALPHA_BIT,
		.layer_handle = host.passthrough_layer,
	};
	xr::CompositionLayerBaseHeader*[2] layers;
	uint count;
	if (host.passthrough_running) layers[count++] = (xr::CompositionLayerBaseHeader*)&room;
	if (drawn)
	{
		if (host.passthrough_running) layer.layer_flags = xr::COMPOSITION_LAYER_BLEND_TEXTURE_SOURCE_ALPHA_BIT;
		layers[count++] = (xr::CompositionLayerBaseHeader*)&layer;
	}
	xr::FrameEndInfo end_info = {
		.type = xr::TYPE_FRAME_END_INFO,
		.display_time = frame.predicted_display_time,
		.environment_blend_mode = xr::ENVIRONMENT_BLEND_MODE_OPAQUE,
		.layer_count = count,
		.layers = count > 0 ? &layers[0] : null,
	};
	xr::check(xr::cmd.end_frame(host.session, &end_info), "xrEndFrame")!;
}
