<*
 A placement list, and the loader that replays it — `three.level`.

	`c3c test --trust=full --test-noleak --test-filter three_tests::level`

 A `.glb` bakes geometry in; a level file names a piece and a transform per
 row instead, so the file stays readable after the kit is re-exported. What
 this suite checks is the two halves of that promise: a plain `load` is
 exactly what was saved (`a_level_round_trips_through_save_and_load`), and a
 row that carries a `snap` can be replayed against a kit that changed
 underneath it (`refit_moves_a_snapped_row_and_leaves_a_freehand_one`) while a
 freehand row never moves on its own. The rest are the invariants a replay in
 file order depends on: an `id` unique within the file, and a `snap.to` that
 only ever points backwards.

 The fixture is `test/fixtures/hierarchy.glb` — `pivot` (a group, its
 children `arm` and `tip` each carrying real geometry) and `loose`, the
 second root — copied into a scratch assets directory the way
 `shipping_test.c3` builds one for `three.writeText`, because
 `three.level.save`/`load` write and read through that same door.
*>
module three_tests::level;

import three;
import three_tests::device;
import vk;
import std::core::test;
import std::io::file;
import std::io::path;

const String TEST_ASSETS = "build/test-level-assets";
const String FIXTURE = "test/fixtures/hierarchy.glb";

<*
 A scratch assets directory holding a copy of `hierarchy.glb`, and a runtime
 with a headless device rooted at it — `three.load` and `asset.node` both
 refuse without a device, so a suite that only ever measures still needs one.
*>
macro @with_level(; @body(three::JsRuntime* run))
{
	(void)path::rmtree((Path)TEST_ASSETS);
	defer (void)path::rmtree((Path)TEST_ASSETS);

	path::mkdir((Path)TEST_ASSETS, recursive: true)!!;
	@pool()
	{
		char[] bytes = file::load_temp(FIXTURE)!!;
		file::save(string::tformat("%s/hierarchy.glb", TEST_ASSETS), bytes)!!;
	};

	three::Renderer* renderer = device::borrow(200, 150);
	defer device::release();

	three::JsRuntime runtime;
	runtime.open(&renderer.pass, renderer)!!;
	defer runtime.close();
	runtime.set_assets_root(TEST_ASSETS);

	@body(&runtime);
}

// ============================================================================
// 1. A round trip
// ============================================================================

fn void a_level_round_trips_through_save_and_load() @test
{
	@with_level(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			const level = three.level.create('hierarchy.glb');
			level.parent = scene;

			const loose = level.add({ id: 'loose_1', piece: 'loose', position: [0, 0, 0], rotation: [0, 0, 0] });
			const pivot = level.add(
				{ id: 'pivot_1', piece: 'pivot', snap: { to: 'loose_1', side: '+x' } },
				{ refit: true });

			const savedLoose = loose.position.toArray();
			const savedPivot = pivot.position.toArray();

			three.level.save('level.json', level);
			const savedRows = JSON.stringify(level.rows);

			const scene2 = new three.Scene();
			const level2 = three.level.load('level.json', scene2);

			const loose2 = scene2.getObjectByName('loose_1');
			const pivot2 = scene2.getObjectByName('pivot_1');

			return {
				kitOk: level2.kit === 'hierarchy.glb',
				hasLoose: loose2 !== null && level2.objects.get('loose_1') === loose2,
				hasPivot: pivot2 !== null && level2.objects.get('pivot_1') === pivot2,
				loosePosOk: JSON.stringify(loose2.position.toArray()) === JSON.stringify(savedLoose),
				pivotPosOk: JSON.stringify(pivot2.position.toArray()) === JSON.stringify(savedPivot),
				rowsOk: JSON.stringify(level2.rows) === savedRows,
			};
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value.contains(`"kitOk":true`), "the kit path round-tripped, got '%s'", result.value);
		test::@check(result.value.contains(`"hasLoose":true`),
			"the freehand row's object is under the parent by its id, got '%s'", result.value);
		test::@check(result.value.contains(`"hasPivot":true`),
			"the snapped row's object is under the parent by its id, got '%s'", result.value);
		test::@check(result.value.contains(`"loosePosOk":true`),
			"the freehand row loaded back at its saved position, got '%s'", result.value);
		test::@check(result.value.contains(`"pivotPosOk":true`),
			"the snapped row loaded back at its saved position, got '%s'", result.value);
		test::@check(result.value.contains(`"rowsOk":true`),
			"the loaded rows equal the saved ones, got '%s'", result.value);
	};
}

// ============================================================================
// 2. refit
// ============================================================================

