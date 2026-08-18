<*
 Unloading: the milestone that turns a scene into levels.

	`c3c test --trust=full --test-noleak --test-filter three_tests::unload`

 `game.md` G2. Until it, `Assets.retain`/`release` moved a counter nothing read,
 `new three.Scene()` emptied the graph and left every upload resident, and
 level 1 → level 2 → level 3 grew device memory monotonically until the process
 exited. Invisible to an agent poking at one scene; fatal to a game.

 **The checks here are the ones a leak cannot pass by accident.** A test that
 unloads once and looks at a number proves very little — an off-by-one in the
 refcount, a texture whose last reference is dropped twice, a slot that is freed
 but never reused, all survive a single cycle. So the load-bearing check runs a
 hundred cycles and asserts the resident counts come back to the number they
 started at *every* time, and that the table itself stops growing after the
 first. Between them those catch the leak, the double free and the free list
 that never gets used.

 The fixture is two meshes over two glTF images with byte-identical payloads, so
 it is also the case that matters one level down: one deduplicated texture held
 by two meshes, which has to survive one of them going and not the other.
*>
module three_tests::unload;

import three;
import vk;
import image;
import collision;
import std::core::test;
import std::io;
import std::io::file;
import std::math;
import std::math::vector;

const String FIXTURE = "test/fixtures/textured.glb";

<*
 A byte-identical copy of the fixture under another name.

 `Assets.load` dedups on the path, so two names are what it takes to get two
 assets — and the texture dedup is on *content*, so those two assets share one
 image. That pair is the whole point of `SharedTexture.refs`: an image outliving
 the file that first uploaded it.
*>
const String FIXTURE_COPY = "build/unload_fixture_copy.glb";

const uint W = 200;
const uint H = 150;

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
 The fixture's bytes under a second name, deleted when the body is done.
*>
macro @with_copy(; @body)
{
	@pool()
	{
		char[] bytes = file::load_temp(FIXTURE)!!;
		file::save(FIXTURE_COPY, bytes)!!;
	};
	defer (void)file::delete(FIXTURE_COPY);
	@body();
}

// ============================================================================
// The cycle
// ============================================================================

<*
 A hundred load-unload cycles leave exactly what they found.

 `game.md` G2's own verification, and the single check that catches every leak
 this milestone can have. Three numbers are asserted after every cycle rather
 than at the end, because a leak that starts at cycle 40 and a leak that starts
 at cycle 1 need different explanations and only the per-cycle check tells them
 apart.

 The fourth assertion is the one a leak test usually forgets: **the table stops
 growing.** Resident count returning to zero while `assets.len()` climbs to a
 hundred would mean nothing is ever freed *as a slot* — the memory comes back
 and the bookkeeping does not, which is a slow leak wearing a passing test's
 clothes.
*>
fn void a_level_loads_and_unloads_a_hundred_times() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Assets* assets = &renderer.pass.assets;
		three::Scene* scene = &renderer.pass.scene;

		uint resident_before = assets.resident();
		uint textures_before = assets.texture_count();
		usz bytes_before = assets.texture_bytes();

		for (uint cycle = 0; cycle < 100; cycle++)
		{
			three::AssetId level = assets.load(&renderer.gpu, FIXTURE)!!;
			three::NodeId group = scene.add_group(scene.root, "level");
			renderer.pass.place(level, group);

			test::@check(assets.resident() == resident_before + 1,
				"cycle %d: loading a level left %d assets resident, expected %d",
				cycle, assets.resident(), resident_before + 1);

			// Rendered, so the frame path has actually referenced the buffers
			// that are about to be freed. Without this the check would pass on a
			// device that never touched them.
			renderer.render_offscreen()!!;

			scene.remove(group);
			three::UnloadReport report = assets.unload_unused(&renderer.gpu);

			test::@check(report.assets == 1, "cycle %d: freed %d assets, expected 1", cycle, report.assets);
			test::@check(assets.resident() == resident_before,
				"cycle %d: %d assets still resident, started at %d", cycle, assets.resident(), resident_before);
			test::@check(assets.texture_count() == textures_before,
				"cycle %d: %d textures still resident, started at %d",
				cycle, assets.texture_count(), textures_before);
			test::@check(assets.texture_bytes() == bytes_before,
				"cycle %d: %d texture bytes still resident, started at %d",
				cycle, assets.texture_bytes(), bytes_before);
		}

		test::@check(assets.assets.len() == 1,
			"a hundred cycles grew the asset table to %d slots; the free list is not being reused",
			assets.assets.len());
		test::@check(assets.textures.len() == 1,
			"a hundred cycles grew the texture table to %d slots", assets.textures.len());
	};
}

