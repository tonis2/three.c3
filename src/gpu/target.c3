<*
 The offscreen colour+depth attachment, and its readback.

 **Everything draws here. Nothing ever draws into a swapchain image.** The
 swapchain blits this (`gpu/swapchain.c3`) and the screenshot copies it; both
 are consumers. That is `plan.md` §1, and this file is where it is either
 honoured or quietly lost.

 Three things follow, and they are the reason for the decision:

 - **The extent is a parameter, not the window's.** A resize rebuilds the
   swapchain and moves the blit's destination rect. It does not touch the
   target, the depth buffer, the pipeline or the projection.
 - **`R8G8B8A8_SRGB`, so readback is a straight memcpy and the bytes are already
   display-ready.** cui swizzles BGRA by hand because it reads back a swapchain
   image whose format the surface chose. three.c3 chose this one. The channel
   order is what makes the memcpy work; the `_SRGB` half is what makes the
   *values* right, and that is a separate claim — see below.
 - **Headless is the same code path.** No surface, no swapchain, and render +
   readback still work — which is what makes an image test possible under
   `c3c test` with no window server.

 ## The layout contract

 The colour image cycles through exactly two layouts and both ends are here:

	begin_render   UNDEFINED               -> COLOR_ATTACHMENT_OPTIMAL
	end_render     COLOR_ATTACHMENT_OPTIMAL -> TRANSFER_SRC_OPTIMAL

 So after `end_render` the image is ready for *either* consumer with no further
 transition, and the next frame's `UNDEFINED` discards contents it is about to
 clear anyway. Anything that reads the colour image outside that window is
 reading it in TRANSFER_SRC_OPTIMAL.
*>
module three;

import std::io;
import vk;
import image;
import image::png;

<*
 Colour is fixed; depth is whatever the device will take (`vk::findDepthFormat`
 walks D32_SFLOAT first).

 ## Why `_SRGB` and not `_UNORM`

 This was `_UNORM` until the round trip was measured, and the round trip was
 broken in a way that is invisible to every test that only asks the renderer to
 agree with itself.

 Textures upload as `R8G8B8A8_SRGB` (`gpu/texture.c3`), so the sampler decodes
 to linear on read and the shaders' lighting arithmetic is linear, which is
 correct. Under `_UNORM` nothing re-encoded on the way out: the shader's linear
 float landed in eight bits raw, and both consumers then treated those bits as
 sRGB — the swapchain because it presents to an sRGB display, the screenshot
 because a PNG with no chunk saying otherwise *is* sRGB. One decode, no encode,
 so **every textured scene came out about 2.2 too dark**.

 `_SRGB` makes the hardware encode on write, which closes it for every pipeline
 at once rather than per shader: the mesh pass, materials, debug lines, and
 anything added later. The clear colour changes meaning with it — a clear value
 is specified in linear and encoded like everything else — which is the same
 rule the shaders now follow rather than a second one.

 Two consumers had to move with it, and one did not:

 - **The swapchain blit does convert.** `vkCmdBlitImage` reads an sRGB source
   *as linear* and re-encodes into an sRGB destination, so an `_SRGB` target
   blitted into a `_UNORM` swapchain would land back in linear and undo the
   fix at the very last step. `gpu/swapchain.c3` now prefers an sRGB surface
   format for exactly this reason, and says so.
 - **The readback does not convert.** `vkCmdCopyImageToBuffer` is a copy, not a
   blit — it moves the stored bytes untouched. So a screenshot now contains
   sRGB-encoded bytes, which is what a PNG is defined to hold.
 - **`scene.pick()` never touched this image.** It is a CPU raycast against the
   hull tree in `scene/pick.c3`, not a colour-buffer read, so it is unaffected.
   Worth stating because a colour-buffer picker is the usual design and would
   have been broken by this change.
*>
const vk::Format TARGET_COLOR_FORMAT = FORMAT_R8G8B8A8_SRGB;

struct Target
{
	vk::Extent2D extent;
	vk::Format color_format;
	vk::Format depth_format;
	vk::Image color;
	vk::ImageView color_view;
	vk::Memory color_memory;
	vk::Image depth;
	vk::ImageView depth_view;
	vk::Memory depth_memory;
}

<*
 @param width : `Independent of any window. Nothing here consults a surface.`
 @require width > 0 && height > 0
