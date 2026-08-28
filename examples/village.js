// village.js — a street of houses, a crowd of people, and nine textures that
// are arithmetic rather than files
//
// Run it:
//
//     ./build/three --script examples/village.js
//     ./build/three --script examples/village.js --mcp   # and attach an agent
//
// Once it is running: `space` holds the clock and `.` steps a held one by a
// single frame, `t` shows the swatch board, `d` toggles the shadow map, `n`
// re-rolls every texture from a new seed, and `s` prints what the frame costs.
//
// What it is here to show
// -----------------------
// **Nothing is loaded.** There is no .glb, no .png and no assets directory —
// every shape is one of the six parametric ones and every image is a
// `DataTexture` built by a loop in this file. The whole village is six
// geometries: a box, a pyramid, a cone, a rod, a ball and a quad.
//
// **Variety is scale and colour, not more assets.** Ten houses of ten
// different sizes are ten transforms of one unit box, so the walls are a
// single draw call and the roofs are another; `mesh.color` tints each one and
// costs nothing, because colour is a per-copy channel. `stats().assets` stays
// at six however many houses the loop builds.
//
// **The people are made of the same parts as the lamp posts.** A person is a
// ball, a rod for the body, four rods for the limbs and a cone for the hat —
// and a lamp post is a rod with a ball on top, so adding the lamps costs no
// new draw call at all. Limbs hang off Groups placed at the joint, which is
// what lets a rotation be a swing rather than a spin: `rotation.x` on a hip.
//
// **A map lives on a material, so an image is a bucket.** That is the whole
// reason the count sits where it does: nine textures over one quad is the
// nine draw calls of the swatch board, while ten houses over one box is one.
// Press `t` to put the board up and watch `drawCalls` move by nine.
//
// **Generated pixels are cheap to make and free to keep.** `n` throws the
// seed away and rebuilds all nine images — the grain of the plaster, the
// jitter of the cobbles, the tone of every brick and shingle. It is one
// `new three.DataTexture` per image and one `material.map =` per material;
// nothing is reloaded and no pipeline is rebuilt.
//
// The swatch board is the honest part of the demo: each panel shows one image
// laid on flat with `repeat = [1, 1]`, so what the ground and the roofs are
// tiling out of is visible next to them rather than only in a comment.

// ---------------------------------------------------------------------------
// Noise
//
// Everything below is a function of `seed`, so the same seed is the same
// village down to the last brick — which is what makes `n` a comparison and
// not just a shuffle.
// ---------------------------------------------------------------------------

const SIZE = 128;
let seed = 20260823;

// One integer in, one float in [0, 1) out. Math.imul because the products
// leave the range a double holds exactly, and a hash that rounds is a hash
// with visible structure in it.
function hash2(x, y, s) {
	let h = Math.imul(x | 0, 374761393) ^ Math.imul(y | 0, 668265263) ^ Math.imul(s | 0, 2246822519);
	h = Math.imul(h ^ (h >>> 13), 1274126177);
	return ((h ^ (h >>> 16)) >>> 0) / 4294967296;
}

function smooth(t) { return t * t * (3 - 2 * t); }
function lerp(a, b, t) { return a + (b - a) * t; }
function mix(a, b, t) { return [lerp(a[0], b[0], t), lerp(a[1], b[1], t), lerp(a[2], b[2], t)]; }
function clamp01(t) { return t < 0 ? 0 : t > 1 ? 1 : t; }
function step(lo, hi, x) { return smooth(clamp01((x - lo) / (hi - lo))); }
function tint(c, k) { return [c[0] * k, c[1] * k, c[2] * k]; }

