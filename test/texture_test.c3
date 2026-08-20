<*
 `three.texture(path)`: a PNG or JPEG off disk, and the material that wears it.

	`c3c test --trust=full --test-noleak --test-filter three_tests::texture`

 The fixtures are written by `test/fixtures/make_texture_files.py`, checked in
 beside them so that what the binaries hold is readable. Two of them are load-
 bearing in a way their names do not say:

 - `checker.png` holds **the same picture as the image embedded in
   `textured.glb`**, which is what makes `a_loose_file_and_a_gltf_image_are_one_upload`
   a test of the content hash rather than of two unrelated files happening to
   both load. The generator imports `make_textured.py` rather than copying it, so
   they cannot drift apart into a test that passes by asserting nothing.
 - `mislabelled.png` is `green.jpg` byte for byte. So "the format came from the
   bytes" is not asserted by the load succeeding — a PNG decoder could in
   principle fail in a way that looked like success — it is asserted by the two
   files landing in the *same texture slot*, which can only happen if both
   decoded to identical pixels.

 The render checks assert on pixels, for `three_tests::asset`'s reason: a
 material that is wired up wrong renders a perfectly valid frame and reports no
 error at all. The colours are chosen so no two of them can be confused —
 magenta and near-black for the checker, and a green with almost no red or blue
 in it for the override.
*>
module three_tests::texture;

import three;
import vk;
import image;
import collision;
import std::core::test;
import std::io;
import std::io::file;
import std::math;
import std::math::vector;

const String CHECKER = "test/fixtures/checker.png";
const String GREEN = "test/fixtures/green.jpg";
const String MISLABELLED = "test/fixtures/mislabelled.png";
const String NOT_AN_IMAGE = "test/fixtures/not_an_image.png";
const String DEEP = "test/fixtures/deep.png";

<*
 The glTF whose two embedded images hold the checkerboard `checker.png` holds.
*>
const String TEXTURED = "test/fixtures/textured.glb";

const uint W = 200;
const uint H = 150;

<*
 The same, with a JavaScript runtime over it — for the checks that exercise the
 verb a script actually calls rather than the function underneath it.
*>
macro @with_js_gpu(; @body(three::JsRuntime* run))
{
	vk::Instance instance = three::create_instance(false, headless: true)!!;
	defer instance.free();

	three::Renderer renderer;
	renderer.init(instance, (vk::SurfaceKHR)null, W, H)!!;
	defer renderer.free();

	renderer.pass.init(&renderer.gpu, &renderer.target)!!;

	three::JsRuntime runtime;
	runtime.open(&renderer.pass, &renderer)!!;
	defer runtime.close();

	@body(&runtime);
}

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
 How many pixels are recognisably one colour, by a test that cannot be satisfied
 by any of the others on screen.

 Deliberately loose on brightness and tight on hue. The shader multiplies by the
 light term and by `PRIMITIVE_COLOR`, so the value that arrives is not the value
 in the file — but nothing in these fixtures turns magenta into green on the way.

 This used to say the looseness was also for "sampled as sRGB into a linear
 target", which was a description of the gamma defect written as though it were
 a fact of life. It is not one any more; `three_tests::color` asserts the round
 trip exactly, and this suite stays loose only because it is about hue.
*>
fn uint count_magenta(image::Image* shot)
{
	uint found = 0;
	for (sz i = 0; i < shot.pixels.len; i += 4)
	{
		if (shot.pixels[i] > 80 && shot.pixels[i + 2] > 80 && shot.pixels[i + 1] < 40) found++;
	}
	return found;
}

fn uint count_green(image::Image* shot)
{
	uint found = 0;
	for (sz i = 0; i < shot.pixels.len; i += 4)
	{
		if (shot.pixels[i + 1] > 60 && shot.pixels[i] < 40 && shot.pixels[i + 2] < 40) found++;
	}
	return found;
}

<*
 How many times the colour changes along the middle row of the frame.

 The measure `material.repeat` is asserted with, and it is chosen to be robust
 where a pixel count is not: it does not care how much of the frame the surface
 covers, how the sampler filtered the edges, or how bright the light was. What it
 counts is how many tile boundaries crossed the row, which is exactly what a
 repeat multiplies.

 The threshold is on the sum of the channel differences rather than on any one
 channel, so it registers a magenta-to-black edge and would register a
 green-to-blue one too.
*>
fn uint row_transitions(image::Image* shot)
{
	sz bpp = shot.bytes_per_pixel();
	sz row = (sz)(shot.height / 2) * (sz)shot.width * bpp;
	uint changes = 0;
	for (sz x = 1; x < (sz)shot.width; x++)
	{
		sz a = row + (x - 1) * bpp;
		sz b = row + x * bpp;
		int delta = math::abs((int)shot.pixels[a] - (int)shot.pixels[b])
			+ math::abs((int)shot.pixels[a + 1] - (int)shot.pixels[b + 1])
			+ math::abs((int)shot.pixels[a + 2] - (int)shot.pixels[b + 2]);
		if (delta > 60) changes++;
	}
	return changes;
}

<*
 How many pixels differ between two frames of the same size.

 Used where the claim is "the picture changed" rather than "this pixel changed",
 which is the honest form of it for anything that slides: a single sample can
 land on the same colour after a shift and say nothing.
