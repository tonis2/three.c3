<*
 The ordered system registry and the cast — `notes.md` §21.

	`c3c test --trust=full --test-noleak --test-filter three_tests::systems`

 **Both of these are JavaScript, and that is exactly why they need checking
 here.** §21 makes no claim about speed — every data layout it could have chosen
 measured inside the noise floor — so what it has to be is CORRECT in the two
 places a script cannot see it going wrong: the order systems run in, and
 whether an index still means the entity it meant a line ago.

 An out-of-order frame does not throw. A stale index does not throw either; it
 damages the wrong critter, which reads as a gameplay bug in whatever ran next.

 The one host-side addition, `three.clock.wall`, is checked against the thing it
 exists to be different from: it has to keep running while the game clock is
 stopped, and a test is the only place that difference is visible without
 pausing a game and watching.
*>
module three_tests::systems;

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

macro String @value(three::JsRuntime* run, String source, String what)
{
	three::RunResult result = run.run(source);
	defer result.free();
	test::@check(result.ok, "%s: %s", what, result.error);
	return result.value.copy(tmem);
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
// The registry
// ============================================================================

<*
 The running order, which is the whole feature.

 Lower `order` first, equal orders in the order they were added — the rule that
 makes a file read top to bottom. Nothing about a wrong order throws: a frame in
 which the camera ran before the character moved looks like the character
 sliding, and the bug gets filed against the physics.

 The fixed phase running before the frame phase is `frame_loop.c3`'s and is
 asserted here because the registry now sits on both and could silently invert
 it.
*>
fn void systems_run_in_the_order_they_declare() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @after_frames(run, `
			globalThis.seen = [];
			three.systems.add('third', () => seen.push('third'), { order: 2 });
			three.systems.add('first', () => seen.push('first'), { order: 1 });
			three.systems.add('second', () => seen.push('second'), { order: 1 });
			three.systems.add('early', () => seen.push('early'), { order: -1 });
			three.systems.add('off', () => seen.push('off'), { enabled: false });
			three.systems.add('step', () => seen.push('step'), { phase: 'fixed' });
			three.setAnimationLoop(() => seen.push('anim'));
			globalThis.mark = () => seen.push('|');
			three.systems.add('mark', () => mark(), { order: 1e9 });
		`, 6, `
			// The last complete frame: everything after the last but one bar.
			const bars = seen.map((s, i) => s === '|' ? i : -1).filter(i => i >= 0);
			const frame = seen.slice(bars[bars.length - 2] + 1, bars[bars.length - 1] + 1);
			return frame.join(',');
		`, "the ordering script ran");

		// A fixed step first, then -1, then 0 (the animation callback, which is
		// a system under a reserved name), then 1 in insertion order, then 2.
		test::@check(value == "\"step,early,anim,first,second,third,|\"",
			"the declared order is the running order; got %s", value);
	};
}

<*
 The two argument conventions, which differ on purpose.

 The animation callback keeps Three.js's milliseconds because it keeps Three.js's
 name; a system is not a Three.js concept and is handed seconds, which is what
 `three.damp`, `three.clock.fixedDelta` and every integration in `examples/`
 already use. Getting this wrong is a factor of a thousand in whatever the
 system integrates, which does not throw — it just makes everything leave the
 level on the first frame.
*>
fn void a_system_gets_seconds_and_the_animation_callback_gets_milliseconds() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @after_frames(run, `
			globalThis.saw = { frame: -1, fixed: -1, anim: -1 };
			three.systems.add('frame', dt => { saw.frame = dt; });
			three.systems.add('step', dt => { saw.fixed = dt; }, { phase: 'fixed' });
			three.setAnimationLoop(ms => { saw.anim = ms; });
		`, 8, `
			return [
				Math.abs(saw.frame - three.clock.dt) < 1e-9,
				Math.abs(saw.fixed - three.clock.fixedDelta) < 1e-9,
				Math.abs(saw.anim - three.clock.time * 1000) < 1e-6,
				saw.frame * 1000 * 4 < saw.anim,
			];
		`, "the units script ran");

		// A frame system's dt is THIS frame's seconds — three.clock.dt — a
		// fixed one's is the step exactly, and the animation callback's is
		// Three.js's argument: the milliseconds since the clock started. The
		// fourth check is the one that matters: after eight frames the
		// callback's number is many times the system's, because one is a
		// total and the other is a delta. The first version of this test
		// asserted `anim ≈ frame * 1000` — that the two AGREED — and a registry
		// handing systems the cumulative time passed it for a whole section.
		test::@check(value == "[true,true,true,true]",
			"a delta for a system and a total for the callback; got %s", value);
	};
}

<*
 A throwing system must not take the others down with it.

 **This is most of why the split is worth having.** With one callback, a throw
 in the fruit code stops the camera, and what gets reported is that the camera
 broke. It must not be swallowed either — the message names the system, and the
 count keeps rising in `report()` after the log has gone quiet.
