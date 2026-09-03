<*
 Images, samplers, and the content hash that keeps one copy of each.

 Textures are deduplicated by content hash from the first upload. It is also what
 the exporter needs to write one glTF image per unique texture rather than one
 per reference: two kit pieces exported from the same source share their images,
 and neither the renderer nor the exporter ever sees them twice.

 The hash is over the *decoded* RGBA bytes rather than the encoded file, so two
 images that differ only in PNG compression settings still collide correctly.
*>
module three;

import vk;

<*
 FNV-1a, 64-bit. Not cryptographic and does not need to be: a collision here
 costs one wrongly shared texture, and the check below compares dimensions before
 trusting the hash.
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
 The same hash over a run of slices, as though they were one.

 FNV-1a is a fold, so hashing level 0 then level 1 gives exactly what hashing
 their concatenation would. That equality is the point: the upload packs the
 levels into one staging buffer and the dedup key is computed before any buffer
 exists, and the two have to agree without either one being able to see the
 other's bytes.

 Every level and not just the base, because two files that agree at level 0 and
 differ below are two different images — sharing a slot between them would hand
 one of them the other's appearance at distance.
*>
fn ulong content_hash_levels(char[][] levels)
{
	ulong hash = 0xcbf29ce484222325;
	foreach (level : levels)
	{
		foreach (byte : level)
		{
			hash ^= (ulong)byte;
			hash *= 0x100000001b3;
		}
	}
	return hash;
}

<*
 Which space a texture's bytes are read in.

 Half of what an image is on the device; `TextureFormat` is the pair, and the
 family beside this is the other half. This was the whole of it once — it
 answered `R8G8B8A8_SRGB` or `R8G8B8A8_UNORM` directly — and a block-compressed
 image is what it had no way to describe.

 `SRGB` makes the hardware decode to linear on every sample, which is right for
 a picture of something and wrong for anything whose channels are numbers: a
 normal map's xyz, a roughness or metalness or occlusion map's scalar, a height
 field, a flow map, a lookup table a shader indexes. Those want `LINEAR` — the
 same bytes, read back as themselves.

 Neither mistake announces itself as a colourspace. A colour map uploaded
 `LINEAR` is washed out and reads as a lighting bug. A normal map uploaded `SRGB`
 has its stored 0.5 — "no tilt" — decoded to 0.21, so every surface leans the
 same way and the bumps go soft; it reads as a bad bake, and the file is fine.

 `SRGB` is the default because it is what a texture usually is.
*>
enum ColorSpace : char
{
	SRGB,
	LINEAR,
}

<*
 Which block layout a texture's bytes are in.

 `RGBA8` is what every decode path here produces and what `create_texture` has
 always taken: one texel is four bytes and the block is 1x1, which is why the
 arithmetic everywhere could be `width * height * 4` and be right.

 The BC families arrive already encoded, out of a KTX2 whose blocks are the
 file's own. They are never blitted — a block-compressed image carries the
 levels its author wrote rather than growing them on the device, which is what
 `Gpu.can_generate_mips` has been saying about BC7 since before one could exist.
*>
enum TextureFamily : char
{
	RGBA8,
	BC1,
	BC3,
	BC5,
	BC7,
}

<*
 What a texture *is* on the device: a family, and the space its bytes are read in.

 `ColorSpace` used to be this by itself — it answered `R8G8B8A8_SRGB` or
 `R8G8B8A8_UNORM` and there was nothing else a texture could be, so a
 block-compressed image had nowhere to say what it was. The space still means
 exactly what it meant and is still the caller's request; the family is what was
 missing, and pairing them is what lets `BC7_SRGB` and `BC7_UNORM` be the same
 choice for blocks that `R8G8B8A8_SRGB` and `R8G8B8A8_UNORM` are for texels.
*>
struct TextureFormat
{
	TextureFamily family;
	ColorSpace space;
}

<*
 The RGBA8 format for a space — what every decode path in this engine produces.
*>
fn TextureFormat rgba8(ColorSpace space) => { TextureFamily.RGBA8, space };

<*
 The Vulkan format this pair resolves to.

 The one table. `BC5` ignores the space rather than obeying it: it is a
 two-channel format with no sRGB form at all, so a normal map's xy is `UNORM`
 whatever the caller asked for, and answering `SRGB` here would be answering
 with a format that does not exist.
