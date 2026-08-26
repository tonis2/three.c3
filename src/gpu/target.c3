<*
 The offscreen colour+depth attachment, and its readback.

 Everything draws here; nothing ever draws into a swapchain image. The swapchain
 blits this (`gpu/swapchain.c3`) and the screenshot copies it — both are
 consumers. Three things follow:

 - The extent is a parameter, not the window's. A resize rebuilds the swapchain
   and moves the blit's destination rect; it does not touch the target, the depth
   buffer, the pipeline or the projection.
 - `R8G8B8A8_SRGB`, so readback is a straight memcpy and the bytes are already
   display-ready. The channel order is what makes the memcpy work; the `_SRGB`
   half is what makes the *values* right, which is a separate claim — see below.
 - Headless is the same code path. No surface, no swapchain, and render +
   readback still work, which is what makes an image test possible under
   `c3c test` with no window server.

 ## The layout contract

 The colour image cycles through exactly two layouts, both set here:

	begin_render   UNDEFINED                -> COLOR_ATTACHMENT_OPTIMAL
	close          COLOR_ATTACHMENT_OPTIMAL -> TRANSFER_SRC_OPTIMAL

 After `close` the image is ready for either consumer with no further
 transition, and the next frame's `UNDEFINED` discards contents it is about to
 clear anyway. Anything reading the colour image outside that window is reading
 it in TRANSFER_SRC_OPTIMAL.
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

 Textures upload as `R8G8B8A8_SRGB` (`gpu/texture.c3`), so the sampler decodes to
 linear on read and the shaders' lighting arithmetic is linear. Under `_UNORM`
 nothing re-encoded on the way out: the shader's linear float landed in eight
 bits raw, and both consumers then treated those bits as sRGB — the swapchain
 because it presents to an sRGB display, the screenshot because a PNG with no
 chunk saying otherwise *is* sRGB. One decode, no encode, so every textured scene
 came out about 2.2 too dark. It is invisible to any test that only asks the
 renderer to agree with itself.

 `_SRGB` makes the hardware encode on write, closing it for every pipeline at
 once rather than per shader. The clear colour changes meaning with it — a clear
 value is specified in linear and encoded like everything else.

 Two consumers had to move with it, and one did not:

 - The swapchain blit *does* convert. `vkCmdBlitImage` reads an sRGB source as
   linear and re-encodes into an sRGB destination, so an `_SRGB` target blitted
   into a `_UNORM` swapchain would land back in linear and undo the fix at the
   last step. `gpu/swapchain.c3` prefers an sRGB surface format for this reason.
 - The readback does *not* convert. `vkCmdCopyImageToBuffer` is a copy, not a
   blit — it moves the stored bytes untouched, so a screenshot contains
   sRGB-encoded bytes, which is what a PNG is defined to hold.
 - `scene.pick()` never touched this image: it is a CPU raycast against the hull
   tree in `scene/pick.c3`. Worth stating because a colour-buffer picker is the
   usual design and would have been broken by this change.
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
	// Both features, for `ShadowMap.ensure`'s reason. The depth buffer is an
	// attachment first and a sampled image second — `p.depth` in a post body
	// reads it — and a format that could be written and not read would fail at
	// the descriptor write rather than here. D32_SFLOAT is required by the spec
	// to do both, so this narrows nothing on a conformant device.
	self.depth_format = vk::findDepthFormat(
		features: FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT | FORMAT_FEATURE_SAMPLED_IMAGE_BIT,
		device: gpu.pdevice
	);

	// TRANSFER_SRC is unconditional, and that is the point: three.c3 created this
	// image, so there is no supportedUsageFlags to mask against and no
	// screenshot_supported flag to carry around.
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
		// SAMPLED as well as ATTACHMENT, and unconditionally: the post chain binds
		// this image to every pass so a body can read `p.depth`. Costs nothing on
		// a device where the format supports both, which is every conformant one.
		.setUsage(IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT | IMAGE_USAGE_SAMPLED_BIT)
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
 `vk::Memory.free` destroys the image it was bound to, so the images must not be
 destroyed again here — the views are the only extra.
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

<*
 The parts every image barrier in this project agrees on: the type tag, and one
 mip level of the colour aspect of a single-layer image.

 Splatted rather than passed as arguments — `{ ...IMAGE_BARRIER, .image = x, … }`
 — so each barrier below still names every field it sets. A function taking four
 stage and access masks positionally would read as eight interchangeable flags at
 the call site, and transposing a source with a destination produces a barrier
 that validates and still races.

 `DEPTH_LEVEL` and the mip chain in `texture.c3` splat the range in turn, so
 every barrier in the project states its layers exactly here and nowhere else.
 Image *views* and blit subresource *layers* are a different struct and keep
 their own.