*>
fn uint pixels_that_differ(image::Image* a, image::Image* b)
{
	if (a.pixels.len != b.pixels.len) return 0;
	uint moved = 0;
	for (sz i = 0; i < a.pixels.len; i += 4)
	{
		int delta = math::abs((int)a.pixels[i] - (int)b.pixels[i])
			+ math::abs((int)a.pixels[i + 1] - (int)b.pixels[i + 1])
			+ math::abs((int)a.pixels[i + 2] - (int)b.pixels[i + 2]);
		if (delta > 60) moved++;
	}
	return moved;
}

fn char[3] centre_of(image::Image* shot)
{
	sz bpp = shot.bytes_per_pixel();
	sz at = ((sz)(shot.height / 2) * (sz)shot.width + (sz)(shot.width / 2)) * bpp;
	return { shot.pixels[at], shot.pixels[at + 1], shot.pixels[at + 2] };
}

fn uint count_dark(image::Image* shot)
{
	uint found = 0;
	for (sz i = 0; i < shot.pixels.len; i += 4)
	{
		if (shot.pixels[i] < 20 && shot.pixels[i + 1] < 20 && shot.pixels[i + 2] < 20) found++;
	}
	return found;
}

// ============================================================================
// Reading a file
// ============================================================================

<*
 The fixtures exist. Everything below is meaningless without them, and a missing
 file should say so once rather than as eleven confusing failures.
*>
fn void the_fixtures_are_there() @test
{
	String[6] fixtures = { CHECKER, GREEN, MISLABELLED, NOT_AN_IMAGE, DEEP, TEXTURED };
	foreach (path : fixtures)
	{
		test::@check(
			file::is_file(path), "%s is missing — regenerate with test/fixtures/make_texture_files.py", path
		);
	}
}

<*
 A PNG becomes a texture with the extents the file declares.

 The extents are checked rather than only the success, because a decoder that
 lost a dimension still returns an image and still uploads: `three.texture` hands
 `width` and `height` back for a script to size a plane by, and a texture that
 loaded at the wrong size is exactly the thing worth being able to see.
*>
fn void a_png_file_becomes_a_texture() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Assets* assets = &renderer.pass.assets;
		int index = assets.load_texture_file(&renderer.gpu, CHECKER)!!;

		test::@check(index >= 0, "the checkerboard did not load");
		test::@check(assets.texture_count() == 1, "%d textures resident after one load", assets.texture_count());

		three::Texture* uploaded = assets.texture_at(index);
		test::@check(uploaded.width == 8 && uploaded.height == 8,
			"the 8x8 checkerboard uploaded as %dx%d", uploaded.width, uploaded.height);
	};
}

<*
 A JPEG does too, which is the other half of what `image.c3l` decodes.

 Separate from the PNG check rather than a loop over both, because the two go
 through different decoders and a failure that named neither would be a failure
 worth bisecting by hand.
*>
fn void a_jpeg_file_becomes_a_texture() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Assets* assets = &renderer.pass.assets;
		int index = assets.load_texture_file(&renderer.gpu, GREEN)!!;

		test::@check(index >= 0, "the JPEG did not load");
		three::Texture* uploaded = assets.texture_at(index);
		test::@check(uploaded.width == 32 && uploaded.height == 32,
			"the 32x32 JPEG uploaded as %dx%d", uploaded.width, uploaded.height);
	};
}

<*
 A JPEG named `.png` loads as a JPEG.

 **Asserted by the slot, not by the success.** `mislabelled.png` is `green.jpg`
 byte for byte, so if the name had chosen the decoder this would either have
 failed outright or — the case worth guarding — produced *something* that was not
 the same picture. Landing in the same texture slot means the decoded RGBA was
 identical, which only the right decoder produces.
*>
fn void the_format_is_read_from_the_bytes_not_the_name() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Assets* assets = &renderer.pass.assets;
		int honest = assets.load_texture_file(&renderer.gpu, GREEN)!!;
		int renamed = assets.load_texture_file(&renderer.gpu, MISLABELLED)!!;

		test::@check(renamed == honest,
			"the same JPEG under two names became textures %d and %d", honest, renamed);
		test::@check(assets.texture_count() == 1,
			"%d textures resident — the renamed copy was decoded as something else", assets.texture_count());
	};
}

<*
 Something that is not an image is refused by name.

 Three refusals and three different things to do about them, which is why they
 are three faults and not one: check the path, convert the file, re-export it at
 eight bits. A single "could not load" would cost the agent all of that.
*>
fn void a_file_that_is_not_an_image_says_which_it_is() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Assets* assets = &renderer.pass.assets;

		int? refused = assets.load_texture_file(&renderer.gpu, NOT_AN_IMAGE);
		if (catch err = refused)
		{
			test::@check(err == three::TEXTURE_FORMAT_UNKNOWN, "text under a .png name reported %s", err);
		}
		else
		{
			test::@check(false, "a text file loaded as a texture");
		}

		int? missing = assets.load_texture_file(&renderer.gpu, "test/fixtures/nothing_here.png");
		if (catch err = missing)
		{
			test::@check(err == three::TEXTURE_UNREADABLE, "a missing file reported %s", err);
		}
		else
		{
			test::@check(false, "a file that is not there loaded as a texture");
		}

		test::@check(assets.texture_count() == 0,
			"%d textures resident after two refusals", assets.texture_count());
	};
}

