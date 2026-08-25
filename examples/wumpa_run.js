// wumpa_run.js — a Crash-shaped run down a jungle hollow, built on §17
//
// The six things the request asked for, one each:
//
//   heightfield      one three.Field whose floor follows the path's own
//                    elevation and whose walls are a function of the distance
//                    to it — so the hollow is a corridor by construction, and
//                    the corridor CLIMBS instead of being flat at y=0
//   material layers  three.LayeredMaterial over the terrain: one splat mask
//                    packed by three.Field.mask, four layers — trail(r),
//                    jungle(g), cliff(b), leaf litter(a)
//   textures         every pixel generated here, so the file runs with no
//                    assets on disk: ground, bark, crates, fruit, critters
//   colliders        four kinds, on purpose — the terrain is ONE
//                    shape:'heightfield' body, crates are dynamic boxes that
//                    tumble, boulders are convex hulls, fruit are triggers, and
//                    the player carries a kinematic capsule so it shoves what
//                    it runs into and trips the triggers
//   player           three.moveAndSlide. The canyon wall IS the fence: there is
//                    no invisible corridor to be pushed back into, no ground
//                    snap written by hand, and no circle test per boulder
//   navigation       three.nav.bake over the finished level, then ONE
//                    three.nav.field re-solved at the player a few times a
//                    second, sampled for the whole pack by three.steer
//
//   Run it:
//   ./build/three --script examples/wumpa_run.js
//   One frame, no window:
//   ./build/three --headless --script examples/wumpa_run.js --screenshot out.png
//   Play it without a window — the fixed loop steps, keys latch, nav runs:
//   ./build/three --headless --script examples/wumpa_run.js --frames 900 \
//       --screenshot run-%03d.png --every 150
//
// ## Controls
//
//   W A S D / arrows   run (camera-relative)
//   Space              jump — hold at the top of a bounce to go higher
//   J / K / shift      SPIN. Breaks crates, and sends a critter flying
//   Q E                swing the camera        R F   tilt it
//   drag               look                    wheel  zoom
//
// ## What is different from examples/crash_canyon.js
//
// The same level idea, and the movement half is 62 lines against 117 — one
// `playerStep` against a `playerStep`, a `groundAt` and a list of blocker
// circles. What went away is all the arithmetic that was standing in for
// collision: `nearestOnPath` shoving the player back into the corridor,
// `groundAt` snapping y to the terrain, a circle test per boulder, and the
// whole vertical block. One `three.moveAndSlide` does the four of them against
// the geometry that is actually drawn — which is why the floor here is allowed
// to climb, where crash_canyon's corridor is dead flat because a chain of
// axis-aligned boxes is the only shape its fence could take.
//
// The saving went into the pack. crash_canyon has no NPCs at all, because a
// critter that walks round a boulder needs a graph and there was none.
//
// ## What building it found, and what building it cost after the fixes
//
// Four things in §17 were wrong or missing, and this file was where each one
// showed. Every one of them is now in the engine rather than worked around
// here, and the three places to look are:
//
//   `noCollide`     the cast is not collision geometry. It replaces hiding
//                   every character's Group around the whole movement phase,
//                   which was the only way to exclude a subtree from a sweep
//                   and cost the spatial index a rebuild per toggle
//   `dropFruit`     `collides = false` is what stops a drawn pickup being a
//                   bollard; the wider volume beside it is reach, not a dodge
//   the nav bake    `radius` is the critter's own again — the erosion used to
//                   cut any descending floor into islands — and `components`
//                   is the counter that says so at bake time
//
// ## And what §21 then did to the shape of it
//
// Three things went, and none of them was an optimisation:
//
//   the arithmetic   the eight helpers this file used to open with — `smooth`,
//                    `lerp`, `clamp01`, `step`, `band`, `tint`, `mixc`,
//                    `hash2` — plus a `valueNoise` and an `fbm` over them, are
//                    `three`'s. Four of the eight examples had the same block
//                    and the copies had drifted
//   `packStep`       101 lines of one function are six named systems declared
//                    beside the pack. Three of them are ONE crossing each for
//                    the whole pack — `field.sample`, `three.steer`,
//                    `three.moveAndSlideAll` — where the old shape called the
//                    single-agent verb ten times
//   the callback     the ninety-line `setAnimationLoop` is seven systems in a
//                    declared order, and `three.systems.report()` says what
//                    each one costs. It reports the PLAYER as the most
//                    expensive thing in the frame, at more than the whole pack
//                    put together, which is not what anyone would have guessed
//
// **The test of it is what a second kind of enemy costs.** A wasp that flies
// would be a second `three.cast`, its own columns, and its own systems declared
// beside it. Nothing in the pack's six changes, nothing in the frame's seven
// changes, and the running order stays readable because `order` is a number
// rather than a position in a function.

three.budget = 60000;   // a cold build: the terrain fill is 2.6M distance tests

// ---------------------------------------------------------------------------
// Arithmetic — all of it three's now.
//
// This file used to open with eight helpers written out by hand: `smooth`,
// `lerp`, `clamp01`, `step`, `band`, `tint`, `mixc` and `hash2`, plus a
// `valueNoise` and an `fbm` over them. Four of the eight examples had the same
// block and the copies had already drifted. They are `math.js` now.
//
// **The one thing to read twice is the argument order.** GLSL's smoothstep is
// `(edge0, edge1, x)` and Three.js's — which is what `three.smoothstep` is — is
// `(x, min, max)`, the VALUE FIRST. The local `step(lo, hi, x)` this file used
// to carry was the GLSL one, so every call site below is written the other way
// round now on purpose rather than being wrapped back.
// ---------------------------------------------------------------------------
const { lerp, clamp, clamp01, smoothstep, band, hash } = three;
const mixc = three.mixColor;
const tint = three.tintColor;
const hash2 = hash;
const smooth = t => smoothstep(t, 0, 1);

// A tileable fbm image, from the point sampler. `period` is what makes the left
// edge meet the right, and `fbm2` scales it per octave — which is the one part
// of a tiling fbm that is wrong when it is written by hand, and the reason the
// version this replaces had to build a grid per octave to get it.
function fbm(size, cells, seed, octaves) {
	const out = new Float32Array(size * size);
	for (let y = 0; y < size; y++) {
		for (let x = 0; x < size; x++) {
			out[y * size + x] = three.fbm2((x / size) * cells, (y / size) * cells, { octaves, seed, period: cells });
		}
	}
	return out;
}

// Row 0 is the BOTTOM row — uv (0,0) is bottom-left, as in Three.js. Glyphs
// below are written top-row-first and flipped on the way in.
function canvas(size, shade) {
	const px = new Uint8Array(size * size * 4);
	for (let y = 0; y < size; y++) for (let x = 0; x < size; x++) {
		const k = y * size + x, c = shade(x, y, k);
		px[k * 4 + 0] = clamp(c[0], 0, 255);
		px[k * 4 + 1] = clamp(c[1], 0, 255);
		px[k * 4 + 2] = clamp(c[2], 0, 255);
		px[k * 4 + 3] = 255;
	}
	return px;
}
function stamp(px, size, rows, cx, cy, scale, color) {
	const h = rows.length, w = rows[0].length;
	const x0 = Math.round(cx - (w * scale) / 2), y0 = Math.round(cy - (h * scale) / 2);
	for (let r = 0; r < h; r++) for (let c = 0; c < w; c++) {
		if (rows[r][c] === ' ') continue;
		for (let dy = 0; dy < scale; dy++) for (let dx = 0; dx < scale; dx++) {
			const x = x0 + c * scale + dx, y = y0 + (h - 1 - r) * scale + dy;
			if (x < 0 || y < 0 || x >= size || y >= size) continue;
			const k = (y * size + x) * 4;
			px[k] = color[0]; px[k + 1] = color[1]; px[k + 2] = color[2];
		}
	}
}
const paint = (size, shade) => new three.DataTexture(canvas(size, shade), size, size);

const GLYPH = {
	arrow: ['   ##   ', '  ####  ', ' ###### ', '########', '   ##   ', '   ##   ', '   ##   ', '   ##   '],
	tnt: ['#######', '   #   ', '   #   ', '   #   ', '   #   ', '       ', '  ###  '],
};

// ---------------------------------------------------------------------------
// The hollow.
//
// One curve is the whole level: the floor's height is the path's own
// elevation, the walls are the distance to it, the splat bands are the
// distance to it, and every crate, palm and critter is placed at a distance
// ALONG it. Author the curve and the rest follows.
// ---------------------------------------------------------------------------
const W = 150, D = 150, SEG = 160;
const HALF = 5.4;        // the corridor floor is flat inside this
const WALL_FEATHER = 1.4;

const PATH_CTRL = [
	[10, 66], [0, 50], [-16, 38], [-24, 20], [-14, 4],
	[2, -6], [18, -16], [26, -34], [14, -50], [-6, -60], [-26, -66],
];
const PATH = three.catmullRom(PATH_CTRL, { samples: 8 });

