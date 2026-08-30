<*
 Instance, physical device selection, logical device, queues, allocator.

 ## Scalar block layout on this machine

 Measured on an Apple M5 against the KosmicKrisp vulkan.c3l bundles:

 scalarBlockLayout    true
 bufferDeviceAddress  true
 dynamicRendering     true
 pushDescriptor       true       <- no descriptor pools anywhere
 fillModeNonSolid     false      <- wireframes are line-list index buffers
 maxPushConstantsSize 256        <- budget stays 128, the portable minimum

 So `-force-glsl-scalar-layout` is legal here and the `float4`-never-`float3` tax
 does not apply. It is still queried rather than assumed
 (`Gpu.limits.scalar_block_layout`) and printed by `Gpu.report`: versions differ,
 a checkout without the bundled driver runs on whatever ICD the loader discovers,
 and a driver that gained `fillModeNonSolid` would still have to be asked.
 Nothing in this project may read any of these at compile time.

 ## KosmicKrisp only — MoltenVK is not supported

 The driver is the one vulkan.c3l bundles: KosmicKrisp, a conformant Vulkan 1.3
 implementation on Metal. Nothing here is written against the portability subset,
 so a portability implementation is turned away rather than partly accommodated,
 in two places that cost nothing:

 - `create_instance` does not enable `VK_KHR_portability_enumeration`, so the
 loader never enumerates their physical devices;
 - `select_device` skips any device advertising `VK_KHR_portability_subset`, and
 says so through `PORTABILITY_DRIVER_ONLY` when that leaves nothing.

 On macOS a checkout without the bundled driver needs an installed KosmicKrisp;
 an installed MoltenVK is not a fallback.

 ## Validation goes to the script, not to stdout

 A message printed to a terminal is invisible to the agent that caused it, and
 the agent is the only caller that can act on it — so validation errors are
 routed into the thrown JS exception.

 The messenger below is this project's rather than `vk::setupDebugMessenger`, for
 three reasons that one cannot give: it carries a `pUserData`, so the callback
 can reach somewhere other than stdout; it drops VERBOSE, which the vendored one
 subscribes to only in order to print it; and it keeps `pMessageIdName`, which is
 the difference between a message an agent can look up and one it can only read.

 The sink is single-threaded, and that is an assumption rather than a guarantee.
 The spec allows the driver to call the messenger on any thread. Here every
 Vulkan call is made from the one thread that owns the loop (`main.c3`,
 `mcp/server.c3`), so the callback arrives on that thread too and the sink is not
 locked. A future worker thread submitting work would have to bring a lock.
*>
module three;

import std::io;
import std::collections::list;
import vk;

faultdef
	NO_BUFFER_DEVICE_ADDRESS, NO_DYNAMIC_RENDERING, NO_PUSH_DESCRIPTOR, NO_SUITABLE_GPU, PORTABILITY_DRIVER_ONLY;

<*
 What the selected device actually reports. Nothing optional is assumed: the
 bundled driver and an installed one are different builds, and neither promises
 the other's optional features.
*>
struct GpuLimits
{
	bool scalar_block_layout;
	bool buffer_device_address;
	bool dynamic_rendering;
	bool push_descriptor;
	bool fill_mode_non_solid;
	uint max_push_constants_size;
	// Nanoseconds per timestamp tick. Meaningless unless `timestamps` is true — a
	// device that cannot write a timestamp may report anything here.
	float timestamp_period;
	// Both halves, because `gpu/timing.c3` needs both. The queue has to be able to
	// write a timestamp at all (`timestampComputeAndGraphics`), and the host has
	// to be able to recycle the query without a command buffer (`hostQueryReset`)
	// — resetting from the host is what lets the reset sit beside the fence wait
	// instead of inside the recording, where it would have to be ordered against a
	// submission that has not happened yet.
	bool timestamps;
	// What the *device* reports, not what `create_instance` asked for. The
	// instance's `apiVersion` is a ceiling; this is the answer, and it decides
	// whether a 1.4 core feature struct may be chained into `deviceCreateInfo` at
	// all — handing one to a 1.3 device is invalid usage rather than a struct it
	// politely walks past.
	uint api_version;
	// `dynamicRenderingLocalRead`, core in 1.4: reading an attachment written
	// earlier in the same `cmdBeginRendering` block, at the same pixel. Enabled
	// wherever it is offered and used by nothing yet — it is what would fuse the
	// pointwise post passes, at no image and no barrier.
	bool dynamic_rendering_local_read;
	char[256] device_name;
}