<*
 A 16-bit PNG is refused rather than rendered from the wrong bytes.

 It decodes — `image.c3l` handles 16-bit fine — and `Image.to_rgba` is the thing
 that cannot narrow it: it indexes as though the source were 8-bit, so what
 reaches the device is not a darker version of the picture, it is a different
 picture assembled from half of each channel. Garbled pixels read as a decoder
 bug; a named refusal reads as what it is.
*>
fn void a_sixteen_bit_png_is_refused_rather_than_garbled() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Assets* assets = &renderer.pass.assets;

		int? refused = assets.load_texture_file(&renderer.gpu, DEEP);
		if (catch err = refused)
		{
			test::@check(err == three::TEXTURE_BIT_DEPTH, "a 16-bit PNG reported %s", err);
		}
		else
		{
			test::@check(false, "a 16-bit PNG uploaded; to_rgba cannot narrow one, so those are the wrong bytes");
		}
	};
}

// ============================================================================
// Sharing
// ============================================================================

<*
 **The headline.** A file on disk and the identical image inside a `.glb` are one
 upload.

 This is what `load_texture_file` going through `claim_texture` buys, and it is
 the reason that refactor happened rather than the loader uploading for itself.
 The hash is over the decoded RGBA, so where the bytes came from — an embedded
 bufferView or a path — is not supposed to be visible at all. Two texture slots
 here would mean a game that ships a texture both loose and inside a model pays
 twice for it, silently, and `stats().textures` would say two while the picture
 stayed identical.

 The glTF is loaded first on purpose. The other order works too and is a weaker
 test: `textured.glb` holds *two* images with identical bytes, so it exercises
 the hash on its own and could pass while the loose file made a third slot.
*>
fn void a_loose_file_and_a_gltf_image_are_one_upload() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Assets* assets = &renderer.pass.assets;

		renderer.pass.load(&renderer.gpu, TEXTURED)!!;
		test::@check(assets.texture_count() == 1,
			"the fixture's two identical images uploaded as %d textures", assets.texture_count());

		int loose = assets.load_texture_file(&renderer.gpu, CHECKER)!!;
		test::@check(assets.texture_count() == 1,
			"the same picture off disk made a second slot: %d textures", assets.texture_count());
		test::@check(assets.texture_refs(loose) > 1,
			"the loose load did not join the existing slot — it holds %d references", assets.texture_refs(loose));
	};
}

<*
 The same file twice is one upload and two references.

 Two references rather than one because each caller releases separately: a script
 holding two handles to one picture and disposing one must not take the image
 out from under the other.
*>
fn void the_same_file_twice_is_one_upload_and_two_references() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Assets* assets = &renderer.pass.assets;

		int first = assets.load_texture_file(&renderer.gpu, CHECKER)!!;
		int second = assets.load_texture_file(&renderer.gpu, CHECKER)!!;

		test::@check(first == second, "the same file loaded as textures %d and %d", first, second);
		test::@check(assets.texture_count() == 1, "%d textures resident", assets.texture_count());
		test::@check(assets.texture_refs(first) == 2,
			"two loads left %d references, so one dispose would free an image the other still holds",
			assets.texture_refs(first)
		);

		assets.release_texture(&renderer.gpu, first);
		test::@check(assets.texture_alive(first), "releasing one of two references freed the image");
		assets.release_texture(&renderer.gpu, second);
		test::@check(!assets.texture_alive(first), "releasing the last reference left the slot alive");
		test::@check(assets.texture_count() == 0, "%d textures resident after both releases", assets.texture_count());
	};
}

// ============================================================================
// Wearing it
// ============================================================================

<*
 A material's map reaches the screen.

 A plane rather than the built-in triangle, because the triangle carries no uvs
 and `mesh.slang` samples only under `FLAG_HAS_UVS` — so this would pass on a
 renderer that ignored the map entirely and drew the base colour, which is white.
 The checkerboard is the fixture that cannot be faked: a lost texture is flat
 white, and broken uvs are one flat sample. Neither puts magenta next to
 near-black.
*>
fn void a_material_map_reaches_the_screen() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Assets* assets = &renderer.pass.assets;
		three::Scene* scene = &renderer.pass.scene;

		int texture = assets.load_texture_file(&renderer.gpu, CHECKER)!!;
		uint material = renderer.pass.create_texture_material(texture)!!;

		three::AssetId plane = assets.primitive(&renderer.gpu, three::plane_shape(2, 2))!!;
		three::NodeId node = scene.add_mesh(plane, 0);
		scene.set_material(node, material);
		renderer.pass.frame_camera();

		image::Image shot = renderer.capture()!!;
		defer shot.free();

		uint magenta = count_magenta(&shot);
		uint dark = count_dark(&shot);
		test::@check(magenta > 100, "only %d magenta pixels — the material's map is not being sampled", magenta);
		test::@check(dark > 100, "only %d dark pixels — the checker is not there, so the uvs are wrong", dark);
	};
}

<*
 The material's map wins over the image the mesh brought.

 `textured.glb`'s first quad carries the checkerboard on its own `GpuMesh`, so
 this draws a mesh that already has a texture and asserts that the material's
 replaces it. The other way round — the file quietly overruling a map a script
 asked for — is the failure worth catching, and it looks exactly like the
 assignment having done nothing.

 Asserted in both directions: the green has to arrive *and* the magenta has to
 go. Checking only for green would pass on a renderer that drew both quads and
 happened to put green somewhere.
