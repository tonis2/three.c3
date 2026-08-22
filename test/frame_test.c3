<*
 The animation loop: what a tick does, and the four ways one stops.

	`c3c test --trust=full --test-noleak --test-filter three_tests::frame`

 **No window and no device.** `JsRuntime.tick` takes the time as an argument
 rather than reading a clock, which is what makes every check below a statement
 about the callback rather than about how fast the machine was — and it is the
 whole reason a feature that only exists while a window is open has tests at all.

 **Assert on what the callback did, not on the tick returning true.** A tick
 answers true for a callback that ran and threw as readily as for one that
 worked, so every check reads the state the callback was supposed to change, or
 the reason it was stopped.
*>
module three_tests::frame;

import three;
import qjs;
import std::core::test;
import std::io;
import std::math;
import std::time;

<*
 A runtime over a scene with no device behind it, and the scene itself.

 The same construction `js_test.c3` uses: `MeshPass` by hand, because `init`
 wants a pipeline and therefore a GPU, and nothing here draws anything.
*>
macro @with_js(; @body(three::JsRuntime* run, three::MeshPass* pass))
{
	three::MeshPass pass;
	pass.scene.init();
	pass.assets.init();
	pass.scene.attach_assets(&pass.assets);
	pass.camera = three::default_camera();
	defer pass.scene.free();
	defer pass.assets.free(null);

	three::JsRuntime runtime;
	runtime.open(&pass)!!;
	defer runtime.close();

	@body(&runtime, &pass);
}

<*
 Run a script and fail the test if it did not succeed. Registration is a script,
 so most checks below open with one, and a typo in a fixture that reported itself
 as "the callback never ran" would be a long afternoon.
*>
macro @ok(three::JsRuntime* run, String source)
{
	three::RunResult result = run.run(source);
	defer result.free();
	test::@check(result.ok, "the setup script succeeded: %s", result.error);
}

// A script's answer as a string, for the checks that read state back out of JS.
macro String @answer(three::JsRuntime* run, String source)
{
	three::RunResult result = run.run(source);
	defer result.free();
	test::@check(result.ok, "the reading script succeeded: %s", result.error);
	return result.value.copy(mem);
}

// ============================================================================
// A tick is a call
// ============================================================================

fn void a_callback_runs_once_per_tick() @test
{
	@with_js(; three::JsRuntime* run, three::MeshPass* pass)
	{
		@ok(run, "globalThis.n = 0; three.setAnimationLoop(() => { globalThis.n++; });");

		test::@check(run.tick(0), "the first tick ran a callback");
		run.tick(16);
		run.tick(32);

		String n = @answer(run, "return globalThis.n;");
		defer n.free(mem);
		test::@check(n == "3", "three ticks called it three times, got '%s'", n);
	};
}

<*
 Nothing registered is not an error, and it is not a call either.

 The host loop ticks on every single frame whether or not a script has ever run,
 so this is the path taken millions of times and it has to cost nothing and say
 nothing.
*>
fn void a_runtime_with_no_callback_does_not_tick() @test
{
	@with_js(; three::JsRuntime* run, three::MeshPass* pass)
	{
		test::@check(!run.tick(0), "there was nothing to run");

		three::RunResult result = run.run("return 1;");
		defer result.free();
		test::@check(!result.frame_running, "and nothing is reported as running");
		test::@check(result.frame_ticks == 0, "and no frames are claimed, got %d", result.frame_ticks);
	};
}

<*
 The callback is told the time, and told the host's time rather than its own.

 An animation that reads the elapsed milliseconds is the difference between one
 that runs at the same speed on every machine and one that runs at the frame
 rate — which is why `setAnimationLoop` passes it in Three.js and why it is
 passed here.