// Value noise on a wrapping lattice. The wrap is the point: the grid indices
// are taken modulo the cell count, so the last column interpolates back into
// the first and the image tiles — which it has to, because the ground shows
// this one fifty-five times across.
function valueNoise(size, cellsX, cellsY, s) {
	const out = new Float32Array(size * size);
	for (let y = 0; y < size; y++) {
		const gy = (y / size) * cellsY;
		const y0 = Math.floor(gy);
		const fy = smooth(gy - y0);
		const ya = y0 % cellsY;
		const yb = (y0 + 1) % cellsY;
		for (let x = 0; x < size; x++) {
			const gx = (x / size) * cellsX;
			const x0 = Math.floor(gx);
			const fx = smooth(gx - x0);
			const xa = x0 % cellsX;
			const xb = (x0 + 1) % cellsX;
			out[y * size + x] = lerp(
				lerp(hash2(xa, ya, s), hash2(xb, ya, s), fx),
				lerp(hash2(xa, yb, s), hash2(xb, yb, s), fx),
				fy,
			);
		}
	}
	return out;
}

// Octaves, halving in amplitude and doubling in frequency. Three of them is
// the difference between plaster and a blur.
function fbm(size, cells, s, octaves) {
	const out = new Float32Array(size * size);
	let amp = 1;
	let total = 0;
	for (let o = 0; o < octaves; o++) {
		const layer = valueNoise(size, cells << o, cells << o, s + o * 101);
		for (let i = 0; i < out.length; i++) out[i] += layer[i] * amp;
		total += amp;
		amp *= 0.5;
	}
	for (let i = 0; i < out.length; i++) out[i] /= total;
	return out;
}

// Run a shader-shaped function over every texel and hand the result to the
// device. **Row 0 is the bottom row** — uv (0, 0) is the bottom-left corner,
// as it is in Three.js — which is why the window panes below brighten with y
// and the shingles overlap the way round they do.
function paint(size, shade) {
	const px = new Uint8Array(size * size * 4);
	for (let y = 0; y < size; y++) {
		for (let x = 0; x < size; x++) {
			const k = y * size + x;
			const c = shade(x, y, k);
			px[k * 4 + 0] = c[0] < 0 ? 0 : c[0] > 255 ? 255 : c[0];
			px[k * 4 + 1] = c[1] < 0 ? 0 : c[1] > 255 ? 255 : c[1];
			px[k * 4 + 2] = c[2] < 0 ? 0 : c[2] > 255 ? 255 : c[2];
			px[k * 4 + 3] = 255;
		}
	}
	return new three.DataTexture(px, size, size);
}

// ---------------------------------------------------------------------------
// The nine images
//
// One function, so that re-rolling is one call and the old set can be
// disposed as a set. Each is a colour map, so each is sRGB — which is the
// default, and the right one for anything an eye is meant to read as a
// picture.
// ---------------------------------------------------------------------------

