module three;

import vk;

faultdef SHADOW_ATLAS_BUDGET;

struct ShadowTile { uint x; uint y; uint size; }

struct ShadowAtlas
{
	vk::Image image;
	vk::ImageView view;
	vk::Memory memory;
	vk::Sampler sampler;
	vk::Image static_image;
	vk::ImageView static_view;
	vk::Memory static_memory;
	vk::Format format;
	uint width;
	uint height;
	uint generation;
	bool initialized;
	bool static_initialized;
	bool static_target;
}

fn usz ShadowAtlas.bytes(&self) => (usz)(self.memory.size + self.static_memory.size);

fn void? ShadowAtlas.create_image(&self, Gpu* gpu, uint width, uint height,
	vk::Image* image, vk::ImageView* view, vk::Memory* memory, usz max_bytes = usz::max)
{
	vk::Image made_image;
	vk::ImageView made_view;
	vk::Memory made_memory;
	defer catch
	{
		if (made_view != null) vk::destroyImageView(gpu.handle, made_view, null);
		if (made_memory.image != null) { made_memory.free(); }
		else if (made_image != null) { vk::destroyImage(gpu.handle, made_image, null); }
	}
	made_image = vk::imageCreateInfo().setImageType(IMAGE_TYPE_2D).setFormat(self.format)
		.setExtent({ width, height, 1 }).setMipLevels(1).setArrayLayers(1).setSamples(SAMPLE_COUNT_1_BIT)
		.setTiling(IMAGE_TILING_OPTIMAL).setUsage(IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT | IMAGE_USAGE_SAMPLED_BIT
		| IMAGE_USAGE_TRANSFER_SRC_BIT | IMAGE_USAGE_TRANSFER_DST_BIT)
		.setInitialLayout(IMAGE_LAYOUT_UNDEFINED).build(gpu.handle)!;
	vk::MemoryRequirements requirements = made_image.getMemoryRequirements(gpu.handle);
	usz required = (usz)requirements.size;
	usz alignment = (usz)requirements.alignment;
	if (alignment > 0) required = (required + alignment - 1) / alignment * alignment;
	if (required > max_bytes) return SHADOW_ATLAS_BUDGET~;
	made_memory = vk::create_image_buffer(made_image, &gpu.allocator, MEMORY_PROPERTY_DEVICE_LOCAL_BIT)!;
	made_view = vk::imageViewCreateInfo().setViewType(IMAGE_VIEW_TYPE_2D).setFormat(self.format)
		.setSubresourceRange({ .aspectMask = IMAGE_ASPECT_DEPTH_BIT, .levelCount = 1, .layerCount = 1 })
		.setImage(made_image).build(gpu.handle)!;
	*image = made_image; *view = made_view; *memory = made_memory;
}

fn void ShadowAtlas.destroy_images(&self, Gpu* gpu)
{
	if (self.view != null) vk::destroyImageView(gpu.handle, self.view, null);
	if (self.memory.image != null) self.memory.free();
	if (self.static_view != null) vk::destroyImageView(gpu.handle, self.static_view, null);
	if (self.static_memory.image != null) self.static_memory.free();
	self.image = (vk::Image)null; self.view = (vk::ImageView)null; self.memory = { };
	self.static_image = (vk::Image)null; self.static_view = (vk::ImageView)null; self.static_memory = { };
	self.width = 0; self.height = 0; self.initialized = false; self.static_initialized = false;
}

fn void? ShadowAtlas.ensure(&self, Gpu* gpu, uint width, uint height, bool want_static = false,
	usz max_bytes = usz::max)
{
	if (self.image != null && self.width == width && self.height == height && self.bytes() > max_bytes)
	{
		return SHADOW_ATLAS_BUDGET~;
	}
	if (self.image == null || self.width != width || self.height != height)
	{
		if (self.image != null) { gpu.wait_idle(); self.destroy_images(gpu); }
		if (self.format == FORMAT_UNDEFINED)
		{
			vk::FormatFeatureFlags wanted = FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT | FORMAT_FEATURE_SAMPLED_IMAGE_BIT;
			self.format = vk::findDepthFormat(features: wanted, device: gpu.pdevice);
		}
		self.create_image(gpu, width, height, &self.image, &self.view, &self.memory, max_bytes)!;
		defer catch self.destroy_images(gpu);
		if (self.sampler == null)
		{
			self.sampler = vk::samplerCreateInfo().setMagFilter(FILTER_NEAREST).setMinFilter(FILTER_NEAREST)
				.setAddressModeU(SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE).setAddressModeV(SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE)
				.setMipmapMode(SAMPLER_MIPMAP_MODE_NEAREST).setMinLod(0).setMaxLod(0)
				.setBorderColor(BORDER_COLOR_FLOAT_OPAQUE_WHITE).build(gpu.handle)!;
		}
		self.width = width; self.height = height;
		self.generation++;
	}
	if (want_static && self.static_image == null)
	{
		usz used = (usz)self.memory.size;
		usz available = used < max_bytes ? max_bytes - used : 0;
		self.create_image(gpu, width, height, &self.static_image, &self.static_view, &self.static_memory, available)!;
		self.static_initialized = false;
	}
}

