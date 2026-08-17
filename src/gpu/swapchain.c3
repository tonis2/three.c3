<*
 The window's swapchain. It blits `gpu/target.c3` and presents. That is all it
 does, and the type is called `Viewer` to keep it that way — the window is a
 viewer, not a render target (`plan.md` §1).

 Two things it therefore does *not* have, and their absence is the payoff:

 - **No image views.** Nothing renders into a swapchain image, so there is no
   attachment to describe.
 - **No say in format, extent, sample count or projection.** Those belong to
   the target. A resize rebuilds this and moves the blit's destination rect;
   nothing upstream of the blit notices.

 ## Resize

 `VK_ERROR_OUT_OF_DATE_KHR` and `VK_SUBOPTIMAL_KHR` are handled here rather than
 later, because a half-done resize means every later milestone gets debugged
 through an intermittent failure that has nothing to do with it. Both the
 acquire and the present can report them; `rebuild` is the single path either
 one takes.

 The image count is settled once at `init` and never moves across a rebuild:
 the per-image render-finished semaphores are sized by it, and a count that
 changes underneath them is a use-after-free that validation catches only
 sometimes.
*>
module three;

import std::io;
import vk;

faultdef SURFACE_CANNOT_BLIT, NO_PRESENTABLE_SURFACE;

struct Viewer
{
	// Externally owned — created from the window, freed by whoever made it.
	vk::SurfaceKHR surface;
	vk::SwapchainKHR handle;
	vk::SurfaceFormatKHR format;
	vk::Extent2D extent;
	vk::ImageList images;
	// Settled at init, then fixed. See the header.
	uint image_count;
}

<*
 The surface's current size in physical pixels.

 Read off the surface rather than off the window: it is the surface the
 swapchain has to agree with, and on a HiDPI display the window's own numbers
 are logical points. A surface that declines to answer (Wayland reports
 `0xFFFFFFFF`, meaning "whatever the swapchain asks for") gets the extent
 already in use, so the caller sees no change.
*>
fn vk::Extent2D? Viewer.surface_extent(&self, Gpu* gpu)
{
	vk::SurfaceCapabilitiesKHR caps = self.surface.deviceSurfaceCapabilities(gpu.pdevice)!;
	if (caps.currentExtent.width == uint::max) return self.extent;
	return caps.currentExtent;
}

<*
 @param width : `Requested size in physical pixels; the surface's own answer wins where it has one.`
 @return? SURFACE_CANNOT_BLIT : `The surface will not grant TRANSFER_DST, or its format cannot be a blit destination. There is no fallback: blitting the target is the swapchain's whole job.`
 @return? NO_PRESENTABLE_SURFACE : `The surface offers no formats at all.`
*>
fn Viewer? Viewer.init(&self, Gpu* gpu, vk::SurfaceKHR surface, uint width, uint height)
{
	self.surface = surface;

	// Given the heap explicitly, and that is not tidiness. A List left
	// zero-initialised has a null allocator, and `list_ensure_capacity`
	// resolves null to `tmem` — so the first push would back this list with
	// temp-arena memory, and any `@pool()` open anywhere up the stack would
	// free it on the way out. Nothing faults there: the entries turn into
	// garbage and the crash lands wherever the list is next walked. vulkan.c3l
	// was bitten by exactly this and says so at the top of its allocator.
	self.images.init(mem, 8);

	vk::SurfaceCapabilitiesKHR caps  = surface.deviceSurfaceCapabilities(gpu.pdevice)!;
	vk::SurfaceFormatList formats    = surface.getFormats(gpu.pdevice)!;
	defer formats.free();
	if (formats.len() == 0) return NO_PRESENTABLE_SURFACE~;

	// B8G8R8A8_UNORM if it is offered, else whatever is first. Unlike cui this
	// choice reaches nothing: the readback reads the *target*, which is always
	// R8G8B8A8_UNORM, so no swizzle follows from it either way.
	self.format = formats[0];
	foreach (candidate : formats)
	{
		if (candidate.format == FORMAT_B8G8R8A8_UNORM && candidate.colorSpace == COLOR_SPACE_SRGB_NONLINEAR_KHR)
		{
			self.format = candidate;
			break;
		}
	}

	if ((uint)(caps.supportedUsageFlags & IMAGE_USAGE_TRANSFER_DST_BIT) == 0) return SURFACE_CANNOT_BLIT~;

	vk::FormatProperties format_props;
	vk::getPhysicalDeviceFormatProperties(gpu.pdevice, self.format.format, &format_props);
	if ((uint)(format_props.optimalTilingFeatures & FORMAT_FEATURE_BLIT_DST_BIT) == 0) return SURFACE_CANNOT_BLIT~;

	uint count = caps.minImageCount + 1;
	if (caps.maxImageCount != 0 && count > caps.maxImageCount) count = caps.maxImageCount;
	self.image_count = count;

	self.build(gpu, { .width = width, .height = height }, caps)!;
	return *self;
}

