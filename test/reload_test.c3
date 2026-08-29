<*
 Hot reload — §8, and the semantics §9 asked for.

	`c3c test --trust=full --test-noleak --test-filter three_tests::reload`

 **What can break here is quiet in both directions.** A reload that keeps too
 much is a stale `import` answering from a module cache, an animation callback
 from a file that has been edited still running, or a second copy of the world
 drawn on top of the first — and every one of those looks like the *edit* not
 having taken rather than the reload not having worked. A reload that keeps too
 little is the camera jumping back to the origin on every save, which is the one
 thing that would stop anybody pressing the key.

 So the checks come in those two shapes: what must be gone (the loop, the nodes,
 the module evaluation, the materials) and what must still be there (the camera,
 the assets, `three.persist`).
*>
module three_tests::reload;

import three;
import vk;
import qjs;
import c3w;
import std::core::test;
import std::io;

<*
 A runtime over a scene with no device behind it, and the scene itself.

 The same construction `frame_test.c3` uses, and for the same reason: a
 `MeshPass.init` wants a pipeline and therefore a GPU, and nothing about a reload
 needs one — the world it tears down is a node pool and a context.
*>
macro @with_js(; @body(three::JsRuntime* run, three::MeshPass* pass))
{
	three::MeshPass pass;
	pass.assets.init();
	pass.init_scenes();
	pass.camera = three::default_camera();
	defer pass.free_scenes();
	defer pass.assets.free(null);

	three::JsRuntime runtime;
	runtime.open(&pass)!!;
	defer runtime.close();

	@body(&runtime, &pass);
}

macro @with_gpu_js(; @body(three::JsRuntime* run, three::Renderer* renderer))
{
	vk::Instance instance = three::create_instance(false, headless: true)!!;
	defer instance.free();

	three::Renderer renderer;
	renderer.init(instance, (vk::SurfaceKHR)null, 200, 150)!!;
	defer renderer.free();

	renderer.pass.init(&renderer.gpu, &renderer.target)!!;

	three::JsRuntime runtime;
	runtime.open(&renderer.pass, &renderer)!!;
	defer runtime.close();

	@body(&runtime, &renderer);
}

// A script's answer as a string. Most checks here read state back out of JS
// twice — once before the reload and once after — and a typo in the first
// reading would report itself as the reload having lost something.
macro String @answer(three::JsRuntime* run, String source)
{
	three::RunResult result = run.run(source);
	defer result.free();
	test::@check(result.ok, "the reading script succeeded: %s", result.error);
	return result.value.copy(tmem);
}

macro @ok(three::JsRuntime* run, String source)
{
	three::RunResult result = run.run(source);
	defer result.free();
	test::@check(result.ok, "the setup script succeeded: %s", result.error);
}

// ============================================================================
// What a script may keep
// ============================================================================

<*
 A boot that is not a reload says so, and hands out an empty bag.

 The pair is the whole of the API, and the false is the half worth asserting: a
 `reloaded` that was truthy on a first boot would send every game down its
 restore path with nothing to restore.
*>
fn void a_first_boot_is_not_a_reload() @test
{
	@with_js(; three::JsRuntime* run, three::MeshPass* pass)
	{
		test::@check(@answer(run, "return three.reloaded;") == "false",
			"a first boot reported itself as a reload");
		test::@check(@answer(run, "return three.persist;") == "{}",
			"and persist started with something in it: %s",
			@answer(run, "return three.persist;"));
	};
}

fn void what_a_script_put_in_persist_comes_back() @test
{
	@with_js(; three::JsRuntime* run, three::MeshPass* pass)
	{
		@ok(run, "three.persist.at = [1, 2, 3]; three.persist.wave = 4;");

		three::reload(run, pass)!!;

		test::@check(@answer(run, "return three.reloaded;") == "true",
			"the boot after a reload did not say so");
		test::@check(@answer(run, "return three.persist;") == `{"at":[1,2,3],"wave":4}`,
			"the state did not come back: %s", @answer(run, "return three.persist;"));
	};
}

<*
 Replacing the object works as well as writing into it.

 `three.persist = {...}` is what a game that gathers its state in one place at the
 end of a frame writes, and it is a different code path from `three.persist.x =`:
 the host reads whatever the property names at teardown rather than the object the
 prelude created.
*>
fn void persist_may_be_replaced_rather_than_written_into() @test
{
	@with_js(; three::JsRuntime* run, three::MeshPass* pass)
	{
		@ok(run, "three.persist = { level: 'two' };");
		three::reload(run, pass)!!;
		test::@check(@answer(run, "return three.persist.level;") == `"two"`,
			"a replaced persist did not survive: %s", @answer(run, "return three.persist;"));
	};
}

