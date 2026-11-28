<*
 The offscreen colour+depth attachment, and its readback.

 Everything draws here, but a headset's eye images, which the scene can write
 itself (`SceneTone`). The window's swapchain blits this (`gpu/swapchain.c3`)
 and the screenshot copies it — both are consumers. Three things follow:

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
	// Where the scene and the prepass shade coarsely; none unless the device was
	// opened for a headset that can.
	FoveationMap foveation;

	// The views the scene is drawn in, each into its own layer of the depth and
	// the scene images, with one draw for all of them. 1 is the ordinary target;
	// 2 is a headset's eyes, side by side in `color`.
	uint views;
	// One view's layer: `extent` itself with one view, half its width with two.
	vk::Extent2D view_extent;
	// Each layer of the depth image alone, for a pass that samples one eye.
	vk::ImageView[MAX_VIEWS] depth_layers;

	// Samples per pixel the scene draws with. Above one the scene draws into
	// `msaa_color` and `msaa_depth`, which never leave the tile on a tiler, and
	// resolves into the scene image and `depth` as the rendering ends.
	vk::SampleCountFlagBits samples;
	// In `POST_CHAIN_FORMAT`, the scene image's, a layer per view. Absent at one sample.
	LayeredImage msaa_color;
	LayeredImage msaa_depth;
	// In `TARGET_COLOR_FORMAT`, for a multiview scene that writes a headset's
	// eye images itself (`SceneTone`). Absent at one sample or one view.
	LayeredImage msaa_display;
}

<*
 The most samples up to `wanted` that the device draws colour and depth with.
*>
fn vk::SampleCountFlagBits msaa_samples(Gpu* gpu, uint wanted)
{
	for (uint count = 8; count > 1; count /= 2)
	{
		if (count <= wanted && ((uint)gpu.limits.msaa_counts & count)) return (vk::SampleCountFlagBits)count;
	}
	return SAMPLE_COUNT_1_BIT;
}

<*
 The view mask a rendering over every view of this target draws with: 0 for
 the ordinary one-view target, one bit per view otherwise.
*>
fn uint Target.view_mask(&self) => self.views > 1 ? (1u << self.views) - 1 : 0;

fn vk::ImageView Target.depth_layer(&self, uint view) => self.views > 1 ? self.depth_layers[view] : self.depth_view;

<*
 @param width : `Independent of any window. Nothing here consults a surface.`
 @param views : "Views drawn side by side in one multiview pass; more than one only where the device has multiview"
 @param samples : "Samples per pixel for the scene, MSAA above one; the device's most below it when it has fewer"
 @require width > 0 && height > 0
 @require views >= 1 && views <= MAX_VIEWS && width >= views : "Between one view and MAX_VIEWS"
 @require samples >= 1 : "At least one sample"
*>
fn Target? Target.init(&self, Gpu* gpu, uint width, uint height, uint views = 1, uint samples = 1)
{
	self.extent = { .width = width, .height = height };
	self.views = views > 1 && gpu.limits.multiview ? views : 1;
	self.view_extent = { .width = width / self.views, .height = height };
	self.color_format = TARGET_COLOR_FORMAT;
	// Both features, for the shared shadow atlas's reason. The depth buffer is an
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
	GpuImage color = gpu.create_image_2d(self.color_format, self.extent,
		IMAGE_USAGE_COLOR_ATTACHMENT_BIT | IMAGE_USAGE_TRANSFER_SRC_BIT)!;
	defer catch color.destroy(gpu);
	// SAMPLED as well as ATTACHMENT, and unconditionally: the post chain binds
	// this image to every pass so a body can read `p.depth`.
	// One layer per view; TRANSFER_SRC so the eyes can be copied side by side
	// for a script's post pass.
	LayeredImage depth = gpu.create_layered_image(self.depth_format, self.view_extent, self.views,
		IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT | IMAGE_USAGE_SAMPLED_BIT | IMAGE_USAGE_TRANSFER_SRC_BIT,
		IMAGE_ASPECT_DEPTH_BIT)!;
	defer catch depth.destroy(gpu);

	self.samples = msaa_samples(gpu, samples);
	LayeredImage msaa_color;
	LayeredImage msaa_depth;
	LayeredImage msaa_display;
	defer catch msaa_color.destroy(gpu);
	defer catch msaa_depth.destroy(gpu);
	defer catch msaa_display.destroy(gpu);
	if (self.samples != SAMPLE_COUNT_1_BIT)
	{
		vk::ImageUsageFlags transient = IMAGE_USAGE_COLOR_ATTACHMENT_BIT | IMAGE_USAGE_TRANSIENT_ATTACHMENT_BIT;
		msaa_color = gpu.create_layered_image(POST_CHAIN_FORMAT, self.view_extent, self.views, transient,
			samples: self.samples)!;
		msaa_depth = gpu.create_layered_image(self.depth_format, self.view_extent, self.views,
			IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT | IMAGE_USAGE_TRANSIENT_ATTACHMENT_BIT, IMAGE_ASPECT_DEPTH_BIT,
			samples: self.samples)!;
		if (self.views > 1)
		{
			msaa_display = gpu.create_layered_image(TARGET_COLOR_FORMAT, self.view_extent, self.views, transient,
				samples: self.samples)!;
		}
	}
	FoveationMap foveation;
	if (gpu.limits.fragment_density_map) foveation.init(gpu, self.view_extent, self.views, Foveation.MEDIUM)!;

	self.msaa_color = msaa_color;
	self.msaa_depth = msaa_depth;
	self.msaa_display = msaa_display;
	self.color = color.image;
	self.color_view = color.view;
	self.color_memory = color.memory;
	self.depth = depth.whole.image;
	self.depth_view = depth.whole.view;
	self.depth_memory = depth.whole.memory;
	self.depth_layers = depth.layers;
	self.foveation = foveation;

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
	foreach (view : self.depth_layers) if (view != null) view.free(gpu.handle);
	self.color_memory.free();
	self.depth_memory.free();
	self.msaa_color.destroy(gpu);
	self.msaa_depth.destroy(gpu);
	self.msaa_display.destroy(gpu);
	self.foveation.free(gpu);
	*self = { };
}

