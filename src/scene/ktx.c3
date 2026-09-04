<*
 KTX2 decode, for `KHR_texture_basisu` and for `.ktx2` named by a script — and,
 at the end of the file, the two encoders `scene.export` writes one with.

 **Every shipped `.glb` compressing its textures loaded with them missing**
 before this file existed: `image.c3l` does PNG and JPEG, `decode_image`
 answered `UNSUPPORTED_IMAGE` for anything else, and `load_material_texture`
 turns that into a material with no picture on it. The geometry arrived, the
 shading did not, and nothing in the frame said which of the two had gone wrong.

 ## Two kinds of KTX2 and one answer

 A KTX2 file is a container, and what is inside it is either

 - **a Basis texture** — ETC1S or UASTC, `vkFormat` 0, which is what
 `KHR_texture_basisu` means and what every glTF compressor writes; or
 - **a plain one** — an ordinary Vulkan format, uncompressed or BCn, optionally
 Zstd/ZLIB supercompressed, which is what an engine-ready pipeline writes.

 They are told apart by the descriptor block rather than by the extension, since
 both arrive through the same mime type, and `ktx::basis::info` reads exactly
 that. Both end as RGBA8 in an `image::Image`, because that is the one thing
 `claim_texture` accepts and the content hash it dedupes on is over those bytes.

 ## Why the base level and not the chain

 A KTX2 can carry its own mips and this reads level 0 and throws the rest away.
 `claim_texture` asks the device to build a chain from the base anyway, so
 keeping the file's would mean a second upload path, a second set of extents to
 get wrong, and a picture that is the file's mips on one code path and the
 device's on the other. The saving is decode time on levels covering a third of
 the texels; the cost would be two definitions of what a texture is.

 The same argument settles transcoding: a Basis texture *could* go to BC7 and
 stay compressed on the device, which is most of the point of shipping one. That
 wants a `Texture` that knows it is block-compressed, a format that survives
 `create_texture`, and mip levels uploaded rather than generated — three changes
 to the GPU side. Transcoding to RGBA8 needs none of them and renders the right
 picture today; the memory it costs is the memory the same asset costs as a PNG.

 A cubemap or an array reads face 0 of layer 0, which is what a material's
 base colour map wants. Faces are what `three.sky` will ask for and it asks
 through `ktx_faces` rather than through here.
*>
module three;

import image;
import ktx::container;
import ktx::basis;
import ktx::codec;
import ktx::mipgen;


<*
 A block-compressed image on its way to the device: every level, still encoded.

 The counterpart to `image::Image` for the path that does not decode. It holds
 views into the container it came out of rather than copies, so `source` is
 owned here and `free` is not optional — dropping one leaks the whole file.
*>
struct BlockImage
{
	uint width;
	uint height;
	TextureFormat format;
	// Level 0 first. Views into `source`, not allocations of their own.
	char[][] levels;
	container::Texture source;
	Allocator allocator;
}

fn void BlockImage.free(&self)
{
	if (self.levels.len) alloc::free(self.allocator, self.levels.ptr);
	self.source.free();
	self.levels = {};
}

<*
 KTX2's twelve-byte identifier — `«KTX 20»` wrapped in the same escape bytes
 PNG uses, and for the same reason: a file mangled by a text-mode transfer stops
 matching. Fixed, at offset zero, so recognising one costs twelve comparisons.
*>
const char[12] KTX2_IDENTIFIER = {
	0xAB, 'K', 'T', 'X', ' ', '2', '0', 0xBB, '\r', '\n', 0x1A, '\n'
};

<*
 Are these bytes a KTX2 file?

 By the identifier, not by the name — `decode_by_signature`'s argument, and the
 reason a `.png` holding a KTX2 is decoded rather than reported as corrupt.
*>
fn bool is_ktx2(char[] encoded)
{
	if (encoded.len < KTX2_IDENTIFIER.len) return false;
	foreach (i, byte : KTX2_IDENTIFIER)
	{
		if (encoded[i] != byte) return false;
	}
	return true;
}

