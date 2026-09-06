<*
 KTX2 decode — `src/scene/ktx.c3`.

	`c3c test --trust=full --test-noleak --test-filter three_tests::ktx`

 **The failure this exists to prevent is silent.** A `.glb` whose textures are
 KTX2 loaded with every material untextured, one line on stdout, and geometry
 that draws perfectly — so the only way to notice was to already know what the
 asset was supposed to look like. Nothing here asserts on a message; every check
 ends at pixels, either the decoded ones or the texture slot they landed in.

 **Nothing here is a checked-in blob.** The KTX2 files are encoded by `ktx.c3l`
 in the test that reads them, which costs a few milliseconds and buys two
 things: the fixture says what it contains in code rather than in a comment
 beside a binary, and the encoder and the decoder are separate halves of the
 library, so a round trip is a real check rather than a tautology.

 The .glb is assembled here for the same reason and for one more: `gltf.c3l`'s
 writer deliberately emits no `KHR_texture_basisu`, so there is nothing in this
 repo that could have produced the file the loader has to read.
*>
module three_tests::ktx;

import three;
import three_tests::device;
import vk;
import image;
import gltf;
import ktx::container;
import ktx::basis;
import ktx::bc7;
import ktx::codec;
import std::core::test;
import std::io::file;
import std::math;
import std::collections::list;

const uint W = 120;
const uint H = 90;

// Small enough to encode in milliseconds, and a multiple of four so no codec
// here has to pad a partial block.
const uint SIZE = 8;

// Named through `ktx::codec` rather than imported from `ktx::vk`, because this
// file already imports the Vulkan bindings and both modules are called `vk`.
// The alias table is the library's own spelling of these two, so a renumbering
// cannot leave the wrong constant here.
fn uint format(String alias_name) => codec::parse_format(alias_name)!!;

macro @with_pass(; @body(three::Renderer* renderer))
{
	three::Renderer* renderer = device::borrow(W, H);
	defer device::release();

	@body(renderer);
}

<*
 A SIZE x SIZE picture that survives being described.

 Four flat quadrants rather than a gradient or noise: every lossy codec here is
 allowed to move a texel a little, and none of them is allowed to put a red one
 where a blue one was. A per-texel tolerance against a flat block says that in
 one comparison; against a gradient it would say it about the interpolation as
 well, which is not what is being checked.
*>
fn char[] quadrants()
{
	char[] rgba = mem::new_array(char, (sz)SIZE * SIZE * 4);
	for (uint y = 0; y < SIZE; y++)
	{
		for (uint x = 0; x < SIZE; x++)
		{
			sz at = ((sz)y * SIZE + x) * 4;
			bool right = x >= SIZE / 2;
			bool low = y >= SIZE / 2;
			rgba[at + 0] = (char)(right ? 0xf0 : 0x10);
			rgba[at + 1] = (char)(low ? 0xf0 : 0x10);
			rgba[at + 2] = (char)(right == low ? 0xf0 : 0x10);
			rgba[at + 3] = (char)0xff;
		}
	}
	return rgba;
}

<*
 The largest per-channel distance between two RGBA8 images of the same size.

 Reported as one number because that is what a tolerance is stated in, and
 because the interesting failure is one channel being wildly wrong rather than
 all of them being slightly wrong.
*>
fn uint worst_channel(char[] a, char[] b)
{
	if (a.len != b.len) return 255;
	uint worst = 0;
	foreach (i, byte : a)
	{
		uint d = (uint)math::abs((int)byte - (int)b[i]);
		if (d > worst) worst = d;
	}
	return worst;
}

// ============================================================================
// The two kinds of KTX2
// ============================================================================

<*
 UASTC — the `KHR_texture_basisu` half, and the one a modern compressor writes.

 `vkFormat` is 0 in one of these, so every question the plain container path
 asks about the format has no answer. Getting it to the transcoder instead is
 the whole of what `decode_ktx2` decides, and this is the check that it decides
 it correctly rather than falling through to the branch that cannot work.
*>
fn void a_uastc_texture_decodes() @test
{
	char[] source = quadrants();
	defer free(source);

	char[][1] images = { source };
	char[] blob = basis::encode(
		mem, basis::UASTC_4X4, images[..], SIZE, SIZE, basis::TexType.D2,
		{ .quality = 90, .effort = 2, .srgb = true, .mipmaps = false }
	)!!;
	defer free(blob);

	test::@check(three::is_ktx2(blob), "the encoder wrote a KTX2");

	image::Image decoded = three::decode_ktx2(blob)!!;
	defer decoded.free();

	test::@check(decoded.width == SIZE && decoded.height == SIZE,
		"decoded %dx%d, expected %dx%d", decoded.width, decoded.height, SIZE, SIZE);
	test::@check(decoded.format == image::PixelFormat.RGBA, "decoded to RGBA");
	test::@check(decoded.bit_depth == 8, "decoded to 8 bits a channel");

	// UASTC at four flat quadrants is very nearly lossless; the tolerance is
	// wide enough that a quantiser change cannot fail it and narrow enough that
	// a swapped channel or a transposed block cannot pass it.
	uint worst = worst_channel(source, decoded.pixels);
	test::@check(worst <= 8, "the picture came back, worst channel off by %d", worst);
}

<*
 ETC1S — the other Basis codec, and the one whose files are half the size.

 Separate from UASTC because they share a container and nothing else: the
 transcoder reaches them through different code, and a decoder that dispatched
 on the container alone would get one of the two wrong.
*>
fn void an_etc1s_texture_decodes() @test
{
	char[] source = quadrants();
	defer free(source);

	char[][1] images = { source };
	char[] blob = basis::encode(
		mem, basis::ETC1S, images[..], SIZE, SIZE, basis::TexType.D2,
		{ .quality = 90, .effort = 2, .srgb = true, .mipmaps = false }
	)!!;
	defer free(blob);

	image::Image decoded = three::decode_ktx2(blob)!!;
	defer decoded.free();

	test::@check(decoded.width == SIZE && decoded.height == SIZE,
		"decoded %dx%d", decoded.width, decoded.height);

	// ETC1S quantises to a shared codebook, so the tolerance is a codec's
	// worth rather than a rounding's. It still cannot put the wrong hue in a
	// quadrant, which is what the quadrants are for.
	uint worst = worst_channel(source, decoded.pixels);
	test::@check(worst <= 40, "the picture came back, worst channel off by %d", worst);
}

