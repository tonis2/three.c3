<*
 Storage images: the formats shady can declare, what each one is on the device,
 and whether this device can have it.

 shady names a storage format the way GLSL's layout qualifiers do - `rgba16f`,
 `r32ui`, `r11f_g11f_b10f` - and writes it into the module as SPIR-V's
 `ImageFormat`. Vulkan names the same thing a third way. The table below is the
 one place the three spellings meet, and everything that binds a storage image -
 a compute kernel's image handle, a post pass's output, a pass's own images -
 goes through it, so a script's `format: 'rgba16f'` and a shader's
 `image2d<rgba16f>` cannot disagree about which `vk::Format` they mean.

 ## Why the name is not taken from shady

 `shady::storage_format` is public and answers name -> `ImageFormat`, but its
 table is `@local` and says nothing about Vulkan. So this table is a second one,
 and `the_storage_format_table_agrees_with_shady` holds the two to each other:
 every name here is a name shady accepts, for the same `ImageFormat`, with the
 same texel type and the same core/extended split.
*>
module three;

import vk;
import shady;

faultdef STORAGE_FORMAT_UNKNOWN, STORAGE_FORMAT_UNSUPPORTED;

<*
 How one component of a texel is stored, which is what a readback has to know
 to hand a script the numbers rather than the bytes.

 `F16` is read back as float: a script has no half type, and the conversion is
 exact. `PACKED32` is the two formats whose channels do not sit on byte
 boundaries - `rgb10_a2` and `r11f_g11f_b10f` - and arrives as the raw words.
*>
enum TexelStore : char
{
	F32,
	F16,
	U8,
	S8,
	U16,
	S16,
	U32,
	S32,
	PACKED32,
}

<*
 One storage format, in all three of its spellings.
*>
struct StorageImageFormat
{
	// shady's and GLSL's name, which is also what a script writes.
	String name;
	// `shady::ImageFormat`, SPIR-V's numbering - what reflection reads back.
	uint shady;
	vk::Format vk;
	// 1 to 4. A packed format is one word and says how many channels it packs.
	uint channels;
	TexelStore store;
	TexelClass texel;
	// Outside the thirteen formats every device stores. Needs
	// `shaderStorageImageExtendedFormats`, and is refused by name without it.
	bool extended;
}

<*
 Bytes one texel occupies in the image.
*>
fn uint StorageImageFormat.texel_bytes(&self)
{
	switch (self.store)
	{
		case F32:
		case U32:
		case S32: return 4 * self.channels;
		case F16:
		case U16:
		case S16: return 2 * self.channels;
		case U8:
		case S8: return self.channels;
		case PACKED32: return 4;
	}
}

<*
 Bytes one component of a texel occupies once it has been read back: what a
 typed array over the readback is made of. Half floats widen to 4.
*>
fn uint StorageImageFormat.read_bytes(&self)
{
	switch (self.store)
	{
		case F32:
		case F16:
		case U32:
		case S32:
		case PACKED32: return 4;
		case U16:
		case S16: return 2;
		case U8:
		case S8: return 1;
	}
}

<*
 How many numbers one texel reads back as - its channels, or one word for a
 packed format.
*>
fn uint StorageImageFormat.read_components(&self) => self.store == TexelStore.PACKED32 ? 1 : self.channels;

<*
 Whether a sampler may read this format as numbers in 0..1 or -1..1 - every
 float and normalized format. An integer image is not a texture: a sampler over
 one returns integers a material's float arithmetic would misread, and Vulkan
 forbids a linear filter on one outright.
*>
fn bool StorageImageFormat.is_float(&self) => self.texel == TexelClass.FLOAT;