*>
fn void a_system_that_throws_does_not_stop_the_others() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @after_frames(run, `
			globalThis.after = 0;
			three.systems.add('bad', () => { throw new Error('on purpose'); }, { order: 0 });
			three.systems.add('good', () => { after++; }, { order: 1 });
		`, 5, `
			const bad = three.systems.report().find(s => s.name === 'bad');
			return [after, bad.errors, three.systems.list().find(s => s.name === 'bad').enabled];
		`, "the throwing script ran");

		// Five frames, the good one ran all five, all five throws counted, and
		// nothing was disabled behind the script's back.
		test::@check(value == "[5,5,true]",
			"a throw is contained, counted, and does not disable; got %s", value);
	};
}

<*
 `three.clock.wall` against the clock it exists to differ from.

 Every other reading on `three.clock` is game time: scaled by `timeScale` and
 stopped by a pause, which is what makes `x += speed * dt` need no `if`. A
 profiler built on that reads zero while paused and four times the truth in slow
 motion — the measurement would be a function of the settings of the thing being
 measured.
*>
fn void the_wall_clock_runs_while_the_game_clock_is_stopped() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @after_frames(run, `
			globalThis.marks = [];
			three.systems.add('watch', () => marks.push([three.clock.wall, three.clock.time]));
			three.clock.timeScale = 0;
		`, 6, `
			// A little arithmetic so there is real time to measure between the
			// first reading and the last, whatever the host was doing.
			let spin = 0;
			for (let i = 0; i < 400000; i++) spin += i;
			const first = marks[0], last = marks[marks.length - 1];
			return [
				marks.length >= 5,
				last[0] > first[0],
				last[1] === first[1],
				three.clock.wall >= last[0],
			];
		`, "the wall clock script ran");

		// Frames ran, the wall clock moved across them, the game clock did not
		// move at all, and a reading taken after them is not behind.
		test::@check(value == "[true,true,true,true]",
			"the wall clock is not the game clock; got %s", value);
	};
}

<*
 Registering a name that exists replaces it.

 A re-run top level — a hot reload, a script evaluated twice — should end up
 with one copy of each system rather than two, and a name is the only identity a
 re-evaluated closure keeps. The reading in `report()` survives the replace on
 purpose: swapping a system's body while watching what it costs is the case.
*>
fn void adding_a_name_twice_replaces_it() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @value(run, `
			let a = 0, b = 0;
			three.systems.add('one', () => a++);
			three.systems.add('one', () => b++);
			three.setAnimationLoop(() => {});
			three.setAnimationLoop(() => {});
			const names = three.systems.list().map(s => s.name);
			const before = three.systems.length;
			three.setAnimationLoop(null);
			return [names.length, names.filter(n => n === 'one').length,
				names.filter(n => n === 'animation').length, before - three.systems.length];
		`, "the replace script ran");

		// Two systems, one of each name, and setAnimationLoop(null) takes its
		// own back out.
		test::@check(value == "[2,1,1,1]",
			"one name is one system; got %s", value);
	};
}

// ============================================================================
// The cast
// ============================================================================

<*
 The two failure contracts, side by side, because the difference is a decision.

 `frame_loop.c3` stops a callback the moment it misbehaves and keeps the reason
 — a rule that predates the registry and belongs to `setAnimationLoop`. A
 system's throw is contained instead, because with one callback a throw in the
 fruit code stops the camera and the report reads as "the camera broke".

 Both live in one registry now, so the difference has to be the one a caller
 chooses by which door they came in, and it has to be visible from inside a
 single run. `test/frame_test.c3` owns the callback half against the host; this
 owns the fact that a system beside it is NOT treated the same way.
*>
fn void a_system_is_contained_where_the_animation_callback_is_stopped() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @after_frames(run, `
			globalThis.counts = { system: 0, callback: 0 };
			three.systems.add('bad', () => { counts.system++; throw new Error('contained'); }, { order: 0 });
			three.systems.add('good', () => { counts.system += 100; }, { order: 1 });
		`, 4, `
			const bad = three.systems.report().find(s => s.name === 'bad');
			return [counts.system, bad.errors, three.systems.list().length];
		`, "the contained script ran");

		// Four frames: the bad one threw four times, the good one ran four
		// times regardless, and neither left the list.
		test::@check(value == "[404,4,2]",
			"a system's throw is contained and counted; got %s", value);

		@value(run, `
			globalThis.after = 0;
			three.setAnimationLoop(() => { throw new Error('the wheels came off'); });
			three.systems.add('later', () => { after++; }, { order: 100 });
		`, "the stopped script ran");
		double at = 0;
		for (int i = 0; i < 4; i++) { at += 16.0; run.tick(at); }

		// The reason reaches exactly ONE run — `test/frame_test.c3` owns that
		// rule — so the reading and the reporting have to be the same run.
		three::RunResult result = run.run("return [after, three.systems.list().length];");
		defer result.free();
		test::@check(result.ok, "the reading script ran: %s", result.error);

		// The callback threw on the first frame and the host took the frame
		// slot away for good, so the system ordered after it never ran again —
		// the old contract, unchanged, reaching everything downstream of it.
		test::@check(result.value == "[0,4]",
			"the animation callback keeps the host's contract; got %s", result.value);
		test::@check(!result.frame_running, "and the loop is reported as stopped");
		test::@check(
			result.frame_error.contains("the wheels came off"),
			"with the callback's own message: '%s'", result.frame_error
		);
	};
}

