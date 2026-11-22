// siege/probe.js — how many welded blocks the headset can knock down at frame rate.
//
//   packaging/android/quest.sh push examples/siege/probe.js
//   packaging/android/quest.sh logs | grep probe
//   ./build/three --script examples/siege/probe.js
//
// Builds a castle of 10 cm blocks on a plinth 3 m ahead at 100, 200 and 300
// blocks, welded to the block below and the one beside. For each size it
// measures the solver while the castle stands, while stones hit it, and while
// it falls apart with every weld gone, then logs one line. It runs on its own,
// so nobody has to aim.

const SIZES = [100, 200, 300];
// The display rate to measure at on a headset; the world steps once a frame.
// `adb shell setprop debug.oculus.refreshRate` overrides it while it is set.
const HZ = 90;
const BLOCK = 0.1;
const LAYERS = 10;
const PLINTH_TOP = 0.7;
const CASTLE_Z = -3;
const WELD = { type: 'fixed', breakForce: 250, breakTorque: 40 };

// Seconds each phase runs; only the second half of `settle` is measured, after
// the castle has had time to fall asleep.
const SETTLE = 3;
const HITS = 4;
const FALL = 5;
const STONE_EVERY = 0.25;
const STONE_SPEED = 14;

const scene = new three.Scene();
scene.background = 0x8aa4c0;
three.light.set([-0.5, -1, -0.4], 0.9);


const stone = new three.MeshLambertMaterial({});
const ground = new three.Mesh(new three.BoxGeometry(20, 0.1, 20), stone);
ground.position.set(0, -0.05, 0);
ground.color = [0.3, 0.42, 0.25];
scene.add(ground);
three.physics.add(ground, { shape: 'box', mass: 0, friction: 0.8 });

const plinth = new three.Mesh(new three.BoxGeometry(2, PLINTH_TOP, 2), stone);
plinth.position.set(0, PLINTH_TOP / 2, CASTLE_Z);
plinth.color = [0.45, 0.43, 0.4];
scene.add(plinth);
three.physics.add(plinth, { shape: 'box', mass: 0, friction: 0.8 });

const blockShape = new three.BoxGeometry(BLOCK, BLOCK, BLOCK);
const stoneShape = new three.SphereGeometry(0.04, 12, 8);

// A rectangular ring of walls, `w` by `d` blocks, `LAYERS` high: 2(w + d) - 4
// blocks a layer. 100, 200 and 300 come out exactly.
function ringFor(count) {
	const perLayer = count / LAYERS;
	const w = Math.ceil((perLayer + 4) / 4);
	return [w, (perLayer + 4) / 2 - w];
}

let blocks = [];
let welds = [];
let stones = [];

function build(count) {
	const [w, d] = ringFor(count);
	const x0 = -(w - 1) * BLOCK / 2;
	const z0 = CASTLE_Z - (d - 1) * BLOCK / 2;
	const ring = [];
	for (let i = 0; i < w; i++) ring.push([i, 0]);
	for (let j = 1; j < d; j++) ring.push([w - 1, j]);
	for (let i = w - 2; i >= 0; i--) ring.push([i, d - 1]);
	for (let j = d - 2; j > 0; j--) ring.push([0, j]);

	const layers = [];
	for (let y = 0; y < LAYERS; y++) {
		const layer = ring.map(([i, j], k) => {
			const block = new three.Mesh(blockShape, stone);
			block.position.set(x0 + i * BLOCK, PLINTH_TOP + (y + 0.5) * BLOCK, z0 + j * BLOCK);
			const shade = 0.55 + 0.1 * ((i * 7 + j * 3 + y * 5) % 4) / 3;
			block.color = [shade, shade * 0.96, shade * 0.9];
			scene.add(block);
			three.physics.add(block, { shape: 'box', mass: 0.6, friction: 0.7, restitution: 0.05 });
			blocks.push(block);
			return block;
		});
		layer.forEach((block, k) => {
			welds.push(three.physics.joint(block, layer[(k + 1) % layer.length], WELD));
			if (y > 0) welds.push(three.physics.joint(layers[y - 1][k], block, WELD));
		});
		layers.push(layer);
	}
}