*>
fn void the_callback_is_told_what_time_it_is() @test
{
	@with_js(; three::JsRuntime* run, three::MeshPass* pass)
	{
		@ok(run, "three.setAnimationLoop((ms) => { globalThis.seen = ms; });");

		run.tick(1250.5);
		String seen = @answer(run, "return globalThis.seen;");
		defer seen.free(mem);
		test::@check(seen == "1250.5", "the callback got the host's clock, got '%s'", seen);
	};
}

<*
 What the loop is actually for: host state that changes with no agent in it.

 The camera rather than a mesh, because it needs no asset and no device — and
 because turning the camera is the thing somebody watching the window would
 actually ask for.
*>
fn void a_callback_moves_the_scene() @test
{
	@with_js(; three::JsRuntime* run, three::MeshPass* pass)
	{
		@ok(run, "three.setAnimationLoop(() => { three.camera.orbit(three.camera.yaw + 10); });");

		// Read rather than assumed: `default_camera` does not start at zero, and
		// a test that hard-codes where it starts fails the day somebody picks a
		// nicer opening angle — for a reason that has nothing to do with frames.
		float before = pass.camera.yaw;
		run.tick(0);
		run.tick(16);
		run.tick(32);

		test::@check(
			math::abs(pass.camera.yaw - before - 30.0f) < 0.001f,
			"three ticks turned the camera 30 degrees, from %f to %f",
			before, pass.camera.yaw
		);
	};
}

<*
 A microtask the callback made settles inside the same frame.

 One line of `Promise.resolve().then(...)` in a callback is ordinary JavaScript,
 and leaving it queued would run it during some later frame — with that frame's
 budget, that frame's log, and a scene that has moved on.
*>
fn void a_microtask_the_callback_made_settles_in_the_same_frame() @test
{
	@with_js(; three::JsRuntime* run, three::MeshPass* pass)
	{
		@ok(run, `
			globalThis.n = 0;
			three.setAnimationLoop(() => { Promise.resolve().then(() => { globalThis.n++; }); });
		`);

		run.tick(0);

		String n = @answer(run, "return globalThis.n;");
		defer n.free(mem);
		test::@check(n == "1", "the microtask ran in its own frame, got '%s'", n);
	};
}

// ============================================================================
// Registering, replacing, stopping
// ============================================================================

fn void null_stops_the_loop() @test
{
	@with_js(; three::JsRuntime* run, three::MeshPass* pass)
	{
		@ok(run, "globalThis.n = 0; three.setAnimationLoop(() => { globalThis.n++; });");
		run.tick(0);

		@ok(run, "three.setAnimationLoop(null);");
		test::@check(!run.tick(16), "there is nothing left to tick");

		String n = @answer(run, "return globalThis.n;");
		defer n.free(mem);
		test::@check(n == "1", "the callback ran once and then stopped, got '%s'", n);
	};
}

<*
 A stopped loop has to *stay* stopped, and be reported as stopped.

 `setAnimationLoop(null)` is how a script gets back to a state a screenshot can
 be taken of, so "the clock is off" is a fact the next result has to carry —
 otherwise the only way to find out is to take two screenshots and compare them.
*>
fn void a_stopped_loop_reports_itself_as_stopped() @test
{
	@with_js(; three::JsRuntime* run, three::MeshPass* pass)
	{
		@ok(run, "three.setAnimationLoop(() => {});");

		three::RunResult running = run.run("return 1;");
		defer running.free();
		test::@check(running.frame_running, "a registered callback is reported as running");

		three::RunResult stopped = run.run("three.setAnimationLoop(null); return 1;");
		defer stopped.free();
		test::@check(!stopped.frame_running, "and a cleared one is not");
	};
}

fn void registering_again_replaces_the_first() @test
{
	@with_js(; three::JsRuntime* run, three::MeshPass* pass)
	{
		@ok(run, `
			globalThis.a = 0;
			globalThis.b = 0;
			three.setAnimationLoop(() => { globalThis.a++; });
			three.setAnimationLoop(() => { globalThis.b++; });
		`);

		run.tick(0);

		String counts = @answer(run, "return [globalThis.a, globalThis.b];");
		defer counts.free(mem);
		test::@check(counts == "[0,1]", "only the second one runs, got '%s'", counts);
	};
}

