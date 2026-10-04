// village_walk.js — walk a villager around a small village built out of
// parallax occlusion mapped surfaces: brick, half-timber, shingle, cobble,
// fieldstone and turf all have real depth, and none of it is geometry.
//
//   ./build/three --script examples/village_walk.js
//   ./build/three --script examples/village_walk.js --camera 0,18,3.2 --screenshot village_walk.png
//
// WASD or the arrows walk (relative to the camera), shift runs, space jumps,
// dragging the mouse orbits and the wheel zooms.
//
//   p  relief on / off — the same village, flat. Walk up to a wall and flip it.
//   l  the relief shading itself toward the sun (self shadow) on / off
//   m  march steps: 8 / 16 / 32
//   o  shadow map on / off
//   s  print what the frame costs
//
// Every image is generated below as a PAIR: a colour map and the height map it
// was painted from, so the mortar in one is the valley in the other. Height is
// uploaded linear (it is data), colour as sRGB (it is a picture).

const SIZE = 256;
const SEED = 7;

// ---------------------------------------------------------------------------
// Noise and painting
// ---------------------------------------------------------------------------

function hash2(x, y, s) {
	let h = Math.imul(x | 0, 374761393) ^ Math.imul(y | 0, 668265263) ^ Math.imul(s | 0, 2246822519);
	h = Math.imul(h ^ (h >>> 13), 1274126177);
	return ((h ^ (h >>> 16)) >>> 0) / 4294967296;
}
const clamp01 = (t) => (t < 0 ? 0 : t > 1 ? 1 : t);
const smooth = (t) => t * t * (3 - 2 * t);
const lerp = (a, b, t) => a + (b - a) * t;
const mix = (a, b, t) => [lerp(a[0], b[0], t), lerp(a[1], b[1], t), lerp(a[2], b[2], t)];
const tint = (c, k) => [c[0] * k, c[1] * k, c[2] * k];
const ramp = (lo, hi, x) => smooth(clamp01((x - lo) / (hi - lo)));

// Value noise that wraps, so the image tiles.
function noise(cells, s) {
	const out = new Float32Array(SIZE * SIZE);
	for (let y = 0; y < SIZE; y++) {
		const gy = (y / SIZE) * cells;
		const y0 = Math.floor(gy);
		const fy = smooth(gy - y0);
		for (let x = 0; x < SIZE; x++) {
			const gx = (x / SIZE) * cells;
			const x0 = Math.floor(gx);
			const fx = smooth(gx - x0);
			const a = hash2(x0 % cells, y0 % cells, s);
			const b = hash2((x0 + 1) % cells, y0 % cells, s);
			const c = hash2(x0 % cells, (y0 + 1) % cells, s);
			const d = hash2((x0 + 1) % cells, (y0 + 1) % cells, s);
			out[y * SIZE + x] = lerp(lerp(a, b, fx), lerp(c, d, fx), fy);
		}
	}
	return out;
}

// Paint a colour map and its height map in one pass. `shade(x, y)` answers
// `{ h, c }`: height in 0..1 (0.5 is the mesh's own plane) and a colour.
function paint(shade) {
	const color = new Uint8Array(SIZE * SIZE * 4);
	const height = new Uint8Array(SIZE * SIZE * 4);
	for (let y = 0; y < SIZE; y++) {
		for (let x = 0; x < SIZE; x++) {
			const { h, c } = shade(x, y);
			const i = (y * SIZE + x) * 4;
			const v = Math.round(clamp01(h) * 255);
			height[i] = v; height[i + 1] = v; height[i + 2] = v; height[i + 3] = 255;
			color[i] = Math.max(0, Math.min(255, c[0]));
			color[i + 1] = Math.max(0, Math.min(255, c[1]));
			color[i + 2] = Math.max(0, Math.min(255, c[2]));
			color[i + 3] = 255;
		}
	}
	return {
		color: new three.DataTexture(color, SIZE, SIZE),
		height: new three.DataTexture(height, SIZE, SIZE, { colorSpace: three.LinearSRGBColorSpace }),
	};
}

