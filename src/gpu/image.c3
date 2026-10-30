<*
 The one place a device-local 2D image is created.

 Every owner of an image — render targets, the post chain, the shadow atlas,
 textures, the lightmap — wants the same thing: optimal tiling, one sample, one
 layer, memory bound, and nothing left behind when a step fails.
*>
module three;

import vk;

faultdef IMAGE_OVER_BUDGET;

<*
 An image, its memory and its view.

 `vk::Memory.free` destroys the image it was bound to, so the view is the only
 extra handle to release.
*>
struct GpuImage
{
	vk::Image image;
	vk::ImageView view;
	vk::Memory memory;
}

<*
 What a chain image is created for by default: a fragment pass writes it as an
 attachment and the next pass samples it.
*>
const vk::ImageUsageFlags CHAIN_IMAGE_USAGE = IMAGE_USAGE_COLOR_ATTACHMENT_BIT | IMAGE_USAGE_SAMPLED_BIT;

<*
 A device-local 2D image with its memory bound, and no view.

 The image is destroyed again when its memory cannot be found, so a failure
 leaves nothing to clean up.

 @param max_bytes : `IMAGE_OVER_BUDGET when the image needs more than this`
*>
fn vk::Memory? Gpu.create_device_image(&self, vk::Format format, uint width, uint height,
	vk::ImageUsageFlags usage, uint levels = 1, usz max_bytes = usz::max)
{
	vk::Image image = vk::imageCreateInfo().setImageType(IMAGE_TYPE_2D).setFormat(format)
		.setExtent({ .width = width, .height = height, .depth = 1 })
		.setMipLevels(levels)
		.setArrayLayers(1)
		.setSamples(SAMPLE_COUNT_1_BIT)
		.setTiling(IMAGE_TILING_OPTIMAL)
		.setUsage(usage)
		.setInitialLayout(IMAGE_LAYOUT_UNDEFINED)
		.build(self.handle)!;
	defer catch vk::destroyImage(self.handle, image, null);

	if (max_bytes != usz::max)
	{
		vk::MemoryRequirements requirements = image.getMemoryRequirements(self.handle);
		usz required = (usz)requirements.size;
		usz alignment = (usz)requirements.alignment;
		if (alignment > 0) required = (required + alignment - 1) / alignment * alignment;
		if (required > max_bytes) return IMAGE_OVER_BUDGET~;
	}
	return vk::create_image_buffer(image, &self.allocator, MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
}

<*
 A view of every level of a 2D image.
*>
fn vk::ImageView? Gpu.create_view_2d(&self, vk::Image image, vk::Format format,
	vk::ImageAspectFlags aspect = IMAGE_ASPECT_COLOR_BIT, uint levels = 1)
{
	return vk::imageViewCreateInfo().setViewType(IMAGE_VIEW_TYPE_2D).setFormat(format)
		.setSubresourceRange({ ...COLOR_LEVEL, .aspectMask = aspect, .levelCount = levels })
		.setImage(image)
		.build(self.handle);
}

<*
 A device-local 2D image and a view of it. Nothing is left behind on failure.
*>
fn GpuImage? Gpu.create_image_2d(&self, vk::Format format, vk::Extent2D extent, vk::ImageUsageFlags usage,
	vk::ImageAspectFlags aspect = IMAGE_ASPECT_COLOR_BIT, uint levels = 1, usz max_bytes = usz::max)
{
	vk::Memory memory = self.create_device_image(format, extent.width, extent.height, usage, levels, max_bytes)!;
	defer catch memory.free();
	return { .image = memory.image, .memory = memory, .view = self.create_view_2d(memory.image, format, aspect, levels)! };
}

<*
 Hands the image to the deferred-deletion queue, so a frame still reading it
 finishes first. Idempotent.
*>
fn void GpuImage.free(&self, Gpu* gpu)
{
	gpu.retire_memory(self.memory, self.view);
	*self = { };
}

<*
 Destroys the image now. Only for an image no submitted work can still touch.
*>
fn void GpuImage.destroy(&self, Gpu* gpu)
{
	if (self.view != null) vk::destroyImageView(gpu.handle, self.view, null);
	if (self.memory.image != null) self.memory.free();
	*self = { };
}

fn bool GpuImage.exists(&self) => self.image != null;

fn vk::DescriptorImageInfo sampled_with(vk::Sampler sampler, vk::ImageView view) => {
	.sampler = sampler, .imageView = view, .imageLayout = IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
};

<*
 A sampler that clamps all three axes and never reads past level 0.

 @param compare : `COMPARE_OP_NEVER for no depth compare`
*>
fn vk::Sampler? Gpu.clamp_sampler(&self, vk::Filter filter,
	vk::BorderColor border = BORDER_COLOR_FLOAT_OPAQUE_WHITE, vk::CompareOp compare = COMPARE_OP_NEVER)
{
	return vk::samplerCreateInfo().setMagFilter(filter).setMinFilter(filter)
		.setAddressModeU(SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE).setAddressModeV(SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE)
		.setAddressModeW(SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE).setMipmapMode(SAMPLER_MIPMAP_MODE_NEAREST)
		.setCompareEnable((uint)(compare != COMPARE_OP_NEVER)).setCompareOp(compare)
		.setMinLod(0).setMaxLod(0).setBorderColor(border).build(self.handle);
}