*>
fn Target? Target.init(&self, Gpu* gpu, uint width, uint height)
{
	self.extent = { .width = width, .height = height };
	self.color_format = TARGET_COLOR_FORMAT;
	self.depth_format = vk::findDepthFormat(
		features: FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT,
		device: gpu.pdevice
	);

	// TRANSFER_SRC is unconditional and that is the point: three.c3 created
	// this image, so there is no supportedUsageFlags to mask against and no
	// screenshot_supported flag to carry around like cui has to.
	self.color = vk::imageCreateInfo().setImageType(IMAGE_TYPE_2D).setFormat(self.color_format)
		.setExtent({ .width = width, .height = height, .depth = 1 })
		.setMipLevels(1)
		.setArrayLayers(1)
		.setSamples(SAMPLE_COUNT_1_BIT)
		.setTiling(IMAGE_TILING_OPTIMAL)
		.setUsage(IMAGE_USAGE_COLOR_ATTACHMENT_BIT | IMAGE_USAGE_TRANSFER_SRC_BIT)
		.setInitialLayout(IMAGE_LAYOUT_UNDEFINED)
		.build(gpu.handle)!;
	self.color_memory = vk::create_image_buffer(self.color, &gpu.allocator, MEMORY_PROPERTY_DEVICE_LOCAL_BIT)!;

	self.color_view = vk::imageViewCreateInfo().setViewType(IMAGE_VIEW_TYPE_2D).setFormat(self.color_format)
		.setSubresourceRange(
			{ .aspectMask = IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 }
		)
		.setImage(self.color)
		.build(gpu.handle)!;

	self.depth = vk::imageCreateInfo().setImageType(IMAGE_TYPE_2D).setFormat(self.depth_format)
		.setExtent({ .width = width, .height = height, .depth = 1 })
		.setMipLevels(1)
		.setArrayLayers(1)
		.setSamples(SAMPLE_COUNT_1_BIT)
		.setTiling(IMAGE_TILING_OPTIMAL)
		.setUsage(IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT)
		.setInitialLayout(IMAGE_LAYOUT_UNDEFINED)
		.build(gpu.handle)!;
	self.depth_memory = vk::create_image_buffer(self.depth, &gpu.allocator, MEMORY_PROPERTY_DEVICE_LOCAL_BIT)!;

	self.depth_view = vk::imageViewCreateInfo().setViewType(IMAGE_VIEW_TYPE_2D).setFormat(self.depth_format)
		.setSubresourceRange(
			{ .aspectMask = IMAGE_ASPECT_DEPTH_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 }
		)
		.setImage(self.depth)
		.build(gpu.handle)!;

	return *self;
}

<*
 `vk::Memory.free` destroys the image it was bound to, so the images must not
 be destroyed again here — the views are the only extra.
*>
fn void Target.free(&self, Gpu* gpu)
{
	if (self.color_view != null) self.color_view.free(gpu.handle);
	if (self.depth_view != null) self.depth_view.free(gpu.handle);
	self.color_memory.free();
	self.depth_memory.free();
	*self = { };
}

// ============================================================================
// The render pass — dynamic rendering, no VkRenderPass and no VkFramebuffer
// ============================================================================

fn vk::ImageMemoryBarrier2 Target.to_color_attachment(&self)
{
	return {
		.sType = STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
		.image = self.color,
		// ALL_COMMANDS with no source access is an execution dependency and
		// nothing more, which is exactly what the hazard here needs: last
		// frame *read* this image (blit, or readback copy) and this frame
		// writes it. Write-after-read wants ordering, not a cache flush.
		.srcStageMask = PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
		.srcAccessMask = (vk::AccessFlags2)0,
		.dstStageMask = PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
		.dstAccessMask = ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
		// The contents are cleared on load, so there is nothing to preserve.
		.oldLayout = IMAGE_LAYOUT_UNDEFINED,
		.newLayout = IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
		.subresourceRange = {
			.aspectMask = IMAGE_ASPECT_COLOR_BIT,
			.baseMipLevel = 0,
			.levelCount = 1,
			.baseArrayLayer = 0,
			.layerCount = 1,
		},
	};
}

