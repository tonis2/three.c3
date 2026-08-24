// terrain_village.js — a village on a real height field, built for the MCP
//
// The four things the request asked for, one each:
//   height-field terrain   one three.Field, carved and flattened, as a
//                          three.TerrainGeometry (one asset, one draw call,
//                          heightAt/normalAt you can stand things on)
//   instanced house pieces every house is the same BOX/GABLE geometry under a
//                          scale, one textured material per piece — so all the
//                          walls are a draw call, all the roofs another
//   ground material layers three.LayeredMaterial over the terrain: a splat mask
//                          blends grass, dirt(PATH), rock(slopes) and water(the
//                          carved river) in one fragment function
//   light + shadows        three.light.set + three.light.shadow
//
//   Render a frame:
//   ./build/three --headless --script examples/terrain_village.js --screenshot out.png
//   or, live in the MCP:
//   (paste this file's body into three.run_script)

// ---------------------------------------------------------------------------
// Noise and paint — everything is arithmetic, so the file runs anywhere.
// ---------------------------------------------------------------------------
function hash2(x, y, s) {
	let h = Math.imul(x | 0, 374761393) ^ Math.imul(y | 0, 668265263) ^ Math.imul(s | 0, 2246822519);
	h = Math.imul(h ^ (h >>> 13), 1274126177);
	return ((h ^ (h >>> 16)) >>> 0) / 4294967296;
}
function smooth(t) { return t * t * (3 - 2 * t); }
function lerp(a, b, t) { return a + (b - a) * t; }
function mixc(a, b, t) { return [lerp(a[0], b[0], t), lerp(a[1], b[1], t), lerp(a[2], b[2], t)]; }
function clamp01(t) { return t < 0 ? 0 : t > 1 ? 1 : t; }
function step(lo, hi, x) { return smooth(clamp01((x - lo) / (hi - lo))); }
function tint(c, k) { return [c[0] * k, c[1] * k, c[2] * k]; }

function valueNoise(size, cellsX, cellsY, s) {
	const out = new Float32Array(size * size);
	for (let y = 0; y < size; y++) {
		const gy = (y / size) * cellsY, y0 = Math.floor(gy), fy = smooth(gy - y0);
		const ya = y0 % cellsY, yb = (y0 + 1) % cellsY;
		for (let x = 0; x < size; x++) {
			const gx = (x / size) * cellsX, x0 = Math.floor(gx), fx = smooth(gx - x0);
			const xa = x0 % cellsX, xb = (x0 + 1) % cellsX;
			out[y * size + x] = lerp(
				lerp(hash2(xa, ya, s), hash2(xb, ya, s), fx),
				lerp(hash2(xa, yb, s), hash2(xb, yb, s), fx), fy);
		}
	}
	return out;
}
function fbm(size, cells, s, octaves) {
	const out = new Float32Array(size * size);
	let amp = 1, total = 0;
	for (let o = 0; o < octaves; o++) {
		const layer = valueNoise(size, cells << o, cells << o, s + o * 101);
		for (let i = 0; i < out.length; i++) out[i] += layer[i] * amp;
		total += amp; amp *= 0.5;
	}
	for (let i = 0; i < out.length; i++) out[i] /= total;
	return out;
}
// Row 0 is the bottom row (uv (0,0) is bottom-left), as in Three.js.
function paint(size, shade) {
	const px = new Uint8Array(size * size * 4);
	for (let y = 0; y < size; y++) for (let x = 0; x < size; x++) {
		const k = y * size + x, c = shade(x, y, k);
		px[k * 4 + 0] = c[0] < 0 ? 0 : c[0] > 255 ? 255 : c[0];
		px[k * 4 + 1] = c[1] < 0 ? 0 : c[1] > 255 ? 255 : c[1];
		px[k * 4 + 2] = c[2] < 0 ? 0 : c[2] > 255 ? 255 : c[2];
		px[k * 4 + 3] = 255;
	}
	return new three.DataTexture(px, size, size);
}

// ---------------------------------------------------------------------------
// The height field and the layout. World is [-120, 120] on both axes.
// ---------------------------------------------------------------------------
const W = 240, D = 240, SEG = 128, WATER_Y = -1.1;

