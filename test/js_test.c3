<*
 The JS binding: the run contract, the handles, and the scene an agent builds.

	`c3c test --trust=full --test-noleak --test-filter three_tests::js`

 Most of this needs no GPU. The scene graph, the handles, the staleness checks
 and `stats()` are all reachable with a `MeshPass` that was never given a
 pipeline, which is what makes the binding suite run in microseconds — and it is
 the same argument `scene_test.c3` makes: the failures worth catching here are
 silent, and a silent failure caught in a millisecond gets caught more often.

 **Assert on the answer, not on the absence of an error.** A script that throws
 and a script that returns nothing both leave `value` empty, so every check that
 cares reads `ok` *and* the field it expects.
*>
module three_tests::js;

import three;
import vk;
import qjs;
import image;
import std::core::test;
import std::io;
import std::math;

const String FIXTURE = "test/fixtures/textured.glb";

<*
 A runtime over a scene with no device behind it.

 `MeshPass` is built by hand rather than through `init`, which would want a
 pipeline and therefore a GPU. Everything the scene layer does works without one.
*>
macro @with_js(; @body(three::JsRuntime* run))
{
	three::MeshPass pass;
	pass.scene.init();
	pass.assets.init();
	pass.scene.attach_assets(&pass.assets);
	pass.camera = three::default_camera();
	defer pass.scene.free();
	// Null device, which `Assets.free` only ever reaches through a texture or a
	// pool — and with nothing loaded there are none of either.
	defer pass.assets.free(null);

	three::JsRuntime runtime;
	runtime.open(&pass)!!;
	defer runtime.close();

	@body(&runtime);
}

<*
 A runtime with a headless device, for the checks that load a file or draw.
*>
macro @with_gpu_js(; @body(three::JsRuntime* run))
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

	@body(&runtime);
}

// ============================================================================
// The run contract (plan.md §4)
// ============================================================================

fn void a_script_returns_what_it_returned() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run("return 1 + 1;");
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == "2", "value is 2, got '%s'", result.value);
	};
}

<*
 Returning nothing and returning null are different answers.

 `undefined` has no JSON form, so `value` is empty; `null` is the four characters
 that JSON spells it with. Collapsing the two would make "the script produced no
 result" and "the script produced null" the same string, and only one of those
 means the agent should look at the log.
*>
fn void nothing_and_null_are_different_answers() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult silent = run.run("const x = 1;");
		defer silent.free();
		test::@check(silent.ok, "the script succeeded: %s", silent.error);
		test::@check(silent.value == "", "no return is an empty value, got '%s'", silent.value);

		three::RunResult explicit = run.run("return null;");
		defer explicit.free();
		test::@check(explicit.value == "null", "return null is 'null', got '%s'", explicit.value);
	};
}

fn void everything_logged_comes_back() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`console.log("one"); console.warn("two"); return 3;`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.log == "one\ntwo\n", "log is both lines, got '%s'", result.log);
		test::@check(result.value == "3", "and the value survived alongside it");
	};
}

<*
 An object logged as `[object Object]` would make `console.log(scene.stats())`
 useless, and that is the one call an agent makes to see its own cost.
*>
fn void an_object_logs_as_json() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`console.log({ drawCalls: 1 });`);
		defer result.free();

		test::@check(result.log == "{\"drawCalls\":1}\n", "logged as JSON, got '%s'", result.log);
	};
}

<*
 A failed run still answers with everything it got to.

 `plan.md` §4: all four, every time. A failure that returns only an error string
 makes the agent guess how far it got, and the log is the only thing that says.
*>
fn void a_failed_run_still_returns_its_log() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`console.log("got here"); throw new Error("boom");`);
		defer result.free();

		test::@check(!result.ok, "the script failed");
		test::@check(result.log == "got here\n", "the log survived the throw, got '%s'", result.log);
		test::@check(result.error.contains("boom"), "the message is carried: %s", result.error);
		test::@check(result.error.contains("at "), "and so is the stack: %s", result.error);
	};
}

<*
 The script's line 1 is line 1 in the trace.

 The async wrapper's open brace deliberately carries no newline, so a stack that
 points at line 3 points at the agent's line 3. Getting this wrong is invisible
 until someone tries to fix a script by the number in the error.
*>
fn void a_stack_points_at_the_scripts_own_lines() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run("const a = 1;\nconst b = 2;\nthrow new Error('third line');");
		defer result.free();

		test::@check(!result.ok, "the script failed");
		test::@check(result.error.contains(":3"), "the trace names line 3: %s", result.error);
	};
}

fn void a_syntax_error_is_reported_as_one() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run("this is not javascript");
		defer result.free();

		test::@check(!result.ok, "the script failed");
		test::@check(result.error.contains("SyntaxError"), "named as a syntax error: %s", result.error);
	};
}

<*
 `while (true) {}` has to end.

 The interrupt handler is the only thing that can stop it, and nothing else in
 the suite arms it — a budget that silently never fires would leave the whole
 agent loop one bad script away from a hang.
*>
fn void an_endless_loop_is_stopped() @test
{
	@with_js(; three::JsRuntime* run)
	{
		run.budget_ns = 200 * 1_000_000;

		three::RunResult result = run.run("while (true) {}");
		defer result.free();

		test::@check(!result.ok, "the script was stopped");
		test::@check(result.error.contains("longer than"), "and says why: %s", result.error);
	};
}

<*
 A promise that never settles is not a hang either, and says something different
 from a timeout: nothing is running, so there is nothing to interrupt.
*>
fn void an_await_that_never_resolves_is_reported() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run("await new Promise(() => {});");
		defer result.free();

		test::@check(!result.ok, "the script did not succeed");
		test::@check(result.error.contains("never finished"), "and says what happened: %s", result.error);
	};
}

<*
 `const kit = await three.load(...)` is the line an agent that has memorized
 Three.js writes, and a SyntaxError on it would be the API being surprising on
 the first line of the first script.
*>
fn void top_level_await_works() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run("const v = await Promise.resolve(41);\nreturn v + 1;");
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == "42", "value is 42, got '%s'", result.value);
	};
}

<*
 One script cannot see another's declarations.

 Each run is its own function body, so `const` in one does not collide with the
 same name in the next — an agent iterating on a script would otherwise get
 "already declared" on its second attempt and have to rename everything.
*>
fn void scripts_do_not_leak_declarations_into_each_other() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult first = run.run("const shared = 1; globalThis.kept = 7; return shared;");
		defer first.free();
		test::@check(first.ok, "the first script succeeded: %s", first.error);

		three::RunResult second = run.run("const shared = 2; return shared + globalThis.kept;");
		defer second.free();
		test::@check(second.ok, "the second script redeclared it freely: %s", second.error);
		test::@check(second.value == "9", "and globalThis still carried state, got '%s'", second.value);
	};
}

// ============================================================================
// The scene, from JavaScript
// ============================================================================

fn void the_docs_describe_the_surface() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run("return three.getApiDocs();");
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value.contains("drawCalls"), "the stats block is described");
		test::@check(result.value.contains("one scene at a time"), "and so is every divergence from Three.js");
	};
}

<*
 An object is not in the scene until it is added — Three.js's rule, and the one
 that stops an unadded mesh from quietly rendering.
*>
fn void an_object_joins_the_scene_only_when_added() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			const g = new three.Group();
			g.position.set(5, 0, 0);
			const before = scene.stats().nodes;
			scene.add(g);
			return [before, scene.stats().nodes];
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == "[1,2]", "the root alone, then the root and the group; got %s", result.value);
	};
}

<*
 A transform set before the add is replayed onto the node, not lost.
*>
fn void a_transform_set_before_the_add_survives_it() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			const outer = new three.Group();
			const inner = new three.Group();
			outer.position.set(10, 0, 0);
			inner.position.set(0, 4, 0);
			outer.add(inner);
			scene.add(outer);
			return inner.getWorldPosition().toArray();
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == "[10,4,0]", "the whole subtree landed where it was told; got %s", result.value);
	};
}

<*
 `plan.md` §1: a JS handle revalidates on access and throws rather than
 dereferencing a freed node. This is that requirement, from the JS side.
*>
fn void a_handle_into_a_removed_object_throws() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			const g = new three.Group();
			scene.add(g);
			const stolen = { i: g._i, gen: g._g };
			scene.remove(g);
			try {
				__three.setVisible(stolen.i, stolen.gen, false);
				return "no throw";
			} catch (e) {
				return e.message;
			}
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value.contains("no longer in the scene"), "the stale handle threw; got %s", result.value);
	};
}

<*
 Replacing the scene is loud rather than silent.

 There is one host scene, so a second `new three.Scene()` empties the first — and
 the divergence from Three.js is made to say so, because the alternative is the
 older Scene quietly operating on the newer one's nodes.
*>
fn void a_replaced_scene_says_so() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const first = new three.Scene();
			first.add(new three.Group());
			const second = new three.Scene();
			try {
				first.add(new three.Group());
				return "no throw";
			} catch (e) {
				return e.message;
			}
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value.contains("replaced"), "the older Scene refused; got %s", result.value);
	};
}

<*
 Re-parenting keeps the node rather than rebuilding it.

 Three.js's `add` moves an object that already has a parent, and doing that by
 destroy-and-recreate would climb the generation and invalidate every handle to
 something that never left the scene.
*>
fn void reparenting_keeps_the_same_node() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			const a = new three.Group();
			const b = new three.Group();
			const child = new three.Group();
			scene.add(a, b);
			a.add(child);
			const was = [child._i, child._g];
			b.add(child);
			return {
				same: child._i === was[0] && child._g === was[1],
				parent: b.children.indexOf(child) === 0,
				gone: a.children.length === 0,
			};
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == `{"same":true,"parent":true,"gone":true}`,
			"the node moved without being rebuilt; got %s", result.value);
	};
}

fn void a_cycle_is_refused() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			const a = new three.Group();
			const b = new three.Group();
			scene.add(a);
			a.add(b);
			try { b.add(a); return "no throw"; } catch (e) { return e.message; }
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value.contains("ancestor"), "the cycle was refused; got %s", result.value);
	};
}

<*
 Without a device, the two verbs that need one say which is missing rather than
 failing somewhere further in.
*>
fn void loading_without_a_device_says_so() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`three.load("anything.glb");`);
		defer result.free();

		test::@check(!result.ok, "the script failed");
		test::@check(result.error.contains("GPU device"), "and named the reason: %s", result.error);
	};
}

// ============================================================================
// With a device
// ============================================================================

<*
 `plan.md` §5's done condition for M3, as a script.

 Twelve meshes sharing one asset reference is one draw call, and that is asserted
 through the JS API rather than through `Scene` directly — the whole point of the
 milestone is that the property survives the binding.
