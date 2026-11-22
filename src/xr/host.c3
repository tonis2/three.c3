<*
 The OpenXR side of a Quest run: instance, session, the space the head is
 tracked in, and the one swapchain both eyes are drawn into side by side.

 Order matters and is OpenXR's, not ours: the instance and system come first,
 because they say which Vulkan device and extensions the runtime needs; then the
 engine opens its device to that order (`vulkan_request`); then the session is
 made against that device.
*>
module three @feat(ANDROID);

import std::io;
import std::collections::list;
import xr;
import vk;
import three::ndk;

// Requested even though Quest reports more: VK_FORMAT_R8G8B8A8_SRGB, then BGRA.
const long[2] XR_COLOR_FORMATS = { 43, 50 };

struct XrHost
{
	xr::Instance instance;
	xr::SystemId system;
	xr::Session session;
	xr::Space space;
	CInt space_type;
	xr::Swapchain swapchain;
	List {vk::Image} images;
	long format;
	// One eye; the swapchain is twice as wide.
	uint eye_width;
	uint eye_height;
	CInt state;
	bool running;
	bool exit_wanted;
	// Own the strings `request` points into.
	char[] instance_extension_text;
	char[] device_extension_text;
	List {ZString} instance_extensions;
	List {ZString} device_extensions;
	VulkanRequest request;
	// The renderer's, so a script's `three.xr.refreshRate` reaches the runtime.
	XrDisplay* display;
}

<*
 Brings up the loader, the instance and the system, and records what the
 runtime wants of Vulkan in `vulkan_request`.

 @param [&inout] app : "The glue's app, for the JavaVM and the activity"
 @param render_scale : "Fraction of the runtime's recommended eye size"
 @require render_scale > 0 : "Scale must be positive"
 @return? xr::COMMAND_MISSING, xr::CALL_FAILED
