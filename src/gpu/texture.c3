<*
 Images, samplers, and the content hash that keeps one copy of each.

 **Textures are deduplicated by content hash from the first upload.** Retro-
 fitting that after two assets already share an image is more work than doing
 it now, and it is the same rule the M6 exporter needs when it writes one glTF
 image per unique texture rather than one per reference. Two kit pieces
 exported from the same source share their images, and neither the renderer nor
 the exporter ever sees them twice.

 The hash is over the *decoded* RGBA bytes rather than the encoded file, so two
 images that differ only in PNG compression settings still collide correctly.
*>
module three;

import std::io;
import vk;
import image;

<*
 FNV-1a, 64-bit. Not cryptographic and does not need to be: a collision here
 costs one wrongly shared texture, and the check below compares dimensions
 before trusting the hash.
*>
fn ulong content_hash(char[] bytes)
{
	ulong hash = 0xcbf29ce484222325;
	foreach (byte : bytes)
	{
		hash ^= (ulong)byte;
		hash *= 0x100000001b3;
	}
	return hash;
}

struct Texture
{
	vk::Image image;
	vk::ImageView view;
	vk::Sampler sampler;
	vk::Memory memory;
	uint width;
	uint height;
	ulong hash;
}

<*
 Upload an RGBA8 image and build its view and sampler.

 `SRGB` rather than `UNORM`: a glTF base colour texture is authored in sRGB and
 the shader's lighting arithmetic is linear, so the hardware has to do the
 conversion on the way in. Getting this wrong is a picture that is subtly too
 dark and looks like a lighting bug.

 @param rgba : `Exactly width*height*4 bytes.`
 @require rgba.len == (sz)width * height * 4
*>
fn Texture? Gpu.create_texture(&self, char[] rgba, uint width, uint height)
{
	Texture texture = { .width = width, .height = height, .hash = content_hash(rgba) };

	texture.image = vk::imageCreateInfo().setImageType(IMAGE_TYPE_2D).setFormat(FORMAT_R8G8B8A8_SRGB)
		.setExtent({ .width = width, .height = height, .depth = 1 })
		.setMipLevels(1)
		.setArrayLayers(1)
		.setSamples(SAMPLE_COUNT_1_BIT)
		.setTiling(IMAGE_TILING_OPTIMAL)
		// TRANSFER_SRC as well as DST, so `read_pixels` can copy the image back.
		// It costs a usage bit and nothing else — no extra memory, no format
		// restriction on any device this runs on — and without it the readback is
		// not merely slow but invalid: the layer answers
		// `VUID-VkImageMemoryBarrier2-oldLayout-01212`, because an image may not be
		// moved to a layout its usage flags do not admit. That is how this bit came
		// to be here: `reading_a_texture_leaves_it_in_the_layout_it_was_found_in`
		// found it on its first run, having been written to catch something else.
		.setUsage(IMAGE_USAGE_TRANSFER_DST_BIT | IMAGE_USAGE_TRANSFER_SRC_BIT | IMAGE_USAGE_SAMPLED_BIT)
		.setInitialLayout(IMAGE_LAYOUT_UNDEFINED)
		.build(self.handle)!;

	texture.memory = vk::create_image_buffer(texture.image, &self.allocator, MEMORY_PROPERTY_DEVICE_LOCAL_BIT)!;

	vk::Memory stage = vk::new_buffer(
		&self.allocator,
		usage: BUFFER_USAGE_TRANSFER_SRC_BIT,
		properties: MEMORY_PROPERTY_HOST_VISIBLE_BIT | MEMORY_PROPERTY_HOST_COHERENT_BIT,
		data: rgba.ptr,
		data_size: rgba.len,
	)!;
	defer stage.free();

	self.handle.@single_time_command(queue: self.graphics; vk::CommandBuffer cmd)
	{
		vk::ImageMemoryBarrier2 to_transfer = {
			.sType = STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
			.image = texture.image,
			.srcStageMask = PIPELINE_STAGE_2_TOP_OF_PIPE_BIT,
			.srcAccessMask = (vk::AccessFlags2)0,
			.dstStageMask = PIPELINE_STAGE_2_ALL_TRANSFER_BIT,
			.dstAccessMask = ACCESS_2_TRANSFER_WRITE_BIT,
			.oldLayout = IMAGE_LAYOUT_UNDEFINED,
			.newLayout = IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
			.subresourceRange = {
				.aspectMask = IMAGE_ASPECT_COLOR_BIT,
				.baseMipLevel = 0,
				.levelCount = 1,
				.baseArrayLayer = 0,
				.layerCount = 1,
			},
		};
		vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo().setImageMemoryBarriers({ to_transfer }));

		vk::BufferImageCopy region = {
			.bufferOffset = 0,
			.bufferRowLength = 0,
			.bufferImageHeight = 0,
			.imageSubresource = {
				.aspectMask = IMAGE_ASPECT_COLOR_BIT,
				.mipLevel = 0,
				.baseArrayLayer = 0,
				.layerCount = 1,
			},
			.imageOffset = { 0, 0, 0 },
			.imageExtent = { width, height, 1 },
		};
		vk::cmdCopyBufferToImage(cmd, stage.buffer, texture.image, IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);

		vk::ImageMemoryBarrier2 to_shader = vk::transferBarrier(
			texture.image,
			IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
			IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
		);
		vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo().setImageMemoryBarriers({ to_shader }));
	}!;

	texture.view = vk::imageViewCreateInfo().setViewType(IMAGE_VIEW_TYPE_2D).setFormat(FORMAT_R8G8B8A8_SRGB)
		.setSubresourceRange(
			{ .aspectMask = IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 }
		)
		.setImage(texture.image)
		.build(self.handle)!;

	texture.sampler = vk::samplerCreateInfo().setMagFilter(FILTER_LINEAR).setMinFilter(FILTER_LINEAR)
		.setAddressModeU(SAMPLER_ADDRESS_MODE_REPEAT)
		.setAddressModeV(SAMPLER_ADDRESS_MODE_REPEAT)
		.setAddressModeW(SAMPLER_ADDRESS_MODE_REPEAT)
		.setMipmapMode(SAMPLER_MIPMAP_MODE_LINEAR)
		.setMinLod(0.0)
		.setMaxLod(0.0)
		.setBorderColor(BORDER_COLOR_INT_OPAQUE_BLACK)
		.build(self.handle)!;

	return texture;
}

