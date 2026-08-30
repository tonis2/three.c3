// tank_yard.js — a Battle City in four API pieces
//
// Run it:
//
//     ./build/three --script examples/tank_yard.js

// Keys: arrows or WASD drive, space fires, `p` stops and starts the autopilot.
// Left alone it plays itself, which is the whole reason a headless run is a
// playtest rather than a still life.
//
// What it is here to show
// -----------------------
// This is meant to be read start to finish by somebody who has not written a
// `three` script before. Four things carry the game, in this order:
//
// **1. A LayeredMaterial is a stack, not a texture.** The ground is ONE mesh
// with ONE mask image: the mask's red channel says where gravel is, green says
// where grass is, blue says where the yard is scorched, and each layer tiles its
// own detail map with `uvScale` while the mask stays stretched across the whole
// arena. That is the trick — the mask describes this specific yard, the detail
// repeats across it. The bricks are the same idea with the damage baked in:
// three materials off one stack description, differing only in how opaque its
// crack and soot layers are, and a brick that takes a hit is
// `mesh.material = next stage`.
// The eagle's stack has an `animated: true` layer instead, so its scorch is a
// uniform the script writes per frame rather than a literal in the shader.
//
// **2. An entity is a class.** `class Brick extends three.Entity` with no
// registration call beside it: the statics ARE the declaration. `static body`
// gives every brick a collider, `static volume` gives every tank an invisible
// box for bullets to hit, `static collides = false` keeps bullets and fire out
// of everybody's movement sweeps. `Brick.spawn(col, row)` is the way in and
// `brick.remove()` is the whole removal — body, node and lookup, on this tick.
//
// **3. A rule is a pair, subject first.** Every interesting thing in this game
// is five lines near the bottom of the file: bullet-brick, bullet-steel,
// bullet-tank, bullet-eagle, bullet-bullet. There is no `if (other.type === ...)`
// chain anywhere, because the class the rule hangs on IS the type test, and the
// handler is handed its two arguments in the order the rule was written.
//
// **4. The VFX is one draw call.** Every fireball in the air shares one
// ShaderMaterial, and each one is at its own moment of its own life because the
// age rides in `mesh.color`'s alpha — `s.color` in the body is this copy's own
// colour, raw and untinted, which makes it the per-instance parameter channel.
// Twenty blasts, one pipeline, one draw.
//
// The whole scene is about ten draw calls: the ground, the steel, three stages
// of brick, the eagle, every part of every tank (one unit box, tinted per copy),
// the bullets and the fire.

// ---------------------------------------------------------------------------
// The level, as a picture
//
// `#` steel (forever), `b` brick (three hits), `E` an enemy spawn point,
// `P` where the player starts, `A` the eagle you are defending.
// ---------------------------------------------------------------------------

const MAP = [
	'###############',
	'#E....b.b....E#',
	'#..bb.b.b.bb..#',
	'#..bb.b.b.bb..#',
	'#.....b.b.....#',
	'#.##...b...##.#',
	'#.bb.bb.bb.bb.#',
	'#......#......#',
	'#.bb.bb.bb.bb.#',
	'#.##...b...##.#',
	'#.....b.b.....#',
	'#..bb.b.b.bb..#',
	'#..bb.bbb.bb..#',
	'#.P..bbAbb....#',
	'###############',
];

const CELL = 2;                       // world units per map square
const HALF = (MAP.length - 1) / 2;    // so the middle of the map is the origin
const WALL_H = 1.7;

const cellX = (col) => (col - HALF) * CELL;
const cellZ = (row) => (row - HALF) * CELL;

// Every random number in the file comes from this stream rather than from
// Math.random, so two runs of `--frames 600` produce the same match.
three.seed(7);

// ---------------------------------------------------------------------------
// Pixels
//
// Built once, here. A DataTexture is on the device when the constructor
// returns and generating one costs real JavaScript time, so none of this
// belongs in a frame.
// ---------------------------------------------------------------------------

// One painter for every image below: hand it a function of (x, y) answering
// [r, g, b] in 0..255 and it hands back a texture.
function paint(size, f, options) {
	const px = new Uint8Array(size * size * 4);
	for (let y = 0; y < size; y++) {
		for (let x = 0; x < size; x++) {
			const c = f(x / size, y / size, x, y);
			const i = (y * size + x) * 4;
			px[i] = c[0]; px[i + 1] = c[1]; px[i + 2] = c[2]; px[i + 3] = 255;
		}
	}
	return new three.DataTexture(px, size, size, options);
}

