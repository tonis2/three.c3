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
import image;

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

// A device, a runtime and a renderer whose frames can be read back — the same
// harness as `@with_gpu_js` with the renderer handed out, for the two checks
// that are about the picture rather than about the numbers.
macro @with_gpu_frames(; @body(three::JsRuntime* run, three::Renderer* renderer))
{
	vk::Instance instance = three::create_instance(false, headless: true)!!;
	defer instance.free();

	three::Renderer renderer;
	renderer.init(instance, (vk::SurfaceKHR)null, 240, 180)!!;
	defer renderer.free();

	renderer.pass.init(&renderer.gpu, &renderer.target)!!;

	three::JsRuntime runtime;
	runtime.open(&renderer.pass, &renderer)!!;
	defer runtime.close();

	@body(&runtime, &renderer);
}

// How many bytes two frames of the same size disagree about.
fn sz differing_pixels(image::Image* a, image::Image* b)
{
	if (a.width != b.width || a.height != b.height) return sz::max;
	sz count = 0;
	foreach (i, byte : a.pixels)
	{
		if (byte != b.pixels[i]) count++;
	}
	return count;
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

<*
 A level's bodies can be built before the level is shown, and they wait.

 **The regression this exists for is a transition that has to rebuild its
 physics.** A world belongs to its scene, so the next level's floor and its
 falling things are standing up while the current level is still on screen —
 and the swap costs nothing. The other half is the honest cost of that: the
 frame steps ONE world, so a body in a scene nobody is looking at is correct and
 motionless. A script that expected it to be simulating would otherwise find out
 by the physics being wrong rather than by being told.

 Proved by injection: step every scene in `frame_loop.c3` and `waited` comes back
 well below 6; put the world back on `JsRuntime` and the `next.physics.add` calls
 land in the world the first scene is using, so `count` reads 4.
*>
fn void bodies_built_before_a_swap_wait_for_it() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult built = run.run(`
			const here = new three.Scene();
			const wall = new three.Mesh(new three.BoxGeometry(4, 4, 4));
			here.add(wall);
			here.physics.add(wall, { shape: 'box', mass: 0 });

			// The next level, built while the first is the one being rendered.
			const next = new three.Scene();
			next.activate();
			here.activate();

			const floor = new three.Mesh(new three.BoxGeometry(20, 1, 20));
			floor.position.y = -0.5;
			next.add(floor);
			next.physics.add(floor, { shape: 'box', mass: 0 });

			const ball = new three.Mesh(new three.SphereGeometry(0.5, 16, 8));
			ball.position.set(0, 6, 0);
			next.add(ball);
			next.physics.add(ball, { shape: 'sphere', mass: 1 });

			globalThis.here = here;
			globalThis.next = next;
			globalThis.ball = ball;
			// Two worlds, not one: the wall is not in the next level's.
			return [here.physics.count, next.physics.count];
		`);
		defer built.free();
		test::@check(built.ok, "the two scenes built: %s", built.error);
		test::@check(built.value == "[1,2]", "each scene has its own bodies, got '%s'", built.value);

		// Two seconds of frames with the OTHER scene active. Nothing in `next`
		// may move.
		for (int i = 1; i <= 120; i++) run.tick((double)i * (1000.0 / 60.0));

		three::RunResult waited = run.run("return globalThis.ball.position.y;");
		defer waited.free();
		test::@check(waited.ok, "read the ball back: %s", waited.error);
		test::@check(waited.value == "6", "it has not moved, y = %s", waited.value);

		three::RunResult swapped = run.run("globalThis.next.activate(); return 1;");
		defer swapped.free();
		test::@check(swapped.ok, "the swap ran: %s", swapped.error);

		for (int i = 121; i <= 240; i++) run.tick((double)i * (1000.0 / 60.0));

		three::RunResult fell = run.run("return globalThis.ball.position.y;");
		defer fell.free();
		test::@check(fell.ok, "read the ball back: %s", fell.error);
		double y = fell.value.to_double() ?? 999.0;
		test::@check(y < 1.0, "and now it falls on a floor that was already there, y = %s", fell.value);
		test::@check(y > 0.0, "rather than through it, y = %s", fell.value);
	};
}

<*
 Disposing a scene gives its bodies back.

 **The regression this exists for is a collider per body left on the heap.** A
 `PhysicsBody` owns one allocation that nothing else points at, and the scene is
 the only thing that knows the world exists — so a `Scene.free` that forgot
 `physics.close()` would leak one per body with nothing to notice. The assertion
 is the leak checker the `-D DEBUG` suite runs, not a number here.

 Proved by injection: drop `self.physics.close()` from `Scene.free` and the run
 reports the colliders and the world's own lists as leaked.
*>
fn void disposing_a_scene_gives_its_bodies_back() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const doomed = new three.Scene();
			for (let i = 0; i < 8; i++) {
				const box = new three.Mesh(new three.BoxGeometry(1, 1, 1));
				box.position.set(i * 2, 4, 0);
				doomed.add(box);
				doomed.physics.add(box, { shape: 'box', mass: 1 });
			}
			const had = doomed.physics.count;

			const after = new three.Scene();
			doomed.dispose();
			return [had, after.stats().scenes, three.physics.count];
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		// Eight bodies gone with their scene, one scene left, and the new one has
		// a world of its own with nothing in it.
		test::@check(result.value == "[8,1,0]",
			"the bodies went with the scene; got %s", result.value);
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
 A vertex no triangle uses does not become a particle.

 A mesh's position array may carry a point its index buffer never names —
 `SphereGeometry` emits one at a pole, whose degenerate cap triangle is dropped.
 Welded into a particle it is an ORPHAN: no triangle means no edge, so no
 distance constraint, no volume gradient and no contact reaches it. It is then
 the one thing in the body still in free fall while the rest of it rests on the
 floor, and it falls forever — measured at y = -132 under a blob sitting on the
 ground, drawn as a spike hanging through the floor and dragging the body's
 bounds and centre down with it.

 The whole-body checks miss this by construction: the mesh looks right, the node
 is in the right place, and `evict_diverged` is about a body that has left, not
 about one particle in a body that has not. So this reads the particles.
