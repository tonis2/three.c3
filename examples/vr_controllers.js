// vr_controllers.js — both hands on the headset: grab, throw, push, walk, turn,
// and the room behind it all.
//
//   ./build/three --script examples/vr_controllers.js      # the mouse and keys are the hands
//   packaging/android/build-apk.sh examples/vr_controllers.js --run
//   packaging/android/quest.sh push examples/vr_controllers.js
//
// Squeeze near a cube to hold it and let go to throw it. The trigger pushes
// what a laser points at. The left stick walks, the right stick turns. A shows
// the room; B brings the cubes back.
//
// At a desk: the pointer is the right hand, its left button the trigger, its
// right button squeeze, 1 and 2 are A and B; Q and E are the left hand's
// trigger and squeeze, WASD its stick, the arrows the right stick.

const scene = new three.Scene();
scene.background = 0x10141c;
three.light.set([-0.4, -1, -0.3], 0.6);
// Does nothing on a headset, where the controllers are the hands.
three.xr.emulate = true;

const matte = new three.MeshLambertMaterial({});

const floor = new three.Mesh(new three.BoxGeometry(12, 0.1, 12), matte);
floor.position.set(0, -0.05, 0);
floor.color = [0.16, 0.17, 0.21];
scene.add(floor);
three.physics.add(floor, { shape: 'box', mass: 0, friction: 0.8 });

const table = new three.Mesh(new three.BoxGeometry(1.2, 0.76, 0.6), matte);
table.position.set(0, 0.38, -0.7);
table.color = [0.36, 0.26, 0.18];
scene.add(table);
three.physics.add(table, { shape: 'box', mass: 0, friction: 0.8 });

// 8 cm cubes in a row on the table.
const cubeShape = new three.BoxGeometry(0.08, 0.08, 0.08);
const cubes = [];
const homes = [];
for (let i = 0; i < 6; i++) {
	const cube = new three.Mesh(cubeShape, matte);
	homes.push([-0.4 + i * 0.16, 0.8, -0.65]);
	cube.position.set(...homes[i]);
	cube.color = [0.3 + 0.12 * i, 0.55, 0.95 - 0.12 * i];
	scene.add(cube);
	three.physics.add(cube, { shape: 'box', mass: 0.3, friction: 0.7 });
	cubes.push(cube);
}

const controllerShape = new three.BoxGeometry(0.04, 0.03, 0.12);
const laserShape = new three.BoxGeometry(0.004, 0.004, 1);
const palmShape = new three.SphereGeometry(0.03, 12, 8);

// Per hand: a model on the grip and a laser on the aim, both left out of
// raycasts, and a hidden ball the held cube is jointed to. The ball is a
// kinematic body only while it holds something (`grab`). Solid all the time,
// it shoved whatever the hand reached past, and on letting go it shoved the
// cube itself, which the joint had been holding inside it.
const hands = [three.xr.left, three.xr.right].map((xr) => {
	const model = new three.Mesh(controllerShape, matte);
	model.color = [0.82, 0.82, 0.86];
	model.collides = false;
	xr.grip.add(model);

	const laser = new three.Mesh(laserShape, matte);
	laser.color = [1, 0.35, 0.2];
	laser.collides = false;
	xr.aim.add(laser);

	const palm = new three.Mesh(palmShape, matte);
	palm.visible = false;
	palm.collides = false;
	scene.add(palm);

	return { xr, laser, palm, held: null, last: null, velocity: [0, 0, 0] };
});

const REACH = 5;
const GRAB_RADIUS = 0.09;
const WALK_SPEED = 1.5;
const TURN_STEP = 30;

let lastMs = null;
let started = false;
let turnArmed = true;

function nearestCube(at) {
	let best = null;
	let bestDistance = GRAB_RADIUS;
	for (const cube of three.query.sphere(at, GRAB_RADIUS)) {
		if (!cubes.includes(cube)) continue;
		const p = cube.position;
		const d = Math.hypot(p.x - at[0], p.y - at[1], p.z - at[2]);
		if (d <= bestDistance) {
			best = cube;
			bestDistance = d;
		}
	}
	return best;
}