fn vk::DescriptorImageInfo ShadowAtlas.descriptor(&self, bool sample_static = false)
{
	return { .sampler = self.sampler, .imageView = sample_static ? self.static_view : self.view,
		.imageLayout = IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL };
}

fn void ShadowAtlas.begin_image(&self, vk::CommandBuffer cmd, vk::Image image, bool initialized, bool discard)
{
	vk::ImageMemoryBarrier2 barrier = { ...IMAGE_BARRIER, .image = image,
		.srcStageMask = PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
		.dstStageMask = PIPELINE_STAGE_2_EARLY_FRAGMENT_TESTS_BIT | PIPELINE_STAGE_2_LATE_FRAGMENT_TESTS_BIT,
		.dstAccessMask = ACCESS_2_DEPTH_STENCIL_ATTACHMENT_READ_BIT | ACCESS_2_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
		.oldLayout = discard || !initialized ? IMAGE_LAYOUT_UNDEFINED : IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
		.newLayout = IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
		.subresourceRange = { .aspectMask = IMAGE_ASPECT_DEPTH_BIT, .levelCount = 1, .layerCount = 1 } };
	vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo().setImageMemoryBarriers({ barrier }));
}

fn void ShadowAtlas.begin_live(&self, vk::CommandBuffer cmd, bool discard = false)
{ self.static_target = false; self.begin_image(cmd, self.image, self.initialized, discard); }
fn void ShadowAtlas.begin_static(&self, vk::CommandBuffer cmd, bool discard = false)
{ self.static_target = true; self.begin_image(cmd, self.static_image, self.static_initialized, discard); }

fn void ShadowAtlas.begin_tile(&self, vk::CommandBuffer cmd, ShadowTile tile, bool clear)
{
	vk::ImageView target = self.static_target ? self.static_view : self.view;
	vk::RenderingAttachmentInfo depth = vk::renderingAttachmentInfo().setImageView(target)
		.setImageLayout(IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL)
		.setLoadOp(clear ? ATTACHMENT_LOAD_OP_CLEAR : ATTACHMENT_LOAD_OP_LOAD)
		.setStoreOp(ATTACHMENT_STORE_OP_STORE).setClearValue({ .depthStencil = { 1.0, 0 } });
	vk::Rect2D area = { .offset = { (int)tile.x, (int)tile.y }, .extent = { tile.size, tile.size } };
	vk::RenderingInfo rendering = vk::renderingInfo().setRenderArea(area).setLayerCount(1).setDepthAttachment(&depth);
	vk::cmdBeginRendering(cmd, &rendering);
	vk::Viewport viewport = { .x = (float)tile.x, .y = (float)(tile.y + tile.size),
		.width = (float)tile.size, .height = -(float)tile.size, .minDepth = 0, .maxDepth = 1 };
	vk::cmdSetViewport(cmd, 0, 1, &viewport); vk::cmdSetScissor(cmd, 0, 1, &area);
}

fn void ShadowAtlas.finish_image(&self, vk::CommandBuffer cmd, vk::Image image)
{
	vk::ImageMemoryBarrier2 barrier = { ...IMAGE_BARRIER, .image = image,
		.srcStageMask = PIPELINE_STAGE_2_EARLY_FRAGMENT_TESTS_BIT | PIPELINE_STAGE_2_LATE_FRAGMENT_TESTS_BIT,
		.srcAccessMask = ACCESS_2_DEPTH_STENCIL_ATTACHMENT_READ_BIT | ACCESS_2_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
		.dstStageMask = PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT, .dstAccessMask = ACCESS_2_SHADER_SAMPLED_READ_BIT,
		.oldLayout = IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL, .newLayout = IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
		.subresourceRange = { .aspectMask = IMAGE_ASPECT_DEPTH_BIT, .levelCount = 1, .layerCount = 1 } };
	vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo().setImageMemoryBarriers({ barrier }));
}
fn void ShadowAtlas.end_live(&self, vk::CommandBuffer cmd) { self.finish_image(cmd, self.image); self.initialized = true; }
fn void ShadowAtlas.end_static(&self, vk::CommandBuffer cmd) { self.finish_image(cmd, self.static_image); self.static_initialized = true; }

