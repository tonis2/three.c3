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
import std::core::test;
import std::io::file;
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

<*
 The kit-shaped fixture and its copy: four meshes, one material, one image.

 `textured.glb` above shares an image between two *files*. This shares one
 between four meshes inside a file, which is the case `ImageMemo` handles and
 therefore the case where the reference can go missing — the memo answers
 without going anywhere near the upload path, and the upload path is where the
 count used to be taken.
*>
const String SHARED = "test/fixtures/shared_material.glb";

<*
 A plain image, for the material checks: `load_texture_file` wants a picture and
 every other fixture in this file is a `.glb`.
*>
const String CHECKER = "test/fixtures/checker.png";
const String SHARED_COPY = "build/unload_shared_copy.glb";

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
 A fixture's bytes under a second name, deleted when the body is done.
*>
macro @copy_of(String source, String dest; @body)
{
	@pool()
	{
		char[] bytes = file::load_temp(source)!!;
		file::save(dest, bytes)!!;
	};
	defer (void)file::delete(dest);
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
		three::Scene* scene = renderer.pass.scene;

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

<*
 An unload during gameplay queues its buffers and its images rather than
 stalling the device.

 This is `plan.md` §2's trigger — "something unloads during gameplay" — asserted
 as the two things that had to become true for it: nothing waits, and nothing is
 destroyed early.

 `Assets.unload_unused` used to open with `gpu.wait_idle()`, which is right for a
 level boundary and wrong for a game that streams. What replaced it is
 `gpu/retire.c3`'s second list, and the check below is the same three-step
 arithmetic `a_retired_pipeline_waits_out_the_frames_in_flight` makes, over
 objects a frame actually read: the asset is rendered once before it is dropped,
 so the command buffer that referenced its buffers is genuinely one of the two in
 flight.

 **The count is a lower bound rather than a number.** A fixture's mesh has
 positions, indices, normals and uvs, and its image is a fifth entry; asserting
 "more than four" rather than "exactly five" keeps this about the mechanism and
 not about what happens to be in `textured.glb`.

 **Proved by injection**, twice. `retire_memory` changed to free rather than
 queue: "the sweep queued nothing: 0". And `retire_at` set to `frame + 1` rather
 than `frame + MAX_FRAMES_IN_FLIGHT`, which is the hazard itself and the reason
 the middle check exists: "the queue gave something back after one frame: 0 of 9
 left". Nine, on this fixture — which is why the bound is written as "more than
 four" rather than as a number.
*>
fn void an_unload_queues_its_buffers_rather_than_waiting_for_the_device() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Gpu* gpu = &renderer.gpu;
		three::Assets* assets = &renderer.pass.assets;
		three::Scene* scene = renderer.pass.scene;

		three::AssetId level = assets.load(gpu, FIXTURE)!!;
		three::NodeId group = scene.add_group(scene.root, "level");
		renderer.pass.place(level, group);

		// So the buffers about to be given back are buffers a submitted command
		// buffer has actually referenced. Without this the queue would still be
		// correct and the test would be about nothing.
		renderer.render_offscreen()!!;

		scene.remove(group);
		sz queued_before = gpu.deletions.memory.len();
		three::UnloadReport report = assets.unload_unused(gpu);
		test::@check(report.assets == 1, "the sweep freed %d assets, expected 1", report.assets);

		sz queued = gpu.deletions.memory.len() - queued_before;
		test::@check(queued > 4, "the sweep queued nothing: %d", (int)queued);

		renderer.render_offscreen()!!;
		test::@check(
			gpu.deletions.memory.len() >= queued,
			"the queue gave something back after one frame: %d of %d left",
			(int)gpu.deletions.memory.len(),
			(int)queued
		);

		renderer.render_offscreen()!!;
		test::@check(
			gpu.deletions.memory.len() == 0,
			"and it was empty after two: %d left",
			(int)gpu.deletions.memory.len()
		);
	};
}

