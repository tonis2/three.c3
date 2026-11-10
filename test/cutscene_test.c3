<*
 `three.cutscene` — `src/js/prelude/cutscene.js`.

	`c3c test --trust=full --test-noleak --test-filter three_tests::cutscene`

 Actors are `test/fixtures/hierarchy.glb` instances, whose clips are `slide`,
 `spin` and `blink`, handed in through `{ actors }`.
*>
module three_tests::cutscene;

import three;
import three_tests::device;
import std::core::test;

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
