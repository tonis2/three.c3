<*
 `game.md` G1/S5: what a glTF says about itself before anything uploads it.

 Pointed at `test/fixtures/`, which is a real directory with a real `.glb` in it
 and — usefully — a `.py` beside it, so the filter is tested by the fixture
 layout rather than by a mock of one.

 Every check here runs with no GPU and no device: reading a glTF's JSON is
 arithmetic over a parse, and that is the whole point of the feature.
*>
module three_tests::inventory;

import std::io;
import three;

const String FIXTURE_DIR = "test/fixtures";

fn void a_directory_is_described_without_being_loaded() @test
{
	three::Inventory? found = three::take_inventory(FIXTURE_DIR);
	if (catch found) { test::@check(false, "the fixture directory was read"); return; }
	defer found.free_entries();

	test::@check(found.len() == 1, "one glTF in test/fixtures (%d)", found.len());
	if (found.len() != 1) return;

	three::InventoryEntry* entry = &found[0];
	test::@check(entry.path == "textured.glb",
		"named relative to the root, which is what three.load wants (%s)", entry.path);
	test::@check(entry.meshes.len() == 2, "with both its meshes (%d)", entry.meshes.len());
	test::@check(entry.triangles == 4, "and four triangles across them (%d)", entry.triangles);
	test::@check(entry.nodes == 2, "and two nodes (%d)", entry.nodes);
	test::@check(entry.animations.len() == 0 && entry.skins == 0,
		"and nothing animated, which this fixture is not");
}

<*
 A mesh's own triangle count, not just the file's total.

 Worth its own check because the total would be right even if every primitive's
 count landed on the wrong mesh — a sum hides an off-by-one in the loop that
 builds it.
*>
fn void every_mesh_carries_its_own_count() @test
{
	three::Inventory? found = three::take_inventory(FIXTURE_DIR);
	if (catch found) { test::@check(false, "the fixture directory was read"); return; }
	defer found.free_entries();
	if (found.len() != 1) { test::@check(false, "one glTF in test/fixtures"); return; }

	uint summed = 0;
	foreach (&mesh : found[0].meshes)
	{
		test::@check(mesh.name.len > 0, "each mesh is named (%s)", mesh.name);
		test::@check(mesh.triangles == 2, "and carries its own two triangles (%d)", mesh.triangles);
		summed += mesh.triangles;
	}
	test::@check(summed == found[0].triangles,
		"and the parts add up to the whole (%d vs %d)", summed, found[0].triangles);
}

<*
 Bounds come out of the position accessor's `min`/`max`, which the glTF spec
 requires to be there — the one reason they are free rather than a buffer read.
*>
fn void the_bounds_are_read_from_the_json() @test
{
	three::Inventory? found = three::take_inventory(FIXTURE_DIR);
	if (catch found) { test::@check(false, "the fixture directory was read"); return; }
	defer found.free_entries();
	if (found.len() != 1) { test::@check(false, "one glTF in test/fixtures"); return; }

	three::InventoryEntry* entry = &found[0];
	test::@check(entry.has_bounds, "the fixture's positions carry min/max");
	if (!entry.has_bounds) return;

	// Two quads side by side: wider than tall, and flat in Z.
	float width = entry.bounds.max[0] - entry.bounds.min[0];
	float height = entry.bounds.max[1] - entry.bounds.min[1];
	test::@check(width > height,
		"and the pair is wider than it is tall (%.2f x %.2f)", width, height);
	test::@check(entry.bounds.max[2] - entry.bounds.min[2] == 0.0f,
		"and flat, being two quads in one plane (%.2f deep)",
		entry.bounds.max[2] - entry.bounds.min[2]);
}

<*
 Everything that is not a glTF is skipped, and a directory that is not there is
 a fault rather than an empty answer.

 The distinction matters for the same reason G1/S2's refusal does: "there is
 nothing here" and "there is no here" send someone to two different places.
*>
fn void only_gltf_files_are_listed() @test
{
	three::Inventory? found = three::take_inventory(FIXTURE_DIR);
	if (catch found) { test::@check(false, "the fixture directory was read"); return; }
	defer found.free_entries();

	// `make_textured.py` sits beside the fixture and must not appear.
	foreach (&entry : found)
	{
		test::@check(entry.path.ends_with(".glb") || entry.path.ends_with(".gltf"),
			"nothing but glTF is listed (%s)", entry.path);
	}

	three::Inventory? missing = three::take_inventory("test/fixtures/nowhere");
	if (try missing)
	{
		missing.free_entries();
		test::@check(false, "a directory that is not there answered with a list");
	}
}
