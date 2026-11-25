// vr_bench.js — what a headset frame costs, one knob at a time: vertices, fragments, lights,
// draw calls, copies, script work, shadows and foveation. It steps through its setups by
// itself and logs a pair of lines for each, so a change to the renderer can be measured
// against the same scenes before and after.
//
//   packaging/android/build-apk.sh examples/vr_bench.js
//   adb install -r build/android/three.apk
//   packaging/android/quest.sh bench          # restarts the app, waits, prints one row a setup
//   ./build/three --script examples/vr_bench.js   # at a desk, to check it runs
//
// Each setup settles, then logs `bench: begin <name>`, measures, and logs `bench: end <name> | ...`.
// The GPU numbers that matter come from Meta's VrApi line between the two, which `quest.sh bench`
// pairs up: the engine's own GPU timestamps include the compositor pre-empting the frame.
//
// Leave the headset still: each scene is built in front of where it looks when that setup starts,
// and a setup starts again if the head moves more than 3° or 3 cm while it runs.
// Pin the GPU level for numbers that compare (`adb shell setprop debug.oculus.gpuLevel 4`), and
// unplug the cable or turn the charging boost off (`setprop debug.crcs.disable_charging_boost 1`).

const SETTLE_MS = 2500;
const MEASURE_MS = 5000;

const scene = new three.Scene();
scene.background = 0x101418;
three.light.set([-0.4, -1, -0.3], 1.0);
// Like the game: the room behind, which is also what caps the GPU at level 2 unless pinned.
if (three.xr.passthroughSupported) three.xr.passthrough = true;
// XR never skips or reuses a frame; this makes a desk run measure the same way.
three.alwaysRender = true;
three.sceneCache = false;
three.camera.lookAt(0, 1.6, 0);
three.camera.orbit(0, 0, 0.01);

const lit = new three.MeshLambertMaterial({});
// No lighting at all: the fragment shader is as cheap as the template allows, so what is left is
// the vertex work and the fixed cost of a fragment.
const unlit = new three.ShaderMaterial({ fragment: 'return s.albedo;' });

// Everything is built under `stage`, which each setup places at the head, facing exactly where it
// looks: local -Z is straight ahead. Two groups, so the turn and the tilt compose the same way
// whatever order an Euler rotation uses. If the head moves during a setup, the setup starts
// again in front of where it is now: a headset picked up mid-run can't skew the numbers.
const turnGroup = new three.Group();
const stage = new three.Group();
turnGroup.add(stage);
scene.add(turnGroup);
let anchor = null; // { x, y, z, yaw, pitch, dir }

const MOVED_DEGREES = 3;
const MOVED_METRES = 0.03;

function headPose() {
	const h = three.xr.head;
	const d = h.direction;
	const len = Math.hypot(d.x, d.y, d.z) || 1;
	const dir = [d.x / len, d.y / len, d.z / len];
	return {
		x: h.position.x, y: h.position.y, z: h.position.z, dir,
		yaw: Math.atan2(-dir[0], -dir[2]),
		pitch: Math.asin(Math.max(-1, Math.min(1, dir[1]))),
	};
}

function placeStage() {
	anchor = headPose();
	turnGroup.position.set(anchor.x, anchor.y, anchor.z);
	turnGroup.rotation.y = anchor.yaw;
	stage.rotation.x = anchor.pitch;
}

function headMoved() {
	const now = headPose();
	const dot = now.dir[0] * anchor.dir[0] + now.dir[1] * anchor.dir[1] + now.dir[2] * anchor.dir[2];
	const degrees = (Math.acos(Math.min(1, dot)) * 180) / Math.PI;
	const metres = Math.hypot(now.x - anchor.x, now.y - anchor.y, now.z - anchor.z);
	return degrees > MOVED_DEGREES || metres > MOVED_METRES;
}

// A stage-space point in the world, for lights, which take world positions: the tilt about X,
// then the turn about Y, then the head's position.
function toWorld(x, y, z) {
	const cp = Math.cos(anchor.pitch);
	const sp = Math.sin(anchor.pitch);
	const [ty, tz] = [y * cp - z * sp, y * sp + z * cp];
	const c = Math.cos(anchor.yaw);
	const s = Math.sin(anchor.yaw);
	return [anchor.x + x * c + tz * s, anchor.y + ty, anchor.z - x * s + tz * c];
}

