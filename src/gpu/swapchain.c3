<*
 The window's swapchain. It blits the finished frame and presents; that is all it
 does. The type is called `Viewer` to keep it that way — the window is a viewer,
 not a render target.

 What it blits is `gpu/target.c3`, or — while an interface is up — the
 `Composite` at the end of this file, which is the target already scaled to the
 window with the interface drawn on top at the window's own pixels. Either way
 the destination is written by exactly one command, and it is a blit.

 Two things it therefore does not have:

 - No image views. Nothing renders into a swapchain image, so there is no
 attachment to describe.
 - No say in format, extent, sample count or projection. Those belong to the
 target. A resize rebuilds this and moves the blit's destination rect;
 nothing upstream of the blit notices.

 `VK_ERROR_OUT_OF_DATE_KHR` and `VK_SUBOPTIMAL_KHR` are handled here rather than
 propagated, because a half-done resize turns into an intermittent failure
 somewhere unrelated. Both the acquire and the present can report them, and
 `rebuild` is the single path either takes.

 The image count is settled once at `init` and never moves across a rebuild: the
 per-image render-finished semaphores are sized by it, and a count that changes
 underneath them is a use-after-free that validation catches only sometimes.
*>
module three;

import vk;

faultdef SURFACE_CANNOT_BLIT, NO_PRESENTABLE_SURFACE;

<*
 Does this format carry the sRGB transfer function, so the hardware encodes on
 write and decodes on read?

 Only the eight-bit four-channel surface formats are listed, since those are the
 only ones a surface has offered here; an unknown format answers `false`, which
 costs a warning and the old behaviour rather than a wrong conversion. There is
 no bit in `vk::Format` to test — the enum is a flat list of names, so a table
 is the only way to ask.
*>
fn bool is_srgb_format(vk::Format format) @local
{
	switch (format)
	{
		case FORMAT_R8G8B8A8_SRGB:
		case FORMAT_B8G8R8A8_SRGB:
		case FORMAT_A8B8G8R8_SRGB_PACK32:
			return true;
		default:
			return false;
	}
}

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
	<*
	 What to build at when the surface declines to say — see `surface_extent`.

	 Zero means "no opinion", which keeps the extent already in use and is what
	 every path that has no window does. `main.c3`'s loop writes the window's own
	 size here every frame, and Wayland is the whole reason it exists: that
	 surface never reports a size, so without this the swapchain goes on asking
	 for whatever it was created at and a resized window shows an old picture
	 scaled by the compositor forever.
	*>
	vk::Extent2D wanted;
}

<*
 The surface's current size in physical pixels.

 Read off the surface rather than the window: the swapchain has to agree with
 the surface, and on a HiDPI display the window's own numbers are logical
 points. A surface that declines to answer (Wayland reports `0xFFFFFFFF`,
 meaning "whatever the swapchain asks for") gets the extent already in use, so
 the caller sees no change.
*>
fn vk::Extent2D? Viewer.surface_extent(&self, Gpu* gpu)
{
	vk::SurfaceCapabilitiesKHR caps = self.surface.deviceSurfaceCapabilities(gpu.pdevice)!;
	if (caps.currentExtent.width == uint::max) return self.client_extent();
	return caps.currentExtent;
}

<*
 What to build at when the surface leaves the choice to the client.

 `wanted` if anybody set it, and the extent already in use otherwise — which
 keeps a renderer with no window, and every test, on exactly the path it was on
 before this existed.
*>
fn vk::Extent2D Viewer.client_extent(&self)
{
	if (self.wanted.width == 0 || self.wanted.height == 0) return self.extent;
	return self.wanted;
}

<*
 @param width : `Requested size in physical pixels; the surface's own answer wins where it has one.`
 @return ? SURFACE_CANNOT_BLIT : `The surface will not grant TRANSFER_DST, or its format cannot be a blit destination. There is no fallback: blitting the target is the swapchain's whole job.`
 @return ? NO_PRESENTABLE_SURFACE : `The surface offers no formats at all.`