<*
 Create (or replace) the swapchain object and re-read its images. Split out of
 `init` because `rebuild` needs exactly this and nothing else — in particular
 not a fresh image count.
*>
fn void? Viewer.build(&self, Gpu* gpu, vk::Extent2D requested, vk::SurfaceCapabilitiesKHR caps)
{
	vk::Extent2D extent = requested;
	if (caps.currentExtent.width != uint::max) extent = caps.currentExtent;

	vk::SwapchainKHR old = self.handle;

	self.handle = vk::swapchainCreateInfoKHR().setSurface(self.surface).setMinImageCount(self.image_count)
		.setImageFormat(self.format.format)
		.setImageColorSpace(self.format.colorSpace)
		.setImageExtent(extent)
		.setImageArrayLayers(1)
		// The only usage this ever needs: it is a blit destination and nothing
		// is rendered into it.
		.setImageUsage(IMAGE_USAGE_TRANSFER_DST_BIT)
		.setImageSharingMode(SHARING_MODE_EXCLUSIVE)
		// Re-queried every rebuild rather than remembered: a display rotation
		// changes it, and a stale transform is a picture on its side.
		.setPreTransform(caps.currentTransform)
		.setCompositeAlpha(COMPOSITE_ALPHA_OPAQUE_BIT_KHR)
		.setPresentMode(PRESENT_MODE_FIFO_KHR)
		.setClipped(vk::TRUE)
		.setOldSwapchain(old)
		.build(gpu.handle)!;

	if (old != null) old.free(gpu.handle);

	self.extent = extent;
	self.images.clear();

	// `minImageCount` is a minimum, so the driver is free to hand back more
	// than was asked for — and everything sized by the count (the per-image
	// render-finished semaphores) has to hear about it, or a later frame
	// indexes past the end of a list it thought it had sized correctly.
	uint actual;
	vk::getSwapchainImagesKHR(gpu.handle, self.handle, &actual, null)!;

	// Queried into scratch rather than through `SwapchainKHR.getImages`: that
	// helper allocates an array and never frees it, so a resize stress leaks
	// one per rebuild.
	vk::Image[] scratch = mem::new_array(vk::Image, actual);
	defer mem::free(scratch);
	vk::getSwapchainImagesKHR(gpu.handle, self.handle, &actual, scratch.ptr)!;

	for (uint i = 0; i < actual; i++) self.images.push(scratch[i]);
	self.image_count = actual;
}

<*
 Wait the device idle, re-query capabilities, and recreate at the surface's
 current size.

 Capabilities are re-read rather than reused: `currentExtent` and
 `currentTransform` are exactly what changed. A zero extent means minimised —
 there is nothing to build a swapchain for, and asking for one would spin the
 loop on an acquire that keeps failing, so the caller is told to skip the
 frame and wait for the next window event.

 @return `false when the window is minimised and there is nothing to present to.`
