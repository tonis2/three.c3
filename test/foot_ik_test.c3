<*
 Feet on the ground — `src/scene/foot_ik.c3` and `character.footIk()`.

 `test/fixtures/legs.glb` is a two-legged rig: `legs` → `hips` at (0, 0.9, 0) →
 `thigh_L/R` at x = ±0.1 → `knee` 0.4 down and 3 cm forward → `ankle` 0.4 down,
 standing 0.1 over the sole, with a `toe` marker 5 cm under it and 10 cm ahead. The
 clip `stand` keys the hips and every leg bone; `sink` keys only the hips, 5 cm
 lower, which sinks both feet into the floor.
*>
module three_tests::foot_ik;

import three;
import three_tests::device;
import std::core::test;
import std::math;
import std::math::quaternion;
import std::math::vector;

macro @with_gpu_js(; @body(three::JsRuntime* run))
{
	three::Renderer* renderer = device::borrow(200, 150);
	defer device::release();

	three::JsRuntime runtime;
	runtime.open(&renderer.pass, renderer)!!;
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

macro @ok(three::JsRuntime* run, String source)
{
	three::RunResult result = run.run(source);
	defer result.free();
	test::@check(result.ok, "the setup script succeeded: %s", result.error);
}

// Feed `frames` host ticks of 16 ms, carrying the clock on from `*at`.
fn void ticks(three::JsRuntime* run, double* at, int frames)
{
	for (int i = 0; i < frames; i++)
	{
		*at += 16.0;
		run.tick(*at);
	}
}

// The rig in a fresh scene, with helpers, as globals.
const String RIG = `
	globalThis.kit = three.load('test/fixtures/legs.glb');
	globalThis.scene = new three.Scene();
	globalThis.block = (w, d, x, z, top) => {
		const m = new three.Mesh(new three.BoxGeometry(w, 1, d));
		m.position.set(x, top - 0.5, z);
		scene.add(m);
		return m;
	};
	globalThis.LEGS = {
		pelvis: 'hips',
		legs: [
			{ upper: 'thigh_L', lower: 'knee_L', foot: 'ankle_L' },
			{ upper: 'thigh_R', lower: 'knee_R', foot: 'ankle_R' },
		],
		smooth: 0,
	};
	globalThis.character = (x = 0, z = 0) => {
		const c = kit.node('legs', { skeleton: true });
		c.position.set(x, 0, z);
		scene.add(c);
		return c;
	};
	globalThis.at = (c, name) => {
		const p = c.getObjectByName(name).getWorldPosition();
		return [+p.x.toFixed(3), +p.y.toFixed(3), +p.z.toFixed(3)];
	};
	globalThis.exact = (c, name) => {
		const p = c.getObjectByName(name).getWorldPosition();
		return [p.x, p.y, p.z];
	};
`;

// ============================================================================
// The solve
// ============================================================================

// Where the limb's joints go under the turns.
fn Vec3[2] posed(three::TwoBoneTurns turns, Vec3 a, Vec3 b, Vec3 c)
{
	Vec3 knee  = a + turns.upper * (b - a);
	Vec3 ankle = knee + turns.lower * (c - b);
	return { knee, ankle };
}

fn void two_bone_reaches_a_target_in_reach_and_keeps_its_lengths() @test
{
	Vec3 a      = { 0, 0, 0 };
	Vec3 b      = { 0, -0.5f, 0.05f };
	Vec3 c      = { 0, -1.0f, 0 };
	Vec3 target = { 0.2f, -0.8f, 0.1f };

	Vec3[2] p = posed(three::solve_two_bone(a, b, c, target, { 0, 0, 1 }), a, b, c);

	test::@check((p[1] - target).length() < 1e-4f, "the ankle is on the target: off by %f", (p[1] - target).length());
	test::@check(math::abs((p[0] - a).length() - (b - a).length()) < 1e-5f, "the thigh kept its length");
	test::@check(math::abs((p[1] - p[0]).length() - (c - b).length()) < 1e-5f, "the shin kept its length");
}

<*
 The knee bends the way it was already bent, whether the target is straight below
 or off to the side. A solve that picked its own bend plane would flip a knee
 backwards the first time a foot stepped sideways.
*>
fn void the_knee_stays_on_its_side_of_the_bend_plane() @test
{
	Vec3 a = { 0, 0, 0 };
	Vec3 b = { 0, -0.5f, 0.05f };
	Vec3 c = { 0, -1.0f, 0 };

	Vec3[2] below = posed(three::solve_two_bone(a, b, c, { 0, -0.7f, 0 }, { 0, 0, 1 }), a, b, c);
	Vec3[2] aside = posed(three::solve_two_bone(a, b, c, { 0.3f, -0.7f, 0 }, { 0, 0, 1 }), a, b, c);

	test::@check(below[0].z > 0.1f, "a shorter reach bends the knee further forward: z %f", below[0].z);
	test::@check(aside[0].z > 0.1f, "a target to the side keeps the knee forward: z %f", aside[0].z);
	test::@check((aside[1] - (Vec3) { 0.3f, -0.7f, 0 }).length() < 1e-4f, "and still reaches it");
}

fn void out_of_reach_straightens_toward_the_target() @test
{
	Vec3 a      = { 0, 0, 0 };
	Vec3 b      = { 0, -0.5f, 0.05f };
	Vec3 c      = { 0, -1.0f, 0 };
	Vec3 target = { 1.0f, -3.0f, 0 };

	Vec3[2] p = posed(three::solve_two_bone(a, b, c, target, { 0, 0, 1 }), a, b, c);
	float span       = (b - a).length() + (c - b).length();

	test::@check(math::abs((p[1] - a).length() - span) < 1e-3f, "the limb is straight");
	test::@check((p[1] - a).normalize().dot(target.normalize()) > 0.9999f, "and points at the target");
}

fn void a_straight_leg_bends_toward_the_pole() @test
{
	Vec3 a = { 0, 0, 0 };
	Vec3 b = { 0, -0.5f, 0 };
	Vec3 c = { 0, -1.0f, 0 };

	Vec3[2] p = posed(three::solve_two_bone(a, b, c, { 0, -0.8f, 0 }, { 0, 0, 1 }), a, b, c);

	test::@check(p[0].z > 0.1f, "the knee went toward the pole: z %f", p[0].z);
	test::@check((p[1] - (Vec3) { 0, -0.8f, 0 }).length() < 1e-4f, "and the ankle reached");
}

// ============================================================================
// On a character
// ============================================================================

<*
 A step under the left foot lifts that foot onto it and leaves the right one and
 the pelvis where the clip put them. A hole under the right foot drops the pelvis
 so the right leg reaches into it, and the left leg bends to stay on its ground.
 The rig's own boxes collide: a ray that did not skip the character would find
 the top of its own foot first.
*>
fn void a_foot_on_a_step_is_lifted_and_a_foot_over_a_dip_drops_the_pelvis() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		@ok(run, RIG.tconcat(`
			block(1, 2, 0.5, 0, 0);        // the floor under the left foot, x 0..1
			block(0.12, 0.5, 0.1, 0, 0.1); // a step on it, under the left foot
			block(1, 2, -0.5, 0, -0.1);    // under the right foot, 10 cm lower
			const c = character();
			c.play('stand');
			globalThis.rig = c;
			globalThis.ik = c.footIk(LEGS);
		`));
		double clock = 0;
		ticks(run, &clock, 3);
		String value = @value(run, `
			return [at(rig, 'ankle_L'), at(rig, 'ankle_R'), at(rig, 'hips')[1]];
		`, "read the legs");

		// Left: the step's top 0.1 + ankle 0.1. Right: the dip's -0.1 + 0.1. The
		// hips come down by the right leg's 0.1.
		test::@check(value == "[[0.1,0.2,0],[-0.1,0,0],0.8]", "both feet on their ground; got %s", value);
	};
}