*>
fn Viewer? Viewer.init(&self, Gpu* gpu, vk::SurfaceKHR surface, uint width, uint height)
{
	self.surface = surface;

	// Given the heap explicitly. A List left zero-initialised has a null
	// allocator, and `list_ensure_capacity` resolves null to `tmem` — so the
	// first push would back this list with temp-arena memory, and any `@pool()`
	// open up the stack would free it on the way out. Nothing faults there: the
	// entries turn into garbage and the crash lands wherever the list is next
	// walked.
	self.images.init(mem, 8);

	vk::SurfaceCapabilitiesKHR caps = surface.deviceSurfaceCapabilities(gpu.pdevice)!;
	vk::SurfaceFormatList formats   = surface.getFormats(gpu.pdevice)!;
	defer formats.free();
	if (formats.len() == 0) return NO_PRESENTABLE_SURFACE~;

	// Prefer an sRGB format. The target is R8G8B8A8_SRGB, and `vkCmdBlitImage`
	// converts: it reads the source as linear — decoding sRGB on the way in —
	// and encodes into the destination's format on the way out. Blitting into a
	// UNORM swapchain would therefore store linear values and present them as
	// sRGB, losing the gamma correction one step after the code that looks
	// responsible for it.
	// 
	// So: the matching sRGB pair first, any sRGB format second, and only then
	// whatever the surface listed first. Readback is unaffected either way — it
	// copies the target, never a swapchain image.
	self.format = formats[0];
	bool found = false;
	foreach (candidate : formats)
	{
		if (candidate.format == FORMAT_B8G8R8A8_SRGB && candidate.colorSpace == COLOR_SPACE_SRGB_NONLINEAR_KHR)
		{
			self.format = candidate;
			found = true;
			break;
		}
	}
	if (!found)
	{
		foreach (candidate : formats)
		{
			if (is_srgb_format(candidate.format) && candidate.colorSpace == COLOR_SPACE_SRGB_NONLINEAR_KHR)
			{
				self.format = candidate;
				found = true;
				break;
			}
		}
	}
	// Nothing sRGB on offer is a surface this project has never met. Presenting
	// through it still beats refusing to open a window, and the failure it
	// leaves — a window that is too dark, with correct screenshots beside it —
	// is worth advising about rather than a fault the caller cannot act on.
	if (!found)
	{
		@advise(
			"three: no sRGB surface format offered; the window will present linear values and look dark. Screenshots are unaffected."
		);
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
 Creates (or replaces) the swapchain object and re-reads its images. Split out
 of `init` because `rebuild` needs exactly this and nothing else — in
 particular, not a fresh image count.
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
		.setImageArrayLayers(
			1
		)/* The only usage this ever needs: it is a blit destination and nothing *//* is rendered into it. */
		.setImageUsage(IMAGE_USAGE_TRANSFER_DST_BIT)
		.setImageSharingMode(
			SHARING_MODE_EXCLUSIVE
		)/* Re-queried every rebuild rather than remembered: a display rotation *//* changes it, and a stale transform is a picture on its side. */
		.setPreTransform(caps.currentTransform)
		.setCompositeAlpha(COMPOSITE_ALPHA_OPAQUE_BIT_KHR)
		.setPresentMode(PRESENT_MODE_FIFO_KHR)
		.setClipped(vk::TRUE)
		.setOldSwapchain(old)
		.build(gpu.handle)!;

	if (old != null) old.free(gpu.handle);

	self.extent = extent;
	self.images.clear();

	// `minImageCount` is a minimum, so the driver may hand back more than was
	// asked for. Everything sized by the count (the per-image render-finished
	// semaphores) has to hear about it, or a later frame indexes past the end.
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
 Waits the device idle, re-queries capabilities and recreates at the surface's
 current size.

 Capabilities are re-read rather than reused, since `currentExtent` and
 `currentTransform` are exactly what changed. A zero extent means minimised:
 there is nothing to build a swapchain for, and asking would spin the loop on an
 acquire that keeps failing, so the caller skips the frame and waits for the
 next window event.

 @return `false when the window is minimised and there is nothing to present to.`
*>
fn bool? Viewer.rebuild(&self, Gpu* gpu)
{
	vk::SurfaceCapabilitiesKHR caps = self.surface.deviceSurfaceCapabilities(gpu.pdevice)!;
	vk::Extent2D extent             = caps.currentExtent;
	if (extent.width == uint::max) extent = self.client_extent();
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

<*
 Blits the target into the acquired image and leaves it presentable.

 The source is already in `TRANSFER_SRC_OPTIMAL` (`Target.close` guarantees it),
 so only the destination needs transitioning, and it comes from `UNDEFINED`
 because a presented image's old contents are of no interest.

 A linear filter handles the target and the window disagreeing about size, which
 they routinely do: the target's extent is fixed and the window's is whatever the
 user dragged it to.
*>
fn void Viewer.record_blit(&self, vk::CommandBuffer cmd, Target* target, uint index)
{
	self.record_blit_from(cmd, target.color, target.extent, index);
}

<*
 The same blit, from whichever image holds the finished frame.

 Two of them do. Without an interface it is the target, straight out of
 `record_scene`. With one it is the `Composite`, which is the target already
 scaled up to the window with the interface drawn on top at the window's own
 pixels — see there. Both arrive in `TRANSFER_SRC_OPTIMAL` and neither is a
 swapchain image, so this stays the one and only thing written into one.

 @param src : `The finished frame. Must be in TRANSFER_SRC_OPTIMAL.`
 @param src_extent : `Its size — the source rect of the blit.`
*>
fn void Viewer.record_blit_from(
	&self,
	vk::CommandBuffer cmd,
	vk::Image src,
	vk::Extent2D src_extent,
	uint index
)
{
	vk::Image dst = self.images[index];

	vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo()
		.setImageMemoryBarriers(
			{
				(vk::ImageMemoryBarrier2) {
					...IMAGE_BARRIER,
					.image = dst,
					.srcStageMask = PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
					.srcAccessMask = (vk::AccessFlags2)0,
					.dstStageMask = PIPELINE_STAGE_2_ALL_TRANSFER_BIT,
					.dstAccessMask = ACCESS_2_TRANSFER_WRITE_BIT,
					.oldLayout = IMAGE_LAYOUT_UNDEFINED,
					.newLayout = IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
				},
			}
		));

	vk::ImageSubresourceLayers layers = {
		.aspectMask = IMAGE_ASPECT_COLOR_BIT,
		.mipLevel = 0,
		.baseArrayLayer = 0,
		.layerCount = 1,
	};
	vk::ImageBlit region = {
		.srcSubresource = layers,
		.srcOffsets = { { 0, 0, 0 }, { (int)src_extent.width, (int)src_extent.height, 1 } },
		.dstSubresource = layers,
		.dstOffsets = { { 0, 0, 0 }, { (int)self.extent.width, (int)self.extent.height, 1 } },
	};
	vk::cmdBlitImage(
		cmd,
		src,
		IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
		dst,
		IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
		1,
		&region,
		FILTER_LINEAR
	);

	vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo()
		.setImageMemoryBarriers(
			{
				(vk::ImageMemoryBarrier2) {
					...IMAGE_BARRIER,
					.image = dst,
					.srcStageMask = PIPELINE_STAGE_2_ALL_TRANSFER_BIT,
					.srcAccessMask = ACCESS_2_TRANSFER_WRITE_BIT,
					.dstStageMask = PIPELINE_STAGE_2_BOTTOM_OF_PIPE_BIT,
					.dstAccessMask = (vk::AccessFlags2)0,
					.oldLayout = IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
					.newLayout = IMAGE_LAYOUT_PRESENT_SRC_KHR,
				},
			}
		));
}
// ============================================================================
// The composite — the frame at the window's own pixels
// ============================================================================

<*
 The finished frame, scaled to the window, with the interface drawn on top of it
 at the window's own resolution.

 ## Why it exists

 The target follows the window by default, so the two usually agree and this is a
 1:1 blit — one image and one copy, and nothing to see. It exists for when they
 do not, which is a render size a script has PINNED with `three.setRenderSize`:
 a 1280x720 target presented across 2560x1440 device pixels, every pixel of it
 stretched by two. That is right for the scene — it is what a render scale means
 — and wrong for the interface, whose glyphs are signed distance fields and
 would be pin-sharp at any size if anything ever asked them for one. Drawn into
 the target they are rasterised at 1280x720 and then upscaled, which is the one
 thing SDF text exists to avoid.

 So with an interface up, the present path grows a middle: the scene is blitted
 up to the window's size FIRST, cui draws into that, and the result is what is
 presented. The scene is scaled exactly as before and the interface never is.

 ## Why not into the swapchain image directly

 It is one blit cheaper and it does not work. `cui::vulkan::CanvasPass` compiles
 its pipeline against one colour format, and the format three renders at
 (`R8G8B8A8_SRGB`) is not the format a surface offers (`B8G8R8A8_SRGB` on every
 platform this has met). Recording into a swapchain image would mean a second
 pipeline, a second pass, or a target that changes format with the window — and
 the `Viewer` would stop being a thing that only ever blits, which is the
 invariant its own header keeps. A composite in the target's format costs one
 image and one more blit, and leaves both of those alone.

 ## What it does NOT change

 `capture()`, `render_offscreen()` and every headless path never touch this: they
 have no window, so the interface goes into the target exactly as it always did
 and a screenshot still has the HUD in it. `Renderer.record_scene` is told which
 of the two is happening and draws the interface once, in one place or the other.
*>
struct Composite
{
	vk::Extent2D extent;
	vk::Image color;
	vk::ImageView color_view;
	vk::Memory color_memory;
}

<*
 Builds (or rebuilds) the image at `extent`, and does nothing when it is already
 that size — which is every frame but the first and the ones after a resize.

 The device is idled before an old image is freed. This is a stall, and it is the
 correct one: the image being replaced may still be read by the blit of a frame
 that has not finished presenting, and the alternative is per-image lifetime
 tracking for something that changes when a person drags a window edge.

 @require extent.width > 0 && extent.height > 0
*>
fn void? Composite.ensure(&self, Gpu* gpu, vk::Extent2D extent)
{
	if (self.color != null && self.extent.width == extent.width && self.extent.height == extent.height) return;

	if (self.color != null)
	{
		gpu.handle.waitIdle();
		self.free(gpu);
	}

	self.extent = extent;

	// TRANSFER_DST to receive the scene, COLOR_ATTACHMENT for cui to draw into
	// it, TRANSFER_SRC to be presented. The whole of its life in three flags.
	self.color = vk::imageCreateInfo().setImageType(IMAGE_TYPE_2D).setFormat(TARGET_COLOR_FORMAT)
		.setExtent({ .width = extent.width, .height = extent.height, .depth = 1 })
		.setMipLevels(1)
		.setArrayLayers(1)
		.setSamples(SAMPLE_COUNT_1_BIT)
		.setTiling(IMAGE_TILING_OPTIMAL)
		.setUsage(IMAGE_USAGE_TRANSFER_DST_BIT | IMAGE_USAGE_COLOR_ATTACHMENT_BIT | IMAGE_USAGE_TRANSFER_SRC_BIT)
		.setInitialLayout(IMAGE_LAYOUT_UNDEFINED)
		.build(gpu.handle)!;
	self.color_memory = vk::create_image_buffer(self.color, &gpu.allocator, MEMORY_PROPERTY_DEVICE_LOCAL_BIT)!;

	self.color_view = vk::imageViewCreateInfo().setViewType(IMAGE_VIEW_TYPE_2D).setFormat(TARGET_COLOR_FORMAT)
		.setSubresourceRange(COLOR_LEVEL)
		.setImage(self.color)
		.build(gpu.handle)!;
}

<*
 `vk::Memory.free` destroys the image it was bound to, so the view is the only
 extra — the same rule `Target.free` follows.
*>
fn void Composite.free(&self, Gpu* gpu)
{
	if (self.color_view != null)
	{
		self.color_view.free(gpu.handle);
		self.color_view = (vk::ImageView)null;
	}
	if (self.color != null)
	{
		self.color_memory.free();
		self.color = (vk::Image)null;
		self.color_memory = {};
	}
	self.extent = {};
}

fn usz Composite.bytes(&self) => (usz)self.color_memory.size;

<*
 Takes the finished scene, scaled to this image's size.

 The source is in `TRANSFER_SRC_OPTIMAL` (`Target.close`) and this image comes
 from `UNDEFINED` because every pixel of it is about to be written. Leaves it in
 `COLOR_ATTACHMENT_OPTIMAL`, ready for `begin_overlay` — one barrier does the
 whole transition rather than TRANSFER_DST and then a second one.
*>
fn void Composite.receive(&self, vk::CommandBuffer cmd, Target* target)
{
	vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo()
		.setImageMemoryBarriers(
			{
				(vk::ImageMemoryBarrier2) {
					...IMAGE_BARRIER,
					.image = self.color,
					.srcStageMask = PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
					.srcAccessMask = (vk::AccessFlags2)0,
					.dstStageMask = PIPELINE_STAGE_2_ALL_TRANSFER_BIT,
					.dstAccessMask = ACCESS_2_TRANSFER_WRITE_BIT,
					.oldLayout = IMAGE_LAYOUT_UNDEFINED,
					.newLayout = IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
				},
			}
		));

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
		self.color,
		IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
		1,
		&region,
		FILTER_LINEAR
	);

	vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo()
		.setImageMemoryBarriers(
			{
				(vk::ImageMemoryBarrier2) {
					...IMAGE_BARRIER,
					.image = self.color,
					.srcStageMask = PIPELINE_STAGE_2_ALL_TRANSFER_BIT,
					.srcAccessMask = ACCESS_2_TRANSFER_WRITE_BIT,
					.dstStageMask = PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
					.dstAccessMask = ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT | ACCESS_2_COLOR_ATTACHMENT_READ_BIT,
					.oldLayout = IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
					.newLayout = IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
				},
			}
		));
}

