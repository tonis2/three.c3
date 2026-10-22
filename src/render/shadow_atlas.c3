module three;

import vk;

struct ShadowTile { uint x; uint y; uint size; }
struct ShadowRect { uint x; uint y; uint width; uint height; }

struct ShadowAtlas
{
	GpuImage live;
	vk::Sampler sampler;
	// The same image again, through a depth-compare sampler: one tap is four
	// texel comparisons filtered in the texture unit.
	vk::Sampler compare_sampler;
	// A 1x1 depth image the compare descriptor points at when there is no atlas:
	// a comparison sampler is only defined against a depth image.
	GpuImage blank;
	bool blank_ready;
	// Static casters only, copied into `live` under the moving ones.
	GpuImage statics;
	vk::Format format;
	uint width;
	uint height;
	uint generation;
	bool initialized;
	bool static_initialized;
	bool static_target;
}

fn usz ShadowAtlas.bytes(&self) => (usz)(self.live.memory.size + self.statics.memory.size);

const vk::ImageUsageFlags SHADOW_ATLAS_USAGE = IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT | IMAGE_USAGE_SAMPLED_BIT
	| IMAGE_USAGE_TRANSFER_SRC_BIT | IMAGE_USAGE_TRANSFER_DST_BIT;

fn GpuImage? ShadowAtlas.create_image(&self, Gpu* gpu, uint width, uint height, usz max_bytes = usz::max)
{
	return gpu.create_image_2d(self.format, { width, height }, SHADOW_ATLAS_USAGE, IMAGE_ASPECT_DEPTH_BIT, 1, max_bytes);
}

fn void ShadowAtlas.destroy_images(&self, Gpu* gpu)
{
	self.live.free(gpu);
	self.statics.free(gpu);
	self.width = 0; self.height = 0; self.initialized = false; self.static_initialized = false;
}

fn void ShadowAtlas.pick_format(&self, Gpu* gpu)
{
	if (self.format != FORMAT_UNDEFINED) return;
	vk::FormatFeatureFlags wanted = FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT | FORMAT_FEATURE_SAMPLED_IMAGE_BIT
		| FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR_BIT;
	self.format = vk::findDepthFormat(features: wanted, device: gpu.pdevice);
}

<*
 The comparison sampler and the 1x1 depth image behind it.

 Made whether or not a shadow pass ever runs: the templates always declare the
 compare binding, so the descriptor always has to be a depth image and a
 comparison sampler.
*>
fn void? ShadowAtlas.ensure_compare(&self, Gpu* gpu)
{
	if (self.compare_sampler != null && self.blank.image != null) return;
	self.pick_format(gpu);
	if (self.compare_sampler == null)
	{
		self.compare_sampler = gpu.clamp_sampler(FILTER_LINEAR, compare: COMPARE_OP_LESS_OR_EQUAL)!;
	}
	if (self.blank.image == null)
	{
		self.blank = self.create_image(gpu, 1, 1)!;
		self.blank_ready = false;
	}
}

// One barrier, once, so the blank is readable in the layout its descriptor names.
fn void ShadowAtlas.record_blank(&self, vk::CommandBuffer cmd)
{
	if (self.blank.image == null || self.blank_ready) return;
	self.begin_image(cmd, self.blank.image, false, true);
	self.finish_image(cmd, self.blank.image);
	self.blank_ready = true;
}

fn void? ShadowAtlas.ensure(&self, Gpu* gpu, uint width, uint height, bool want_static = false,
	usz max_bytes = usz::max)
{
	if (self.live.image != null && self.width == width && self.height == height && self.bytes() > max_bytes)
	{
		return IMAGE_OVER_BUDGET~;
	}
	if (self.live.image == null || self.width != width || self.height != height)
	{
		self.destroy_images(gpu);
		self.pick_format(gpu);
		self.live = self.create_image(gpu, width, height, max_bytes)!;
		defer catch self.destroy_images(gpu);
		if (self.sampler == null)
		{
			self.sampler = gpu.clamp_sampler(FILTER_NEAREST)!;
		}
		self.width = width; self.height = height;
		self.generation++;
	}
	if (want_static && self.statics.image == null)
	{
		usz used = (usz)self.live.memory.size;
		usz available = used < max_bytes ? max_bytes - used : 0;
		self.statics = self.create_image(gpu, width, height, available)!;
		self.static_initialized = false;
	}
}

fn vk::DescriptorImageInfo ShadowAtlas.descriptor(&self, bool sample_static = false)
{
	return { .sampler = self.sampler, .imageView = sample_static ? self.statics.view : self.live.view,
		.imageLayout = IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL };
}

fn vk::DescriptorImageInfo ShadowAtlas.compare_descriptor(&self, bool sample_static = false, bool live = true)
{
	vk::ImageView view = sample_static ? self.statics.view : self.live.view;
	bool readable = live && view != null && (sample_static ? self.static_initialized : self.initialized);
	return { .sampler = self.compare_sampler, .imageView = readable ? view : self.blank.view,
		.imageLayout = IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL };
}

fn void ShadowAtlas.begin_image(&self, vk::CommandBuffer cmd, vk::Image image, bool initialized, bool discard)
{
	vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo().setImageMemoryBarriers({ depth_open_barrier(image, discard || !initialized) }));
}

fn void ShadowAtlas.begin_live(&self, vk::CommandBuffer cmd, bool discard = false)
{ self.static_target = false; self.begin_image(cmd, self.live.image, self.initialized, discard); }
fn void ShadowAtlas.begin_static(&self, vk::CommandBuffer cmd, bool discard = false)
{ self.static_target = true; self.begin_image(cmd, self.statics.image, self.static_initialized, discard); }