// ---------------------------------------------------------------------------
// The six surfaces. `tile` is the size of one image in metres: it is what a
// face divides its own size by to say how many times to repeat.
// ---------------------------------------------------------------------------

function makeSurfaces() {
	const speck = noise(16, SEED + 1);
	const grain = noise(8, SEED + 2);

	// Courses of bricks, every other one shifted by half a brick. Faces bevel
	// down into the mortar.
	const ROWS = 8, PER_ROW = 4;
	const COURSE = SIZE / ROWS, BRICK = SIZE / PER_ROW;
	const brick = paint((x, y) => {
		const row = Math.floor(y / COURSE);
		const cx = (x + (row & 1 ? BRICK / 2 : 0)) % SIZE;
		const bx = cx % BRICK, by = y % COURSE;
		const edge = Math.min(bx, BRICK - bx, by, COURSE - by);
		const face = ramp(1.5, 5, edge);
		const k = y * SIZE + x;
		const id = row * 7 + Math.floor(cx / BRICK) * 13;
		const clay = tint(mix([150, 70, 52], [190, 108, 80], speck[k]), 0.82 + 0.3 * hash2(id, 3, SEED));
		const mortar = mix([168, 162, 150], [196, 190, 178], speck[k]);
		return { h: 0.1 + 0.8 * face - 0.04 * speck[k], c: mix(mortar, clay, face > 0.35 ? 1 : face / 0.35) };
	});

	// Plaster between timber beams that stand proud of it, on a tile edge so
	// the frame lands on the corners of a wall.
	const timber = paint((x, y, ) => {
		const u = x / SIZE, v = y / SIZE;
		const k = y * SIZE + x;
		const d = Math.min(u, 1 - u, v, 1 - v);
		const cross = Math.min(Math.abs(u - 0.5), Math.abs(v - 0.5));
		const beam = Math.min(ramp(0.1, 0.075, d), 1) ;
		const brace = ramp(0.06, 0.04, cross);
		const wood = Math.max(beam, brace);
		const plaster = mix([232, 222, 200], [190, 178, 152], grain[k]);
		const oak = mix([74, 52, 36], [108, 80, 54], grain[k]);
		// Plaster is lumpy; beams are flat-topped.
		return { h: lerp(0.3 + 0.1 * grain[k], 0.85, wood), c: mix(plaster, oak, wood) };
	});

	// Cobbles: Voronoi cells, domed in the middle, gaps between them.
	const CELLS = 5;
	const cobble = paint((x, y) => {
		const gx = (x / SIZE) * CELLS, gy = (y / SIZE) * CELLS;
		let d1 = 9, d2 = 9, id = 0;
		for (let oy = -1; oy <= 1; oy++) {
			for (let ox = -1; ox <= 1; ox++) {
				const cx = Math.floor(gx) + ox, cy = Math.floor(gy) + oy;
				const wx = ((cx % CELLS) + CELLS) % CELLS, wy = ((cy % CELLS) + CELLS) % CELLS;
				const px = cx + 0.2 + 0.6 * hash2(wx, wy, SEED + 11);
				const py = cy + 0.2 + 0.6 * hash2(wx, wy, SEED + 12);
				const d = Math.hypot(gx - px, gy - py);
				if (d < d1) { d2 = d1; d1 = d; id = wy * CELLS + wx; }
				else if (d < d2) d2 = d;
			}
		}
		const gap = d2 - d1;
		const stone = ramp(0.02, 0.2, gap);
		const dome = 0.8 + 0.2 * (1 - clamp01(d1 / 0.5)) * stone;
		const tone = 0.7 + 0.5 * hash2(id, id >> 3, SEED + 13);
		return { h: 0.08 + 0.55 * stone * dome, c: mix([58, 56, 52], tint([128, 122, 114], tone), stone) };
	});

	// Shingle courses: each tile is a ramp that rises toward its lip and is
	// cut at the sides, so the rows overlap.
	const COURSES = 6, COLS = 4;
	const CH = SIZE / COURSES, CW = SIZE / COLS;
	const shingle = paint((x, y) => {
		const r = Math.floor(y / CH);
		const cx = (x + (r & 1 ? CW / 2 : 0)) % SIZE;
		const u = (cx % CW) / CW, v = (y % CH) / CH;
		const side = ramp(0.0, 0.07, Math.min(u, 1 - u));
		const h = 0.15 + 0.75 * (1 - v) * side;
		const base = mix([96, 56, 44], [160, 100, 72], hash2(Math.floor(cx / CW), r, SEED + 21));
		return { h, c: tint(base, (0.6 + 0.4 * (1 - v)) * (0.65 + 0.35 * side)) };
	});

	// Fieldstone blocks of different widths in staggered courses.
	const BLOCKS = 5;
	const BH = SIZE / BLOCKS;
	const stone = paint((x, y) => {
		const row = Math.floor(y / BH);
		const widths = [0.5, 0.3, 0.45, 0.25, 0.35];
		let start = hash2(row, 1, SEED + 31) * SIZE, cell = 0, edgeX = 0, w = 0, acc = start;
		const px = (x - start + SIZE * 2) % SIZE;
		let run = 0;
		for (let i = 0; i < 12; i++) {
			w = SIZE * (0.18 + 0.2 * hash2(row, i, SEED + 32));
			if (px < run + w) { cell = i; edgeX = Math.min(px - run, run + w - px); break; }
			run += w;
		}
		const by = y % BH;
		const edge = Math.min(edgeX, by, BH - by);
		const face = ramp(1, 6, edge);
		const wob = grain[y * SIZE + x];
		const tone = 0.75 + 0.4 * hash2(row, cell, SEED + 33);
		return { h: 0.1 + 0.7 * face + 0.1 * wob, c: mix([70, 68, 64], tint([150, 146, 138], tone), face) };
	});

	// Turf: low, soft relief; blades are tiny height spikes.
	const turf = noise(10, SEED + 41);
	const grass = paint((x, y) => {
		const k = y * SIZE + x;
		const blade = hash2(x, y, SEED + 42);
		const c = mix([54, 88, 40], [118, 152, 72], turf[k]);
		const lift = blade > 0.9 ? 0.2 : 0;
		return { h: 0.35 + 0.35 * turf[k] + lift, c: [c[0] + lift * 70, c[1] + lift * 120, c[2]] };
	});

	return {
		brick:   { ...brick,   tile: [0.9, 0.6],  depth: 0.07, steps: 24 },
		timber:  { ...timber,  tile: [2.4, 2.4],  depth: 0.08, steps: 24 },
		cobble:  { ...cobble,  tile: [1.6, 1.6],  depth: 0.09, steps: 32 },
		shingle: { ...shingle, tile: [1.8, 1.2],  depth: 0.09, steps: 24 },
		stone:   { ...stone,   tile: [1.6, 1.2],  depth: 0.10, steps: 24 },
		grass:   { ...grass,   tile: [2.0, 2.0],  depth: 0.06, steps: 12 },
	};
}