function clear() {
	for (const each of [...blocks, ...stones]) {
		three.physics.remove(each);
		scene.remove(each);
	}
	blocks = [];
	welds = [];
	stones = [];
}

function throwStone(t) {
	const s = new three.Mesh(stoneShape, stone);
	s.color = [0.3, 0.3, 0.32];
	const sway = Math.sin(t * 7.3) * 0.35;
	const lift = Math.cos(t * 5.1) * 0.25;
	s.position.set(sway, 1.4, -0.5);
	scene.add(s);
	three.physics.add(s, { shape: 'sphere', mass: 0.5, friction: 0.6, restitution: 0.1 });
	// Aimed at the castle's middle, a little high: gravity drops it on the way.
	const to = [-sway * 0.6, PLINTH_TOP + LAYERS * BLOCK * 0.5 + 0.35 + lift - 1.4, CASTLE_Z + 0.5];
	const length = Math.hypot(...to);
	three.physics.setVelocity(s, to.map((v) => v / length * STONE_SPEED));
	stones.push(s);
}

// Per phase, averaged over its frames: the solver, the rest of the engine's
// frame (`host`) and the script, in milliseconds.
function meter() {
	return { frames: 0, solver: 0, solverMax: 0, host: 0, script: 0 };
}
function sample(m) {
	const ms = three.frame.ms;
	m.frames++;
	m.solver += ms.solver;
	m.solverMax = Math.max(m.solverMax, ms.solver);
	m.host += ms.host;
	m.script += ms.total;
}
function line(m) {
	const n = Math.max(m.frames, 1);
	const f = (v) => (v / n).toFixed(2);
	return `solver ${f(m.solver)} (max ${m.solverMax.toFixed(2)}), host ${f(m.host)}, script ${f(m.script)}`;
}

let broken = 0;
three.onJointBreak(() => broken++);

let size = 0;
let phase = 'settle';
let phaseStart = null;
let nextStone = 0;
let meters = {};
let started = false;

function begin(name, now) {
	phase = name;
	phaseStart = now;
	meters[name] = meter();
}

function report() {
	console.log(
		`probe: ${SIZES[size]} blocks, ${welds.length} welds, ${three.physics.rate} Hz, ` +
		`${three.physics.substeps} substeps, budget ${(1000 / (three.xr.refreshRate || 60)).toFixed(1)} ms`
	);
	console.log(`probe:   standing ${line(meters.settle)}`);
	console.log(`probe:   hits     ${line(meters.hits)}, ${broken} welds broke`);
	console.log(`probe:   falling  ${line(meters.fall)}`);
}

three.setAnimationLoop((ms) => {
	const now = ms / 1000;
	// A step every frame, at whatever rate the headset runs.
	if (three.xr.presenting && three.xr.refreshRate !== HZ) three.xr.refreshRate = HZ;
	three.physics.rate = three.xr.refreshRate || 60;
	if (!started) {
		started = true;
		three.camera.lookAt(0, three.xr.presenting ? 0 : 1.6, 0);
		three.camera.orbit(0, three.xr.presenting ? 0 : 12, 0);
		build(SIZES[size]);
		broken = 0;
		begin('settle', now);
		return;
	}
	const t = now - phaseStart;

	if (phase === 'settle') {
		if (t > SETTLE / 2) sample(meters.settle);
		if (t > SETTLE) {
			begin('hits', now);
			nextStone = now;
		}
	} else if (phase === 'hits') {
		sample(meters.hits);
		if (now >= nextStone) {
			throwStone(now);
			nextStone += STONE_EVERY;
		}
		if (t > HITS) {
			// The worst a game can see: every block loose and tumbling at once.
			for (const id of welds) three.physics.removeJoint(id);
			for (const block of blocks) {
				const p = block.position;
				three.physics.applyImpulse(block, [p.x * 0.4, 0.6, (p.z - CASTLE_Z) * 0.4]);
			}
			begin('fall', now);
		}
	} else if (phase === 'fall') {
		sample(meters.fall);
		if (t > FALL) {
			report();
			clear();
			size = (size + 1) % SIZES.length;
			if (size === 0) console.log('probe: again from the smallest');
			build(SIZES[size]);
			broken = 0;
			begin('settle', now);
		}
	}
});