const CUM = [0];
for (let i = 1; i < PATH.length; i++) {
	CUM.push(CUM[i - 1] + Math.hypot(PATH[i][0] - PATH[i - 1][0], PATH[i][1] - PATH[i - 1][1]));
}
const PATH_LEN = CUM[CUM.length - 1];

// The corridor floor climbs and dips. This is the one number the whole terrain
// is hung off, and it is why the level is not flat: a heightfield that only
// makes walls is a wall generator, not ground.
function pathY(s) {
	return 3.4 + Math.sin(s * 0.031) * 2.6 + Math.sin(s * 0.0165 + 1.1) * 1.7 + s * 0.006;
}

function along(s) {
	const t = clamp(s, 0, PATH_LEN);
	let i = 1;
	while (i < CUM.length - 1 && CUM[i] < t) i++;
	const a = PATH[i - 1], b = PATH[i];
	const seg = Math.max(1e-6, CUM[i] - CUM[i - 1]);
	const k = (t - CUM[i - 1]) / seg;
	const tx = (b[0] - a[0]) / seg, tz = (b[1] - a[1]) / seg;
	return { x: lerp(a[0], b[0], k), z: lerp(a[1], b[1], k), tx, tz, nx: -tz, nz: tx, yaw: Math.atan2(tx, tz) };
}
const onPath = (s, off) => {
	const p = along(s);
	return { x: p.x + p.nx * off, z: p.z + p.nz * off, yaw: p.yaw, s };
};

// Nearest point on the polyline, and how far ALONG it that point is — the `s`
// is what lets the floor's height follow the path instead of being a plane.
function nearestOnPath(x, z) {
	let bd = 1e9, bx = 0, bz = 0, bs = 0;
	for (let i = 1; i < PATH.length; i++) {
		const ax = PATH[i - 1][0], az = PATH[i - 1][1], cx = PATH[i][0], cz = PATH[i][1];
		const dx = cx - ax, dz = cz - az, L = dx * dx + dz * dz;
		let t = L > 0 ? ((x - ax) * dx + (z - az) * dz) / L : 0;
		t = clamp01(t);
		const px = ax + dx * t, pz = az + dz * t;
		const d = Math.hypot(x - px, z - pz);
		if (d < bd) { bd = d; bx = px; bz = pz; bs = lerp(CUM[i - 1], CUM[i], t); }
	}
	return { d: bd, x: bx, z: bz, s: bs };
}

// ---------------------------------------------------------------------------
// The height field.
// ---------------------------------------------------------------------------
function ridge(x, z) {
	return Math.sin(x * 0.048 + 1.1) * Math.cos(z * 0.041 - 0.6) * 2.3
		+ Math.sin(x * 0.023 - z * 0.019 + 2.3) * 3.2
		+ Math.cos(x * 0.034 + z * 0.029) * 1.5;
}

const field = new three.Field({ width: W, depth: D, segments: SEG });
{
	const side = field.side;
	for (let j = 0; j < side; j++) {
		const z = field.zAt(j);
		for (let i = 0; i < side; i++) {
			const x = field.xAt(i);
			const n = nearestOnPath(x, z);
			const wall = Math.max(0, n.d - HALF - WALL_FEATHER);
			// Quadratic, so the corridor edge is a scramble and the far wall is
			// a cliff — past about 45 degrees moveAndSlide stops calling it
			// ground and the nav bake stops calling it walkable, which is what
			// makes the hollow a corridor without an invisible fence in it.
			const rise = Math.min(0.45 * wall + 0.09 * wall * wall, 22);
			field.values[j * side + i] = pathY(n.s) + rise + ridge(x, z) * Math.min(1, wall / 6);
		}
	}
}

// Shelves to jump up onto. Levelled into the field before the terrain is
// built, because a pad has to be flat before it is ground.
//
// Every one of them is OFF the centreline and no wider than half the corridor.
// A pad across the trail is a wall the height of its own step, and `step` is
// 0.45 — so a 2.3-unit shelf in the middle of the path is not a platform, it is
// a full stop with no way over it and nothing that reports as ground to jump
// from. The first two are a staircase: 1.4 is inside one jump from the floor,
// 3.0 is not, and is inside one jump from the step below it.
const SHELVES = [
	{ s: 50, off: 4.0, w: 5, d: 5, up: 1.4 },
	{ s: 57, off: 4.2, w: 5, d: 5, up: 3.0 },
	{ s: 138, off: -4.0, w: 5, d: 6, up: 1.5 },
].map(p => ({ ...p, ...onPath(p.s, p.off) }));
for (const p of SHELVES) {
	p.y = pathY(p.s) + p.up;
	field.flatten({ x: p.x, z: p.z, width: p.w, depth: p.d }, p.y, 1.1);
}

const terrain = new three.TerrainGeometry({ width: W, depth: D, segments: SEG, skirt: 10, heights: field });
const groundY = (x, z) => terrain.heightAt(x, z);

// ---------------------------------------------------------------------------
// Textures — a jungle palette: wet trail, sun-bleached grass, grey cliff.
// ---------------------------------------------------------------------------
const litterN = fbm(128, 4, 71, 3);
const grassN = fbm(128, 6, 913, 3);
const rockN = fbm(128, 5, 337, 4);

const tex = {
	trail: paint(128, (x, y, k) => {
		const n = litterN[k];
		const c = mixc([104, 78, 52], [138, 110, 74], n);
		const grit = hash2(x, y, 5) > 0.86 ? 16 : 0;
		return [c[0] + grit, c[1] + grit - 2, c[2] + grit - 6];
	}),
	jungle: paint(128, (x, y, k) => {
		const n = grassN[k];
		const blade = Math.sin(x * 0.9 + n * 9) * 0.5 + 0.5;
		const c = mixc([58, 92, 40], [104, 142, 58], n * 0.75 + blade * 0.25);
		return hash2(x, y, 11) > 0.965 ? [c[0] + 30, c[1] + 44, c[2] + 10] : c;
	}),
	cliff: paint(128, (x, y, k) => {
		const n = rockN[k];
		const strata = Math.sin(y * 0.28 + n * 3.4) * 0.5 + 0.5;
		const c = mixc([118, 100, 78], [172, 152, 120], n * 0.6 + strata * 0.4);
		return hash2(x, y, 17) > 0.93 ? [c[0] - 26, c[1] - 24, c[2] - 18] : c;
	}),
	litter: paint(128, (x, y, k) => {
		const n = litterN[(k * 7) % litterN.length];
		const leaf = band(n, 0.42, 0.72);
		return mixc([120, 96, 48], [168, 132, 56], n * 0.6 + leaf * 0.4);
	}),
	bark: paint(64, (x, y) => {
		const g = Math.sin(x * 1.5) * 0.5 + 0.5;
		const c = mixc([74, 56, 38], [104, 82, 56], g * 0.7 + hash2(x >> 2, y >> 3, 3) * 0.3);
		return c;
	}),
	frond: paint(64, (x, y) => {
		const rib = Math.abs(y - 32) < 2 ? 1 : 0;
		const c = mixc([46, 104, 44], [86, 148, 56], hash2(x >> 2, y >> 2, 23));
		return rib ? [c[0] * 0.7, c[1] * 0.8, c[2] * 0.6] : c;
	}),
	boulder: paint(64, (x, y) => {
		const n = rockN[((y << 1) * 128 + (x << 1)) % rockN.length];
		return mixc([88, 84, 80], [132, 126, 116], n);
	}),
	fruit: paint(32, (x, y) => {
		const dx = x - 16, dy = y - 16, d = Math.hypot(dx, dy) / 16;
		const c = mixc([242, 156, 40], [214, 78, 34], clamp01(d * 1.1));
		return d < 0.45 && dy > 2 ? [252, 214, 120] : c;
	}),
	critter: paint(48, (x, y) => {
		const n = hash2(x >> 2, y >> 2, 61);
		const belly = y < 18 ? 1 : 0;
		return belly ? mixc([206, 188, 148], [226, 210, 172], n)
			: mixc([96, 66, 116], [132, 92, 154], n);
	}),
};

// The crate family. One shade function, one glyph.
function crateTex(base, edge, glyph, ink) {
	const px = canvas(64, (x, y) => {
		const rim = Math.min(x, y, 63 - x, 63 - y);
		const plank = Math.sin(y * 0.62) * 0.5 + 0.5;
		return rim < 4 ? edge : mixc(base, tint(base, 1.16), plank * 0.5 + hash2(x >> 2, y >> 2, 7) * 0.5);
	});
	if (glyph) stamp(px, 64, glyph, 32, 32, 3, ink);
	return new three.DataTexture(px, 64, 64);
}
tex.crateWood = crateTex([164, 118, 62], [96, 66, 34], null, null);
tex.crateArrow = crateTex([196, 158, 62], [110, 84, 28], GLYPH.arrow, [64, 44, 16]);
tex.crateTnt = crateTex([176, 62, 48], [92, 28, 22], GLYPH.tnt, [250, 236, 210]);

