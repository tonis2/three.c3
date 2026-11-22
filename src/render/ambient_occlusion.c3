module three;

import std::io;
import std::math;
import std::math::matrix;
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

<*
 The ambient occlusion pass's push block: `shaders/ambient_occlusion.shady`'s
 whole view of the frame, one view at a time.
*>
struct AoPush
{
	Matrix4f inverse_view_projection;
	// The view's rectangle in full-resolution pixels: x, y, width, height.
	float[4] view_rect;
	// x intensity, y radius, z bias.
	float[4] settings;
	// xy the full-resolution target's size, zw the half-resolution images'.
	float[4] target;
}

const PushFieldLayout[*] AO_PUSH_FIELDS = {
	{ "inverse_view_projection", 0, 64 },
	{ "view_rect", 64, 16 },
	{ "settings", 80, 16 },
	{ "target", 96, 16 },
};

$assert AoPush::size == 112 : "AoPush no longer matches shaders/ambient_occlusion.shady";

// How much of the sky each pixel sees; the mesh shader reads it filtered.
const vk::Format AO_FORMAT = FORMAT_R8_UNORM;

<*
 Screen-space ambient occlusion in two passes at half the target's size: the
 visible geometry depth-only into `depth`, then `ambient_occlusion.shady` over it
 into `result`. The mesh shader reads `result` once per pixel, late, so the
 occlusion is no weight on the lighting loop. `extent` is the target's.
*>
struct AmbientOcclusion
{
	inline AmbientOcclusionSettings settings;
	GpuImage depth;
	GpuImage result;
	vk::Sampler sampler;
	vk::Sampler linear;
	vk::Format format;
	vk::Extent2D extent;
	vk::Extent2D result_extent;
	MeshPipeline pipeline;
	bool live;
}

fn void AmbientOcclusion.apply(&self, AmbientOcclusionSettings settings)
{
	self.settings = settings;
	self.live = false;
}

// The pipeline and samplers once, the two images whenever the target's size changes.
fn void? AmbientOcclusion.ensure(&self, Gpu* gpu, vk::Extent2D extent)
{
	if (self.pipeline.handle == null)
	{
		@pool()
		{
			ShaderModule mod = compile_shader(ShaderPass.AMBIENT_OCCLUSION)!;
			defer mod.free();
			if (!mod.ok)
			{
				io::eprintn(mod.diagnostic);
				return SHADER_COMPILE_FAILED~;
			}
			self.pipeline.init_post(gpu, &mod, AO_FORMAT, AO_PUSH_FIELDS[..])!;
		};
	}
	if (self.sampler == null) self.sampler = gpu.clamp_sampler(FILTER_NEAREST)!;
	if (self.linear == null) self.linear = gpu.clamp_sampler(FILTER_LINEAR)!;
	if (self.depth.exists() && self.extent.width == extent.width && self.extent.height == extent.height) return;
	if (self.depth.exists()) self.destroy_image(gpu);

	vk::FormatFeatureFlags wanted = FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT | FORMAT_FEATURE_SAMPLED_IMAGE_BIT;
	self.format = vk::findDepthFormat(features: wanted, device: gpu.pdevice);
	vk::FormatProperties properties;
	vk::getPhysicalDeviceFormatProperties(gpu.pdevice, self.format, &properties);
	if ((properties.optimalTilingFeatures & wanted) != wanted) return SHADOW_FORMAT_UNSUPPORTED~;

	vk::Extent2D half = { (extent.width + 1) / 2, (extent.height + 1) / 2 };
	self.depth = gpu.create_image_2d(self.format, half,
		IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT | IMAGE_USAGE_SAMPLED_BIT, IMAGE_ASPECT_DEPTH_BIT)!;
	defer catch self.depth.destroy(gpu);
	self.result = gpu.create_image_2d(AO_FORMAT, half, IMAGE_USAGE_COLOR_ATTACHMENT_BIT | IMAGE_USAGE_SAMPLED_BIT)!;
	self.extent = extent;
	self.result_extent = half;
}

fn void AmbientOcclusion.begin(&self, vk::CommandBuffer cmd)
{
	vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo().setImageMemoryBarriers({ depth_open_barrier(self.depth.image, true) }));
	begin_depth_rendering(cmd, self.depth.view, self.result_extent);
}

<*
 Points the depth pass at one view's half-size rectangle. Fractional, so the
 half-size grid lines up with the full one exactly.

 @param rect : "The view's rectangle in full-resolution pixels"
