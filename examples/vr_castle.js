// vr_castle.js — knock a toy castle off a table in VR, with both hands: grab,
// throw, push, walk and turn, by the light of three lamps, with a board that
// counts. A small cousin of Tabletop Siege (github.com/tonis2/tabletop-siege).
//
//   ./build/three --script examples/vr_castle.js      # the mouse and keys are the hands
//   packaging/android/build-apk.sh examples/vr_castle.js --run
//   packaging/android/quest.sh push examples/vr_castle.js
//
// Squeeze near a ball or a block to hold it and let go to throw it. The trigger
// pushes what a laser points at. The left stick walks, the right stick turns.
// A shows the room; B builds the castle again.
//
// At a desk: the pointer is the right hand, its left button the trigger, its
// right button squeeze, 1 and 2 are A and B; Q and E are the left hand's
// trigger and squeeze, WASD its stick, the arrows the right stick.

const scene = new three.Scene();
scene.background = 0x141826;
// A dim moon, so the lamps light the table.
three.light.set([-0.4, -1, -0.3], 0.3);
// Does nothing on a headset, where the controllers are the hands.
three.xr.emulate = true;

const matte = new three.MeshLambertMaterial({});

function box(size, at, color, body) {
	const mesh = new three.Mesh(new three.BoxGeometry(...size), matte);
	mesh.position.set(...at);
	mesh.color = color;
	scene.add(mesh);
	if (body) three.physics.add(mesh, { shape: 'box', mass: 0, friction: 0.8 });
	return mesh;
}

const floor = box([12, 0.1, 12], [0, -0.05, 0], [0.16, 0.17, 0.21], true);
const TABLE_TOP = 0.76;
box([1.4, TABLE_TOP, 0.8], [0, TABLE_TOP / 2, -1], [0.36, 0.26, 0.18], true);

// Three lamps on posts round the table: a light each, and a bulb that glows.
const bulbShape = new three.SphereGeometry(0.04, 12, 8);
const bulbGlow = new three.MeshLambertMaterial({ emissive: 0xffb060, emissiveIntensity: 2 });
const lamps = [[-0.95, -0.7], [0.95, -0.7], [0, -1.7]].map(([x, z]) => {
	box([0.04, 1.3, 0.04], [x, 0.65, z], [0.2, 0.18, 0.16], true);
	const bulb = new three.Mesh(bulbShape, bulbGlow);
	bulb.position.set(x, 1.34, z);
	bulb.collides = false;
	scene.add(bulb);
	return three.lights.add({ position: [x, 1.34, z], range: 3, color: 0xffb060, intensity: 2 });
});

// The castle: toy blocks, stacked and loose, two towers and a wall between.
const BLOCK = 0.06;
const blockShape = new three.BoxGeometry(BLOCK, BLOCK, BLOCK);
const blocks = [];

function buildCastle() {
	for (const block of blocks) {
		three.physics.remove(block);
		scene.remove(block);
	}
	blocks.length = 0;
	const lay = (i, y, k) => {
		const block = new three.Mesh(blockShape, matte);
		block.position.set(i * BLOCK, TABLE_TOP + (y + 0.5) * BLOCK, -1.15 + k * BLOCK);
		const shade = 0.62 + 0.12 * (((i * 7 + y * 3 + k * 5) % 4) / 3);
		block.color = [shade, shade * 0.97, shade * 0.92];
		scene.add(block);
		three.physics.add(block, { shape: 'box', mass: 0.15, friction: 0.6, angularDamping: 1 });
		blocks.push(block);
	};
	for (const x of [-4, 3]) {
		for (let y = 0; y < 6; y++) for (let i = 0; i < 2; i++) for (let k = 0; k < 2; k++) lay(x + i, y, k);
	}
	for (let y = 0; y < 3; y++) for (let i = -2; i < 3; i++) lay(i, y, 0.5);
}

