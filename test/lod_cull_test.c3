<*
 Unit tests for precomputed volume scale in `normal_matrix`, subtree-scoped
 `CullVolume`, engine-level LOD bucketing/hysteresis, and their JS bindings.
*>
module three_tests::lod_cull;

import three;
import collision;
import std::core::test;
import std::math;
import std::math::vector;
import std::math::matrix;

fn bool close(float a, float b, float tol = 0.001f) => math::abs(a - b) < tol;

fn three::AssetId add_test_asset(
	three::Assets* assets,
	uint mesh_count,
	collision::Aabb3 bounds,
	bool has_skin = false
)
{
	uint index = (uint)assets.assets.len();
	three::Asset asset = {
		.bounds = bounds,
		.generation = 1,
		.alive = true,
	};
	asset.meshes.init(mem, mesh_count);
	for (uint i = 0; i < mesh_count; i++)
	{
		asset.meshes.push({
			.vertex_count = 24,
			.index_count = 36,
			.texture = three::NO_TEXTURE,
			.bounds = bounds,
			.has_skin = has_skin,
			.uploaded = true,
		});
	}
	assets.assets.push(asset);
	return { .index = index, .generation = 1 };
}

fn Matrix4f forward_vp(float fov_deg = 90.0f)
{
	three::Camera camera = {
		.target = { 0, 0, -10 },
		.distance = 10.0f,
		.yaw = 0.0f,
		.pitch = 0.0f,
		.fov = fov_deg,
		.near_plane = 0.01f,
		.far_plane = 1000.0f,
	};
	return camera.view_projection(1.0f);
}

fn void normal_matrix_packs_volume_scale_in_m15() @test
{
	Matrix4f ident = three::normal_matrix(matrix::IDENTITY4{float});
	test::@check(close(ident.m[15], 1.0f), "identity volume scale was %f, expected 1", ident.m[15]);

	Matrix4f rot = three::normal_matrix(matrix::IDENTITY4{float}.rotate_y(0.7f));
	test::@check(close(rot.m[15], 1.0f, 0.0001f), "rotation volume scale was %f, expected 1", rot.m[15]);

	Matrix4f uniform = three::normal_matrix(matrix::IDENTITY4{float}.scale({ 3.0f, 3.0f, 3.0f }));
	test::@check(close(uniform.m[15], 3.0f), "uniform 3x scale was %f, expected 3", uniform.m[15]);

	Matrix4f mirrored = three::normal_matrix(matrix::IDENTITY4{float}.scale({ -2.0f, 2.0f, 2.0f }));
	test::@check(close(mirrored.m[15], 2.0f), "mirrored 2x scale was %f, expected 2", mirrored.m[15]);

	Matrix4f nonuniform = three::normal_matrix(matrix::IDENTITY4{float}.scale({ 2.0f, 4.0f, 1.0f }));
	test::@check(close(nonuniform.m[15], 2.0f), "non-uniform (2,4,1) volume scale was %f, expected 2", nonuniform.m[15]);

	Matrix4f singular = three::normal_matrix(matrix::IDENTITY4{float}.scale({ 1.0f, 0.0f, 1.0f }));
	test::@check(close(singular.m[15], 1.0f), "singular fallback volume scale was %f, expected 1", singular.m[15]);
}

