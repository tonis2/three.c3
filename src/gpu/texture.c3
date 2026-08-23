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

<*
 Which space a texture's bytes are in, and therefore which format it uploads as.

 **Not a note attached to the image — it is the image's format**, decided at
 upload and unchangeable afterwards. `SRGB` makes the hardware decode to linear
 on every sample, which is right for a picture of something and wrong for
 anything whose channels are numbers rather than colours: a normal map's xyz, a
 roughness or metalness or occlusion map's scalar, a height field, a flow map, a
 lookup table a shader indexes. Those want `LINEAR` — the same bytes, read back
 as themselves.

 **Neither failure announces itself as a colourspace.** A colour map uploaded
 `LINEAR` is washed out and reads as a lighting bug. A normal map uploaded `SRGB`
 has its stored 0.5 — which is "no tilt" — decoded to 0.21, so every surface
 leans the same way and the bumps go soft; it reads as a bad bake, and the file
 is fine.

 `SRGB` is the default because it is what a texture usually is, and because it is
 what every texture in this project was before this enum existed.
*>
enum ColorSpace : char
{
	SRGB,
	LINEAR,
}

fn vk::Format ColorSpace.format(self)
{
	switch (self)
	{
		case LINEAR: return FORMAT_R8G8B8A8_UNORM;
		default: return FORMAT_R8G8B8A8_SRGB;
	}
}

fn String ColorSpace.name(self)
{
	switch (self)
	{
		case LINEAR: return "linear";
		default: return "srgb";
	}
}

struct Texture
{
	vk::Image image;
	vk::ImageView view;
	vk::Sampler sampler;
	vk::Memory memory;
	uint width;
	uint height;
	// How many mip levels the image **actually has**, which is 1 when the chain
	// was declined — by the caller, or by a device that cannot blit this format.
	// Stored rather than recomputed from the extents at each use, because "what
	// this image has" and "what an image this size would get" are different
	// questions and only the first is safe to build a `maxLod` from.
	uint levels;
	ColorSpace space;
	ulong hash;
}

<*
 How many levels a full mip chain has for these extents.

 Halving the longest side until it reaches one, which is Vulkan's own rule — the
 short side floors at 1 and keeps being copied while the long one keeps
 shrinking, so a 1024x16 gets eleven levels and not five.
*>
fn uint mip_levels(uint width, uint height)
{
	uint side = width > height ? width : height;
	uint levels = 1;
	while (side > 1)
	{
		side /= 2;
		levels++;
	}
	return levels;
}

<*
 Whether this device can build a mip chain for this format by blitting.

 Three features and all three are needed: the image is the blit's source and its
 destination in the same command, and the downsample is a `FILTER_LINEAR` blit,
 which is a filtered *sample* and is the bit that is genuinely optional. Every
 device this targets reports all three for RGBA8, and asking costs one call at
 upload — but a format that cannot do it fails at the blit with a validation
 error and a chain of undefined levels, which looks like a corrupt texture at
 distance and like nothing at all up close.

 The answer is per format rather than cached on `Gpu`, because it is per format:
 `R8G8B8A8_SRGB` and `R8G8B8A8_UNORM` are entitled to differ, and a compressed
 format arriving with KTX2 will differ — a BC7 image carries its own chain and
 must never be blitted at all.
*>
fn bool Gpu.can_generate_mips(&self, vk::Format format)
{
	const vk::FormatFeatureFlags NEEDED = FORMAT_FEATURE_BLIT_SRC_BIT
		| FORMAT_FEATURE_BLIT_DST_BIT
		| FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR_BIT;

	vk::FormatProperties props;
	vk::getPhysicalDeviceFormatProperties(self.pdevice, format, &props);
	return (props.optimalTilingFeatures & NEEDED) == NEEDED;
}

<*
 How many levels an upload of this description would end up with.

 Split out of `create_texture` so that `Assets.claim_texture` can ask the same
 question before deciding whether an existing slot is the same image — the answer
 depends on the device as well as on the caller, so recomputing it there from
 `mips` alone would say a chain was wanted on a device that cannot make one and
 upload a duplicate for ever after.
*>
fn uint Gpu.levels_for(&self, uint width, uint height, ColorSpace space, bool mips)
{
	return mips && self.can_generate_mips(space.format()) ? mip_levels(width, height) : 1;
}