<*
 Total bytes on the allocator's free lists.

 The only handle a test has on "was this allocation actually given back". Vulkan
 will not answer "is this `VkImage` alive", and the validation layer only says so
 at `vkDestroyDevice`, which is after the last test has run. But `vk::Memory.free`
 destroys the handle *and* returns the block in one call, so a block reappearing
 here is that call having happened.
*>
fn sz free_block_bytes(three::Gpu* gpu)
{
	sz total = 0;
	foreach (page : gpu.allocator.pages)
	{
		foreach (block : page.free_blocks) total += block.size;
	}
	return total;
}

<*
 Draining the queue destroys what is in it, images included.

 The test above proves the queue holds an unload for two frames and then lets go
 of it. It cannot prove that letting go *frees* anything, and for images it did
 not: `free_retired_memory` guarded its last call on `due.memory.buffer != null`,
 and an image-backed `vk::Memory` leaves that field null and fills in `.image`
 instead. Every texture, shadow map and chain image that ever reached the queue
 was dequeued and dropped on the floor — the `VkImage` never destroyed, the page
 block never returned.

 It survived because the suite had no way to see it. A leaked image is reported
 by `vkDestroyDevice`, which happens after the last check in a run; the sink is
 armed around a script and this is not one; and the picture is identical either
 way. What finally showed it was a `--debug` run validating without being asked —
 see `validation_layer_present` in `src/gpu/device.c3` — which put "1 leaked
 object" under the built-in triangle, the white 1x1 stand-in being the only image
 it makes.

 So the assertion is the byte count rather than the handle: `vk::Memory.free`
 destroys the image and returns the block in the same three lines, so the block
 coming back is that call having run.

 **One image alone in the queue, and nothing else**, which is the part the first
 draft of this got wrong. Retiring a whole asset and asserting on the total bytes
 returned passes with the bug in place: its four vertex streams are buffers, they
 come back, and they outweigh the image that did not. So this makes exactly one
 image, checks the queue holds exactly one entry, and measures across the drain
 and nothing else.

 **Proved by injection.** The guard put back to `due.memory.buffer != null`:
 "the drain returned 0 bytes for a 262144-byte image".
