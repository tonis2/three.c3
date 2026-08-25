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
 A despawn does not move anybody until the frame ends.

 **The rule is one sentence and everything else follows from it**: an index is
 valid for the frame it was obtained in. A system holding index 4 across a
 despawn of index 2 must still be looking at the same critter, because the
 alternative — compacting on the spot — is a bug that looks like the wrong
 entity taking damage rather than like an indexing error.

 The compaction pass is a registered system, so this is a frame boundary and not
 a call the script makes.
*>
fn void a_despawn_takes_effect_at_the_end_of_the_frame() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @after_frames(run, `
			globalThis.log = [];
			const pack = three.cast({ capacity: 8, name: 'pack' });
			globalThis.pack = pack;
			const mark = pack.float('mark');
			globalThis.ids = [];
			for (let i = 0; i < 5; i++) { const id = pack.spawn(); ids.push(id); mark[pack.indexOf(id)] = i + 1; }

			let frames = 0;
			pack.system('watch', () => {
				frames++;
				if (frames === 1) {
					pack.despawn(ids[1]);
					// Same frame, after the despawn: nothing has moved.
					log.push([pack.count, pack.alive, pack.indexOf(ids[3]), mark[3], pack.indexOf(ids[1])]);
				}
				if (frames === 2) {
					log.push([pack.count, pack.alive, pack.indexOf(ids[3]), mark[2], pack.indexOf(ids[1])]);
				}
			}, { order: 0 });
		`, 4, `
			return log;
		`, "the deferred-despawn script ran");

		// In the frame of the despawn: five slots, four alive, id 3 still at
		// index 3 with its own mark, and the dead id already answering -1.
		// After the boundary: four slots, four alive, id 3 shifted to 2 and its
		// mark with it.
		test::@check(value == "[[5,4,3,4,-1],[4,4,2,4,-1]]",
			"the slot lingers for the frame and the index is stable; got %s", value);
	};
}

<*
 The columns ARE the buffers, which is the whole reason a cast is worth having.

 `three.steer`, `field.sample` and `three.moveAndSlideAll` take a contiguous
 typed array, and `cast.live(column)` is that array with nothing copied. If this
 ever stops being true the cast becomes a marshalling step in front of the verbs
 that exist to remove one.
*>
fn void a_cast_column_is_what_the_bulk_verbs_take() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @value(run, `
			const scene = new three.Scene();
			const floor = new three.Mesh(new three.BoxGeometry(60, 2, 60));
			floor.position.y = -1;
			scene.add(floor);

			const pack = three.cast({ capacity: 6, name: 'pack' });
			const position = pack.vec3('position');
			const motion = pack.vec3('motion');
			const move = pack.buffer('move', three.moveResult.stride);

			for (let i = 0; i < 4; i++) {
				const g = new three.Group();
				const body = new three.Mesh(new three.BoxGeometry(0.6, 0.8, 0.6));
				body.position.y = 0.6;
				g.add(body);
				g.position.set(i * 4, 0, 0);
				scene.add(g);
				const id = pack.spawn();
				pack.attach(id, g);
				const at = pack.indexOf(id) * 3;
				position[at] = i * 4;
				position[at + 1] = 0.6;
				motion[at] = 0.5;
				motion[at + 1] = -0.05;
			}

			// The live view is a subarray of the column, not a copy.
			const view = pack.live(position);
			const sameMemory = view.buffer === position.buffer && view.length === pack.count * 3;
			const cached = pack.live(position) === view;

			const stepped = three.moveAndSlideAll(view, pack.live(motion), {
				radius: 0.4, height: 1.2, step: 0.4, slope: 50, snap: 0.3,
				results: pack.live(move), self: pack.live(pack.handles),
			});

			// It wrote through the view into the column itself.
			const wrote = Math.abs(position[0] - 0.5) < 0.01;
			let grounded = 0;
			for (let i = 0; i < pack.count; i++) {
				if ((move[i * 8 + three.moveResult.flags] | 0) & three.moveResult.GROUNDED) grounded++;
			}

			// And drawing them is one more crossing.
			pack.pose(position, { lift: -0.6 });
			const flushed = pack.flush();
			const stale = pack.objectAt(0).position.x === 0;
			const synced = pack.sync();
			const agrees = Math.abs(pack.objectAt(0).position.x - position[0]) < 1e-6;

			return [sameMemory, cached, stepped, wrote, grounded, flushed, stale, synced, agrees];
		`, "the columns script ran");

		// Same memory, cached view, four stepped, the column written through,
		// all four grounded, four flushed in one crossing, the objects stale
		// until sync and in agreement after it.
		test::@check(value == "[true,true,4,true,4,4,true,4,true]",
			"a column is the buffer and nothing is copied; got %s", value);
	};
}

<*
 An id outlives a compaction and a dead one never comes back.

 The generational half of the sparse set, and the same contract `NodeId` carries
 for the same reason: a bare slot cannot tell entity 3 from whatever moved into
 slot 3 afterwards, and a script that kept one across a frame would damage the
 wrong thing with no error anywhere.
