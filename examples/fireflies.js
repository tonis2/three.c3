// fireflies.js — a night-time chase in a walled garden.
//
// Fourteen fireflies drift between the hedges and scatter when you get close.
// Corner them against the walls and catch all fourteen before the night ends.
// Nothing is loaded from disk — every texture is generated here.
//
//   ./build/three --script examples/fireflies.js
//   ./build/three --headless --script examples/fireflies.js --frames 120 --screenshot /tmp/ff.png
//
// ## Controls
//
//   W A S D / arrows   run (camera-relative)
//   space              jump — and start from the menu
//   drag / Q E         look          R F      tilt
//   p                  pause         m        menu
//   wheel              zoom

const { Panel, Stack, Row, Label, Button, Rect } = three.ui;
const { clamp, clamp01, damp, hash } = three;

// ---------------------------------------------------------------------------
// The garden
// ---------------------------------------------------------------------------
const HALF = 20;          // the walls sit at ±HALF
const NEED = 14;          // fireflies to catch
const TIME = 90;          // seconds of night
const FLEE_R = 3.4, FLEE_SPD = 4.5, DRIFT_SPD = 1.1;
// The flight band. A `near` rule is a strict 3-D distance from the player's
// capsule centre at y 0.8, so a fly that rides too high is one nobody can
// catch — keep the worst bob plus flee-lift inside the catch radius.
const FLY_LOW = 0.7, FLY_BAND = 0.6, FLY_BOB = 0.18, FLEE_LIFT = 0.4;

const scene = new three.Scene();
scene.background = 0x05070f;

// A blue moon high up, a faint fill from the other side, and a low floor —
// the fireflies carry the rest of the light in the picture.
three.light.set([0.3, 1, 0.45], 0.14);
three.light.color = 0x9db4ff;
three.light.shadow = { enabled: true, size: 2048, intensity: 0.45 };
three.lights.add([0.2, 0.35, 0.6], 0x2c3a55, 0.3);

// -- textures -----------------------------------------------------------------

// A tileable night lawn.
const grass = new three.DataTexture((() => {
	const px = new Uint8Array(64 * 64 * 4);
	for (let y = 0; y < 64; y++) for (let x = 0; x < 64; x++) {
		const k = y * 64 + x, n = hash(x, y, 3), m = hash(x >> 2, y >> 2, 7);
		const g = 34 + m * 26 + n * 10;
		px[k * 4] = 16 + m * 12; px[k * 4 + 1] = g; px[k * 4 + 2] = 14 + m * 8; px[k * 4 + 3] = 255;
	}
	return px;
})(), 64, 64);

const bark = new three.DataTexture((() => {
	const px = new Uint8Array(32 * 32 * 4);
	for (let y = 0; y < 32; y++) for (let x = 0; x < 32; x++) {
		const k = y * 32 + x;
		const s = Math.sin(x * 1.9 + hash(x, y, 11) * 2) * 0.5 + 0.5;
		const c = 38 + s * 22 + hash(x, y, 13) * 8;
		px[k * 4] = c; px[k * 4 + 1] = c * 0.8; px[k * 4 + 2] = c * 0.6; px[k * 4 + 3] = 255;
	}
	return px;
})(), 32, 32);

const leaf = new three.DataTexture((() => {
	const px = new Uint8Array(48 * 48 * 4);
	for (let y = 0; y < 48; y++) for (let x = 0; x < 48; x++) {
		const k = y * 48 + x, n = hash(x >> 1, y >> 1, 17), hole = hash(x, y, 19) > 0.9;
		const d = hole ? 0.45 : 1;
		px[k * 4] = (14 + n * 16) * d; px[k * 4 + 1] = (30 + n * 30) * d;
		px[k * 4 + 2] = (16 + n * 14) * d; px[k * 4 + 3] = 255;
	}
	return px;
})(), 48, 48);