const surface = makeSurfaces();

// ---------------------------------------------------------------------------
// Materials. A map is a property of a material, and so is its tiling, so a
// face of a given size asks `relief(kind, w, h)` and gets the material that
// repeats right for it. Repeat is rounded to a quarter so a village of
// ten houses is a dozen materials rather than a hundred.
// ---------------------------------------------------------------------------

const reliefMaterials = [];
const cache = new Map();
let reliefOn = true;
let selfShadow = 1;
let steps = 1; // multiplier index, see `m`

function relief(kind, w, h) {
	const s = surface[kind];
	const rx = Math.max(0.25, Math.round((w / s.tile[0]) * 4) / 4);
	const ry = Math.max(0.25, Math.round((h / s.tile[1]) * 4) / 4);
	const key = `${kind}:${rx}:${ry}`;
	let m = cache.get(key);
	if (!m) {
		m = new three.MeshLambertMaterial({
			map: s.color,
			heightMap: s.height,
			heightScale: s.depth,
			parallaxSteps: s.steps,
			parallaxShadow: selfShadow,
			roughness: 0.9,
		});
		m.repeat = [rx, ry];
		m.baseDepth = s.depth;
		m.baseSteps = s.steps;
		cache.set(key, m);
		reliefMaterials.push(m);
	}
	return m;
}