<*
 Upload an RGBA8 image, build its mip chain, and build its view and sampler.

 ## The format is the caller's to choose

 `SRGB` decodes to linear on every sample, which is what a base colour map wants:
 a glTF texture is authored in sRGB and the shading arithmetic is linear, so the
 hardware has to do the conversion on the way in. `LINEAR` uploads `UNORM` and
 hands the shader the stored bytes, which is what a normal, roughness or height
 map wants. See `ColorSpace` for what each mistake looks like on screen.

 ## The chain is generated on the device

 Level 0 is copied from the staging buffer and every level below it is a
 `FILTER_LINEAR` blit from the level above — the standard construction, and the
 one that costs no host memory and no second decode.

 It is worth being clear about what that is: a box filter run pairwise, not a
 Kaiser or a Mitchell, so a texture whose author cared will still ship better
 levels of its own inside a KTX2 and should keep them. And whether the average is
 taken in linear or in stored values is the implementation's to decide for an
 `SRGB` image — the visible consequence, where one gets it wrong, is levels that
 darken slightly with distance rather than anything structural. What the chain
 buys is the thing that was missing, which is that a textured floor stops
 aliasing into noise at grazing angles.

 **Without it the sampler had no chain to clamp to and `maxLod` was 0**, so every
 sample came from the full-resolution image however few pixels the surface
 covered. That is the shimmer, and it is invisible in a screenshot of a scene
 viewed head-on — which is why it survived as long as it did.

 `mips: false` is for an image that is a *table* rather than a picture: pixels a
 script generated to be indexed exactly, where a blurred level is not a cheaper
 approximation of anything.

 @param rgba : `Exactly width*height*4 bytes.`
 @param space : `SRGB for a colour map, LINEAR for a map whose channels are numbers.`
 @param mips : `False to upload the one level. A device that cannot blit the format gives one anyway.`
 @require rgba.len == (sz)width * height * 4