*>
const vk::ImageSubresourceRange COLOR_LEVEL = {
	.aspectMask = IMAGE_ASPECT_COLOR_BIT,
	.baseMipLevel = 0,
	.levelCount = 1,
	.baseArrayLayer = 0,
	.layerCount = 1,
};
const vk::ImageSubresourceRange DEPTH_LEVEL = { ...COLOR_LEVEL, .aspectMask = IMAGE_ASPECT_DEPTH_BIT };
const vk::ImageMemoryBarrier2 IMAGE_BARRIER = {
	.sType = STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
	.subresourceRange = COLOR_LEVEL,
};

<*
 The barrier a colour attachment is opened with, for whichever image the pass is
 about to write.

 Takes the image rather than reading `self.color`, and sits beside
 `vk::depthBarrier` rather than being a method, because the scene does not always
 draw into the target: a pass that post-processes it draws into `self.color`
 while the scene draws into an image that pass then samples. `begin_render_to` is
 the other half.
*>
fn vk::ImageMemoryBarrier2 color_attachment_barrier(vk::Image image)
{
	// The contents are cleared on load, so UNDEFINED preserves nothing that
	// matters. ALL_COMMANDS with no source access is an execution dependency and
	// nothing more, which is what this hazard needs: last frame *read* this image
	// (blit, or readback copy) and this frame writes it. Write-after-read wants
	// ordering, not a cache flush.
	return { ...IMAGE_BARRIER,
		.image = image,
		.srcStageMask = PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
		.srcAccessMask = (vk::AccessFlags2)0,
		.dstStageMask = PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
		.dstAccessMask = ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
		.oldLayout = IMAGE_LAYOUT_UNDEFINED,
		.newLayout = IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
	};
}

fn vk::ImageMemoryBarrier2 Target.to_transfer_src(&self)
{
	return { ...IMAGE_BARRIER,
		.image = self.color,
		.srcStageMask = PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
		.srcAccessMask = ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
		.dstStageMask = PIPELINE_STAGE_2_ALL_TRANSFER_BIT,
		.dstAccessMask = ACCESS_2_TRANSFER_READ_BIT,
		.oldLayout = IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
		.newLayout = IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
	};
}

<*
 The other way a finished colour attachment can be consumed: read by a later pass
 in the same command buffer instead of copied out of.

 Never `self.color`, whose two-layout contract is at the top of this file — this
 is for an image a pass renders into so the next pass can sample it, a
 write-then-read inside one submission, which needs access masks a layout change
 alone would not give.
*>
fn vk::ImageMemoryBarrier2 shader_read_barrier(vk::Image image)
{
	return { ...IMAGE_BARRIER,
		.image = image,
		.srcStageMask = PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
		.srcAccessMask = ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
		.dstStageMask = PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT,
		.dstAccessMask = ACCESS_2_SHADER_SAMPLED_READ_BIT,
		.oldLayout = IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
		.newLayout = IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
	};
}

<*
 The depth attachment, finished being written and about to be sampled.

 `shader_read_barrier`'s shape over the depth aspect. Both differences are
 forced: the source stage is the fragment tests rather than colour output,
 because that is what wrote it, and the destination layout is
 `DEPTH_STENCIL_READ_ONLY_OPTIMAL` rather than `SHADER_READ_ONLY_OPTIMAL`.

 Issued once per frame by `PostPass.record_chain`, beside the one for image A.
 There is no barrier back: `vk::depthBarrier` opens the next frame's geometry
 pass from `UNDEFINED`, discarding contents this pass has finished reading.

 Only the post chain reads depth, and only when there is a chain — a frame with
 no post shader renders straight into `target.color` and never issues this.
*>
fn vk::ImageMemoryBarrier2 depth_read_barrier(vk::Image image)
{
	return { ...IMAGE_BARRIER,
		.image = image,
		.srcStageMask = PIPELINE_STAGE_2_EARLY_FRAGMENT_TESTS_BIT | PIPELINE_STAGE_2_LATE_FRAGMENT_TESTS_BIT,
		.srcAccessMask = ACCESS_2_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
		.dstStageMask = PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT,
		.dstAccessMask = ACCESS_2_SHADER_SAMPLED_READ_BIT,
		.oldLayout = IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
		.newLayout = IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL,
		.subresourceRange = DEPTH_LEVEL,
	};
}