*>
fn void a_material_map_wins_over_the_image_the_mesh_brought() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Assets* assets = &renderer.pass.assets;
		three::Scene* scene = &renderer.pass.scene;

		three::AssetId textured = assets.load(&renderer.gpu, TEXTURED)!!;
		three::NodeId node = scene.add_mesh(textured, 0);
		renderer.pass.frame_camera();

		image::Image before = renderer.capture()!!;
		defer before.free();
		test::@check(count_magenta(&before) > 100,
			"the fixture's own checkerboard is not on screen (%d magenta pixels), so this test proves nothing",
			count_magenta(&before)
		);

		int green = assets.load_texture_file(&renderer.gpu, GREEN)!!;
		uint material = renderer.pass.create_texture_material(green)!!;
		scene.set_material(node, material);

		image::Image after = renderer.capture()!!;
		defer after.free();

		test::@check(count_green(&after) > 100,
			"only %d green pixels — the material's map did not replace the mesh's own", count_green(&after));
		test::@check(count_magenta(&after) == 0,
			"%d magenta pixels remain — the mesh's own texture is still being sampled", count_magenta(&after));
	};
}

<*
 A material holds a reference to its map for as long as it names it.

 The reference the *script* holds and the one the *material* holds are different
 references, which is what makes `texture.dispose()` safe to call as soon as a
 script is done referring to a texture rather than something to be timed against
 the materials using it.
*>
fn void a_material_holds_a_reference_to_its_map() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Assets* assets = &renderer.pass.assets;

		int texture = assets.load_texture_file(&renderer.gpu, CHECKER)!!;
		test::@check(assets.texture_refs(texture) == 1, "a fresh load holds %d references", assets.texture_refs(texture));

		uint material = renderer.pass.create_texture_material(texture)!!;
		test::@check(assets.texture_refs(texture) == 2,
			"a material naming the texture left %d references", assets.texture_refs(texture));

		// The script letting go of its handle. The material still draws with it.
		assets.release_texture(&renderer.gpu, texture);
		test::@check(assets.texture_alive(texture),
			"disposing the script's handle freed an image a material is still drawing with");
		test::@check(renderer.pass.material(material).texture == texture,
			"the material stopped naming its map");
	};
}

<*
 Re-pointing a map moves the reference rather than adding one.

 The count going up and never coming down is the leak this catches, and it has no
 other symptom: the picture is right, the material is right, and the texture
 table grows by one dead image per assignment for the life of the process.
*>
fn void re_pointing_a_map_moves_the_reference() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Assets* assets = &renderer.pass.assets;

		int checker = assets.load_texture_file(&renderer.gpu, CHECKER)!!;
		int green = assets.load_texture_file(&renderer.gpu, GREEN)!!;
		uint material = renderer.pass.create_texture_material(checker)!!;

		test::@check(assets.texture_refs(checker) == 2, "%d references before the move", assets.texture_refs(checker));

		renderer.pass.set_material_map(&renderer.gpu, material, green)!!;
		test::@check(assets.texture_refs(checker) == 1,
			"the old map still holds %d references after the material stopped naming it",
			assets.texture_refs(checker)
		);
		test::@check(assets.texture_refs(green) == 2,
			"the new map holds %d references", assets.texture_refs(green));

		// Clearing it puts the material back on whatever the mesh carries, and
		// gives the last material-held reference back.
		renderer.pass.set_material_map(&renderer.gpu, material, three::NO_TEXTURE)!!;
		test::@check(assets.texture_refs(green) == 1,
			"clearing the map left %d references on it", assets.texture_refs(green));
		test::@check(renderer.pass.material(material).texture == three::NO_TEXTURE,
			"the material still names a map after it was cleared");
	};
}

<*
 The last reference going takes the image with it, even from a material.

 `MeshPass.free` releases what its materials hold before `Assets.free` walks the
 table, so a material's reference is a real one and not a formality — and the
 leak tracker is what proves it, since a count left standing here is invisible in
 every other test.
*>
fn void the_shared_slot_survives_the_scripts_handle() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Assets* assets = &renderer.pass.assets;

		int texture = assets.load_texture_file(&renderer.gpu, CHECKER)!!;
		uint material = renderer.pass.create_texture_material(texture)!!;
		assets.release_texture(&renderer.gpu, texture);

		three::AssetId plane = assets.primitive(&renderer.gpu, three::plane_shape(2, 2))!!;
		three::NodeId node = renderer.pass.scene.add_mesh(plane, 0);
		renderer.pass.scene.set_material(node, material);
		renderer.pass.frame_camera();

		image::Image shot = renderer.capture()!!;
		defer shot.free();

		test::@check(count_magenta(&shot) > 100,
			"only %d magenta pixels — the image went when the script's handle did", count_magenta(&shot));
	};
}

// ============================================================================
// What a material will not accept
// ============================================================================

<*
 The built-in materials refuse a map.

 `DEFAULT_MATERIAL` is what every node draws with until it is given something
 else, so a map on it would texture the whole scene through a handle that reads
 like it names one material. `LINE_MATERIAL` is refused because a debug line
 carries no uvs, and offering a setting that silently does nothing is worse than
 not offering it.