<*
 How many frames went by is the one number that says the loop is alive.

 It counts since the last call rather than since the loop started, because
 "sixty frames since you last looked" is the answer to the question an agent is
 actually asking, and a total is the same number every time once it is large.
*>
fn void the_frame_count_comes_back_and_resets() @test
{
	@with_js(; three::JsRuntime* run, three::MeshPass* pass)
	{
		@ok(run, "three.setAnimationLoop(() => {});");
		run.tick(0);
		run.tick(16);
		run.tick(32);

		three::RunResult first = run.run("return 1;");
		defer first.free();
		test::@check(first.frame_ticks == 3, "three frames since the last call, got %d", first.frame_ticks);

		three::RunResult second = run.run("return 1;");
		defer second.free();
		test::@check(second.frame_ticks == 0, "and none since that one, got %d", second.frame_ticks);
	};
}

// ============================================================================
// The four ways a callback stops
// ============================================================================

<*
 A throwing callback is stopped, and the throw survives to the next run.

 **This is the whole policy in one check.** The alternative — call it again next
 frame — throws sixty times a second into a log nobody drains, in a window that
 has visibly stopped moving, and leaves the agent with a scene that does not
 animate and no statement anywhere about why.
*>
fn void a_throwing_callback_is_stopped_and_says_why() @test
{
	@with_js(; three::JsRuntime* run, three::MeshPass* pass)
	{
		@ok(run, "three.setAnimationLoop(() => { throw new Error('the wheels came off'); });");

		test::@check(run.tick(0), "the callback ran");
		test::@check(!run.tick(16), "and does not run again");

		three::RunResult result = run.run("return 1;");
		defer result.free();

		test::@check(result.ok, "the run that reports it is not itself a failure");
		test::@check(!result.frame_running, "and the loop is reported as stopped");
		test::@check(
			result.frame_error.contains("the wheels came off"),
			"the callback's own message survives: '%s'",
			result.frame_error
		);
	};
}

<*
 Reported to one caller, not to every caller from now on.

 A reason that repeats is a reason that gets ignored: the fifth tool call in a
 row carrying the same stopped-callback error is indistinguishable from a
 callback that is failing again right now.
*>
fn void the_reason_reaches_exactly_one_run() @test
{
	@with_js(; three::JsRuntime* run, three::MeshPass* pass)
	{
		@ok(run, "three.setAnimationLoop(() => { throw new Error('once'); });");
		run.tick(0);

		three::RunResult first = run.run("return 1;");
		defer first.free();
		test::@check(first.frame_error.contains("once"), "the first run carries it: '%s'", first.frame_error);

		three::RunResult second = run.run("return 1;");
		defer second.free();
		test::@check(second.frame_error.len == 0, "and the second does not: '%s'", second.frame_error);
	};
}

<*
 `while (true) {}` in a callback ends, and ends in a tenth of a second.

 The interrupt handler is shared with `JsRuntime.run`, so this is also the check
 that a frame borrows the budget rather than replacing it — see the test below,
 which is the other half.
*>
fn void an_endless_callback_is_stopped_by_the_frame_budget() @test
{
	@with_js(; three::JsRuntime* run, three::MeshPass* pass)
	{
		@ok(run, "three.setAnimationLoop(() => { while (true) {} });");

		Clock started = clock::now();
		test::@check(run.tick(0), "the callback ran");
		long spent_ms = (long)started.to_now() / 1_000_000;

		test::@check(!run.tick(16), "and was stopped for good");

		// The clock rather than the message, because the message is a sentence
		// the code chooses and this is the fact it claims. An injection that
		// removed the frame budget entirely left the sentence saying "100 ms"
		// while the tick sat there for the script's five seconds, and only this
		// line can tell those apart. Ten times the budget and five times under
		// the failure: not a rate this asserts, just which budget applied.
		test::@check(spent_ms < 1_000, "under the frame budget, not the script's: %d ms", spent_ms);

		three::RunResult result = run.run("return 1;");
		defer result.free();
		test::@check(
			result.frame_error.contains("100 ms"),
			"named as the frame budget rather than the script's: '%s'",
			result.frame_error
		);
	};
}