<*
 Which of the two kinds of KTX2 these bytes are.

 The file header's distinction, asked as a question. It matters outside the
 decoder because the two answer to different glTF extensions —
 `KHR_texture_basisu` for a Basis one, `CUSTOM_texture_ktx2` for a plain one —
 and the mime type cannot tell them apart. A `.glb` that declares the wrong one
 is worse than one that declares neither: a reader acts on it.

 `basis::info` reads the descriptor block and fails for anything that is not
 ETC1S or UASTC, which is exactly the test.

 @param encoded : `The whole file. False for bytes that are not a KTX2 at all.`
*>
fn bool is_basis_ktx2(char[] encoded)
{
	if (!is_ktx2(encoded)) return false;
	if (catch basis::info(encoded)) return false;
	return true;
}

<*
 A KTX2 blob to an 8-bit RGBA image, whichever of the two kinds it is.

 The image owns its pixels and the caller frees it, exactly like a `png::` or
 `jpeg::` decode — which is what lets `decode_image` return one of these three
 from one switch and its callers stay as they were.

 @param encoded : `The whole file. Not modified, and not retained.`
 @return ? UNSUPPORTED_IMAGE : `Not a KTX2, or a format inside it this cannot narrow to RGBA8.`
*>
fn image::Image? decode_ktx2(char[] encoded, Allocator allocator = mem)
{
	if (!is_ktx2(encoded)) return UNSUPPORTED_IMAGE~;

	// Asked first, because a Basis texture states `vkFormat` 0 and would fail
	// every format question the container path asks. `info` fails for anything
	// that is not one, which is the plain path's cue rather than an error.
	basis::Info? basis_info = basis::info(encoded);
	if (try basis_info) return decode_ktx2_basis(encoded, basis_info, allocator);
	return decode_ktx2_plain(encoded, allocator);
}

<*
 ETC1S or UASTC to RGBA8, through the transcoder.

 `TF_RGBA32` rather than a BC target for the reason in the file header: a
 block-compressed result has nowhere to go on this side yet.
*>
fn image::Image? decode_ktx2_basis(char[] encoded, basis::Info info, Allocator allocator) @local
{
	basis::Transcoded? out = basis::transcode(allocator, encoded, 0, 0, 0, basis::TF_RGBA32, 4);
	if (catch out) return UNSUPPORTED_IMAGE~;
	return {
		.width = out.width,
		.height = out.height,
		.bit_depth = 8,
		.format = image::PixelFormat.RGBA,
		.pixels = out.data,
		.allocator = allocator,
	};
}

<*
 An ordinary Vulkan format to RGBA8.

 `container::read` undoes the supercompression and hands back inflated levels;
 `codec::decode_image` is where BCn stops being blocks and a 16-bit or float
 format is narrowed. Both of those are the library's problem, and the only one
 left here is picking the image out of a level that may hold six faces and any
 number of layers.
*>
fn image::Image? decode_ktx2_plain(char[] encoded, Allocator allocator) @local
{
	container::Texture? maybe = container::read(allocator, encoded);
	if (catch maybe) return UNSUPPORTED_IMAGE~;
	container::Texture tex = maybe;
	defer tex.free();

	// A cube or an array packs every face of every layer into one level, so the
	// base image is the first `image_size` bytes of level 0 — which `image` is
	// the accessor for, and it is the same call for the plain 2D case.
	char[]? face = tex.image(0, 0, 0);
	if (catch face) return UNSUPPORTED_IMAGE~;

	uint width   = tex.level_width(0);
	uint height  = tex.level_height(0);
	char[]? rgba = codec::decode_image(allocator, tex.vk_format, face, width, height);
	if (catch rgba) return UNSUPPORTED_IMAGE~;

	return {
		.width = width,
		.height = height,
		.bit_depth = 8,
		.format = image::PixelFormat.RGBA,
		.pixels = rgba,
		.allocator = allocator,
	};
}

<*
 A KTX2's blocks, kept rather than narrowed — every level, in the file's format.

 The fast path this whole section exists for. `decode_ktx2` above expands blocks
 to RGBA8, which costs four times the memory and, by measurement, 86% of what
 a texture takes to load. Here nothing is decoded at
 all: `container::read` undoes the supercompression and the blocks go to the
 device as they are.

 The levels are views into the container, which is why `BlockImage` owns it. The
 alternative is copying several megabytes out so the container can be freed
 early, which would be paying a memcpy to avoid a lifetime.

 @param space : `What the caller wants these bytes read as. The file supplies only the family.`
 @return ? UNSUPPORTED_IMAGE : `Not a KTX2, a Basis one, or a format with no block family here.`