// A winding river on the east, a road down the middle, an east branch to a bridge.
// The control points are what the eye sees; `three.catmullRom` bends a smooth
// curve through them, and every consumer below (carve, mask, scatter-avoid,
// the water ribbon) uses the SAME smoothed path, so the mud is where the water
// is and the channel is as smooth as the curve it was carved with.
const riverCtrl = [[42, -120], [60, -70], [54, -20], [70, 30], [60, 80], [72, 120]];
const roadCtrl  = [[-2, -120], [-4, -60], [0, -20], [4, 20], [0, 60], [-2, 120]];
const eastRoadCtrl = [[2, -6], [18, -7], [34, -9], [58, -11], [78, -9]];
const river = three.catmullRom(riverCtrl, { samples: 8 });
const road = three.catmullRom(roadCtrl, { samples: 10 });
const eastRoad = three.catmullRom(eastRoadCtrl, { samples: 10 });

const bumps = (x, z) =>
	Math.sin(x * 0.030 + 1.3) * Math.cos(z * 0.026 - 0.8) * 3.2
	+ Math.sin(x * 0.014 - z * 0.010 + 2.1) * 2.6
	+ Math.cos(x * 0.021 + z * 0.031) * 1.1;

// Building sites (x, z, footprint w, d). The ground is levelled under each.
const SITES = [
	[-34, -46, 12, 10], [-18, -26, 11, 9], [-36, -10, 12, 10], [-16, 12, 11, 9],
	[-34, 32, 12, 10], [-16, 48, 10, 8], [-52, 18, 13, 10], [-56, -34, 12, 9],
	[20, -64, 11, 9], [34, 66, 12, 10],
	[-74, -6, 12, 10], [-80, -50, 11, 9], [-14, 82, 11, 9], [28, -42, 10, 8],
];

function segDist(px, pz, ax, az, bx, bz) {
	const dx = bx - ax, dz = bz - az, L = dx * dx + dz * dz;
	let t = L > 0 ? ((px - ax) * dx + (pz - az) * dz) / L : 0;
	t = Math.max(0, Math.min(1, t));
	return Math.hypot(px - (ax + dx * t), pz - (az + dz * t));
}
function nearPolyline(x, z, pts, w) {
	for (let i = 0; i < pts.length - 1; i++)
		if (segDist(x, z, pts[i][0], pts[i][1], pts[i + 1][0], pts[i + 1][1]) < w) return true;
	return false;
}
function polyDist(x, z, pts) {
	let m = 1e9;
	for (let i = 0; i < pts.length - 1; i++)
		m = Math.min(m, segDist(x, z, pts[i][0], pts[i][1], pts[i + 1][0], pts[i + 1][1]));
	return m;
}
function riverX(z) {
	// Rough river x at a given z, for placing the bridge.
	return 60 + 6 * Math.sin(z * 0.05) + 3 * Math.sin(z * 0.11);
}

const field = new three.Field({ width: W, depth: D, segments: SEG })
	.fill(bumps)
	.carve(river, 20, 8, 11)
	.carve(road, 7, 0.6, 3)
	.carve(eastRoad, 7, 0.6, 3);
for (const s of SITES) field.flatten({ x: s[0], z: s[1], width: s[2], depth: s[3] }, undefined, 4);

const terrain = new three.TerrainGeometry({ width: W, depth: D, segments: SEG, skirt: 6, heights: field });