// ============================================================================
// The verb, and the neighbours
// ============================================================================

<*
 The phase is said in the verb, and saying it twice is refused.

 `{ phase: 'fixed' }` was a string in an options bag that a reader had to know
 the two legal values of before the line meant anything, and `step`/`frame` is
 the same decision with the answer in the word. The refusal matters more than it
 looks: `three.systems.step(name, fn, { phase: 'frame' })` under a silent
 override runs on a clock the person who wrote it did not choose, and nothing
 about a system on the wrong clock announces itself — it drifts.
*>
fn void the_verb_is_the_phase() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @after_frames(run, `
			globalThis.saw = { step: -1, frame: -1 };
			three.systems.step('walk', dt => { saw.step = dt; });
			three.systems.frame('look', dt => { saw.frame = dt; });
			globalThis.refused = [];
			try { three.systems.step('bad', () => {}, { phase: 'frame' }); }
			catch (e) { refused.push(e.message.includes('the verb is the phase')); }
			try { three.systems.frame('bad', () => {}, { phase: 'fixed' }); }
			catch (e) { refused.push(e.message.includes('the verb is the phase')); }
		`, 6, `
			const list = three.systems.list();
			return [
				list.find(s => s.name === 'walk').phase,
				list.find(s => s.name === 'look').phase,
				Math.abs(saw.step - three.clock.fixedDelta) < 1e-9,
				Math.abs(saw.frame - three.clock.dt) < 1e-9,
				refused,
				list.some(s => s.name === 'bad'),
			];
		`, "the verb script ran");

		// The phase each landed in, and then the reading that says the two
		// verbs really did reach two clocks rather than one clock twice: the
		// step was handed the step exactly, and the frame was handed what that
		// frame was worth.
		test::@check(value == "[\"fixed\",\"frame\",true,true,[true,true],false]",
			"the verb picks the phase and a second answer is refused; got %s", value);
	};
}

<*
 `after` and `before` name a neighbour, and registration order does the rest.

 The shape is `examples/tank_yard.js`: five systems in the order the file reads,
 and one at the bottom — the autopilot, which presses the game's own keys — that
 has to run before something declared three hundred lines above it. That was
 `order: 10` against `order: 50`, two coordinates whose only meaning was each
 other.

 The forward reference is checked in the same script on purpose: `draw` names
 `mark` before `mark` exists, which is the normal case rather than the clever
 one — a file is read top to bottom and half its neighbours are below.

 What must NOT happen is the rest of the list moving. `fire` is still the first
 frame system it was, because the only thing asked for was that one system come
 before it.
*>
fn void after_and_before_name_a_neighbour() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @after_frames(run, `
			globalThis.seen = [];
			three.systems.step('walk', () => seen.push('walk'));
			three.systems.frame('fire', () => seen.push('fire'));
			three.systems.frame('draw', () => seen.push('draw'), { after: 'mark' });
			three.systems.frame('autopilot', () => seen.push('autopilot'), { before: 'fire' });
			three.systems.frame('mark', () => seen.push('mark'));
		`, 4, `
			globalThis.seen = [];
			return [three.systems.list().map(s => s.name).join(',')];
		`, "the neighbour script ran");

		// Every step before any frame system; `autopilot` pulled in front of
		// `fire` and nothing else disturbed; `draw` pushed behind the `mark` it
		// named before there was one.
		test::@check(value == "[\"walk,autopilot,fire,mark,draw\"]",
			"a named neighbour moves one system and no others; got %s", value);
	};
}

<*
 `first` and `last` are the two ends of the game's own list, not of the tick.

 A game asking to be last means last among the things it wrote. The entity
 registry's own systems still bracket it — the rules drain ahead, because an
 event that fired has to be delivered before anything reads the result of it,
 and the column write-back and the compaction behind, because those have to see
 where everything finished. A `{ last: true }` that jumped those would be a
 script quietly reordering the engine, which is the trap the old numeric scale
 already sprang: two tests in this repo reached for `order: 1e7` and `order: 1e9`
 to get past brackets they could not see.
