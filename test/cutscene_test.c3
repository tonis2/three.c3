<*
 `three.cutscene` — `src/js/prelude/cutscene.js`.

	`c3c test --trust=full --test-noleak --test-filter three_tests::cutscene`

 Actors are `test/fixtures/hierarchy.glb` instances, whose clips are `slide`,
 `spin` and `blink`, handed in through `{ actors }`.

 The `.cutscene.glb` half plays files the Blender add-on's exporter wrote:
 `cutscene_hero.glb` is a rig (hero → spine → arm, skinned `hero_body`) whose
 clips are `walk` (spine bob, 1 s) and `wave` (arm out 0.5 m, 0.5 s).
 `intro.cutscene.glb`, and the same as `.gltf` + `.bin`, is 10 s: a 6 m walk
 along +X over 0–3 s, `wave` at 3–3.5 s, the one-off `intro_trip` (the arm
 drops 0.4 m) at 5–5.333 s, three camera keys and two events.
 `finer.cutscene.glb` loops `wave` twice over 1–2 s, plays `walk` from 0.25 s
 in over 3–3.5 s, and has a baked, linear camera. `turn.cutscene.gltf` is a
 hand-made version 2 file: `hero` placed and turned twice, and a `post` to face.
 The `cutscene_*.gltf`, `turn_*.gltf` and `place_*.gltf` files are hand-made
 broken ones.

 `walk_turn_play.cutscene.gltf` and `with_one_off.cutscene.gltf` / `.glb` are
 Rigsmith's exports (`crig_tests::cutscene_samples`), and `<name>.poses.json` is
 what Rigsmith's preview poses at a list of times. Their actors are
 `sample_actor.gltf`: actor → hips → shoulder_L → hand_L and one triangle, with
 clips `Walk` and `Rest` as long as Rigsmith's, which move only the hips.
*>
module three_tests::cutscene;

import three;
import three_tests::device;
import std::core::test;
import std::io::file;

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

// A hierarchy.glb actor in a scene, as globalThis.rig.
const String ACTOR = `
	const rig = three.load("test/fixtures/hierarchy.glb").instantiate();
	const scene = new three.Scene();
	scene.add(rig);
	globalThis.rig = rig;
	globalThis.log = [];
	const round = (n) => Math.round(n * 100) / 100;
	globalThis.round = round;
`;

fn void a_move_walks_its_path_by_time() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		@ok(run, ACTOR.tconcat(`
			globalThis.cs = three.cutscene.create({
				actors: [{ row: "hero", strips: [
					{ type: "move", start: 0, end: 2, ease: "linear", path: [[0,0,0],[4,0,0]] } ] }],
			}, { actors: { hero: rig } });
		`));
		String mid = @value(run, `
			cs.seek(1);
			return { x: round(rig.position.x), z: round(rig.position.z), yaw: round(rig.rotation.y) };
		`, "seek to the middle");
		test::@check(mid == `{"x":2,"z":0,"yaw":1.57}`, "halfway along, facing +X: %s", mid);

		String after = @value(run, `
			cs.seek(2);
			return { x: round(rig.position.x), duration: cs.duration };
		`, "seek to the end");
		test::@check(after == `{"x":4,"duration":2}`, "at the end of the path: %s", after);

		// Played rather than sought: about 0.5 s of frames moves about a metre.
		@ok(run, "cs.seek(0); cs.play();");
		double at = 0;
		ticks(run, &at, 32);
		String played = @value(run, "return rig.position.x;", "read the walked distance");
		double x = played.to_double()!!;
		test::@check(x > 0.8 && x < 1.2, "half a second of a 2 m/s walk is about a metre, not %s", played);
	};
}

<*
 An actor that stands with a lean keeps it, whichever way a move heads it. The
 rig stands as `zidane_armature` does in the Evil Forest level: turned 92° and
 leaning 13°, as the armature is in Blender. Its Euler triple is near the
 XYZ lock, (-105.8°, 81.8°, 115.7°), and writing a move's heading into Y while
 keeping X and Z laid him at 139° on the leg heading west: under the ground.
*>
fn void a_move_turns_an_actor_and_keeps_its_lean() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		@ok(run, ACTOR.tconcat(`
			rig.rotation = [-1.845868, 1.427825, 2.019156];
			globalThis.cs = three.cutscene.create({
				actors: [{ row: "hero", strips: [
					{ type: "move", start: 0, end: 1, ease: "linear", path: [[0,0,0],[4,0,0]] },
					{ type: "move", start: 1, end: 2, ease: "linear", path: [[4,0,0],[0,0,0]] } ] }],
			}, { actors: { hero: rig } });
			// How far its up axis leans from the world's, and where its +Z faces.
			globalThis.axes = () => {
				const [a, b, c] = [rig.rotation.x, rig.rotation.y, rig.rotation.z];
				const ca = Math.cos(a), sa = Math.sin(a), cb = Math.cos(b), sb = Math.sin(b), cc = Math.cos(c), sc = Math.sin(c);
				const up = ca * cc - sa * sb * sc;
				const forward = [sb, -sa * cb, ca * cb];
				return {
					lean: Math.round(Math.acos(Math.min(1, up)) * 180 / Math.PI),
					heading: Math.round(Math.atan2(forward[0], forward[2]) * 180 / Math.PI),
				};
			};
		`));
		String turned = @value(run, `
			cs.seek(0.5);
			const east = axes();
			cs.seek(1.5);
			const west = axes();
			return { east, west };
		`, "seek into both legs");
		test::@check(turned == `{"east":{"lean":13,"heading":89},"west":{"lean":13,"heading":-91}}`,
			"the lean stays 13° heading east and west: %s", turned);
	};
}

fn void a_play_strip_starts_its_clip_at_the_strip_time() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		@ok(run, ACTOR.tconcat(`
			globalThis.cs = three.cutscene.create({
				actors: [{ row: "hero", strips: [
					{ type: "play", start: 0.5, clip: "slide", loop: false } ] }],
				duration: 3,
			}, { actors: { hero: rig } });
		`));
		String before = @value(run, "cs.seek(0.25); return rig.animation === null ? 'none' : rig.animation.name;", "before the strip");
		test::@check(before == `"none"`, "nothing plays before the strip: %s", before);

		String inside = @value(run, `
			cs.seek(1.0);
			const a = rig.animation;
			return { name: a.name, time: round(a.time), speed: a.speed };
		`, "inside the strip");
		test::@check(inside == `{"name":"slide","time":0.5,"speed":0}`,
			"half a second into the strip, held while paused: %s", inside);
	};
}