// ---------------------------------------------------------------------------
// Textures.
// ---------------------------------------------------------------------------
const SIZE = 128;
function makeTextures(s) {
	const grassF = fbm(SIZE, 12, s + 3, 3);
	const grass = paint(SIZE, (x, y, k) => {
		const c = mixc([56, 96, 44], [130, 158, 74], grassF[k]);
		const b = hash2(x, y, s + 5);
		if (b > 0.93) return [c[0] + 12, c[1] + 22, c[2] + 6];
		if (b < 0.05) return [c[0] - 12, c[1] - 10, c[2] - 8];
		return c;
	});
	const dirtF = fbm(SIZE, 14, s + 9, 2);
	const dirt = paint(SIZE, (x, y, k) => tint(mixc([108, 84, 56], [150, 118, 76], dirtF[k]), 0.85 + 0.3 * hash2(x, y, s + 11)));
	const rockF = fbm(SIZE, 16, s + 13, 2);
	const rock = paint(SIZE, (x, y, k) => tint(mixc([104, 102, 96], [150, 148, 140], rockF[k]), 0.8 + 0.4 * hash2(x, y, s + 15)));
	const soilF = fbm(SIZE, 8, s + 17, 2);
	const soil = paint(SIZE, (x, y, k) => mixc([86, 74, 56], [120, 104, 78], soilF[k]));

	// Stone walls: courses of blocks with mortar, light grey.
	const wall = paint(SIZE, (x, y) => {
		const rowH = 10, row = Math.floor(y / rowH);
		const u = ((x / SIZE) + ((row & 1) ? 0.5 : 0)) % 1;
		const cols = 5, idx = Math.floor(u * cols), fu = (u * cols) % 1, fv = (y % rowH) / rowH;
		const mortar = fu < 0.06 || fu > 0.94 || fv < 0.12 || fv > 0.88;
		let v = mortar ? 0.52 : 0.66 + hash2(idx + 1, row + 1, s + 19) * 0.20;
		v += (hash2(x * 3, y * 7, s + 21) - 0.5) * 0.08;
		return [v * 150, v * 148, v * 142];
	});
	// Red shingles, every other course offset.
	const shingle = paint(SIZE, (x, y) => {
		const rowH = 10, row = Math.floor(y / rowH), fv = (y % rowH) / rowH;
		const u = ((x / SIZE) + ((row & 1) ? 0.5 : 0)) % 1;
		const cols = 6, idx = Math.floor(u * cols), fu = (u * cols) % 1;
		const gap = fu < 0.06;
		let v = gap ? 0.44 : (0.72 + hash2(idx + 3, row + 5, s + 23) * 0.22) * (0.72 + 0.34 * fv);
		v += (hash2(x * 5, y * 11, s + 25) - 0.5) * 0.05;
		return [v * 200, v * 96, v * 66];
	});
	// Brick, for chimneys.
	const brick = paint(SIZE, (x, y) => {
		const rowH = 12, row = Math.floor(y / rowH);
		const u = ((x / SIZE) + ((row & 1) ? 0.5 : 0)) % 1;
		const cols = 4, idx = Math.floor(u * cols);
		const mortar = ((u * cols) % 1) < 0.09 || (y % rowH) < 3;
		let v = mortar ? 0.6 : 0.74 + hash2(idx, row, s + 27) * 0.2;
		return [v * 176, v * 78, v * 60];
	});
	// Glass: a frame, four panes, a warm gradient.
	const glass = paint(SIZE, (x, y) => {
		const u = x / SIZE, v = y / SIZE;
		const frame = u < 0.13 || u > 0.87 || v < 0.13 || v > 0.87
			|| Math.abs(u - 0.5) < 0.05 || Math.abs(v - 0.5) < 0.05;
		return frame ? [70, 52, 38] : mixc([216, 184, 122], [240, 228, 198], v);
	});
	// Planks, grain running the long way.
	const fibre = valueNoise(SIZE, 48, 4, s + 29);
	const wood = paint(SIZE, (x, y, k) => {
		if ((x % (SIZE / 4)) < 3) return [52, 36, 24];
		return tint(mixc([120, 84, 50], [160, 116, 70], fibre[k]), 0.85 + 0.28 * hash2(Math.floor(x / (SIZE / 4)), 0, s + 31));
	});
	const leavesF = fbm(SIZE, 5, s + 33, 3);
	const leaves = paint(SIZE, (x, y, k) => {
		const c = mixc([34, 74, 34], [96, 138, 58], leavesF[k]);
		return hash2(x, y, s + 35) > 0.9 ? [c[0], c[1] + 22, c[2]] : c;
	});
	return { grass, dirt, rock, soil, wall, shingle, brick, glass, wood, leaves };
}

const tex = makeTextures(20260823);