*>
fn void a_drained_image_is_destroyed_and_not_merely_dequeued() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Gpu* gpu = &renderer.gpu;

		// Big enough that the answer cannot be alignment slack, and mip-less so
		// that the allocation is the 256 KiB the arithmetic below expects.
		const uint SIDE = 256;
		char[] rgba = mem::new_array(char, (usz)SIDE * SIDE * 4);
		defer free(rgba);
		three::Texture texture = gpu.create_texture(rgba, SIDE, SIDE, mips: false)!!;

		sz queued_before = gpu.deletions.memory.len();
		texture.free(gpu);
		test::@check(
			gpu.deletions.memory.len() == queued_before + 1,
			"freeing one texture queued %d entries",
			(int)(gpu.deletions.memory.len() - queued_before)
		);

		// With the queue full, so the drain is the only thing between the two
		// readings — `drain_deletions` waits idle and frees, and allocates
		// nothing that could eat a block on the way.
		sz before = free_block_bytes(gpu);
		gpu.drain_deletions();
		sz returned = free_block_bytes(gpu) - before;

		sz image_bytes = (sz)SIDE * SIDE * 4;
		test::@check(
			returned >= image_bytes,
			"the drain returned %d bytes for a %d-byte image",
			(int)returned, (int)image_bytes
		);
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
		three::Scene* scene = renderer.pass.scene;

		three::AssetId level = assets.load(&renderer.gpu, FIXTURE)!!;
		test::@check(assets.slot(level).refs == 0, "a freshly loaded asset already had %d references",
			assets.slot(level).refs);

		uint meshes = (uint)assets.slot(level).meshes.len();
		test::@check(meshes >= 2, "the fixture has %d meshes; this check wants at least 2", meshes);

		three::NodeId group = scene.add_group(scene.root, "level");
		three::NodeId placed = renderer.pass.place(level, group);
		test::@check(assets.slot(level).refs == meshes,
			"placing %d meshes took %d references", meshes, assets.slot(level).refs);

		// One node of the subtree, so the release has to come from the recursion
		// rather than from the node `remove` was handed. Taken off `place`'s own
		// return value since G3, because the asset's hierarchy decides the shape
		// of what it built and a test should not be asserting on that here.
		three::NodeId first = scene.node(placed).children[0];
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
		three::Scene* scene = renderer.pass.scene;

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
	@copy_of(FIXTURE, FIXTURE_COPY)
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
	@copy_of(FIXTURE, FIXTURE_COPY)
	{
		@with_pass(; three::Renderer* renderer)
		{
			three::Assets* assets = &renderer.pass.assets;
			three::Scene* scene = renderer.pass.scene;

			three::AssetId one = assets.load(&renderer.gpu, FIXTURE)!!;
			three::AssetId two = assets.load(&renderer.gpu, FIXTURE_COPY)!!;

			// Both have to be *placed*, not merely loaded: since G3/S3 loading
			// describes a file and retaining a mesh is what uploads it, so two
			// loaded-and-unused files share nothing because neither has an image
			// yet.
			three::NodeId first = scene.instantiate(one, scene.root, "first");
			scene.instantiate(two, scene.root, "second");

			test::@check(assets.resident() == 2, "%d assets resident, expected 2", assets.resident());
			test::@check(assets.texture_count() == 1,
				"two files with identical images uploaded %d textures", assets.texture_count());
			usz shared_bytes = assets.texture_bytes();
			test::@check(shared_bytes > 0, "the shared image measured zero bytes");

			// Keep the second file, drop the first.
			scene.remove(first);
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
 An image four meshes share does not die with the first file that drops it.

 The same shape as the test above, one level in. There the image is shared
 between two *files* and the content hash is what notices; here it is shared
 between four meshes of one file and `ImageMemo` is what notices, which means
 the reference is taken on a code path that never touches the upload.

 Two copies of the kit, eight meshes, one image, eight references. Drop one copy
 and four go — and the image has to be exactly as alive as it was, because four
 meshes still sample it.

 The failure this exists for has no picture and no fault: forget the retain on a
 memo hit and the count reads 2 instead of 8, the first sweep takes it to zero,
 and `release_texture` politely ignores the four releases that follow. What is
 left is a `GpuMesh` holding an index into a destroyed image — which is why
 `render_offscreen` is in here, with the validation layer watching.
*>
fn void an_image_four_meshes_share_survives_losing_half_of_them() @test
{
	@copy_of(SHARED, SHARED_COPY)
	{
		@with_pass(; three::Renderer* renderer)
		{
			three::Assets* assets = &renderer.pass.assets;
			three::Scene* scene = renderer.pass.scene;

			three::AssetId one = assets.load(&renderer.gpu, SHARED)!!;
			three::AssetId two = assets.load(&renderer.gpu, SHARED_COPY)!!;

			// Placed, not merely loaded — see the test above.
			three::NodeId dropped = scene.instantiate(one, scene.root, "dropped");
			scene.instantiate(two, scene.root, "kept");

			test::@check(assets.texture_count() == 1,
				"eight meshes over one image uploaded %d textures", assets.texture_count());
			test::@check(assets.textures[0].refs == 8,
				"eight meshes name the image and it holds %d references", assets.textures[0].refs);
			usz shared_bytes = assets.texture_bytes();

			// Keep the second copy's four meshes, drop the first copy's four.
			scene.remove(dropped);
			three::UnloadReport sweep = assets.unload_unused(&renderer.gpu);

			test::@check(sweep.assets == 1, "the sweep freed %d assets, expected 1", sweep.assets);
			test::@check(sweep.textures == 0,
				"the sweep freed %d textures while four meshes still sample the image", sweep.textures);
			test::@check(assets.textures[0].refs == 4,
				"four meshes are left and the image holds %d references", assets.textures[0].refs);
			test::@check(assets.texture_bytes() == shared_bytes,
				"the image's bytes changed from %d to %d", shared_bytes, assets.texture_bytes());
			test::@check(assets.slot(one) == null, "the dropped copy still resolved");

			renderer.render_offscreen()!!;

			scene.remove(scene.root);
			three::UnloadReport last = assets.unload_unused(&renderer.gpu);
			test::@check(last.textures == 1,
				"the last four references went and %d textures were freed", last.textures);
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

		three::Scene* scene = renderer.pass.scene;

		three::AssetId first = assets.load(&renderer.gpu, FIXTURE)!!;
		scene.instantiate(first, scene.root, "level");
		test::@check(assets.textures.len() == 1, "the fixture uploaded %d texture slots", assets.textures.len());

		scene.remove(scene.root);
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

		three::AssetId again = assets.load(&renderer.gpu, FIXTURE)!!;
		scene.instantiate(again, scene.root, "level again");
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
		three::Scene* scene = renderer.pass.scene;

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
		three::Scene* scene = renderer.pass.scene;

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

// ============================================================================
// Materials
// ============================================================================

<*
 A fragment body per index, so that each material is its own compile.

 Distinct sources are the whole point: two identical bodies are one pipeline by
 design (`the_pipeline_cache_skips_the_compile`), and a check about accumulation
 written on identical bodies would pass against a cache that never grew because
 it never had anything to grow with.
*>
fn String shading_body(uint n, alloc::Allocator allocator)
{
	return string::format(allocator, "float3 shade(Surface s) { return s.albedo * %d.0; }", n + 1);
}

<*
 The cache entry a handed-out pipeline belongs to, or null.

 The test's own version of `PipelineCache.entry_for`, which is not exported.
 Pointer identity, as the cache's is.
*>
fn three::CachedPipeline* entry_for(three::PipelineCache* cache, three::MeshPipeline* pipeline)
{
	foreach (entry : cache.entries)
	{
		if (&entry.pipeline == pipeline) return entry;
	}
	return null;
}

<*
 Disposing a material gives its pipeline back to the cache.

 The reference, not the pipeline: the entry stays cached and evictable, which is
 `a_released_pipeline_is_kept_for_the_next_acquire`'s claim from the other end.
 What this asserts is the count, because the count is what eviction reads and
 the count is what nothing was keeping before — every `Material` pinned its
 pipeline for the life of the process, so `plan.md` §1's cache could never have
 evicted anything even if it had tried.

 ## Proved by injection

 - **`free_material` not releasing the pipeline:** "and gave its reference back:
   1" — the material is collected, the pipeline is pinned forever, and nothing
   else in the suite says so.
 - **`MeshPass.material` ignoring `alive`:** "the material was collected" fails,
   because a collected slot answers with its zeroed self and a null pipeline.
*>
fn void a_disposed_material_gives_its_pipeline_back() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::MeshPass* pass = &renderer.pass;

		uint material;
		@pool()
		{
			material = pass.create_material(
				&renderer.gpu, &renderer.target, shading_body(0, tmem), {}
			)!!;
		};

		three::MeshPipeline* pipeline = pass.material(material).pipeline;
		three::CachedPipeline* entry = entry_for(&pass.pipelines, pipeline);
		test::@check(entry != null, "the material's pipeline came out of the cache");
		test::@check(entry.refs == 1, "and the material holds the one reference: %d", entry.refs);

		pass.dispose_material(&renderer.gpu, material)!!;

		test::@check(pass.material(material) == null, "the material was collected");
		test::@check(entry.refs == 0, "and gave its reference back: %d", entry.refs);
	};
}

<*
 A disposed material a mesh still draws with is not collected.

 `texture.dispose()`'s rule, applied to the thing textures are put on: giving
 back a handle is a statement about the handle. A mesh that is still drawing
 with the material is not wrong for doing so, and collecting underneath it would
 turn `dispose()` into something a script has to time against its own scene.

 The second half is the one that makes the first half safe rather than merely
 lenient. Once the mesh goes, the next render collects — so a script that
 disposes early does not have to come back and dispose again.

 **Proved by injection.** `collect_materials` ignoring which materials a node
 names: "the material outlived the handle" fails at the first check, and the box
 stops drawing from that frame on.
*>
fn void a_disposed_material_survives_the_mesh_that_draws_with_it() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::MeshPass* pass = &renderer.pass;
		three::Scene* scene = pass.scene;

		uint material;
		@pool()
		{
			material = pass.create_material(
				&renderer.gpu, &renderer.target, shading_body(0, tmem), {}
			)!!;
		};

		three::AssetId box = pass.assets.primitive(&renderer.gpu, three::box_shape(1, 1, 1))!!;
		three::NodeId node = scene.add_mesh(box, 0);
		scene.set_material(node, material);

		pass.dispose_material(&renderer.gpu, material)!!;
		test::@check(pass.material(material) != null, "the material outlived the handle");
		test::@check(pass.pending_materials == 1, "and is waiting on the mesh: %d", pass.pending_materials);

		// It still draws, which is the part a premature collection would break
		// silently: `MeshPass.record` skips a bucket whose material does not
		// resolve, so the symptom is a missing shape and not a crash.
		renderer.pass.frame_camera();
		renderer.render_offscreen()!!;
		test::@check(pass.material(material) != null, "and a frame did not take it either");

		scene.remove(node);
		renderer.render_offscreen()!!;

		test::@check(pass.material(material) == null, "the mesh went and the material followed");
		test::@check(pass.pending_materials == 0, "with nothing left pending: %d", pass.pending_materials);
	};
}

<*
 A collected slot is handed to the next material rather than left behind.

 The same claim as `a_freed_texture_slot_is_reused` and for the same reason: a
 count that comes back to zero while the table grows is a leak wearing a passing
 test's clothes. An agent iterating compiles a material per run, and the list
 those land in has to stop growing as well as the cache they name.

 **Proved by injection.** `claim_slot` always pushing: "the freed slot came
 back: 2 then 3".
*>
fn void a_collected_material_slot_is_reused() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::MeshPass* pass = &renderer.pass;

		uint first;
		@pool()
		{
			first = pass.create_material(&renderer.gpu, &renderer.target, shading_body(0, tmem), {})!!;
		};
		sz slots = pass.materials.len();

		pass.dispose_material(&renderer.gpu, first)!!;

		uint second;
		@pool()
		{
			second = pass.create_material(&renderer.gpu, &renderer.target, shading_body(1, tmem), {})!!;
		};

		test::@check(second == first, "the freed slot came back: %d then %d", first, second);
		test::@check(pass.materials.len() == slots,
			"and the table did not grow: %d then %d", (int)slots, (int)pass.materials.len());
	};
}