// ============================================================================
// What a reference means
// ============================================================================

<*
 A node is one reference, and removing it gives that reference back.

 The count is `Scene.create_slot`'s and `Scene.kill`'s since G2 — one
 implementation rather than one per caller — so this is the check that the two
 halves agree. They are asserted through `place`, which adds one node per mesh,
 because "two meshes is two references" is the case an implementation that
 counted per *asset added* would get wrong.
*>
fn void every_node_is_one_reference() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Assets* assets = &renderer.pass.assets;
		three::Scene* scene = &renderer.pass.scene;

		three::AssetId level = assets.load(&renderer.gpu, FIXTURE)!!;
		test::@check(assets.slot(level).refs == 0, "a freshly loaded asset already had %d references",
			assets.slot(level).refs);

		uint meshes = (uint)assets.slot(level).meshes.len();
		test::@check(meshes >= 2, "the fixture has %d meshes; this check wants at least 2", meshes);

		three::NodeId group = scene.add_group(scene.root, "level");
		renderer.pass.place(level, group);
		test::@check(assets.slot(level).refs == meshes,
			"placing %d meshes took %d references", meshes, assets.slot(level).refs);

		// One node of the subtree, so the release has to come from the recursion
		// rather than from the node `remove` was handed.
		three::NodeId first = scene.node(group).children[0];
		scene.remove(first);
		test::@check(assets.slot(level).refs == meshes - 1,
			"removing one node left %d references, expected %d", assets.slot(level).refs, meshes - 1);

		scene.remove(group);
		test::@check(assets.slot(level).refs == 0,
			"removing the group left %d references", assets.slot(level).refs);
	};
}

<*
 An asset something still draws is not freed, and the sweep says so.

 The half of `unload_unused` that is easy to get right by doing nothing and easy
 to get wrong by one line: a sweep that freed everything would pass every check
 above this one.
*>
fn void an_asset_a_node_still_names_survives_the_sweep() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Assets* assets = &renderer.pass.assets;
		three::Scene* scene = &renderer.pass.scene;

		three::AssetId kept = assets.load(&renderer.gpu, FIXTURE)!!;
		scene.add_mesh(kept, 0, scene.root, "kept");

		three::UnloadReport report = assets.unload_unused(&renderer.gpu);
		test::@check(report.assets == 0, "the sweep freed %d assets while one was still drawn", report.assets);
		test::@check(assets.slot(kept) != null, "the asset a live node names was freed");

		// And it still draws.
		renderer.render_offscreen()!!;
		three::SceneStats stats = renderer.pass.stats();
		test::@check(stats.instances == 1, "%d instances after a sweep that should have changed nothing",
			stats.instances);
	};
}

// ============================================================================
// Stale handles
// ============================================================================

<*
 A handle taken before an unload does not answer afterwards.

 This is the whole reason an asset handle grew a generation. The slot is reused
 — that is the point of the free list — so an index on its own would come back
 pointing at a *different file*, and a script placing meshes from it would get
 somebody else's geometry with nothing anywhere reporting a problem. The
 generation turns that silence into a null.
*>
fn void a_handle_from_before_an_unload_does_not_answer() @test
{
	@with_copy()
	{
		@with_pass(; three::Renderer* renderer)
		{
			three::Assets* assets = &renderer.pass.assets;

			three::AssetId first = assets.load(&renderer.gpu, FIXTURE)!!;
			assets.unload_unused(&renderer.gpu);
			test::@check(assets.slot(first) == null, "a handle to an unloaded asset still resolved");

			// A different file, so a stale handle that resolved would be pointing
			// at geometry from somewhere else entirely.
			three::AssetId second = assets.load(&renderer.gpu, FIXTURE_COPY)!!;
			test::@check(second.index == first.index,
				"the freed slot was not reused: %d then %d", first.index, second.index);
			test::@check(second.generation != first.generation,
				"the reused slot kept generation %d, so both handles resolve", second.generation);
			test::@check(assets.slot(first) == null, "the old handle resolved once its slot was reused");
			test::@check(assets.slot(second) != null, "the new handle did not resolve");
		};
	};
}

