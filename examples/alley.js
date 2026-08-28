// alley.js — material.repeat / material.offset and the physics verbs
//
// Run it:
//
//     ./build/three --script examples/alley.js
//     ./build/three --script examples/alley.js --mcp   # and attach an agent to it
//
// or paste it into `run_script` against a `./build/three --mcp`.
//
// Once it is running, the keys are: space to roll, `r` to re-rack, `b` to
// bomb the stack from underneath, `a` to stop and start the auto-cycle. Left
// alone it rolls itself every ~7.7 seconds.
//
// What it is here to show
// -----------------------
// **One floor mesh, not four hundred.** The ground is a single
// PlaneGeometry(40, 40) with `repeat = [20, 20]`, so it shows 400 tiles. The
// tile image carries a border and an off-centre stud on purpose: a stretched
// texture shows one stud, a tiled one shows as many studs as it repeats, so
// the claim cannot be faked by an image that happens to look busy.
//
// **One brick image, two walls that disagree.** Textures are deduplicated by
// content, so loading the bricks twice is one texture slot. The uv transform
// lives on the *material* rather than on the texture, which is what lets the
// side wall scroll its `offset` every frame while the back wall stands still.
//
// **setVelocity assigns, applyImpulse adds.** The ball is given a speed; the
// capstone is given a push. An off-centre impulse is a shove and a tumble
// from one call.
//
// **A dynamic body refuses a transform write** — the solver owns it. So
// re-racking is not `position.set()`, it is remove the body, move the node,
// give it a body back. See `A.rerack` below.
//
// The whole scene is 5 draw calls and 14 instances: the ten crates are ten
// different tints and still one call, because colour is a per-copy channel.

function tileTexture(size, border, ink, face, stud) {
	const px = new Uint8Array(size * size * 4);
	for (let y = 0; y < size; y++) {
		for (let x = 0; x < size; x++) {
			const edge = x < border || y < border || x >= size - border || y >= size - border;
			const dot = (x - 14) ** 2 + (y - 14) ** 2 < 36;
			const c = edge ? ink : dot ? stud : face;
			const i = (y * size + x) * 4;
			px[i] = c[0]; px[i + 1] = c[1]; px[i + 2] = c[2]; px[i + 3] = 255;
		}
	}
	return new three.DataTexture(px, size, size);
}

function brickTexture(size) {
	const px = new Uint8Array(size * size * 4);
	const rowH = size / 4, brickW = size / 2, mortar = 3;
	for (let y = 0; y < size; y++) {
		for (let x = 0; x < size; x++) {
			const shift = (Math.floor(y / rowH) & 1) ? brickW / 2 : 0;
			const seam = (y % rowH) < mortar || ((x + shift) % brickW) < mortar;
			const c = seam ? [188, 184, 176] : [150, 74, 58];
			const i = (y * size + x) * 4;
			px[i] = c[0]; px[i + 1] = c[1]; px[i + 2] = c[2]; px[i + 3] = 255;
		}
	}
	return new three.DataTexture(px, size, size);
}

const scene = new three.Scene();
three.light.set([-0.45, -1, -0.35], 0.34);

const floorTex = tileTexture(64, 3, [96, 96, 104], [214, 212, 206], [120, 130, 158]);
const brickTex = brickTexture(64);

// One 40x40 mesh, twenty tiles across. Without repeat this is 400 planes.
const floorMat = new three.MeshLambertMaterial({ map: floorTex });
floorMat.repeat = [20, 20];
const ground = new three.Mesh(new three.PlaneGeometry(40, 40), floorMat);
ground.name = 'ground';
ground.rotation.x = -Math.PI / 2;
scene.add(ground);

// Same brick image, deduplicated to one texture slot; two materials, so the
// side wall can scroll its offset while the back wall stays put.
const wallMatA = new three.MeshLambertMaterial({ map: brickTex });
wallMatA.repeat = [10, 2.5];
const wallMatB = new three.MeshLambertMaterial({ map: brickTex });
wallMatB.repeat = [10, 2.5];

const backWall = new three.Mesh(new three.PlaneGeometry(40, 10), wallMatA);
backWall.position.set(0, 5, -20);
scene.add(backWall);
const sideWall = new three.Mesh(new three.PlaneGeometry(40, 10), wallMatB);
sideWall.position.set(-20, 5, 0);
sideWall.rotation.y = Math.PI / 2;
scene.add(sideWall);