const StorageImageFormat[*] STORAGE_IMAGE_FORMATS = {
	// The core thirteen, in shady's order.
	{ "rgba32f",        1,  FORMAT_R32G32B32A32_SFLOAT,     4, F32,      FLOAT, false },
	{ "rgba16f",        2,  FORMAT_R16G16B16A16_SFLOAT,     4, F16,      FLOAT, false },
	{ "r32f",           3,  FORMAT_R32_SFLOAT,              1, F32,      FLOAT, false },
	{ "rgba8",          4,  FORMAT_R8G8B8A8_UNORM,          4, U8,       FLOAT, false },
	{ "rgba8_snorm",    5,  FORMAT_R8G8B8A8_SNORM,          4, S8,       FLOAT, false },
	{ "rg32f",          6,  FORMAT_R32G32_SFLOAT,           2, F32,      FLOAT, true },
	{ "rg16f",          7,  FORMAT_R16G16_SFLOAT,           2, F16,      FLOAT, true },
	// GLSL's r11f_g11f_b10f is Vulkan's B10G11R11: Vulkan names packed formats
	// from the most significant bit down, GLSL from the least.
	{ "r11f_g11f_b10f", 8,  FORMAT_B10G11R11_UFLOAT_PACK32, 3, PACKED32, FLOAT, true },
	{ "r16f",           9,  FORMAT_R16_SFLOAT,              1, F16,      FLOAT, true },
	{ "rgba16",         10, FORMAT_R16G16B16A16_UNORM,      4, U16,      FLOAT, true },
	// And for the same reason, rgb10_a2 is A2B10G10R10.
	{ "rgb10_a2",       11, FORMAT_A2B10G10R10_UNORM_PACK32, 4, PACKED32, FLOAT, true },
	{ "rg16",           12, FORMAT_R16G16_UNORM,            2, U16,      FLOAT, true },
	{ "rg8",            13, FORMAT_R8G8_UNORM,              2, U8,       FLOAT, true },
	{ "r16",            14, FORMAT_R16_UNORM,               1, U16,      FLOAT, true },
	{ "r8",             15, FORMAT_R8_UNORM,                1, U8,       FLOAT, true },
	{ "rgba16_snorm",   16, FORMAT_R16G16B16A16_SNORM,      4, S16,      FLOAT, true },
	{ "rg16_snorm",     17, FORMAT_R16G16_SNORM,            2, S16,      FLOAT, true },
	{ "rg8_snorm",      18, FORMAT_R8G8_SNORM,              2, S8,       FLOAT, true },
	{ "r16_snorm",      19, FORMAT_R16_SNORM,               1, S16,      FLOAT, true },
	{ "r8_snorm",       20, FORMAT_R8_SNORM,                1, S8,       FLOAT, true },
	{ "rgba32i",        21, FORMAT_R32G32B32A32_SINT,       4, S32,      SINT,  false },
	{ "rgba16i",        22, FORMAT_R16G16B16A16_SINT,       4, S16,      SINT,  false },
	{ "rgba8i",         23, FORMAT_R8G8B8A8_SINT,           4, S8,       SINT,  false },
	{ "r32i",           24, FORMAT_R32_SINT,                1, S32,      SINT,  false },
	{ "rg32i",          25, FORMAT_R32G32_SINT,             2, S32,      SINT,  true },
	{ "rg16i",          26, FORMAT_R16G16_SINT,             2, S16,      SINT,  true },
	{ "rg8i",           27, FORMAT_R8G8_SINT,               2, S8,       SINT,  true },
	{ "r16i",           28, FORMAT_R16_SINT,                1, S16,      SINT,  true },
	{ "r8i",            29, FORMAT_R8_SINT,                 1, S8,       SINT,  true },
	{ "rgba32ui",       30, FORMAT_R32G32B32A32_UINT,       4, U32,      UINT,  false },
	{ "rgba16ui",       31, FORMAT_R16G16B16A16_UINT,       4, U16,      UINT,  false },
	{ "rgba8ui",        32, FORMAT_R8G8B8A8_UINT,           4, U8,       UINT,  false },
	{ "r32ui",          33, FORMAT_R32_UINT,                1, U32,      UINT,  false },
	{ "rgb10_a2ui",     34, FORMAT_A2B10G10R10_UINT_PACK32, 4, PACKED32, UINT,  true },
	{ "rg32ui",         35, FORMAT_R32G32_UINT,             2, U32,      UINT,  true },
	{ "rg16ui",         36, FORMAT_R16G16_UINT,             2, U16,      UINT,  true },
	{ "rg8ui",          37, FORMAT_R8G8_UINT,               2, U8,       UINT,  true },
	{ "r16ui",          38, FORMAT_R16_UINT,                1, U16,      UINT,  true },
	{ "r8ui",           39, FORMAT_R8_UINT,                 1, U8,       UINT,  true },
};