*>
fn vk::Format TextureFormat.vk(self)
{
	bool srgb = self.space == ColorSpace.SRGB;
	switch (self.family)
	{
		case BC1: return srgb ? FORMAT_BC1_RGB_SRGB_BLOCK : FORMAT_BC1_RGB_UNORM_BLOCK;
		case BC3: return srgb ? FORMAT_BC3_SRGB_BLOCK : FORMAT_BC3_UNORM_BLOCK;
		case BC5: return FORMAT_BC5_UNORM_BLOCK;
		case BC7: return srgb ? FORMAT_BC7_SRGB_BLOCK : FORMAT_BC7_UNORM_BLOCK;
		default:  return srgb ? FORMAT_R8G8B8A8_SRGB : FORMAT_R8G8B8A8_UNORM;
	}
}

fn bool TextureFormat.is_block(self) => self.family != TextureFamily.RGBA8;

<*
 The side of one block in texels: 4 for every BC family, 1 for RGBA8.

 RGBA8 answering 1 rather than being a special case is what lets `image_size`
 be one calculation instead of two.
*>
fn uint TextureFormat.block_side(self) => self.family == TextureFamily.RGBA8 ? 1 : 4;

fn uint TextureFormat.block_bytes(self)
{
	switch (self.family)
	{
		case RGBA8: return 4;
		case BC1: return 8;
		default: return 16;
	}
}

<*
 Bytes one level of this format occupies, rounded up to whole blocks.

 The rounding is the whole point, and it is exactly where `width * height * 4`
 stops being right: a 2x2 level of a BC7 image is still one entire 4x4 block and
 costs 16 bytes rather than 4. `test/fixtures/oblong_bc7.ktx2` is 12x6 so that
 three of its four levels round up, which is what makes a wrong answer here
 visible instead of merely latent.

 This is `ktx::vk::image_size`'s calculation, kept here rather than imported
 because the GPU side should not have to reach into a decoder library to know
 how big its own images are.
*>
fn sz TextureFormat.image_size(self, uint width, uint height)
{
	uint side = self.block_side();
	sz across = (sz)((width + side - 1) / side);
	sz down   = (sz)((height + side - 1) / side);
	return across * down * (sz)self.block_bytes();
}

<*
 Whether two textures are the same format — the dedup key's question.
*>
fn bool TextureFormat.equals(self, TextureFormat other)
	=> self.family == other.family && self.space == other.space;

<*
 A family's name, for a message a person reads.

 Worth the switch: "texture.read() cannot read a BC7 texture" names something a
 script's author can act on, and a number would not.