<*
 A plain uncompressed KTX2 — no Basis anywhere in it — is exact.

 This is the half a build pipeline writes rather than the half a glTF exporter
 does, and it goes through the container reader instead of the transcoder. It
 is also the only case here where the answer can be checked byte for byte, so
 it is where a channel order or a row stride would be caught.
*>
fn void a_plain_texture_decodes_exactly() @test
{
	char[] source = quadrants();
	defer free(source);

	container::Texture tex = container::create(mem, {
		.vk_format = format("rgba8-srgb"), .width = SIZE, .height = SIZE
	})!!;
	defer tex.free();
	tex.set_image(0, 0, 0, source)!!;

	char[] blob = container::write(mem, &tex)!!;
	defer free(blob);

	image::Image decoded = three::decode_ktx2(blob)!!;
	defer decoded.free();

	test::@check(decoded.width == SIZE && decoded.height == SIZE,
		"decoded %dx%d", decoded.width, decoded.height);
	test::@check(worst_channel(source, decoded.pixels) == 0,
		"an uncompressed texture round-trips byte for byte");
}

<*
 Zstd supercompression is undone before the pixels are read.

 Same texture as above through the same reader, so a difference between the two
 is the inflation and nothing else — which is the point: the level payload is
 the only thing that changed, and it has to arrive the same size it left.
*>
fn void a_supercompressed_texture_is_inflated() @test
{
	char[] source = quadrants();
	defer free(source);

	container::Texture tex = container::create(mem, {
		.vk_format = format("rgba8-srgb"), .width = SIZE, .height = SIZE
	})!!;
	defer tex.free();
	tex.set_image(0, 0, 0, source)!!;

	char[] blob = container::write(mem, &tex, { .scheme = container::Scheme.ZSTD })!!;
	defer free(blob);

	image::Image decoded = three::decode_ktx2(blob)!!;
	defer decoded.free();

	test::@check(worst_channel(source, decoded.pixels) == 0,
		"a Zstd-supercompressed texture round-trips byte for byte");
}

<*
 A block-compressed format still narrows to RGBA8 when it is asked to.

 This was once the only thing that could happen to a BC7 payload, because
 `create_texture` took RGBA8 and nothing else. It is now the *fallback*: a device
 that cannot sample BC7, a Basis file, or a caller that asked for no mip chain
 all end up here, and the picture they get is the right one.

 `decode_ktx2` is the function that narrows and `decode_ktx2_blocks` is the one
 that does not, so which of them is called is the whole difference — asserted
 both ways below, against one blob, so the boundary between the two paths cannot
 quietly move.
*>
fn void a_block_compressed_texture_decodes() @test
{
	char[] source = quadrants();
	defer free(source);

	char[] blocks = codec::encode_image(mem, format("bc7-srgb"), source, SIZE, SIZE)!!;
	defer free(blocks);

	container::Texture tex = container::create(mem, {
		.vk_format = format("bc7-srgb"), .width = SIZE, .height = SIZE
	})!!;
	defer tex.free();
	tex.set_image(0, 0, 0, blocks)!!;

	char[] blob = container::write(mem, &tex)!!;
	defer free(blob);

	image::Image decoded = three::decode_ktx2(blob)!!;
	defer decoded.free();

	test::@check(decoded.width == SIZE && decoded.height == SIZE,
		"decoded %dx%d", decoded.width, decoded.height);
	uint worst = worst_channel(source, decoded.pixels);
	test::@check(worst <= 16, "the picture came back, worst channel off by %d", worst);

	// The same bytes down the other path: blocks, in the family the file names,
	// and no decode at all.
	three::BlockImage kept = three::decode_ktx2_blocks(blob, three::ColorSpace.SRGB)!!;
	defer kept.free();

	test::@check(kept.format.family == three::TextureFamily.BC7,
		"the blocks path did not report BC7");
	test::@check(kept.width == SIZE && kept.height == SIZE,
		"the blocks path reports %dx%d", kept.width, kept.height);
	test::@check(kept.levels.len == 1, "a one-level file gave %d levels", (int)kept.levels.len);
	test::@check(kept.levels[0].len == blocks.len,
		"level 0 is %d bytes of blocks, not the %d that were encoded",
		(int)kept.levels[0].len, (int)blocks.len);
}

<*
 A Basis file has no blocks to lend, so its levels are made — every one of them,
 and they hold the picture.

 `decode_ktx2_blocks` above refuses a Basis file and `transcode_ktx2_blocks` is
 the door it refuses it towards, so what is asserted is that the door leads
 somewhere: the file's whole chain, in BC7, decoding back to what the RGBA8 path
 next door would have handed over.

 The tolerance is against **the transcoder's own RGBA8 output** rather than
 against `source`. ETC1S has already quantised these texels and the BC7 encode
 is the only step this function owns; comparing against the original would be
 measuring both, and a regression in the half that is here would hide inside the
 half that is not.