// Masks, ramps and noise are TABLES, not pictures: their channels are numbers a
// shader does arithmetic with, and pushing them through the sRGB decode every
// colour goes through would make every weight in this file quietly wrong.
const TABLE = { colorSpace: three.LinearSRGBColorSpace, generateMipmaps: false };

// A gradient read as a lookup table — sample at float2(k, 0.5) and k picks the
// colour. `stops` are [position, r, g, b].
function ramp(width, stops) {
	const px = new Uint8Array(width * 4 * 4);
	for (let x = 0; x < width; x++) {
		const t = x / (width - 1);
		let lo = stops[0], hi = stops[stops.length - 1];
		for (let i = 0; i < stops.length - 1; i++) {
			if (t >= stops[i][0] && t <= stops[i + 1][0]) { lo = stops[i]; hi = stops[i + 1]; break; }
		}
		const k = three.clamp01((t - lo[0]) / Math.max(hi[0] - lo[0], 1e-5));
		for (let row = 0; row < 4; row++) {
			const i = (row * width + x) * 4;
			for (let c = 0; c < 3; c++) px[i + c] = lo[1 + c] + (hi[1 + c] - lo[1 + c]) * k;
			px[i + 3] = 255;
		}
	}
	return new three.DataTexture(px, width, 4, TABLE);
}

// Brick, in a running bond. This is the BASE of the wall stack; the wear on top
// of it is a separate image with a separate job.
const brickTex = paint(64, (u, v, x, y) => {
	const rowH = 16, brickW = 32, mortar = 3;
	const shift = (Math.floor(y / rowH) & 1) ? brickW / 2 : 0;
	const seam = (y % rowH) < mortar || ((x + shift) % brickW) < mortar;
	const grit = three.fbm2(u * 8, v * 8, { octaves: 2, seed: 5, period: 8 }) * 26;
	return seam ? [176 + grit, 170 + grit, 160 + grit] : [148 + grit, 66 + grit * 0.4, 48];
});

// The wall stack's mask. RED is where the cracks run, GREEN is where grime
// gathers — two layers, one image, and no second sampler. Ridged noise (the
// distance from a level set, inverted) is what makes a crack rather than a
// cloud, and the 1.6 saturates the middle of that band to a solid 1 so the
// fracture has a body instead of being a hairline the game camera cannot see.
const wearTex = paint(64, (u, v) => {
	const n = three.fbm2(u * 4, v * 4, { octaves: 3, seed: 21, period: 4 });
	const crack = three.clamp01((1 - Math.abs(n - 0.5) * 8) * 1.6);
	const grime = three.clamp01((three.fbm2(u * 3 + 4, v * 3, { octaves: 2, seed: 4, period: 3 }) - 0.35) * 2.2);
	return [crack * 255, grime * 255, 0];
}, TABLE);

const steelTex = paint(64, (u, v, x, y) => {
	const border = x < 4 || y < 4 || x >= 60 || y >= 60;
	const rivet = [[12, 12], [52, 12], [12, 52], [52, 52]]
		.some(([rx, ry]) => (x - rx) ** 2 + (y - ry) ** 2 < 10);
	const grit = three.fbm2(u * 10, v * 10, { octaves: 2, seed: 33, period: 10 }) * 22;
	if (rivet) return [196 + grit, 202 + grit, 212 + grit];
	return border ? [132 + grit, 140 + grit, 152 + grit] : [166 + grit, 172 + grit, 182 + grit];
});

// The ground's three detail maps. Each tiles many times across the yard; the
// mask below does not tile at all.
const dirtTex = paint(64, (u, v) => {
	const n = three.fbm2(u * 6, v * 6, { octaves: 3, seed: 11, period: 6 });
	return [96 + n * 40, 84 + n * 34, 70 + n * 26];
});
const gravelTex = paint(64, (u, v) => {
	const n = three.fbm2(u * 12, v * 12, { octaves: 3, seed: 2, period: 12 });
	const stone = n > 0.58 ? 1 : 0;
	return [110 + stone * 70, 108 + stone * 68, 104 + stone * 66];
});
const grassTex = paint(64, (u, v) => {
	const n = three.fbm2(u * 9, v * 9, { octaves: 3, seed: 44, period: 9 });
	return [54 + n * 40, 96 + n * 78, 44 + n * 30];
});

