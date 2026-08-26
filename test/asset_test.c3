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
import collision;
import std::core::test;
import std::io;
import std::io::file;
import std::math;
import std::math::vector;

const String FIXTURE = "test/fixtures/textured.glb";

<*
 The other half of the texture story: one image, four meshes, one material.

 `textured.glb` is two different images that hold the same picture — the case
 only a content hash can see. This is one image named four times — the case the
 hash sees far too late, because it cannot answer until the PNG has been
 decoded. Written by `test/fixtures/make_shared_material.py`.
*>
const String SHARED = "test/fixtures/shared_material.glb";

<*
 The fixture whose geometry is all at the origin and whose *nodes* put it
 anywhere. Written by `test/fixtures/make_hierarchy.py`, which explains what
 each node is for.
*>
const String HIERARCHY = "test/fixtures/hierarchy.glb";

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

		three::SceneStats stats = renderer.pass.stats();
		test::@check(stats.unique_meshes == 2, "the fixture's two meshes came back as %d", stats.unique_meshes);
		test::@check(stats.triangles == 4, "two quads should be 4 triangles, got %d", stats.triangles);
		test::@check(stats.vertices == 8, "two quads should be 8 vertices, got %d", stats.vertices);
	};
}

<*
 Two identical images upload once — and are still decoded twice.

 The fixture declares two glTF images, two textures and two materials; the PNG
 payloads are byte-identical. A loader keyed on the file's own indices uploads
 two. Content-hash dedup uploads one — the same rule the M6 exporter needs when
 it writes one glTF image per unique texture rather than one per reference.

 The decode count is asserted alongside, and asserted at **two**, because that
 is the honest description of what the hash can and cannot do. It is keyed on
 the decoded pixels, so it cannot say anything until both files' bytes have been
 through the decoder; two distinct images is precisely the case `ImageMemo` is
 blind to. Pinning the number here rather than leaving it unsaid is what stops
 the next reader from assuming the memo covers this too.
*>
fn void identical_textures_upload_once() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		renderer.pass.load(&renderer.gpu, FIXTURE)!!;

		three::SceneStats stats = renderer.pass.stats();
		test::@check(stats.textures == 1, "two byte-identical images uploaded as %d textures", stats.textures);
		test::@check(
			renderer.pass.assets.decodes == 2,
			"two distinct images decoded %d times; the hash works on pixels and has to see both",
			renderer.pass.assets.decodes
		);
	};
}

<*
 One image, four meshes, one decode.

 This is the check `identical_textures_upload_once` looks like it makes and does
 not. That one counts *textures*, which is the far side of the cache: the upload
 was already deduplicated and the count read 1 while the same PNG went through
 `decode_image`, `to_rgba` and a 64-bit hash once per primitive naming it. A
 test on the far side of a cache is a test the cache can fail behind, and this
 one did, for the whole of M1 through G2.

 So this counts decodes. Four meshes share material 0, which names image 0; the
 decoder should see the file's bytes exactly once. Four is what a memo-less
 loader reports, which is why the fixture has four pieces and not two — an
 off-by-one and a missing cache should not produce the same number.
*>
fn void an_image_every_mesh_shares_is_decoded_once() @test
{
	test::@check(file::is_file(SHARED), "%s is missing — regenerate it with test/fixtures/make_shared_material.py", SHARED);

	@with_pass(; three::Renderer* renderer)
	{
		renderer.pass.load(&renderer.gpu, SHARED)!!;

		three::SceneStats stats = renderer.pass.stats();
		test::@check(stats.unique_meshes == 4, "the fixture's four pieces came back as %d", stats.unique_meshes);
		test::@check(stats.textures == 1, "one image uploaded as %d textures", stats.textures);
		test::@check(
			renderer.pass.assets.decodes == 1,
			"one image shared by four meshes was decoded %d times",
			renderer.pass.assets.decodes
		);
	};
}

<*
 A memo hit still counts as a reference.

 The memo returns a texture index without going near the upload path, and the
 upload path is where the reference used to be taken. Skip the retain and the
 count is 1 where it should be 4 — which is invisible until the first of those
 four meshes goes away and takes a live image out from under the other three.

 Asserted on the refcount rather than on a render because the failure has no
 picture: `release_texture` will not free a slot whose count is already zero, so
 a driver-level use-after-free is not even reliably what happens. The number is
 the fault, and `an_image_four_meshes_share_survives_losing_half_of_them` in
 `unload_test` is where it turns into behaviour.
