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

 Transcoding took the other road once those three changes to the GPU side
 existed. `transcode_ktx2_blocks` puts a Basis texture on the device as BC7 with
 the file's own chain — a quarter of the RGBA8 the same file used to cost — and
 `decode_ktx2_basis` below is what a device without BC7 still gets.

 A cubemap or an array reads face 0 of layer 0, which is what a material's
 base colour map wants. Faces are what `three.sky` will ask for and it asks
 through `ktx_faces` rather than through here.
*>
module three;

import image;
import ktx::container;
import ktx::basis;
import ktx::bc7;
import ktx::codec;
import ktx::mipgen;
import std::time;


<*
 A block-compressed image on its way to the device: every level, still encoded.

 The counterpart to `image::Image` for the path that does not decode. A file
 that already holds blocks lends them: the levels are views into the container
 it came out of, so `source` is owned here and `free` is not optional — dropping
 one leaks the whole file. A Basis file has none to lend and its levels are
 encoded here, one allocation each, which is what `owns_levels` says.
*>
struct BlockImage
{
	uint width;
	uint height;
	TextureFormat format;
	// Level 0 first. Views into `source` unless `owns_levels`.
	char[][] levels;
	// True when each level is its own allocation and `source` is empty — the
	// transcoded path. One flag rather than two structs, because everything
	// downstream of here reads the levels and cares about nothing else.
	bool owns_levels;
	container::Texture source;
	Allocator allocator;
}