// A star dome: 1024x512 equirect, row 0 is the BOTTOM row. The dome is 110
// units across, so a star is one texel — at 256 wide a texel covers a hedge,
// which is why this texture is the one big one in the file.
const stars = new three.DataTexture((() => {
	const W2 = 1024, H2 = 512, px = new Uint8Array(W2 * H2 * 4);
	const mx = W2 * 0.76, my = H2 * 0.30, mr = 36;
	for (let y = 0; y < H2; y++) for (let x = 0; x < W2; x++) {
		const k = (y * W2 + x) * 4;
		const lift = y / H2;
		let r = 3 + lift * 5, g = 5 + lift * 9, b = 10 + lift * 20;
		const dm = Math.hypot(x - mx, y - my);
		if (dm < mr) { const e = 1 - dm / mr; r += 210 * e; g += 212 * e; b += 190 * e; }
		else {
			const s = hash(x, y, 23);
			if (s > 0.9992) { const w = 140 + (s - 0.9992) * 90000; r += w; g += w; b += w * 1.05; }
		}
		px[k] = clamp(r, 0, 255); px[k + 1] = clamp(g, 0, 255);
		px[k + 2] = clamp(b, 0, 255); px[k + 3] = 255;
	}
	return px;
})(), 1024, 512);

// -- materials ----------------------------------------------------------------
const mat = {
	grass: new three.MeshLambertMaterial({ map: grass }),
	bark: new three.MeshLambertMaterial({ map: bark }),
	leaf: new three.MeshLambertMaterial({ map: leaf }),
	flat: new three.MeshLambertMaterial(),
	glass: new three.MeshLambertMaterial({ transparent: true, opacity: 0.22 }),
};
mat.grass.repeat = 14;
mat.leaf.repeat = [3, 2];

// A flat unlit glow. The flies' haloes, their cores and the jar's catch all
// share the additive one; the star dome gets its own sampler.
const glow = new three.ShaderMaterial({
	uniforms: { tint: [1.0, 0.95, 0.55] },
	fragment: `float3 shade(Surface s) { return tint * 1.35; }`,
	blending: three.AdditiveBlending,
});
const starMat = new three.ShaderMaterial({
	textures: { sky: stars },
	fragment: `float3 shade(Surface s) { return sky.Sample(s.uv).rgb; }`,
	side: three.BackSide,
});

// -- the ground and what stands on it -----------------------------------------
const floor = new three.Mesh(new three.PlaneGeometry(HALF * 2 + 4, HALF * 2 + 4), mat.grass);
floor.rotation.x = -Math.PI / 2;
floor.static = true;
scene.add(floor);

scene.add(new three.Mesh(new three.SphereGeometry(110, 24, 16), starMat));

const WALL_H = 2.4, WALL_T = 0.7, WALL_L = HALF * 2 + WALL_T;
for (const [x, z, w, d] of [
	[0, HALF + WALL_T / 2, WALL_L, WALL_T], [0, -HALF - WALL_T / 2, WALL_L, WALL_T],
	[HALF + WALL_T / 2, 0, WALL_T, WALL_L], [-HALF - WALL_T / 2, 0, WALL_T, WALL_L],
]) {
	const wall = new three.Mesh(new three.BoxGeometry(w, WALL_H, d), mat.flat);
	wall.position.set(x, WALL_H / 2, z);
	wall.color = 0x2a3040;
	wall.static = true;
	scene.add(wall);
}

// Hedges: axis-aligned, and the rectangles the fireflies dodge around.
const HEDGES = [
	[-10, -6, 7, 1.6], [8, -3, 5, 1.6], [-4, 7, 1.6, 7], [6, 9, 6, 1.6],
	[0, -12, 8, 1.6], [-13, 4, 1.6, 6], [12, 2, 1.6, 5], [-2, -2, 1.6, 5],
	[10, 14, 4, 1.6],
];
const RECTS = [];
for (const [x, z, w, d] of HEDGES) {
	const h = new three.Mesh(new three.BoxGeometry(w, 1.4, d), mat.leaf);
	h.position.set(x, 0.7, z);
	h.static = true;
	scene.add(h);
	RECTS.push({ x0: x - w / 2, x1: x + w / 2, z0: z - d / 2, z1: z + d / 2 });
}

const TREES = [[-14, -14], [15, -15], [-16, 11], [13, 12], [3, -7]].map(([x, z]) => ({ x, z, r: 1.9 }));
for (const t of TREES) {
	const trunk = new three.Mesh(new three.CylinderGeometry(0.35, 0.45, 2.8, 8), mat.bark);
	trunk.position.set(t.x, 1.4, t.z);
	trunk.static = true;
	scene.add(trunk);
	for (let i = 0; i < 2; i++) {
		const cone = new three.Mesh(new three.ConeGeometry(1.7 - i * 0.5, 2.4, 9), mat.leaf);
		cone.position.set(t.x, 3.4 + i * 1.6, t.z);
		cone.static = true;
		scene.add(cone);
	}
}