// The splat mask: ONE image over the whole 30x30 yard, three weights in three
// channels. Nothing here repeats — that is what makes it a description of this
// particular ground rather than a pattern.
const splatTex = paint(128, (u, v) => {
	const gravel = three.clamp01((three.fbm2(u * 3, v * 3, { octaves: 4, seed: 3, period: 3 }) - 0.42) * 3.4);
	const grass = three.clamp01((three.fbm2(u * 4 + 9, v * 4 + 5, { octaves: 3, seed: 9, period: 4 }) - 0.60) * 4.2);
	// Scorched towards the middle, where the fighting is.
	const d = Math.hypot(u - 0.5, v - 0.5) * 2;
	const scorch = three.clamp01((1 - d) * 1.3) * three.fbm2(u * 5, v * 5, { octaves: 2, seed: 17, period: 5 });
	return [gravel * 255, grass * 255, scorch * 255];
}, TABLE);

// The eagle's plate: a pale star on dark metal.
const eagleTex = paint(64, (u, v, x, y) => {
	const dx = (x - 32) / 26, dy = (y - 30) / 26;
	const a = Math.atan2(dy, dx), r = Math.hypot(dx, dy);
	const star = r < 0.45 + 0.42 * Math.cos(5 * a) * Math.cos(5 * a);
	return star ? [236, 222, 176] : [58, 52, 48];
});

// The fireball's two samplers: something to animate and something to colour it.
const fireNoise = paint(128, (u, v) =>
	[three.fbm2(u * 8, v * 8, { octaves: 4, seed: 88, period: 8 }) * 255, 0, 0], TABLE);
const fireRamp = ramp(64, [
	[0.00, 6, 3, 4], [0.28, 132, 24, 10], [0.55, 240, 96, 22],
	[0.80, 255, 194, 78], [1.00, 255, 250, 228],
]);

// ---------------------------------------------------------------------------
// Materials
//
// Three LayeredMaterials and one ShaderMaterial. Everything else is a plain
// MeshLambertMaterial, because a stack you do not need is samplers you paid for.
// ---------------------------------------------------------------------------

// The yard. No base map at all — the mesh's own colour is the bare earth, and
// every layer paints over it through its own channel of the one mask.
const groundMat = new three.LayeredMaterial({
	mask: splatTex,
	layers: [
		{ name: 'dirt', mask: 'r', map: dirtTex, uvScale: 14 },
		{ name: 'grass', mask: 'g', map: grassTex, uvScale: 18 },
		// No map and no uv of its own: a tint through a mask is a stain.
		{ name: 'scorch', mask: 'b', tint: [0.20, 0.17, 0.15], blend: 'multiply' },
	],
});

// One stack description, three materials, two numbers apart. A layer's opacity
// is compiled into the shader as a LITERAL unless you say `animated: true`, so
// these are three pipelines and cost the frame nothing to switch between.
//
// TWO cues rather than one, because they are read at different distances. The
// crack layer is the detail you see standing over a wall; the soot layer covers
// the whole face and is what makes a damaged block read as damaged from the
// game camera, where a block is forty pixels across and a fracture line is not
// there at all.
const brickStack = (crack, soot) => ({
	map: brickTex,
	mask: wearTex,
	layers: [
		{ name: 'grime', mask: 'g', tint: [0.52, 0.48, 0.44], blend: 'multiply' },
		{ name: 'crack', mask: 'r', tint: [0.05, 0.035, 0.03], opacity: crack },
		// No mask at all, so it covers everything under it.
		{ name: 'soot', tint: [0.46, 0.38, 0.33], blend: 'multiply', opacity: soot },
	],
});
// Indexed by remaining hit points, so `BRICK_MAT[brick.hp]` is the whole lookup.
const BRICK_MAT = [null, brickStack(1, 0.78), brickStack(0.72, 0.42), brickStack(0, 0)]
	.map((s) => s && new three.LayeredMaterial(s));

// The eagle. Its ruin layer IS animated, because the script writes it per frame
// when the thing falls — that is the one case worth 16 of the material's 104
// uniform bytes.
const eagleMat = new three.LayeredMaterial({
	map: eagleTex,
	layers: [{ name: 'ruin', tint: [0.07, 0.06, 0.06], opacity: 0, animated: true, blend: 'multiply' }],
});