*>
fn void every_mesh_sharing_an_image_holds_a_reference() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		renderer.pass.load(&renderer.gpu, SHARED)!!;

		three::Assets* assets = &renderer.pass.assets;
		test::@check(assets.textures.len() == 1, "expected one texture slot, got %d", assets.textures.len());
		test::@check(
			assets.textures[0].refs == 4,
			"four meshes name the image and it holds %d references",
			assets.textures[0].refs
		);
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

		collision::Aabb3 bounds = renderer.pass.bounds();
		test::@check(bounds.min[0] < -1.2 && bounds.max[0] > 1.2, "x bounds came back [%f, %f], expected about [-1.25, 1.25]", bounds.min[0], bounds.max[0]);
		test::@check(bounds.min[1] < -0.4 && bounds.max[1] > 0.4, "y bounds came back [%f, %f], expected about [-0.5, 0.5]", bounds.min[1], bounds.max[1]);
	};
}

// ============================================================================
// The node hierarchy — `game.md` G3/S2
// ============================================================================

<*
 A node by name, anywhere in the scene.

 `Scene` has no find-by-name — `getObjectByName` is a JavaScript-side walk in
 Three.js and there is nothing in the host that wants one — so this is the
 test's own, over the node pool rather than the tree, which is the same set.
*>
fn three::NodeId named(three::Scene* scene, String name)
{
	foreach (i, &node : scene.nodes)
	{
		if (node.alive && node.name == name)
		{
			return { .index = (uint)i, .generation = node.generation };
		}
	}
	test::@check(false, "no node called '%s' in the scene", name);
	return three::NO_NODE;
}

fn bool near(Vec3 got, Vec3 want)
{
	return math::abs(got.x - want.x) < 0.001f
		&& math::abs(got.y - want.y) < 0.001f
		&& math::abs(got.z - want.z) < 0.001f;
}

<*
 The loader keeps the file's node tree.

 Until G3 it did not, and there was no way to tell: both other fixtures bake
 their positions into their vertices, so a loader that discards every node
 renders them perfectly. This fixture is the other kind — one quad at the
 origin, four times, positioned entirely by nodes — and under the old loader it
 draws as a single pile.

 Two roots, because `record_nodes` derives them from "nothing lists it as a
 child" rather than from the `scenes` array, and a file with two of them is what
 separates that from "node 0".
*>
fn void the_node_tree_survives_the_loader() @test
{
	test::@check(file::is_file(HIERARCHY), "%s is missing — regenerate it with test/fixtures/make_hierarchy.py", HIERARCHY);

	@with_pass(; three::Renderer* renderer)
	{
		three::AssetId id = renderer.pass.assets.load(&renderer.gpu, HIERARCHY)!!;
		three::Asset* asset = renderer.pass.assets.slot(id);

		test::@check(asset.nodes.len() == 4, "the file's four nodes came back as %d", asset.nodes.len());
		test::@check(asset.roots.len() == 2, "two nodes are nobody's child; %d were found", asset.roots.len());
		test::@check(asset.meshes.len() == 4,
			"three glTF meshes, one of them two primitives, uploaded as %d", asset.meshes.len());

		// `arm` names a glTF mesh with two primitives, so its range is two wide.
		// This is the mapping that cannot be arithmetic: a primitive with no
		// vertices is skipped at upload, so node-to-mesh has to be recorded.
		foreach (&node : asset.nodes)
		{
			if (node.name == "arm")
			{
				test::@check(node.mesh_count == 2, "`arm` draws %d meshes, expected 2", node.mesh_count);
			}
			if (node.name == "pivot")
			{
				test::@check(node.mesh_count == 0, "`pivot` has no mesh and drew %d", node.mesh_count);
			}
		}
	};
}

<*
 Instantiating rebuilds the transforms, and the chain composes.

 `tip` is under `arm` is under `pivot`, and its world position is the only
 number here that no single mistake produces by accident:

	pivot   translate (2, 0, 0), then a quarter turn about +Y
	arm     scale 2
	tip     translate (1, 0, 0)

 A quarter turn about +Y sends +X to (0, 0, -1) — which is not this test's
 claim to make, it is `a_child_follows_its_parent`'s, asserted there against
 `set_rotation` directly. So the local +1 on X becomes +2 after `arm`'s scale
 and (0, 0, -2) after `pivot`'s rotation, landing at (2, 0, -2).

 Drop the hierarchy and it is at the origin. Drop the scale and it is at
 (2, 0, -1). Compose the rotation the other way and it is at (4, 0, 0). Read the
 quaternion with a flipped sign and it is at (2, 0, 2). Every one of those is a
 different wrong answer, which is the property worth having in a fixture.

 `loose` is the second root and states its transform as a `matrix`; it is here
 because a loader that reads only TRS leaves it at the origin and every other
 assertion in this file still passes.
