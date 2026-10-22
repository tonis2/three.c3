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
	GpuImage depth;
	vk::Sampler sampler;
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
	if (self.depth.exists() && self.extent.width == extent.width && self.extent.height == extent.height) return;
	if (self.depth.exists()) self.destroy_image(gpu);

	vk::FormatFeatureFlags wanted = FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT | FORMAT_FEATURE_SAMPLED_IMAGE_BIT;
	self.format = vk::findDepthFormat(features: wanted, device: gpu.pdevice);
	vk::FormatProperties properties;
	vk::getPhysicalDeviceFormatProperties(gpu.pdevice, self.format, &properties);
	if ((properties.optimalTilingFeatures & wanted) != wanted) return SHADOW_FORMAT_UNSUPPORTED~;

	self.depth = gpu.create_image_2d(self.format, extent,
		IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT | IMAGE_USAGE_SAMPLED_BIT, IMAGE_ASPECT_DEPTH_BIT)!;
	defer catch self.depth.destroy(gpu);
	self.sampler = gpu.clamp_sampler(FILTER_NEAREST)!;
	self.extent = extent;
}

fn void AmbientOcclusion.begin(&self, vk::CommandBuffer cmd)
{
	vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo().setImageMemoryBarriers({ depth_open_barrier(self.depth.image, true) }));
	begin_depth_rendering(cmd, self.depth.view, self.extent);
}

fn void AmbientOcclusion.end(&self, vk::CommandBuffer cmd)
{
	vk::cmdEndRendering(cmd);
	vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo().setImageMemoryBarriers({ depth_sample_barrier(self.depth.image) }));
}

fn vk::DescriptorImageInfo AmbientOcclusion.descriptor(&self) => sampled_with(self.sampler, self.depth.view);

fn usz AmbientOcclusion.bytes(&self) => self.depth.exists() ? (usz)self.depth.memory.size : 0;

fn void AmbientOcclusion.destroy_image(&self, Gpu* gpu)
{
	gpu.retire_memory(self.depth.memory, self.depth.view, self.sampler);
	self.depth = { };
	self.sampler = (vk::Sampler)null;
	self.extent = { };
}

fn void AmbientOcclusion.free(&self, Gpu* gpu)
{
	if (self.depth.exists()) self.destroy_image(gpu);
	*self = { };
}