// A soft vignette to close the night in.
three.setPost({
	fragment: `
		float3 post(Post p) {
			float d = distance(p.uv, float2(0.5, 0.44));
			float v = 1.0 - smoothstep(0.32, 0.82, d);
			return p.color * lerp(0.5, 1.0, v);
		}`,
});

// ---------------------------------------------------------------------------
// The player
// ---------------------------------------------------------------------------
const SPEED = 6.6, GRAV = 24, JUMP = 8.6;
const MOVE = { radius: 0.42, height: 1.6, step: 0.4, slope: 52, skin: 0.02, snap: 0.35 };

const groups = {};
for (const name of ['player', 'flies']) {
	const g = new three.Group(); g.name = name; scene.add(g); groups[name] = g;
}

// One unit box under a scale: every body part in the game is one geometry, so
// the whole cast is a handful of draw calls however many of them there are.
const BOX = new three.BoxGeometry(1, 1, 1);
const GLOW_BALL = new three.SphereGeometry(0.09, 12, 8);

function part(parent, size, pos, look) {
	const m = new three.Mesh(BOX, mat.flat);
	m.scale.set(...size);
	m.position.set(...pos);
	if (typeof look === 'number') m.color = look;
	else m.material = look;
	parent.add(m);
	return m;
}

class Player extends three.Entity {
	static parent = groups.player;
	static volume = { shape: 'capsule', radius: 0.42, height: 1.6, offset: [0, 0.8, 0] };
	static collides = false;

	constructor(x, z) {
		super();
		const root = new three.Group();
		part(root, [0.66, 0.72, 0.5], [0, 0.98, 0], 0x46587a);           // coat
		part(root, [0.5, 0.46, 0.46], [0, 1.58, 0.02], 0xd9b48f);        // head
		part(root, [0.54, 0.14, 0.52], [0, 1.84, 0.02], 0x2c3a55);       // hat
		for (const side of [-1, 1]) part(root, [0.1, 0.1, 0.05], [side * 0.13, 1.62, 0.25], 0x101418);
		// Limbs hang from pivots ON the body: a pivot off the scene draws nothing.
		this.leg = [-1, 1].map(s => {
			const pivot = new three.Group();
			pivot.position.set(s * 0.18, 0.62, 0);
			part(pivot, [0.22, 0.62, 0.26], [0, -0.3, 0], 0x2e3446);
			root.add(pivot);
			return pivot;
		});
		this.arm = [-1, 1].map(s => {
			const pivot = new three.Group();
			pivot.position.set(s * 0.44, 1.3, 0);
			part(pivot, [0.18, 0.56, 0.2], [0, -0.26, 0], 0x46587a);
			root.add(pivot);
			return pivot;
		});

		// The jar: a glass box with a glow inside that grows with the catch.
		const jar = new three.Group();
		jar.position.set(0.5, 1.06, 0.22);
		part(jar, [0.3, 0.36, 0.3], [0, 0.18, 0], mat.glass);
		this.jarGlow = new three.Mesh(GLOW_BALL, glow);
		this.jarGlow.position.set(0, 0.18, 0);
		jar.add(this.jarGlow);
		root.add(jar);

		this.object = root;
		this.setJar(0);

		this.x = x; this.z = z; this.y = 0; this.vy = 0; this.grounded = false;
		this.heading = 0; this.moving = false; this.walkT = 0;
		this.yaw = 180; this.pitch = 20; this.dist = 9;
		this.intent = { jump: false };
	}

	setJar(n) {
		const k = n / NEED;
		this.jarGlow.scale.setScalar(0.5 + k * 2.6);
		this.jarGlow.color = [0.8 + k * 0.6, 0.78 + k * 0.5, 0.4];
	}

	caught() {
		G.caught++;
		this.setJar(G.caught);
		if (G.caught >= NEED) win();
	}