*>
fn void a_basis_texture_becomes_blocks() @test
{
	const uint SIDE = 32;

	char[] source = mem::new_array(char, (sz)SIDE * SIDE * 4);
	defer free(source);
	for (uint y = 0; y < SIDE; y++)
	{
		for (uint x = 0; x < SIDE; x++)
		{
			sz at = ((sz)y * SIDE + x) * 4;
			bool right = x >= SIDE / 2;
			bool low = y >= SIDE / 2;
			source[at + 0] = (char)(right ? 0xf0 : 0x10);
			source[at + 1] = (char)(low ? 0xf0 : 0x10);
			source[at + 2] = (char)(right == low ? 0xf0 : 0x10);
			source[at + 3] = (char)0xff;
		}
	}

	char[][1] images = { source };
	char[] blob = basis::encode(
		mem, basis::ETC1S, images[..], SIDE, SIDE, basis::TexType.D2,
		{ .quality = 90, .effort = 2, .srgb = true, .mipmaps = true }
	)!!;
	defer free(blob);

	test::@check(three::is_basis_ktx2(blob), "the encoder did not write a Basis KTX2");
	test::@check(@catch(three::decode_ktx2_blocks(blob, three::ColorSpace.SRGB)),
		"the blocks path accepted a Basis file, which has no blocks to lend");

	three::TextureFormat bc7 = { three::TextureFamily.BC7, three::ColorSpace.SRGB };
	three::BlockImage made = three::transcode_ktx2_blocks(blob, bc7)!!;
	defer made.free();

	uint chain = three::mip_levels(SIDE, SIDE);
	test::@check(made.format.equals(bc7), "the transcode did not report BC7 sRGB");
	test::@check(made.width == SIDE && made.height == SIDE,
		"the transcode reports %dx%d", made.width, made.height);
	test::@check(made.levels.len == chain,
		"the file's %d levels became %d", chain, (int)made.levels.len);

	// Every level is a whole number of blocks for its own extents, which is what
	// `create_texture_levels` checks before it copies anything.
	for (uint i = 0; i < chain; i++)
	{
		uint side = three::level_extent(SIDE, i);
		test::@check(made.levels[i].len == bc7.image_size(side, side),
			"level %d is %d bytes, not the %d a %dx%d BC7 image is",
			i, (int)made.levels[i].len, (int)bc7.image_size(side, side), side, side);
	}

	image::Image reference = three::decode_ktx2(blob)!!;
	defer reference.free();
	char[] back = bc7::decode(mem, made.levels[0], SIDE, SIDE)!!;
	defer free(back);

	uint worst = worst_channel(reference.pixels, back);
	test::@check(worst <= 8, "the blocks lost the picture, worst channel off by %d", worst);
}

<*
 UASTC becomes BC7 by being *mapped*, and the check is that no picture is lost.

 `transcode_ktx2_blocks` no longer decodes and re-encodes: `ktx::uastc_bc7`
 rewrites each UASTC block as a BC7 block, endpoints requantized and weights
 remapped, with no pixel in between. So this asserts against the transcoder's
 own RGBA8 output, which is what the mapping has to agree with — the source
 would be measuring UASTC's quantisation as well.

 A detailed source rather than flat quadrants, deliberately: flat blocks take
 UASTC's solid mode, which maps exactly, and would pass whatever the rest of
 the mapper did.
*>
fn void a_uastc_texture_becomes_blocks() @test
{
	const uint SIDE = 32;

	char[] source = mem::new_array(char, (sz)SIDE * SIDE * 4);
	defer free(source);
	for (uint y = 0; y < SIDE; y++)
	{
		for (uint x = 0; x < SIDE; x++)
		{
			sz at = ((sz)y * SIDE + x) * 4;
			source[at + 0] = (char)(x * 8 + y);
			source[at + 1] = (char)(255 - y * 7);
			source[at + 2] = (char)((x * y) & 0xff);
			source[at + 3] = (char)(x + y < SIDE ? 0xff : 0x40);
		}
	}

	char[][1] images = { source };
	char[] blob = basis::encode(
		mem, basis::UASTC_4X4, images[..], SIDE, SIDE, basis::TexType.D2,
		{ .quality = 90, .effort = 4, .srgb = true, .mipmaps = true }
	)!!;
	defer free(blob);

	three::TextureFormat bc7 = { three::TextureFamily.BC7, three::ColorSpace.SRGB };
	three::BlockImage made = three::transcode_ktx2_blocks(blob, bc7)!!;
	defer made.free();

	uint chain = three::mip_levels(SIDE, SIDE);
	test::@check(made.levels.len == chain,
		"the file's %d levels became %d", chain, (int)made.levels.len);

	// Every level, not just the base: a mapper that got a mode wrong would show
	// it on whichever level happened to use that mode.
	for (uint level = 0; level < chain; level++)
	{
		uint side = three::level_extent(SIDE, level);
		basis::Transcoded want = basis::transcode(mem, blob, level, 0, 0, basis::TF_RGBA32, 4)!!;
		defer free(want.data);
		char[] back = bc7::decode(mem, made.levels[level], side, side)!!;
		defer free(back);

		// 9 is what the mapper is allowed to be off by, and it is the library's
		// number rather than this file's: `uastc_bc7_tests::every_mode_maps`
		// measures every one of UASTC's nineteen modes over uniformly random
		// blocks and the worst is mode 18's 9, its 5-bit weight grid folded onto
		// BC7's 4-bit one. Anything tighter would be a bound this image happens
		// to meet — it measures 5 — and not one the mapper promises.
		uint worst = worst_channel(want.data, back);
		test::@check(worst <= 9,
			"level %d lost the picture, worst channel off by %d", level, worst);
	}
}

<*
 And the same file, uploaded — BC7 blocks on the device, not RGBA8.

 `claim_blocks_if_possible` is the only caller of the transcode, and what it
 decides is whether a Basis file reaches the device as blocks at all. The slot
 it returns records the format and the level count, which is where a transcode
 that quietly fell back to the decoder would show up.