// ---------------------------------------------------------------------------
// The splat mask — four fields packed into one RGBA image.
//
// Authored against the ACTUAL terrain: heightAt and normalAt read the grid the
// mesh was built from, so "cliff on the steep bits" lands on the steep bits
// that got drawn rather than on the ones the height function meant.
// ---------------------------------------------------------------------------
const MSEG = 160;
const mopts = { width: W, depth: D, segments: MSEG };
const mTrail = new three.Field(mopts);
const mJungle = new three.Field(mopts);
const mCliff = new three.Field(mopts);
const mLitter = new three.Field(mopts);
{
	const side = mTrail.side;
	for (let j = 0; j < side; j++) {
		const z = mTrail.zAt(j);
		for (let i = 0; i < side; i++) {
			const x = mTrail.xAt(i), at = j * side + i;
			const d = nearestOnPath(x, z).d;
			const slope = 1 - terrain.normalAt(x, z)[1];

			const cliff = clamp01((slope - 0.34) * 3.2);
			const trail = (1 - smoothstep(d, HALF - 2.2, HALF + 2.4)) * (1 - cliff * 0.8);
			const jungle = smoothstep(d, HALF - 0.5, HALF + 3) * (1 - cliff);
			const litter = band(d, HALF - 1.0, HALF + 5.5) * (1 - cliff) * 0.85;

			mTrail.values[at] = trail;
			mJungle.values[at] = jungle;
			mCliff.values[at] = cliff;
			mLitter.values[at] = litter;
		}
	}
}
const splat = three.Field.mask({ r: mTrail, g: mJungle, b: mCliff, a: mLitter });

const ground = new three.Mesh(terrain, new three.LayeredMaterial({
	map: tex.trail,
	mask: splat,
	layers: [
		{ name: 'jungle', map: tex.jungle, mask: 'g', uvScale: 30, blend: 'mix' },
		{ name: 'litter', map: tex.litter, mask: 'a', uvScale: 22, blend: 'mix', tint: [1.02, 0.98, 0.88] },
		{ name: 'cliff', map: tex.cliff, mask: 'b', uvScale: 26, blend: 'mix' },
		{ name: 'trail', map: tex.trail, mask: 'r', uvScale: 18, blend: 'mix', tint: [1.06, 1.0, 0.92] },
	],
}));
ground.name = 'ground';
ground.static = true;

const scene = new three.Scene();
scene.add(ground);
scene.background = 0x8ec6d8;

// A high sun. In a hollow with 20-unit walls a low one puts the whole corridor
// in shadow and the frame reads as one with no shadows in it at all.
three.light.set([0.42, 1.1, 0.36], 0.40);
three.light.shadow = { enabled: true, size: 2048, distance: 60, bias: 0.0004, intensity: 0.78 };

// ---------------------------------------------------------------------------
// Shared geometry and materials — one geometry under a scale, one material per
// look, so every crate of a kind is one draw call.
// ---------------------------------------------------------------------------
const BOX = new three.BoxGeometry(1, 1, 1);
const BALL = new three.SphereGeometry(0.5, 12, 9);
const CYL = new three.CylinderGeometry(0.5, 0.5, 1, 10);
const CONE = new three.ConeGeometry(0.5, 1, 12);
const CHIP = new three.BoxGeometry(0.28, 0.28, 0.28);

const mat = {
	bark: new three.MeshLambertMaterial({ map: tex.bark }),
	frond: new three.MeshLambertMaterial({ map: tex.frond, side: three.DoubleSide }),
	boulder: new three.MeshLambertMaterial({ map: tex.boulder }),
	fruit: new three.MeshLambertMaterial({ map: tex.fruit }),
	critter: new three.MeshLambertMaterial({ map: tex.critter }),
	wood: new three.MeshLambertMaterial({ map: tex.crateWood }),
	arrow: new three.MeshLambertMaterial({ map: tex.crateArrow }),
	tnt: new three.MeshLambertMaterial({ map: tex.crateTnt }),
	flat: new three.MeshLambertMaterial(),
};
mat.bark.repeat = [1, 3];

// Groups are for the things that have NO body. A body-backed object has to be
// a child of the scene itself — the solver works in world space, and a parent
// transform would fight it — so crates, boulders and fruit go straight on.
const groups = {};
for (const name of ['scenery', 'pack', 'debris', 'player']) {
	const g = new three.Group(); g.name = name; scene.add(g); groups[name] = g;
}

// ---------------------------------------------------------------------------
// The floor the SOLVER stands on: the terrain itself, as one body.
//
// `shape: 'heightfield'` hands the solver the grid TerrainGeometry was built
// from, so a crate rests on exactly the surface terrain.heightAt(x, z) reports
// — on the trail, on a shelf, and on the hillside a spin knocked it up.
// ---------------------------------------------------------------------------
three.physics.add(ground, { shape: 'heightfield', mass: 0, friction: 0.92, restitution: 0.03 });

// ---------------------------------------------------------------------------
// Boulders — a convex hull collider IS the geometry.
// ---------------------------------------------------------------------------
const BOULDERS = [
	{ s: 24, off: 4.4, r: 1.5 }, { s: 41, off: -4.8, r: 1.9 },
	{ s: 78, off: 4.9, r: 1.6 }, { s: 96, off: -5.1, r: 2.1 },
	{ s: 118, off: 4.6, r: 1.4 }, { s: 158, off: -4.7, r: 1.8 },
	{ s: 176, off: 5.0, r: 1.7 },
].map(b => ({ ...b, ...onPath(b.s, b.off) }));

for (const b of BOULDERS) {
	const pts = [];
	for (let i = 0; i < 26; i++) {
		const u = hash2(i, b.s | 0, 3) * 2 - 1;
		const a = hash2(i, b.s | 0, 9) * Math.PI * 2;
		const rr = Math.sqrt(1 - u * u);
		const k = 0.72 + hash2(i, b.s | 0, 15) * 0.5;
		pts.push([Math.cos(a) * rr * b.r * k, u * b.r * 0.78 * k, Math.sin(a) * rr * b.r * k]);
	}
	const m = new three.Mesh(new three.ConvexGeometry(pts), mat.boulder);
	m.position.set(b.x, groundY(b.x, b.z) + b.r * 0.45, b.z);
	m.name = `boulder@${b.s}`;
	m.static = true;
	scene.add(m);
	three.physics.add(m, { shape: 'hull', mass: 0, friction: 0.8 });
	b.mesh = m;
}

// ---------------------------------------------------------------------------
// Palms on the shoulder. Decoration only — no body, because moveAndSlide
// collides with the drawn triangles and a trunk is already solid to it.
// ---------------------------------------------------------------------------
for (let s = 8; s < PATH_LEN - 8; s += 11) {
	for (const side of [-1, 1]) {
		const off = side * (HALF + 2.6 + hash2(s | 0, side, 41) * 2.6);
		const at = onPath(s + hash2(s | 0, side, 43) * 5, off);
		const y = groundY(at.x, at.z);
		if (y > pathY(at.s) + 3.6) continue;        // do not plant up the cliff
		// Tall, and the fronds are short. A palm at the corridor edge with a
		// 3.4-unit frond puts a leaf between the follow camera and the player
		// on every second tree, which is the one thing a third-person camera
		// cannot be asked to forgive.
		const h = 6.2 + hash2(s | 0, side, 47) * 3.0;
		const palm = new three.Group();
		palm.position.set(at.x, y, at.z);
		palm.rotation.y = hash2(s | 0, side, 53) * 6.28;
		const trunk = new three.Mesh(CYL, mat.bark);
		trunk.scale.set(0.42, h, 0.42);
		trunk.position.set(0, h / 2, 0);
		palm.add(trunk);
		for (let f = 0; f < 6; f++) {
			const frond = new three.Mesh(CONE, mat.frond);
			frond.scale.set(2.4, 0.9, 1.0);
			frond.position.set(0, h + 0.1, 0);
			frond.rotation.y = (f / 6) * 6.28;
			frond.rotation.z = 1.15;
			palm.add(frond);
		}
		palm.static = true;
		groups.scenery.add(palm);
	}
}