function add(geometry, material, x, y, z, color = [0.8, 0.78, 0.74]) {
	const mesh = new three.Mesh(geometry, material);
	mesh.position.set(x, y, z);
	mesh.color = color;
	mesh.collides = false;
	stage.add(mesh);
	return mesh;
}

// A square grid of `count` copies of one shape, `spread` metres across, `ahead` metres away.
function grid(geometry, material, count, spread, ahead) {
	const side = Math.ceil(Math.sqrt(count));
	const step = side > 1 ? spread / (side - 1) : 0;
	const meshes = [];
	for (let i = 0; i < count; i++) {
		const col = i % side;
		const row = Math.floor(i / side);
		const shade = 0.55 + 0.4 * ((i * 37) % 11) / 10;
		meshes.push(add(geometry, material, -spread / 2 + col * step, -spread / 2 + row * step, -ahead, [shade, shade * 0.9, 0.7]));
	}
	return meshes;
}

// Planes that cover the whole view, one behind the other, facing the head.
function fill(material, layers) {
	const plane = new three.PlaneGeometry(5, 5);
	for (let i = 0; i < layers; i++) add(plane, material, 0, 0, -(1.0 + i * 0.1), [0.5 + 0.1 * i, 0.55, 0.6]);
}

let lamps = [];
function setLamps(count) {
	for (const lamp of lamps) three.lights.remove(lamp);
	lamps = [];
	for (let i = 0; i < count; i++) {
		const a = (i / Math.max(count, 1)) * Math.PI * 2;
		lamps.push(three.lights.add({ position: toWorld(Math.sin(a) * 0.8, 0.3 * Math.cos(a * 3), -1.0 + Math.cos(a) * 0.3), range: 2.5, color: 0xffd8a0, intensity: 2 }));
	}
}

// One small sphere has 64 x 32 segments, about 4k triangles; the vertex sweep copies it.
const ball = new three.SphereGeometry(0.02, 64, 32);
const big = new three.SphereGeometry(0.3, 512, 256);
const box = new three.BoxGeometry(0.03, 0.03, 0.03);

// `build` puts the setup's meshes on the stage and may return a per-frame function.
// `prepass`, `shadow`, `foveation` and `lamps` default to the game's settings; the prepass to the
// engine's own default, which is off on a Quest.
const DEFAULT_PREPASS = three.depthPrepass;
const SETUPS = [
	{ name: 'empty', build() {} },

	// Vertices: copies of a small ball, tiny on screen, so fragments stay few.
	...[12, 25, 50, 100, 200].map((n) => ({ name: `vertices unlit ${n} balls`, build: () => grid(ball, unlit, n, 0.5, 1.2) })),
	...[50, 200].map((n) => ({ name: `vertices lit ${n} balls`, build: () => grid(ball, lit, n, 0.5, 1.2) })),
	{ name: 'vertices unlit 1 big ball', build: () => add(big, unlit, 0, 0, -1.5) },

	// Fragments: planes covering the view. With the prepass only the front one is shaded; without
	// it every layer is.
	{ name: 'fill unlit 1 layer', build: () => fill(unlit, 1) },
	{ name: 'fill lit 1 layer', build: () => fill(lit, 1) },
	{ name: 'fill lit 1 layer, 8 lamps', lamps: 8, build: () => fill(lit, 1) },
	{ name: 'fill lit 1 layer, 32 lamps', lamps: 32, build: () => fill(lit, 1) },
	{ name: 'fill lit 4 layers', build: () => fill(lit, 4) },
	{ name: 'fill lit 4 layers, no prepass', prepass: false, build: () => fill(lit, 4) },
	{ name: 'fill lit 4 layers, with prepass', prepass: true, build: () => fill(lit, 4) },

	// Draw calls: boxes that cannot share one, each a slightly different size.
	...[100, 300, 1000].map((n) => ({
		name: `draws ${n}`,
		build: () => {
			const side = Math.ceil(Math.sqrt(n));
			for (let i = 0; i < n; i++) {
				const shape = new three.BoxGeometry(0.02 + i * 1e-5, 0.02, 0.02);
				add(shape, lit, -0.4 + (i % side) * (0.8 / side), -0.4 + Math.floor(i / side) * (0.8 / side), -1.2);
			}
		},
	})),

	// Copies: one box, so one draw however many there are.
	...[1000, 5000, 10000].map((n) => ({ name: `copies ${n}`, build: () => grid(box, lit, n, 0.9, 1.4) })),

	// Script: copies moved from JavaScript every frame.
	...[100, 1000, 3000].map((n) => ({
		name: `script moves ${n}`,
		build: () => {
			const meshes = grid(box, lit, n, 0.9, 1.4);
			const base = meshes.map((m) => [m.position.x, m.position.y, m.position.z]);
			return (t) => {
				for (let i = 0; i < meshes.length; i++) {
					const b = base[i];
					meshes[i].position.set(b[0], b[1] + 0.01 * Math.sin(t * 3 + i), b[2]);
				}
			};
		},
	})),

	// Features, on a middle scene: 100 lit balls (about 400k triangles) in front of a lit wall.
	...[
		{ name: 'mid scene' },
		{ name: 'mid scene, sun shadow', shadow: true },
		{ name: 'mid scene, no prepass', prepass: false },
		{ name: 'mid scene, with prepass', prepass: true },
		{ name: 'mid scene, foveation off', foveation: 'off' },
		{ name: 'mid scene, foveation high', foveation: 'high' },
	].map((s) => ({ ...s, build: () => { fill(lit, 1); grid(ball, lit, 100, 0.5, 0.9); } })),
];