fn void cull_volume_cylinder_and_sphere_are_subtree_scoped() @test
{
	three::Assets assets;
	assets.init();
	defer assets.free(null);

	three::Scene scene;
	scene.init();
	scene.attach_assets(&assets);
	defer scene.free();

	collision::Aabb3 unit = { .min = { -0.5f, -0.5f, -0.5f }, .max = { 0.5f, 0.5f, 0.5f } };
	three::AssetId box = add_test_asset(&assets, 1, unit);

	three::NodeId map_root = scene.add_group(three::NO_NODE, "mapRoot");
	three::NodeId hud_root = scene.add_group(three::NO_NODE, "hudRoot");

	three::NodeId near_in    = scene.add_mesh(box, 0, map_root, "nearIn");
	three::NodeId far_out    = scene.add_mesh(box, 0, map_root, "farOut");
	three::NodeId high_out   = scene.add_mesh(box, 0, map_root, "highOut");
	three::NodeId exempt_far = scene.add_mesh(box, 0, map_root, "exemptFar");
	three::NodeId hud_far    = scene.add_mesh(box, 0, hud_root, "hudFar");

	scene.set_position(near_in, { 2, 0, 0 });
	scene.set_position(far_out, { 50, 0, 0 });
	scene.set_position(high_out, { 2, 40, 0 });
	scene.set_position(exempt_far, { 50, 0, 0 });
	scene.set_position(hud_far, { 50, 0, 0 });
	scene.set_cull_exempt(exempt_far, true);

	// Disable frustum culling and pass a wide light frustum so only CullVolume decides.
	scene.cull = false;
	Matrix4f vp = forward_vp();
	Matrix4f light_vp = matrix::ortho{float}(-200.0f, 200.0f, -200.0f, 200.0f, -200.0f, 200.0f);

	// Cylinder volume on mapRoot with cull_shadows = true: drops farOut (XZ) and highOut (Y slab),
	// preserves nearIn, exemptFar (opted out), and hudFar (sibling outside mapRoot).
	bool ok = scene.set_cull_volume(map_root, CYLINDER, { 0, 0, 0 }, 10.0f, false, true, -5.0f, 10.0f);
	test::@check(ok, "set_cull_volume failed");

	scene.update(&assets, vp, light_view_projection: &light_vp);
	test::@check(scene.instances.len() == 3, "cylinder cull left %d instances, expected 3", scene.instances.len());
	test::@check(scene.volume_culled == 2, "cylinder volume_culled was %d, expected 2", scene.volume_culled);
	test::@check(scene.culled == 2, "cylinder culled was %d, expected 2", scene.culled);
	test::@check(scene.buckets.len() == 1 && scene.buckets[0].visible == 3 && scene.buckets[0].count == 3,
		"expected 3 visible and 3 shadow instances in bucket");

	// stats() skips CullVolume for scene counts and reports last frame's volume_culled.
	three::SceneStats st = scene.stats(&assets);
	test::@check(st.instances == 5, "stats().instances was %d, expected 5", st.instances);
	test::@check(st.volume_culled_last_frame == 2, "stats().volume_culled_last_frame was %d, expected 2",
		st.volume_culled_last_frame);

	// With cull_shadows = false, rejected nodes drop from color (visible=3) but stay in shadow tail (count=5).
	scene.set_cull_volume(map_root, CYLINDER, { 0, 0, 0 }, 10.0f, false, false, -5.0f, 10.0f);
	scene.update(&assets, vp, light_view_projection: &light_vp);
	test::@check(scene.buckets.len() == 1 && scene.buckets[0].visible == 3 && scene.buckets[0].count == 5,
		"cull_shadows=false gave visible=%d count=%d, expected 3 and 5",
		scene.buckets[0].visible, scene.buckets[0].count);
	test::@check(scene.volume_culled == 2, "volume_culled was %d, expected 2", scene.volume_culled);

	// Sphere volume (3D radius): rejects both farOut and highOut.
	scene.set_cull_volume(map_root, SPHERE, { 0, 0, 0 }, 10.0f, false, true);
	scene.update(&assets, vp, light_view_projection: &light_vp);
	test::@check(scene.instances.len() == 3, "sphere cull left %d instances, expected 3", scene.instances.len());
	test::@check(scene.volume_culled == 2, "sphere volume_culled was %d, expected 2", scene.volume_culled);

	// Local-space sphere transforms center and scales radius with mapRoot.
	scene.set_position(map_root, { 100, 0, 0 });
	scene.set_scale(map_root, { 0.5f, 0.5f, 0.5f });
	scene.set_cull_volume(map_root, SPHERE, { 0, 0, 0 }, 10.0f, true, true);
	scene.update(&assets, vp, light_view_projection: &light_vp);
	test::@check(scene.instances.len() == 3, "local-space sphere left %d instances, expected 3", scene.instances.len());
	test::@check(scene.volume_culled == 2, "local-space volume_culled was %d, expected 2", scene.volume_culled);

	// Clearing restores all 5 nodes; killing the root cleans up its volume slot.
	scene.clear_cull_volume(map_root);
	test::@check(scene.cull_volume_count == 0, "clear_cull_volume left count %d", scene.cull_volume_count);
	scene.update(&assets, vp, light_view_projection: &light_vp);
	test::@check(scene.instances.len() == 5, "after clear, got %d instances, expected 5", scene.instances.len());

	scene.set_cull_volume(map_root, SPHERE, { 0, 0, 0 }, 10.0f);
	test::@check(scene.cull_volume_count == 1, "expected 1 active volume before remove");
	scene.remove(map_root);
	test::@check(scene.cull_volume_count == 0, "removing root left %d active volumes", scene.cull_volume_count);
}