function grab(hand, cube) {
	three.physics.add(hand.palm, { shape: 'sphere', kinematic: true });
	three.physics.joint(hand.palm, cube, { type: 'fixed' });
	hand.held = cube;
}

function letGo(hand) {
	if (hand.held === null) return;
	// Taking the palm's body away takes its joint with it.
	three.physics.remove(hand.palm);
	three.physics.setVelocity(hand.held, hand.velocity);
	hand.held = null;
}

three.setAnimationLoop((ms) => {
	const dt = lastMs === null ? 1 / 72 : Math.max((ms - lastMs) / 1000, 1e-3);
	lastMs = ms;

	// On the first frame, because a headset is presenting by then: at a desk
	// the player stands 1.6 m tall, a little back from the table, looking down.
	if (!started) {
		started = true;
		three.camera.lookAt(0, three.xr.presenting ? 0 : 1.6, 0.3);
		three.camera.orbit(0, three.xr.presenting ? 0 : 25, 0);
	}

	for (const hand of hands) {
		const { xr } = hand;
		if (!xr.connected) {
			letGo(hand);
			hand.last = null;
			continue;
		}
		const g = xr.grip.position;
		const at = [g.x, g.y, g.z];
		// Averaged over about 50 ms. One frame's step at 120 Hz is mostly
		// tracking noise, and handed to a cube set down gently it kicks it.
		if (hand.last === null) {
			hand.velocity = [0, 0, 0];
		} else {
			const k = Math.min(1, dt / 0.05);
			hand.velocity = hand.velocity.map((v, i) => v + ((at[i] - hand.last[i]) / dt - v) * k);
		}
		hand.last = at;
		hand.palm.position.set(...at);

		const aim = xr.aim;
		const hit = scene.raycast(aim.position, aim.direction);
		const length = hit !== null ? Math.min(hit.distance, REACH) : REACH;
		hand.laser.scale.set(1, 1, length);
		hand.laser.position.set(0, 0, -length / 2);

		if (xr.pressed('squeeze') && hand.held === null) {
			const cube = nearestCube(at);
			if (cube !== null) {
				grab(hand, cube);
				xr.vibrate(0.8, 0.12);
			}
		}
		if (xr.released('squeeze')) letGo(hand);

		if (xr.pressed('trigger') && hit !== null && cubes.includes(hit.object)) {
			const d = aim.direction;
			three.physics.applyImpulse(hit.object, [d.x * 0.5, d.y * 0.5, d.z * 0.5], [hit.point.x, hit.point.y, hit.point.z]);
			xr.vibrate(0.5, 0.06);
		}
	}

	// Walk where the rig faces; -Z is ahead before any turn.
	const [sx, sy] = three.xr.left.thumbstick;
	if (Math.hypot(sx, sy) > 0.15) {
		const yaw = three.camera.yaw * Math.PI / 180;
		const t = three.camera.target;
		const step = WALK_SPEED * dt;
		const ahead = [-Math.sin(yaw), -Math.cos(yaw)];
		const side = [Math.cos(yaw), -Math.sin(yaw)];
		three.camera.lookAt(t.x + (ahead[0] * sy + side[0] * sx) * step, t.y, t.z + (ahead[1] * sy + side[1] * sx) * step);
	}

	// Snap turns: smooth turning in a headset makes people sick.
	const [tx] = three.xr.right.thumbstick;
	if (Math.abs(tx) < 0.3) turnArmed = true;
	if (turnArmed && Math.abs(tx) > 0.7) {
		turnArmed = false;
		three.camera.orbit(three.camera.yaw - Math.sign(tx) * TURN_STEP);
	}

	if (three.xr.right.pressed('a') && three.xr.passthroughSupported) {
		three.xr.passthrough = !three.xr.passthrough;
		floor.visible = !three.xr.passthrough;
	}

	if (three.xr.right.pressed('b')) {
		for (const hand of hands) letGo(hand);
		cubes.forEach((cube, i) => {
			three.physics.remove(cube);
			cube.position.set(...homes[i]);
			cube.rotation.set(0, 0, 0);
			three.physics.add(cube, { shape: 'box', mass: 0.3, friction: 0.7 });
		});
	}
});