<*
 A held clip and a paused clock re-pose nothing, so the solve starts from its own
 answer unless it puts the clip's pose back first. Ten frames of both must be the
 same picture to the last bit.
*>
fn void a_held_pose_does_not_compound() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		@ok(run, RIG.tconcat(`
			block(1, 2, 0.5, 0, 0.1);
			block(1, 2, -0.5, 0, -0.1);
			const c = character();
			c.play('stand', { speed: 0 });
			globalThis.rig = c;
			globalThis.ik = c.footIk(LEGS);
			globalThis.seen = [];
		`));
		double clock = 0;
		ticks(run, &clock, 2);
		for (int i = 0; i < 5; i++)
		{
			ticks(run, &clock, 1);
			@ok(run, `seen.push(JSON.stringify([exact(rig, 'ankle_L'), exact(rig, 'knee_L'), exact(rig, 'knee_R')]));`);
		}
		@ok(run, `three.clock.timeScale = 0;`);
		for (int i = 0; i < 5; i++)
		{
			ticks(run, &clock, 1);
			@ok(run, `seen.push(JSON.stringify([exact(rig, 'ankle_L'), exact(rig, 'knee_L'), exact(rig, 'knee_R')]));`);
		}
		String value = @value(run, `
			three.clock.timeScale = 1;
			return [new Set(seen).size, seen.length, at(rig, 'ankle_L')[1]];
		`, "compare the frames");

		test::@check(value == "[1,10,0.2]", "ten frames, one picture, the foot on its ground; got %s", value);
	};
}