*>
fn void the_tier_one_example_builds_one_draw_call() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const kit = await three.load("test/fixtures/textured.glb");
			const wall = kit.mesh(kit.meshes[0]);

			const scene = new three.Scene();
			for (let i = 0; i < 12; i++) {
				const m = new three.Mesh(wall);
				m.position.set(i * 2, 0, 0);
				m.rotation.y = Math.PI / 2;
				scene.add(m);
			}

			three.camera.frameAll();
			three.render(scene, three.camera);
			return scene.stats();
		`);
		defer result.free();

		test::@check(result.ok, "the example ran: %s", result.error);
		test::@check(result.stats.draw_calls == 1, "one draw call, got %d", result.stats.draw_calls);
		test::@check(result.stats.instances == 12, "twelve instances, got %d", result.stats.instances);
		test::@check(result.value.contains(`"drawCalls":1`), "and the script saw the same: %s", result.value);
	};
}

<*
 Two different meshes are two draws; twelve of each is still two.

 The check that `drawCalls` counts distinct geometry rather than counting
 anything about how many times `add` was called.
*>
fn void two_meshes_are_two_draws_however_many_instances() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const kit = await three.load("test/fixtures/textured.glb");
			const scene = new three.Scene();
			for (let i = 0; i < 12; i++) {
				for (const name of kit.meshes) {
					const m = new three.Mesh(kit.mesh(name));
					m.position.set(i, 0, 0);
					scene.add(m);
				}
			}
			return scene.stats();
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.stats.unique_meshes == 2, "two unique meshes, got %d", result.stats.unique_meshes);
		test::@check(result.stats.draw_calls == 2, "two draw calls, got %d", result.stats.draw_calls);
		test::@check(result.stats.instances == 24, "twenty-four instances, got %d", result.stats.instances);
	};
}

<*
 Loading the same path twice is one asset — "linked, not duplicated" (§2), seen
 from the API rather than from the loader.
*>
fn void loading_the_same_file_twice_uploads_once() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const a = three.load("test/fixtures/textured.glb");
			const b = three.load("test/fixtures/textured.glb");
			const scene = new three.Scene();
			scene.add(new three.Mesh(a.meshAt(0)));
			scene.add(new three.Mesh(b.meshAt(0)));
			return scene.stats();
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.stats.instances == 2, "both meshes were placed, got %d", result.stats.instances);
		test::@check(result.stats.draw_calls == 1, "and they bucket together, got %d", result.stats.draw_calls);
	};
}

fn void a_bad_path_says_which_path() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`three.load("no/such/file.glb");`);
		defer result.free();

		test::@check(!result.ok, "the script failed");
		test::@check(result.error.contains("no/such/file.glb"), "the path is in the message: %s", result.error);
	};
}

// ============================================================================
// Shapes
// ============================================================================
//
// `scene/primitive.c3` builds them and `test/primitive_test.c3` checks what they
// are shaped like, with no device in sight. What is left for here is the part
// that only exists once there is one: that a shape uploads, that it reaches the
// screen, that it can be picked, and — the claim the whole design turns on —
// that constructing the same one a hundred times costs one asset and one draw
// call.

<*
 A scene with no file in it, and the Three.js habit costing nothing.

 **A geometry per mesh is what an agent will write**, because that is what
 Three.js requires; under Three.js it is also N uploads and N draws unless the
 author knows about `InstancedMesh`. The dedup in `Assets.primitive` is what
 makes the naive loop the fast one here, and this is the assertion that it is:
 a hundred separately constructed `BoxGeometry`s, one unique mesh, one draw.
*>
fn void a_shape_needs_no_file_and_a_hundred_of_them_is_one_draw() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			for (let i = 0; i < 100; i++) {
				const cube = new three.Mesh(new three.BoxGeometry(1, 1, 1));
				cube.position.set((i % 10) * 2, 0, Math.floor(i / 10) * 2);
				scene.add(cube);
			}
			three.camera.frameAll();
			three.render(scene, three.camera);
			return scene.stats();
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.stats.instances == 100, "a hundred instances, got %d", result.stats.instances);
		test::@check(result.stats.unique_meshes == 1, "one unique mesh, got %d", result.stats.unique_meshes);
		test::@check(result.stats.draw_calls == 1, "one draw call, got %d", result.stats.draw_calls);
		// Twelve triangles a box, so the count also says the box is a box.
		test::@check(result.stats.triangles == 1200, "1200 triangles, got %d", result.stats.triangles);
	};
}

<*
 Two sizes are two assets, and scale is the free axis.

 The other half of the dedup, and the half worth telling an agent about: a
 hundred *different* `BoxGeometry`s are a hundred uploads and a hundred draws,
 while a hundred copies of one box under a hundred scales are one of each. Both
 halves are asserted here because a test for the first alone would pass on an
 implementation that returned the same asset for every box regardless of its
 numbers — which would be the wrong shape rather than a slow scene.
*>
fn void two_sizes_are_two_assets_and_scale_is_free() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult sizes = run.run(`
			const scene = new three.Scene();
			for (let i = 0; i < 8; i++) {
				scene.add(new three.Mesh(new three.BoxGeometry(1 + i, 1, 1)));
			}
			return scene.stats();
		`);
		defer sizes.free();

		test::@check(sizes.ok, "the script succeeded: %s", sizes.error);
		test::@check(sizes.stats.unique_meshes == 8, "eight sizes are eight meshes, got %d", sizes.stats.unique_meshes);
		test::@check(sizes.stats.draw_calls == 8, "and eight draws, got %d", sizes.stats.draw_calls);

		three::RunResult scaled = run.run(`
			const scene = new three.Scene();
			const box = new three.BoxGeometry(1, 1, 1);
			for (let i = 0; i < 8; i++) {
				const m = new three.Mesh(box);
				m.scale.set(1 + i, 1, 1);
				scene.add(m);
			}
			return scene.stats();
		`);
		defer scaled.free();

		test::@check(scaled.ok, "the script succeeded: %s", scaled.error);
		test::@check(scaled.stats.instances == 8, "eight instances, got %d", scaled.stats.instances);
		test::@check(scaled.stats.draw_calls == 1, "the same eight sizes by scale are one draw, got %d", scaled.stats.draw_calls);
	};
}

<*
 A cone and the cylinder that spells it are one asset.

 `ConeGeometry(r, h)` asks the host for `cylinder(0, r, h)`, so the two reach the
 same key and the same upload. Asserted through `stats()` rather than by
 comparing the two `asset` numbers, because the number being equal is the
 mechanism and the draw call being one is the point.
*>
fn void a_cone_and_the_cylinder_that_spells_it_are_one_draw() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			const cone = new three.Mesh(new three.ConeGeometry(1, 2, 32, 1));
			const spelt = new three.Mesh(new three.CylinderGeometry(0, 1, 2, 32, 1));
			spelt.position.x = 3;
			scene.add(cone, spelt);
			return { stats: scene.stats(), same: cone.geometry.asset === spelt.geometry.asset };
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.stats.instances == 2, "both were placed, got %d", result.stats.instances);
		test::@check(result.stats.draw_calls == 1, "and they bucket together, got %d", result.stats.draw_calls);
		test::@check(result.value.contains(`"same":true`), "the two spellings share an asset: %s", result.value);
	};
}

<*
 A hull is an asset like any other: deduped, instanced, and refused when the
 cloud describes nothing.

 The dedup is the claim worth asserting with a device behind it, because it is
 the one that makes the Three.js habit cheap for the shape that costs the most to
 build. A geometry per mesh is what an agent writes; here fifty of them from one
 array are one quickhull, one upload and one draw call, and the second
 construction never reaches the hull at all — `Assets.convex` asks `Assets.built`
 before it computes anything.

 The three refusals are in the same test rather than three of their own because
 what is being checked is that each comes back as a *sentence a script can act
 on*, and they are only comparable side by side. The degenerate case is the one
 that has to travel furthest: quickhull answers with an empty mesh, `Assets.convex`
 turns that into a fault, and `js_convex` turns the fault into the three ways a
 cloud can be flat — which is the fact the agent needs and the fault name does
 not carry.
*>
fn void a_hull_is_deduped_instanced_and_refused_like_any_shape() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();

			// One cloud, fifty separately constructed geometries.
			const cloud = [];
			for (let i = 0; i < 40; i++) {
				cloud.push([Math.cos(i * 1.1), Math.sin(i * 1.7), Math.cos(i * 2.3)]);
			}
			let first = null;
			for (let i = 0; i < 50; i++) {
				const geometry = new three.ConvexGeometry(cloud);
				if (first === null) first = geometry.asset;
				const rock = new three.Mesh(geometry);
				rock.position.set((i % 10) * 3, 0, Math.floor(i / 10) * 3);
				rock.color = [i / 50, 0.5, 1 - i / 50, 1];
				scene.add(rock);
			}

			// The same eight corners, spelled three ways.
			const flat = [-1,-1,-1, 1,-1,-1, 1,1,-1, -1,1,-1, -1,-1,1, 1,-1,1, 1,1,1, -1,1,1];
			const vectors = [];
			for (let i = 0; i < flat.length; i += 3) {
				vectors.push(new three.Vector3(null, flat[i], flat[i + 1], flat[i + 2]));
			}
			const a = new three.ConvexGeometry(flat);
			const b = new three.ConvexGeometry(vectors);
			const c = new three.ConvexGeometry(new Float32Array(flat));
			// Placed, so that stats() counts it: unique_meshes is what the scene
			// holds, not what has been uploaded.
			const cube = new three.Mesh(a);
			cube.position.set(-6, 0, 0);
			scene.add(cube);

			const refuse = (fn) => { try { fn(); return "no throw"; } catch (e) { return e.message; } };

			three.camera.frameAll();
			three.render(scene, three.camera);
			return {
				stats: scene.stats(),
				oneAsset: new three.ConvexGeometry(cloud).asset === first,
				spellings: a.asset === b.asset && b.asset === c.asset,
				cubeIsACube: a.parameters.points === 8,
				tooFew: refuse(() => new three.ConvexGeometry([[0,0,0],[1,0,0],[0,1,0]])),
				flatCloud: refuse(() => new three.ConvexGeometry([[0,0,0],[1,0,0],[0,1,0],[1,1,0],[2,5,0]])),
				capped: refuse(() => new three.ConvexGeometry(new Float32Array(70000 * 3))),
			};
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.stats.instances == 51, "fifty rocks and a cube were placed, got %d", result.stats.instances);
		test::@check(
			result.stats.unique_meshes == 2,
			"one hull for the cloud and one for the cube, got %d", result.stats.unique_meshes
		);
		test::@check(
			result.stats.draw_calls == 2,
			"the fifty rocks are one draw and the cube is the other, got %d", result.stats.draw_calls
		);
		// Twelve triangles for the cube, so the count also says the hull of eight
		// corners is those eight corners and not a shape with a face shaved off.
		// The cloud's own face count is left open on purpose: it comes out of
		// Math.cos and Math.sin, and pinning it here would make the suite fail on
		// a platform whose libm rounds a coordinate differently rather than on a
		// change to anything in this repository. That the remainder is fifty
		// identical hulls is the claim, and it is the one that would break.
		test::@check(
			result.stats.triangles > 12 && (result.stats.triangles - 12) % 50 == 0,
			"a twelve-triangle cube and fifty copies of one hull, got %d triangles", result.stats.triangles
		);
		test::@check(result.value.contains(`"oneAsset":true`), "the same cloud is the same asset: %s", result.value);
		test::@check(
			result.value.contains(`"spellings":true`),
			"Vector3s, [x,y,z] and a Float32Array reach one asset: %s", result.value
		);
		test::@check(result.value.contains(`"cubeIsACube":true`), "the cube kept its point count: %s", result.value);

		// Each refusal names what to do about it, which is the whole reason the
		// host does not hand the fault name over.
		test::@check(result.value.contains("at least 4 points"), "too few points says how many: %s", result.value);
		test::@check(result.value.contains("enclose no volume"), "a flat cloud says it is flat: %s", result.value);
		test::@check(result.value.contains("65536"), "the cap names itself: %s", result.value);
	};
}

<*
 Every shape reaches the screen.

 The complement to `primitive_test.c3`'s winding checks, and deliberately a
 weaker claim made a different way: that one says the triangles face outward by
 arithmetic on the triangles, and this one says the whole path — build, upload,
 index buffer, buffer device address, draw — puts pixels in the frame for each
 of the seven. Neither substitutes for the other. An inside-out sphere would pass
 this and fail that; a shape that was never uploaded fails this and passes that.
 `convex_test.c3` makes the same pair of claims about the hull.

 The threshold is deliberately low. `frameAll` fits a bounding sphere with room
 around it, so a torus seen edge-on covers a small fraction of the image and the
 assertion worth making is "something recognisably large is there", not a
 coverage number that has to be re-tuned whenever the camera fit changes.
*>
fn void every_shape_reaches_the_screen() @test
{
	String[7] shapes = {
		"new three.BoxGeometry(1, 1, 1)",
		"new three.SphereGeometry(1, 32, 16)",
		"new three.PlaneGeometry(2, 2)",
		"new three.CylinderGeometry(1, 1, 2)",
		"new three.ConeGeometry(1, 2)",
		"new three.TorusGeometry(1, 0.4)",
		// The hull of a cube's corners, which is that cube — so this asserts the
		// same coverage the BoxGeometry line does, reached by the other path.
		"new three.ConvexGeometry([-1,-1,-1, 1,-1,-1, 1,1,-1, -1,1,-1, -1,-1,1, 1,-1,1, 1,1,1, -1,1,1])",
	};

	@with_gpu_js(; three::JsRuntime* run)
	{
		foreach (shape : shapes)
		{
			three::RunResult built = run.run(string::tformat(`
				const scene = new three.Scene();
				scene.add(new three.Mesh(%s));
				three.camera.lookAt(0, 0, 0);
				three.camera.orbit(35, 25);
				three.camera.frameAll();
				three.render(scene, three.camera);
			`, shape));
			defer built.free();
			test::@check(built.ok, "%s drew: %s", shape, built.error);

			image::Image frame = run.renderer.capture()!!;
			defer frame.free();

			int back_r = (int)frame.pixels[0];
			int back_g = (int)frame.pixels[1];
			int back_b = (int)frame.pixels[2];

			usz drawn = 0;
			for (usz at = 0; at < (usz)frame.width * frame.height * 4; at += 4)
			{
				int dr = (int)frame.pixels[at] - back_r;
				int dg = (int)frame.pixels[at + 1] - back_g;
				int db = (int)frame.pixels[at + 2] - back_b;
				if (math::abs(dr) + math::abs(dg) + math::abs(db) > 24) drawn++;
			}

			usz total = (usz)frame.width * frame.height;
			test::@check(
				drawn > total / 50,
				"%s covered more than a fiftieth of the frame, got %d of %d pixels", shape, drawn, total
			);
		}
	};
}

<*
 A generated shape can be picked, and the hit is where the shape's surface is.

 The BVH is built from the generated positions, so this is the check that they
 are the positions the shape claims: a unit box at the origin seen from +Z has
 its front face at z = 0.5, and a picker that agreed with a box of some other
 size — or with no tree at all — would answer somewhere else or not at all.

 It also closes the loop between the two halves of this feature. `stats()` says
 how many triangles were placed and a screenshot says something was drawn; only
 a pick says *the geometry is where the parameters put it*.
*>
fn void a_generated_shape_can_be_picked_where_its_surface_is() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			const cube = new three.Mesh(new three.BoxGeometry(1, 1, 1));
			cube.name = "cube";
			scene.add(cube);

			three.camera.lookAt(0, 0, 0);
			three.camera.orbit(0, 0, 5);

			const { width, height } = three.renderSize();
			const hit = scene.pick(width / 2, height / 2);
			if (hit === null) return { hit: null };
			return {
				name: hit.name,
				same: hit.object === cube,
				z: Math.round(hit.point.z * 1000) / 1000,
				normal: Math.round(hit.normal.z * 1000) / 1000,
			};
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(
			result.value == `{"name":"cube","same":true,"z":0.5,"normal":1}`,
			"the centre pick lands on the box's front face at z = 0.5 facing +Z; got %s", result.value
		);
	};
}

<*
 A shape is named by its own constructor, and remembers what it was asked for.

 `parameters` is Three.js's, and it earns its place here for a reason Three.js
 does not have: an agent that has just built a scene and wants to know what is in
 it reads it back out of `toJSON`, and "BoxGeometry" with no numbers would leave
 it re-deriving sizes from world positions.
*>
fn void a_shape_says_what_it_is_and_what_it_was_asked_for() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const box = new three.BoxGeometry(2, 1, 3);
			const mesh = new three.Mesh(box);
			return {
				type: box.type,
				name: box.name,
				parameters: box.parameters,
				geometryIsTheOnePassed: mesh.geometry === box,
				isGeometry: box instanceof three.Geometry && box instanceof three.BoxGeometry,
				defaults: new three.SphereGeometry().parameters,
			};
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value.contains(`"type":"BoxGeometry"`), "it knows its type: %s", result.value);
		test::@check(
			result.value.contains(`"parameters":{"width":2,"height":1,"depth":3,"widthSegments":1,"heightSegments":1,"depthSegments":1}`),
			"and what it was asked for, defaults filled in: %s", result.value
		);
		test::@check(result.value.contains(`"geometryIsTheOnePassed":true`), "mesh.geometry is it: %s", result.value);
		test::@check(result.value.contains(`"isGeometry":true`), "and it is a Geometry: %s", result.value);
		// Three.js's defaults, which are what an agent will assume when it leaves
		// the arguments out.
		test::@check(
			result.value.contains(`"defaults":{"radius":1,"widthSegments":32,"heightSegments":16}`),
			"a bare SphereGeometry is Three.js's default sphere: %s", result.value
		);
	};
}

<*
 `new three.Mesh(geometry, material)` — Three.js's two arguments, in Three.js's
 order.

 The material goes through the same setter an assignment would, so the type
 check and the "not in the scene yet" replay are the ones already tested; what
 is new is that the argument exists at all, and that a bad one throws at the
 constructor rather than at the add.
*>
fn void a_mesh_takes_its_material_in_the_constructor() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const mat = new three.ShaderMaterial({
				uniforms: { tint: [1, 0, 0] },
				fragment: "float3 shade(Surface s) { return tint * lambert(s.normal); }",
			});
			const scene = new three.Scene();
			const ball = new three.Mesh(new three.SphereGeometry(1), mat);
			scene.add(ball);
			three.camera.frameAll();
			three.render(scene, three.camera);

			let refused = "";
			try {
				new three.Mesh(new three.BoxGeometry(1, 1, 1), { fragment: "not a material" });
			} catch (e) {
				refused = e.message;
			}
			return { assigned: ball.material === mat, refused, stats: scene.stats() };
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value.contains(`"assigned":true`), "the material was assigned: %s", result.value);
		test::@check(
			result.value.contains("ShaderMaterial"),
			"and something that is not one is refused by name: %s", result.value
		);
		test::@check(result.stats.draw_calls == 1, "the shaded sphere is one draw, got %d", result.stats.draw_calls);
	};
}

<*
 A shape that cannot be built says which number was wrong.

 Every one of these is a typo an agent will make, and each message names the
 argument rather than the failure — `RangeError: ... width must be a positive
 number, got 0` is a line it can fix without reading this file.
*>
fn void a_shape_that_cannot_be_built_names_the_number() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const said = [];
			const refuse = (what, f) => {
				try { f(); said.push(what + ": nothing was thrown"); }
				catch (e) { said.push(what + ": " + e.message); }
			};

			refuse("zero width", () => new three.BoxGeometry(0, 1, 1));
			refuse("negative radius", () => new three.SphereGeometry(-1));
			refuse("too few segments", () => new three.CylinderGeometry(1, 1, 1, 2));
			refuse("too many segments", () => new three.SphereGeometry(1, 4096, 16));
			refuse("a cone with no radius at all", () => new three.CylinderGeometry(0, 0, 1));
			refuse("nothing at all", () => new three.BoxGeometry(undefined, NaN, 1));
			return said;
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value.contains("width must be a positive number, got 0"), "%s", result.value);
		test::@check(result.value.contains("radius must be a positive number, got -1"), "%s", result.value);
		test::@check(result.value.contains("radialSegments must be at least 3, got 2"), "%s", result.value);
		test::@check(result.value.contains("widthSegments is capped at 512"), "%s", result.value);
		test::@check(result.value.contains("both radii are zero"), "%s", result.value);
		test::@check(result.value.contains("height must be a positive number, got NaN"), "%s", result.value);
		test::@check(!result.value.contains("nothing was thrown"), "every one of them threw: %s", result.value);
	};
}

<*
 A made-up shape name is refused by the host verb, with the real ones listed.

 Only reachable by calling `__three.primitive` directly, which is not the API —
 but the flat verb layer is readable from a script and a forged call has to be
 answered with a sentence rather than with a switch falling through to a box.
*>
fn void a_shape_the_host_does_not_build_says_which_it_does() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			try { __three.primitive("teapot", 1, 1, 1, 1, 1, 1, false); }
			catch (e) { return e.message; }
			return "nothing was thrown";
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value.contains("teapot"), "the name is in the message: %s", result.value);
		test::@check(result.value.contains("box, sphere, plane, cylinder, torus"), "and the real ones: %s", result.value);
	};
}

<*
 Building a shape without a device says so, the way `three.load` does.

 The scene-math runtime has no GPU, and "cannot read property of null" is not an
 answer an agent can act on.
*>
fn void building_a_shape_without_a_device_says_so() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			try { new three.BoxGeometry(1, 1, 1); }
			catch (e) { return e.message; }
			return "nothing was thrown";
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(
			result.value.contains("GPU device"),
			"it says a device is what is missing: %s", result.value
		);
	};
}

// ============================================================================
// Per copy: colour and variant
// ============================================================================
//
// The two channels a copy of a mesh may differ in without becoming a second
// draw call. `scene_test.c3` asserts that they reach the instance record and do
// not split a bucket, with no device; what is left for here is the half only a
// picture can answer — that the value the script set is the value the shader
// read, in one call, for copies that disagree.

<*
 A thousand copies in three colours, drawn once.

 **The draw-call count and the pixels are both required, and neither is enough.**
 An implementation that ignored `mesh.color` entirely would keep the count at one
 and paint everything white; one that made a bucket per colour would paint the
 right pixels in three calls. So this asserts a single call *and* that all three
 colours are in the frame at the same time — which no return value can say.
*>
fn void a_thousand_colours_are_still_one_draw_call() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			const box = new three.BoxGeometry(1, 1, 1);
			const colors = [[1, 0, 0], [0, 1, 0], [0, 0, 1]];

			for (let i = 0; i < 1000; i++) {
				const cube = new three.Mesh(box);
				// Three columns, each its own colour and each far enough from the
				// next to survive being rendered at 200 x 150.
				cube.position.set((i % 3) * 3 - 3, 0, -Math.floor(i / 3) * 0.02);
				cube.color = colors[i % 3];
				scene.add(cube);
			}

			three.camera.lookAt(0, 0, 0);
			three.camera.orbit(0, 0, 12);
			three.render(scene, three.camera);
			return scene.stats();
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.stats.instances == 1000, "a thousand instances, got %d", result.stats.instances);
		test::@check(result.stats.draw_calls == 1, "in one draw call, got %d", result.stats.draw_calls);

		image::Image frame = run.renderer.capture()!!;
		defer frame.free();

		// Lit by the default shader, so nothing is fully saturated — the tint is
		// asserted by which channel dominates rather than by a value.
		uint reds = 0;
		uint greens = 0;
		uint blues = 0;
		for (sz i = 0; i < frame.pixels.len; i += 4)
		{
			int r = (int)frame.pixels[i];
			int g = (int)frame.pixels[i + 1];
			int b = (int)frame.pixels[i + 2];
			if (r < 40 && g < 40 && b < 40) continue;   // the clear colour
			if (r > g + 30 && r > b + 30) reds++;
			if (g > r + 30 && g > b + 30) greens++;
			if (b > r + 30 && b > g + 30) blues++;
		}

		test::@check(reds > 100, "the red column is red, got %d pixels", reds);
		test::@check(greens > 100, "the green column is green, got %d pixels", greens);
		test::@check(blues > 100, "the blue column is blue, got %d pixels", blues);
	};
}

<*
 One material, one draw call, two looks — chosen per copy.

 This is the whole point of `variant`. Two quads share a geometry *and* a
 material, so they are one bucket and one `vkCmdDrawIndexed`; they differ only in
 which row of the material's table they read. A variant that never reached the
 shader paints both of them row zero's colour, and the draw-call count would
 still be one — so the count alone proves nothing here and the pixels are the
 evidence.
*>
fn void a_variant_picks_a_row_of_the_material_table() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const kit = three.load("test/fixtures/textured.glb");
			globalThis.mat = new three.ShaderMaterial({
				uniforms: { palette: [[1, 0, 0], [0, 1, 0], [0, 0, 1]] },
				fragment: "float3 shade(Surface s) { return palette[s.variant]; }",
			});

			globalThis.scene = new three.Scene();
			// quad_left is centred on x = -0.75; +0.75 puts each over the axis.
			for (let i = 0; i < 3; i++) {
				const quad = new three.Mesh(kit.mesh("quad_left"), globalThis.mat);
				quad.position.set(0.75 + (i - 1) * 1.2, 0, 0);
				quad.variant = i;
				globalThis.scene.add(quad);
			}

			three.camera.lookAt(0, 0, 0);
			three.camera.orbit(0, 0, 4);
			three.render(globalThis.scene, three.camera);
			return globalThis.scene.stats();
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.stats.instances == 3, "three quads, got %d", result.stats.instances);
		test::@check(result.stats.draw_calls == 1, "one material and one mesh is one draw, got %d", result.stats.draw_calls);

		image::Image frame = run.renderer.capture()!!;
		defer frame.free();

		uint red = count_near(&frame, 255, 0, 0);
		uint green = count_near(&frame, 0, 255, 0);
		uint blue = count_near(&frame, 0, 0, 255);

		test::@check(red > 200, "row 0 painted its quad red, got %d pixels", red);
		test::@check(green > 200, "row 1 painted its quad green, got %d pixels", green);
		test::@check(blue > 200, "row 2 painted its quad blue, got %d pixels", blue);

		// A row past the end is the last row, not a read off the end of the push
		// block — which would be some other uniform's bytes as a colour, or the
		// same colour by luck. Asserted as "still exactly three colours, and the
		// third one grew" rather than by naming a pixel.
		three::RunResult past = run.run(`
			globalThis.scene.children[0].variant = 99;
			three.render(globalThis.scene, three.camera);
		`);
		defer past.free();
		test::@check(past.ok, "the second run succeeded: %s", past.error);

		image::Image clamped = run.renderer.capture()!!;
		defer clamped.free();

		test::@check(count_near(&clamped, 255, 0, 0) < 50, "row 99 stopped being red, got %d", count_near(&clamped, 255, 0, 0));
		test::@check(
			count_near(&clamped, 0, 0, 255) > blue + 200,
			"and became the last row instead: %d blue pixels, up from %d",
			count_near(&clamped, 0, 0, 255), blue
		);
	};
}

<*
 A table is written a row at a time, and the write reaches the GPU.

 `mat.uniforms.palette[1] = [...]` is the line an agent will write, and the
 obvious implementation of `uniforms` hands back the stored JavaScript array —
 where that line mutates a value nothing ever reads again. It renders unchanged,
 with no error, which is the same silent no-op `an_undeclared_uniform_cannot_be_assigned`
 was written for one level up.
*>
fn void a_table_row_can_be_written_on_its_own() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult first = run.run(`
			const kit = three.load("test/fixtures/textured.glb");
			globalThis.mat = new three.ShaderMaterial({
				uniforms: { palette: [[1, 0, 0], [1, 0, 0]] },
				fragment: "float3 shade(Surface s) { return palette[s.variant]; }",
			});
			globalThis.scene = new three.Scene();
			const quad = new three.Mesh(kit.mesh("quad_left"), globalThis.mat);
			quad.position.set(0.75, 0, 0);
			quad.variant = 1;
			globalThis.scene.add(quad);
			three.camera.lookAt(0, 0, 0);
			three.camera.orbit(0, 0, 3);
			three.render(globalThis.scene, three.camera);
		`);
		defer first.free();
		test::@check(first.ok, "the first run succeeded: %s", first.error);

		image::Image red_frame = run.renderer.capture()!!;
		defer red_frame.free();
		test::@check(count_near(&red_frame, 255, 0, 0) > 500, "it started red");

		three::RunResult second = run.run(`
			globalThis.mat.uniforms.palette[1] = [0, 1, 0];
			three.render(globalThis.scene, three.camera);
			return globalThis.mat.uniforms.palette[1];
		`);
		defer second.free();
		test::@check(second.ok, "the second run succeeded: %s", second.error);
		test::@check(second.value == "[0,1,0]", "the row reads back as it was written, got %s", second.value);

		image::Image green_frame = run.renderer.capture()!!;
		defer green_frame.free();
		test::@check(count_near(&green_frame, 0, 255, 0) > 500, "and row 1 is green now");
		test::@check(
			count_near(&green_frame, 255, 0, 0) == 0,
			"with no red left, so the write reached the device rather than a JavaScript array"
		);
		// Row 0 was not touched. Asserted because a `_setRow` that wrote at the
		// field's own offset regardless of the row would pass every check above.
		three::RunResult row_zero = run.run(`return globalThis.mat.uniforms.palette[0];`);
		defer row_zero.free();
		test::@check(row_zero.value == "[1,0,0]", "row 0 was left alone, got %s", row_zero.value);
	};
}

<*
 A colour set before the object is added survives the add.

 The same replay `_materialize` does for the transform, the name and the
 material, and the same reason: an object is a detached description until it is
 added, and a script that sets a colour and then adds must not lose it. Checked
 with the default shader, so it also says the instance colour reaches
 `mesh.slang` and not only a `ShaderMaterial`.
*>
fn void a_colour_set_before_the_add_survives_it() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		// A generated box rather than the textured fixture, deliberately: the
		// fixture's quads carry a warm base colour texture, so "the frame is
		// reddish" would be true whether or not the tint arrived. Measured — the
		// first version of this test passed with the replay in `_materialize`
		// deleted.
		three::RunResult result = run.run(`
			const scene = new three.Scene();

			const cube = new three.Mesh(new three.BoxGeometry(1, 1, 1));
			cube.color = [1, 0, 0];
			cube.variant = 2;
			scene.add(cube);          // everything above was set while detached

			three.camera.lookAt(0, 0, 0);
			three.camera.orbit(20, 15, 3);
			three.render(scene, three.camera);
			return { color: cube.color, variant: cube.variant };
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value.contains(`"variant":2`), "the variant reads back: %s", result.value);

		image::Image frame = run.renderer.capture()!!;
		defer frame.free();
		// Lit, so not saturated — the red channel simply has to dominate.
		uint reds = 0;
		for (sz i = 0; i < frame.pixels.len; i += 4)
		{
			if ((int)frame.pixels[i] > (int)frame.pixels[i + 1] + 40) reds++;
		}
		test::@check(reds > 500, "the cube is red without a material, got %d red pixels", reds);
	};
}