*>
fn bool? Viewer.rebuild(&self, Gpu* gpu)
{
	vk::SurfaceCapabilitiesKHR caps = self.surface.deviceSurfaceCapabilities(gpu.pdevice)!;
	vk::Extent2D extent             = caps.currentExtent;
	if (extent.width == uint::max) extent = self.extent;
	if (extent.width == 0 || extent.height == 0) return false;

	gpu.handle.waitIdle();
	self.build(gpu, extent, caps)!;
	return true;
}

fn void Viewer.free(&self, Gpu* gpu)
{
	self.images.free();
	if (self.handle != null)
	{
		self.handle.free(gpu.handle);
		self.handle = (vk::SwapchainKHR)null;
	}
}

// ============================================================================
// The blit — the swapchain's entire contribution
// ============================================================================

fn vk::ImageMemoryBarrier2 blit_barrier(
	vk::Image target,
	vk::ImageLayout from,
	vk::ImageLayout to,
	vk::PipelineStageFlags2 src_stage,
	vk::AccessFlags2 src_access,
	vk::PipelineStageFlags2 dst_stage,
	vk::AccessFlags2 dst_access
)
{
	return {
		.sType = STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
		.image = target,
		.srcStageMask = src_stage,
		.srcAccessMask = src_access,
		.dstStageMask = dst_stage,
		.dstAccessMask = dst_access,
		.oldLayout = from,
		.newLayout = to,
		.subresourceRange = {
			.aspectMask = IMAGE_ASPECT_COLOR_BIT,
			.baseMipLevel = 0,
			.levelCount = 1,
			.baseArrayLayer = 0,
			.layerCount = 1,
		},
	};
}

<*
 Blit the target into the acquired image and leave it presentable.

 The source is already in `TRANSFER_SRC_OPTIMAL` — `Target.end_render`
 guarantees it — so only the destination needs transitioning, and it comes
 from `UNDEFINED` because a presented image's old contents are of no interest.

 A linear filter handles the target and the window disagreeing about size,
 which they routinely do: the target's extent is fixed and the window's is
 whatever the user dragged it to.
*>
fn void Viewer.record_blit(&self, vk::CommandBuffer cmd, Target* target, uint index)
{
	vk::Image dst = self.images[index];

	vk::cmdPipelineBarrier2(
		cmd,
		&&vk::dependencyInfo().setImageMemoryBarriers(
			{
				blit_barrier(
					dst,
					IMAGE_LAYOUT_UNDEFINED,
					IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
					PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
					(vk::AccessFlags2)0,
					PIPELINE_STAGE_2_ALL_TRANSFER_BIT,
					ACCESS_2_TRANSFER_WRITE_BIT
				),
			}
		)
	);

	vk::ImageSubresourceLayers layers = {
		.aspectMask = IMAGE_ASPECT_COLOR_BIT,
		.mipLevel = 0,
		.baseArrayLayer = 0,
		.layerCount = 1,
	};
	vk::ImageBlit region = {
		.srcSubresource = layers,
		.srcOffsets = { { 0, 0, 0 }, { (int)target.extent.width, (int)target.extent.height, 1 } },
		.dstSubresource = layers,
		.dstOffsets = { { 0, 0, 0 }, { (int)self.extent.width, (int)self.extent.height, 1 } },
	};
	vk::cmdBlitImage(
		cmd,
		target.color,
		IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
		dst,
		IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
		1,
		&region,
		FILTER_LINEAR
	);

	vk::cmdPipelineBarrier2(
		cmd,
		&&vk::dependencyInfo().setImageMemoryBarriers(
			{
				blit_barrier(
					dst,
					IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
					IMAGE_LAYOUT_PRESENT_SRC_KHR,
					PIPELINE_STAGE_2_ALL_TRANSFER_BIT,
					ACCESS_2_TRANSFER_WRITE_BIT,
					PIPELINE_STAGE_2_BOTTOM_OF_PIPE_BIT,
					(vk::AccessFlags2)0
				),
			}
		)
	);
}