function makeTextures(s) {
	const turf = fbm(SIZE, 10, s + 3, 3);
	const grass = paint(SIZE, (x, y, k) => {
		const c = mix([58, 88, 42], [116, 150, 70], turf[k]);
		const blade = hash2(x, y, s + 5);
		if (blade > 0.94) return [c[0] + 16, c[1] + 26, c[2] + 8];
		if (blade < 0.04) return [c[0] - 14, c[1] - 12, c[2] - 8];
		return c;
	});

	// Cobbles, from a jittered lattice: for each texel find the two nearest
	// stone centres, and call the place where they are equally near the gap
	// between the stones. The centres are jittered by a *wrapped* hash and
	// placed at an unwrapped index, which is what keeps the seam across the
	// tile boundary from being a straight line of mortar.
	const CELLS = 6;
	const cobble = paint(SIZE, (x, y) => {
		const gx = (x / SIZE) * CELLS;
		const gy = (y / SIZE) * CELLS;
		let d1 = 9;
		let d2 = 9;
		let id = 0;
		for (let oy = -1; oy <= 1; oy++) {
			for (let ox = -1; ox <= 1; ox++) {
				const cx = Math.floor(gx) + ox;
				const cy = Math.floor(gy) + oy;
				const wx = ((cx % CELLS) + CELLS) % CELLS;
				const wy = ((cy % CELLS) + CELLS) % CELLS;
				const px = cx + 0.2 + 0.6 * hash2(wx, wy, s + 13);
				const py = cy + 0.2 + 0.6 * hash2(wx, wy, s + 17);
				const d = Math.hypot(gx - px, gy - py);
				if (d < d1) { d2 = d1; d1 = d; id = wy * CELLS + wx; }
				else if (d < d2) { d2 = d; }
			}
		}
		const stone = step(0.03, 0.16, d2 - d1);
		const tone = 0.72 + 0.5 * hash2(id, id >> 3, s + 19);
		return mix([64, 62, 58], tint([124, 120, 114], tone), stone);
	});

	// A timber frame: beams around the edge and a cross through the middle,
	// with plaster between them. At repeat [1, 1] the beams land on the
	// corners of the wall, which is why the houses look framed rather than
	// wallpapered.
	const grain = fbm(SIZE, 8, s + 23, 3);
	const plaster = paint(SIZE, (x, y, k) => {
		const u = x / SIZE;
		const v = y / SIZE;
		const beam = u < 0.09 || u > 0.91 || v < 0.08 || v > 0.92
			|| Math.abs(u - 0.5) < 0.05 || Math.abs(v - 0.52) < 0.05;
		return beam
			? mix([76, 54, 38], [106, 78, 54], grain[k])
			: mix([228, 218, 198], [186, 174, 150], grain[k]);
	});

	const speck = fbm(SIZE, 16, s + 29, 2);
	const ROWS = 8;
	const ROWH = SIZE / ROWS;
	const BRICKW = SIZE / 4;
	const brick = paint(SIZE, (x, y, k) => {
		const r = Math.floor(y / ROWH);
		const cx = (x + ((r & 1) ? BRICKW / 2 : 0)) % SIZE;
		if ((y % ROWH) < 2.5 || (cx % BRICKW) < 2.5) return mix([172, 166, 154], [200, 194, 182], speck[k]);
		return tint(mix([150, 72, 56], [182, 104, 78], speck[k]), 0.82 + 0.32 * hash2(Math.floor(cx / BRICKW), r, s + 31));
	});

	// Courses of shingles, every other one offset by half a tile. The lip of
	// the course above throws a line of shade across the top of each tile,
	// and the cut sides are darker than the middle — two gradients, and the
	// roof stops being a flat orange triangle.
	const COURSES = 7;
	const COLS = 5;
	const CH = SIZE / COURSES;
	const CW = SIZE / COLS;
	const shingle = paint(SIZE, (x, y) => {
		const r = Math.floor(y / CH);
		const cx = (x + ((r & 1) ? CW / 2 : 0)) % SIZE;
		const u = (cx % CW) / CW;
		const v = (y % CH) / CH;
		const shade = (1 - 0.5 * step(0.84, 1, v)) * (0.55 + 0.45 * step(0.05, 0.14, Math.min(u, 1 - u)));
		return tint(mix([104, 58, 46], [158, 98, 72], hash2(Math.floor(cx / CW), r, s + 37)), shade);
	});

	// Planks, so the grain has to run the long way: the lattice is 40 cells
	// across and 4 down, which is a noise field stretched into stripes.
	const fibre = valueNoise(SIZE, 40, 4, s + 41);
	const PLANKW = SIZE / 4;
	const planks = paint(SIZE, (x, y, k) => {
		if ((x % PLANKW) < 2.5) return [46, 32, 22];
		return tint(mix([104, 72, 44], [148, 108, 68], fibre[k]), 0.85 + 0.3 * hash2(Math.floor(x / PLANKW), 0, s + 43));
	});

	// Not a hole in the wall: a frame, four panes, and a warm gradient with
	// the bright end at the top, which is enough to read as glass with a room
	// behind it under a light that never enters one.
	const glass = paint(SIZE, (x, y) => {
		const u = x / SIZE;
		const v = y / SIZE;
		const frame = u < 0.12 || u > 0.88 || v < 0.12 || v > 0.88
			|| Math.abs(u - 0.5) < 0.045 || Math.abs(v - 0.5) < 0.045;
		return frame ? [72, 50, 34] : mix([232, 198, 124], [252, 242, 202], v);
	});

	const clump = fbm(SIZE, 5, s + 47, 3);
	const leaves = paint(SIZE, (x, y, k) => {
		const c = mix([36, 70, 32], [100, 140, 58], clump[k]);
		return hash2(x, y, s + 53) > 0.9 ? [c[0], c[1] + 24, c[2]] : c;
	});

	// A four-texel over-under weave with a slub in it. Near white on purpose:
	// the clothes are tinted per person, and a tint multiplies.
	const slub = fbm(SIZE, 12, s + 59, 2);
	const linen = paint(SIZE, (x, y, k) => {
		const over = (((x >> 2) + (y >> 2)) & 1) !== 0;
		return tint(over ? [228, 224, 214] : [202, 196, 184], 0.9 + 0.2 * slub[k]);
	});

	return { grass, cobble, plaster, brick, shingle, planks, glass, leaves, linen };
}