fn void BlockImage.free(&self)
{
	if (self.owns_levels)
	{
		foreach (level : self.levels)
		{
			if (level.len) alloc::free(self.allocator, level.ptr);
		}
	}
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
 How much work a Basis image is, near enough to order a queue by.

 Texels rather than bytes, because the transcode's cost is per block and a mip
 chain adds a fixed third to it. One number, and it is enough: a file whose
 images are sixty 1024x1024s and one 4096x4096 is one image that costs sixteen
 times the rest, and a pool that starts that one last waits for it alone.

 Zero for anything that is not a Basis KTX2.
*>
fn ulong basis_image_cost(char[] encoded)
{
	basis::Info? info = basis::info(encoded);
	if (catch info) return 0;
	return (ulong)info.width * info.height;
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
	// is not a family any device samples. It has no blocks to lend;
	// `transcode_ktx2_blocks` is its door.
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
 A Basis KTX2 to BC7 blocks — every level the file carries, none of them decoded
 to RGBA8 on the way to the device.

 `decode_ktx2_blocks`'s twin for the half of KTX2 that has no blocks to lend.
 ETC1S and UASTC are transport formats: no device samples either, so a
 `KHR_texture_basisu` image has to become *something* on this side, and until
 this existed that something was RGBA8 — four bytes a texel and a generated mip
 chain, which is how `evil_forest.glb`'s 17.7 MB of images became 373 MiB of
 device memory. BC7 is one byte a texel and the file's own chain, which is a
 quarter of it.

 ## Why BC7 and nothing else

 One byte a texel for colour and for data alike, alpha carried, and near enough
 to lossless over an ETC1S source that the picture does not move. BC5 for a
 normal map and BC4 for a single-channel mask would be half that again, and both
 are refused here for the same reason: they drop channels the shader reads. A
 BC5 normal has no z and a BC4 mask has only red, so either would need the
 sampling side to reconstruct what the format threw away — a shader change, and
 a wrong picture until it lands. `space` still crosses, because `BC7_SRGB` and
 `BC7_UNORM` are the same blocks read two ways and picking the wrong one shifts
 every colour.

 ## What it costs: a block rewrite, not an encode

 `ktx.c3l` maps blocks now. Each of UASTC's nineteen modes is a BC7 mode with
 the same partition, endpoints and weights, and an ETC1S block is a base colour,
 an intensity table and sixteen 2-bit selectors — BC7 mode 6's shape once the
 four levels are placed on its weights. So a block is an unpack and a repack, no
 pixel in between and no search at all, running per block row across every core.
 `evil_forest.glb`'s 61 images went from a 31.7 s load to 4.5 s, and the UASTC
 export of the same scene from 33.1 s to 2.1 s. What is left is the slice
 decode, not the mapping: an ETC1S slice is one Huffman bitstream with
 cross-block prediction and has nothing to split, and it is 21 ms of the 39 ms a
 1024x1024 image with eleven levels costs. `--debug` prints that per image.

 One call for the whole chain rather than `basis::transcode` per level, because
 the shared part of a file — a UASTC container's Zstd stream, an ETC1S file's
 codebooks — is read once that way and once per level the other, which on an
 eleven-level image is about as much work again as the mapping.

 ## A file with no chain still gets one

 The levels are the file's wherever the file has any — every image in
 `evil_forest.glb` carries a full eleven or thirteen. A Basis file written
 without mips is the one case where they cannot be, and it does not get to lose
 them here: the RGBA8 path this replaces had the device blit a chain, so one is
 built from the transcoded base instead. `mipgen` filters at full precision and
 in the right space, which is a better chain than the blit was.

 This is the one path that still encodes, and it has to: a filtered level is
 pixels and has no blocks to rewrite. `fast` is what keeps it affordable — it
 stops after mode 6 instead of also searching mode 1's sixty-four partitions,
 250ms against 1813ms on a 1024x1024 image for 52.8dB against 57.2dB, both far
 above where a difference is visible because the source was quantised before
 these bytes existed. `encode_ktx2_bc7` below encodes full-precision pixels and
 still asks for the whole search.

 ## One image at a time, or several at once

 A file with sixty-one of these spends its load running this function sixty-one
 times, and the mapping inside it is already across every core — so the cores
 are busy for the mapping and idle for the slice decode that precedes it, which
 on ETC1S is the larger half. `Assets.load`'s pre-pass runs whole *images*
 concurrently instead, and `threads` is what stops each of them then asking for
 the whole machine again; `pretranscode_basis_images` argues the split it picks.
 `quiet` goes with it: the per-image line is printed by the caller after the
 join rather than by sixteen threads into one stream.

 @param format : `The target. BC7 in the caller's space; nothing else is encoded here.`
 @param threads : `The block mapper's thread count. 0 decides from the core count; 1 pins it to this thread.`
 @param quiet : `True to leave the --debug line to a caller that is timing this itself.`
 @return ? UNSUPPORTED_IMAGE : `Not a Basis KTX2, an unencodable target, or a level that would not transcode.`
*>
fn BlockImage? transcode_ktx2_blocks(
	char[] encoded,
	TextureFormat format,
	Allocator allocator = mem,
	uint threads = 0,
	bool quiet = false
)
{
	if (format.family != TextureFamily.BC7) return UNSUPPORTED_IMAGE~;

	basis::Info? maybe = basis::info(encoded);
	if (catch maybe) return UNSUPPORTED_IMAGE~;
	basis::Info info = maybe;

	if (info.width == 0 || info.height == 0) return UNSUPPORTED_IMAGE~;
	if (info.levels == 0 || info.levels > MAX_UPLOAD_LEVELS) return UNSUPPORTED_IMAGE~;

	bool generated = info.levels == 1 && (info.width > 1 || info.height > 1);
	uint count = generated ? mipgen::chain_length(info.width, info.height) : info.levels;
	if (count > MAX_UPLOAD_LEVELS) return UNSUPPORTED_IMAGE~;

	Clock started = clock::now();

	BlockImage out = {
		.width = info.width,
		.height = info.height,
		.format = format,
		.levels = alloc::new_array(allocator, char[], count),
		.owns_levels = true,
		.allocator = allocator,
	};
	// Every level allocated so far goes back on any failure below, which is what
	// makes a half-transcoded image cost nothing rather than leak the levels that
	// did succeed.
	bool ok = false;
	defer if (!ok) out.free();

	if (!generated)
	{
		// Face 0 of layer 0, exactly as `decode_ktx2_plain` picks its image: a
		// material's map is one picture, and a cube is `ktx_faces`' business.
		basis::Transcoded[]? mapped = basis::transcode_levels(allocator, encoded, 0, 0, basis::TF_BC7_RGBA, threads);
		if (catch mapped) return UNSUPPORTED_IMAGE~;
		// The blocks are already the caller's allocation; only the array that
		// listed them is this function's to give back.
		for (uint level = 0; level < count; level++) out.levels[level] = mapped[level].data;
		alloc::free(allocator, mapped.ptr);

		ok = true;
		if (!quiet)
		{
			@debug_log("basis: %dx%d, %d levels mapped to BC7 in %d ms",
				info.width, info.height, count, (long)started.to_now() / 1_000_000);
		}
		return out;
	}

	mipgen::Options options = { .srgb = format.space == ColorSpace.SRGB, .renormalize = false };
	// The level being encoded, as pixels. Carried across iterations, because each
	// level is filtered from the one above it.
	char[] pixels;
	defer if (pixels.len) alloc::free(allocator, pixels.ptr);
	uint lw;
	uint lh;

	for (uint level = 0; level < count; level++)
	{
		if (level > 0)
		{
			char[] next = mipgen::next_level(allocator, pixels, lw, lh, options);
			alloc::free(allocator, pixels.ptr);
			pixels = next;
			lw = lw > 1 ? lw >> 1 : 1;
			lh = lh > 1 ? lh >> 1 : 1;
		}
		else
		{
			basis::Transcoded? rgba = basis::transcode(allocator, encoded, 0, 0, 0, basis::TF_RGBA32, 4);
			if (catch rgba) return UNSUPPORTED_IMAGE~;
			pixels = rgba.data;
			lw = rgba.width;
			lh = rgba.height;
		}

		char[]? blocks = bc7::encode(allocator, pixels, lw, lh, true, threads, true);
		if (catch blocks) return UNSUPPORTED_IMAGE~;
		out.levels[level] = blocks;
	}

	ok = true;
	if (!quiet)
	{
		@debug_log("basis: %dx%d, %d levels encoded to BC7 in %d ms (the file shipped no chain)",
			info.width, info.height, count, (long)started.to_now() / 1_000_000);
	}
	return out;
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