*>
fn Texture? Gpu.create_texture(
	&self, char[] rgba, uint width, uint height, ColorSpace space = ColorSpace.SRGB, bool mips = true
)
{
	vk::Format format = space.format();
	uint levels = self.levels_for(width, height, space, mips);

	Texture texture = {
		.width = width,
		.height = height,
		.levels = levels,
		.space = space,
		.hash = content_hash(rgba),
	};

	texture.image = vk::imageCreateInfo().setImageType(IMAGE_TYPE_2D).setFormat(format)
		.setExtent({ .width = width, .height = height, .depth = 1 })
		.setMipLevels(levels)
		.setArrayLayers(1)
		.setSamples(SAMPLE_COUNT_1_BIT)
		.setTiling(IMAGE_TILING_OPTIMAL)
		// TRANSFER_SRC as well as DST, so `read_pixels` can copy the image back —
		// and, since the chain arrived, so each mip level can be the blit source
		// for the one below it. It costs a usage bit and nothing else — no extra
		// memory, no format restriction on any device this runs on — and without
		// it the readback is not merely slow but invalid: the layer answers
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
		// **The whole chain, not just level 0.** Every level is a separate
		// subresource with a layout of its own, and one left in `UNDEFINED` is
		// not a level that reads as black — it is a blit destination in a layout
		// the blit does not admit, which is
		// `VUID-vkCmdBlitImage-dstImageLayout-00226` and undefined contents after.
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
				.levelCount = levels,
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

		// Each level downsampled from the one above it, which is why this is a
		// loop and not a fan-out: level N is not readable until level N-1 has
		// been written *and* moved to `TRANSFER_SRC`, so the barrier inside the
		// loop is a real dependency and not bookkeeping. Blitting every level
		// from level 0 instead would need no barriers and would be worse — a
		// single wide box filter per level rather than a chain, which is exactly
		// the aliasing the chain exists to remove.
		int mip_width = (int)width;
		int mip_height = (int)height;
		for (uint level = 1; level < levels; level++)
		{
			vk::ImageMemoryBarrier2 to_source = {
				.sType = STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
				.image = texture.image,
				.srcStageMask = PIPELINE_STAGE_2_ALL_TRANSFER_BIT,
				.srcAccessMask = ACCESS_2_TRANSFER_WRITE_BIT,
				.dstStageMask = PIPELINE_STAGE_2_ALL_TRANSFER_BIT,
				.dstAccessMask = ACCESS_2_TRANSFER_READ_BIT,
				.oldLayout = IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
				.newLayout = IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
				.subresourceRange = {
					.aspectMask = IMAGE_ASPECT_COLOR_BIT,
					.baseMipLevel = level - 1,
					.levelCount = 1,
					.baseArrayLayer = 0,
					.layerCount = 1,
				},
			};
			vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo().setImageMemoryBarriers({ to_source }));

			// Floored at 1 rather than halved, because the short side reaches 1
			// while the long one is still shrinking. A zero extent is not a small
			// blit, it is an invalid one.
			int next_width = mip_width > 1 ? mip_width / 2 : 1;
			int next_height = mip_height > 1 ? mip_height / 2 : 1;

			vk::ImageBlit downsample = {
				.srcSubresource = {
					.aspectMask = IMAGE_ASPECT_COLOR_BIT,
					.mipLevel = level - 1,
					.baseArrayLayer = 0,
					.layerCount = 1,
				},
				.srcOffsets = { { 0, 0, 0 }, { mip_width, mip_height, 1 } },
				.dstSubresource = {
					.aspectMask = IMAGE_ASPECT_COLOR_BIT,
					.mipLevel = level,
					.baseArrayLayer = 0,
					.layerCount = 1,
				},
				.dstOffsets = { { 0, 0, 0 }, { next_width, next_height, 1 } },
			};
			vk::cmdBlitImage(
				cmd,
				texture.image,
				IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
				texture.image,
				IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
				1,
				&downsample,
				FILTER_LINEAR
			);

			mip_width = next_width;
			mip_height = next_height;
		}

		// Two barriers rather than one because the levels are in two different
		// layouts by now: everything the loop read from is in `TRANSFER_SRC`, and
		// the last level was only ever written to. Both are handed to one
		// `cmdPipelineBarrier2` — a dependency covers a *set* of subresources,
		// and splitting these into two calls would order the second against the
		// first for no reason.
		//
		// A one-level image takes the second entry alone, which is the barrier
		// this function had before the chain existed.
		vk::ImageMemoryBarrier2 read_levels = {
			.sType = STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
			.image = texture.image,
			.srcStageMask = PIPELINE_STAGE_2_ALL_TRANSFER_BIT,
			.srcAccessMask = ACCESS_2_TRANSFER_READ_BIT,
			.dstStageMask = PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT,
			.dstAccessMask = ACCESS_2_SHADER_READ_BIT,
			.oldLayout = IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
			.newLayout = IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
			.subresourceRange = {
				.aspectMask = IMAGE_ASPECT_COLOR_BIT,
				.baseMipLevel = 0,
				.levelCount = levels - 1,
				.baseArrayLayer = 0,
				.layerCount = 1,
			},
		};
		vk::ImageMemoryBarrier2 last_level = {
			.sType = STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
			.image = texture.image,
			.srcStageMask = PIPELINE_STAGE_2_ALL_TRANSFER_BIT,
			.srcAccessMask = ACCESS_2_TRANSFER_WRITE_BIT,
			.dstStageMask = PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT,
			.dstAccessMask = ACCESS_2_SHADER_READ_BIT,
			.oldLayout = IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
			.newLayout = IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
			.subresourceRange = {
				.aspectMask = IMAGE_ASPECT_COLOR_BIT,
				.baseMipLevel = levels - 1,
				.levelCount = 1,
				.baseArrayLayer = 0,
				.layerCount = 1,
			},
		};
		// `last_level` first so that a one-level image is the head of this array
		// rather than a special case built somewhere else.
		vk::ImageMemoryBarrier2[2] to_shader = { last_level, read_levels };
		usz used = levels > 1 ? 2 : 1;
		vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo().setImageMemoryBarriers(to_shader[:used]));
	}!;

	// `levelCount = levels`, and this is the half that is easy to leave behind:
	// the image can have a full chain while the view exposes one level, and the
	// result is not an error anywhere — it is a sampler whose `maxLod` clamps
	// against levels the view does not have, which reads as a texture that never
	// blurs however far away it gets.
	texture.view = vk::imageViewCreateInfo().setViewType(IMAGE_VIEW_TYPE_2D).setFormat(format)
		.setSubresourceRange(
			{
				.aspectMask = IMAGE_ASPECT_COLOR_BIT,
				.baseMipLevel = 0,
				.levelCount = levels,
				.baseArrayLayer = 0,
				.layerCount = 1,
			}
		)
		.setImage(texture.image)
		.build(self.handle)!;

	// **`maxLod` was 0 and that is what "no mips" was**, not the missing levels:
	// a sampler clamped to lod 0 samples the top level however small the surface
	// is on screen. It is `levels` rather than `LOD_CLAMP_NONE` because this
	// image really has that many, and a clamp that states the truth about its own
	// image is one fewer thing to keep in step if a chain is ever declined.
	texture.sampler = vk::samplerCreateInfo().setMagFilter(FILTER_LINEAR).setMinFilter(FILTER_LINEAR)
		.setAddressModeU(SAMPLER_ADDRESS_MODE_REPEAT)
		.setAddressModeV(SAMPLER_ADDRESS_MODE_REPEAT)
		.setAddressModeW(SAMPLER_ADDRESS_MODE_REPEAT)
		.setMipmapMode(SAMPLER_MIPMAP_MODE_LINEAR)
		.setMinLod(0.0)
		.setMaxLod((float)levels)
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
 rather than a blit, so it moves stored bytes and performs no conversion — what
 lands in `dst` is the RGBA the texture was created from, not the values the
 sampler produces. That is the useful answer: it round-trips against
 `DataTexture`, and for an `SRGB` texture it is the same space `png::save_file`
 wants. It is also why `space` does not appear here: the two formats store the
 same bytes and differ only in what sampling does to them.

 **Level 0, and only level 0.** The generated levels are not the caller's data
 and there is no verb to ask for one; a level is an approximation this file made
 up, and handing one back through a function whose contract is "the bytes that
 went in" would make that contract false for a reason no call site could see.
 The barriers below are scoped to level 0 for the same reason — the rest of the
 chain stays in `SHADER_READ_ONLY` throughout, which is legal precisely because a
 layout is per subresource.

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