fn void lod_switches_by_distance_scale_hysteresis_and_small_feature_cull() @test
{
	three::Assets assets;
	assets.init();
	defer assets.free(null);

	three::Scene scene;
	scene.init();
	scene.attach_assets(&assets);
	defer scene.free();

	collision::Aabb3 unit = { .min = { -0.5f, -0.5f, -0.5f }, .max = { 0.5f, 0.5f, 0.5f } };
	three::AssetId tree = add_test_asset(&assets, 3, unit);

	// Unsorted on purpose to verify descending threshold sorting in set_mesh_lods.
	three::LodEntry[3] levels = {
		{ .asset = three::NO_ASSET, .mesh = three::NO_MESH, .min_screen_h = 0.02f },
		{ .asset = tree, .mesh = 1, .min_screen_h = 0.20f },
		{ .asset = tree, .mesh = 2, .min_screen_h = 0.08f },
	};
	scene.set_mesh_lods(&assets, tree, 0, levels[..])!!;
	test::@check(assets.mesh(tree, 1).refs == 1 && assets.mesh(tree, 2).refs == 1,
		"set_mesh_lods must retain target LOD meshes");

	three::NodeId node = scene.add_mesh(tree, 0, three::NO_NODE, "tree");
	Matrix4f vp = forward_vp(90.0f);

	// Distance-based switching (r_world = sqrt(3)/2 ~= 0.866, proj_y = 1.0).
	scene.set_position(node, { 0, 0, -2.0f });
	scene.update(&assets, vp);
	test::@check(scene.buckets.len() == 1 && scene.buckets[0].mesh == 0,
		"close node expected LOD 0, got mesh %d", scene.buckets[0].mesh);

	scene.set_position(node, { 0, 0, -6.0f });
	scene.update(&assets, vp);
	test::@check(scene.buckets.len() == 1 && scene.buckets[0].mesh == 1,
		"mid node expected LOD 1, got mesh %d", scene.buckets[0].mesh);

	scene.set_position(node, { 0, 0, -15.0f });
	scene.update(&assets, vp);
	test::@check(scene.buckets.len() == 1 && scene.buckets[0].mesh == 2,
		"far node expected LOD 2, got mesh %d", scene.buckets[0].mesh);

	// Small-feature cull drops the node completely.
	scene.set_position(node, { 0, 0, -60.0f });
	scene.update(&assets, vp);
	test::@check(scene.buckets.len() == 0, "tiny node expected culled, got %d buckets", scene.buckets.len());
	test::@check(scene.culled == 1, "small-feature cull expected culled=1, got %d", scene.culled);

	// Scale-based switching (miniature zoom at close distance).
	scene.set_position(node, { 0, 0, -2.0f });
	scene.set_scale(node, { 0.1f, 0.1f, 0.1f });
	scene.update(&assets, vp);
	test::@check(scene.buckets.len() == 1 && scene.buckets[0].mesh == 2,
		"scaled-down close node expected LOD 2, got mesh %d", scene.buckets[0].mesh);

	scene.set_scale(node, { 1.0f, 1.0f, 1.0f });
	scene.update(&assets, vp);
	test::@check(scene.buckets.len() == 1 && scene.buckets[0].mesh == 0,
		"unscaled close node expected LOD 0, got mesh %d", scene.buckets[0].mesh);

	// ±8% hysteresis around threshold 0.20 (drop below 0.184, upgrade above 0.216).
	scene.set_position(node, { 0, 0, -4.4f }); // screen_h ~= 0.197: stays at LOD 0
	scene.update(&assets, vp);
	test::@check(scene.buckets.len() == 1 && scene.buckets[0].mesh == 0,
		"hysteresis should hold LOD 0 at screen_h ~0.197, got mesh %d", scene.buckets[0].mesh);

	scene.set_position(node, { 0, 0, -4.8f }); // screen_h ~= 0.181 < 0.184: drops to LOD 1
	scene.update(&assets, vp);
	test::@check(scene.buckets.len() == 1 && scene.buckets[0].mesh == 1,
		"expected drop to LOD 1 at screen_h ~0.181, got mesh %d", scene.buckets[0].mesh);

	scene.set_position(node, { 0, 0, -4.2f }); // screen_h ~= 0.207 < 0.216: stays at LOD 1
	scene.update(&assets, vp);
	test::@check(scene.buckets.len() == 1 && scene.buckets[0].mesh == 1,
		"hysteresis should hold LOD 1 at screen_h ~0.207, got mesh %d", scene.buckets[0].mesh);

	scene.set_position(node, { 0, 0, -3.8f }); // screen_h ~= 0.228 > 0.216: upgrades to LOD 0
	scene.update(&assets, vp);
	test::@check(scene.buckets.len() == 1 && scene.buckets[0].mesh == 0,
		"expected upgrade to LOD 0 at screen_h ~0.228, got mesh %d", scene.buckets[0].mesh);

	// lod_bias scales projected screen height.
	scene.set_position(node, { 0, 0, -2.0f });
	scene.set_lod_bias(0.3f);
	scene.update(&assets, vp);
	test::@check(scene.buckets.len() == 1 && scene.buckets[0].mesh == 1,
		"lod_bias=0.3 should select LOD 1, got mesh %d", scene.buckets[0].mesh);

	// Clearing LODs releases retained target refcounts symmetrically.
	scene.clear_mesh_lods(&assets, tree, 0);
	test::@check(assets.mesh(tree, 1).refs == 0 && assets.mesh(tree, 2).refs == 0,
		"clear_mesh_lods must release target LOD refcounts");
}

