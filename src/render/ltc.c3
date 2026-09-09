<*
 The linearly transformed cosine table, uploaded once and read by every shader
 that shades a surface.

 An area light is a polygon, and a polygon lit by a cosine distribution has a
 closed-form integral. Heitz et al. (2016) fit the GGX lobe, per roughness and
 per view angle, to that same cosine seen through a 3x3 linear map — so the GGX
 integral over the emitter becomes the cosine integral over a transformed
 emitter, and the sixteen-sample loop `lighting.slang` used to run becomes two
 texture reads and four edges.

 `ltc_table.bin` is the fit, generated offline: 64x128 RGBA halves, the column
 perceptual roughness and the row `sqrt(1 - N·V)`. Rows 0-63 hold the four free
 entries of the fitted inverse; rows 64-127 hold the GGX directional albedo split
 the way a Schlick Fresnel splits it, which is what scales the result.

 Its own image rather than an `Assets` texture for two reasons: the table is not
 RGBA8 and never will be — eight bits of a matrix entry is a visible change in
 the size of a highlight — and nothing about it is per scene, so it has no slot,
 no reference count and no dedup key. `AmbientOcclusion` beside it is the same
 shape for the same reason.
*>
module three;

import vk;

const char[*] LTC_TABLE_BYTES = $embed("ltc_table.bin");
const uint LTC_TABLE_WIDTH  = 64;
const uint LTC_TABLE_HEIGHT = 128;
const vk::Format LTC_TABLE_FORMAT = FORMAT_R16G16B16A16_SFLOAT;

faultdef LTC_FORMAT_UNSUPPORTED, LTC_TABLE_CORRUPT;

struct LtcTable
{
	vk::Image image;
	vk::ImageView view;
	vk::Sampler sampler;
	vk::Memory memory;
	<*
	 True once the table is on the device and bound. `FrameBlock.lighting.w`
	 carries it into the shader, and false there means the numeric integration —
	 which is the honest fallback rather than a degraded one.
	*>
	bool live;
	<*
	 Whether the upload has been tried. A device that refuses the format refuses
	 it every frame, and the sentence saying so is worth reading once.
	*>
	bool attempted;
}

<*
 Creates and uploads the table, once. A second call is nothing.

 @return ? LTC_FORMAT_UNSUPPORTED : `The device cannot linearly filter RGBA16F, so a table read from it would be a staircase.`
 @return ? LTC_TABLE_CORRUPT : `The embedded fit is not the size the image is — a truncated or regenerated table.`