<*
 The Vulkan version the instance asks for.

 `apiVersion` is a ceiling, not a demand, and the natural reading is the opposite
 one. It declares the highest version this code is written against; a device
 reporting less still works and simply may not be handed 1.4 core entry points,
 which is what `GpuLimits.api_version` is read for. Raising this does not narrow
 what `select_device` accepts.

 The one loader that would refuse is a Vulkan 1.0 one — implementations at 1.1
 and above must not return `ERROR_INCOMPATIBLE_DRIVER` for *any* `apiVersion` —
 and it is detected the way the spec says to: `vkEnumerateInstanceVersion` is
 simply absent from a 1.0 loader. Asking and taking the lower of the two costs
 one call at startup.
*>
fn uint wanted_api_version()
{
	const uint V1_0 = vk::@makeApiVersion(0, 1, 0, 0);
	const uint V1_4 = vk::@makeApiVersion(0, 1, 4, 0);

	if (vk::vkEnumerateInstanceVersion == null) return V1_0;

	uint loader;
	if (catch vk::enumerateInstanceVersion(&loader)) return V1_0;
	return loader < V1_4 ? loader : V1_4;
}

// The layer that produces the messages, and the instance extension that carries
// them. Named once because `create_instance` asks whether the first is installed
// and `Gpu.init` asks whether the second was enabled.
const ZString VALIDATION_LAYER              = "VK_LAYER_KHRONOS_validation";
const ZString DEBUG_UTILS_EXTENSION         = "VK_EXT_debug_utils";
// What lets `VkValidationFeaturesEXT` be chained onto the instance. Requested
// only alongside `sync`, because that struct is the only thing here that uses it.
const ZString VALIDATION_FEATURES_EXTENSION = "VK_EXT_validation_features";

// Spelled out because vulkan.c3l declares the severity bits in a `constdef`,
// whose members are only visible unqualified inside module vk. Every other use
// here is inferred from a builder's parameter type; this one is a comparison and
// has nothing to infer from.
const uint SEVERITY_ERROR @local = (uint)vk::DebugUtilsMessageSeverityFlagBitsEXT
	.DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT;

<*
 What the debug messenger heard, kept apart by severity.

 Two buffers rather than one tagged buffer because the two are answered with
 differently: an ERROR becomes the exception the script gets back, a WARNING
 becomes a line in its log. One buffer would mean the runtime parsing its own
 text back out to tell them apart.

 Null and unallocated when validation is off. The messenger that fills this does
 not exist then, and every `DString` call used here is null-safe.
*>
struct ValidationSink
{
	DString errors;
	DString warnings;
	// Armed for the length of one script run and nothing else. Off means print.
	bool capturing;
}

struct Gpu
{
	vk::Instance instance;
	vk::DebugUtilsMessengerEXT debug;
	// Externally owned: created from the window, freed by whoever made it. Null in
	// headless mode, and every path here has to cope with that.
	vk::SurfaceKHR surface;
	vk::PhysicalDevice pdevice;
	vk::Device handle;
	vk::DeviceQueue graphics;
	vk::MemoryAllocator allocator;
	GpuLimits limits;
	// Whether validation is *running*, not whether it was asked for. A machine
	// with no Khronos layer installed sets this false even in a `-D DEBUG` build,
	// and `js/runtime.c3` reads it to decide whether there is a sink worth arming.
	bool validation;
	ValidationSink sink;
	// GPU objects given back but not yet destroyable — see `gpu/retire.c3`. Lives
	// on the device rather than on whatever owns the objects, because the frames
	// in flight are a property of the device and two owners retiring into two
	// queues would each have to be swept from the frame loop separately.
	DeletionQueue deletions;
	// The driver's own `VkPipelineCache`, warmed off disk — `gpu/driver_cache.c3`.
	// On the device for the same reason the queue is, and a stronger one: its
	// validity *is* the device's `pipelineCacheUUID`.
	DriverCache driver_cache;
}