<*
 `stats().materials` counts what a script built and has not had collected.

 The number behind the warning `plan.md` §2 asked for. A material an agent
 compiled holds a `VkPipeline` until `material.dispose()` gives it back, and
 `MAX_UNUSED_PIPELINES` cannot help with that: an entry a live material names has
 a reference and is never one of the unused ones the cache is allowed to evict.
 So a script that builds materials and drops the handles grows device memory
 monotonically, exactly as a script that never unloaded an asset used to — and
 this is the counterpart of `stats().assets`, which is how that one is watched.

 It counts *collections* and not disposals, which is the half worth pinning: a
 disposed material a mesh still draws with is still holding its pipeline, and a
 count that fell at the `dispose()` would tell a script it had given back what it
 had not. The middle of this test is that case.

 The two built-in materials are not in it. They are claimed in `MeshPass.init`,
 they cannot be disposed, and a permanent 2 in front of the one number this
 exists to watch would be noise standing where the signal goes.

 **Proved by injection.**

 - **`live_materials` counted from the built-ins rather than reset after them:**
   "nothing a script built is live yet: 2".
 - **The decrement moved from `free_material` to `dispose_material`:** "the mesh
   still draws with it, so it is still live: 0".
*>
fn void the_live_material_count_is_what_a_script_watches() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::MeshPass* pass = &renderer.pass;
		three::Scene* scene = pass.scene;

		test::@check(pass.stats().materials == 0,
			"nothing a script built is live yet: %d", pass.stats().materials);

		uint material = pass.create_texture_material(three::NO_TEXTURE)!!;
		test::@check(pass.stats().materials == 1, "one built: %d", pass.stats().materials);

		// Named by a mesh, so the dispose is a release and not a collection.
		three::AssetId box = pass.assets.primitive(&renderer.gpu, three::box_shape(1, 1, 1))!!;
		three::NodeId node = scene.add_mesh(box, 0);
		scene.set_material(node, material);

		pass.dispose_material(&renderer.gpu, material)!!;
		test::@check(pass.stats().materials == 1,
			"the mesh still draws with it, so it is still live: %d", pass.stats().materials);

		scene.remove(node);
		renderer.pass.frame_camera();
		renderer.render_offscreen()!!;
		test::@check(pass.stats().materials == 0,
			"the mesh went, the material was collected, and the count followed: %d",
			pass.stats().materials);
	};
}