*>
fn void a_basis_texture_uploads_as_blocks() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::TextureFormat bc7 = { three::TextureFamily.BC7, three::ColorSpace.SRGB };
		if (!renderer.gpu.supports(bc7)) return;   // no BC7 here; the RGBA8 path is correct

		const uint SIDE = 32;
		char[] source = mem::new_array(char, (sz)SIDE * SIDE * 4);
		defer free(source);
		for (uint i = 0; i < source.len; i += 4)
		{
			source[i] = (char)(i / 4);
			source[i + 1] = (char)(255 - i / 4);
			source[i + 2] = (char)((i / 4) * 3);
			source[i + 3] = 255;
		}

		char[][1] images = { source };
		char[] blob = basis::encode(
			mem, basis::ETC1S, images[..], SIDE, SIDE, basis::TexType.D2,
			{ .quality = 90, .effort = 2, .srgb = true, .mipmaps = true }
		)!!;
		defer free(blob);

		three::Assets* assets = &renderer.pass.assets;
		int slot = assets.claim_blocks_if_possible(&renderer.gpu, blob, three::ColorSpace.SRGB, true, false)!!;
		defer assets.release_texture(&renderer.gpu, slot);

		test::@check(assets.textures[slot].texture.format.equals(bc7),
			"the upload is not BC7 sRGB");
		test::@check(assets.textures[slot].texture.levels == three::mip_levels(SIDE, SIDE),
			"the upload has %d levels, not the file's %d",
			assets.textures[slot].texture.levels, three::mip_levels(SIDE, SIDE));
	};
}

<*
 A Basis file that shipped no chain still gets one.

 The levels are the file's wherever it has any, and this is the one case where
 it has none. The RGBA8 path this replaced had the device blit a chain from
 level 0, so a transcode handing back a single level would be trading aliasing
 in the distance for the memory — a worse picture, quietly, on exactly the files
 a small exporter writes.
*>
fn void a_chainless_basis_texture_gets_a_chain() @test
{
	const uint SIDE = 16;

	char[] source = mem::new_array(char, (sz)SIDE * SIDE * 4);
	defer free(source);
	foreach (i, &byte : source) *byte = (char)(i % 4 == 3 ? 0xff : (i * 7) & 0xff);

	char[][1] images = { source };
	char[] blob = basis::encode(
		mem, basis::UASTC_4X4, images[..], SIDE, SIDE, basis::TexType.D2,
		{ .quality = 90, .effort = 2, .srgb = true, .mipmaps = false }
	)!!;
	defer free(blob);

	test::@check(basis::info(blob)!!.levels == 1,
		"the fixture already has a chain, so this asserts nothing");

	three::TextureFormat bc7 = { three::TextureFamily.BC7, three::ColorSpace.LINEAR };
	three::BlockImage made = three::transcode_ktx2_blocks(blob, bc7)!!;
	defer made.free();

	test::@check(made.levels.len == three::mip_levels(SIDE, SIDE),
		"a one-level file gave %d levels, not the full %d",
		(int)made.levels.len, three::mip_levels(SIDE, SIDE));
	for (uint i = 0; i < made.levels.len; i++)
	{
		uint side = three::level_extent(SIDE, i);
		test::@check(made.levels[i].len == bc7.image_size(side, side),
			"generated level %d is %d bytes, not the %d a %dx%d BC7 image is",
			i, (int)made.levels[i].len, (int)bc7.image_size(side, side), side, side);
	}
}

<*
 And the base of that chain is the file's own blocks, not an encode of them.

 A chainless file used to be decoded to pixels and encoded level by level, level
 0 among them — three quarters of the blocks in a chain, through the slowest
 thing in the transcoder, to arrive at an approximation of blocks the file
 already had. `evil_forest.glb`'s sixty-one images cost 28.8 s of a 30 s load
 that way, against 1.0 s for the same images with their chains. Level 0 takes
 the mapper now and only the levels the chain invents are encoded.

 Byte equality against the mapper alone is what says so: an encode of the same
 pixels would be close and would not be equal.
*>
fn void a_generated_chain_maps_its_base() @test
{
	const uint SIDE = 64;

	char[] source = mem::new_array(char, (sz)SIDE * SIDE * 4);
	defer free(source);
	for (uint y = 0; y < SIDE; y++)
	{
		for (uint x = 0; x < SIDE; x++)
		{
			sz at = ((sz)y * SIDE + x) * 4;
			source[at + 0] = (char)(x * 4 + y);
			source[at + 1] = (char)(255 - y * 3);
			source[at + 2] = (char)((x * y) & 0xff);
			source[at + 3] = 255;
		}
	}

	char[][1] images = { source };
	char[] blob = basis::encode(
		mem, basis::ETC1S, images[..], SIDE, SIDE, basis::TexType.D2,
		{ .quality = 90, .effort = 2, .srgb = true, .mipmaps = false }
	)!!;
	defer free(blob);

	test::@check(basis::info(blob)!!.levels == 1,
		"the fixture already has a chain, so this asserts nothing");

	three::TextureFormat bc7 = { three::TextureFamily.BC7, three::ColorSpace.SRGB };
	three::BlockImage made = three::transcode_ktx2_blocks(blob, bc7)!!;
	defer made.free();

	basis::Transcoded[] mapped = basis::transcode_levels(mem, blob, 0, 0, basis::TF_BC7_RGBA, 1)!!;
	defer free(mapped.ptr);
	defer free(mapped[0].data);

	test::@check(made.levels[0] == mapped[0].data,
		"level 0 is an encode of the picture, not the file's own blocks");

	// The chain below it is still there, and at the sizes a chain has: mapping
	// the base must not have cost the levels it is the base of.
	uint chain = three::mip_levels(SIDE, SIDE);
	test::@check(made.levels.len == chain,
		"a one-level file gave %d levels, not the full %d", (int)made.levels.len, chain);
	for (uint level = 1; level < chain; level++)
	{
		uint side = three::level_extent(SIDE, level);
		test::@check(made.levels[level].len == bc7.image_size(side, side),
			"generated level %d is %d bytes, not the %d a %dx%d BC7 image is",
			level, (int)made.levels[level].len, (int)bc7.image_size(side, side), side, side);
	}
}

// ============================================================================
// Getting there
// ============================================================================

<*
 A KTX2 is recognised by its first twelve bytes, not by anything else.

 The same rule `decode_by_signature` already applied to PNG and JPEG, extended
 to the third format — so a `.ktx2` renamed `.png`, or a glTF image that
 declares no mime type at all, still decodes.