// ---------------------------------------------------------------------------
// The scene
// ---------------------------------------------------------------------------

const scene = new three.Scene();
scene.background = 0x8fb4d8;
three.light.set([0.42, 0.86, 0.34], 0.34);

let tex = makeTextures(seed);

// Six geometries, and every shape in the village is one of them under a
// scale. Unit-sized on purpose: two boxes of different sizes are two assets
// and two draw calls, while one box under two scales is one of each.
const BOX = new three.BoxGeometry(1, 1, 1);
const PYRAMID = new three.ConeGeometry(1, 1, 4);
const CONE = new three.ConeGeometry(1, 1, 14);
const ROD = new three.CylinderGeometry(0.5, 0.5, 1, 12);
const BALL = new three.SphereGeometry(0.5, 16, 10);
const QUAD = new three.PlaneGeometry(1, 1);

// One material per image, because a map is a property of a material — and
// each carries its own tiling, which is the number that decides texel density
// on a surface of a given size.
const mat = {
	grass: new three.MeshLambertMaterial({ map: tex.grass }),
	cobble: new three.MeshLambertMaterial({ map: tex.cobble }),
	wall: new three.MeshLambertMaterial({ map: tex.plaster }),
	roof: new three.MeshLambertMaterial({ map: tex.shingle }),
	brick: new three.MeshLambertMaterial({ map: tex.brick }),
	wood: new three.MeshLambertMaterial({ map: tex.planks }),
	glass: new three.MeshLambertMaterial({ map: tex.glass }),
	leaf: new three.MeshLambertMaterial({ map: tex.leaves }),
	cloth: new three.MeshLambertMaterial({ map: tex.linen }),
	// No map at all — hands and faces are the per-copy tint on the flat
	// default, and share every batch the clothed parts do not.
	skin: new three.MeshLambertMaterial(),
};

// Only the ones that are not [1, 1]: a wall, a door and a window each show
// their image exactly once per face, which is what puts the timber frame on
// the corners of the wall rather than somewhere across it.
mat.grass.repeat = [55, 46];
mat.cobble.repeat = [3, 18];
mat.roof.repeat = [4, 2];
mat.brick.repeat = [1, 2];
mat.leaf.repeat = [2, 2];

// The ground and the street: two quads, and the tiling is what makes them
// ground rather than two smears. Without repeat a 128px image would be
// stretched across 110 world units.
const ground = new three.Mesh(QUAD, mat.grass);
ground.name = 'ground';
ground.rotation.x = -Math.PI / 2;
ground.scale.set(110, 92, 1);
scene.add(ground);

const street = new three.Mesh(QUAD, mat.cobble);
street.name = 'street';
street.rotation.x = -Math.PI / 2;
street.scale.set(6.5, 50, 1);
// A centimetre up, so the two surfaces are not coplanar — matching depths is
// a speckle rather than a decision.
street.position.y = 0.01;
scene.add(street);

