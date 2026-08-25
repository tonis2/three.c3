<*
 `three.cooldown(duration, options)` — `notes.md` §17 / §21, `src/js/prelude/cooldown.js`.

	`c3c test --trust=full --test-noleak --test-filter three_tests::cooldown`

 **The one real design question this file has to settle is not in this file —
 it is in `cooldown.js`'s own header.** `three.clock.time` advances ONCE per
 `JsRuntime.tick`, before the fixed loop decides how many times it runs this
 frame, so a Cooldown that read the clock back would see the same reading
 through every fixed step of a catch-up tick. `a_sub_step_cooldown_ends_inside_
 one_catch_up_tick` below is the test that would have failed against that
 design and passes against the one that shipped: a cooldown shorter than one
 fixed step still ends BETWEEN two fixed steps of the SAME `run.tick()` call,
 because it is ticked with each step's own `dt` rather than read off a clock
 that only moved once for all of them.

 Otherwise this is an ordinary state-machine file: what `start()`, `cancel()`
 and the four booleans answer at a few points in time, driven the way
 `test/systems_test.c3` drives a system — a hand-fed clock and a script that
 leaves a global for the next one to read.
*>
module three_tests::cooldown;

import three;
import vk;
import qjs;
import std::core::test;
import std::io;

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

macro String @value(three::JsRuntime* run, String source, String what)
{
	three::RunResult result = run.run(source);
	defer result.free();
	test::@check(result.ok, "%s: %s", what, result.error);
	return result.value.copy(tmem);
}

// Run once to succeed and discard the value — the setup half of a script
// split across `@after_frames`'s source/read pair, and for a script with
// nothing worth reading back at all.
macro @ok(three::JsRuntime* run, String source)
{
	three::RunResult result = run.run(source);
	defer result.free();
	test::@check(result.ok, "the setup script succeeded: %s", result.error);
}

// The sentence a script threw, or the empty string if it did not throw.
macro String @refusal(three::JsRuntime* run, String source)
{
	three::RunResult result = run.run(source);
	defer result.free();
	return result.ok ? "".copy(tmem) : result.error.copy(tmem);
}

// Run `frames` ticks with a hand-fed clock, then read a global the script left.
macro String @after_frames(three::JsRuntime* run, String source, int frames, String read, String what)
{
	@value(run, source, what);
	double at = 0;
	for (int i = 0; i < frames; i++)
	{
		at += 16.0;
		run.tick(at);
	}
	return @value(run, read, "the reading script ran");
}

// ============================================================================
// The state machine
// ============================================================================

<*
 Before the first `start()`, a cooldown is ready rather than active — the
 answer `started` exists to give without reaching for `elapsed === Infinity`,
 which every consumer of `elapsed` would otherwise have to special-case.
*>
fn void a_fresh_cooldown_is_not_active_and_is_ready() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @value(run, `
			const c = three.cooldown(0.5);
			return [c.active, c.ready, c.recovering, c.started, c.remaining, c.progress];
		`, "the fresh script ran");

		test::@check(value == "[false,true,false,false,0,0]",
			"nothing has happened yet; got %s", value);
	};
}

// `start()` answers whether it took, and with nothing else in the way it
// always does the first time.
fn void starting_it_makes_it_active_and_not_ready() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @value(run, `
			const c = three.cooldown(0.5);
			const started = c.start();
			return [started, c.active, c.started, c.ready];
		`, "the start script ran");

		test::@check(value == "[true,true,true,false]",
			"start() took and active follows; got %s", value);
	};
}

<*
 `ready` is false for the whole of `active`, false again for the whole of
 `recovering`, and true only past both — the three-way split `recover` exists
 to add on top of the two Three.js has no equivalent of at all.

 Driven with a `'frame'`-phase cooldown so the elapsed time is an exact
 multiple of the sixteen-millisecond frame this file feeds the clock, rather
 than whatever the fixed-step accumulator's carry happened to leave.