*>
fn void the_bytes_say_what_it_is() @test
{
	char[] source = quadrants();
	defer free(source);

	container::Texture tex = container::create(mem, {
		.vk_format = format("rgba8-srgb"), .width = SIZE, .height = SIZE
	})!!;
	defer tex.free();
	tex.set_image(0, 0, 0, source)!!;
	char[] blob = container::write(mem, &tex)!!;
	defer free(blob);

	char[]? png = file::load(mem, "test/fixtures/checker.png");
	test::@check(@ok(png), "the PNG fixture is readable");
	defer free(png!!);

	test::@check(!three::is_ktx2(png!!), "a PNG is not a KTX2");
	test::@check(!three::is_ktx2(blob[:4]), "a truncated header is not a KTX2");

	image::Image guessed = three::decode_by_signature(blob)!!;
	defer guessed.free();
	test::@check(worst_channel(source, guessed.pixels) == 0,
		"the signature path decoded it, not just the mime path");

	// The glTF path, which is where a real file arrives.
	image::Image by_mime = three::decode_image(gltf::ImageType.IMAGE_KTX2, blob)!!;
	defer by_mime.free();
	test::@check(worst_channel(source, by_mime.pixels) == 0, "the mime path decoded it too");
}

<*
 `three.texture("...")` on a `.ktx2` reaches the device.

 `load_texture_file` refused everything that was not a PNG or a JPEG, and it is
 the entry point a script has — so a scene that wanted a compressed lookup table
 or a compressed sky had no way to ask for one.
*>
fn void a_ktx2_file_uploads() @test
{
	String path = "build/ktx_texture.ktx2";

	char[] source = quadrants();
	defer free(source);

	container::Texture tex = container::create(mem, {
		.vk_format = format("rgba8-srgb"), .width = SIZE, .height = SIZE
	})!!;
	defer tex.free();
	tex.set_image(0, 0, 0, source)!!;
	container::write_file(&tex, path)!!;
	defer (void)file::delete(path);

	@with_pass(; three::Renderer* renderer)
	{
		three::Assets* assets = &renderer.pass.assets;
		int slot = assets.load_texture_file(&renderer.gpu, path)!!;
		test::@check(slot >= 0, "a .ktx2 loaded to slot %d", slot);
		test::@check(assets.textures[slot].texture.width == SIZE,
			"the uploaded texture is %d wide", assets.textures[slot].texture.width);

		// The one thing a decode returning the wrong picture could still pass:
		// the hash is over the decoded bytes, so the same picture written as a
		// PNG and as a KTX2 has to be one upload.
		int again = assets.load_texture_file(&renderer.gpu, path)!!;
		test::@check(again == slot, "the same file twice is one slot");
	};
}

// ============================================================================
// End to end
// ============================================================================

<*
 A minimal .glb whose one material takes its base colour from a KTX2 image.

 Assembled by hand because nothing in this repo writes one: `gltf.c3l`'s writer
 states in its own comment that it emits no `KHR_texture_basisu`, so there is no
 round trip available and the file the loader must read has to be described
 directly.

 One textured quad, indexed, with normals — the smallest thing that exercises
 the whole path from `textures[0].extensions` to a texture slot on a `GpuMesh`.
*>
fn void write_basisu_glb(String path, char[] ktx2)
{
	// Geometry: a unit quad in the XY plane, four vertices and two triangles.
	float[12] positions = {
		-1, -1, 0,   1, -1, 0,   1, 1, 0,   -1, 1, 0,
	};
	float[12] normals = {
		0, 0, 1,   0, 0, 1,   0, 0, 1,   0, 0, 1,
	};
	float[8] uvs = { 0, 1,   1, 1,   1, 0,   0, 0 };
	ushort[6] indices = { 0, 1, 2, 0, 2, 3 };

	List{char} bin;
	bin.init(mem);
	defer bin.free();

	sz pos_at = bin.len();
	bin.push_all(((char*)&positions)[:(sz)48]);
	sz nrm_at = bin.len();
	bin.push_all(((char*)&normals)[:(sz)48]);
	sz uv_at = bin.len();
	bin.push_all(((char*)&uvs)[:(sz)32]);
	sz idx_at = bin.len();
	bin.push_all(((char*)&indices)[:(sz)12]);
	while (bin.len() % 4 != 0) bin.push(0);
	sz img_at = bin.len();
	bin.push_all(ktx2);
	while (bin.len() % 4 != 0) bin.push(0);

	DString json;
	json.init(mem);
	defer json.free();
	json.appendf(`{"asset":{"version":"2.0"},`);
	json.appendf(`"extensionsUsed":["KHR_texture_basisu"],`);
	json.appendf(`"scene":0,"scenes":[{"nodes":[0]}],"nodes":[{"mesh":0}],`);
	json.appendf(`"meshes":[{"name":"quad","primitives":[{"attributes":{"POSITION":0,"NORMAL":1,"TEXCOORD_0":2},"indices":3,"material":0}]}],`);
	json.appendf(`"materials":[{"pbrMetallicRoughness":{"baseColorTexture":{"index":0}}}],`);
	json.appendf(`"textures":[{"sampler":0,"extensions":{"KHR_texture_basisu":{"source":0}}}],`);
	json.appendf(`"samplers":[{}],`);
	json.appendf(`"images":[{"mimeType":"image/ktx2","bufferView":4}],`);
	json.appendf(
		`"accessors":[`
		`{"bufferView":0,"componentType":5126,"count":4,"type":"VEC3","min":[-1,-1,0],"max":[1,1,0]},`
		`{"bufferView":1,"componentType":5126,"count":4,"type":"VEC3"},`
		`{"bufferView":2,"componentType":5126,"count":4,"type":"VEC2"},`
		`{"bufferView":3,"componentType":5123,"count":6,"type":"SCALAR"}],`
	);
	json.appendf(
		`"bufferViews":[`
		`{"buffer":0,"byteOffset":%d,"byteLength":%d},`
		`{"buffer":0,"byteOffset":%d,"byteLength":%d},`
		`{"buffer":0,"byteOffset":%d,"byteLength":%d},`
		`{"buffer":0,"byteOffset":%d,"byteLength":%d},`
		`{"buffer":0,"byteOffset":%d,"byteLength":%d}],`,
		pos_at, (sz)48, nrm_at, (sz)48, uv_at, (sz)32,
		idx_at, (sz)12, img_at, ktx2.len
	);
	json.appendf(`"buffers":[{"byteLength":%d}]}`, bin.len());
	while (json.len() % 4 != 0) json.append_char(' ');

	List{char} glb;
	glb.init(mem);
	defer glb.free();
	uint total = 12 + 8 + (uint)json.len() + 8 + (uint)bin.len();
	@append_u32(&glb, 0x46546C67);   // "glTF"
	@append_u32(&glb, 2);
	@append_u32(&glb, total);
	@append_u32(&glb, (uint)json.len());
	@append_u32(&glb, 0x4E4F534A);   // "JSON"
	glb.push_all(json.str_view());
	@append_u32(&glb, (uint)bin.len());
	@append_u32(&glb, 0x004E4942);   // "BIN\0"
	glb.push_all(bin.array_view());

	file::save(path, glb.array_view())!!;
}