<*
 Is the Khronos validation layer installed on this machine?

 Asked rather than assumed. `vkCreateInstance` fails outright with
 ERROR_LAYER_NOT_PRESENT when handed a layer that is not there, so naming the
 layer unconditionally would mean a machine without the Vulkan SDK cannot start
 three.c3 at all. A machine that cannot run the diagnostics should still run the
 scripts.

 Not cached. It is only asked when validation was requested, it costs one
 enumeration at startup, and a `false` cached from before `vk::init()` bound the
 loader would be a lie with no expiry.

 This is also the one lock `-D DEBUG` turns. Without a debug build the answer is
 false whatever is installed, and that is deliberately the only place the build
 flag is read on this path: `create_instance` gates the layer and the extension
 on it, `Gpu.init` gates the messenger on it, and both go on asking the same
 question. Three separate `$if`s would be three places that could each forget.
*>
fn bool validation_layer_present()
{
	$if !DEBUG_BUILD:
		// Installed or not, there is nothing here to report to: the messenger, the
		// sink and the callback are all compiled out below.
		return false;
	$else
		vk::StringList? installed = vk::getValidationLayers();
		if (catch err = installed) return false;
		defer installed.release();
		return installed.contains(VALIDATION_LAYER.str_view());
	$endif
}

<*
 The instance extensions three.c3 always wants: the platform surface extension
 and `VK_KHR_surface` itself. Headless drops both — see `create_instance`.
*>
fn void push_surface_extensions(vk::ZStringList* out)
{
	out.push_all(vk::DEFAULT_EXTENSIONS);
	out.push("VK_KHR_surface");
}

<*
 Creates the Vulkan instance.

 `vk::init()` comes first and is not negotiable: every Vulkan command in these
 bindings is a runtime-loaded pointer, and calling one before the loader is bound
 is a null-pointer crash that reads like a broken driver.

 No portability implementation is asked for or accepted — see the note on
 `VK_KHR_portability_enumeration` below.

 Validation is a request, not an instruction: a layer that is not installed is
 skipped with a line on stdout rather than failing the instance.

 The driver vulkan.c3l ships is preferred over whatever the loader discovers,
 which is deterministic and so makes screenshots reproducible across machines. A
 checkout without one falls back to loader discovery, and says so.

 @param validate : `Ask for the Khronos validation layer and VK_EXT_debug_utils. Honoured only if the layer is installed. main.c3 passes DEBUG_BUILD — there is no flag for it — and the suite passes false except where a test is checking the layer's own output.`
 @param headless : `Skip the surface extensions entirely — nothing will present.`