const steelMat = new three.MeshLambertMaterial({ map: steelTex });
steelMat.reflectance = 0.4;
steelMat.roughness = 0.45;

const tankMat = new three.MeshLambertMaterial();
tankMat.reflectance = 0.3;
tankMat.roughness = 0.5;

const shotMat = new three.MeshLambertMaterial();

// The fireball. Every blast in the air draws with this one material, and every
// one of them is at a different moment of its own life, because the age travels
// in the per-copy colour rather than in a uniform.
const blastMat = new three.ShaderMaterial({
	blending: three.AdditiveBlending,
	side: three.DoubleSide,
	textures: { noise_map: fireNoise, ramp_map: fireRamp },
	uniforms: { t: 0 },
	fragment: `
	// A ramp is 64 texels wide and the sampler repeats, so sampling at 0 or 1
	// lands on the seam and blends the two ENDS of the gradient together. Half
	// a texel in at each end is the fix.
	float2 lut(float k)
	{
	    return float2(0.0078 + saturate(k) * 0.9844, 0.5);
	}

	float3 shade(Surface s)
	{
	    // s.color is this copy's own colour, raw and never folded into the
	    // albedo: rgb is the tint this blast was spawned with and ALPHA is how
	    // far through its life it is. One material, one draw call, twenty
	    // fireballs each at their own age.
	    float age = s.color.a;

	    // Two noise taps at different rates, multiplied — the cheapest thing
	    // that reads as burning rather than as a moving picture of fire.
	    float a = noise_map.Sample(s.uv * 2.0 + float2(t * 0.09, -t * 0.31)).r;
	    float b = noise_map.Sample(s.uv * 5.0 - float2(t * 0.24, t * 0.57)).r;
	    float heat = saturate(a * b * 3.6) * (1.0 - age);

	    // The shell burns away from the outside in. shade() returns rgb and
	    // never alpha, on purpose — a body that MEANS to make geometry vanish
	    // discards, which is what breaks the ball into tongues as it dies.
	    if (heat < 0.09) discard;
	    return ramp_map.Sample(lut(heat)).rgb * s.color.rgb * heat * 2.8;
	}`,
});

// ---------------------------------------------------------------------------
// The yard
// ---------------------------------------------------------------------------

const scene = new three.Scene();
scene.background = [0.05, 0.06, 0.08];
// The direction points from the surface TO the light, so positive Y lights the
// tops of things.
three.light.set([-0.35, 0.9, 0.28], 0.32);
three.light.shadow = { enabled: true, size: 2048 };

const ground = new three.Mesh(new three.PlaneGeometry(CELL * MAP.length, CELL * MAP.length), groundMat);
ground.name = 'ground';
ground.rotation.x = -Math.PI / 2;
ground.color = [0.34, 0.30, 0.25, 1];
ground.static = true;
scene.add(ground);

// Nothing falls in this game and nothing is thrown: the bullets are the only
// dynamic bodies there are, and they should fly dead straight.
three.physics.gravity = [0, 0, 0];

// Every tank's nodes hang off this one Group, which is what `static parent`
// below points at. A Group draws nothing and costs no draw call; what it buys
// is that the tanks are one thing the scene graph can see.
const tanks = new three.Group();
scene.add(tanks);

const BLOCK = new three.BoxGeometry(CELL, WALL_H, CELL);
const UNIT = new three.BoxGeometry(1, 1, 1);
const SHOT = new three.SphereGeometry(0.16, 12, 8);
const FIRE = new three.SphereGeometry(1, 16, 12);

// ---------------------------------------------------------------------------
// Numbers, and the two helpers everything below reaches for
// ---------------------------------------------------------------------------

const PLAYER_SPEED = 5.2, FOE_SPEED = 3.4, SHOT_SPEED = 15;
const FOES_AT_ONCE = 3, FOES_PER_ROUND = 12, FOE_EVERY = 3.2;

// North, east, south, west — and the heading that faces each one, given that
// a box's local +Z is its front.
const DIRS = [[0, -1], [1, 0], [0, 1], [-1, 0]];
const HEADING = DIRS.map(([dx, dz]) => Math.atan2(dx, dz));
const KEY_FOR_DIR = ['up', 'right', 'down', 'left'];