*>
fn void no_particle_is_left_out_of_the_mesh() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult built = run.run(`
			const scene = new three.Scene();
			const floor = new three.Mesh(new three.BoxGeometry(20, 1, 20));
			floor.position.y = -0.5;                 // its top face is y = 0
			scene.add(floor);
			three.physics.add(floor, { shape: 'box', mass: 0 });

			// A UV sphere, which is the shape that has the stray pole vertex.
			const blob = new three.Mesh(new three.SphereGeometry(1.2, 20, 14));
			blob.position.set(0, 3, 0);
			scene.add(blob);
			three.physics.soft(blob, { mass: 1.5, volume: true });
			globalThis.blob = blob;

			globalThis.below = () => {
				const p = three.physics.points(globalThis.blob);
				let n = 0, lowest = Infinity;
				for (let i = 1; i < p.length; i += 3) {
					lowest = Math.min(lowest, p[i]);
					if (p[i] < -0.5) n++;
				}
				return { n: n, lowest: lowest };
			};
			return 1;
		`);
		defer built.free();
		test::@check(built.ok, "the scene built: %s", built.error);

		// Long enough to land and then sit there: an orphan keeps going, so the
		// longer this runs the further out of the body it is.
		for (int i = 1; i <= 400; i++) run.tick((double)i * (1000.0 / 60.0));

		three::RunResult after = run.run(`
			const r = globalThis.below();
			return { escaped: r.n, sane: r.lowest > -0.5, lowest: r.lowest };
		`);
		defer after.free();
		test::@check(after.ok, "read the particles back: %s", after.error);
		test::@check(
			after.value.contains(`"escaped":0`) && after.value.contains(`"sane":true`),
			"a particle went through the floor and kept going: %s", after.value
		);
	};
}

<*
 A soft body actually STOPS on a rigid one.

 `a_soft_body_falls_and_lands_in_one_piece` asserts `y > 0` after 180 frames from
 a start of 5, and a soft body descends at about a unit a second — so it was
 still in the air when that test read it and the landing was never exercised. It
 stayed green while a jelly fell straight through the floor and kept going.

 What was wrong is in `generate_rigidbody_collisions`: the projection test picked
 the vertices that were already CLEAR of the body rather than the ones inside it,
 and the constraints it made were no-ops besides — `solve_collision_constraint`
 measures d = (p - contact_point) . normal and returns on `d >= 0`, which is
 every constraint that selection could produce. Twelve contacts a frame, none of
 them pushing.

 Started close and given long enough to settle, so this is about the contact and
 not about how fast a soft body falls.
*>
fn void a_soft_body_stops_on_a_rigid_floor() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult built = run.run(`
			const scene = new three.Scene();
			const floor = new three.Mesh(new three.BoxGeometry(20, 1, 20));
			floor.position.y = -0.5;                 // its top face is y = 0
			scene.add(floor);
			three.physics.add(floor, { shape: 'box', mass: 0 });

			const jelly = new three.Mesh(new three.BoxGeometry(2, 2, 2));
			jelly.position.set(0, 1.6, 0);
			scene.add(jelly);
			three.physics.soft(jelly, { mass: 2, volume: true });
			globalThis.jelly = jelly;
			return 1;
		`);
		defer built.free();
		test::@check(built.ok, "the scene built: %s", built.error);

		for (int i = 1; i <= 300; i++) run.tick((double)i * (1000.0 / 60.0));

		three::RunResult rest = run.run(`
			const y = globalThis.jelly.position.y;
			// A two-unit cube resting on y = 0 has its centre at 1. Loose on the
			// low side because it squashes, but it must not be under the floor.
			return { y: y, onTop: y > 0.6, sunk: y < -0.1 };
		`);
		defer rest.free();
		test::@check(rest.ok, "read the jelly back: %s", rest.error);
		test::@check(rest.value.contains(`"onTop":true`) && rest.value.contains(`"sunk":false`),
			"the jelly did not come to rest on the floor: %s", rest.value);
	};
}

<*
 A pressurised soft body that is touching nothing still steps.

 `solve_soft_bodies` PARTITIONS: a soft body whose collision constraints name a
 rigidbody mutates that body while solving, so it runs sequentially on the main
 thread — and one touching nothing is handed to the worker pool. The volume
 solver builds a per-particle gradient buffer, and a C3 list that has not been
 given an allocator seats itself on the *temp* allocator on its first push. A
 worker thread has none, so the process aborted inside the solver:

     Use '@pool_init()' to enable the temp allocator on a new thread
       in collision.SoftBody.solve_volume_constraint

 Every soft-body test before this one dropped its jelly straight onto a rigid
 floor, which is the coupled path and the main thread — so the whole suite was
 green and any scene with a balloon still falling through the air took the
 process down. The distinguishing detail is the AIR: this one must not touch the
 floor within the frames it runs.
*>
fn void a_pressurised_soft_body_falls_untouched_without_crashing() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult built = run.run(`
			const scene = new three.Scene();
			const floor = new three.Mesh(new three.BoxGeometry(20, 1, 20));
			floor.position.y = -0.5;
			scene.add(floor);
			three.physics.add(floor, { shape: 'box', mass: 0 });

			// Three of them, high up and far enough apart to touch neither the
			// floor nor each other: uncoupled, which is the worker-thread path.
			globalThis.balloons = [];
			for (let i = 0; i < 3; i++) {
				const b = new three.Mesh(new three.SphereGeometry(1, 16, 10));
				b.position.set(i * 4 - 4, 30, 0);
				scene.add(b);
				three.physics.soft(b, { mass: 1.5, volume: true, bending: true });
				globalThis.balloons.push(b);
			}
			return globalThis.balloons.length;
		`);
		defer built.free();
		test::@check(built.ok, "the scene built: %s", built.error);

		// Half a second, all of it in the air — thirty units up at 9.8 m/s²
		// falls about 1.2, so nothing has reached the floor.
		for (int i = 1; i <= 30; i++) run.tick((double)i * (1000.0 / 60.0));

		three::RunResult fell = run.run(`
			const y = globalThis.balloons.map(b => b.position.y);
			return { falling: y.every(v => v < 29.9 && v > 27), n: y.length };
		`);
		defer fell.free();
		test::@check(fell.ok, "the reading script succeeded: %s", fell.error);
		test::@check(fell.value.contains(`"falling":true`),
			"the balloons did not fall as three untouched bodies: %s", fell.value);
	};
}