macro @append_u32(List{char}* out, uint value)
{
	uint v = value;
	out.push_all(((char*)&v)[:4]);
}

<*
 The whole point of the section: a `.glb` compressing its textures arrives with
 them.

 Before this, `decode_image` answered `UNSUPPORTED_IMAGE` for `image/ktx2`,
 `load_material_texture` turned that into `-1`, and the mesh sampled the shared
 1x1 white — geometry on screen, shading gone, and one printed line as the only
 evidence. So the assertion is on the texture index, which is exactly the thing
 that used to be `-1`, and on the picture landing on the device at its real
 size, which says the bytes were read and not merely accepted.
*>
fn void a_glb_with_a_basisu_texture_arrives_shaded() @test
{
	String path = "build/ktx_basisu.glb";

	char[] source = quadrants();
	defer free(source);

	char[][1] images = { source };
	char[] blob = basis::encode(
		mem, basis::UASTC_4X4, images[..], SIZE, SIZE, basis::TexType.D2,
		{ .quality = 90, .effort = 2, .srgb = true, .mipmaps = false }
	)!!;
	defer free(blob);

	write_basisu_glb(path, blob);
	defer (void)file::delete(path);

	@with_pass(; three::Renderer* renderer)
	{
		three::Assets* assets = &renderer.pass.assets;
		three::AssetId id = assets.load(&renderer.gpu, path)!!;
		three::Asset* asset = assets.slot(id);

		test::@check(asset.meshes.len() == 1, "one mesh, got %d", asset.meshes.len());

		// `load` reads the JSON and stops; the geometry and its images reach the
		// device when something starts drawing the mesh. Asking before that
		// would read the placeholder rather than the answer.
		assets.ensure_uploaded(id, 0);

		int slot = assets.mesh(id, 0).texture;
		test::@check(slot >= 0,
			"the KTX2 base colour map reached a texture slot; -1 is the old answer");
		test::@check(assets.textures[slot].texture.width == SIZE,
			"and it is the picture, %d wide", assets.textures[slot].texture.width);
	};
}

// ============================================================================
// The load's pre-pass
// ============================================================================

<*
 A `.glb` with several KTX2 images, each on a quad of its own.

 `write_basisu_glb`'s many-image sibling, which is what the pre-pass needs to be
 asked anything at all: one image is a loop that runs once. Every image gets a
 texture, so every one is queued; `with_materials` is what decides whether
 anything ever *claims* one, which is the other half of the ownership question.

 The geometry is one quad reused by every primitive — the same four vertices and
 six indices — because nothing here is about geometry and a second copy would
 only be a second thing to get wrong.