// ---------------------------------------------------------------------------
// The ground material layers — one splat mask, four layers, one fragment body.
// ---------------------------------------------------------------------------
// Author the mask against the ACTUAL terrain (heightAt/normalAt are the same
// grid the mesh is built from), so the bands line up with what is drawn.
// 256 x 256 over a 240-unit field is ~0.94 units a cell — fine enough that a
// FEATHERED road edge spans a couple cells instead of landing on a hard boolean
// step, which is what a 128 mask can only do at 1.9 units.
const MSIZE = 256;
function buildSplat() {
	const px = new Uint8Array(MSIZE * MSIZE * 4);
	for (let y = 0; y < MSIZE; y++) {
		const v = y / MSIZE, z = -D / 2 + v * D;
		for (let x = 0; x < MSIZE; x++) {
			const u = x / MSIZE, wx = -W / 2 + u * W;
			const h = terrain.heightAt(wx, z);
			const n = terrain.normalAt(wx, z);
			const slope = 1 - n[1];
			// water where carved below the level; rock on slopes; dirt on paths; grass otherwise
			const water = clamp01((WATER_Y + 1 - h) * 4.0) * (1 - step(6, 13, polyDist(wx, z, river)));
			const rock = clamp01((slope - 0.32) * 3.5);
			// Dirt on the roads, feathered. polyDist is the distance to the
			// centreline; `1 - step(3.2, 6.0, d)` is a smooth band that is full
			// dirt within 3.2 units and fades to grass by 6.0 — a soft shoulder
			// instead of a hard 3.4-unit cut that shows its own mask grid.
			const rDist = Math.min(polyDist(wx, z, road), polyDist(wx, z, eastRoad));
			let d = 1 - step(3.2, 6.0, rDist);
			for (const s of SITES) if (Math.abs(wx - s[0]) < s[2] / 2 + 1 && Math.abs(z - s[1]) < s[3] / 2 + 1) d = Math.max(d, 0.8);
			d *= (1 - water) * (1 - rock);
			const grass = Math.max(0, Math.min(1, 1 - d - rock - water));
			const i = (y * MSIZE + x) * 4;
			px[i] = d * 255;            // r = dirt / path
			px[i + 1] = grass * 255;    // g = grass
			px[i + 2] = rock * 255;     // b = rock
			px[i + 3] = water * 255;    // a = water
		}
	}
	return new three.DataTexture(px, MSIZE, MSIZE, { colorSpace: three.LinearSRGBColorSpace });
}

const ground = new three.Mesh(terrain, new three.LayeredMaterial({
	map: tex.soil,
	mask: buildSplat(),
	layers: [
		{ name: 'grass', map: tex.grass, mask: 'g', uvScale: 20, blend: 'overlay', tint: [1.02, 1.08, 0.96] },
		{ name: 'dirt', map: tex.dirt, mask: 'r', uvScale: 12, blend: 'mix', tint: [1, 1, 1] },
		{ name: 'rock', map: tex.rock, mask: 'b', uvScale: 12, blend: 'mix', tint: [1, 1, 1] },
	],
}));
ground.name = 'ground';
const scene = new three.Scene();
scene.add(ground);
scene.background = 0x8fb6d8;
three.light.set([0.42, 0.86, 0.34], 0.46);
three.light.shadow = { enabled: true, size: 2048, distance: 260, bias: 0.0006 };

// ---------------------------------------------------------------------------
// Materials for the built pieces.
// ---------------------------------------------------------------------------
const BOX = new three.BoxGeometry(1, 1, 1);
const GABLE = new three.ConvexGeometry([
	[-0.5, 0, -0.5], [0.5, 0, -0.5], [-0.5, 0, 0.5], [0.5, 0, 0.5],
	[-0.5, 1, 0], [0.5, 1, 0],
]);
const CYL = new three.CylinderGeometry(0.5, 0.5, 1, 10);
const CONE = new three.ConeGeometry(0.5, 1, 10);
const BALL = new three.SphereGeometry(0.5, 12, 8);

const mat = {
	wall: new three.MeshLambertMaterial({ map: tex.wall }),
	roof: new three.MeshLambertMaterial({ map: tex.shingle }),
	brick: new three.MeshLambertMaterial({ map: tex.brick }),
	glass: new three.MeshLambertMaterial({ map: tex.glass }),
	wood: new three.MeshLambertMaterial({ map: tex.wood }),
	leaf: new three.MeshLambertMaterial({ map: tex.leaves }),
	flat: new three.MeshLambertMaterial(),
};
mat.wall.repeat = [2, 1];
mat.roof.repeat = [3, 2];
mat.brick.repeat = [1, 2];
mat.leaf.repeat = [2, 2];

