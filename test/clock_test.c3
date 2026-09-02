<*
 The game clock — `plan.md` §17, the second item in the order of work.

	`c3c test --trust=full --test-noleak --test-filter three_tests::clock`

 **No window and, for all but two of these, no device.** `JsRuntime.tick` takes
 the host's reading as an argument, so every check below is a statement about
 the conversion rather than about how fast the machine was — the same property
 `three_tests::frame` is built on, and the reason a clock is testable at all.

 **Assert on what moved, not on what the clock says.** A clock that reported a
 delta nothing consumed would pass a check that only read `three.clock.dt`, and
 the whole complaint this answers is that a script stopping its own arithmetic
 left a world running underneath it. So the pause checks read the callback's
 argument, the fixed loop's call count, a falling body and a post pass's pixels.
*>
module three_tests::clock;

import three;
import three_tests::device;
import vk;
import image;
import std::core::test;

<*
 A runtime over a scene with no device behind it, and the scene itself.

 `three_tests::frame`'s macro exactly. `JsRuntime.open` is what starts the clock
 on a `MeshPass` built by hand — see `GameClock.defaults` for why that is not
 left to the zero value.
*>
macro @with_js(; @body(three::JsRuntime* run))
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

	@body(&runtime);
}

macro @ok(three::JsRuntime* run, String source)
{
	three::RunResult result = run.run(source);
	defer result.free();
	test::@check(result.ok, "the setup script succeeded: %s", result.error);
}

macro String @answer(three::JsRuntime* run, String source)
{
	three::RunResult result = run.run(source);
	defer result.free();
	test::@check(result.ok, "the reading script succeeded: %s", result.error);
	return result.value.copy(mem);
}

// The sentence a script threw, or the empty string if it did not throw.
macro String @refusal(three::JsRuntime* run, String source)
{
	three::RunResult result = run.run(source);
	defer result.free();
	return result.ok ? "".copy(mem) : result.error.copy(mem);
}

// ============================================================================
// Wall time in, game time out
// ============================================================================

<*
 The first tick is worth nothing, however long the boot took.

 `elapsed_ms` is measured from process start, so the first reading carries window
 creation, device selection and the script's own load. A clock that took it would
 start every scene half a second into itself — and the symptom is a clip that has
 already played, which reads as an animation bug rather than as a clock one.
*>
fn void the_first_tick_is_worth_nothing() @test
{
	@with_js(; three::JsRuntime* run)
	{
		run.tick(1250.5);

		String dt = @answer(run, "return three.clock.dt;");
		defer dt.free(mem);
		test::@check(dt == "0", "the first frame was worth nothing, got '%s'", dt);

		String now = @answer(run, "return three.clock.time;");
		defer now.free(mem);
		test::@check(now == "0", "and the clock is still at zero, got '%s'", now);
	};
}

// A frame is worth the wall delta, and the time is what the frames add up to.
fn void a_frame_is_worth_the_delta_between_two_readings() @test
{
	@with_js(; three::JsRuntime* run)
	{
		run.tick(0);
		run.tick(20);

		String dt = @answer(run, "return Math.round(three.clock.dt * 1000);");
		defer dt.free(mem);
		test::@check(dt == "20", "twenty milliseconds of frame, got '%s'", dt);

		run.tick(40);
		String now = @answer(run, "return Math.round(three.clock.time * 1000);");
		defer now.free(mem);
		test::@check(now == "40", "two frames of it add up, got '%s'", now);
	};
}

<*
 A stall is clamped, and the clamp is on the wall delta rather than on the game
 one.

 A frame that took five seconds means the process was stopped — a breakpoint, a
 swap storm, a `run_script` that took its whole budget — and nothing should
 teleport through five seconds of itself for it.
*>
fn void a_stall_is_clamped_to_a_tenth_of_a_second() @test
{
	@with_js(; three::JsRuntime* run)
	{
		run.tick(0);
		run.tick(5000);

		String dt = @answer(run, "return Math.round(three.clock.dt * 1000);");
		defer dt.free(mem);
		test::@check(dt == "100", "the stall was clamped, got '%s' ms", dt);
	};
}