// ============================================================================
// The render pass — dynamic rendering, no VkRenderPass and no VkFramebuffer
// ============================================================================

<*
 The parts every image barrier in this project agrees on: the type tag, and one
 mip level of the colour aspect of every layer the image has.

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
	// Every layer, so one barrier opens or closes both eyes of a multiview image.
	.layerCount = vk::REMAINING_ARRAY_LAYERS,
};
const vk::ImageSubresourceRange DEPTH_LEVEL = { ...COLOR_LEVEL, .aspectMask = IMAGE_ASPECT_DEPTH_BIT };
const vk::ImageMemoryBarrier2 IMAGE_BARRIER = {
	.sType = STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
	.subresourceRange = COLOR_LEVEL,
};

<*
 The colour range of one layer, or of every layer for a negative one: what a
 barrier opening one eye of a layered image names, so opening the other eye's
 does not discard what the first one wrote.
*>
fn vk::ImageSubresourceRange color_layers(int layer)
{
	if (layer < 0) return COLOR_LEVEL;
	return { ...COLOR_LEVEL, .baseArrayLayer = (uint)layer, .layerCount = 1 };
}

<*
 The barrier a colour attachment is opened with, for whichever image the pass is
 about to write.

 Takes the image rather than reading `self.color`, and sits beside
 `depth_discard_barrier` rather than being a method, because the scene does not always
 draw into the target: a pass that post-processes it draws into `self.color`
 while the scene draws into an image that pass then samples. `begin_render_to` is
 the other half.

 @param layer : "The one layer to open, or every layer when negative"
*>
fn vk::ImageMemoryBarrier2 color_attachment_barrier(vk::Image image, int layer = -1)
{
	// The contents are cleared on load, so UNDEFINED preserves nothing that
	// matters. ALL_COMMANDS with no source access is an execution dependency and
	// nothing more, which is what this hazard needs: last frame *read* this image
	// (blit, or readback copy) and this frame writes it. Write-after-read wants
	// ordering, not a cache flush.
	return {
		...IMAGE_BARRIER,
		.image = image,
		.srcStageMask = PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
		.srcAccessMask = (vk::AccessFlags2)0,
		.dstStageMask = PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
		.dstAccessMask = ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
		.oldLayout = IMAGE_LAYOUT_UNDEFINED,
		.newLayout = IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
		.subresourceRange = color_layers(layer),
	};
}

<*
 A colour attachment, finished, about to be the source of a copy or a blit.
*>
fn vk::ImageMemoryBarrier2 transfer_src_barrier(vk::Image image)
{
	return {
		...IMAGE_BARRIER,
		.image = image,
		.srcStageMask = PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
		.srcAccessMask = ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
		.dstStageMask = PIPELINE_STAGE_2_ALL_TRANSFER_BIT,
		.dstAccessMask = ACCESS_2_TRANSFER_READ_BIT,
		.oldLayout = IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
		.newLayout = IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
	};
}

<*
 The stages that read the post chain's images: a fragment pass's sampler and a
 compute pass's, either of which may be the next pass in the chain.

 Both on every barrier that hands an image to the chain - not the one stage the
 next pass happens to be - because which kind of pass comes next is a fact about
 the chain the barrier's caller does not have, and naming a stage nothing runs
 costs nothing. The cached-scene reopen below waits on the same pair for the
 same reason: last frame's readers of image A were either.
*>
const vk::PipelineStageFlags2 CHAIN_READERS = PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT | PIPELINE_STAGE_2_COMPUTE_SHADER_BIT;

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
	return {
		...IMAGE_BARRIER,
		.image = image,
		.srcStageMask = PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
		.srcAccessMask = ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
		.dstStageMask = CHAIN_READERS,
		.dstAccessMask = ACCESS_2_SHADER_SAMPLED_READ_BIT,
		.oldLayout = IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
		.newLayout = IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
	};
}