*>
fn void write_basisu_glb_multi(String path, char[][] ktx2s, bool with_materials)
{
	float[12] positions = {
		-1, -1, 0,   1, -1, 0,   1, 1, 0,   -1, 1, 0,
	};
	float[12] normals = {
		0, 0, 1,   0, 0, 1,   0, 0, 1,   0, 0, 1,
	};
	float[8] uvs = { 0, 1,   1, 1,   1, 0,   0, 0 };
	ushort[6] indices = { 0, 1, 2, 0, 2, 3 };

	List{char} bin;
	bin.init(mem);
	defer bin.free();

	List{sz} image_at;
	List{sz} image_len;
	image_at.init(mem);
	image_len.init(mem);
	defer image_at.free();
	defer image_len.free();

	sz pos_at = bin.len();
	bin.push_all(((char*)&positions)[:(sz)48]);
	sz nrm_at = bin.len();
	bin.push_all(((char*)&normals)[:(sz)48]);
	sz uv_at = bin.len();
	bin.push_all(((char*)&uvs)[:(sz)32]);
	sz idx_at = bin.len();
	bin.push_all(((char*)&indices)[:(sz)12]);
	foreach (ktx2 : ktx2s)
	{
		while (bin.len() % 4 != 0) bin.push(0);
		image_at.push(bin.len());
		image_len.push(ktx2.len);
		bin.push_all(ktx2);
	}
	while (bin.len() % 4 != 0) bin.push(0);

	DString json;
	json.init(mem);
	defer json.free();
	json.appendf(`{"asset":{"version":"2.0"},`);
	json.appendf(`"extensionsUsed":["KHR_texture_basisu"],`);
	json.appendf(`"scene":0,"scenes":[{"nodes":[0]}],"nodes":[{"mesh":0}],`);

	json.appendf(`"meshes":[{"name":"quads","primitives":[`);
	foreach (i, ktx2 : ktx2s)
	{
		if (i > 0) json.appendf(`,`);
		json.appendf(`{"attributes":{"POSITION":0,"NORMAL":1,"TEXCOORD_0":2},"indices":3`);
		if (with_materials) json.appendf(`,"material":%d`, i);
		json.appendf(`}`);
	}
	json.appendf(`]}],`);

	if (with_materials)
	{
		json.appendf(`"materials":[`);
		foreach (i, ktx2 : ktx2s)
		{
			if (i > 0) json.appendf(`,`);
			json.appendf(`{"pbrMetallicRoughness":{"baseColorTexture":{"index":%d}}}`, i);
		}
		json.appendf(`],`);
	}

	json.appendf(`"textures":[`);
	foreach (i, ktx2 : ktx2s)
	{
		if (i > 0) json.appendf(`,`);
		json.appendf(`{"sampler":0,"extensions":{"KHR_texture_basisu":{"source":%d}}}`, i);
	}
	json.appendf(`],"samplers":[{}],`);

	json.appendf(`"images":[`);
	foreach (i, ktx2 : ktx2s)
	{
		if (i > 0) json.appendf(`,`);
		json.appendf(`{"mimeType":"image/ktx2","bufferView":%d}`, 4 + i);
	}
	json.appendf(`],`);

	json.appendf(
		`"accessors":[`
		`{"bufferView":0,"componentType":5126,"count":4,"type":"VEC3","min":[-1,-1,0],"max":[1,1,0]},`
		`{"bufferView":1,"componentType":5126,"count":4,"type":"VEC3"},`
		`{"bufferView":2,"componentType":5126,"count":4,"type":"VEC2"},`
		`{"bufferView":3,"componentType":5123,"count":6,"type":"SCALAR"}],`,
	);
	json.appendf(
		`"bufferViews":[`
		`{"buffer":0,"byteOffset":%d,"byteLength":%d},`
		`{"buffer":0,"byteOffset":%d,"byteLength":%d},`
		`{"buffer":0,"byteOffset":%d,"byteLength":%d},`
		`{"buffer":0,"byteOffset":%d,"byteLength":%d}`,
		pos_at, (sz)48, nrm_at, (sz)48, uv_at, (sz)32, idx_at, (sz)12
	);
	foreach (i, at : image_at)
	{
		json.appendf(`,{"buffer":0,"byteOffset":%d,"byteLength":%d}`, at, image_len[i]);
	}
	json.appendf(`],`);
	json.appendf(`"buffers":[{"byteLength":%d}]}`, bin.len());
	while (json.len() % 4 != 0) json.append_char(' ');

	List{char} glb;
	glb.init(mem);
	defer glb.free();
	uint total = 12 + 8 + (uint)json.len() + 8 + (uint)bin.len();
	@append_u32(&glb, 0x46546C67);   // "glTF"
	@append_u32(&glb, 2);
	@append_u32(&glb, total);
	@append_u32(&glb, (uint)json.len());
	@append_u32(&glb, 0x4E4F534A);   // "JSON"
	glb.push_all(json.str_view());
	@append_u32(&glb, (uint)bin.len());
	@append_u32(&glb, 0x004E4942);   // "BIN\0"
	glb.push_all(bin.array_view());

	file::save(path, glb.array_view())!!;
}

<*
 Four small pictures, two in each codec, no two of them the same.

 Different content on purpose: a mapper bug that only shows on flat blocks, or
 only on an alpha slice, would pass a set of four identical images. Encoded with
 the same options `encode_ktx2_basis` uses, so these are the files a real export
 writes.
*>
fn char[] pre_pass_blob(uint which)
{
	const uint SIDE = 32;
	char[] source = mem::new_array(char, (sz)SIDE * SIDE * 4);
	defer free(source);

	for (uint y = 0; y < SIDE; y++)
	{
		for (uint x = 0; x < SIDE; x++)
		{
			sz at = ((sz)y * SIDE + x) * 4;
			switch (which % 4)
			{
				case 0:
					// Flat quadrants — the case every codec maps exactly.
					source[at + 0] = (char)(x >= SIDE / 2 ? 0xf0 : 0x10);
					source[at + 1] = (char)(y >= SIDE / 2 ? 0xf0 : 0x10);
					source[at + 2] = 0x80;
					source[at + 3] = 0xff;
				case 1:
					// A gradient, which takes the interpolated modes.
					source[at + 0] = (char)(x * 8);
					source[at + 1] = (char)(255 - y * 7);
					source[at + 2] = (char)((x * y) & 0xff);
					source[at + 3] = 0xff;
				case 2:
					// Alpha, so the second slice of an ETC1S file is exercised.
					source[at + 0] = (char)(y * 8);
					source[at + 1] = (char)(x * 3);
					source[at + 2] = (char)(x + y);
					source[at + 3] = (char)(x + y < SIDE ? 0xff : 0x40);
				default:
					// Noise, which takes whichever mode is left.
					source[at + 0] = (char)((x * 37 + y * 11) & 0xff);
					source[at + 1] = (char)((x * 13 + y * 53) & 0xff);
					source[at + 2] = (char)((x * 7 + y * 97) & 0xff);
					source[at + 3] = 0xff;
			}
		}
	}

	char[][1] images = { source };
	uint codec = which < 2 ? basis::ETC1S : basis::UASTC_4X4;
	return basis::encode(
		mem, codec, images[..], SIDE, SIDE, basis::TexType.D2,
		{ .quality = 90, .effort = 2, .srgb = true, .mipmaps = true }
	)!!;
}

<*
 The pre-pass and the one-at-a-time transcode produce the same bytes.

 **This is the whole claim.** `Assets.load` now transcodes every Basis image the
 file names before any material asks for one, on a pool, with the block mapper
 pinned to fewer threads inside — three things that could each move a byte. So
 the check is byte equality against `transcode_ktx2_blocks` called the way it
 was called before, on the same blobs, for both codecs and four different
 pictures.

 The last two checks are what `PreBlocks` rests on: the same file asked for as
 sRGB and as linear is the same blocks, so one transcode serves both and the
 space is written on at claim time.