<*
 Loading a path again after unloading it gives a fresh asset, not the old one.

 `Assets.load`'s path dedup walks every slot including dead ones, and matching
 on a dead slot's leftover path would hand back a handle to nothing.
*>
fn void loading_a_path_again_after_unloading_it_gives_a_new_asset() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Assets* assets = &renderer.pass.assets;

		three::AssetId first = assets.load(&renderer.gpu, FIXTURE)!!;
		assets.unload_unused(&renderer.gpu);

		three::AssetId again = assets.load(&renderer.gpu, FIXTURE)!!;
		test::@check(assets.slot(again) != null, "reloading an unloaded path answered with a dead slot");
		test::@check(again.generation != first.generation,
			"reloading answered with the handle the unload was supposed to invalidate");
		test::@check(assets.slot(again).meshes.len() >= 2,
			"the reloaded asset has %d meshes", assets.slot(again).meshes.len());
	};
}

// ============================================================================
// Textures
// ============================================================================

<*
 An image two files share outlives the first of them.

 The texture table is deduplicated across *files* (`plan.md` §2), which is what
 makes a scene built out of a kit upload each image once — and it is what makes
 "free the textures this asset uploaded" the wrong rule. The right one is a
 count, and this is the case that tells them apart: two assets, one image, one
 of them unloaded.
*>
fn void an_image_two_files_share_outlives_the_first_of_them() @test
{
	@with_copy()
	{
		@with_pass(; three::Renderer* renderer)
		{
			three::Assets* assets = &renderer.pass.assets;
			three::Scene* scene = &renderer.pass.scene;

			three::AssetId one = assets.load(&renderer.gpu, FIXTURE)!!;
			three::AssetId two = assets.load(&renderer.gpu, FIXTURE_COPY)!!;

			test::@check(assets.resident() == 2, "%d assets resident, expected 2", assets.resident());
			test::@check(assets.texture_count() == 1,
				"two files with identical images uploaded %d textures", assets.texture_count());
			usz shared_bytes = assets.texture_bytes();
			test::@check(shared_bytes > 0, "the shared image measured zero bytes");

			// Keep the second file, drop the first.
			scene.add_mesh(two, 0, scene.root, "kept");
			three::UnloadReport first_sweep = assets.unload_unused(&renderer.gpu);

			test::@check(first_sweep.assets == 1, "the sweep freed %d assets, expected 1", first_sweep.assets);
			test::@check(first_sweep.textures == 0,
				"the sweep freed %d textures while another file still used the image", first_sweep.textures);
			test::@check(assets.texture_bytes() == shared_bytes,
				"the shared image's bytes changed from %d to %d", shared_bytes, assets.texture_bytes());
			test::@check(assets.slot(two) != null, "the surviving asset was freed");

			// And it draws — the surviving asset's mesh still samples an image
			// nothing destroyed.
			renderer.render_offscreen()!!;

			// Now drop the second as well.
			scene.remove(scene.root);
			three::UnloadReport second_sweep = assets.unload_unused(&renderer.gpu);
			test::@check(second_sweep.textures == 1,
				"the last reference went and %d textures were freed", second_sweep.textures);
			test::@check(second_sweep.bytes == shared_bytes,
				"the sweep reported %d bytes, expected %d", second_sweep.bytes, shared_bytes);
			test::@check(assets.texture_count() == 0, "%d textures still resident", assets.texture_count());
			test::@check(assets.texture_bytes() == 0, "%d texture bytes still resident", assets.texture_bytes());
		};
	};
}

<*
 A freed texture slot is reused rather than appended to.

 The same argument the asset free list makes, one level down: a game that cycles
 levels should hold as many texture slots as its largest level, not as many as it
 ever uploaded.