<*
 A frame borrows the script's budget and gives it back.

 The one interrupt handler reads one field, so a tick that set it and walked away
 would silently hand every later script the frame's tenth of a second — a scene
 build that worked yesterday failing today, with a timeout message naming a
 number nobody typed.

 Set through `script_budget_ns` rather than `budget_ns`, which is what those two
 fields now mean: `budget_ns` is the live value the interrupt reads and a frame
 borrows, and `script_budget_ns` is what a run puts back into it at the top of
 every run. They were one field until `three.budget` let a script raise its own —
 at which point sharing them would have made a raised script budget into a raised
 per-frame one, and one animation callback able to wedge a game for as long as
 it liked.
*>
fn void the_frame_budget_is_not_the_script_budget() @test
{
	@with_js(; three::JsRuntime* run, three::MeshPass* pass)
	{
		run.script_budget_ns = 200 * 1_000_000;
		@ok(run, "three.setAnimationLoop(() => {});");
		run.tick(0);

		three::RunResult result = run.run("while (true) {}");
		defer result.free();

		test::@check(!result.ok, "the script was still stopped");
		test::@check(
			result.error.contains("200 ms"),
			"under its own budget, not the frame's: '%s'",
			result.error
		);
	};
}

<*
 An async callback is refused where it is written, not where it fails.

 It fails in a way that reads as nothing happening at all: it returns a promise
 immediately, does its work on some later microtask, and the frame it was meant
 to be part of has been presented by then. A TypeError on the line that
 registered it is the difference between a five-second fix and an afternoon.
*>
fn void an_async_callback_is_refused_at_registration() @test
{
	@with_js(; three::JsRuntime* run, three::MeshPass* pass)
	{
		three::RunResult result = run.run("three.setAnimationLoop(async () => {});");
		defer result.free();

		test::@check(!result.ok, "the registration failed");
		test::@check(result.error.contains("synchronous"), "and says what is wrong: '%s'", result.error);
		test::@check(!run.tick(0), "and nothing was registered");
	};
}

<*
 A plain function that happens to return a promise is caught at the first tick.

 The registration check reads `AsyncFunction`, which `() => fetch(...)` is not.
 The two together are the guarantee — one catches the spelling, one catches the
 behaviour.
*>
fn void a_callback_that_returns_a_promise_is_stopped() @test
{
	@with_js(; three::JsRuntime* run, three::MeshPass* pass)
	{
		@ok(run, "three.setAnimationLoop(() => Promise.resolve(1));");

		test::@check(run.tick(0), "it ran once");
		test::@check(!run.tick(16), "and was stopped");

		three::RunResult result = run.run("return 1;");
		defer result.free();
		test::@check(
			result.frame_error.contains("promise"),
			"and says what it did: '%s'",
			result.frame_error
		);
	};
}

<*
 The callback outlives `new three.Scene()`, and is stopped by the handles it
 kept rather than by the reset.

 The loop belongs to the host, as Three.js's does to the renderer, so a script
 that rebuilds the scene does not silently lose its animation. What it does lose
 is every handle it captured, and the stale-handle throw is exactly the sentence
 that says so — which is better than a callback that keeps running against
 nothing.