	step(dt) {
		const held = k => three.input.isDown(k);
		const axis = (...ks) => ks.reduce((a, k) => a + (held(k) ? 1 : 0), 0);
		const move = three.camera.planarMove(
			axis('w', 'arrowup') - axis('s', 'arrowdown'),
			axis('d', 'arrowright') - axis('a', 'arrowleft'),
		);
		this.moving = move.length() > 0;
		if (this.moving) this.heading = Math.atan2(move.x, move.z);

		if (this.intent.jump && this.grounded) { this.vy = JUMP; this.grounded = false; }
		this.intent.jump = false;
		this.vy = Math.max(this.vy - GRAV * dt, -40);

		const motion = [move.x * SPEED * dt, this.vy * dt, move.z * SPEED * dt];
		const r = three.moveAndSlide([this.x, this.y + 0.8, this.z], motion, MOVE);
		this.x = r.position.x; this.z = r.position.z; this.y = r.position.y - 0.8;
		this.grounded = r.grounded;
		if (this.grounded && this.vy < 0) this.vy = 0;
	}

	look(dt) {
		const ptr = three.input.pointer;
		if (ptr.down) { this.yaw -= ptr.dx * 0.24; this.pitch += ptr.dy * 0.2; }
		this.yaw += (three.input.isDown('q') - three.input.isDown('e')) * 110 * dt;
		this.pitch += (three.input.isDown('r') - three.input.isDown('f')) * 55 * dt;
		this.pitch = clamp(this.pitch, -4, 62);
		this.dist = clamp(this.dist + ptr.scroll, 5, 18);
		three.camera.orbit(this.yaw, this.pitch, this.dist);
	}

	pose(dt) {
		this.object.position.set(this.x, this.y, this.z);
		this.object.rotation.y = this.heading;
		if (this.moving && this.grounded) this.walkT += dt * 11;
		const swing = this.moving && this.grounded ? Math.sin(this.walkT) * 0.55 : 0;
		this.leg[0].rotation.x = swing; this.leg[1].rotation.x = -swing;
		this.arm[0].rotation.x = -swing * 0.7; this.arm[1].rotation.x = swing * 0.7;
		if (!this.grounded) { this.leg[0].rotation.x = 0.45; this.leg[1].rotation.x = -0.3; }
	}
}

// ---------------------------------------------------------------------------
// The fireflies.
//
// **A trigger volume cannot carry a catch.** In the solver a trigger's AABB is
// baked where it was added and never follows the node, so a trigger that moves
// — and a firefly is nothing but movement — fires against nothing. A `near`
// rule is the engine's answer to exactly this: the engine runs the distance
// test against where the things ARE, every tick, and physics never has to hear
// about the flies at all.
// ---------------------------------------------------------------------------
class Firefly extends three.Entity {
	static parent = groups.flies;
	static collides = false;

	constructor(i) {
		super();
		const a = (i / NEED) * Math.PI * 2;
		const r = 4 + hash(i, 1, 31) * 11;
		this.homeX = Math.cos(a) * r;
		this.homeZ = Math.sin(a) * r;

		this.core = new three.Mesh(GLOW_BALL, glow);
		this.halo = new three.Mesh(GLOW_BALL, glow);
		this.object = new three.Group();
		this.object.add(this.core, this.halo);
		this.baseY = FLY_LOW + hash(i, 2, 37) * FLY_BAND;
		// glow() is a frame system and can run before the first fixed step; an
		// undefined y here becomes a NaN position, and a NaN position makes every
		// distance test compare against NaN — which is a match to nothing, or
		// worse, a match to everything downstream.
		this.x = this.homeX; this.z = this.homeZ; this.y = this.baseY;
		this.vx = 0; this.vz = 0; this.lift = 0;
		this.dir = hash(i, 3, 41) * Math.PI * 2;
		this.phase = hash(i, 4, 43) * 6.28;
		this.far = 0;
	}