*>
fn void a_freed_texture_slot_is_reused() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Assets* assets = &renderer.pass.assets;

		assets.load(&renderer.gpu, FIXTURE)!!;
		test::@check(assets.textures.len() == 1, "the fixture uploaded %d texture slots", assets.textures.len());

		assets.unload_unused(&renderer.gpu);
		test::@check(assets.texture_count() == 0, "%d textures survived a full sweep", assets.texture_count());
		// The bookkeeping saying "gone" and the image actually being destroyed
		// are two claims, and only the second one gives the memory back.
		// `Texture.free` zeroes the struct, so a handle still here is a leak that
		// every count in this file would otherwise report as a clean sweep.
		test::@check(assets.textures[0].texture.image == null,
			"the texture slot was marked dead with its image still on the device");
		test::@check(assets.textures[0].texture.sampler == null, "and its sampler");
		test::@check(assets.textures[0].texture.view == null, "and its view");

		assets.load(&renderer.gpu, FIXTURE)!!;
		test::@check(assets.textures.len() == 1,
			"reloading grew the texture table to %d slots instead of reusing the free one",
			assets.textures.len());
		test::@check(assets.texture_count() == 1, "%d textures resident after reloading", assets.texture_count());
	};
}

// ============================================================================
// stats()
// ============================================================================

<*
 `stats()` reports what is resident, not how many slots the table has.

 `game.md` G2/S6: an agent that can watch the number go back down is the only
 way anyone believes any of this works, and a `stats()` that reported
 `assets.len()` would show a working unload as a leak.
*>
fn void stats_reports_resident_assets_rather_than_slots() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Assets* assets = &renderer.pass.assets;
		three::Scene* scene = &renderer.pass.scene;

		three::AssetId level = assets.load(&renderer.gpu, FIXTURE)!!;
		three::NodeId group = scene.add_group(scene.root, "level");
		renderer.pass.place(level, group);

		three::SceneStats loaded = renderer.pass.stats();
		test::@check(loaded.assets == 1, "stats() reported %d assets with one loaded", loaded.assets);
		test::@check(loaded.textures == 1, "stats() reported %d textures", loaded.textures);
		test::@check(loaded.texture_bytes > 0, "stats() reported no texture bytes");

		scene.remove(group);
		assets.unload_unused(&renderer.gpu);

		three::SceneStats swept = renderer.pass.stats();
		test::@check(swept.assets == 0, "stats() still reported %d assets after the sweep", swept.assets);
		test::@check(swept.textures == 0, "stats() still reported %d textures after the sweep", swept.textures);
		test::@check(swept.texture_bytes == 0, "stats() still reported %d texture bytes", swept.texture_bytes);
	};
}

<*
 A generated shape unloads exactly as a loaded file does.

 `Assets.primitive` and `Assets.load` file into the same table under the same
 rule, so they had better leave it the same way. The check that matters is the
 second half: the *key* has to go with the slot, or a shape built after an
 unload would be handed the dead asset the key still matched.
*>
fn void a_generated_shape_unloads_like_a_file() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Assets* assets = &renderer.pass.assets;
		three::Scene* scene = &renderer.pass.scene;

		three::Primitive box = { .kind = three::PrimitiveKind.BOX, .a = 1, .b = 1, .c = 1, .u = 1, .v = 1, .w = 1 };
		three::AssetId first = assets.primitive(&renderer.gpu, box)!!;
		scene.add_mesh(first, 0, scene.root, "box");

		// Same numbers, so the dedup answers with the same handle.
		three::AssetId same = assets.primitive(&renderer.gpu, box)!!;
		test::@check(same == first, "the same box built two assets");

		scene.remove(scene.root);
		three::UnloadReport report = assets.unload_unused(&renderer.gpu);
		test::@check(report.assets == 1, "the sweep freed %d assets", report.assets);

		three::AssetId rebuilt = assets.primitive(&renderer.gpu, box)!!;
		test::@check(assets.slot(rebuilt) != null, "rebuilding the box answered with a dead slot");
		test::@check(rebuilt.generation != first.generation,
			"rebuilding answered with the handle the unload invalidated");
	};
}
