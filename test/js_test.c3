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
import std::core::test;
import std::io;

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