<*
 Opens the rendering cui records into: load what is there, no clear, no depth,
 no Y flip — `Target.begin_overlay` says why for all three, and this is the same
 rendering over a different image.
*>
fn void Composite.begin_overlay(&self, vk::CommandBuffer cmd)
{
	vk::RenderingAttachmentInfo color_attachment = vk::renderingAttachmentInfo().setImageView(self.color_view)
		.setImageLayout(IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL)
		.setLoadOp(ATTACHMENT_LOAD_OP_LOAD)
		.setStoreOp(ATTACHMENT_STORE_OP_STORE);

	vk::RenderingInfo rendering = vk::renderingInfo().setRenderArea({ .extent = self.extent }).setLayerCount(1)
		.setColorAttachments({ color_attachment });

	vk::cmdBeginRendering(cmd, &rendering);
	set_full_viewport(cmd, self.extent, false);
}

<*
 Hands it to the blit that presents it. `Target.close` in every respect but the
 image.
*>
fn void Composite.close(&self, vk::CommandBuffer cmd)
{
	vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo()
		.setImageMemoryBarriers(
			{
				(vk::ImageMemoryBarrier2) {
					...IMAGE_BARRIER,
					.image = self.color,
					.srcStageMask = PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
					.srcAccessMask = ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
					.dstStageMask = PIPELINE_STAGE_2_ALL_TRANSFER_BIT,
					.dstAccessMask = ACCESS_2_TRANSFER_READ_BIT,
					.oldLayout = IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
					.newLayout = IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
				},
			}
		));
}