*>
fn vk::Instance? create_instance(bool validate, bool headless = false, bool sync = false)
{
	vk::init()!;

	// Both the layer and the extension are gated on the same answer. Without the
	// layer nothing produces a validation message, so a debug messenger with
	// nothing to say is not worth an extension.
	bool validating = validate && validation_layer_present();
	if (validate && !validating)
	{
		// Two different failures wearing the same face: in a debug build the layer
		// is missing from the machine and the fix is to install the SDK; in a
		// release build the machinery is not in the binary and the layer being
		// installed changes nothing.
		// 
		// The second is unreachable from `main`, which passes `DEBUG_BUILD`. It is
		// kept for the caller that is not `main` — a test, or anything embedding
		// this.
		$if DEBUG_BUILD:
			io::printfn("three: %s is not installed — running without validation", VALIDATION_LAYER);
		$else
			io::printn("three: built without -D DEBUG — validation layers are not compiled in");
		$endif
	}

	vk::ZStringList extensions;
	defer extensions.free();
	if (!headless) push_surface_extensions(&extensions);
	if (validating) extensions.push(DEBUG_UTILS_EXTENSION);
	// The struct chained onto `pNext` below is only read if this is enabled —
	// without it the request is silently ignored and the layer runs with its
	// ordinary checks, which is a synchronization check that checks nothing.
	if (validating && sync) extensions.push(VALIDATION_FEATURES_EXTENSION);

	// VK_KHR_portability_enumeration is deliberately *not* requested, and its
	// instance flag deliberately not set. That flag is the spec's own switch for
	// "I accept portability implementations", and without it the loader does not
	// enumerate their physical devices at all. It is how MoltenVK is kept out.

	// Both structs are read by vkCreateInstance, so they must outlive the
	// build() call below — function scope, not the `if`.
	vk::DirectDriverLoadingInfoLUNARG driver_info;
	vk::DirectDriverLoadingListLUNARG driver_list;
	bool direct_driver = false;

	if (try icd = vk::findBundledDriver())
	{
		if (vk::supportsDirectDriverLoading())
		{
			driver_info = vk::directDriverInfo(icd);
			driver_list = vk::directDriverList(&driver_info, 1);
			extensions.push(vk::DIRECT_DRIVER_LOADING_EXTENSION_NAME);
			direct_driver = true;
			@debug_log("driver: bundled, handed to the loader directly");
		}
		else
		{
			@debug_log("driver: bundled one found, but this loader cannot be handed one");
		}
	}
	else
	{
		// The `./setup.sh driver` case, and worth a line: a missing bundled driver
		// is not an error — the loader falls back to whatever ICD it discovers —
		// so nothing else anywhere says which driver drew the picture.
		@debug_log("driver: no bundled one; using whatever the loader discovers");
	}

	// Only meaningful against drivers the loader already discovered: instance
	// extensions are enumerated before the instance exists, so a driver handed
	// over at create time is invisible to this check.
	if (!direct_driver) vk::checkInstanceExtensionSupport(extensions)!;

	vk::ApplicationInfo app_info = {
		.pApplicationName = "three.c3",
		.pEngineName = "three.c3",
		.applicationVersion = vk::@makeApiVersion(0, 0, 1, 0),
		.engineVersion = vk::@makeApiVersion(0, 0, 1, 0),
		.apiVersion = wanted_api_version(),
	};

	vk::InstanceCreateInfo info = vk::instanceCreateInfo().setApplicationInfo(&app_info);
	// Guarded because the list really can be empty — headless, no validation, no
	// bundled driver asks for nothing at all — and the builder takes `&names[0]`,
	// which is an out-of-bounds panic on an empty slice rather than a null count.
	if (extensions.len() > 0) info = info.setEnabledExtensionNames(extensions.array_view());

	vk::ZStringList layers;
	defer layers.free();
	if (validating)
	{
		layers.push(VALIDATION_LAYER);
		info = info.setEnabledLayerNames(layers.array_view());
	}

	if (direct_driver)
	{
		driver_list.pNext = info.pNext;
		info.pNext = &driver_list;
	}

	// Synchronization validation — asked for, and it does not answer here.
	// 
	// The ordinary layer checks that every call is *well formed*: the right
	// handles, the right layouts, arguments in range. It does not check that a
	// write is ordered against the read that follows it, so a missing
	// `vkCmdPipelineBarrier2` produces no message at all and a picture that is
	// correct on whichever driver happened to finish first.
	// 
	// Measured, and the measurement is negative: deleting the barrier at the end
	// of `MeshPass.skin` left the skinning checks green with this off, with it on,
	// and with `VK_EXT_validation_features` enabled so the struct below was really
	// read.
	// 
	// That is history rather than something the suite re-derives. The check that
	// recorded it asked for the extension at instance creation and the loader here
	// answers "Extension not supported VK_EXT_validation_features", so it failed
	// for the machine rather than for the code and has been removed. Nothing in
	// the suite passes `sync: true` today.
	// 
	// Kept because it is the documented way to ask, it costs nothing when nobody
	// asks, and a layer that reports nothing today may report something tomorrow.
	// What must not happen is a *check* claiming to rest on it.
	// 
	// Function scope, like the two driver structs above: `vkCreateInstance` reads
	// through `pNext` after this returns from the `if`.
	vk::ValidationFeatureEnableEXT[1] sync_features = { VALIDATION_FEATURE_ENABLE_SYNCHRONIZATION_VALIDATION_EXT };
	vk::ValidationFeaturesEXT features;
	if (validating && sync)
	{
		features = vk::validationFeaturesEXT().setEnabledValidationFeatures(sync_features[..]);
		features.pNext = info.pNext;
		info.pNext = &features;
	}

	return info.build();
}

<*
 Picks a physical device.

 `vk::selectPhysicalDevice` would do this, but it dereferences the surface to
 check present support and three.c3 has to work with no surface at all. So: same
 shape, surface check skipped when there is none, and portability
 implementations turned away.

 @return ? PORTABILITY_DRIVER_ONLY : `Every device on offer was a portability implementation. Distinguished from NO_SUITABLE_GPU because the fix is a different driver, not different code.`
 @return ? NO_SUITABLE_GPU : `No device has a graphics queue, the required extensions, and present support for the surface.`