*>
fn void an_instantiated_tree_puts_its_meshes_where_the_file_says() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Scene* scene = renderer.pass.scene;

		three::AssetId id = renderer.pass.assets.load(&renderer.gpu, HIERARCHY)!!;
		scene.instantiate(id, scene.root, "prop");
		scene.update_world_matrices();

		Vec3 tip = scene.node(named(scene, "tip")).world_position();
		test::@check(near(tip, { 2, 0, -2 }),
			"`tip` landed at (%.3f, %.3f, %.3f), expected (2, 0, -2)", tip.x, tip.y, tip.z);

		Vec3 loose = scene.node(named(scene, "loose")).world_position();
		test::@check(near(loose, { 0, 3, 0 }),
			"`loose` states its transform as a matrix and landed at (%.3f, %.3f, %.3f), expected (0, 3, 0)",
			loose.x, loose.y, loose.z);

		Vec3 arm = scene.node(named(scene, "arm")).world_position();
		test::@check(near(arm, { 2, 0, 0 }),
			"`arm` landed at (%.3f, %.3f, %.3f), expected (2, 0, 0)", arm.x, arm.y, arm.z);

		// `arm` names a two-primitive mesh, so it is a group: two mesh children
		// plus `tip`. Three.js's GLTFLoader produces the same shape.
		three::Node* arm_node = scene.node(named(scene, "arm"));
		test::@check(arm_node.asset.is_set() == false, "`arm` draws a mesh itself instead of being a group");
		test::@check(arm_node.children.len() == 3,
			"`arm` has %d children; expected its two primitives and `tip`", arm_node.children.len());
	};
}

<*
 One instantiation is one reference per drawing node, and two instantiations are
 two subtrees over one upload.

 **The thesis, at a level the API could not previously state.** Before G3 a
 prop's hierarchy was not a thing that existed, so "instantiate it twice" was not
 an operation. It is now, and what it costs is what `plan.md` §2 promises: the
 nodes double and nothing on the device does.

 G2's `create_slot` is what makes it true and nothing in `instantiate` counts
 anything — which is the point of asserting it here rather than trusting it.
*>
fn void instantiating_twice_is_two_subtrees_over_one_upload() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Assets* assets = &renderer.pass.assets;
		three::Scene* scene = renderer.pass.scene;

		three::AssetId id = assets.load(&renderer.gpu, HIERARCHY)!!;
		uint meshes = (uint)assets.slot(id).meshes.len();

		// `Assets.load` uploads and nothing else — it is `MeshPass.load` that
		// also places. So a freshly loaded asset is at zero and unloadable, which
		// is what makes `three.load` cheap to call speculatively.
		test::@check(assets.slot(id).refs == 0, "loading alone took %d references", assets.slot(id).refs);

		three::NodeId one = scene.instantiate(id, scene.root, "first");
		test::@check(assets.slot(id).refs == meshes,
			"one instantiation of %d meshes took %d references", meshes, assets.slot(id).refs);

		three::NodeId two = scene.instantiate(id, scene.root, "second");
		test::@check(assets.slot(id).refs == meshes * 2,
			"two instantiations took %d references, expected %d", assets.slot(id).refs, meshes * 2);

		three::SceneStats stats = renderer.pass.stats();
		test::@check(stats.unique_meshes == meshes,
			"two copies of one asset report %d unique meshes, expected %d", stats.unique_meshes, meshes);

		scene.remove(one);
		test::@check(assets.slot(id).refs == meshes,
			"dropping one subtree left %d references, expected %d", assets.slot(id).refs, meshes);

		scene.remove(two);
		test::@check(assets.slot(id).refs == 0,
			"dropping both subtrees left %d references", assets.slot(id).refs);
	};
}

// ============================================================================
// Lazy loading — `game.md` G3/S3
// ============================================================================

<*
 **Loading a file uploads nothing.**

 The check that keeps a lazy loader lazy, and the reason it is phrased as an
 absence: every other test in this suite asserts that something is *there*, and
 all of them keep passing on the day the loader quietly goes back to uploading
 everything. Nothing else notices. This is the only assertion that can.

 What is there after a load is what the JSON says: a mesh slot per primitive,
 each with its name, its vertex count and its bounds — because a POSITION
 accessor carries `count` and is *required* to carry `min`/`max`. `Asset.bounds`
 is therefore correct on a file that has never uploaded a byte, which is what
 `camera.frameAll()` reads.
