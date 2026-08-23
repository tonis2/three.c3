<*
 `game.md` G1/S5: what a glTF says about itself before anything uploads it.

 Pointed at `test/fixtures/`, which is a real directory with real `.glb`s in it
 and — usefully — `.py` files beside them, so the filter is tested by the fixture
 layout rather than by a mock of one.

 There are three glTFs there, which matters more than it looks. A directory
 holding exactly one file cannot tell a working listing apart from a function
 that describes whatever it finds first, and it lets every check index `found[0]`
 and call that a test. So nothing here indexes: each check names the file it is
 about and looks it up, which is also what a game does with `three.inventory()`.

 Every check here runs with no GPU and no device: reading a glTF's JSON is
 arithmetic over a parse, and that is the whole point of the feature.
*>
module three_tests::inventory;

import std::io;
import three;

const String FIXTURE_DIR = "test/fixtures";

<*
 The entry for one fixture, or a failed check saying which one is missing.

 A null return rather than an assert so a caller can bail cleanly: a missing
 fixture is one failure, not one per line that would have read it.
*>
fn three::InventoryEntry* named(three::Inventory* found, String path)
{
	foreach (&entry : *found)
	{
		if (entry.path == path) return entry;
	}
	test::@check(false, "%s is not in the inventory of %s", path, FIXTURE_DIR);
	return null;
}

fn void a_directory_is_described_without_being_loaded() @test
{
	three::Inventory? found = three::take_inventory(FIXTURE_DIR);
	if (catch found) { test::@check(false, "the fixture directory was read"); return; }
	defer found.free_entries();

	test::@check(found.len() == 5, "every glTF in test/fixtures (%d)", found.len());

	three::InventoryEntry* entry = named(&found, "textured.glb");
	if (entry == null) return;

	test::@check(entry.meshes.len() == 2, "with both its meshes (%d)", entry.meshes.len());
	test::@check(entry.triangles == 4, "and four triangles across them (%d)", entry.triangles);
	test::@check(entry.nodes == 2, "and two nodes (%d)", entry.nodes);
	test::@check(entry.animations.len() == 0 && entry.skins == 0,
		"and nothing animated, which this fixture is not");

	// The other side of that: `skins` had no fixture that reported anything until
	// skinning landed, so the field was only ever checked against zero.
	three::InventoryEntry* rigged = named(&found, "skinned.glb");
	if (rigged == null) return;

	test::@check(rigged.skins == 1, "skinned.glb reports its skin (%d)", rigged.skins);
	test::@check(rigged.animations.len() == 2, "and both its clips (%d)", rigged.animations.len());

	// The path is what `three.load` is handed straight back, so it is relative
	// to the root that was scanned and not to the process's directory.
	three::InventoryEntry* shared = named(&found, "shared_material.glb");
	if (shared == null) return;
	test::@check(shared.meshes.len() == 4, "and the kit fixture's four pieces (%d)", shared.meshes.len());

	// Counted from the JSON, so a fixture whose geometry is positioned entirely
	// by its nodes is described without any of it being read.
	three::InventoryEntry* tree = named(&found, "hierarchy.glb");
	if (tree == null) return;
	test::@check(tree.nodes == 4, "and the hierarchy fixture's four nodes (%d)", tree.nodes);
	test::@check(tree.triangles == 8, "and its eight triangles across four primitives (%d)", tree.triangles);
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

	three::InventoryEntry* entry = named(&found, "textured.glb");
	if (entry == null) return;

	uint summed = 0;
	foreach (&mesh : entry.meshes)
	{
		test::@check(mesh.name.len > 0, "each mesh is named (%s)", mesh.name);
		test::@check(mesh.triangles == 2, "and carries its own two triangles (%d)", mesh.triangles);
		summed += mesh.triangles;
	}
	test::@check(summed == entry.triangles,
		"and the parts add up to the whole (%d vs %d)", summed, entry.triangles);
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

	three::InventoryEntry* entry = named(&found, "textured.glb");
	if (entry == null) return;

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

	// The `make_*.py` generators sit beside the fixtures and must not appear.
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