fn void events_fire_once_in_order_and_rearm_on_a_seek_back() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		@ok(run, ACTOR.tconcat(`
			globalThis.cs = three.cutscene.create({
				events: [
					{ at: 0.2, name: "say", data: { text: "b" } },
					{ at: 0.1, name: "say", data: { text: "a" } },
					{ at: 0.3, name: "music", data: { track: "c" } },
					{ at: 0.6, name: "end" } ],
			});
			cs.on("say", e => log.push(e.text)).on("music", e => log.push(e.track)).on("end", () => log.push("end"));
			cs.play();
		`));
		double at = 0;
		ticks(run, &at, 60);
		String first = @value(run, "return { log, done: cs.done, systems: three.systems.list().map(s => s.name) };", "read the log");
		test::@check(first == `{"log":["a","b","c","end"],"done":true,"systems":[]}`,
			"each once, in time order, then the end, and the system gone: %s", first);

		String sought = @value(run, "cs.seek(0.15); return log.length;", "seek back");
		test::@check(sought == "4", "a seek fires nothing: %s", sought);

		@ok(run, "cs.play();");
		ticks(run, &at, 60);
		String again = @value(run, "return log.slice(4);", "read the replay");
		test::@check(again == `["b","c","end"]`, "from 0.15 the later events fire again: %s", again);
	};
}

fn void skip_fires_only_the_always_events() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		@ok(run, ACTOR.tconcat(`
			globalThis.cs = three.cutscene.create({
				actors: [{ row: "hero", strips: [
					{ type: "move", start: 0, end: 1, path: [[0,0,0],[0,0,3]] } ] }],
				events: [
					{ at: 0.5, name: "music", always: true },
					{ at: 1.0, name: "say" },
					{ at: 2.0, name: "end" } ],
			}, { actors: { hero: rig } });
			for (const name of ["music", "say", "end"]) cs.on(name, () => log.push(name));
			cs.play();
			cs.skip();
		`));
		String skipped = @value(run, "return { log, time: cs.time, done: cs.done, z: round(rig.position.z) };", "after the skip");
		test::@check(skipped == `{"log":["music","end"],"time":2,"done":true,"z":3}`,
			"the always event and the end, landed on the last pose: %s", skipped);
	};
}

fn void a_paused_game_clock_holds_the_scene() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		@ok(run, `
			globalThis.cs = three.cutscene.create({ events: [{ at: 5, name: "end" }] });
			three.clock.timeScale = 0;
			cs.play();
		`);
		double at = 0;
		ticks(run, &at, 20);
		String held = @value(run, "const t = cs.time; three.clock.timeScale = 1; return t;", "read the time");
		test::@check(held == "0", "a paused clock moves no cutscene time: %s", held);
	};
}

fn void the_camera_follows_the_keys_and_comes_back() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		@ok(run, `
			three.camera.lookAt(1, 2, 3).orbit(30, 10, 7);
			globalThis.before = { yaw: three.camera.yaw, pitch: three.camera.pitch, distance: three.camera.distance };
			globalThis.cs = three.cutscene.create({
				camera: [
					{ at: 0, eye: [0, 0, 5], target: [0, 0, 0], cut: true },
					{ at: 0.3, eye: [5, 0, 0], target: [0, 0, 0], cut: true } ],
				events: [{ at: 0.5, name: "end" }],
			});
		`);
		String shot = @value(run, `
			cs.seek(0);
			const r = (n) => Math.round(n * 100) / 100;
			const p = three.camera.position();
			return { eye: [r(p.x), r(p.y), r(p.z)], controls: three.controls.enabled };
		`, "the first shot");
		test::@check(shot == `{"eye":[0,0,5],"controls":false}`, "the eye is the key's, the mouse is off: %s", shot);

		@ok(run, "cs.play();");
		double at = 0;
		ticks(run, &at, 60);
		String back = @value(run, `
			const r = (n) => Math.round(n * 100) / 100;
			return { same: r(three.camera.yaw) === r(before.yaw) && r(three.camera.pitch) === r(before.pitch)
				&& r(three.camera.distance) === r(before.distance), controls: three.controls.enabled, done: cs.done };
		`, "after the end");
		test::@check(back == `{"same":true,"controls":true,"done":true}`, "the camera and the mouse come back: %s", back);
	};
}

fn void a_bad_spec_is_refused_with_its_field() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			three.cutscene.create({ actors: [{ row: "hero", strips: [{ type: "move", start: 0, end: 1, path: [[0,0,0]] }] }] },
				{ actors: { hero: new three.Group() } });
		`);
		defer result.free();
		test::@check(!result.ok && result.error.contains("strips[0]") && result.error.contains("2 points"),
			"a one-point path names the strip: %s", result.error);
	};
}

// The exporter's hero kit in a scene, and the helpers the checks read it with.
const String HERO = `
	globalThis.kit = three.load("test/fixtures/cutscene_hero.glb");
	globalThis.scene = new three.Scene();
	globalThis.round = (n) => Math.round(n * 100) / 100 + 0;
	globalThis.at = (o) => o.getWorldPosition().toArray().map(round);
	globalThis.hostClips = () => three.load("test/fixtures/cutscene_hero.glb").animations.join(",");
	globalThis.log = [];