*>
fn vk::DeviceSelection? select_device(vk::Instance instance, vk::SurfaceKHR surface, vk::ZStringList extensions)
{
	vk::DeviceList devices = instance.getDevices()!;
	defer devices.free();

	vk::DeviceSelection best;
	bool found          = false;
	bool found_discrete = false;
	uint portability    = 0;

	foreach (candidate : devices)
	{
		// A portability implementation advertises VK_KHR_portability_subset, and
		// on this platform that means MoltenVK, which three.c3 does not support.
		// 
		// Leaving VK_KHR_portability_enumeration off the instance already keeps
		// these out of the enumeration. This is the second lock: a driver handed
		// to the loader directly did not go through that filter.
		vk::StringList available = vk::getDeviceExtensions(candidate)!;
		defer available.release();
		if (available.contains("VK_KHR_portability_subset"))
		{
			portability++;
			continue;
		}

		if (extensions.len() > 0)
		{
			if (!candidate.checkExtensionSupport(extensions)!) continue;
		}

		vk::QueuePropertiesList queues = candidate.getQueueProperties()!;
		defer queues.free();

		int graphics = queues.find(
			fn (
				sz index,
				vk::QueueFamilyProperties props
			) => (uint)((vk::QueueFlagBits)props.queueFlags & QUEUE_GRAPHICS_BIT) != 0
		);
		if (graphics < 0) continue;

		if (surface != null && !surface.checkSurfaceSupport((sz)graphics, candidate)!) continue;

		vk::PhysicalDeviceProperties properties;
		vk::getPhysicalDeviceProperties(candidate, &properties);
		bool is_discrete = properties.deviceType == PHYSICAL_DEVICE_TYPE_DISCRETE_GPU;

		if (!found || (is_discrete && !found_discrete))
		{
			best = {
				.device = candidate,
				.graphics_queue_index = (uint)graphics,
				.present_queue_index = (uint)graphics,
				.transfer_queue_index = (uint)graphics,
			};
			found = true;
			found_discrete = is_discrete;
		}
	}

	if (!found) return portability > 0 ? PORTABILITY_DRIVER_ONLY~ : NO_SUITABLE_GPU~;
	return best;
}

<*
 Brings up the logical device, its queue and its allocator.

 @param surface : `Null for headless. With one, VK_KHR_swapchain is required of the device; without, it is not asked for.`
 @param validate : `Must be the same answer create_instance was given. Vulkan has no way to ask an instance what it enabled, so this is taken on trust and then checked against what is installed.`
 @return ? NO_BUFFER_DEVICE_ADDRESS : `Geometry reaches the shader through buffer device addresses; there is no vertex-input fallback to degrade to.`
 @return ? NO_DYNAMIC_RENDERING : `There is no VkRenderPass anywhere in this project, by decision.`
 @return ? NO_PUSH_DESCRIPTOR : `There are no descriptor pools and no descriptor sets here at all — the draw loop names the image and the sampler inline. Required rather than probed and worked around, for the same reason dynamic rendering is: it is baseline on every driver this targets, and a fallback path would be a second renderer nobody exercises.`
