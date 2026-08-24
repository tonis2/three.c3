// camera.js — the camera following something
//
// Run it:
//
//     ./build/three --script examples/camera.js
//     ./build/three --script examples/camera.js --mcp   # and attach an agent to it
//
// Keys:
//
//     1   third person, rigid      — the camera is welded to the walker
//     2   third person, lag 250ms  — the same camera, late on purpose
//     3   first person             — distance 0, and the mouse looks
//     0   detach                   — back to the turntable
//     space  start and stop the walk
//     w/s    walk, a/d turn        — works in every mode
//
// What it is here to show
// -----------------------
// **`attach` owns the orbit point and nothing else.** In modes 1 and 2 the
// mouse controls are left ON, so a drag still orbits around the walker and the
// wheel still zooms while the camera is following it. Try it: the camera stays
// glued to the walker and you are moving the eye around it. What you cannot do
// is *pan* — a pan writes the orbit point and the next frame writes it back,
// which is the one gesture `attach` takes away and the reason it says so.
//
// **First person is not a mode, it is `distance: 0`.** The eye sits on the
// point it orbits, which is the head. Nothing else about the camera changes —
// the same `orbit(yaw, pitch)` aims it — so scrolling back out would be a
// third-person camera again with nothing to switch. Press 3 then 2 and back.
//
// **Lag is a time, not a number of frames.** Mode 2 is 250 ms of catch-up,
// which is deliberately far too much: the walker turns a corner and the camera
// arrives afterwards. The point of the number being a time constant is that it
// means the same lateness whatever the frame rate.
//
// **The follow runs last in the frame.** The walker below moves inside the
// animation callback, and the camera is already on it in the same frame — not
// one behind. That is the whole reason this is a host verb rather than three
// lines of JavaScript setting `camera.target` every tick.

const scene = new three.Scene();
scene.background = 0x87a8c8;
three.light.set([0.4, 0.85, 0.35], 0.32);
three.light.shadow = { enabled: true, size: 2048, intensity: 0.55 };

// ---------------------------------------------------------------------------
// Somewhere to walk

const ground = new three.Mesh(new three.PlaneGeometry(120, 120), new three.MeshLambertMaterial());
ground.rotation.x = -Math.PI / 2;
ground.color = 0x5d7a3a;
scene.add(ground);

// Landmarks, so motion is obvious and so there is something to be inside of.
// One geometry and one material, so all of them together are one draw call.
const PILLAR = new three.BoxGeometry(2, 6, 2);
const stone = new three.MeshLambertMaterial();

for (let ring = 0; ring < 3; ring++) {
	const radius = 10 + ring * 11;
	const count = 8 + ring * 4;
	for (let i = 0; i < count; i++) {
		const a = (i / count) * Math.PI * 2 + ring * 0.3;
		const p = new three.Mesh(PILLAR, stone);
		p.position.set(Math.cos(a) * radius, 3, Math.sin(a) * radius);
		p.scale.y = 0.6 + ((i * 7) % 5) * 0.35;
		p.position.y = 3 * p.scale.y;
		// Per copy, so a hundred different stones are still one draw call.
		p.color = [0.55 + ((i * 3) % 4) * 0.08, 0.5, 0.42];
		scene.add(p);
	}
}

// A post at the origin, so "where am I" always has an answer.
const post = new three.Mesh(new three.CylinderGeometry(0.3, 0.3, 10, 12), stone);
post.position.y = 5;
post.color = 0xd8d0c0;
scene.add(post);

// ---------------------------------------------------------------------------
// The walker
//
// A Group with a body under it: the group is what the camera attaches to, and
// what `position` and `rotation` are written on. The pieces are children, so
// they come along without any of them being the thing the camera follows.

const walker = new three.Group();
walker.name = 'walker';
// Out in the gap between the first and second ring, not on the origin — the
// post is there, and a camera seven units behind a walker standing inside a
// pillar sees the pillar.
walker.position.set(0, 0, 16);
scene.add(walker);

const skin = new three.MeshLambertMaterial();

const body = new three.Mesh(new three.CylinderGeometry(0.4, 0.5, 1.4, 12), skin);
body.position.y = 0.9;
body.color = 0xc25b3a;
walker.add(body);

const head = new three.Mesh(new three.SphereGeometry(0.32, 16, 12), skin);
head.position.y = 1.85;
head.color = 0xe0b28c;
walker.add(head);

