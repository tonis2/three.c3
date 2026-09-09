<*
 The static light cache — `three.lights.bake()`, `render/lightmap.c3`.

 One scene of generated geometry, three receivers and two baked lights, and the
 question is always the same one: does moving a light's diffuse into a texture
 change the picture. It must not, on the receiver that has a tile; and on the two
 that do not it must not change *anything at all*, because a light the cache
 cannot carry there is still a light.

 The eligibility half is checked through the same scene rather than by asking the
 measurement directly: a `PlaneGeometry` unwraps once into the square and a
 `BoxGeometry` puts all six faces on top of each other, so one is a receiver and
 the other is skipped without a fixture saying so.
*>
module three_tests::bake;

import three;
import three_tests::device;
import image;
import std::core::test;
import std::io::file;
import std::io::path;
import std::math;

const uint W = 240;
const uint H = 180;

// The save verbs write into the assets directory, and a test may not write into
// the repo. Under `build/`, which is gitignored, so `rm -rf build` is the whole
// of the cleanup a failed run needs.
const String TEST_BAKE_ASSETS = "build/test-bake";

macro @with_assets(#run; @body)
{
	(void)path::rmtree((Path)TEST_BAKE_ASSETS);
	path::mkdir((Path)TEST_BAKE_ASSETS, recursive: true)!!;
	defer (void)path::rmtree((Path)TEST_BAKE_ASSETS);
	#run.set_assets_root(TEST_BAKE_ASSETS);
	@body();
}

macro @with_js(; @body(three::JsRuntime* run, three::Renderer* renderer))
{
	three::Renderer* renderer = device::borrow(W, H);
	defer device::release();

	three::JsRuntime runtime;
	runtime.open(&renderer.pass, renderer)!!;
	defer runtime.close();

	@body(&runtime, renderer);
}

fn char[3] pixel_at(image::Image* img, uint x, uint y)
{
	sz bpp = img.bytes_per_pixel();
	sz at = ((sz)y * (sz)img.width + (sz)x) * bpp;
	return { img.pixels[at], img.pixels[at + 1], img.pixels[at + 2] };
}

fn uint luma_at(image::Image* img, uint x, uint y)
{
	char[3] rgb = pixel_at(img, x, y);
	return (uint)rgb[0] + (uint)rgb[1] + (uint)rgb[2];
}

// The largest single-channel disagreement between two frames, and how many
// channels disagree by more than a threshold.
fn uint worst_channel(image::Image* a, image::Image* b)
{
	if (a.width != b.width || a.height != b.height) return 255;
	uint worst = 0;
	foreach (i, byte : a.pixels)
	{
		if (i % 4 == 3) continue;
		uint delta = byte > b.pixels[i] ? (uint)(byte - b.pixels[i]) : (uint)(b.pixels[i] - byte);
		if (delta > worst) worst = delta;
	}
	return worst;
}

<*
 A plane whose uvs are a plain unwrap, a box whose six faces share one square,
 and a box that is not static — plus a point light and a disk light, both close
 enough that everything is lit and none of it is saturated.

 The camera looks straight down so the plane fills the frame and the two boxes
 are separated left and right, which is what lets one pixel be about one receiver.
*>
const String SCENE = `
	const scene = new three.Scene();
	three.scene = scene;
	three.light.intensity = 0;
	three.lights.shadow = { enabled: true, size: 512, maxLocal: 8 };
	const mat = new three.MeshLambertMaterial({ color: 0xffffff });

	const plane = new three.Mesh(new three.PlaneGeometry(4, 4), mat);
	plane.rotation.x = -Math.PI / 2;
	scene.add(plane);
	plane.static = true;

	const box = new three.Mesh(new three.BoxGeometry(1, 1, 1), mat);
	box.position.set(1.5, 0.5, 0);
	scene.add(box);
	box.static = true;

	const dyn = new three.Mesh(new three.BoxGeometry(1, 1, 1), mat);
	dyn.position.set(-1.5, 0.5, 0);
	scene.add(dyn);

	globalThis.point = three.lights.add(
		{ position: [0, 2, 0], range: 12, color: 0xffffff, intensity: 6 });
	globalThis.disk = three.lights.add({ position: [0, 2.5, 2], right: [1, 0, 0], up: [0, 0, 1],
		width: 1.5, height: 1.5, shape: 'disk', color: 0xffddbb, intensity: 4 });

	three.camera.lookAt(0, 0, 0);
	three.camera.orbit(0, 45, 9);
`;

<*
 `light.baked` is off by default, survives a shadow write, and reads back.

 The second half is the one worth pinning: the flag and the per-light shadow
 settings share `Light.meta.w`, so a script setting one must not clear the other.
*>
fn void a_light_is_not_baked_until_it_says_so() @test
{
	@with_js(; three::JsRuntime* run, three::Renderer* renderer)
	{
		three::RunResult built = run.run(SCENE);
		defer built.free();
		test::@check(built.ok, "the scene built: %s", built.error);

		three::RunResult before = run.run(`return three.lights[1].baked;`);
		defer before.free();
		test::@check(before.value == "false", "a fresh light is not baked, got %s", before.value);

		three::RunResult after = run.run(
			`point.baked = true; point.shadow = { enabled: true, size: 256 };
			 return [point.baked, point.shadow.size].join(' ');`
		);
		defer after.free();
		test::@check(
			after.value == `"true 256"`,
			"the flag and the light's own shadow size share a field and keep each other, got %s", after.value
		);
	};
}

<*
 One bake, and the two numbers that say which meshes it could reach.

 `receivers: 1, skipped: 1` is the whole eligibility contract in one line: the
 plane's uv is a layout and the box's is six faces stacked on one square, and the
 dynamic box is neither — it is not a static receiver at all, so it is not counted
 as refused.
*>
fn void a_bake_takes_the_meshes_whose_uvs_can_hold_one() @test
{
	@with_js(; three::JsRuntime* run, three::Renderer* renderer)
	{
		three::RunResult built = run.run(SCENE);
		defer built.free();
		test::@check(built.ok, "the scene built: %s", built.error);

		// A frame first: the bake reads the shadow atlas as the last frame left it.
		image::Image warm = renderer.capture()!!;
		warm.free();

		three::RunResult baked = run.run(
			`point.baked = true; disk.baked = true;
			 const r = three.lights.bake({ texelsPerMetre: 32 });
			 return [r.receivers, r.skipped, r.bytes > 0, three.stats().lightmapReceivers,
			  three.stats().lightmapSkipped].join(' ');`
		);
		defer baked.free();
		test::@check(baked.ok, "the bake ran: %s", baked.error);
		test::@check(
			baked.value == `"1 1 true 1 1"`,
			"one receiver and one refusal, reported the same way by stats — got %s", baked.value
		);
	};
}

<*
 The picture is the picture, with the two lights baked and with them not.

 The tolerance is not zero and the reason is geometric rather than sloppy: the
 tile is a fixed grid over the surface, so a shadow edge that the real-time loop
 resolves per pixel is resolved per texel here. At 32 texels a metre on a 4 m
 plane that is a handful of pixels along each silhouette, which is what the
 threshold below allows — a lightmap that was not being read at all, or one being
 read through the wrong rectangle, moves the *lit* interior of the plane and
 fails the second check by a wide margin.
*>
fn void a_baked_light_lights_a_receiver_as_it_did_in_real_time() @test
{
	@with_js(; three::JsRuntime* run, three::Renderer* renderer)
	{
		three::RunResult built = run.run(SCENE);
		defer built.free();
		test::@check(built.ok, "the scene built: %s", built.error);

		image::Image live = renderer.capture()!!;
		defer live.free();

		three::RunResult baked = run.run(
			`point.baked = true; disk.baked = true;
			 return three.lights.bake({ texelsPerMetre: 32 }).receivers;`
		);
		defer baked.free();
		test::@check(baked.value == "1", "the plane was baked: %s", baked.value);

		image::Image cached = renderer.capture()!!;
		defer cached.free();

		// The middle of the plane, which both lights reach and no box shadows.
		uint lit_before = luma_at(&live, W / 2, (uint)(H * 0.62f));
		uint lit_after = luma_at(&cached, W / 2, (uint)(H * 0.62f));
		uint drift = lit_before > lit_after ? lit_before - lit_after : lit_after - lit_before;
		test::@check(
			drift <= 6,
			"a lit texel of the plane reads the same baked as live: %d against %d", lit_before, lit_after
		);
		test::@check(
			worst_channel(&live, &cached) <= 64,
			"and no pixel of the frame moved more than a shadow edge, worst %d", worst_channel(&live, &cached)
		);
	};
}

<*
 The two receivers the cache cannot reach are lit exactly as they were.

 Byte for byte, which is stronger than the check above and is the half that says
 "nothing goes dark": a mesh whose uvs cannot carry a tile, and a mesh that is not
 static, both keep the whole real-time loop for a light that was marked baked.
*>
fn void an_ineligible_and_a_dynamic_receiver_are_untouched() @test
{
	@with_js(; three::JsRuntime* run, three::Renderer* renderer)
	{
		three::RunResult built = run.run(SCENE);
		defer built.free();
		test::@check(built.ok, "the scene built: %s", built.error);

		image::Image live = renderer.capture()!!;
		defer live.free();

		three::RunResult baked = run.run(
			`point.baked = true; disk.baked = true;
			 return three.lights.bake({ texelsPerMetre: 32 }).skipped;`
		);
		defer baked.free();
		test::@check(baked.value == "1", "the overlapping box was refused a tile: %s", baked.value);

		image::Image cached = renderer.capture()!!;
		defer cached.free();

		// The lit top of each box: the static one on the right, the dynamic one on
		// the left. Both are above the plane and neither has a tile.
		uint static_x = (uint)(W * 0.72f);
		uint dynamic_x = (uint)(W * 0.28f);
		uint top_y = (uint)(H * 0.40f);
		test::@check(
			luma_at(&live, static_x, top_y) == luma_at(&cached, static_x, top_y),
			"the box whose uvs overlap is lit exactly as before: %d against %d",
			luma_at(&live, static_x, top_y), luma_at(&cached, static_x, top_y)
		);
		test::@check(
			luma_at(&live, dynamic_x, top_y) == luma_at(&cached, dynamic_x, top_y),
			"and so is the dynamic box: %d against %d",
			luma_at(&live, dynamic_x, top_y), luma_at(&cached, dynamic_x, top_y)
		);
	};
}

<*
 Clearing the flag puts the light back in the loop, tile or no tile.

 The frame after `baked = false` is the frame before any of this happened, byte
 for byte — which is what makes the whole feature reversible from a script and is
 the check that would catch a lightmap being added *on top of* the real-time term
 rather than instead of it.
*>
fn void unbaking_a_light_restores_the_real_time_picture() @test
{
	@with_js(; three::JsRuntime* run, three::Renderer* renderer)
	{
		three::RunResult built = run.run(SCENE);
		defer built.free();
		test::@check(built.ok, "the scene built: %s", built.error);

		image::Image live = renderer.capture()!!;
		defer live.free();

		three::RunResult baked = run.run(
			`point.baked = true; disk.baked = true;
			 return three.lights.bake({ texelsPerMetre: 32 }).receivers;`
		);
		defer baked.free();
		test::@check(baked.value == "1", "the plane was baked: %s", baked.value);

		three::RunResult cleared = run.run(
			`point.baked = false; disk.baked = false; return point.baked;`
		);
		defer cleared.free();
		test::@check(cleared.value == "false", "the flags came off: %s", cleared.value);

		image::Image restored = renderer.capture()!!;
		defer restored.free();
		test::@check(
			worst_channel(&live, &restored) == 0,
			"the frame is the one before the bake, byte for byte — worst channel %d",
			worst_channel(&live, &restored)
		);
	};
}

<*
 A baked light that moves takes its tiles with it.

 The check that matters is the last one and it is exact: the picture after the
 catch-up has settled is the picture a bake made from nothing in the moved
 configuration, pixel for pixel. Anything less would mean a tile holding some of
 where the light was, which is the failure this whole half exists to stop.

 The frame right after the move is the one that reports the dirty count, because
 the catch-up deliberately waits a frame there — a tile baked in the same breath
 as the move would cache the shadow of where the light used to be.
*>
fn void moving_a_baked_light_dirties_the_tiles_it_reaches() @test
{
	@with_js(; three::JsRuntime* run, three::Renderer* renderer)
	{
		three::RunResult built = run.run(SCENE);
		defer built.free();
		test::@check(built.ok, "the scene built: %s", built.error);

		image::Image warm = renderer.capture()!!;
		warm.free();

		three::RunResult baked = run.run(
			`point.baked = true; disk.baked = true;
			 return [three.lights.bake({ texelsPerMetre: 32 }).receivers,
			  three.stats().lightmapDirty].join(' ');`
		);
		defer baked.free();
		test::@check(baked.value == `"1 0"`, "one receiver and nothing dirty: %s", baked.value);

		three::RunResult moved = run.run(`point.position = [-1.4, 2, 0.6]; return 1;`);
		defer moved.free();
		test::@check(moved.ok, "the light moved: %s", moved.error);

		image::Image waiting = renderer.capture()!!;
		waiting.free();
		three::RunResult pending = run.run(`return three.stats().lightmapDirty;`);
		defer pending.free();
		test::@check(pending.value == "1", "the tile the light reaches went dirty: %s", pending.value);

		for (uint i = 0; i < 12; i++)
		{
			image::Image tick = renderer.capture()!!;
			tick.free();
		}
		three::RunResult settled = run.run(`return three.stats().lightmapDirty;`);
		defer settled.free();
		test::@check(settled.value == "0", "and the catch-up finished it: %s", settled.value);

		image::Image caught = renderer.capture()!!;
		defer caught.free();

		three::RunResult again = run.run(`return three.lights.bake({ texelsPerMetre: 32 }).receivers;`);
		defer again.free();
		test::@check(again.value == "1", "the control bake ran: %s", again.value);
		image::Image fresh = renderer.capture()!!;
		defer fresh.free();

		test::@check(
			worst_channel(&caught, &fresh) == 0,
			"the caught-up picture is the freshly baked one, byte for byte — worst channel %d",
			worst_channel(&caught, &fresh)
		);
	};
}

<*
 A static receiver that moves dirties its own tile, and so does one that has none.

 The box's uvs overlap and it holds no tile at all, so moving it can only be seen
 through the plane it stands on — which is the conservative half of the rule: a
 caster that moved changes the light on everything the baked lights could carry
 its shadow to, and there is no cheap exact answer to what that is.
*>
fn void moving_a_static_receiver_dirties_the_tiles_around_it() @test
{
	@with_js(; three::JsRuntime* run, three::Renderer* renderer)
	{
		three::RunResult built = run.run(SCENE);
		defer built.free();
		test::@check(built.ok, "the scene built: %s", built.error);

		image::Image warm = renderer.capture()!!;
		warm.free();

		three::RunResult baked = run.run(
			`point.baked = true; disk.baked = true;
			 globalThis.box = three.scene.children[1];
			 return three.lights.bake({ texelsPerMetre: 32 }).receivers;`
		);
		defer baked.free();
		test::@check(baked.value == "1", "the plane was baked: %s", baked.value);

		three::RunResult moved = run.run(`box.position.set(0.4, 0.5, 0.8); return box.static;`);
		defer moved.free();
		test::@check(moved.value == "true", "the caster is static and moved: %s", moved.value);

		image::Image waiting = renderer.capture()!!;
		waiting.free();
		three::RunResult pending = run.run(`return three.stats().lightmapDirty;`);
		defer pending.free();
		test::@check(
			pending.value == "1",
			"the tile under the moved caster went dirty: %s", pending.value
		);

		for (uint i = 0; i < 12; i++)
		{
			image::Image tick = renderer.capture()!!;
			tick.free();
		}
		image::Image caught = renderer.capture()!!;
		defer caught.free();

		three::RunResult again = run.run(
			`return [three.lights.bake({ texelsPerMetre: 32 }).receivers,
			  three.stats().lightmapDirty].join(' ');`
		);
		defer again.free();
		test::@check(again.value == `"1 0"`, "the control bake ran: %s", again.value);
		image::Image fresh = renderer.capture()!!;
		defer fresh.free();
		test::@check(
			worst_channel(&caught, &fresh) == 0,
			"and the re-baked tile is the freshly baked one — worst channel %d",
			worst_channel(&caught, &fresh)
		);
	};
}

<*
 A saved bake loads back as the same atlas and asks for no bake at all.

 Two checks and they are different questions. The picture is the one the bake
 made, which says the tiles landed in the rectangles they were saved from; and the
 file the loaded atlas writes back out is byte-identical to the one it was read
 from, which says every texel survived the round trip through the device.
*>
fn void a_saved_bake_loads_back_byte_identical() @test
{
	@with_js(; three::JsRuntime* run, three::Renderer* renderer)
	{
		@with_assets(run)
		{
			three::RunResult built = run.run(SCENE);
			defer built.free();
			test::@check(built.ok, "the scene built: %s", built.error);

			image::Image warm = renderer.capture()!!;
			warm.free();

			three::RunResult saved = run.run(
				`point.baked = true; disk.baked = true;
				 three.lights.bake({ texelsPerMetre: 32 });
				 const s = three.lights.saveBake('first.lightmap');
				 return [s.tiles, s.dirty, s.bytes > 0].join(' ');`
			);
			defer saved.free();
			test::@check(saved.ok, "the bake saved: %s", saved.error);
			test::@check(saved.value == `"1 0 true"`, "one tile, nothing dirty: %s", saved.value);

			image::Image before = renderer.capture()!!;
			defer before.free();

			three::RunResult loaded = run.run(
				`const l = three.lights.loadBake('first.lightmap');
				 three.lights.saveBake('second.lightmap');
				 return [l.tiles, l.dirty, three.stats().lightmapReceivers].join(' ');`
			);
			defer loaded.free();
			test::@check(
				loaded.value == `"1 0 1"`,
				"it loaded one clean tile and the atlas is live: %s", loaded.value
			);

			image::Image after = renderer.capture()!!;
			defer after.free();
			test::@check(
				worst_channel(&before, &after) == 0,
				"the loaded atlas is the baked one — worst channel %d", worst_channel(&before, &after)
			);

			char[] first = file::load(mem, "build/test-bake/first.lightmap")!!;
			defer mem::free(first);
			char[] second = file::load(mem, "build/test-bake/second.lightmap")!!;
			defer mem::free(second);
			test::@check(
				first.len == second.len && first == second,
				"and what it writes back out is the file it read — %d bytes against %d",
				first.len, second.len
			);
		};
	};
}

<*
 A bake of other lights is refused, and the scene bakes rather than loading it.

 The atlas is a sum over the lights that were baked into it, so a file whose
 signature is not this scene's is not a stale bake to patch up — it is a bake of
 a different lighting. `loadBake` answers null, which is the same answer as "no
 file yet" and wants the same thing done about it.
*>
fn void a_bake_of_other_lights_is_not_loaded() @test
{
	@with_js(; three::JsRuntime* run, three::Renderer* renderer)
	{
		@with_assets(run)
		{
			three::RunResult built = run.run(SCENE);
			defer built.free();
			test::@check(built.ok, "the scene built: %s", built.error);

			image::Image warm = renderer.capture()!!;
			warm.free();

			three::RunResult saved = run.run(
				`point.baked = true; disk.baked = true;
				 three.lights.bake({ texelsPerMetre: 32 });
				 return three.lights.saveBake('both.lightmap').tiles;`
			);
			defer saved.free();
			test::@check(saved.value == "1", "the bake saved: %s", saved.value);

			three::RunResult refused = run.run(
				`disk.baked = false;
				 return three.lights.loadBake('both.lightmap') === null;`
			);
			defer refused.free();
			test::@check(
				refused.value == "true",
				"a file of two baked lights is not a bake of one: %s", refused.value
			);

			three::RunResult missing = run.run(
				`return three.lights.loadBake('nothing-here.lightmap') === null;`
			);
			defer missing.free();
			test::@check(missing.value == "true", "and neither is a file that is not there: %s", missing.value);
		};
	};
}

<*
 Two planes that share a name and a mesh, so the copy index is what tells them
 apart. One of them moves between the save and the load.
*>
const String TWO_PLANES = `
	const scene = new three.Scene();
	three.scene = scene;
	three.light.intensity = 0;
	three.lights.shadow = { enabled: true, size: 512, maxLocal: 8 };
	const mat = new three.MeshLambertMaterial({ color: 0xffffff });

	globalThis.left = new three.Mesh(new three.PlaneGeometry(2, 2), mat);
	left.rotation.x = -Math.PI / 2;
	left.position.set(-1.5, 0, 0);
	scene.add(left);
	left.static = true;

	globalThis.right = new three.Mesh(new three.PlaneGeometry(2, 2), mat);
	right.rotation.x = -Math.PI / 2;
	right.position.set(1.5, 0, 0);
	scene.add(right);
	right.static = true;

	globalThis.point = three.lights.add(
		{ position: [0, 2, 0], range: 12, color: 0xffffff, intensity: 6 });
	three.camera.lookAt(0, 0, 0);
	three.camera.orbit(0, 45, 8);
`;

<*
 A receiver that moved since the save is the only tile the load asks to re-bake.

 The atlas comes back whole and the tile table is matched receiver by receiver,
 so a level where one crate was nudged pays for one crate rather than for the
 level — which is the difference between the load being worth having and being a
 slower way to bake.
*>
fn void a_receiver_that_moved_since_the_save_is_the_only_dirty_tile() @test
{
	@with_js(; three::JsRuntime* run, three::Renderer* renderer)
	{
		@with_assets(run)
		{
			three::RunResult built = run.run(TWO_PLANES);
			defer built.free();
			test::@check(built.ok, "the scene built: %s", built.error);

			image::Image warm = renderer.capture()!!;
			warm.free();

			three::RunResult saved = run.run(
				`point.baked = true;
				 const b = three.lights.bake({ texelsPerMetre: 32 });
				 return [b.receivers, three.lights.saveBake('pair.lightmap').tiles].join(' ');`
			);
			defer saved.free();
			test::@check(saved.value == `"2 2"`, "two receivers, two tiles saved: %s", saved.value);

			three::RunResult loaded = run.run(
				`right.position.set(1.5, 0.35, 0);
				 const l = three.lights.loadBake('pair.lightmap');
				 return [l.tiles, l.dirty].join(' ');`
			);
			defer loaded.free();
			test::@check(
				loaded.value == `"2 1"`,
				"both tiles loaded and only the moved one is dirty: %s", loaded.value
			);

			for (uint i = 0; i < 12; i++)
			{
				image::Image tick = renderer.capture()!!;
				tick.free();
			}
			image::Image caught = renderer.capture()!!;
			defer caught.free();

			three::RunResult again = run.run(
				`return [three.lights.bake({ texelsPerMetre: 32 }).receivers,
				  three.stats().lightmapDirty].join(' ');`
			);
			defer again.free();
			test::@check(again.value == `"2 0"`, "the control bake ran: %s", again.value);
			image::Image fresh = renderer.capture()!!;
			defer fresh.free();
			test::@check(
				worst_channel(&caught, &fresh) == 0,
				"and the loaded-plus-caught-up picture is the freshly baked one — worst channel %d",
				worst_channel(&caught, &fresh)
			);
		};
	};
}