let index = -1;
let phase = 'wait'; // wait -> settle -> measure
let since = 0;
let tick = null;
let frames = 0;
let jsMs = 0;
let hostMs = 0;
let trackedFrames = 0;

function clear() {
	for (const child of [...stage.children]) stage.remove(child);
	setLamps(0);
	tick = null;
}

function apply(setup) {
	clear();
	placeStage();
	three.depthPrepass = setup.prepass ?? DEFAULT_PREPASS;
	three.light.shadow = setup.shadow ? { enabled: true, distance: 3 } : false;
	if (three.xr.presenting) three.xr.foveation = setup.foveation ?? 'medium';
	setLamps(setup.lamps ?? 0);
	tick = setup.build() ?? null;
	if (typeof tick !== 'function') tick = null;
}

function report(setup) {
	const stats = three.stats();
	const n = Math.max(frames, 1);
	const seconds = MEASURE_MS / 1000;
	const moved = retries >= MAX_RETRIES ? ' (the head kept moving)' : '';
	console.log(`bench: end ${setup.name} | frames ${frames}, fps ${(frames / seconds).toFixed(1)}, js ${(jsMs / n).toFixed(2)} ms, engine ${(hostMs / n).toFixed(2)} ms | ${stats.drawCalls} draws, ${stats.instances} copies, ${(stats.triangles / 1000).toFixed(0)}k triangles${moved}`);
}

// How many times one setup starts again for a moving head before it is measured anyway.
const MAX_RETRIES = 10;
let retries = 0;

three.setAnimationLoop((ms) => {
	if (tick) tick(ms / 1000);

	if (phase === 'wait') {
		// The head reads where the desktop camera was for the first frames, so wait for it to be
		// tracked a while before building in front of it.
		const ready = three.xr.presenting ? three.xr.head.tracked : true;
		trackedFrames = ready ? trackedFrames + 1 : 0;
		if (trackedFrames < 30) return;
		console.log(`bench: ${SETUPS.length} setups, ${SETTLE_MS} ms to settle and ${MEASURE_MS} ms measured each`);
		phase = 'next';
	}

	if (phase === 'next') {
		index++;
		if (index >= SETUPS.length) {
			clear();
			console.log('bench: done');
			phase = 'done';
			return;
		}
		retries = 0;
		apply(SETUPS[index]);
		phase = 'settle';
		since = ms;
		return;
	}

	// A moved head sees a different scene: start this setup again where the head is now.
	if ((phase === 'settle' || phase === 'measure') && retries < MAX_RETRIES && headMoved()) {
		retries++;
		console.log(`bench: the head moved, starting ${SETUPS[index].name} again`);
		apply(SETUPS[index]);
		phase = 'settle';
		since = ms;
		return;
	}

	if (phase === 'settle' && ms - since >= SETTLE_MS) {
		console.log(`bench: begin ${SETUPS[index].name}`);
		phase = 'measure';
		since = ms;
		frames = 0;
		jsMs = 0;
		hostMs = 0;
		return;
	}

	if (phase === 'measure') {
		// The frame before this one, which is complete.
		const spent = three.frame.ms;
		jsMs += spent.total;
		hostMs += spent.host;
		frames++;
		if (ms - since >= MEASURE_MS) {
			report(SETUPS[index]);
			phase = 'next';
		}
	}
});