<*
 A falling body is a reason to keep drawing.

 `main.c3` parks the window in `getEvent(wait: true)` whenever the last frame is
 still on screen and nothing is known to want another one. `is_animating` covers
 a callback, a handler and a playing clip — and a scene with physics and no
 `setAnimationLoop` is none of those, so the sleep condition was true while the
 world was still falling and the simulation advanced only while the mouse moved.

 The second half is the half that makes it a condition rather than a switch: once
 everything has settled the window is *supposed* to sleep, so this has to go
 false again on its own.
*>
fn void a_falling_body_keeps_the_window_awake() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		test::@check(!run.is_simulating(), "an empty runtime already had something to step");

		three::RunResult built = run.run(`
			const scene = new three.Scene();
			const floor = new three.Mesh(new three.BoxGeometry(60, 1, 60));
			floor.position.y = -0.5;
			scene.add(floor);
			three.physics.add(floor, { shape: 'box', mass: 0 });

			const ball = new three.Mesh(new three.SphereGeometry(0.5, 16, 8));
			ball.position.set(0, 8, 0);
			scene.add(ball);
			three.physics.add(ball, { shape: 'sphere', mass: 1 });
			return 1;
		`);
		defer built.free();
		test::@check(built.ok, "the scene built: %s", built.error);

		// Nothing is registered, so the runtime says it is not animating. That is
		// the exact state the sleep condition used to read as "nothing to do".
		test::@check(!run.is_animating(), "something registered a callback");
		test::@check(run.is_simulating(), "a ball eight units up was not worth a frame");

		int i = 1;
		for (; i <= 30; i++) run.tick((double)i * (1000.0 / 60.0));
		test::@check(run.is_simulating(), "the ball stopped being worth a frame mid-fall");

		// Four seconds, which is eight times the half-second sleep timer.
		for (; i <= 240; i++) run.tick((double)i * (1000.0 / 60.0));
		test::@check(!run.is_simulating(), "a settled scene still refuses to let the window sleep");
	};
}

// A static body never moves, so a world made only of them is not a reason to
// spend a frame — the sleep condition asks what is being integrated, not what
// exists.
fn void a_world_of_static_bodies_lets_the_window_sleep() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult built = run.run(`
			const scene = new three.Scene();
			for (let i = 0; i < 4; i++) {
				const m = new three.Mesh(new three.BoxGeometry(2, 2, 2));
				m.position.set(i * 3, 1, 0);
				scene.add(m);
				three.physics.add(m, { shape: 'box', mass: 0 });
			}
			return 1;
		`);
		defer built.free();
		test::@check(built.ok, "the scene built: %s", built.error);

		test::@check(!run.is_simulating(), "four static boxes wanted the CPU");
		for (int i = 1; i <= 10; i++) run.tick((double)i * (1000.0 / 60.0));
		test::@check(!run.is_simulating(), "and still wanted it ten frames later");
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

 **Proved by injection.** Deleting the two lines of `Physics.wake` makes this
 go red at the last check with `x = -0.002877` — the impulse landed in a
 velocity nothing integrates. That is the state any binding that wrote
 `linear_velocity` and stopped there would create on its very first push, so
 the wake is a correctness requirement of the library and not a courtesy of
 this API.

 **That injection used to hang the suite instead, and the reason is worth
 keeping**, because it is a trap any check in this file can still spring. A
 failed `test::@check` `longjmp`s to the runner, which unwinds past every
 `defer` — so `@with_gpu_js`'s `defer runtime.close()` never ran, the physics
 world was never freed, and its worker thread stayed parked on a mutex in this
 test's abandoned stack frame. The next physics test built its world in that
 same frame and initialized a new pool over the sleeping worker's bytes, and
 `join()` then waited on a queue two workers were draining. It was read for a
 while as the solver's island bookkeeping failing on a sleeping body carrying
 velocity; it was neither about sleep nor about islands. `collision.c3l` now
 keeps the pool's state in a heap block the workers own, so an abandoned world
 leaks a thread instead of capturing the next one — see
 `collision_tests::pool::an_abandoned_pool_does_not_capture_the_next_one`.
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

<*
 A body the solver moved is drawn where the solver put it.

 **The one thing every check above this takes for granted.** They all read a
 body's position back through `three.physics` or through the object's own
 `position`, both of which answer from the solver — so a solver that moved a body
 and never told the *scene graph* would pass all of them and render a ball
 hanging in the air where it was dropped.

 `getWorldPosition()` is the only reader in the API that goes through
 `Node.world`, which is the matrix the draw list copies into the instance record.
 That makes it the check: the ball's world position has to have fallen, and it
 has to agree with what the solver says.

 **Proved by injection.** `Physics.write_back` reverted to writing `node.dirty`
 directly instead of calling `Scene.mark_moved`, which is what it did before
 `plan.md` §19.5 gave the world-matrix walk the right to skip itself: "the ball
 was drawn where it was dropped, world y = 6" while `ball.position.y`
 still reads where the solver put it. Nothing else in this file moves.