*>
fn Gpu? Gpu.init(&self, vk::Instance instance, vk::SurfaceKHR surface, bool validate = false)
{
	self.instance = instance;
	self.surface = surface;
	// Before anything below can fail. `Gpu.free` runs on a partially initialised
	// device and walks this list, and a list is only safe to walk once it owns its
	// storage.
	self.deletions.init();

	// Asked twice, because neither question is sufficient on its own.
	// 
	// The layer probe is the same one `create_instance` used, repeated rather than
	// remembered: there is no way to ask an instance which extensions it was
	// created with, so `validate` here is a *claim* about what `create_instance`
	// was told, and installing a messenger on an instance without
	// VK_EXT_debug_utils is undefined rather than an error.
	// 
	// The entry point is the second lock. It cannot be the only one — the loader
	// resolves instance-extension commands it knows about whether or not the
	// caller enabled them — but a null here is conclusive the other way.
	self.validation = validate && validation_layer_present() && vk::extensions.vkCreateDebugUtilsMessengerEXT != null;
	if (self.validation) self.install_debug_messenger()!;

	vk::ZStringList extensions;
	defer extensions.free();
	if (surface != null) extensions.push("VK_KHR_swapchain");
	extensions.push("VK_KHR_dynamic_rendering");
	extensions.push("VK_KHR_push_descriptor");

	vk::DeviceSelection selection = select_device(instance, surface, extensions)!;
	self.pdevice = selection.device;
	self.graphics = { .index = selection.graphics_queue_index };

	// Nothing is added to `extensions` here. A device that advertises
	// VK_KHR_portability_subset would have to have it enabled, but no such device
	// gets this far: `select_device` turns them away.

	// Through properties2 rather than the v1 call, because that is the only way to
	// reach `maxPushDescriptors`. A device without VK_KHR_push_descriptor walks
	// past the struct it has never heard of and leaves it as it was, so the zero
	// this is initialised with *is* the answer.
	vk::PhysicalDevicePushDescriptorPropertiesKHR push_descriptor = {
		.sType = STRUCTURE_TYPE_PHYSICAL_DEVICE_PUSH_DESCRIPTOR_PROPERTIES,
	};
	vk::PhysicalDeviceProperties2 properties2 = {
		.sType = STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2,
		.pNext = &push_descriptor,
	};
	vk::getPhysicalDeviceProperties2(self.pdevice, &properties2);
	vk::PhysicalDeviceProperties properties = properties2.properties;

	// The properties are read before the features, and the order is the point.
	// Unlike the push-descriptor struct above — which a device that has never
	// heard of it leaves untouched — a `VkPhysicalDeviceVulkan14Features` handed
	// to a 1.3 device is invalid usage rather than a no-op. Whether it may be
	// chained at all is a question only the properties can answer.
	bool has_1_4 = properties.apiVersion >= vk::@makeApiVersion(0, 1, 4, 0);

	// Queried, then handed to deviceCreateInfo unchanged, so exactly what the
	// device supports is what gets enabled — and what the checks below read is
	// what the device will actually have.
	vk::PhysicalDeviceVulkan14Features v14 = { .sType = STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_4_FEATURES };
	vk::PhysicalDeviceVulkan13Features v13 = {
		.sType = STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
		.pNext = has_1_4 ? (void*)&v14 : null,
	};
	vk::PhysicalDeviceVulkan12Features v12 = {
		.sType = STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
		.pNext = &v13,
	};
	vk::PhysicalDeviceVulkan11Features v11 = {
		.sType = STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES,
		.pNext = &v12,
	};
	vk::PhysicalDeviceFeatures2 features = { .sType = STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, .pNext = &v11 };
	vk::getPhysicalDeviceFeatures2(self.pdevice, &features);

	self.limits = {
		.scalar_block_layout = v12.scalarBlockLayout == vk::TRUE,
		.buffer_device_address = v12.bufferDeviceAddress == vk::TRUE,
		.dynamic_rendering = v13.dynamicRendering == vk::TRUE,
		.push_descriptor = push_descriptor.maxPushDescriptors > 0,
		.fill_mode_non_solid = features.features.fillModeNonSolid == vk::TRUE,
		.max_push_constants_size = properties.limits.maxPushConstantsSize,
		.timestamp_period = properties.limits
			.timestampPeriod, // `hostQueryReset` is read off the same `v12` handed to `deviceCreateInfo`
			// below unchanged, so it is enabled exactly when it is supported: a claim
			// about the device *and* about what was asked for, which cannot disagree.
		.timestamps = properties.limits.timestampComputeAndGraphics == vk::TRUE && v12.hostQueryReset == vk::TRUE,
		.api_version = properties
			.apiVersion, // Read off the same `v14` that goes to `deviceCreateInfo`, so — as with
			// `hostQueryReset` — this cannot disagree with what was asked for. False on
			// a 1.3 device because the struct was never chained there.
		.dynamic_rendering_local_read = has_1_4 && v14.dynamicRenderingLocalRead == vk::TRUE,
		.device_name = properties.deviceName,
	};

	if (!self.limits.buffer_device_address) return NO_BUFFER_DEVICE_ADDRESS~;
	if (!self.limits.dynamic_rendering) return NO_DYNAMIC_RENDERING~;
	if (!self.limits.push_descriptor) return NO_PUSH_DESCRIPTOR~;

	vk::DeviceQueueCreateInfo queue_info = vk::deviceQueueCreateInfo().setQueueFamilyIndex(self.graphics.index)
		.setQueuePriorities({ 1.0 });

	self.handle = vk::deviceCreateInfo().setQueueCreateInfos({ queue_info })
		.setEnabledExtensionNames(extensions.array_view())
		.setNext(&features)
		.build(self.pdevice)!;

	// Dispatch straight into the driver rather than through the loader.
	vk::loadDeviceCommands(self.handle);

	self.graphics.handle = self.handle.getQueue(self.graphics.index);

	// Before anything builds a pipeline, and after the device exists.
	// `properties` is the one already read above; asking the physical device a
	// second time could not give a different answer.
	self.driver_cache.open(self, &properties);

	self.allocator = {
		.device = self.handle,
		.pdevice = self.pdevice,
		.queue = self.graphics,
		.flags = MEMORY_ALLOCATE_DEVICE_ADDRESS_BIT,
	};
	self.allocator.init()!;

	return *self;
}

