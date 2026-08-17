<*
 Instance, physical device selection, logical device, queues, allocator.

 ## Scalar block layout on this machine

 `plan.md` §1 asks for this to be decided once and the answer written down.
 Measured on an Apple M5 against the KosmicKrisp vulkan.c3l bundles:

	scalarBlockLayout    true
	bufferDeviceAddress  true
	dynamicRendering     true
	fillModeNonSolid     false      <- wireframes are line-list index buffers
	maxPushConstantsSize 256        <- budget stays 128, the portable minimum

 So `-force-glsl-scalar-layout` is legal here and the `float4`-never-`float3`
 tax does not apply. It is still **queried, not assumed**
 (`Gpu.limits.scalar_block_layout`) and printed by `--validate`. Narrowing to one
 driver is not a licence to assume: versions differ, `--system-driver` picks an
 installed KosmicKrisp rather than this one, and a driver that gained
 `fillModeNonSolid` would still have to be asked. Nothing in this project may
 read any of these at compile time.

 ## KosmicKrisp only — MoltenVK is not supported

 The driver is the one vulkan.c3l bundles: KosmicKrisp, a conformant Vulkan 1.3
 implementation on Metal. Nothing here is written against the portability
 subset, so a portability implementation is turned away rather than partly
 accommodated, in two places that cost nothing:

 - `create_instance` does not enable `VK_KHR_portability_enumeration`, so the
   loader never enumerates their physical devices;
 - `select_device` skips any device advertising `VK_KHR_portability_subset`, and
   says so through `PORTABILITY_DRIVER_ONLY` when that leaves nothing.

 On macOS this means `--system-driver` needs an installed KosmicKrisp; an
 installed MoltenVK is not a fallback.

 ## Frames in flight

 Two frames are in flight (`gpu/frame.c3`), so **anything the GPU may still be
 reading must be double-buffered**. crig's pose palette tore for exactly this
 reason. Nothing here is per-frame-mutable yet; the rule applies the moment the
 first uniform or instance buffer arrives.
*>
module three;

import std::io;
import std::collections::list;
import vk;

faultdef
	NO_BUFFER_DEVICE_ADDRESS,
	NO_DYNAMIC_RENDERING,
	NO_SUITABLE_GPU,
	PORTABILITY_DRIVER_ONLY;

<*
 What the selected device actually reports. Nothing optional is assumed
 (`plan.md` §1): the bundled driver and an installed one are different builds,
 and neither promises the other's optional features.
*>
struct GpuLimits
{
	bool scalar_block_layout;
	bool buffer_device_address;
	bool dynamic_rendering;
	bool fill_mode_non_solid;
	uint max_push_constants_size;
	char[256] device_name;
}

struct Gpu
{
	vk::Instance instance;
	vk::DebugUtilsMessengerEXT debug;
	// Externally owned: created from the window, freed by whoever made it.
	// Null in headless mode, and every path here has to cope with that.
	vk::SurfaceKHR surface;
	vk::PhysicalDevice pdevice;
	vk::Device handle;
	vk::DeviceQueue graphics;
	vk::MemoryAllocator allocator;
	GpuLimits limits;
	bool validation;
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
 Create the Vulkan instance.

 `vk::init()` comes first and is not negotiable: every Vulkan command in these
 bindings is a runtime-loaded pointer, and calling one before the loader is
 bound is a null-pointer crash that reads like a broken driver.

 No portability implementation is asked for or accepted — see the note on
 `VK_KHR_portability_enumeration` below, and the header of this file.

 @param validate : `Enable the Khronos validation layer and VK_EXT_debug_utils.`
 @param headless : `Skip the surface extensions entirely — nothing will present.`
 @param bundled_driver : `Prefer the driver vulkan.c3l ships over whatever the loader discovers. Deterministic, which is what makes screenshots reproducible across machines.`
*>
fn vk::Instance? create_instance(bool validate, bool headless = false, bool bundled_driver = true)
{
	vk::init()!;

	vk::ZStringList extensions;
	defer extensions.free();
	if (!headless) push_surface_extensions(&extensions);
	if (validate) extensions.push("VK_EXT_debug_utils");

	// VK_KHR_portability_enumeration is deliberately *not* requested, and its
	// instance flag deliberately not set. That flag is the spec's own switch for
	// "I accept portability implementations", and without it the loader does not
	// enumerate their physical devices at all — which is exactly the intent
	// here. It is how MoltenVK is kept out.

	// Both structs are read by vkCreateInstance, so they must outlive the
	// build() call below — function scope, not the `if`.
	vk::DirectDriverLoadingInfoLUNARG driver_info;
	vk::DirectDriverLoadingListLUNARG driver_list;
	bool direct_driver = false;

	if (bundled_driver)
	{
		if (try icd = vk::findBundledDriver())
		{
			if (vk::supportsDirectDriverLoading())
			{
				driver_info = vk::directDriverInfo(icd);
				driver_list = vk::directDriverList(&driver_info, 1);
				extensions.push(vk::DIRECT_DRIVER_LOADING_EXTENSION_NAME);
				direct_driver = true;
			}
		}
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
		.apiVersion = vk::@makeApiVersion(0, 1, 3, 0),
	};

	vk::InstanceCreateInfo info = vk::instanceCreateInfo().setApplicationInfo(&app_info);
	// Guarded because the list really can be empty — headless, no validation, no
	// bundled driver asks for nothing at all — and the builder takes `&names[0]`,
	// which is an out-of-bounds panic on an empty slice rather than a null count.
	if (extensions.len() > 0) info = info.setEnabledExtensionNames(extensions.array_view());

	vk::ZStringList layers;
	defer layers.free();
	if (validate)
	{
		layers.push("VK_LAYER_KHRONOS_validation");
		info = info.setEnabledLayerNames(layers.array_view());
	}

	if (direct_driver)
	{
		driver_list.pNext = info.pNext;
		info.pNext = &driver_list;
	}

	return info.build();
}

<*
 Pick a physical device.

