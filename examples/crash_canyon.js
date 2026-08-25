// crash_canyon.js — a Crash-Bandicoot-shaped level: a path through the hills
//
// The four things the request asked for, one each:
//   height-field hills     one three.Field whose height IS the distance to the
//                          path, so the canyon walls hug the corridor instead
//                          of being noise that happens to leave a gap
//   texture layers         three.LayeredMaterial over the terrain: one splat
//                          mask packed by three.Field.mask, four layers —
//                          flowers(r), gold grass(g), rock(b), gravel(a) —
//                          blended in a single generated fragment body
//   colliders              a real physics world: crates are dynamic boxes that
//                          stack and tumble, rocks are convex hulls, the kerb
//                          walls are static, the FLOOR IS THE TERRAIN — one
//                          `shape: 'heightfield'` body over the whole level —
//                          the player carries a kinematic capsule that shoves
//                          what it runs into, and the wumpa fruit are triggers
//   light + shadows        three.light.set + three.light.shadow, fitted close
//                          with `distance` so the path gets sharp shadows
//
//   Run it:
//   ./build/three --script examples/crash_canyon.js
//   One frame, no window:
//   ./build/three --headless --script examples/crash_canyon.js --screenshot out.png
//   Play it without a window — physics steps, the callback runs, keys latch:
//   ./build/three --headless --script examples/crash_canyon.js --frames 600 \
//       --screenshot run-%03d.png --every 120
//   Why are there no shadows:
//   ./build/three --headless --script examples/crash_canyon.js --frames 4 \
//       --screenshot shadow.png --camera 20,45,90
//   with `three.debug.view = 'shadow'` in the scene, or read
//   `three.light.shadow.fit` for the same answer as numbers
//
// ## Controls
//
//   W A S D / arrows   run (camera-relative)
//   Space              jump
//   J / K / shift      SPIN — the whole point. Breaks crates, and knocks
//                      anything with a body clean off the path
//   Q E                swing the camera        R F   tilt it
//   drag               look                    wheel zoom
//
// ## Why the controller is written here rather than being three.character()
//
// `three.character({ terrain })` is the built-in and is what a scene that only
// wants to walk around should use — this file's movement, look and walk cycle
// are deliberately the same idiom, down to the key table and `planarMove`.
// What it does not expose is `vy`, and two of the three things that make this
// feel like Crash write to it: bouncing off a crate you land on, and the little
// hop a TNT gives you. So the vertical half is spelled out here.

// ---------------------------------------------------------------------------
// Noise and paint. Everything is arithmetic, so the file runs anywhere.
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
function band(lo, hi, x) { return step(lo, (lo + hi) / 2, x) * (1 - step((lo + hi) / 2, hi, x)); }
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