<*
 A colour is whatever a script had to hand, and a wrong one says so.

 The four spellings are the ones an agent will actually type, and hex is the
 Three.js habit. It is divided by 255 and not de-gamma'd — there is no colour
 management anywhere in this project, and doing half of it here would be worse
 than doing none — so `0xff0000` and `[1, 0, 0]` must be the same colour.
*>
fn void a_colour_is_whatever_the_script_had_to_hand() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			const box = new three.BoxGeometry(1, 1, 1);
			const spellings = [[1, 0, 0], [1, 0, 0, 1], { r: 1, g: 0, b: 0 }, 0xff0000];
			const read = spellings.map(s => {
				const m = new three.Mesh(box);
				m.color = s;
				scene.add(m);
				return m.color.join(',');
			});

			const said = [];
			const refuse = f => { try { f(); said.push("nothing was thrown"); } catch (e) { said.push(e.message); } };
			refuse(() => { new three.Mesh(box).color = "red"; });
			refuse(() => { new three.Mesh(box).color = [1, 0]; });
			refuse(() => { new three.Mesh(box).color = [1, NaN, 0]; });
			refuse(() => { new three.Mesh(box).variant = -1; });

			return { read, agree: new Set(read).size === 1, said };
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value.contains(`"agree":true`), "all four spellings are one colour: %s", result.value);
		test::@check(result.value.contains("1,0,0,1"), "and it is opaque red: %s", result.value);
		test::@check(result.value.contains("0xff8800"), "a bad colour says what it wanted: %s", result.value);
		test::@check(result.value.contains("non-finite"), "a NaN component is named: %s", result.value);
		test::@check(result.value.contains("row index of 0 or more"), "and a negative row: %s", result.value);
		test::@check(!result.value.contains("nothing was thrown"), "every one of them threw: %s", result.value);
	};
}

<*
 A ragged table is refused in JavaScript, before a shader is written.

 The host refuses it too — `columns_of_different_heights_are_refused` — and this
 is the layer that can name both columns at the line that declared them, which is
 `plan.md` §4's argument for where a check belongs when both layers can make it.
*>
fn void a_ragged_table_is_refused_by_name() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const said = [];
			const refuse = f => { try { f(); said.push("nothing was thrown"); } catch (e) { said.push(e.message); } };

			// Two real columns, two and three rows deep. A sheen of
			// [0.1, 0.2, 0.3] would *not* be ragged — that is one row three
			// floats wide, and a plain uniform beside a table is ordinary.
			refuse(() => new three.ShaderMaterial({
				uniforms: { palette: [[1, 0, 0], [0, 1, 0]], sheen: [[0.1], [0.2], [0.3]] },
				fragment: "float3 shade(Surface s) { return palette[s.variant] * sheen[s.variant]; }",
			}));
			refuse(() => new three.ShaderMaterial({
				uniforms: { palette: [[1, 0, 0], [0, 1]] },
				fragment: "float3 shade(Surface s) { return palette[s.variant]; }",
			}));
			refuse(() => {
				const mat = new three.ShaderMaterial({
					uniforms: { palette: [[1, 0, 0], [0, 1, 0]] },
					fragment: "float3 shade(Surface s) { return palette[s.variant]; }",
				});
				mat.uniforms.palette[5] = [0, 0, 1];
			});
			return said;
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		// `sheen: [0.1, 0.2, 0.3]` is three floats in one row, not three rows —
		// so the ragged case has to be spelled with two real tables.
		test::@check(
			result.value.contains("same number of rows") || result.value.contains("same width"),
			"a ragged table is named: %s", result.value
		);
		test::@check(result.value.contains("every row of a table has to be the same width"), "%s", result.value);
		test::@check(result.value.contains("row 5 is not one of them"), "and a row past the end: %s", result.value);
		test::@check(!result.value.contains("nothing was thrown"), "every one of them threw: %s", result.value);
	};
}

// ============================================================================
// Picking
// ============================================================================
//
// `plan.md` §7 calls the raycast "the suite that catches a projection and a
// raycast that disagree" — the half of a 3D app that fails silently, where
// everything still renders and things land somewhere other than where they were
// asked for. `scene_test.c3` makes that check against `Scene` directly; what is
// left for here is the binding: that a hit comes back as the object the script
// is holding, that a miss is `null` rather than something falsy-but-not-null,
// and that the two verbs treat a missing device differently on purpose.
//
// The fixture's geometry is exact and worth having to hand: `quad_left` spans
// x from -1.25 to -0.25, `quad_right` spans 0.25 to 1.25, both are one unit
// tall about y = 0 and both lie flat in the plane z = 0 facing +Z.

<*
 A hit answers with the `Mesh` the script built, not with a handle.

 That is the whole point of the binding — `hit.object.position.set(...)` is the
 line an agent writes next — and it is asserted by identity rather than by name,
 because a rebuilt-from-the-handle object would compare equal on every field and
 still be the wrong thing to hold.

 The second copy five units behind the first is there so that returning the
 first node found rather than the closest has something wrong to return.
*>
fn void a_hit_answers_with_the_object_the_script_built() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const kit = three.load("test/fixtures/textured.glb");
			const scene = new three.Scene();

			const near = new three.Mesh(kit.mesh("quad_left"));
			near.name = "near";
			scene.add(near);

			const far = new three.Mesh(kit.mesh("quad_left"));
			far.name = "far";
			far.position.set(0, 0, -5);
			scene.add(far);

			// -0.75 is the centre of quad_left; the ray runs down -Z from ten out.
			const hit = scene.raycast([-0.75, 0, 10], [0, 0, -1]);
			return {
				same: hit.object === near,
				name: hit.name,
				distance: Math.abs(hit.distance - 10) < 1e-3,
				point: Math.abs(hit.point.x + 0.75) < 1e-3 && Math.abs(hit.point.z) < 1e-3,
				normal: Math.abs(hit.normal.z - 1) < 1e-3,
			};
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(
			result.value == `{"same":true,"name":"near","distance":true,"point":true,"normal":true}`,
			"the near quad came back whole; got %s", result.value
		);
	};
}

<*
 The object a hit hands back is the live one, not a copy of it.

 Moving it moves the node, which the second cast proves by finding nothing where
 the first one hit. A binding that rebuilt an `Object3D` around the handle would
 pass every check above and fail this one silently — the script would place
 things and nothing would move.
*>
fn void the_object_a_hit_returns_is_the_live_one() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const kit = three.load("test/fixtures/textured.glb");
			const scene = new three.Scene();
			const quad = new three.Mesh(kit.mesh("quad_left"));
			scene.add(quad);

			const hit = scene.raycast([-0.75, 0, 10], [0, 0, -1]);
			hit.object.position.x = 40;

			return {
				moved: scene.raycast([-0.75, 0, 10], [0, 0, -1]) === null,
				followed: scene.raycast([39.25, 0, 10], [0, 0, -1]) !== null,
			};
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == `{"moved":true,"followed":true}`,
			"the returned object drove the node; got %s", result.value);
	};
}

<*
 A miss is `null`, and it is `null` rather than an empty array.

 Three.js's `intersectObjects` answers with a list, so a script written from
 memory may well test `hits.length`. On an empty array that reads false and on
 `null` it throws — which is the loud half of the divergence, and is why the
 docs say so in `differences` rather than leaving it to be discovered.
*>
fn void a_miss_is_null_not_an_empty_list() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const kit = three.load("test/fixtures/textured.glb");
			const scene = new three.Scene();
			scene.add(new three.Mesh(kit.mesh("quad_left")));

			// x = 0 is the gap between the two quads, so this is a miss over a
			// scene that plainly has geometry in it.
			const miss = scene.raycast([0, 0, 10], [0, 0, -1]);
			return { isNull: miss === null, notArray: !Array.isArray(miss) };
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == `{"isNull":true,"notArray":true}`,
			"a miss answered null; got %s", result.value);
	};
}

<*
 What cannot be seen cannot be picked, and hiding a parent hides its children.

 `Scene.raycast` skips on `world_visible`, which is resolved in the same walk
 that builds the world matrices — so this also asserts that the walk ran before
 the cast rather than after it.
*>
fn void picking_skips_what_is_invisible() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const kit = three.load("test/fixtures/textured.glb");
			const scene = new three.Scene();

			const near = new three.Mesh(kit.mesh("quad_left"));
			near.name = "near";
			scene.add(near);

			// The far one lives under a group, so hiding the group has to hide it.
			const group = new three.Group();
			const far = new three.Mesh(kit.mesh("quad_left"));
			far.name = "far";
			far.position.set(0, 0, -5);
			group.add(far);
			scene.add(group);

			const down = [[-0.75, 0, 10], [0, 0, -1]];
			const first = scene.raycast(...down).name;

			near.visible = false;
			const second = scene.raycast(...down).name;

			group.visible = false;
			const third = scene.raycast(...down);

			return { first, second, third };
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == `{"first":"near","second":"far","third":null}`,
			"visibility drove the picks; got %s", result.value);
	};
}

<*
 A pick through the centre of the image finds what is in the centre of it.

 The camera is the one the renderer draws with and the ray comes out of the same
 view-projection, so this is the binding's version of §7's projection-and-raycast
 check. The second copy twenty units to the left is there so a `pick` that
 ignored its arguments still has something wrong to return.

 `renderSize` is asserted alongside because it is the only way a script can know
 what to halve, and a `pick` counted against the wrong extent misses by a
 proportion rather than failing.
*>
fn void picking_the_centre_of_the_image_finds_what_is_centred() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const kit = three.load("test/fixtures/textured.glb");
			const scene = new three.Scene();

			// quad_left is centred on x = -0.75, so this puts it over the origin.
			const centred = new three.Mesh(kit.mesh("quad_left"));
			centred.name = "centred";
			centred.position.set(0.75, 0, 0);
			scene.add(centred);

			const aside = new three.Mesh(kit.mesh("quad_left"));
			aside.name = "aside";
			aside.position.set(-20, 0, 0);
			scene.add(aside);

			three.camera.lookAt(0, 0, 0);
			three.camera.orbit(0, 0, 5);

			const { width, height } = three.renderSize();
			const hit = scene.pick(width / 2, height / 2);
			const corner = scene.pick(0, 0);

			return { size: [width, height], name: hit.object.name, corner };
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == `{"size":[200,150],"name":"centred","corner":null}`,
			"the centre picked the centred quad and the corner picked nothing; got %s", result.value);
	};
}

<*
 A pick agrees with the picture it was counted in.

 **This is the check the other picking tests cannot make.** Every one of them
 asks the picker to agree with itself: a round trip through the same mapping, a
 pick at the centre of the image, a fixture symmetric about that centre. A
 vertical flip survives all three, because the centre row is the one row a flip
 leaves alone — so the suite was green while `scene.pick` answered the top of
 the image with what was drawn at the bottom.

 The ground truth here is the frame instead. Two quads are placed either side of
 the camera's target, the scene is rendered, and the *topmost* row with anything
 drawn in it is found by scanning the pixels. Only the higher quad is drawn up
 there, so a pick on that row has exactly one correct answer, and it is the one
 the renderer put there rather than the one the picker derives.

 Found by driving the API through the MCP server against a window: a pick near
 the bottom of a ring of panels kept naming a panel from the top of it.
 `screen_ray` built NDC Y in the same direction as the row index, while
 `gpu/target.c3` binds `.height = -height`, which puts the top row at +1 — the
 two ran opposite ways, and only a pixel could say so.
*>
fn void a_pick_agrees_with_the_pixels_it_was_counted_in() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult built = run.run(`
			const kit = three.load("test/fixtures/textured.glb");
			const scene = new three.Scene();
			globalThis.scene = scene;

			// quad_left is centred on x = -0.75, so +0.75 puts each over the axis:
			// the only thing separating them is height.
			const high = new three.Mesh(kit.mesh("quad_left"));
			high.name = "high";
			high.position.set(0.75, 1.5, 0);
			scene.add(high);

			const low = new three.Mesh(kit.mesh("quad_left"));
			low.name = "low";
			low.position.set(0.75, -1.5, 0);
			scene.add(low);

			three.camera.lookAt(0, 0, 0);
			three.camera.orbit(0, 0, 8);
			three.render(scene, three.camera);
		`);
		defer built.free();
		test::@check(built.ok, "the scene was built: %s", built.error);

		image::Image frame = run.renderer.capture()!!;
		defer frame.free();

		// The clear colour, read out of a corner rather than assumed, so this
		// keeps working if the background ever changes.
		int back_r = (int)frame.pixels[0];
		int back_g = (int)frame.pixels[1];
		int back_b = (int)frame.pixels[2];

		int top_x = -1;
		int top_y = -1;
		for (uint row = 0; row < frame.height && top_y < 0; row++)
		{
			for (uint col = 0; col < frame.width; col++)
			{
				usz at = ((usz)row * frame.width + col) * 4;
				int dr = (int)frame.pixels[at] - back_r;
				int dg = (int)frame.pixels[at + 1] - back_g;
				int db = (int)frame.pixels[at + 2] - back_b;
				if (math::abs(dr) + math::abs(dg) + math::abs(db) > 24)
				{
					top_x = (int)col;
					top_y = (int)row;
					break;
				}
			}
		}

		test::@check(top_y >= 0, "the frame has something drawn in it");
		// Not an assertion about picking — an assertion that the fixture is the
		// one this test reasons about. Two quads either side of the target, and
		// the first geometry from the top belongs to the upper one.
		test::@check(
			top_y < (int)frame.height / 2,
			"the topmost geometry is above the middle of the image, got row %d of %d", top_y, frame.height
		);

		// A few rows in from the silhouette, so an edge cannot decide this.
		String question = string::tformat(
			`const hit = globalThis.scene.pick(%d, %d); return hit ? hit.name : null;`, top_x, top_y + 4
		);
		three::RunResult picked = run.run(question);
		defer picked.free();

		test::@check(picked.ok, "the pick ran: %s", picked.error);
		test::@check(
			picked.value == `"high"`,
			"a pick at (%d, %d) — a pixel the renderer drew the upper quad on — names it; got %s",
			top_x, top_y + 4, picked.value
		);
	};
}

<*
 A ray needs somewhere to point, and a vector has to be readable.

 Both messages name the argument rather than the failure, because the script
 that produces them is being written by something that cannot see this file.
*>
fn void a_ray_that_points_nowhere_says_so() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			const said = [];
			try { scene.raycast([0, 0, 0], [0, 0, 0]); } catch (e) { said.push(e.message); }
			try { scene.raycast("here", [0, 0, -1]); } catch (e) { said.push(e.message); }
			try { scene.pick("middle", 0); } catch (e) { said.push(e.message); }
			return said;
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value.contains("points nowhere"), "the zero direction was named: %s", result.value);
		test::@check(result.value.contains("Vector3"), "the unreadable vector said what it wanted: %s", result.value);
		test::@check(result.value.contains("pixel coordinates"), "and so did the bad pick: %s", result.value);
	};
}

<*
 Without a device the two verbs differ, and the difference is deliberate.

 A world-space raycast needs no GPU: with nothing loaded there is nothing to hit,
 and `null` is the true answer rather than an error. A `pick` needs the extent of
 an image that does not exist, so it says which piece is missing — the same
 shape as `three.load`'s and `three.render`'s messages.
*>
fn void picking_without_a_device_says_which_verb_needs_one() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			const cast = scene.raycast([0, 0, 10], [0, 0, -1]);
			try {
				scene.pick(1, 1);
				return { cast, picked: "no throw" };
			} catch (e) {
				return { cast, picked: e.message };
			}
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value.contains(`"cast":null`), "the empty scene was cast through: %s", result.value);
		test::@check(result.value.contains("GPU device"), "and the pick named the reason: %s", result.value);
	};
}

// ============================================================================
// Materials
//
// `plan.md` §5's done condition for M5: an agent-written fragment shader renders
// and a bad one throws a JS error carrying the Slang diagnostic. Both halves are
// asserted here, on a device, through the same `run_script` surface an agent
// drives — not against the assembly layer, which `three_tests::material` covers.
// ============================================================================

<*
 How many pixels are close to a given colour.

 Blunt on purpose, in the same spirit as `scene_test.c3`'s `count_drawn`: it
 answers "is the thing on screen the colour the material asked for", which no
 return value from the script can. The tolerance is wide because the default
 shader's lighting is not being asserted here — only which shader ran.
*>
fn uint count_near(image::Image* shot, int r, int g, int b, int tolerance = 40)
{
	uint found = 0;
	for (sz i = 0; i < shot.pixels.len; i += 4)
	{
		int dr = (int)shot.pixels[i] - r;
		int dg = (int)shot.pixels[i + 1] - g;
		int db = (int)shot.pixels[i + 2] - b;
		if (math::abs(dr) <= tolerance && math::abs(dg) <= tolerance && math::abs(db) <= tolerance) found++;
	}
	return found;
}

<*
 A fragment body an agent wrote reaches the screen and changes it.

 The claim is not that a material compiles — `three_tests::material` proves that
 without a GPU. It is that the compiled thing is *bound and drawn*, and only a
 picture can say so. The same quad is rendered twice, once on the default shader
 and once on a material whose whole body is `return float3(1, 0, 0)`, and the
 frames are compared by counting red pixels.

 A material that compiled and was then never bound leaves the two frames
 identical — which is exactly the silent failure `plan.md` §6 warns about: "a
 compile that fails and falls back to a previous pipeline is a shader edit that
 appears to work and changes nothing on screen". Asserting on `drawCalls` here
 would report success for that.
*>
fn void an_agent_written_shader_reaches_the_screen() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult before = run.run(`
			const kit = three.load("test/fixtures/textured.glb");
			globalThis.scene = new three.Scene();
			globalThis.quad = new three.Mesh(kit.mesh("quad_left"));
			globalThis.quad.position.set(0, 0, 0);
			globalThis.scene.add(globalThis.quad);
			three.camera.lookAt(0, 0, 0);
			three.camera.orbit(0, 0, 3);
			three.render(globalThis.scene);
		`);
		defer before.free();
		test::@check(before.ok, "the first run succeeded: %s", before.error);

		image::Image plain = run.renderer.capture()!!;
		defer plain.free();
		uint red_before = count_near(&plain, 255, 0, 0);

		three::RunResult after = run.run(`
			globalThis.quad.material = new three.ShaderMaterial({
				fragment: "float3 shade(Surface s) { return float3(1.0, 0.0, 0.0); }"
			});
			three.render(globalThis.scene);
		`);
		defer after.free();
		test::@check(after.ok, "the second run succeeded: %s", after.error);

		image::Image shaded = run.renderer.capture()!!;
		defer shaded.free();
		uint red_after = count_near(&shaded, 255, 0, 0);

		test::@check(
			red_after > 500,
			"the agent's shader painted the quad red, got %d red pixels",
			red_after
		);
		test::@check(
			red_after > red_before * 4,
			"and that is a change: %d red pixels before, %d after",
			red_before,
			red_after
		);
	};
}

<*
 The material's uniform is what the pixels are.

 The strongest form of "assert on the thing, not the flag" available here: a
 material whose whole body is `return tint` makes the rendered colour a direct
 read of the uniform. Red, then green through the *same* material — so this also
 proves that writing `mat.uniforms.tint` after a render takes effect, which a
 material that only uploaded its uniforms at construction would fail while
 leaving every JavaScript-side value correct.

 Reading the value back out of `mat.uniforms` would assert nothing about the
 GPU at all, and an earlier version of this test did exactly that under this
 name.
*>
fn void a_uniform_is_what_the_pixels_are() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult first = run.run(`
			const kit = three.load("test/fixtures/textured.glb");
			globalThis.scene = new three.Scene();
			const quad = new three.Mesh(kit.mesh("quad_left"));
			globalThis.mat = new three.ShaderMaterial({
				uniforms: { tint: [1, 0, 0] },
				fragment: "float3 shade(Surface s) { return tint; }"
			});
			quad.material = globalThis.mat;
			globalThis.scene.add(quad);
			three.camera.lookAt(0, 0, 0);
			three.camera.orbit(0, 0, 3);
			three.render(globalThis.scene);
		`);
		defer first.free();
		test::@check(first.ok, "the first run succeeded: %s", first.error);

		image::Image red_frame = run.renderer.capture()!!;
		defer red_frame.free();

		three::RunResult second = run.run(`
			globalThis.mat.uniforms.tint = [0, 1, 0];
			three.render(globalThis.scene);
		`);
		defer second.free();
		test::@check(second.ok, "the second run succeeded: %s", second.error);

		image::Image green_frame = run.renderer.capture()!!;
		defer green_frame.free();

		uint red = count_near(&red_frame, 255, 0, 0);
		uint green = count_near(&green_frame, 0, 255, 0);
		uint red_still = count_near(&green_frame, 255, 0, 0);

		test::@check(red > 500, "the quad rendered red, got %d red pixels", red);
		test::@check(green > 500, "and after the write it rendered green, got %d green pixels", green);
		test::@check(
			red_still == 0,
			"with no red left over — %d pixels are still red, so the write did not reach the GPU",
			red_still
		);
	};
}