<*
 Weight zero is the clip's pose, exactly — the same numbers a twin with no rig
 shows — and raising it again puts the feet back.
*>
fn void weight_zero_puts_back_the_clips_pose_exactly() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		@ok(run, RIG.tconcat(`
			block(1, 2, 0.5, 0, 0.1);
			block(1, 2, -0.5, 0, -0.1);
			block(1, 2, 3.5, 0, 0.1);
			block(1, 2, 2.5, 0, -0.1);
			const c = character();
			c.play('stand');
			const twin = character(3, 0);
			twin.play('stand');
			globalThis.rig = c;
			globalThis.twin = twin;
			globalThis.ik = c.footIk(LEGS);
		`));
		double clock = 0;
		ticks(run, &clock, 3);
		String bent = @value(run, `
			const out = at(rig, 'ankle_L')[1];
			ik.weight = 0;
			return out;
		`, "weigh out");
		ticks(run, &clock, 2);
		String value = @value(run, `
			const mine = ['ankle_L', 'knee_L', 'ankle_R', 'hips'].map((n) => exact(rig, n).map((v, i) => i === 0 ? v : v));
			const theirs = ['ankle_L', 'knee_L', 'ankle_R', 'hips'].map((n) => exact(twin, n).map((v, i) => i === 0 ? v - 3 : v));
			const same = mine.every((p, i) => p.every((v, k) => Math.abs(v - theirs[i][k]) < 1e-6));
			ik.weight = 1;
			return [same, three.stats().footIk.solves];
		`, "compare with the twin");
		ticks(run, &clock, 2);
		String back = @value(run, `return at(rig, 'ankle_L')[1];`, "weigh back in");

		test::@check(bent == "0.2", "the rig lifted the left foot; got %s", bent);
		test::@check(value == "[true,0]", "at weight 0 the pose is the twin's and nothing is solved; got %s", value);
		test::@check(back == "0.2", "weight 1 puts the foot back on its ground; got %s", back);
	};
}

<*
 A clip that sinks the feet 5 cm into the floor has them lifted out to the ankle's
 standing height. `sink` keys only the hips, so the leg bones are channels nobody
 but the rig writes — the restore has to find them unchanged and put them back.
*>
fn void a_sinking_clip_is_lifted_to_the_ankle_height() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		@ok(run, RIG.tconcat(`
			block(4, 4, 0, 0, 0);
			const c = character();
			c.play('sink');
			globalThis.rig = c;
			globalThis.ik = c.footIk({ ...LEGS, ankle: 0.1 });
		`));
		double clock = 0;
		ticks(run, &clock, 4);
		String value = @value(run, `
			return [at(rig, 'ankle_L')[1], at(rig, 'ankle_R')[1], at(rig, 'hips')[1]];
		`, "read the legs");

		test::@check(value == "[0.1,0.1,0.85]", "the feet stand on the floor and the hips stay down; got %s", value);
	};
}