*>
fn BlockImage? decode_ktx2_blocks(char[] encoded, ColorSpace space, Allocator allocator = mem)
{
	if (!is_ktx2(encoded)) return UNSUPPORTED_IMAGE~;

	// A Basis file states `vkFormat` 0 and its payload is ETC1S or UASTC, which
	// is not a family any device samples. Turning one into BC7 means decoding it
	// and re-encoding on the CPU — a build step, not a load — so it goes the
	// RGBA8 way.
	if (try basis::info(encoded)) return UNSUPPORTED_IMAGE~;

	container::Texture? maybe = container::read(allocator, encoded);
	if (catch maybe) return UNSUPPORTED_IMAGE~;
	container::Texture tex = maybe;

	TextureFamily? family = block_family_of(tex.vk_format);
	if (catch family)
	{
		// Uncompressed, 16-bit, float — real KTX2 contents this cannot pass
		// through, and the RGBA8 path narrows all of them.
		tex.free();
		return UNSUPPORTED_IMAGE~;
	}

	uint count = tex.level_count();
	if (count == 0 || count > MAX_UPLOAD_LEVELS)
	{
		tex.free();
		return UNSUPPORTED_IMAGE~;
	}

	char[][] levels = alloc::new_array(allocator, char[], count);
	for (uint i = 0; i < count; i++)
	{
		char[]? face = tex.image(i, 0, 0);
		if (catch face)
		{
			alloc::free(allocator, levels.ptr);
			tex.free();
			return UNSUPPORTED_IMAGE~;
		}
		levels[i] = face;
	}

	return {
		.width = tex.level_width(0),
		.height = tex.level_height(0),
		.format = { family, space },
		.levels = levels,
		.source = tex,
		.allocator = allocator,
	};
}

<*
 Which block family a Vulkan format number is, if it is one this can upload.

 `ktx::vk`'s constants are numerically the Vulkan ones — 131 to 146 across the BC
 range — so the file's `vkFormat` is compared directly rather than translated.

 The sRGB and UNORM members of a pair map to the same family on purpose. Their
 blocks are bit-identical and the difference is only how a sample is decoded, so
 the space is the caller's to choose exactly as it is for a PNG: a file is not
 entitled to insist a normal map be read as colour.
*>
fn TextureFamily? block_family_of(uint vk_format) @local
{
	switch (vk_format)
	{
		case 131:
		case 132:
			return TextureFamily.BC1;
		case 137:
		case 138:
			return TextureFamily.BC3;
		case 141:
			return TextureFamily.BC5;
		case 145:
		case 146:
			return TextureFamily.BC7;
		default:
			return UNSUPPORTED_IMAGE~;
	}
}

<*
 RGBA8 pixels to a BC7 KTX2 with a full mip chain — the write side of §23.

 The exporter's, not the loader's. `decode_ktx2_blocks` reads these files and
 this writes them, and until it existed a game's textures became `.ktx2` only by
 somebody running `ktx create` by hand.

 ## This is expensive and is meant to be

 BC7 encoding searches partition and endpoint combinations per block. It already
 fans out across cores inside `bc7::encode`, and one 2048x2048 still costs around
 27 seconds of wall time here. That is the correct price for a build step and an
 impossible one for anything on a frame's path, which is why it lives behind an
 export option and why nothing should ever do it at load.

 ## The chain is generated here rather than on the device

 `mipgen::next_level` is a proper box filter over the *decoded* pixels, done
 before each level is encoded — so the file gets a chain built from full-precision
 source rather than from the level above it after a lossy round trip. That is
 strictly better than the device's blit chain, and it is the reason a KTX2's own
 levels are worth keeping when it is read back.

 `srgb` is handed to the filter as well as chosen as the format: averaging sRGB
 values as though they were linear darkens every level, and it is the mistake
 that reads as a texture dimming with distance.

 @param decoded : `8-bit pixels. Narrowed to RGBA here, so RGB sources are fine.`
 @param space : `SRGB for a colour map, LINEAR for one whose channels are numbers.`
 @return `The whole .ktx2 file, Zstd supercompressed, owned by the caller.`