<*
 Opens an image a compute pass is about to write every texel of.

 `color_attachment_barrier`'s compute counterpart: from `UNDEFINED`, because the
 dispatch covers the image and nothing in it is worth keeping, into `GENERAL`,
 the one layout a storage image may be written in. An execution dependency on
 everything before it and no source access, for the same write-after-read reason
 - last frame sampled it, this frame overwrites it.

 @param layer : "The one layer to open, or every layer when negative"
*>
fn vk::ImageMemoryBarrier2 storage_open_barrier(vk::Image image, int layer = -1)
{
	return {
		...IMAGE_BARRIER,
		.image = image,
		.srcStageMask = PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
		.srcAccessMask = (vk::AccessFlags2)0,
		.dstStageMask = PIPELINE_STAGE_2_COMPUTE_SHADER_BIT,
		.dstAccessMask = ACCESS_2_SHADER_STORAGE_WRITE_BIT,
		.oldLayout = IMAGE_LAYOUT_UNDEFINED,
		.newLayout = IMAGE_LAYOUT_GENERAL,
		.subresourceRange = color_layers(layer),
	};
}

<*
 Closes an image a compute pass wrote, for the next pass to sample.

 `shader_read_barrier` from the other side: the writer was a compute shader's
 storage store rather than colour output, and the image leaves `GENERAL` for the
 same `SHADER_READ_ONLY_OPTIMAL` every chain image is read in - so the pass after
 a compute pass cannot tell what kind of pass made its input.
*>
fn vk::ImageMemoryBarrier2 storage_close_barrier(vk::Image image)
{
	return {
		...IMAGE_BARRIER,
		.image = image,
		.srcStageMask = PIPELINE_STAGE_2_COMPUTE_SHADER_BIT,
		.srcAccessMask = ACCESS_2_SHADER_STORAGE_WRITE_BIT,
		.dstStageMask = CHAIN_READERS,
		.dstAccessMask = ACCESS_2_SHADER_SAMPLED_READ_BIT,
		.oldLayout = IMAGE_LAYOUT_GENERAL,
		.newLayout = IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
	};
}

<*
 Orders one pass's storage-image writes before the next pass's reads and writes
 of the same images, which stay in `GENERAL` throughout: a memory barrier, since
 there is no layout to change and naming each image would add nothing.

 What makes a histogram one pass builds visible to the pass that reduces it, and
 what keeps a history image a pass rewrites from being read half-written.
*>
fn vk::MemoryBarrier2 storage_memory_barrier()
{
	return {
		.sType = STRUCTURE_TYPE_MEMORY_BARRIER_2,
		.srcStageMask = CHAIN_READERS,
		.srcAccessMask = ACCESS_2_SHADER_STORAGE_WRITE_BIT,
		.dstStageMask = CHAIN_READERS,
		.dstAccessMask = ACCESS_2_SHADER_STORAGE_READ_BIT | ACCESS_2_SHADER_STORAGE_WRITE_BIT,
	};
}

<*
 Makes what a compute pass wrote to storage buffers visible to the stage that
 reads it next.
*>
fn void compute_to_stage_barrier(vk::CommandBuffer cmd, vk::PipelineStageFlags2 reader)
{
	vk::MemoryBarrier2 barrier = {
		.sType = STRUCTURE_TYPE_MEMORY_BARRIER_2,
		.srcStageMask = PIPELINE_STAGE_2_COMPUTE_SHADER_BIT,
		.srcAccessMask = ACCESS_2_SHADER_STORAGE_WRITE_BIT,
		.dstStageMask = reader,
		.dstAccessMask = ACCESS_2_SHADER_STORAGE_READ_BIT,
	};
	vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo().setMemoryBarriers({ barrier }));
}

<*
 The depth attachment, finished being written and about to be sampled.

 `shader_read_barrier`'s shape over the depth aspect. The source is the
 fragment tests, which wrote it, and colour output too, where an MSAA resolve
 writes it. The destination layout is `DEPTH_STENCIL_READ_ONLY_OPTIMAL` rather
 than `SHADER_READ_ONLY_OPTIMAL`.

 Issued once per frame by `PostPass.record_chain`, beside the one for image A.
 There is no barrier back: `depth_discard_barrier` opens the next frame's geometry
 pass from `UNDEFINED`, discarding contents this pass has finished reading.

 Only the post chain reads depth, and only when there is a chain — a frame with
 no post shader renders straight into `target.color` and never issues this.
*>
fn vk::ImageMemoryBarrier2 depth_read_barrier(vk::Image image)
{
	return {
		...IMAGE_BARRIER,
		.image = image,
		.srcStageMask = PIPELINE_STAGE_2_EARLY_FRAGMENT_TESTS_BIT | PIPELINE_STAGE_2_LATE_FRAGMENT_TESTS_BIT
			| PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
		.srcAccessMask = ACCESS_2_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT | ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
		.dstStageMask = CHAIN_READERS,
		.dstAccessMask = ACCESS_2_SHADER_SAMPLED_READ_BIT,
		.oldLayout = IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
		.newLayout = IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL,
		.subresourceRange = DEPTH_LEVEL,
	};
}