<*
 State that is not JSON is dropped, and the reload happens anyway.

 The cycle is the shape a game reaches by accident — a saved entity holding the
 thing that holds it — and the answer has to be that the *reload* still works.
 Refusing to reload because the state would not serialise would make the feature
 fail exactly when somebody is trying to fix the code that made it fail.
*>
fn void persist_that_is_not_json_is_dropped_and_the_boot_still_happens() @test
{
	@with_js(; three::JsRuntime* run, three::MeshPass* pass)
	{
		@ok(run, "const a = {}; a.self = a; three.persist = a;");

		three::reload(run, pass)!!;

		test::@check(@answer(run, "return three.reloaded;") == "true",
			"the reload did not happen");
		test::@check(@answer(run, "return three.persist;") == "{}",
			"half a cycle came back: %s", @answer(run, "return three.persist;"));
	};
}

// A game that keeps nothing still boots, and still finds out that it is a
// reload — the two halves are independent and only one of them is opt-in.
fn void a_game_that_keeps_nothing_still_knows_it_reloaded() @test
{
	@with_js(; three::JsRuntime* run, three::MeshPass* pass)
	{
		three::reload(run, pass)!!;
		test::@check(@answer(run, "return three.reloaded;") == "true");
		test::@check(@answer(run, "return three.persist;") == "{}");
	};
}

// ============================================================================
// What a reload takes away
// ============================================================================

<*
 The animation loop does not survive, and this is §9's first answer.

 `frame_fn` is a retained reference into the context being closed, so the only
 alternative to dropping it was never available — but a reload that left
 `frame_active` true over a released function would call into freed memory rather
 than fail a check, so the assertion is on the runtime's own answer.
*>
fn void a_reload_takes_the_animation_loop_with_it() @test
{
	@with_js(; three::JsRuntime* run, three::MeshPass* pass)
	{
		@ok(run, "globalThis.__ticks = 0; three.setAnimationLoop(() => { globalThis.__ticks++; });");
		run.tick(16.0);
		test::@check(run.is_animating(), "the callback was not registered");

		three::reload(run, pass)!!;

		test::@check(!run.is_animating(), "the loop survived the reload");
		run.tick(32.0);
		test::@check(@answer(run, "return typeof globalThis.__ticks;") == `"undefined"`,
			"the context survived the reload with the old script's globals in it");
	};
}

<*
 The world goes, and one empty scene is what is left.

 Two scenes rather than one, because the count is the assertion: a reload that
 built a fresh scene without freeing the old ones would answer 3 here and draw
 the right picture, and nothing else would ever say so.
*>
fn void a_reload_empties_the_world() @test
{
	@with_js(; three::JsRuntime* run, three::MeshPass* pass)
	{
		@ok(run, `
			const a = new three.Scene();
			for (let i = 0; i < 3; i++) a.add(new three.Group());
			const b = new three.Scene();
			b.add(new three.Group());
		`);
		test::@check(@answer(run, "return three.stats().scenes;") == "2",
			"the fixture did not build two scenes");

		three::reload(run, pass)!!;

		test::@check(@answer(run, "return three.stats().scenes;") == "1",
			"a scene outlived the reload: %s", @answer(run, "return three.stats().scenes;"));
		test::@check(@answer(run, "return three.stats().nodes;") == "1",
			"and so did its nodes: %s", @answer(run, "return three.stats().nodes;"));
	};
}

<*
 An `import` is evaluated again, and this is the property the whole feature rests
 on.

 QuickJS caches an evaluated module on the *runtime*, and `JsRuntime.close` takes
 the runtime down with it — so nothing here busts a cache, and this is the check
 that says so. The fixture writes a global from its module body, so a second
 evaluation is visible as that global coming back after it has been overwritten.
 If the module were served from a cache the body would not run and `__game` would
 still say `stale`.
*>
fn void a_reload_evaluates_the_modules_again() @test
{
	@with_js(; three::JsRuntime* run, three::MeshPass* pass)
	{
		run.set_assets_root("test/fixtures/game");
		three::RunResult booted = run.run_module("main.js");
		defer booted.free();
		test::@check(booted.ok, "the fixture game booted: %s", booted.error);

		String built = @answer(run, "return globalThis.__game.grid;");
		@ok(run, "globalThis.__game = 'stale';");

		three::reload(run, pass, assets: "test/fixtures/game")!!;

		test::@check(@answer(run, "return globalThis.__game.grid;") == built,
			"main.js was not evaluated again: %s", @answer(run, "return globalThis.__game;"));
	};
}