<*
 On a 20° slope a planted foot turns toward the slope, as far as `tilt` allows.
 The toe marker sits 5 cm under the ankle, so a turn of θ about +Z moves it
 0.05·sin θ along +X.
*>
fn void a_planted_foot_tilts_to_the_slope_up_to_tilt() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		@ok(run, RIG.tconcat(`
			const slope = (x) => {
				const m = new three.Mesh(new three.BoxGeometry(2, 1, 2));
				const a = 20 * Math.PI / 180;
				m.rotation.z = a;
				m.position.set(x + 0.5 * Math.sin(a), -0.5 * Math.cos(a), 0);
				scene.add(m);
			};
			slope(0);
			slope(5);
			const wide = character(0, 0);
			const narrow = character(5, 0);
			wide.play('stand');
			narrow.play('stand');
			globalThis.wide = wide;
			globalThis.narrow = narrow;
			wide.footIk({ ...LEGS, tilt: 30 });
			narrow.footIk({ ...LEGS, tilt: 10 });
		`));
		double clock = 0;
		ticks(run, &clock, 3);
		String value = @value(run, `
			const turn = (c) => {
				const t = exact(c, 'toe_L');
				const a = exact(c, 'ankle_L');
				return +(t[0] - a[0]).toFixed(4);
			};
			return [turn(wide), turn(narrow)];
		`, "read the toes");

		// 0.05·sin 20° and 0.05·sin 10°.
		test::@check(value == "[0.0171,0.0087]", "the foot turned 20° on the slope, and 10° when held to 10; got %s", value);
	};
}

fn void footIk_on_a_baked_character_names_skeleton_true() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @value(run, RIG.tconcat(`
			const baked = kit.node('legs');
			scene.add(baked);
			try { baked.footIk(LEGS); return 'no throw'; } catch (e) { return e.message.includes('{ skeleton: true }'); }
		`), "ask a baked character");

		test::@check(value == "true", "the message names the option; got %s", value);
	};
}

fn void a_missing_bone_is_named() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String value = @value(run, RIG.tconcat(`
			const c = character();
			const legs = [{ upper: 'thigh_L', lower: 'shin_L', foot: 'ankle_L' }];
			const wrong = [{ upper: 'thigh_L', lower: 'knee_R', foot: 'ankle_R' }];
			const out = [];
			try { c.footIk({ pelvis: 'hips', legs }); out.push('no throw'); } catch (e) { out.push(e.message.startsWith('no bone named "shin_L"')); }
			try { c.footIk({ pelvis: 'hips', legs: wrong }); out.push('no throw'); } catch (e) { out.push(e.message.includes('does not hang from "thigh_L"')); }
			try { c.footIk({ ...LEGS, reach: 'far' }); out.push('no throw'); } catch (e) { out.push(e.message.includes('reach')); }
			try { c.footIk({ ...LEGS, feet: 2 }); out.push('no throw'); } catch (e) { out.push(e.message.includes("'feet' is not an option")); }
			return out;
		`), "ask with bad bones");

		test::@check(value == "[true,true,true,true]", "each mistake is named; got %s", value);
	};
}

<*
 What a frame of foot IK did is in `three.stats().footIk`, and a character that
 leaves the scene takes its rig with it.
*>
fn void stats_count_the_work_and_removing_the_character_drops_the_rig() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		@ok(run, RIG.tconcat(`
			block(4, 4, 0, 0, 0);
			const c = character();
			c.play('stand');
			globalThis.rig = c;
			globalThis.ik = c.footIk(LEGS);
		`));
		double clock = 0;
		ticks(run, &clock, 2);
		String working = @value(run, `
			const s = three.stats().footIk;
			const out = [s.rigs, s.solves, s.rays, s.misses, s.us > 0, ik.alive];
			scene.remove(rig);
			return out;
		`, "read the counters");
		ticks(run, &clock, 2);
		String gone = @value(run, `
			const s = three.stats().footIk;
			return [s.rigs, s.solves, ik.alive];
		`, "read them again");

		test::@check(working == "[1,2,2,0,true,true]", "one rig, two legs, two rays; got %s", working);
		test::@check(gone == "[0,0,false]", "nothing left to solve; got %s", gone);
	};
}
