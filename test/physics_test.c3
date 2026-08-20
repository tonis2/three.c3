<*
 The physics world — `game.md` G5.
*>
module three_tests::physics;

import three;
import vk;
import qjs;
import std::core::test;
import std::io;
import std::math;

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

// A ball dropped on a floor comes to rest on it, and gets there by falling.
fn void a_dropped_body_lands_on_the_floor() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult built = run.run(`
			const scene = new three.Scene();
			const floor = new three.Mesh(new three.BoxGeometry(20, 1, 20));
			floor.position.y = -0.5;
			scene.add(floor);
			three.physics.add(floor, { shape: 'box', mass: 0 });

			const ball = new three.Mesh(new three.SphereGeometry(0.5, 16, 8));
			ball.position.set(0, 6, 0);
			scene.add(ball);
			three.physics.add(ball, { shape: 'sphere', mass: 1 });
			globalThis.ball = ball;
			return three.physics.count;
		`);
		defer built.free();
		test::@check(built.ok, "the scene built: %s", built.error);
		test::@check(built.value == "2", "two bodies, got '%s'", built.value);

		// Two seconds of frames. The host clock is the caller's, so this is
		// exactly 120 steps of the fixed 60 Hz world and nothing depends on
		// how fast the machine running the test happens to be.
		for (int i = 1; i <= 120; i++) run.tick((double)i * (1000.0 / 60.0));

		three::RunResult after = run.run("return globalThis.ball.position.y;");
		defer after.free();
		test::@check(after.ok, "read the ball back: %s", after.error);

		double y = after.value.to_double() ?? 999.0;
		test::@check(y < 1.0, "the ball fell, y = %s", after.value);
		test::@check(y > 0.0, "and stopped on the floor rather than through it, y = %s", after.value);
	};
}

// G5/S6. The solver owns a dynamic body's transform, and says so rather than
// letting a script and the world take turns writing it.
fn void the_solver_refuses_a_write_to_what_it_owns() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();

			const dynamic = new three.Mesh(new three.BoxGeometry(1, 1, 1));
			scene.add(dynamic);
			three.physics.add(dynamic, { shape: 'box', mass: 1 });

			const stat = new three.Mesh(new three.BoxGeometry(1, 1, 1));
			scene.add(stat);
			three.physics.add(stat, { shape: 'box', mass: 0 });

			const kinematic = new three.Mesh(new three.BoxGeometry(1, 1, 1));
			scene.add(kinematic);
			three.physics.add(kinematic, { shape: 'box', kinematic: true });

			const tried = (o) => { try { o.position.y = 3; return null; } catch (e) { return e.message; } };

			return {
				dynamic: tried(dynamic),
				// A static body never moves, so nothing is being fought over.
				static: tried(stat),
				// Kinematic is exactly "I will move this myself".
				kinematic: tried(kinematic),
				// And the refusal lifts when the body does.
				afterRemove: (three.physics.remove(dynamic), tried(dynamic)),
			};
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value.contains("belongs to the physics solver"),
			"the dynamic body was refused, with a reason: %s", result.value);
		test::@check(result.value.contains(`"static":null`), "the static body was writable: %s", result.value);
		test::@check(result.value.contains(`"kinematic":null`), "the kinematic body was writable: %s", result.value);
		test::@check(result.value.contains(`"afterRemove":null`),
			"removing the body gave the transform back: %s", result.value);
	};
}

<*
 G5/S1. **The claim the fixed step exists to make.**

 The same second of simulated time, delivered as 60 frames and as 30, lands in
 the same place. A variable-rate integrator would not: it would take bigger,
 less accurate steps on the longer frames and drift. This is what "physics is
 fixed-rate, the frame callback stays variable-rate, and the two never argue"
 means, written as something that can fail.

 Each run starts from `new three.Scene()`, which empties the world and with it
 the accumulator — otherwise the second run inherits the first run's remainder
 and the comparison is measuring that instead.