*>
fn void first_and_last_sit_inside_the_engines_own_brackets() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @value(run, `
			class Critter extends three.Entity {
				constructor() { super(); this.object = new three.Mesh(new three.BoxGeometry(1, 1, 1)); }
			}
			// Reading a static is what registers the class, and the rule is
			// what puts the drain in — neither needs a scene to exist.
			Critter.on('click', '*', () => {});

			three.systems.frame('late', () => {}, { last: true });
			three.systems.frame('middle', () => {});
			three.systems.frame('early', () => {}, { first: true });

			const at = three.systems.list().map(s => s.name);
			const seat = name => at.indexOf(name);
			return [
				seat('rules') < seat('early'),
				seat('early') < seat('middle'),
				seat('middle') < seat('late'),
				seat('late') < seat('Critter.compact'),
			];
		`, "the brackets script ran");

		test::@check(value == "[true,true,true,true]",
			"first and last are the ends of the script's list, inside the engine's; got %s", value);
	};
}

<*
 A loop is refused, and the registry is left exactly as it was.

 There is no order that satisfies it, so unlike a name that pointed at nothing
 there is nothing to carry on with — and the `add` that closed the loop is the
 call still on the screen. The rollback is the part worth a test: a registry
 that kept the half of the system that landed would fail the NEXT add too, for a
 reason that has scrolled away by then.
*>
fn void a_loop_is_refused_and_changes_nothing() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @value(run, `
			three.systems.frame('a', () => {});
			let said = '';
			try { three.systems.frame('b', () => {}, { before: 'a', after: 'a' }); }
			catch (e) { said = e.message; }
			return [said.includes('loop'), three.systems.list().map(s => s.name).join(',')];
		`, "the loop script ran");

		test::@check(value == "[true,\"a\"]",
			"a loop is raised and the registry is untouched; got %s", value);
	};
}

<*
 A neighbour that is not there is said once, and the system still runs.

 Not raised, unlike the loop: the sort runs while systems are being registered,
 where a name pointing forwards is not yet wrong, and again inside the tick,
 where a throw would take a whole loop down over a misspelling. Not swallowed
 either, for the reason every other failure in this file is reported — the
 system runs, in a place nobody asked for, and an out-of-order frame reads as a
 bug in whatever ran next.
*>
fn void a_neighbour_that_is_not_there_is_said_once() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		@value(run, `
			globalThis.ran = 0;
			three.systems.frame('lonely', () => { ran++; }, { after: 'nobody' });
			three.systems.step('walk', () => {}, { before: 'lonely' });
		`, "the missing-neighbour script ran");

		double at = 0;
		for (int i = 0; i < 5; i++) { at += 16.0; run.tick(at); }

		three::RunResult result = run.run("return ran;");
		defer result.free();
		test::@check(result.ok, "the reading script ran: %s", result.error);

		// It ran every frame regardless of the name it could not find.
		test::@check(result.value == "5", "the system still runs; got %s", result.value);

		// Once for five frames, not five times — and the cross-phase one says
		// which of the two it is, because that is the mistake two clocks invite.
		usz saidOnce = 0;
		String log = result.log;
		usz from = 0;
		while (try found = log[from..].index_of("nothing by that name"))
		{
			saidOnce++;
			from += (usz)(found + 1);
		}
		test::@check(saidOnce == 1, "the missing name is said once, not once a frame:\n%s", log);
		test::@check(
			log.contains("the phase decides which runs first"),
			"and a neighbour in the other phase says so:\n%s", log
		);
	};
}

<*
 `outline()` is the tick as a picture, with the two phases apart.

 One line each because they are two lists — every fixed step this frame owes
 runs before any frame system — and a flat list is what made the old pair
 unreadable: `{ phase: 'frame', order: 50 }` sitting between `order: 40` and
 `order: 60` on two fixed systems looks like it runs between them, and it runs
 after both.
*>
fn void the_outline_keeps_the_two_phases_apart() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @value(run, `
			three.systems.step('spawn', () => {});
			three.systems.step('shots', () => {});
			three.systems.frame('fire', () => {});
			three.systems.frame('autopilot', () => {}, { before: 'fire' });
			three.systems.enable('shots', false);

			const out = three.systems.outline();
			const lines = out.split('\n');
			return [
				lines.length,
				lines[0].startsWith('step'),
				lines[0].includes('(shots)'),
				lines[1].startsWith('frame'),
				lines[1].indexOf('autopilot') < lines[1].indexOf('fire'),
			];
		`, "the outline script ran");

		// Two lines, the steps first, a disabled system still shown and in
		// brackets, and the frame line in the order it runs.
		test::@check(value == "[2,true,true,true,true]",
			"the outline is the tick, phase by phase; got %s", value);
	};
}