<*
 The scale multiplies the frame, and it multiplies what the clamp left.

 The order matters and is asserted here because getting it the other way round
 is invisible until somebody uses a scale: clamping *after* the scale would make
 `timeScale = 4` a slower game than `timeScale = 1` on any frame over 25 ms,
 which is the opposite of what was asked for.
*>
fn void the_time_scale_multiplies_the_frame() @test
{
	@with_js(; three::JsRuntime* run)
	{
		@ok(run, "three.clock.timeScale = 2;");
		run.tick(0);
		run.tick(20);

		String dt = @answer(run, "return Math.round(three.clock.dt * 1000);");
		defer dt.free(mem);
		test::@check(dt == "40", "double speed, got '%s' ms", dt);

		run.tick(5000);
		String stalled = @answer(run, "return Math.round(three.clock.dt * 1000);");
		defer stalled.free(mem);
		test::@check(stalled == "200", "and the clamp is on the wall delta, got '%s' ms", stalled);
	};
}

// Reading back what was written, with no window and no frames.
fn void the_scale_and_the_rate_read_back() @test
{
	@with_js(; three::JsRuntime* run)
	{
		@ok(run, "three.clock.timeScale = 0.25; three.clock.fixedRate = 30;");

		String scale = @answer(run, "return three.clock.timeScale;");
		defer scale.free(mem);
		test::@check(scale == "0.25", "the scale read back, got '%s'", scale);

		String rate = @answer(run, "return three.clock.fixedRate;");
		defer rate.free(mem);
		test::@check(rate == "30", "the rate read back, got '%s'", rate);

		String step = @answer(run, "return Math.round(three.clock.fixedDelta * 1000);");
		defer step.free(mem);
		test::@check(step == "33", "and the step follows the rate, got '%s' ms", step);
	};
}

<*
 A rewind is refused by name rather than clamped to zero.

 Three different wrong behaviours come out of one negative assignment — a clip
 sampled backwards, a solver that cannot run backwards at all, and a fixed
 accumulator sitting at a negative balance until enough forward time arrives to
 clear it. Refusing is the only version that says which one you would have got.
*>
fn void a_negative_scale_is_refused() @test
{
	@with_js(; three::JsRuntime* run)
	{
		String why = @refusal(run, "three.clock.timeScale = -1;");
		defer why.free(mem);
		test::@check(why.contains("zero or more"), "a rewind was refused: '%s'", why);

		String rate = @refusal(run, "three.clock.fixedRate = 0;");
		defer rate.free(mem);
		test::@check(rate.contains("steps a second"), "a zero rate was refused: '%s'", rate);

		String fast = @refusal(run, "three.clock.fixedRate = 100000;");
		defer fast.free(mem);
		test::@check(fast.contains("steps a second"), "an absurd rate was refused: '%s'", fast);
	};
}

// The two derived readings say so rather than accepting a write that does
// nothing — `api.js` throws on assignment for this reason three other times.
fn void the_derived_readings_refuse_assignment() @test
{
	@with_js(; three::JsRuntime* run)
	{
		String time = @refusal(run, "three.clock.time = 5;");
		defer time.free(mem);
		test::@check(time.contains("advance"), "time pointed at advance(): '%s'", time);

		String dt = @refusal(run, "three.clock.dt = 5;");
		defer dt.free(mem);
		test::@check(dt.contains("timeScale"), "dt pointed at the knob: '%s'", dt);

		String paused = @refusal(run, "three.clock.paused = true;");
		defer paused.free(mem);
		test::@check(paused.contains("timeScale = 0"), "paused pointed at the knob: '%s'", paused);
	};
}

// ============================================================================
// The pause, which is the whole feature
// ============================================================================

<*
 Zero is a pause, and the pause reaches the callback's own argument.

 The headline. Most of what moves in most of these scenes is a function of the
 number `setAnimationLoop` is handed — every example in `examples/` computes a
 phase or a delta from it — so a pause that stopped the clips and the solver and
 left that argument climbing would be a still world with the propellers still
 turning. It is the game clock now, which is why this check reads the callback
 rather than reading `three.clock.time`.