// ---------------------------------------------------------------------------
// Houses
// ---------------------------------------------------------------------------

const WALL_TINTS = [0xfff4e4, 0xf3e3c9, 0xe9dec4, 0xdde7e4, 0xf2dacd, 0xe6e2d2];
const ROOF_TINTS = [0xffffff, 0xd9baa9, 0xc3d0c8, 0xe6c9a4, 0xb9a8a0];

function makeHouse(h) {
	const g = new three.Group();
	g.name = h.name;
	g.position.set(h.x, 0, h.z);
	g.rotation.y = h.facing;

	const walls = new three.Mesh(BOX, mat.wall);
	walls.scale.set(h.width, h.wallH, h.depth);
	walls.position.y = h.wallH / 2;
	walls.color = h.tint;
	g.add(walls);

	// A four-segment cone is a pyramid, and its base corners sit on the axes
	// — so it is turned an eighth of a turn to put its faces against the
	// walls. Its base then measures radius * sqrt(2) across, which is where
	// the 0.7071 comes from; the extra 0.6 is the eaves.
	const eaveW = h.width + 0.6;
	const eaveD = h.depth + 0.6;
	const roof = new three.Mesh(PYRAMID, mat.roof);
	roof.rotation.y = Math.PI / 4;
	roof.scale.set(eaveW * 0.7071, h.roofH, eaveD * 0.7071);
	roof.position.y = h.wallH + h.roofH / 2;
	roof.color = h.roofTint;
	g.add(roof);

	const door = new three.Mesh(BOX, mat.wood);
	door.name = 'door';
	door.scale.set(0.9, 1.75, 0.12);
	door.position.set(0, 0.875, h.depth / 2 + 0.01);
	g.add(door);

	const front = h.depth / 2 + 0.01;
	for (const dx of [-1, 1]) {
		const w = new three.Mesh(BOX, mat.glass);
		w.scale.set(0.78, 0.78, 0.1);
		w.position.set(dx * h.width * 0.3, 1.25, front);
		g.add(w);

		// And one in each gable end, which is the face the street sees of the
		// house next door.
		const side = new three.Mesh(BOX, mat.glass);
		side.scale.set(0.1, 0.72, 0.72);
		side.position.set(dx * (h.width / 2 + 0.01), 1.3, -h.depth * 0.18);
		g.add(side);
	}

	if (h.wallH > 3.1) {
		const attic = new three.Mesh(BOX, mat.glass);
		attic.scale.set(0.66, 0.66, 0.1);
		attic.position.set(0, h.wallH - 0.62, front);
		g.add(attic);
	}

	// Where the stack comes out is where the roof is, so ask the roof: a
	// pyramid falls off linearly from the apex, and the taller of the two
	// axes is the face this point is on. Buried to below the wall top and
	// clearing the slope by 0.8, so it reads as a chimney rather than as a
	// pole standing behind the house.
	const cx = h.width * 0.22;
	const cz = -h.depth * 0.16;
	const slope = h.roofH * (1 - Math.max(Math.abs(cx) / (eaveW / 2), Math.abs(cz) / (eaveD / 2)));
	const top = h.wallH + slope + 0.8;
	const base = h.wallH - 0.3;
	const chimney = new three.Mesh(BOX, mat.brick);
	chimney.scale.set(0.62, top - base, 0.62);
	chimney.position.set(cx, (top + base) / 2, cz);
	g.add(chimney);

	scene.add(g);
	return g;
}

const houses = [];
for (let row = 0; row < 2; row++) {
	for (let i = 0; i < 5; i++) {
		const r = (n) => hash2(i, row, seed + n);
		houses.push(makeHouse({
			name: `house_${row}_${i}`,
			x: row ? 7.6 : -7.6,
			z: -14 + i * 7 + (r(1) - 0.5) * 1.4,
			// Built facing +Z and turned to face the street, so both rows are
			// the same arithmetic with one number different.
			facing: row ? -Math.PI / 2 : Math.PI / 2,
			width: 3.6 + r(2) * 1.9,
			depth: 3.4 + r(3) * 1.5,
			wallH: 2.5 + r(4) * 1.3,
			roofH: 1.5 + r(5) * 1.2,
			tint: WALL_TINTS[Math.floor(r(6) * WALL_TINTS.length)],
			roofTint: ROOF_TINTS[Math.floor(r(7) * ROOF_TINTS.length)],
		}));
	}
}