<*
 The format a script or a pass declaration names.

 @return ? STORAGE_FORMAT_UNKNOWN : `Not a name shady accepts. storage_format_hint() has the nearest one when there is an obvious one.`
*>
fn StorageImageFormat? storage_format_named(String name)
{
	foreach (format : STORAGE_IMAGE_FORMATS) if (format.name == name) return format;
	return STORAGE_FORMAT_UNKNOWN~;
}

<*
 The format a module declared, by the `shady::ImageFormat` reflection read.

 @return ? STORAGE_FORMAT_UNKNOWN : `Zero - the host picks - or a number shady never writes.`
*>
fn StorageImageFormat? storage_format_of(uint shady_format)
{
	foreach (format : STORAGE_IMAGE_FORMATS) if (format.shady == shady_format) return format;
	return STORAGE_FORMAT_UNKNOWN~;
}

<*
 The format an image already is, for a message that names it.

 @return ? STORAGE_FORMAT_UNKNOWN : `A Vulkan format no storage declaration can name.`
*>
fn StorageImageFormat? storage_format_of_vk(vk::Format vk_format)
{
	foreach (format : STORAGE_IMAGE_FORMATS) if (format.vk == vk_format) return format;
	return STORAGE_FORMAT_UNKNOWN~;
}

<*
 What a script probably meant by a name that is not a format, or "".

 Only the mistakes worth a sentence: the three-channel formats no storage image
 has, and the colour-space suffix none can carry.
*>
fn String storage_format_hint(String name)
{
	switch (name)
	{
		case "rgb8": return "rgba8";
		case "rgb16f": return "rgba16f";
		case "rgb32f": return "rgba32f";
		case "rgba8_srgb":
		case "srgb8": return "rgba8 - a storage image cannot be sRGB; encode in the shader";
		case "float4": return "rgba16f or rgba32f";
		case "float": return "r32f";
		case "uint": return "r32ui";
		case "int": return "r32i";
		default: return "";
	}
}

<*
 The name of a texel class, for a message a person reads.
*>
fn String texel_class_name(TexelClass texel)
{
	switch (texel)
	{
		case FLOAT: return "float";
		case SINT: return "int";
		case UINT: return "uint";
		default: return "unknown";
	}
}

<*
 Whether this device can store to an image of this format, from a shader.

 Per format and uncached, for `can_sample`'s reason. The atomics an `r32ui`
 image is used for need no question of their own: `STORAGE_IMAGE_ATOMIC_BIT` is
 mandatory for `R32_UINT` and `R32_SINT`.
*>
fn bool Gpu.can_store(&self, vk::Format format)
{
	const vk::FormatFeatureFlags NEEDED = FORMAT_FEATURE_STORAGE_IMAGE_BIT;

	vk::FormatProperties props;
	vk::getPhysicalDeviceFormatProperties(self.pdevice, format, &props);
	return (props.optimalTilingFeatures & NEEDED) == NEEDED;
}

<*
 Whether a sampler over this format may filter linearly. `R32_SFLOAT` and
 `R32G32B32A32_SFLOAT` are the common formats a device is entitled to refuse.
