module three_tests::nav_profile;

import three;
import three_tests::device;
import std::core::test;
import std::math::vector;

macro @with_gpu_js(; @body(three::JsRuntime* run))
{
	three::Renderer* renderer = device::borrow(160, 120);
	defer device::release();
	three::JsRuntime runtime;
	runtime.open(&renderer.pass, renderer)!!;
	defer runtime.close();
	@body(&runtime);
}

fn three::AssetNavigationProfile profile_with(int[] cells, float step)
{
	return {
		.settings = { .cell = 0.5, .agent_radius = 0.3, .agent_height = 1.66,
			.step_height = step, .slope_limit = 54 },
		.origin = { 0, 0, 0 }, .nx = 7, .ny = 7, .nz = 7, .cells = cells,
		.components = 1, .largest_component = (uint)cells.len,
	};
}

fn void embedded_links_respect_step_height_and_corners() @test
{
	int[2] diagonal_cells = { 114, 164 };
	three::AssetNavigationProfile diagonal = profile_with(diagonal_cells[0..1], 0.5);
	three::Scene scene;
	test::@check(scene.load_nav(&diagonal), "diagonal fixture loaded");
	test::@check(scene.nav.components == 2, "a diagonal cannot cut an empty corner");
	scene.drop_nav();

	int[4] mismatched_corner_cells = { 108, 114, 156, 178 };
	three::AssetNavigationProfile mismatched = profile_with(mismatched_corner_cells[0..3], 1.0);
	test::@check(scene.load_nav(&mismatched), "mismatched-height corner fixture loaded");
	test::@check(scene.nav.components == 2,
		"side cells too low to reach the target cannot justify its diagonal");
	scene.drop_nav();

	int[3] stepped_corner_cells = { 114, 122, 178 };
	three::AssetNavigationProfile stepped = profile_with(stepped_corner_cells[0..2], 1.0);
	test::@check(scene.load_nav(&stepped), "stepped diagonal fixture loaded");
	test::@check(scene.nav.components == 1,
		"a diagonal connects when one two-cardinal route climbs through a side cell");
	scene.drop_nav();

	int[2] step_cells = { 114, 129 };
	three::AssetNavigationProfile low = profile_with(step_cells[0..1], 0.75);
	test::@check(scene.load_nav(&low), "low-step fixture loaded");
	test::@check(scene.nav.components == 2, "a one-metre rise exceeds a 0.75 metre step");
	scene.drop_nav();

	three::AssetNavigationProfile high = profile_with(step_cells[0..1], 1.0);
	test::@check(scene.load_nav(&high), "high-step fixture loaded");
	test::@check(scene.nav.components == 1, "the same rise connects when the profile permits it");
	scene.drop_nav();

	int[2] stacked_cells = { 114, 121 };
	three::AssetNavigationProfile stacked = profile_with(stacked_cells[0..1], 1.0);
	test::@check(scene.load_nav(&stacked), "stacked-floor fixture loaded");
	test::@check(scene.nav.components == 2, "floors directly above one another have no walkable edge");
	scene.drop_nav();
}

fn void a_long_turning_field_converges_completely() @test
{
	const int ROWS = 140;
	const int WIDTH = 7;
	const int COUNT = ROWS * WIDTH + ROWS - 1;
	int[COUNT] cells;
	int at = 0;
	int nx = 11;
	int ny = 7;
	int plane = nx * ny;
	for (int row = 0; row < ROWS; row++)
	{
		int z = 2 + row * 2;
		for (int x = 2; x < 2 + WIDTH; x++) cells[at++] = z * plane + 3 * nx + x;
		if (row + 1 < ROWS)
		{
			int connector_x = row % 2 == 0 ? 2 + WIDTH - 1 : 2;
			cells[at++] = (z + 1) * plane + 3 * nx + connector_x;
		}
	}

	three::AssetNavigationProfile profile = {
		.settings = { .cell = 0.5, .agent_radius = 0.3, .agent_height = 1.66,
			.step_height = 0.5, .slope_limit = 54 },
		.origin = { 0, 0, 0 }, .nx = nx, .ny = ny, .nz = ROWS * 2 + 5,
		.cells = cells[0..COUNT - 1],
	};
	three::Scene scene;
	test::@check(scene.load_nav(&profile), "long snake fixture loaded");
	defer scene.drop_nav();

	float[COUNT] field;
	int goal_voxel = cells[0];
	int far_voxel = cells[COUNT - 1];
	vector::Vec3[1] goals = { scene.nav.foot_of(goal_voxel) };
	test::@check(scene.nav.solve(goals[..], field[..]), "long snake field seeded");
	vector::Vec3[COUNT] raw;
	test::@check(scene.nav.walk(field[..], scene.nav.foot_of(far_voxel), raw[..]) > 0,
		"a route requiring more than 64 alternating sweeps reaches its goal");
}

