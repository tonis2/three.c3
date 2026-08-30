// wumpa_run.js — a Crash-shaped run down a jungle hollow.
//
// A whole small game in one file: a terrain that is also the collision mesh, a
// player who runs and spins, crates that break, fruit to collect, and a pack of
// critters that finds its way to you over baked navigation.
//
// Nothing is loaded from disk. Every texture is generated here, so the file runs
// on a clean checkout.
//
//   ./build/three --script examples/wumpa_run.js
//
//   # one frame, no window
//   ./build/three --headless --script examples/wumpa_run.js --screenshot out.png
//
//   # play it without a window — the fixed loop steps, keys latch, nav runs
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
// ## The shape of the file
//
//   arithmetic     helpers, then the trail's own curve
//   the level      one three.Field carved into a corridor, then a
//                  LayeredMaterial over it and one heightfield body
//   the things     Crate, Wumpa, Player and Critter, each a three.Entity
//   the rules      two of them: fruit is collected, a critter that reaches you
//                  costs a life
//   the frame      every system, in declared order
//
// An entity class owns its own spawn, lookup, body, collision volume and
// removal, so there is no array-plus-map-plus-alive-flag anywhere below, and
// `c.remove()` is the whole removal. The pack is the only one with `columns`:
// its position, motion and so on are one shared array per field, which is what
// three.steer, field.sample and three.moveAndSlideAll are handed directly.
// Everything else is an ordinary property on an ordinary object.

three.budget = 60000;   // a cold build: the terrain fill is 2.6M distance tests

// ---------------------------------------------------------------------------
// Arithmetic. All of it three's — these are just shorter local names.
//
// Watch the argument order: `three.smoothstep` is Three.js's `(x, min, max)`,
// the VALUE FIRST, not GLSL's `(edge0, edge1, x)`.
// ---------------------------------------------------------------------------
const { lerp, clamp, clamp01, smoothstep, band, hash } = three;
const mixc = three.mixColor;
const tint = three.tintColor;
const hash2 = hash;
const smooth = t => smoothstep(t, 0, 1);

// A tileable fbm image. `period` is what makes the left edge meet the right,
// and fbm2 scales it per octave — the part a hand-written tiling fbm gets wrong.
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

const TRAIL = [0];
for (let i = 1; i < PATH.length; i++) {
	TRAIL.push(TRAIL[i - 1] + Math.hypot(PATH[i][0] - PATH[i - 1][0], PATH[i][1] - PATH[i - 1][1]));
}
const PATH_LEN = TRAIL[TRAIL.length - 1];

// The corridor floor climbs and dips. This is the one number the whole terrain
// is hung off, and it is why the level is not flat: a heightfield that only
// makes walls is a wall generator, not ground.
function pathY(s) {
	return 3.4 + Math.sin(s * 0.031) * 2.6 + Math.sin(s * 0.0165 + 1.1) * 1.7 + s * 0.006;
}