// Row 0 is the BOTTOM row — uv (0,0) is bottom-left, as in Three.js. Every
// glyph below is written top-row-first and flipped on the way in, because a
// '?' authored upside down is the kind of thing you only notice on the crate.
const SIZE = 128;
function canvas(size, shade) {
	const px = new Uint8Array(size * size * 4);
	for (let y = 0; y < size; y++) for (let x = 0; x < size; x++) {
		const k = y * size + x, c = shade(x, y, k);
		px[k * 4 + 0] = c[0] < 0 ? 0 : c[0] > 255 ? 255 : c[0];
		px[k * 4 + 1] = c[1] < 0 ? 0 : c[1] > 255 ? 255 : c[1];
		px[k * 4 + 2] = c[2] < 0 ? 0 : c[2] > 255 ? 255 : c[2];
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
	q: ['  ####  ', ' ##  ## ', ' ##  ## ', '     ## ', '    ##  ', '   ##   ', '   ##   ', '        ', '   ##   ', '   ##   '],
	t: ['#####', '  #  ', '  #  ', '  #  ', '  #  '],
	n: ['#   #', '##  #', '# # #', '#  ##', '#   #'],
	skull: ['  ####  ', ' ###### ', '##.##.##', '########', ' ###### ', '  #  #  ', ' # ## # '],
};

// ---------------------------------------------------------------------------
// The world and the path.
//
// One curve is the whole level: the hills are built from the distance to it,
// the splat mask is banded by the distance to it, the kerb stones and the wall
// colliders are laid along it, and every crate, tent and pole is placed at a
// distance ALONG it. Author the curve, and everything else follows — which is
// the difference between moving a level and re-authoring one.
// ---------------------------------------------------------------------------
const W = 260, D = 260, SEG = 192;
const PATH_HALF = 6.3;    // the corridor floor is dead flat inside this
const KERB = 7.2;         // where the stone kerb sits
const WALK = 5.9;         // how far off the centreline the player may get

const PATH_CTRL = [
	[8, 138], [2, 112], [-14, 88], [-26, 60], [-20, 30],
	[0, 8], [18, -14], [26, -42], [12, -68], [-10, -90],
	[-20, -114], [-14, -140],
];
const PATH = three.catmullRom(PATH_CTRL, { samples: 8 });

// Arc length, so a set piece can be placed "62 units down the path" and stay
// where it was put when a control point moves.
const CUM = [0];
for (let i = 1; i < PATH.length; i++) {
	CUM.push(CUM[i - 1] + Math.hypot(PATH[i][0] - PATH[i - 1][0], PATH[i][1] - PATH[i - 1][1]));
}
const PATH_LEN = CUM[CUM.length - 1];

// Position, tangent and left-normal at `s` units along the path.
function along(s) {
	const t = Math.max(0, Math.min(PATH_LEN, s));
	let i = 1;
	while (i < CUM.length - 1 && CUM[i] < t) i++;
	const a = PATH[i - 1], b = PATH[i];
	const seg = Math.max(1e-6, CUM[i] - CUM[i - 1]);
	const k = (t - CUM[i - 1]) / seg;
	const tx = (b[0] - a[0]) / seg, tz = (b[1] - a[1]) / seg;
	return { x: lerp(a[0], b[0], k), z: lerp(a[1], b[1], k), tx, tz, nx: -tz, nz: tx, yaw: Math.atan2(tx, tz) };
}
// A point `off` units to the left of the centreline, `s` along it.
function onPath(s, off) {
	const p = along(s);
	return { x: p.x + p.nx * off, z: p.z + p.nz * off, yaw: p.yaw };
}

function segDist(px, pz, ax, az, bx, bz) {
	const dx = bx - ax, dz = bz - az, L = dx * dx + dz * dz;
	let t = L > 0 ? ((px - ax) * dx + (pz - az) * dz) / L : 0;
	t = t < 0 ? 0 : t > 1 ? 1 : t;
	return Math.hypot(px - (ax + dx * t), pz - (az + dz * t));
}
function polyDist(x, z) {
	let m = 1e9;
	for (let i = 1; i < PATH.length; i++) {
		const d = segDist(x, z, PATH[i - 1][0], PATH[i - 1][1], PATH[i][0], PATH[i][1]);
		if (d < m) m = d;
	}
	return m;
}
// The same walk, keeping the point — what the corridor fence pushes back along.
function nearestOnPath(x, z) {
	let best = { d: 1e9, x: 0, z: 0 };
	for (let i = 1; i < PATH.length; i++) {
		const ax = PATH[i - 1][0], az = PATH[i - 1][1], bx = PATH[i][0], bz = PATH[i][1];
		const dx = bx - ax, dz = bz - az, L = dx * dx + dz * dz;
		let t = L > 0 ? ((x - ax) * dx + (z - az) * dz) / L : 0;
		t = t < 0 ? 0 : t > 1 ? 1 : t;
		const px = ax + dx * t, pz = az + dz * t;
		const d = Math.hypot(x - px, z - pz);
		if (d < best.d) best = { d, x: px, z: pz };
	}
	return best;
}

// ---------------------------------------------------------------------------
// The height field.
//
// The canyon wall is a function of the distance to the path and nothing else,
// which is what makes it a canyon rather than terrain with a road on it. The
// noise is multiplied by how far out you already are, so it never intrudes on
// the corridor and the walls still read as rock rather than as a ramp.
// ---------------------------------------------------------------------------
function ridge(x, z) {
	return Math.sin(x * 0.045 + 1.1) * Math.cos(z * 0.038 - 0.6) * 2.6
		+ Math.sin(x * 0.021 - z * 0.017 + 2.3) * 3.6
		+ Math.cos(x * 0.031 + z * 0.027) * 1.7
		+ Math.sin(x * 0.083 + z * 0.061) * 0.8;
}
function hills(x, z) {
	const wall = Math.max(0, polyDist(x, z) - PATH_HALF - 1.6);
	const rise = Math.min(0.42 * wall + 0.0075 * wall * wall, 23);
	return Math.max(0, rise + ridge(x, z) * Math.min(1, wall / 7));
}

const field = new three.Field({ width: W, depth: D, segments: SEG }).fill(hills);
// Flat inside `half - feather` and blended out to `half`: the corridor floor is
// exactly 0 to KERB and a little past, then climbs into the wall.
field.stroke(PATH, 36, 0, 18 - PATH_HALF - 0.8);

// The tents stand off the path on the hillside, and a cone pitched on a slope
// reads as a sheet stuck through it — so their pads are levelled into the field
// BEFORE the terrain is built. Declared here rather than beside the tents for
// exactly that reason: the ground has to know first.
const TENTS = [
	{ s: 66, off: -16, mat: 'tentA', scale: 1.0 },
	{ s: 80, off: -21, mat: 'tentB', scale: 0.8 },
	{ s: 214, off: 17, mat: 'tentB', scale: 1.0 },
	{ s: 228, off: 22, mat: 'tentA', scale: 0.78 },
].map(t => {
	const at = onPath(t.s, t.off);
	return { ...t, x: at.x, z: at.z, yaw: at.yaw };
});
for (const t of TENTS) field.flatten({ x: t.x, z: t.z, width: 15 * t.scale, depth: 15 * t.scale }, undefined, 5);

// Three shelves off the path, for something to jump up onto.
const PLATFORMS = [
	{ s: 74, off: 0, w: 7, d: 7, top: 2.4 },
	{ s: 79, off: 0, w: 7, d: 7, top: 4.6 },
	{ s: 176, off: -4.4, w: 6, d: 9, top: 3.0 },
].map(p => {
	const at = onPath(p.s, p.off);
	return { ...p, x: at.x, z: at.z, yaw: at.yaw };
});

const terrain = new three.TerrainGeometry({ width: W, depth: D, segments: SEG, skirt: 8, heights: field });

// ---------------------------------------------------------------------------
// Textures — the Crash palette: ochre hills, purple flowers, warm crates.
// ---------------------------------------------------------------------------
function makeTextures(s) {
	const sandF = fbm(SIZE, 10, s + 3, 3);
	const sand = paint(SIZE, (x, y, k) => {
		const c = mixc([166, 106, 56], [214, 158, 96], sandF[k]);
		const b = hash2(x, y, s + 5);
		if (b > 0.965) return [c[0] + 26, c[1] + 22, c[2] + 18];   // grit
		if (b < 0.03) return [c[0] - 26, c[1] - 20, c[2] - 14];
		return c;
	});
	const gravelF = fbm(SIZE, 20, s + 7, 2);
	const gravel = paint(SIZE, (x, y, k) => {
		const c = mixc([132, 106, 78], [186, 158, 118], gravelF[k]);
		const b = hash2(x >> 1, y >> 1, s + 9);
		return b > 0.9 ? tint([158, 132, 100], 0.85 + b * 0.3) : c;
	});
	// Gold grass, not green — the hills in Crash's warp rooms are ochre.
	const grassF = fbm(SIZE, 11, s + 11, 3);
	const grass = paint(SIZE, (x, y, k) => {
		const c = mixc([150, 104, 30], [224, 176, 66], grassF[k]);
		const b = hash2(x, y, s + 13);
		if (b > 0.93) return [c[0] + 16, c[1] + 20, c[2] + 4];
		if (b < 0.06) return [c[0] - 20, c[1] - 18, c[2] - 8];
		return c;
	});
	const rockF = fbm(SIZE, 14, s + 17, 3);
	const rock = paint(SIZE, (x, y, k) => tint(mixc([104, 96, 86], [166, 158, 144], rockF[k]), 0.82 + 0.34 * hash2(x, y, s + 19)));

	// The gold grass again, with four-petal purple flowers scattered on it —
	// the mask decides WHERE the patches are, this decides what one looks like.
	const flowers = paint(SIZE, (x, y, k) => {
		const c = mixc([150, 104, 30], [214, 168, 62], grassF[k]);
		const cell = 21, cx = Math.floor(x / cell), cy = Math.floor(y / cell);
		const jx = cx * cell + 2 + Math.floor(hash2(cx, cy, s + 21) * 16);
		const jy = cy * cell + 2 + Math.floor(hash2(cx, cy, s + 23) * 16);
		const dx = x - jx, dy = y - jy;
		if (hash2(cx, cy, s + 25) < 0.52) return c;
		const petal = (Math.abs(dx) <= 2 && Math.abs(dy) <= 4) || (Math.abs(dx) <= 4 && Math.abs(dy) <= 2);
		if (!petal) return c;
		if (Math.abs(dx) <= 1 && Math.abs(dy) <= 1) return [250, 220, 128];   // the eye
		return hash2(cx, cy, s + 27) > 0.45 ? [104, 44, 150] : [172, 82, 202];
	});

	// One weathered boulder, filling the whole image — the kerb is a LINE OF
	// ROCKS and not a wall, so its texture must not carry a course of blocks
	// that tiles across a stone the size of a footstool.
	const bouldF = fbm(SIZE, 5, s + 47, 4);
	const bouldG = fbm(SIZE, 9, s + 51, 3);
	const boulder = paint(SIZE, (x, y, k) => {
		const c = mixc([98, 92, 84], [176, 168, 152], bouldF[k]);
		// A crack is where two octaves cross, not where a sine grid says so — a
		// grid on a boulder reads as brickwork however it is coloured.
		const seam = Math.abs(bouldF[k] - bouldG[k]);
		const pit = bouldG[k] < 0.24 ? 0.78 : 1;
		const v = (seam < 0.014 ? 0.62 : 1) * pit;
		return tint(c, v * (0.9 + 0.2 * hash2(x, y, s + 49)));
	});

	// Stone courses, for the castle and anything built.
	const stone = paint(SIZE, (x, y) => {
		const rowH = 16, row = Math.floor(y / rowH);
		const u = ((x / SIZE) + ((row & 1) ? 0.5 : 0)) % 1;
		const cols = 4, idx = Math.floor(u * cols), fu = (u * cols) % 1, fv = (y % rowH) / rowH;
		const mortar = fu < 0.05 || fu > 0.95 || fv < 0.1 || fv > 0.9;
		let v = mortar ? 0.5 : 0.68 + hash2(idx + 1, row + 1, s + 29) * 0.22;
		v += (hash2(x * 3, y * 7, s + 31) - 0.5) * 0.07;
		return [v * 168, v * 160, v * 146];
	});

	// Planks, grain the long way — poles, barrels, the crate carcass.
	const fibre = valueNoise(SIZE, 40, 5, s + 33);
	const plank = (base, hi) => (x, y, k) => {
		if ((x % (SIZE / 4)) < 3) return tint(base, 0.5);
		return tint(mixc(base, hi, fibre[k]), 0.86 + 0.26 * hash2(Math.floor(x / (SIZE / 4)), 0, s + 35));
	};
	const wood = paint(SIZE, plank([116, 78, 44], [166, 118, 66]));

	// A crate face: a plank field with a heavy frame, then whatever goes on it.
	function crateFace(base, hi, frame, draw) {
		const px = canvas(SIZE, (x, y, k) => {
			const e = 9;
			if (x < e || y < e || x >= SIZE - e || y >= SIZE - e) return tint(frame, 0.94 + 0.12 * hash2(x, y, s + 37));
			const board = Math.floor((y - e) / ((SIZE - 2 * e) / 4));
			if (((y - e) % ((SIZE - 2 * e) / 4)) < 2) return tint(frame, 0.8);
			return tint(mixc(base, hi, fibre[k]), 0.88 + 0.22 * hash2(board, x >> 3, s + 39));
		});
		if (draw) draw(px);
		return new three.DataTexture(px, SIZE, SIZE);
	}
	const crateWood = crateFace([150, 104, 52], [196, 148, 82], [96, 62, 32], null);
	const crateQuest = crateFace([150, 104, 52], [196, 148, 82], [96, 62, 32],
		px => { stamp(px, SIZE, GLYPH.q, 64, 62, 7, [40, 26, 12]); stamp(px, SIZE, GLYPH.q, 62, 64, 7, [248, 206, 62]); });
	const crateTnt = crateFace([176, 52, 40], [214, 84, 60], [96, 26, 20],
		px => {
			stamp(px, SIZE, GLYPH.t, 30, 64, 6, [24, 18, 16]);
			stamp(px, SIZE, GLYPH.n, 64, 64, 6, [24, 18, 16]);
			stamp(px, SIZE, GLYPH.t, 98, 64, 6, [24, 18, 16]);
		});
	const crateNitro = crateFace([34, 122, 58], [64, 168, 84], [18, 68, 34],
		px => stamp(px, SIZE, GLYPH.skull, 64, 64, 9, [236, 240, 232]));

	// Tent canvas: bold vertical stripes with a scalloped hem.
	const tentStripe = (a, b) => paint(SIZE, (x, y) => {
		const bandN = Math.floor((x / SIZE) * 8);
		const c = (bandN & 1) ? a : b;
		if (y < 10) return tint(c, 0.72);
		return tint(c, 0.92 + 0.16 * hash2(x >> 2, y >> 2, s + 41));
	});

	const leafF = fbm(SIZE, 6, s + 43, 3);
	const leaves = paint(SIZE, (x, y, k) => {
		const c = mixc([58, 82, 30], [116, 142, 52], leafF[k]);
		return hash2(x, y, s + 45) > 0.9 ? [c[0] + 14, c[1] + 20, c[2] + 6] : c;
	});

	return {
		sand, gravel, grass, rock, flowers, stone, boulder, wood, leaves,
		crateWood, crateQuest, crateTnt, crateNitro,
		tentA: tentStripe([54, 88, 168], [232, 228, 214]),
		tentB: tentStripe([186, 54, 62], [240, 216, 168]),
	};
}
const tex = makeTextures(20260825);

// ---------------------------------------------------------------------------
// The splat mask — four fields packed into one RGBA image by three.Field.mask.
//
// Authored against the ACTUAL terrain (heightAt and normalAt read the grid the
// mesh was built from), so a band that says "rock on the steep bits" lands on
// the steep bits that got drawn.
// ---------------------------------------------------------------------------
const MSEG = 192;
const opts = { width: W, depth: D, segments: MSEG };
const mGravel = new three.Field(opts);
const mGrass = new three.Field(opts);
const mRock = new three.Field(opts);
const mFlower = new three.Field(opts);
const flowerNoise = fbm(64, 4, 9901, 2);
{
	const side = mGravel.side;
	for (let j = 0; j < side; j++) {
		const z = mGravel.zAt(j);
		for (let i = 0; i < side; i++) {
			const x = mGravel.xAt(i);
			const at = j * side + i;
			const d = polyDist(x, z);
			const h = terrain.heightAt(x, z);
			const slope = 1 - terrain.normalAt(x, z)[1];

			// Rock takes the steep faces and the tops of the ridges.
			const rock = clamp01((slope - 0.46) * 3.4) * 0.95 + step(24, 32, h) * 0.3;
			// Gold grass starts just past the kerb.
			const grass = step(PATH_HALF + 1.5, PATH_HALF + 7, d) * (1 - clamp01(rock));
			// A gravel shoulder hugging the kerb line, on the path side.
			const gravel = band(PATH_HALF - 3.5, PATH_HALF + 3.5, d);
			// Flower patches: noise, but only where the grass actually won.
			const fx = Math.floor(((x + W / 2) / W) * 63), fz = Math.floor(((z + D / 2) / D) * 63);
			const patch = flowerNoise[Math.min(4095, fz * 64 + fx)];
			const flower = clamp01((patch - 0.50) * 6) * grass * (1 - clamp01(rock));

			mFlower.values[at] = flower;
			mGrass.values[at] = grass;
			mRock.values[at] = clamp01(rock);
			mGravel.values[at] = gravel;
		}
	}
}
const splat = three.Field.mask({ r: mFlower, g: mGrass, b: mRock, a: mGravel });

const ground = new three.Mesh(terrain, new three.LayeredMaterial({
	map: tex.sand,
	mask: splat,
	layers: [
		{ name: 'gravel', map: tex.gravel, mask: 'a', uvScale: 26, blend: 'mix' },
		{ name: 'grass', map: tex.grass, mask: 'g', uvScale: 34, blend: 'mix', tint: [1.04, 1.0, 0.9] },
		{ name: 'rock', map: tex.rock, mask: 'b', uvScale: 30, blend: 'mix' },
		{ name: 'flowers', map: tex.flowers, mask: 'r', uvScale: 20, blend: 'mix' },
	],
}));
ground.name = 'ground';
ground.static = true;

const scene = new three.Scene();
scene.add(ground);
scene.background = 0xd9702e;
// A HIGH sun, and the canyon is why. At 30 degrees of elevation a 20-unit wall
// throws a 35-unit shadow across a 17-unit corridor: the whole path sits in it,
// every object's own shadow lands inside a shadow, and the frame reads as one
// with no shadows in it at all. Around 58 degrees the path is lit and the
// crates, the fruit and the player each cast something you can see.
three.light.set([0.58, 1.05, -0.32], 0.36);
// `distance` beats `size`: the map covers a square this wide, so fitting it to
// the part of the level you can actually see is worth more than more texels.
three.light.shadow = { enabled: true, size: 2048, distance: 70, bias: 0.0004, intensity: 0.82 };

// ---------------------------------------------------------------------------
// Shared geometry and materials. One geometry under a scale, one material per
// look — so every kerb stone is one draw call and so is every crate of a kind.
// ---------------------------------------------------------------------------
const BOX = new three.BoxGeometry(1, 1, 1);
const CYL = new three.CylinderGeometry(0.5, 0.5, 1, 12);
const CONE = new three.ConeGeometry(0.5, 1, 14);
const BALL = new three.SphereGeometry(0.5, 12, 9);
const CAPS = new three.CylinderGeometry(0.36, 0.36, 1.8, 8);
const FRAG = new three.BoxGeometry(0.32, 0.32, 0.32);

const mat = {
	stone: new three.MeshLambertMaterial({ map: tex.stone }),
	boulder: new three.MeshLambertMaterial({ map: tex.boulder }),
	wood: new three.MeshLambertMaterial({ map: tex.wood }),
	leaf: new three.MeshLambertMaterial({ map: tex.leaves }),
	tentA: new three.MeshLambertMaterial({ map: tex.tentA }),
	tentB: new three.MeshLambertMaterial({ map: tex.tentB }),
	wood_c: new three.MeshLambertMaterial({ map: tex.crateWood }),
	quest_c: new three.MeshLambertMaterial({ map: tex.crateQuest }),
	tnt_c: new three.MeshLambertMaterial({ map: tex.crateTnt }),
	nitro_c: new three.MeshLambertMaterial({ map: tex.crateNitro }),
	flat: new three.MeshLambertMaterial(),
};
mat.stone.repeat = [3, 2];
mat.leaf.repeat = [2, 2];

const groups = {};
for (const name of ['kerb', 'scenery', 'debris', 'player']) {
	const g = new three.Group(); g.name = name; scene.add(g); groups[name] = g;
}

// ---------------------------------------------------------------------------
// The floor the SOLVER stands on: the terrain itself, as one collider.
//
// `shape: 'heightfield'` hands the solver the grid `TerrainGeometry` was built
// from, so a crate rests on exactly the surface `terrain.heightAt(x, z)`
// reports — on the path, on the shoulder, and on the hillside a spin knocked it
// up. One body, and the ground under it is the ground you can see.
//
// **This used to be thirteen invisible boxes**, a chain of overlapping 30x4x34
// slabs buried under the path, and the comment here used to explain why they
// overlapped (a seam is a hole a crate falls through) and why there could not
// be one big box (the broadphase refused a collider that size). Both of those
// problems are gone with the shape that was missing, and so is the constraint
// that shaped the level: the corridor is dead flat at y=0 because a flat floor
// is the only shape a chain of axis-aligned boxes can be, and it does not have
// to be any more.
// ---------------------------------------------------------------------------
three.physics.add(ground, { shape: 'heightfield', mass: 0, friction: 0.9, restitution: 0.02 });

// ---------------------------------------------------------------------------
// The kerb: stones you can see, walls you cannot.
//
// The stones are decoration and are spaced for the eye. The colliders are a
// separate, coarser chain of long boxes — one every ten units instead of one
// every three — because fifty static boxes hold a crate in just as well as two
// hundred do, and the solver walks all of them.
// ---------------------------------------------------------------------------
let kerbCount = 0;
for (let s = 1.5; s < PATH_LEN - 1.5; s += 2.7) {
	for (const side of [-1, 1]) {
		const jitter = hash2(s * 7 | 0, side, 3);
		const at = onPath(s, side * (KERB + jitter * 0.7));
		const st = new three.Mesh(BOX, mat.boulder);
		const h = 0.62 + hash2(s | 0, side, 11) * 0.55;
		st.scale.set(1.9 + hash2(s | 0, side, 13) * 0.7, h, 2.3 + hash2(s | 0, side, 17) * 0.7);
		// Seated: a third of every stone is in the ground, so the line reads as
		// rocks half-buried along the edge rather than as blocks set on top of it.
		st.position.set(at.x, h / 2 - h * 0.34, at.z);
		st.rotation.y = at.yaw + (hash2(s | 0, side, 19) - 0.5) * 0.55;
		st.rotation.z = (hash2(s | 0, side, 29) - 0.5) * 0.22;
		st.color = mixc([0.78, 0.76, 0.72], [1.1, 1.05, 0.98], hash2(s | 0, side, 23));
		st.static = true;
		groups.kerb.add(st);
		kerbCount++;
	}
}
let wallBodies = 0;
for (let s = 0; s < PATH_LEN; s += 9.5) {
	for (const side of [-1, 1]) {
		const at = onPath(s + 4.75, side * (KERB + 1.4));
		const w = new three.Mesh(BOX, mat.flat);
		w.scale.set(1.6, 4, 10.6);
		w.position.set(at.x, 1.6, at.z);
		w.rotation.y = at.yaw;
		w.visible = false;
		scene.add(w);
		three.physics.add(w, { shape: 'box', mass: 0, friction: 0.4, restitution: 0.1 });
		wallBodies++;
	}
}

// The jump-up shelves: seen, stood on, and solid to the crates.
for (const p of PLATFORMS) {
	// The block that actually holds things up, and the one the feet stand on.
	const m = new three.Mesh(BOX, mat.boulder);
	m.scale.set(p.w, p.top, p.d);
	m.position.set(p.x, p.top / 2, p.z);
	m.rotation.y = p.yaw;
	m.color = 0xd6c8ae;
	m.static = true;
	scene.add(m);   // body-backed: a child of the SCENE, never of a group
	three.physics.add(m, { shape: 'box', mass: 0, friction: 0.8, restitution: 0.05 });
	// A skirt of loose rock around the base, so a ledge reads as cut out of the
	// ground rather than as a crate the same colour as the hills.
	for (let k = 0; k < 7; k++) {
		const a = (k / 7) * Math.PI * 2 + p.yaw;
		const r = Math.max(p.w, p.d) * 0.52;
		const chunk = new three.Mesh(BOX, mat.boulder);
		const h = 0.7 + hash2(k, p.s | 0, 41) * 0.8;
		chunk.scale.set(1.5 + hash2(k, 1, 43) * 0.9, h, 1.4 + hash2(k, 2, 47) * 0.9);
		chunk.position.set(p.x + Math.cos(a) * r, h * 0.34, p.z + Math.sin(a) * r);
		chunk.rotation.y = a + hash2(k, 3, 53);
		chunk.color = mixc([0.8, 0.78, 0.72], [1.08, 1.02, 0.94], hash2(k, 4, 59));
		chunk.static = true;
		groups.scenery.add(chunk);
	}
}

// ---------------------------------------------------------------------------
// Rocks — a convex hull collider IS the geometry.
//
// `shape: 'hull'` runs the same collision::quickhull that built the
// ConvexGeometry, so the rock the solver sees is the rock that was drawn rather
// than a box around it. These are the obstacles that actually stop you.
// ---------------------------------------------------------------------------
const blockers = [];   // { x, z, r } — what the player's own fence pushes out of
function rockPoints(seed, r) {
	// A Fibonacci sphere with a jittered radius, squashed and lifted so the
	// flat bottom sits on the path. Evenly spread directions matter: sampling
	// the angles at random bunches them, and quickhull over a bunch of nearly
	// coplanar points answers with a plate rather than a rock.
	const pts = [], n = 22, phi = Math.PI * (3 - Math.sqrt(5));
	for (let i = 0; i < n; i++) {
		const y = 1 - (i / (n - 1)) * 2;
		const rad = Math.sqrt(Math.max(0, 1 - y * y));
		const a = phi * i;
		const k = r * (0.7 + hash2(seed, i, 11) * 0.55);
		pts.push([
			Math.cos(a) * rad * k,
			Math.max(-0.12, y) * k * 0.85 + r * 0.55,
			Math.sin(a) * rad * k,
		]);
	}
	return pts;
}
// Every one of these is a BLOCKER as well as a collider, so each has to fit
// inside the corridor with room for the player's own radius: `|off| + r*0.82 +
// 0.45` must stay under WALK, or the rock's push-out and the corridor's
// push-in fight each other and the character buzzes between them.
const ROCK_SHAPES = [0, 1, 2, 3, 4].map(i => new three.ConvexGeometry(rockPoints(i * 13 + 1, 1)));
const rockShape = seed => ROCK_SHAPES[Math.floor(hash2(seed, 5, 61) * ROCK_SHAPES.length) % ROCK_SHAPES.length];

const ROCKS = [
	{ s: 52, off: 2.4, r: 1.9 }, { s: 72, off: -2.6, r: 2.2 }, { s: 110, off: 2.8, r: 2.0 },
	{ s: 134, off: -2.0, r: 1.7 }, { s: 166, off: 2.6, r: 2.3 }, { s: 208, off: -2.8, r: 2.1 },
	{ s: 252, off: 2.2, r: 1.8 }, { s: 288, off: -2.4, r: 2.2 },
];
for (const r of ROCKS) {
	const reach = Math.abs(r.off) + r.r * 0.82 + 0.45;
	if (reach > WALK) throw new RangeError(`rock at s=${r.s} reaches ${reach.toFixed(2)} past the ${WALK} fence`);
}
ROCKS.forEach((r, i) => {
	const at = onPath(r.s, r.off);
	const m = new three.Mesh(rockShape(i), mat.boulder);
	m.scale.set(r.r, r.r * (0.85 + hash2(i, 7, 67) * 0.35), r.r);
	m.position.set(at.x, -0.15, at.z);
	m.rotation.y = hash2(i, 3, 29) * Math.PI * 2;
	m.color = mixc([0.82, 0.8, 0.76], [1.04, 1.0, 0.94], hash2(i, 5, 31));
	m.static = true;
	scene.add(m);   // body-backed, so not groups.scenery
	three.physics.add(m, { shape: 'hull', mass: 0, friction: 0.7, restitution: 0.1 });
	blockers.push({ x: at.x, z: at.z, r: r.r * 0.82 });
});

// Loose boulders out past the kerb. No body and no fence entry: they are on the
// hillside where nothing walks, and a collider there would only cost the solver
// a broad-phase entry to hold up nothing.
for (let s = 14; s < PATH_LEN - 14; s += 17) {
	for (const side of [-1, 1]) {
		if (hash2(s | 0, side, 67) < 0.45) continue;
		const off = side * (KERB + 2.5 + hash2(s | 0, side, 71) * 6);
		const at = onPath(s, off);
		const r = 1.1 + hash2(s | 0, side, 73) * 1.5;
		const m = new three.Mesh(rockShape((s | 0) * 7 + side), mat.boulder);
		m.scale.set(r, r * (0.7 + hash2(s | 0, side, 89) * 0.5), r);
		m.position.set(at.x, terrain.heightAt(at.x, at.z) - r * 0.35, at.z);
		m.rotation.y = hash2(s | 0, side, 79) * Math.PI * 2;
		m.color = mixc([0.8, 0.78, 0.74], [1.06, 1.0, 0.94], hash2(s | 0, side, 83));
		m.static = true;
		groups.scenery.add(m);
	}
}

// ---------------------------------------------------------------------------
// Crates.
//
// Every crate is a dynamic box: they stack, they tumble, and the player's
// capsule shoves them. Four kinds, and the kind decides what breaking it does.
// ---------------------------------------------------------------------------
const CRATE = 1.55;
const crateMat = { wood: mat.wood_c, quest: mat.quest_c, tnt: mat.tnt_c, nitro: mat.nitro_c };
const crates = [];
function crate(kind, x, z, level) {
	const m = new three.Mesh(BOX, crateMat[kind]);
	m.name = `${kind}_crate`;
	m.scale.set(CRATE, CRATE, CRATE);
	// **On the ground rather than at zero.** The corridor is flat at y=0 for most
	// of its width, but the stroke feathers out towards the kerb and a crate
	// placed at a hardcoded zero out there spawns with its lower half inside the
	// terrain — which the solver answers with a correction deep enough to throw
	// it forty units into the air. It was invisible while the floor was a chain
	// of boxes whose tops were all exactly 0; the heightfield collider is the
	// real ground, so the placement has to be too.
	// **A stack leaves six centimetres between crates.** Placed in exact contact
	// — `level * CRATE`, which is what this said — the solver resolves the
	// zero-depth pair on the first step by pushing the boxes apart, and a
	// three-high stack launches about thirty units into the air before it comes
	// back down and settles. Measured: seven crates moving on frame 4 and ten by
	// frame 20, against none at either with the gap. It costs nothing visually.
	m.position.set(x, terrain.heightAt(x, z) + CRATE / 2 + level * (CRATE + 0.06) + 0.02, z);
	scene.add(m);   // a body must be a child of the SCENE, not of a group
	three.physics.add(m, {
		shape: 'box',
		mass: kind === 'tnt' ? 5 : 3.4,
		friction: 0.85,
		restitution: 0.04,
	});
	const c = { m, kind, alive: true, fuse: -1 };
	crates.push(c);
	return c;
}
// The level's crate plan: `s` down the path, `off` across it, `stack` upward.
const CRATE_PLAN = [
	{ s: 40, off: -2.6, stack: ['wood'] }, { s: 40, off: 0, stack: ['quest'] }, { s: 40, off: 2.6, stack: ['wood'] },
	{ s: 60, off: -1.4, stack: ['wood', 'wood'] }, { s: 60, off: 1.4, stack: ['wood', 'quest'] },
	// s 80 was inside the second shelf — the platform at s 79 is 7 deep and its
	// top is 4.6, so a three-high stack spawned at 0.8, 2.4 and 3.9 was entirely
	// buried in it, and the solver answered that with a correction that threw all
	// three about thirty units into the air on the first frame.
	{ s: 90, off: 0, stack: ['wood', 'wood', 'quest'] },
	{ s: 98, off: -3.0, stack: ['tnt'] }, { s: 98, off: 3.0, stack: ['wood'] },
	{ s: 118, off: -2.2, stack: ['wood'] }, { s: 118, off: 0.4, stack: ['nitro'] }, { s: 118, off: 3.0, stack: ['wood'] },
	{ s: 140, off: 0, stack: ['quest', 'wood'] },
	{ s: 158, off: -2.8, stack: ['wood', 'tnt'] }, { s: 158, off: 2.8, stack: ['wood', 'wood'] },
	{ s: 178, off: 0, stack: ['wood'] },
	{ s: 198, off: -2.4, stack: ['wood', 'quest'] }, { s: 198, off: 2.4, stack: ['wood', 'wood'] },
	{ s: 218, off: 0, stack: ['nitro'] }, { s: 218, off: -3.4, stack: ['wood'] }, { s: 218, off: 3.4, stack: ['wood'] },
	{ s: 240, off: -1.6, stack: ['wood', 'wood', 'wood'] }, { s: 240, off: 1.6, stack: ['tnt'] },
	{ s: 262, off: 0, stack: ['quest'] },
	{ s: 280, off: -2.6, stack: ['wood'] }, { s: 280, off: 0, stack: ['wood'] }, { s: 280, off: 2.6, stack: ['wood'] },
	{ s: 298, off: 0, stack: ['quest', 'wood'] },
];
for (const plan of CRATE_PLAN) {
	if (plan.s > PATH_LEN - 12) continue;
	const at = onPath(plan.s, plan.off);
	plan.stack.forEach((kind, level) => crate(kind, at.x, at.z, level));
}

// ---------------------------------------------------------------------------
// Wumpa fruit — trigger volumes.
//
// A trigger has a collider and takes part in the overlap test, but produces no
// response: three.onTrigger says when the player's capsule is inside one. That
// is the whole pickup, and it is the physics world doing the work rather than a
// distance check in the frame loop.
// ---------------------------------------------------------------------------
const wumpa = [];
function addWumpa(x, y, z) {
	const g = new three.Mesh(BALL, mat.flat);
	g.name = 'wumpa';
	g.scale.set(0.72, 0.86, 0.72);
	g.position.set(x, y, z);
	g.color = 0xff8c1a;
	scene.add(g);
	const leaf = new three.Mesh(BOX, mat.flat);
	leaf.scale.set(0.1, 0.26, 0.34); leaf.position.set(0, 0.5, 0.08); leaf.color = 0x2f7a34;
	g.add(leaf);
	three.physics.add(g, { shape: 'sphere', mass: 0, trigger: true });
	wumpa.push({ m: g, alive: true, phase: wumpa.length * 0.7 });
}
for (let s = 34; s < PATH_LEN - 12; s += 11) {
	const swing = Math.sin(s * 0.09) * 3.4;
	const at = onPath(s, swing);
	addWumpa(at.x, 1.35, at.z);
}

// ---------------------------------------------------------------------------
// Scenery: tents on the shoulder, bunting between poles, dry bushes on the
// hills, and a castle wall closing the far end.
// ---------------------------------------------------------------------------
function tent(t) {
	const material = mat[t.mat], scale = t.scale;
	const g = new three.Group();
	g.position.set(t.x, terrain.heightAt(t.x, t.z) - 0.3, t.z);
	g.rotation.y = t.yaw;
	const top = new three.Mesh(CONE, material);
	top.scale.set(7.4 * scale, 5.2 * scale, 7.4 * scale);
	top.position.y = 2.6 * scale;
	g.add(top);
	const pole = new three.Mesh(CYL, mat.wood);
	pole.scale.set(0.22, 9 * scale, 0.22); pole.position.y = 4.5 * scale;
	g.add(pole);
	const flag = new three.Mesh(BOX, mat.flat);
	flag.scale.set(0.06, 0.7, 1.3); flag.position.set(0, 8.4 * scale, 0.65);
	flag.color = 0xf2c53a;
	g.add(flag);
	g.static = true;
	groups.scenery.add(g);
}
TENTS.forEach(tent);

// Bunting: poles down one side with a sagging line of little flags.
{
	const BUNT = [0xe8542f, 0xf2c53a, 0x3f7fd0, 0xe9e3d2, 0x8b46b0];
	for (let s = 30; s < PATH_LEN - 30; s += 44) {
		const a = onPath(s, KERB + 1.2), b = onPath(s + 22, KERB + 1.2);
		for (const at of [a, b]) {
			const pole = new three.Mesh(CYL, mat.wood);
			pole.scale.set(0.26, 6.4, 0.26);
			pole.position.set(at.x, 3.0, at.z);
			pole.static = true;
			groups.scenery.add(pole);
		}
		for (let k = 1; k < 10; k++) {
			const t = k / 10;
			const at = onPath(s + 22 * t, KERB + 1.2);
			const sag = Math.sin(t * Math.PI) * 1.1;
			const f = new three.Mesh(BOX, mat.flat);
			f.scale.set(0.5, 0.6, 0.06);
			f.position.set(at.x, 5.6 - sag, at.z);
			f.rotation.y = at.yaw;
			f.color = BUNT[k % BUNT.length];
			f.static = true;
			groups.scenery.add(f);
		}
	}
}

// Dry bushes and the odd dead tree, scattered on the hills and kept off the path.
{
	const spots = three.scatter({
		count: 220, seed: 20260825, onTerrain: terrain, spacing: 6,
		minHeight: 1.5, maxSlope: 34,
		avoid: [{ path: PATH, width: 24 }],
	});
	spots.forEach((p, i) => {
		const s = 0.7 + hash2(i, 9, 5) * 0.8;
		if (hash2(i, 10, 5) < 0.88) {
			const bush = new three.Mesh(BALL, mat.leaf);
			bush.scale.set(2.2 * s, 1.5 * s, 2.2 * s);
			bush.position.set(p.x, p.y + 0.5 * s, p.z);
			bush.color = mixc([0.98, 0.94, 0.58], [1.2, 1.12, 0.78], hash2(i, 11, 5));
			bush.static = true;
			groups.scenery.add(bush);
		} else {
			const trunk = new three.Mesh(CYL, mat.wood);
			trunk.scale.set(0.4 * s, 3.4 * s, 0.4 * s);
			trunk.position.set(p.x, p.y + 1.7 * s, p.z);
			trunk.static = true;
			groups.scenery.add(trunk);
			const crown = new three.Mesh(CONE, mat.leaf);
			crown.scale.set(2.7 * s, 3.2 * s, 2.7 * s);
			crown.position.set(p.x, p.y + 3.7 * s, p.z);
			crown.color = 0xc9b95e;
			crown.static = true;
			groups.scenery.add(crown);
		}
	});
}

// The castle at the far end — a wall across the canyon with an arch over the
// path, two towers, and a keep behind it that only ever reads as a silhouette.
{
	const end = along(PATH_LEN - 16);
	const g = new three.Group();
	g.position.set(end.x, 0, end.z);
	g.rotation.y = end.yaw;
	const wallH = 11;
	for (const side of [-1, 1]) {
		const w = new three.Mesh(BOX, mat.stone);
		w.scale.set(26, wallH, 4.5);
		w.position.set(side * 20, wallH / 2, 0);
		g.add(w);
		const tower = new three.Mesh(CYL, mat.stone);
		tower.scale.set(7.5, wallH + 7, 7.5);
		tower.position.set(side * 8.5, (wallH + 7) / 2, 0);
		g.add(tower);
		const cap = new three.Mesh(CONE, mat.flat);
		cap.scale.set(9, 5, 9);
		cap.position.set(side * 8.5, wallH + 7 + 2.5, 0);
		cap.color = 0x8d4a3a;
		g.add(cap);
	}
	const lintel = new three.Mesh(BOX, mat.stone);
	lintel.scale.set(13, 4, 4.5);
	lintel.position.set(0, wallH - 2, 0);
	g.add(lintel);
	for (let i = -9; i <= 9; i += 3) {
		const x = i * 2.4;
		if (Math.abs(x) < 9) continue;   // the gateway is under here
		const merlon = new three.Mesh(BOX, mat.stone);
		merlon.scale.set(1.6, 1.8, 4.5);
		merlon.position.set(x, wallH + 0.9, 0);
		g.add(merlon);
	}
	const keep = new three.Mesh(BOX, mat.stone);
	keep.scale.set(22, 26, 16);
	keep.position.set(0, 13, -22);
	keep.color = 0x9a8f80;
	g.add(keep);
	g.static = true;
	groups.scenery.add(g);
}

// ---------------------------------------------------------------------------
// The player.
//
// A voxel bandicoot: orange, cream muzzle, blue jeans, big shoes. The pivots
// are Groups so a limb swings from the hip rather than from its own middle, and
// `spinner` is a Group of its own INSIDE the heading — so the spin turns the
// body without the controller's `rotation.y = heading` fighting it.
// ---------------------------------------------------------------------------
function limb(parent, px, py, pz, w, h, d, color) {
	const pivot = new three.Group(); pivot.position.set(px, py, pz);
	const m = new three.Mesh(BOX, mat.flat);
	m.scale.set(w, h, d); m.position.y = -h / 2; m.color = color;
	pivot.add(m);
	parent.add(pivot);
	return pivot;
}
function buildPlayer() {
	const g = new three.Group(); g.name = 'crash';
	const spinner = new three.Group(); g.add(spinner);

	const FUR = 0xe8631a, CREAM = 0xf6dcae, JEANS = 0x2f4fa8, SHOE = 0x6b3a1c;

	const torso = new three.Mesh(BOX, mat.flat);
	torso.scale.set(0.66, 0.78, 0.42); torso.position.y = 1.24; torso.color = FUR;
	spinner.add(torso);
	const belly = new three.Mesh(BOX, mat.flat);
	belly.scale.set(0.44, 0.56, 0.1); belly.position.set(0, 1.2, 0.2); belly.color = CREAM;
	spinner.add(belly);

	const head = new three.Mesh(BOX, mat.flat);
	head.scale.set(0.58, 0.5, 0.5); head.position.y = 1.86; head.color = FUR;
	spinner.add(head);
	const muzzle = new three.Mesh(BOX, mat.flat);
	muzzle.scale.set(0.34, 0.26, 0.24); muzzle.position.set(0, 1.76, 0.3); muzzle.color = CREAM;
	spinner.add(muzzle);
	const nose = new three.Mesh(BOX, mat.flat);
	nose.scale.set(0.16, 0.13, 0.1); nose.position.set(0, 1.82, 0.42); nose.color = 0x201a16;
	spinner.add(nose);
	for (const dx of [-1, 1]) {
		const eye = new three.Mesh(BOX, mat.flat);
		eye.scale.set(0.14, 0.17, 0.06); eye.position.set(dx * 0.14, 1.99, 0.26); eye.color = 0xf4f2ec;
		spinner.add(eye);
		const pupil = new three.Mesh(BOX, mat.flat);
		pupil.scale.set(0.06, 0.09, 0.05); pupil.position.set(dx * 0.14, 1.98, 0.29); pupil.color = 0x1c2a18;
		spinner.add(pupil);
		const ear = new three.Mesh(BOX, mat.flat);
		ear.scale.set(0.1, 0.2, 0.16); ear.position.set(dx * 0.27, 2.16, -0.02); ear.color = FUR;
		spinner.add(ear);
	}
	for (let i = 0; i < 3; i++) {
		const spike = new three.Mesh(CONE, mat.flat);
		spike.scale.set(0.2, 0.34, 0.2);
		spike.position.set((i - 1) * 0.17, 2.18, -0.06 - Math.abs(i - 1) * 0.03);
		spike.rotation.x = -0.3;
		spike.color = 0x7b3f16;
		spinner.add(spike);
	}

	const legs = [
		limb(spinner, -0.18, 0.86, 0, 0.24, 0.72, 0.26, JEANS),
		limb(spinner, 0.18, 0.86, 0, 0.24, 0.72, 0.26, JEANS),
	];
	const arms = [
		limb(spinner, -0.44, 1.56, 0, 0.18, 0.62, 0.2, FUR),
		limb(spinner, 0.44, 1.56, 0, 0.18, 0.62, 0.2, FUR),
	];
	legs.forEach((p, i) => {
		const shoe = new three.Mesh(BOX, mat.flat);
		shoe.scale.set(0.34, 0.24, 0.5); shoe.position.set(0, -0.82, 0.1); shoe.color = SHOE;
		p.add(shoe);
	});
	arms.forEach(p => {
		const hand = new three.Mesh(BOX, mat.flat);
		hand.scale.set(0.22, 0.2, 0.22); hand.position.y = -0.7; hand.color = CREAM;
		p.add(hand);
	});
	return { g, spinner, legs, arms };
}

const P = buildPlayer();
groups.player.add(P.g);

// The capsule the SOLVER sees. Kinematic, so the script owns its transform and
// the solver still pushes everything it touches — which is what makes running
// through a stack of crates scatter them.
const capsule = new three.Mesh(CAPS, mat.flat);
capsule.name = 'player_body';
capsule.visible = false;
scene.add(capsule);
three.physics.add(capsule, { shape: 'capsule', mass: 0, kinematic: true, friction: 0.4 });

const START_S = 26;
const start = along(START_S);
const spawnDir = along(START_S + 2);
const ctl = globalThis.__crash = {
	x: start.x, z: start.z, y: 0,
	yaw: (Math.atan2(spawnDir.tx, spawnDir.tz) * 180) / Math.PI + 180,
	pitch: 21, dist: 13,
	heading: Math.atan2(spawnDir.tx, spawnDir.tz),
	vy: 0, grounded: true, coyote: 0, walkT: 0, moving: false,
	spin: 0, spinCool: 0, spinAngle: 0,
	broken: 0, fruit: 0, travelled: 0,
};
const SPEED = 12.5, JUMP = 9.4, GRAV = 26, SPIN_TIME = 0.42, SPIN_R = 2.7;

// ---------------------------------------------------------------------------
// Debris: a pool of chips, thrown by hand rather than given bodies.
//
// A broken crate wants twelve chunks for half a second. Twelve bodies added and
// removed per crate would churn the world for something that never needs to be
// collided with — so these are integrated in the frame loop and parked when
// their life runs out. The pool is fixed, so a busy explosion reuses the
// oldest chip instead of allocating.
// ---------------------------------------------------------------------------
const chips = [];
for (let i = 0; i < 80; i++) {
	const m = new three.Mesh(FRAG, mat.wood_c);
	m.visible = false;
	groups.debris.add(m);
	chips.push({ m, life: 0, vx: 0, vy: 0, vz: 0, sx: 0, sz: 0 });
}
let chipAt = 0;
function burst(x, y, z, color, n, power) {
	for (let i = 0; i < n; i++) {
		const c = chips[chipAt = (chipAt + 1) % chips.length];
		const a = Math.random() * Math.PI * 2, up = 0.4 + Math.random() * 0.9;
		c.m.visible = true;
		c.m.position.set(x, y, z);
		c.m.color = color;
		c.life = 0.75 + Math.random() * 0.5;
		c.vx = Math.cos(a) * power * (0.5 + Math.random());
		c.vz = Math.sin(a) * power * (0.5 + Math.random());
		c.vy = power * up;
		c.sx = (Math.random() - 0.5) * 18;
		c.sz = (Math.random() - 0.5) * 18;
	}
}

// ---------------------------------------------------------------------------
// Breaking a crate.
//
// `three.physics.remove` takes the body away and `scene.remove` takes the node,
// in that order — a body outliving its node is the one combination the solver
// has nothing to move. What the kind decides is what happens NEXT: a quest
// crate coughs up fruit, a TNT lights a fuse, a nitro goes off where it stands.
// ---------------------------------------------------------------------------
const CHIP_COLOR = { wood: 0xb98a4e, quest: 0xe8c23c, tnt: 0xc4443a, nitro: 0x3f9a58 };
function kill(c) {
	if (!c.alive) return;
	c.alive = false;
	three.physics.remove(c.m);
	scene.remove(c.m);
	ctl.broken++;
}
function breakCrate(c, chain) {
	if (!c.alive) return;
	if (c.kind === 'tnt' && c.fuse < 0 && !chain) { c.fuse = 2.2; return; }
	const p = c.m.position;
	const x = p.x, y = p.y, z = p.z;
	if (c.kind === 'nitro' || c.kind === 'tnt') {
		kill(c);
		burst(x, y, z, CHIP_COLOR[c.kind], 18, 9);
		explode(x, y, z, c.kind === 'nitro' ? 7.5 : 6.5);
	} else {
		kill(c);
		burst(x, y, z, CHIP_COLOR[c.kind], 11, 6);
		if (c.kind === 'quest') { ctl.fruit += 3; burst(x, y + 0.4, z, 0xff8c1a, 5, 4.5); }
	}
}
function explode(x, y, z, radius) {
	for (const o of crates) {
		if (!o.alive) continue;
		const p = o.m.position;
		const d = Math.hypot(p.x - x, p.y - y, p.z - z);
		if (d > radius) continue;
		if (d < radius * 0.6) { breakCrate(o, true); continue; }
		const k = (1 - d / radius) * 26;
		three.physics.applyImpulse(o.m, [((p.x - x) / (d || 1)) * k, k * 0.8, ((p.z - z) / (d || 1)) * k]);
	}
	// And a shove for whoever lit it.
	const dp = Math.hypot(ctl.x - x, ctl.z - z);
	if (dp < radius + 1.5 && ctl.vy < 2) { ctl.vy = 7.5; ctl.grounded = false; }
}

function collect(mesh) {
	const w = wumpa.find(f => f.alive && f.m === mesh);
	if (!w) return false;
	w.alive = false;
	w.m.visible = false;
	three.physics.remove(w.m);
	ctl.fruit++;
	return true;
}
// A trigger has a collider and takes part in the overlap test but produces no
// response, so this fires the moment the player's capsule is inside a fruit.
three.onTrigger(e => {
	if (e.type === 'enter' && e.other === capsule) collect(e.trigger);
});

// ---------------------------------------------------------------------------
// Where the feet are.
//
// The terrain, or the top of a shelf, or the top of a crate you are above and
// falling onto. The crate test needs the "already above it" clause: without it
// walking INTO a stack teleports you onto it, which is the difference between
// a platform and a wall.
// ---------------------------------------------------------------------------
function groundAt(x, z, fromY) {
	let g = terrain.heightAt(x, z);
	for (const p of PLATFORMS) {
		const dx = x - p.x, dz = z - p.z;
		const c = Math.cos(-p.yaw), s = Math.sin(-p.yaw);
		const lx = dx * c - dz * s, lz = dx * s + dz * c;
		if (Math.abs(lx) < p.w / 2 + 0.3 && Math.abs(lz) < p.d / 2 + 0.3 && p.top <= fromY + 0.55) {
			g = Math.max(g, p.top);
		}
	}
	for (const c of crates) {
		if (!c.alive) continue;
		const p = c.m.position;
		const top = p.y + CRATE / 2;
		if (top > fromY + 0.55) continue;
		if (Math.abs(x - p.x) < CRATE / 2 + 0.34 && Math.abs(z - p.z) < CRATE / 2 + 0.34) g = Math.max(g, top);
	}
	return g;
}

// ---------------------------------------------------------------------------
// The controller.
// ---------------------------------------------------------------------------
const held = k => three.input.isDown(k);
const axis = (a, b) => ((a.some(held) ? 1 : 0) - (b.some(held) ? 1 : 0));
const KEYS = {
	forward: ['w', 'arrowup'], back: ['s', 'arrowdown'],
	left: ['a', 'arrowleft'], right: ['d', 'arrowright'],
	jump: ['space'], spin: ['j', 'k', 'shift'],
	yawL: ['q'], yawR: ['e'], pitchU: ['r'], pitchD: ['f'],
};

// The spin, as its own verb. Break what is in reach, then throw whatever is
// left standing just outside it — which is the difference between a spin and a
// bump, and is the one move the whole level is built around.
function spin() {
	ctl.spin = SPIN_TIME;
	ctl.spinCool = SPIN_TIME + 0.16;
	for (const c of crates) {
		if (!c.alive) continue;
		const p = c.m.position;
		if (Math.abs(p.y - (ctl.y + 0.8)) > 2.1) continue;
		if (Math.hypot(p.x - ctl.x, p.z - ctl.z) > SPIN_R) continue;
		breakCrate(c, false);
	}
	for (const c of crates) {
		if (!c.alive) continue;
		const p = c.m.position;
		const d = Math.hypot(p.x - ctl.x, p.z - ctl.z);
		if (d > SPIN_R + 2.2 || d < 1e-4) continue;
		three.physics.applyImpulse(c.m, [((p.x - ctl.x) / d) * 22, 9, ((p.z - ctl.z) / d) * 22]);
	}
}

function playerStep(dt) {
	const ptr = three.input.pointer;
	// Drag to look: this host reports tiny pointer deltas every frame even when
	// the cursor is still, and applying them unconditionally makes the yaw creep
	// — which rotates the frame W/A/S/D steers in, out from under the player.
	if (ptr.down) {
		ctl.yaw -= ptr.dx * 0.24;
		ctl.pitch += ptr.dy * 0.2;
	}
	ctl.yaw += axis(KEYS.yawL, KEYS.yawR) * 120 * dt;
	ctl.pitch += axis(KEYS.pitchU, KEYS.pitchD) * 60 * dt;
	ctl.pitch = Math.max(-4, Math.min(72, ctl.pitch));
	ctl.dist = Math.max(5, Math.min(24, ctl.dist + ptr.scroll));
	three.camera.orbit(ctl.yaw, ctl.pitch, ctl.dist);

	// --- run, in the camera's frame ---
	const move = three.camera.planarMove(axis(KEYS.forward, KEYS.back), axis(KEYS.right, KEYS.left));
	ctl.moving = move.length() > 0;
	if (ctl.moving) {
		ctl.heading = Math.atan2(move.x, move.z);
		ctl.x += move.x * SPEED * dt;
		ctl.z += move.z * SPEED * dt;
		ctl.travelled += SPEED * dt;
	}

	// --- the fence: stay in the corridor, on the terrain, and out of the rocks ---
	const near = nearestOnPath(ctl.x, ctl.z);
	if (near.d > WALK) {
		const k = WALK / (near.d || 1);
		ctl.x = near.x + (ctl.x - near.x) * k;
		ctl.z = near.z + (ctl.z - near.z) * k;
	}
	ctl.x = Math.max(-W / 2 + 6, Math.min(W / 2 - 6, ctl.x));
	ctl.z = Math.max(-D / 2 + 6, Math.min(D / 2 - 6, ctl.z));
	for (const b of blockers) {
		const dx = ctl.x - b.x, dz = ctl.z - b.z;
		const d = Math.hypot(dx, dz), want = b.r + 0.45;
		if (d < want && d > 1e-4) {
			ctl.x = b.x + (dx / d) * want;
			ctl.z = b.z + (dz / d) * want;
		}
	}

	// --- spin ---
	if (ctl.spinCool > 0) ctl.spinCool -= dt;
	if (ctl.spin <= 0 && ctl.spinCool <= 0 && KEYS.spin.some(k => three.input.pressed(k))) spin();
	if (ctl.spin > 0) {
		ctl.spin -= dt;
		ctl.spinAngle += dt * 34;
	} else {
		ctl.spinAngle *= 0.7;   // unwind rather than snap
	}

	// --- vertical ---
	const g = groundAt(ctl.x, ctl.z, ctl.y);
	if (ctl.grounded) ctl.coyote = 0.12; else ctl.coyote -= dt;
	if (ctl.coyote > 0 && three.input.pressed('space')) {
		ctl.vy = JUMP; ctl.grounded = false; ctl.coyote = 0;
	} else if (ctl.grounded && g < ctl.y - 0.55) {
		ctl.vy = 0; ctl.grounded = false;
	}
	if (ctl.grounded) {
		ctl.y = g;
	} else {
		ctl.vy -= GRAV * dt;
		ctl.y += ctl.vy * dt;
		// Landing on a crate breaks it and bounces — Crash's other verb, and the
		// reason the vertical half of this controller is written out here.
		if (ctl.vy < 0) {
			for (const c of crates) {
				if (!c.alive) continue;
				const p = c.m.position;
				const top = p.y + CRATE / 2;
				if (ctl.y > top + 0.25 || ctl.y < top - 1.3) continue;
				if (Math.abs(ctl.x - p.x) > CRATE / 2 + 0.4 || Math.abs(ctl.z - p.z) > CRATE / 2 + 0.4) continue;
				breakCrate(c, false);
				ctl.vy = JUMP * 0.78;
				break;
			}
		}
		if (ctl.y <= g) { ctl.y = g; ctl.vy = 0; ctl.grounded = true; }
	}

	// --- write the transforms ---
	P.g.position.set(ctl.x, ctl.y, ctl.z);
	P.g.rotation.y = ctl.heading;
	P.spinner.rotation.y = ctl.spinAngle;
	capsule.position.set(ctl.x, ctl.y + 0.9, ctl.z);

	// --- the walk cycle, and arms out while spinning ---
	if (ctl.moving && ctl.grounded) ctl.walkT += dt * 13;
	const swing = ctl.moving && ctl.grounded ? Math.sin(ctl.walkT) * 0.62 : 0;
	P.legs[0].rotation.x = swing; P.legs[1].rotation.x = -swing;
	const out = ctl.spin > 0 ? 1 : 0;
	P.arms[0].rotation.x = -swing * 0.7 * (1 - out); P.arms[1].rotation.x = swing * 0.7 * (1 - out);
	P.arms[0].rotation.z = out * 1.5; P.arms[1].rotation.z = -out * 1.5;
	if (!ctl.grounded) { P.legs[0].rotation.x = 0.5; P.legs[1].rotation.x = -0.3; }
}

// ---------------------------------------------------------------------------
// The sky and the haze, in one post pass.
//
// `p.depth` is in WORLD UNITS and a pixel nothing was drawn into reads as the
// far plane — which is what makes a sky gradient and a distance fog the same
// shader. The far plane is derived and moves with the camera, so it is a
// uniform written every frame rather than a constant baked in here.
// ---------------------------------------------------------------------------
const sky = three.setPost({
	uniforms: {
		viewFar: 400,
		fogColor: [0.80, 0.40, 0.22],
		skyLow: [0.97, 0.52, 0.20],
		skyHigh: [0.42, 0.11, 0.17],
		fogRange: [95, 340],
	},
	fragment: `
		float3 post(Post p) {
			float isSky = smoothstep(viewFar * 0.975, viewFar * 0.999, p.depth);
			float up = pow(clamp(1.0 - p.uv.y, 0.0, 1.0), 0.8);
			float3 gradient = lerp(skyLow, skyHigh, up);

			float haze = clamp((p.depth - fogRange.x) / max(1.0, fogRange.y - fogRange.x), 0.0, 1.0);
			float3 lit = lerp(p.color, fogColor, haze * haze * 0.72);
			return lerp(lit, gradient, isSky);
		}`,
});

// ---------------------------------------------------------------------------
// The frame.
// ---------------------------------------------------------------------------
three.camera.attach(P.g, { offset: [0, 1.5, 0], distance: ctl.dist, lag: 90 });
three.controls.enabled = false;
three.camera.orbit(ctl.yaw, ctl.pitch, ctl.dist);
// The far plane is derived and moves with the camera, so the sky test needs it
// before the first frame as well as on every frame after: a scene rendered once,
// headless, never reaches the animation callback at all.
sky.uniforms.viewFar = three.camera.far;

function frame(dt, t) {
	playerStep(dt);

	// Fuses.
	for (const c of crates) {
		if (!c.alive || c.fuse < 0) continue;
		c.fuse -= dt;
		c.m.color = Math.floor(t * 12) % 2 ? 0xffe0d0 : 0xffffff;
		if (c.fuse <= 0) breakCrate(c, true);
	}
	// Nitro goes off on contact, so anything that gets shoved into the player
	// or lands next to one is enough. This is the distance the SOLVER already
	// resolved, read back rather than simulated a second time.
	for (const c of crates) {
		if (!c.alive || c.kind !== 'nitro') continue;
		const p = c.m.position;
		if (Math.hypot(p.x - ctl.x, p.z - ctl.z) < 1.5 && Math.abs(p.y - ctl.y) < 2.2) breakCrate(c, true);
	}

	// Fruit bob and turn.
	for (const w of wumpa) {
		if (!w.alive) continue;
		w.m.rotation.y = t * 2.2 + w.phase;
		w.m.position.y = 1.35 + Math.sin(t * 2.6 + w.phase) * 0.18;
	}

	// Chips.
	for (const c of chips) {
		if (c.life <= 0) continue;
		c.life -= dt;
		if (c.life <= 0) { c.m.visible = false; continue; }
		c.vy -= 26 * dt;
		c.m.position.x += c.vx * dt;
		c.m.position.y += c.vy * dt;
		c.m.position.z += c.vz * dt;
		c.m.rotation.x += c.sx * dt;
		c.m.rotation.z += c.sz * dt;
		if (c.m.position.y < 0.16) { c.m.position.y = 0.16; c.vy *= -0.35; c.vx *= 0.7; c.vz *= 0.7; }
	}

	sky.uniforms.viewFar = three.camera.far;
}

three.setAnimationLoop(() => frame(three.clock.dt, three.clock.time));

three.render(scene, three.camera);
three.unloadUnused();

const st = scene.stats();
console.log('crash_canyon: ' + JSON.stringify({
	draws: st.drawCalls, shadow: st.shadowDraws, instances: st.instances,
	triangles: st.triangles, textures: st.textures,
	bodies: three.physics.count, crates: crates.length, wumpa: wumpa.length,
	kerb: kerbCount, wallBodies, pathLen: +PATH_LEN.toFixed(1),
	gpuMs: +st.gpuMs.toFixed(2),
}));
return {
	stats: st, bodies: three.physics.count, crates: crates.length,
	wumpa: wumpa.length, pathLen: +PATH_LEN.toFixed(1), ctl,
};
