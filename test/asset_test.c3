<*
 Loading a glTF, and drawing what came out of it.

	`c3c test --trust=full --test-noleak --test-filter three_tests::asset`

 The fixture is `test/fixtures/textured.glb`, written by
 `test/fixtures/make_textured.py` — which is checked in beside it so what the
 binary contains is readable rather than being a blob nobody can inspect. It is
 built to fail the two decisions `base_stage.md` S9 says must be right at M1
 rather than at M2:

 - Two meshes, so a loader that welds a file into one triangle soup is caught.
 - Two *separate* glTF images with byte-identical PNG payloads, so a loader
   that trusts the file's own indices instead of hashing content uploads two
   textures where one will do.

 The render checks assert on pixels. A mesh count says nothing about whether
 anything reached the screen, and the failure mode these exist to catch — a
 stream read at the wrong stride, a winding culled the wrong way — renders a
 perfectly valid empty frame with no validation message at all.
*>
module three_tests::asset;

import three;
import vk;
import image;
import gltf;
import std::core::test;
import std::io;
import std::io::file;

const String FIXTURE = "test/fixtures/textured.glb";

const uint W = 200;
const uint H = 150;

<*
 A headless renderer with the mesh pipeline built from `shaders/mesh.spv`.

 Skips nothing if the .spv is missing — it fails, loudly. A test suite that
 quietly passes when the shader was never built is worse than no suite.
*>
macro @with_pass(; @body(three::Renderer* renderer))
{
	vk::Instance instance = three::create_instance(false, headless: true)!!;
	defer instance.free();

	three::Renderer renderer;
	renderer.init(instance, (vk::SurfaceKHR)null, W, H)!!;
	defer renderer.free();

	renderer.pass.init(&renderer.gpu, &renderer.target)!!;

	@body(&renderer);
}

<*
 How many pixels are not the clear colour.

 The blunt instrument on purpose: it answers "did anything draw at all", which
 is the question that separates a broken geometry path from a broken material
 one, and it cannot be satisfied by a renderer that returns success without
 rasterising.
*>
fn uint count_drawn(image::Image* shot, float[4] clear)
{
	char[3] background = {
		(char)(uint)(clear[0] * 255.0 + 0.5),
		(char)(uint)(clear[1] * 255.0 + 0.5),
		(char)(uint)(clear[2] * 255.0 + 0.5),
	};

	uint drawn = 0;
	for (sz i = 0; i < shot.pixels.len; i += 4)
	{
		int dr = (int)shot.pixels[i] - (int)background[0];
		int dg = (int)shot.pixels[i + 1] - (int)background[1];
		int db = (int)shot.pixels[i + 2] - (int)background[2];
		if (dr * dr + dg * dg + db * db > 12) drawn++;
	}
	return drawn;
}

<*
 The built-in triangle draws.

 This is `base_stage.md` S8 as a regression test: geometry reaching the shader
 through a buffer device address, with no file involved. It is separate from
 the glTF checks so that a blank screen is never ambiguous about which half
 broke — and it is the check that would have caught the front-face direction
 being backwards, which validation is entirely happy about.
*>
fn void the_builtin_triangle_reaches_the_screen() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		renderer.pass.load_triangle(&renderer.gpu)!!;

		image::Image shot = renderer.capture()!!;
		defer shot.free();

		uint drawn = count_drawn(&shot, renderer.clear);
		uint total = W * H;
		test::@check(drawn > total / 50, "only %d of %d pixels differ from the clear colour; nothing rasterised", drawn, total);
		test::@check(drawn < total, "every pixel changed — the clear colour is not being written");
	};
}

<*
 A file with several meshes uploads several meshes.

 crig's loader deliberately welds a whole scene into one triangle soup, because
 a rigger wants one mesh. three.c3's thesis needs the opposite: an instance is
 an immutable asset reference plus a transform, so M2 has to be able to name a
 mesh and place N copies of it. If this ever returns 1, that thesis is gone and
 the file has to be read again to get it back.