// ============================================================================
// The debug messenger and its sink
// ============================================================================

<*
 Installs the messenger that turns validation output into something a script can
 be handed.

 WARNING and ERROR only. `vk::setupDebugMessenger` also subscribes to VERBOSE,
 which on a validating instance is a running commentary on every object created —
 thousands of lines that exist only to be printed. None of it is a defect, and a
 log an agent has to skim is a log it stops reading. INFO is left off for the
 same reason. All three message *types* are kept: a PERFORMANCE warning is advice
 worth having, and a GENERAL one is where the loader says the thing nobody else
 will.

 `pUserData` is the sink and nothing else — the callback has no use for the rest
 of `Gpu`, and a narrower pointer is a narrower lifetime to argue about. The sink
 is a field of `Gpu`, `Gpu` is a field of `Renderer`, and both are function-scope
 locals never copied or reallocated after `init`. `Gpu.free` destroys the
 messenger *before* it releases the sink, so there is no window in which the
 driver can call back into freed memory.
*>
fn void? Gpu.install_debug_messenger(&self)
{
	self.sink.errors.init(mem, 1024);
	self.sink.warnings.init(mem, 1024);

	self.debug = vk::debugUtilsMessengerCreateInfoEXT()
		.setMessageSeverity(DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT | DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT)
		.setMessageType(
			DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT | DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT
				| DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT
		)/* See `validation_message` for why this cast is here and why it is not a *//* bug being papered over. */
		.setPfnUserCallback((vk::PFN_vkDebugUtilsMessengerCallbackEXT)&validation_message)
		.setUserData(&self.sink)
		.build(self.instance)!;
}

<*
 Captures the next run's validation output instead of printing it, and drops
 whatever the last one left.

 Armed by `JsRuntime.run` for exactly the length of one script and by nothing
 else, which is what makes a captured message attributable to the script that
 caused it. Outside that window a message is printed.

 A no-op when validation is off: there is no messenger to capture from, and an
 armed flag would be a claim this cannot keep.
*>
fn void Gpu.begin_capture(&self)
{
	if (!self.validation) return;
	self.sink.errors.clear();
	self.sink.warnings.clear();
	self.sink.capturing = true;
}

<*
 Stops capturing. Read the sink before calling this, not after — a message
 arriving in between goes down the printing path and is gone.
*>
fn void Gpu.end_capture(&self)
{
	self.sink.capturing = false;
}

<*
 Every warning and error the layer produces, captured for the running script or
 printed when there is none.

 This returns `uint`, and that is not pedantry. The ABI wants a 4-byte VkBool32
 here; vulkan.c3l's own `debugCallback` returns a one-byte C3 `bool`, which
 leaves the rest of the return register holding whatever was there before. A
 non-zero read tells the loader to abort the API call being validated, so a
 validation *warning* would start failing draws.

 The cast at the install site is the other half of the same problem.
 `PFN_vkDebugUtilsMessengerCallbackEXT` in `vk/extra.c3` declares the message
 struct *by value* where Vulkan passes a pointer. That file is vendored and not
 this project's to correct, so the signature here is the right one and the
 function pointer is cast on the way in.

 @param user : `The sink, from Gpu.init. Outlives the messenger, which Gpu.free destroys first.`
 @return `Always FALSE: a messenger that aborted the call it was reporting on would turn a diagnostic into a second failure.`
