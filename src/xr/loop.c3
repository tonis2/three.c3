<*
 The XR frame loop: OpenXR's wait, begin, locate, draw and end around the
 engine's own tick, with both eyes drawn in one pass.

 The right eye is an extra `SceneView` beside the main camera, so geometry,
 lights and shadows are prepared once for both. Each eye gets its own light
 clusters and AO. On a multiview target every draw reaches both eyes, each
 into its own layer, and each layer goes to the swapchain's layer for that eye:
 written by the scene itself with MSAA, otherwise toned and copied there.
 Without multiview each eye is drawn over its half of the target in turn, and
 the tonemap puts them side by side in the swapchain image.
*>
module three @feat(ANDROID);

import std::io;
import std::time;
import std::math;
import std::math::vector;
import xr;
import vk;
import three::ndk;

<*
 The eye size to render at: XR_RENDER_SCALE (`gpu/headset.c3`), unless `adb shell setprop
 debug.three.xr_scale 0.9` asks for another between 0.4 and 1.5. Read once, when
 the app starts, because the swapchain is made at that size; restart the app to
 try the next one. It is how a game finds what its scene can afford on the
 headset without rebuilding the engine for each try.
*>
fn float xr_render_scale()
{
	String asked = ndk::property("debug.three.xr_scale");
	if (asked.len == 0) return XR_RENDER_SCALE;
	float? scale = asked.trim().to_float();
	if (catch scale)
	{
		io::eprintfn("xr: debug.three.xr_scale is %s, not a number; rendering at %.2f", asked, XR_RENDER_SCALE);
		return XR_RENDER_SCALE;
	}
	if (scale < 0.4f || scale > 1.5f)
	{
		io::eprintfn("xr: debug.three.xr_scale %.2f is outside 0.4 to 1.5; rendering at %.2f", scale, XR_RENDER_SCALE);
		return XR_RENDER_SCALE;
	}
	io::printfn("xr: debug.three.xr_scale asks for %.2f of the recommended eye size", scale);
	return scale;
}

<*
 The eyes' samples per pixel: XR_MSAA (`gpu/headset.c3`), unless `adb shell setprop debug.three.msaa`
 asks for 1 (none), 2 or 4. Read once, when the app starts.
*>
fn uint xr_msaa()
{
	String asked = ndk::property("debug.three.msaa").trim();
	switch (asked)
	{
		case "": return XR_MSAA;
		case "1": return 1;
		case "2": return 2;
		case "4": return 4;
	}
	io::eprintfn("xr: debug.three.msaa is %s, not 1, 2 or 4; %dx MSAA", asked, XR_MSAA);
	return XR_MSAA;
}

<*
 How the compositor filters the eye images as it scales them to the display:
 Meta Quest Super Resolution, an upscale and sharpen that costs the compositor
 about 0.15 ms, because the eyes are always drawn below the display's size.
 `adb shell setprop debug.three.xr_filter` asks for `none` (bilinear), `sharpen`
 (normal sharpening) or `auto` (Super Resolution where the runtime thinks it
 helps) instead. Read once, when the app starts.