*>
fn void AmbientOcclusion.depth_view(&self, vk::CommandBuffer cmd, vk::Rect2D rect)
{
	float x = (float)rect.offset.x * 0.5f;
	float y = (float)rect.offset.y * 0.5f;
	float width = (float)rect.extent.width * 0.5f;
	float height = (float)rect.extent.height * 0.5f;
	vk::cmdSetViewport(cmd, 0, 1, (vk::Viewport[]) { {
		.x = x, .y = y + height, .width = width, .height = -height, .minDepth = 0.0, .maxDepth = 1.0 } });
	vk::cmdSetScissor(cmd, 0, 1, (vk::Rect2D[]) { half_rect(rect) });
}

// The half-size texels a full-resolution rectangle touches.
fn vk::Rect2D half_rect(vk::Rect2D rect) @local
{
	int x0 = rect.offset.x / 2;
	int y0 = rect.offset.y / 2;
	int x1 = (rect.offset.x + (int)rect.extent.width + 1) / 2;
	int y1 = (rect.offset.y + (int)rect.extent.height + 1) / 2;
	return { .offset = { x0, y0 }, .extent = { (uint)(x1 - x0), (uint)(y1 - y0) } };
}

<*
 Ends the depth pass and opens `result` for `draw_view`. Every texel a view
 covers is drawn, and nothing reads outside the views, so nothing is cleared.
*>
fn void AmbientOcclusion.end(&self, vk::CommandBuffer cmd)
{
	vk::cmdEndRendering(cmd);
	vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo().setImageMemoryBarriers({
		depth_sample_barrier(self.depth.image), color_attachment_barrier(self.result.image) }));

	vk::RenderingAttachmentInfo color = vk::renderingAttachmentInfo().setImageView(self.result.view)
		.setImageLayout(IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL)
		.setLoadOp(ATTACHMENT_LOAD_OP_DONT_CARE)
		.setStoreOp(ATTACHMENT_STORE_OP_STORE);
	vk::RenderingInfo rendering = vk::renderingInfo().setRenderArea({ .extent = self.result_extent }).setLayerCount(1)
		.setColorAttachments({ color });
	vk::cmdBeginRendering(cmd, &rendering);
	vk::cmdBindPipeline(cmd, PIPELINE_BIND_POINT_GRAPHICS, self.pipeline.handle);
	SampledBindings samplers;
	samplers.add(0, sampled_with(self.sampler, self.depth.view));
	samplers.push(cmd, &self.pipeline);
}

<*
 Works out one view's occlusion into its half-size rectangle of `result`.

 @param rect : "The view's rectangle in full-resolution pixels"
*>
fn void AmbientOcclusion.draw_view(&self, vk::CommandBuffer cmd, vk::Rect2D rect, Matrix4f view_projection)
{
	set_viewport_rect(cmd, half_rect(rect), false);

	AoPush push = {
		.inverse_view_projection = invert(view_projection),
		.view_rect = rect_floats(rect),
		.settings = { self.intensity, self.radius, self.bias, 0 },
		.target = { (float)self.extent.width, (float)self.extent.height,
			(float)self.result_extent.width, (float)self.result_extent.height },
	};
	vk::cmdPushConstants(cmd, self.pipeline.layout, self.pipeline.shader.stages, 0, AoPush::size, &push);
	vk::cmdDraw(cmd, 3, 1, 0, 0);
}

// Closes `result` for the scene pass to sample.
fn void AmbientOcclusion.finish(&self, vk::CommandBuffer cmd)
{
	vk::cmdEndRendering(cmd);
	vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo().setImageMemoryBarriers({ shader_read_barrier(self.result.image) }));
}

fn vk::DescriptorImageInfo AmbientOcclusion.descriptor(&self) => sampled_with(self.linear, self.result.view);

fn usz AmbientOcclusion.bytes(&self)
{
	usz bytes = self.depth.exists() ? (usz)self.depth.memory.size : 0;
	return bytes + (self.result.exists() ? (usz)self.result.memory.size : 0);
}

fn void AmbientOcclusion.destroy_image(&self, Gpu* gpu)
{
	gpu.retire_memory(self.depth.memory, self.depth.view);
	if (self.result.exists()) gpu.retire_memory(self.result.memory, self.result.view);
	self.depth = { };
	self.result = { };
	self.extent = { };
	self.result_extent = { };
}

fn void AmbientOcclusion.free(&self, Gpu* gpu)
{
	if (self.depth.exists()) self.destroy_image(gpu);
	if (self.sampler != null) gpu.retire_memory({}, sampler: self.sampler);
	if (self.linear != null) gpu.retire_memory({}, sampler: self.linear);
	if (self.pipeline.handle != null) gpu.retire_pipeline(self.pipeline);
	*self = { };
}