<*
 Two materials in one frame each get their own shader.

 The bucket loop binds a pipeline per bucket and skips the call when it has not
 changed, which is an optimization built on the draw list being sorted
 material-major. If the bind were hoisted back out of the loop — where it lived
 until M5 — or if the skip compared the wrong thing, the second bucket would draw
 with the first material's pipeline and its own push block.

 Two quads, one red and one green, both on screen at once. Either failure paints
 both of them the same colour, and no draw-call count would notice.
*>
fn void two_materials_at_once_each_get_their_own_shader() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const kit = three.load("test/fixtures/textured.glb");
			const scene = new three.Scene();

			const left = new three.Mesh(kit.mesh("quad_left"));
			left.material = new three.ShaderMaterial({
				uniforms: { tint: [1, 0, 0] },
				fragment: "float3 shade(Surface s) { return tint; }"
			});

			// A *different body*, not just a different uniform. Two materials
			// with identical source share one VkPipeline through the cache —
			// correctly — and then binding once would be right and this test
			// would prove nothing about the per-bucket bind.
			const right = new three.Mesh(kit.mesh("quad_right"));
			right.material = new three.ShaderMaterial({
				uniforms: { level: 1 },
				fragment: "float3 shade(Surface s) { return float3(0.0, level, 0.0); }"
			});

			scene.add(left, right);
			three.camera.lookAt(0, 0, 0);
			three.camera.orbit(0, 0, 4);
			three.render(scene);
			return three.stats().drawCalls;
		`);
		defer result.free();
		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == "2", "two materials are two draws, got %s", result.value);

		image::Image shot = run.renderer.capture()!!;
		defer shot.free();

		uint red = count_near(&shot, 255, 0, 0);
		uint green = count_near(&shot, 0, 255, 0);
		test::@check(red > 500, "the left quad is red, got %d red pixels", red);
		test::@check(green > 500, "the right quad is green, got %d green pixels", green);
	};
}

<*
 A bad body throws, and the message names the line the agent wrote.

 The done condition. The error must arrive at construction — not at the next
 render, and not as a black screen — and it must carry Slang's own text, whose
 line number `#line` has already remapped to the agent's body rather than to the
 generated preamble around it.

 The typo is on the body's third line so a passing test cannot be an accident of
 the preamble happening to be exactly the right length.
*>
fn void a_bad_material_throws_with_the_line_the_agent_wrote() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			try {
				new three.ShaderMaterial({
					uniforms: { tint: [1, 0, 0] },
					fragment: [
						"float3 shade(Surface s)",
						"{",
						"    return s.albedo * tintt;",
						"}"
					].join("\n")
				});
				return "no throw";
			} catch (e) { return e.message; }
		`);
		defer result.free();

		test::@check(result.ok, "the script survived to report: %s", result.error);
		test::@check(result.value.contains("tintt"), "the diagnostic names the typo: %s", result.value);
		test::@check(
			result.value.contains("material:3"),
			"and points at line 3 of the body the agent wrote, not into the preamble: %s",
			result.value
		);
	};
}

<*
 The material verbs say which piece is missing, and which of them needs one.

 Same pairing as `picking_without_a_device_says_which_verb_needs_one`: the
 interesting claim is not that it fails, it is that the sentence names the
 device. A material *is* a pipeline, so unlike `raycast` there is no meaningful
 answer to give without one.
*>
fn void a_material_without_a_device_says_so() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			try {
				new three.ShaderMaterial({ fragment: "float3 shade(Surface s) { return s.albedo; }" });
				return "no throw";
			} catch (e) { return e.message; }
		`);
		defer result.free();

		test::@check(result.ok, "the script survived to report: %s", result.error);
		test::@check(result.value.contains("GPU device"), "the message names the device: %s", result.value);
	};
}

<*
 A uniform that was never declared cannot be assigned, and says so.

 `mat.uniforms` is sealed with an accessor per declared name, so a typo is a
 throw rather than a silent write to a property nothing reads. That is the whole
 reason the accessors are built from the names instead of the object being a
 plain bag — a bag would make `mat.uniforms.tnit = 1` a no-op that renders
 unchanged and looks like a shader bug.
*>
fn void an_undeclared_uniform_cannot_be_assigned() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const mat = new three.ShaderMaterial({
				uniforms: { tint: [1, 0, 0] },
				fragment: "float3 shade(Surface s) { return tint; }"
			});
			const said = [];
			try { mat.uniforms.tnit = [0, 1, 0]; said.push("no throw"); }
			catch (e) { said.push("threw"); }
			try { mat.uniforms.tint = "red"; said.push("no throw"); }
			catch (e) { said.push(e.message); }
			return said;
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value.contains("threw"), "the misspelt name was refused: %s", result.value);
		test::@check(result.value.contains("tint"), "and the bad value named the uniform: %s", result.value);
	};
}

<*
 A material outlives the scene that used it.

 `new three.Scene()` empties the graph and every node handle in it goes stale,
 but a material is not a node — it lives on the pass beside the assets, for the
 same reason a loaded `.glb` does. An agent that rebuilds its scene each run
 should not have to recompile its shaders to do it.
*>
fn void a_material_survives_a_new_scene() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const kit = three.load("test/fixtures/textured.glb");
			const mat = new three.ShaderMaterial({
				uniforms: { tint: [0.2, 0.4, 0.8] },
				fragment: "float3 shade(Surface s) { return tint * s.albedo; }"
			});

			const first = new three.Scene();
			first.add(new three.Mesh(kit.mesh("quad_left"))).children[0].material = mat;

			const second = new three.Scene();
			const quad = new three.Mesh(kit.mesh("quad_right"));
			quad.material = mat;
			second.add(quad);
			three.render(second);

			return { draws: three.stats().drawCalls, tint: mat.uniforms.tint };
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(
			result.value == `{"draws":1,"tint":[0.2,0.4,0.8]}`,
			"the material still draws and still knows its uniforms; got %s",
			result.value
		);
	};
}

<*
 Two meshes on one material bucket together; two materials split them.

 The M2 thesis, restated for M5: what makes a draw call is now (asset, mesh,
 material), and the agent can see the consequence in `stats()` rather than
 having to infer it. `uniqueMeshes` staying at one while `drawCalls` goes to two
 is the whole point of reporting them separately.
*>
fn void two_materials_over_one_mesh_are_two_draws() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const kit = three.load("test/fixtures/textured.glb");
			const scene = new three.Scene();
			const ref = kit.mesh("quad_left");

			const a = new three.Mesh(ref);
			const b = new three.Mesh(ref);
			b.position.set(2, 0, 0);
			scene.add(a, b);
			const shared = three.stats();

			const mat = new three.ShaderMaterial({
				uniforms: { k: 0.5 },
				fragment: "float3 shade(Surface s) { return s.albedo * k; }"
			});
			b.material = mat;
			const split = three.stats();

			b.material = null;
			const rejoined = three.stats();

			return {
				shared: [shared.drawCalls, shared.uniqueMeshes],
				split: [split.drawCalls, split.uniqueMeshes],
				rejoined: [rejoined.drawCalls, rejoined.uniqueMeshes],
			};
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(
			result.value == `{"shared":[1,1],"split":[2,1],"rejoined":[1,1]}`,
			"one material is one draw, two are two, and null returns to the default; got %s",
			result.value
		);
	};
}

<*
 `three.texture(path)` reports what it loaded, and a material wears it.

 The whole tier-1 texture story in one script: no Slang, no uniforms, no
 `ShaderMaterial`. If this needs a fragment body to put a picture on a box, the
 verb has failed at the thing it exists for.

 The extents are asserted because they are the reason `three.texture` answers
 with an object rather than a handle — a script sizing a plane to an image's
 aspect ratio reads them, and a texture that loaded at the wrong size otherwise
 has no symptom until it is on screen.
*>
fn void a_texture_loads_and_says_how_big_it_is() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const tex = three.texture("test/fixtures/checker.png");
			const scene = new three.Scene();
			const quad = new three.Mesh(
				new three.PlaneGeometry(2, 2),
				new three.MeshLambertMaterial({ map: tex }),
			);
			scene.add(quad);
			three.camera.lookAt(0, 0, 0);
			three.camera.orbit(0, 0, 3);
			three.render(scene);
			return [tex.width, tex.height, tex.alive, three.stats().textures, three.stats().drawCalls];
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == "[8,8,true,1,1]",
			"an 8x8 png, alive, one texture, one draw call; got %s", result.value);

		image::Image shot = run.renderer.capture()!!;
		defer shot.free();

		test::@check(count_near(&shot, 200, 0, 200, 90) > 100,
			"the checkerboard is not on screen, so MeshLambertMaterial({ map }) drew nothing textured");
	};
}

<*
 A texture assigned after the fact replaces what the mesh brought.

 `material.map = ...` rather than the constructor, because the two go through
 different verbs — `setMap` and `createTextureMaterial` — and a surface where one
 works and the other silently does not is exactly the kind an agent gives up on.

 The magenta going to zero is the half that matters. Asserting only that green
 arrived would pass on a renderer that drew the quad twice.
*>
fn void a_map_assigned_afterwards_replaces_the_meshs_own() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const kit = three.load("test/fixtures/textured.glb");
			const scene = new three.Scene();
			const quad = new three.Mesh(kit.mesh("quad_left"));
			const mat = new three.MeshLambertMaterial();
			quad.material = mat;
			scene.add(quad);
			three.camera.lookAt(0, 0, 0);
			three.camera.orbit(0, 0, 3);
			three.render(scene);

			mat.map = three.texture("test/fixtures/green.jpg");
			three.render(scene);
			return [mat.map.path, mat.map.width, three.stats().textures];
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value.contains("green.jpg"), "material.map reads back as the texture set; got %s", result.value);

		image::Image shot = run.renderer.capture()!!;
		defer shot.free();

		test::@check(count_near(&shot, 0, 150, 0, 90) > 100, "the assigned map is not on screen");
		test::@check(count_near(&shot, 200, 0, 200, 60) == 0,
			"the mesh's own checkerboard is still being sampled, so the assignment did nothing");
	};
}

<*
 A disposed texture cannot be used, and says so rather than rendering untextured.

 The failure this refuses is the quiet one: a disposed handle that resolved to
 `NO_TEXTURE` would leave a mesh drawing its base colour, which is
 indistinguishable from having forgotten the line — and, worse, the index it
 carries is *recycled*, so a later load can make a stale handle name a completely
 different picture. Disposing twice is not an error, because a cleanup path that
 may run twice is ordinary.
*>
fn void a_disposed_texture_refuses_to_be_used() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const tex = three.texture("test/fixtures/checker.png");
			const before = three.stats().textures;
			tex.dispose();
			tex.dispose();

			let threw = '';
			try { new three.MeshLambertMaterial({ map: tex }); }
			catch (e) { threw = e.message; }

			return [before, three.stats().textures, tex.alive, threw.includes('disposed')];
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == "[1,0,false,true]",
			"one texture, then none, dead, and using it says 'disposed'; got %s", result.value);
	};
}

<*
 Disposing while a material still draws with it leaves the material correct.

 This is what makes `dispose()` a thing a script can call as soon as it is done
 *referring* to a texture, rather than something that has to be timed against
 every material using it. The reference the handle holds and the reference the
 material holds are different references, and only the first one goes.
*>
fn void disposing_a_handle_does_not_disturb_a_material_using_it() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			const tex = three.texture("test/fixtures/checker.png");
			const quad = new three.Mesh(
				new three.PlaneGeometry(2, 2),
				new three.MeshLambertMaterial({ map: tex }),
			);
			scene.add(quad);
			tex.dispose();
			three.camera.lookAt(0, 0, 0);
			three.camera.orbit(0, 0, 3);
			three.render(scene);
			return three.stats().textures;
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == "1", "the image is still resident: got %s textures", result.value);

		image::Image shot = run.renderer.capture()!!;
		defer shot.free();
		test::@check(count_near(&shot, 200, 0, 200, 90) > 100,
			"the image went when the script's handle did");
	};
}

<*
 A `ShaderMaterial` can wear a map too, and it arrives as `Surface.albedo`.

 Documented in `getApiDocs` and true for a reason that is easy to lose:
 `material.slang` declares the same `[vk::binding(0, 0)] Sampler2D` that
 `mesh.slang` does and folds the sample into `s.albedo` before the agent's body
 runs — so a body that never mentions a texture gets one anyway. Nothing else in
 the suite crosses those two features, and a claim in the docs with no test
 behind it is the kind that stops being true quietly.

 The body multiplies by a uniform so the assertion cannot be satisfied by the
 default shader having run instead: `s.albedo * 3` is brighter than anything the
 fixed pipeline produces from the same texel.
*>
fn void a_shader_material_can_wear_a_map() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			const mat = new three.ShaderMaterial({
				uniforms: { boost: 3.0 },
				fragment: "float3 shade(Surface s) { return s.albedo * boost; }",
			});
			mat.map = three.texture("test/fixtures/checker.png");
			scene.add(new three.Mesh(new three.PlaneGeometry(2, 2), mat));
			three.camera.lookAt(0, 0, 0);
			three.camera.orbit(0, 0, 3);
			three.render(scene);
			return [mat.map.width, three.stats().textures, three.stats().drawCalls];
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == "[8,1,1]", "an 8px map, one texture, one draw; got %s", result.value);

		image::Image shot = run.renderer.capture()!!;
		defer shot.free();

		// **The green channel is the whole assertion.** The checker's magenta is
		// (255, 0, 255) and the body triples it, so the lit squares clip to a
		// bright magenta with green still near zero. A shader whose map never
		// reached the host samples the 1x1 white stand-in instead and returns
		// `base_color * 3` — a saturated *white* field, which is bright in every
		// channel.
		//
		// Written first as "bright pixels, and dark pixels" and that caught
		// nothing: white is bright, and the clear colour is (26, 28, 33), so the
		// dark count was satisfied by the background whatever the quad did.
		uint magenta = 0;
		uint white = 0;
		for (sz i = 0; i < shot.pixels.len; i += 4)
		{
			bool lit = shot.pixels[i] > 200 && shot.pixels[i + 2] > 200;
			if (lit && shot.pixels[i + 1] < 120) magenta++;
			if (lit && shot.pixels[i + 1] > 200) white++;
		}
		test::@check(magenta > 100,
			"only %d bright magenta pixels — the agent's shader did not run over the map", magenta);
		test::@check(white == 0,
			"%d saturated white pixels — the shader ran over the 1x1 stand-in, so the map never crossed", white);
	};
}

<*
 A material with no map is still a side, and that is what a skydome needs.

 A sphere seen from the inside shows only its back faces, so under the default it
 is not dim, it is *absent*. Before `MeshLambertMaterial` the only way to ask for
 `BackSide` was to compile a `ShaderMaterial` for it — a Slang invocation to
 change one Vulkan enum.

 Asserted as a render from inside the sphere, because "the material was built" is
 exactly the flag that would pass while the cull mode went the wrong way.
*>
fn void a_material_with_no_map_is_how_a_skydome_is_asked_for() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			const sky = new three.Mesh(
				new three.SphereGeometry(10),
				new three.MeshLambertMaterial({ side: three.BackSide }),
			);
			sky.color = [0.2, 0.4, 1.0];
			scene.add(sky);
			// Inside it, looking outward.
			three.camera.lookAt(0, 0, 0);
			three.camera.orbit(0, 0, 0.5);
			three.render(scene);
			return [sky.material.side, sky.material.map];
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == "[1,null]", "BackSide and no map; got %s", result.value);

		image::Image shot = run.renderer.capture()!!;
		defer shot.free();

		uint filled = 0;
		for (sz i = 0; i < shot.pixels.len; i += 4)
		{
			if (shot.pixels[i + 2] > shot.pixels[i] + 20) filled++;
		}
		test::@check(filled > (200 * 150) / 2,
			"only %d pixels are the sky — from inside a FrontSide sphere there is nothing at all", filled);
	};
}

<*
 The same picture reached two ways is one upload.

 The dedup is asserted through the script surface as well as in
 `three_tests::texture` because this is the number an agent actually watches:
 `three.stats().textures` is what tells it whether a scene is sharing its images,
 and it is reported off the deduplicated table.

 **The mesh has to be drawn before the count means anything.** Since G3
 `three.load` reads metadata and uploads nothing, so a `.glb`'s images arrive when
 something places one of its meshes — this test was written as load-then-count
 first and read zero, which is correct behaviour and a useless assertion. The
 render is what makes `embedded` a real number to compare against.

 The loose file goes *second* on purpose. The other order also passes and proves
 less: `textured.glb` holds two identical images, so it exercises the hash by
 itself, and a loose load that made a third slot would be invisible behind it.
*>
fn void the_same_image_two_ways_is_one_texture() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const kit = three.load("test/fixtures/textured.glb");
			const scene = new three.Scene();
			scene.add(new three.Mesh(kit.mesh("quad_left")));
			three.camera.lookAt(0, 0, 0);
			three.camera.orbit(0, 0, 3);
			three.render(scene);

			const embedded = three.stats().textures;
			const loose = three.texture("test/fixtures/checker.png");
			return [embedded, three.stats().textures, loose.width];
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == "[1,1,8]",
			"a .glb image and the identical file on disk are one upload; got %s", result.value);
	};
}

<*
 The things a texture and a material will not accept, each named.

 One test for the refusals because each is one line and the interesting property
 is that they are *distinguishable*: a script handed "wants a three.texture" for
 a bad path and "wants a three.texture" for a bad map has learned nothing about
 which line to fix.
*>
fn void the_texture_verbs_refuse_by_name() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const said = (fn) => { try { fn(); return ''; } catch (e) { return e.message; } };
			return [
				said(() => three.texture("test/fixtures/nothing_here.png")).includes('no readable file'),
				said(() => three.texture("test/fixtures/not_an_image.png")).includes('not a PNG or a JPEG'),
				said(() => three.texture("test/fixtures/deep.png")).includes('16-bit'),
				said(() => three.texture(42)).includes('wants a path'),
				said(() => new three.MeshLambertMaterial({ map: "brick.png" })).includes('wants a three.texture'),
				said(() => new three.MeshLambertMaterial({ side: 9 })).includes('three.FrontSide'),
			];
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == "[true,true,true,true,true,true]",
			"each refusal says which one it is; got %s", result.value);
	};
}

<*
 Two meshes sharing a geometry and a textured material are one draw call.

 The thesis, applied to the new material: `MeshLambertMaterial` must not be a way
 to accidentally break batching. Two copies of one shape wearing one material are
 one bucket, and giving the second its own material — even with the same image —
 is two, because a bucket is (asset, mesh, material) and two materials are two
 sets of push bytes whatever they contain.
*>
fn void textured_copies_of_one_shape_are_one_draw_call() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			const tex = three.texture("test/fixtures/checker.png");
			const mat = new three.MeshLambertMaterial({ map: tex });
			const box = new three.BoxGeometry(1, 1, 1);
			for (let i = 0; i < 8; i++) {
				const m = new three.Mesh(box, mat);
				m.position.set(i * 2, 0, 0);
				scene.add(m);
			}
			const shared = three.stats().drawCalls;

			const odd = new three.Mesh(box, new three.MeshLambertMaterial({ map: tex }));
			odd.position.set(-2, 0, 0);
			scene.add(odd);
			return [shared, three.stats().drawCalls, three.stats().textures];
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == "[1,2,1]",
			"eight textured copies are one draw, a second material makes two, and both share one image; got %s",
			result.value
		);
	};
}

<*
 **The headline.** Pixels a script generated and the identical `.png` are one
 texture.

 This is the strongest check available for the whole path, because it asserts
 *byte equality* without anything having to state what the bytes are. The content
 hash is over decoded RGBA and cannot tell where they came from, so landing in
 one slot means the `Uint8Array` that crossed the boundary was exactly what
 `image.c3l` produced from `checker.png` — same values, same order, same
 alignment, no offset, no stride, no channel swap. Any one of those wrong and
 this is two textures.

 The loop mirrors `png_checker()` in `test/fixtures/make_textured.py`: 8x8, two
 pixels to a square, magenta and near-black, alpha filled in because the PNG has
 none and `to_rgba` writes 0xff. Row 0 here is row 0 there, which is the PNG's
 *top* row — so this pins the row order too.