function part(size, at, tint) {
	const m = new three.Mesh(UNIT, tankMat);
	m.scale.set(size[0], size[1], size[2]);
	m.position.set(at[0], at[1], at[2]);
	m.color = tint;
	return m;
}

// Which of the four directions points from `from` towards `to`.
function towards(from, to) {
	const dx = to[0] - from[0], dz = to[2] - from[2];
	return Math.abs(dx) > Math.abs(dz) ? (dx > 0 ? 1 : 3) : (dz > 0 ? 2 : 0);
}

// ---------------------------------------------------------------------------
// The entities
//
// Five classes, and the statics on each one are the whole declaration — there
// is no registration call anywhere below.
// ---------------------------------------------------------------------------

// Steel: it stops everything and it never changes. It is its own class rather
// than a flag on Brick so that the rule about it can be one line.
class Steel extends three.Entity {
	static body = { shape: 'box', mass: 0 };

	constructor(col, row) {
		super();
		this.object = new three.Mesh(BLOCK, steelMat);
		this.object.name = `steel_${col}_${row}`;
		this.object.position.set(cellX(col), WALL_H / 2, cellZ(row));
		// Scenery that never moves: the shadow pass gets to skip re-fitting it.
		this.object.static = true;
	}
}

// Brick: three hits, and each one is a material swap down the same stack.
class Brick extends three.Entity {
	static body = { shape: 'box', mass: 0 };

	constructor(col, row) {
		super();
		this.hp = 3;
		this.object = new three.Mesh(BLOCK, BRICK_MAT[3]);
		this.object.name = `brick_${col}_${row}`;
		this.object.position.set(cellX(col), WALL_H / 2, cellZ(row));
	}

	// Answers with whether that was the last one.
	hit() {
		this.hp--;
		if (this.hp > 0) {
			this.object.material = BRICK_MAT[this.hp];
			return false;
		}
		// `remove()` takes the body, the node and the lookup away NOW, so a
		// wall broken half way through a frame stops blocking on this tick.
		this.remove();
		return true;
	}
}

// The eagle. One of these exists at a time and losing it ends the round.
class Eagle extends three.Entity {
	static body = { shape: 'box', mass: 0 };

	constructor(col, row) {
		super();
		this.object = new three.Mesh(UNIT, eagleMat);
		this.object.name = 'eagle';
		this.object.scale.set(1.6, 1.5, 1.6);
		this.object.position.set(cellX(col), 0.75, cellZ(row));
	}
}

// A tank. The drawn body is a Group of five tinted boxes; the thing bullets
// actually hit is the invisible kinematic box `static volume` declares beside
// it, carried every frame by the `Tank.follow` system the class installs.
class Tank extends three.Entity {
	static parent = tanks;
	static volume = { shape: 'box', size: [1.5, 1.0, 1.5], offset: [0, 0.5, 0] };

	constructor(col, row, foe) {
		super();
		this.foe = foe;
		this.dir = foe ? 2 : 0;             // an index into DIRS
		this.gun = three.cooldown(foe ? 1.1 : 0.45);
		this.turn = 0;                      // seconds until the AI reconsiders
		this.blocked = false;

		const skin = foe ? [0.74, 0.74, 0.78, 1] : [0.42, 0.60, 0.26, 1];
		const dark = foe ? [0.50, 0.50, 0.56, 1] : [0.27, 0.40, 0.17, 1];
		const root = new three.Group();
		root.add(part([1.2, 0.5, 1.5], [0, 0.30, 0], skin));            // hull
		root.add(part([0.28, 0.45, 1.6], [-0.62, 0.25, 0], dark));      // left track
		root.add(part([0.28, 0.45, 1.6], [0.62, 0.25, 0], dark));       // right track
		root.add(part([0.8, 0.42, 0.8], [0, 0.75, -0.05], skin));       // turret
		root.add(part([0.16, 0.16, 1.0], [0, 0.78, 0.62], dark));       // barrel
		root.position.set(cellX(col), 0, cellZ(row));
		root.rotation.y = HEADING[this.dir];
		this.object = root;
	}

	// Where the movement capsule is: the node sits on the ground and the
	// capsule sits in the middle of the hull.
	centre() {
		const p = this.object.position;
		return [p.x, 0.55, p.z];
	}