*>
fn void a_callback_holding_the_old_scene_is_stopped_not_ignored() @test
{
	@with_js(; three::JsRuntime* run, three::MeshPass* pass)
	{
		@ok(run, `
			const scene = new three.Scene();
			const g = new three.Group();
			scene.add(g);
			three.setAnimationLoop(() => { g.position.x += 1; });
		`);
		test::@check(run.tick(0), "it ran against the scene it was built for");

		@ok(run, "new three.Scene();");
		test::@check(run.tick(16), "it ran once more");
		test::@check(!run.tick(32), "and was stopped");

		three::RunResult result = run.run("return 1;");
		defer result.free();
		test::@check(
			result.frame_error.contains("no longer in the scene"),
			"with the stale-handle sentence: '%s'",
			result.frame_error
		);
	};
}

fn void a_non_function_is_refused_by_the_host_too() @test
{
	@with_js(; three::JsRuntime* run, three::MeshPass* pass)
	{
		// Past `prelude.js` deliberately: `__three` is reachable from a script,
		// and a number retained here would be called once a frame forever.
		three::RunResult result = run.run("globalThis.__three.setFrame(5);");
		defer result.free();

		test::@check(!result.ok, "the host refused it");
		test::@check(result.error.contains("wants a function"), "and says so: '%s'", result.error);
		test::@check(!run.tick(0), "and nothing was registered");
	};
}

// ============================================================================
// What the frames logged
// ============================================================================

<*
 A callback's `console.log` reaches the next run, under a marker.

 Without the marker the callback's lines arrive above the script's own and read
 as the script's own — an agent debugging the script it just wrote would be
 reading output from a function it registered ten calls ago.
*>
fn void what_a_frame_logged_arrives_with_the_next_run() @test
{
	@with_js(; three::JsRuntime* run, three::MeshPass* pass)
	{
		@ok(run, "let n = 0; three.setAnimationLoop(() => { console.log('frame', n++); });");

		run.tick(0);
		run.tick(16);

		three::RunResult result = run.run(`console.log("the script");`);
		defer result.free();

		test::@check(
			result.log == "[animation loop]\nframe 0\nframe 1\n[script]\nthe script\n",
			"both halves, in order and labelled, got '%s'",
			result.log
		);
	};
}

<*
 A script that never animates sees exactly what it always saw.

 The markers are the kind of addition that quietly changes every result in the
 project; this is the check that says they do not.
*>
fn void a_script_that_never_animates_sees_no_markers() @test
{
	@with_js(; three::JsRuntime* run, three::MeshPass* pass)
	{
		three::RunResult result = run.run(`console.log("hello");`);
		defer result.free();
		test::@check(result.log == "hello\n", "the log is only the script's, got '%s'", result.log);
	};
}

<*
 A callback that logs every frame is bounded, and says what it dropped.

 Sixty lines a second fills anything. **The oldest go**, because the state worth
 seeing is the state it is in now — and the count goes with them, because a log
 that silently begins in the middle is a log that will be read as the beginning.
*>
fn void a_flood_of_logging_is_bounded_and_says_what_it_dropped() @test
{
	@with_js(; three::JsRuntime* run, three::MeshPass* pass)
	{
		@ok(run, `
			let n = 0;
			three.setAnimationLoop(() => { console.log('line ' + (n++) + ' ' + 'x'.repeat(200)); });
		`);

		for (int i = 0; i < 100; i++) run.tick((double)i * 16.0);

		three::RunResult result = run.run("return 1;");
		defer result.free();

		test::@check(result.log.len < 12_000, "the log is bounded, got %d bytes", result.log.len);
		test::@check(result.log.contains("earlier lines dropped"), "and says it dropped some: '%s'", result.log[:120]);
		test::@check(result.log.contains("line 99 "), "the newest line survived");
		test::@check(!result.log.contains("line 0 "), "and the oldest did not");
	};
}

// ============================================================================
// The other reader: a terminal, when there is no agent
// ============================================================================

<*
 A host with a terminal drains the lines *and* the reason the callback stopped.

 `--mcp` keeps both for the next tool call, because the next tool call is the
 first moment anyone is listening. A `--script` or `--assets` boot with no
 listener has no next call: the callback dies, the window stops moving, and
 without this the reason sits in a buffer until the process exits.

 The reason comes after the lines because that is the order they happened — a
 callback logs and *then* throws.