function applyRelief() {
	for (const m of reliefMaterials) {
		m.heightScale = reliefOn ? m.baseDepth : 0;
		m.parallaxSteps = Math.min(64, Math.round(m.baseSteps * steps));
		m.parallaxShadow = selfShadow;
	}
}

// Colour is per mesh, so every plain prop shares this one white material and
// carries its colour on the mesh, which keeps them in one batch.
const WHITE = new three.MeshLambertMaterial({ roughness: 0.85 });
const SKIN = WHITE;
const plain = () => WHITE;
function solid(geometry, color) {
	const m = new three.Mesh(geometry, WHITE);
	m.color = color;
	return m;
}

// ---------------------------------------------------------------------------
// Scene
// ---------------------------------------------------------------------------

const scene = new three.Scene();
scene.background = 0x9bbbd8;
three.light.set([0.5, 0.55, 0.35], 0.32);
three.light.shadow = { enabled: true, size: 2048 };

const QUAD = new three.PlaneGeometry(1, 1);
const BOX = new three.BoxGeometry(1, 1, 1);
const ROD = new three.CylinderGeometry(0.5, 0.5, 1, 14);
const PYRAMID = new three.ConeGeometry(1, 1, 4);
const CONE = new three.ConeGeometry(1, 1, 12);
const BALL = new three.SphereGeometry(0.5, 16, 10);

// A flat tile of ground: a plane lying down, `w` east-west, `d` north-south.
function slab(kind, w, d, x, y, z) {
	const m = new three.Mesh(QUAD, relief(kind, w, d));
	m.rotation.x = -Math.PI / 2;
	m.scale.set(w, d, 1);
	m.position.set(x, y, z);
	scene.add(m);
	return m;
}

slab('grass', 120, 120, 0, 0, 0);
// The plaza and the road out of it, a hair above the turf.
slab('cobble', 18, 18, 0, 0.05, 0);
slab('cobble', 5, 45, 0, 0.05, 31);
slab('cobble', 45, 5, 31, 0.05, 0);

// A box that blocks, sunk 10 cm behind its skin: planes closer than that to
// the box z-fight with it at a distance, which reads as flicker in motion.
// A box that blocks and is not drawn with relief, with relief faces skinned
// onto it. `collides` is per node: the box is the wall, the planes are skin.
function skinnedBox(parent, kind, w, h, d, topKind) {
	const core = solid(BOX, 0xb8aa94);
	core.scale.set(w - 0.2, h - 0.2, d - 0.2);
	core.position.y = h / 2;
	parent.add(core);

	const faces = [
		{ w, at: [0, h / 2, d / 2], ry: 0 },
		{ w, at: [0, h / 2, -d / 2], ry: Math.PI },
		{ w: d, at: [w / 2, h / 2, 0], ry: Math.PI / 2 },
		{ w: d, at: [-w / 2, h / 2, 0], ry: -Math.PI / 2 },
	];
	for (const f of faces) {
		const p = new three.Mesh(QUAD, relief(kind, f.w, h));
		p.scale.set(f.w, h, 1);
		p.position.set(...f.at);
		p.rotation.y = f.ry;
		p.collides = false;
		parent.add(p);
	}
	return core;
}

// ---------------------------------------------------------------------------
// Houses
// ---------------------------------------------------------------------------

const ROOF_TINTS = [0xffffff, 0xe0c2b0, 0xc9d3c8, 0xe9cfa8];
const WALL_KINDS = ['brick', 'timber', 'timber', 'brick'];
const WALLS_SOLID = [];