	// The muzzle, in world space — where a shot starts and where it must NOT
	// still be inside its own tank.
	muzzle() {
		const p = this.object.position, h = this.object.rotation.y;
		return [p.x + Math.sin(h) * 1.15, 0.78, p.z + Math.cos(h) * 1.15];
	}

	fire() {
		if (!this.gun.start()) return false;
		Bullet.spawn(this, this.dir);
		return true;
	}

	// One axis-locked step. `three.moveAndSlide` takes a position and answers
	// with one — it owns no object and integrates nothing, so the tank's y and
	// its heading stay this class's business.
	drive(dt, dir) {
		if (dir < 0) { this.blocked = false; return; }
		this.dir = dir;
		this.object.rotation.y = HEADING[dir];
		const [dx, dz] = DIRS[dir];
		const step = (this.foe ? FOE_SPEED : PLAYER_SPEED) * dt;
		const r = three.moveAndSlide(this.centre(), [dx * step, 0, dz * step], {
			radius: 0.55, height: 0.9, step: 0.05, snap: 0,
			// The whole subtree, not one mesh: without this a tank collides
			// with its own turret and never moves at all.
			ignore: this.object,
		});
		this.object.position.set(r.position.x, 0, r.position.z);
		this.blocked = !!r.hit;
	}

	die() {
		Blast.spawn([this.object.position.x, 0.7, this.object.position.z], 2.2, 0.75,
			this.foe ? [1.0, 0.72, 0.34] : [1.0, 0.45, 0.30]);
		this.remove();
	}
}

// A shot. The only dynamic body in the world, and the only thing that raises a
// contact — which is what every rule below is written against.
class Bullet extends three.Entity {
	static body = { shape: 'sphere', mass: 0.2, friction: 0, restitution: 0 };
	// A bullet is not scenery: without this a tank's movement sweep walks into
	// its own shot and stops dead a metre from the barrel.
	static collides = false;

	constructor(from, dir) {
		super();
		this.foe = from.foe;
		this.dead = false;
		this.velocity = [DIRS[dir][0] * SHOT_SPEED, 0, DIRS[dir][1] * SHOT_SPEED];
		this.object = new three.Mesh(SHOT, shotMat);
		this.object.name = 'shot';
		this.object.color = from.foe ? [1.0, 0.86, 0.55, 1] : [1.0, 0.95, 0.70, 1];
		this.object.position.set(...from.muzzle());
	}

	// Idempotent, because a shot that hits two things in one step is dispatched
	// twice and a second removal would throw.
	pop(size = 0.9) {
		if (this.dead) return;
		this.dead = true;
		const p = this.object.position;
		Blast.spawn([p.x, p.y, p.z], size, 0.35, [1.0, 0.78, 0.42]);
		this.remove();
	}
}

// Fire. No body, no collider, nothing to hit — it only draws.
class Blast extends three.Entity {
	static collides = false;

	constructor(at, size, life, tint) {
		super();
		this.age = 0;
		this.size = size;
		this.life = life;
		this.tint = tint;
		this.object = new three.Mesh(FIRE, blastMat);
		this.object.name = 'blast';
		this.object.position.set(at[0], at[1], at[2]);
	}
}

// ---------------------------------------------------------------------------
// The rules
//
// Every consequence in the game, in five lines. `Class.on(event, matcher, fn)`
// dispatches on a PAIR and SUBJECT FIRST — the rule lives on Bullet, so the
// handler is handed (bullet, whatever it hit) in that order, and the class the
// rule hangs on is the type test. There is no `if (other.kind === ...)` here
// because there is nowhere for one to go.
// ---------------------------------------------------------------------------

Bullet.on('touch', Brick, (shot, wall) => {
	shot.pop();
	if (wall.hit()) G.broken++;
});

Bullet.on('touch', Steel, (shot) => shot.pop(0.7));

Bullet.on('touch', Tank, (shot, tank) => {
	// Your own shell cannot kill you, and neither can your own side's.
	if (shot.foe === tank.foe) return;
	shot.pop();
	tank.die();
	if (tank.foe) G.kills++; else G.lost++;
	if (tank === G.player) G.player = null;
});

Bullet.on('touch', Eagle, (shot, eagle) => {
	shot.pop();
	if (G.over) return;
	G.over = three.clock.time;
	Blast.spawn([eagle.object.position.x, 1.0, eagle.object.position.z], 3.4, 1.1, [1.0, 0.5, 0.25]);
});