<*
 A depth image a shader samples, opened again as an attachment. `discard` opens
 it from `UNDEFINED`, for a pass that clears it on load.
*>
fn vk::ImageMemoryBarrier2 depth_open_barrier(vk::Image image, bool discard)
{
	return {
		...IMAGE_BARRIER,
		.image = image,
		.srcStageMask = PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
		.dstStageMask = PIPELINE_STAGE_2_EARLY_FRAGMENT_TESTS_BIT | PIPELINE_STAGE_2_LATE_FRAGMENT_TESTS_BIT,
		.dstAccessMask = ACCESS_2_DEPTH_STENCIL_ATTACHMENT_READ_BIT | ACCESS_2_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
		.oldLayout = discard ? IMAGE_LAYOUT_UNDEFINED : IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
		.newLayout = IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
		.subresourceRange = DEPTH_LEVEL,
	};
}

<*
 A depth attachment, finished being written and about to be sampled by a
 fragment shader in `SHADER_READ_ONLY_OPTIMAL`.
*>
fn vk::ImageMemoryBarrier2 depth_sample_barrier(vk::Image image)
{
	return {
		...IMAGE_BARRIER,
		.image = image,
		.srcStageMask = PIPELINE_STAGE_2_EARLY_FRAGMENT_TESTS_BIT | PIPELINE_STAGE_2_LATE_FRAGMENT_TESTS_BIT,
		.srcAccessMask = ACCESS_2_DEPTH_STENCIL_ATTACHMENT_READ_BIT | ACCESS_2_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
		.dstStageMask = PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT,
		.dstAccessMask = ACCESS_2_SHADER_SAMPLED_READ_BIT,
		.oldLayout = IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
		.newLayout = IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
		.subresourceRange = DEPTH_LEVEL,
	};
}

<*
 The frame's depth buffer reopened as an attachment, contents kept. `sampled`
 when the post chain last read it in `DEPTH_STENCIL_READ_ONLY_OPTIMAL`.
*>
fn vk::ImageMemoryBarrier2 depth_reopen_barrier(vk::Image image, bool sampled)
{
	return {
		...IMAGE_BARRIER,
		.image = image,
		.srcStageMask = sampled ? CHAIN_READERS
			: PIPELINE_STAGE_2_EARLY_FRAGMENT_TESTS_BIT | PIPELINE_STAGE_2_LATE_FRAGMENT_TESTS_BIT,
		.srcAccessMask = sampled ? ACCESS_2_SHADER_SAMPLED_READ_BIT
			: ACCESS_2_DEPTH_STENCIL_ATTACHMENT_READ_BIT | ACCESS_2_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
		.dstStageMask = PIPELINE_STAGE_2_EARLY_FRAGMENT_TESTS_BIT | PIPELINE_STAGE_2_LATE_FRAGMENT_TESTS_BIT,
		.dstAccessMask = ACCESS_2_DEPTH_STENCIL_ATTACHMENT_READ_BIT | ACCESS_2_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
		.oldLayout = sampled ? IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL
			: IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
		.newLayout = IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
		.subresourceRange = DEPTH_LEVEL,
	};
}

<*
 Begins a depth-only rendering over `extent`, cleared to the far plane.
*>
fn void begin_depth_rendering(vk::CommandBuffer cmd, vk::ImageView view, vk::Extent2D extent, void* next = null,
	uint view_mask = 0)
{
	vk::RenderingAttachmentInfo depth_attachment = vk::renderingAttachmentInfo().setImageView(view)
		.setImageLayout(IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL)
		.setLoadOp(ATTACHMENT_LOAD_OP_CLEAR)
		.setStoreOp(ATTACHMENT_STORE_OP_STORE)
		.setClearValue({ .depthStencil = { 1.0, 0 } });

	vk::RenderingInfo rendering = vk::renderingInfo().setRenderArea({ .extent = extent }).setLayerCount(1)
		.setViewMask(view_mask)
		.setDepthAttachment(&depth_attachment)
		.setNext(next);

	vk::cmdBeginRendering(cmd, &rendering);
	set_full_viewport(cmd, extent, true);
}

<*
 Opens the depth buffer on its own, cleared, for the depth prepass.

 A rendering of its own rather than the first draws of the scene's, because the
 pipeline statistics query brackets the scene rendering and the prepass is not
 part of what `fragmentsShaded` is meant to measure. `begin_render` is then asked
 to keep what this left behind.

 `depth_discard_barrier` opens from `UNDEFINED`, which is right here for the same
 reason it is right there: the attachment is cleared on load.

 @require self.samples == SAMPLE_COUNT_1_BIT : "An MSAA prepass draws inside the scene rendering"