// Balls to throw, in a row at the near edge of the table.
const ballShape = new three.SphereGeometry(0.035, 16, 10);
const balls = [];
for (let i = 0; i < 4; i++) {
	const ball = new three.Mesh(ballShape, matte);
	ball.color = [0.75, 0.2, 0.15];
	scene.add(ball);
	balls.push(ball);
}

function setBalls() {
	balls.forEach((ball, i) => {
		three.physics.remove(ball);
		ball.position.set(0.25 + i * 0.1, TABLE_TOP + 0.04, -0.7);
		three.physics.add(ball, { shape: 'sphere', mass: 0.3, friction: 0.6, angularDamping: 1 });
	});
}

// A board on the table counting the blocks knocked off it, in seven-segment
// digits of glowing boxes. The interface layer is drawn once across both eyes,
// so on a headset a count belongs in the world.
const SEGMENTS = [0x3f, 0x06, 0x5b, 0x4f, 0x66, 0x6d, 0x7d, 0x07, 0x7f, 0x6f];
const lit = new three.MeshLambertMaterial({ emissive: 0x7fd4ff, emissiveIntensity: 1.5 });
const board = box([0.2, 0.12, 0.015], [-0.55, TABLE_TOP + 0.08, -1.3], [0.12, 0.11, 0.1], false);
// Turned toward the player before its body is made, which takes the turn as built.
board.rotation.y = 0.4;
three.physics.add(board, { shape: 'box', mass: 0, friction: 0.8 });
const across = new three.BoxGeometry(0.028, 0.008, 0.004);
const upright = new three.BoxGeometry(0.008, 0.03, 0.004);

function digit(x) {
	const places = [[0, 0.032, across], [0.018, 0.016, upright], [0.018, -0.016, upright], [0, -0.032, across],
		[-0.018, -0.016, upright], [-0.018, 0.016, upright], [0, 0, across]];
	return places.map(([sx, sy, shape]) => {
		const segment = new three.Mesh(shape, matte);
		segment.position.set(x + sx, sy, 0.01);
		segment.color = [0.08, 0.08, 0.09];
		segment.collides = false;
		board.add(segment);
		return segment;
	});
}

const digits = [digit(-0.025), digit(0.025)];
function showCount(n) {
	const text = String(Math.min(n, 99)).padStart(2, ' ');
	digits.forEach((segments, d) => {
		const bits = text[d] === ' ' ? 0 : SEGMENTS[+text[d]];
		segments.forEach((segment, k) => { segment.material = bits & (1 << k) ? lit : matte; });
	});
}

// At a desk, the same count and a button, on the interface.
const { Panel, Label, Button } = three.ui;
class Hud extends three.Widget {
	down = 0;
	render() {
		return new Panel({ at: 'top-left', margin: 16, gap: 8 },
			new Label(`blocks off the table: ${this.down} of ${blocks.length}`, { size: 18 }),
			new Button('Build it again', () => rebuild()),
		);
	}
}
const hud = new Hud();

// Per hand: a model on the grip and a laser on the aim, both left out of
// raycasts, and a hidden ball the held thing is jointed to. The engine keeps
// the ball on the grip (`track`), placed before the physics step, so what is
// held is where the hand is this frame. The ball is a kinematic body only
// while it holds something: solid all the time, it shoved whatever the hand
// reached past.
const controllerShape = new three.BoxGeometry(0.04, 0.03, 0.12);
const laserShape = new three.BoxGeometry(0.004, 0.004, 1);
const palmShape = new three.SphereGeometry(0.03, 12, 8);
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
	xr.track(palm);

	return { xr, laser, palm, held: null };
});

const REACH = 5;
const GRAB_RADIUS = 0.09;
const WALK_SPEED = 1.5;
const TURN_STEP = 30;
const grabbable = (object) => balls.includes(object) || blocks.includes(object);