*>
fn void? XrHost.open(&self, ndk::App* app, float render_scale)
{
	xr::load_global()!;
	if (xr::cmd.initialize_loader != null)
	{
		xr::LoaderInitInfoAndroidKHR loader = {
			.type = xr::TYPE_LOADER_INIT_INFO_ANDROID_KHR,
			.application_vm = app.activity.vm,
			.application_context = app.activity.clazz,
		};
		xr::check(xr::cmd.initialize_loader(&loader), "xrInitializeLoaderKHR")!;
	}

	// The two optional ones only when the runtime has them: asking for an
	// extension it lacks fails the whole instance.
	bool refresh_rate = xr::has_extension(xr::FB_DISPLAY_REFRESH_RATE_EXTENSION_NAME) ?? false;
	bool performance = xr::has_extension(xr::EXT_PERFORMANCE_SETTINGS_EXTENSION_NAME) ?? false;
	ZString[4] extensions = { "XR_KHR_vulkan_enable", "XR_KHR_android_create_instance", null, null };
	uint enabled = 2;
	if (refresh_rate) extensions[enabled++] = xr::FB_DISPLAY_REFRESH_RATE_EXTENSION_NAME;
	if (performance) extensions[enabled++] = xr::EXT_PERFORMANCE_SETTINGS_EXTENSION_NAME;
	xr::InstanceCreateInfoAndroidKHR android_info = {
		.type = xr::TYPE_INSTANCE_CREATE_INFO_ANDROID_KHR,
		.application_vm = app.activity.vm,
		.application_activity = app.activity.clazz,
	};
	xr::InstanceCreateInfo info = {
		.type = xr::TYPE_INSTANCE_CREATE_INFO,
		.next = &android_info,
		.application_info = {
			.application_name = "three.c3",
			.application_version = 1,
			.engine_name = "three.c3",
			.engine_version = 1,
			.api_version = xr::make_version(1, 0, 0),
		},
		.enabled_extension_count = enabled,
		.enabled_extension_names = &extensions[0],
	};
	xr::check(xr::cmd.create_instance(&info, &self.instance), "xrCreateInstance")!;
	xr::load_instance(self.instance)!;
	xr::load_extensions(self.instance, refresh_rate, performance);
	xr::set_result_names(self.instance);

	xr::InstanceProperties props = { .type = xr::TYPE_INSTANCE_PROPERTIES };
	if (xr::cmd.get_instance_properties(self.instance, &props) >= 0)
	{
		io::printfn("xr: runtime %s %d.%d", ((ZString)&props.runtime_name).str_view(),
			xr::version_major(props.runtime_version), xr::version_minor(props.runtime_version));
	}

	xr::SystemGetInfo system_info = { .type = xr::TYPE_SYSTEM_GET_INFO, .form_factor = xr::FORM_FACTOR_HEAD_MOUNTED_DISPLAY };
	xr::check(xr::cmd.get_system(self.instance, &system_info, &self.system), "xrGetSystem")!;

	xr::ViewConfigurationView[2] views = {
		{ .type = xr::TYPE_VIEW_CONFIGURATION_VIEW },
		{ .type = xr::TYPE_VIEW_CONFIGURATION_VIEW },
	};
	uint count;
	xr::check(xr::cmd.enumerate_view_configuration_views(self.instance, self.system,
		xr::VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO, 2, &count, &views[0]), "xrEnumerateViewConfigurationViews")!;
	self.eye_width = (uint)((float)views[0].recommended_image_rect_width * render_scale) & ~3u;
	self.eye_height = (uint)((float)views[0].recommended_image_rect_height * render_scale) & ~3u;
	io::printfn("xr: eye %dx%d recommended, rendering %dx%d",
		views[0].recommended_image_rect_width, views[0].recommended_image_rect_height, self.eye_width, self.eye_height);

	// Must be asked before a session is made, even though the engine's own
	// version choice already falls inside what Quest allows.
	xr::GraphicsRequirementsVulkanKHR requirements = { .type = xr::TYPE_GRAPHICS_REQUIREMENTS_VULKAN_KHR };
	xr::check(xr::cmd.get_vulkan_graphics_requirements(self.instance, self.system, &requirements),
		"xrGetVulkanGraphicsRequirementsKHR")!;
	io::printfn("xr: Vulkan %d.%d to %d.%d", xr::version_major(requirements.min_api_version_supported),
		xr::version_minor(requirements.min_api_version_supported),
		xr::version_major(requirements.max_api_version_supported),
		xr::version_minor(requirements.max_api_version_supported));

	self.instance_extension_text = self.extension_text(xr::cmd.get_vulkan_instance_extensions)!;
	self.device_extension_text = self.extension_text(xr::cmd.get_vulkan_device_extensions)!;
	self.instance_extensions.init(mem);
	self.device_extensions.init(mem);
	io::printfn("xr: Vulkan instance extensions: %s", ((ZString)self.instance_extension_text.ptr).str_view());
	io::printfn("xr: Vulkan device extensions: %s", ((ZString)self.device_extension_text.ptr).str_view());
	split_names(self.instance_extension_text, &self.instance_extensions);
	split_names(self.device_extension_text, &self.device_extensions);

	self.request = {
		.instance_extensions = self.instance_extensions.array_view(),
		.device_extensions = self.device_extensions.array_view(),
		.pick_device = &pick_xr_device,
		.pick_context = self,
	};
	vulkan_request = &self.request;
}

<*
 One of the KHR_vulkan_enable "space-separated list" queries, NUL-terminated.

 @return? xr::CALL_FAILED
*>
fn char[]? XrHost.extension_text(&self, xr::GetVulkanExtensionsFn query)
{
	uint needed;
	xr::check(query(self.instance, self.system, 0, &needed, null), "xrGetVulkan*ExtensionsKHR")!;
	char[] text = mem::new_array(char, (sz)needed + 1);
	xr::check(query(self.instance, self.system, needed, &needed, text.ptr), "xrGetVulkan*ExtensionsKHR")!;
	return text;
}