*>
fn void Target.begin_depth(&self, vk::CommandBuffer cmd)
{
	vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo().setImageMemoryBarriers({ depth_discard_barrier(self.depth) }));
	vk::RenderingFragmentDensityMapAttachmentInfoEXT density;
	begin_depth_rendering(cmd, self.depth_view, self.view_extent, self.foveation.attach(&density), self.view_mask());
}

<*
 Opens a depth attachment that is cleared on load, from `UNDEFINED`. Every
 layer, which `vk::depthBarrier` does not cover: a multiview depth has two.
*>
fn vk::ImageMemoryBarrier2 depth_discard_barrier(vk::Image image)
{
	return {
		...IMAGE_BARRIER,
		.image = image,
		.srcStageMask = PIPELINE_STAGE_2_EARLY_FRAGMENT_TESTS_BIT | PIPELINE_STAGE_2_LATE_FRAGMENT_TESTS_BIT,
		.dstStageMask = PIPELINE_STAGE_2_EARLY_FRAGMENT_TESTS_BIT | PIPELINE_STAGE_2_LATE_FRAGMENT_TESTS_BIT,
		.dstAccessMask = ACCESS_2_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
		.oldLayout = IMAGE_LAYOUT_UNDEFINED,
		.newLayout = IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
		.subresourceRange = DEPTH_LEVEL,
	};
}

<*
 Opens a single-sample depth buffer that an MSAA rendering resolves into, from
 `UNDEFINED`. A resolve writes in the colour output stage, depth included.
*>
fn vk::ImageMemoryBarrier2 depth_resolve_barrier(vk::Image image)
{
	return {
		...IMAGE_BARRIER,
		.image = image,
		.srcStageMask = PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
		.dstStageMask = PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
		.dstAccessMask = ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
		.oldLayout = IMAGE_LAYOUT_UNDEFINED,
		.newLayout = IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
		.subresourceRange = DEPTH_LEVEL,
	};
}

<*
 The depth attachment carried from one rendering into the next inside a frame.

 Not `depth_discard_barrier`, which comes from `UNDEFINED` and so discards — which is
 exactly what a prepass must not have happen to its result.
*>
fn vk::ImageMemoryBarrier2 depth_keep_barrier(vk::Image image)
{
	return {
		...IMAGE_BARRIER,
		.image = image,
		.srcStageMask = PIPELINE_STAGE_2_EARLY_FRAGMENT_TESTS_BIT | PIPELINE_STAGE_2_LATE_FRAGMENT_TESTS_BIT,
		.srcAccessMask = ACCESS_2_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
		.dstStageMask = PIPELINE_STAGE_2_EARLY_FRAGMENT_TESTS_BIT | PIPELINE_STAGE_2_LATE_FRAGMENT_TESTS_BIT,
		.dstAccessMask = ACCESS_2_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT | ACCESS_2_DEPTH_STENCIL_ATTACHMENT_READ_BIT,
		.oldLayout = IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
		.newLayout = IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
		.subresourceRange = DEPTH_LEVEL,
	};
}

<*
 Transitions in, begins dynamic rendering, and sets a full-target viewport —
 into the target's own colour image.

 @param clear : `sRGB - the same units a script writes scene.background in - and decoded here. The attachment carries the sRGB transfer function, so Vulkan encodes whatever it is handed; an already-linear value would come out as a far too bright frame with nothing in the API saying which space it wanted. Alpha passes through untouched.`
 @require self.views == 1 : "A multiview target's colour holds the eyes side by side, not a layer each"
*>
fn void Target.begin_render(
	&self,
	vk::CommandBuffer cmd,
	float[4] clear = { 0, 0, 0, 1 },
	bool keep_depth = false,
	bool store_depth = true
) => self.begin_render_to(cmd, self.color, self.color_view, clear, keep_depth, store_depth, self.color_format);

<*
 The same, into a colour image that is not necessarily the target's.

 The extent, the depth buffer and the viewport are still the target's — only
 where the colour lands varies, because a pass that reads the frame back out
 (post-processing) needs the scene in an image it can sample while still sharing
 the depth attachment and the geometry it was drawn with. Every such image is
 created at `self.extent`; nothing here rescales.

 The viewport height is negative, which flips Y so glTF's coordinate system lands
 the right way up in Vulkan's. Every projection matrix in this project assumes it.

 With MSAA the scene draws into the target's multisampled images and resolves
 into `view` and the depth buffer as the rendering ends; the samples themselves
 are never stored.

 @param image : `The colour image being written. Its layout is not read - the barrier discards whatever was there.`
 @param view : `A view of image, and the attachment's format follows the image's, not the target's.`
 @param format : "The image's format, which MSAA samples are drawn in"
 @require self.samples == SAMPLE_COUNT_1_BIT || !keep_depth : "MSAA depth is not kept between renderings"
 @require self.samples == SAMPLE_COUNT_1_BIT || format == POST_CHAIN_FORMAT || (format == TARGET_COLOR_FORMAT && self.msaa_display.exists())
	: "MSAA samples come in the scene's float format, or the display's on a multiview target"