*>
fn bool Gpu.can_filter(&self, vk::Format format)
{
	const vk::FormatFeatureFlags NEEDED = FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR_BIT;

	vk::FormatProperties props;
	vk::getPhysicalDeviceFormatProperties(self.pdevice, format, &props);
	return (props.optimalTilingFeatures & NEEDED) == NEEDED;
}

<*
 Whether this device can have a storage image of this format at all: the format
 feature, and the extended-formats feature for a format outside the core
 thirteen. The question every path that creates a storage image asks first.
*>
fn bool Gpu.can_have_storage(&self, StorageImageFormat format)
{
	if (format.extended && !self.limits.storage_image_extended_formats) return false;
	return self.can_store(format.vk);
}

// ============================================================================
// Images a compute kernel writes
// ============================================================================

<*
 An image a kernel writes and anything else may read: a material, a post pass,
 another kernel, a readback.

 A `Texture`, so it goes where textures go - a slot in `Assets.textures`, an
 index in the device-wide table, a reference count, `dispose` - and differs only
 in being written by a shader rather than uploaded. `Texture.storage` is what
 tells the two apart, and `resting_layout` is the consequence: the image lives in
 `GENERAL`, the one layout a kernel's stores and a material's samples are both
 legal in, because nothing between the two submissions could transition it.

 One level. A chain would need a kernel or a blit per level after every write,
 and nothing a script writes this way wants one decided for it.

 Starts at zero rather than at whatever the memory held: an accumulator, a
 history image and a histogram all want that, and an image read before anything
 wrote it should read as nothing rather than as last run's frame.

 `SAMPLED` usage only where the device can sample the format, so an integer image
 - which no material could filter anyway - costs nothing it cannot use.

 @param nearest : `The sampler's filter when it is sampled. A format the device cannot filter linearly is nearest whatever this says.`
 @return ? STORAGE_FORMAT_UNSUPPORTED : `This device cannot store to the format, or the format is an extended one and the device lacks shaderStorageImageExtendedFormats.`
*>
fn Texture? Gpu.create_storage_texture(&self, uint width, uint height, StorageImageFormat format, bool nearest = false)
{
	if (!self.can_have_storage(format)) return STORAGE_FORMAT_UNSUPPORTED~;

	bool sampled = self.can_sample(format.vk);
	vk::ImageUsageFlags usage = IMAGE_USAGE_STORAGE_BIT | IMAGE_USAGE_TRANSFER_SRC_BIT | IMAGE_USAGE_TRANSFER_DST_BIT;
	if (sampled) usage |= IMAGE_USAGE_SAMPLED_BIT;

	Texture texture = {
		.width = width,
		.height = height,
		.levels = 1,
		// Meaningless for a storage image - `storage` is the format - and set to
		// the linear RGBA8 pair so nothing that reads it is handed a block family.
		.format = rgba8(ColorSpace.LINEAR),
		.nearest = nearest || !self.can_filter(format.vk),
		.storage = format.vk,
	};

	texture.memory = self.create_device_image(format.vk, width, height, usage)!;
	texture.image = texture.memory.image;

	self.handle.@single_time_command(queue: self.graphics ; vk::CommandBuffer cmd)
	{
		vk::ImageMemoryBarrier2 to_general = {
			...IMAGE_BARRIER,
			.image = texture.image,
			.srcStageMask = PIPELINE_STAGE_2_TOP_OF_PIPE_BIT,
			.srcAccessMask = (vk::AccessFlags2)0,
			.dstStageMask = PIPELINE_STAGE_2_CLEAR_BIT,
			.dstAccessMask = ACCESS_2_TRANSFER_WRITE_BIT,
			.oldLayout = IMAGE_LAYOUT_UNDEFINED,
			.newLayout = IMAGE_LAYOUT_GENERAL,
		};
		vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo().setImageMemoryBarriers({ to_general }));

		// Zero in every class: 0.0 and 0 are the same bits.
		vk::ClearColorValue zero = { .uint32 = { 0, 0, 0, 0 } };
		vk::cmdClearColorImage(cmd, texture.image, IMAGE_LAYOUT_GENERAL, &zero, 1, &COLOR_LEVEL);

		// Visible to whatever is submitted next: a kernel, a frame, a readback.
		vk::ImageMemoryBarrier2 ready = {
			...IMAGE_BARRIER,
			.image = texture.image,
			.srcStageMask = PIPELINE_STAGE_2_CLEAR_BIT,
			.srcAccessMask = ACCESS_2_TRANSFER_WRITE_BIT,
			.dstStageMask = PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
			.dstAccessMask = ACCESS_2_SHADER_READ_BIT | ACCESS_2_SHADER_WRITE_BIT
				| ACCESS_2_TRANSFER_READ_BIT | ACCESS_2_TRANSFER_WRITE_BIT,
			.oldLayout = IMAGE_LAYOUT_GENERAL,
			.newLayout = IMAGE_LAYOUT_GENERAL,
		};
		vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo().setImageMemoryBarriers({ ready }));
	}!;

	// The view and the sampler are an uploaded texture's, over one level.
	self.finish_texture(&texture, format.vk, texture.nearest)!;
	return texture;
}