// Two shells meeting in the air take each other out, as they always have.
Bullet.on('touch', Bullet, (a, b) => { a.pop(0.6); b.pop(0.6); });

// ---------------------------------------------------------------------------
// The round
// ---------------------------------------------------------------------------

// Each run_script call has its own scope, so everything a later call, a key
// handler or a system needs to reach has to live somewhere it can find.
const G = globalThis.yard = {
	scene, player: null, eagle: null, spawns: [], home: [0, 0],
	round: 0, kills: 0, lost: 0, broken: 0, waiting: FOES_PER_ROUND,
	over: 0, since: 0, auto: true, held: new Set(),
};

// The steel never changes, so it is built once and outlives every round.
MAP.forEach((line, row) => {
	[...line].forEach((c, col) => {
		if (c === '#') Steel.spawn(col, row);
		if (c === 'E') G.spawns.push([col, row]);
		if (c === 'P') G.home = [col, row];
	});
});

// A round is the bricks, the eagle and everybody standing in the yard. Losing
// the eagle rebuilds all of it, which is what makes a long headless run keep
// having something to look at.
function newRound() {
	Bullet.clear();
	Blast.clear();
	Brick.clear();
	Tank.clear();
	Eagle.clear();
	eagleMat.layers[0].opacity = 0;

	MAP.forEach((line, row) => {
		[...line].forEach((c, col) => {
			if (c === 'b') Brick.spawn(col, row);
			if (c === 'A') G.eagle = Eagle.spawn(col, row);
		});
	});
	G.player = Tank.spawn(G.home[0], G.home[1], false);
	G.waiting = FOES_PER_ROUND;
	G.since = 0;
	G.over = 0;
	G.round++;
}

// ---------------------------------------------------------------------------
// The systems
//
// A named, ordered list rather than one animation callback with five things in
// it. It makes nothing faster; it makes a slow frame attributable, and
// `three.systems.report()` will say which of these it was.
// ---------------------------------------------------------------------------

// Enemies arrive at the top corners, a few at a time.
three.systems.step('spawn', (dt) => {
	if (G.over) return;
	G.since += dt;
	if (G.since < FOE_EVERY || G.waiting <= 0) return;
	let alive = 0;
	for (const t of Tank) if (t.foe) alive++;
	if (alive >= FOES_AT_ONCE) return;
	G.since = 0;
	G.waiting--;
	const [col, row] = G.spawns[three.randInt(0, G.spawns.length - 1)];
	Tank.spawn(col, row, true);
	// A tank materialising is worth a puff of its own.
	Blast.spawn([cellX(col), 0.7, cellZ(row)], 1.6, 0.5, [0.55, 0.80, 1.0]);
});

// The player. Keys are polled rather than latched, because driving is a state
// and not an edge — a held key fires no repeat event.
three.systems.step('player', (dt) => {
	const p = G.player;
	if (!p) return;
	let dir = -1;
	if (three.input.isDown('up') || three.input.isDown('w')) dir = 0;
	else if (three.input.isDown('right') || three.input.isDown('d')) dir = 1;
	else if (three.input.isDown('down') || three.input.isDown('s')) dir = 2;
	else if (three.input.isDown('left') || three.input.isDown('a')) dir = 3;
	p.drive(dt, dir);
	if (three.input.isDown('space')) p.fire();
});

// The enemies. Drive at the eagle, turn when something is in the way, fire on
// the gun's own cooldown — which is a `three.cooldown` rather than a number
// counted down by hand, so a paused clock pauses it too.
three.systems.step('foes', (dt) => {
	const goal = G.eagle ? G.eagle.object.position : null;
	for (const t of Tank) {
		if (!t.foe) continue;
		t.turn -= dt;
		if (t.blocked || t.turn <= 0) {
			t.turn = three.randFloat(0.8, 2.2);
			const at = t.centre();
			// Mostly towards the eagle, sometimes not — a pack that all takes
			// the same corner every round is a pack you have already beaten.
			t.dir = (goal && three.randFloat(0, 1) < 0.6)
				? towards(at, [goal.x, goal.y, goal.z])
				: three.randInt(0, 3);
		}
		t.drive(dt, t.dir);
		t.fire();
	}
});