	// Wander home, or bolt when the player closes in.
	drift(dt) {
		const chasing = G.mode === 'playing';
		let dvx, dvz;
		const dx = this.x - player.x, dz = this.z - player.z;
		const d = Math.hypot(dx, dz);
		this.far = chasing && d < FLEE_R ? 1 - d / FLEE_R : 0;

		if (this.far > 0) {
			dvx = (dx / (d || 1)) * FLEE_SPD;
			dvz = (dz / (d || 1)) * FLEE_SPD;
		} else {
			this.dir += (hash(this.slot | 0, (three.clock.time * 0.5) | 0, 47) - 0.5) * 4 * dt;
			const hx = this.x - this.homeX, hz = this.z - this.homeZ;
			const home = Math.hypot(hx, hz) > 3 ? Math.atan2(-hz, -hx) : this.dir;
			this.dir = three.dampAngle(this.dir, home, 0.6, dt);
			dvx = Math.cos(this.dir) * DRIFT_SPD;
			dvz = Math.sin(this.dir) * DRIFT_SPD;
		}

		this.vx = damp(this.vx, dvx, 5, dt);
		this.vz = damp(this.vz, dvz, 5, dt);
		this.x = clamp(this.x + this.vx * dt, -HALF + 1.2, HALF - 1.2);
		this.z = clamp(this.z + this.vz * dt, -HALF + 1.2, HALF - 1.2);

		// Out of the hedges and off the trunks.
		for (const r of RECTS) {
			const m = 0.55;
			if (this.x > r.x0 - m && this.x < r.x1 + m && this.z > r.z0 - m && this.z < r.z1 + m) {
				const px = Math.min(this.x - r.x0 + m, r.x1 + m - this.x);
				const pz = Math.min(this.z - r.z0 + m, r.z1 + m - this.z);
				if (px < pz) this.x += this.x - (r.x0 + r.x1) / 2 > 0 ? px : -px;
				else this.z += this.z - (r.z0 + r.z1) / 2 > 0 ? pz : -pz;
			}
		}
		for (const t of TREES) {
			const tx = this.x - t.x, tz = this.z - t.z, td = Math.hypot(tx, tz);
			if (td < t.r) { this.x = t.x + (tx / (td || 1)) * t.r; this.z = t.z + (tz / (td || 1)) * t.r; }
		}

		this.lift = damp(this.lift, this.far * FLEE_LIFT, 3, dt);
		const bob = Math.sin(three.clock.time * 1.3 + this.phase) * FLY_BOB;
		this.y = damp(this.y ?? this.baseY, this.baseY + bob + this.lift, 4, dt);
	}

	glow(dt) {
		this.object.position.set(this.x, this.y, this.z);
		this.object.rotation.y = Math.atan2(this.vx, this.vz);
		const pulse = 0.5 + 0.5 * Math.sin(three.clock.time * 2.4 + this.phase);
		this.halo.scale.setScalar(2.4 + pulse * 1.1 + this.far * 1.6);
		const w = 0.55 + pulse * 0.65;
		this.core.scale.setScalar(0.8 + pulse * 0.5);
		this.core.color = [w, w, w * 0.55];
	}
}

// ---------------------------------------------------------------------------
// The night: state, rules, systems
// ---------------------------------------------------------------------------
const G = { mode: 'menu', caught: 0, endsAt: 0, left: TIME, win: false, used: 0 };

function populate() { for (let i = 0; i < NEED; i++) Firefly.spawn(i); }

const player = Player.spawn(0, HALF - 6);
populate();

three.camera.attach(player.object, { offset: [0, 1.35, 0], distance: player.dist, lag: 0.12 });
three.controls.enabled = false;
three.camera.orbit(player.yaw, player.pitch, player.dist);

function start() {
	for (const f of Firefly) f.remove();
	populate();
	player.x = 0; player.z = HALF - 6; player.y = 0; player.vy = 0;
	player.setJar(0);
	G.caught = 0; G.win = false;
	G.endsAt = three.clock.time + TIME;
	player.intent.jump = false;
	show('playing');
}

function finish(won) {
	G.win = won;
	G.spare = Math.max(0, Math.round(G.left));
	show('over');
}
function win() { if (G.mode === 'playing') finish(true); }
function lose() { if (G.mode === 'playing') finish(false); }
// A catch: the engine's distance pass, subject first. Removing the fly here is
// safe — the list waits for the frame boundary — and the guard keeps a fly the
// menu removed from being caught a second time in the same tick.
Firefly.on('near', Player, (f, p) => {
	if (G.mode !== 'playing') return;
	f.remove();
	p.caught();
}, { within: 1.35 });

Player.step('move', dt => { if (G.mode === 'playing' && !three.clock.paused) player.step(dt); });
Player.frame('latch', () => {
	if (three.input.pressed('space')) player.intent.jump = true;
});
Player.frame('look', dt => player.look(dt));
Player.frame('pose', dt => player.pose(dt));
Firefly.step('drift', dt => { if (!three.clock.paused) for (const f of Firefly) f.drift(dt); });
Firefly.frame('glow', dt => { for (const f of Firefly) f.glow(dt); });