*>
fn void generated_pixels_and_a_file_are_one_texture() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const n = 8;
			const px = new Uint8Array(n * n * 4);
			for (let y = 0; y < n; y++) {
				for (let x = 0; x < n; x++) {
					const i = (y * n + x) * 4;
					const on = (((x >> 1) + (y >> 1)) % 2) === 0;
					px[i] = on ? 255 : 16;
					px[i + 1] = on ? 0 : 16;
					px[i + 2] = on ? 255 : 16;
					px[i + 3] = 255;
				}
			}
			const built = new three.DataTexture(px, n, n);
			const afterBuilt = three.stats().textures;
			const loaded = three.texture("test/fixtures/checker.png");
			return [afterBuilt, three.stats().textures, built.width, built.path, loaded.width];
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == "[1,1,8,null,8]",
			"generated pixels and the identical file are one upload; got %s", result.value);
	};
}

<*
 Generated pixels reach the screen, and the rows go the way the docs say.

 The pattern is asymmetric top to bottom on purpose. A checkerboard would render
 identically whichever way the rows were fed, so it can say "a texture arrived"
 and nothing about whether it arrived the right way up — and upside down is the
 single most likely thing to be wrong about a buffer somebody filled by hand.

 What it records: **row 0 of the array is the bottom of the quad on screen.**
 That is not an arbitrary fact and it is not this verb's doing. `PlaneGeometry`
 generates Three.js's uvs, where (0, 0) is the bottom-left vertex, and Vulkan
 samples v = 0 at the *first* texel row — so the first row of any texture, from a
 file or from here, lands along the bottom edge. Three.js compensates with
 `texture.flipY = true` by default; there is no flipY here.
*>
fn void generated_pixels_reach_the_screen_the_right_way_up() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const n = 16;
			const px = new Uint8Array(n * n * 4);
			for (let y = 0; y < n; y++) {
				for (let x = 0; x < n; x++) {
					const i = (y * n + x) * 4;
					// First half of the rows red, second half blue.
					const red = y < n / 2;
					px[i] = red ? 255 : 0;
					px[i + 1] = 0;
					px[i + 2] = red ? 0 : 255;
					px[i + 3] = 255;
				}
			}
			const scene = new three.Scene();
			scene.add(new three.Mesh(
				new three.PlaneGeometry(2, 2),
				new three.MeshLambertMaterial({ map: new three.DataTexture(px, n, n) }),
			));
			three.camera.lookAt(0, 0, 0);
			three.camera.orbit(0, 0, 3);
			three.render(scene);
			return three.stats().textures;
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == "1", "one texture, got %s", result.value);

		image::Image shot = run.renderer.capture()!!;
		defer shot.free();

		// Where the reddest and the bluest pixels sit vertically. Row 0 of the
		// captured image is the top of the screen.
		usz stride = (usz)shot.width * 4;
		uint red_rows = 0;
		uint blue_rows = 0;
		uint red_y = 0;
		uint blue_y = 0;
		for (uint y = 0; y < shot.height; y++)
		{
			for (uint x = 0; x < shot.width; x++)
			{
				sz i = (sz)((usz)y * stride + (usz)x * 4);
				if (shot.pixels[i] > 90 && shot.pixels[i + 2] < 40) { red_rows++; red_y += y; }
				if (shot.pixels[i + 2] > 90 && shot.pixels[i] < 40) { blue_rows++; blue_y += y; }
			}
		}

		test::@check(red_rows > 100 && blue_rows > 100,
			"both halves have to be on screen: %d red, %d blue", red_rows, blue_rows);
		if (red_rows > 0 && blue_rows > 0)
		{
			// Larger y is lower on screen.
			test::@check(red_y / red_rows > blue_y / blue_rows,
				"the array's first rows are red and belong along the bottom edge, but the red is at y=%d "
				"and the blue at y=%d — the texture is upside down",
				red_y / red_rows, blue_y / blue_rows
			);
		}
	};
}

<*
 A DataTexture is a Texture in every other way.

 It extends `Texture` rather than reimplementing it, and this is what says so: a
 map, a dispose that gives the reference back, and extents read off the upload.
 Written as one test because each half is one line and what is being asserted is
 that they are *the same* mechanism, not three separate ones that happen to work.

 **The texture is 4x8 rather than square, and that is deliberate.** Every other
 check here uses a square one, so swapping the two dimensions anywhere along the
 path — the verb, the `Image`, the upload — produces an identical picture and an
 identical hash, and passes all of them. Found by injecting exactly that swap and
 watching the whole suite stay green; this is the check that turns it red.
*>
fn void a_data_texture_behaves_like_any_other() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const px = new Uint8Array(4 * 8 * 4).fill(200);
			const tex = new three.DataTexture(px, 4, 8);
			const mat = new three.MeshLambertMaterial({ map: tex });
			const isTexture = tex instanceof three.Texture;
			const resident = three.stats().textures;

			tex.dispose();
			const afterDispose = three.stats().textures;   // the material still holds one
			mat.map = null;
			return [isTexture, tex.width, tex.height, resident, afterDispose, three.stats().textures, mat.map];
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == "[true,4,8,1,1,0,null]",
			"a Texture, 4 wide and 8 tall, resident, still resident while a material holds it, gone after; got %s",
			result.value
		);
	};
}

<*
 A plain Array works, and a wrong byte count is refused with the arithmetic.

 The Array is accepted because it is what a script most naturally builds and
 because refusing it would be refusing the obvious thing over a container detail
 the author cannot see the reason for. It costs a copy, which is what the
 `Uint8Array` route exists to skip.

 The refusal carries both numbers because that is the difference between a
 message an agent can act on and one it has to do arithmetic to use — and the
 mistake being caught is usually a transposition or a forgotten alpha channel,
 both of which are obvious the moment the two counts are side by side.
*>
fn void a_plain_array_works_and_a_wrong_count_says_both_numbers() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const said = (fn) => { try { fn(); return ''; } catch (e) { return e.message; } };

			const plain = [];
			for (let i = 0; i < 2 * 2 * 4; i++) plain.push(255);
			const fromArray = new three.DataTexture(plain, 2, 2);

			// Three channels instead of four: the commonest way to get this wrong.
			const short = new Uint8Array(4 * 4 * 3);
			const complaint = said(() => new three.DataTexture(short, 4, 4));

			return [
				fromArray.width,
				complaint.includes('64') && complaint.includes('48'),
				said(() => new three.DataTexture(new Uint8Array(16), 2, 2.5)).includes('whole-number'),
				said(() => new three.DataTexture("nope", 2, 2)).includes('Uint8Array'),
				said(() => new three.DataTexture(new Uint8Array(4), 1, 1)).length === 0,
				said(() => new three.DataTexture(new Uint8Array(4), 0, 0)).includes('positive'),
			];
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == "[2,true,true,true,true,true]",
			"an Array is widened, and each refusal says which one it is; got %s", result.value);
	};
}

<*
 Every name the API exposes is documented where it belongs.

 `the_docs_describe_the_surface` checks that the dump contains two string
 literals, which asserts that docs exist rather than that they are true: adding
 `ShaderMaterial` and never mentioning it passed that test green. `plan.md` §4
 calls `getApiDocs()` the cheapest possible mitigation for the agent not having
 memorized this API, and a doc that has silently stopped covering the surface is
 worth less than none, because it is trusted.

 So this asks the surface itself — the module's exports, and every public member
 of every exported class walked off the prototype chain — and requires each to be
 documented *in its own entry*. A sweep of the whole dump was written first and
 was too weak to catch anything: renaming the `ShaderMaterial` entry to
 `_ShaderMaterialUndocumented` still contains the string `ShaderMaterial`, and
 prose in `differences` mentioning a class counted as documenting it.
*>
fn void the_docs_name_everything_the_api_exposes() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const docs = three.getApiDocs();
			const elsewhere = JSON.stringify(docs.functions) + JSON.stringify(Object.keys(docs.classes));

			const members = (ctor) => {
				const out = new Set();
				let p = ctor.prototype;
				while (p && p !== Object.prototype) {
					for (const n of Object.getOwnPropertyNames(p)) {
						if (n !== 'constructor' && !n.startsWith('_')) out.add(n);
					}
					p = Object.getPrototypeOf(p);
				}
				return [...out];
			};

			const missing = [];
			for (const name of Object.keys(three)) {
				const exported = three[name];
				const isClass = typeof exported === 'function' && /^[A-Z]/.test(name);
				if (!isClass) {
					if (!elsewhere.includes(name)) missing.push(name);
					continue;
				}
				const entry = docs.classes[name];
				if (!entry) { missing.push('classes.' + name); continue; }
				const text = JSON.stringify(entry);
				for (const m of members(exported)) {
					if (!text.includes(m)) missing.push(name + '.' + m);
				}
			}
			return missing;
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(
			result.value == "[]",
			"every exported name is documented in its own entry; these are not: %s",
			result.value
		);
	};
}

<*
 Many consecutive push-descriptor draws each keep their own state.

 `plan.md`'s M0/M1 findings recorded that KosmicKrisp's `vkCmdPushDescriptorSetKHR`
 "breaks subsequent draws when descriptorWriteCount > 0", and M5 moved the whole
 texture path onto exactly that call. If the defect is still present, the first
 bucket draws correctly and the rest do not — which is why this asserts on four
 buckets rather than two, and on four *distinct* colours rather than on a count.

 Four materials over one mesh, so every bucket pushes a descriptor and a block
 and draws. A driver that dropped or corrupted the state after the first push
 leaves the last three quads sharing the first's appearance.
*>
fn void consecutive_push_descriptor_draws_each_keep_their_own_state() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const kit = three.load("test/fixtures/textured.glb");
			const scene = new three.Scene();
			const ref = kit.mesh("quad_left");
			const colours = [[1,0,0],[0,1,0],[0,0,1],[1,1,0]];

			colours.forEach((c, i) => {
				const m = new three.Mesh(ref);
				m.position.set(i * 1.2, 0, 0);
				m.material = new three.ShaderMaterial({
					uniforms: { tint: c },
					fragment: "float3 shade(Surface s) { return tint; }"
				});
				scene.add(m);
			});

			three.camera.lookAt(1.8, 0, 0);
			three.camera.orbit(0, 0, 7);
			three.render(scene);
			return three.stats().drawCalls;
		`);
		defer result.free();
		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == "4", "four materials are four draws, got %s", result.value);

		image::Image shot = run.renderer.capture()!!;
		defer shot.free();

		uint red = count_near(&shot, 255, 0, 0);
		uint green = count_near(&shot, 0, 255, 0);
		uint blue = count_near(&shot, 0, 0, 255);
		uint yellow = count_near(&shot, 255, 255, 0);

		test::@check(red > 200, "the first quad is red, got %d", red);
		test::@check(green > 200, "the second survived the first push, got %d green", green);
		test::@check(blue > 200, "and the third, got %d blue", blue);
		test::@check(yellow > 200, "and the fourth, got %d yellow", yellow);
	};
}

// ============================================================================
// Unloading (game.md G2)
// ============================================================================

<*
 `scene.unload()` empties the scene and gives the assets back.

 The verb a level transition is written in. Asserted through `stats()` on both
 sides, because "the assets went" is the claim and `stats().assets` is the only
 thing a script — or an agent watching one — can read it off.

 The Scene survives, which is what separates this from `new three.Scene()`: the
 same object is still usable afterwards, and the check adds to it again to prove
 it rather than only asserting that nothing threw.
*>
fn void unloading_a_scene_gives_the_assets_back() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			const kit = three.load('test/fixtures/textured.glb');
			for (const name of kit.meshes) scene.add(new three.Mesh(kit.mesh(name)));
			const loaded = scene.stats();

			const freed = scene.unload();
			const swept = scene.stats();

			// The Scene is still the Scene: adding to it works, and the box is a
			// fresh asset the sweep knew nothing about.
			scene.add(new three.Mesh(new three.BoxGeometry(1, 1, 1)));

			return {
				loadedAssets: loaded.assets,
				loadedTextures: loaded.textures,
				freedAssets: freed.assets,
				freedTextures: freed.textures,
				freedBytes: freed.bytes,
				sweptAssets: swept.assets,
				sweptTextures: swept.textures,
				sweptBytes: swept.textureBytes,
				sweptNodes: swept.instances,
				after: scene.stats().instances,
			};
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value.contains(`"loadedAssets":1`), "one asset was resident: %s", result.value);
		test::@check(result.value.contains(`"loadedTextures":1`), "and one texture: %s", result.value);
		test::@check(result.value.contains(`"freedAssets":1`), "the unload freed it: %s", result.value);
		test::@check(result.value.contains(`"freedTextures":1`), "and its texture: %s", result.value);
		test::@check(!result.value.contains(`"freedBytes":0`), "and reported the bytes: %s", result.value);
		test::@check(result.value.contains(`"sweptAssets":0`), "nothing was left resident: %s", result.value);
		test::@check(result.value.contains(`"sweptTextures":0`), "no textures either: %s", result.value);
		test::@check(result.value.contains(`"sweptBytes":0`), "and no texture bytes: %s", result.value);
		test::@check(result.value.contains(`"sweptNodes":0`), "the scene was emptied: %s", result.value);
		test::@check(result.value.contains(`"after":1`), "and it still takes an add: %s", result.value);
	};
}

<*
 An asset handle from before an unload throws, and says what to do.

 The failure this whole generation business exists to prevent: the slot is
 reused, so without it `kit.mesh('quad')` after an unload would place geometry
 out of whatever file happened to land there next, silently. The sentence has to
 name the recovery — loading the file again — because "that asset is gone" on its
 own leaves an agent guessing at whether the path or the script is at fault.
*>
fn void an_asset_handle_from_before_an_unload_throws() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			const kit = three.load('test/fixtures/textured.glb');
			scene.unload();

			let said = '';
			try {
				scene.add(new three.Mesh(kit.meshAt(0)));
			} catch (e) {
				said = e.message;
			}

			// Loading it again is the recovery the message names, and it works.
			const fresh = three.load('test/fixtures/textured.glb');
			scene.add(new three.Mesh(fresh.meshAt(0)));

			return { said, instances: scene.stats().instances, assets: scene.stats().assets };
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value.contains("no longer loaded"), "the stale handle was refused: %s", result.value);
		test::@check(result.value.contains("unloadUnused"), "and the message names what freed it: %s", result.value);
		test::@check(result.value.contains(`"instances":1`), "the reloaded asset places: %s", result.value);
		test::@check(result.value.contains(`"assets":1`), "and it is the only one resident: %s", result.value);
	};
}

<*
 `three.unloadUnused()` frees what nothing draws and leaves what something does.

 The half `scene.unload()` cannot express: a level stays up while an asset
 loaded and then thought better of goes away. Also the case worth warning about
 in the docs — an asset that has not been added yet has no references either, so
 the order is load, add, unload rather than load, unload, add.
*>
fn void unload_unused_leaves_what_is_still_drawn() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			const kept = new three.Mesh(new three.BoxGeometry(1, 1, 1));
			scene.add(kept);

			// Built and never added: nothing names it.
			new three.SphereGeometry(1, 8, 6);
			const before = scene.stats().assets;

			const freed = three.unloadUnused();
			const after = scene.stats();

			return { before, freedAssets: freed.assets, after: after.assets, instances: after.instances };
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value.contains(`"before":2`), "both shapes were resident: %s", result.value);
		test::@check(result.value.contains(`"freedAssets":1`), "the sphere went: %s", result.value);
		test::@check(result.value.contains(`"after":1`), "and the box stayed: %s", result.value);
		test::@check(result.value.contains(`"instances":1`), "still drawing: %s", result.value);
	};
}

<*
 A hundred levels through the JavaScript API leave what they found.

 The same claim `three_tests::unload` makes against the host, made again through
 the surface a game actually writes. It is not a duplicate: everything between
 `scene.unload()` and `Assets.free_slot` — the prelude's demotion of the JS
 objects, `H.remove`, `Scene.kill`'s recursion — is only covered here, and a
 reference leaked in any of it would show up as the resident count climbing.
*>
fn void a_hundred_levels_through_the_api_leave_nothing_behind() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			const seen = new Set();

			for (let level = 0; level < 100; level++) {
				const kit = three.load('test/fixtures/textured.glb');
				const group = new three.Group();
				for (const name of kit.meshes) group.add(new three.Mesh(kit.mesh(name)));
				scene.add(group);
				// A generated shape too, so both kinds of asset cycle.
				scene.add(new three.Mesh(new three.BoxGeometry(1, 1, 1)));

				seen.add(scene.stats().assets);
				scene.unload();
				seen.add('after:' + scene.stats().assets);
			}

			const end = scene.stats();
			return {
				duringSizes: [...seen].filter(v => typeof v === 'number'),
				afterSizes: [...seen].filter(v => typeof v === 'string'),
				assets: end.assets,
				textures: end.textures,
				bytes: end.textureBytes,
				instances: end.instances,
			};
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		// Two assets while a level is up, zero after it goes — every cycle, or
		// the sets would have more than one member each.
		test::@check(result.value.contains(`"duringSizes":[2]`),
			"every level was two resident assets: %s", result.value);
		test::@check(result.value.contains(`"afterSizes":["after:0"]`),
			"and every unload took both back: %s", result.value);
		test::@check(result.value.contains(`"assets":0`), "nothing resident at the end: %s", result.value);
		test::@check(result.value.contains(`"textures":0`), "no textures either: %s", result.value);
		test::@check(result.value.contains(`"bytes":0`), "and no texture bytes: %s", result.value);
		test::@check(result.value.contains(`"instances":0`), "and an empty scene: %s", result.value);
	};
}

// ============================================================================
// asset.instantiate() — `game.md` G3/S2
// ============================================================================

<*
 A prop's own hierarchy comes back as Object3Ds, positioned where the file says.

 The host's `Scene.instantiate` is checked in `asset_test`; this is the other
 consumer of the same walk, and what it has to prove is that going out through a
 description and back in through the ordinary `add` path lands in the same
 place. `tip` is under `arm` is under `pivot` in `hierarchy.glb` and ends up at
 (2, 0, -2) — see `make_hierarchy.py` for why that number is the one no single
 mistake produces by accident.

 `pivot`'s quarter turn about +Y is exactly the pose where an Euler triple stops
 being able to say what a quaternion means — `asin` at the top of its range —
 so this is also the check on the second crossing. Sending only the Euler angles
 puts `tip` at 2.0007 rather than 2, which the rounding below is deliberately
 tight enough to fail.
*>
fn void an_instantiated_prop_keeps_its_hierarchy() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const prop = three.load("test/fixtures/hierarchy.glb");
			const tree = prop.instantiate();

			const scene = new three.Scene();
			scene.add(tree);

			const find = (o, name) => {
				if (o.name === name) return o;
				for (const c of o.children) {
					const hit = find(c, name);
					if (hit) return hit;
				}
				return null;
			};

			const tip = find(tree, "tip");
			const arm = find(tree, "arm");
			const loose = find(tree, "loose");
			// Four decimals: tight enough that the Euler-only crossing, which
			// missed by 7e-4 here, does not round to the right answer.
			const at = o => o.getWorldPosition().toArray().map(n => Math.round(n * 1e4) / 1e4);
			return {
				tip: tip ? at(tip) : null,
				loose: loose ? at(loose) : null,
				armChildren: arm ? arm.children.length : -1,
				armIsGroup: arm ? !(arm instanceof three.Mesh) : null,
				stats: scene.stats(),
			};
		`);
		defer result.free();

		test::@check(result.ok, "the script ran: %s", result.error);
		test::@check(result.value.contains(`"tip":[2,0,-2]`),
			"`tip` should be at (2, 0, -2) after the chain: %s", result.value);
		test::@check(result.value.contains(`"loose":[0,3,0]`),
			"`loose` states its transform as a matrix and should be at (0, 3, 0): %s", result.value);
		test::@check(result.value.contains(`"armChildren":3`),
			"`arm` draws a two-primitive mesh and parents `tip`, so it should have three children: %s",
			result.value);
		test::@check(result.value.contains(`"armIsGroup":true`),
			"`arm` should be a group rather than a mesh: %s", result.value);
	};
}

<*
 Two instantiations are two trees over one upload.

 `plan.md` §2 at the level G3 added: the JavaScript objects double, the node
 count doubles, and the number of unique meshes does not move. A loader that
 uploaded per instantiation would pass every positional check above and fail
 this one.