// ---------------------------------------------------------------------------
// Crates.
//
// Dynamic boxes. They are drawable, so moveAndSlide walks INTO them and stops
// — Crash does not push crates, he breaks them — and they are rigid bodies, so
// the kinematic capsule shoves them and a spin sends them tumbling.
// ---------------------------------------------------------------------------
const CRATE = 1.35;
const CRATE_KIND = {
	wood: { mat: mat.wood, fruit: 3 },
	arrow: { mat: mat.arrow, fruit: 1, bounce: true },
	tnt: { mat: mat.tnt, fruit: 0, tnt: true },
};
const CRATE_PLAN = [
	{ s: 18, off: 0, k: 'wood' }, { s: 18, off: 1.7, k: 'wood' }, { s: 18, off: -1.7, k: 'wood' },
	{ s: 34, off: 0, k: 'arrow' },
	{ s: 47, off: -1.2, k: 'wood' }, { s: 47, off: 1.2, k: 'tnt' },
	{ s: 50, off: 4.0, k: 'wood', on: 0 },
	{ s: 66, off: 0, k: 'wood' }, { s: 66, off: 0, k: 'wood', stack: 1 },
	{ s: 84, off: 2.0, k: 'wood' }, { s: 84, off: -2.0, k: 'wood' }, { s: 88, off: 0, k: 'arrow' },
	{ s: 104, off: 0, k: 'tnt' }, { s: 108, off: -1.6, k: 'wood' }, { s: 108, off: 1.6, k: 'wood' },
	{ s: 126, off: 0, k: 'wood' }, { s: 126, off: 0, k: 'wood', stack: 1 }, { s: 126, off: 0, k: 'wood', stack: 2 },
	{ s: 138, off: -4.0, k: 'wood', on: 2 },
	{ s: 150, off: 1.8, k: 'arrow' }, { s: 150, off: -1.8, k: 'wood' },
	{ s: 168, off: 0, k: 'tnt' }, { s: 172, off: 0, k: 'wood' }, { s: 172, off: 2.2, k: 'wood' },
	{ s: 186, off: 0, k: 'wood' }, { s: 186, off: -2.2, k: 'wood' }, { s: 190, off: 1.4, k: 'arrow' },
];

const crates = [];
for (const c of CRATE_PLAN) {
	const at = onPath(c.s, c.off);
	const kind = CRATE_KIND[c.k];
	const base = c.on !== undefined ? SHELVES[c.on].y : groundY(at.x, at.z);
	const m = new three.Mesh(BOX, kind.mat);
	m.scale.set(CRATE, CRATE, CRATE);
	m.position.set(at.x, base + CRATE / 2 + (c.stack || 0) * CRATE, at.z);
	m.rotation.y = at.yaw;
	m.name = `crate:${c.k}@${c.s}`;
	scene.add(m);
	three.physics.add(m, { shape: 'box', mass: 5, friction: 0.7, restitution: 0.05 });
	crates.push({ m, kind: c.k, ...kind, alive: true });
}
// Every crate is found by its node, because a query answers with objects.
const crateOf = new Map(crates.map(c => [c.m, c]));

// ---------------------------------------------------------------------------
// Wumpa fruit — trigger volumes.
//
// **`collides = false` is what stops a pickup being a bollard.** A drawn mesh
// is swept against, so a fruit lying on the path used to bounce the player off
// unless it was made invisible before he reached it; the flag says "this is
// scenery, not a wall" and leaves it out of every spatial query while it still
// draws. Physics is a separate world and does not read it, which is why the
// trigger below still works.
//
// The second node is no longer a workaround — it is REACH. A body's collider is
// taken from its mesh, so the only way to be collected at 1.3 units rather than
// at 0.73 is a wider volume. It is invisible because there is nothing to see.
//
// A trigger needs two BODIES to overlap, and moveAndSlide gives the player
// none. That is what the player's kinematic capsule is for: it is driven from
// the controller's answer, it shoves crates, and it trips these.
// ---------------------------------------------------------------------------
const FRUIT_R = 0.62;      // the drawn fruit
const PICKUP_R = 1.8;      // the volume that collects it
const fruit = [];
const fruitOf = new Map();

function dropFruit(x, y, z) {
	const m = new three.Mesh(BALL, mat.fruit);
	m.scale.set(FRUIT_R, FRUIT_R, FRUIT_R);
	m.position.set(x, y, z);
	m.name = 'wumpa';
	m.collides = false;
	scene.add(m);

	const vol = new three.Mesh(BALL, mat.flat);
	vol.scale.set(PICKUP_R, PICKUP_R, PICKUP_R);
	vol.position.set(x, y, z);
	vol.visible = false;
	vol.name = 'wumpa-pickup';
	scene.add(vol);
	three.physics.add(vol, { shape: 'sphere', mass: 0, trigger: true });

	const f = { m, vol, alive: true, spin: hash2(x * 13 | 0, z * 7 | 0, 5) * 6.28, bob: hash2(x | 0, z | 0, 8) * 6.28 };
	fruit.push(f);
	fruitOf.set(vol, f);
	return f;
}
for (let s = 12; s < PATH_LEN - 10; s += 7.5) {
	const off = Math.sin(s * 0.21) * 2.6;
	const at = onPath(s, off);
	dropFruit(at.x, groundY(at.x, at.z) + 1.05, at.z);
}

// ---------------------------------------------------------------------------
// The player.
// ---------------------------------------------------------------------------
const HEIGHT = 1.75, RADIUS = 0.42;
const SPEED = 9.2, GRAV = 26, JUMP = 10.4;
const SPIN_TIME = 0.42, SPIN_R = 2.5;

function buildPlayer() {
	const g = new three.Group(); g.name = 'player';
	const spinner = new three.Group(); g.add(spinner);
	const body = new three.Mesh(BOX, mat.flat);
	body.scale.set(0.78, 0.82, 0.62); body.position.set(0, 0.86, 0); body.color = 0xd86a1e;
	spinner.add(body);
	const head = new three.Mesh(BOX, mat.flat);
	head.scale.set(0.66, 0.56, 0.6); head.position.set(0, 1.52, 0.02); head.color = 0xe2762a;
	spinner.add(head);
	for (const sx of [-1, 1]) {
		const ear = new three.Mesh(CONE, mat.flat);
		ear.scale.set(0.26, 0.4, 0.26); ear.position.set(sx * 0.2, 1.92, 0); ear.color = 0xc95c18;
		spinner.add(ear);
		const eye = new three.Mesh(BOX, mat.flat);
		eye.scale.set(0.14, 0.16, 0.06); eye.position.set(sx * 0.16, 1.6, 0.32); eye.color = 0xf5f0e2;
		spinner.add(eye);
	}
	const arms = [], legs = [];
	for (const sx of [-1, 1]) {
		const arm = new three.Group(); arm.position.set(sx * 0.52, 1.16, 0); spinner.add(arm);
		const am = new three.Mesh(BOX, mat.flat);
		am.scale.set(0.2, 0.62, 0.2); am.position.set(0, -0.3, 0); am.color = 0xd86a1e;
		arm.add(am); arms.push(arm);
		const leg = new three.Group(); leg.position.set(sx * 0.22, 0.46, 0); spinner.add(leg);
		const lm = new three.Mesh(BOX, mat.flat);
		lm.scale.set(0.26, 0.5, 0.3); lm.position.set(0, -0.23, 0); lm.color = 0x4a3b2c;
		leg.add(lm); legs.push(leg);
	}
	return { g: noCollide(g), spinner, arms, legs };
}
const P = buildPlayer();
groups.player.add(P.g);

// The kinematic capsule: a body the size of the controller's own capsule,
// driven from the controller's answer. It shoves crates and trips triggers;
// it does not decide where the player may go.
const capsule = new three.Mesh(CYL, mat.flat);
capsule.scale.set(RADIUS * 2, HEIGHT, RADIUS * 2);
capsule.visible = false;
capsule.name = 'player-capsule';
scene.add(capsule);
three.physics.add(capsule, { shape: 'capsule', mass: 0, kinematic: true });

const spawn = onPath(4, 0);
const ctl = {
	x: spawn.x, y: groundY(spawn.x, spawn.z) + 0.05, z: spawn.z,
	vy: 0, grounded: false, coyote: 0,
	yaw: (spawn.yaw * 180) / Math.PI + 180, pitch: 20, dist: 12,
	heading: spawn.yaw, moving: false, walkT: 0,
	spin: 0, spinCool: 0, spinAngle: 0,
	hurt: 0, s: 0,
};
const state = { fruit: 0, lives: 4, broken: 0, done: false, best: 0 };

// A handle for driving this from a run_script or a headless probe. `three.c3`
// has no UI yet (plan.md §5), so the score lives here and in console.log —
// and a scene that cannot be inspected from outside cannot be tested at all.
globalThis.__wumpa = { ctl, state, get pack() { return pack; }, get positions() { return P_POS; } };

// ---------------------------------------------------------------------------
// Debris — a pool of chips, thrown by hand rather than given bodies.
// ---------------------------------------------------------------------------
const chips = [];
for (let i = 0; i < 48; i++) {
	const m = new three.Mesh(CHIP, mat.flat);
	m.visible = false;
	groups.debris.add(m);
	chips.push({ m, life: 0, vx: 0, vy: 0, vz: 0, spin: 0 });
}
let chipAt = 0;
function throwChips(x, y, z, colour, n) {
	for (let i = 0; i < n; i++) {
		const c = chips[chipAt = (chipAt + 1) % chips.length];
		const a = Math.random() * 6.28, sp = 3 + Math.random() * 4;
		c.life = 0.75; c.vx = Math.cos(a) * sp; c.vz = Math.sin(a) * sp; c.vy = 3 + Math.random() * 5;
		c.spin = (Math.random() - 0.5) * 22;
		c.m.position.set(x, y, z); c.m.color = colour; c.m.visible = true;
	}
}