<*
 The format a storage texture is, from its table. Every storage texture was made
 from one of these, so the lookup cannot miss for one.

 @require self.storage != FORMAT_UNDEFINED : `an uploaded texture has no storage format`
*>
fn StorageImageFormat Texture.storage_format(&self) => storage_format_of_vk(self.storage) ?? STORAGE_IMAGE_FORMATS[0];

<*
 Bytes a readback of the whole image hands a script: `read_components` numbers a
 texel, each `read_bytes` wide.
*>
fn sz Texture.storage_read_size(&self)
{
	StorageImageFormat format = self.storage_format();
	return (sz)self.width * (sz)self.height * (sz)format.read_components() * (sz)format.read_bytes();
}

<*
 A half float's value as a float. Exact: every half is a float.
*>
fn float half_to_float(ushort half)
{
	uint sign = ((uint)half >> 15) << 31;
	uint exponent = ((uint)half >> 10) & 0x1f;
	uint mantissa = (uint)half & 0x3ff;
	if (exponent == 0)
	{
		// Zero, or a subnormal: the mantissa in units of 2^-24.
		float value = (float)mantissa * 5.9604644775390625e-8f;
		return sign != 0 ? -value : value;
	}
	uint bits;
	if (exponent == 31)
	{
		bits = sign | 0x7f80_0000 | (mantissa << 13);
	}
	else
	{
		bits = sign | ((exponent + 112) << 23) | (mantissa << 13);
	}
	return bitcast(bits, float);
}

<*
 The nearest half to a float, ties to even - what a GPU's own conversion does,
 so a value written from a script and the same value stored by a kernel are the
 same bits. Past the half range is infinity, below it is a signed zero.
*>
fn ushort float_to_half(float value)
{
	uint bits = bitcast(value, uint);
	uint sign = (bits >> 16) & 0x8000;
	uint biased = (bits >> 23) & 0xff;
	uint mantissa = bits & 0x7f_ffff;

	if (biased == 0xff) return (ushort)(sign | 0x7c00 | (mantissa != 0 ? 0x200 : 0));
	int exponent = (int)biased - 127 + 15;
	if (exponent >= 31) return (ushort)(sign | 0x7c00);
	if (exponent <= 0)
	{
		if (exponent < -10) return (ushort)sign;
		mantissa |= 0x80_0000;
		uint shift = (uint)(14 - exponent);
		uint kept = mantissa >> shift;
		uint rest = mantissa & ((1u << shift) - 1);
		uint halfway = 1u << (shift - 1);
		if (rest > halfway || (rest == halfway && (kept & 1) != 0)) kept++;
		return (ushort)(sign | kept);
	}
	uint result = sign | ((uint)exponent << 10) | (mantissa >> 13);
	uint rest = mantissa & 0x1fff;
	// A carry out of the mantissa lands in the exponent, which is the right
	// answer: the next power of two up.
	if (rest > 0x1000 || (rest == 0x1000 && (result & 1) != 0)) result++;
	return (ushort)result;
}