// ---------------------------------------------------------------------------
// Houses — every house is the same geometry under a scale, one material each.
// ---------------------------------------------------------------------------
const WALL_TINTS = [0xf2e9dc, 0xe7e0d0, 0xd9dee0, 0xece2d4, 0xdfe5e2];
const ROOF_TINTS = [0xffffff, 0xd9b0a0, 0xc8b0a4, 0xe0baa0, 0xbfa090];
let wallCount = 0, roofCount = 0;
function house(site, seedN) {
	const [hx, hz, hw, hd] = site;
	const g = new three.Group();
	g.name = `house_${seedN}`;
	g.position.set(hx, terrain.heightAt(hx, hz), hz);
	g.rotation.y = hash2(seedN, 3, 7) * Math.PI * 2;

	const wallH = 2.6 + hash2(seedN, 4, 7) * 1.2;
	const roofH = 1.6 + hash2(seedN, 5, 7) * 1.0;
	const tint = WALL_TINTS[Math.floor(hash2(seedN, 6, 7) * WALL_TINTS.length)];
	const roofT = ROOF_TINTS[Math.floor(hash2(seedN, 7, 7) * ROOF_TINTS.length)];

	const walls = new three.Mesh(BOX, mat.wall);
	walls.scale.set(hw, wallH, hd); walls.position.y = wallH / 2; walls.color = tint;
	g.add(walls); wallCount++;

	const roof = new three.Mesh(GABLE, mat.roof);
	roof.scale.set(hw + 1.2, roofH, hd + 1.2); roof.position.y = wallH; roof.color = roofT;
	g.add(roof); roofCount++;

	const door = new three.Mesh(BOX, mat.wood);
	door.scale.set(0.9, 1.8, 0.12); door.position.set(0, 0.9, hd / 2 + 0.02);
	g.add(door);

	for (const dx of [-1, 1]) {
		const w = new three.Mesh(BOX, mat.glass);
		w.scale.set(0.8, 0.8, 0.1); w.position.set(dx * hw * 0.3, 1.35, hd / 2 + 0.02);
		g.add(w);
		const side = new three.Mesh(BOX, mat.glass);
		side.scale.set(0.1, 0.7, 0.7); side.position.set(dx * (hw / 2 + 0.02), 1.4, -hd * 0.18);
		g.add(side);
	}

	const cx = hw * 0.22, cz = -hd * 0.16;
	const top = wallH + roofH * 0.9, base = wallH - 0.2;
	const chimney = new three.Mesh(BOX, mat.brick);
	chimney.scale.set(0.6, top - base, 0.6); chimney.position.set(cx, (top + base) / 2, cz);
	g.add(chimney);

	scene.add(g);
	return g;
}
SITES.forEach((s, i) => house(s, i));

// ---------------------------------------------------------------------------
// A wooden bridge over the river, on the east road.
// ---------------------------------------------------------------------------
{
	const bz = -11, bx = riverX(bz), g = new three.Group();
	g.name = 'bridge';
	const bank = Math.max(terrain.heightAt(bx - 12, bz), terrain.heightAt(bx + 12, bz));
	g.position.set(bx, bank + 0.3, bz);
	g.rotation.y = Math.PI / 2;   // run across the river (river runs ~north-south)
	const deck = new three.Mesh(BOX, mat.wood);
	deck.scale.set(4.5, 0.4, 24); deck.position.y = 0.0; g.add(deck);
	for (const sz of [-11, 11]) for (const px of [-2, 2]) {
		const rail = new three.Mesh(BOX, mat.wood);
		rail.scale.set(0.22, 1.2, 0.22); rail.position.set(px, 1.0, sz); g.add(rail);
	}
	scene.add(g);
}

// ---------------------------------------------------------------------------
// Trees — scattered on the terrain by three.scatter, avoiding road + river.
// ---------------------------------------------------------------------------
{
	const spots = three.scatter({
		count: 260, seed: 20260823, onTerrain: terrain, spacing: 7,
		minHeight: 0.5, maxSlope: 24,
		avoid: [
			{ path: river, width: 26 }, { path: road, width: 12 },
			{ path: eastRoad, width: 12 },
			...SITES.map(s => ({ x: s[0], z: s[1], radius: Math.max(s[2], s[3]) * 0.8 })),
		],
	});
	const trees = new three.Group(); trees.name = 'trees'; scene.add(trees);
	spots.forEach((p, i) => {
		const s = 0.8 + hash2(i, 9, 5) * 0.7;
		const trunk = new three.Mesh(CYL, mat.wood);
		trunk.scale.set(0.44 * s, 2.4 * s, 0.44 * s); trunk.position.set(p.x, p.y + 1.2 * s, p.z);
		trees.add(trunk);
		if (hash2(i, 10, 5) < 0.5) {   // deciduous
			const crown = new three.Mesh(BALL, mat.leaf);
			crown.scale.set(3.4 * s, 3.0 * s, 3.4 * s); crown.position.set(p.x, p.y + 3.4 * s, p.z);
			crown.color = mixc([0.7, 0.95, 0.62], [1, 1, 0.85], hash2(i, 11, 5));
			trees.add(crown);
		} else {                        // conifer
			const crown = new three.Mesh(CONE, mat.leaf);
			crown.scale.set(3.0 * s, 5.2 * s, 3.0 * s); crown.position.set(p.x, p.y + 4.0 * s, p.z);
			crown.color = 0x2e5a2a;
			trees.add(crown);
		}
	});
}