*>
fn void the_built_in_materials_refuse_a_map() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Assets* assets = &renderer.pass.assets;
		int texture = assets.load_texture_file(&renderer.gpu, CHECKER)!!;

		uint[2] built_in = { three::DEFAULT_MATERIAL, three::LINE_MATERIAL };
		foreach (index : built_in)
		{
			if (catch err = renderer.pass.set_material_map(&renderer.gpu, index, texture))
			{
				test::@check(err == three::MATERIAL_UNKNOWN, "material %d refused a map with %s", index, err);
			}
			else
			{
				test::@check(false, "built-in material %d accepted a map that every node shares", index);
			}
		}

		test::@check(assets.texture_refs(texture) == 1,
			"a refused assignment left %d references — it retained before it refused",
			assets.texture_refs(texture)
		);
	};
}

<*
 A texture that is not there cannot be given to a material.

 **The index used is a disposed one, not an out-of-range one**, and that is the
 whole difference between this test and a weaker version of it. An index past the
 end of the table is refused by every function that touches it almost by
 accident. A *disposed* index is in range, names a slot that is really there, and
 differs from a live one only by a flag — so it is the one that gets through, and
 it is the one a script actually produces: dispose, then assign.

 The last check is the one with teeth. A refusal that retained on its way out
 would leave a reference standing on a dead slot, which nothing observes until
 `free_textures` hands that slot to the next upload — and the new occupant then
 starts one reference too high and is never freed. That is a leak whose symptom
 appears an arbitrary number of loads later, attached to the wrong image.

 **That last check is guarded twice, and this test only catches losing both.**
 `set_material_map` validates before it retains, and `retain_texture` refuses a
 dead slot on its own; either one alone is enough, so deleting just one leaves
 this passing. Verified by injection rather than assumed — it is worth knowing
 that this is a belt-and-braces check and not a single-point one, so that nobody
 deletes the "redundant" guard on the strength of the suite staying green.
*>
fn void a_texture_that_is_not_there_is_refused() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Assets* assets = &renderer.pass.assets;

		// **The keeper is loaded first, and that order is the test.** A freed slot
		// goes on `free_textures` and the next upload takes it — so loading the
		// keeper *after* disposing would hand it the very index under test, and
		// `dead` would name a live texture again. Written the other way round
		// first, and this is what caught it: the second refusal passed, because
		// there was nothing left to refuse.
		int keeper = assets.load_texture_file(&renderer.gpu, GREEN)!!;
		int dead = assets.load_texture_file(&renderer.gpu, CHECKER)!!;
		assets.release_texture(&renderer.gpu, dead);
		test::@check(!assets.texture_alive(dead), "the fixture for this test is supposed to be a disposed slot");

		if (catch err = renderer.pass.create_texture_material(dead))
		{
			test::@check(err == three::MATERIAL_TEXTURE_UNKNOWN, "a disposed index reported %s", err);
		}
		else
		{
			test::@check(false, "a material was built over a texture that had been disposed");
		}

		uint material = renderer.pass.create_texture_material(keeper)!!;

		if (catch err = renderer.pass.set_material_map(&renderer.gpu, material, dead))
		{
			test::@check(err == three::MATERIAL_TEXTURE_UNKNOWN, "assigning a disposed index reported %s", err);
		}
		else
		{
			test::@check(false, "a material accepted a map that had been disposed");
		}

		test::@check(renderer.pass.material(material).texture == keeper,
			"a refused assignment changed the map anyway");

		// Read off the slot rather than through `texture_refs`, which answers zero
		// for anything not alive and would report success either way. The raw
		// count is the only place a retain on a dead slot is visible.
		test::@check(assets.textures[dead].refs == 0,
			"the disposed slot came out of two refusals holding %d references",
			assets.textures[dead].refs
		);
	};
}

<*
 A material with no map is a side and nothing else, and that is a use.

 It is the cheapest skydome: a sphere seen from inside shows only its back faces,
 and before this the only way to ask for `BackSide` was to compile a
 `ShaderMaterial` for it. Nothing else in the tree covers "the built-in pipeline,
 with a side" because until now it could not be asked for.
*>
fn void a_material_with_no_map_still_carries_a_side() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		uint material = renderer.pass.create_texture_material(three::NO_TEXTURE, three::SIDE_BACK)!!;

		three::Material* built = renderer.pass.material(material);
		test::@check(built != null, "a material with no map was not built");
		test::@check(built.texture == three::NO_TEXTURE, "it came out naming texture %d", built.texture);
		test::@check(built.cull == CULL_MODE_FRONT_BIT,
			"BackSide has to cull the front faces, which is what makes a skydome visible from inside");
	};
}

<*
 The default material has no texture of its own, with images in the table.

 This exists for one line in `MeshPass.init`. `Material.texture` is an `int` and
 C3 zero-fills what a designated initializer leaves out, so a forgotten
 `.texture = NO_TEXTURE` there does not render untextured — it renders **texture
 zero**, whatever the first image any asset happened to upload was, on every node
 in the scene that was never given a material.

 Nothing else catches it. Every other check here builds a material on purpose and
 hands it a texture on purpose, so they all pass with the field zeroed. The shape
 of this test is what makes it work: an image in the table that the geometry has
 no business wearing, and a plane drawn with the material a script never chose.