fn void ShadowAtlas.begin_tile(&self, vk::CommandBuffer cmd, ShadowTile tile, bool clear)
{
	self.begin_tile_rect(cmd, tile, { tile.x, tile.y, tile.size, tile.size }, clear);
}

fn void ShadowAtlas.begin_tile_rect(&self, vk::CommandBuffer cmd, ShadowTile tile, ShadowRect rect, bool clear)
{
	vk::ImageView target = self.static_target ? self.statics.view : self.live.view;
	vk::RenderingAttachmentInfo depth = vk::renderingAttachmentInfo().setImageView(target)
		.setImageLayout(IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL)
		.setLoadOp(clear ? ATTACHMENT_LOAD_OP_CLEAR : ATTACHMENT_LOAD_OP_LOAD)
		.setStoreOp(ATTACHMENT_STORE_OP_STORE).setClearValue({ .depthStencil = { 1.0, 0 } });
	vk::Rect2D area = { .offset = { (int)rect.x, (int)rect.y }, .extent = { rect.width, rect.height } };
	vk::RenderingInfo rendering = vk::renderingInfo().setRenderArea(area).setLayerCount(1).setDepthAttachment(&depth);
	vk::cmdBeginRendering(cmd, &rendering);
	vk::Viewport viewport = { .x = (float)tile.x, .y = (float)(tile.y + tile.size),
		.width = (float)tile.size, .height = -(float)tile.size, .minDepth = 0, .maxDepth = 1 };
	vk::cmdSetViewport(cmd, 0, 1, &viewport); vk::cmdSetScissor(cmd, 0, 1, &area);
}

fn void ShadowAtlas.finish_image(&self, vk::CommandBuffer cmd, vk::Image image)
{
	vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo().setImageMemoryBarriers({ depth_sample_barrier(image) }));
}
fn void ShadowAtlas.end_live(&self, vk::CommandBuffer cmd) { self.finish_image(cmd, self.live.image); self.initialized = true; }
fn void ShadowAtlas.end_static(&self, vk::CommandBuffer cmd) { self.finish_image(cmd, self.statics.image); self.static_initialized = true; }

// Leaves the live atlas in attachment layout for dynamic LOAD overlays.
fn void ShadowAtlas.copy_static(&self, vk::CommandBuffer cmd, ShadowRect[] tiles)
{
	if (tiles.len == 0) return;
	self.static_target = false;
	vk::ImageMemoryBarrier2[2] before = {
		{ ...IMAGE_BARRIER, .image = self.statics.image, .srcStageMask = PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
			.srcAccessMask = ACCESS_2_SHADER_SAMPLED_READ_BIT | ACCESS_2_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
			.dstStageMask = PIPELINE_STAGE_2_ALL_TRANSFER_BIT, .dstAccessMask = ACCESS_2_TRANSFER_READ_BIT,
			.oldLayout = IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, .newLayout = IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
			.subresourceRange = DEPTH_LEVEL },
		{ ...IMAGE_BARRIER, .image = self.live.image, .srcStageMask = PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
			.srcAccessMask = ACCESS_2_SHADER_SAMPLED_READ_BIT | ACCESS_2_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
			.dstStageMask = PIPELINE_STAGE_2_ALL_TRANSFER_BIT, .dstAccessMask = ACCESS_2_TRANSFER_WRITE_BIT,
			.oldLayout = self.initialized ? IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL : IMAGE_LAYOUT_UNDEFINED,
			.newLayout = IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
			.subresourceRange = DEPTH_LEVEL },
	};
	vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo().setImageMemoryBarriers(before[..]));
	foreach (tile : tiles)
	{
		vk::ImageCopy region = { .srcSubresource = { .aspectMask = IMAGE_ASPECT_DEPTH_BIT, .layerCount = 1 },
			.srcOffset = { (int)tile.x, (int)tile.y, 0 }, .dstSubresource = { .aspectMask = IMAGE_ASPECT_DEPTH_BIT, .layerCount = 1 },
			.dstOffset = { (int)tile.x, (int)tile.y, 0 }, .extent = { tile.width, tile.height, 1 } };
		vk::cmdCopyImage(cmd, self.statics.image, IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
			self.live.image, IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);
	}
	vk::ImageMemoryBarrier2[2] after = {
		{ ...IMAGE_BARRIER, .image = self.statics.image, .srcStageMask = PIPELINE_STAGE_2_ALL_TRANSFER_BIT,
			.srcAccessMask = ACCESS_2_TRANSFER_READ_BIT, .dstStageMask = PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT,
			.dstAccessMask = ACCESS_2_SHADER_SAMPLED_READ_BIT, .oldLayout = IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
			.newLayout = IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
			.subresourceRange = DEPTH_LEVEL },
		{ ...IMAGE_BARRIER, .image = self.live.image, .srcStageMask = PIPELINE_STAGE_2_ALL_TRANSFER_BIT,
			.srcAccessMask = ACCESS_2_TRANSFER_WRITE_BIT,
			.dstStageMask = PIPELINE_STAGE_2_EARLY_FRAGMENT_TESTS_BIT | PIPELINE_STAGE_2_LATE_FRAGMENT_TESTS_BIT,
			.dstAccessMask = ACCESS_2_DEPTH_STENCIL_ATTACHMENT_READ_BIT | ACCESS_2_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
			.oldLayout = IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, .newLayout = IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
			.subresourceRange = DEPTH_LEVEL },
	};
	vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo().setImageMemoryBarriers(after[..]));
}

fn void ShadowAtlas.free(&self, Gpu* gpu)
{
	if (gpu.handle == null) return;
	self.destroy_images(gpu);
	self.blank.free(gpu);
	gpu.retire_memory({ }, sampler: self.sampler);
	gpu.retire_memory({ }, sampler: self.compare_sampler);
	*self = { };
}