*>
macro double @fall_for_a_second(three::JsRuntime* run, double start_ms, int frames)
{
	three::RunResult built = run.run(`
		const scene = new three.Scene();
		const floor = new three.Mesh(new three.BoxGeometry(40, 1, 40));
		floor.position.y = -20;
		scene.add(floor);
		three.physics.add(floor, { shape: 'box', mass: 0 });

		const ball = new three.Mesh(new three.SphereGeometry(0.5, 16, 8));
		ball.position.set(0, 10, 0);
		scene.add(ball);
		three.physics.add(ball, { shape: 'sphere', mass: 1 });
		globalThis.ball = ball;
		return 'ok';
	`);
	defer built.free();
	test::@check(built.ok, "the scene built: %s", built.error);

	for (int i = 1; i <= frames; i++) run.tick(start_ms + (double)i * (1000.0 / (double)frames));

	three::RunResult read = run.run("return globalThis.ball.position.y;");
	defer read.free();
	test::@check(read.ok, "the ball was read back: %s", read.error);
	return read.value.to_double() ?? 999.0;
}

fn void the_step_is_fixed_whatever_the_frame_rate() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		// Continuous on the host clock. A jump would arrive as one enormous
		// delta, be clamped to ANIMATION_MAX_STEP_MS and then hit the five-step
		// catch-up cap — the spiral guard doing its job, and nothing to do with
		// the frame rate this is measuring.
		double y_fast = @fall_for_a_second(run, 0.0, 60);
		double y_slow = @fall_for_a_second(run, 1000.0, 30);

		// Free fall for a second is ~4.9 units before the world's linear
		// damping takes its share, so this only asserts that it plainly moved.
		test::@check(y_fast < 8.0, "the ball actually fell in the 60-frame run, y = %f", y_fast);
		// **Bounded divergence, not bit-equality, and the bound is the point.**
		// A fixed accumulator keeps a remainder, so at any instant the world is
		// up to a step behind the frame — and two runs whose frames divide the
		// second differently end on different sides of that remainder. What
		// must not happen is drift that grows with the frame length, which is
		// what a variable-rate integrator does. A step's worth of fall at this
		// speed is about 0.07 units; a couple of steps is the whole budget.
		test::@check(math::abs(y_fast - y_slow) < 0.25,
			"same second, same fall to within a step or two: 60 frames gave %f, 30 frames gave %f",
			y_fast, y_slow);
	};
}

// G5/S7 and S5, together: a body destroyed inside a trigger is still seen to
// leave it. The library half of this is `test_remove_body_emits_exit_events`;
// this is the half that gets it to a script.
fn void a_body_destroyed_in_a_trigger_still_leaves_it() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult built = run.run(`
			const scene = new three.Scene();
			globalThis.seen = [];
			three.onTrigger(e => globalThis.seen.push(e.type + ':' + (e.other ? e.other.name : 'gone')));

			const zone = new three.Mesh(new three.BoxGeometry(6, 6, 6));
			zone.name = 'zone';
			scene.add(zone);
			three.physics.add(zone, { shape: 'box', trigger: true });

			const walker = new three.Mesh(new three.BoxGeometry(1, 1, 1));
			walker.name = 'walker';
			scene.add(walker);
			three.physics.add(walker, { shape: 'box', kinematic: true });
			globalThis.walker = walker;

			three.setAnimationLoop(() => {});
			return 'ok';
		`);
		defer built.free();
		test::@check(built.ok, "the scene built: %s", built.error);

		// Overlapping from the start, so the enter lands on the first step.
		for (int i = 1; i <= 10; i++) run.tick((double)i * (1000.0 / 60.0));

		three::RunResult entered = run.run("return globalThis.seen.join(',');");
		defer entered.free();
		test::@check(entered.value.contains("enter:walker"), "the walker entered: %s", entered.value);

		// Destroyed while still inside.
		three::RunResult destroyed = run.run("three.physics.remove(globalThis.walker); return 'ok';");
		defer destroyed.free();
		test::@check(destroyed.ok, "the body was removed: %s", destroyed.error);

		for (int i = 11; i <= 14; i++) run.tick((double)i * (1000.0 / 60.0));

		three::RunResult exited = run.run("return globalThis.seen.join(',');");
		defer exited.free();
		test::@check(exited.value.contains("exit:walker"),
			"and was still seen to leave, naming what left: %s", exited.value);
	};
}