// Cuts "A B C" into NUL-terminated names in place.
fn void split_names(char[] text, List {ZString}* out) @local
{
	foreach (&c : text)
	{
		if (*c == ' ') *c = 0;
	}
	sz start = 0;
	foreach (i, c : text)
	{
		if (c != 0) continue;
		if (i > start) out.push((ZString)&text[start]);
		start = i + 1;
	}
}

fn vk::PhysicalDevice pick_xr_device(void* context, vk::Instance instance)
{
	XrHost* self = context;
	void* device;
	if (catch xr::check(xr::cmd.get_vulkan_graphics_device(self.instance, self.system, (void*)instance, &device),
		"xrGetVulkanGraphicsDeviceKHR")) return (vk::PhysicalDevice)null;
	return (vk::PhysicalDevice)device;
}

<*
 Makes the session against the engine's device, the reference space, and the
 swapchain.

 @param [&in] gpu : "The device the engine opened to vulkan_request"
 @return? xr::CALL_FAILED
*>
fn void? XrHost.start(&self, Gpu* gpu)
{
	xr::GraphicsBindingVulkanKHR binding = {
		.type = xr::TYPE_GRAPHICS_BINDING_VULKAN_KHR,
		.instance = (void*)gpu.instance,
		.physical_device = (void*)gpu.pdevice,
		.device = (void*)gpu.handle,
		.queue_family_index = gpu.graphics.index,
		.queue_index = 0,
	};
	xr::SessionCreateInfo session_info = { .type = xr::TYPE_SESSION_CREATE_INFO, .next = &binding, .system_id = self.system };
	xr::check(xr::cmd.create_session(self.instance, &session_info, &self.session), "xrCreateSession")!;

	self.space_type = self.pick_space()!;
	xr::ReferenceSpaceCreateInfo space_info = {
		.type = xr::TYPE_REFERENCE_SPACE_CREATE_INFO,
		.reference_space_type = self.space_type,
		.pose_in_reference_space = { .orientation = { .w = 1 } },
	};
	xr::check(xr::cmd.create_reference_space(self.session, &space_info, &self.space), "xrCreateReferenceSpace")!;
	io::printfn("xr: tracking in %s space", self.space_type == xr::REFERENCE_SPACE_TYPE_STAGE ? "stage"
		: self.space_type == xr::REFERENCE_SPACE_TYPE_LOCAL_FLOOR ? "local-floor" : "local");

	self.format = self.pick_format()!;
	xr::SwapchainCreateInfo swap_info = {
		.type = xr::TYPE_SWAPCHAIN_CREATE_INFO,
		.usage_flags = xr::SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT | xr::SWAPCHAIN_USAGE_TRANSFER_DST_BIT,
		.format = self.format,
		.sample_count = 1,
		.width = self.eye_width * 2,
		.height = self.eye_height,
		.face_count = 1,
		.array_size = 1,
		.mip_count = 1,
	};
	xr::check(xr::cmd.create_swapchain(self.session, &swap_info, &self.swapchain), "xrCreateSwapchain")!;

	uint count;
	xr::check(xr::cmd.enumerate_swapchain_images(self.swapchain, 0, &count, null), "xrEnumerateSwapchainImages")!;
	xr::SwapchainImageVulkanKHR[] found = mem::new_array(xr::SwapchainImageVulkanKHR, count);
	defer free(found);
	foreach (&image : found) image.type = xr::TYPE_SWAPCHAIN_IMAGE_VULKAN_KHR;
	xr::check(xr::cmd.enumerate_swapchain_images(self.swapchain, count, &count, found.ptr), "xrEnumerateSwapchainImages")!;
	self.images.init(mem);
	foreach (image : found) self.images.push((vk::Image)image.image);
	io::printfn("xr: swapchain %dx%d, format %d, %d images", self.eye_width * 2, self.eye_height, self.format, count);
}

<*
 Stage when the guardian has one, floor-level local otherwise, plain local last.

 @return? xr::CALL_FAILED