*>
fn void the_pre_pass_matches_the_serial_transcode() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::TextureFormat bc7 = { three::TextureFamily.BC7, three::ColorSpace.SRGB };
		if (!renderer.gpu.supports(bc7)) return;   // no BC7 here; the pre-pass declines

		char[][4] blobs;
		for (uint i = 0; i < 4; i++) blobs[i] = pre_pass_blob(i);
		defer for (uint i = 0; i < 4; i++) free(blobs[i]);

		String path = "build/ktx_pre_pass.glb";
		write_basisu_glb_multi(path, blobs[..], true);
		defer (void)file::delete(path);

		three::Assets* assets = &renderer.pass.assets;
		three::AssetId id = assets.load(&renderer.gpu, path)!!;
		three::Asset* asset = assets.slot(id);

		test::@check(asset.images.blocks.len() == 4,
			"the pre-pass queued %d images, not the file's 4", asset.images.blocks.len());

		foreach (image_index, blob : blobs)
		{
			three::BlockImage want = three::transcode_ktx2_blocks(blob, bc7)!!;
			defer want.free();

			three::BlockImage* got = null;
			foreach (&pre : asset.images.blocks)
			{
				if (pre.image == (int)image_index) got = &pre.blocks;
			}
			test::@check(got != null, "image %d was not pre-transcoded", image_index);

			test::@check(got.width == want.width && got.height == want.height,
				"image %d is %dx%d, not %dx%d",
				image_index, got.width, got.height, want.width, want.height);
			test::@check(got.levels.len == want.levels.len,
				"image %d has %d levels, not %d",
				image_index, (int)got.levels.len, (int)want.levels.len);

			foreach (level, bytes : want.levels)
			{
				test::@check(got.levels[level] == bytes,
					"image %d level %d differs from the serial transcode", image_index, level);
			}
		}

		three::TextureFormat linear = { three::TextureFamily.BC7, three::ColorSpace.LINEAR };
		three::BlockImage as_srgb = three::transcode_ktx2_blocks(blobs[0], bc7)!!;
		defer as_srgb.free();
		three::BlockImage as_linear = three::transcode_ktx2_blocks(blobs[0], linear)!!;
		defer as_linear.free();
		test::@check(as_srgb.levels.len == as_linear.levels.len,
			"the two spaces gave different level counts");
		foreach (level, bytes : as_srgb.levels)
		{
			test::@check(as_linear.levels[level] == bytes,
				"level %d differs between sRGB and linear; one transcode cannot serve both", level);
		}
	};
}

<*
 A material claiming a pre-transcoded image uploads BC7, and takes it away.

 The pre-pass would be a memory leak dressed as a speed-up if the claim quietly
 transcoded again and left the queued copy sitting there. So this asserts both
 ends: the slot on the device is BC7 with the file's own chain, and the queue
 entry is gone.
*>
fn void a_claim_after_the_pre_pass_uploads_blocks() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::TextureFormat bc7 = { three::TextureFamily.BC7, three::ColorSpace.SRGB };
		if (!renderer.gpu.supports(bc7)) return;

		char[][4] blobs;
		for (uint i = 0; i < 4; i++) blobs[i] = pre_pass_blob(i);
		defer for (uint i = 0; i < 4; i++) free(blobs[i]);

		String path = "build/ktx_pre_pass_claim.glb";
		write_basisu_glb_multi(path, blobs[..], true);
		defer (void)file::delete(path);

		three::Assets* assets = &renderer.pass.assets;
		three::AssetId id = assets.load(&renderer.gpu, path)!!;

		uint chain = three::mip_levels(32, 32);
		for (uint mesh = 0; mesh < 4; mesh++)
		{
			assets.ensure_uploaded(id, mesh);
			int slot = assets.mesh(id, mesh).texture;
			test::@check(slot >= 0, "primitive %d did not resolve its KTX2 map", mesh);
			test::@check(assets.textures[slot].texture.format.equals(bc7),
				"primitive %d uploaded something that is not BC7 sRGB", mesh);
			test::@check(assets.textures[slot].texture.levels == chain,
				"primitive %d uploaded %d levels, not the file's %d",
				mesh, assets.textures[slot].texture.levels, chain);
		}

		three::Asset* asset = assets.slot(id);
		foreach (pre : asset.images.blocks)
		{
			test::@check(pre.image < 0,
				"image %d was still queued after its material claimed it", pre.image);
		}
	};
}

<*
 A file whose images no material ever names gives every one of them back.

 The pre-pass transcodes what a `texture` points at, and a `texture` nothing
 samples is perfectly legal glTF — so this file queues four chains that nobody
 will ever claim. Freeing them is `AssetImages.free_blocks`' job, reached from
 `free_stream`, reached from both `free_slot` here and `Assets.free` when the
 device is given back.

 There is no assertion on the bytes: the check is the runner's own, which
 reports whatever the test allocated and did not free.
*>
fn void unclaimed_pre_transcodes_are_given_back() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::TextureFormat bc7 = { three::TextureFamily.BC7, three::ColorSpace.SRGB };
		if (!renderer.gpu.supports(bc7)) return;

		char[][4] blobs;
		for (uint i = 0; i < 4; i++) blobs[i] = pre_pass_blob(i);
		defer for (uint i = 0; i < 4; i++) free(blobs[i]);

		String path = "build/ktx_pre_pass_orphan.glb";
		write_basisu_glb_multi(path, blobs[..], false);
		defer (void)file::delete(path);

		three::Assets* assets = &renderer.pass.assets;
		three::AssetId id = assets.load(&renderer.gpu, path)!!;

		test::@check(assets.slot(id).images.blocks.len() == 4,
			"the pre-pass queued %d images, so this asserts nothing",
			assets.slot(id).images.blocks.len());

		// Nothing ever drew it, so the sweep takes the whole file — and with it
		// four BC7 chains no material asked for.
		three::UnloadReport report = assets.unload_unused(&renderer.gpu);
		test::@check(report.assets == 1, "the sweep took %d assets, not the one", report.assets);
		test::@check(assets.slot(id) == null, "the handle still names a live asset");
	};
}