*>
fn void loading_a_file_uploads_nothing() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Assets* assets = &renderer.pass.assets;

		three::AssetId id = assets.load(&renderer.gpu, SHARED)!!;
		three::Asset* asset = assets.slot(id);

		test::@check(asset.meshes.len() == 4, "the file's four meshes were described as %d", asset.meshes.len());
		test::@check(assets.decodes == 0, "loading decoded %d images", assets.decodes);
		test::@check(assets.texture_count() == 0, "loading uploaded %d textures", assets.texture_count());

		foreach (&mesh : asset.meshes)
		{
			test::@check(!mesh.uploaded, "`%s` was uploaded by a plain load", mesh.name);
			test::@check(mesh.positions.buffer == null, "`%s` has a vertex buffer on the device", mesh.name);
			test::@check(mesh.bvh == null, "`%s` built its picking tree before anything drew it", mesh.name);

			// The three things that come out of the JSON, and the reason the
			// rest can wait.
			test::@check(mesh.name.len > 0, "a described mesh has no name");
			test::@check(mesh.vertex_count == 4, "`%s` describes %d vertices, expected a quad's 4", mesh.name, mesh.vertex_count);
		}

		test::@check(asset.bounds.max[0] > asset.bounds.min[0],
			"bounds came back empty from the JSON: [%f, %f]", asset.bounds.min[0], asset.bounds.max[0]);
	};
}

<*
 Placing one piece of a kit uploads one piece of it.

 `game.md` G3/S3's actual claim: a 200-mesh kit where a level places twelve pays
 for twelve. Here it is four and one. The count of *described* meshes does not
 move — the file is still fully known — which is the distinction the API now
 makes and could not before.
*>
fn void placing_one_mesh_of_a_kit_uploads_one() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Assets* assets = &renderer.pass.assets;
		three::Scene* scene = renderer.pass.scene;

		three::AssetId id = assets.load(&renderer.gpu, SHARED)!!;
		int wanted = assets.find_mesh(id, "piece_2");
		test::@check(wanted >= 0, "the fixture has no mesh called piece_2");

		scene.add_mesh(id, (uint)wanted, scene.root, "just the one");

		uint uploaded = 0;
		foreach (&mesh : assets.slot(id).meshes)
		{
			if (mesh.uploaded) uploaded++;
		}
		test::@check(uploaded == 1, "placing one mesh of a four-mesh file uploaded %d", uploaded);
		test::@check(assets.slot(id).meshes.len() == 4,
			"and the other three stopped being described (%d left)", assets.slot(id).meshes.len());
		test::@check(assets.decodes == 1, "one placed mesh decoded %d images", assets.decodes);

		// And it draws — an uploaded-on-demand mesh is a mesh like any other.
		three::SceneStats stats = renderer.pass.stats();
		test::@check(stats.unique_meshes == 1, "%d meshes reached the draw list", stats.unique_meshes);
		renderer.render_offscreen()!!;
	};
}

<*
 One piece of a kit can be given back while the rest of the file stays.

 The sharper unloading G3/S3 buys, and the thing the refcount moving from the
 file to the mesh is *for*: a level that swaps which pieces it places gives back
 the ones it stopped using without giving back the kit — and without re-reading
 the file to get them again, because the description never left.

 `report.meshes` is the count that says so. `report.assets` staying at zero is
 half the assertion: a sweep that took the whole file would look identical in
 every byte-counting check and be a completely different thing.
*>
fn void a_piece_of_a_kit_unloads_while_the_kit_stays() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Assets* assets = &renderer.pass.assets;
		three::Scene* scene = renderer.pass.scene;

		three::AssetId id = assets.load(&renderer.gpu, SHARED)!!;
		three::NodeId keep = scene.add_mesh(id, 0, scene.root, "kept");
		three::NodeId drop = scene.add_mesh(id, 1, scene.root, "dropped");

		test::@check(assets.slot(id).meshes[0].uploaded && assets.slot(id).meshes[1].uploaded,
			"both placed meshes should be on the device");

		scene.remove(drop);
		three::UnloadReport report = assets.unload_unused(&renderer.gpu);

		test::@check(report.meshes == 1, "the sweep gave back %d meshes, expected 1", report.meshes);
		test::@check(report.assets == 0, "the sweep took %d whole assets with it", report.assets);
		test::@check(assets.slot(id) != null, "the file was freed out from under the mesh still drawing");
		test::@check(assets.slot(id).meshes[0].uploaded, "the mesh still being drawn was freed");
		test::@check(!assets.slot(id).meshes[1].uploaded, "the unused mesh is still on the device");

		// Still described, which is what makes getting it back cheap.
		test::@check(assets.slot(id).meshes[1].name.len > 0, "the freed mesh lost its name");
		test::@check(assets.slot(id).meshes[1].vertex_count == 4, "the freed mesh lost its vertex count");

		// And placing it again uploads it again, with no re-read of the file.
		scene.add_mesh(id, 1, scene.root, "back again");
		test::@check(assets.slot(id).meshes[1].uploaded, "re-placing a freed mesh did not upload it");
		test::@check(assets.slot(id).meshes.len() == 4, "the mesh table changed shape");

		renderer.render_offscreen()!!;
		(void)keep;
	};
}