function house(name, x, z, facing, w, d, wallH, roofH, kind, roofTint) {
	const g = new three.Group();
	g.name = name;
	g.position.set(x, 0, z);
	g.rotation.y = facing;
	scene.add(g);

	// A stone plinth makes the walls read as standing on something.
	const plinth = new three.Group();
	g.add(plinth);
	skinnedBox(plinth, 'stone', w + 0.2, 0.6, d + 0.2);

	const walls = new three.Group();
	walls.position.y = 0.6;
	g.add(walls);
	skinnedBox(walls, kind, w, wallH, d);

	const eaveW = w + 0.7, eaveD = d + 0.7;
	const roof = new three.Mesh(PYRAMID, relief('shingle', 6, 2.4));
	roof.rotation.y = Math.PI / 4;
	roof.scale.set(eaveW * 0.7071, roofH, eaveD * 0.7071);
	roof.position.y = 0.6 + wallH + roofH / 2;
	roof.color = roofTint;
	roof.collides = false;
	g.add(roof);

	const door = solid(BOX, 0x6a4a2c);
	door.scale.set(0.95, 1.9, 0.16);
	door.position.set(0, 0.6 + 0.95, d / 2 + 0.06);
	g.add(door);
	const step = solid(BOX, 0x777168);
	step.scale.set(1.5, 0.2, 0.7);
	step.position.set(0, 0.1, d / 2 + 0.45);
	g.add(step);

		for (const dx of [-1, 1]) {
		const win = solid(BOX, 0xf1d27c);
		win.scale.set(0.75, 0.8, 0.1);
		win.position.set(dx * w * 0.3, 0.6 + wallH * 0.55, d / 2 + 0.03);
		win.collides = false;
		g.add(win);
		const sill = solid(BOX, 0x6a4a2c);
		sill.scale.set(0.95, 0.08, 0.2);
		sill.position.set(dx * w * 0.3, 0.6 + wallH * 0.55 - 0.45, d / 2 + 0.07);
		sill.collides = false;
		g.add(sill);
	}

	const chimney = new three.Mesh(BOX, relief('brick', 0.7, 3));
	chimney.scale.set(0.7, wallH * 0.7 + roofH, 0.7);
	chimney.position.set(w * 0.2, 0.6 + wallH * 0.5 + roofH * 0.15, -d * 0.15);
	chimney.collides = false;
	g.add(chimney);
	return g;
}

// Houses face the plaza from three sides, with the roads leaving through the
// two gaps in the corners.
const lots = [
	// north side, facing +z
	{ x: -11, z: -13, f: 0, w: 5.5, d: 4.6 },
	{ x: -3.2, z: -13.6, f: 0, w: 4.6, d: 4.4 },
	{ x: 4.6, z: -13, f: 0, w: 5.2, d: 4.6 },
	{ x: 12.2, z: -13.4, f: 0, w: 4.4, d: 4.2 },
	// west side, facing +x
	{ x: -13.5, z: -4.5, f: Math.PI / 2, w: 5, d: 4.4 },
	{ x: -13.2, z: 4.5, f: Math.PI / 2, w: 4.6, d: 4.6 },
	{ x: -13.8, z: 12, f: Math.PI / 2, w: 5.4, d: 4.2 },
	// east side, facing -x
	{ x: 13.4, z: -3.5, f: -Math.PI / 2, w: 5, d: 4.4 },
	{ x: 13.8, z: 5, f: -Math.PI / 2, w: 4.6, d: 4.8 },
	// south side, facing -z, either side of the road
	{ x: -9, z: 14, f: Math.PI, w: 5, d: 4.4 },
	{ x: 9.5, z: 14, f: Math.PI, w: 5.2, d: 4.6 },
];
lots.forEach((l, i) => {
	const r = (n) => hash2(i, n, SEED + 50);
	house(
		`house_${i}`, l.x, l.z, l.f, l.w, l.d,
		2.7 + r(1) * 0.9, 1.7 + r(2) * 1.0,
		WALL_KINDS[Math.floor(r(3) * WALL_KINDS.length)],
		ROOF_TINTS[Math.floor(r(4) * ROOF_TINTS.length)],
	);
});

// ---------------------------------------------------------------------------
// The plaza: a well, a low fieldstone wall, a few barrels and crates
// ---------------------------------------------------------------------------