// ---------------------------------------------------------------------------
// A few fences and sheep by the west houses.
// ---------------------------------------------------------------------------
{
	const fenceG = new three.Group(); fenceG.name = 'fences'; scene.add(fenceG);
	const c = [-20, 30];
	for (let i = 0; i < 16; i++) {
		const x = c[0] + (i - 3) * 1, z = c[1];
		const post = new three.Mesh(BOX, mat.wood);
		post.scale.set(0.3, 1.8, 0.3);
		post.position.set(x, terrain.heightAt(x, z) + 0.9, z);
		fenceG.add(post);
	}
	for (let i = 0; i < 4; i++) {
		const r = hash2(i, 21, 9);
		const s = new three.Group(); s.name = `sheep_${i}`;
		const b = new three.Mesh(BALL, mat.flat);
		b.scale.set(0.9, 0.9, 0.9); b.color = 0xf2f0ec; s.add(b);
		const hd = new three.Mesh(BALL, mat.flat);
		hd.scale.set(0.4, 0.4, 0.4); hd.position.set(0, 0.45, 0.7); hd.color = 0x3b332c; s.add(hd);
		const x = c[0] - 6 + r * 6, z = c[1] + 2 + hash2(i, 22, 9) * 3;
		s.position.set(x, terrain.heightAt(x, z) + 0.6, z);
		scene.add(s);
	}
}

// ---------------------------------------------------------------------------
// The river surface — a real water mesh, not a flat colour.
//
// A RibbonGeometry carries the whole river as ONE curved sheet following the
// smooth centreline (one draw call). The vertex body displaces the surface with
// a travelling wave, and the fragment body rebuilds the normal from the wave's
// derivatives, which is what makes the specular glints move. `bounds` is how far
// a vertex can be pushed, so culling never drops a crest.
// ---------------------------------------------------------------------------
const waterMat = new three.ShaderMaterial({
	uniforms: { t: 0, deep: [0.03, 0.09, 0.16], shallow: [0.08, 0.20, 0.30], sky: [0.55, 0.68, 0.80], sunDir: [0.42, 0.86, 0.34] },
	bounds: 0.6,
	vertex: `
		float3 wave(float2 p, float ph) {
			return float3(
				sin(p.x * 0.30 + ph * 0.9),
				sin(p.y * 0.46 - ph * 1.1),
				sin((p.x + p.y) * 0.19 + ph * 1.6));
		}
		void displace(inout Vertex v) {
			float2 p = float2(v.position.x, v.position.z);
			float3 w = wave(p, t * 0.55);
			v.position.y += w.x * 0.05 + w.y * 0.05 + w.z * 0.03;
		}`,
	fragment: `
		float3 shade(Surface s) {
			float2 p = s.position.xz;
			float3 w = wave(p, t * 0.55);
			float3 n = normalize(float3(w.x * 0.22 + w.z * 0.12, 1.0, w.y * 0.18 + w.z * 0.12));
			float crest = max(w.x * 0.4 + w.y * 0.35 + w.z * 0.25, 0.0);
			float3 base = lerp(deep, shallow, crest * 0.55);
			float spec = pow(max(dot(n, normalize(sunDir)), 0.0), 140.0);
			float grazing = pow(1.0 - max(n.y, 0.0), 4.0);
			return base * lambert(n)
				+ float3(0.80, 0.88, 0.96) * spec * 0.35
				+ sky * grazing * 0.18;
		}`,
});
const WATER_LEVEL = -0.55;
// A RibbonGeometry follows the smooth river centreline as ONE mesh — a curved
// sheet instead of the grid of squares this was, and the river's curve is as
// smooth as the carve that made the channel. It sits at WATER_LEVEL as a flat
// surface (a river is a plane, not a drape) and keeps the same water shader.
const waterGeo = new three.RibbonGeometry({
	path: riverCtrl, width: 18, y: WATER_LEVEL, columns: 4, samples: 16,
});
const waterGroup = new three.Group(); waterGroup.name = 'water'; scene.add(waterGroup);
const water = new three.Mesh(waterGeo, waterMat);
waterGroup.add(water);
const waterTiles = 1; // one curved sheet, not a tiled footprint

