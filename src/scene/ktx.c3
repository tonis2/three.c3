<*
 KTX2 decode, for `KHR_texture_basisu` and for `.ktx2` named by a script.

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
import ktx::dfd;

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