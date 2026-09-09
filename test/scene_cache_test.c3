module three_tests::scene_cache;

import three;
import three_tests::device;
import std::core::test;
import vk;
import image;

fn vk::Rect2D rect(int x, int y, uint width, uint height) => {
	.offset = { x, y }, .extent = { width, height }
};

fn void check_same(image::Image* cached, image::Image* full, String change)
{
	test::@check(cached.pixels.len == full.pixels.len);
	foreach (i, byte : cached.pixels)
	{
		test::@check(byte == full.pixels[i], "%s cached/full differ at byte %d: %d != %d",
			change, i, byte, full.pixels[i]);
	}
}

fn void moving_a_copy_dirties_its_old_and_new_bounds() @test
{
	SceneCache cache;
	defer cache.free();
	cache.begin({ 100, 80 }, 7);
	cache.observe(1, 10, rect(10, 10, 8, 8));
	(void)cache.finish();
	cache.begin({ 100, 80 }, 7);
	cache.observe(1, 11, rect(30, 20, 8, 8));
	vk::Rect2D dirty = cache.finish();
	test::@check(dirty.offset.x == 10);
	test::@check(dirty.offset.y == 10);
	test::@check(dirty.extent.width == 28);
	test::@check(dirty.extent.height == 18);
}

fn void a_missing_copy_erases_its_previous_bounds() @test
{
	SceneCache cache;
	defer cache.free();
	cache.begin({ 64, 64 }, 3);
	cache.observe(9, 1, rect(4, 5, 6, 7));
	(void)cache.finish();
	cache.begin({ 64, 64 }, 3);
	vk::Rect2D dirty = cache.finish();
	test::@check(three::scene_cache_same(dirty, rect(4, 5, 6, 7)));
}

fn void global_changes_invalidate_the_whole_attachment() @test
{
	SceneCache cache;
	defer cache.free();
	cache.begin({ 32, 24 }, 1);
	(void)cache.finish();
	cache.begin({ 32, 24 }, 2);
	test::@check(three::scene_cache_same(cache.finish(), rect(0, 0, 32, 24)));
}

fn void cached_movement_matches_a_forced_full_depth_prepass() @test
{
	three::Renderer* renderer = device::borrow(96, 72);
	defer device::release();
	three::JsRuntime runtime;
	runtime.open(&renderer.pass, renderer)!!;
	defer runtime.close();

	three::RunResult setup = runtime.run(`
		const scene = new three.Scene();
		scene.background = 0x182030;
		three.light.ambient = .35;
		three.light.shadow = true;
		const floor = new three.Mesh(new three.BoxGeometry(7, .2, 7),
			new three.MeshLambertMaterial({ color: 0x708060 }));
		floor.position.y = -1;
		scene.add(floor);
		globalThis.box = new three.Mesh(new three.BoxGeometry(1.6, 1.6, 1.6),
			new three.MeshLambertMaterial({ color: 0xd05030 }));
		scene.add(box);
		three.camera.target.set(0, 0, 0);
		three.camera.orbit(20, 12, 6);
	`);
	defer setup.free();
	test::@check(setup.ok, "cache scene built: %s", setup.error);

	// Establish preserved colour/depth, then move through the partial path while
	// the engine depth prepass remains enabled.
	renderer.capture()!!.free();
	three::RunResult moved = runtime.run(`box.position.x = .45;`);
	defer moved.free();
	test::@check(moved.ok, "box moved: %s", moved.error);
	image::Image cached = renderer.capture()!!;
	defer cached.free();

	renderer.scene_cache_disabled = true;
	image::Image full = renderer.capture()!!;
	defer full.free();
	check_same(&cached, &full, "movement and shadow");

	renderer.scene_cache_disabled = false;
	renderer.capture()!!.free();
	three::RunResult recolored = runtime.run(`box.color = 0x3090d0;`);
	defer recolored.free();
	test::@check(recolored.ok);
	image::Image cached_color = renderer.capture()!!;
	defer cached_color.free();
	renderer.scene_cache_disabled = true;
	image::Image full_color = renderer.capture()!!;
	defer full_color.free();
	check_same(&cached_color, &full_color, "material");

	renderer.scene_cache_disabled = false;
	renderer.capture()!!.free();
	three::RunResult removed = runtime.run(`box.visible = false;`);
	defer removed.free();
	test::@check(removed.ok);
	image::Image cached_removed = renderer.capture()!!;
	defer cached_removed.free();
	renderer.scene_cache_disabled = true;
	image::Image full_removed = renderer.capture()!!;
	defer full_removed.free();
	check_same(&cached_removed, &full_removed, "removal and old shadow");

	renderer.scene_cache_disabled = false;
	renderer.capture()!!.free();
	three::RunResult global = runtime.run(`three.camera.orbit(28, 16, 6); three.light.intensity = .7;`);
	defer global.free();
	test::@check(global.ok);
	image::Image cached_global = renderer.capture()!!;
	defer cached_global.free();
	renderer.scene_cache_disabled = true;
	image::Image full_global = renderer.capture()!!;
	defer full_global.free();
	check_same(&cached_global, &full_global, "camera and light");

	// Shader-side lighting modes live in the frame block rather than Lighting.
	// They must still invalidate every preserved scene pixel.
	renderer.scene_cache_disabled = false;
	renderer.capture()!!.free();
	ulong pixels_before = renderer.scene_cache_pixels;
	renderer.pass.area_reference = !renderer.pass.area_reference;
	renderer.capture()!!.free();
	test::@check(renderer.scene_cache_pixels - pixels_before == 96 * 72,
		"area-light mode change invalidates the full cached scene");
}