*>
fn CompositionLayerSettingsFlagsFB xr_layer_filter()
{
	String asked = ndk::property("debug.three.xr_filter").trim();
	switch (asked)
	{
		case "":
		case "super": return QUALITY_SHARPENING;
		case "none": return {};
		case "sharpen": return NORMAL_SHARPENING;
		case "auto": return QUALITY_SHARPENING | AUTO_LAYER_FILTER;
	}
	io::eprintfn("xr: debug.three.xr_filter is %s, not none, sharpen, super or auto; Super Resolution", asked);
	return QUALITY_SHARPENING;
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
	XrFrameStats stats;

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
		Clock pacing = clock::now();
		xr::check(xr::cmd.wait_frame(host.session, &wait_info, &frame), "xrWaitFrame")!;
		xr::FrameBeginInfo begin_info = { .type = xr::TYPE_FRAME_BEGIN_INFO };
		xr::check(xr::cmd.begin_frame(host.session, &begin_info), "xrBeginFrame")!;
		stats.paced_ns += (long)pacing.to_now();

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
		stats.script_ns += runtime.frame_spend.script_ns();
		stats.solver_ns += runtime.frame_spend.solver_ns;
		stats.engine_ns += runtime.frame_spend.host_ns;

		end_frame(host, &frame, &views, drawn)!;
		print_frame_output(runtime, &said);
		if (runtime.quit_wanted) host.request_exit();

		if (drawn)
		{
			stats.frames_drawn++;
			FrameTiming gpu = renderer.timing();
			stats.gpu_sum.total += gpu.total;
			stats.gpu_sum.prepare += gpu.prepare;
			stats.gpu_sum.shadow += gpu.shadow;
			stats.gpu_sum.occlusion += gpu.occlusion;
			stats.gpu_sum.prepass += gpu.prepass;
			stats.gpu_sum.scene += gpu.scene;
			stats.gpu_sum.post += gpu.post;
			stats.gpu_sum.present += gpu.present;
			stats.drawn_calls += renderer.pass.drawn_calls;
			stats.drawn_instances += renderer.pass.drawn_instances;
			stats.drawn_triangles += renderer.pass.drawn_triangles;
		}
		stats.busy_ns += (long)busy.to_now() - wait_ns;
		stats.waited_ns += wait_ns;
		long since_ns = (long)report_since.to_now();
		if (since_ns >= 5_000_000_000)
		{
			double seconds = (double)since_ns / 1e9;
			double n = stats.frames_drawn > 0 ? (double)stats.frames_drawn : 1.0;
			io::printfn("xr: %.1f fps, cpu %.2f ms, fence wait %.2f ms, gpu %.2f ms (prepare %.2f, shadow %.2f, ao %.2f, prepass %.2f, scene %.2f, post %.2f, present %.2f), hands L:%s R:%s",
				stats.frames_drawn / seconds, (double)stats.busy_ns / 1e6 / n, (double)stats.waited_ns / 1e6 / n,
				stats.gpu_sum.total / n, stats.gpu_sum.prepare / n, stats.gpu_sum.shadow / n, stats.gpu_sum.occlusion / n,
				stats.gpu_sum.prepass / n, stats.gpu_sum.scene / n, stats.gpu_sum.post / n, stats.gpu_sum.present / n,
				hand_word(&runtime.hands, Hand.LEFT), hand_word(&runtime.hands, Hand.RIGHT));
			// The engine part also holds xrWaitSwapchainImage and the submit; the
			// pacing wait is xrWaitFrame and xrBeginFrame, outside "cpu" above.
			io::printfn("xr: cpu split: js %.2f ms (solver %.2f), engine %.2f ms, paced %.2f ms; drawn %.0f calls, %.0f copies, %.0fk triangles",
				(double)stats.script_ns / 1e6 / n, (double)stats.solver_ns / 1e6 / n, (double)stats.engine_ns / 1e6 / n, (double)stats.paced_ns / 1e6 / n,
				(double)stats.drawn_calls / n, (double)stats.drawn_instances / n, (double)stats.drawn_triangles / 1e3 / n);
			report_since = clock::now();
			stats = {};
		}
	}
}

struct XrFrameStats @local
{
	uint frames_drawn;
	long busy_ns;
	long waited_ns;
	FrameTiming gpu_sum;
	long script_ns;
	long solver_ns;
	long engine_ns;
	long paced_ns;
	ulong drawn_calls;
	ulong drawn_instances;
	ulong drawn_triangles;
}
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
	xr::Fovf fov = views[0].fov;
	io::printfn("xr: left eye fov %.4f %.4f %.4f %.4f rad (left, right, up, down)",
		fov.angle_left, fov.angle_right, fov.angle_up, fov.angle_down);
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
	bool eyes = host.layers > 1;
	renderer.render_into(host.images[index], view, { eyes ? host.eye_width : host.eye_width * 2, host.eye_height },
		eyes, renderer.xr_display.passthrough_active, wait_ns)!;
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
					.offset = { host.layers > 1 ? 0 : (int)(i * host.eye_width), 0 },
					.extent = { (int)host.eye_width, (int)host.eye_height },
				},
				.image_array_index = host.layers > 1 ? (uint)i : 0,
			},
		};
	}
	xr::CompositionLayerSettingsFB filter = {
		.type = xr::TYPE_COMPOSITION_LAYER_SETTINGS_FB,
		.layer_flags = host.layer_filter,
	};
	xr::CompositionLayerProjection layer = {
		.type = xr::TYPE_COMPOSITION_LAYER_PROJECTION,
		.next = host.layer_filter ? &filter : null,
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