*>
fn void several_meshes_stay_several_meshes() @test
{
	test::@check(file::is_file(FIXTURE), "%s is missing — regenerate it with test/fixtures/make_textured.py", FIXTURE);

	@with_pass(; three::Renderer* renderer)
	{
		renderer.pass.load(&renderer.gpu, FIXTURE)!!;

		three::PassStats stats = renderer.pass.stats();
		test::@check(stats.meshes == 2, "the fixture's two meshes came back as %d", stats.meshes);
		test::@check(stats.triangles == 4, "two quads should be 4 triangles, got %d", stats.triangles);
		test::@check(stats.vertices == 8, "two quads should be 8 vertices, got %d", stats.vertices);
	};
}

<*
 Two identical images upload once.

 The fixture declares two glTF images, two textures and two materials; the PNG
 payloads are byte-identical. A loader keyed on the file's own indices uploads
 two. Content-hash dedup uploads one — the same rule the M6 exporter needs when
 it writes one glTF image per unique texture rather than one per reference.
*>
fn void identical_textures_upload_once() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		renderer.pass.load(&renderer.gpu, FIXTURE)!!;

		three::PassStats stats = renderer.pass.stats();
		test::@check(stats.textures == 1, "two byte-identical images uploaded as %d textures", stats.textures);
	};
}

<*
 Indices are read at the width the file stored them.

 The fixture's indices are unsigned shorts, which is what almost every exporter
 writes. Reading them as uint pairs adjacent values into one index, so a quad
 comes back referring to vertex 196608 — and the draw either renders nothing or
 reads past the buffer. The count alone does not catch it, so this asserts on
 the picture too.
*>
fn void ushort_indices_are_not_read_as_uint() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		renderer.pass.load(&renderer.gpu, FIXTURE)!!;

		image::Image shot = renderer.capture()!!;
		defer shot.free();

		uint drawn = count_drawn(&shot, renderer.clear);
		test::@check(drawn > (W * H) / 50, "the fixture's quads drew %d pixels; indices are being misread", drawn);
	};
}

<*
 The base colour texture is actually sampled.

 The fixture's texture is a magenta and black checkerboard, chosen because it
 cannot be confused with anything else that could end up on screen: a material
 that lost its texture renders the flat white base colour factor, and a texture
 bound with broken UVs renders one flat sample of it. Neither produces magenta
 next to near-black.

 The expected magenta is dimmer than 255 because the shader multiplies by the
 light term, and the texture is sampled as sRGB into a linear target — so the
 check is on hue rather than on an exact value.
*>
fn void the_base_colour_texture_reaches_the_screen() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		renderer.pass.load(&renderer.gpu, FIXTURE)!!;

		image::Image shot = renderer.capture()!!;
		defer shot.free();

		uint magenta = 0;
		uint dark    = 0;
		for (sz i = 0; i < shot.pixels.len; i += 4)
		{
			int r = (int)shot.pixels[i];
			int g = (int)shot.pixels[i + 1];
			int b = (int)shot.pixels[i + 2];
			if (r > 80 && b > 80 && g < 40) magenta++;
			if (r < 20 && g < 20 && b < 20) dark++;
		}

		test::@check(magenta > 100, "only %d magenta pixels — the base colour texture is not being sampled", magenta);
		test::@check(dark > 100, "only %d dark pixels — the checker pattern is not there, so the UVs are wrong", dark);
	};
}

<*
 A mesh's bounds are the geometry's, not a guess.

 The camera frames what it is shown off these numbers, so bounds that are wrong
 put the model outside the frustum — which looks exactly like a renderer that
 draws nothing. The fixture's two quads span x in [-1.25, 1.25] and y in
 [-0.5, 0.5] by construction.
*>
fn void asset_bounds_cover_the_geometry() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		renderer.pass.load(&renderer.gpu, FIXTURE)!!;

		gltf::Aabb bounds = renderer.pass.asset.bounds;
		test::@check(bounds.min[0] < -1.2 && bounds.max[0] > 1.2, "x bounds came back [%f, %f], expected about [-1.25, 1.25]", bounds.min[0], bounds.max[0]);
		test::@check(bounds.min[1] < -0.4 && bounds.max[1] > 0.4, "y bounds came back [%f, %f], expected about [-0.5, 0.5]", bounds.min[1], bounds.max[1]);
	};
}