*>
fn void an_id_survives_a_move_and_a_dead_one_never_returns() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @value(run, `
			const pack = three.cast({ capacity: 4, name: 'pack' });
			const mark = pack.float('mark');
			const ids = [];
			for (let i = 0; i < 4; i++) { const id = pack.spawn(); ids.push(id); mark[i] = i + 10; }

			// Full: a spawn with nothing dead is an answer, not an error.
			const whenFull = pack.spawn();

			pack.despawn(ids[0]);
			pack.compact();

			const moved = pack.indexOf(ids[3]);          // was 3, now 2
			const markFollowed = mark[moved] === 13;
			const roundTrip = pack.idOf(moved) === ids[3];

			// The slot the dead one used comes back, and the old id does not.
			const reborn = pack.spawn();
			const rebornAt = pack.indexOf(reborn);
			const oldStillDead = pack.indexOf(ids[0]);
			const zeroed = mark[rebornAt] === 0;

			return [whenFull, moved, markFollowed, roundTrip, rebornAt, oldStillDead, zeroed,
				pack.count, pack.alive, three.NO_ENTITY];
		`, "the generation script ran");

		// Full answers NO_ENTITY; the survivor moved from 3 to 2 with its data
		// and answers to the same id; the reused slot is at the end and zeroed;
		// the retired id is still nothing.
		test::@check(value == "[-1,2,true,true,3,-1,true,4,4,-1]",
			"an id is durable and a dead one is dead; got %s", value);
	};
}

<*
 A cast hands its object back rather than deleting it.

 The rest of this API frees nothing until it is told to, and a cast that quietly
 removed nodes would be a local exception to that — `plan.md` §21 called it and
 this is the call. `scene.remove(pack.despawn(id))` is the line, and the point of
 the shape is that it says at the call site what happens to the mesh.
*>
fn void despawn_hands_the_object_back() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @value(run, `
			const scene = new three.Scene();
			const pack = three.cast({ capacity: 4, name: 'pack' });
			const m = new three.Mesh(new three.BoxGeometry(1, 1, 1));
			scene.add(m);
			const id = pack.spawn();
			pack.attach(id, m);

			const drawnBefore = scene.stats().drawCalls;
			const handed = pack.despawn(id);
			const same = handed === m;
			const stillDrawn = scene.stats().drawCalls === drawnBefore;
			scene.remove(handed);
			const gone = scene.stats().drawCalls < drawnBefore;
			return [same, stillDrawn, gone, pack.despawn(id) === null];
		`, "the ownership script ran");

		// The object comes back, it is still in the scene until the caller says
		// otherwise, removing it works, and a second despawn is null.
		test::@check(value == "[true,true,true,true]",
			"a cast is not a lifetime manager; got %s", value);
	};
}

<*
 `cast.of(object)` answers with an ID, and survives the compaction that moves
 the slot.

 **An id and not a slot, and the test is the compaction.** A query, a raycast
 and `three.onTrigger` all hand back an object, and what a script wants back is
 the thing it can still hold next frame — `_objects` is indexed by SLOT and a
 slot moves when something above it dies, so a reverse map built on one would
 answer with somebody else's critter the moment anything was despawned. That is
 not an error anywhere; it is the wrong entity taking damage, which is the same
 failure `notes.md` §21 wrote the deferred compaction to prevent, arriving
 through the lookup instead of through the index.

 `examples/wumpa_run.js` hand-built exactly this map and got it right by keeping
 an id in it; the point of having it here is that the next script does not have
 to know why.
*>
fn void a_cast_finds_its_entity_from_an_object_across_a_compaction() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @value(run, `
			const scene = new three.Scene();
			const pack = three.cast({ capacity: 8, name: 'pack' });
			const objects = [], ids = [];
			for (let i = 0; i < 4; i++) {
				const m = new three.Mesh(new three.BoxGeometry(1, 1, 1));
				m.position.x = i * 2;
				scene.add(m);
				objects.push(m);
				const id = pack.spawn();
				ids.push(id);
				pack.attach(id, m);
			}
			const stranger = new three.Mesh(new three.BoxGeometry(1, 1, 1));
			scene.add(stranger);

			const found = pack.of(objects[3]) === ids[3];
			const slotBefore = pack.indexOf(pack.of(objects[3]));

			// Kill the first one and close the gap, which moves every slot
			// above it down by one.
			scene.remove(pack.despawn(ids[0]));
			pack.compact();

			return [
				found, slotBefore,
				pack.of(objects[3]) === ids[3],
				pack.indexOf(pack.of(objects[3])),
				pack.of(objects[0]),
				pack.of(stranger),
				three.NO_ENTITY,
				pack.objectAt(pack.indexOf(pack.of(objects[3]))) === objects[3],
			];
		`, "the reverse-lookup script ran");

		// The object answered with its id before the compaction and with the
		// same id after it, while the SLOT moved from 3 to 2; a despawned
		// object and one the cast never had are both NO_ENTITY; and the round
		// trip back through objectAt lands on the object it started from.
		test::@check(value == "[true,3,true,2,-1,-1,-1,true]",
			"an object answers with a durable id, not a slot; got %s", value);
	};
}

<*
 `dispose` takes the cast's systems out of the registry, including the
 compaction pass it registered on its own.

 A level teardown that left the compaction system behind would leave the
 registry calling into a cast nothing else references, which is the kind of leak
 that shows up as a report full of names from the last level.
*>
fn void disposing_a_cast_takes_its_systems_with_it() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @value(run, `
			const before = three.systems.length;
			const pack = three.cast({ capacity: 4, name: 'pack' });
			pack.system('a', () => {});
			pack.system('b', () => {}, { phase: 'fixed' });
			const names = three.systems.list().map(s => s.name).filter(n => n.startsWith('pack.'));
			const during = three.systems.length;
			pack.dispose();
			return [before, during - before, names.sort().join(','), three.systems.length];
		`, "the dispose script ran");

		// Nothing registered to start with; a cast adds its compaction pass and
		// the two systems; all three go.
		test::@check(value == "[0,3,\"pack.a,pack.b,pack.compact\",0]",
			"a cast's systems leave with it; got %s", value);
	};
}

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