*>
fn String block_family_name(TextureFamily family)
{
	switch (family)
	{
		case BC1: return "BC1";
		case BC3: return "BC3";
		case BC5: return "BC5";
		case BC7: return "BC7";
		default: return "RGBA8";
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
	// How many mip levels the image *actually* has, which is 1 when the chain was
	// declined — by the caller, or by a device that cannot blit this format.
	// Stored rather than recomputed from the extents, because "what this image
	// has" and "what an image this size would get" are different questions and
	// only the first is safe to build a `maxLod` from.
	uint levels;
	// What this image is on the device. Was a bare `ColorSpace` back when that
	// was the only thing a texture could differ by.
	TextureFormat format;
	// Part of the texture's identity for the same reason the colourspace is: the
	// same pixels asked for nearest and for linear are two images in two samplers,
	// and sharing a slot between them would hand whichever caller came second the
	// other one's filtering.
	bool nearest;
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
	uint side   = width > height ? width : height;
	uint levels = 1;
	while (side > 1)
	{
		side /= 2;
		levels++;
	}
	return levels;
}

<*
 One side of a mip level, floored at 1.

 The halving that `mip_levels` counts, done for one level rather than counted to
 the end. Floored rather than halved because the short side reaches 1 while the
 long one is still shrinking, and a zero extent is not a small image but an
 invalid one.
*>
fn uint level_extent(uint size, uint level) => (size >> level) > 0 ? (size >> level) : 1;

<*
 As many levels as any image this can address could have.

 `mip_levels` reaches 32 at 2^31, which no device admits and no file carries;
 KTX2's own container reader bounds itself at the same number. Fixed so that the
 copy regions can be a stack array — one upload should not allocate to describe
 itself.
*>
const uint MAX_UPLOAD_LEVELS = 32;

faultdef TEXTURE_TOO_MANY_LEVELS, TEXTURE_LEVEL_WRONG_SIZE, TEXTURE_FORMAT_UNSUPPORTED,
	TEXTURE_IS_COMPRESSED;

<*
 Whether this device can build a mip chain for this format by blitting.

 Three features, all needed: the image is the blit's source and its destination
 in the same command, and the downsample is a `FILTER_LINEAR` blit — a filtered
 *sample*, which is the genuinely optional bit. Every device this targets reports
 all three for RGBA8, and asking costs one call at upload; a format that cannot
 do it fails at the blit with a validation error and a chain of undefined levels,
 which looks like a corrupt texture at distance and like nothing at all up close.

 Per format rather than cached on `Gpu`, because it is per format:
 `R8G8B8A8_SRGB` and `R8G8B8A8_UNORM` are entitled to differ, and a BC7 image
 arriving with KTX2 carries its own chain and must never be blitted at all.
*>
fn bool Gpu.can_generate_mips(&self, vk::Format format)
{
	const vk::FormatFeatureFlags NEEDED = FORMAT_FEATURE_BLIT_SRC_BIT | FORMAT_FEATURE_BLIT_DST_BIT
		| FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR_BIT;

	vk::FormatProperties props;
	vk::getPhysicalDeviceFormatProperties(self.pdevice, format, &props);
	return (props.optimalTilingFeatures & NEEDED) == NEEDED;
}

<*
 Whether this device can sample an image in this format at all.

 The question `can_generate_mips` does not ask. RGBA8 is in Vulkan's mandatory
 format table and every device sampling anything samples that, so nothing needed
 to ask until a format arrived that a device is entitled to refuse. BC7 is
 exactly that: universal on desktop and absent on a good deal of mobile, and
 ASTC-only hardware is the common case rather than an exotic one.

 `SAMPLED_IMAGE_BIT` and not the filter bit beside it, because these two are
 different refusals. A format that can be sampled but not linearly filtered is a
 usable image with a blocky sampler; a format that cannot be sampled is not an
 image this device can have, and creating one is not a soft failure — it is
 `VK_ERROR_FORMAT_NOT_SUPPORTED` at `vkCreateImage` if the driver is honest and
 undefined behaviour if it is not.

 The answer decides which format to *decode to*, which is why it is asked before
 a decode rather than after one: a device without BC7 wants the KTX2 narrowed to
 RGBA8 the way it always was, and that costs the decode this section exists to
 avoid — correct everywhere, fast where the hardware allows it.

 Per format and uncached for `can_generate_mips`'s reason, and it costs the same
 one call.
*>
fn bool Gpu.can_sample(&self, vk::Format format)
{
	const vk::FormatFeatureFlags NEEDED = FORMAT_FEATURE_SAMPLED_IMAGE_BIT;

	vk::FormatProperties props;
	vk::getPhysicalDeviceFormatProperties(self.pdevice, format, &props);
	return (props.optimalTilingFeatures & NEEDED) == NEEDED;
}

<*
 Whether an image of this family and space can exist on this device.

 The pair's form of `can_sample`, and the one a decode path should ask: it is
 answering "may I hand you BC7" rather than "is 146 a number you know".
*>
fn bool Gpu.supports(&self, TextureFormat format) => self.can_sample(format.vk());

<*
 How many levels an upload of this description would end up with.

 Split out of `create_texture` so `Assets.claim_texture` can ask the same question
 before deciding whether an existing slot is the same image. The answer depends on
 the device as well as on the caller, so recomputing it from `mips` alone would
 say a chain was wanted on a device that cannot make one and upload a duplicate
 for ever after.
*>
fn uint Gpu.levels_for(&self, uint width, uint height, TextureFormat format, bool mips)
{
	// Only the *generated* chain is in question here. A block-compressed image
	// carries the levels its file shipped and is never blitted, so it does not
	// ask the device whether it could be.
	if (format.is_block()) return mips ? mip_levels(width, height) : 1;
	return mips && self.can_generate_mips(format.vk()) ? mip_levels(width, height) : 1;
}

<*
 Uploads an RGBA8 image, builds its mip chain, and builds its view and sampler.

 ## The format is the caller's to choose

 `SRGB` decodes to linear on every sample, which is what a base colour map wants:
 a glTF texture is authored in sRGB and the shading arithmetic is linear.
 `LINEAR` uploads `UNORM` and hands the shader the stored bytes, which is what a
 normal, roughness or height map wants. See `ColorSpace`.

 ## The chain is generated on the device

 Level 0 is copied from the staging buffer and every level below it is a
 `FILTER_LINEAR` blit from the level above — the standard construction, costing
 no host memory and no second decode.

 That is a box filter run pairwise, not a Kaiser or a Mitchell, so a texture
 whose author cared will still ship better levels inside a KTX2 and should keep
 them. Whether the average is taken in linear or in stored values is the
 implementation's to decide for an `SRGB` image; the visible consequence of
 getting it wrong is levels that darken slightly with distance.

 What the chain buys is a textured floor that stops aliasing into noise at
 grazing angles. Without it the sampler has no chain to clamp to and `maxLod` is
 0, so every sample comes from the full-resolution image however few pixels the
 surface covers — invisible in a screenshot of a scene viewed head-on, which is
 why it is easy to miss.

 `mips: false` is for an image that is a *table* rather than a picture: pixels a
 script generated to be indexed exactly, where a blurred level is not a cheaper
 approximation of anything.

 `nearest` is the sampler, not the chain: mag and min filter both `NEAREST` and
 no mipmap mode, for pixels meant to be read as squares — pixel art, a palette
 indexed by a shader, anything authored on a grid. Linear filtering is the
 default and the right one for a picture of something; one bright texel in a
 table magnified under linear is a soft square the size of everything beside it,
 which is the symptom that sent a game looking at its star field.

 @param rgba : `Exactly width*height*4 bytes.`
 @param space : `SRGB for a colour map, LINEAR for a map whose channels are numbers.`
 @param mips : `False to upload the one level. A device that cannot blit the format gives one anyway.`
 @param nearest : `True for a nearest-filtered sampler. The default linear is right for a picture.`
 @require rgba.len == (sz)width * height * 4
*>
fn Texture? Gpu.create_texture(
	&self,
	char[] rgba,
	uint width,
	uint height,
	ColorSpace space = ColorSpace.SRGB,
	bool mips = true,
	bool nearest = false
)
{
	TextureFormat layout = rgba8(space);
	vk::Format format    = layout.vk();
	uint levels          = self.levels_for(width, height, layout, mips);

	Texture texture = {
		.width = width,
		.height = height,
		.levels = levels,
		.format = layout,
		.nearest = nearest,
		.hash = content_hash(rgba),
	};

	texture.image = vk::imageCreateInfo().setImageType(IMAGE_TYPE_2D).setFormat(format)
		.setExtent({ .width = width, .height = height, .depth = 1 })
		.setMipLevels(levels)
		.setArrayLayers(1)
		.setSamples(SAMPLE_COUNT_1_BIT)
		.setTiling(
			IMAGE_TILING_OPTIMAL
		)/* TRANSFER_SRC as well as DST, so `read_pixels` can copy the image back *//* and each mip level can be the blit source for the one below it. It costs *//* a usage bit and nothing else, and without it the readback is not merely *//* slow but invalid: the layer answers *//* `VUID-VkImageMemoryBarrier2-oldLayout-01212`, because an image may not *//* be moved to a layout its usage flags do not admit. */
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

	self.handle.@single_time_command(queue: self.graphics ; vk::CommandBuffer cmd)
	{
		// The whole chain, not just level 0. Every level is a separate subresource
		// with a layout of its own, and one left in `UNDEFINED` is not a level
		// that reads as black — it is a blit destination in a layout the blit does
		// not admit (`VUID-vkCmdBlitImage-dstImageLayout-00226`), with undefined
		// contents after.
		vk::ImageMemoryBarrier2 to_transfer = {
			...IMAGE_BARRIER,
			.image = texture.image,
			.srcStageMask = PIPELINE_STAGE_2_TOP_OF_PIPE_BIT,
			.srcAccessMask = (vk::AccessFlags2)0,
			.dstStageMask = PIPELINE_STAGE_2_ALL_TRANSFER_BIT,
			.dstAccessMask = ACCESS_2_TRANSFER_WRITE_BIT,
			.oldLayout = IMAGE_LAYOUT_UNDEFINED,
			.newLayout = IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
			.subresourceRange = { ...COLOR_LEVEL, .levelCount = levels },
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

		// Each level downsampled from the one above, which is why this is a loop
		// and not a fan-out: level N is not readable until level N-1 has been
		// written *and* moved to `TRANSFER_SRC`, so the barrier inside the loop is
		// a real dependency. Blitting every level from level 0 instead would need
		// no barriers and would be worse — a single wide box filter per level
		// rather than a chain, which is exactly the aliasing the chain removes.
		int mip_width  = (int)width;
		int mip_height = (int)height;
		for (uint level = 1; level < levels; level++)
		{
			vk::ImageMemoryBarrier2 to_source = {
				...IMAGE_BARRIER,
				.image = texture.image,
				.srcStageMask = PIPELINE_STAGE_2_ALL_TRANSFER_BIT,
				.srcAccessMask = ACCESS_2_TRANSFER_WRITE_BIT,
				.dstStageMask = PIPELINE_STAGE_2_ALL_TRANSFER_BIT,
				.dstAccessMask = ACCESS_2_TRANSFER_READ_BIT,
				.oldLayout = IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
				.newLayout = IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
				.subresourceRange = { ...COLOR_LEVEL, .baseMipLevel = level - 1 },
			};
			vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo().setImageMemoryBarriers({ to_source }));

			// Floored at 1 rather than halved, because the short side reaches 1
			// while the long one is still shrinking. A zero extent is not a small
			// blit, it is an invalid one.
			int next_width  = mip_width > 1 ? mip_width / 2 : 1;
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

		// Two barriers, because the levels are in two different layouts by now:
		// everything the loop read from is in `TRANSFER_SRC`, and the last level
		// was only ever written to. Both are handed to one `cmdPipelineBarrier2` —
		// a dependency covers a *set* of subresources, and splitting these into
		// two calls would order the second against the first for no reason.
		// 
		// A one-level image takes the second entry alone.
		vk::ImageMemoryBarrier2 read_levels = {
			...IMAGE_BARRIER,
			.image = texture.image,
			.srcStageMask = PIPELINE_STAGE_2_ALL_TRANSFER_BIT,
			.srcAccessMask = ACCESS_2_TRANSFER_READ_BIT,
			.dstStageMask = PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT,
			.dstAccessMask = ACCESS_2_SHADER_READ_BIT,
			.oldLayout = IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
			.newLayout = IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
			.subresourceRange = { ...COLOR_LEVEL, .levelCount = levels - 1 },
		};
		vk::ImageMemoryBarrier2 last_level = {
			...read_levels,
			.srcAccessMask = ACCESS_2_TRANSFER_WRITE_BIT,
			.oldLayout = IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
			.subresourceRange = { ...COLOR_LEVEL, .baseMipLevel = levels - 1 },
		};
		// `last_level` first so a one-level image is the head of this array rather
		// than a special case built somewhere else.
		vk::ImageMemoryBarrier2[2] to_shader = { last_level, read_levels };
		usz used                             = levels > 1 ? 2 : 1;
		vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo().setImageMemoryBarriers(to_shader[:used]));
	}!;

	self.finish_texture(&texture, format, nearest)!;
	return texture;
}

<*
 The view and the sampler, which are the same question whatever wrote the levels.

 Split out when the block path arrived: a BC7 image and an RGBA8 one differ in
 how their levels get there and in nothing after, so having two copies of this
 would have been two places for `levelCount` and `maxLod` to drift apart.

 `levelCount = texture.levels`, and this is the half that is easy to leave
 behind: the image can have a full chain while the view exposes one level, and
 the result is not an error anywhere — it is a sampler whose `maxLod` clamps
 against levels the view does not have, which reads as a texture that never blurs
 however far away it gets.

 `maxLod` is what "no mips" actually was, not the missing levels: a sampler
 clamped to lod 0 samples the top level however small the surface is on screen.
 It is `levels` rather than `LOD_CLAMP_NONE` because this image really has that
 many, and a clamp stating the truth about its own image is one fewer thing to
 keep in step if a chain is ever declined.

 Nearest is a whole different sampler, decided here rather than patched on: no
 mipmap mode, because a nearest-filtered image that blends levels is neither one
 thing nor the other.
*>
fn void? Gpu.finish_texture(&self, Texture* texture, vk::Format format, bool nearest)
{
	uint levels = texture.levels;

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

	vk::Filter filter        = nearest ? FILTER_NEAREST : FILTER_LINEAR;
	vk::SamplerMipmapMode mode = nearest ? SAMPLER_MIPMAP_MODE_NEAREST : SAMPLER_MIPMAP_MODE_LINEAR;

	texture.sampler = vk::samplerCreateInfo().setMagFilter(filter).setMinFilter(filter)
		.setAddressModeU(SAMPLER_ADDRESS_MODE_REPEAT)
		.setAddressModeV(SAMPLER_ADDRESS_MODE_REPEAT)
		.setAddressModeW(SAMPLER_ADDRESS_MODE_REPEAT)
		.setMipmapMode(mode)
		.setMinLod(0.0)
		.setMaxLod((float)levels)
		.setBorderColor(BORDER_COLOR_INT_OPAQUE_BLACK)
		.build(self.handle)!;
}

<*
 Uploads an image whose levels are already encoded — one copy region per level,
 out of one staging buffer.

 ## Why this is shorter than the path beside it

 `create_texture` copies level 0 and then *builds* the rest, so every level after
 the first is a blit whose source is the level above it: a real dependency, hence
 a barrier inside the loop and a `TRANSFER_SRC` round trip for every level but
 the last. Here the levels arrive already written. Nothing reads anything back,
 so there is no dependency between the copies at all, and the whole upload is one
 barrier in, one `cmdCopyBufferToImage` with N regions, one barrier out.

 `can_generate_mips` is never asked, which is what `Gpu.can_generate_mips`'s own
 note has been saying since before a BC7 image could exist here: a block format
 is not blittable on most devices and does not need to be, because it carries the
 levels its author wrote.

 ## Sizes come from the format, not from the extents

 Every level's byte count is `TextureFormat.image_size`, which rounds up to whole
 blocks. That is checked rather than trusted — a level handed over short is not a
 small image, it is a copy that reads past the end of what the caller allocated,
 and `VUID-vkCmdCopyBufferToImage-pRegions-00171` catches it only if the layer is
 running.

 ## The hash covers every level

 `create_texture` hashes the decoded RGBA it was given. There is no decoded RGBA
 here, so the hash is over the packed blocks — all of them, because two files
 that agree at level 0 and differ further down are two different images and
 sharing a slot between them would hand one of them the other's distance.

 @param levels : `Level 0 first. Each exactly image_size bytes for its own extents.`
 @param format : `The family and space these blocks are in. RGBA8 is allowed and behaves.`
 @require levels.len > 0 : `An image with no levels is not an image.`
 @require levels.len <= MAX_UPLOAD_LEVELS
*>
fn Texture? Gpu.create_texture_levels(
	&self,
	char[][] levels,
	uint width,
	uint height,
	TextureFormat format,
	bool nearest = false
)
{
	uint count = (uint)levels.len;
	if (count > mip_levels(width, height)) return TEXTURE_TOO_MANY_LEVELS~;

	// The guard rather than the choice. Deciding to decode to RGBA8 instead
	// belongs where the bytes are still encoded and a different decode is still
	// possible; by here the caller has already committed, so all this can do is
	// refuse — and refusing is much better than the alternative, which is
	// `VK_ERROR_FORMAT_NOT_SUPPORTED` from an honest driver and a wrongly
	// sampled image from a lenient one.
	if (!self.supports(format)) return TEXTURE_FORMAT_UNSUPPORTED~;

	// Sized and checked before anything is created, so a bad file costs no
	// device object and the error names the level rather than the image.
	sz total = 0;
	for (uint level = 0; level < count; level++)
	{
		sz want = format.image_size(level_extent(width, level), level_extent(height, level));
		if ((sz)levels[level].len != want) return TEXTURE_LEVEL_WRONG_SIZE~;
		total += want;
	}

	vk::Format vkformat = format.vk();

	Texture texture = {
		.width = width,
		.height = height,
		.levels = count,
		.format = format,
		.nearest = nearest,
	};

	texture.image = vk::imageCreateInfo().setImageType(IMAGE_TYPE_2D).setFormat(vkformat)
		.setExtent({ .width = width, .height = height, .depth = 1 })
		.setMipLevels(count)
		.setArrayLayers(1)
		.setSamples(SAMPLE_COUNT_1_BIT)
		.setTiling(IMAGE_TILING_OPTIMAL)
		// `TRANSFER_SRC` is here for the same reason as on the RGBA8 path and not
		// for the blit: an image may only enter a layout its usage admits, so
		// without it a later readback is invalid rather than merely refused.
		.setUsage(IMAGE_USAGE_TRANSFER_DST_BIT | IMAGE_USAGE_TRANSFER_SRC_BIT | IMAGE_USAGE_SAMPLED_BIT)
		.setInitialLayout(IMAGE_LAYOUT_UNDEFINED)
		.build(self.handle)!;

	texture.memory = vk::create_image_buffer(texture.image, &self.allocator, MEMORY_PROPERTY_DEVICE_LOCAL_BIT)!;

	vk::Memory stage = vk::new_buffer(
		&self.allocator,
		usage: BUFFER_USAGE_TRANSFER_SRC_BIT,
		properties: MEMORY_PROPERTY_HOST_VISIBLE_BIT | MEMORY_PROPERTY_HOST_COHERENT_BIT,
		data: null,
		data_size: total,
	)!;
	defer stage.free();

	// Packed straight into the mapped staging memory rather than into a host
	// array first, so the levels are copied once instead of twice.
	char* packed = (char*)stage.data();
	vk::BufferImageCopy[MAX_UPLOAD_LEVELS] regions;
	sz offset = 0;
	for (uint level = 0; level < count; level++)
	{
		mem::copy(packed + offset, levels[level].ptr, levels[level].len);
		regions[level] = {
			// A whole number of blocks, so this satisfies the alignment the copy
			// wants without any padding between levels.
			.bufferOffset = (ulong)offset,
			.bufferRowLength = 0,
			.bufferImageHeight = 0,
			.imageSubresource = {
				.aspectMask = IMAGE_ASPECT_COLOR_BIT,
				.mipLevel = level,
				.baseArrayLayer = 0,
				.layerCount = 1,
			},
			.imageOffset = { 0, 0, 0 },
			// The level's own extents in texels, not in blocks — Vulkan does the
			// block arithmetic itself and wants the picture's size.
			.imageExtent = { level_extent(width, level), level_extent(height, level), 1 },
		};
		offset += levels[level].len;
	}

	texture.hash = content_hash_levels(levels);

	self.handle.@single_time_command(queue: self.graphics ; vk::CommandBuffer cmd)
	{
		vk::ImageMemoryBarrier2 to_transfer = {
			...IMAGE_BARRIER,
			.image = texture.image,
			.srcStageMask = PIPELINE_STAGE_2_TOP_OF_PIPE_BIT,
			.srcAccessMask = (vk::AccessFlags2)0,
			.dstStageMask = PIPELINE_STAGE_2_ALL_TRANSFER_BIT,
			.dstAccessMask = ACCESS_2_TRANSFER_WRITE_BIT,
			.oldLayout = IMAGE_LAYOUT_UNDEFINED,
			.newLayout = IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
			.subresourceRange = { ...COLOR_LEVEL, .levelCount = count },
		};
		vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo().setImageMemoryBarriers({ to_transfer }));

		// Every level in one call. They are independent writes to disjoint
		// subresources, so there is nothing to order between them.
		vk::cmdCopyBufferToImage(
			cmd,
			stage.buffer,
			texture.image,
			IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
			count,
			&regions[0]
		);

		// One barrier for the whole chain, because every level is in the same
		// layout — which is the part the generated path cannot do.
		vk::ImageMemoryBarrier2 to_shader = {
			...IMAGE_BARRIER,
			.image = texture.image,
			.srcStageMask = PIPELINE_STAGE_2_ALL_TRANSFER_BIT,
			.srcAccessMask = ACCESS_2_TRANSFER_WRITE_BIT,
			.dstStageMask = PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT,
			.dstAccessMask = ACCESS_2_SHADER_READ_BIT,
			.oldLayout = IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
			.newLayout = IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
			.subresourceRange = { ...COLOR_LEVEL, .levelCount = count },
		};
		vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo().setImageMemoryBarriers({ to_shader }));
	}!;

	self.finish_texture(&texture, vkformat, nearest)!;
	return texture;
}