*>
fn void a_zero_scale_stops_the_argument_the_callback_is_told() @test
{
	@with_js(; three::JsRuntime* run)
	{
		@ok(run, "three.setAnimationLoop((ms) => { globalThis.seen = ms; globalThis.calls = (globalThis.calls || 0) + 1; });");

		run.tick(0);
		run.tick(20);
		@ok(run, "three.clock.timeScale = 0;");
		run.tick(40);
		run.tick(60);

		String seen = @answer(run, "return Math.round(globalThis.seen);");
		defer seen.free(mem);
		test::@check(seen == "20", "the clock stopped where the pause found it, got '%s'", seen);

		// And the loop is still running, which is the difference between a pause
		// and a stop: the window goes on drawing the frozen world.
		String calls = @answer(run, "return globalThis.calls;");
		defer calls.free(mem);
		test::@check(calls == "4", "the callback still ran every frame, got '%s'", calls);
	};
}

<*
 `advance` moves a stopped clock exactly once, and by exactly what was asked.

 What makes `timeScale = 0` a pause rather than a freezer, and what §2's
 screenshot-reproducibility entry was waiting for: with the scale at zero the
 only time that passes is time somebody asked for, so two runs asking for the
 same amount draw the same frame.
*>
fn void advance_moves_a_stopped_clock_once() @test
{
	@with_js(; three::JsRuntime* run)
	{
		@ok(run, "three.clock.timeScale = 0;");
		run.tick(0);
		run.tick(20);

		@ok(run, "three.clock.advance(0.5);");
		run.tick(40);

		String stepped = @answer(run, "return Math.round(three.clock.dt * 1000);");
		defer stepped.free(mem);
		test::@check(stepped == "500", "the step was worth what was asked, got '%s' ms", stepped);

		run.tick(60);
		String after = @answer(run, "return Math.round(three.clock.dt * 1000);");
		defer after.free(mem);
		test::@check(after == "0", "and only once — the next frame was worth '%s' ms", after);

		String now = @answer(run, "return Math.round(three.clock.time * 1000);");
		defer now.free(mem);
		test::@check(now == "500", "the clock kept it, got '%s' ms", now);
	};
}

// The debt is not multiplied by the scale, which is the only reading of
// `advance` that is any use while paused — the interesting case is exactly the
// one where the scale is zero.
fn void a_step_is_not_scaled() @test
{
	@with_js(; three::JsRuntime* run)
	{
		@ok(run, "three.clock.timeScale = 4; three.clock.advance(0.5);");
		run.tick(0);

		String dt = @answer(run, "return Math.round(three.clock.dt * 1000);");
		defer dt.free(mem);
		test::@check(dt == "500", "the step was itself and not four of itself, got '%s' ms", dt);
	};
}

// ============================================================================
// The fixed loop
// ============================================================================

<*
 The fixed loop runs the steps the clock owes, at its own rate, whatever the
 frame did.

 Ninety milliseconds of game time at 60 Hz is five steps, and it is five whether
 that arrived as one long frame or as five short ones — which is the whole of
 what a fixed step is for.

 Ninety rather than a hundred for two reasons that both matter: a hundred is at
 `CLOCK_MAX_STEP_MS`, where a frame stops being worth what the wall said, and it
 is also exactly six steps to the last bit of a double and five of them once
 `1000 / 60` has been rounded. Either would make this a check about something
 other than the accumulator.
*>
fn void the_fixed_loop_runs_what_the_clock_owes() @test
{
	@with_js(; three::JsRuntime* run)
	{
		@ok(run, "globalThis.steps = 0; three.setFixedLoop((dt) => { globalThis.steps++; globalThis.step = dt; });");

		run.tick(0);
		run.tick(90);

		String steps = @answer(run, "return globalThis.steps;");
		defer steps.free(mem);
		test::@check(steps == "5", "ninety milliseconds is five steps of a sixtieth, got '%s'", steps);

		String step = @answer(run, "return Math.round(globalThis.step * 10000);");
		defer step.free(mem);
		test::@check(step == "167", "and the step it was handed is a sixtieth, got '%s' (x1e-4 s)", step);
	};
}