// A dynamic body's velocity is recomputed by the solver at the end of every
// step, so re-asserting it is what keeps a shell flying dead straight instead
// of drifting off the first thing it grazes.
three.systems.step('shots', () => {
	for (const b of Bullet) if (!b.dead) three.physics.setVelocity(b.object, b.velocity);
});

// The fire. Everything here is per-copy — a scale and a colour — which is why
// twenty blasts are still one draw call.
three.systems.frame('fire', (dt) => {
	blastMat.uniforms.t = three.clock.time;
	for (const b of Blast) {
		b.age += dt / b.life;
		if (b.age >= 1) { b.remove(); continue; }
		// Fast out, then slowing: a square root is the whole easing curve.
		const s = b.size * (0.3 + 0.85 * Math.sqrt(b.age));
		b.object.scale.set(s, s, s);
		b.object.color = [b.tint[0], b.tint[1], b.tint[2], b.age];
	}
});

// The round. The eagle's ruin layer is the one `animated: true` layer in the
// file, so this is a uniform write per frame rather than a new pipeline.
three.systems.step('round', (dt) => {
	if (G.over) {
		eagleMat.layers[0].opacity = three.moveTowards(eagleMat.layers[0].opacity, 1, dt * 2.2);
		if (three.clock.time - G.over > 3.5) newRound();
		return;
	}
	// A player who has been shot comes back at the corner he started from,
	// once nothing hostile is standing on it.
	if (!G.player) {
		let clear = true;
		for (const t of Tank) if (t.foe) {
			const d = t.centre();
			if (Math.hypot(d[0] - cellX(G.home[0]), d[2] - cellZ(G.home[1])) < 3) clear = false;
		}
		if (clear) G.player = Tank.spawn(G.home[0], G.home[1], false);
	}
});

// ---------------------------------------------------------------------------
// The autopilot
//
// `--headless` has no keyboard, so a scene that can only be driven by one is a
// scene no batch run ever exercises. This presses the game's OWN keys through
// `three.input.press`, which goes down the same path a real one does — so every
// headless run is a playtest that says whether the level still plays.
//
// It keeps the set of keys it pressed itself: a key that is down and not in
// that set is somebody taking the controls, and it stands aside.
// ---------------------------------------------------------------------------

function press(k) { if (!G.held.has(k)) { three.input.press(k); G.held.add(k); } }
function lift(k) { if (G.held.has(k)) { three.input.release(k); G.held.delete(k); } }
function liftAll() { for (const k of [...G.held]) lift(k); }

three.systems.frame('autopilot', () => {
	for (const k of ['up', 'down', 'left', 'right', 'w', 'a', 's', 'd', 'space'])
		if (three.input.isDown(k) && !G.held.has(k)) G.auto = false;
	if (!G.auto || !G.player) { liftAll(); return; }

	// Head for the nearest enemy; back off towards the eagle when there is
	// none in the yard yet.
	const me = G.player.centre();
	let target = G.eagle ? G.eagle.object.position : null;
	let best = Infinity;
	for (const t of Tank) {
		if (!t.foe) continue;
		const p = t.object.position;
		const d = Math.hypot(p.x - me[0], p.z - me[2]);
		if (d < best) { best = d; target = p; }
	}
	let dir = target ? towards(me, [target.x, target.y, target.z]) : 0;
	// Blocked? Take the other axis rather than grinding against the wall.
	if (G.player.blocked) dir = (dir + (three.randFloat(0, 1) < 0.5 ? 1 : 3)) % 4;

	for (const k of KEY_FOR_DIR) if (k !== KEY_FOR_DIR[dir]) lift(k);
	press(KEY_FOR_DIR[dir]);
	// The gun's own cooldown decides the rate, so holding fire is enough.
	press('space');
}, { before: 'fire' });

three.onKeyDown('p', () => { G.auto = !G.auto; liftAll(); });

// ---------------------------------------------------------------------------
// Go
// ---------------------------------------------------------------------------

newRound();

three.camera.lookAt(0, 0, 0);
three.camera.orbit(0, 62, 34);

three.debug.write({
	keys: { 'arrows / wasd': 'drive', space: 'fire', p: 'autopilot on/off' },
	map: `${MAP[0].length}x${MAP.length} cells of ${CELL}`,
	steel: Steel.count, brick: Brick.count, tanks: Tank.count,
	materials: 'ground, brick x3 and eagle are LayeredMaterial; the fire is a ShaderMaterial',
	stats: three.stats(),
});