*>
fn CInt? XrHost.pick_space(&self)
{
	uint count;
	xr::check(xr::cmd.enumerate_reference_spaces(self.session, 0, &count, null), "xrEnumerateReferenceSpaces")!;
	CInt[] spaces = mem::new_array(CInt, count);
	defer free(spaces);
	xr::check(xr::cmd.enumerate_reference_spaces(self.session, count, &count, spaces.ptr), "xrEnumerateReferenceSpaces")!;
	CInt[3] preferred = { xr::REFERENCE_SPACE_TYPE_STAGE, xr::REFERENCE_SPACE_TYPE_LOCAL_FLOOR, xr::REFERENCE_SPACE_TYPE_LOCAL };
	foreach (want : preferred)
	{
		foreach (have : spaces)
		{
			if (have == want) return want;
		}
	}
	return xr::REFERENCE_SPACE_TYPE_LOCAL;
}

<*
 @return? xr::CALL_FAILED
*>
fn long? XrHost.pick_format(&self)
{
	uint count;
	xr::check(xr::cmd.enumerate_swapchain_formats(self.session, 0, &count, null), "xrEnumerateSwapchainFormats")!;
	long[] formats = mem::new_array(long, count);
	defer free(formats);
	xr::check(xr::cmd.enumerate_swapchain_formats(self.session, count, &count, formats.ptr), "xrEnumerateSwapchainFormats")!;
	foreach (want : XR_COLOR_FORMATS)
	{
		foreach (have : formats)
		{
			if (have == want) return want;
		}
	}
	io::eprintn("xr: no sRGB swapchain format offered; using the runtime's first");
	return formats.len > 0 ? formats[0] : XR_COLOR_FORMATS[0];
}

<*
 Drains the runtime's events and follows the session through its states:
 begin when READY, end when STOPPING, give up when EXITING or LOSS_PENDING.
*>
fn void XrHost.poll(&self)
{
	while (true)
	{
		xr::EventDataBuffer event = { .type = xr::TYPE_EVENT_DATA_BUFFER };
		xr::Result r = xr::cmd.poll_event(self.instance, &event);
		if (r != xr::SUCCESS) return;
		switch (event.type)
		{
			case xr::TYPE_EVENT_DATA_INSTANCE_LOSS_PENDING:
				io::printn("xr: instance loss pending");
				self.exit_wanted = true;
			case xr::TYPE_EVENT_DATA_SESSION_STATE_CHANGED:
				xr::EventDataSessionStateChanged* changed = (xr::EventDataSessionStateChanged*)&event;
				self.state = changed.state;
				io::printfn("xr: session state %d", self.state);
				self.follow_state();
			case xr::TYPE_EVENT_DATA_DISPLAY_REFRESH_RATE_CHANGED_FB:
				xr::EventDataDisplayRefreshRateChangedFB* rate = (xr::EventDataDisplayRefreshRateChangedFB*)&event;
				io::printfn("xr: display now %.0f Hz, was %.0f", rate.to_display_refresh_rate, rate.from_display_refresh_rate);
				if (self.display != null) self.display.now = rate.to_display_refresh_rate;
			default:
		}
	}
}

fn void XrHost.follow_state(&self)
{
	switch (self.state)
	{
		case xr::SESSION_STATE_READY:
			xr::SessionBeginInfo begin = {
				.type = xr::TYPE_SESSION_BEGIN_INFO,
				.primary_view_configuration_type = xr::VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO,
			};
			self.running = @ok(xr::check(xr::cmd.begin_session(self.session, &begin), "xrBeginSession"));
			if (self.running) self.tune_session();
		case xr::SESSION_STATE_FOCUSED:
			self.report_refresh_rates();
		case xr::SESSION_STATE_STOPPING:
			(void)xr::check(xr::cmd.end_session(self.session), "xrEndSession");
			self.running = false;
		case xr::SESSION_STATE_EXITING:
		case xr::SESSION_STATE_LOSS_PENDING:
			self.exit_wanted = true;
		default:
	}
}