// Y is down, once, with no axis to configure — G5/S2a.
fn void gravity_is_y_up_and_settable() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const before = three.physics.gravity;
			three.physics.gravity = [0, 0, -20];
			const after = three.physics.gravity;
			return { before, after };
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value.contains("[0,-9.8"), "y-down by default: %s", result.value);
		test::@check(result.value.contains("[0,0,-20]"), "and settable to anything: %s", result.value);
	};
}

<*
 A scene with a body spawned inside static geometry does not take the process
 with it.

 This is the scene that found the guard: four walls laid out so that two of them
 run through the origin, and a stack of boxes spawned at the origin — so the
 boxes begin *inside* static geometry. XPBD answers a deep overlap with a
 correspondingly deep correction, and a few substeps of that leaves a transform
 with no finite value in it; the next `spatial_map.update` trips a library
 `@require` and aborts.

 An agent writing scenes will produce this constantly, and "the application
 exits" is the one failure this API cannot afford. `xpbd_predict` now throws the
 nonsense prediction away and puts the body back where it was, so the overlap
 costs a body that sits still rather than a process that stops — and this holds
 it to that.
*>
fn void a_body_inside_a_wall_does_not_take_the_process_with_it() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult built = run.run(`
			const scene = new three.Scene();

			const ground = new three.Mesh(new three.BoxGeometry(40, 1, 40));
			ground.position.y = -0.5;
			scene.add(ground);
			three.physics.add(ground, { shape: 'box', mass: 0 });

			// Deliberately wrong: an 18-long wall centred nine out from the
			// origin reaches the origin, so it runs through the stack below.
			for (let i = 0; i < 4; i++) {
				const a = (i / 4) * Math.PI * 2;
				const wall = new three.Mesh(new three.BoxGeometry(18, 3, 1));
				wall.position.set(Math.cos(a) * 9, 1.5, Math.sin(a) * 9);
				wall.rotation.y = -a;
				scene.add(wall);
				three.physics.add(wall, { shape: 'box', mass: 0 });
			}

			for (let i = 0; i < 6; i++) {
				const b = new three.Mesh(new three.BoxGeometry(1, 1, 1));
				b.position.set(0, 0.5 + i * 1.02, 0);
				scene.add(b);
				three.physics.add(b, { shape: 'box', mass: 1 });
			}

			// Convex hulls dropped in on top, which is what actually drives the
			// stack into the wall it is already inside.
			let seed = 7;
			const rnd = () => (seed = (seed * 1664525 + 1013904223) >>> 0) / 4294967296;
			for (let i = 0; i < 8; i++) {
				const pts = [];
				for (let k = 0; k < 12; k++) pts.push([(rnd() - 0.5) * 1.6, (rnd() - 0.5) * 1.6, (rnd() - 0.5) * 1.6]);
				const rock = new three.Mesh(new three.ConvexGeometry(pts));
				rock.position.set((rnd() - 0.5) * 8, 6 + i * 1.5, (rnd() - 0.5) * 8);
				scene.add(rock);
				three.physics.add(rock, { shape: 'hull', mass: 2, restitution: 0.2 });
			}

			three.setAnimationLoop(() => {});
			return three.physics.count;
		`);
		defer built.free();
		test::@check(built.ok, "the scene built: %s", built.error);
		test::@check(built.value == "19", "nineteen bodies, got '%s'", built.value);

		// Long enough for the overlap to blow up and for the guard to see it.
		for (int i = 1; i <= 600; i++) run.tick((double)i * (1000.0 / 60.0));

		// Read before anything else runs: `run` clears the frame report, so a
		// script asked first would take the answer away.
		bool reported = run.frame_error.str_view().contains("left the simulation");

		// **Reaching here at all is most of the claim**: before the solver reset
		// this aborted inside the broadphase, six hundred frames from anything
		// the caller could have done about it.
		three::RunResult after = run.run("return three.physics.count;");
		defer after.free();
		test::@check(after.ok, "the world still answers: %s", after.error);

		// Most bodies survive. A couple are thrown clear of the world by the
		// overlap before it settles and are evicted at ten kilometres out —
		// which is the host's second line and a different case from the
		// solver's: that one is "this stopped being a number", this one is
		// "this is still a number and is nowhere near the game".
		int left = (int)(after.value.to_int() ?? 0);
		test::@check(left >= 15 && left <= 19, "most bodies survived, %d of 19 left", left);

		// And whatever was evicted was said out loud rather than vanishing.
		// `report_frame_failure` writes to `frame_error`, which is what the run
		// report carries back — where an agent already reads for what went
		// wrong inside a frame.
		if (left < 19) test::@check(reported, "the eviction was reported rather than silent");

		// The animation loop is untouched: none of this is a script's failure,
		// so nothing was stopped for good.
		three::RunResult live = run.run("return three.physics.count > 0;");
		defer live.free();
		test::@check(live.value == "true", "the world is still usable: %s", live.value);
	};
}