<*
 The same number of steps arrives however the frames were cut.

 The claim in one comparison: five frames of eighteen milliseconds and one frame
 of ninety owe the same five steps, which is the property an integration written
 against a variable `dt` cannot have.
*>
fn void the_step_count_does_not_depend_on_the_frame_rate() @test
{
	@with_js(; three::JsRuntime* run)
	{
		@ok(run, "globalThis.steps = 0; three.setFixedLoop(() => { globalThis.steps++; });");

		run.tick(0);
		for (int i = 1; i <= 5; i++) run.tick((double)i * 18.0);

		String steps = @answer(run, "return globalThis.steps;");
		defer steps.free(mem);
		test::@check(steps == "5", "five short frames owe the same five steps, got '%s'", steps);
	};
}

<*
 A rate a script chose is the rate it gets.

 The same ninety milliseconds that owed five steps at sixty hertz owes two at
 thirty, and the step handed to the callback is a thirtieth rather than a
 sixtieth — the two have to move together or a script that lowered its rate
 would silently run at half speed.
*>
fn void the_rate_is_the_script_s() @test
{
	@with_js(; three::JsRuntime* run)
	{
		@ok(run, "three.clock.fixedRate = 30; globalThis.steps = 0; three.setFixedLoop((dt) => { globalThis.steps++; globalThis.step = dt; });");

		run.tick(0);
		run.tick(90);

		String steps = @answer(run, "return globalThis.steps;");
		defer steps.free(mem);
		test::@check(steps == "2", "thirty hertz is two steps in ninety milliseconds, got '%s'", steps);

		String step = @answer(run, "return Math.round(globalThis.step * 1000);");
		defer step.free(mem);
		test::@check(step == "33", "and the step is a thirtieth, got '%s' ms", step);
	};
}

<*
 Nothing is banked while no fixed loop is registered.

 An accumulator left filling would fire a frame's worth of catch-up the moment
 something was registered — a game whose first gameplay step is eight steps long,
 for no reason a script could see. The steps are taken every frame and spent only
 if there is somewhere to spend them.

 **Proved by injection.** `take_fixed_steps` called only while `fixed_active`:
 "one frame's worth and not ten, got '8' steps" — the cap, which is the shape
 this failure has whatever the banked amount was.
*>
fn void no_time_is_banked_while_nothing_is_registered() @test
{
	@with_js(; three::JsRuntime* run)
	{
		run.tick(0);
		for (int i = 1; i <= 10; i++) run.tick((double)i * 20.0);

		@ok(run, "globalThis.steps = 0; three.setFixedLoop(() => { globalThis.steps++; });");
		run.tick(220);

		String steps = @answer(run, "return globalThis.steps;");
		defer steps.free(mem);
		long count = steps.to_long() ?? 99;
		test::@check(count <= 2, "one frame's worth and not ten, got '%s' steps", steps);
	};
}

// A frame that ran very long catches up at most `CLOCK_MAX_FIXED_STEPS` and
// drops the rest, which is the difference between a stutter and a spiral.
fn void a_very_long_frame_catches_up_and_stops() @test
{
	@with_js(; three::JsRuntime* run)
	{
		@ok(run, "globalThis.steps = 0; three.setFixedLoop(() => { globalThis.steps++; });");

		run.tick(0);
		// Ten seconds of wall clock, clamped to a hundred milliseconds of game
		// time by the clock and then to eight steps by the accumulator — the two
		// caps in one frame.
		@ok(run, "three.clock.timeScale = 10;");
		run.tick(10000);

		String steps = @answer(run, "return globalThis.steps;");
		defer steps.free(mem);
		test::@check(steps == "8", "capped at eight steps, got '%s'", steps);

		// And the remainder is dropped rather than carried, so the next frame is
		// an ordinary one instead of the second instalment of a spiral.
		@ok(run, "three.clock.timeScale = 1; globalThis.steps = 0;");
		run.tick(10020);
		String next = @answer(run, "return globalThis.steps;");
		defer next.free(mem);
		test::@check(next == "1", "the next frame was ordinary, got '%s' steps", next);
	};
}