{
	const well = new three.Group();
	well.name = 'well';
	scene.add(well);
	const ring = new three.Mesh(ROD, relief('stone', 3.6, 1.2));
	ring.scale.set(2.4, 1.0, 2.4);
	ring.position.y = 0.5;
	well.add(ring);
	const water = solid(ROD, 0x2c4a68);
	water.scale.set(1.8, 0.05, 1.8);
	water.position.y = 0.97;
	water.collides = false;
	well.add(water);
	for (const s of [-1, 1]) {
		const post = solid(ROD, 0x6a4a2c);
		post.scale.set(0.16, 2.3, 0.16);
		post.position.set(s * 1.0, 1.9, 0);
		well.add(post);
	}
	const beam = solid(BOX, 0x6a4a2c);
	beam.scale.set(2.4, 0.16, 0.2);
	beam.position.y = 3.0;
	beam.collides = false;
	well.add(beam);
	const hood = new three.Mesh(PYRAMID, relief('shingle', 4, 1.5));
	hood.rotation.y = Math.PI / 4;
	hood.scale.set(1.9, 0.9, 1.4);
	hood.position.y = 3.5;
	hood.collides = false;
	well.add(hood);
}

// Low walls along the roads and one around a garden — long thin boxes, so the
// stone is seen from the side and from above.
function wall(x, z, len, along) {
	const g = new three.Group();
	g.position.set(x, 0, z);
	g.rotation.y = along ? Math.PI / 2 : 0;
	scene.add(g);
	skinnedBox(g, 'stone', len, 1.0, 0.7);
}
wall(-5, 22, 8, false);
wall(5, 22, 8, false);
wall(22, -5, 8, true);
wall(22, 5, 8, true);
wall(-22, -22, 14, false);
wall(-29, -15, 14, true);

// Barrels and crates by the doors.
function barrel(x, z) {
	const b = solid(ROD, 0x7a5230);
	b.scale.set(0.8, 1.0, 0.8);
	b.position.set(x, 0.5, z);
	scene.add(b);
	const band = solid(ROD, 0x2b2118);
	band.scale.set(0.84, 0.08, 0.84);
	band.position.set(x, 0.7, z);
	band.collides = false;
	scene.add(band);
}
function crate(x, z, s = 0.9) {
	const c = solid(BOX, 0x8a6a3c);
	c.scale.set(s, s, s);
	c.position.set(x, s / 2, z);
	c.rotation.y = hash2(x * 10, z * 10, SEED) * 1.2;
	scene.add(c);
}
barrel(-8.2, -10.6); barrel(-7.4, -10.7); crate(8, -10.6); crate(8.8, -10.8, 0.7);
barrel(-11.2, 0.5); crate(-11, 8); barrel(11.2, 8); crate(11.4, -0.5);

// ---------------------------------------------------------------------------
// Trees and lamps
// ---------------------------------------------------------------------------

for (let i = 0; i < 26; i++) {
	const r = (n) => hash2(i, n, SEED + 70);
	const a = r(1) * Math.PI * 2;
	const dist = 26 + r(2) * 24;
	const x = Math.cos(a) * dist, z = Math.sin(a) * dist;
	// Keep the roads clear.
	if (Math.abs(x) < 4.5 || Math.abs(z) < 4.5) continue;
	const s = 0.8 + r(3) * 0.8;
	const trunk = solid(ROD, 0x6a4a2c);
	trunk.scale.set(0.4 * s, 2.4 * s, 0.4 * s);
	trunk.position.set(x, 1.2 * s, z);
	scene.add(trunk);
	for (const [yy, rr, hh] of [[3.4, 2.4, 3], [4.9, 1.7, 2.4]]) {
		const crown = solid(CONE, 0x4c7a38);
		crown.scale.set(rr * s, hh * s, rr * s);
		crown.position.set(x, yy * s, z);
		crown.color = [0.3 + r(4) * 0.12, 0.58 + r(5) * 0.12, 0.26];
		crown.collides = false;
		scene.add(crown);
	}
}