*>
fn void instantiating_a_prop_twice_shares_the_upload() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const prop = three.load("test/fixtures/hierarchy.glb");
			const scene = new three.Scene();

			const one = prop.instantiate("left");
			const two = prop.instantiate("right");
			one.position.x = -5;
			two.position.x = 5;
			scene.add(one, two);

			return scene.stats();
		`);
		defer result.free();

		test::@check(result.ok, "the script ran: %s", result.error);
		// Four primitives in the file, and two copies of each drawn.
		test::@check(result.stats.unique_meshes == 4,
			"two copies of a four-mesh prop report %d unique meshes", result.stats.unique_meshes);
		test::@check(result.stats.instances == 8,
			"two copies of four meshes should be eight instances, got %d", result.stats.instances);
		test::@check(result.stats.assets == 1,
			"two instantiations of one file report %d assets", result.stats.assets);
	};
}

<*
 An instantiated tree is ordinary objects, not a sealed handle.

 The whole reason the host answers `instantiate()` with a *description* rather
 than building host nodes itself: what comes back has not been added to anything,
 so a script can take it apart before it ever reaches a scene. Here one piece is
 pulled out and added on its own, and the rest is never added at all — which
 should draw exactly one mesh and hold exactly one reference.
*>
fn void an_instantiated_tree_can_be_taken_apart_before_it_is_added() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const prop = three.load("test/fixtures/hierarchy.glb");
			const tree = prop.instantiate();

			const find = (o, name) => {
				if (o.name === name) return o;
				for (const c of o.children) {
					const hit = find(c, name);
					if (hit) return hit;
				}
				return null;
			};

			const loose = find(tree, "loose");
			const scene = new three.Scene();
			scene.add(loose);

			return { added: loose.name, stats: scene.stats() };
		`);
		defer result.free();

		test::@check(result.ok, "the script ran: %s", result.error);
		test::@check(result.stats.instances == 1,
			"one piece of the tree was added and %d instances drew", result.stats.instances);
		test::@check(result.stats.unique_meshes == 1,
			"one piece should be one mesh, got %d", result.stats.unique_meshes);
	};
}

// ============================================================================
// Lazy loading, from JavaScript — `game.md` G3/S3
// ============================================================================

<*
 `three.load` costs nothing on the device, and adding a mesh is what pays.

 The claim an agent has to be able to act on: loading a 200-piece kit to place
 twelve costs twelve. Here it is four and one, watched through `three.stats()`
 rather than through host internals, because the number a script can read is the
 one it can plan against.

 `textures` is the observable, and it is a good one — the fixture's four meshes
 share one image, so a loader that uploaded everything eagerly would report 1
 after the load rather than 0.
*>
fn void loading_a_kit_uploads_nothing_until_a_piece_is_placed() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const kit = three.load("test/fixtures/shared_material.glb");
			const scene = new three.Scene();

			const described = kit.meshes.length;
			const afterLoad = three.stats();

			scene.add(new three.Mesh(kit.mesh("piece_2")));
			const afterOne = three.stats();

			return {
				described,
				loadedTextures: afterLoad.textures,
				loadedMeshes: afterLoad.uniqueMeshes,
				placedTextures: afterOne.textures,
				placedMeshes: afterOne.uniqueMeshes,
			};
		`);
		defer result.free();

		test::@check(result.ok, "the script ran: %s", result.error);
		test::@check(result.value.contains(`"described":4`),
			"the file's four meshes should be known without being uploaded: %s", result.value);
		test::@check(result.value.contains(`"loadedTextures":0`),
			"three.load uploaded a texture: %s", result.value);
		test::@check(result.value.contains(`"placedTextures":1`),
			"placing one mesh should have uploaded its image: %s", result.value);
		test::@check(result.value.contains(`"placedMeshes":1`),
			"placing one mesh of four should draw one: %s", result.value);
	};
}

<*
 A level can swap which pieces of a kit it uses without reloading the kit.

 What the refcount moving from the file to the mesh is for. The kit stays loaded
 across the swap — `assets` does not move — and the piece that was dropped comes
 back as `meshes` in the report, which is the number that distinguishes this from
 a sweep that took the whole file and reloaded it.
*>
fn void swapping_pieces_of_a_kit_keeps_the_kit() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const kit = three.load("test/fixtures/shared_material.glb");
			const scene = new three.Scene();

			const keep = new three.Mesh(kit.mesh("piece_0"));
			const swap = new three.Mesh(kit.mesh("piece_1"));
			scene.add(keep, swap);
			const before = three.stats();

			scene.remove(swap);
			const report = three.unloadUnused();

			scene.add(new three.Mesh(kit.mesh("piece_3")));
			const after = three.stats();

			return { before: before.uniqueMeshes, report, after: after.uniqueMeshes };
		`);
		defer result.free();

		test::@check(result.ok, "the script ran: %s", result.error);
		test::@check(result.value.contains(`"before":2`),
			"two pieces placed should be two meshes: %s", result.value);
		test::@check(result.value.contains(`"meshes":1`),
			"dropping one piece should give back one mesh: %s", result.value);
		test::@check(result.value.contains(`"assets":0`),
			"the kit itself should have stayed loaded: %s", result.value);
		test::@check(result.value.contains(`"after":2`),
			"a third piece placed after the sweep should draw: %s", result.value);
	};
}

// ============================================================================
// Animation, from JavaScript — `game.md` G3/S7
// ============================================================================

<*
 Drive the runtime from one moment to another in 60 Hz frames.

 **Not one big tick.** `JsRuntime.step_animations` clamps a single delta to
 100 ms, because a longer one means the process stalled rather than that a second
 of animation happened — so a test that jumped a second in one call would be
 asserting on the clamp. Sixty frames is what a second actually looks like, and
 the telescoping of consecutive absolute readings makes the total exact.
*>
fn void advance(three::JsRuntime* run, double from_ms, double to_ms)
{
	const double STEP = 1000.0 / 60.0;
	for (double t = from_ms; t < to_ms; t += STEP) run.tick(t);
	run.tick(to_ms);
}

<*
 `mesh.play('Walk')` — the three-line surface, working end to end.

 This is the whole of S7 in one script, and it goes through a path the host tests
 cannot reach: `asset.instantiate()` in JavaScript builds `Object3D`s and lets
 the ordinary `add` materialize them, so the host never performed the tree walk
 and only JavaScript knows which object came from which glTF node. `play` sends
 that map over on its first call. Get it wrong and the clip plays into nothing —
 the call succeeds, the time advances, and every node stays where it was.

 Which is why the check is on `tip`'s position after a tick rather than on
 `play()` returning.
*>
fn void a_clip_plays_through_the_javascript_api() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const prop = three.load("test/fixtures/hierarchy.glb");
			const rig = prop.instantiate();
			const scene = new three.Scene();
			scene.add(rig);

			const find = (o, name) => {
				if (o.name === name) return o;
				for (const c of o.children) {
					const hit = find(c, name);
					if (hit) return hit;
				}
				return null;
			};
			const tip = find(rig, "tip");

			globalThis.rig = rig;
			globalThis.tip = tip;
			rig.play("slide", { loop: false });

			return { clips: rig.animations, assetClips: prop.animations, at: tip.getWorldPosition().toArray() };
		`);
		defer result.free();
		test::@check(result.ok, "the script ran: %s", result.error);
		test::@check(result.value.contains(`"clips":["slide","spin","blink"]`),
			"the prop should list its three clips: %s", result.value);
		test::@check(result.value.contains(`"assetClips":["slide","spin","blink"]`),
			"and so should the asset: %s", result.value);

		// One second of host frames, which is what actually advances a clip.
		advance(run, 0, 1000);

		three::RunResult moved = run.run(`
			const at = globalThis.tip.getWorldPosition().toArray().map(n => Math.round(n * 1e2) / 1e2);
			return { at };
		`);
		defer moved.free();
		test::@check(moved.ok, "the second script ran: %s", moved.error);
		test::@check(moved.value.contains(`"at":[2,0,-4]`),
			"a second into `slide`, `tip` should be at (2, 0, -4): %s", moved.value);
	};
}

<*
 A playing clip keeps the window awake.

 `game.md` G3/S6's easy-to-miss term. `is_animating` is the host's "may this
 window sleep" condition and `tick`'s own early return, and a clip playing with
 no `setAnimationLoop` registered is exactly the case that was not in it — the
 clip advances, the player steps, and the frames stop arriving. Nothing about
 that reads as a bug in the animation code.

 The reverse is asserted too: once the clip finishes, the window is allowed to
 sleep again. A term that is always true is the same bug with the opposite cost.
*>
fn void a_playing_clip_keeps_the_window_awake() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		test::@check(!run.is_animating(), "a fresh runtime already wanted frames");

		three::RunResult result = run.run(`
			const rig = three.load("test/fixtures/hierarchy.glb").instantiate();
			new three.Scene().add(rig);
			globalThis.rig = rig;
			rig.play("slide", { loop: false });
			return three.stats().nodes;
		`);
		defer result.free();
		test::@check(result.ok, "the script ran: %s", result.error);

		test::@check(run.is_animating(),
			"a clip is playing with no setAnimationLoop registered and the window may sleep");

		// Past the end of a two-second clip.
		advance(run, 0, 3000);

		test::@check(!run.is_animating(),
			"the clip finished and the window still may not sleep");
	};
}

<*
 A clip that is not there is a sentence, not a silent no.

 The host answers `play` with a boolean because a false is a question rather than
 an error. JavaScript is where it becomes a message, because `mesh.animations`
 is right there and a script that named the wrong clip should be told what the
 right ones are rather than watching nothing happen.
*>
fn void playing_a_clip_that_is_not_there_says_which_ones_are() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const rig = three.load("test/fixtures/hierarchy.glb").instantiate();
			new three.Scene().add(rig);
			try { rig.play("moonwalk"); return "played"; }
			catch (e) { return e.message; }
		`);
		defer result.free();
		test::@check(result.ok, "the script ran: %s", result.error);
		test::@check(result.value.contains("moonwalk") && result.value.contains("slide"),
			"the message should name the clip asked for and the ones there are: %s", result.value);
	};
}

<*
 An ordinary Group has no animations and says so.

 A clip targets glTF nodes, so playing one needs a subtree that came from a file.
 Returning false here would leave a script unable to tell "wrong clip name" from
 "wrong kind of object".
*>
fn void an_ordinary_group_cannot_play_anything() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const g = new three.Group();
			new three.Scene().add(g);
			const empty = g.animations.length;
			try { g.play("slide"); return { empty, message: "played" }; }
			catch (e) { return { empty, message: e.message }; }
		`);
		defer result.free();
		test::@check(result.ok, "the script ran: %s", result.error);
		test::@check(result.value.contains(`"empty":0`), "a plain Group listed animations: %s", result.value);
		test::@check(result.value.contains("instantiate"),
			"the message should say which door to use: %s", result.value);
	};
}

<*
 Two props of one file play at different phases, from JavaScript.

 The per-instance player (S5) reached through the binding. Both play `slide`;
 only one gets the second tick, so their positions have to differ — and the
 asset still reports one upload behind both of them.
*>
fn void two_props_of_one_file_animate_independently() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult setup = run.run(`
			const prop = three.load("test/fixtures/hierarchy.glb");
			const scene = new three.Scene();
			const a = prop.instantiate("a");
			const b = prop.instantiate("b");
			scene.add(a, b);
			globalThis.a = a;
			globalThis.b = b;
			a.play("slide", { loop: false });
			return three.stats().assets;
		`);
		defer setup.free();
		test::@check(setup.ok, "the setup ran: %s", setup.error);

		advance(run, 0, 1000);

		three::RunResult started = run.run(`globalThis.b.play("slide", { loop: false }); return 0;`);
		defer started.free();
		test::@check(started.ok, "the second play ran: %s", started.error);

		advance(run, 1000, 1500);

		three::RunResult where = run.run(`
			const at = o => o.getObjectByName("tip").getWorldPosition().toArray()
				.map(n => Math.round(n * 1e2) / 1e2);
			return { a: at(globalThis.a), b: at(globalThis.b), assets: three.stats().assets };
		`);
		defer where.free();
		test::@check(where.ok, "the script ran: %s", where.error);
		// `a` has had 1.5s of the clip, `b` has had 0.5s.
		test::@check(where.value.contains(`"a":[2,0,-5]`),
			"the first prop should be 1.5s in, at (2, 0, -5): %s", where.value);
		test::@check(where.value.contains(`"b":[2,0,-3]`),
			"the second should be 0.5s in, at (2, 0, -3): %s", where.value);
		test::@check(where.value.contains(`"assets":1`),
			"two animated props should share one asset: %s", where.value);
	};
}

<*
 Removing an animated prop stops it, and the scene stays steppable.

 The player holds `NodeId`s into the scene, so one outliving its subtree would be
 writing sampled transforms into slots something else now occupies — a node
 moving on its own with no code anywhere that moves it.
*>
fn void removing_an_animated_prop_stops_it() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const prop = three.load("test/fixtures/hierarchy.glb");
			const scene = new three.Scene();
			const rig = prop.instantiate();
			scene.add(rig);
			rig.play("slide");
			globalThis.scene = scene;
			globalThis.rig = rig;
			return 0;
		`);
		defer result.free();
		test::@check(result.ok, "the script ran: %s", result.error);
		test::@check(run.is_animating(), "the clip is not playing");

		advance(run, 0, 500);

		three::RunResult removed = run.run(`globalThis.scene.remove(globalThis.rig); return three.stats().nodes;`);
		defer removed.free();
		test::@check(removed.ok, "the removal ran: %s", removed.error);

		test::@check(!run.is_animating(), "the removed prop is still animating");
		advance(run, 500, 1500);
	};
}

// ============================================================================
// material.dispose()
// ============================================================================

<*
 **The defect in `plan.md` §1, closed.**

 "An agent iterating on a shader in a loop accumulates one `VkPipeline` per
 distinct source for the life of the process." Twelve distinct bodies is that
 loop, written the way an agent writes it — a fresh `ShaderMaterial` per run —
 and the check is that the cache comes back under its cap rather than holding
 all twelve.

 The bodies have to differ. Two identical ones are one pipeline on purpose, so a
 version of this check written on one repeated body would pass against the cache
 that had the defect.

 Four entries are never evictable and are added to the cap here rather than
 glossed: the pass holds `mesh.slang` over four render states for its whole life
 — `SOLID_STATE` and `LINE_STATE` for `DEFAULT_MATERIAL` and `LINE_MATERIAL`,
 plus `ALPHA_STATE` and `ADDITIVE_STATE`, which `MeshPass.init` builds up front so
 that `create_texture_material` can stay device-free. The number was two until
 blending arrived; it is written as a number rather than read off the pass
 because the claim being made is about what an *agent's* shaders leave behind,
 and a cap that quietly grew with the built-ins would stop making it.

 **Proved by injection.** `PipelineCache.trim` returning immediately, which is
 the cache exactly as §1 describes it: "twelve compiles left 16 entries, and the
 cap plus the four built-in ones is 12".
*>
fn void an_agent_iterating_on_a_shader_does_not_accumulate_pipelines() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			for (let i = 0; i < 12; i++) {
				const mat = new three.ShaderMaterial({
					fragment: "float3 shade(Surface s) { return s.albedo * " + (i + 1) + ".0; }"
				});
				mat.dispose();
			}
			return "done";
		`);
		defer result.free();
		test::@check(result.ok, "the script succeeded: %s", result.error);

		three::PipelineCache* cache = &run.pass.pipelines;
		sz cap = (sz)three::MAX_UNUSED_PIPELINES + 4;
		test::@check(cache.entries.len() <= cap,
			"twelve compiles left %d entries, and the cap plus the four built-in ones is %d",
			(int)cache.entries.len(), (int)cap);
		test::@check(cache.evictions > 0, "something was actually evicted: %d", cache.evictions);
		test::@check(cache.modules.len() <= cap,
			"and the SPIR-V went with the pipelines: %d modules", (int)cache.modules.len());
	};
}

<*
 A disposed material handle throws, and disposing twice does not.

 `texture.dispose()`'s pair of rules, and they pull in opposite directions on
 purpose. The second call has nothing to give back and says so by doing nothing,
 which is what makes `dispose()` safe in a cleanup path that runs more than
 once. *Using* the handle afterwards is a different thing entirely: passing the
 dead index along would reach the host as "no such material", which is the
 message a handle from another renderer gets, and would send whoever read it to
 the wrong question.

 **Proved by injection.** `Material._index` handing back `_m` without checking
 it: "dead | disposed twice | that material is not in this context | no throw" —
 the throw came from the host, one call later, saying the wrong thing, and the
 mesh took the dead material without complaint.
*>
fn void a_disposed_material_handle_throws() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const mat = new three.ShaderMaterial({
				fragment: "float3 shade(Surface s) { return s.albedo; }"
			});
			const said = [];
			mat.dispose();
			said.push(mat.alive === false ? "dead" : "alive");
			mat.dispose();
			said.push("disposed twice");
			try { mat.side = three.BackSide; said.push("no throw"); }
			catch (e) { said.push(e.message); }
			try { new three.Mesh(new three.BoxGeometry(1, 1, 1), mat); said.push("no throw"); }
			catch (e) { said.push("refused by the mesh"); }
			return said.join(" | ");
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value.contains("dead"), "the handle knows it is gone: %s", result.value);
		test::@check(result.value.contains("disposed twice"),
			"and the second dispose was not an error: %s", result.value);
		test::@check(result.value.contains("disposed"),
			"using it said so by name: %s", result.value);
		test::@check(!result.value.contains("no throw"), "nothing went through: %s", result.value);
	};
}

<*
 A mesh keeps drawing with a material whose handle has been given back.

 The script-level half of `a_disposed_material_survives_the_mesh_that_draws_with_it`,
 asserted on the picture rather than on the bookkeeping — because the failure
 mode of collecting too early is not a crash. `MeshPass.record` skips a bucket
 whose material does not resolve, so what a premature collection produces is an
 empty frame, and an empty frame is exactly what a script that got its camera
 wrong produces too.

 **Proved by injection**, and the first version of this check did not survive
 it. `collect_materials` ignoring which materials a node names left
 `scene.stats().drawCalls` at 1 and the test **passing** — `stats` counts
 buckets out of the scene graph and never consults the material table, so it
 reports a bucket `record` went on to skip. Against the pixels the same
 injection reads "only 0 red pixels".
*>
fn void a_mesh_keeps_drawing_with_a_disposed_material() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const mat = new three.ShaderMaterial({
				fragment: "float3 shade(Surface s) { return float3(1, 0, 0); }"
			});
			const scene = new three.Scene();
			const mesh = new three.Mesh(new three.BoxGeometry(1, 1, 1), mat);
			scene.add(mesh);
			three.camera.frameAll();
			mat.dispose();
			three.render(scene, three.camera);
			return scene.stats().drawCalls;
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value.contains("1"),
			"the box is still one bucket: %s", result.value);

		// The picture, and it has to be the picture. `stats()` counts buckets out
		// of the scene graph and never consults the material table, so it answers
		// "one draw call" just as happily for a bucket `record` went on to skip.
		image::Image frame = run.renderer.capture()!!;
		defer frame.free();
		test::@check(count_near(&frame, 255, 0, 0) > 100,
			"only %d red pixels — the disposed material stopped drawing",
			count_near(&frame, 255, 0, 0));
	};
}

// ============================================================================
// Transparency and blending
//
// `plan.md` Phase A: a material can be built to blend with what is already on
// the screen, transparent draws are sorted farthest-first behind everything that
// is not, and `opacity` reaches the pixels. Every check here is a picture,
// because none of it is visible any other way — `stats()` counts buckets out of
// the scene graph and is deliberately camera-free, so it cannot tell a blended
// frame from an overwritten one (`plan.md` §10).
//
// ## The trap these tests exist inside
//
// **Blending happens in linear light behind an `_SRGB` colour attachment.** The
// hardware decodes the destination, blends, and encodes the result on write — so
// the pixel that comes back from a half-and-half mix is `encode(0.5·a + 0.5·b)`
// and **not** the average of the two encoded values. Mid-range the two differ by
// about thirty eight-bit levels, which is far more than any tolerance worth
// having, and a check written the wrong way round fails against correct code.
// `encode_srgb` below is the one place that arithmetic is written.
//
// ## And the other one: a generated shape is not white
//
// `mesh.color` *multiplies* the shape's own base colour, and a generated shape's
// is `PRIMITIVE_COLOR` — 0.78, 0.78, 0.80 in sRGB. So `mesh.color = 0xff0000` is
// not linear (1, 0, 0), it is (0.57, 0, 0), and an expectation of 255 red would
// be wrong by 56 levels for a reason that has nothing to do with blending. Every
// expectation below is built from `PRIMITIVE_COLOR` rather than from the colour
// the script asked for.
//
// The light is turned off in each fixture — `three.light.set([0, 0, 1], 1)`, an
// ambient of 1 — so a surface renders its own flat colour and the numbers are
// the blend arithmetic and nothing else. It has to come *after*
// `new three.Scene()`, which restores the default light.
// ============================================================================

<*
 One linear channel, as the eight-bit value the frame holds.

 `Target.capture` reads an `_SRGB` image, so every channel in it has been through
 the encode. Stating an expectation in linear and putting it through this is the
 only honest way to write down what a blend should produce — see the section
 header.
*>
fn int encode_srgb(float linear)
{
	return (int)math::round((double)three::linear_to_srgb(linear) * 255.0);
}

<*
 A generated shape's own base colour, in linear light, one channel at a time.

 `mesh.color` multiplies this. Read off `PRIMITIVE_COLOR` rather than written
 down, so a change to the shade every parametric shape starts at moves these
 checks with it instead of turning them red for a reason that is not theirs.
*>
fn float primitive_linear(usz channel)
{
	return three::srgb_to_linear(three::PRIMITIVE_COLOR[channel]);
}

<*
 A transparent material blends with what is behind it rather than covering it.

 The whole of Phase A in one picture: an opaque red wall, a half-opacity blue
 pane a clear two units in front of it, and a camera looking straight down the
 axis. What must be in the overlap is *neither* source colour.

 **The two quads are separated on purpose.** Interpenetrating transparent
 geometry has no correct answer under a per-object sort — three.js has the same
 limit — so a fixture built out of it would be asserting a bug rather than a
 behaviour.

 The expected mix is computed in linear light and encoded once, because that is
 what the hardware does: `encode(0.5·blue + 0.5·red)` is (146, 0, 149) and the
 sRGB-space average of the two encoded colours is (100, 0, 102). Forty-six levels
 apart in one channel, which is the whole reason `plan.md` §10 has an entry for
 it.

 The second check is what makes the first one mean something: **no pixel anywhere
 is the pane's own colour**. A pipeline that ignored the blend state would paint
 exactly that and would leave a picture that still looks like a blue pane on a
 red wall to anyone reading a screenshot description rather than the pixels.

 **Proved by injection.** `MeshPipeline.init` ignoring `state.blend` and always
 setting `blendEnable = FALSE`: "the overlap is the mix of the two, got 0 pixels
 of it" — and the second check went with it, at 2916 pixels of untouched pane.
*>
fn void a_transparent_material_blends_with_what_is_behind_it() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			three.light.set([0, 0, 1], 1);

			const wall = new three.Mesh(new three.PlaneGeometry(4, 4));
			wall.color = 0xff0000;
			wall.position.z = -1;
			scene.add(wall);

			const glass = new three.Mesh(
				new three.PlaneGeometry(1.5, 1.5),
				new three.MeshLambertMaterial({ transparent: true, opacity: 0.5 })
			);
			glass.color = 0x0000ff;
			glass.position.z = 1;
			scene.add(glass);

			three.camera.lookAt(0, 0, 0);
			three.camera.orbit(0, 0, 6);
			three.render(scene, three.camera);
			return [glass.material.transparent, glass.material.blending, glass.material.opacity].join(",");
		`);
		defer result.free();
		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value.contains("true,1,0.5"),
			"the material says what it was built as: %s", result.value);

		image::Image frame = run.renderer.capture()!!;
		defer frame.free();

		float red = primitive_linear(0);
		float blue = primitive_linear(2);
		uint mixed = count_near(&frame, encode_srgb(0.5f * red), 0, encode_srgb(0.5f * blue));
		uint untouched = count_near(&frame, 0, 0, encode_srgb(blue));

		test::@check(mixed > 500, "the overlap is the mix of the two, got %d pixels of it", mixed);
		test::@check(untouched == 0,
			"and nowhere is the pane its own colour, got %d pixels of it", untouched);
		test::@check(count_near(&frame, encode_srgb(red), 0, 0) > 500,
			"the wall around the pane is still the wall");
	};
}