// ============================================================================
// What a reload leaves alone
// ============================================================================

<*
 The camera is where it was, and §9's answer is that this is on purpose.

 It survives because it lives on `MeshPass` beside the assets rather than on the
 runtime — so what this really asserts is that `reset_world` does not reach for
 it. Somebody adding a "reset everything the script touched" line to that
 function fails here, which is the point.
*>
fn void a_reload_leaves_the_camera_alone() @test
{
	@with_js(; three::JsRuntime* run, three::MeshPass* pass)
	{
		@ok(run, "three.camera.orbit(45, 30, 80);");
		String aimed = @answer(run, "const c = three.camera; return [c.yaw, c.pitch, c.distance];");

		three::reload(run, pass)!!;

		test::@check(@answer(run, "const c = three.camera; return [c.yaw, c.pitch, c.distance];") == aimed,
			"the viewpoint moved: was %s, now %s", aimed,
			@answer(run, "const c = three.camera; return [c.yaw, c.pitch, c.distance];"));
	};
}

// ============================================================================
// Asking for one
// ============================================================================

<*
 `three.reload()` asks and does not act.

 Acting on the call would free the engine the call is running in, so the flag is
 the whole mechanism — and the second half of this is that the context is still
 usable afterwards, because the script that asked has lines below the one that
 asked.
*>
fn void three_reload_asks_for_one_rather_than_performing_it() @test
{
	@with_js(; three::JsRuntime* run, three::MeshPass* pass)
	{
		test::@check(!run.reload_wanted, "something wanted a reload before anything asked");

		test::@check(@answer(run, "three.reload(); return 'still here';") == `"still here"`,
			"the call did not return");
		test::@check(run.reload_wanted, "three.reload() did not ask for one");

		// And the flag is a property of the context, so the reload it asked for
		// clears it by construction rather than by anybody remembering to.
		three::reload(run, pass)!!;
		test::@check(!run.reload_wanted, "the request outlived the reload it caused");
	};
}

<*
 Shift+R, and neither half on its own.

 An edge on the R and a level on the shift: the third case is the one that would
 have reloaded sixty times a second, and the fourth is the game that binds R.
*>
fn void shift_r_is_the_reload_key() @test
{
	three::InputState both;
	both.pressed.set(c3w::EventKey.R);
	both.down.set(c3w::EventKey.R);
	both.down.set(c3w::EventKey.LEFT_SHIFT);
	test::@check(three::wants_reload(both), "shift+R did not ask for a reload");

	three::InputState right_shift;
	right_shift.pressed.set(c3w::EventKey.R);
	right_shift.down.set(c3w::EventKey.RIGHT_SHIFT);
	test::@check(three::wants_reload(right_shift), "the right shift is a shift too");

	three::InputState held;
	held.down.set(c3w::EventKey.R);
	held.down.set(c3w::EventKey.LEFT_SHIFT);
	test::@check(!three::wants_reload(held), "holding the pair reloaded a second time");

	three::InputState bare_r;
	bare_r.pressed.set(c3w::EventKey.R);
	bare_r.down.set(c3w::EventKey.R);
	test::@check(!three::wants_reload(bare_r), "R on its own reloaded");

	three::InputState nothing;
	test::@check(!three::wants_reload(nothing), "an idle frame reloaded");
}

// ============================================================================
// What makes it fast enough to press
// ============================================================================

<*
 The assets stay resident, which is the reason a reload is not a boot.

 `Assets` is on the pass and keyed by path, so the second `three.load` of the same
 file answers out of memory with nothing reopened and nothing uploaded. If a
 reload swept them, every one would re-parse and re-upload the whole kit — correct,
 and slow enough that nobody would use this.
*>
fn void a_reload_keeps_the_assets_that_were_loaded() @test
{
	@with_gpu_js(; three::JsRuntime* run, three::Renderer* renderer)
	{
		@ok(run, `
			const kit = three.load("test/fixtures/textured.glb");
			const scene = new three.Scene();
			scene.add(new three.Mesh(kit.mesh("quad_left")));
		`);
		test::@check(@answer(run, "return three.stats().assets;") == "1",
			"the fixture did not load");

		three::reload(run, &renderer.pass, renderer)!!;

		test::@check(@answer(run, "return three.stats().assets;") == "1",
			"the asset was swept by the reload: %s", @answer(run, "return three.stats().assets;"));

		// And the second load is the same slot rather than a second parse of the
		// same file — which is what the count above would fail to notice if the
		// sweep and the reload had both happened.
		@ok(run, `globalThis.__again = three.load("test/fixtures/textured.glb");`);
		test::@check(@answer(run, "return three.stats().assets;") == "1",
			"loading it again made a second asset");
	};
}