fn vk::ImageMemoryBarrier2 Target.to_transfer_src(&self)
{
	return {
		.sType = STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
		.image = self.color,
		.srcStageMask = PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
		.srcAccessMask = ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
		.dstStageMask = PIPELINE_STAGE_2_ALL_TRANSFER_BIT,
		.dstAccessMask = ACCESS_2_TRANSFER_READ_BIT,
		.oldLayout = IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
		.newLayout = IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
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
 Transition in, begin dynamic rendering, and set a full-target viewport.

 The viewport height is negative, which flips Y so glTF's coordinate system
 lands the right way up in Vulkan's. Every projection matrix in this project
 assumes it.

 @param clear : `sRGB - the same units a script writes scene.background in - and decoded here. The attachment carries the sRGB transfer function, so Vulkan encodes whatever it is handed; an already-linear value would come out as a far too bright frame with nothing in the API saying which space it wanted. Alpha passes through untouched.`
*>
fn void Target.begin_render(&self, vk::CommandBuffer cmd, float[4] clear = { 0, 0, 0, 1 })
{
	// The one colour in the renderer that never meets a shader, so the one that
	// cannot be decoded where the others are. `gpu/color.c3` says why the curve
	// is the piecewise one.
	float[4] clear_linear = srgb_to_linear_rgb(clear);
	vk::ImageMemoryBarrier2[2] barriers = { self.to_color_attachment(), vk::depthBarrier(self.depth) };
	vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo().setImageMemoryBarriers(barriers[..]));

	vk::RenderingAttachmentInfo color_attachment = vk::renderingAttachmentInfo().setImageView(self.color_view)
		.setImageLayout(IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL)
		.setLoadOp(ATTACHMENT_LOAD_OP_CLEAR)
		.setStoreOp(ATTACHMENT_STORE_OP_STORE)
		.setClearValue({ .color = { .float32 = clear_linear } });

	vk::RenderingAttachmentInfo depth_attachment = vk::renderingAttachmentInfo().setImageView(self.depth_view)
		.setImageLayout(IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL)
		.setLoadOp(ATTACHMENT_LOAD_OP_CLEAR)
		.setStoreOp(ATTACHMENT_STORE_OP_STORE)
		.setClearValue({ .depthStencil = { 1.0, 0 } });

	vk::RenderingInfo rendering = vk::renderingInfo().setRenderArea({ .extent = self.extent }).setLayerCount(1)
		.setColorAttachments({ color_attachment })
		.setDepthAttachment(&depth_attachment);

	vk::cmdBeginRendering(cmd, &rendering);

	float width  = (float)self.extent.width;
	float height = (float)self.extent.height;
	vk::cmdSetViewport(
		cmd,
		0,
		1,
		(vk::Viewport[]) { { .x = 0, .y = height, .width = width, .height = -height, .minDepth = 0.0, .maxDepth = 1.0 } }
	);
	vk::cmdSetScissor(cmd, 0, 1, (vk::Rect2D[]) { { .offset = { 0, 0 }, .extent = self.extent } });
}

<*
 End rendering and leave the colour image in TRANSFER_SRC_OPTIMAL, ready for
 the swapchain blit, the readback copy, both, or neither.
*>
fn void Target.end_render(&self, vk::CommandBuffer cmd)
{
	vk::cmdEndRendering(cmd);
	vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo().setImageMemoryBarriers({ self.to_transfer_src() }));
}

// ============================================================================
// Readback — the screenshot
// ============================================================================

fn sz Target.readback_size(&self) => (sz)self.extent.width * (sz)self.extent.height * 4;

<*
 A host-visible buffer big enough for one frame of the colour target.

 Freed by the caller once the fence guarding the copy has signalled — the copy
 is recorded into the frame's command buffer, so the GPU is still reading this
 when the call returns.
*>
fn vk::Memory? Target.create_readback(&self, Gpu* gpu)
{
	return vk::new_buffer(
		&gpu.allocator,
		usage: BUFFER_USAGE_TRANSFER_DST_BIT,
		properties: MEMORY_PROPERTY_HOST_VISIBLE_BIT | MEMORY_PROPERTY_HOST_COHERENT_BIT,
		data_size: self.readback_size(),
	);
}

<*
 Record the copy. The colour image must already be in TRANSFER_SRC_OPTIMAL,
 which `end_render` guarantees.

 `bufferRowLength` and `bufferImageHeight` of zero mean tightly packed to
 `imageExtent`, so the destination is exactly `readback_size()` bytes with no
 row padding to unpick on the way out.
*>
fn void Target.record_readback(&self, vk::CommandBuffer cmd, vk::Memory* dst)
{
	vk::BufferImageCopy region = {
		.bufferOffset = 0,
		.bufferRowLength = 0,
		.bufferImageHeight = 0,
		.imageSubresource = { .aspectMask = IMAGE_ASPECT_COLOR_BIT, .mipLevel = 0, .baseArrayLayer = 0, .layerCount = 1 },
		.imageOffset = { 0, 0, 0 },
		.imageExtent = { self.extent.width, self.extent.height, 1 },
	};
	vk::cmdCopyImageToBuffer(cmd, self.color, IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, dst.buffer, 1, &region);
}

<*
 Copy the readback buffer into an owned `image::Image`.

 Only safe once the fence guarding `record_readback` has signalled. The target
 is `R8G8B8A8_SRGB`, so this is a memcpy and there is no channel swizzle
 anywhere in this project.

 Alpha is forced opaque: a half-transparent PNG of a finished frame is never
 what was wanted, and it is the difference between a screenshot that looks
 right in a viewer and one that does not.

 @return `An Image owning its pixels — free it with Image.free.`
*>
fn image::Image Target.decode_readback(&self, vk::Memory* src, alloc::Allocator allocator = mem)
{
	sz size      = self.readback_size();
	char[] bytes = alloc::new_array(allocator, char, size);
	mem::copy(bytes.ptr, src.data(), size);
	for (sz i = 3; i < size; i += 4) bytes[i] = 0xff;

	return {
		.width = self.extent.width,
		.height = self.extent.height,
		.bit_depth = 8,
		.format = image::PixelFormat.RGBA,
		.pixels = bytes,
		.allocator = allocator,
	};
}

fn void? write_png(image::Image* img, String path)
{
	png::save_file(img, path)!;
}