*>
fn void the_default_material_wears_no_texture_of_its_own() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Assets* assets = &renderer.pass.assets;

		// Texture 0, and nothing names it. A forgotten `NO_TEXTURE` puts it on
		// the plane below.
		int index = assets.load_texture_file(&renderer.gpu, CHECKER)!!;
		test::@check(index == 0, "the checkerboard took slot %d, so this test is not about slot zero", index);

		three::AssetId plane = assets.primitive(&renderer.gpu, three::plane_shape(2, 2))!!;
		three::NodeId node = renderer.pass.scene.add_mesh(plane, 0);
		test::@check(renderer.pass.scene.node(node).material == three::DEFAULT_MATERIAL,
			"a new node is supposed to start on the default material");
		renderer.pass.frame_camera();

		image::Image shot = renderer.capture()!!;
		defer shot.free();

		test::@check(count_magenta(&shot) == 0,
			"%d magenta pixels on a plane nobody gave a texture — the default material is wearing texture 0",
			count_magenta(&shot)
		);
	};
}

<*
 A mesh with no uvs is not refused, and shows nothing.

 The one case where this looks broken and is not, recorded as a test so that the
 next person to see it does not go looking for the bug. A `ConvexGeometry` has no
 natural parameterisation, so `upload_built` leaves `has_uvs` false and
 `mesh.slang` never samples — the material is set, correct, and invisible.

 Asserted as "drew, but no magenta" rather than as an error, because the two
 failures it separates are worth separating: nothing on screen at all would be a
 geometry bug, and magenta on screen would mean the hull grew uvs from somewhere.
*>
fn void a_hull_has_nowhere_to_put_a_map() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Assets* assets = &renderer.pass.assets;
		three::Scene* scene = &renderer.pass.scene;

		int texture = assets.load_texture_file(&renderer.gpu, CHECKER)!!;
		uint material = renderer.pass.create_texture_material(texture)!!;

		Vec3[8] corners = {
			{ -1, -1, -1 }, { 1, -1, -1 }, { 1, 1, -1 }, { -1, 1, -1 },
			{ -1, -1, 1 }, { 1, -1, 1 }, { 1, 1, 1 }, { -1, 1, 1 },
		};
		three::AssetId hull = assets.convex(&renderer.gpu, corners[..])!!;
		test::@check(!assets.mesh(hull, 0).has_uvs, "a hull grew uvs, so this test is no longer about anything");

		three::NodeId node = scene.add_mesh(hull, 0);
		scene.set_material(node, material);
		renderer.pass.frame_camera();

		image::Image shot = renderer.capture()!!;
		defer shot.free();

		uint drawn = 0;
		for (sz i = 0; i < shot.pixels.len; i += 4)
		{
			if (shot.pixels[i] > 30 || shot.pixels[i + 1] > 30 || shot.pixels[i + 2] > 30) drawn++;
		}
		test::@check(drawn > 100, "the hull drew %d lit pixels — this is a geometry failure, not a uv one", drawn);
		test::@check(count_magenta(&shot) == 0,
			"%d magenta pixels on a mesh with no uv stream", count_magenta(&shot));
	};
}

// ============================================================================
// Reading pixels back
//
// Textures were write-only: pixels went to the device and could not come back.
// Two costs, and they looked unrelated. `examples/village` needed each generated
// texture's average colour to bake into its glTF export, and with no readback
// the choice was a second copy of all eleven generators — which drifts from the
// real ones silently — or accumulating the mean inside the loop that wrote them,
// which only works for a script that owns both sides. And a texture nothing can
// read is a texture nothing can test: every check above goes the long way round,
// through a rendered frame, because there was no shorter one.
// ============================================================================

<*
 A `DataTexture` reads back as the array it was built from, byte for byte.

 The claim worth making exactly rather than approximately, because it pins the
 whole chain at once: the upload copies, the image is `R8G8B8A8_SRGB`,
 `vkCmdCopyImageToBuffer` converts nothing, and the layout goes back where the
 descriptor expects it. Any of those being wrong shows up here as a number.

 Deliberately not a flat colour — a gradient with all four channels moving, so a
 channel swizzle, a row-stride mistake or a half-copied image cannot pass. A
 solid fill would survive all three.
*>
fn void a_data_texture_reads_back_as_the_bytes_it_was_given() @test
{
	@with_js_gpu(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const w = 16, h = 12;
			const px = new Uint8Array(w * h * 4);
			for (let y = 0; y < h; y++) {
				for (let x = 0; x < w; x++) {
					const i = (y * w + x) * 4;
					px[i] = x * 16;
					px[i + 1] = y * 20;
					px[i + 2] = (x + y) * 8;
					px[i + 3] = 255;
				}
			}
			const tex = new three.DataTexture(px, w, h);
			const back = tex.read();

			let same = 0;
			for (let i = 0; i < px.length; i++) if (px[i] === back[i]) same++;
			return { len: back.length, want: px.length, same, first: [back[0], back[1], back[2], back[3]] };
		`);
		defer result.free();
		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value.contains(`"len":768`), "16x12x4 is 768 bytes: %s", result.value);
		test::@check(result.value.contains(`"same":768`),
			"every byte should come back as it went in: %s", result.value);
	};
}

<*
 A texture from a file reads back too, which is the half a script cannot fake.

 A generated texture can always be regenerated; a `.png` cannot, and that is the
 case the village had no answer to. `checker.png` is magenta and near-black, so
 the assertion is on what the file actually contains rather than on a length.
*>
fn void a_texture_from_a_file_reads_back_its_own_pixels() @test
{
	@with_js_gpu(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const tex = three.texture("test/fixtures/checker.png");
			const px = tex.read();
			let magenta = 0, dark = 0;
			for (let i = 0; i < px.length; i += 4) {
				if (px[i] > 200 && px[i + 2] > 200 && px[i + 1] < 60) magenta++;
				else if (px[i] < 60 && px[i + 1] < 60 && px[i + 2] < 60) dark++;
			}
			return { len: px.length, magenta, dark, w: tex.width, h: tex.height };
		`);
		defer result.free();
		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(!result.value.contains(`"magenta":0`),
			"the checkerboard's magenta should be in the bytes that came back: %s", result.value);
		test::@check(!result.value.contains(`"dark":0`),
			"and its dark squares: %s", result.value);
	};
}