<*
 The textures the old script held are given back.

 A texture reference is owned by a *handle* — the `Texture` object the prelude
 wraps the index in — and every handle went down with the context without
 `dispose()` ever being called on it. So this is the same hole
 `release_script_materials` fills, one resource over: without it, ten reloads of a
 game that makes two textures leaves twenty images resident that nothing names and
 nothing can reach.
*>
fn void a_reload_gives_back_the_textures_the_script_held() @test
{
	@with_gpu_js(; three::JsRuntime* run, three::Renderer* renderer)
	{
		@ok(run, `
			three.texture("test/fixtures/checker.png");
			three.texture("test/fixtures/green.jpg");
		`);
		test::@check(@answer(run, "return three.stats().textures;") == "2",
			"the fixture did not make two textures: %s",
			@answer(run, "return three.stats().textures;"));

		three::reload(run, &renderer.pass, renderer)!!;

		test::@check(@answer(run, "return three.stats().textures;") == "0",
			"the images outlived the handles that held them: %s",
			@answer(run, "return three.stats().textures;"));
	};
}

<*
 A handle the script disposed itself is not given back twice.

 The tally and the table have to agree, and this is the case that would break
 them: a release counted at the dispose and counted again at the teardown frees an
 image that is already gone. Under `-D DEBUG` a second destroy of the same
 `VkImage` is a validation error, so this is checked twice over — once by the
 count and once by the layer.
*>
fn void a_texture_the_script_disposed_is_not_released_again() @test
{
	@with_gpu_js(; three::JsRuntime* run, three::Renderer* renderer)
	{
		@ok(run, `
			const gone = three.texture("test/fixtures/checker.png");
			gone.dispose();
			three.texture("test/fixtures/green.jpg");
		`);
		test::@check(@answer(run, "return three.stats().textures;") == "1",
			"the dispose did not take: %s", @answer(run, "return three.stats().textures;"));

		three::reload(run, &renderer.pass, renderer)!!;

		test::@check(@answer(run, "return three.stats().textures;") == "0",
			"the one that was left did not go: %s",
			@answer(run, "return three.stats().textures;"));
	};
}

<*
 A texture an *asset* owns is kept, because the asset is.

 The other side of the release, and the one that says it is a release rather than
 a sweep: a `.glb`'s own image is held by the `GpuMesh` that names it, the asset
 stays resident across a reload on purpose, and so the image has to stay with it.
 A teardown that freed every texture rather than the script's own would make the
 next boot re-decode and re-upload the whole kit — correct, and slow enough that
 nobody would press the key.
*>
fn void a_reload_keeps_a_texture_the_asset_owns() @test
{
	@with_gpu_js(; three::JsRuntime* run, three::Renderer* renderer)
	{
		@ok(run, `
			const kit = three.load("test/fixtures/textured.glb");
			const scene = new three.Scene();
			scene.add(new three.Mesh(kit.mesh("quad_left")));
		`);
		String held = @answer(run, "return three.stats().textures;");
		test::@check(held != "0", "the fixture uploaded no texture");

		three::reload(run, &renderer.pass, renderer)!!;

		test::@check(@answer(run, "return three.stats().textures;") == held,
			"the asset's own image went with the script's: was %s, now %s", held,
			@answer(run, "return three.stats().textures;"));
		test::@check(@answer(run, "return three.stats().assets;") == "1",
			"and the asset itself went");
	};
}

<*
 The materials the old script held are given back.

 They are the one resource a reload has to collect by hand: a material is freed by
 its *handle* going away, every handle went down with the context, and nothing
 else would ever call `dispose` on them. Ten reloads of a game with twenty
 materials would otherwise be two hundred live ones, each holding a pipeline.
*>
fn void a_reload_gives_back_the_materials_the_script_held() @test
{
	@with_gpu_js(; three::JsRuntime* run, three::Renderer* renderer)
	{
		@ok(run, `
			const scene = new three.Scene();
			for (const c of [[1,0,0],[0,1,0],[0,0,1]]) {
				new three.MeshLambertMaterial({ color: c });
			}
		`);
		test::@check(@answer(run, "return three.stats().materials;") == "3",
			"the fixture did not build three materials: %s",
			@answer(run, "return three.stats().materials;"));

		three::reload(run, &renderer.pass, renderer)!!;

		test::@check(@answer(run, "return three.stats().materials;") == "0",
			"the materials outlived the script that held them: %s",
			@answer(run, "return three.stats().materials;"));
	};
}