for (const [x, z] of [[-8, -8], [8, -8], [-8, 8], [8, 8], [0, 18], [18, 0], [0, -18]]) {
	const post = solid(ROD, 0x33333b);
	post.scale.set(0.14, 3.2, 0.14);
	post.position.set(x, 1.6, z);
	scene.add(post);
	const lamp = solid(BALL, 0xffe6a4);
	lamp.scale.set(0.36, 0.42, 0.36);
	lamp.position.set(x, 3.35, z);
	lamp.collides = false;
	scene.add(lamp);
}

// ---------------------------------------------------------------------------
// People. The player, and a few villagers who stroll between points.
// ---------------------------------------------------------------------------

const COATS = [0xa8443c, 0x3e5f8a, 0x4d7a4a, 0x8a6a2c, 0x6a4a7a, 0xb0763a];

function limb(parent, x, y, len, thick, material, color) {
	const pivot = new three.Group();
	pivot.position.set(x, y, 0);
	const m = new three.Mesh(ROD, material);
	m.scale.set(thick, len, thick);
	m.position.y = -len / 2;
	m.color = color;
	m.collides = false;
	pivot.add(m);
	parent.add(pivot);
	return pivot;
}

function person(coat, hat) {
	const root = new three.Group();
	const body = new three.Group();
	root.add(body);
	const part = (geo, mat, color, scale, at) => {
		const m = new three.Mesh(geo, mat);
		m.scale.set(...scale);
		m.position.set(...at);
		m.color = color;
		m.collides = false;
		body.add(m);
		return m;
	};
	const cloth = plain(0xffffff);
	part(ROD, cloth, coat, [0.46, 0.62, 0.3], [0, 0.95, 0]);
	part(BALL, SKIN, 0xe0aa80, [0.34, 0.38, 0.32], [0, 1.42, 0]);
	part(CONE, cloth, hat, [0.42, 0.3, 0.42], [0, 1.66, 0]);
	return {
		root, body,
		legL: limb(body, -0.12, 0.64, 0.64, 0.17, cloth, 0x3a3328),
		legR: limb(body, 0.12, 0.64, 0.64, 0.17, cloth, 0x3a3328),
		armL: limb(body, -0.27, 1.2, 0.58, 0.13, SKIN, 0xe0aa80),
		armR: limb(body, 0.27, 1.2, 0.58, 0.13, SKIN, 0xe0aa80),
	};
}

function swing(p, phase, amount) {
	const s = Math.sin(phase) * amount;
	p.legL.rotation.x = s;
	p.legR.rotation.x = -s;
	p.armL.rotation.x = -s * 0.8;
	p.armR.rotation.x = s * 0.8;
}

// --- the player ---
const HEIGHT = 1.75, RADIUS = 0.4;
const MOVE = { radius: RADIUS, height: HEIGHT, step: 0.4, slope: 50, skin: 0.02, snap: 0.35 };
const hero = person(0xc0392b, 0x2f4858);
hero.root.name = 'hero';
hero.root.collides = false;
scene.add(hero.root);

const me = { x: 0, y: 0.05, z: 22, vy: 0, grounded: false, heading: Math.PI, walk: 0, jump: false };
hero.root.position.set(me.x, me.y, me.z);

// --- a few strollers ---
const folk = [];
const routes = [
	[[-6, 3], [6, 3], [6, -4], [-6, -4]],
	[[0, 28], [0, 10], [0, 28]],
	[[28, 2], [10, 2], [28, 2]],
	[[-9, 9], [-3, 12], [3, 9], [-3, 6]],
];
routes.forEach((route, i) => {
	const p = person(COATS[i % COATS.length], 0x8a2f2f);
	scene.add(p.root);
	folk.push({ p, route, at: 0, x: route[0][0], z: route[0][1], phase: i * 1.7, speed: 1.1 + 0.2 * i });
});

// ---------------------------------------------------------------------------
// Camera and controls
// ---------------------------------------------------------------------------

three.camera.attach(hero.root, { offset: [0, 1.5, 0], distance: 7, lag: 0.08 });
three.camera.orbit(0, 20, 7);

