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

<*
 A frame the camera moved on skips the shadow damage, and the frames after it
 still match a full redraw.

 A moved camera makes the whole target dirty, so `scene_cache_update` no longer
 projects every receiver through every refreshed shadow view to find damage
 inside it — that was forty milliseconds a frame of a third-person walk at -O0.
 What it must not do is keep the per-view reuse it skipped: the static shadow
 damage is keyed under the old camera, and trusting it on the first still frame
 would leave shadow pixels unrepainted. So the check is the sequence that would
 expose that — the camera moves while the shadow caster moves, then stops while
 the caster goes on moving — compared with a forced full redraw at each step.
*>
fn void a_moving_camera_skips_shadow_damage_and_still_matches() @test
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
		floor.static = true;
		scene.add(floor);
		globalThis.box = new three.Mesh(new three.BoxGeometry(1.2, 1.2, 1.2),
			new three.MeshLambertMaterial({ color: 0xd05030 }));
		scene.add(box);
		three.camera.target.set(0, 0, 0);
		three.camera.orbit(20, 18, 6);
	`);
	defer setup.free();
	test::@check(setup.ok, "cache scene built: %s", setup.error);
	renderer.capture()!!.free();
	renderer.capture()!!.free();

	// The caster moves under a still camera first, which is what schedules a
	// shadow view and fills its static damage — without this the check below
	// would pass against a cache that never had anything to drop.
	three::RunResult first = runtime.run(`box.position.x = .2;`);
	defer first.free();
	test::@check(first.ok, "moved: %s", first.error);
	renderer.capture()!!.free();
	bool kept = false;
	foreach (valid : renderer.scene_cache.static_shadow_valid) kept = kept || valid;
	test::@check(kept, "a caster moving under a still camera filled no shadow view's static damage");

	// The camera and the caster both move: the frame is redrawn whole, and the
	// per-view static damage is dropped rather than kept under the old camera.
	three::RunResult moving = runtime.run(`three.camera.orbit(26, 18, 6); box.position.x = .4;`);
	defer moving.free();
	test::@check(moving.ok, "moved: %s", moving.error);
	renderer.capture()!!.free();
	foreach (i, valid : renderer.scene_cache.static_shadow_valid)
	{
		test::@check(!valid, "shadow view %d kept its static damage through a camera move", i);
	}

	// Then the camera stops and the caster goes on: the partial path again, and
	// it has to agree with a full redraw pixel for pixel.
	three::RunResult still = runtime.run(`box.position.x = .8;`);
	defer still.free();
	test::@check(still.ok, "moved again: %s", still.error);
	image::Image cached = renderer.capture()!!;
	defer cached.free();
	renderer.scene_cache_disabled = true;
	image::Image full = renderer.capture()!!;
	defer full.free();
	check_same(&cached, &full, "the first still frame after a camera move");
}