*>
fn void Target.begin_render_to(
	&self,
	vk::CommandBuffer cmd,
	vk::Image image,
	vk::ImageView view,
	float[4] clear = { 0, 0, 0, 1 },
	bool keep_depth = false,
	bool store_depth = true,
	vk::Format format = POST_CHAIN_FORMAT
)
{
	// The one colour in the renderer that never meets a shader, so the one that
	// cannot be decoded where the others are. `gpu/color.c3` says why the curve
	// is the piecewise one.
	float[4] clear_linear               = srgb_to_linear_rgb(clear);
	bool msaa                           = self.samples != SAMPLE_COUNT_1_BIT;
	LayeredImage* samples               = format == TARGET_COLOR_FORMAT ? &self.msaa_display : &self.msaa_color;
	vk::ImageMemoryBarrier2[4] barriers;
	barriers[0] = color_attachment_barrier(image);
	barriers[1] = keep_depth ? depth_keep_barrier(self.depth) : depth_discard_barrier(self.depth);
	if (msaa)
	{
		// The depth buffer is opened even when nothing resolves into it, because
		// the post chain closes it from the attachment layout either way.
		barriers[1] = depth_resolve_barrier(self.depth);
		barriers[2] = color_attachment_barrier(samples.whole.image);
		barriers[3] = depth_discard_barrier(self.msaa_depth.whole.image);
	}
	vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo().setImageMemoryBarriers(barriers[:msaa ? 4 : 2]));

	vk::RenderingAttachmentInfo color_attachment = vk::renderingAttachmentInfo().setImageView(view)
		.setImageLayout(IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL)
		.setLoadOp(ATTACHMENT_LOAD_OP_CLEAR)
		.setStoreOp(ATTACHMENT_STORE_OP_STORE)
		.setClearValue({ .color = { .float32 = clear_linear } });

	vk::RenderingAttachmentInfo depth_attachment = vk::renderingAttachmentInfo().setImageView(self.depth_view)
		.setImageLayout(IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL)
		.setLoadOp(keep_depth ? ATTACHMENT_LOAD_OP_LOAD : ATTACHMENT_LOAD_OP_CLEAR)
		// Not written back when nothing reads it after the scene: on a tiled GPU
		// that is a whole depth image of memory traffic saved.
		.setStoreOp(store_depth ? ATTACHMENT_STORE_OP_STORE : ATTACHMENT_STORE_OP_DONT_CARE)
		.setClearValue({ .depthStencil = { 1.0, 0 } });

	if (msaa)
	{
		color_attachment = color_attachment.setImageView(samples.whole.view)
			.setStoreOp(ATTACHMENT_STORE_OP_DONT_CARE)
			.setResolveMode(RESOLVE_MODE_AVERAGE_BIT)
			.setResolveImageView(view)
			.setResolveImageLayout(IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL);
		depth_attachment = depth_attachment.setImageView(self.msaa_depth.whole.view)
			.setStoreOp(ATTACHMENT_STORE_OP_DONT_CARE);
		// The first sample's depth, which is a surface that is there; an average
		// across a silhouette would not be.
		if (store_depth)
		{
			depth_attachment = depth_attachment.setResolveMode(RESOLVE_MODE_SAMPLE_ZERO_BIT)
				.setResolveImageView(self.depth_view)
				.setResolveImageLayout(IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL);
		}
	}

	vk::RenderingFragmentDensityMapAttachmentInfoEXT density;
	vk::RenderingInfo rendering = vk::renderingInfo().setRenderArea({ .extent = self.view_extent }).setLayerCount(1)
		.setViewMask(self.view_mask())
		.setColorAttachments({ color_attachment })
		.setDepthAttachment(&depth_attachment)
		.setNext(self.foveation.attach(&density));

	vk::cmdBeginRendering(cmd, &rendering);

	set_full_viewport(cmd, self.view_extent, true);
}

<*
 Reopens a cached scene attachment and clears only the region which will be
 replayed. `sampled` describes the layouts left by a post chain; otherwise the
 colour is the final transfer source and depth is still an attachment.

 @require self.views == 1 : "The scene cache is for one view"
 @require self.samples == SAMPLE_COUNT_1_BIT : "The scene cache keeps no samples"