<*
 The live-scene warning waits for twice the count, the material one's way.

 **The regression this exists for is a level transition that leaks a world per
 level, silently.** `new three.Scene()` stopped freeing the scene before it —
 that is what makes building the next level early possible — so a game that never
 calls `scene.dispose()` holds a node pool, a physics world, a nav bake and a set
 of asset references per level it has ever shown. Nothing else says so: those
 scenes are not drawn, not stepped and not queried, so every frame number stays
 exactly as healthy as it was.

 Doubling rather than warning per scene, and never resetting downwards, for the
 three reasons `note_material_claimed` gives.

 Proved by injection: fold the threshold bump out of `note_scene_created` and the
 last check reads the same number twice.
*>
fn void the_scene_warning_waits_for_twice_the_count() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::MeshPass* pass = &renderer.pass;
		uint threshold = pass.scene_warn_at;
		test::@check(threshold == three::SCENE_WARN_AT, "nothing has fired yet: %d", threshold);
		// The one `init` built. It is a real scene and is counted, which is what
		// `claim_scene` exists to keep from reading as two.
		test::@check(pass.scenes.len() == 1, "a pass starts with one scene: %d", pass.scenes.len());

		while (pass.scenes.len() < (sz)(threshold - 1)) pass.new_scene();
		test::@check(pass.scene_warn_at == threshold,
			"nothing said below it: %d", pass.scene_warn_at);

		pass.new_scene();
		test::@check(pass.scene_warn_at == threshold * 2,
			"the next word waits for twice the count: %d then %d", threshold, pass.scene_warn_at);

		// And they all go back. `MeshPass.free` frees every scene, not just the
		// active one — the leak checker in a run without `--test-noleak` is the
		// assertion.
		test::@check(pass.scenes.len() == (sz)threshold,
			"the scenes are all still there to be freed: %d", pass.scenes.len());
	};
}