<*
 An additive material brightens what is behind it instead of covering it.

 The one blend mode where the order genuinely does not matter, and the reason it
 exists at all: fire, a glow, a beam. What separates it from alpha blending in a
 picture is that **both** channels come out high — additive takes nothing away
 from the destination, so blue over red is magenta and not a darker purple.

 An alpha-blended pane at full opacity is the trap this check is shaped against:
 it renders as its own colour, which is a red channel of zero. So the assertion
 is on the red channel surviving underneath, which is exactly the thing the two
 modes disagree about.

 **Proved by injection.** `ADDITIVE` mapped to the alpha destination factors
 (`ONE_MINUS_SRC_ALPHA` rather than `ONE`): "the overlap carries both sources,
 got 0 pixels of it" — with 2916 pixels of pane colour where the mix should be.
*>
fn void an_additive_material_brightens_rather_than_covers() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			three.light.set([0, 0, 1], 1);

			const wall = new three.Mesh(new three.PlaneGeometry(4, 4));
			wall.color = 0xff0000;
			wall.position.z = -1;
			scene.add(wall);

			const glow = new three.Mesh(
				new three.PlaneGeometry(1.5, 1.5),
				new three.MeshLambertMaterial({ blending: three.AdditiveBlending })
			);
			glow.color = 0x0000ff;
			glow.position.z = 1;
			scene.add(glow);

			three.camera.lookAt(0, 0, 0);
			three.camera.orbit(0, 0, 6);
			three.render(scene, three.camera);
			return [glow.material.transparent, glow.material.blending].join(",");
		`);
		defer result.free();
		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value.contains("true,2"),
			"an additive material is a transparent one: %s", result.value);

		image::Image frame = run.renderer.capture()!!;
		defer frame.free();

		float red = primitive_linear(0);
		float blue = primitive_linear(2);
		uint both = count_near(&frame, encode_srgb(red), 0, encode_srgb(blue));
		uint covered = count_near(&frame, 0, 0, encode_srgb(blue));

		test::@check(both > 500, "the overlap carries both sources, got %d pixels of it", both);
		test::@check(covered == 0,
			"and nothing was taken away from what was behind, got %d covered pixels", covered);
	};
}

<*
 Transparent draws are recorded farthest first, whatever order their materials
 were built in.

 A blended pipeline writes no depth (`ALPHA_STATE` has the argument), so the only
 thing deciding which pane shows through which is the order they were recorded
 in. Getting it backwards is not an error and not an empty frame — it is a
 picture, of the wrong thing.

 **The fixture is built so that material order and depth order disagree.** The
 near pane's material *and* its geometry are both created first, so both the
 material index and the asset index would put it first; only the depth says
 otherwise. A comparator that never looked at the depth therefore gets it exactly
 backwards rather than accidentally right.

 The far pane is transparent at full opacity, which is what makes the two orders
 tell apart in one number: drawn first it is an opaque red backdrop and the near
 pane blends to the mix; drawn second it replaces whatever the near pane left, so
 the overlap is flatly the far pane's own colour.

 **Proved by injection.** The comparator's `if (a.order == TRANSPARENT_ORDER)`
 branch deleted, so transparent draws fall through to the key comparison: "the
 near pane is blended over the far one, got 0 pixels of the mix".
*>
fn void transparent_draws_sort_back_to_front() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			three.light.set([0, 0, 1], 1);

			// Near first: lower material index, lower asset index, and the one that
			// has to be recorded second. See the doc block.
			const near = new three.Mesh(
				new three.PlaneGeometry(1.5, 1.5),
				new three.MeshLambertMaterial({ transparent: true, opacity: 0.5 })
			);
			near.color = 0x0000ff;
			near.position.z = 1;
			scene.add(near);

			const far = new three.Mesh(
				new three.PlaneGeometry(4, 4),
				new three.MeshLambertMaterial({ transparent: true })
			);
			far.color = 0xff0000;
			far.position.z = -1;
			scene.add(far);

			three.camera.lookAt(0, 0, 0);
			three.camera.orbit(0, 0, 6);
			three.render(scene, three.camera);
			return scene.stats().drawCalls;
		`);
		defer result.free();
		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == "2", "two panes, two buckets; got %s", result.value);

		image::Image frame = run.renderer.capture()!!;
		defer frame.free();

		float red = primitive_linear(0);
		float blue = primitive_linear(2);
		uint mixed = count_near(&frame, encode_srgb(0.5f * red), 0, encode_srgb(0.5f * blue));

		test::@check(mixed > 300,
			"the near pane is blended over the far one, got %d pixels of the mix", mixed);
	};
}

<*
 Every transparent bucket is recorded after every opaque one, whatever their
 material indices say.

 The failure this prevents does not look like an ordering bug. An opaque draw
 writes depth *and* tests it, so a wall recorded after the glass in front of it
 is not blended with — it simply overwrites, and what an agent sees is glass that
 vanished.

 **The glass's material is built first**, so its index is lower than the wall's
 and a sort by material index alone puts it first. That is the whole fixture: the
 band `draw_order` reserves is the only thing that can put it second.

 **Proved by injection.** `draw_order` returning `material` for a transparent
 draw rather than `TRANSPARENT_ORDER`: "the wall shows through the glass, got 0
 pixels of the mix" — the frame was a flat wall with no pane in it at all.
*>
fn void transparent_buckets_draw_after_opaque_ones() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			three.light.set([0, 0, 1], 1);

			// The glass first, so that its material index is *lower* than the
			// opaque wall's and material order alone would record it first.
			const glassMaterial = new three.MeshLambertMaterial({ transparent: true, opacity: 0.5 });
			const wallMaterial = new three.MeshLambertMaterial({});

			const wall = new three.Mesh(new three.PlaneGeometry(4, 4), wallMaterial);
			wall.color = 0xff0000;
			wall.position.z = -1;
			scene.add(wall);

			const glass = new three.Mesh(new three.PlaneGeometry(1.5, 1.5), glassMaterial);
			glass.color = 0x0000ff;
			glass.position.z = 1;
			scene.add(glass);

			three.camera.lookAt(0, 0, 0);
			three.camera.orbit(0, 0, 6);
			three.render(scene, three.camera);
			return [glassMaterial.transparent, wallMaterial.transparent].join(",");
		`);
		defer result.free();
		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value.contains("true,false"),
			"one of each, and the transparent one built first: %s", result.value);

		image::Image frame = run.renderer.capture()!!;
		defer frame.free();

		float red = primitive_linear(0);
		float blue = primitive_linear(2);
		uint mixed = count_near(&frame, encode_srgb(0.5f * red), 0, encode_srgb(0.5f * blue));

		test::@check(mixed > 300,
			"the wall shows through the glass, got %d pixels of the mix", mixed);
	};
}

<*
 `material.opacity` is settable between frames and the pixels move.

 The property that makes opacity worth having at all: it is one float in the push
 block rather than pipeline state, so a script may write it every frame. What
 that is worth is only provable across two captures of the same scene — a single
 frame at 0.25 proves the number was read once, not that writing it again is
 free.

 At 1.0 the pane is flatly its own colour; at 0.25 it is a quarter of itself over
 three quarters of the wall, which in linear light is a colour with a *higher*
 red channel and a *lower* blue one. Both directions are asserted, because a
 fade that only moved one channel would be a fade toward black rather than toward
 what is behind it.

 **Proved by injection.** The `base_color[3] *= material.opacity()` multiply
 dropped from `MeshPass.record`: "the pane faded toward the wall, got 0 pixels of
 the quarter mix" — the second capture was byte-identical to the first, which is
 exactly what "the number was stored and nothing read it" looks like.
*>
fn void opacity_is_settable_and_reaches_the_pixels() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult solid = run.run(`
			globalThis.scene = new three.Scene();
			three.light.set([0, 0, 1], 1);

			const wall = new three.Mesh(new three.PlaneGeometry(4, 4));
			wall.color = 0xff0000;
			wall.position.z = -1;
			globalThis.scene.add(wall);

			globalThis.glass = new three.Mesh(
				new three.PlaneGeometry(1.5, 1.5),
				new three.MeshLambertMaterial({ transparent: true })
			);
			globalThis.glass.color = 0x0000ff;
			globalThis.glass.position.z = 1;
			globalThis.scene.add(globalThis.glass);

			three.camera.lookAt(0, 0, 0);
			three.camera.orbit(0, 0, 6);
			three.render(globalThis.scene, three.camera);
			return globalThis.glass.material.opacity;
		`);
		defer solid.free();
		test::@check(solid.ok, "the first run succeeded: %s", solid.error);
		test::@check(solid.value == "1", "a material starts opaque; got %s", solid.value);

		image::Image full = run.renderer.capture()!!;
		defer full.free();

		three::RunResult faded = run.run(`
			globalThis.glass.material.opacity = 0.25;
			three.render(globalThis.scene, three.camera);
			return globalThis.glass.material.opacity;
		`);
		defer faded.free();
		test::@check(faded.ok, "the second run succeeded: %s", faded.error);
		test::@check(faded.value == "0.25", "and it reads back what was set; got %s", faded.value);

		image::Image quarter = run.renderer.capture()!!;
		defer quarter.free();

		float red = primitive_linear(0);
		float blue = primitive_linear(2);

		uint whole = count_near(&full, 0, 0, encode_srgb(blue));
		test::@check(whole > 500,
			"at opacity 1 the pane is flatly itself, got %d pixels of it", whole);

		uint left = count_near(&quarter, 0, 0, encode_srgb(blue));
		uint shifted = count_near(&quarter, encode_srgb(0.75f * red), 0, encode_srgb(0.25f * blue));
		test::@check(shifted > 500,
			"the pane faded toward the wall, got %d pixels of the quarter mix", shifted);
		test::@check(left == 0,
			"and none of it is still flatly itself, got %d pixels", left);
	};
}

<*
 A debug helper draws over glass, as it draws over everything else.

 `draw_order` puts the line material above the transparent band, and the two
 decisions are the same decision made twice: a helper is drawn to be *seen*, and
 the times an agent asks where something is are the times it is inside something.
 A helper that disappeared behind the glass it was drawn to explain would be the
 same failure the line band already exists to prevent, one layer up.

 The assertion is that the helper's lines are its **own** colour and not a blend
 of it with the pane in front — which is what a helper recorded before the glass
 comes back as. Both are pictures; only one of them is a helper.

 **Proved by injection.** The `if (material == LINE_MATERIAL)` line deleted from
 `draw_order`, so a helper sorts by its material index like anything else: "the
 helper is drawn over the glass, got 0 pixels of its own colour", with 263 pixels
 of the blended-under colour in its place.
*>
fn void a_debug_helper_still_draws_over_glass() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			three.light.set([0, 0, 1], 1);

			const box = new three.Mesh(new three.BoxGeometry(1.4, 1.4, 1.4));
			box.color = 0xff0000;
			scene.add(box);
			scene.add(new three.BoxHelper(box, 0x00ff00));

			const glass = new three.Mesh(
				new three.PlaneGeometry(3, 3),
				new three.MeshLambertMaterial({ transparent: true, opacity: 0.5 })
			);
			glass.color = 0x0000ff;
			glass.position.z = 2;
			scene.add(glass);

			three.camera.lookAt(0, 0, 0);
			three.camera.orbit(0, 0, 8);
			three.render(scene, three.camera);
			return scene.stats().drawCalls;
		`);
		defer result.free();
		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == "3", "box, helper and pane; got %s", result.value);

		image::Image frame = run.renderer.capture()!!;
		defer frame.free();

		float green = primitive_linear(1);
		float blue = primitive_linear(2);
		uint over = count_near(&frame, 0, encode_srgb(green), 0);
		uint under = count_near(&frame, 0, encode_srgb(0.5f * green), encode_srgb(0.5f * blue));

		test::@check(over > 20,
			"the helper is drawn over the glass, got %d pixels of its own colour", over);
		test::@check(under == 0,
			"and none of it was blended under the pane, got %d pixels", under);
	};
}

<*
 Blending cannot be changed after a material is built, and says why.

 The one place this API deliberately refuses a Three.js line rather than
 emulating it. Blending is baked into the pipeline on this device — Metal keeps
 it inside the compiled pipeline state, so every dynamic colour-blend feature bit
 the driver advertises is false — and a settable `transparent` would mean
 re-acquiring a pipeline from a device, a target and the assembled shader source,
 to save a script the one line that builds the material it meant.

 **The refusal has to name the alternative**, which is the whole reason it is a
 throw and not a silent no-op: a script that assigned `transparent = true` and
 got nothing would look for the bug in the renderer.

 **Proved by injection.** Both setters replaced with plain field writes: "no
 throw | no throw | still false at 0" — a material reporting itself opaque while
 its pipeline had never stopped blending, which is the two halves of the API
 disagreeing about the same fact.
*>
fn void blending_cannot_change_after_construction() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const mat = new three.MeshLambertMaterial({ transparent: true });
			const said = [];
			try { mat.transparent = false; said.push("no throw"); } catch (e) { said.push(e.message); }
			try { mat.blending = three.NoBlending; said.push("no throw"); } catch (e) { said.push(e.message); }
			said.push("still " + mat.transparent + " at " + mat.blending);
			return said.join(" | ");
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(!result.value.contains("no throw"), "neither assignment went through: %s", result.value);
		test::@check(
			result.value.contains("blending is baked into the pipeline on this device"),
			"it says why: %s", result.value
		);
		test::@check(
			result.value.contains("build a new material with { transparent } or { blending } instead"),
			"and what to do instead: %s", result.value
		);
		test::@check(result.value.contains("still true at 1"),
			"and the material is what it was built as: %s", result.value);
	};
}

<*
 A blending value the API does not know is refused by name, and so is a
 `transparent` that is not a boolean.

 `_checkSide`'s rule, applied to the second constant this API borrows from
 Three.js: the message names the three values rather than saying "invalid",
 because an agent that wrote `blending: 3` was reaching for Three.js's
 `SubtractiveBlending` and needs to be told it is not here — not told it is
 wrong.

 `transparent: 0.5` is the mistake worth spending a separate sentence on. It is
 somebody meaning `opacity`, and a truthiness test would build a blended pipeline
 and leave the surface fully opaque — a material that is transparent by every
 flag and solid in the picture.

 **Proved by injection.** `_checkBlending` returning without checking and the
 `typeof` test dropped from `_resolveBlending`: "no throw | no throw | no throw |
 no throw | no throw".
*>
fn void blending_refuses_a_value_it_does_not_know() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const said = [];
			for (const bad of [3, -1, "additive", null]) {
				try { new three.MeshLambertMaterial({ blending: bad }); said.push("no throw"); }
				catch (e) { said.push(e.message); }
			}
			try { new three.MeshLambertMaterial({ transparent: 0.5 }); said.push("no throw"); }
			catch (e) { said.push(e.message); }
			return said.join(" | ");
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(!result.value.contains("no throw"), "nothing went through: %s", result.value);
		test::@check(
			result.value.contains(
				"`blending` wants three.NoBlending, three.NormalBlending or three.AdditiveBlending, not 3"
			),
			"the three constants are named, and so is what arrived: %s", result.value
		);
		test::@check(result.value.contains("not additive"),
			"a string is refused as itself rather than coerced: %s", result.value);
		test::@check(result.value.contains("not null"), "and so is null: %s", result.value);
		test::@check(
			result.value.contains("`transparent` wants true or false, not 0.5"),
			"a number where a flag belongs is told what it probably meant: %s", result.value
		);
	};
}

<*
 An opacity outside 0 to 1 is refused, and both ends of the range are not.

 The range check exists because the two ways out of it fail differently and
 neither fails loudly: above 1 the blend factor saturates and the material is
 simply opaque, below 0 it clamps and the material is simply gone. Both look like
 the renderer ignoring a script.

 **0 and 1 are asserted alongside**, because a range check written with the wrong
 comparison is invisible at every value except its two ends — and 0 is the one
 the storage format had to be shaped around (`Material.one_minus_opacity` stores
 the complement precisely so that a fully faded material is representable rather
 than being stolen by a sentinel).

 **Proved by injection.** The range test in the `opacity` setter reduced to
 `typeof v !== 'number'`: "no throw | no throw | ... | opacity NaN". Both ends of
 the range went through, and so did `NaN` — which every comparison written the
 obvious way lets past — leaving a material whose opacity was not a number at
 all.
*>
fn void opacity_outside_zero_to_one_is_refused() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const mat = new three.MeshLambertMaterial({ transparent: true });
			const said = [];
			for (const bad of [-0.1, 1.5, "half", NaN, null]) {
				try { mat.opacity = bad; said.push("no throw"); } catch (e) { said.push(e.message); }
			}
			said.push("opacity " + mat.opacity);
			try { new three.MeshLambertMaterial({ transparent: true, opacity: 2 }); said.push("no throw"); }
			catch (e) { said.push(e.message); }
			mat.opacity = 0;
			said.push("zero " + mat.opacity);
			mat.opacity = 1;
			said.push("one " + mat.opacity);
			return said.join(" | ");
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(!result.value.contains("no throw"), "nothing went through: %s", result.value);
		test::@check(result.value.contains("`opacity` wants a number from 0 to 1, not -0.1"),
			"below the range is refused by name: %s", result.value);
		test::@check(result.value.contains("not 1.5"), "and above it: %s", result.value);
		test::@check(result.value.contains("not half"), "and a string that looks like a number: %s", result.value);
		test::@check(result.value.contains("not NaN"), "and a NaN, which every comparison lets through: %s", result.value);
		test::@check(result.value.contains("opacity 1"),
			"none of them moved the material: %s", result.value);
		test::@check(result.value.contains("zero 0"), "0 is a value, not a mistake: %s", result.value);
		test::@check(result.value.contains("one 1"), "and so is 1: %s", result.value);
	};
}