*>
fn void Target.begin_cached_render_to(
	&self,
	vk::CommandBuffer cmd,
	vk::Image image,
	vk::ImageView view,
	vk::Rect2D dirty,
	float[4] clear,
	bool sampled,
	bool keep_depth = false
)
{
	vk::ImageMemoryBarrier2 color = {
		...IMAGE_BARRIER,
		.image = image,
		.srcStageMask = sampled ? CHAIN_READERS : PIPELINE_STAGE_2_ALL_TRANSFER_BIT,
		.srcAccessMask = sampled ? ACCESS_2_SHADER_SAMPLED_READ_BIT : ACCESS_2_TRANSFER_READ_BIT,
		.dstStageMask = PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
		.dstAccessMask = ACCESS_2_COLOR_ATTACHMENT_READ_BIT | ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
		.oldLayout = sampled ? IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL : IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
		.newLayout = IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
	};
	vk::ImageMemoryBarrier2 depth = depth_reopen_barrier(self.depth, sampled && !keep_depth);
	vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo().setImageMemoryBarriers({ color, depth }));

	vk::RenderingAttachmentInfo color_attachment = vk::renderingAttachmentInfo().setImageView(view)
		.setImageLayout(IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL).setLoadOp(ATTACHMENT_LOAD_OP_LOAD)
		.setStoreOp(ATTACHMENT_STORE_OP_STORE);
	vk::RenderingAttachmentInfo depth_attachment = vk::renderingAttachmentInfo().setImageView(self.depth_view)
		.setImageLayout(IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL).setLoadOp(ATTACHMENT_LOAD_OP_LOAD)
		.setStoreOp(ATTACHMENT_STORE_OP_STORE);
	vk::RenderingFragmentDensityMapAttachmentInfoEXT density;
	vk::RenderingInfo rendering = vk::renderingInfo().setRenderArea({ .extent = self.extent }).setLayerCount(1)
		.setColorAttachments({ color_attachment }).setDepthAttachment(&depth_attachment)
		.setNext(self.foveation.attach(&density));
	vk::cmdBeginRendering(cmd, &rendering);

	float[4] clear_linear = srgb_to_linear_rgb(clear);
	vk::ClearAttachment[2] attachments = {
		{ .aspectMask = IMAGE_ASPECT_COLOR_BIT, .colorAttachment = 0,
			.clearValue = { .color = { .float32 = clear_linear } } },
		{ .aspectMask = IMAGE_ASPECT_DEPTH_BIT,
			.clearValue = { .depthStencil = { 1.0, 0 } } },
	};
	vk::ClearRect area = { .rect = dirty, .baseArrayLayer = 0, .layerCount = 1 };
	vk::cmdClearAttachments(cmd, keep_depth ? 1 : 2, &attachments[0], 1, &area);
	set_full_viewport(cmd, self.extent, true);
	vk::cmdSetScissor(cmd, 0, 1, (vk::Rect2D[]) { dirty });
}

<*
 Rebuilds depth only inside a cached scene's dirty region.
 @require self.views == 1 : "The scene cache is for one view"
 @require self.samples == SAMPLE_COUNT_1_BIT : "The scene cache keeps no samples"
*>
fn void Target.begin_cached_depth(&self, vk::CommandBuffer cmd, vk::Rect2D dirty, bool sampled)
{
	vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo().setImageMemoryBarriers({ depth_reopen_barrier(self.depth, sampled) }));
	vk::RenderingAttachmentInfo attachment = vk::renderingAttachmentInfo().setImageView(self.depth_view)
		.setImageLayout(IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL)
		.setLoadOp(ATTACHMENT_LOAD_OP_LOAD).setStoreOp(ATTACHMENT_STORE_OP_STORE);
	vk::RenderingFragmentDensityMapAttachmentInfoEXT density;
	vk::RenderingInfo rendering = vk::renderingInfo().setRenderArea({ .extent = self.extent })
		.setLayerCount(1).setDepthAttachment(&attachment)
		.setNext(self.foveation.attach(&density));
	vk::cmdBeginRendering(cmd, &rendering);
	vk::ClearAttachment clear = { .aspectMask = IMAGE_ASPECT_DEPTH_BIT,
		.clearValue = { .depthStencil = { 1.0, 0 } } };
	vk::ClearRect area = { .rect = dirty, .baseArrayLayer = 0, .layerCount = 1 };
	vk::cmdClearAttachments(cmd, 1, &clear, 1, &area);
	set_full_viewport(cmd, self.extent, true);
	vk::cmdSetScissor(cmd, 0, 1, (vk::Rect2D[]) { dirty });
}

<*
 Reopens the finished frame as a colour attachment, to draw an interface over it.

 The third way a rendering starts here, and the only one that keeps what is
 already in the image. `begin_render` clears, `begin_render_to` writes somewhere
 else — this loads `self.color` and draws on top of it, which is what an overlay
 is. Ends with `vk::cmdEndRendering` like the others, and `close` still happens
 once, in `Renderer.record_scene`.

 Three things it does differently, and each of them is a way to get it wrong:

 - **The barrier is not `color_attachment_barrier`.** That one comes from
   `UNDEFINED` and so discards, which is right for an attachment about to be
   cleared and destroys the frame here. This is a write-after-write on an image
   that is already `COLOR_ATTACHMENT_OPTIMAL` — the scene left it there, or the
   post chain's last pass did — so the layout does not change and only the
   ordering is asked for.
 - **`LOAD_OP_LOAD`, and no depth attachment.** cui never tests or writes depth,
   and the `CanvasPass` is created with `FORMAT_UNDEFINED` to match.
 - **`flip_y` is false.** Every other pass here flips Y because it rasterises
   glTF geometry into Vulkan clip space; cui's `ui_view()` already bakes the
   orientation and the pixel-exact scale into its own view matrix. Flipping again
   draws the interface upside down while hit-testing it the right way up, which
   is the worst way for it to be broken.
