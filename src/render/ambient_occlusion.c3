module three;

import std::math;
import vk;

const float AO_DEFAULT_RADIUS = 1.0f;
const float AO_DEFAULT_INTENSITY = 1.0f;
const float AO_DEFAULT_BIAS = 0.02f;

struct AmbientOcclusionSettings
{
	bool enabled;
	float radius;
	float intensity;
	float bias;
}

const AmbientOcclusionSettings DEFAULT_AMBIENT_OCCLUSION = {
	.enabled = false,
	.radius = AO_DEFAULT_RADIUS,
	.intensity = AO_DEFAULT_INTENSITY,
	.bias = AO_DEFAULT_BIAS,
};

struct AmbientOcclusion
{
	inline AmbientOcclusionSettings settings;
	vk::Image image;
	vk::ImageView view;
	vk::Sampler sampler;
	vk::Memory memory;
	vk::Format format;
	vk::Extent2D extent;
	bool live;
}

fn void AmbientOcclusion.apply(&self, AmbientOcclusionSettings settings)
{
	self.settings = settings;
	self.live = false;
}

fn void? AmbientOcclusion.ensure(&self, Gpu* gpu, vk::Extent2D extent)
{
	if (self.image != null && self.extent.width == extent.width && self.extent.height == extent.height) return;
	if (self.image != null) self.destroy_image(gpu);

	vk::FormatFeatureFlags wanted = FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT | FORMAT_FEATURE_SAMPLED_IMAGE_BIT;
	self.format = vk::findDepthFormat(features: wanted, device: gpu.pdevice);
	vk::FormatProperties properties;
	vk::getPhysicalDeviceFormatProperties(gpu.pdevice, self.format, &properties);
	if ((properties.optimalTilingFeatures & wanted) != wanted) return SHADOW_FORMAT_UNSUPPORTED~;
	defer catch
	{
		if (self.sampler != null) vk::destroySampler(gpu.handle, self.sampler, null);
		if (self.view != null) vk::destroyImageView(gpu.handle, self.view, null);
		if (self.memory.image != null) { self.memory.free(); }
		else if (self.image != null) { vk::destroyImage(gpu.handle, self.image, null); }
		self.image = (vk::Image)null;
		self.view = (vk::ImageView)null;
		self.sampler = (vk::Sampler)null;
		self.memory = { };
		self.extent = { };
	}

	self.image = vk::imageCreateInfo().setImageType(IMAGE_TYPE_2D).setFormat(self.format)
		.setExtent({ .width = extent.width, .height = extent.height, .depth = 1 })
		.setMipLevels(1).setArrayLayers(1).setSamples(SAMPLE_COUNT_1_BIT)
		.setTiling(IMAGE_TILING_OPTIMAL)
		.setUsage(IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT | IMAGE_USAGE_SAMPLED_BIT)
		.setInitialLayout(IMAGE_LAYOUT_UNDEFINED).build(gpu.handle)!;
	self.memory = vk::create_image_buffer(self.image, &gpu.allocator, MEMORY_PROPERTY_DEVICE_LOCAL_BIT)!;
	self.view = vk::imageViewCreateInfo().setViewType(IMAGE_VIEW_TYPE_2D).setFormat(self.format)
		.setSubresourceRange({ .aspectMask = IMAGE_ASPECT_DEPTH_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 })
		.setImage(self.image).build(gpu.handle)!;
	self.sampler = vk::samplerCreateInfo().setMagFilter(FILTER_NEAREST).setMinFilter(FILTER_NEAREST)
		.setAddressModeU(SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE).setAddressModeV(SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE)
		.setAddressModeW(SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE).setMipmapMode(SAMPLER_MIPMAP_MODE_NEAREST)
		.setMinLod(0).setMaxLod(0).setBorderColor(BORDER_COLOR_FLOAT_OPAQUE_WHITE).build(gpu.handle)!;
	self.extent = extent;
}

fn void AmbientOcclusion.begin(&self, vk::CommandBuffer cmd)
{
	vk::ImageMemoryBarrier2 barrier = { ...IMAGE_BARRIER, .image = self.image,
		.srcStageMask = PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
		.dstStageMask = PIPELINE_STAGE_2_EARLY_FRAGMENT_TESTS_BIT | PIPELINE_STAGE_2_LATE_FRAGMENT_TESTS_BIT,
		.dstAccessMask = ACCESS_2_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
		.oldLayout = IMAGE_LAYOUT_UNDEFINED, .newLayout = IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
		.subresourceRange = DEPTH_LEVEL };
	vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo().setImageMemoryBarriers({ barrier }));
	vk::RenderingAttachmentInfo depth = vk::renderingAttachmentInfo().setImageView(self.view)
		.setImageLayout(IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL).setLoadOp(ATTACHMENT_LOAD_OP_CLEAR)
		.setStoreOp(ATTACHMENT_STORE_OP_STORE).setClearValue({ .depthStencil = { 1.0, 0 } });
	vk::RenderingInfo info = vk::renderingInfo().setRenderArea({ .extent = self.extent }).setLayerCount(1).setDepthAttachment(&depth);
	vk::cmdBeginRendering(cmd, &info);
	set_full_viewport(cmd, self.extent, true);
}

fn void AmbientOcclusion.end(&self, vk::CommandBuffer cmd)
{
	vk::cmdEndRendering(cmd);
	vk::ImageMemoryBarrier2 barrier = { ...IMAGE_BARRIER, .image = self.image,
		.srcStageMask = PIPELINE_STAGE_2_EARLY_FRAGMENT_TESTS_BIT | PIPELINE_STAGE_2_LATE_FRAGMENT_TESTS_BIT,
		.srcAccessMask = ACCESS_2_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
		.dstStageMask = PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT, .dstAccessMask = ACCESS_2_SHADER_SAMPLED_READ_BIT,
		.oldLayout = IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL, .newLayout = IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
		.subresourceRange = DEPTH_LEVEL };
	vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo().setImageMemoryBarriers({ barrier }));
}

fn vk::DescriptorImageInfo AmbientOcclusion.descriptor(&self) => {
	.sampler = self.sampler, .imageView = self.view, .imageLayout = IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
};

fn usz AmbientOcclusion.bytes(&self) => self.image != null ? (usz)self.memory.size : 0;

fn void AmbientOcclusion.destroy_image(&self, Gpu* gpu)
{
	gpu.retire_memory(self.memory, self.view, self.sampler);
	self.image = (vk::Image)null;
	self.view = (vk::ImageView)null;
	self.sampler = (vk::Sampler)null;
	self.memory = { };
	self.extent = { };
}

fn void AmbientOcclusion.free(&self, Gpu* gpu)
{
	if (self.image != null) self.destroy_image(gpu);
	*self = { };
}