 `vk::selectPhysicalDevice` would do this, but it dereferences the surface to
 check present support and three.c3 has to work with no surface at all — the
 offscreen target renders identically headless, which is the whole point of
 `plan.md` §1. So: same shape, surface check skipped when there is none, and
 portability implementations turned away.

 @return? PORTABILITY_DRIVER_ONLY : `Every device on offer was a portability implementation. Distinguished from NO_SUITABLE_GPU because the fix is a different driver, not different code.`
 @return? NO_SUITABLE_GPU : `No device has a graphics queue, the required extensions, and present support for the surface.`
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
		// on this platform that means MoltenVK. three.c3 does not support it:
		// everything here is written against a conformant Vulkan 1.3, which is
		// what the KosmicKrisp driver vulkan.c3l bundles provides.
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
 Bring up the logical device, its queue and its allocator.

 @param surface : `Null for headless. With one, VK_KHR_swapchain is required of the device; without, it is not asked for.`
 @return? NO_BUFFER_DEVICE_ADDRESS : `Geometry reaches the shader through buffer device addresses (plan.md §1); there is no vertex-input fallback to degrade to.`
 @return? NO_DYNAMIC_RENDERING : `There is no VkRenderPass anywhere in this project, by decision.`
*>
fn Gpu? Gpu.init(&self, vk::Instance instance, vk::SurfaceKHR surface, bool validate = false)
{
	self.instance = instance;
	self.surface = surface;
	self.validation = validate;

	if (validate) self.debug = vk::setupDebugMessenger(instance)!;

	vk::ZStringList extensions;
	defer extensions.free();
	if (surface != null) extensions.push("VK_KHR_swapchain");
	extensions.push("VK_KHR_dynamic_rendering");

	vk::DeviceSelection selection = select_device(instance, surface, extensions)!;
	self.pdevice = selection.device;
	self.graphics = { .index = selection.graphics_queue_index };

	// Nothing is added to `extensions` here. A device that advertises
	// VK_KHR_portability_subset would have to have it enabled, but no such
	// device gets this far: `select_device` turns them away.

	// Queried, then handed to deviceCreateInfo unchanged, so exactly what the
	// device supports is what gets enabled — and what the checks below read is
	// what the device will actually have.
	vk::PhysicalDeviceVulkan13Features v13 = { .sType = STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES };
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

	vk::PhysicalDeviceProperties properties;
	vk::getPhysicalDeviceProperties(self.pdevice, &properties);

	self.limits = {
		.scalar_block_layout = v12.scalarBlockLayout == vk::TRUE,
		.buffer_device_address = v12.bufferDeviceAddress == vk::TRUE,
		.dynamic_rendering = v13.dynamicRendering == vk::TRUE,
		.fill_mode_non_solid = features.features.fillModeNonSolid == vk::TRUE,
		.max_push_constants_size = properties.limits.maxPushConstantsSize,
		.device_name = properties.deviceName,
	};

	if (!self.limits.buffer_device_address) return NO_BUFFER_DEVICE_ADDRESS~;
	if (!self.limits.dynamic_rendering) return NO_DYNAMIC_RENDERING~;

	vk::DeviceQueueCreateInfo queue_info = vk::deviceQueueCreateInfo()
		.setQueueFamilyIndex(self.graphics.index)
		.setQueuePriorities({ 1.0 });

	self.handle = vk::deviceCreateInfo().setQueueCreateInfos({ queue_info })
		.setEnabledExtensionNames(extensions.array_view())
		.setNext(&features)
		.build(self.pdevice)!;

	// Dispatch straight into the driver rather than through the loader.
	vk::loadDeviceCommands(self.handle);

	self.graphics.handle = self.handle.getQueue(self.graphics.index);

	self.allocator = {
		.device = self.handle,
		.pdevice = self.pdevice,
		.queue = self.graphics,
		.flags = MEMORY_ALLOCATE_DEVICE_ADDRESS_BIT,
	};
	self.allocator.init()!;

	return *self;
}

fn void Gpu.report(&self)
{
	io::printfn("device       %s", (ZString)&self.limits.device_name);
	io::printfn("  scalarBlockLayout    %s", self.limits.scalar_block_layout);
	io::printfn("  bufferDeviceAddress  %s", self.limits.buffer_device_address);
	io::printfn("  dynamicRendering     %s", self.limits.dynamic_rendering);
	io::printfn("  fillModeNonSolid     %s", self.limits.fill_mode_non_solid);
	io::printfn("  maxPushConstantsSize %d", self.limits.max_push_constants_size);
}

<*
 Tear down everything this owns, in reverse. The surface and the instance are
 not ours: whoever made them frees them.
*>
fn void Gpu.free(&self)
{
	if (self.handle != null)
	{
		self.handle.waitIdle();
		self.allocator.free();
		self.handle.free();
		self.handle = (vk::Device)null;
	}
	if (self.debug != null)
	{
		self.debug.free(self.instance);
		self.debug = (vk::DebugUtilsMessengerEXT)null;
	}
}