<*
 Removing one body out of a world where others are still touching — G5/S5.

 Separate from `a_body_destroyed_in_a_trigger_still_leaves_it` because that one
 removes the only overlapping pair there is. The replacement sets the library
 builds are then never written to, which is the one case that cannot expose
 where they live. This scene keeps a stack in contact after the removal, so the
 next step reads a set that had to be rebuilt, and reads it from wherever the
 rebuild put it.
*>
fn void removing_one_body_leaves_the_rest_standing() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult built = run.run(`
			const scene = new three.Scene();

			const ground = new three.Mesh(new three.BoxGeometry(20, 1, 20));
			ground.name = 'ground';
			ground.position.set(0, -0.5, 0);
			scene.add(ground);
			three.physics.add(ground, { mass: 0 });

			// Four resting on the floor and on each other, so the contact set
			// has pairs that must survive one of them going away.
			const geo = new three.BoxGeometry(1, 1, 1);
			globalThis.boxes = [];
			for (let i = 0; i < 4; i++) {
				const box = new three.Mesh(geo);
				box.name = 'box' + i;
				box.position.set(0, 0.5 + i * 1.02, 0);
				scene.add(box);
				three.physics.add(box, { mass: 1, friction: 0.6 });
				globalThis.boxes.push(box);
			}

			three.setAnimationLoop(() => {});
			return 'ok';
		`);
		defer built.free();
		test::@check(built.ok, "the stack built: %s", built.error);

		// Long enough for the stack to settle into contact with itself.
		double clock = 0;
		for (int i = 0; i < 90; i++) { clock += 1000.0 / 60.0; run.tick(clock); }

		three::RunResult removed = run.run(
			"const n = three.physics.count;"
			"three.physics.remove(globalThis.boxes[1]);"
			"return n - three.physics.count;"
		);
		defer removed.free();
		test::@check(removed.ok, "the middle box was removed: %s", removed.error);
		test::@check(removed.value == "1", "and exactly one body went: %s", removed.value);

		// The steps that read the rebuilt sets.
		for (int i = 0; i < 60; i++) { clock += 1000.0 / 60.0; run.tick(clock); }

		three::RunResult standing = run.run(
			"return [three.physics.count,"
			" globalThis.boxes.filter(b => b.body).length];"
		);
		defer standing.free();
		test::@check(standing.ok, "the world survived the removal: %s", standing.error);
		test::@check(standing.value == "[4,3]",
			"four bodies and three live boxes are left: %s", standing.value);
	};
}

// ============================================================================
// Steering a body
//
// The gap these close is the one that stopped a character being built on this
// world at all: a dynamic body could be dropped and watched but never steered,
// and a kinematic one was steered but never stopped, so there was no
// combination that walked *and* collided. `examples/village` worked around it
// with 123 hand-registered shapes resolved in JavaScript every frame.
//
// Every check here asserts a position moved, not that a number came back. A
// binding that wrote `linear_velocity` into a copy of the solver's record would
// round-trip perfectly through `velocity()` and move nothing.
// ============================================================================

<*
 A velocity set from a script carries the body across the floor.

 Sideways rather than up, so gravity is not what is being measured, and against
 a floor so this is a body that is colliding at the same time as it is being
 driven — which is the combination that did not exist.