// A paused clock owes nothing, for the same reason it moves nothing else.
fn void a_paused_clock_owes_no_fixed_steps() @test
{
	@with_js(; three::JsRuntime* run)
	{
		@ok(run, "globalThis.steps = 0; three.setFixedLoop(() => { globalThis.steps++; });");
		@ok(run, "three.clock.timeScale = 0;");

		run.tick(0);
		for (int i = 1; i <= 10; i++) run.tick((double)i * 20.0);

		String steps = @answer(run, "return globalThis.steps;");
		defer steps.free(mem);
		test::@check(steps == "0", "a stopped clock owes nothing, got '%s' steps", steps);
	};
}

<*
 A fixed loop is a reason to keep drawing.

 The same term `is_animating` carries for the animation callback and for a
 playing clip, and it is the host's "may this window go to sleep" condition —
 a game simulating with no `setAnimationLoop` at all would otherwise stop
 getting frames, and the symptom is a simulation that runs only while the mouse
 is moving.
*>
fn void a_fixed_loop_keeps_the_window_awake() @test
{
	@with_js(; three::JsRuntime* run)
	{
		test::@check(!run.is_animating(), "nothing registered, nothing to do");
		@ok(run, "three.setFixedLoop(() => {});");
		test::@check(run.is_animating(), "a fixed loop is work every frame");
		@ok(run, "three.setFixedLoop(null);");
		test::@check(!run.is_animating(), "and null stops it");
	};
}

// The three ways a callback stops are the frame callback's three, said about
// this one — and the reason is kept for the next run to read, as that one's is.
fn void a_throwing_fixed_loop_is_stopped_and_says_which_loop_it_was() @test
{
	@with_js(; three::JsRuntime* run)
	{
		@ok(run, "globalThis.steps = 0; three.setFixedLoop(() => { globalThis.steps++; throw new Error('no'); });");

		run.tick(0);
		run.tick(90);

		three::RunResult after = run.run("return globalThis.steps;");
		defer after.free();
		test::@check(after.ok, "the reading script ran: %s", after.error);
		test::@check(after.value == "1", "it stopped on the first bad step, got '%s'", after.value);
		test::@check(
			after.frame_error.contains("the fixed loop threw"),
			"the reason names the loop it was: '%s'", after.frame_error
		);

		// Stopped for good, rather than retried sixty times a second.
		run.tick(200);
		String steps = @answer(run, "return globalThis.steps;");
		defer steps.free(mem);
		test::@check(steps == "1", "and it was not called again, got '%s'", steps);
	};
}

// ============================================================================
// What the clock reaches, with a device behind it
// ============================================================================

<*
 A paused world does not fall.

 `plan.md` §17 in one sentence: "nothing can pause today". The solver's
 accumulator is fed the game delta rather than the host's, so a zero scale is a
 world that stops — with no flag anywhere in `scene/physics.c3` testing for it.

 **Proved by injection.** `Physics.step` fed the host's `elapsed_ms` rather than
 the clock's delta: "two seconds of paused frames left it at 6, got
 '-338.0013427734375'" — the accumulator taking the whole elapsed reading every
 frame, which is what a pause that only stopped the *script* would look like.
 Restored, green again.