<*
 The count is what earns a word about disposing, and the next word costs twice.

 `MATERIAL_WARN_AT` is the trigger `plan.md` §2 wrote down: the answer to "a
 material nobody disposes is immortal" is a warning naming the count rather than
 a `FinalizationRegistry`, because a collector-driven free would make device
 memory depend on when QuickJS felt like collecting — which is the property
 `three.unloadUnused()` exists so that assets do not have.

 The doubling is the part worth a test. A line per creation past the threshold
 would bury the one that mattered under the loop that caused it, and a threshold
 that did not move would say the same sentence forever. Read before and compared
 after, so this pins the behaviour and not the constant.

 `create_texture_material` rather than `create_material`, because this needs a
 lot of materials and none of them needs a compile: it takes a reference on a
 pipeline the pass already holds. What is being counted is materials, and every
 one of them holds a pipeline whether Slang ran for it or not.

 **Proved by injection.** `note_material_claimed` returning before the doubling:
 "the next word waits for twice the count: 64 then 64" — and every creation from
 then on prints.
*>
fn void the_material_warning_waits_for_twice_the_count() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::MeshPass* pass = &renderer.pass;
		uint threshold = pass.material_warn_at;
		test::@check(threshold > 0, "there is a threshold to cross: %d", threshold);
		// The two built-in materials are claimed by `init` and go through the same
		// counter. They must not have warned about *themselves* on the way in,
		// which they did until the threshold was set before those two claims
		// rather than after them — a fresh scene printed two lines about holding
		// one material and then two.
		test::@check(pass.live_materials == 0, "the built-ins are not counted: %d", pass.live_materials);
		test::@check(threshold == three::MATERIAL_WARN_AT,
			"and nothing has fired yet: %d", threshold);

		while (pass.live_materials < threshold - 1)
		{
			pass.create_texture_material(three::NO_TEXTURE)!!;
		}
		test::@check(pass.material_warn_at == threshold,
			"nothing said below it: %d", pass.material_warn_at);

		pass.create_texture_material(three::NO_TEXTURE)!!;
		test::@check(pass.material_warn_at == threshold * 2,
			"the next word waits for twice the count: %d then %d", threshold, pass.material_warn_at);
	};
}