*>
fn void a_host_with_a_terminal_drains_what_the_frames_said() @test
{
	@with_js(; three::JsRuntime* run, three::MeshPass* pass)
	{
		@ok(run, `
			let n = 0;
			three.setAnimationLoop(() => {
				console.log('frame ' + n);
				if (n++ === 1) throw new Error('the wheels came off');
			});
		`);

		run.tick(0);
		run.tick(16);

		DString said;
		said.init(mem, 128);
		defer said.free();
		run.take_frame_output(&said);
		String text = said.str_view();

		test::@check(text.contains("frame 0\nframe 1\n"), "both lines, in order: '%s'", text);
		test::@check(text.contains("the wheels came off"), "and why it stopped: '%s'", text);
		test::@check(
			text.index_of("frame 1")!! < text.index_of("the wheels")!!,
			"the reason comes last, because it happened last: '%s'", text
		);
	};
}

<*
 What the terminal took is gone: not printed twice, and not left for an agent.

 Both halves matter and they fail differently. Draining without clearing turns a
 callback that logged one line into a loop printing it sixty times a second —
 the check below runs a *second* drain with nothing in between, which is exactly
 what the next iteration of the host loop does. Leaving it for a run as well
 would mean an attached agent reading a stopped-callback report it has already
 been given, on every call, forever.
*>
fn void what_a_terminal_took_is_not_reported_twice() @test
{
	@with_js(; three::JsRuntime* run, three::MeshPass* pass)
	{
		@ok(run, "three.setAnimationLoop(() => { console.log('once'); throw new Error('and out'); });");
		run.tick(0);

		DString said;
		said.init(mem, 128);
		defer said.free();
		run.take_frame_output(&said);
		test::@check(said.str_view().contains("once"), "the first drain has it: '%s'", said.str_view());

		said.clear();
		run.take_frame_output(&said);
		test::@check(said.len() == 0, "and the second has nothing: '%s'", said.str_view());

		three::RunResult result = run.run("return 1;");
		defer result.free();
		test::@check(!result.log.contains("once"), "and a run is not told again: '%s'", result.log);
		test::@check(result.frame_error.len == 0, "nor given the reason again: '%s'", result.frame_error);
	};
}

<*
 A boot from a command line counts a slow frame; a served one does not.

 The switch `play_frames` throws, asserted on the one thing that separates the
 two modes at a survivable cost — an endless callback separates them too, but
 only by sitting for the script's five seconds.

 Thirty milliseconds against an eight millisecond frame: nearly four times over,
 so no machine this runs on can make it a near miss in either direction.
*>
fn void a_boot_from_a_command_line_counts_a_slow_frame() @test
{
	String slow = `
		three.setAnimationLoop(() => {
			const until = Date.now() + 30;
			while (Date.now() < until) {}
		});
	`;

	@with_js(; three::JsRuntime* run, three::MeshPass* pass)
	{
		run.play_frames();
		@ok(run, slow);
		run.tick(0);

		test::@check(run.tick(16), "the callback is still registered after running long");

		three::RunResult result = run.run("return 1;");
		defer result.free();
		test::@check(result.frame_overruns == 2, "both frames counted, got %d", result.frame_overruns);
		test::@check(
			result.frame_error.contains("over the 8 ms a frame has"),
			"and the first one said so: '%s'", result.frame_error
		);
	};

	@with_js(; three::JsRuntime* run, three::MeshPass* pass)
	{
		@ok(run, slow);
		run.tick(0);
		run.tick(16);

		three::RunResult result = run.run("return 1;");
		defer result.free();
		test::@check(result.frame_overruns == 0, "a served run counts nothing, got %d", result.frame_overruns);
		test::@check(result.frame_error.len == 0, "and says nothing: '%s'", result.frame_error);
	};
}