*>
fn void ready_is_false_through_active_and_recovery_then_true() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @after_frames(run, `
			globalThis.snapshots = [];
			let frame = 0;
			const c = three.cooldown(0.2, { recover: 0.1, phase: 'frame' });
			c.start();
			// duration 0.2s, recover 0.1s: frame 1 is t=0 (active), frame 16
			// is t=0.24s (in the recover window), frame 22 is t=0.336s (past
			// it). Fifteen frame boundaries of ~16 ms apiece between 1 and
			// 16, twenty-one between 1 and 22 — see the header's note on why
			// the first tick is worth nothing.
			three.systems.add('watch', () => {
				frame++;
				if (frame === 1 || frame === 16 || frame === 22) {
					snapshots.push([c.active, c.recovering, c.ready]);
				}
			}, { phase: 'frame', order: 100 });
		`, 25, `
			return snapshots;
		`, "the recovery script ran");

		test::@check(value == "[[true,false,false],[false,true,false],[false,false,true]]",
			"active, then recovering, then ready; got %s", value);
	};
}

<*
 A `start()` while already active is refused and changes nothing — the
 `remaining` a HUD is reading does not jump back up because something else in
 the level tried to start the same cooldown twice.
*>
fn void starting_it_again_while_active_does_not_extend_it() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @after_frames(run, `
			globalThis.c = three.cooldown(0.5, { phase: 'frame' });
			c.start();
		`, 10, `
			const before = c.elapsed;
			const startedAgain = c.start();
			return [startedAgain, c.elapsed === before, c.active];
		`, "the no-extend script ran");

		test::@check(value == "[false,true,true]",
			"a refused start leaves elapsed exactly where it was; got %s", value);
	};
}

<*
 `{ restart: true }` is the one call that starts a cooldown even while it is
 active or recovering — coyote time re-armed on every grounded frame, or a
 buff refreshed by picking up a second one of it.
*>
fn void restart_extends_it_even_while_active() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @after_frames(run, `
			globalThis.c = three.cooldown(0.5, { phase: 'frame' });
			c.start();
		`, 10, `
			const restarted = c.start({ restart: true });
			return [restarted, c.elapsed === 0, c.active, c.remaining === c.duration];
		`, "the restart script ran");

		test::@check(value == "[true,true,true,true]",
			"restart takes even mid-active and starts the window over; got %s", value);
	};
}

<*
 `cancel()` is "the spin was interrupted", not "the spin finished early" —
 recovery is skipped rather than begun, so the next `start()` is refused by
 nothing.
*>
fn void cancel_makes_it_ready_at_once() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @value(run, `
			const c = three.cooldown(0.5, { recover: 0.3 });
			c.start();
			c.cancel();
			return [c.active, c.recovering, c.ready, c.remaining];
		`, "the cancel script ran");

		test::@check(value == "[false,false,true,0]",
			"cancelling skips recovery entirely; got %s", value);
	};
}

<*
 `remaining` and `progress` against an independently-summed `dt`, not against
 the cooldown's own arithmetic read back at itself — a second system adds up
 the same `dt` the cooldown's own tick sees, from the same clock, and the two
 totals are asserted equal rather than merely plausible.
*>
fn void remaining_and_progress_agree_with_an_independently_summed_dt() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @after_frames(run, `
			globalThis.total = 0;
			// Reads three.clock.dt directly rather than trusting its own
			// argument — see cooldown.js's header on why a 'frame'-phase
			// system's dt argument is not a delta.
			three.systems.add('sum', () => { total += three.clock.dt; }, { phase: 'frame', order: 100 });
			globalThis.c = three.cooldown(1.0, { phase: 'frame' });
			c.start();
		`, 20, `
			return [
				c.elapsed === total,
				c.remaining === (1.0 - total),
				c.progress === total,
				total > 0.1 && total < 0.9,
			];
		`, "the summed-dt script ran");

		test::@check(value == "[true,true,true,true]",
			"the cooldown's own count agrees with an outside one; got %s", value);
	};
}

<*
 `duration` and `recover` are ordinary writable properties — a game upgrading
 the player's spin — and there is no stored end time to go stale when they
 change: every getter is a function of `elapsed` against them, read fresh.