*>
fn uint validation_message(
	vk::DebugUtilsMessageSeverityFlagBitsEXT severity,
	vk::DebugUtilsMessageTypeFlagsEXT type,
	vk::DebugUtilsMessengerCallbackDataEXT* data,
	void* user
) @local
{
	ValidationSink* sink = (ValidationSink*)user;
	if (sink == null || data == null) return vk::FALSE;

	bool fatal  = (uint)severity >= SEVERITY_ERROR;
	// Both are documented as possibly-null, and a validating driver is exactly
	// where a null would arrive.
	String id   = data.pMessageIdName != null ? ((ZString)data.pMessageIdName).str_view() : "";
	String text = data.pMessage != null ? ((ZString)data.pMessage).str_view() : "";

	DString* into = fatal ? &sink.errors : &sink.warnings;
	sz mark       = into.len();

	into.append_string(fatal ? "validation ERROR" : "validation WARNING");
	// The VUID, or whatever else named this. The Khronos layer repeats it inside
	// pMessage, so this is not the only copy — but the loader's own GENERAL
	// messages carry no such prose, and it is the part an agent can look up, so it
	// goes at the front where it is findable rather than mid-sentence.
	if (id.len > 0)
	{
		into.append_char(' ');
		into.append_string(id);
	}
	into.append_string(": ");
	into.append_string(text);

	if (!sink.capturing)
	{
		// Composed in the buffer and then rewound rather than formatted twice, so
		// the line a human reads and the line a script is handed cannot drift.
		io::printn(into.str_view()[mark..]);
		into.chop(mark);
		return vk::FALSE;
	}

	// Only on the captured path: the lines stack, and a log wants them apart.
	into.append_char('\n');
	return vk::FALSE;
}

fn void Gpu.report(&self)
{
	io::printfn("device       %s", (ZString)&self.limits.device_name);
	uint api = self.limits.api_version;
	io::printfn("  apiVersion           %d.%d.%d", (api >> 22) & 0x7F, (api >> 12) & 0x3FF, api & 0xFFF);
	io::printfn("  validation           %s", self.validation ? "on" : "off");
	io::printfn("  scalarBlockLayout    %s", self.limits.scalar_block_layout);
	io::printfn("  bufferDeviceAddress  %s", self.limits.buffer_device_address);
	io::printfn("  dynamicRendering     %s", self.limits.dynamic_rendering);
	io::printfn("  pushDescriptor       %s", self.limits.push_descriptor);
	io::printfn("  localRead            %s", self.limits.dynamic_rendering_local_read);
	io::printfn("  fillModeNonSolid     %s", self.limits.fill_mode_non_solid);
	io::printfn("  maxPushConstantsSize %d", self.limits.max_push_constants_size);
	io::printfn("  timestamps           %s", self.limits.timestamps);
	io::printfn("  timestampPeriod      %f", self.limits.timestamp_period);
}

<*
 Blocks until the device has finished everything already submitted.

 What keeps `Assets.unload_unused` from freeing a buffer a frame in flight is
 still reading. A full idle is heavy — the opposite of what
 `MAX_FRAMES_IN_FLIGHT` exists for — and is kept only where the caller is
 already stalling, such as a level transition. `gpu/retire.c3` is what a
 mid-gameplay unload uses instead.

 Answers nothing on failure: `VK_ERROR_DEVICE_LOST` here means the frame loop is
 about to fail on its own with a better sentence, and refusing to free would turn
 a lost device into a leak as well.
*>
fn void Gpu.wait_idle(&self)
{
	if (self.handle != null) self.handle.waitIdle();
}

<*
 Tears down everything this owns, in reverse. The surface and the instance are
 not ours: whoever made them frees them.
*>
fn void Gpu.free(&self)
{
	if (self.handle != null)
	{
		self.handle.waitIdle();
		// After the idle and before the allocator: every retired pipeline is
		// unreachable by definition once the device is idle, and destroying them
		// here keeps a process that exits mid-queue from leaking whatever the last
		// two frames gave back.
		self.drain_deletions();
		// Then the driver's cache, in that order: a pipeline retired above may be
		// the only reason there is anything new to write, and reading the blob back
		// out of a cache whose device is idle is the one moment nothing can be
		// adding to it.
		self.driver_cache.save(self);
		self.driver_cache.free(self);
		self.allocator.free();
		self.handle.free();
		self.handle = (vk::Device)null;
	}
	// Owns nothing by now — `drain_deletions` emptied it — but the lists' own
	// storage is still ours to give back.
	self.deletions.pipelines.free();
	self.deletions.memory.free();
	if (self.debug != null)
	{
		self.debug.free(self.instance);
		self.debug = (vk::DebugUtilsMessengerEXT)null;
	}
	// After the messenger, never before. Until it is destroyed the driver is
	// entitled to call back into this, and the callback writes here.
	self.sink.errors.free();
	self.sink.warnings.free();
	self.sink.capturing = false;
	self.validation = false;
}