// ---------------------------------------------------------------------------
// Trees and lamp posts
//
// The trunks are the rod the people's arms are made of and the lamps are the
// ball their heads are, so neither costs a bucket of its own.
// ---------------------------------------------------------------------------

for (let i = 0; i < 14; i++) {
	const r = (n) => hash2(i, 7, seed + n);
	const s = 0.75 + r(2) * 0.7;
	const g = new three.Group();
	g.name = `tree_${i}`;
	g.position.set((i & 1 ? 1 : -1) * (12 + r(1) * 5), 0, -18 + (i >> 1) * 5.4 + r(3) * 2);

	const trunk = new three.Mesh(ROD, mat.wood);
	trunk.scale.set(0.34 * s, 2.1 * s, 0.34 * s);
	trunk.position.y = 1.05 * s;
	g.add(trunk);

	const crown = new three.Mesh(CONE, mat.leaf);
	crown.scale.set(2 * s, 2.8 * s, 2 * s);
	crown.position.y = 3.2 * s;
	crown.color = mix([0.72, 0.94, 0.66], [1, 0.98, 0.84], r(4));
	g.add(crown);

	const top = new three.Mesh(CONE, mat.leaf);
	top.scale.set(1.4 * s, 2.1 * s, 1.4 * s);
	top.position.y = 4.6 * s;
	top.color = crown.color;
	g.add(top);

	scene.add(g);
}

for (let i = 0; i < 6; i++) {
	const g = new three.Group();
	g.name = `lamp_${i}`;
	g.position.set(i & 1 ? 4.4 : -4.4, 0, -13 + (i >> 1) * 11);

	const post = new three.Mesh(ROD, mat.skin);
	post.scale.set(0.13, 3.2, 0.13);
	post.position.y = 1.6;
	post.color = 0x3b3b42;
	g.add(post);

	const lamp = new three.Mesh(BALL, mat.skin);
	lamp.scale.set(0.34, 0.4, 0.34);
	lamp.position.y = 3.3;
	lamp.color = 0xffe6a4;
	g.add(lamp);

	scene.add(g);
}

// ---------------------------------------------------------------------------
// People
//
// Six parts each, and the limbs hang off Groups placed at the joint. That is
// the whole trick: `rotation.x` on a mesh spins it about its own middle, and
// on a Group at the hip it is a stride.
// ---------------------------------------------------------------------------

const SKINS = [0xf0c8a4, 0xe0aa80, 0xc08658, 0x8a5a3c, 0xf6d9bc];
const COATS = [0xa8443c, 0x3e5f8a, 0x4d7a4a, 0x8a6a2c, 0x6a4a7a, 0xb0763a, 0x37474f];
const HATS = [0x6d4c2f, 0x8a2f2f, 0x2f4858, 0xc8a24a];

function joint(x, y, len, thick, material, color) {
	const pivot = new three.Group();
	pivot.position.set(x, y, 0);
	const m = new three.Mesh(ROD, material);
	m.scale.set(thick, len, thick);
	m.position.y = -len / 2;
	m.color = color;
	pivot.add(m);
	return pivot;
}