<*
 Copies the whole image back, as numbers a script can read: one texel after
 another, row by row from the top, each `read_components` values of
 `read_bytes`. A half-float image arrives as floats.

 Submits anything the kernels still owe first, like `StorageBuffer.read`: a
 readback of work that is recorded and not submitted would read the image as it
 was before it.

 @param into : `At least storage_read_size() bytes. The caller owns it.`
 @require self.storage != FORMAT_UNDEFINED
 @require into.len >= self.storage_read_size()
*>
fn void? Texture.read_storage(&self, Compute* compute, char[] into)
{
	compute.flush()!;
	Gpu* gpu = compute.gpu;
	StorageImageFormat format = self.storage_format();
	sz texels = (sz)self.width * (sz)self.height;
	sz bytes = texels * (sz)format.texel_bytes();

	vk::Memory stage = gpu.create_readback(bytes)!;
	defer stage.free();

	gpu.handle.@single_time_command(queue: gpu.graphics ; vk::CommandBuffer cmd)
	{
		storage_copy_barrier(cmd, self.image, true);
		vk::BufferImageCopy region = {
			.imageSubresource = { .aspectMask = IMAGE_ASPECT_COLOR_BIT, .layerCount = 1 },
			.imageExtent = { self.width, self.height, 1 },
		};
		vk::cmdCopyImageToBuffer(cmd, self.image, IMAGE_LAYOUT_GENERAL, stage.buffer, 1, &region);
		storage_copy_barrier(cmd, self.image, false);
	}!;

	char* stored = (char*)stage.data();
	if (format.store != TexelStore.F16)
	{
		mem::copy(into.ptr, stored, bytes);
		return;
	}
	ushort* halves = (ushort*)stored;
	float* floats = (float*)into.ptr;
	sz count = texels * (sz)format.channels;
	for (sz i = 0; i < count; i++) floats[i] = half_to_float(halves[i]);
}

<*
 Replaces the whole image with numbers a script wrote, in `read_storage`'s own
 layout - so a readback written straight back is the image it came from. A
 half-float image is written from floats.

 Bumps the compute epoch, because the picture changes through a door no scene
 change saw: a material sampling this image draws something new.

 @require self.storage != FORMAT_UNDEFINED
 @require values.len >= self.storage_read_size()
*>
fn void? Texture.write_storage(&self, Compute* compute, char[] values)
{
	compute.flush()!;
	Gpu* gpu = compute.gpu;
	StorageImageFormat format = self.storage_format();
	sz texels = (sz)self.width * (sz)self.height;
	sz bytes = texels * (sz)format.texel_bytes();

	vk::Memory stage = gpu.create_upload(bytes)!;
	defer stage.free();

	char* staged = (char*)stage.data();
	if (format.store == TexelStore.F16)
	{
		float* floats = (float*)values.ptr;
		ushort* halves = (ushort*)staged;
		sz count = texels * (sz)format.channels;
		for (sz i = 0; i < count; i++) halves[i] = float_to_half(floats[i]);
	}
	else
	{
		mem::copy(staged, values.ptr, bytes);
	}

	gpu.handle.@single_time_command(queue: gpu.graphics ; vk::CommandBuffer cmd)
	{
		storage_copy_barrier(cmd, self.image, true, write: true);
		vk::BufferImageCopy region = {
			.imageSubresource = { .aspectMask = IMAGE_ASPECT_COLOR_BIT, .layerCount = 1 },
			.imageExtent = { self.width, self.height, 1 },
		};
		vk::cmdCopyBufferToImage(cmd, stage.buffer, self.image, IMAGE_LAYOUT_GENERAL, 1, &region);
		storage_copy_barrier(cmd, self.image, false, write: true);
	}!;
	compute.image_epoch++;
}