// ---------------------------------------------------------------------------
// Breaking a crate.
// ---------------------------------------------------------------------------
function breakCrate(c) {
	if (!c.alive) return;
	c.alive = false;
	const p = c.m.position;
	const [px, py, pz] = [p.x, p.y, p.z];
	throwChips(px, py, pz, c.kind === 'tnt' ? 0xb03a2c : 0xa4763e, c.kind === 'tnt' ? 10 : 6);
	for (let i = 0; i < c.fruit; i++) {
		const f = dropFruit(px + (Math.random() - 0.5) * 1.4, py + 0.4 + i * 0.5, pz + (Math.random() - 0.5) * 1.4);
		f.free = true;
	}
	three.physics.remove(c.m);
	scene.remove(c.m);
	crateOf.delete(c.m);
	state.broken++;

	// A TNT takes its neighbours and anything loose with it.
	if (c.tnt) {
		for (const o of crates) {
			if (!o.alive) continue;
			const q = o.m.position;
			if (Math.hypot(q.x - px, q.y - py, q.z - pz) < 3.4) breakCrate(o);
		}
		for (const b of BOULDERS) {
			const q = b.mesh.position;
			const d = Math.hypot(q.x - px, q.z - pz);
			if (d < 5) throwChips(q.x, q.y + b.r, q.z, 0x7d7a72, 3);
		}
		// Over the cast's live range, which is a plain indexed loop — an id is
		// what you keep across frames and an index is what you use inside one.
		for (let i = 0; i < pack.count; i++) {
			if ((pack.state[i] & 1) === 0) continue;
			const at = i * 3;
			const d = Math.hypot(P_POS[at] - px, P_POS[at + 2] - pz);
			if (d < 5.5) launch(i, (P_POS[at] - px) / (d || 1), (P_POS[at + 2] - pz) / (d || 1), 13);
		}
	}
}

// ---------------------------------------------------------------------------
// The pack.
//
// Every one of these is a critter that has to get round a boulder to reach
// you, which is what the nav bake is for. The shape is the documented one: ONE
// field re-solved at the player a few times a second, three.steer sampling it
// for the whole pack in one crossing, and moveAndSlide per agent so they
// collide with the walls, the crates and the ground they are actually on.
// ---------------------------------------------------------------------------
const PACK_N = 10;
const CRITTER_R = 0.38, CRITTER_H = 1.15;

// The cast is not collision geometry.
//
// **`collides = false` is the whole of what used to be a hide/show dance.**
// Every drawable mesh is swept against, so a character built out of eight boxes
// collided with its own chest, and the only way to exclude a whole subtree was
// to hide it — which cost the spatial index a rebuild per toggle, twenty-two of
// them a step. Now it is a per-mesh flag set once, at build time.
//
// Not inherited, so it is a traverse rather than one write on the Group: it
// says what one piece of geometry IS, and a Group is not geometry.
//
// The per-call alternative is `{ ignore: group }` on moveAndSlide, which leaves
// that subtree out of ONE sweep and holds up to eight of them. It is the right
// tool when the exclusion is about the call — a projectile ignoring whoever
// fired it. It is the wrong tool here twice over: there are eleven characters
// and nobody may block anybody, which is more pairs than an ignore set holds,
// and "you run through the enemies" is a property of the enemies rather than of
// any one sweep. Crash runs through the ones that hurt him.
//
// They still collide with the ground, the crates, the boulders and the palms,
// which is everything that should stop them.
function noCollide(root) {
	root.traverse(o => { if (o.geometry) o.collides = false; });
	return root;
}

function buildCritter() {
	const g = new three.Group();
	const body = new three.Mesh(BOX, mat.critter);
	body.scale.set(0.7, 0.62, 0.86); body.position.set(0, 0.5, 0);
	g.add(body);
	const head = new three.Mesh(BOX, mat.critter);
	head.scale.set(0.5, 0.44, 0.44); head.position.set(0, 0.92, 0.3);
	g.add(head);
	const legs = [];
	for (const sx of [-1, 1]) {
		const leg = new three.Group(); leg.position.set(sx * 0.24, 0.24, 0); g.add(leg);
		const lm = new three.Mesh(BOX, mat.flat);
		lm.scale.set(0.18, 0.3, 0.24); lm.position.set(0, -0.12, 0); lm.color = 0x5b4a2e;
		leg.add(lm); legs.push(leg);
	}
	for (const sx of [-1, 1]) {
		const eye = new three.Mesh(BOX, mat.flat);
		eye.scale.set(0.11, 0.12, 0.05); eye.position.set(sx * 0.13, 0.98, 0.53); eye.color = 0xf2ead6;
		g.add(eye);
	}
	return { g: noCollide(g), legs };
}

// The pack is a CAST — plan.md §21.
//
// Ten critters as COLUMNS rather than as ten objects with fields, and the
// reason is not cache locality: `notes.md` §17 measured every JavaScript-side
// layout inside the noise floor of the measurement itself. The reason is that
// **a column is the buffer a bulk verb takes.** `position` below is handed
// straight to `three.steer`, to `field.sample` and to `three.moveAndSlideAll`
// with nothing marshalled in between, and the three of them are three crossings
// for the whole pack instead of thirty.
//
// One Cast is one KIND of thing. A second sort of enemy is a second Cast and
// its own systems, and nothing in this file changes to make room for it.
const pack = three.cast({ capacity: PACK_N, name: 'pack' });

const P_POS = pack.vec3('position');      // the capsule CENTRE, moved in place
const P_FOOT = pack.vec3('foot');         // where the nav field is sampled
const P_VEL = pack.vec3('velocity');      // what three.steer wants them to do
const P_MOTION = pack.vec3('motion');     // what this step actually asks for
const P_ARC = pack.vec3('arc');           // the free flight of a launched one
const P_MOVE = pack.buffer('move', three.moveResult.stride);
const P_COST = pack.float('cost');        // ground distance to the player
const P_HEADING = pack.float('heading');
const P_WALK = pack.float('walk');        // the leg-swing phase
const P_VY = pack.float('vy');
const P_STUN = pack.float('stun');
const P_LIFE = pack.float('life');        // how long a launch lasts
const P_TUMBLE = pack.float('tumble');
const P_BUILD = pack.float('build');      // which critter was built, for the legs
const P_HOME_S = pack.float('homeS');
const P_HOME_OFF = pack.float('homeOff');

const CHASING = pack.tag('chasing');
const MOVING = pack.tag('moving');
const LAUNCHED = pack.tag('launched');

// The legs are an ordinary `three.batch`, not part of the cast, and the two
// compose exactly as they should: a cast slot MOVES when something above it
// dies, and a batch's membership does not. So the batch is indexed by the
// critter's build number — which is what `P_BUILD` is — and a dead critter's
// legs are left in it, where the host skips them because its Group has left the
// scene. One crossing for twenty leg pivots.
const legObjects = [];
const critterOf = new Map();

for (let i = 0; i < PACK_N; i++) {
	const s = 26 + (i / PACK_N) * (PATH_LEN - 50);
	const off = (hash2(i, 3, 77) - 0.5) * 5.2;
	const at = onPath(s, off);
	const built = buildCritter();
	built.g.name = `critter${i}`;
	groups.pack.add(built.g);
	legObjects.push(built.legs[0], built.legs[1]);

	const id = pack.spawn();
	const slot = pack.indexOf(id);
	pack.attach(id, built.g);
	critterOf.set(built.g, id);

	P_POS[slot * 3] = at.x;
	P_POS[slot * 3 + 1] = groundY(at.x, at.z) + CRITTER_H / 2;
	P_POS[slot * 3 + 2] = at.z;
	P_HEADING[slot] = at.yaw;
	P_WALK[slot] = hash2(i, 9, 5) * 6;
	P_BUILD[slot] = i;
	P_HOME_S[slot] = s;
	P_HOME_OFF[slot] = off;
}
const legs = three.batch(legObjects, { euler: true });

// Retire one. `despawn` hands the Group back rather than removing it, because a
// Cast is not a lifetime manager — and putting the removal at the call site is
// what makes it obvious that the mesh outlives the entity by exactly as long as
// this line takes.
function retire(slot) {
	const id = pack.idOf(slot);
	if (id < 0) return;
	groups.pack.remove(pack.despawn(id));
}