fn void refit_moves_a_snapped_row_and_leaves_a_freehand_one() @test
{
	@with_level(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			const level = three.level.create('hierarchy.glb');
			level.parent = scene;

			level.add({ id: 'loose_1', piece: 'loose', position: [0, 0, 0], rotation: [0, 0, 0] });
			const pivot = level.add(
				{ id: 'pivot_1', piece: 'pivot', snap: { to: 'loose_1', side: '+x' } },
				{ refit: true });
			const loose = level.objects.get('loose_1');

			const beforePivot = pivot.position.toArray();

			loose.position.x += 2;
			level.refit();

			return {
				loosePosOk: Math.abs(loose.position.x - 2) < 1e-4
					&& loose.position.y === 0 && loose.position.z === 0,
				pivotFollowedOk: Math.abs((pivot.position.x - beforePivot[0]) - 2) < 1e-4,
				pivotOtherAxesUnchanged: pivot.position.y === beforePivot[1] && pivot.position.z === beforePivot[2],
			};
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value.contains(`"loosePosOk":true`),
			"the freehand row moved by exactly the direct write, got '%s'", result.value);
		test::@check(result.value.contains(`"pivotFollowedOk":true`),
			"the snapped row followed the target by the same +2, got '%s'", result.value);
		test::@check(result.value.contains(`"pivotOtherAxesUnchanged":true`),
			"refit only replays the axes the snap names, got '%s'", result.value);
	};
}

// ============================================================================
// 3. What a replay in file order depends on
// ============================================================================

fn void a_snap_pointing_forward_throws_naming_the_target() @test
{
	@with_level(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			const level = three.level.create('hierarchy.glb');
			level.parent = scene;
			level.add({ id: 'pivot_1', piece: 'pivot', snap: { to: 'loose_1', side: '+x' } });
		`);
		defer result.free();

		test::@check(!result.ok, "a snap.to naming a row not yet placed should throw");
		test::@check(result.error.contains("loose_1"),
			"the error should name the row the snap could not find, got '%s'", result.error);
	};
}

fn void a_duplicate_id_throws_naming_it() @test
{
	@with_level(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			const level = three.level.create('hierarchy.glb');
			level.parent = scene;
			level.add({ id: 'loose_1', piece: 'loose', position: [0, 0, 0], rotation: [0, 0, 0] });
			level.add({ id: 'loose_1', piece: 'loose', position: [1, 0, 0], rotation: [0, 0, 0] });
		`);
		defer result.free();

		test::@check(!result.ok, "adding the same id twice should throw");
		test::@check(result.error.contains("loose_1"),
			"the error should name the id that was used twice, got '%s'", result.error);
	};
}

fn void an_unknown_piece_throws_naming_it_and_the_file() @test
{
	@with_level(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			const level = three.level.create('hierarchy.glb');
			level.parent = scene;
			level.add({ id: 'x_1', piece: 'no_such_piece', position: [0, 0, 0], rotation: [0, 0, 0] });
		`);
		defer result.free();

		test::@check(!result.ok, "a piece the kit does not have should throw");
		test::@check(result.error.contains("TypeError"), "it should be a TypeError, got '%s'", result.error);
		test::@check(result.error.contains("no_such_piece"),
			"the error should name the piece that was not found, got '%s'", result.error);
		test::@check(result.error.contains("hierarchy.glb"),
			"the error should name the file, got '%s'", result.error);
		test::@check(result.error.contains("pivot"),
			"the error should list the node names the file does have, got '%s'", result.error);
	};
}

fn void removing_a_row_a_later_snap_points_at_throws() @test
{
	@with_level(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			const level = three.level.create('hierarchy.glb');
			level.parent = scene;
			level.add({ id: 'loose_1', piece: 'loose', position: [0, 0, 0], rotation: [0, 0, 0] });
			level.add({ id: 'pivot_1', piece: 'pivot', snap: { to: 'loose_1', side: '+x' } }, { refit: true });
			level.remove('loose_1');
		`);
		defer result.free();

		test::@check(!result.ok, "removing a row a later snap points at should throw");
		test::@check(result.error.contains("loose_1") && result.error.contains("pivot_1"),
			"the error should name the removed row and the row whose snap points at it, got '%s'", result.error);
	};
}

// ============================================================================
// 4. A missing file
// ============================================================================

fn void loading_a_missing_level_returns_null() @test
{
	@with_level(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			return three.level.load('no-such-level.json', scene) === null;
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == "true", "a missing level file should load as null, got '%s'", result.value);
	};
}

// ============================================================================
// 5. Unknown fields
// ============================================================================

fn void unknown_row_fields_survive_a_round_trip() @test
{
	@with_level(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			const level = three.level.create('hierarchy.glb');
			level.parent = scene;
			level.add({
				id: 'loose_1', piece: 'loose', position: [0, 0, 0], rotation: [0, 0, 0], locked: true,
			});
			three.level.save('level.json', level);

			const scene2 = new three.Scene();
			const level2 = three.level.load('level.json', scene2);
			return level2.rows[0].locked === true;
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == "true",
			"a field the loader does not know should survive a save/load round trip, got '%s'", result.value);
	};
}