function makePerson(p) {
	const g = new three.Group();
	g.name = p.name;
	g.position.set(p.x, 0, p.z);
	g.rotation.y = p.speed < 0 ? Math.PI : 0;

	const torso = new three.Mesh(ROD, mat.cloth);
	torso.scale.set(0.46, 0.62, 0.3);
	torso.position.y = 0.95;
	torso.color = p.coat;
	g.add(torso);

	const head = new three.Mesh(BALL, mat.skin);
	head.scale.set(0.34, 0.38, 0.32);
	head.position.y = 1.42;
	head.color = p.skin;
	g.add(head);

	if (p.hat >= 0) {
		const hat = new three.Mesh(CONE, mat.cloth);
		hat.scale.set(0.4, 0.32, 0.4);
		hat.position.y = 1.62;
		hat.color = HATS[p.hat];
		g.add(hat);
	}

	const legL = joint(-0.12, 0.64, 0.64, 0.17, mat.cloth, p.trousers);
	const legR = joint(0.12, 0.64, 0.64, 0.17, mat.cloth, p.trousers);
	const armL = joint(-0.27, 1.2, 0.58, 0.13, mat.skin, p.skin);
	const armR = joint(0.27, 1.2, 0.58, 0.13, mat.skin, p.skin);
	g.add(legL, legR, armL, armR);

	scene.add(g);
	return { ...p, group: g, legL, legR, armL, armR };
}

const people = [];
for (let i = 0; i < 16; i++) {
	const r = (n) => hash2(i, 11, seed + n);
	// Twelve walk the street in two lanes; the last four stand about outside
	// the houses and sway, which is what makes the walkers read as walking.
	const walking = i < 12;
	const lane = i & 1 ? 1 : -1;
	people.push(makePerson({
		name: `person_${i}`,
		x: walking ? lane * (1.3 + r(1) * 0.9) : lane * (5.2 + r(1) * 0.5),
		z: walking ? -18 + i * 3.1 : -9 + (i - 12) * 6.5 + r(2) * 2,
		speed: walking ? lane * (1.1 + r(3) * 0.9) : 0,
		cadence: 4.4 + r(4) * 2.4,
		phase: r(5) * Math.PI * 2,
		stride: walking ? 0.5 + r(6) * 0.28 : 0.06,
		skin: SKINS[Math.floor(r(7) * SKINS.length)],
		coat: COATS[Math.floor(r(8) * COATS.length)],
		trousers: COATS[Math.floor(r(9) * COATS.length)],
		hat: r(10) > 0.45 ? Math.floor(r(11) * HATS.length) : -1,
	}));
}

// ---------------------------------------------------------------------------
// The swatch board
//
// Nine panels at the end of the street, each showing one image at repeat
// [1, 1] — the pixels themselves rather than what tiling does to them. Nine
// maps is nine materials is nine draw calls, and that is the same rule that
// keeps ten houses at one.
// ---------------------------------------------------------------------------

const board = new three.Group();
board.name = 'swatches';
board.position.set(0, 0, -20.5);

const NAMES = ['grass', 'cobble', 'plaster', 'shingle', 'brick', 'planks', 'glass', 'leaves', 'linen'];
const swatchMats = NAMES.map((n) => new three.MeshLambertMaterial({ map: tex[n] }));

NAMES.forEach((n, i) => {
	const x = (i - (NAMES.length - 1) / 2) * 1.75;

	const panel = new three.Mesh(QUAD, swatchMats[i]);
	panel.name = `swatch_${n}`;
	panel.scale.set(1.55, 1.55, 1);
	panel.position.set(x, 2.1, 0);
	board.add(panel);

	const post = new three.Mesh(ROD, mat.wood);
	post.scale.set(0.12, 2.6, 0.12);
	post.position.set(x, 1.3, -0.06);
	board.add(post);
});

scene.add(board);

// ---------------------------------------------------------------------------
// The view
// ---------------------------------------------------------------------------

three.camera.lookAt(0, 2.2, -1);
three.camera.orbit(3, 14, 38);
three.light.shadow = { enabled: true, size: 2048 };

// ---------------------------------------------------------------------------

function report() {
	const s = three.stats();
	console.log(
		`draws ${s.drawCalls} (+${s.shadowDraws} shadow) · ${s.instances} instances · `
		+ `${s.assets} assets · ${s.textures} textures, ${(s.textureBytes / 1024).toFixed(0)} KiB · `
		+ `${s.triangles} tris · ${s.gpuMs.toFixed(2)} ms`
	);
}