fn void an_embedded_profile_replaces_the_scene_grid() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const asset = three.load('test/fixtures/navigation_profile.gltf');
			const scene = new three.Scene();
			const stats = scene.nav.load(asset);
			const field = scene.nav.field([2.25, 1, 1.25]);
			const path = scene.nav.path([1.25, 1, 1.25], [2.25, 1, 1.25]);
			const wall = new three.Mesh(new three.BoxGeometry(0.2, 3, 3));
			wall.position.set(1.75, 1.5, 1.25);
			scene.add(wall);
			const blocked = scene.nav.path([1.25, 1, 1.25], [2.25, 1, 1.25]);
			const answer = [stats.cell, stats.radius, stats.height, stats.stepHeight, stats.slope,
				stats.walkable, stats.components, stats.largest, stats.profile, stats.sourceHash,
				field.reaches([1.25, 1, 1.25]), path.length, blocked.length];
			field.dispose();
			scene.nav.clear();
			three.unloadUnused();
			return answer;
		`);
		defer result.free();
		test::@check(result.ok, "embedded navigation loaded: %s", result.error);
		test::@check(result.value == "[0.5,0.30000001192092896,1.659999966621399,0.41999998688697815,54,3,1,3,\"default\",\"fixture\",true,2,0]",
			"profile settings, field and path survived load; got %s", result.value);
	};
}

fn void malformed_optional_profiles_do_not_poison_the_asset() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const asset = three.load('test/fixtures/navigation_malformed.gltf');
			const scene = new three.Scene();
			const loaded = scene.nav.load(asset);
			const meshes = asset.meshes.length;
			three.unloadUnused();
			return [meshes, loaded];
		`);
		defer result.free();
		test::@check(result.ok, "malformed optional navigation left the asset loadable: %s", result.error);
		test::@check(result.value == "[1,null]", "all malformed profiles were skipped; got %s", result.value);
	};
}

fn void a_waypoint_limit_never_returns_a_partial_path() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			const floor = new three.Mesh(new three.BoxGeometry(30, 1, 30));
			floor.position.y = -0.5;
			scene.add(floor);
			const wall = new three.Mesh(new three.BoxGeometry(1, 4, 20));
			wall.position.set(0, 2, -3);
			scene.add(wall);
			scene.nav.bake({ cell: 0.5, radius: 0.3, height: 1.8 });
			const full = scene.nav.path([-10, 0, 0], [10, 0, 0]);
			const limited = scene.nav.path([-10, 0, 0], [10, 0, 0], { limit: 2 });
			return [full.length > 2, limited.length];
		`);
		defer result.free();
		test::@check(result.ok, "limited navigation path ran: %s", result.error);
		test::@check(result.value == "[true,0]",
			"an insufficient waypoint buffer returns no route, never a prefix; got %s", result.value);
	};
}

fn void navigation_options_reject_non_finite_and_pathological_numbers() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			const bad = [
				() => scene.nav.bake({ radius: Infinity }),
				() => scene.nav.bake({ height: NaN }),
				() => scene.nav.bake({ slope: 90 }),
				() => scene.nav.bake({ height: 1, stepHeight: 2 }),
				() => scene.nav.bake({ bounds: { min: [1, 0, 0], max: [0, 1, 1] } }),
				() => scene.nav.path([0, 0, 0], [1, 0, 0], { limit: Infinity }),
				() => scene.nav.path([0, 0, 0], [1, 0, 0], { limit: 65537 }),
			];
			return bad.map(call => { try { call(); return false; } catch (error) { return error instanceof RangeError; } });
		`);
		defer result.free();
		test::@check(result.ok, "navigation option validation ran: %s", result.error);
		test::@check(result.value == "[true,true,true,true,true,true,true]",
			"every invalid numeric option was rejected; got %s", result.value);
	};
}