<*
 Copies a texture's pixels back off the device, into a caller's buffer.

 Without this, textures are write-only: a script cannot read a generated
 texture's average colour to bake into an export, a texture loaded from a file
 cannot be inspected at all, and every texture check has to go the long way round
 through a rendered frame.

 ## What comes back

 Exactly the bytes that were uploaded. `vkCmdCopyImageToBuffer` is a copy rather
 than a blit, so it moves stored bytes and performs no conversion — what lands in
 `dst` is the RGBA the texture was created from, not the values the sampler
 produces. That round-trips against `DataTexture`, and for an `SRGB` texture it
 is the same space `png::save_file` wants. It is also why `space` does not appear
 here: the two formats store the same bytes and differ only in what sampling does
 to them.

 Level 0 only. The generated levels are not the caller's data and there is no
 verb to ask for one — a level is an approximation this file made up, and handing
 one back through a function whose contract is "the bytes that went in" would
 make that contract false invisibly. The barriers are scoped to level 0 for the
 same reason; the rest of the chain stays in `SHADER_READ_ONLY` throughout, which
 is legal precisely because a layout is per subresource.

 ## The layout dance

 The image lives in `SHADER_READ_ONLY_OPTIMAL` between uploads, which is where
 `create_texture` leaves it and where the descriptor expects it. This moves it to
 `TRANSFER_SRC_OPTIMAL`, copies, and moves it *back* — the return leg is not
 optional, and its absence is invisible until something draws with the texture
 again several frames later, as a validation error or a black surface depending
 on the driver.

 `@single_time_command` submits and waits, so this is synchronous and costs a
 queue idle: the right trade for a verb a script calls at load or in a test, and
 the wrong one per frame. That is why nothing here caches, and why the JS side
 takes a destination rather than allocating.

 @param dst : `Filled with width*height*4 bytes. The caller owns it; nothing is retained.`
 @return ? TEXTURE_IS_COMPRESSED : `A block-compressed texture. Its bytes are blocks, not pixels.`
 @require dst.len >= (sz)self.width * self.height * 4