// Throw the seed away and build all nine again. The materials keep their
// pipelines and their tiling — only the image behind each map changes — and
// the old textures are handed back once nothing names them.
function reroll() {
	const began = Date.now();
	const old = tex;
	seed = (seed * 1664525 + 1013904223) >>> 0;
	tex = makeTextures(seed);

	mat.grass.map = tex.grass;
	mat.cobble.map = tex.cobble;
	mat.wall.map = tex.plaster;
	mat.roof.map = tex.shingle;
	mat.brick.map = tex.brick;
	mat.wood.map = tex.planks;
	mat.glass.map = tex.glass;
	mat.leaf.map = tex.leaves;
	mat.cloth.map = tex.linen;
	NAMES.forEach((n, i) => { swatchMats[i].map = tex[n]; });

	for (const t of Object.values(old)) t.dispose();
	console.log(`seed ${seed} — nine images in ${Date.now() - began} ms`);
}

three.onKeyDown('space', () => {
	// One number holds the whole village: the crowd below stops because its
	// step is zero, and so would a clip, a body and a post pass — none of which
	// a flag in this file could ever have reached.
	three.clock.timeScale = three.clock.paused ? 1 : 0;
	console.log(three.clock.paused ? 'held' : 'running');
});
three.onKeyDown('.', () => {
	// A held clock moved by hand, one sixtieth at a time. It is the same amount
	// of world every press however long you wait between them, which is what
	// makes a paused scene something to step through rather than only to look
	// at — and what makes two screenshots of the same step the same picture.
	if (!three.clock.paused) return;
	three.clock.advance(three.clock.fixedDelta);
	console.log(`stepped to ${three.clock.time.toFixed(3)}s`);
});
three.onKeyDown('t', () => {
	board.visible = !board.visible;
	console.log(board.visible ? 'swatch board up' : 'swatch board down');
});
three.onKeyDown('d', () => {
	three.light.shadow.enabled = !three.light.shadow.enabled;
	console.log(three.light.shadow.enabled ? 'shadows on' : 'shadows off');
});
three.onKeyDown('n', () => reroll());
three.onKeyDown('s', () => report());

// The crowd walks in the *fixed* loop rather than the animation one, which is
// the shape a game wants and costs nothing to adopt here: it is called at
// `three.clock.fixedRate` with the same `dt` every time, however fast the
// frames happen to be arriving, so twelve walkers cover the same ground on a
// machine drawing at 30 as on one drawing at 144. The animation callback is for
// drawing the consequence; there is nothing to draw here that the scene graph
// does not already hold, so this file has only the one loop.
three.setFixedLoop((dt) => {
	const t = three.clock.time;

	for (const p of people) {
		const s = Math.sin(t * p.cadence + p.phase);
		if (p.speed !== 0) {
			p.z += p.speed * dt;
			if (p.z > 19) p.z -= 38;
			else if (p.z < -19) p.z += 38;
		}
		// One write rather than three: every component of a position flushes
		// to the host on its own, and sixteen people is enough for that to be
		// worth caring about.
		p.group.position.set(p.x, Math.abs(s) * (p.speed !== 0 ? 0.05 : 0.012), p.z);
		p.legL.rotation.x = s * p.stride;
		p.legR.rotation.x = -s * p.stride;
		p.armL.rotation.x = -s * p.stride * 0.8;
		p.armR.rotation.x = s * p.stride * 0.8;
	}
});

console.log(`${houses.length} houses, ${people.length} people, ${NAMES.length} generated images — seed ${seed}`);
console.log('space holds · . steps a held clock · t swatch board · d shadows · n re-roll · s the cost');
report();

three.debug.write({
	keys: {
		space: 'hold the clock',
		'.': 'step a held clock one frame',
		t: 'swatches',
		d: 'shadows',
		n: 're-roll textures',
		s: 'stats',
	},
	stats: three.stats(),
});