*>
fn void a_paused_world_does_not_fall() @test
{
	three::Renderer* renderer = device::borrow(200, 150);
	defer device::release();

	three::JsRuntime run;
	run.open(&renderer.pass, renderer)!!;
	defer run.close();

	three::RunResult built = run.run(`
		const scene = new three.Scene();
		const ball = new three.Mesh(new three.SphereGeometry(0.5, 16, 8));
		ball.position.set(0, 6, 0);
		scene.add(ball);
		three.physics.add(ball, { shape: 'sphere', mass: 1 });
		globalThis.ball = ball;
		three.clock.timeScale = 0;
		return three.physics.count;
	`);
	defer built.free();
	test::@check(built.ok, "the scene built: %s", built.error);

	for (int i = 1; i <= 120; i++) run.tick((double)i * (1000.0 / 60.0));

	three::RunResult held = run.run("return globalThis.ball.position.y;");
	defer held.free();
	test::@check(held.ok, "read the ball back: %s", held.error);
	test::@check(held.value == "6", "two seconds of paused frames left it at 6, got '%s'", held.value);

	// And unpausing is all it takes — the same frames, moving now.
	three::RunResult resumed = run.run("three.clock.timeScale = 1; return 0;");
	defer resumed.free();
	test::@check(resumed.ok, "resumed: %s", resumed.error);

	for (int i = 121; i <= 240; i++) run.tick((double)i * (1000.0 / 60.0));

	three::RunResult fell = run.run("return globalThis.ball.position.y;");
	defer fell.free();
	test::@check(fell.ok, "read the ball back: %s", fell.error);
	double y = fell.value.to_double() ?? 999.0;
	test::@check(y < 0.0, "and then it fell, y = %s", fell.value);
}

<*
 `p.time` is the game clock, which is what makes a post pass reproducible.

 It was seconds since the shader was compiled, off a wall clock, and `plan.md`
 §2 deferred fixing it until there was a clock to read — so a screenshot with a
 post pass active could not be taken twice and a paused scene kept animating.
 Now the only thing that moves it is the clock moving.

 Driven through `GameClock` directly rather than through a tick, because this is
 the renderer's half: no runtime is involved in recording a frame, and the point
 of the check is that the chain reads the clock on `MeshPass` rather than a
 second one of its own.

 **Proved by injection.** `info.z` put back on a wall clock: "the clock reached
 the frame: 0.000000 then 0.000000" — a `p.time` fed by anything other than the
 clock does not move when the clock does.

 **The half of this that is weaker than it looks**, said here rather than
 discovered later: the two captures being *equal* is a statement about the clock
 not moving on its own, and the wall clock it replaced would have passed it too,
 because two captures are microseconds apart and a microsecond of `p.time` does
 not survive being rounded to a byte. It is the *advance* that carries this
 check. What the equality does catch is the class of mistake that would put a
 reading of the host's clock back into `record` — anything per-frame rather than
 per-second — and it costs one capture to have.
*>
fn void the_post_clock_is_the_game_clock() @test
{
	three::Renderer* renderer = device::borrow(64, 64);
	defer device::release();

	// The whole frame is `p.time`, so the picture *is* the reading.
	renderer.post.set(
		&renderer.gpu,
		&renderer.target,
		`float3 post(Post p) { return float3(p.time, p.time, p.time); }`,
		{}
	)!!;

	image::Image first = renderer.capture()!!;
	defer first.free();
	float dark = mean_red(&first);
	test::@check(dark < 4.0, "a stage set before the first frame starts at zero, got %f", dark);

	// A frame with no clock movement is the same frame. This is the one that
	// closes §2's screenshot-reproducibility entry.
	image::Image again = renderer.capture()!!;
	defer again.free();
	test::@check(
		mean_red(&again) == dark,
		"a second capture with a still clock differed: %f vs %f", dark, mean_red(&again)
	);

	// Half a second of game time, and only what the clock was given.
	renderer.pass.clock.advance(0.5);
	renderer.pass.clock.advance_frame(0);
	image::Image later = renderer.capture()!!;
	defer later.free();
	float lit = mean_red(&later);
	test::@check(lit > dark + 40.0, "the clock reached the frame: %f then %f", dark, lit);
}

// The mean red channel of a whole image. The post body writes one value into
// every pixel, so the mean is the value.
fn float mean_red(image::Image* img)
{
	sz bpp = img.bytes_per_pixel();
	double total = 0;
	sz count = (sz)img.width * (sz)img.height;
	for (sz i = 0; i < count; i++) total += (double)img.pixels[i * bpp];
	return count == 0 ? 0 : (float)(total / (double)count);
}