*>
fn void a_body_the_solver_moved_is_drawn_where_it_landed() @test
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
			return ball.getWorldPosition().y;
		`);
		defer built.free();
		test::@check(built.ok, "the scene built: %s", built.error);
		test::@check((built.value.to_double() ?? 0.0) > 5.0, "the ball starts high, y = %s", built.value);

		for (int i = 1; i <= 120; i++) run.tick((double)i * (1000.0 / 60.0));

		three::RunResult world = run.run("return globalThis.ball.getWorldPosition().y;");
		defer world.free();
		test::@check(world.ok, "read the ball back: %s", world.error);
		double drawn = world.value.to_double() ?? 999.0;

		test::@check(
			drawn < 1.0,
			"the ball was drawn where it was dropped, world y = %s", world.value
		);

		three::RunResult solver = run.run("return globalThis.ball.position.y;");
		defer solver.free();
		double told = solver.value.to_double() ?? -999.0;
		test::@check(
			math::abs(drawn - told) < 0.001,
			"and the graph agrees with the solver: drawn %s against %s", world.value, solver.value
		);
	};
}

// §20.4. A terrain collider is the grid the geometry was built from, so a body
// rests on the same surface `terrain.heightAt(x, z)` reports — at any slope,
// with one collider.
//
// **The slope is the whole test.** Before `ShapeType.HEIGHTFIELD` the shape
// reported CONVEX and its support function answered with one of the four corners
// of the whole map, so GJK settled every body onto the plane through them: the
// terrain, flattened, with nothing anywhere reporting an error. On a flat map
// that failure is invisible, which is why this one is a ramp.
fn void a_body_rests_on_terrain_and_not_on_its_corners() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult built = run.run(`
			const scene = new three.Scene();
			// Rises 0.3 per unit of x, so the ground under the ball is 6 units
			// above the ground at the low edge — a difference no plane through
			// the map's corners can be confused with.
			const terrain = new three.TerrainGeometry({
				width: 60, depth: 60, segments: 48, heights: (x, z) => 0.3 * x,
			});
			const ground = new three.Mesh(terrain);
			scene.add(ground);
			three.physics.add(ground, { shape: 'heightfield', mass: 0, friction: 0.9 });

			const ball = new three.Mesh(new three.SphereGeometry(0.5, 16, 8));
			ball.position.set(10, 12, -4);
			scene.add(ball);
			three.physics.add(ball, { shape: 'sphere', mass: 1, friction: 0.9 });

			globalThis.ball = ball;
			globalThis.terrain = terrain;
			return three.physics.count;
		`);
		defer built.free();
		test::@check(built.ok, "the scene built: %s", built.error);
		test::@check(built.value == "2", "two bodies, got '%s'", built.value);

		for (int i = 1; i <= 180; i++) run.tick((double)i * (1000.0 / 60.0));

		// The gap rather than the two numbers, because a script's *string* comes
		// back quoted and a number does not — and what is being asserted is the
		// difference in any case.
		three::RunResult after = run.run(
			"const g = globalThis.terrain.heightAt(ball.position.x, ball.position.z);"
			"return ball.position.y - g;"
		);
		defer after.free();
		test::@check(after.ok, "read the ball back: %s", after.error);

		// On the ground it is actually standing on, within its own radius and a
		// slope's worth of slack. A body on the flattened plane is metres away
		// from this, and one that fell through is metres below.
		double gap = after.value.to_double() ?? 999.0;
		test::@check(gap > 0.2 && gap < 1.2, "rests on the slope, gap = %s", after.value);

		// And it is somewhere on the slope rather than still in the air at the
		// height it was dropped from.
		three::RunResult height = run.run("return globalThis.ball.position.y;");
		defer height.free();
		double y = height.value.to_double() ?? 999.0;
		test::@check(y < 11.0, "it fell, y = %s", height.value);
	};
}

// The same collider asked for on a mesh that has no grid. Refused by name, with
// the fix in the message — approximating one would be a collider that looks
// right and behaves wrongly, which is the failure this whole item is about.
fn void a_heightfield_collider_needs_a_terrain() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult tried = run.run(`
			const scene = new three.Scene();
			const box = new three.Mesh(new three.BoxGeometry(2, 2, 2));
			scene.add(box);
			try {
				three.physics.add(box, { shape: 'heightfield', mass: 0 });
				return 'accepted';
			} catch (e) {
				return String(e.message || e);
			}
		`);
		defer tried.free();
		test::@check(tried.ok, "the script ran: %s", tried.error);
		test::@check(tried.value != "accepted", "a box was accepted as terrain");
		test::@check(
			tried.value.contains("TerrainGeometry"),
			"and the message names the fix, got '%s'", tried.value
		);
	};
}

// §20.2's first item, at the surface a script sees it. The views themselves are
// a branch in the shading pass and what they draw is checked by looking; what
// can break silently is the property — a name that quietly did nothing would be
// a diagnostic that reported "no shadows here" for every scene.
fn void the_debug_view_is_selected_by_name() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult checked = run.run(`
			const seen = [];
			seen.push(three.debug.view);
			three.debug.view = 'shadow';
			seen.push(three.debug.view);
			three.debug.view = 'shadowMap';
			seen.push(three.debug.view);

			// A typo is the whole failure mode of a string enum, and it says so
			// rather than quietly drawing the scene.
			let refused = 'accepted';
			try { three.debug.view = 'shadwo'; } catch (e) { refused = 'refused'; }
			seen.push(refused);
			seen.push(three.debug.view);

			// **Not scene state.** A script rebuilding the world is not a reason
			// to switch off a diagnostic somebody is reading, and rebuilding the
			// world is what the caller here does between looks.
			new three.Scene();
			seen.push(three.debug.view);

			three.debug.view = 'off';
			seen.push(three.debug.view);
			return seen.join(',');
		`);
		defer checked.free();
		test::@check(checked.ok, "the script ran: %s", checked.error);
		test::@check(
			checked.value.contains("off,shadow,shadowMap,refused,shadowMap,shadowMap,off"),
			"got %s", checked.value
		);
	};
}

// ---------------------------------------------------------------------------
// Joints — `plan.md` §7.

<*
 A point joint holds two bodies together while they fall.

 The floor is deliberately absent: what is being measured is the constraint and
 not the contact, so both bodies fall freely and the only thing that can keep
 them the same distance apart is the joint.
*>
fn void a_point_joint_keeps_two_bodies_together() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult built = run.run(`
			const scene = new three.Scene();

			const anchor = new three.Mesh(new three.BoxGeometry(1, 1, 1));
			anchor.position.set(0, 8, 0);
			scene.add(anchor);
			three.physics.add(anchor, { shape: 'box', mass: 1 });

			const hanging = new three.Mesh(new three.BoxGeometry(1, 1, 1));
			hanging.position.set(2, 8, 0);
			scene.add(hanging);
			three.physics.add(hanging, { shape: 'box', mass: 1 });

			globalThis.a = anchor;
			globalThis.b = hanging;
			globalThis.id = three.physics.joint(anchor, hanging, { type: 'point' });
			return typeof globalThis.id;
		`);
		defer built.free();
		test::@check(built.ok, "the joint was made: %s", built.error);
		test::@check(built.value == "\"number\"", "joint() answers with an id, got '%s'", built.value);

		for (int i = 1; i <= 120; i++) run.tick((double)i * (1000.0 / 60.0));

		three::RunResult after = run.run(`
			const gap = Math.hypot(
				globalThis.a.position.x - globalThis.b.position.x,
				globalThis.a.position.y - globalThis.b.position.y,
				globalThis.a.position.z - globalThis.b.position.z);
			return [gap.toFixed(2), globalThis.a.position.y < 0];
		`);
		defer after.free();
		test::@check(after.ok, "read the pair back: %s", after.error);
		// Pinned at the midpoint, so the two centres are held one unit apart
		// each side of it — the same two units they started at.
		test::@check(
			after.value == "[\"2.00\",true]",
			"the pair fell together and kept its spacing, got '%s'", after.value
		);
	};
}

<*
 A hinge onto a static body holds position and gives up rotation.

 The door swings and stays on its frame. Both halves matter: a joint that held
 nothing would let it fall, and a joint that locked everything would be a weld.
*>
fn void a_hinge_swings_and_stays_attached() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult built = run.run(`
			const scene = new three.Scene();

			const frame = new three.Mesh(new three.BoxGeometry(0.4, 4, 0.4));
			frame.position.set(0, 2, 0);
			scene.add(frame);
			three.physics.add(frame, { shape: 'box', mass: 0 });

			const door = new three.Mesh(new three.BoxGeometry(2, 4, 0.2));
			door.position.set(1.2, 2, 0);
			scene.add(door);
			three.physics.add(door, { shape: 'box', mass: 1 });

			globalThis.door = door;
			globalThis.start = [door.position.x, door.position.y, door.position.z];
			// About world Y, at the frame's own centre line.
			three.physics.joint(frame, door, { type: 'hinge', axis: [0, 1, 0], pivot: [0, 2, 0] });
			// A shove along Z, which a hinge about Y is free to answer with a turn.
			three.physics.applyImpulse(door, [0, 0, 6], [1, 0, 0]);
			return three.physics.count;
		`);
		defer built.free();
		test::@check(built.ok, "the door was hung: %s", built.error);

		// A sixth of a second, and the shortness is deliberate: the door is free
		// about its axle, so it goes on turning and a longer run would be asking
		// where in the circle it happened to stop.
		for (int i = 1; i <= 10; i++) run.tick((double)i * (1000.0 / 60.0));

		three::RunResult after = run.run(`
			const p = globalThis.door.position;
			// How far the door's centre is from the hinge line, which the
			// joint holds however far it has swung.
			const reach = Math.hypot(p.x, p.z);
			return [reach.toFixed(1), Math.abs(p.y - 2) < 0.2, Math.abs(p.z) > 0.5];
		`);
		defer after.free();
		test::@check(after.ok, "read the door back: %s", after.error);
		test::@check(
			after.value == "[\"1.2\",true,true]",
			"the door swung about the hinge and stayed on it, got '%s'", after.value
		);
	};
}

<*
 A joint between two immovable bodies is refused, and each other refusal has its
 own sentence.
*>
fn void a_joint_says_what_it_will_not_hold() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult said = run.run(`
			const scene = new three.Scene();
			const wall = new three.Mesh(new three.BoxGeometry(1, 1, 1));
			scene.add(wall);
			three.physics.add(wall, { shape: 'box', mass: 0 });

			const post = new three.Mesh(new three.BoxGeometry(1, 1, 1));
			post.position.x = 2;
			scene.add(post);
			three.physics.add(post, { shape: 'box', mass: 0 });

			const bare = new three.Mesh(new three.BoxGeometry(1, 1, 1));
			bare.position.x = 4;
			scene.add(bare);

			const said = [];
			const tell = fn => { try { fn(); said.push('no throw'); } catch (e) { said.push(e.message); } };

			tell(() => three.physics.joint(wall, post, { type: 'fixed' }));
			tell(() => three.physics.joint(wall, bare, { type: 'fixed' }));
			tell(() => three.physics.joint(wall, wall, { type: 'fixed' }));
			tell(() => three.physics.joint(wall, post, { type: 'welded' }));
			tell(() => three.physics.joint(wall, post, { type: 'hinge', range: [0, 0] }));
			return said.map(s => s.slice(0, 28));
		`);
		defer said.free();
		test::@check(said.ok, "the refusals were collected: %s", said.error);
		test::@check(
			said.value == "[\"neither end of this joint ca\",\"a joint holds two bodies tog\","
				"\"a joint needs two different \",\"'welded' is not a joint type\","
				"\"a range of [0, 0] would LOCK\"]",
			"each refusal says what it is, got '%s'", said.value
		);
	};
}

<*
 Removing a joint lets go, and removing a body takes its joints with it.

 The second half is the one that could take the process down rather than merely
 misbehave: the world prunes its own copy of a joint when a body goes, and a
 rebuild that put ours back would hand the solver a body id that resolves to
 nothing.
*>
fn void a_joint_goes_when_it_is_removed_or_its_body_does() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult built = run.run(`
			const scene = new three.Scene();
			const hook = new three.Mesh(new three.BoxGeometry(1, 1, 1));
			hook.position.set(0, 8, 0);
			scene.add(hook);
			three.physics.add(hook, { shape: 'box', mass: 0 });

			const make = (x) => {
				const m = new three.Mesh(new three.BoxGeometry(1, 1, 1));
				m.position.set(x, 6, 0);
				scene.add(m);
				three.physics.add(m, { shape: 'box', mass: 1 });
				return m;
			};

			globalThis.cut = make(0);
			globalThis.orphan = make(3);
			globalThis.kept = make(-3);

			globalThis.cutId = three.physics.joint(hook, globalThis.cut, { type: 'point' });
			three.physics.joint(hook, globalThis.orphan, { type: 'point' });
			three.physics.joint(hook, globalThis.kept, { type: 'point' });

			return [three.physics.removeJoint(globalThis.cutId), three.physics.removeJoint(globalThis.cutId)];
		`);
		defer built.free();
		test::@check(built.ok, "the joints were made: %s", built.error);
		test::@check(built.value == "[true,false]", "removing twice is not an error, got '%s'", built.value);

		run.tick(1000.0 / 60.0);

		three::RunResult cut = run.run("three.physics.remove(globalThis.orphan); return true;");
		defer cut.free();
		test::@check(cut.ok, "the second body was removed: %s", cut.error);

		for (int i = 2; i <= 120; i++) run.tick((double)i * (1000.0 / 60.0));

		three::RunResult after = run.run(`
			return [globalThis.cut.position.y < 2, globalThis.kept.position.y > 4];
		`);
		defer after.free();
		test::@check(after.ok, "read the three back: %s", after.error);
		test::@check(
			after.value == "[true,true]",
			"the cut one fell and the kept one is still hanging, got '%s'", after.value
		);
	};
}

<*
 A hinge written out as limits and a hinge asked for by name are the same joint.

 The shorthand is expanded in `prelude/physics.js` and nothing below it knows
 what a hinge is, so this is the check that keeps the two from drifting: two
 doors, one of each, given the same shove and landing in the same place.

 It is also the check that says the generic form is complete. If `limits` could
 not say what `type: 'hinge'` says, the four words would be the API and the list
 would be decoration.
*>
fn void a_hinge_by_name_and_a_hinge_by_limits_agree() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult built = run.run(`
			const scene = new three.Scene();

			const hang = (x, options) => {
				const post = new three.Mesh(new three.BoxGeometry(0.4, 4, 0.4));
				post.position.set(x, 2, 0);
				scene.add(post);
				three.physics.add(post, { shape: 'box', mass: 0 });

				const door = new three.Mesh(new three.BoxGeometry(2, 4, 0.2));
				door.position.set(x + 1.2, 2, 0);
				scene.add(door);
				three.physics.add(door, { shape: 'box', mass: 1 });

				three.physics.joint(post, door, Object.assign({ axis: [0, 1, 0], pivot: [x, 2, 0] }, options));
				three.physics.applyImpulse(door, [0, 0, 4], [1, 0, 0]);
				return door;
			};

			globalThis.named = hang(-8, { type: 'hinge' });
			// The same thing, said in glTF's terms: pinned, no twist and no tilt,
			// and axis 0 — the axle — left out of the angular list entirely.
			globalThis.spelled = hang(8, {
				limits: [
					{ linearAxes: [0, 1, 2] },
					{ angularAxes: [1, 2] },
				],
			});
			return true;
		`);
		defer built.free();
		test::@check(built.ok, "both doors were hung: %s", built.error);

		for (int i = 1; i <= 10; i++) run.tick((double)i * (1000.0 / 60.0));

		three::RunResult after = run.run(`
			// Each door's offset from its own post, which is the only thing that
			// can be compared between two of them eight units apart.
			const local = (door, x) => [door.position.x - x, door.position.y, door.position.z];
			const a = local(globalThis.named, -8);
			const b = local(globalThis.spelled, 8);
			return a.map((n, i) => Math.abs(n - b[i]) < 1e-3);
		`);
		defer after.free();
		test::@check(after.ok, "read both doors back: %s", after.error);
		test::@check(
			after.value == "[true,true,true]",
			"the two hinges swung to the same place, got '%s'", after.value
		);
	};
}

<*
 A limit carries its own range and its own stiffness, and both are felt.

 Two doors given the same shove, hinged with the same stop, differing only in
 whether that stop is a wall or a spring. Three facts come out of it: the range
 holds at all — a free hinge sampled over two seconds reaches pi and these do not
 — a rigid stop holds close to where it was set, and a soft one gives.

 **`stiffness` is a spring constant, not a compliance**, and 0 is the rigid end
 rather than the soft one. The solver reads it as `(1 / stiffness) / dt²`
 (`solver/joint.c3`), so bigger is stiffer and 0 is special-cased to no give at
 all — which is why 800 below is loose and 0 is a wall.
*>
fn void a_limit_carries_its_own_range_and_stiffness() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult built = run.run(`
			const scene = new three.Scene();

			const hang = (x, stiffness) => {
				const post = new three.Mesh(new three.BoxGeometry(0.4, 4, 0.4));
				post.position.set(x, 2, 0);
				scene.add(post);
				three.physics.add(post, { shape: 'box', mass: 0 });

				const door = new three.Mesh(new three.BoxGeometry(2, 4, 0.2));
				door.position.set(x + 1.2, 2, 0);
				scene.add(door);
				three.physics.add(door, { shape: 'box', mass: 1 });

				three.physics.joint(post, door, {
					axis: [0, 1, 0],
					pivot: [x, 2, 0],
					limits: [
						{ linearAxes: [0, 1, 2] },
						{ angularAxes: [1, 2] },
						{ angularAxes: [0], min: -0.6, max: 0.6, stiffness },
					],
				});
				// Hard enough to spin a free hinge several times round.
				three.physics.applyImpulse(door, [0, 0, 12], [1, 0, 0]);
				return { door, x, peak: 0 };
			};

			globalThis.stopped = hang(-8, 0);
			globalThis.sprung = hang(8, 800);

			// Every frame, not just the last one: a hinge sampled once has a fair
			// chance of being caught near its start whatever it did in between, so
			// what is measured is the furthest each one ever got.
			three.setAnimationLoop(() => {
				for (const it of [globalThis.stopped, globalThis.sprung]) {
					const p = it.door.position;
					it.peak = Math.max(it.peak, Math.abs(Math.atan2(p.z, p.x - it.x)));
				}
			});
			return true;
		`);
		defer built.free();
		test::@check(built.ok, "both doors were hung: %s", built.error);

		for (int i = 1; i <= 120; i++) run.tick((double)i * (1000.0 / 60.0));

		three::RunResult after = run.run(`
			const stopped = globalThis.stopped.peak;
			const sprung = globalThis.sprung.peak;
			return [
				stopped < 0.9,          // held near the 0.6 it was given
				sprung > stopped,       // the spring let it past
				sprung < 2.0,           // and still nothing like a free hinge's pi
			];
		`);
		defer after.free();
		test::@check(after.ok, "read both doors back: %s", after.error);
		test::@check(
			after.value == "[true,true,true]",
			"the stop held, the spring gave, and neither spun, got '%s'", after.value
		);
	};
}

// ---------------------------------------------------------------------------
// Soft bodies — `plan.md` §7.

<*
 A soft body falls, lands on the floor and is still one object.

 The last clause is the whole test. The particles have to stay a shape: a soft
 body whose links did not hold would land as a puddle of loose points, and the
 spread of the particles is what says which happened.
*>
fn void a_soft_body_falls_and_lands_in_one_piece() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult built = run.run(`
			const scene = new three.Scene();
			const floor = new three.Mesh(new three.BoxGeometry(20, 1, 20));
			floor.position.y = -0.5;
			scene.add(floor);
			three.physics.add(floor, { shape: 'box', mass: 0 });

			const jelly = new three.Mesh(new three.SphereGeometry(1, 12, 8));
			jelly.position.set(0, 5, 0);
			scene.add(jelly);
			three.physics.soft(jelly, { mass: 2 });

			globalThis.jelly = jelly;
			globalThis.spread = () => {
				const p = three.physics.points(jelly);
				let lo = Infinity, hi = -Infinity;
				for (let i = 0; i < p.length; i += 3) { lo = Math.min(lo, p[i]); hi = Math.max(hi, p[i]); }
				return hi - lo;
			};
			globalThis.wide = globalThis.spread();
			return [three.physics.softCount(jelly) > 0, Math.abs(jelly.position.y - 5) < 0.3];
		`);
		defer built.free();
		test::@check(built.ok, "the jelly was made: %s", built.error);
		// Near where it was placed rather than exactly on it: the node sits at the
		// PARTICLES' average, and a sphere's vertices are not spread evenly through
		// the volume they enclose.
		test::@check(built.value == "[true,true]", "it starts where it was put, got '%s'", built.value);

		for (int i = 1; i <= 180; i++) run.tick((double)i * (1000.0 / 60.0));

		three::RunResult after = run.run(`
			const y = globalThis.jelly.position.y;
			const now = globalThis.spread();
			return [y < 4, y > 0, (now / globalThis.wide) < 2];
		`);
		defer after.free();
		test::@check(after.ok, "read the jelly back: %s", after.error);
		test::@check(
			after.value == "[true,true,true]",
			"it fell, stopped on the floor and stayed one shape, got '%s'", after.value
		);
	};
}

<*
 A box's twenty-four vertices are eight particles.

 The weld, stated as the number it produces. Without it a soft `BoxGeometry` is
 six squares that fall away from each other, because a box that shades with hard
 edges shares no vertex between two faces and the links are taken from the
 triangles.
*>
fn void a_soft_box_welds_its_corners() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult built = run.run(`
			const scene = new three.Scene();
			const cube = new three.Mesh(new three.BoxGeometry(1, 1, 1));
			cube.position.set(0, 4, 0);
			scene.add(cube);
			three.physics.soft(cube, { mass: 1 });
			globalThis.cube = cube;
			return three.physics.softCount(cube);
		`);
		defer built.free();
		test::@check(built.ok, "the cube was made soft: %s", built.error);
		test::@check(built.value == "8", "a box is eight particles, got '%s'", built.value);

		// And it holds together in free fall: eight loose particles would keep the
		// spacing gravity gives them, six loose faces would not.
		for (int i = 1; i <= 60; i++) run.tick((double)i * (1000.0 / 60.0));

		three::RunResult after = run.run(`
			const p = three.physics.points(globalThis.cube);
			let lo = Infinity, hi = -Infinity;
			for (let i = 0; i < p.length; i += 3) { lo = Math.min(lo, p[i]); hi = Math.max(hi, p[i]); }
			return (hi - lo).toFixed(1);
		`);
		defer after.free();
		test::@check(after.ok, "read the cube back: %s", after.error);
		test::@check(after.value == "\"1.0\"", "the cube is still a cube, got '%s'", after.value);
	};
}

<*
 A pinned particle holds the body up, and letting it go drops it.
*>
fn void a_pin_holds_a_soft_body_where_it_is_put() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult built = run.run(`
			const scene = new three.Scene();
			const cloth = new three.Mesh(new three.PlaneGeometry(2, 2, 6, 6));
			cloth.position.set(0, 6, 0);
			scene.add(cloth);
			three.physics.soft(cloth, { mass: 1 });

			// The two highest particles, which for a plane standing in XY are its
			// top edge corners.
			const p = three.physics.points(cloth);
			let top = -Infinity;
			for (let i = 1; i < p.length; i += 3) top = Math.max(top, p[i]);
			globalThis.pins = [];
			for (let i = 0; i < p.length / 3; i++) {
				if (p[i * 3 + 1] > top - 0.01) globalThis.pins.push(i);
			}
			for (const i of globalThis.pins) three.physics.pin(cloth, i);

			globalThis.cloth = cloth;
			return globalThis.pins.length > 0;
		`);
		defer built.free();
		test::@check(built.ok, "the cloth was pinned: %s", built.error);
		test::@check(built.value == "true", "something was pinned, got '%s'", built.value);

		for (int i = 1; i <= 180; i++) run.tick((double)i * (1000.0 / 60.0));

		three::RunResult hanging = run.run("return globalThis.cloth.position.y > 3;");
		defer hanging.free();
		test::@check(hanging.ok, "read the cloth back: %s", hanging.error);
		test::@check(hanging.value == "true", "the pins are holding it up, got '%s'", hanging.value);

		three::RunResult freed = run.run(`
			for (const i of globalThis.pins) three.physics.unpin(globalThis.cloth, i);
			return true;
		`);
		defer freed.free();
		test::@check(freed.ok, "the pins were let go: %s", freed.error);

		for (int i = 181; i <= 400; i++) run.tick((double)i * (1000.0 / 60.0));

		three::RunResult fell = run.run("return globalThis.cloth.position.y < 0;");
		defer fell.free();
		test::@check(fell.ok, "read the cloth back again: %s", fell.error);
		test::@check(fell.value == "true", "letting go drops it, got '%s'", fell.value);
	};
}

<*
 A soft body's transform is the solver's, and the refusal says so in its own
 words rather than a rigid body's.
*>
fn void the_solver_refuses_a_write_to_a_soft_body() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult said = run.run(`
			const scene = new three.Scene();
			const jelly = new three.Mesh(new three.SphereGeometry(1, 8, 6));
			scene.add(jelly);
			three.physics.soft(jelly, { mass: 1 });

			let message = 'no throw';
			try { jelly.position.y = 4; } catch (e) { message = e.message; }
			three.physics.removeSoft(jelly);
			jelly.position.y = 4;
			return [message.slice(0, 34), jelly.position.y];
		`);
		defer said.free();
		test::@check(said.ok, "the write was refused: %s", said.error);
		test::@check(
			said.value == "[\"this object's transform belongs to\",4]",
			"the soft body owns its transform until it is removed, got '%s'", said.value
		);
	};
}

<*
 A soft body is drawn, and it is drawn on its own.

 Two copies of one mesh are one draw call; two soft copies are two, because each
 one is writing its own vertices. That is the exception to the thesis this whole
 feature buys, and it is worth a number rather than a paragraph.
*>
fn void two_soft_copies_of_one_mesh_are_two_draws() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult counted = run.run(`
			const scene = new three.Scene();
			const geometry = new three.SphereGeometry(1, 8, 6);

			const a = new three.Mesh(geometry);
			a.position.set(-2, 3, 0);
			scene.add(a);
			const b = new three.Mesh(geometry);
			b.position.set(2, 3, 0);
			scene.add(b);

			const shared = three.stats().drawCalls;
			three.physics.soft(a, { mass: 1 });
			three.physics.soft(b, { mass: 1 });
			return [shared, three.stats().drawCalls];
		`);
		defer counted.free();
		test::@check(counted.ok, "the two were counted: %s", counted.error);
		test::@check(
			counted.value == "[1,2]",
			"one draw shared, two once each is soft, got '%s'", counted.value
		);
	};
}


<*
 A soft body is drawn as the shape the solver left it in, not as the shape it was
 modelled as.

 The comparison is against *the same mesh at the same place with the soft body
 taken off*, which is the only pair that isolates the thing being checked. A frame
 taken before the drop and one taken after would differ for a reason that has
 nothing to do with the vertices — the node moved. These two frames have the node
 in one position and the same camera, and the only difference between them is
 whether `MeshPass.write_soft_vertices` had anything to say.
*>
fn void a_soft_body_is_drawn_as_the_solver_left_it() @test
{
	@with_gpu_frames(; three::JsRuntime* run, three::Renderer* renderer)
	{
		three::RunResult built = run.run(`
			const scene = new three.Scene();
			three.light.set([0.3, 1.0, 0.4], 0.35);

			const floor = new three.Mesh(new three.BoxGeometry(6, 1, 6));
			floor.position.y = -0.5;
			scene.add(floor);
			three.physics.add(floor, { shape: 'box', mass: 0 });

			const jelly = new three.Mesh(new three.SphereGeometry(1, 16, 10));
			jelly.position.set(0, 3, 0);
			scene.add(jelly);
			three.physics.soft(jelly, { mass: 2, volume: true });
			globalThis.jelly = jelly;

			// Framed once, and never again: both captures have to be the same
			// camera or they differ for the wrong reason.
			three.camera.frameAll();
			return three.stats().drawCalls;
		`);
		defer built.free();
		test::@check(built.ok, "the scene built: %s", built.error);
		test::@check(built.value == "2", "the floor and the jelly, got '%s'", built.value);

		// Long enough to land and settle into a squashed shape.
		for (int i = 1; i <= 240; i++) run.tick((double)i * (1000.0 / 60.0));

		image::Image squashed = renderer.capture()!!;
		defer squashed.free();

		three::RunResult undone = run.run(`
			const at = globalThis.jelly.position.y;
			three.physics.removeSoft(globalThis.jelly);
			// Allowed now, and the same place the solver had it — so the two
			// frames differ by the vertices and by nothing else.
			globalThis.jelly.position.y = at;
			return true;
		`);
		defer undone.free();
		test::@check(undone.ok, "the soft body was taken off: %s", undone.error);

		image::Image rest = renderer.capture()!!;
		defer rest.free();

		sz changed = differing_pixels(&squashed, &rest);
		test::@check(
			changed > 200,
			"the deformed sphere and the rest sphere are different pictures, %d bytes apart", changed
		);
	};
}