fn void lod_preserves_instancing_buckets() @test
{
	three::Assets assets;
	assets.init();
	defer assets.free(null);

	three::Scene scene;
	scene.init();
	scene.attach_assets(&assets);
	defer scene.free();

	collision::Aabb3 unit = { .min = { -0.5f, -0.5f, -0.5f }, .max = { 0.5f, 0.5f, 0.5f } };
	three::AssetId prop = add_test_asset(&assets, 2, unit);

	three::LodEntry[1] levels = { { .asset = prop, .mesh = 1, .min_screen_h = 0.25f } };
	scene.set_mesh_lods(&assets, prop, 0, levels[..])!!;

	// Interleave 10 near copies (LOD 0) and 10 far copies (LOD 1).
	for (uint i = 0; i < 10; i++)
	{
		three::NodeId near_copy = scene.add_mesh(prop, 0);
		scene.set_position(near_copy, { ((float)i - 4.5f) * 0.1f, 0, -2.0f });

		three::NodeId far_copy = scene.add_mesh(prop, 0);
		scene.set_position(far_copy, { ((float)i - 4.5f) * 0.2f, 0, -10.0f });
	}

	scene.update(&assets, forward_vp(90.0f));
	test::@check(scene.buckets.len() == 2, "10 near + 10 far copies made %d buckets, expected 2", scene.buckets.len());
	test::@check(scene.buckets[0].mesh == 0 && scene.buckets[0].count == 10,
		"bucket 0 had mesh=%d count=%d, expected mesh=0 count=10", scene.buckets[0].mesh, scene.buckets[0].count);
	test::@check(scene.buckets[1].mesh == 1 && scene.buckets[1].count == 10,
		"bucket 1 had mesh=%d count=%d, expected mesh=1 count=10", scene.buckets[1].mesh, scene.buckets[1].count);
	test::@check(scene.buckets[0].first == 0 && scene.buckets[1].first == 10,
		"bucket instance ranges are not contiguous");

	// Camera-free stats() still counts all 20 copies on their base mesh in 1 bucket.
	three::SceneStats st = scene.stats(&assets);
	test::@check(st.draw_calls == 1 && st.instances == 20,
		"stats() reported draw_calls=%d instances=%d, expected 1 and 20", st.draw_calls, st.instances);
}