function along(s) {
	const t = clamp(s, 0, PATH_LEN);
	let i = 1;
	while (i < TRAIL.length - 1 && TRAIL[i] < t) i++;
	const a = PATH[i - 1], b = PATH[i];
	const seg = Math.max(1e-6, TRAIL[i] - TRAIL[i - 1]);
	const k = (t - TRAIL[i - 1]) / seg;
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
		if (d < bd) { bd = d; bx = px; bz = pz; bs = lerp(TRAIL[i - 1], TRAIL[i], t); }
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

// Shelves to jump up onto, levelled into the field before the terrain is built
// — a pad has to be flat before it is ground.
//
// Keep them OFF the centreline: a pad across the trail is a wall, not a
// platform, since nothing that tall reports as ground to jump from. The first
// two are a staircase — 1.4 is one jump from the floor, 3.0 is one jump from
// the step below it.
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

const ground = new three.Mesh(terrain, 
	new three.LayeredMaterial({
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

// A body part: the unit box above under a scale. `look` is a colour, which the
// flat material carries per mesh, or a material of its own.
function box(size, pos, look) {
	const m = new three.Mesh(BOX, typeof look === 'number' ? mat.flat : look);
	m.scale.set(size[0], size[1], size[2]);
	m.position.set(pos[0], pos[1], pos[2]);
	if (typeof look === 'number') m.color = look;
	return m;
}
function cone(radius, height, pos, color) {
	const m = new three.Mesh(CONE, mat.flat);
	m.scale.set(radius * 2, height, radius * 2);
	m.position.set(pos[0], pos[1], pos[2]);
	m.color = color;
	return m;
}

// A limb hangs from a Group at the JOINT with its mesh below that, which is what
// makes `arm[0].rotation.x` swing from the shoulder rather than roll about the
// arm's own middle. Answers with the pair, left first.
function limbs(parent, joint, size, pos, look) {
	return [-1, 1].map(side => {
		const pivot = new three.Group();
		pivot.position.set(side * joint[0], joint[1], joint[2]);
		pivot.add(box(size, pos, look));
		parent.add(pivot);
		return pivot;
	});
}

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
// Crates — dynamic boxes.
//
// Drawable, so moveAndSlide walks INTO them and stops: Crash breaks crates, he
// does not push them. They are also rigid bodies, so the player's capsule
// shoves them and a spin sends them tumbling.
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

// The class owns the object -> instance map, the spawn and the removal, so the
// only thing written here is what a crate IS.
class Crate extends three.Entity {
	static body = { shape: 'box', mass: 5, friction: 0.7, restitution: 0.05 };

	constructor(at, k, yaw) {
		super();
		Object.assign(this, CRATE_KIND[k]);
		this.variant = k;
		this.object = new three.Mesh(BOX, CRATE_KIND[k].mat);
		this.object.scale.set(CRATE, CRATE, CRATE);
		this.object.position.set(at[0], at[1], at[2]);
		this.object.rotation.y = yaw;
	}

	// Answers with how many broke — a TNT takes its neighbours, so the count is
	// the caller's to add to their own score.
	//
	// `remove()` takes the body, the node and the map entry away NOW: a crate
	// broken inside a spin has to stop colliding on this tick. Only the live
	// list waits for the frame boundary, which is what makes the loops below
	// safe to remove from. It answers false for one already gone, which is the
	// recursion guard a TNT chain needs.
	break() {
		const p = this.object.position;
		const [px, py, pz] = [p.x, p.y, p.z];
		if (!this.remove()) return 0;
		throwChips(px, py, pz, this.variant === 'tnt' ? 0xb03a2c : 0xa4763e, this.variant === 'tnt' ? 10 : 6);
		for (let i = 0; i < this.fruit; i++) {
			const f = Wumpa.spawn(px + (Math.random() - 0.5) * 1.4, py + 0.4 + i * 0.5, pz + (Math.random() - 0.5) * 1.4);
			f.free = true;
		}
		let broke = 1;

		// A TNT takes its neighbours and anything loose with it.
		if (this.tnt) {
			for (const o of Crate) {
				const q = o.object.position;
				if (Math.hypot(q.x - px, q.y - py, q.z - pz) < 3.4) broke += o.break();
			}
			for (const b of BOULDERS) {
				const q = b.mesh.position;
				const d = Math.hypot(q.x - px, q.z - pz);
				if (d < 5) throwChips(q.x, q.y + b.r, q.z, 0x7d7a72, 3);
			}
			// The live ones, as instances. Removal is deferred to the frame
			// boundary, so this loop is safe even though a launch can end in a
			// retirement.
			for (const c of Critter) {
				const q = c.position;
				const d = Math.hypot(q[0] - px, q[2] - pz);
				if (d < 5.5) c.launch((q[0] - px) / (d || 1), (q[2] - pz) / (d || 1), 13);
			}
		}
		return broke;
	}
}

for (const c of CRATE_PLAN) {
	const at = onPath(c.s, c.off);
	const base = c.on !== undefined ? SHELVES[c.on].y : groundY(at.x, at.z);
	Crate.spawn([at.x, base + CRATE / 2 + (c.stack || 0) * CRATE, at.z], c.k, at.yaw);
}

// ---------------------------------------------------------------------------
// Wumpa fruit.
//
// **`collides = false` is what stops a pickup being a bollard.** Drawn meshes
// are swept against, so a fruit on the path would bounce the player off it; the
// flag takes it out of every spatial query while it still draws. Physics is a
// separate world and ignores the flag, which is why the trigger still fires.
//
// The trigger volume is REACH, not a workaround: a collider is taken from its
// mesh, so collecting at 0.9 rather than at 0.31 needs a wider shape.
// ---------------------------------------------------------------------------
const FRUIT_R = 0.62;      // the drawn fruit
const PICKUP_R = 0.9;      // the volume that collects it — a WORLD radius, so
                           // the reach is 0.9 + the player's 0.42, as before
class Wumpa extends three.Entity {
	static collides = false;
	// A volume is a SIBLING — a body-backed node has to be a direct child of
	// the scene — so `Wumpa.follow` carries it. The `bob` system never touches
	// it; follow runs after and picks up wherever bob left the fruit.
	static trigger = { shape: 'sphere', radius: PICKUP_R };

	constructor(x, y, z) {
		super();
		this.object = new three.Mesh(BALL, mat.fruit);
		this.object.scale.set(FRUIT_R, FRUIT_R, FRUIT_R);
		this.object.position.set(x, y, z);
		this.spin = hash2((x * 13) | 0, (z * 7) | 0, 5) * 6.28;
		this.bob = hash2(x | 0, z | 0, 8) * 6.28;
		this.free = false;
	}
}

for (let s = 12; s < PATH_LEN - 10; s += 7.5) {
	const off = Math.sin(s * 0.21) * 2.6;
	const at = onPath(s, off);
	Wumpa.spawn(at.x, groundY(at.x, at.z) + 1.05, at.z);
}

// ---------------------------------------------------------------------------
// The player.
//
// Where he is, what he is doing and what he has collected are fields; `step`,
// `spin`, `hurt`, `collect`, `look` and `pose` are the verbs. There is one
// `player`, and everything about him is on it.
//
// `static volume` IS the kinematic capsule — moveAndSlide raises no contact, so
// without a body the player could not shove a crate or trip a trigger. A volume
// is a SIBLING node, carried by `Player.follow`, and a `near` rule measures
// against it rather than the drawn root, which sits at his feet.
// ---------------------------------------------------------------------------
const HEIGHT = 1.75, RADIUS = 0.42;
const SPEED = 9.2, GRAV = 26, JUMP = 10.4;
const SPIN_TIME = 0.42, SPIN_R = 2.5;
const MOVE = { radius: RADIUS, height: HEIGHT, step: 0.45, slope: 52, skin: 0.02, snap: 0.4 };

// The spin's broad-phase answer, kept OUTSIDE the loop that reads it.
const hits = three.query.buffer(64);

const held = k => three.input.isDown(k);
const axis = (a, b) => ((a.some(held) ? 1 : 0) - (b.some(held) ? 1 : 0));
const KEYS = {
	forward: ['w', 'arrowup'], back: ['s', 'arrowdown'],
	left: ['a', 'arrowleft'], right: ['d', 'arrowright'],
	jump: ['space'], spin: ['j', 'k', 'shift'],
	yawL: ['q'], yawR: ['e'], pitchU: ['r'], pitchD: ['f'],
};

class Player extends three.Entity {
	static parent = groups.player;
	static volume = { shape: 'capsule', radius: RADIUS, height: HEIGHT, offset: [0, HEIGHT / 2, 0] };
	// The drawn body is not collision geometry — the capsule above is. Without
	// this the player's own meshes are in every sweep he makes.
	static collides = false;

	constructor(at) {
		super();
		// root -> spinner -> everything. The spinner draws nothing; it is the
		// Group the whole body rotates with when he spins, which is why it is
		// between the root and the parts rather than being the root.
		const root = new three.Group();
		const spinner = new three.Group();
		root.add(spinner);

		spinner.add(box([0.78, 0.82, 0.62], [0, 0.86, 0], 0xd86a1e));    // body
		spinner.add(box([0.66, 0.56, 0.6], [0, 1.52, 0.02], 0xe2762a));  // head
		for (const side of [-1, 1]) {
			spinner.add(cone(0.13, 0.4, [side * 0.2, 1.92, 0], 0xc95c18));            // ear
			spinner.add(box([0.14, 0.16, 0.06], [side * 0.16, 1.6, 0.32], 0xf5f0e2)); // eye
		}

		this.object = root;
		this.spinner = spinner;
		this.arm = limbs(spinner, [0.52, 1.16, 0], [0.2, 0.62, 0.2], [0, -0.3, 0], 0xd86a1e);
		this.leg = limbs(spinner, [0.22, 0.46, 0], [0.26, 0.5, 0.3], [0, -0.23, 0], 0x4a3b2c);

		// Where he is, and where the camera is looking from.
		this.x = at.x; this.y = groundY(at.x, at.z) + 0.05; this.z = at.z;
		this.vy = 0; this.grounded = false;
		this.yaw = (at.yaw * 180) / Math.PI + 180; this.pitch = 20; this.dist = 12;
		this.heading = at.yaw; this.moving = false; this.walkT = 0; this.spinAngle = 0;
		this.s = 0;

		// The three hand-rolled countdowns this file used to carry — the spin's
		// active window plus its 0.14s recovery in one three.cooldown, the grace
		// window after leaving the ground, and the hurt window's own re-entry
		// refusal. The nouns are the countdowns; the verbs below are the methods.
		this.coyote = three.cooldown(0.12);
		this.spinning = three.cooldown(SPIN_TIME, { recover: 0.14 });
		this.hurting = three.cooldown(1.4);

		// Edges mean something once per FRAME; the fixed loop runs zero to eight
		// times per frame. `latch` fills this, `step` empties it.
		this.intent = { jump: false, spin: false };

		// The run, scored by the one who is running it.
		this.fruit = 0; this.lives = 4; this.broken = 0; this.best = 0; this.done = false;
	}

	// The controller. The whole collision half is one moveAndSlide: no corridor
	// fence, no ground snap, no per-boulder circle test, because the wall, the
	// floor and the boulder are all triangles it sweeps against.
	step(dt) {
		// --- run, in the camera's frame ---
		const move = three.camera.planarMove(axis(KEYS.forward, KEYS.back), axis(KEYS.right, KEYS.left));
		this.moving = move.length() > 0;
		if (this.moving) this.heading = Math.atan2(move.x, move.z);

		// --- spin --- the readiness check lives inside spin()'s start()
		if (this.intent.spin) this.spin();
		this.intent.spin = false;
		if (this.spinning.active) this.spinAngle += dt * 34;
		else this.spinAngle *= 0.72;

		// --- vertical --- restart() every grounded frame keeps the window open
		// the whole time he is on the ground; cancel() is the "spent it".
		if (this.grounded) this.coyote.start({ restart: true });
		if (this.intent.jump && this.coyote.active) { this.vy = JUMP; this.coyote.cancel(); this.grounded = false; }
		this.intent.jump = false;
		this.vy = Math.max(this.vy - GRAV * dt, -42);

		// --- one call: the wall, the floor, the ledge and the boulder ---
		const speed = this.hurting.active ? SPEED * 0.45 : SPEED;
		const motion = [move.x * speed * dt, this.vy * dt, move.z * speed * dt];
		const r = three.moveAndSlide([this.x, this.y + HEIGHT / 2, this.z], motion, MOVE);

		this.x = r.position.x;
		this.y = r.position.y - HEIGHT / 2;
		this.z = r.position.z;

		// Landing on a crate breaks it and bounces — Crash's other verb, and the
		// reason the vertical half is spelled out rather than handed to a helper.
		if (this.vy < 0 && r.grounded) {
			const c = Crate.of(r.ground);
			if (c) {
				const bounce = c.bounce;
				this.broken += c.break();
				this.vy = bounce ? JUMP * 1.15 : JUMP * 0.72;
				this.grounded = false;
			} else {
				this.vy = 0; this.grounded = true;
			}
		} else if (r.grounded) {
			if (this.vy < 0) this.vy = 0;
			this.grounded = true;
		} else {
			this.grounded = false;
			// Hitting a ceiling: stop climbing rather than hanging under it.
			if (this.vy > 0 && r.remaining.y > 1e-4) this.vy = 0;
		}

		// Fell off the world.
		if (this.y < -6) this.hurt(true);

		// --- how far down the hollow ---
		const near = nearestOnPath(this.x, this.z);
		this.s = near.s;
		if (near.s > this.best) this.best = near.s;
		if (!this.done && near.s > PATH_LEN - 8) {
			this.done = true;
			console.log(`Made it. ${this.fruit} wumpa, ${this.broken} crates, ${this.lives} lives.`);
		}
	}

	// The spin, as its own verb. `three.query.sphere` answers with a broad-phase
	// list of NODES, and what each one is comes from asking the classes rather
	// than from a name. Crates in reach break; critters in reach fly.
	spin() {
		// start() answers false while active or still recovering, which is the
		// readiness check step() used to make before calling this.
		if (!this.spinning.start()) return 0;
		const centre = [this.x, this.y + HEIGHT / 2, this.z];
		const n = three.query.sphere(centre, SPIN_R, hits);
		for (const o of hits.objects()) {
			const c = Crate.of(o);
			if (c) {
				// Broad phase answers with boxes, so check the real distance
				// before breaking something whose corner merely reached.
				const p = c.object.position;
				if (Math.abs(p.y - centre[1]) < 1.9 && Math.hypot(p.x - this.x, p.z - this.z) < SPIN_R) {
					this.broken += c.break();
				}
				continue;
			}
			// `of` answers with the INSTANCE, which stays valid next frame even
			// though its column slot may move under it.
			const c2 = Critter.of(o);
			if (c2 && !c2.launched) {
				const q = c2.position;
				const d = Math.hypot(q[0] - this.x, q[2] - this.z);
				if (d < SPIN_R + 0.4) c2.launch((q[0] - this.x) / (d || 1), (q[2] - this.z) / (d || 1), 15);
			}
		}
		// Anything with a body just outside the break radius gets thrown instead.
		for (const c of Crate) {
			const p = c.object.position;
			const d = Math.hypot(p.x - this.x, p.z - this.z);
			if (d > SPIN_R + 2.4 || d < 1e-4) continue;
			three.physics.applyImpulse(c.object, [((p.x - this.x) / d) * 20, 8, ((p.z - this.z) / d) * 20]);
		}
		return n;
	}

	// Taking a hit. The Cooldown ticks itself; start() answering false IS the
	// re-entry refusal that used to be a hand-written `if (hurtT > 0) return`.
	hurt(fell) {
		if (!this.hurting.start()) return false;
		this.lives--;
		const back = onPath(Math.max(2, this.best - 12), 0);
		if (fell || this.lives <= 0) {
			this.x = back.x; this.z = back.z; this.y = groundY(back.x, back.z) + 0.4; this.vy = 0;
		}
		if (this.lives <= 0) {
			this.lives = 4;
			this.fruit = Math.max(0, this.fruit - 10);
			console.log('Out of lives — back down the trail.');
		} else {
			console.log(`Ouch. ${this.lives} lives left.`);
		}
		return true;
	}

	// One wumpa. Twenty-five of them is a life.
	collect() {
		this.fruit++;
		if (this.fruit % 25 === 0) {
			this.lives++;
			console.log(`25 wumpa — an extra life. ${this.lives} left.`);
		}
	}

	look(dt) {
		const ptr = three.input.pointer;
		if (ptr.down) { this.yaw -= ptr.dx * 0.24; this.pitch += ptr.dy * 0.2; }
		this.yaw += axis(KEYS.yawL, KEYS.yawR) * 120 * dt;
		this.pitch += axis(KEYS.pitchU, KEYS.pitchD) * 60 * dt;
		this.pitch = clamp(this.pitch, -4, 70);
		this.dist = clamp(this.dist + ptr.scroll, 6, 22);
		three.camera.orbit(this.yaw, this.pitch, this.dist);
	}

	// He is one character, so it is the SINGLE-agent verbs all the way through,
	// including the ordinary property writes here. A column of one would be a
	// crossing saved that was never spent. The capsule is not written here any
	// more: `Player.follow` carries it.
	pose(dt) {
		this.object.position.set(this.x, this.y, this.z);
		this.object.rotation.y = this.heading;
		this.spinner.rotation.y = this.spinAngle;
		if (this.moving && this.grounded) this.walkT += dt * 13;
		const swing = this.moving && this.grounded ? Math.sin(this.walkT) * 0.62 : 0;
		this.leg[0].rotation.x = swing; this.leg[1].rotation.x = -swing;
		const out = this.spinning.active ? 1 : 0;
		this.arm[0].rotation.x = -swing * 0.7 * (1 - out);
		this.arm[1].rotation.x = swing * 0.7 * (1 - out);
		this.arm[0].rotation.z = out * 1.5;
		this.arm[1].rotation.z = -out * 1.5;
		if (!this.grounded) { this.leg[0].rotation.x = 0.5; this.leg[1].rotation.x = -0.3; }
	}
}

const player = Player.spawn(onPath(4, 0));

// A handle for driving this from a run_script or a headless probe. `three.c3`
// has no UI yet, so the score lives on the player and in console.log — and a
// scene that cannot be inspected from outside cannot be tested at all.
globalThis.__wumpa = {
	player, Crate, Wumpa,
	get Critter() { return Critter; },
	get positions() { return Critter.column('position'); },
};

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
// The pack.
//
// Each critter has to get round a boulder to reach you, which is what the nav
// bake is for: ONE field re-solved at the player a few times a second,
// three.steer sampling it for the whole pack in one crossing, then a sweep per
// agent so they collide with the walls, the crates and the ground.
// ---------------------------------------------------------------------------
const PACK_N = 10;
const CRITTER_R = 0.38, CRITTER_H = 1.15;
const CRITTER_MOVE = { radius: CRITTER_R, height: CRITTER_H, step: 0.4, slope: 48, snap: 0.35 };


// The pack — the one class here with COLUMNS.
//
// **A column is the buffer a bulk verb takes.** `position` is handed straight
// to field.sample, three.steer and three.moveAndSlideAll with nothing
// marshalled in between: three crossings for the whole pack instead of thirty.
// That is the only reason to declare one, and the rule for deciding is simply
// whether a bulk verb reads the field.
//
// So `stun`, `walk`, `homeS` and `chasing` are ordinary properties — nothing
// takes those in bulk.
class Critter extends three.Entity {
	static parent = groups.pack;
	static capacity = PACK_N;
	// Nobody in the pack is collision geometry: you run THROUGH the critters,
	// and the `near` rule is what happens when you do. They still collide with
	// the ground, the crates and the boulders, which is everything that should
	// stop them.
	static collides = false;
	static columns = {
		position: 3,   // the capsule CENTRE, moved in place
		foot: 3,       // where the nav field is sampled
		velocity: 3,   // what three.steer wants them to do
		motion: 3,     // what this step actually asks for
		arc: 3,        // the free flight of a launched one
		cost: 1,       // ground distance to the player, written by field.sample
		move: three.moveResult.stride,
	};

	constructor(i, s, off) {
		super();
		const at = onPath(s, off);
		this.position[0] = at.x;
		this.position[1] = groundY(at.x, at.z) + CRITTER_H / 2;
		this.position[2] = at.z;

		this.heading = at.yaw;
		this.walk = hash2(i, 9, 5) * 6;    // the leg-swing phase
		this.vy = 0;
		this.stun = 0;
		this.life = 0;                     // how long a launch lasts
		this.tumble = 0;
		this.homeS = s;
		this.homeOff = off;
		this.chasing = false;
		this.moving = false;
		this.launched = false;
		this.build = i;                    // which critter was built, not which slot it is in

		const root = new three.Group();
		root.add(box([0.7, 0.62, 0.86], [0, 0.5, 0], mat.critter));    // body
		root.add(box([0.5, 0.44, 0.44], [0, 0.92, 0.3], mat.critter)); // head
		for (const side of [-1, 1]) {
			root.add(box([0.11, 0.12, 0.05], [side * 0.13, 0.98, 0.53], 0xf2ead6)); // eye
		}
		this.object = root;

		// Its two leg pivots, and where they sit in the pack's leg batch.
		this.legs = limbs(root, [0.24, 0.24, 0], [0.18, 0.3, 0.24], [0, -0.12, 0], 0x5b4a2e);
		this.legAt = i * 2;
	}

	// The flow field the whole pack steers down: one solve, kept and re-aimed at
	// the player a few times a second. It belongs to the pack, not to any one
	// critter, so it is a static.
	static flow = null;
	static flowAge = 0;

	static resolve() {
		const next = three.nav.field([player.x, player.y + 0.2, player.z]);
		if (next) {
			if (Critter.flow) Critter.flow.dispose();
			Critter.flow = next;
		}
		// A null answer means the player is off the mesh — mid-jump, or on a
		// shelf the bake found too small. Keep the last good field, so the pack
		// waits at the bottom of a ledge instead of forgetting you exist.
		Critter.flowAge = 0;
	}

	// Twenty leg pivots in one crossing. A batch rather than a column because a
	// leg is a separate NODE under the critter's root: `Critter.flush()` writes
	// the roots, this writes what swings below them.
	//
	// Indexed by `legAt` and not by the slot — a slot moves when something above
	// it dies, and a batch's membership does not. A dead critter's legs stay in
	// it, where the host skips them because their Group has left the scene.
	//
	// Built on first draw, so the membership is whoever is alive then. The whole
	// pack spawns before frame one; a critter spawned later would walk stiff.
	static legBatch = null;

	static swingLegs() {
		if (Critter.legBatch === null) {
			const pivots = [];
			for (const c of Critter) pivots.push(c.legs[0], c.legs[1]);
			Critter.legBatch = three.batch(pivots, { euler: true });
		}
		const b = Critter.legBatch;
		for (const c of Critter) {
			const swing = c.launched ? 0 : (c.moving ? Math.sin(c.walk) * 0.5 : 0);
			b.positions[b.rotationAt(c.legAt)] = swing;
			b.positions[b.rotationAt(c.legAt + 1)] = -swing;
		}
		return b.flush();
	}

	// Sent flying — by a spin, by a TNT, by anything with a direction and a
	// number. The `arc` system below is what happens next, and it is the only
	// thing that reads `life` and `launched`.
	launch(dx, dz, power) {
		this.arc[0] = dx * power;
		this.arc[1] = 7.5;
		this.arc[2] = dz * power;
		this.life = 1.5;
		this.stun = 1.5;
		this.launched = true;
	}
}

for (let i = 0; i < PACK_N; i++) {
	Critter.spawn(i, 26 + (i / PACK_N) * (PATH_LEN - 50), (hash2(i, 3, 77) - 0.5) * 5.2);
}

// The bake, AFTER the level is built — nothing bakes for you.
//
// `bounds` is the only option not about the agent, and it is what keeps the
// cost down: the walls reach 21 units up, but nothing walks above the corridor,
// so there is no reason to voxelize the sky over the cliffs.
const pathBox = PATH.reduce((b, p) => ({
	x0: Math.min(b.x0, p[0]), x1: Math.max(b.x1, p[0]),
	z0: Math.min(b.z0, p[1]), z1: Math.max(b.z1, p[1]),
}), { x0: 1e9, x1: -1e9, z0: 1e9, z1: -1e9 });
const NAV_PAD = HALF + 5;
const navBounds = {
	min: [pathBox.x0 - NAV_PAD, -2, pathBox.z0 - NAV_PAD],
	max: [pathBox.x1 + NAV_PAD, 16, pathBox.z1 + NAV_PAD],
};
// **Read `components`.** A fragmented bake looks healthy from every other
// number — a big `walkable`, a live field, a plausible `bakeMs` — and the graph
// coming apart shows up as the pack standing around as if the steering broke.
//
// More than one region is not wrong by itself: the top of a crate is standing
// room nothing can walk up to, so it is honestly its own region. Watch
// `largest` against `walkable` — 5190 of 5597 here, and the rest are crate
// lids. A broken bake has the largest region at a fraction of the whole.
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

// ---------------------------------------------------------------------------
// Picking up fruit — one rule.
// ---------------------------------------------------------------------------
// The rule resolves the trigger volume back to the fruit that owns it and hands
// the handler its SUBJECT first, what it met second. No type test, no lookup.
//
// Engine events queue and drain in the `rules` system at the top of the frame
// rather than firing inside the solver, so removing the fruit here is safe.
Wumpa.on('enter', Player, (f, p) => { f.remove(); p.collect(); });

// ---------------------------------------------------------------------------
// The pack's systems — six named things in a declared order. Three of them are
// one crossing apiece for the whole pack, whatever its size.
// ---------------------------------------------------------------------------

// The kept solve, re-aimed at the player a few times a second.
const FLOW_EVERY = 0.35;  // seconds
Critter.step('flow', (dt) => {
	Critter.flowAge += dt;
	if (Critter.flow === null || Critter.flowAge >= FLOW_EVERY) Critter.resolve();
});

// How far everyone is from the player, ALONG THE GROUND — one crossing, and
// `field.cost` in a loop is what it replaces. A NEGATIVE cost is unreachable
// here where `cost()` answers Infinity, which is the one place the convenient
// form and the flat form disagree about a value.
Critter.step('sense', () => {
	for (const c of Critter) {
		c.foot[0] = c.position[0];
		c.foot[1] = c.position[1] - CRITTER_H / 2 + 0.2;
		c.foot[2] = c.position[2];
	}
	if (Critter.flow) {
		Critter.flow.sample(Critter.column('foot'), { costs: Critter.column('cost') });
	} else {
		Critter.column('cost').fill(-1);
	}
	// Out of earshot: hold station near home rather than sprinting the whole
	// level at you, which is what makes a hollow feel populated.
	for (const c of Critter) {
		c.chasing = c.cost[0] >= 0 && c.cost[0] < 26 && c.stun <= 0;
	}
});

// Seek, arrive and separation for the whole pack in one crossing. What comes
// back is a DESIRED velocity — going there is still moveAndSlide's decision.
Critter.step('steer', () => {
	if (Critter.flow) {
		three.steer(Critter.column('position'), Critter.column('velocity'), {
			field: Critter.flow, maxSpeed: 4.6, arrive: 1.6, separation: 1.5, separationWeight: 1.5,
		});
	} else {
		Critter.column('velocity').fill(0);
	}
});

// The whole pack's collision, in one call. A launched critter is given zero
// motion and has its position overwritten by `arc` below, so its sweep is
// wasted — cheaper than branching the one call that makes this fast.
Critter.step('walk', (dt) => {
	for (const c of Critter) {
		if (c.launched) {
			c.motion[0] = 0; c.motion[1] = 0; c.motion[2] = 0;
			continue;
		}
		if (c.stun > 0) c.stun -= dt;

		let vx = c.velocity[0], vz = c.velocity[2];
		if (!c.chasing) {
			const h = onPath(c.homeS + Math.sin(three.clock.time * 0.5 + c.build) * 5, c.homeOff);
			const dx = h.x - c.position[0], dz = h.z - c.position[2], d = Math.hypot(dx, dz);
			vx = d > 0.4 ? (dx / d) * 1.7 : 0;
			vz = d > 0.4 ? (dz / d) * 1.7 : 0;
		} else if (c.stun > 0) {
			vx *= 0.2; vz *= 0.2;
		}

		c.vy = Math.max(c.vy - GRAV * dt, -40);
		c.motion[0] = vx * dt;
		c.motion[1] = c.vy * dt;
		c.motion[2] = vz * dt;

		c.moving = Math.hypot(vx, vz) > 0.25;
		if (c.moving) c.heading = Math.atan2(vx, vz);
		c.walk += dt * (c.chasing ? 15 : 9) * (c.moving ? 1 : 0);
	}

	// `Critter.handles` is both things a crowd needs in one array: the `self`
	// column that keeps an agent from colliding with its own mesh, and the
	// handle array the flush below writes through.
	three.moveAndSlideAll(Critter.column('position'), Critter.column('motion'), {
		...CRITTER_MOVE,
		results: Critter.column('move'),
		self: Critter.handles,
	});

	for (const c of Critter) {
		if (c.launched) continue;
		const grounded = (c.move[three.moveResult.flags] | 0) & three.moveResult.GROUNDED;
		if (grounded && c.vy < 0) c.vy = 0;
		if (c.position[1] < -6) c.remove();
	}
});

// The ones a spin or a TNT sent flying: a free arc, no steering, and the only
// thing they collide with is the ground they land on.
Critter.step('arc', (dt) => {
	for (const c of Critter) {
		if (!c.launched) continue;
		c.life -= dt;
		c.arc[1] -= GRAV * 0.7 * dt;
		c.position[0] += c.arc[0] * dt;
		c.position[1] += c.arc[1] * dt;
		c.position[2] += c.arc[2] * dt;
		c.tumble += dt * 16;

		const foot = c.position[1] - CRITTER_H / 2;
		const ground = groundY(c.position[0], c.position[2]);
		if (foot > ground && c.life > 0) continue;

		c.position[1] = Math.max(c.position[1], ground + CRITTER_H / 2);
		c.launched = false;
		c.vy = 0;
		if (Math.abs(c.position[0]) > W / 2 - 4 || Math.abs(c.position[2]) > D / 2 - 4 || foot < -4) c.remove();
	}
});

// Reaching the player costs a life — unless you are spinning, in which case the
// critter loses.
//
// **`near` is the event physics never raises**, because moveAndSlide produces
// no contact. `{ within }` is the hand-written hypot loop, in the engine, once.
// It reads the critter's position COLUMN and the player's collision VOLUME, so
// it tests where they actually are rather than where the draw last put them.
Critter.on('near', Player, (c, p) => {
	if (c.launched || p.hurting.active) return;
	const d = Math.hypot(c.position[0] - p.x, c.position[2] - p.z) || 1;
	const nx = (c.position[0] - p.x) / d, nz = (c.position[2] - p.z) / d;
	if (p.spinning.active) c.launch(nx, nz, 15);
	else { p.hurt(false); c.launch(nx, nz, 7); }
}, { within: 0.95 });

// Drawing them: two crossings for the whole pack, whatever its size. `lift`
// carries the capsule-centre-to-feet offset — those are never the same point —
// and `heading` here is an ordinary field, which pose reads just as happily as
// a column.
Critter.frame('draw', () => {
	Critter.pose('position', { lift: -CRITTER_H / 2, heading: 'heading' });
	const t = Critter.transform;
	let slot = 0;
	for (const c of Critter) {
		if (c.launched) t[slot * 9 + 4] = c.tumble;
		slot++;
	}
	Critter.flush();
	Critter.swingLegs();
}, { after: 'Player.pose' });

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
// The frame, as a list of named things.
//
// Gameplay runs in the FIXED phase, at a dt that is the same every call.
// Drawing the consequence runs in the frame phase, which is also the only
// place a key EDGE means anything.
//
// `three.systems.list()` is the running order and `three.systems.report()` says
// what each one costs, most expensive first. The pack's six are declared beside
// the pack; these are what is left.
// ---------------------------------------------------------------------------
three.camera.attach(player.object, { offset: [0, 1.5, 0], distance: player.dist, lag: 0.095 });
three.controls.enabled = false;
three.camera.orbit(player.yaw, player.pitch, player.dist);

sky.uniforms.viewFar = three.camera.far;

// Declared on the class, so they report as `Player.step`, `Player.pose` and so
// on, and `Player.dispose()` would take them with it. What each one does is a
// method; where it runs is the option beside it.
Player.step('step', dt => {
	if (three.clock.paused) return;
	player.step(dt);
}, { first: true });

Player.frame('look', dt => player.look(dt));

// Edges mean something once per FRAME, and the fixed loop runs zero to eight
// times per frame — so latch here, consume in `step`.
Player.frame('latch', () => {
	if (KEYS.jump.some(k => three.input.pressed(k))) player.intent.jump = true;
	if (KEYS.spin.some(k => three.input.pressed(k))) player.intent.spin = true;
});

Player.frame('pose', dt => player.pose(dt));

// No columns: nothing takes two dozen bobbing fruit in bulk. The trigger volume
// is not written here either — `Wumpa.follow` runs later and picks up wherever
// this left the fruit.
Wumpa.frame('bob', dt => {
	for (const f of Wumpa) {
		f.spin += dt * 3;
		f.object.rotation.y = f.spin;
		if (f.free) {
			// One that fell out of a crate settles onto the ground it landed on.
			const g = groundY(f.object.position.x, f.object.position.z) + 0.62;
			if (f.object.position.y > g) f.object.position.y = Math.max(g, f.object.position.y - 9 * dt);
			else f.free = false;
		} else {
			f.bob += dt * 2.4;
			f.object.position.y += Math.sin(f.bob) * 0.4 * dt;
		}
	}
});

three.systems.frame('chips', dt => {
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
});

three.systems.frame('sky', () => { sky.uniforms.viewFar = three.camera.far; });

// ---------------------------------------------------------------------------
// What the level cost to build.
// ---------------------------------------------------------------------------
const nav = three.nav.stats();
console.log(`hollow: ${PATH_LEN.toFixed(0)} units of trail, ${Crate.count} crates, `
	+ `${Wumpa.count} wumpa, ${Critter.count} critters`);
if (nav) {
	console.log(`nav: cell ${nav.cell}, ${nav.voxels} voxels, ${nav.walkable} walkable, `
		+ `${nav.components} regions (largest ${nav.largest}), baked in ${nav.bakeMs.toFixed(1)} ms`);
} else {
	console.log('nav: the bake found no standing room — the pack will hold station');
}

three.debug.write({
	trail: Math.round(PATH_LEN),
	crates: Crate.count,
	wumpa: Wumpa.count,
	critters: Critter.count,
	nav: bake && {
		cell: bake.cell, voxels: bake.voxels, walkable: bake.walkable,
		components: bake.components, largest: bake.largest, bakeMs: +bake.bakeMs.toFixed(1),
	},
	stats: three.stats(),
});
