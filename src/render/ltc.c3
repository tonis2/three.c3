<*
 The linearly transformed cosine table, uploaded once and read by every shader
 that shades a surface.

 An area light is a polygon, and a polygon lit by a cosine distribution has a
 closed-form integral. Heitz et al. (2016) fit the GGX lobe, per roughness and
 per view angle, to that same cosine seen through a 3x3 linear map — so the GGX
 integral over the emitter becomes the cosine integral over a transformed
 emitter: the sixteen-sample loop becomes two texture reads and four edges.

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
	GpuImage table;
	vk::Sampler sampler;
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
		self.table.destroy(gpu);
		*self = { .attempted = true };
	}

	self.table.memory = gpu.create_device_image(LTC_TABLE_FORMAT, LTC_TABLE_WIDTH, LTC_TABLE_HEIGHT,
		IMAGE_USAGE_TRANSFER_DST_BIT | IMAGE_USAGE_SAMPLED_BIT)!;
	self.table.image = self.table.memory.image;

	vk::Memory stage = gpu.create_upload(LTC_TABLE_BYTES.len, &LTC_TABLE_BYTES[0])!;
	defer stage.free();
	vk::BufferImageCopy[1] region = { {
		.imageSubresource = { .aspectMask = IMAGE_ASPECT_COLOR_BIT, .mipLevel = 0, .baseArrayLayer = 0, .layerCount = 1 },
		.imageExtent = { LTC_TABLE_WIDTH, LTC_TABLE_HEIGHT, 1 },
	} };
	gpu.upload_levels(self.table.image, &stage, region[..])!;

	self.table.view = gpu.create_view_2d(self.table.image, LTC_TABLE_FORMAT)!;
	// Clamped and linear, which is the whole sampler: the fit is smooth in both
	// axes, and the half-texel bias the shader applies keeps a tap inside its own
	// half of the image so the two tables never blend into each other.
	self.sampler = gpu.clamp_sampler(FILTER_LINEAR)!;

	self.live = true;
}

fn vk::DescriptorImageInfo LtcTable.descriptor(&self) => sampled_with(self.sampler, self.table.view);

fn void LtcTable.free(&self, Gpu* gpu)
{
	if (self.table.exists()) gpu.retire_memory(self.table.memory, self.table.view, self.sampler);
	*self = { };
}