// ============================================================================
// GPU time through the binding
//
// `plan.md` Phase C: the renderer measures a frame on the GPU's own clock, and
// `stats().gpuMs` is where a script reads it. The number itself is proved in
// `gpu_test.c3` — that it is non-zero, that it is a millisecond count and not a
// tick count, that a capture reports its own frame. What is proved here is the
// *join*: `SceneStats` has no `gpu_ms` field and never will, so the two halves
// of `stats()` come from two places, and either one of them can go missing
// without the other noticing.
//
// The value assertion is `> 0` and nothing tighter. A 200x150 clear with one box
// in it costs tens of microseconds on this device, and a threshold picked to
// look meaningful would be a benchmark that fails on a faster machine.
// ============================================================================

<*
 A script that renders a frame can read what that frame cost.

 The render comes first and the read comes after, which is the order the docs
 promise works: `three.render()` goes through `render_offscreen`, which waits on
 its own fence and collects its own timing, so "render, then read the stats" sees
 the render it just asked for rather than the one before it.

 Both halves of the object are checked in one script. `drawCalls` beside `gpuMs`
 is the point — the scene facts and the device measurement arrive as one answer,
 and a join that dropped either would still return a plausible-looking object.

 **Proved by injection.** `js_stats` setting `gpuMs` to a hardcoded 0 rather
 than asking the renderer — the shape of the mistake where the key is added to
 the object literal and the wiring behind it is forgotten: "the frame was
 measured: {"drawCalls":1,"gpuMs":0,"present":true,"positive":false} (this
 device reports timestamps=true)". Restored, green again.
*>
fn void stats_reports_the_renderers_gpu_time() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			scene.add(new three.Mesh(new three.BoxGeometry(1, 1, 1)));
			three.camera.frameAll();
			three.render(scene, three.camera);

			const s = three.stats();
			return {
				drawCalls: s.drawCalls,
				gpuMs: s.gpuMs,
				present: "gpuMs" in s,
				positive: s.gpuMs > 0,
			};
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value.contains(`"present":true`), "stats() carries a gpuMs: %s", result.value);
		test::@check(result.value.contains(`"positive":true`),
			"the frame was measured: %s (this device reports timestamps=%s)",
			result.value, run.renderer.gpu.limits.timestamps);
		test::@check(result.value.contains(`"drawCalls":1`),
			"and the scene facts came through the same call: %s", result.value);

		// The host's own reading and the script's are the same number, which is
		// what says the binding read the renderer rather than something that
		// merely moves like it.
		test::@check(result.gpu_ms == run.renderer.gpu_ms(),
			"the run result agrees with the renderer: %f vs %f", result.gpu_ms, run.renderer.gpu_ms());
	};
}

<*
 No device, no measurement — but still a key, and still a number.

 This is the case that makes `gpuMs` unconditional. A scene-math runtime has no
 renderer at all, so there is nothing to ask, and the tempting shape is to set
 the property only when there is something to set. That produces `undefined`,
 which is not 0 in any of the ways a script would use it: `s.gpuMs > 16` is
 quietly false, `s.gpuMs.toFixed(1)` throws somewhere unrelated, and
 `total += s.gpuMs` turns into NaN and stays that way. The whole check is on the
 *key*, and the value being 0 is the second half of the same sentence.

 The exact-string comparison is deliberate: `contains("gpuMs")` would pass on
 `"gpuMs":null` and on `"gpuMs":undefined`, which is the failure this exists to
 catch.

 **Proved by injection.** `js_stats` guarding the set with
 `if (self.renderer != null)`: "a runtime with no device answers
 {"present":false} — the key has to be there, with a 0 behind it". Note what the
 script got back: not a null, not a zero, but a property that `JSON.stringify`
 dropped on the floor because its value was `undefined`. Every other check in
 this file stayed green, since nothing else reads the field. Restored, green
 again.
*>
fn void a_runtime_without_a_device_reports_zero_gpu_time() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const s = three.stats();
			return { present: "gpuMs" in s, gpuMs: s.gpuMs };
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == `{"present":true,"gpuMs":0}`,
			"a runtime with no device answers %s — the key has to be there, with a 0 behind it",
			result.value);
		test::@check(result.gpu_ms == 0.0, "and so does the run result: %f", result.gpu_ms);
	};
}

// ============================================================================
// The post pass, from JavaScript
//
// `plan.md` Phase D item 6: `three.setPost({ fragment, uniforms })`. What is
// proved here is the **boundary** and nothing else — that the verb compiles at
// the line that wrote it, that the handle's Proxy reaches the device, that
// clearing goes through, that the refusals are sentences. The engine below it is
// `three_tests::post`'s: image A's format, the positive viewport, the identity
// round trip, retiring a swapped-out pipeline and the barriers under validation
// are all pinned there and are deliberately not repeated here.
//
// The fixture is Phase A's: a plane the size of the view, `mesh.color = 0xff0000`
// over `PRIMITIVE_COLOR`, and the light turned off with an ambient of 1 so the
// surface renders its own flat colour. Every expectation is built from
// `primitive_linear` for the reason the blending section gives — a generated
// shape is not white, so 255 red is never the number.
// ============================================================================

<*
 Put a red wall in front of the camera, lit flat.

 The one fixture every check below shares. A single colour across most of the
 frame is what makes `count_near` a usable instrument: a post body that swaps two
 channels moves several thousand pixels at once, and nothing in the picture is
 near the swapped colour by accident.
*>
fn three::RunResult red_wall_scene(three::JsRuntime* run)
{
	return run.run(`
		globalThis.scene = new three.Scene();
		three.light.set([0, 0, 1], 1);
		const wall = new three.Mesh(new three.PlaneGeometry(4, 4));
		wall.color = 0xff0000;
		globalThis.scene.add(wall);
		three.camera.lookAt(0, 0, 0);
		three.camera.orbit(0, 0, 6);
		three.render(globalThis.scene, three.camera);
	`);
}

<*
 A post body an agent wrote reaches the screen, and stays there across scripts.

 `an_agent_written_shader_reaches_the_screen` for the pass that has no geometry,
 and the same argument: the claim is not that a body compiles — `three_tests::post`
 proves that without a device — it is that the compiled thing is *recorded and
 drawn*. `p.color.bgr` swaps red and blue, so a red wall comes back blue, which
 no return value from the script could say.

 The third run is the other half and is the decision this file documents: the
 post pass belongs to the renderer and not to the scene, so it survives the end
 of the script that set it. Nobody clears it between `run()` calls — which is
 exactly the MCP server's case, where every `run_script` is a fresh scope over
 the same renderer — and a frame drawn by a script that never mentions post
 processing still goes through it. `three.setPost(null)` is the only thing that
 stops it, which is what the docs promise.

 **Proved by injection.** The `if (posted) self.post.record(...)` branch dropped
 from the tail of `Renderer.record_scene`, so the scene is drawn into image A and
 nothing ever reads it — the same shape as a post pass that compiled and was then
 never bound: "the post pass did not reach the frame: 0 blue pixels, 14400 still
 red". Restored, green again.
*>
fn void a_post_pass_reaches_the_screen() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult built = red_wall_scene(run);
		defer built.free();
		test::@check(built.ok, "the scene was built: %s", built.error);

		int red = encode_srgb(primitive_linear(0));

		image::Image plain = run.renderer.capture()!!;
		defer plain.free();
		test::@check(count_near(&plain, red, 0, 0) > 500,
			"the fixture is a red wall, got %d red pixels", count_near(&plain, red, 0, 0));

		three::RunResult posted = run.run(`
			const post = three.setPost({ fragment: "float3 post(Post p) { return p.color.bgr; }" });
			three.render(globalThis.scene, three.camera);
			return post.fragment;
		`);
		defer posted.free();
		test::@check(posted.ok, "the post shader compiled: %s", posted.error);
		test::@check(posted.value.contains("p.color.bgr"),
			"the handle carries the body that is running: %s", posted.value);

		image::Image swapped = run.renderer.capture()!!;
		defer swapped.free();
		test::@check(
			count_near(&swapped, 0, 0, red) > 500,
			"the post pass did not reach the frame: %d blue pixels, %d still red",
			count_near(&swapped, 0, 0, red),
			count_near(&swapped, red, 0, 0)
		);
		test::@check(count_near(&swapped, red, 0, 0) == 0,
			"and nowhere is the wall still its own colour, got %d pixels of it",
			count_near(&swapped, red, 0, 0));

		// A script that says nothing about post processing at all.
		three::RunResult later = run.run(`three.render(globalThis.scene, three.camera);`);
		defer later.free();
		test::@check(later.ok, "the later script succeeded: %s", later.error);

		image::Image still = run.renderer.capture()!!;
		defer still.free();
		test::@check(
			count_near(&still, 0, 0, red) > 500,
			"the pass did not survive the script that set it: %d blue pixels",
			count_near(&still, 0, 0, red)
		);
	};
}

<*
 `three.setPost(null)` puts the frame back.

 The verb's other half, and the reason it is `null` rather than a `clear()` on
 the handle: there is one post slot, so the thing being cleared is the slot and
 not the object a script happens to be holding. It answers with `null` as well,
 so `post = three.setPost(null)` leaves a script's variable saying what is true.

 The assertion is on the red wall coming back *and* on no blue being left, which
 together are the whole of "the frame is the one it was before any shader was
 set". Byte-for-byte restoration is `three_tests::post`'s check and is not
 repeated here; what this adds is that the JS verb reaches it.

 **Proved by injection.** `js_clear_post` returning before it calls
 `PostPass.clear` — the shape of the mistake where the verb is bound and wired to
 nothing: "clearing did not put the wall back: 0 red pixels, 14400 still blue".
 Restored, green again.
*>
fn void clearing_the_post_pass_restores_the_frame() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult built = red_wall_scene(run);
		defer built.free();
		test::@check(built.ok, "the scene was built: %s", built.error);

		int red = encode_srgb(primitive_linear(0));

		three::RunResult cleared = run.run(`
			three.setPost({ fragment: "float3 post(Post p) { return p.color.bgr; }" });
			three.render(globalThis.scene, three.camera);
			const answer = three.setPost(null);
			three.render(globalThis.scene, three.camera);
			return { answer, cleared: answer === null };
		`);
		defer cleared.free();
		test::@check(cleared.ok, "the script succeeded: %s", cleared.error);
		test::@check(cleared.value.contains(`"cleared":true`),
			"clearing answers with null: %s", cleared.value);

		image::Image restored = run.renderer.capture()!!;
		defer restored.free();
		test::@check(
			count_near(&restored, red, 0, 0) > 500,
			"clearing did not put the wall back: %d red pixels, %d still blue",
			count_near(&restored, red, 0, 0),
			count_near(&restored, 0, 0, red)
		);
		test::@check(count_near(&restored, 0, 0, red) == 0,
			"and no blue is left over, got %d pixels of it", count_near(&restored, 0, 0, red));
	};
}

<*
 A post uniform written through the handle's Proxy is live between frames.

 Two claims in one picture, and they fail in opposite directions:

 - **The initial value reaches the device.** `PostPass.set` zeroes the push
   block, deliberately — a new shader's uniforms are new fields at new offsets —
   so the values the spec gave have to be written *after* the compile succeeds.
   A prelude that passed them to `setPost` and stopped there would leave `gain`
   at zero and the first frame black.
 - **A later write reaches it too**, with no compile and no pipeline: the whole
   point of the uniform block, and what makes an animated post pass free.

 The first frame is asserted to be the wall at full strength and the second to be
 the wall at a quarter of it — computed in linear and encoded once, because the
 multiply happens in the body before the `_SRGB` write and a quarter of an
 encoded value is a different number entirely.

 **Proved by injection.** The `for (const name of names) handle._set(...)` loop
 removed from `three.setPost`, so the spec's uniforms are enumerated, crossed and
 never written: "the initial uniform value did not reach the device: 0 pixels at
 full strength" — a black frame, which is what a body multiplying by an unwritten
 uniform produces. The pixel check is asserted before the handle's read-back on
 purpose: the read-back fails under this injection too, and a test that stopped
 there would be proving that JavaScript remembered a number rather than that the
 GPU got one. Restored, green again.
*>
fn void post_uniforms_are_live_between_frames() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult built = red_wall_scene(run);
		defer built.free();
		test::@check(built.ok, "the scene was built: %s", built.error);

		float red = primitive_linear(0);

		three::RunResult first = run.run(`
			globalThis.post = three.setPost({
				fragment: "float3 post(Post p) { return p.color * gain; }",
				uniforms: { gain: 1 }
			});
			three.render(globalThis.scene, three.camera);
			return globalThis.post.uniforms.gain;
		`);
		defer first.free();
		test::@check(first.ok, "the post shader compiled: %s", first.error);

		image::Image bright = run.renderer.capture()!!;
		defer bright.free();
		test::@check(
			count_near(&bright, encode_srgb(red), 0, 0) > 500,
			"the initial uniform value did not reach the device: %d pixels at full strength",
			count_near(&bright, encode_srgb(red), 0, 0)
		);
		test::@check(first.value.contains("1"), "the handle reads back what it wrote: %s", first.value);

		three::RunResult second = run.run(`
			globalThis.post.uniforms.gain = 0.25;
			three.render(globalThis.scene, three.camera);
		`);
		defer second.free();
		test::@check(second.ok, "the second script succeeded: %s", second.error);

		image::Image dim = run.renderer.capture()!!;
		defer dim.free();
		test::@check(
			count_near(&dim, encode_srgb(0.25f * red), 0, 0) > 500,
			"the write through the Proxy did not reach the frame: %d pixels at a quarter",
			count_near(&dim, encode_srgb(0.25f * red), 0, 0)
		);
		test::@check(
			count_near(&dim, encode_srgb(red), 0, 0) == 0,
			"and %d pixels are still at full strength, so the write went nowhere",
			count_near(&dim, encode_srgb(red), 0, 0)
		);
	};
}

<*
 A post body that does not compile throws Slang's own text, at the agent's line.

 `plan.md` §5's done condition for a material, applied to the pass: the error a
 script catches has to *carry the diagnostic*, because a fault on its own leaves
 an agent with "it did not work" and nothing to edit. Both coordinates are
 asserted — `post:` is the file name the `#line` directive gives the body, and
 `3` is the line inside it, which is the line the script itself wrote the mistake
 on. Either alone would pass for a diagnostic naming the right file at the wrong
 line.

 The failure leaving the previous shader running is pinned at engine level and
 is not repeated; what is checked here is the JS half of it — that the throw
 happens at the `setPost` line and that a handle from before the failure is still
 the live one.

 **Proved by injection.** `post_failure` returning its fault sentence
 unconditionally, with the `if (diagnostic.len > 0)` test removed — the shape of
 the mistake where the diagnostic is collected and then not used: "the throw does
 not carry the Slang text: the post shader failed to compile and Slang said
 nothing about why". Restored, green again.
*>
fn void a_bad_post_shader_throws_the_diagnostic() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult built = red_wall_scene(run);
		defer built.free();
		test::@check(built.ok, "the scene was built: %s", built.error);

		three::RunResult result = run.run(`
			const good = three.setPost({ fragment: "float3 post(Post p) { return p.color.bgr; }" });
			try {
				three.setPost({ fragment: "float3 post(Post p)\n{\n\treturn notAFunction(p.uv);\n}" });
				return "no throw";
			} catch (e) {
				good.uniforms;
				return e.message;
			}
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(!result.value.contains("no throw"),
			"a body calling a function that does not exist was accepted");
		test::@check(
			result.value.contains("post:3") || result.value.contains("post(3)"),
			"the throw does not carry the Slang text: %s",
			result.value
		);
		test::@check(run.renderer.post.active, "the failed set left the pass with no shader at all");
	};
}

<*
 Everything `three.setPost` will not take, and what it says about each.

 No device is needed for any of these, which is the point: they are refused in
 JavaScript before a byte crosses to the host, so an agent gets the sentence at
 the line rather than a Slang error about a module that should never have been
 assembled. The one exception rides along at the end — a *valid* spec on a
 runtime with no GPU, which is the host's refusal and is the only one that could
 not be made here.

 `three.setPost(null)` with no device is checked too, and answers null rather
 than throwing: clearing a pass that cannot exist is not a mistake, and a script
 that tidies up unconditionally should not have to ask first.

 **Proved by injection.** The `typeof fragment !== 'string'` test dropped from
 `three.setPost`, so a spec with no body crosses to the host and is refused there
 for the wrong reason: "and a spec with no body says which field: ... empty:
 compiling a post shader needs a GPU device and this context has none | blank:
 compiling a post shader needs a GPU device and this context has none ...". Note
 that everything still *threw* — a device is missing either way — which is why
 this check reads the sentences and not merely the absence of a success.
 Restored, green again.
*>
fn void a_post_spec_that_is_not_one_is_refused() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const body = "float3 post(Post p) { return p.color; }";
			const said = [];
			const refuse = (what, spec) => {
				try { three.setPost(spec); said.push(what + ": no throw"); }
				catch (e) { said.push(what + ": " + e.message); }
			};

			refuse("number", 5);
			refuse("empty", {});
			refuse("blank", { fragment: "   " });
			refuse("uniforms", { fragment: body, uniforms: 5 });
			refuse("word", { fragment: body, uniforms: { gain: "loud" } });
			refuse("table", { fragment: body, uniforms: { palette: [[1, 0, 0], [0, 1, 0]] } });
			refuse("wide", { fragment: body, uniforms: { m: [1, 2, 3, 4, 5] } });
			refuse("valid", { fragment: body });

			said.push("cleared: " + three.setPost(null));
			return said.join(" | ");
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(!result.value.contains("no throw"), "everything was refused: %s", result.value);
		test::@check(result.value.contains("wants an options object, or null to clear the pass"),
			"a number is not a spec: %s", result.value);
		test::@check(result.value.contains("needs a `fragment` body"),
			"and a spec with no body says which field: %s", result.value);
		test::@check(result.value.contains("blank: a post pass needs a `fragment` body"),
			"whitespace is not a body: %s", result.value);
		test::@check(result.value.contains("`uniforms` wants an object"),
			"and neither is a number of uniforms: %s", result.value);
		test::@check(result.value.contains("uniform 'gain' wants a number or an array of up to four numbers"),
			"a uniform that is a word is refused by name: %s", result.value);
		test::@check(result.value.contains("no instances to select a row with"),
			"and a table says why a post pass cannot have one: %s", result.value);
		test::@check(result.value.contains("uniform 'm' wants a number"),
			"five floats is not a uniform: %s", result.value);
		test::@check(result.value.contains("needs a GPU device"),
			"and a valid spec with no device says which piece is missing: %s", result.value);
		test::@check(result.value.contains("cleared: null"),
			"clearing without a device is not a mistake: %s", result.value);
	};
}

<*
 A handle from before a replacement will not steer the shader that replaced it.

 There is one post slot, so `three.setPost` twice leaves a script holding two
 objects and one pass. The dangerous shape is the quiet one: the old handle's
 uniform names are usually the *same* names, so a write through it would land on
 the new shader's block and change the picture in a way that reads as the new
 body being wrong. An epoch check turns that into a sentence, which is the same
 trade `Scene` makes when a second `new three.Scene()` replaces the first.

 The new handle is exercised in the same breath, because a check that only proved
 the old one throws would also pass if *both* did.

 **Proved by injection.** The handle's `_check` neutered to `if (false)` — every
 handle answering as the live one, which is the version where nothing goes stale:
 "the replaced handle wrote through: old: no throw | new: 0.5 | unknown: the post
 pass has no uniform called 'nope' — it declared gain". Note the other two checks
 stayed green, which is the whole reason the stale write is asserted separately
 from the live one. Restored, green again.
*>
fn void a_replaced_post_handle_is_refused() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult built = red_wall_scene(run);
		defer built.free();
		test::@check(built.ok, "the scene was built: %s", built.error);

		three::RunResult result = run.run(`
			const said = [];
			const first = three.setPost({
				fragment: "float3 post(Post p) { return p.color * gain; }",
				uniforms: { gain: 1 }
			});
			const second = three.setPost({
				fragment: "float3 post(Post p) { return p.color * gain * 0.5; }",
				uniforms: { gain: 1 }
			});

			try { first.uniforms.gain = 0.25; said.push("old: no throw"); }
			catch (e) { said.push("old: " + e.message); }

			second.uniforms.gain = 0.5;
			said.push("new: " + second.uniforms.gain);

			try { second.uniforms.nope = 1; said.push("unknown: no throw"); }
			catch (e) { said.push("unknown: " + e.message); }

			return said.join(" | ");
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(!result.value.contains("no throw"), "the replaced handle wrote through: %s", result.value);
		test::@check(result.value.contains("replaced by a later three.setPost()"),
			"and it says what happened to it: %s", result.value);
		test::@check(result.value.contains("new: 0.5"),
			"the live handle still writes: %s", result.value);
		test::@check(result.value.contains("the post pass has no uniform called 'nope'"),
			"and an undeclared name is refused by the same Proxy a material uses: %s", result.value);
	};
}