<*
 The two barriers around a copy into or out of a storage image, which stays in
 `GENERAL` throughout.

 Before: after everything already on the queue - a frame still sampling the
 image, a kernel still writing it - and with their writes visible to the copy.
 After: the copy's own write, or only its execution for a read, made visible to
 whatever is submitted next.
*>
fn void storage_copy_barrier(vk::CommandBuffer cmd, vk::Image image, bool before, bool write = false) @local
{
	vk::AccessFlags2 copy_access = write ? ACCESS_2_TRANSFER_WRITE_BIT : ACCESS_2_TRANSFER_READ_BIT;
	vk::ImageMemoryBarrier2 barrier = before
		? (vk::ImageMemoryBarrier2) {
			...IMAGE_BARRIER,
			.image = image,
			.srcStageMask = PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
			.srcAccessMask = ACCESS_2_SHADER_WRITE_BIT | ACCESS_2_TRANSFER_WRITE_BIT,
			.dstStageMask = PIPELINE_STAGE_2_ALL_TRANSFER_BIT,
			.dstAccessMask = copy_access,
			.oldLayout = IMAGE_LAYOUT_GENERAL,
			.newLayout = IMAGE_LAYOUT_GENERAL,
		}
		: (vk::ImageMemoryBarrier2) {
			...IMAGE_BARRIER,
			.image = image,
			.srcStageMask = PIPELINE_STAGE_2_ALL_TRANSFER_BIT,
			.srcAccessMask = write ? ACCESS_2_TRANSFER_WRITE_BIT : (vk::AccessFlags2)0,
			.dstStageMask = PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
			.dstAccessMask = ACCESS_2_SHADER_READ_BIT | ACCESS_2_SHADER_WRITE_BIT
				| ACCESS_2_TRANSFER_READ_BIT | ACCESS_2_TRANSFER_WRITE_BIT,
			.oldLayout = IMAGE_LAYOUT_GENERAL,
			.newLayout = IMAGE_LAYOUT_GENERAL,
		};
	vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo().setImageMemoryBarriers({ barrier }));
}

<*
 Whether an image may go in a kernel's binding, as a sentence saying why not.

 A storage binding takes a storage image whose format is the one declared - or,
 for a format the host picks, one whose texels are the declared class. A sampled
 binding takes any texture the device can sample as floats: an uploaded one, or
 a float storage image. Anything else would compile, bind, and reinterpret bits.

 @return `"" when the image fits, otherwise the reason, in temporary memory.`
*>
fn String storage_image_mismatch(Gpu* gpu, ComputeBindingInfo* info, Texture* image)
{
	if (info.type == DESCRIPTOR_TYPE_STORAGE_IMAGE)
	{
		if (image.storage == FORMAT_UNDEFINED)
		{
			return "it is an uploaded texture, and a kernel stores only into an image made by three.compute.image()";
		}
		StorageImageFormat have = image.storage_format();
		if (info.storage_format != 0)
		{
			StorageImageFormat? want = storage_format_of(info.storage_format);
			if (try want && want.vk != image.storage)
			{
				return string::tformat("the shader declares it %s and the image is %s", want.name, have.name);
			}
			return "";
		}
		if (have.texel != info.texel)
		{
			return string::tformat("the shader reads it as %s texels and the image is %s, which holds %s",
				texel_class_name(info.texel), have.name, texel_class_name(have.texel));
		}
		return "";
	}
	if (info.type == DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER)
	{
		if (image.storage == FORMAT_UNDEFINED) return "";
		StorageImageFormat have = image.storage_format();
		if (!have.is_float() || !gpu.can_sample(have.vk))
		{
			return string::tformat("the shader samples it, and a %s image cannot be sampled - bind it as an image2d<%s>",
				have.name, have.name);
		}
		return "";
	}
	return "it is an image, and the shader declares a buffer here";
}