function launch(slot, dx, dz, power) {
	P_ARC[slot * 3] = dx * power;
	P_ARC[slot * 3 + 1] = 7.5;
	P_ARC[slot * 3 + 2] = dz * power;
	P_LIFE[slot] = 1.5;
	P_STUN[slot] = 1.5;
	pack.state[slot] |= LAUNCHED;
}

// The bake. AFTER the level is built — nothing bakes for you, and the whole
// point of the number below is that you find out what it cost.
//
// `bounds` is the one option that is not about the agent, and it is what keeps
// this a level-boundary operation: the hollow's walls reach 21 units above a
// floor that is never below zero, but nothing walks above the corridor, so
// there is no reason to voxelize the sky over the cliffs.
const pathBox = PATH.reduce((b, p) => ({
	x0: Math.min(b.x0, p[0]), x1: Math.max(b.x1, p[0]),
	z0: Math.min(b.z0, p[1]), z1: Math.max(b.z1, p[1]),
}), { x0: 1e9, x1: -1e9, z0: 1e9, z1: -1e9 });
const NAV_PAD = HALF + 5;
const navBounds = {
	min: [pathBox.x0 - NAV_PAD, -2, pathBox.z0 - NAV_PAD],
	max: [pathBox.x1 + NAV_PAD, 16, pathBox.z1 + NAV_PAD],
};
// `radius` is the critter's own, which is worth saying because it could not be
// until the erosion was fixed. The bake used to reserve the agent's width by
// dilating the whole SOLID set horizontally; on a trail that descends — 5.7
// degrees here, nothing a 48 degree slope limit would refuse — the uphill
// column's floor cell landed in the downhill column at the uphill height, which
// is exactly the cell the downhill agent had to stand in, and the graph came
// apart into islands one dilation wide. A field solved at the player reached
// four units and stopped, and the pack stood around looking like the steering
// was broken. It now dilates the WALLS instead, so ground you stand on is not
// something to keep clear of.
//
// **Read `components`.** It is the counter that would have caught that in one
// line: everything else about a fragmented bake looks healthy — a big
// `walkable`, a live field, a plausible `bakeMs` — and the only other way to
// find out is to ask a second point whether it is reachable.
//
// More than one region is not automatically wrong, and this level is why: the
// top of a crate and the top of a boulder are standing room nothing can walk
// UP to, so they are honestly their own regions. The number to watch is
// `largest` against `walkable` — 5190 of 5597 here, and the 407 left over are
// the crate lids. A broken bake does not look like that; it looks like the
// largest region being a fraction of the whole.
const bake = three.nav.bake({
	cell: 0.75,
	radius: CRITTER_R,
	height: CRITTER_H,
	slope: 48,
	bounds: navBounds,
});
if (bake && bake.largest < bake.walkable * 0.75) {
	console.log(`nav: the biggest walkable region is ${bake.largest} of ${bake.walkable} cells across`
		+ ` ${bake.components} regions — the trail has come apart, and the pack will hold station`
		+ ' wherever they are. Look at the geometry before touching cell or radius.');
}

let flow = null;          // the kept solve, re-aimed at the player
let flowAge = 0;
const FLOW_EVERY = 0.35;  // seconds

function resolveFlow() {
	const next = three.nav.field([ctl.x, ctl.y + 0.2, ctl.z]);
	if (next) {
		if (flow) flow.dispose();
		flow = next;
	}
	// A null answer means the player is off the mesh — mid-jump over a gap, on
	// a shelf the bake found too small. Keep the last good field rather than
	// dropping the pack, which is what makes them wait at the bottom of a ledge
	// instead of forgetting you exist.
	flowAge = 0;
}

// ---------------------------------------------------------------------------
// The spin, as its own verb.
//
// three.query.sphere with a buffer kept OUTSIDE the loop: the answer is a
// broad-phase list of nodes, and what each one is comes from the two Maps
// above rather than from a name. Crates in reach break; critters in reach fly.
// ---------------------------------------------------------------------------
const hits = three.query.buffer(64);

function spin() {
	ctl.spin = SPIN_TIME;
	ctl.spinCool = SPIN_TIME + 0.14;
	const centre = [ctl.x, ctl.y + HEIGHT / 2, ctl.z];
	const n = three.query.sphere(centre, SPIN_R, hits);
	for (const o of hits.objects()) {
		const c = crateOf.get(o);
		if (c && c.alive) {
			// Broad phase answers with boxes, so check the real distance before
			// breaking something whose corner merely reached.
			const p = c.m.position;
			if (Math.abs(p.y - centre[1]) < 1.9 && Math.hypot(p.x - ctl.x, p.z - ctl.z) < SPIN_R) breakCrate(c);
			continue;
		}
		// `critterOf` holds an ID rather than an index, because a query answers
		// with objects and this list outlives the frame it was built in — an
		// index is only good for the frame it was read in, and `indexOf` is the
		// one line that turns the durable name back into this frame's slot.
		const i = pack.indexOf(critterOf.get(o) ?? -1);
		if (i >= 0 && (pack.state[i] & LAUNCHED) === 0) {
			const at = i * 3;
			const d = Math.hypot(P_POS[at] - ctl.x, P_POS[at + 2] - ctl.z);
			if (d < SPIN_R + 0.4) launch(i, (P_POS[at] - ctl.x) / (d || 1), (P_POS[at + 2] - ctl.z) / (d || 1), 15);
		}
	}
	// Anything with a body just outside the break radius gets thrown instead.
	for (const c of crates) {
		if (!c.alive) continue;
		const p = c.m.position;
		const d = Math.hypot(p.x - ctl.x, p.z - ctl.z);
		if (d > SPIN_R + 2.4 || d < 1e-4) continue;
		three.physics.applyImpulse(c.m, [((p.x - ctl.x) / d) * 20, 8, ((p.z - ctl.z) / d) * 20]);
	}
	return n;
}

// ---------------------------------------------------------------------------
// Picking up fruit. The trigger fires from inside the frame.
// ---------------------------------------------------------------------------
three.onTrigger(e => {
	if (e.type !== 'enter' || !e.trigger) return;
	const f = fruitOf.get(e.trigger);
	if (!f || !f.alive || e.other !== capsule) return;
	f.alive = false;
	three.physics.remove(f.vol);
	scene.remove(f.vol);
	scene.remove(f.m);
	fruitOf.delete(f.vol);
	state.fruit++;
	if (state.fruit % 25 === 0) {
		state.lives++;
		console.log(`25 wumpa — an extra life. ${state.lives} left.`);
	}
});

// ---------------------------------------------------------------------------
// The controller.
//
// The whole of the collision half is one call. There is no corridor fence, no
// ground snap and no per-boulder circle test, because the wall, the floor and
// the boulder are all just triangles it sweeps against.
// ---------------------------------------------------------------------------
// Nobody in the cast is collision geometry — see `noCollide`, which is set once
// at build time and is the whole of what this used to need.
//
// The fixed phase decides and the frame phase draws, which is now a property of
// the system list rather than of where the code happens to sit. That ordering
// is not load-bearing for correctness — a moved node has its entry RE-FILED
// rather than the index rebuilt, so writing between two sweeps is cheap — and
// it is kept because it is the clearer shape and because it is free.

const held = k => three.input.isDown(k);
const axis = (a, b) => ((a.some(held) ? 1 : 0) - (b.some(held) ? 1 : 0));
const KEYS = {
	forward: ['w', 'arrowup'], back: ['s', 'arrowdown'],
	left: ['a', 'arrowleft'], right: ['d', 'arrowright'],
	jump: ['space'], spin: ['j', 'k', 'shift'],
	yawL: ['q'], yawR: ['e'], pitchU: ['r'], pitchD: ['f'],
};
// Edges mean something once per FRAME; the fixed loop runs zero to eight times
// per frame. Latch in the animation callback, consume in the step.
const intent = { jump: false, spin: false };

const MOVE = { radius: RADIUS, height: HEIGHT, step: 0.45, slope: 52, skin: 0.02, snap: 0.4 };
const CRITTER_MOVE = { radius: CRITTER_R, height: CRITTER_H, step: 0.4, slope: 48, snap: 0.35 };