<*
 Reading a texture leaves it in the layout the descriptor expects, proved by the
 validation layer rather than by a picture.

 **A picture does not catch this**, and that was established by trying it. The
 first version of this check read the texture and then rendered again, asserting
 the checkerboard was still on screen. Deleting the return-leg barrier from
 `Texture.read_pixels` left that check green: this driver samples an image in
 `TRANSFER_SRC_OPTIMAL` and produces the same frame, so the bug is invisible to
 every pixel assertion available. It is still undefined behaviour, and a driver
 that took the spec literally would produce garbage or nothing.

 That is the same situation `render/pass.c3` records about pushing 64 bytes into
 a 60-byte range — "pixel-identical either way on this driver, so no test here
 catches it and only `--validate` does" — and it has the same answer. So this
 arms the sink, does the read, draws, and requires the layer to have said
 nothing.

 Skipped when the Khronos layer is not installed, like the eleven other checks
 that need it, because a machine with no Vulkan SDK must still run the suite —
 and a check that silently passes without executing is `plan.md` §11's
 unexercised regression test.
*>
fn void reading_a_texture_leaves_it_in_the_layout_it_was_found_in() @test
{
	vk::Instance instance = three::create_instance(true, headless: true)!!;
	defer instance.free();

	three::Renderer renderer;
	renderer.init(instance, (vk::SurfaceKHR)null, W, H, validate: true)!!;
	defer renderer.free();

	if (!renderer.gpu.validation) return;

	renderer.pass.init(&renderer.gpu, &renderer.target)!!;
	three::Assets* assets = &renderer.pass.assets;
	three::Scene* scene = &renderer.pass.scene;

	int texture = assets.load_texture_file(&renderer.gpu, CHECKER)!!;
	uint material = renderer.pass.create_texture_material(texture)!!;

	three::AssetId plane = assets.primitive(&renderer.gpu, three::plane_shape(2, 2))!!;
	three::NodeId node = scene.add_mesh(plane, 0);
	scene.set_material(node, material);
	renderer.pass.frame_camera();

	// One frame before the read, so anything the layer objects to afterwards is
	// the read's doing and not the setup's.
	image::Image warmup = renderer.capture()!!;
	warmup.free();

	renderer.gpu.begin_capture();

	three::Texture* tex = assets.texture_at(texture);
	char[] pixels = mem::new_array(char, (sz)tex.width * tex.height * 4);
	defer free(pixels);
	tex.read_pixels(&renderer.gpu, pixels)!!;

	image::Image after = renderer.capture()!!;
	defer after.free();

	String errors = renderer.gpu.sink.errors.str_view();
	renderer.gpu.end_capture();

	test::@check(errors.len == 0,
		"reading a texture and drawing with it again produced validation errors, which means the image was left in the wrong layout: %s",
		errors
	);
	test::@check(count_magenta(&after) > 100,
		"and the texture still draws, got %d magenta pixels", count_magenta(&after));
}

<*
 A destination too small is refused with both numbers in the message.

 The one mistake this API's shape makes easy: the caller supplies the buffer, so
 the caller can supply the wrong one. Writing past it would be a heap corruption
 inside the engine's own storage, which is the worst available failure.
*>
fn void a_read_into_too_small_a_buffer_is_refused() @test
{
	@with_js_gpu(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const tex = new three.DataTexture(new Uint8Array(16 * 16 * 4), 16, 16);
			try { tex.read(new Uint8Array(100)); return "accepted"; }
			catch (e) { return e.message; }
		`);
		defer result.free();
		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value.contains("1024") && result.value.contains("100"),
			"the refusal should name what was needed and what was given: %s", result.value);
	};
}

<*
 A disposed texture refuses to be read rather than reading whatever took its
 slot.

 The same rule every other handle in this API follows, and the reason it matters
 here specifically: the slot is reused, so the failure without this check is not
 an error but a *different picture*, which is the kind nobody investigates.
*>
fn void a_disposed_texture_cannot_be_read() @test
{
	@with_js_gpu(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const tex = new three.DataTexture(new Uint8Array(4), 1, 1);
			tex.dispose();
			try { tex.read(); return "accepted"; }
			catch (e) { return e.message; }
		`);
		defer result.free();
		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value.contains("disposed"),
			"a disposed texture should refuse to be read: %s", result.value);
	};
}