*>
fn void duration_is_writable_mid_run_and_takes_effect_immediately() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @after_frames(run, `
			globalThis.c = three.cooldown(1.0, { recover: 0.5, phase: 'frame' });
			c.start();
		`, 20, `
			// About 0.3s in and still active against the original 1.0s
			// duration. Shortening it below the elapsed time should be seen
			// at once, with no additional call to start() needed.
			c.duration = 0.2;
			return [c.active, c.recovering, c.ready, c.remaining];
		`, "the retune script ran");

		test::@check(value == "[false,true,false,0]",
			"a shortened duration is read fresh, not cached at start(); got %s", value);
	};
}

// ============================================================================
// The clock
// ============================================================================

<*
 A paused game clock freezes a cooldown of either phase, for the same reason
 it freezes everything else on `three.clock` — see `cooldown.js`'s header for
 which host fact makes each phase true (a `'fixed'` cooldown's system simply
 does not run; a `'frame'` one runs but is handed `dt = 0`).
*>
fn void a_paused_game_clock_freezes_every_phase() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @after_frames(run, `
			globalThis.f = three.cooldown(0.05, { phase: 'fixed' });
			globalThis.g = three.cooldown(0.05, { phase: 'frame' });
			f.start();
			g.start();
			three.clock.timeScale = 0;
		`, 20, `
			return [f.active, f.remaining === 0.05, g.active, g.remaining === 0.05];
		`, "the paused script ran");

		test::@check(value == "[true,true,true,true]",
			"a paused clock spends no cooldown's time, on either phase; got %s", value);
	};
}

<*
 The test the clock-based design would have failed. Ninety milliseconds owed
 in one `run.tick()` call is five fixed steps of a sixtieth each
 (`the_fixed_loop_runs_what_the_clock_owes`, `test/clock_test.c3`) — all of
 them inside the one tick that has exactly one `three.clock.time` reading. A
 0.03s cooldown started before that tick is still active after the first of
 the five steps (16.667 ms in) and has ended by the second (33.3 ms in),
 which only a design ticked by each step's own `dt` can tell apart.
*>
fn void a_sub_step_cooldown_ends_inside_one_catch_up_tick() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		run.tick(0);

		@ok(run, `
			globalThis.states = [];
			globalThis.c = three.cooldown(0.03);
			c.start();
			three.systems.add('watch', () => states.push(c.active), { phase: 'fixed', order: 1 });
		`);

		run.tick(90);

		String value = @value(run, "return states;", "the catch-up script ran");

		test::@check(value == "[true,false,false,false,false]",
			"active through the first step and ended by the second; got %s", value);
	};
}

// ============================================================================
// Refusals
// ============================================================================

<*
 Zero, negative, `NaN` and a non-numeric string all fail the same check and
 all name the same call — the point being that whichever one an agent typed,
 it is told what it typed into.
*>
fn void an_invalid_duration_is_refused() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String zero = @refusal(run, "three.cooldown(0);");
		test::@check(zero.contains("three.cooldown(duration, options)"), "zero named the call: '%s'", zero);

		String negative = @refusal(run, "three.cooldown(-1);");
		test::@check(negative.contains("three.cooldown(duration, options)"), "negative named the call: '%s'", negative);

		String nan = @refusal(run, "three.cooldown(NaN);");
		test::@check(nan.contains("three.cooldown(duration, options)"), "NaN named the call: '%s'", nan);

		String str = @refusal(run, "three.cooldown('soon');");
		test::@check(str.contains("three.cooldown(duration, options)"), "a non-numeric string named the call: '%s'", str);
	};
}

// A typo in an option key is a thrown sentence naming both the typo and what
// the call actually takes — `three.assemble`'s `PART_KEYS` refusal, reused.
fn void an_unknown_option_key_is_refused() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String typo = @refusal(run, "three.cooldown(0.5, { recovr: 0.1 });");
		test::@check(typo.contains("recovr") && typo.contains("recover"),
			"the typo and the real option are both in the message: '%s'", typo);
	};
}

// `phase` is a recognised key with only two valid values, checked the same
// way `three.systems.add`'s own `phase` option is.
fn void an_invalid_phase_is_refused() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String phase = @refusal(run, "three.cooldown(0.5, { phase: 'never' });");
		test::@check(phase.contains("'fixed' or 'frame'"), "an unknown phase is refused: '%s'", phase);
	};
}