// ---------------------------------------------------------------------------
// A player you can walk around the village, with a third-person follow camera.
//
// WASD / arrow keys move the character relative to the camera; Q/E swing the
// camera left/right, R/F tilt it, the mouse wheel zooms, and moving the mouse
// looks around. The character stays on the height field (terrain.heightAt is the
// same grid the mesh is built from, so it rides the bumps), turns to face where
// it walks, and has a little walk cycle. Space jumps.
//
// The camera rides on it via three.camera.attach, which re-centres AFTER every
// animation/physics step, so the view is never a frame behind the feet; we take
// the turntable's hand off (controls.enabled = false) and steer it ourselves, so
// the mouse and our keys do not fight the drag-orbit.
// ---------------------------------------------------------------------------
function buildPlayer() {
	const g = new three.Group(); g.name = 'player';

	// A pivot for each limb so a leg/arm swings from the hip/shoulder, not its centre.
	function limb(parent, px, py, pz, w, h, d, color, matr) {
		const pivot = new three.Group(); pivot.position.set(px, py, pz);
		const m = new three.Mesh(new three.BoxGeometry(w, h, d), matr || mat.flat);
		m.position.y = -h / 2; m.color = color; pivot.add(m);
		parent.add(pivot); return pivot;
	}

	// Solid colours (mat.flat, no map) so the little villager reads as a clean
	// voxel figure instead of being covered in the foliage/plank textures.
	const torso = new three.Mesh(new three.BoxGeometry(0.62, 0.95, 0.36), mat.flat);
	torso.position.y = 1.28; torso.color = 0x8a5a36; g.add(torso);

	const rope = new three.Mesh(new three.BoxGeometry(0.64, 0.12, 0.38), mat.flat);
	rope.position.y = 0.86; rope.color = 0x5f4a2e; g.add(rope);

	const head = new three.Mesh(new three.BoxGeometry(0.46, 0.46, 0.46), mat.flat);
	head.position.y = 1.98; head.color = 0xe8c39e; g.add(head);

	const hat = new three.Mesh(new three.CylinderGeometry(0.42, 0.42, 0.08, 12), mat.flat);
	hat.position.y = 2.24; hat.color = 0xc9a24a; g.add(hat);
	const crown = new three.Mesh(new three.CylinderGeometry(0.20, 0.22, 0.22, 12), mat.flat);
	crown.position.y = 2.38; crown.color = 0xb8912f; g.add(crown);

	const legs = [
		limb(g, -0.17, 0.82, 0, 0.20, 0.82, 0.22, 0x3c2c1c, mat.flat),
		limb(g, 0.17, 0.82, 0, 0.20, 0.82, 0.22, 0x3c2c1c, mat.flat),
	];
	const arms = [
		limb(g, -0.41, 1.66, 0, 0.16, 0.74, 0.18, 0x6a4630, mat.flat),
		limb(g, 0.41, 1.66, 0, 0.16, 0.74, 0.18, 0x6a4630, mat.flat),
	];
	return { g, legs, arms, torso };
}

const P = buildPlayer();
const player = P.g; scene.add(player);

// Spawn on the main road near the village centre, facing north up the road.
const SPAWN = [0, 6];
player.position.set(SPAWN[0], terrain.heightAt(SPAWN[0], SPAWN[1]), SPAWN[1]);

// The character controller's state — camYaw is OUR copy, so W/S/A/D steer in the
// camera's frame. Degrees for yaw/pitch (orbit wants degrees), radians for heading.
const ctl = globalThis.__ctl = {
	camYaw: 0, camPitch: 14, dist: 10,
	speed: 8.5, heading: Math.PI, // heading=PI faces -Z (north, away from the camera)
	vy: 0, grounded: true, walkT: 0, moving: false,
};
const GRAV = 22, JUMP = 7.5;