<*
 A disposed material gives its image back too.

 The material holds one reference to the texture slot it names — the one
 `create_texture_material` took — and collecting it has to give that back or the
 image outlives everything that ever pointed at it. Asserted through the count
 rather than through a picture, because the leak this catches is invisible in
 every frame: the texture is still correct, it is just immortal.

 **Proved by injection.** The release dropped from `free_material`: "the
 material's reference came back with it: 2".
*>
fn void a_disposed_material_gives_its_image_back() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::MeshPass* pass = &renderer.pass;
		three::Assets* assets = &pass.assets;

		int texture = assets.load_texture_file(&renderer.gpu, CHECKER)!!;
		uint material = pass.create_texture_material(texture)!!;
		test::@check(assets.texture_refs(texture) == 2,
			"the script's handle and the material: %d", assets.texture_refs(texture));

		pass.dispose_material(&renderer.gpu, material)!!;
		test::@check(assets.texture_refs(texture) == 1,
			"the material's reference came back with it: %d", assets.texture_refs(texture));

		assets.release_texture(&renderer.gpu, texture);
		test::@check(assets.texture_refs(texture) == 0, "and the last one is the script's");
	};
}

<*
 The built-in materials refuse to be disposed.

 `the_built_in_materials_refuse_a_map`'s argument, applied to the sharper verb.
 `DEFAULT_MATERIAL` is what every node that never asked for a material draws
 with, so collecting it would take the pipeline out from under the whole scene
 through a handle that reads like it names one thing. `LINE_MATERIAL` is every
 debug helper's.

 **Proved by injection.** The guard removed from `dispose_material`: "built-in
 material 0 was disposed out from under every node".
*>
fn void the_built_in_materials_refuse_dispose() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		uint[2] built_in = { three::DEFAULT_MATERIAL, three::LINE_MATERIAL };
		foreach (index : built_in)
		{
			if (catch err = renderer.pass.dispose_material(&renderer.gpu, index))
			{
				test::@check(err == three::MATERIAL_UNKNOWN, "material %d refused with %s", index, err);
			}
			else
			{
				test::@check(false, "built-in material %d was disposed out from under every node", index);
			}
			test::@check(renderer.pass.material(index) != null, "and material %d is still there", index);
		}
	};
}