const held = (k) => three.input.isDown(k);
const axis = (a, b) => (a.some(held) ? 1 : 0) - (b.some(held) ? 1 : 0);
const GRAV = 24, JUMP = 8.5;

three.setFixedLoop((dt) => {
	const run = held('shift') ? 1.7 : 1;
	const speed = 3.6 * run;
	const move = three.camera.planarMove(
		axis(['w', 'arrowup'], ['s', 'arrowdown']),
		axis(['d', 'arrowright'], ['a', 'arrowleft']),
	);
	const moving = move.length() > 0;
	if (moving) {
		// Turn toward the way we are going rather than snapping to it.
		const want = Math.atan2(move.x, move.z);
		me.heading += three.angleDelta(me.heading, want) * Math.min(1, dt * 14);
	}

	if (me.jump && me.grounded) { me.vy = JUMP; me.grounded = false; }
	me.jump = false;
	me.vy = Math.max(me.vy - GRAV * dt, -30);

	const r = three.moveAndSlide(
		[me.x, me.y + HEIGHT / 2, me.z],
		[move.x * speed * dt, me.vy * dt, move.z * speed * dt],
		MOVE,
	);
	me.x = r.position.x;
	me.y = r.position.y - HEIGHT / 2;
	me.z = r.position.z;
	if (r.grounded) { if (me.vy < 0) me.vy = 0; me.grounded = true; }
	else { me.grounded = false; if (me.vy > 0 && r.remaining.y > 1e-4) me.vy = 0; }
	if (me.y < -10) { me.x = 0; me.y = 1; me.z = 22; me.vy = 0; }

	me.walk += moving && me.grounded ? dt * 6.5 * run : 0;
	hero.root.position.set(me.x, me.y, me.z);
	hero.body.rotation.y = me.heading;
	swing(hero, me.walk, moving ? 0.7 : 0);
	hero.body.position.y = moving && me.grounded ? Math.abs(Math.sin(me.walk)) * 0.05 : 0;

	for (const f of folk) {
		const [tx, tz] = f.route[f.at];
		const dx = tx - f.x, dz = tz - f.z;
		const dist = Math.hypot(dx, dz);
		if (dist < 0.3) { f.at = (f.at + 1) % f.route.length; continue; }
		f.x += (dx / dist) * f.speed * dt;
		f.z += (dz / dist) * f.speed * dt;
		f.phase += dt * 5.5;
		f.p.root.position.set(f.x, Math.abs(Math.sin(f.phase)) * 0.04, f.z);
		f.p.body.rotation.y = Math.atan2(dx, dz);
		swing(f.p, f.phase, 0.6);
	}
});

// Edges are per frame; the fixed loop can run zero or several times in one.
three.setAnimationLoop(() => {
	if (three.input.pressed('space')) me.jump = true;
});

three.onKeyDown('p', () => {
	reliefOn = !reliefOn;
	applyRelief();
	console.log(reliefOn ? 'relief on' : 'relief off — the same surfaces, flat');
});
three.onKeyDown('l', () => {
	selfShadow = selfShadow > 0 ? 0 : 1;
	applyRelief();
	console.log(selfShadow ? 'relief self-shadow on' : 'relief self-shadow off');
});
three.onKeyDown('m', () => {
	steps = steps === 1 ? 2 : steps === 2 ? 0.5 : 1;
	applyRelief();
	console.log(`march steps x${steps}`);
});
three.onKeyDown('o', () => {
	three.light.shadow.enabled = !three.light.shadow.enabled;
	console.log(three.light.shadow.enabled ? 'shadow map on' : 'shadow map off');
});
three.onKeyDown('s', () => {
	const s = three.stats();
	console.log(`draws ${s.drawCalls} (+${s.shadowDraws} shadow) · ${s.triangles} tris · ${s.gpuMs.toFixed(2)} ms · ${reliefMaterials.length} relief materials`);
});

applyRelief();
console.log(`${lots.length} houses, ${reliefMaterials.length} relief materials`);
console.log('WASD walk · shift run · space jump · drag orbit · p relief · l self-shadow · m steps · o shadow map · s cost');
