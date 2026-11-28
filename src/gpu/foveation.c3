<*
 Fixed foveation: a fragment density map over the scene, so the scene and the
 depth prepass shade the edge of each eye's view in 2x2 or 4x4 blocks of
 pixels. The lens blurs those parts anyway, and they are most of the pixels.

 The map follows the target's layout: one layer per eye for a multiview target,
 or both eyes side by side in one layer for a target that draws them next to
 each other.

 One texel of the map covers 32x32 pixels: the driver works the texel size out
 as the rendering's size over the map's, rounded up to a power of two.
*>
module three;

import vk;
import std::math;

const uint FOVEATION_TEXEL = 32;
const float[4] DEFAULT_LENS_CENTERS = { 0.5f, 0.5f, 0.5f, 0.5f };

enum Foveation : char (String name)
{
	OFF    { "off" },
	LOW    { "low" },
	MEDIUM { "medium" },
	HIGH   { "high" },
}

struct FoveationMap
{
	LayeredImage image;
	// In density texels.
	vk::Extent2D extent;
	Foveation level;
	// Each eye's lens centre across its own view: u, v, then u, v.
	float[4] centers;
}

fn bool FoveationMap.exists(&self) => self.image.exists();

<*
 Creates the map for a rendering of `target`'s size, at `level`, around `centers`
 (defaulting to the middle of each eye until the headset reports its FOV).

 @param views : "1 for both eyes side by side in one layer, 2 for a multiview target's layer each"
 @param centers : "Each eye's lens centre across its half of the target, u v u v"
*>
fn void? FoveationMap.init(&self, Gpu* gpu, vk::Extent2D target, uint views, Foveation level,
	float[4] centers = { 0.5f, 0.5f, 0.5f, 0.5f })
{
	self.extent = { (target.width + FOVEATION_TEXEL - 1) / FOVEATION_TEXEL,
		(target.height + FOVEATION_TEXEL - 1) / FOVEATION_TEXEL };
	self.image = gpu.create_layered_image(FORMAT_R8G8_UNORM, self.extent, views,
		IMAGE_USAGE_FRAGMENT_DENSITY_MAP_BIT_EXT | IMAGE_USAGE_TRANSFER_DST_BIT)!;
	defer catch self.image.destroy(gpu);
	self.fill(gpu, target, level, centers)!;
}

<*
 The density a texel this far from the lens centre gets, as a byte: 255 is
 every pixel, 127 a 2x2 block and 63 a 4x4 one. `distance` is in half-widths
 of the eye's view, so 1 is the middle of its left or right edge.
*>
fn char foveation_density(Foveation level, float distance)
{
	switch (level)
	{
		case OFF:
			return 255;
		case LOW:
			return distance < 0.6f ? 255 : 127;
		case MEDIUM:
			if (distance < 0.5f) return 255;
			return distance < 0.85f ? 127 : 63;
		case HIGH:
			if (distance < 0.35f) return 255;
			return distance < 0.65f ? 127 : 63;
	}
}

// The density one eye wants at a point of its own view, in pixels from its top left.
fn char eye_density(Foveation level, float[4] centers, uint eye, float x, float y, float width, uint height) @local
{
	float dx = x - centers[eye * 2] * width;
	float dy = y - centers[eye * 2 + 1] * (float)height;
	return foveation_density(level, math::sqrt(dx * dx + dy * dy) / (width * 0.5f));
}

<*
 Writes the map for `level` around `centers` and leaves it ready to be read by
 a rendering. Waits for the copy; the caller makes sure no frame is reading
 the map while it changes.

 @param centers : "Each eye's lens centre across its half of the target, u v u v"
*>
fn void? FoveationMap.fill(&self, Gpu* gpu, vk::Extent2D target, Foveation level, float[4] centers)
{
	uint layers = self.image.count;
	sz layer_bytes = (sz)self.extent.width * self.extent.height * 2;
	char[] texels = mem::new_array(char, layer_bytes * layers);
	defer free(texels);

	// An eye is a whole layer, or half of the only one.
	float eye_width = layers > 1 ? (float)target.width : (float)target.width * 0.5f;
	for (uint layer = 0; layer < layers; layer++)
	{
		for (uint y = 0; y < self.extent.height; y++)
		{
			for (uint x = 0; x < self.extent.width; x++)
			{
				float px = ((float)x + 0.5f) * FOVEATION_TEXEL;
				float py = ((float)y + 0.5f) * FOVEATION_TEXEL;
				uint eye = layers > 1 ? layer : (px < eye_width ? 0 : 1);
				float left = layers > 1 ? 0.0f : (float)eye * eye_width;
				char density = eye_density(level, centers, eye, px - left, py, eye_width, target.height);
				sz at = (sz)layer * layer_bytes + ((sz)y * self.extent.width + x) * 2;
				texels[at] = density;
				texels[at + 1] = density;
			}
		}
	}

	vk::Memory stage = gpu.create_upload(layer_bytes * layers, texels.ptr)!;
	defer stage.free();
	vk::Image image = self.image.whole.image;
	vk::Extent2D extent = self.extent;
	gpu.handle.@single_time_command(queue: gpu.graphics ; vk::CommandBuffer cmd)
	{
		vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo().setImageMemoryBarriers({ upload_barrier(image, 1) }));
		vk::BufferImageCopy region = {
			.imageSubresource = { .aspectMask = IMAGE_ASPECT_COLOR_BIT, .layerCount = layers },
			.imageExtent = { extent.width, extent.height, 1 },
		};
		vk::cmdCopyBufferToImage(cmd, stage.buffer, image, IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);
		vk::ImageMemoryBarrier2 ready = {
			...IMAGE_BARRIER,
			.image = image,
			.srcStageMask = PIPELINE_STAGE_2_ALL_TRANSFER_BIT,
			.srcAccessMask = ACCESS_2_TRANSFER_WRITE_BIT,
			.dstStageMask = PIPELINE_STAGE_2_FRAGMENT_DENSITY_PROCESS_BIT_EXT,
			.dstAccessMask = ACCESS_2_FRAGMENT_DENSITY_MAP_READ_BIT_EXT,
			.oldLayout = IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
			.newLayout = IMAGE_LAYOUT_FRAGMENT_DENSITY_MAP_OPTIMAL_EXT,
		};
		vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo().setImageMemoryBarriers({ ready }));
	}!;
	self.level = level;
	self.centers = centers;
}

<*
 Points `info` at the map and returns it for a rendering's `pNext`, or null
 when there is no map.
*>
fn void* FoveationMap.attach(&self, vk::RenderingFragmentDensityMapAttachmentInfoEXT* info)
{
	if (!self.exists()) return null;
	*info = {
		.sType = STRUCTURE_TYPE_RENDERING_FRAGMENT_DENSITY_MAP_ATTACHMENT_INFO_EXT,
		.imageView = self.image.whole.view,
		.imageLayout = IMAGE_LAYOUT_FRAGMENT_DENSITY_MAP_OPTIMAL_EXT,
	};
	return info;
}

fn void FoveationMap.free(&self, Gpu* gpu)
{
	if (self.exists()) self.image.destroy(gpu);
	*self = { };
}