function nearest(at) {
	let best = null;
	let bestDistance = GRAB_RADIUS;
	for (const object of three.query.sphere(at, GRAB_RADIUS)) {
		if (!grabbable(object)) continue;
		const p = object.position;
		const d = Math.hypot(p.x - at[0], p.y - at[1], p.z - at[2]);
		if (d <= bestDistance) {
			best = object;
			bestDistance = d;
		}
	}
	return best;
}

function grab(hand, object) {
	three.physics.add(hand.palm, { shape: 'sphere', kinematic: true });
	three.physics.joint(hand.palm, object, { type: 'fixed' });
	hand.held = object;
}

// Thrown with what the headset measured the hand doing: smoother than any
// difference of two poses, and with the flick of the wrist as spin.
let thrower = null;
function letGo(hand) {
	if (hand.held === null) return;
	// Taking the palm's body away takes its joint with it.
	three.physics.remove(hand.palm);
	const v = hand.xr.grip.velocity;
	const w = hand.xr.grip.angularVelocity;
	three.physics.setVelocity(hand.held, [v.x, v.y, v.z]);
	three.physics.setAngularVelocity(hand.held, [w.x, w.y, w.z]);
	hand.held = null;
	thrower = hand;
}

function rebuild() {
	for (const hand of hands) letGo(hand);
	buildCastle();
	setBalls();
}

// A ball hitting the castle buzzes the hand that threw it.
three.onContact(({ type, a, b }) => {
	if (type !== 'start' || thrower === null) return;
	if ((balls.includes(a) && blocks.includes(b)) || (balls.includes(b) && blocks.includes(a))) thrower.xr.vibrate(0.6, 0.06);
});

let lastMs = null;
let started = false;
let turnArmed = true;

three.setAnimationLoop((ms) => {
	const dt = lastMs === null ? 1 / 72 : Math.max((ms - lastMs) / 1000, 1e-3);
	lastMs = ms;

	// On the first frame, because a headset is presenting by then: at a desk
	// the player stands 1.6 m tall, a little back from the table, looking down.
	if (!started) {
		started = true;
		three.camera.lookAt(0, three.xr.presenting ? 0 : 1.6, 0.2);
		three.camera.orbit(0, three.xr.presenting ? 0 : 25, 0);
		rebuild();
		if (!three.xr.presenting) hud.mount();
	}
	// A step every frame, so a held ball moves as smoothly as the hand.
	three.physics.rate = three.xr.refreshRate || 60;

	for (const hand of hands) {
		const { xr } = hand;
		if (!xr.connected) {
			letGo(hand);
			continue;
		}
		const g = xr.grip.position;
		const aim = xr.aim;
		const hit = scene.raycast(aim.position, aim.direction);
		const length = hit !== null ? Math.min(hit.distance, REACH) : REACH;
		hand.laser.scale.set(1, 1, length);
		hand.laser.position.set(0, 0, -length / 2);

		if (xr.pressed('squeeze') && hand.held === null) {
			const object = nearest([g.x, g.y, g.z]);
			if (object !== null) {
				grab(hand, object);
				xr.vibrate(0.8, 0.12);
			}
		}
		if (xr.released('squeeze')) letGo(hand);

		if (xr.pressed('trigger') && hit !== null && grabbable(hit.object)) {
			const d = aim.direction;
			three.physics.applyImpulse(hit.object, [d.x * 0.3, d.y * 0.3, d.z * 0.3], [hit.point.x, hit.point.y, hit.point.z]);
			thrower = hand;
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
	if (three.xr.right.pressed('b')) rebuild();

	// The lamps flicker a little, each to its own beat.
	const t = ms / 1000;
	lamps.forEach((lamp, i) => { lamp.intensity = 2 + 0.25 * Math.sin(t * (7 + i * 2.3)) * Math.sin(t * (3.1 + i)); });

	const down = blocks.filter((block) => block.position.y < TABLE_TOP).length;
	showCount(down);
	if (hud.down !== down) hud.down = down;
});