function playerStep(dt) {
	// --- run, in the camera's frame ---
	const move = three.camera.planarMove(axis(KEYS.forward, KEYS.back), axis(KEYS.right, KEYS.left));
	ctl.moving = move.length() > 0;
	if (ctl.moving) ctl.heading = Math.atan2(move.x, move.z);

	// --- spin ---
	if (ctl.spinCool > 0) ctl.spinCool -= dt;
	if (intent.spin && ctl.spin <= 0 && ctl.spinCool <= 0) spin();
	intent.spin = false;
	if (ctl.spin > 0) { ctl.spin -= dt; ctl.spinAngle += dt * 34; }
	else ctl.spinAngle *= 0.72;

	// --- vertical ---
	if (ctl.grounded) ctl.coyote = 0.12; else ctl.coyote -= dt;
	if (intent.jump && ctl.coyote > 0) { ctl.vy = JUMP; ctl.coyote = 0; ctl.grounded = false; }
	intent.jump = false;
	ctl.vy = Math.max(ctl.vy - GRAV * dt, -42);

	// --- one call: the wall, the floor, the ledge and the boulder ---
	const speed = ctl.hurt > 0 ? SPEED * 0.45 : SPEED;
	const motion = [move.x * speed * dt, ctl.vy * dt, move.z * speed * dt];
	const r = three.moveAndSlide([ctl.x, ctl.y + HEIGHT / 2, ctl.z], motion, MOVE);

	ctl.x = r.position.x;
	ctl.y = r.position.y - HEIGHT / 2;
	ctl.z = r.position.z;

	// Landing on a crate breaks it and bounces — Crash's other verb, and the
	// reason the vertical half is spelled out rather than handed to a helper.
	if (ctl.vy < 0 && r.grounded) {
		const c = crateOf.get(r.ground);
		if (c && c.alive) {
			breakCrate(c);
			ctl.vy = c.bounce ? JUMP * 1.15 : JUMP * 0.72;
			ctl.grounded = false;
		} else {
			ctl.vy = 0; ctl.grounded = true;
		}
	} else if (r.grounded) {
		if (ctl.vy < 0) ctl.vy = 0;
		ctl.grounded = true;
	} else {
		ctl.grounded = false;
		// Hitting a ceiling: stop climbing rather than hanging under it.
		if (ctl.vy > 0 && r.remaining.y > 1e-4) ctl.vy = 0;
	}

	// Fell off the world.
	if (ctl.y < -6) hurt(true);

	// --- how far down the hollow ---
	const near = nearestOnPath(ctl.x, ctl.z);
	ctl.s = near.s;
	if (near.s > state.best) state.best = near.s;
	if (!state.done && near.s > PATH_LEN - 8) {
		state.done = true;
		console.log(`Made it. ${state.fruit} wumpa, ${state.broken} crates, ${state.lives} lives.`);
	}

	if (ctl.hurt > 0) ctl.hurt -= dt;
}

function hurt(fell) {
	if (ctl.hurt > 0) return;
	ctl.hurt = 1.4;
	state.lives--;
	const back = onPath(Math.max(2, state.best - 12), 0);
	if (fell || state.lives <= 0) {
		ctl.x = back.x; ctl.z = back.z; ctl.y = groundY(back.x, back.z) + 0.4; ctl.vy = 0;
	}
	if (state.lives <= 0) {
		state.lives = 4;
		state.fruit = Math.max(0, state.fruit - 10);
		console.log('Out of lives — back down the trail.');
	} else {
		console.log(`Ouch. ${state.lives} lives left.`);
	}
}

// ---------------------------------------------------------------------------
// The pack's step.
// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
// The pack's systems.
//
// What used to be one hundred and one lines of `packStep` is six named things
// that run in a declared order, and `three.systems.report()` says what each one
// costs. Three of the six are one crossing apiece for the whole pack.
// ---------------------------------------------------------------------------

// The kept solve, re-aimed at the player a few times a second.
pack.system('flow', (dt) => {
	flowAge += dt;
	if (flow === null || flowAge >= FLOW_EVERY) resolveFlow();
}, { phase: 'fixed', order: 1 });

// How far everyone is from the player, ALONG THE GROUND — one crossing, and
// `field.cost` in a loop is what it replaces. A NEGATIVE cost is unreachable
// here where `cost()` answers Infinity, which is the one place the convenient
// form and the flat form disagree about a value.
pack.system('sense', () => {
	const n = pack.count;
	for (let i = 0; i < n; i++) {
		P_FOOT[i * 3] = P_POS[i * 3];
		P_FOOT[i * 3 + 1] = P_POS[i * 3 + 1] - CRITTER_H / 2 + 0.2;
		P_FOOT[i * 3 + 2] = P_POS[i * 3 + 2];
	}
	if (flow) {
		flow.sample(pack.live(P_FOOT), { costs: pack.live(P_COST) });
	} else {
		pack.live(P_COST).fill(-1);
	}
	// Out of earshot: hold station near home rather than sprinting the whole
	// level at you, which is what makes a hollow feel populated.
	for (let i = 0; i < n; i++) {
		const heard = P_COST[i] >= 0 && P_COST[i] < 26 && P_STUN[i] <= 0;
		if (heard) pack.state[i] |= CHASING; else pack.state[i] &= ~CHASING;
	}
}, { phase: 'fixed', order: 2 });

// Seek, arrive and separation for the whole pack in one crossing. What comes
// back is a DESIRED velocity — going there is still moveAndSlide's decision.
pack.system('steer', () => {
	if (flow) {
		three.steer(pack.live(P_POS), pack.live(P_VEL), {
			field: flow, maxSpeed: 4.6, arrive: 1.6, separation: 1.5, separationWeight: 1.5,
		});
	} else {
		pack.live(P_VEL).fill(0);
	}
}, { phase: 'fixed', order: 3 });

// The whole pack's collision, in one call.
//
// A launched critter is given zero motion here and has its position overwritten
// by `arc` below, so its sweep is wasted work — a handful of agents for a
// second and a half apiece, against branching the one call that is the reason
// any of this is fast.
pack.system('walk', (dt) => {
	const n = pack.count;
	for (let i = 0; i < n; i++) {
		const at = i * 3;
		if ((pack.state[i] & LAUNCHED) !== 0) {
			P_MOTION[at] = 0; P_MOTION[at + 1] = 0; P_MOTION[at + 2] = 0;
			continue;
		}
		if (P_STUN[i] > 0) P_STUN[i] -= dt;

		let vx = P_VEL[at], vz = P_VEL[at + 2];
		if ((pack.state[i] & CHASING) === 0) {
			const h = onPath(P_HOME_S[i] + Math.sin(three.clock.time * 0.5 + i) * 5, P_HOME_OFF[i]);
			const dx = h.x - P_POS[at], dz = h.z - P_POS[at + 2], d = Math.hypot(dx, dz);
			vx = d > 0.4 ? (dx / d) * 1.7 : 0;
			vz = d > 0.4 ? (dz / d) * 1.7 : 0;
		} else if (P_STUN[i] > 0) {
			vx *= 0.2; vz *= 0.2;
		}

		P_VY[i] = Math.max(P_VY[i] - GRAV * dt, -40);
		P_MOTION[at] = vx * dt;
		P_MOTION[at + 1] = P_VY[i] * dt;
		P_MOTION[at + 2] = vz * dt;

		const moving = Math.hypot(vx, vz) > 0.25;
		if (moving) P_HEADING[i] = Math.atan2(vx, vz);
		if (moving) pack.state[i] |= MOVING; else pack.state[i] &= ~MOVING;
		P_WALK[i] += dt * ((pack.state[i] & CHASING) ? 15 : 9) * (moving ? 1 : 0);
	}

	three.moveAndSlideAll(pack.live(P_POS), pack.live(P_MOTION), {
		...CRITTER_MOVE,
		results: pack.live(P_MOVE),
		self: pack.live(pack.handles),
	});

	for (let i = 0; i < n; i++) {
		if ((pack.state[i] & LAUNCHED) !== 0) continue;
		const grounded = (P_MOVE[i * 8 + three.moveResult.flags] | 0) & three.moveResult.GROUNDED;
		if (grounded && P_VY[i] < 0) P_VY[i] = 0;
		if (P_POS[i * 3 + 1] < -6) retire(i);
	}
}, { phase: 'fixed', order: 4 });

// The ones a spin or a TNT sent flying: a free arc, no steering, and the only
// thing they collide with is the ground they land on.
pack.system('arc', (dt) => {
	for (let i = 0; i < pack.count; i++) {
		if ((pack.state[i] & LAUNCHED) === 0) continue;
		const at = i * 3;
		P_LIFE[i] -= dt;
		P_ARC[at + 1] -= GRAV * 0.7 * dt;
		P_POS[at] += P_ARC[at] * dt;
		P_POS[at + 1] += P_ARC[at + 1] * dt;
		P_POS[at + 2] += P_ARC[at + 2] * dt;
		P_TUMBLE[i] += dt * 16;

		const foot = P_POS[at + 1] - CRITTER_H / 2;
		const ground = groundY(P_POS[at], P_POS[at + 2]);
		if (foot > ground && P_LIFE[i] > 0) continue;

		P_POS[at + 1] = Math.max(P_POS[at + 1], ground + CRITTER_H / 2);
		pack.state[i] &= ~LAUNCHED;
		P_VY[i] = 0;
		if (Math.abs(P_POS[at]) > W / 2 - 4 || Math.abs(P_POS[at + 2]) > D / 2 - 4 || foot < -4) retire(i);
	}
}, { phase: 'fixed', order: 5 });