function playerStep(dt) {
	// --- camera look ---
	// Mouse-look only while DRAGGING (a button is held) and the pointer is over the
	// window. This windowed host reports tiny nonzero pointer deltas every frame even
	// when the cursor is idle, and applying them unconditionally makes camYaw creep on
	// its own — the movement frame rotates under the character and W/A/S/D point in
	// changing directions. "Drag to orbit" is also this app's own convention, so tying
	// look to pointer.down reads as intended rather than surprising.
	const ptr = three.input.pointer;
	if (ptr.down) {
		ctl.camYaw -= ptr.dx * 0.24;
		ctl.camPitch += ptr.dy * 0.2;
	}
	ctl.camYaw += ((three.input.isDown('q') ? 1 : 0) - (three.input.isDown('e') ? 1 : 0)) * 120 * dt;
	ctl.camPitch += ((three.input.isDown('r') ? 1 : 0) - (three.input.isDown('f') ? 1 : 0)) * 60 * dt;
	ctl.camPitch = Math.max(-8, Math.min(84, ctl.camPitch));
	ctl.dist = Math.max(3, Math.min(26, ctl.dist + ptr.scroll));

	// Point the REAL camera wherever ctl.camYaw now is, so the view and the frame
	// WASD steers on stay the same thing. Without this the camera stayed where it
	// was last orbit()'d while the movement frame rotated away from it — which is
	// exactly why W/A/S/D could send the character off to one side after a turn.
	// (controls.enabled is false, so this is the only thing that moves the camera.)
	three.camera.orbit(ctl.camYaw, ctl.camPitch, ctl.dist);

	// --- move in the camera's frame: forward=( -sin,-cos ), right=( cos,-sin ) ---
	let f = 0, r = 0;
	if (three.input.isDown('w') || three.input.isDown('arrowup')) f += 1;
	if (three.input.isDown('s') || three.input.isDown('arrowdown')) f -= 1;
	if (three.input.isDown('d') || three.input.isDown('arrowright')) r += 1;
	if (three.input.isDown('a') || three.input.isDown('arrowleft')) r -= 1;
	const a = ctl.camYaw * Math.PI / 180, Fx = -Math.sin(a), Fz = -Math.cos(a), Rx = Math.cos(a), Rz = -Math.sin(a);
	let mx = Fx * f + Rx * r, mz = Fz * f + Rz * r;
	const len = Math.hypot(mx, mz);
	ctl.moving = len > 0;
	if (ctl.moving) {
		mx /= len; mz /= len;
		ctl.heading = Math.atan2(mx, mz);
		player.position.x += mx * ctl.speed * dt;
		player.position.z += mz * ctl.speed * dt;
		player.position.x = Math.max(-118, Math.min(118, player.position.x));
		player.position.z = Math.max(-118, Math.min(118, player.position.z));
	}
	player.rotation.y = ctl.heading;

	// --- vertical: ride the terrain, jump on space ---
	const ground = terrain.heightAt(player.position.x, player.position.z);
	if (ctl.grounded && three.input.isDown('space')) { ctl.vy = JUMP; ctl.grounded = false; }
	if (!ctl.grounded) {
		ctl.vy -= GRAV * dt;
		player.position.y += ctl.vy * dt;
		if (player.position.y <= ground) { player.position.y = ground; ctl.vy = 0; ctl.grounded = true; }
	} else {
		player.position.y = ground;
	}

	// --- a little walk cycle ---
	if (ctl.moving) ctl.walkT += dt * 10;
	const swing = ctl.moving ? Math.sin(ctl.walkT) * 0.55 : 0;
	P.legs[0].rotation.x = swing; P.legs[1].rotation.x = -swing;
	P.arms[0].rotation.x = -swing * 0.7; P.arms[1].rotation.x = swing * 0.7;
}

// One animation loop drives the waves AND the character.
three.setAnimationLoop(() => {
	waterMat.uniforms.t = three.clock.time;
	playerStep(three.clock.dt);
});

// Follow camera: it looks at the player and we steer its yaw/pitch/distance.
three.camera.attach(player, { offset: [0, 1.7, 0], distance: ctl.dist, lag: 0.12 });
three.controls.enabled = false;
three.camera.orbit(ctl.camYaw, ctl.camPitch);

// ---------------------------------------------------------------------------
// The view and one frame.
// ---------------------------------------------------------------------------
three.render(scene, three.camera);
three.unloadUnused();

const st = scene.stats();
console.log('terrain_village: ' + JSON.stringify({
	draws: st.drawCalls, shadow: st.shadowDraws, instances: st.instances,
	triangles: st.triangles, assets: st.assets, textures: st.textures,
	textureBytes: st.textureBytes, gpuMs: +st.gpuMs.toFixed(2), walls: wallCount, roofs: roofCount,
}));
return { stats: st, walls: wallCount, roofs: roofCount, player: player.position.toArray(), ctl };