<*
 Transitions in, begins dynamic rendering, and sets a full-target viewport —
 into the target's own colour image.

 @param clear : `sRGB - the same units a script writes scene.background in - and decoded here. The attachment carries the sRGB transfer function, so Vulkan encodes whatever it is handed; an already-linear value would come out as a far too bright frame with nothing in the API saying which space it wanted. Alpha passes through untouched.`
*>
fn void Target.begin_render(&self, vk::CommandBuffer cmd, float[4] clear = { 0, 0, 0, 1 })
	=> self.begin_render_to(cmd, self.color, self.color_view, clear);

<*
 The same, into a colour image that is not necessarily the target's.

 The extent, the depth buffer and the viewport are still the target's — only
 where the colour lands varies, because a pass that reads the frame back out
 (post-processing) needs the scene in an image it can sample while still sharing
 the depth attachment and the geometry it was drawn with. Every such image is
 created at `self.extent`; nothing here rescales.

 The viewport height is negative, which flips Y so glTF's coordinate system lands
 the right way up in Vulkan's. Every projection matrix in this project assumes it.

 @param image : `The colour image being written. Its layout is not read - the barrier discards whatever was there.`
 @param view : `A view of image, and the attachment's format follows the image's, not the target's.`
*>
fn void Target.begin_render_to(
	&self,
	vk::CommandBuffer cmd,
	vk::Image image,
	vk::ImageView view,
	float[4] clear = { 0, 0, 0, 1 }
)
{
	// The one colour in the renderer that never meets a shader, so the one that
	// cannot be decoded where the others are. `gpu/color.c3` says why the curve
	// is the piecewise one.
	float[4] clear_linear = srgb_to_linear_rgb(clear);
	vk::ImageMemoryBarrier2[2] barriers = { color_attachment_barrier(image), vk::depthBarrier(self.depth) };
	vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo().setImageMemoryBarriers(barriers[..]));

	vk::RenderingAttachmentInfo color_attachment = vk::renderingAttachmentInfo().setImageView(view)
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

	set_full_viewport(cmd, self.extent, true);
}

<*
 Viewport and scissor over the whole of `extent`, as every pass in the project
 sets them.

 Both are dynamic state on every pipeline here, so each pass sets them after
 `cmdBeginRendering` rather than baking them in — which lets one pipeline serve a
 window that resizes.

 @param flip_y : `Negative height, putting +Y up. Every pass that rasterises geometry wants it; the post chain, which draws a full-screen triangle in clip space and samples with uv, does not.`
*>
fn void set_full_viewport(vk::CommandBuffer cmd, vk::Extent2D extent, bool flip_y)
{
	float width  = (float)extent.width;
	float height = (float)extent.height;
	vk::cmdSetViewport(
		cmd,
		0,
		1,
		(vk::Viewport[]) { {
			.x = 0,
			.y = flip_y ? height : 0,
			.width = width,
			.height = flip_y ? -height : height,
			.minDepth = 0.0,
			.maxDepth = 1.0,
		} }
	);
	vk::cmdSetScissor(cmd, 0, 1, (vk::Rect2D[]) { { .offset = { 0, 0 }, .extent = extent } });
}

<*
 Hands the colour image to whatever reads it next.

 Split out because the frame is a list and the close happens exactly once, at the
 end of it — see `Renderer.record_scene`. With a post chain running it is the
 tonemap that ends the last rendering rather than the scene, and the close is the
 same either way; keeping them fused would mean two spellings of "the frame is
 finished".
*>
fn void Target.close(&self, vk::CommandBuffer cmd)
{
	vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo().setImageMemoryBarriers({ self.to_transfer_src() }));
}

// ============================================================================
// Readback — the screenshot
// ============================================================================

fn sz Target.readback_size(&self) => (sz)self.extent.width * (sz)self.extent.height * 4;

<*
 A host-visible buffer big enough for one frame of the colour target.

 Freed by the caller once the fence guarding the copy has signalled — the copy is
 recorded into the frame's command buffer, so the GPU is still reading this when
 the call returns.
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
 Records the copy. The colour image must already be in TRANSFER_SRC_OPTIMAL,
 which `close` guarantees.

 `bufferRowLength` and `bufferImageHeight` of zero mean tightly packed to
 `imageExtent`, so the destination is exactly `readback_size()` bytes with no row
 padding to unpick on the way out.
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
 Copies the readback buffer into an owned `image::Image`.

 Only safe once the fence guarding `record_readback` has signalled. The target is
 `R8G8B8A8_SRGB`, so this is a memcpy and there is no channel swizzle anywhere in
 this project.

 Alpha is forced opaque: a half-transparent PNG of a finished frame is never what
 was wanted, and it is the difference between a screenshot that looks right in a
 viewer and one that does not.

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
