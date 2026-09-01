<*
 `three.debug.write(...)` — the run's second answer, `src/js/runtime.c3`.

	`c3c test --trust=full --test-noleak --test-filter three_tests::debug`

 **What this exists to check is that the debug array is always parseable JSON.**
 It is spliced into the tool result rather than escaped into it, so a hole in it
 is not a bad value an agent reads and shrugs at — it is a malformed result the
 agent cannot read at all. The two ways to make a hole are a value with no JSON
 form and a callback writing while nobody is listening, and both have a test.

 The rest is the split with `value`: what a script SAID on its way through and
 what it ANSWERED with are separate fields, and neither one clears the other.
*>
module three_tests::debug;

import three;
import vk;
import std::core::test;

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
// The sink
// ============================================================================

<*
 One entry per argument, in the order they were written.

 The array shape rather than a merged object: a script that writes from three
 places has three things to say and no key to agree on between them.
*>
fn void write_collects_every_argument_in_order() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			three.debug.write({ crates: 24 });
			three.debug.write(42, 'done');
		`);
		defer result.free();

		test::@check(result.ok, "the script ran: %s", result.error);
		test::eq(result.debug, `[{"crates":24},42,"done"]`);
	};
}

<*
 Empty, not `[]`, when nothing was written.

 The same distinction `value` draws between returning null and returning
 nothing: the MCP report leaves the field out entirely on this run, and a
 caller that saw `[]` would have to decide whether an empty array meant
 anything.
*>
fn void a_run_that_writes_nothing_says_nothing() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run("const x = 1;");
		defer result.free();

		test::@check(result.ok, "the script ran: %s", result.error);
		test::eq(result.debug.len, 0);
	};
}

<*
 The two fields do not stand in for one another.

 A script may do both, and each half has to arrive whole — the debug entries
 are not folded into the return, and returning does not empty the sink.
*>
fn void a_script_can_write_and_return_in_the_same_run() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			three.debug.write('on the way');
			return { at: 'the end' };
		`);
		defer result.free();

		test::@check(result.ok, "the script ran: %s", result.error);
		test::eq(result.debug, `["on the way"]`);
		test::eq(result.value, `{"at":"the end"}`);
	};
}

<*
 A new run answers for itself.

 Same reason `log` and `value` are cleared at the top of every run: an entry
 that outlived the script that wrote it reads as this script's, and the agent
 acts on a number from two calls ago.
*>
fn void the_sink_is_emptied_between_runs() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult first = run.run("three.debug.write('one');");
		test::eq(first.debug, `["one"]`);
		first.free();

		three::RunResult second = run.run("three.debug.write('two');");
		defer second.free();
		test::eq(second.debug, `["two"]`);
	};
}

<*
 `write` sits on the same object as `view`, and neither shadows the other.

 The regression this file was written after: `debug` was already the renderer's
 view selector, and adding a second `debug` to the `three` literal replaced it
 with a plain object — `three.debug.view = 'shadow'` then stored a string on it
 and every shadow diagnostic silently stopped working. Nothing threw.
*>
fn void write_lives_beside_the_view_rather_than_replacing_it() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			three.debug.view = 'shadow';
			three.debug.write(three.debug.view);
			three.debug.view = 'off';
			return three.debug.view;
		`);
		defer result.free();

		test::@check(result.ok, "the script ran: %s", result.error);
		test::eq(result.debug, `["shadow"]`);
		test::eq(result.value, `"off"`);
	};
}

// ============================================================================
// Always parseable
// ============================================================================

<*
 A cycle is JSON.stringify's one throw, and it must not become a hole.

 `String(value)` instead, which is what a log would have shown. The entry is
 useless and the array is still an array — the trade the other way round costs
 the caller every other entry beside it.
*>
fn void a_cyclic_value_arrives_as_text_rather_than_breaking_the_array() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const loop = { n: 1 };
			loop.self = loop;
			three.debug.write(loop, 1);
		`);
		defer result.free();

		test::@check(result.ok, "the script ran: %s", result.error);
		test::eq(result.debug, `["[object Object]",1]`);
	};
}

<*
 `undefined` and a function have no JSON form at all — a quieter hole than a
 throw, and the same repair.
*>
fn void what_has_no_json_form_arrives_as_text_too() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			three.debug.write(undefined, () => 1);
		`);
		defer result.free();

		test::@check(result.ok, "the script ran: %s", result.error);
		test::eq(result.debug, `["undefined","() => 1"]`);
	};
}

<*
 The host is the one that guarantees the JSON, not the prelude.

 `__three` is reachable from a script, so a caller that hands the binding a
 value of its own devising must not be able to put its own characters into the
 result. The binding stringifies whatever arrives; it never splices it.
*>
fn void the_binding_json_encodes_rather_than_trusting_its_caller() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			__three.debugWrite('", "injected": true, "x": "');
		`);
		defer result.free();

		test::@check(result.ok, "the script ran: %s", result.error);
		test::eq(result.debug, `["\", \"injected\": true, \"x\": \""]`);
	};
}

// ============================================================================
// From inside a frame
// ============================================================================

<*
 A system writes when no run is listening, and the next one reports it.

 Exactly what `console.log` from a callback does. Without the second sink these
 entries would land in `debug` and be cleared unread at the top of the run that
 was going to report them, which is the silent half of the feature and the only
 part a script cannot see going wrong.
*>
fn void entries_written_in_a_frame_are_held_for_the_next_run() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult started = run.run(`
			let n = 0;
			three.setAnimationLoop(() => { three.debug.write({ frame: ++n }); });
		`);
		test::@check(started.ok, "the script ran: %s", started.error);
		// Nothing to report yet: the callback has not run.
		test::eq(started.debug.len, 0);
		started.free();

		double at = 0;
		for (int i = 0; i < 3; i++)
		{
			at += 16.0;
			run.tick(at);
		}

		three::RunResult after = run.run("three.setAnimationLoop(null);");
		defer after.free();
		test::@check(after.ok, "the script ran: %s", after.error);
		test::eq(after.debug, `[{"frame":1},{"frame":2},{"frame":3}]`);
	};
}

<*
 A frame's entries read before the script's, because they happened first.
*>
fn void a_frames_entries_come_before_the_scripts_own() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult started = run.run(`
			three.setAnimationLoop(() => { three.debug.write('frame'); });
		`);
		test::@check(started.ok, "the script ran: %s", started.error);
		started.free();

		run.tick(16.0);

		three::RunResult after = run.run(`
			three.setAnimationLoop(null);
			three.debug.write('script');
		`);
		defer after.free();
		test::eq(after.debug, `["frame","script"]`);
	};
}