// Reaching the player costs a life — unless you are spinning, in which case it
// is the critter that loses.
pack.system('touch', () => {
	for (let i = 0; i < pack.count; i++) {
		if ((pack.state[i] & 1) === 0 || (pack.state[i] & LAUNCHED) !== 0) continue;
		const at = i * 3;
		const d = Math.hypot(ctl.x - P_POS[at], ctl.z - P_POS[at + 2]);
		if (d >= 0.95 || ctl.hurt > 0) continue;
		const nx = (P_POS[at] - ctl.x) / (d || 1), nz = (P_POS[at + 2] - ctl.z) / (d || 1);
		if (ctl.spin > 0) { launch(i, nx, nz, 15); } else { hurt(false); launch(i, nx, nz, 7); }
	}
}, { phase: 'fixed', order: 6 });

// Drawing them: two crossings for the whole pack, whatever its size. `pose`
// carries the capsule-centre-to-feet offset, because the capsule's centre and
// the model's origin are never the same point.
pack.system('draw', () => {
	pack.pose(P_POS, { lift: -CRITTER_H / 2, heading: P_HEADING });
	for (let i = 0; i < pack.count; i++) {
		if ((pack.state[i] & LAUNCHED) !== 0) {
			pack.transform[i * 9 + 4] = P_TUMBLE[i];
		}
		const build = P_BUILD[i] | 0;
		const swing = (pack.state[i] & LAUNCHED) ? 0 : ((pack.state[i] & MOVING) ? Math.sin(P_WALK[i]) * 0.5 : 0);
		legs.positions[legs.rotationAt(build * 2)] = swing;
		legs.positions[legs.rotationAt(build * 2 + 1)] = -swing;
	}
	pack.flush();
	legs.flush();
}, { order: 40 });

// ---------------------------------------------------------------------------
// The sky and the haze, in one post pass. p.depth is in WORLD UNITS and a pixel
// nothing was drawn into reads as the far plane — which is what makes a sky
// gradient and a distance fog the same shader.
// ---------------------------------------------------------------------------
const sky = three.setPost({
	uniforms: { viewFar: 400, skyLow: [0.72, 0.86, 0.92], skyHigh: [0.26, 0.52, 0.80], haze: [0.66, 0.78, 0.80], fogRange: [30, 120] },
	fragment: `
		float3 post(Post p) {
			float isSky = smoothstep(viewFar * 0.975, viewFar * 0.999, p.depth);
			float up = pow(clamp(1.0 - p.uv.y, 0.0, 1.0), 0.9);
			float3 gradient = lerp(skyLow, skyHigh, up);

			float f = clamp((p.depth - fogRange.x) / max(1.0, fogRange.y - fogRange.x), 0.0, 1.0);
			float3 lit = lerp(p.color, haze, f * f * 0.7);
			return lerp(lit, gradient, isSky);
		}`,
});

// ---------------------------------------------------------------------------
// The frame, as a list of named things — plan.md §21.
//
// This used to be one ninety-line `setAnimationLoop` doing the camera look, the
// key latching, the transform write-back for every character, the player's
// pose, the fruit's bob and the debris, none of which knew about each other.
// Adding a sixth thing meant editing that function.
//
// `three.systems.report()` says what each of these costs, most expensive first,
// which is the CPU half of what `three.stats()` has always given the GPU half.
// `three.systems.list()` is the running order; the pack's own six are declared
// beside the pack.
//
// Gameplay is in the FIXED phase, at a dt that is the same every call. Drawing
// the consequence is in the frame phase, which is also the only place a key
// EDGE means anything.
// ---------------------------------------------------------------------------
three.camera.attach(P.g, { offset: [0, 1.5, 0], distance: ctl.dist, lag: 95 });
three.controls.enabled = false;
three.camera.orbit(ctl.yaw, ctl.pitch, ctl.dist);

sky.uniforms.viewFar = three.camera.far;

three.systems.add('player', dt => {
	if (three.clock.paused) return;
	playerStep(dt);
}, { phase: 'fixed', order: 0 });

three.systems.add('look', dt => {
	const ptr = three.input.pointer;
	if (ptr.down) { ctl.yaw -= ptr.dx * 0.24; ctl.pitch += ptr.dy * 0.2; }
	ctl.yaw += axis(KEYS.yawL, KEYS.yawR) * 120 * dt;
	ctl.pitch += axis(KEYS.pitchU, KEYS.pitchD) * 60 * dt;
	ctl.pitch = clamp(ctl.pitch, -4, 70);
	ctl.dist = clamp(ctl.dist + ptr.scroll, 6, 22);
	three.camera.orbit(ctl.yaw, ctl.pitch, ctl.dist);
}, { order: 10 });

// Edges mean something once per FRAME; the fixed loop runs zero to eight times
// per frame. Latched here, consumed there — which is why this is a system of
// its own rather than three lines at the top of another one.
three.systems.add('latch', () => {
	if (KEYS.jump.some(k => three.input.pressed(k))) intent.jump = true;
	if (KEYS.spin.some(k => three.input.pressed(k))) intent.spin = true;
}, { order: 20 });

// The player is one character, so it is the SINGLE-agent verbs all the way
// through — including the ordinary property writes here. A cast of one would be
// a column of one and a crossing saved that was never spent.
three.systems.add('player.pose', dt => {
	P.g.position.set(ctl.x, ctl.y, ctl.z);
	capsule.position.set(ctl.x, ctl.y + HEIGHT / 2, ctl.z);
	P.g.rotation.y = ctl.heading;
	P.spinner.rotation.y = ctl.spinAngle;
	if (ctl.moving && ctl.grounded) ctl.walkT += dt * 13;
	const swing = ctl.moving && ctl.grounded ? Math.sin(ctl.walkT) * 0.62 : 0;
	P.legs[0].rotation.x = swing; P.legs[1].rotation.x = -swing;
	const out = ctl.spin > 0 ? 1 : 0;
	P.arms[0].rotation.x = -swing * 0.7 * (1 - out);
	P.arms[1].rotation.x = swing * 0.7 * (1 - out);
	P.arms[0].rotation.z = out * 1.5;
	P.arms[1].rotation.z = -out * 1.5;
	if (!ctl.grounded) { P.legs[0].rotation.x = 0.5; P.legs[1].rotation.x = -0.3; }
}, { order: 30 });

// The fruit is deliberately NOT a cast, and it is worth saying why: each one is
// a drawn mesh plus a trigger volume the solver owns, and what the pickup is
// keyed by is the volume's OBJECT IDENTITY, arriving through three.onTrigger.
// A cast buys nothing where the loop is over two dozen things that are already
// addressed by object, and it would cost a second index to get back to them.
three.systems.add('fruit', dt => {
	for (const f of fruit) {
		if (!f.alive) continue;
		f.spin += dt * 3;
		f.m.rotation.y = f.spin;
		if (f.free) {
			// One that fell out of a crate settles onto the ground it landed on.
			const g = groundY(f.m.position.x, f.m.position.z) + 0.62;
			if (f.m.position.y > g) f.m.position.y = Math.max(g, f.m.position.y - 9 * dt);
			else f.free = false;
		} else {
			f.bob += dt * 2.4;
			f.m.position.y += Math.sin(f.bob) * 0.4 * dt;
		}
		f.vol.position.set(f.m.position.x, f.m.position.y, f.m.position.z);
	}
}, { order: 50 });

three.systems.add('chips', dt => {
	for (const c of chips) {
		if (c.life <= 0) continue;
		c.life -= dt;
		if (c.life <= 0) { c.m.visible = false; continue; }
		c.vy -= 24 * dt;
		c.m.position.set(
			c.m.position.x + c.vx * dt,
			c.m.position.y + c.vy * dt,
			c.m.position.z + c.vz * dt);
		c.m.rotation.x += c.spin * dt;
		c.m.rotation.z += c.spin * 0.7 * dt;
	}
}, { order: 60 });

three.systems.add('sky', () => { sky.uniforms.viewFar = three.camera.far; }, { order: 70 });

// ---------------------------------------------------------------------------
// What the level cost to build, which is the honest way to report a bake.
// ---------------------------------------------------------------------------
const nav = three.nav.stats();
console.log(`hollow: ${PATH_LEN.toFixed(0)} units of trail, ${crates.length} crates, `
	+ `${fruit.length} wumpa, ${pack.alive} critters`);
if (nav) {
	console.log(`nav: cell ${nav.cell}, ${nav.voxels} voxels, ${nav.walkable} walkable, `
		+ `${nav.components} regions (largest ${nav.largest}), baked in ${nav.bakeMs.toFixed(1)} ms`);
} else {
	console.log('nav: the bake found no standing room — the pack will hold station');
}

return {
	trail: Math.round(PATH_LEN),
	crates: crates.length,
	wumpa: fruit.length,
	critters: pack.alive,
	nav: bake && {
		cell: bake.cell, voxels: bake.voxels, walkable: bake.walkable,
		components: bake.components, largest: bake.largest, bakeMs: +bake.bakeMs.toFixed(1),
	},
	stats: three.stats(),
};