// ============================================================================
// Laying a texture across a surface
//
// Nothing scaled uvs, so a surface mapped its texture exactly once and texel
// density was a function of how big the mesh was. `examples/village` covered its
// ground with 484 separate plane meshes on a six-unit grid — one draw call
// between them, and 484 nodes — purely so one 128px grass image would not
// stretch across 132 world units. Every large flat surface in every scene would
// have done the same thing.
// ============================================================================

<*
 A repeat tiles the image, asserted by counting edges in the frame.

 **Not by reading a number back**, which is what a binding that stored the value
 and never pushed it would pass. A two-colour checkerboard on one plane has a
 fixed number of colour changes across the middle row of the rendered image; ask
 for four repeats and that count goes up several-fold. Counting transitions
 rather than pixels is what makes it robust to the plane's size on screen, to
 filtering, and to the light.
*>
fn void a_repeat_tiles_the_image_across_the_surface() @test
{
	uint once;
	uint four_times;

	@with_pass(; three::Renderer* renderer)
	{
		three::Assets* assets = &renderer.pass.assets;
		three::Scene* scene = &renderer.pass.scene;

		int texture = assets.load_texture_file(&renderer.gpu, CHECKER)!!;
		uint material = renderer.pass.create_texture_material(texture)!!;

		three::AssetId plane = assets.primitive(&renderer.gpu, three::plane_shape(2, 2))!!;
		three::NodeId node = scene.add_mesh(plane, 0);
		scene.set_material(node, material);
		renderer.pass.frame_camera();

		image::Image plain = renderer.capture()!!;
		defer plain.free();
		once = row_transitions(&plain);

		renderer.pass.set_material_uv(material, 4, 4, 0, 0)!!;

		image::Image tiled = renderer.capture()!!;
		defer tiled.free();
		four_times = row_transitions(&tiled);
	};

	test::@check(once > 0, "the checkerboard has edges to begin with, got %d transitions", once);
	test::@check(four_times > once * 2,
		"four repeats should multiply the edges across the middle row: %d at repeat 1, %d at repeat 4",
		once, four_times
	);
}

<*
 An offset moves the image without changing how much of it there is.

 The half a repeat check cannot catch: a binding that wrote the offset into the
 scale would change the tiling, and one that dropped the offset entirely would
 change nothing. So this requires the picture to *move* and the edge count to
 stay in the same neighbourhood.
*>
fn void an_offset_slides_the_image_without_rescaling_it() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Assets* assets = &renderer.pass.assets;
		three::Scene* scene = &renderer.pass.scene;

		int texture = assets.load_texture_file(&renderer.gpu, CHECKER)!!;
		uint material = renderer.pass.create_texture_material(texture)!!;

		three::AssetId plane = assets.primitive(&renderer.gpu, three::plane_shape(2, 2))!!;
		three::NodeId node = scene.add_mesh(plane, 0);
		scene.set_material(node, material);
		renderer.pass.frame_camera();

		image::Image before = renderer.capture()!!;
		defer before.free();
		uint edges_before = row_transitions(&before);

		// A third of a tile rather than a half. Half is the one shift a
		// symmetric checkerboard can absorb — every square lands where an
		// identically coloured one was, and the frame comes back byte-identical
		// while the binding is working perfectly. That is what the first version
		// of this check asserted, and it failed for the fixture's reason rather
		// than the code's.
		renderer.pass.set_material_uv(material, 1, 1, 0.333, 0)!!;

		image::Image after = renderer.capture()!!;
		defer after.free();
		uint edges_after = row_transitions(&after);

		// The whole frame rather than one pixel: "the image slid" is a claim
		// about the picture, and any single sample can happen to land on the same
		// colour after a shift.
		uint moved = pixels_that_differ(&before, &after);

		test::@check(moved > 500,
			"a third of a tile of offset should move the picture, and only %d pixels changed", moved);
		test::@check(edges_after > edges_before / 2 && edges_after < edges_before * 2,
			"and should not have rescaled it: %d edges became %d", edges_before, edges_after
		);
	};
}

<*
 A material with no transform is unchanged, which is what makes the zero-means-
 unset rule safe.

 `Material.uv_transform` is a struct field, so C3 zero-fills it wherever an
 initializer omits it — and a repeat of zero maps an entire surface onto one
 texel. Every material built before this feature existed is in that state. This
 is the check that says they still draw the way they always did.
*>
fn void a_material_that_was_never_given_a_transform_is_untouched() @test
{
	@with_js_gpu(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const tex = three.texture("test/fixtures/checker.png");
			const m = new three.MeshLambertMaterial({ map: tex });
			return { repeat: m.repeat, offset: m.offset };
		`);
		defer result.free();
		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value.contains(`"repeat":[1,1]`),
			"an untouched material repeats once, not zero times: %s", result.value);
		test::@check(result.value.contains(`"offset":[0,0]`),
			"and starts at the corner: %s", result.value);
	};
}

<*
 A repeat of zero is refused rather than collapsing the surface.

 It is never what anyone means, and it is exactly what an unset field looks
 like — so accepting it would make the two indistinguishable at the one place
 where telling them apart matters.
*>
fn void a_repeat_of_zero_is_refused() @test
{
	@with_js_gpu(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const m = new three.MeshLambertMaterial({});
			try { m.repeat = [0, 1]; return "accepted"; }
			catch (e) { return e.message; }
		`);
		defer result.free();
		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value.contains("cannot be zero"),
			"a zero repeat should be refused and say why: %s", result.value);
	};
}
