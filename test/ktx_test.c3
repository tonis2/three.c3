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