fn void lod_validates_skinned_assets_and_releases_on_scene_free() @test
{
	three::Assets assets;
	assets.init();
	defer assets.free(null);

	collision::Aabb3 unit = { .min = { -0.5f, -0.5f, -0.5f }, .max = { 0.5f, 0.5f, 0.5f } };
	three::AssetId hero     = add_test_asset(&assets, 2, unit, true);
	three::AssetId other    = add_test_asset(&assets, 1, unit, true);
	three::AssetId impostor = add_test_asset(&assets, 1, unit, false);

	three::Scene scene;
	scene.init();
	scene.attach_assets(&assets);

	three::LodEntry[1] bad = { { .asset = other, .mesh = 0, .min_screen_h = 0.2f } };
	test::@error(scene.set_mesh_lods(&assets, hero, 0, bad[..]), three::LOD_SKIN_MISMATCH);

	// Same-asset skinned LOD + cross-asset unskinned impostor are both allowed.
	three::LodEntry[2] good = {
		{ .asset = hero, .mesh = 1, .min_screen_h = 0.2f },
		{ .asset = impostor, .mesh = 0, .min_screen_h = 0.05f },
	};
	scene.set_mesh_lods(&assets, hero, 0, good[..])!!;
	test::@check(assets.mesh(hero, 1).refs == 1 && assets.mesh(impostor, 0).refs == 1,
		"expected retained refs on both LOD meshes");

	scene.free();
	test::@check(assets.mesh(hero, 1).refs == 0 && assets.mesh(impostor, 0).refs == 0,
		"Scene.free() must release all retained LOD mesh refs");
}

fn void js_cull_volume_lod_bias_and_stats_bindings() @test
{
	three::MeshPass pass;
	pass.assets.init();
	pass.init_scenes();
	pass.camera = three::default_camera();
	defer pass.free_scenes();
	defer pass.assets.free(null);

	three::JsRuntime run;
	run.open(&pass)!!;
	defer run.close();

	three::RunResult res = run.run(`
		const scene = new three.Scene();
		const mapRoot = new three.Group();
		mapRoot.setCullVolume({ shape: 'cylinder', center: [1, 2], radius: 25, space: 'local', shadows: false, yMin: -4, yMax: 12 });
		const child = new three.Group();
		child.cullExempt = true;
		mapRoot.add(child);
		scene.add(mapRoot);
		scene.lodBias = 0.75;
		const bias = scene.lodBias;
		mapRoot.clearCullVolume();
		const s = three.stats();
		return {
			bias,
			cullExempt: child.cullExempt,
			hasDrawnCalls: typeof s.drawnCalls === 'number',
			hasDrawnInstances: typeof s.drawnInstances === 'number',
			hasDrawnTriangles: typeof s.drawnTriangles === 'number',
			hasVolumeCulled: typeof s.volumeCulled === 'number',
		};
	`);
	defer res.free();

	test::@check(res.ok, "JS bindings test failed: %s", res.error);
	test::@check(res.value.contains(`"bias":0.75`), "lodBias round-trip failed: %s", res.value);
	test::@check(res.value.contains(`"cullExempt":true`), "cullExempt round-trip failed: %s", res.value);
	test::@check(res.value.contains(`"hasDrawnCalls":true`) && res.value.contains(`"hasDrawnInstances":true`)
		&& res.value.contains(`"hasDrawnTriangles":true`) && res.value.contains(`"hasVolumeCulled":true`),
		"stats() missing drawn/volume fields: %s", res.value);
}