// Pointing at -Z, which is the way a heading of zero faces. Without something
// asymmetric there is no way to see which way the walker is turned in third
// person, and no way to tell that first person agrees with it.
const nose = new three.Mesh(new three.ConeGeometry(0.18, 0.5, 10), skin);
nose.rotation.x = -Math.PI / 2;
nose.position.set(0, 1.85, -0.42);
nose.color = 0xffd24a;
walker.add(nose);

// ---------------------------------------------------------------------------
// Walking

// Degrees, and shared with the camera: `three.camera.orbit(heading, ...)` puts
// the eye behind the walker, because the camera's yaw names where the *eye*
// stands relative to the point it orbits.
let heading = 0;
let auto = true;

const WALK = 6.5;   // units a second
const TURN = 90;    // degrees a second

function forward() {
	const r = heading * Math.PI / 180;
	return [-Math.sin(r), -Math.cos(r)];
}

// ---------------------------------------------------------------------------
// The four camera modes

const HEAD = [0, 1.85, 0];   // where the eyes are, in world space

const MODES = {
	'1': () => {
		three.controls.enabled = true;
		three.camera.attach(walker, { offset: [0, 1.4, 0], distance: 7, lag: 0 });
		three.camera.orbit(heading, 18);
		return 'third person, rigid — drag to orbit around it, wheel to zoom';
	},
	'2': () => {
		three.controls.enabled = true;
		three.camera.attach(walker, { offset: [0, 1.4, 0], distance: 7, lag: 250 });
		three.camera.orbit(heading, 18);
		return 'third person, 250 ms of lag — turn a corner and watch it arrive late';
	},
	'3': () => {
		// The mouse belongs to the look now, not to the turntable: without this
		// a drag would orbit the camera at the same time as the look turns it.
		three.controls.enabled = false;
		three.camera.attach(walker, { offset: HEAD, distance: 0 });
		three.camera.orbit(heading, 0);
		return 'first person — move the mouse to look';
	},
	'0': () => {
		three.camera.detach();
		three.controls.enabled = true;
		three.camera.frameAll();
		return 'detached — the ordinary turntable, and frameAll() works again';
	},
};

let mode = '1';
function setMode(key) {
	mode = key;
	console.log(`[${key}] ${MODES[key]()}`);
}

for (const key of Object.keys(MODES)) three.onKeyDown(key, () => setMode(key));
three.onKeyDown('space', () => {
	auto = !auto;
	console.log(auto ? 'walking' : 'stopped');
});

// ---------------------------------------------------------------------------
// The frame


three.setAnimationLoop(() => {
	// The frame's own seconds, clamped by the host rather than by a
	// `Math.min` written out here — and zero while the clock is paused, which
	// is what makes a pause stop the walker with no flag to test.
	const dt = three.clock.dt;

	// Turning, by key and — in first person — by the mouse.
	if (three.input.isDown('a')) heading -= TURN * dt;
	if (three.input.isDown('d')) heading += TURN * dt;

	if (mode === '3') {
		// This is the whole of a mouse look: the frame's movement, scaled.
		// `dx` is differenced by the host against the previous frame's reading,
		// which is why it is the frame's movement and not the movement since
		// whenever this script last happened to ask.
		const p = three.input.pointer;
		heading += p.dx * 0.25;
		const pitch = Math.max(-70, Math.min(70, three.camera.pitch - p.dy * 0.25));
		three.camera.orbit(heading, pitch);
	}

	// Walking.
	let speed = 0;
	if (auto) speed = WALK * 0.55;
	if (three.input.isDown('w')) speed = WALK;
	if (three.input.isDown('s')) speed = -WALK * 0.6;

	// The walk curves on its own so the follow has corners to take.
	if (auto && !three.input.isDown('a') && !three.input.isDown('d')) heading += 22 * dt;

	if (speed !== 0) {
		const [fx, fz] = forward();
		walker.position.x += fx * speed * dt;
		walker.position.z += fz * speed * dt;
	}

	walker.rotation.y = -heading * Math.PI / 180;

	// **Nothing here writes the camera's position.** The walker moved, and the
	// camera is on it by the end of this same frame — the follow runs after
	// this callback returns, which is what stops the camera being a frame late.
});

setMode('1');

console.log('keys: 1 third-person rigid | 2 third-person lagged | 3 first person | 0 detach');
console.log('      space walk/stop, w/s walk, a/d turn');

return {
	mode: '1 — third person, rigid',
	drawCalls: three.stats().drawCalls,
	attached: three.camera.attached?.name ?? null,
};