*>
fn void Target.begin_overlay(&self, vk::CommandBuffer cmd)
{
	vk::ImageMemoryBarrier2 keep = {
		...IMAGE_BARRIER,
		.image = self.color,
		.srcStageMask = PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
		.srcAccessMask = ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
		.dstStageMask = PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
		.dstAccessMask = ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT | ACCESS_2_COLOR_ATTACHMENT_READ_BIT,
		.oldLayout = IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
		.newLayout = IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
	};
	vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo().setImageMemoryBarriers({ keep }));
	begin_overlay_rendering(cmd, self.color_view, self.extent);
}

<*
 A colour-only rendering that loads what is there: no clear, no depth, no Y flip.
*>
fn void begin_overlay_rendering(vk::CommandBuffer cmd, vk::ImageView view, vk::Extent2D extent)
{
	vk::RenderingAttachmentInfo color_attachment = vk::renderingAttachmentInfo().setImageView(view)
		.setImageLayout(IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL)
		.setLoadOp(ATTACHMENT_LOAD_OP_LOAD)
		.setStoreOp(ATTACHMENT_STORE_OP_STORE);

	vk::RenderingInfo rendering = vk::renderingInfo().setRenderArea({ .extent = extent }).setLayerCount(1)
		.setColorAttachments({ color_attachment });

	vk::cmdBeginRendering(cmd, &rendering);
	set_full_viewport(cmd, extent, false);
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
	set_viewport_rect(cmd, { .offset = { 0, 0 }, .extent = extent }, flip_y);
}

<*
 The same, over part of the attachment rather than all of it.

 What `set_full_viewport` delegates to, and what a host drawing the scene inside
 a pane of a larger interface sets instead — `MeshPass.view_rect`. The scissor
 is the rect exactly; the viewport is the rect too, which is what makes the
 projection's aspect the *pane's* rather than the window's and puts the middle of
 the picture in the middle of the pane instead of the middle of the window.

 The clear is untouched by either: `begin_render_to` clears through the render
 area, which is always the whole attachment, so the target outside the rect is
 the clear colour rather than last frame's.

 @param rect : `Physical pixels, and must lie inside the attachment — Vulkan requires a scissor within the render area, and a pane scrolled off the edge has to be clamped by the caller.`
*>
fn void set_viewport_rect(vk::CommandBuffer cmd, vk::Rect2D rect, bool flip_y)
{
	float x      = (float)rect.offset.x;
	float y      = (float)rect.offset.y;
	float width  = (float)rect.extent.width;
	float height = (float)rect.extent.height;
	vk::cmdSetViewport(
		cmd,
		0,
		1,
		(vk::Viewport[]) {
			{
				.x = x,
				.y = flip_y ? y + height : y,
				.width = width,
				.height = flip_y ? -height : height,
				.minDepth = 0.0,
				.maxDepth = 1.0,
			}
		}
	);
	vk::cmdSetScissor(cmd, 0, 1, (vk::Rect2D[]) { rect });
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
	vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo().setImageMemoryBarriers({ transfer_src_barrier(self.color) }));
}

// ============================================================================
// Readback — the screenshot
// ============================================================================

<*
 What the offscreen frame costs, in bytes.

 Colour and depth, both at the target's extent and neither of them optional: this
 is what a process holds before a single mesh is loaded. At 1080p it is about
 17 MB, and it is the floor under every other number in `stats()`.
*>
fn usz Target.bytes(&self) => (usz)(self.color_memory.size + self.depth_memory.size);

fn sz Target.readback_size(&self) => (sz)self.extent.width * (sz)self.extent.height * 4;

<*
 A host-visible buffer big enough for one frame of the colour target.

 Freed by the caller once the fence guarding the copy has signalled — the copy is
 recorded into the frame's command buffer, so the GPU is still reading this when
 the call returns.
*>
fn vk::Memory? Target.create_readback(&self, Gpu* gpu)
{
	return gpu.create_readback(self.readback_size());
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
		.imageSubresource = {
			.aspectMask = IMAGE_ASPECT_COLOR_BIT,
			.mipLevel = 0,
			.baseArrayLayer = 0,
			.layerCount = 1
		},
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
fn image::Image Target.decode_readback(&self, vk::Memory* src, alloc::Allocator allocator = mem, bool keep_alpha = false)
{
	sz size      = self.readback_size();
	char[] bytes = alloc::new_array(allocator, char, size);
	mem::copy(bytes.ptr, src.data(), size);
	if (!keep_alpha)
	{
		for (sz i = 3; i < size; i += 4) bytes[i] = 0xff;
	}

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