`;

<*
 A character placed in a level comes out of `node()` whole. The walk lifts the
 skinned `hero_body` to the file's root; the subtree takes it along and undoes
 the (1, 0, -2) the file put `hero` at, which its pose already carries. So the
 arm is where the whole file draws it, and it follows the node when that moves.
*>
fn void a_placed_character_comes_out_of_node_whole() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String whole = @value(run, HERO.tconcat(`
			const file = kit.instantiate();
			scene.add(file);
			const hero = kit.node("hero");
			scene.add(hero);
			const body = hero.getObjectByName("hero_body");
			const inFile = at(file.socket("arm"));
			const hand = hero.socket("arm");
			const placed = at(hand);
			hero.position.set(5, 0, 0);
			const moved = at(hand);
			hero.play("wave");
			return { body: body !== null && body.parent === hero, inFile, placed, moved, clips: hero.animations.join(",") };
		`), "a character out of node()");
		test::@check(whole == `{"body":true,"inFile":[1,1,-2],"placed":[1,1,-2],"moved":[5,1,0],"clips":"walk,wave"}`,
			"the body comes along and draws where the file does: %s", whole);
	};
}

fn void a_cutscene_glb_loads_as_the_spec_create_plays() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String read = @value(run, HERO.tconcat(`
			const hero = kit.node("hero");
			scene.add(hero);
			const spec = (file) => {
				const cs = three.cutscene.load(file, { actors: { hero }, camera: false });
				const out = cs.spec;
				cs.dispose();
				return out;
			};
			const glb = spec("test/fixtures/intro.cutscene.glb");
			const gltf = spec("test/fixtures/intro.cutscene.gltf");
			const strips = glb.actors[0].strips;
			return {
				keys: Object.keys(glb), file: glb.file, duration: glb.duration, row: glb.actors[0].row,
				kinds: strips.map(s => s.type), path: [strips[0].path.length, strips[0].path[24]],
				oneOff: [strips[2].clip, strips[2].animation], shots: glb.camera.length,
				events: glb.events.map(e => e.name),
				same: JSON.stringify({ ...glb, file: 0 }) === JSON.stringify({ ...gltf, file: 0 }),
			};
		`), "load both files");
		test::@check(read == `{"keys":["file","name","duration","fps","actors","camera","events"],`
			`"file":"test/fixtures/intro.cutscene.glb","duration":10,"row":"hero",`
			`"kinds":["move","play","play"],"path":[25,[6,0,0]],"oneOff":["intro_trip",0],"shots":3,`
			`"events":["music","say"],"same":true}`,
			"the payload with its path inlined, the same from the .glb and the .gltf: %s", read);
	};
}

fn void the_actor_walks_the_path_and_plays_its_clips() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		@ok(run, HERO.tconcat(`
			globalThis.hero = kit.node("hero");
			scene.add(hero);
			globalThis.cs = three.cutscene.load("test/fixtures/intro.cutscene.glb", { actors: { hero } });
			globalThis.pose = (t) => {
				cs.seek(t);
				const a = hero.animation;
				return [round(hero.position.x), round(hero.position.z), round(hero.rotation.y), a && a.name, a && round(a.time)];
			};
		`));
		String walked = @value(run, "return [pose(0), pose(0.6), pose(1.2), pose(3)];", "seek along the walk");
		test::@check(walked == `[[0,0,1.57,"walk",0],[1.2,0,1.57,"walk",0.8],[2.4,0,1.57,"walk",0.6],[6,0,1.57,"wave",0]]`,
			"2 m/s along +X facing it, the walk at 1.3333x, the wave from 3 s: %s", walked);

		String played = @value(run, "return [pose(3.25), pose(4)];", "seek into the wave");
		test::@check(played == `[[6,0,1.57,"wave",0.25],[6,0,1.57,"wave",0.5]]`,
			"the listed clip by name where the walk ended, held after its end: %s", played);

		// Played rather than sought: a second of frames is about 2 m.
		@ok(run, "cs.seek(0); cs.play();");
		double at = 0;
		ticks(run, &at, 62);
		String moving = @value(run, "return [hero.animation.name, round(hero.animation.speed)];", "play a second");
		test::@check(moving == `["walk",1.33]`, "the walk running at its speed: %s", moving);
		String walked_x = @value(run, "return hero.position.x;", "read the distance");
		double x = walked_x.to_double()!!;
		test::@check(x > 1.7 && x < 2.3, "a second of the walk covers about 2 m, not %s", walked_x);
		@ok(run, "cs.dispose();");
	};
}

fn void the_events_fire_with_their_data() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		@ok(run, HERO.tconcat(`
			const hero = kit.node("hero");
			scene.add(hero);
			const listen = (cs) => cs.on("music", e => log.push(["music", e.track, e.at]))
				.on("say", e => log.push(["say", e.text, e.at])).on("end", () => log.push(["end"]));
			globalThis.played = listen(three.cutscene.load("test/fixtures/intro.cutscene.glb", { actors: { hero }, camera: false }));
			globalThis.skipped = listen(three.cutscene.load("test/fixtures/intro.cutscene.glb", { actors: { hero }, camera: false }));
			played.play();
		`));
		double at = 0;
		ticks(run, &at, 70);
		String heard = @value(run, "played.pause(); skipped.skip(); return log;", "play, then skip the other");
		test::@check(heard == `[["music","tense",0],["say","Not today.",1],["music","tense",0],["end"]]`,
			"each event with its data as it is crossed, and only the always one on a skip: %s", heard);
		@ok(run, "played.dispose(); skipped.dispose();");
	};
}

<*
 The one-off `intro_trip` lives in the cutscene file and targets the stub `arm`.
 It has to move the live actor's own `arm`, and be gone from the character after
 dispose. With `skeleton: true` the bone is a node, so its world position is the
 check: the clip lowers the arm's local Y by up to 0.4 m, and with the hero left
 at x = 6 facing +X that is the arm's world X going from 6 to 5.6.
*>
fn void a_one_off_clip_moves_the_live_actor_and_leaves_with_the_cutscene() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String runs = @value(run, HERO.tconcat(`
			const once = (file) => {
				const hero = kit.node("hero", { skeleton: true });
				scene.add(hero);
				const arm = hero.getObjectByName("arm");
				const cs = three.cutscene.load(file, { actors: { hero }, camera: false });
				const out = { during: [hero.animations.join(","), hostClips()] };
				cs.seek(5 + 1 / 6);
				out.mid = [hero.animation.name, ...at(arm)];
				cs.seek(8);
				out.held = [hero.animation.name, round(hero.animation.time), ...at(arm)];
				cs.dispose();
				out.after = [hero.animations.join(","), hostClips(), hero.animation, ...at(arm)];
				try { hero.play("intro_trip"); out.gone = false; } catch (e) { out.gone = e.message.includes('no animation named "intro_trip"'); }
				scene.remove(hero);
				return out;
			};
			return [once("test/fixtures/intro.cutscene.glb"), once("test/fixtures/intro.cutscene.gltf")];
		`), "play the one-off from both files");
		String expected = `{"during":["walk,wave,intro_trip","walk,wave,intro_trip"],"mid":["intro_trip",5.8,1,0],`
			`"held":["intro_trip",0.33,5.6,1,0],"after":["walk,wave","walk,wave",null,6,1,0],"gone":true}`;
		test::@check(runs == string::tformat("[%s,%s]", expected, expected),
			"the arm drops 0.2 m halfway and 0.4 m at the end, and is back at rest with the clip gone: %s", runs);
	};
}

<*
 A baked character has no bone nodes and no frames of the one-off in its table,
 so the clip is composed on the CPU; a socket on the arm reads that pose. The
 actor here is a whole-file group, so the stub `hero` binds by name, and the
 hero node's offset in it puts the arm's rest at (4, 1, -1) and its drop on X.
*>
fn void a_one_off_clip_poses_a_baked_actor_too() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String posed = @value(run, HERO.tconcat(`
			const rig = kit.instantiate();
			scene.add(rig);
			const hand = rig.socket("arm");
			const cs = three.cutscene.load("test/fixtures/intro.cutscene.glb", { actors: { hero: rig }, camera: false });
			cs.seek(3.25);
			const wave = at(hand);
			cs.seek(5 + 1 / 6);
			const mid = at(hand);
			cs.seek(8);
			const held = at(hand);
			cs.dispose();
			return { wave, mid, held, after: at(hand), clips: hostClips(), animation: rig.animation };
		`), "pose a baked actor");
		test::@check(posed == `{"wave":[4,1,-1.25],"mid":[3.8,1,-1],"held":[3.6,1,-1],"after":[4,1,-1],"clips":"walk,wave","animation":null}`,
			"the table for wave, the composed one-off after it, and the rest pose once it is gone: %s", posed);
	};
}

<*
 Two cutscenes over one character each add their one-off, and the second one's
 name is suffixed rather than shadowing the first. Disposing the first takes
 its clip out from under the second, which must keep playing its own.
*>
fn void two_cutscenes_on_one_actor_keep_their_own_clips() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String kept = @value(run, HERO.tconcat(`
			const hero = kit.node("hero", { skeleton: true });
			scene.add(hero);
			const arm = hero.getObjectByName("arm");
			const first = three.cutscene.load("test/fixtures/intro.cutscene.glb", { actors: { hero }, camera: false });
			const second = three.cutscene.load("test/fixtures/intro.cutscene.gltf", { actors: { hero }, camera: false });
			const names = hostClips();
			second.seek(5 + 1 / 6);
			const before = [hero.animation.name, ...at(arm)];
			first.dispose();
			const after = [hero.animation.name, ...at(arm), hostClips()];
			second.seek(8);
			const later = [hero.animation.name, ...at(arm)];
			second.dispose();
			return { names, before, after, later, left: hostClips() };
		`), "two cutscenes");
		test::@check(kept == `{"names":"walk,wave,intro_trip,intro_trip#2","before":["intro_trip#2",5.8,1,0],`
			`"after":["intro_trip#2",5.8,1,0,"walk,wave,intro_trip#2"],"later":["intro_trip#2",5.6,1,0],"left":"walk,wave"}`,
			"the second keeps playing its clip when the first leaves: %s", kept);
	};
}

<*
 In `finer.cutscene.glb` a looping play strip stops at its `end` and holds the
 pose it ended on, and `offset` starts a clip part-way in.
*>
fn void a_play_strip_holds_at_its_end_and_starts_at_its_offset() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		@ok(run, HERO.tconcat(`
			globalThis.hero = kit.node("hero");
			scene.add(hero);
			globalThis.clipAt = (cs, t) => { cs.seek(t); const a = hero.animation; return a ? [a.name, round(a.time), a.speed] : null; };
			globalThis.cs = three.cutscene.load("test/fixtures/finer.cutscene.glb", { actors: { hero }, camera: false });
		`));
		String held = @value(run, "return [clipAt(cs, 1.25), clipAt(cs, 2.5), clipAt(cs, 3.25), clipAt(cs, 4)];", "seek");
		test::@check(held == `[["wave",0.25,0],["wave",0.5,0],["walk",0.5,0],["walk",0.75,0]]`,
			"the second loop's last frame held after 2 s, and the walk from 0.25 s in: %s", held);

		// Played across the end: the loop stops on the frame it ended on.
		@ok(run, "cs.seek(0.9); cs.play();");
		double at = 0;
		ticks(run, &at, 100);
		String stopped = @value(run, "cs.pause(); const a = hero.animation; return [a.name, round(a.time), a.speed];", "play past the end");
		test::@check(stopped == `["wave",0.5,0]`, "held where it ended while the scene plays on: %s", stopped);
		@ok(run, "cs.dispose();");
	};
}

fn void a_baked_camera_moves_in_a_straight_line() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String eyes = @value(run, HERO.tconcat(`
			const hero = kit.node("hero");
			scene.add(hero);
			const eye = (file, t) => {
				const cs = three.cutscene.load(file, { actors: { hero } });
				cs.seek(t);
				const p = three.camera.position();
				cs.dispose();
				return [round(p.x), round(p.y), round(p.z)];
			};
			return { linear: eye("test/fixtures/finer.cutscene.glb", 0.5), eased: eye("test/fixtures/intro.cutscene.glb", 0.5),
				cut: eye("test/fixtures/intro.cutscene.glb", 5.5) };
		`), "the eye a quarter of the way through each move");
		test::@check(eyes == `{"linear":[1,2,10],"eased":[0.63,2,10],"cut":[10,5,0]}`,
			"a linear key arrives evenly, an unmarked one eases in and out, a cut jumps: %s", eyes);
	};
}

fn void a_bad_cutscene_file_says_what_is_wrong() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		@ok(run, HERO.tconcat(`
			const hero = kit.node("hero");
			scene.add(hero);
			const stray = new three.Group();
			scene.add(stray);
			globalThis.tries = {};
			const attempt = (name, fn) => { try { fn(); tries[name] = "loaded"; } catch (e) { tries[name] = e.message; } };
			const fixture = (name) => "test/fixtures/" + name;
			attempt("plain", () => three.cutscene.load(fixture("hierarchy.glb")));
			attempt("version", () => three.cutscene.load(fixture("cutscene_wrong_version.gltf")));
			attempt("path", () => three.cutscene.load(fixture("cutscene_missing_path.gltf"), { actors: { hero } }));
			attempt("missing", () => three.cutscene.load(fixture("nowhere.cutscene.glb")));
			attempt("bone", () => three.cutscene.load(fixture("cutscene_unknown_bone.gltf"), { actors: { hero } }));
			attempt("stray", () => three.cutscene.load(fixture("intro.cutscene.glb"), { actors: { hero: stray } }));
			attempt("noFile", () => three.cutscene.create({ actors: [{ row: "hero", node: 0,
				strips: [{ type: "play", start: 0, clip: "intro_trip", animation: 0 }] }] }, { actors: { hero } }));
			attempt("json", () => three.cutscene.load(fixture("intro.cutscene.json"), { actors: { hero } }));
		`));
		String[] names = { "plain", "version", "path", "missing", "bone", "stray", "noFile", "json" };
		String[] says = {
			"hierarchy.glb'): this glTF has no CUSTOM_cutscene extension",
			"CUSTOM_cutscene is version 3, and this engine reads versions 1 and 2",
			"actors[0].strips[0].path is 3, and the file has 1 path",
			"'test/fixtures/nowhere.cutscene.glb' is not there",
			"moves 'wrist', and actor 'hero' (from test/fixtures/cutscene_hero.glb) has no node by that name",
			"actor 'hero' plays the one-off clip 'intro_trip'",
			"names no file",
			"intro.cutscene.json'): a cutscene is a .cutscene.glb (or .gltf) written by the Blender exporter",
		};
		foreach (i, name : names)
		{
			String said = @value(run, string::tformat("return tries.%s;", name), name);
			test::@check(said.contains(says[i]), "%s: expected '%s' in %s", name, says[i], said);
		}
		String left = @value(run, "return hostClips();", "the clips after the failures");
		test::@check(left == `"walk,wave"`, "a file that failed to bind left no clip behind: %s", left);
	};
}

<*
 Load, play and dispose, over and over: nothing the file brought may pile up on
 the character. Run without `--test-noleak` this is also the heap check.
*>
fn void a_cutscene_loaded_and_disposed_leaves_the_character_as_it_was() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		@ok(run, HERO.tconcat(`
			globalThis.hero = kit.node("hero", { skeleton: true });
			scene.add(hero);
			globalThis.arm = hero.getObjectByName("arm");
		`));
		double at = 0;
		for (int cycle = 0; cycle < 40; cycle++)
		{
			@ok(run, string::tformat(`
				globalThis.cs = three.cutscene.load("test/fixtures/intro.cutscene.%s", { actors: { hero }, camera: false });
				cs.seek(5);
				cs.play();
			`, cycle % 2 == 0 ? "glb" : "gltf"));
			ticks(run, &at, 3);
			@ok(run, "cs.dispose();");
		}
		String left = @value(run, `
			return { clips: hostClips(), own: hero.animations.join(","), animation: hero.animation,
				arm: at(arm), systems: three.systems.list().length };
		`, "after forty cutscenes");
		test::@check(left == `{"clips":"walk,wave","own":"walk,wave","animation":null,"arm":[6,1,0],"systems":0}`,
			"the character's own clips, the arm at rest where the walk left the hero, nothing running: %s", left);
	};
}

// Where an object's +Z faces, in whole degrees about +Y, read off its Euler XYZ.
const String FACING = `
	globalThis.facing = (o) => {
		const a = o.rotation.x, b = o.rotation.y;
		return Math.round(Math.atan2(Math.sin(b), Math.cos(a) * Math.cos(b)) * 180 / Math.PI) + 0;
	};
	globalThis.deg = (d) => d * Math.PI / 180;
	globalThis.facingAt = (cs, o, times) => times.map(t => { cs.seek(t); return facing(o); });