*>
fn void? LtcTable.ensure(&self, Gpu* gpu)
{
	if (self.live || self.attempted) return;
	self.attempted = true;
	if (LTC_TABLE_BYTES.len != (usz)LTC_TABLE_WIDTH * LTC_TABLE_HEIGHT * 8) return LTC_TABLE_CORRUPT~;

	const vk::FormatFeatureFlags NEEDED = FORMAT_FEATURE_SAMPLED_IMAGE_BIT
		| FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR_BIT | FORMAT_FEATURE_TRANSFER_DST_BIT;
	vk::FormatProperties properties;
	vk::getPhysicalDeviceFormatProperties(gpu.pdevice, LTC_TABLE_FORMAT, &properties);
	if ((properties.optimalTilingFeatures & NEEDED) != NEEDED) return LTC_FORMAT_UNSUPPORTED~;

	defer catch
	{
		if (self.sampler != null) vk::destroySampler(gpu.handle, self.sampler, null);
		if (self.view != null) vk::destroyImageView(gpu.handle, self.view, null);
		if (self.memory.image != null) { self.memory.free(); }
		else if (self.image != null) { vk::destroyImage(gpu.handle, self.image, null); }
		*self = { .attempted = true };
	}

	self.image = vk::imageCreateInfo().setImageType(IMAGE_TYPE_2D).setFormat(LTC_TABLE_FORMAT)
		.setExtent({ .width = LTC_TABLE_WIDTH, .height = LTC_TABLE_HEIGHT, .depth = 1 })
		.setMipLevels(1).setArrayLayers(1).setSamples(SAMPLE_COUNT_1_BIT)
		.setTiling(IMAGE_TILING_OPTIMAL)
		.setUsage(IMAGE_USAGE_TRANSFER_DST_BIT | IMAGE_USAGE_SAMPLED_BIT)
		.setInitialLayout(IMAGE_LAYOUT_UNDEFINED).build(gpu.handle)!;
	self.memory = vk::create_image_buffer(self.image, &gpu.allocator, MEMORY_PROPERTY_DEVICE_LOCAL_BIT)!;

	vk::Memory stage = vk::new_buffer(
		&gpu.allocator,
		usage: BUFFER_USAGE_TRANSFER_SRC_BIT,
		properties: MEMORY_PROPERTY_HOST_VISIBLE_BIT | MEMORY_PROPERTY_HOST_COHERENT_BIT,
		data: &LTC_TABLE_BYTES[0],
		data_size: LTC_TABLE_BYTES.len,
	)!;
	defer stage.free();

	gpu.handle.@single_time_command(queue: gpu.graphics ; vk::CommandBuffer cmd)
	{
		vk::ImageMemoryBarrier2 to_transfer = {
			...IMAGE_BARRIER, .image = self.image,
			.srcStageMask = PIPELINE_STAGE_2_TOP_OF_PIPE_BIT,
			.srcAccessMask = (vk::AccessFlags2)0,
			.dstStageMask = PIPELINE_STAGE_2_ALL_TRANSFER_BIT,
			.dstAccessMask = ACCESS_2_TRANSFER_WRITE_BIT,
			.oldLayout = IMAGE_LAYOUT_UNDEFINED,
			.newLayout = IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
			.subresourceRange = COLOR_LEVEL,
		};
		vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo().setImageMemoryBarriers({ to_transfer }));

		vk::BufferImageCopy region = {
			.imageSubresource = { .aspectMask = IMAGE_ASPECT_COLOR_BIT, .mipLevel = 0, .baseArrayLayer = 0, .layerCount = 1 },
			.imageExtent = { LTC_TABLE_WIDTH, LTC_TABLE_HEIGHT, 1 },
		};
		vk::cmdCopyBufferToImage(cmd, stage.buffer, self.image, IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);

		vk::ImageMemoryBarrier2 to_shader = {
			...IMAGE_BARRIER, .image = self.image,
			.srcStageMask = PIPELINE_STAGE_2_ALL_TRANSFER_BIT,
			.srcAccessMask = ACCESS_2_TRANSFER_WRITE_BIT,
			.dstStageMask = PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT,
			.dstAccessMask = ACCESS_2_SHADER_READ_BIT,
			.oldLayout = IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
			.newLayout = IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
			.subresourceRange = COLOR_LEVEL,
		};
		vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo().setImageMemoryBarriers({ to_shader }));
	}!;

	self.view = vk::imageViewCreateInfo().setViewType(IMAGE_VIEW_TYPE_2D).setFormat(LTC_TABLE_FORMAT)
		.setSubresourceRange(COLOR_LEVEL).setImage(self.image).build(gpu.handle)!;
	// Clamped and linear, which is the whole sampler: the fit is smooth in both
	// axes, and the half-texel bias the shader applies keeps a tap inside its own
	// half of the image so the two tables never blend into each other.
	self.sampler = vk::samplerCreateInfo().setMagFilter(FILTER_LINEAR).setMinFilter(FILTER_LINEAR)
		.setAddressModeU(SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE).setAddressModeV(SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE)
		.setAddressModeW(SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE).setMipmapMode(SAMPLER_MIPMAP_MODE_NEAREST)
		.setMinLod(0).setMaxLod(0).setBorderColor(BORDER_COLOR_FLOAT_OPAQUE_WHITE).build(gpu.handle)!;

	self.live = true;
}

fn vk::DescriptorImageInfo LtcTable.descriptor(&self) => {
	.sampler = self.sampler, .imageView = self.view, .imageLayout = IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
};

fn void LtcTable.free(&self, Gpu* gpu)
{
	if (self.image == null) { *self = { }; return; }
	gpu.retire_memory(self.memory, self.view, self.sampler);
	*self = { };
}