<*
 Copy a texture's pixels back off the device, into a caller's buffer.

 ## Why this exists

 Pixels went to the device and could not come back, which made textures
 **write-only** and had two costs that looked unrelated. `examples/village`
 needed each generated texture's average colour to bake into its glTF export,
 and with no readback the choice was a second copy of all eleven generators —
 which would silently drift from the real ones — or accumulating the mean inside
 the loop that wrote them, which only works for a script that owns both sides. A
 texture loaded from a file had no such option at all. And separately: a texture
 nothing can read is a texture nothing can test, so every check in
 `three_tests::texture` had to go the long way round, through a rendered frame.

 ## What comes back

 **Exactly the bytes that were uploaded.** `vkCmdCopyImageToBuffer` is a copy
 rather than a blit, so it moves stored bytes and performs no conversion — the
 image is `R8G8B8A8_SRGB` and what lands in `dst` is the sRGB-encoded RGBA the
 texture was created from, not the linear values the sampler produces. That is
 the useful answer: it round-trips against `DataTexture`, and it is the same
 space `png::save_file` wants.

 ## The layout dance

 The image lives in `SHADER_READ_ONLY_OPTIMAL` between uploads, which is where
 `create_texture` leaves it and where the descriptor expects it. This moves it to
 `TRANSFER_SRC_OPTIMAL`, copies, and moves it **back** — the return leg is not
 optional and its absence is invisible until something draws with the texture
 again, several frames later, as a validation error or a black surface depending
 on the driver.

 `@single_time_command` submits and waits, so this is synchronous and costs a
 queue idle. That is the right trade for a verb a script calls at load or in a
 test, and the wrong one for a per-frame call — which is why nothing here caches
 and why the JS side takes a destination rather than allocating, so the cost is
 visible at the call site.

 @param dst : `Filled with width*height*4 bytes. The caller owns it; nothing is retained.`
 @require dst.len >= (sz)self.width * self.height * 4
*>
fn void? Texture.read_pixels(&self, Gpu* gpu, char[] dst)
{
	sz bytes = (sz)self.width * (sz)self.height * 4;

	vk::Memory readback = vk::new_buffer(
		&gpu.allocator,
		usage: BUFFER_USAGE_TRANSFER_DST_BIT,
		properties: MEMORY_PROPERTY_HOST_VISIBLE_BIT | MEMORY_PROPERTY_HOST_COHERENT_BIT,
		data: null,
		data_size: bytes,
	)!;
	defer readback.free();

	gpu.handle.@single_time_command(queue: gpu.graphics; vk::CommandBuffer cmd)
	{
		vk::ImageMemoryBarrier2 to_src = vk::transferBarrier(
			self.image,
			IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
			IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL
		);
		vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo().setImageMemoryBarriers({ to_src }));

		vk::BufferImageCopy region = {
			.bufferOffset = 0,
			.bufferRowLength = 0,
			.bufferImageHeight = 0,
			.imageSubresource = {
				.aspectMask = IMAGE_ASPECT_COLOR_BIT,
				.mipLevel = 0,
				.baseArrayLayer = 0,
				.layerCount = 1,
			},
			.imageOffset = { 0, 0, 0 },
			.imageExtent = { self.width, self.height, 1 },
		};
		vk::cmdCopyImageToBuffer(cmd, self.image, IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, readback.buffer, 1, &region);

		// Back where the descriptor expects it. Leaving it in TRANSFER_SRC is
		// the failure that shows up several frames later in something unrelated.
		vk::ImageMemoryBarrier2 to_shader = vk::transferBarrier(
			self.image,
			IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
			IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
		);
		vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo().setImageMemoryBarriers({ to_shader }));
	}!;

	// Host-coherent, and the single-time command has already waited, so there is
	// nothing to invalidate — the same reason `Target.decode_readback` maps and
	// copies with nothing in between.
	mem::copy(dst.ptr, readback.data(), bytes);
}

<*
 The 1x1 opaque white image every untextured material samples.

 It is what keeps M1 to a single pipeline: the descriptor binding is always
 occupied, so there is no "has texture" specialisation and no shader
 permutation — the material's base colour factor multiplied by white is the
 material's base colour factor.
*>
fn Texture? Gpu.create_white_texture(&self)
{
	char[4] white = { 0xff, 0xff, 0xff, 0xff };
	return self.create_texture(white[..], 1, 1);
}

fn void Texture.free(&self, Gpu* gpu)
{
	if (self.sampler != null) vk::destroySampler(gpu.handle, self.sampler, null);
	if (self.view != null) self.view.free(gpu.handle);
	// Memory.free destroys the image it was bound to; destroying it here too
	// would be a double free.
	self.memory.free();
	*self = { };
}