*>
fn void a_velocity_set_from_a_script_moves_the_body() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult built = run.run(`
			const scene = new three.Scene();
			const floor = new three.Mesh(new three.BoxGeometry(60, 1, 60));
			floor.position.y = -0.5;
			scene.add(floor);
			three.physics.add(floor, { shape: 'box', mass: 0 });

			const box = new three.Mesh(new three.BoxGeometry(1, 1, 1));
			box.position.set(0, 0.5, 0);
			scene.add(box);
			three.physics.add(box, { shape: 'box', mass: 1 });
			globalThis.box = box;

			// Set once here so the round trip can be read before any frame has
			// run, then held every frame — which is what a character does. The
			// solver recomputes the velocity from what actually happened at the
			// end of each step, so a single set survives exactly one
			// integration and a walk has to keep asking.
			three.physics.setVelocity(box, [4, 0, 0]);
			const readBack = three.physics.velocity(box)[0];
			three.setAnimationLoop(() => three.physics.setVelocity(box, [4, 0, 0]));
			return readBack;
		`);
		defer built.free();
		test::@check(built.ok, "the scene built: %s", built.error);
		test::@check(built.value == "4", "the velocity reads back as it was set, got '%s'", built.value);

		// One second of the fixed 60 Hz world.
		for (int i = 1; i <= 60; i++) run.tick((double)i * (1000.0 / 60.0));

		three::RunResult after = run.run("three.setAnimationLoop(null); return globalThis.box.position.x;");
		defer after.free();
		test::@check(after.ok, "reading back succeeded: %s", after.error);

		double x = after.value.to_double() ?? 0.0;
		// 4 units a second for a second, less whatever friction with the floor
		// takes. Loose at the top as well as the bottom: a body that shot off to
		// 40 would mean the velocity was being added to every frame rather than
		// assigned, which is the mistake this API's shape exists to prevent.
		test::@check(x > 2.5 && x < 5.0,
			"a body held at 4 units a second for a second should be about 4 units along, got %f", x);
	};
}

<*
 An impulse adds to what the body was already doing, and a sleeping body
 answers it.

 The sleep half is the one worth having a check for. A body resting on a floor
 is asleep within half a second, and a sleeping body is skipped by integration
 entirely — so a binding that did not wake it would work on a rolling crate and
 do nothing at all to a settled one, which reads as the verb being unreliable
 rather than as sleep.

 **Proved by injection, and the injection is more alarming than the check.**
 Deleting the two lines of `Physics.wake` does not make this go red; it makes
 the suite **hang**, reproducibly, with the main thread in
 `collision::WorkerPool.join` on a mutex and a worker parked on a condition
 variable. Giving a sleeping body a velocity is a state the solver's island
 bookkeeping does not survive. That is worth knowing beyond this file: it is the
 state any binding that wrote `linear_velocity` and stopped there would create
 on its very first push, so the wake is a correctness requirement of the library
 and not a courtesy of this API.
*>
fn void an_impulse_wakes_a_settled_body_and_moves_it() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult built = run.run(`
			const scene = new three.Scene();
			const floor = new three.Mesh(new three.BoxGeometry(60, 1, 60));
			floor.position.y = -0.5;
			scene.add(floor);
			three.physics.add(floor, { shape: 'box', mass: 0 });

			const ball = new three.Mesh(new three.SphereGeometry(0.5, 16, 8));
			ball.position.set(0, 0.5, 0);
			scene.add(ball);
			three.physics.add(ball, { shape: 'sphere', mass: 1 });
			globalThis.ball = ball;
			return 1;
		`);
		defer built.free();
		test::@check(built.ok, "the scene built: %s", built.error);

		// Two seconds of doing nothing, which is four times the sleep timer.
		for (int i = 1; i <= 120; i++) run.tick((double)i * (1000.0 / 60.0));

		three::RunResult asleep = run.run(`
			const v = three.physics.velocity(globalThis.ball);
			return { still: Math.abs(v[0]) < 0.01, y: globalThis.ball.position.y };
		`);
		defer asleep.free();
		test::@check(asleep.ok, "the settling script succeeded: %s", asleep.error);
		test::@check(asleep.value.contains(`"still":true`),
			"the ball has to have settled for this to be testing sleep at all: %s", asleep.value);

		three::RunResult push = run.run("three.physics.applyImpulse(globalThis.ball, [6, 0, 0]); return 1;");
		defer push.free();
		test::@check(push.ok, "the impulse succeeded: %s", push.error);

		for (int i = 121; i <= 180; i++) run.tick((double)i * (1000.0 / 60.0));

		three::RunResult after = run.run("return globalThis.ball.position.x;");
		defer after.free();
		double x = after.value.to_double() ?? 0.0;
		test::@check(x > 1.0,
			"a settled ball given a 6-unit impulse should have travelled, got x = %f — a sleeping body absorbs an impulse into a number nothing reads",
			x
		);
	};
}