`;

<*
 A version 2 `place` is the actor's home: where `seek(0)` and `play()` put it,
 whatever transform the object had, and its scale is left alone.
*>
fn void a_place_is_where_the_actor_starts() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		@ok(run, HERO.tconcat(FACING).tconcat(`
			globalThis.hero = kit.node("hero");
			hero.scale.set(2, 2, 2);
			scene.add(hero);
			globalThis.post = new three.Group();
			scene.add(post);
			globalThis.cs = three.cutscene.load("test/fixtures/turn.cutscene.gltf", { actors: { hero, post }, camera: false });
			globalThis.stand = () => [...hero.position.toArray().map(round), facing(hero), round(hero.scale.x)];
		`));
		String sought = @value(run, "cs.seek(0); return [stand(), post.position.toArray().map(round)];", "seek to the start");
		test::@check(sought == `[[3,0,2,90,2],[8,0,2]]`, "both at their places, the hero turned to +X and still twice the size: %s", sought);

		@ok(run, "hero.position.set(-4, 0, -4); hero.rotation = [0, 0, 0]; cs.play();");
		double at = 0;
		ticks(run, &at, 2);
		String played = @value(run, "cs.pause(); return stand();", "play two frames");
		test::@check(played == `[3,0,2,90,2]`, "moved away and played, it starts at its place: %s", played);
		@ok(run, "cs.dispose();");

		// Built in code too, with the quaternion's length taken off.
		String made = @value(run, `
			const cs = three.cutscene.create({ actors: [{ row: "hero",
				place: { position: [1, 2, 3], rotation: [0, 0, 0, 2] } }] }, { actors: { hero } });
			cs.seek(0);
			return stand();
		`, "a place in a spec");
		test::@check(made == `[1,2,3,0,2]`, "create() places it the same: %s", made);
	};
}

fn void a_version_2_file_turns_to_a_point_and_to_an_actor() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String turned = @value(run, HERO.tconcat(FACING).tconcat(`
			const hero = kit.node("hero");
			scene.add(hero);
			const post = new three.Group();
			scene.add(post);
			const cs = three.cutscene.load("test/fixtures/turn.cutscene.gltf", { actors: { hero, post }, camera: false });
			const out = facingAt(cs, hero, [0, 1.5, 2, 2.5, 3]);
			cs.dispose();
			return out;
		`), "seek through both turns");
		test::@check(turned == `[90,45,0,45,90]`, "from +X round to the point at +Z, then to the post at +X: %s", turned);
	};
}

fn void a_turn_ends_facing_its_point() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String turned = @value(run, ACTOR.tconcat(FACING).tconcat(`
			rig.position.set(0, 0, 0);
			rig.rotation = [0, 0, 0];
			const cs = three.cutscene.create({ actors: [{ row: "hero", strips: [
				{ type: "play", start: 0, clip: "slide", loop: true },
				{ type: "turn", start: 1, end: 3, point: [5, 0, 0] } ] }] }, { actors: { hero: rig } });
			const headings = facingAt(cs, rig, [0.5, 1.5, 2, 3, 4]);
			cs.seek(2);
			return { headings, clip: rig.animation.name, at: rig.position.toArray().map(round) };
		`), "seek through the turn");
		test::@check(turned == `{"headings":[0,14,45,90,90],"clip":"slide","at":[0,0,0]}`,
			"eased in and out to face +X, held after, the clip and the place untouched: %s", turned);
	};
}

fn void a_turn_goes_the_short_way_round() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String turned = @value(run, ACTOR.tconcat(FACING).tconcat(`
			rig.position.set(0, 0, 0);
			rig.rotation = [0, deg(170), 0];
			const cs = three.cutscene.create({ actors: [{ row: "hero", strips: [
				{ type: "turn", start: 0, end: 1, ease: "linear", point: [Math.sin(deg(-170)), 0, Math.cos(deg(-170))] } ] }] },
				{ actors: { hero: rig } });
			return facingAt(cs, rig, [0, 0.25, 0.75, 1]);
		`), "seek through the turn");
		test::@check(turned == `[170,175,-175,-170]`, "20° on through 180°, not 340° back: %s", turned);
	};
}

fn void a_turn_starts_from_an_earlier_turning_move() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String turned = @value(run, ACTOR.tconcat(FACING).tconcat(`
			rig.rotation = [0, 0, 0];
			const cs = three.cutscene.create({ actors: [{ row: "hero", strips: [
				{ type: "move", start: 0, end: 1, ease: "linear", path: [[0,0,0],[4,0,0]] },
				{ type: "turn", start: 1, end: 2, ease: "linear", point: [9, 0, -5 * Math.sqrt(3)] } ] }] },
				{ actors: { hero: rig } });
			return facingAt(cs, rig, [0.5, 1, 1.5, 2]);
		`), "seek along the walk and the turn");
		test::@check(turned == `[90,90,120,150]`, "the turn picks up the walk's +X, not the home 0°: %s", turned);
	};
}

<*
 The post walks on while the hero turns to it. The hero faces where the post
 was as the turn began, and finds that from the post's strips, not from where
 the post object happens to be.
*>
fn void a_turn_to_an_actor_faces_where_it_stood_as_the_turn_began() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String turned = @value(run, ACTOR.tconcat(FACING).tconcat(`
			rig.position.set(0, 0, 0);
			rig.rotation = [0, 0, 0];
			const post = new three.Group();
			scene.add(post);
			const cs = three.cutscene.create({ actors: [
				{ row: "hero", strips: [{ type: "turn", start: 1, end: 2, ease: "linear", actor: "post" }] },
				{ row: "post", strips: [{ type: "move", start: 0, end: 2, ease: "linear", turn: false, path: [[0,0,5],[10,0,5]] }] } ] },
				{ actors: { hero: rig, post } });
			const headings = facingAt(cs, rig, [1, 2, 3]);
			cs.seek(2);
			return { headings, post: round(post.position.x) };
		`), "seek through the turn");
		test::@check(turned == `{"headings":[0,45,45],"post":10}`,
			"facing (5, 0, 5), where the post was at 1 s, while it stands at x = 10: %s", turned);
	};
}

fn void a_turn_with_nothing_to_face_keeps_its_heading() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String kept = @value(run, ACTOR.tconcat(FACING).tconcat(`
			rig.position.set(0, 0, 0);
			rig.rotation = [0, deg(30), 0];
			const cs = three.cutscene.create({ actors: [{ row: "hero", strips: [
				{ type: "turn", start: 0, end: 1, point: [0, 3, 0] },
				{ type: "turn", start: 1, end: 2, actor: "hero" } ] }] }, { actors: { hero: rig } });
			return facingAt(cs, rig, [0.5, 1, 1.5, 2.5]);
		`), "seek through both turns");
		test::@check(kept == `[30,30,30,30]`, "a point straight overhead and the actor itself leave it at 30°: %s", kept);
	};
}

<*
 A move with `turn: false` keeps the heading of the turning strip before it, so
 its rotation is the same whatever was posed first, and a played frame is the
 frame a seek to its time shows.
*>
fn void a_seek_lands_on_the_same_rotation_from_anywhere() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		@ok(run, ACTOR.tconcat(FACING).tconcat(`
			rig.rotation = [0, 0, 0];
			globalThis.cs = three.cutscene.create({ actors: [{ row: "hero", strips: [
				{ type: "move", start: 0.5, end: 1, ease: "linear", path: [[0,0,0],[4,0,0]] },
				{ type: "move", start: 1, end: 2, ease: "linear", turn: false, path: [[4,0,0],[4,0,4]] },
				{ type: "turn", start: 3, end: 4, ease: "linear", point: [6, 0, 4 + 2 * Math.sqrt(3)] } ] }] },
				{ actors: { hero: rig } });
			globalThis.rot = () => JSON.stringify([rig.rotation.x, rig.rotation.y, rig.rotation.z].map(v => Math.round(v * 1e4) / 1e4));
			globalThis.same = (t) => {
				const seen = [0, 0.75, 2.5, 3.9].map(from => { cs.seek(from); cs.seek(t); return rot(); });
				return seen.every(r => r === seen[0]);
			};
		`));
		String sought = @value(run, "return { walk: same(1.5), turn: same(3.5), headings: facingAt(cs, rig, [0, 1.5, 3.5]) };", "seek from four places");
		test::@check(sought == `{"walk":true,"turn":true,"headings":[0,90,60]}`,
			"the same rotation from every earlier seek: %s", sought);

		@ok(run, "cs.seek(0); cs.play();");
		double at = 0;
		ticks(run, &at, 210);
		String played = @value(run, `
			const t = cs.time, r = rot();
			cs.pause();
			cs.seek(0);
			cs.seek(t);
			return { inTurn: t > 3 && t < 4, same: r === rot() };
		`, "play into the turn");
		test::@check(played == `{"inTurn":true,"same":true}`, "the played frame is the sought one: %s", played);
	};
}

fn void the_version_2_additions_are_refused_where_they_are_wrong() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		@ok(run, HERO.tconcat(`
			const hero = kit.node("hero");
			scene.add(hero);
			globalThis.tries = {};
			const attempt = (name, fn) => { try { fn(); tries[name] = "loaded"; } catch (e) { tries[name] = e.message; } };
			const fixture = (name) => "test/fixtures/" + name;
			const turn = (strip) => three.cutscene.create({ actors: [{ row: "hero",
				strips: [{ type: "turn", start: 0, end: 1, ...strip }] }] }, { actors: { hero } });
			const place = (place) => three.cutscene.create({ actors: [{ row: "hero", place }] }, { actors: { hero } });
			attempt("v1turn", () => three.cutscene.load(fixture("turn_version1.gltf"), { actors: { hero } }));
			attempt("v1place", () => three.cutscene.load(fixture("place_version1.gltf"), { actors: { hero } }));
			attempt("nobody", () => three.cutscene.load(fixture("turn_no_actor.gltf"), { actors: { hero } }));
			attempt("neither", () => turn({}));
			attempt("both", () => turn({ point: [0, 0, 1], actor: "hero" }));
			attempt("backwards", () => turn({ start: 1, end: 1, point: [0, 0, 1] }));
			attempt("clip", () => turn({ point: [0, 0, 1], clip: "wave" }));
			attempt("ease", () => turn({ point: [0, 0, 1], ease: "fast" }));
			attempt("point", () => turn({ point: [0, 1] }));
			attempt("rotation", () => place({ position: [0, 0, 0], rotation: [0, 0, 0] }));
			attempt("zero", () => place({ position: [0, 0, 0], rotation: [0, 0, 0, 0] }));
			attempt("position", () => place({ rotation: [0, 0, 0, 1] }));
		`));
		String[] names = { "v1turn", "v1place", "nobody", "neither", "both", "backwards", "clip", "ease", "point",
			"rotation", "zero", "position" };
		String[] says = {
			"turn_version1.gltf'): actors[0].strips[0].type 'turn' needs CUSTOM_cutscene version 2, and the file says version 1",
			"place_version1.gltf'): actors[0].place needs CUSTOM_cutscene version 2, and the file says version 1",
			"turn_no_actor.gltf'): actors[0].strips[0].actor is 'nobody', and this cutscene has no actor of that row",
			"actors[0].strips[0]: a turn faces a point: [x, y, z] or an actor: '<row>', names neither",
			"actors[0].strips[0]: a turn faces a point: [x, y, z] or an actor: '<row>', not both",
			"actors[0].strips[0]: a turn needs an end after its start",
			"actors[0].strips[0]: a turn plays no clip",
			"actors[0].strips[0].ease is one of linear, in, out, inout",
			"actors[0].strips[0].point wants [x, y, z], not [0,1]",
			"actors[0].place.rotation wants a quaternion [x, y, z, w], not [0,0,0]",
			"actors[0].place.rotation is all zeros, which is not a rotation",
			"actors[0].place.position wants [x, y, z]",
		};
		foreach (i, name : names)
		{
			String said = @value(run, string::tformat("return tries.%s;", name), name);
			test::@check(said.contains(says[i]), "%s: expected '%s' in %s", name, says[i], said);
		}
	};
}

// Rigsmith's sample exports, played on `sample_actor.gltf` copies, and the helpers the checks read them with.
const String SAMPLE = `
	globalThis.kit = three.load("test/fixtures/sample_actor.gltf");
	globalThis.scene = new three.Scene();
	globalThis.round = (n) => Math.round(n * 100) / 100 + 0;
	globalThis.cast = (watcher) => {
		const actors = { walker: kit.instantiate(), watcher: watcher ?? kit.instantiate() };
		for (const o of Object.values(actors)) scene.add(o);
		return actors;
	};
	globalThis.leave = (actors) => { for (const o of Object.values(actors)) scene.remove(o); };
	// The quaternion of an Euler XYZ triple, as the prelude's quatFromEulerXYZ makes it.
	globalThis.quat = (r) => {
		const c1 = Math.cos(r.x / 2), c2 = Math.cos(r.y / 2), c3 = Math.cos(r.z / 2);
		const s1 = Math.sin(r.x / 2), s2 = Math.sin(r.y / 2), s3 = Math.sin(r.z / 2);
		return [s1 * c2 * c3 + c1 * s2 * s3, c1 * s2 * c3 - s1 * c2 * s3, c1 * c2 * s3 + s1 * s2 * c3, c1 * c2 * c3 - s1 * s2 * s3];
	};
	globalThis.multiply = ([ax, ay, az, aw], [bx, by, bz, bw]) => [
		aw * bx + ax * bw + ay * bz - az * by, aw * by - ax * bz + ay * bw + az * bx,
		aw * bz + ax * by - ay * bx + az * bw, aw * bw - ax * bx - ay * by - az * bz];
	globalThis.rotate = ([x, y, z, w], [vx, vy, vz]) => {
		const tx = 2 * (y * vz - z * vy), ty = 2 * (z * vx - x * vz), tz = 2 * (x * vy - y * vx);
		return [vx + w * tx + y * tz - z * ty, vy + w * ty + z * tx - x * tz, vz + w * tz + x * ty - y * tx];
	};
	globalThis.heading = ([x, y, z, w]) => Math.atan2(2 * (w * y - x * z), 1 - 2 * (y * y + z * z));
	// The angle between two rotations, from their difference's axis part: acos near 1 loses the digits.
	globalThis.apart = (p, q) => {
		const d = multiply([-p[0], -p[1], -p[2], p[3]], q);
		return 2 * Math.atan2(Math.hypot(d[0], d[1], d[2]), Math.abs(d[3]));
	};
	globalThis.turnOff = (a, b) => Math.abs(Math.atan2(Math.sin(a - b), Math.cos(a - b)));
	globalThis.distance = (a, b) => Math.hypot(a[0] - b[0], a[1] - b[1], a[2] - b[2]);