<*
 Asks for sustained-high CPU and GPU clocks, where the runtime has the extension
 for it. A failure is logged and otherwise ignored: the session runs either way,
 just slower.
*>
fn void XrHost.tune_session(&self)
{
	if (xr::cmd.perf_settings_set_performance_level != null)
	{
		bool cpu = @ok(xr::check(xr::cmd.perf_settings_set_performance_level(self.session,
			xr::PERF_SETTINGS_DOMAIN_CPU, xr::PERF_SETTINGS_LEVEL_SUSTAINED_HIGH), "xrPerfSettingsSetPerformanceLevelEXT"));
		bool gpu = @ok(xr::check(xr::cmd.perf_settings_set_performance_level(self.session,
			xr::PERF_SETTINGS_DOMAIN_GPU, xr::PERF_SETTINGS_LEVEL_SUSTAINED_HIGH), "xrPerfSettingsSetPerformanceLevelEXT"));
		if (cpu && gpu) io::printn("xr: CPU and GPU at sustained high");
	}
}

<*
 Logs the display rates the runtime offers and the one it runs at, and keeps
 both in `display` for scripts to read.
*>
fn void XrHost.report_refresh_rates(&self)
{
	if (xr::cmd.enumerate_display_refresh_rates == null) return;
	float[16] rates;
	uint count;
	if (catch xr::check(xr::cmd.enumerate_display_refresh_rates(self.session, rates.len, &count, &rates[0]),
		"xrEnumerateDisplayRefreshRatesFB")) return;
	foreach (rate : rates[:count]) io::printfn("xr: display offers %.0f Hz", rate);
	float now;
	if (xr::cmd.get_display_refresh_rate(self.session, &now) >= 0) io::printfn("xr: display at %.0f Hz", now);
	if (self.display == null) return;
	self.display.offered_count = min(count, (uint)self.display.offered.len);
	self.display.offered[:self.display.offered_count] = rates[:self.display.offered_count];
	self.display.now = now;
}

<*
 Passes a changed `three.xr.refreshRate` to the runtime, snapped to a rate it
 offers. The switch lands a few frames later, with the changed event.

 The `debug.oculus.refreshRate` system property overrides any request:
 `adb shell setprop debug.oculus.refreshRate ""` clears it.
*>
fn void XrHost.apply_refresh_rate(&self)
{
	if (self.display == null || !self.running || xr::cmd.request_display_refresh_rate == null) return;
	XrDisplay* display = self.display;
	// Waits for FOCUSED to list the rates, so a request is always one of them.
	if (display.wanted == display.requested || display.offered_count == 0) return;
	display.requested = display.wanted;
	float hz = display.wanted > 0 ? display.nearest_offered(display.wanted) : 0;
	if (catch xr::check(xr::cmd.request_display_refresh_rate(self.session, hz), "xrRequestDisplayRefreshRateFB")) return;
	io::printfn("xr: asked for %.0f Hz", hz);
}

// Asks the runtime to wind the session down; `poll` sees it through.
fn void XrHost.request_exit(&self)
{
	if (self.session != null && self.running)
	{
		(void)xr::check(xr::cmd.request_exit_session(self.session), "xrRequestExitSession");
		return;
	}
	self.exit_wanted = true;
}

fn void XrHost.close(&self)
{
	if (self.swapchain != null) xr::cmd.destroy_swapchain(self.swapchain);
	if (self.space != null) xr::cmd.destroy_space(self.space);
	if (self.session != null) xr::cmd.destroy_session(self.session);
	if (self.instance != null) xr::cmd.destroy_instance(self.instance);
	self.images.free();
	self.instance_extensions.free();
	self.device_extensions.free();
	free(self.instance_extension_text);
	free(self.device_extension_text);
	if (vulkan_request == &self.request) vulkan_request = null;
	*self = {};
}