*>
fn void? Texture.read_pixels(&self, Gpu* gpu, char[] dst)
{
	// Refused rather than attempted, and named rather than approximated. The
	// copy would succeed: `vkCmdCopyImageToBuffer` moves stored bytes, so a BC7
	// image hands back a quarter as many of them as the contract promises and
	// the rest of `dst` keeps whatever it held. That reads as a corrupt texture
	// downstream and says nothing about the format that caused it. Decoding the
	// blocks here instead would be a decoder living in the GPU layer to serve a
	// verb that exists for tests and exports.
	if (self.format.is_block()) return TEXTURE_IS_COMPRESSED~;

	sz bytes = (sz)self.width * (sz)self.height * 4;

	vk::Memory readback = vk::new_buffer(
		&gpu.allocator,
		usage: BUFFER_USAGE_TRANSFER_DST_BIT,
		properties: MEMORY_PROPERTY_HOST_VISIBLE_BIT | MEMORY_PROPERTY_HOST_COHERENT_BIT,
		data: null,
		data_size: bytes,
	)!;
	defer readback.free();

	gpu.handle.@single_time_command(queue: gpu.graphics ; vk::CommandBuffer cmd)
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

		// Back where the descriptor expects it. Leaving it in TRANSFER_SRC is the
		// failure that shows up several frames later in something unrelated.
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

 It is what keeps the renderer to a single pipeline: the descriptor binding is
 always occupied, so there is no "has texture" specialisation and no shader
 permutation — the material's base colour factor multiplied by white is the
 material's base colour factor.
*>
fn Texture? Gpu.create_white_texture(&self)
{
	char[4] white = { 0xff, 0xff, 0xff, 0xff };
	return self.create_texture(white[..], 1, 1);
}

<*
 Gives the image back, once the frames that may still be sampling it are done.

 Through `gpu/retire.c3` rather than straight to the driver, which is what makes
 a texture droppable *during* a frame: a command buffer in flight may still be
 reading the image.

 The struct is zeroed on the way out, and that is load-bearing twice over: the
 queue owns these handles from here, so a copy left behind is a double free, and
 a dead `SharedTexture` slot with an image handle still in it is the one bug the
 texture table's tests look for.
*>
fn void Texture.free(&self, Gpu* gpu)
{
	// Memory.free destroys the image it was bound to; destroying it separately
	// would be a double free, which is why the image handle is not handed over.
	gpu.retire_memory(self.memory, self.view, self.sampler);
	*self = { };
}