`;

// What Rigsmith posed for sample `name`, set as `globalThis.ref`.
fn String poses_script(String name) @local
{
	String text = (String)file::load(tmem, string::tformat("test/fixtures/%s.poses.json", name))!!;
	return string::tformat("globalThis.ref = %s;", text);
}

fn void rigsmith_exports_load_as_version_2_and_start_at_their_places() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String read = @value(run, SAMPLE.tconcat(`
			const read = (file) => {
				const actors = cast();
				actors.walker.position.set(-4, 0, -4);
				actors.watcher.position.set(7, 0, 7);
				actors.watcher.rotation = [0, 1, 0];
				const cs = three.cutscene.load(file, { actors, camera: false });
				const doc = JSON.parse(globalThis.__three.gltfJson(file));
				cs.seek(0);
				const out = {
					version: doc.extensions.CUSTOM_cutscene.version, duration: cs.duration,
					kinds: cs.spec.actors.map(a => a.row + ":" + a.strips.map(s => s.type).join(",")),
					at: [actors.walker, actors.watcher].map(o => [...o.position.toArray().map(round), round(heading(quat(o.rotation)))]),
				};
				cs.dispose();
				leave(actors);
				return out;
			};
			const spec = (file) => {
				const actors = cast();
				const cs = three.cutscene.load(file, { actors, camera: false });
				const out = JSON.stringify({ ...cs.spec, file: 0 });
				cs.dispose();
				leave(actors);
				return out;
			};
			return { walk: read("test/fixtures/walk_turn_play.cutscene.gltf"), gltf: read("test/fixtures/with_one_off.cutscene.gltf"),
				glb: read("test/fixtures/with_one_off.cutscene.glb"),
				same: spec("test/fixtures/with_one_off.cutscene.gltf") === spec("test/fixtures/with_one_off.cutscene.glb") };
		`), "load the samples");
		String placed = `{"version":2,"duration":14,"kinds":["walker:move,play,turn,play","watcher:play,turn%s"],"at":[[0,0,0,0],[2.5,0,3,0]]}`;
		String walk = string::tformat(placed, "");
		String one_off = string::tformat(placed, ",play");
		test::@check(read == string::tformat(`{"walk":%s,"gltf":%s,"glb":%s,"same":true}`, walk, one_off, one_off),
			"version 2, both actors at their places whatever they stood at, the .glb the same as the .gltf: %s", read);
	};
}

<*
 What Rigsmith previews, within 1 mm, 1 mrad (0.06°) and 1 ms of clip time; and
 what Rigsmith poses from the file itself, within 0.01 mm, 0.01 mrad and 0.01 ms.
 The two differ by the writer's rounding of paths and times to 0.1 mm and 0.1 ms.
*>
const String TOLERANCE = "{ preview: { position: 1e-3, rotation: 1e-3, clip: 1e-3 }, file: { position: 1e-5, rotation: 1e-5, clip: 1e-5 } }";

<*
 Every actor at every time Rigsmith posed: its place, its rotation, the clip its
 strip names and that clip's time, wrapped by the loop or held as the strip says.
 Sought in order and then back again, so no answer leans on the seek before it.
 Where Rigsmith plays nothing the player may still hold a stopped clip: neither
 side's rules say what shows then, and a fresh load in order shows nothing.
*>
fn void rigsmith_exports_pose_as_rigsmith_previews_them() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		@ok(run, SAMPLE.tconcat(`
			globalThis.compare = (file, tolerance) => {
				const actors = cast();
				const cs = three.cutscene.load(file, { actors, camera: false });
				const lengths = {};
				for (const a of ref.actors) for (const c of a.clips) lengths[a.row + "/" + c.name] = c.length;
				const worst = { preview: { position: 0, rotation: 0, clip: 0 }, file: { position: 0, rotation: 0, clip: 0 } };
				const wrong = [];
				const against = (into, row, a, want, loop) => {
					const o = actors[row];
					into.position = Math.max(into.position, distance(o.position.toArray(), want.position));
					into.rotation = Math.max(into.rotation, apart(quat(o.rotation), want.rotation));
					if (a === null || want.clip === undefined) return;
					const length = lengths[row + "/" + want.clip];
					let off = Math.abs(a.time - want.clip_local);
					if (loop) off = Math.min(off, Math.abs(length - off));
					into.clip = Math.max(into.clip, off);
				};
				for (const pose of [...ref.poses, ...ref.poses.slice().reverse()]) {
					cs.seek(pose.time);
					for (const want of pose.actors) {
						const o = actors[want.row];
						const at = want.row + " at " + pose.time + " s";
						const a = o.animation;
						if (want.strip < 0) {
							if (a !== null && a.playing) wrong.push(at + " plays " + a.name + ", and Rigsmith nothing");
							against(worst.preview, want.row, null, want, false);
							against(worst.file, want.row, null, want.file, false);
							continue;
						}
						if (a === null || a.name !== want.clip || want.file.clip !== want.clip) {
							wrong.push(at + " plays " + (a && a.name) + ", not " + want.clip);
							continue;
						}
						const length = lengths[want.row + "/" + want.clip];
						if (Math.abs(a.duration - length) > 1e-5) wrong.push(at + ": " + want.clip + " lasts " + a.duration + " s, not " + length);
						against(worst.preview, want.row, a, want, want.loop);
						against(worst.file, want.row, a, want.file, want.loop);
					}
				}
				cs.dispose();
				leave(actors);
				const within = (got, most) => got.position <= most.position && got.rotation <= most.rotation && got.clip <= most.clip;
				const close = within(worst.preview, tolerance.preview) && within(worst.file, tolerance.file);
				return { close, wrong, worst, times: ref.poses.length };
			};
		`));
		String[2][] samples = {
			{ "walk_turn_play", "walk_turn_play.cutscene.gltf" },
			{ "with_one_off", "with_one_off.cutscene.gltf" },
			{ "with_one_off", "with_one_off.cutscene.glb" },
		};
		foreach (sample : samples)
		{
			@ok(run, poses_script(sample[0]));
			String said = @value(run, string::tformat(`return compare("test/fixtures/%s", %s);`, sample[1], TOLERANCE), sample[1]);
			test::@check(said.starts_with(`{"close":true,"wrong":[],`), "%s plays as Rigsmith posed it: %s", sample[1], said);
		}
	};
}

<*
 The walker turns to face the watcher where it stood as the turn began, and the
 watcher turns to its point; both still face it to the end.
*>
fn void rigsmith_turns_end_facing_their_targets() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String faced = @value(run, SAMPLE.tconcat(`
			const actors = cast();
			const cs = three.cutscene.load("test/fixtures/walk_turn_play.cutscene.gltf", { actors, camera: false });
			const turn = (row) => cs.spec.actors.find(a => a.row === row).strips.find(s => s.type === "turn");
			const toward = turn("walker"), aside = turn("watcher");
			const facing = (o, t) => { cs.seek(t); return heading(quat(o.rotation)); };
			cs.seek(toward.start);
			const from = actors.walker.position.toArray(), other = actors.watcher.position.toArray();
			const walker = Math.atan2(other[0] - from[0], other[2] - from[2]);
			cs.seek(aside.start);
			const stood = actors.watcher.position.toArray();
			const watcher = Math.atan2(aside.point[0] - stood[0], aside.point[2] - stood[2]);
			const out = {
				target: [toward.actor, aside.point],
				degrees: [walker, watcher].map(h => Math.round(h * 180 / Math.PI)),
				walker: [toward.end, 12, cs.duration].map(t => turnOff(facing(actors.walker, t), walker) < 1e-3),
				watcher: [aside.end, 8, cs.duration].map(t => turnOff(facing(actors.watcher, t), watcher) < 1e-3),
				midway: turnOff(facing(actors.walker, (toward.start + toward.end) / 2), walker) > 0.1,
			};
			cs.dispose();
			leave(actors);
			return out;
		`), "seek past both turns");
		test::@check(faced == `{"target":["watcher",[1.5,0,4]],"degrees":[112,-45],"walker":[true,true,true],"watcher":[true,true,true],"midway":true}`,
			"each faces its target from its turn's end on, and not yet halfway through: %s", faced);
	};
}

<*
 The one-off moves the stub `shoulder_L`, so it binds to the watcher's own
 `shoulder_L`: halfway through its strip that bone has the one-off's rotation,
 read off where `hand_L` hangs from it, not its rest. A watcher whose rig has no
 such bone is refused, naming it.
*>
fn void a_rigsmith_one_off_turns_the_bone_it_names() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		@ok(run, poses_script("with_one_off"));
		String posed = @value(run, SAMPLE.tconcat(`
			const arm = (o) => {
				const a = o.getObjectByName("shoulder_L").getWorldPosition().toArray();
				const b = o.getObjectByName("hand_L").getWorldPosition().toArray();
				return [b[0] - a[0], b[1] - a[1], b[2] - a[2]];
			};
			const slerp = (a, b, u) => {
				const dot = a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3];
				const sign = dot < 0 ? -1 : 1, cos = Math.abs(dot);
				if (cos > 0.9995) {
					const q = a.map((v, i) => v + (sign * b[i] - v) * u);
					const n = Math.hypot(...q);
					return q.map(v => v / n);
				}
				const angle = Math.acos(cos), s = Math.sin(angle);
				return a.map((v, i) => v * Math.sin((1 - u) * angle) / s + sign * b[i] * Math.sin(u * angle) / s);
			};
			// A rotation channel at clip time t, as glTF's LINEAR samples it.
			const keyAt = (channel, t) => {
				const key = (i) => channel.values.slice(i * 4, i * 4 + 4);
				if (t <= channel.times[0]) return key(0);
				for (let i = 1; i < channel.times.length; i++) {
					if (t <= channel.times[i]) return slerp(key(i - 1), key(i), (t - channel.times[i - 1]) / (channel.times[i] - channel.times[i - 1]));
				}
				return key(channel.times.length - 1);
			};
			const reach = [0.5, 0, 0];
			const channel = ref.one_offs[0].channels[0];
			const once = (file) => {
				const actors = cast();
				const watcher = actors.watcher;
				const cs = three.cutscene.load(file, { actors, camera: false });
				const strip = cs.spec.actors.find(a => a.row === "watcher").strips.find(s => s.animation !== undefined);
				const rest = () => rotate(quat(watcher.rotation), reach);
				const out = { clips: watcher.animations.join(",") };
				cs.seek(strip.start - 0.25);
				out.before = distance(arm(watcher), rest()) < 1e-4;
				cs.seek((strip.start + strip.end) / 2);
				const a = watcher.animation;
				const one = rotate(multiply(quat(watcher.rotation), keyAt(channel, a.time)), reach);
				out.mid = [a.name, round(a.time), distance(arm(watcher), one) < 1e-4, round(distance(arm(watcher), rest()))];
				cs.dispose();
				out.after = [watcher.animations.join(","), distance(arm(watcher), rest()) < 1e-4];
				leave(actors);
				return out;
			};
			return { bone: channel.bone, gltf: once("test/fixtures/with_one_off.cutscene.gltf"), glb: once("test/fixtures/with_one_off.cutscene.glb") };
		`), "play the one-off from both files");
		String each = `{"clips":"Walk,Rest,one_off","before":true,"mid":["one_off",1,true,0.38],"after":["Walk,Rest",true]}`;
		test::@check(posed == string::tformat(`{"bone":"shoulder_L","gltf":%s,"glb":%s}`, each, each),
			"the shoulder at rest before, turned by the one-off halfway, and at rest once it is gone: %s", posed);

		String refused = @value(run, `
			const stray = three.load("test/fixtures/hierarchy.glb").instantiate();
			let said = "loaded";
			try { three.cutscene.load("test/fixtures/with_one_off.cutscene.gltf", { actors: cast(stray), camera: false }); }
			catch (e) { said = e.message; }
			return { said, left: three.load("test/fixtures/hierarchy.glb").animations.join(",") };
		`, "a watcher without the bone");
		test::@check(refused.contains("in test/fixtures/with_one_off.cutscene.gltf moves 'shoulder_L', and actor 'watcher' "
			"(from test/fixtures/hierarchy.glb) has no node by that name") && refused.contains(`"left":"slide,spin,blink"`),
			"the bone named and nothing left behind: %s", refused);
	};
}