// Leaves the live atlas in attachment layout for dynamic LOAD overlays.
fn void ShadowAtlas.copy_static(&self, vk::CommandBuffer cmd, ShadowTile[] tiles)
{
	if (tiles.len == 0) return;
	self.static_target = false;
	vk::ImageMemoryBarrier2[2] before = {
		{ ...IMAGE_BARRIER, .image = self.static_image, .srcStageMask = PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
			.srcAccessMask = ACCESS_2_SHADER_SAMPLED_READ_BIT | ACCESS_2_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
			.dstStageMask = PIPELINE_STAGE_2_ALL_TRANSFER_BIT, .dstAccessMask = ACCESS_2_TRANSFER_READ_BIT,
			.oldLayout = IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, .newLayout = IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
			.subresourceRange = { .aspectMask = IMAGE_ASPECT_DEPTH_BIT, .levelCount = 1, .layerCount = 1 } },
		{ ...IMAGE_BARRIER, .image = self.image, .srcStageMask = PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
			.srcAccessMask = ACCESS_2_SHADER_SAMPLED_READ_BIT | ACCESS_2_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
			.dstStageMask = PIPELINE_STAGE_2_ALL_TRANSFER_BIT, .dstAccessMask = ACCESS_2_TRANSFER_WRITE_BIT,
			.oldLayout = self.initialized ? IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL : IMAGE_LAYOUT_UNDEFINED,
			.newLayout = IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
			.subresourceRange = { .aspectMask = IMAGE_ASPECT_DEPTH_BIT, .levelCount = 1, .layerCount = 1 } },
	};
	vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo().setImageMemoryBarriers(before[..]));
	foreach (tile : tiles)
	{
		vk::ImageCopy region = { .srcSubresource = { .aspectMask = IMAGE_ASPECT_DEPTH_BIT, .layerCount = 1 },
			.srcOffset = { (int)tile.x, (int)tile.y, 0 }, .dstSubresource = { .aspectMask = IMAGE_ASPECT_DEPTH_BIT, .layerCount = 1 },
			.dstOffset = { (int)tile.x, (int)tile.y, 0 }, .extent = { tile.size, tile.size, 1 } };
		vk::cmdCopyImage(cmd, self.static_image, IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
			self.image, IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);
	}
	vk::ImageMemoryBarrier2[2] after = {
		{ ...IMAGE_BARRIER, .image = self.static_image, .srcStageMask = PIPELINE_STAGE_2_ALL_TRANSFER_BIT,
			.srcAccessMask = ACCESS_2_TRANSFER_READ_BIT, .dstStageMask = PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT,
			.dstAccessMask = ACCESS_2_SHADER_SAMPLED_READ_BIT, .oldLayout = IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
			.newLayout = IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
			.subresourceRange = { .aspectMask = IMAGE_ASPECT_DEPTH_BIT, .levelCount = 1, .layerCount = 1 } },
		{ ...IMAGE_BARRIER, .image = self.image, .srcStageMask = PIPELINE_STAGE_2_ALL_TRANSFER_BIT,
			.srcAccessMask = ACCESS_2_TRANSFER_WRITE_BIT,
			.dstStageMask = PIPELINE_STAGE_2_EARLY_FRAGMENT_TESTS_BIT | PIPELINE_STAGE_2_LATE_FRAGMENT_TESTS_BIT,
			.dstAccessMask = ACCESS_2_DEPTH_STENCIL_ATTACHMENT_READ_BIT | ACCESS_2_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
			.oldLayout = IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, .newLayout = IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
			.subresourceRange = { .aspectMask = IMAGE_ASPECT_DEPTH_BIT, .levelCount = 1, .layerCount = 1 } },
	};
	vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo().setImageMemoryBarriers(after[..]));
}

fn void ShadowAtlas.free(&self, Gpu* gpu)
{
	if (gpu.handle == null) return;
	gpu.wait_idle(); self.destroy_images(gpu);
	if (self.sampler != null) vk::destroySampler(gpu.handle, self.sampler, null);
	*self = { };
}