three.physics.gravity = [0, -9.81, 0];
three.physics.add(ground, { shape: 'box', mass: 0, friction: 0.7, restitution: 0.05 });

const CRATE = { shape: 'box', mass: 1, friction: 0.6, restitution: 0.05 };
const BALL = { shape: 'sphere', mass: 6, friction: 0.35, restitution: 0.25 };

const boxGeo = new three.BoxGeometry(1, 1, 1);
const crateMat = new three.MeshLambertMaterial({ map: floorTex });
const stack = [], slots = [];
for (let row = 0; row < 4; row++) {
	for (let i = 0; i < 4 - row; i++) {
		const box = new three.Mesh(boxGeo, crateMat);
		box.name = `crate_${row}_${i}`;
		box.color = [0.55 + 0.12 * row, 0.45 + 0.08 * i, 0.35, 1];
		scene.add(box);
		stack.push(box);
		slots.push([-1.53 + row * 0.51 + i * 1.02, 0.5 + row * 1.01, -3]);
	}
}

const ball = new three.Mesh(new three.SphereGeometry(0.7, 32, 16), crateMat);
ball.name = 'ball';
ball.color = [0.25, 0.5, 0.85, 1];
scene.add(ball);

// Each run_script call has its own scope, so anything a later call needs to
// reach — or a key handler, or the animation loop — has to be kept here.
const A = globalThis.alley = {
	scene, ground, stack, slots, ball, floorMat, wallMatA, wallMatB,
	phase: 'racked', mark: 0, now: 0, auto: true, rolls: 0,
};

// A dynamic body refuses a transform write — the solver owns it, and a script
// and a solver writing the same transform every frame is jitter, not a
// compromise. So re-racking is: take the body away, move the node, give it a
// body back.
A.rerack = () => {
	A.stack.forEach((box, k) => {
		three.physics.remove(box);
		box.rotation.set(0, 0, 0);
		box.position.set(...A.slots[k]);
		three.physics.add(box, CRATE);
	});
	three.physics.remove(A.ball);
	A.ball.rotation.set(0, 0, 0);
	A.ball.position.set(11, 0.7, -3);
	three.physics.add(A.ball, BALL);
	A.phase = 'racked';
	A.mark = A.now;
};

// setVelocity assigns a speed; applyTorqueImpulse adds a spin with no shove,
// so it rolls the way it travels instead of skidding.
A.roll = () => {
	three.physics.setVelocity(A.ball, [-16, 1.2, 0]);
	three.physics.applyTorqueImpulse(A.ball, [0, 0, -9]);
	A.phase = 'rolling';
	A.mark = A.now;
	A.rolls++;
};

// An off-centre impulse: one call is both a shove and a tumble.
A.bomb = () => {
	for (const box of A.stack) {
		three.physics.applyImpulse(box, [0, 4.5, 0], [0.35, 0, 0.2]);
	}
};

three.onKeyDown('space', () => A.roll());
three.onKeyDown('r', () => A.rerack());
three.onKeyDown('b', () => A.bomb());
three.onKeyDown('a', () => { A.auto = !A.auto; A.mark = A.now; });

three.setAnimationLoop(() => {
	// Seconds, from the game clock — so every interval below is written in the
	// unit a person says them in, and `three.clock.timeScale = 0` holds the
	// timer as well as the picture.
	const t = three.clock.time;
	A.now = t;
	// The side wall's bricks slide while the mesh stands still — offset moving
	// the tiling, not the geometry. Delete this line for a wall that holds
	// still; `wallMatB.offset = [0.5, 0.25]` once, at build time, makes the
	// same point more quietly — half a brick and a quarter row of shift, so
	// the two walls do not show visibly the same seam in the same place.
	A.wallMatB.offset = [(t / 9) % 1, 0];
	if (!A.auto) return;
	if (A.phase === 'racked' && t - A.mark > 1.2) A.roll();
	else if (A.phase === 'rolling' && t - A.mark > 6.5) A.rerack();
});

A.rerack();
three.camera.lookAt(0, 1.6, -3);
three.camera.orbit(24, 14, 20);

three.debug.write({
	keys: { space: 'roll', r: 're-rack', b: 'bomb the stack', a: 'auto on/off' },
	auto: 'rolls every ~7.7s on its own',
	stats: three.stats(),
});