*>
fn char[]? encode_ktx2_bc7(
	image::Image* decoded,
	ColorSpace space = ColorSpace.SRGB,
	Allocator allocator = mem
) => @pool()
{
	bool srgb   = space == ColorSpace.SRGB;
	uint format = srgb ? 146u : 145u;
	uint w      = decoded.width;
	uint h      = decoded.height;
	if (w == 0 || h == 0) return UNSUPPORTED_IMAGE~;

	uint levels = mipgen::chain_length(w, h);

	container::Texture tex = container::create(tmem, {
		.vk_format = format,
		.width = w,
		.height = h,
		.face_count = 1,
		.layer_count = 0,
		.level_count = levels,
	})!;

	mipgen::Options options = { .srgb = srgb, .renormalize = false };

	// `to_rgba` rather than `pixels`, because an RGB source is three bytes a
	// texel and the encoder wants four.
	char[] rgba = decoded.to_rgba();
	defer free(rgba);

	uint lw = w;
	uint lh = h;
	char[] level = rgba;
	for (uint l = 0; l < levels; l++)
	{
		if (l > 0)
		{
			level = mipgen::next_level(tmem, level, lw, lh, options);
			lw = lw > 1 ? lw >> 1 : 1;
			lh = lh > 1 ? lh >> 1 : 1;
		}
		// No alpha flag: `codec::encode_image` reads the level's own alpha and
		// hands it to `bc7::encode`, which is a better answer than one taken off
		// the base level — a chain can filter down to opaque.
		char[] blocks = codec::encode_image(tmem, format, level, lw, lh)!;
		tex.set_image(l, 0, 0, blocks)!;
	}

	// Zstd for the same reason the fixtures use it: it is what an engine-ready
	// file looks like, and `container::read` inflates it on the way back in.
	return container::write(allocator, &tex, { .scheme = container::Scheme.ZSTD, .zstd_level = 3 });
}

<*
 RGBA8 pixels to an ETC1S KTX2 with a full mip chain — the portable half of §24.

 `encode_ktx2_bc7`'s sibling and its opposite trade. BC7 is what *this* engine
 wants: `decode_ktx2_blocks` uploads those blocks untouched, which is the whole
 saving. Nothing else reads them — `CUSTOM_texture_ktx2` is our own name, so a
 Blender importer or another engine handed one of those files declines it.

 ETC1S is the one a stranger can read. It is `KHR_texture_basisu`, which every
 glTF toolchain implements, and it is *supercompressed*: a BasisLZ payload a
 fifth the size of the equivalent BC7. What it costs is quality — it is visibly
 lossy where BC7 is nearly not — and load time here, since this engine has no
 GPU-side transcode and takes the RGBA8 path back in. So it is for a file leaving
 the engine, and PNG stays the default for one coming back.
 
 The mip chain is basis_universal's rather than this file's: `mipmaps` makes the
 encoder build one internally, from full-precision source, per level, before
 quantising. Running `mipgen` first and handing the levels over as separate
 images would make them array layers instead — six pictures rather than one
 picture at six sizes.

 @param decoded : `8-bit pixels. Narrowed to RGBA here, so RGB sources are fine.`
 @param space : `SRGB for a colour map, LINEAR for one whose channels are numbers.`
 @return `The whole .ktx2 file, BasisLZ supercompressed, owned by the caller.`
*>
fn char[]? encode_ktx2_basis(
	image::Image* decoded,
	ColorSpace space = ColorSpace.SRGB,
	Allocator allocator = mem
) => @pool()
{
	uint w = decoded.width;
	uint h = decoded.height;
	if (w == 0 || h == 0) return UNSUPPORTED_IMAGE~;

	char[] rgba = decoded.to_rgba();
	defer free(rgba);

	char[][1] one = { rgba };
	// The CLI's own numbers — `ktx create -f etc1s` — so a file written here and
	// one written by hand are the same file.
	basis::EncodeOptions options = { .quality = 90, .effort = 2, .srgb = space == ColorSpace.SRGB, .mipmaps = true };
	return basis::encode(allocator, basis::ETC1S, one[..], w, h, basis::TexType.D2, options);
}