three.systems.frame('night', () => {
	if (G.mode !== 'playing') return;
	G.left = Math.max(G.endsAt - three.clock.time, 0);
	hud.left = G.left;
	if (G.left <= 0) lose();
});

// ---------------------------------------------------------------------------
// The interface
// ---------------------------------------------------------------------------
const DIM = [0.6, 0.66, 0.78];
const GOLD = [0.98, 0.85, 0.4];
const SCRIM = [0.01, 0.02, 0.05, 0.6];

class Hud extends three.Widget {
	constructor() {
		super();
		this.left = TIME;
	}
	render() {
		return new Stack({},
			new Panel({ at: 'top-left', margin: 16 },
				new Label(`fireflies  ${G.caught} / ${NEED}`, { size: 20 }),
			),
			new Panel({ at: 'top-right', margin: 16 },
				new Label(this.left.toFixed(1), { size: 22, color: this.left < 10 ? GOLD : undefined }),
			),
		);
	}
}

class Menu extends three.Widget {
	render() {
		return new Stack({},
			new Rect({ color: SCRIM, solid: true }),
			new Panel({ at: 'center', width: 330, gap: 10 },
				new Label('Fireflies', { size: 36 }),
				new Label(`${NEED} fireflies drift in the garden and scatter when you close in. Corner them against the walls and hedges — catch every one before the night ends.`, { color: DIM, size: 13 }),
				new Button('Begin the night', () => start()),
				new Label('wasd run · space jump · drag to look', { color: DIM, size: 12 }),
			),
		);
	}
}

class Pause extends three.Widget {
	static layer = 1;
	render() {
		return new Stack({},
			new Rect({ color: SCRIM, solid: true }),
			new Panel({ at: 'center', width: 240, gap: 8 },
				new Label('Paused', { size: 26 }),
				new Button('Resume', () => show('playing')),
				new Button('Give up', () => finish(false)),
			),
		);
	}
}

class Over extends three.Widget {
	static layer = 1;
	render() {
		return new Stack({},
			new Rect({ color: SCRIM, solid: true }),
			new Panel({ at: 'center', width: 320, gap: 10 },
				new Label(G.win ? 'The jar is full' : 'Dawn came first', { size: 30 }),
				new Label(G.win
					? `All ${NEED} fireflies caught with ${G.spare}s of night to spare.`
					: `${G.caught} of ${NEED} caught before the sun rose.`, { color: DIM, size: 13 }),
				new Row({ gap: 8 },
					new Button('Another night', () => start()),
					new Button('Menu', () => show('menu')),
				),
			),
		);
	}
}

const hud = new Hud();
const screens = { menu: new Menu(), pause: new Pause(), over: new Over() };

function show(mode) {
	G.mode = mode;
	const wanted = {
		menu: [screens.menu],
		playing: [hud],
		paused: [hud, screens.pause],
		over: [hud, screens.over],
	}[mode];
	for (const w of three.Widget.all()) if (!wanted.includes(w)) w.unmount();
	for (const w of wanted) w.mount();
	three.clock.timeScale = mode === 'paused' ? 0 : 1;
	if (mode === 'playing') hud.left = G.left;
}

three.onKeyDown('space', () => { if (G.mode === 'menu' || G.mode === 'over') start(); });
three.onKeyDown('p', () => {
	if (G.mode === 'playing') show('paused');
	else if (G.mode === 'paused') show('playing');
});
three.onKeyDown('m', () => { if (G.mode !== 'menu') show('menu'); });

show('menu');

const stats = three.stats();
console.log(`garden: ${NEED} fireflies, ${stats.instances} instances over ${stats.uniqueMeshes} meshes, `
	+ `${stats.drawCalls} draw calls, ${stats.colliders} colliders`);

three.debug.write({
	fireflies: NEED,
	drawCalls: stats.drawCalls,
	instances: stats.instances,
	uniqueMeshes: stats.uniqueMeshes,
	colliders: stats.colliders,
});

// A handle for headless probes: drive the player, count the flies, force the dawn.
globalThis.__fireflies = { player, Player, Firefly, G, start, lose, get count() { return Firefly.count; } };
