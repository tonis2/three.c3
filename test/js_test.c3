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