<*
 A material gives back the images its own samplers held.

 The lifetime half of `textures:`. A `ShaderMaterial` can now hold up to five
 references into the texture table — `map` and four samplers of its own — and
 every one of them has to come back when the material is collected, or a script
 that rebuilds its materials every run leaks an image per run and
 `scene.unload()` quietly stops emptying.

 Three separate moments are checked, because they are three different pieces of
 code: taking a reference (`set_material_texture` retains), replacing one
 (retain the new, release the old — and the retain comes *first*, because the two
 indices can name one slot), and collecting the material (`free_material` walks
 the bindings). A test that only checked the last would pass with the middle one
 leaking.

 **Proved by injection.** The sampler loop removed from `free_material`: "the
 material gave its samplers back: 2" — the images stay pinned at the count the
 material took them to, and every other test in the suite stays green.
*>
fn void a_material_gives_back_the_textures_its_samplers_held() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::MeshPass* pass = &renderer.pass;

		int red = solid_texture(renderer, 220, 40, 40);
		int green = solid_texture(renderer, 40, 220, 60);
		test::@check(pass.assets.texture_refs(red) == 1, "the table holds each image once to start with");

		uint material;
		@pool()
		{
			three::MaterialTexture[2] textures = { { "noise_map" }, { "ramp_map" } };
			material = pass.create_material(
				&renderer.gpu,
				&renderer.target,
				`float3 shade(Surface s)
				{
				    return noise_map.Sample(s.uv).rgb * ramp_map.Sample(s.uv).rgb;
				}`,
				{},
				three::SIDE_FRONT,
				three::BLENDING_NONE,
				textures[..]
			)!!;
		};

		// Declared but not yet filled: the samplers exist and hold nothing, which
		// is the state a body reads as white.
		test::@check(pass.material_texture(material, "noise_map") == three::NO_TEXTURE,
			"a declared sampler starts empty");

		pass.set_material_texture(&renderer.gpu, material, "noise_map", red)!!;
		pass.set_material_texture(&renderer.gpu, material, "ramp_map", green)!!;
		test::@check(pass.assets.texture_refs(red) == 2,
			"the material took a reference: %d", pass.assets.texture_refs(red));
		test::@check(pass.material_texture(material, "noise_map") == red, "and reads back by name");

		// Replacing one gives the old image back and holds the new one, which is
		// where a release-before-retain would take a shared slot to zero.
		pass.set_material_texture(&renderer.gpu, material, "noise_map", green)!!;
		test::@check(pass.assets.texture_refs(red) == 1,
			"replacing released the old image: %d", pass.assets.texture_refs(red));
		test::@check(pass.assets.texture_refs(green) == 3,
			"and both samplers now name the new one: %d", pass.assets.texture_refs(green));

		// A name the shader does not have is refused rather than ignored, and a
		// texture that is not there is a different fault from a sampler that is not.
		fault unknown = @catch(pass.set_material_texture(&renderer.gpu, material, "no_such_map", red));
		test::@check(unknown == three::MATERIAL_SAMPLER_UNKNOWN, "an unknown sampler is refused, got %s", unknown);
		fault dead = @catch(pass.set_material_texture(&renderer.gpu, material, "noise_map", 4242));
		test::@check(dead == three::MATERIAL_TEXTURE_UNKNOWN, "and an unknown texture is its own fault, got %s", dead);

		pass.dispose_material(&renderer.gpu, material)!!;
		test::@check(pass.material(material) == null, "the material was collected");
		test::@check(pass.assets.texture_refs(green) == 1,
			"and gave its samplers back: %d", pass.assets.texture_refs(green));
	};
}

<*
 A one-pixel image, uploaded, for a test that needs a texture and does not care
 what is in it.
*>
fn int solid_texture(three::Renderer* renderer, char r, char g, char b)
{
	char[4] pixels = { r, g, b, 255 };
	image::Image one = {
		.width = 1,
		.height = 1,
		.bit_depth = 8,
		.format = image::PixelFormat.RGBA,
		// No allocator, left at the zero fill: `Image.free` frees nothing without
		// one, which is what makes a stack array safe to hand over here.
		.pixels = pixels[..],
	};
	return renderer.pass.assets.claim_texture(&renderer.gpu, one)!!;
}