<*
 A torque impulse spins a body without shoving it.
*>
fn void a_torque_impulse_spins_without_shoving() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult built = run.run(`
			const scene = new three.Scene();
			const box = new three.Mesh(new three.BoxGeometry(1, 1, 1));
			scene.add(box);
			three.physics.add(box, { shape: 'box', mass: 1 });
			three.physics.gravity = [0, 0, 0];
			three.physics.applyTorqueImpulse(box, [0, 2, 0]);
			const v = three.physics.velocity(box);
			return { spin: v[4] > 0.1, drift: Math.abs(v[0]) + Math.abs(v[1]) + Math.abs(v[2]) };
		`);
		defer built.free();
		test::@check(built.ok, "the script succeeded: %s", built.error);
		test::@check(built.value.contains(`"spin":true`),
			"a torque impulse about y should give an angular velocity about y: %s", built.value);
		test::@check(built.value.contains(`"drift":0`),
			"and no linear velocity at all: %s", built.value);
	};
}

<*
 The three bodies that cannot be pushed refuse by name.

 Each one is a different mistake with a different fix, so each gets its own
 sentence rather than one "cannot" covering all of them. The failure being
 avoided is the silent kind: a static body absorbs an impulse arithmetically —
 inverse mass zero — and a kinematic body has its velocity overwritten a
 fraction of a step later, so both would look like the verb doing nothing.
*>
fn void a_body_the_solver_does_not_integrate_refuses_to_be_pushed() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			const out = {};

			const wall = new three.Mesh(new three.BoxGeometry(1, 1, 1));
			scene.add(wall);
			three.physics.add(wall, { shape: 'box', mass: 0 });
			try { three.physics.setVelocity(wall, [1, 0, 0]); out.static = 'accepted'; }
			catch (e) { out.static = e.message; }

			const lift = new three.Mesh(new three.BoxGeometry(1, 1, 1));
			lift.position.x = 4;
			scene.add(lift);
			three.physics.add(lift, { shape: 'box', mass: 1, kinematic: true });
			try { three.physics.applyImpulse(lift, [1, 0, 0]); out.kinematic = 'accepted'; }
			catch (e) { out.kinematic = e.message; }

			const loose = new three.Mesh(new three.BoxGeometry(1, 1, 1));
			loose.position.x = 8;
			scene.add(loose);
			try { three.physics.setVelocity(loose, [1, 0, 0]); out.none = 'accepted'; }
			catch (e) { out.none = e.message; }

			return out;
		`);
		defer result.free();
		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value.contains("static body"),
			"a static body should refuse and say why: %s", result.value);
		test::@check(result.value.contains("kinematic body"),
			"a kinematic body should refuse and say why: %s", result.value);
		test::@check(result.value.contains("needs a body"),
			"an object with no body should say that rather than anything about masses: %s", result.value);
	};
}

<*
 Reading a velocity off something with no body is null, not a throw.

 The asymmetry with the setters is deliberate: a getter is asked in a loop over
 objects that may or may not have bodies, and making that throw means writing
 the same guard at every call site.
*>
fn void reading_a_velocity_with_no_body_is_null() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			const m = new three.Mesh(new three.BoxGeometry(1, 1, 1));
			scene.add(m);
			return three.physics.velocity(m) === null;
		`);
		defer result.free();
		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == "true", "no body should read back as null, got '%s'", result.value);
	};
}
