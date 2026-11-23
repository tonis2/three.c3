// siege/siege.js — knocking down toy castles with thrown stones (gameplan.md).
//
//   packaging/android/quest.sh push examples/siege/siege.js
//   ./build/three --script examples/siege/siege.js
//
// Reach into the basket at your right hip, squeeze to take a stone and let go
// to throw it. Eight stones a round; the board beside the castle keeps the
// score, the best for this castle, which castle it is and the stones left. B or
// Y starts the round again, X moves on to the next castle.
//
// At a desk the pointer is the right hand: point at the basket and hold the
// right button to take a stone, point at the castle and let go to throw it.
// 2 rebuilds and 3 moves on (they are B and X).
//
// Every throw is kept in `siege.throws`, for tuning over MCP while somebody
// throws: what the hand measured, what the stone left with, and what it hit.

const HZ = 90;
// The castle's grid: a block is one cell, a brick two or three in a row.
const CELL = 0.1;
const PLINTH = 2;
const PLINTH_TOP = 0.7;
const CASTLE_Z = -3;
// Seconds a new castle stands on welds that cannot break. A castle settling
// onto its plinth briefly loads its welds harder than most hits do.
const SETTLE = 1;

// A stone frees the pieces round the point it is about to hit, the frame
// before it lands. Left to the solver, the blow lands on a whole welded wall,
// which barely moves, and the stone bounces off; freeing them first lets the
// struck pieces take it. `reach` is how far from the point pieces are freed at
// `speed` m/s, growing by `perSpeed` metres for each m/s faster, up to `most`.
// `share` is how much of the stone's momentum the freed pieces take.
const impact = { speed: 3, reach: 0.02, perSpeed: 0.015, most: 0.12, share: 0.8 };

// Per material: kilograms per cell, and the force a weld one cell square
// breaks at. The solver's breaking is for collapses, a falling chunk landing
// on a wall, so these sit well above the 25 N or so a weld carries at rest.
// There is no torque rating: at rest a weld reads up to 3 N·m that is mostly
// the solver working against the contacts. Read when a castle is built.
const ratings = {
	stone: { density: 0.3, force: 100 },
	wood: { density: 0.2, force: 60 },
};

const STONES = 8;
const STONE_RADIUS = 0.04;
const STONE_MASS = 0.6;
// How close a grip has to come to a stone, or to the basket, to take one.
const GRAB_RADIUS = 0.1;
// Where a stone sits in the hand, in the grip's frame.
const HOLD = [0, -0.01, -0.03];
// The basket: inside width, depth and height, and its wall thickness.
const BASKET = [0.3, 0.22, 0.12];
const WALL = 0.012;
// At a desk the mouse cannot throw, so a stone leaves along the pointer at this.
const DESK_SPEED = 9;
const DESK_EYE = 1.6;

// How the release velocity is read, changeable over MCP: 'raw' is the hand on
// the frame squeeze let go, 'peak' the fastest frame in the last `window`
// seconds averaged with its neighbours (a hand opening slows down first).
// `scale` is a throw boost: with nothing in the hand people throw gently, and
// the first throws on the headset left at 4-6 m/s.
const tuning = { mode: 'peak', window: 0.1, scale: 1.6 };

// Best scores are kept in the game's save folder, named before anything else.
try {
	three.configure({ saveDir: 'siege' });
} catch {
	// Already named by the run this one reloaded.
}

const scene = new three.Scene();
scene.background = 0x8aa4c0;
three.light.set([-0.5, -1, -0.4], 0.9);
// Does nothing on a headset, where the controllers are the hands.
three.xr.emulate = true;

// ---------------------------------------------------------------------------
// Textures, generated here so the game runs on a clean checkout.
// ---------------------------------------------------------------------------

const SIZE = 128;
const { clamp01, smoothstep, fbm2, hash } = three;
const mix = (a, b, t) => [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t];
const scale3 = (c, k) => [c[0] * k, c[1] * k, c[2] * k];
const byte = (n) => (n < 0 ? 0 : n > 255 ? 255 : n);

// A colour map and a normal map from one pass: `shade(u, v, x, y)` answers
// [colour, height], and the normal is the height's slope. Rows run bottom to
// top, so v = 0 is the bottom of the image. `wrap` is for an image that tiles.
function paint(shade, { relief = 3, wrap = false } = {}) {
	const color = new Uint8Array(SIZE * SIZE * 4);
	const height = new Float32Array(SIZE * SIZE);
	for (let y = 0; y < SIZE; y++) {
		for (let x = 0; x < SIZE; x++) {
			const [c, h] = shade((x + 0.5) / SIZE, (y + 0.5) / SIZE, x, y);
			const i = y * SIZE + x;
			height[i] = h;
			color[i * 4] = byte(c[0]);
			color[i * 4 + 1] = byte(c[1]);
			color[i * 4 + 2] = byte(c[2]);
			color[i * 4 + 3] = 255;
		}
	}
	const at = wrap
		? (x, y) => height[((y + SIZE) % SIZE) * SIZE + (x + SIZE) % SIZE]
		: (x, y) => height[Math.min(Math.max(y, 0), SIZE - 1) * SIZE + Math.min(Math.max(x, 0), SIZE - 1)];
	const normal = new Uint8Array(SIZE * SIZE * 4);
	for (let y = 0; y < SIZE; y++) {
		for (let x = 0; x < SIZE; x++) {
			const dx = (at(x + 1, y) - at(x - 1, y)) * 0.5 * relief;
			const dy = (at(x, y + 1) - at(x, y - 1)) * 0.5 * relief;
			const k = 1 / Math.hypot(dx, dy, 1);
			const i = (y * SIZE + x) * 4;
			normal[i] = (-dx * k * 0.5 + 0.5) * 255;
			normal[i + 1] = (-dy * k * 0.5 + 0.5) * 255;
			normal[i + 2] = (k * 0.5 + 0.5) * 255;
			normal[i + 3] = 255;
		}
	}
	return new three.MeshLambertMaterial({
		map: new three.DataTexture(color, SIZE, SIZE),
		normalMap: new three.DataTexture(normal, SIZE, SIZE, { colorSpace: three.LinearSRGBColorSpace }),
	});
}

// One dressed stone per face: a rough face chiselled down at its edges.
const stoneMaterial = paint((u, v, x, y) => {
	const chisel = smoothstep(Math.min(u, 1 - u, v, 1 - v), 0, 0.12);
	const rough = fbm2(u * 6, v * 6, { octaves: 4, seed: 11 });
	const grit = hash(x, y, 13);
	const tone = (0.8 + 0.3 * rough) * (0.72 + 0.28 * chisel) + (grit - 0.5) * 0.08;
	return [scale3([172, 164, 150], tone), 0.55 * chisel + 0.35 * rough * chisel + 0.1 * grit];
});

// A plank with its grain along v, a knot, and its edges eased.
const woodMaterial = paint((u, v, x, y) => {
	const warp = fbm2(u * 3, v * 1.5, { octaves: 3, seed: 21 });
	const ring = 0.5 + 0.5 * Math.sin((u * 7 + warp * 2.5) * Math.PI * 2);
	const fibre = fbm2(u * 48, v * 3, { octaves: 2, seed: 22 });
	const knot = 1 - smoothstep(Math.hypot(u - 0.32, (v - 0.64) * 0.5), 0.015, 0.06);
	const ease = smoothstep(Math.min(u, 1 - u, v, 1 - v), 0, 0.07);
	const t = clamp01(0.5 * ring + 0.5 * fibre - 0.7 * knot);
	const c = scale3(mix([104, 68, 40], [178, 130, 84], t), 0.72 + 0.28 * ease);
	return [c, 0.6 * ease + 0.25 * fibre * ease + 0.15 * ring - 0.25 * knot];
});

// The plinth's sides: two courses of big stones in mortar, tiling.
const plinthMaterial = paint((u, v, x, y) => {
	const row = Math.floor(v * 2);
	const across = u * 3 + (row % 2) * 0.5;
	const col = Math.floor(across);
	const su = across - col;
	const sv = v * 2 - row;
	const edge = Math.min(su / 3, (1 - su) / 3, sv / 2, (1 - sv) / 2);
	const face = smoothstep(edge, 0.008, 0.03);
	const rough = fbm2(u * 8, v * 8, { octaves: 4, period: 8, seed: 31 });
	const tone = 0.78 + 0.3 * hash(col % 3, row, 32);
	const stone = scale3([150, 142, 128], tone * (0.82 + 0.3 * rough));
	return [mix([96, 92, 84], stone, face), 0.15 + 0.6 * face + 0.25 * rough * face];
}, { wrap: true });

// Moss and grass, tiling.
function turf(repeat) {
	const material = paint((u, v, x, y) => {
		const patch = fbm2(u * 6, v * 6, { octaves: 4, period: 6, seed: 41 });
		const blade = hash(x, y, 42);
		let c = mix([46, 70, 32], [104, 132, 60], patch);
		if (blade > 0.9) c = scale3(c, 1.2);
		else if (blade < 0.08) c = scale3(c, 0.78);
		return [c, 0.7 * patch + 0.3 * blade];
	}, { relief: 2, wrap: true });
	material.repeat = repeat;
	material.stochastic = true;
	return material;
}

// Thrown stones: grey and rough all over, with no edges to show the seam.
const pebbleMaterial = paint((u, v, x, y) => {
	const rough = fbm2(u * 8, v * 4, { octaves: 4, period: 8, seed: 51 });
	return [scale3([92, 90, 88], 0.75 + 0.45 * rough), rough];
}, { wrap: true });

// Eight looks per block out of one picture: the turns and mirrors of a square.
// Wood keeps its grain along a piece's length: rows 0-3 for upright pieces,
// 4-7 turned a quarter for lying ones.
stoneMaterial.uvVariants = [0, 1, 2, 3].flatMap((turn) => [[0, 0, turn, 0], [0, 0, turn, 3]]);
woodMaterial.uvVariants = [0, 1].flatMap((turn) => [0, 1, 2, 3].map((flip) => [0, 0, turn, flip]));
plinthMaterial.repeat = [2, 1.5];

const matte = new three.MeshLambertMaterial({});

function box(size, at, material, color, body, yaw = 0) {
	const mesh = new three.Mesh(new three.BoxGeometry(...size), material);
	mesh.position.set(...at);
	mesh.rotation.y = yaw;
	if (color) mesh.color = color;
	scene.add(mesh);
	if (body) three.physics.add(mesh, { shape: 'box', mass: 0, friction: 0.8, ...body });
	return mesh;
}

const ground = box([20, 0.1, 20], [0, -0.05, 0], turf([16, 16]), null, {});
const plinth = box([PLINTH, PLINTH_TOP - 0.01, PLINTH], [0, (PLINTH_TOP - 0.01) / 2, CASTLE_Z], plinthMaterial, null, {});
const plinthTurf = box([PLINTH, 0.01, PLINTH], [0, PLINTH_TOP - 0.005, CASTLE_Z], turf([2, 2]), [0.9, 0.95, 0.85], {});
// The throwing line, drawn only.
const line = box([2, 0.004, 0.04], [0, 0.002, -0.3], matte, [0.9, 0.88, 0.8], null);
line.collides = false;

// ---------------------------------------------------------------------------
// The castle builder. A castle is sections, and a section is pieces on the
// grid, each welded to every piece of the same section it touches and to
// nothing else: a hit breaks a section apart without waking its neighbours.
//
// Grid: x across (0 is the plinth's middle), y up from the plinth's top, z
// toward the player (0 is the plinth's middle). A piece's `at` is its corner
// nearest -x, -y, -z, in cells.
// ---------------------------------------------------------------------------

class Section {
	constructor(name) {
		this.name = name;
		this.pieces = [];
	}

	add(kind, at, size, extra = {}) {
		const piece = { kind, at, size, ...extra };
		this.pieces.push(piece);
		return piece;
	}
}

// A brick covering a straight run of [x, z] cells.
function brick(section, kind, cells, y, height = 1) {
	if (cells.length === 0) return;
	const xs = cells.map((c) => c[0]);
	const zs = cells.map((c) => c[1]);
	const x0 = Math.min(...xs);
	const z0 = Math.min(...zs);
	section.add(kind, [x0, y, z0], [Math.max(...xs) + 1 - x0, height, Math.max(...zs) + 1 - z0]);
}

// The cells round a square ring `width` cells across, from its corner at
// (x, z), one side after another.
function ringPath(x, z, width) {
	const side = width - 1;
	const path = [];
	for (let k = 0; k < side; k++) path.push([x + k, z]);
	for (let k = 0; k < side; k++) path.push([x + side, z + k]);
	for (let k = 0; k < side; k++) path.push([x + side - k, z + side]);
	for (let k = 0; k < side; k++) path.push([x, z + side - k]);
	return path;
}

// One course of a square tower's wall: each side is bricks of two (three to
// finish an odd side), and every other course starts one cell further round,
// so no joint sits over the one below. `skip(x, y, z)` leaves cells out.
function ring(section, kind, x, z, width, y, skip = null) {
	const side = width - 1;
	const path = ringPath(x, z, width);
	for (let s = 0; s < 4; s++) {
		const cells = [];
		for (let k = 0; k < side; k++) cells.push(path[(s * side + k + y % 2) % path.length]);
		for (let k = 0, n = cells.length; n > 0;) {
			const length = n === 3 ? 3 : Math.min(n, 2);
			let run = [];
			for (const c of cells.slice(k, k + length)) {
				if (skip?.(c[0], y, c[1])) {
					brick(section, kind, run, y);
					run = [];
				} else run.push(c);
			}
			brick(section, kind, run, y);
			k += length;
			n -= length;
		}
	}
}

// Battlements on a ring: the corners and every other cell between.
function merlons(section, kind, x, z, width, y) {
	const side = width - 1;
	ringPath(x, z, width).forEach((c, k) => {
		if ((k % side) % 2 === 0) section.add(kind, [c[0], y, c[1]], [1, 1, 1]);
	});
}

// A straight wall one cell thick, `length` cells along x from (x, z), in
// bricks of two with the courses offset by one. `gate: [from, to, height]` is
// an opening over cells from..to-1, spanned by one lintel stone.
function wall(section, kind, x, z, length, courses, { gate = null, battlements = true } = {}) {
	const [g0, g1, gh] = gate ?? [0, 0, -1];
	for (let y = 0; y < courses; y++) {
		let run = [];
		const flush = () => {
			brick(section, kind, run, y);
			run = [];
		};
		for (let i = 0; i < length; i++) {
			const open = (y < gh && i >= g0 && i < g1) || (y === gh && i >= g0 - 1 && i <= g1);
			if (open) {
				flush();
				continue;
			}
			if (run.length > 0 && (i + y) % 2 === 0) flush();
			run.push([x + i, z]);
		}
		flush();
		if (y === gh) section.add(kind, [x + g0 - 1, y, z], [g1 - g0 + 2, 1, 1]);
	}
	if (battlements) {
		for (let i = 0; i < length; i += 2) section.add(kind, [x + i, courses, z], [1, 1, 1]);
	}
}

// Level 1: a wooden palisade round a watchtower. Wood is light and its welds
// weak, so this is the one a first throw breaks.
function palisade() {
	const front = new Section('front');
	for (let i = 0; i < 14; i++) {
		if (i === 6 || i === 7) continue;
		front.add('wood', [-7 + i, 0, 3], [1, 5 + (i % 2), 1], { tip: true });
	}
	for (const [x, y] of [[-7, 1], [1, 1], [-7, 3.5], [1, 3.5]]) front.add('wood', [x, y, 2.5], [6, 0.5, 0.5]);

	const sides = [-7, 6].map((x) => {
		const side = new Section(x < 0 ? 'left' : 'right');
		for (let z = -6; z < 2; z++) side.add('wood', [x, 0, z], [1, 5, 1], { tip: true });
		const inside = x < 0 ? x + 1 : x - 0.5;
		for (const y of [1, 3.5]) side.add('wood', [inside, y, -6], [0.5, 0.5, 8]);
		return side;
	});

	const tower = new Section('watchtower');
	for (const [x, z] of [[-2, -6], [1, -6], [-2, -3], [1, -3]]) {
		tower.add('wood', [x, 0, z], [1, 4, 1]);
		tower.add('wood', [x, 4, z], [1, 3, 1]);
		tower.add('wood', [x, 7.5, z], [1, 2, 1]);
	}
	for (const z of [-6, -3]) tower.add('wood', [-1, 3, z], [2, 0.5, 1]);
	for (const x of [-2, 1]) tower.add('wood', [x, 3.5, -5], [1, 0.5, 2]);
	tower.add('wood', [-2, 7, -6], [4, 0.5, 4]);
	tower.add('wood', [-2.5, 9.5, -6.5], [5, 3, 5], { roof: true });
	return [front, ...sides, tower];
}

// Level 2: a keep behind a gated curtain wall between two towers.
function keep() {
	const hall = new Section('keep');
	const slit = (x, y, z) => z === -1 && x === -0.5 && y >= 5 && y < 7;
	for (let y = 0; y < 9; y++) ring(hall, 'stone', -2.5, -5, 5, y, slit);
	merlons(hall, 'stone', -2.5, -5, 5, 9);

	const towers = [-6.5, 3.5].map((x) => {
		const tower = new Section(x < 0 ? 'left tower' : 'right tower');
		for (let y = 0; y < 10; y++) ring(tower, 'stone', x, 2, 3, y);
		merlons(tower, 'stone', x, 2, 3, 10);
		return tower;
	});

	const curtain = new Section('curtain');
	wall(curtain, 'stone', -3.5, 3, 7, 6, { gate: [2, 5, 3] });
	return [hall, ...towers, curtain];
}

// Level 3: a tall bell tower, open at the top with a bell hung inside, and a
// churchyard wall in front.
function belfry() {
	const tower = new Section('tower');
	for (let y = 0; y < 16; y++) ring(tower, 'stone', -2, -4, 4, y);
	for (const [x, z] of [[-2, -4], [1, -4], [-2, -1], [1, -1]]) tower.add('stone', [x, 16, z], [1, 3, 1]);
	const cap = tower.add('stone', [-2, 19, -4], [4, 0.5, 4]);
	tower.add('wood', [-2.5, 19.5, -4.5], [5, 4, 5], { roof: true });
	tower.add('bell', [-0.4, 17.6, -2.4], [0.8, 1, 0.8], { hang: cap });

	const yard = new Section('churchyard');
	wall(yard, 'stone', -6.5, 4, 13, 3, { gate: [5, 8, 2], battlements: false });
	return [tower, yard];
}

// How many substeps a second each castle needs to stand still: two a step at
// 90 Hz is half the solver's time of four and lets struck pieces slide out
// further, but the belfry's tall tower only keeps still at four. `soldiers` is
// where each stands, in cells: the middle of its feet, y the top it stands on.
const LEVELS = [
	{
		name: 'palisade', build: palisade, substepRate: 180,
		soldiers: [[-0.5, 7.5, -4.5], [0.5, 7.5, -3.5], [-3, 0, 1.5], [3, 0, 1.5]],
	},
	{
		name: 'keep', build: keep, substepRate: 180,
		soldiers: [[-2, 6, 3.5], [2, 6, 3.5], [-5, 10, 4.5], [5, 10, 4.5], [1, 9, -0.5]],
	},
	{
		name: 'belfry', build: belfry, substepRate: 360,
		soldiers: [[-4.5, 3, 4.5], [4.5, 3, 4.5], [0, 16, -0.5], [0, 16, -3.5]],
	},
];

const bronzeMaterial = new three.MeshLambertMaterial({});
const KINDS = {
	stone: { material: stoneMaterial, density: () => ratings.stone.density },
	wood: { material: woodMaterial, density: () => ratings.wood.density },
	bell: { material: bronzeMaterial, density: () => 1.2 },
};

const geometries = new Map();
function geometryFor(piece) {
	const [sx, sy, sz] = piece.size.map((n) => n * CELL);
	const key = `${piece.size}${piece.roof ? 'roof' : piece.kind === 'bell' ? 'bell' : ''}`;
	if (!geometries.has(key)) {
		let geometry;
		// A cone of four sides turned an eighth is a pyramid as wide as the box.
		if (piece.roof) geometry = new three.ConeGeometry(sx / Math.SQRT2, sy, 4);
		else if (piece.kind === 'bell') geometry = new three.CylinderGeometry(sx * 0.3, sx / 2, sy, 12);
		else geometry = new three.BoxGeometry(sx, sy, sz);
		geometries.set(key, geometry);
	}
	return geometries.get(key);
}

const tipGeometry = new three.ConeGeometry(CELL / Math.SQRT2, CELL * 0.6, 4);
// Each piece's half size in metres, along x, y and z as built.
const halfSizes = new Map();
// Each piece's height as built and its mass, which the score is counted from.
const homes = new Map();

function centreOf(piece) {
	const [x, y, z] = piece.at;
	const [sx, sy, sz] = piece.size;
	return [(x + sx / 2) * CELL, PLINTH_TOP + (y + sy / 2) * CELL, CASTLE_Z + (z + sz / 2) * CELL];
}

function placePiece(piece, n) {
	const mesh = new three.Mesh(geometryFor(piece), KINDS[piece.kind].material);
	mesh.position.set(...centreOf(piece));
	if (piece.roof) mesh.rotation.y = Math.PI / 4;
	const tone = 0.86 + 0.24 * hash(n, 7, 3);
	if (piece.kind === 'stone') {
		mesh.color = [tone, tone * 0.97, tone * 0.93];
		mesh.variant = Math.floor(hash(n, 5, 1) * 8);
	} else if (piece.kind === 'wood') {
		const lying = piece.size[1] < Math.max(piece.size[0], piece.size[2]);
		mesh.color = piece.roof ? [0.45, 0.34, 0.3] : [tone, tone * 0.95, tone * 0.9];
		mesh.variant = (lying ? 4 : 0) + Math.floor(hash(n, 6, 2) * 4);
	} else {
		mesh.color = [0.78, 0.56, 0.24];
	}
	scene.add(mesh);
	const [sx, sy, sz] = piece.size;
	// A roof is a thin shell, a tenth of the box it fills.
	const fill = piece.roof ? 0.1 : 1;
	const mass = KINDS[piece.kind].density() * sx * sy * sz * fill;
	homes.set(mesh, { y: mesh.position.y, mass });
	three.physics.add(mesh, {
		shape: piece.roof || piece.kind === 'bell' ? 'hull' : 'box',
		mass,
		friction: 0.4,
		restitution: 0.05,
		// Knocked down, thin stakes and rails jittered on the plinth until they
		// walked off it.
		angularDamping: 1,
	});
	if (piece.tip) {
		// A point on the stake, drawn only.
		const tip = new three.Mesh(tipGeometry, woodMaterial);
		tip.position.set(0, (sy / 2 + 0.3) * CELL, 0);
		tip.rotation.y = Math.PI / 4;
		tip.color = mesh.color;
		tip.collides = false;
		mesh.add(tip);
	}
	piece.mesh = mesh;
	halfSizes.set(mesh, [sx * CELL / 2, sy * CELL / 2, sz * CELL / 2]);
	return mesh;
}

// The face two pieces share: the axis they meet on and how much of it, in
// cells squared. Null unless they meet on one axis and overlap on the others.
function contact(a, b) {
	let axis = -1;
	let area = 1;
	for (let k = 0; k < 3; k++) {
		const lo = Math.max(a.at[k], b.at[k]);
		const hi = Math.min(a.at[k] + a.size[k], b.at[k] + b.size[k]);
		if (Math.abs(hi - lo) < 1e-6) {
			if (axis !== -1) return null;
			axis = k;
		} else if (hi < lo) return null;
		else area *= hi - lo;
	}
	if (axis === -1) console.warn(`siege: two pieces overlap at ${a.at} and ${b.at}`);
	return axis === -1 ? null : { axis, area };
}

// A weld is rated for the weaker of its two materials, and by how much face it
// holds: a brick on two bricks holds each by half as much as a block on one.
// Four times that on a roof and on what it rests on: the solver loads the welds
// of posts holding up a hull hard while it stands still (130 N on a watchtower
// post), and a stone that frees the posts still brings the roof down.
function ratingFor(a, b, area) {
	const r = a.kind === 'wood' || b.kind === 'wood' ? ratings.wood : ratings.stone;
	const roofed = a.roof || b.roof || a.bearing || b.bearing;
	return r.force * Math.min(Math.max(area, 0.5), 2) * (roofed ? 4 : 1);
}

let level = 0;
let blocks = [];
const blockSet = new Set();
// Every weld: its two pieces' meshes, its rating, and the joint's id, null
// once it is broken.
let welds = [];
let builtAt = 0;
let armed = false;

function buildCastle() {
	for (const block of blocks) {
		three.physics.remove(block);
		scene.remove(block);
	}
	blocks = [];
	welds = [];
	blockSet.clear();
	halfSizes.clear();
	homes.clear();
	const sections = LEVELS[level].build();
	let n = 0;
	for (const section of sections) {
		for (const piece of section.pieces) {
			const mesh = placePiece(piece, n++);
			blocks.push(mesh);
			blockSet.add(mesh);
		}
		const solid = section.pieces.filter((p) => p.kind !== 'bell');
		const faces = [];
		for (let i = 0; i < solid.length; i++) {
			for (let j = i + 1; j < solid.length; j++) {
				const face = contact(solid[i], solid[j]);
				if (face !== null && face.area >= 0.25) faces.push({ p: solid[i], q: solid[j], face });
			}
		}
		// What a roof rests on carries it, see `ratingFor`.
		for (const { p, q } of faces) {
			if (p.roof) q.bearing = true;
			if (q.roof) p.bearing = true;
		}
		for (const { p, q, face } of faces) {
			// A piece resting on another still touches it, so the weight goes
			// down through the contact and the weld holds only what pulls the
			// two apart. Pieces side by side need no contact for that, and nor
			// does a roof: a hull resting on a box fought its weld with 500 N of
			// contact standing still, where a light roof's weld carries it alone.
			const collide = face.axis === 1 && !p.roof && !q.roof;
			const id = three.physics.joint(p.mesh, q.mesh, { type: 'fixed', collide });
			welds.push({ a: p.mesh, b: q.mesh, collide, force: ratingFor(p, q, face.area), id });
		}
		// Hung things are welded to what they hang from: a bell left free to
		// swing on a point joint spun up and kept its tower awake for ever. A
		// stone that frees it brings it down.
		for (const piece of section.pieces.filter((p) => p.hang)) {
			const id = three.physics.joint(piece.hang.mesh, piece.mesh, { type: 'fixed' });
			welds.push({ a: piece.hang.mesh, b: piece.mesh, collide: false, force: ratingFor(piece.hang, piece, 1), id });
		}
	}
	builtAt = three.clock.time;
	armed = false;
	return sections;
}

// Once the castle has settled, each weld is made again where its pieces now
// are, with its rating.
function arm() {
	// Heights are counted from here too: settling is not a hit.
	for (const block of blocks) homes.get(block).y = block.position.y;
	for (const weld of welds) {
		if (weld.id === null) continue;
		three.physics.removeJoint(weld.id);
		weld.id = three.physics.joint(weld.a, weld.b, { type: 'fixed', collide: weld.collide, breakForce: weld.force });
	}
	armed = true;
}

// How far a piece's nearest face is from a point, as built, which is where it
// still is while welded.
function distanceTo(block, point) {
	const p = block.position;
	const h = halfSizes.get(block);
	const d = [p.x - point[0], p.y - point[1], p.z - point[2]].map((n, k) => Math.max(Math.abs(n) - h[k], 0));
	return Math.hypot(d[0], d[1], d[2]);
}

// Frees `struck` and every piece within `radius` of a point: all their welds
// break, since any one left would hand the blow to the whole wall. Answers the
// freed pieces, each with its distance, and how many welds broke.
function breakAround(point, radius, struck) {
	const loose = new Map();
	for (const block of blocks) {
		const d = block === struck ? 0 : distanceTo(block, point);
		if (d <= radius) loose.set(block, d);
	}
	let n = 0;
	for (const weld of welds) {
		if (weld.id === null || (!loose.has(weld.a) && !loose.has(weld.b))) continue;
		three.physics.removeJoint(weld.id);
		weld.id = null;
		n++;
	}
	return { loose, welds: n };
}

// Pushes the pieces a stone freed with `share` of its momentum, most to the
// one it struck and less the further a piece is from the point. Left to the
// contacts alone, the struck piece's friction with the pieces round it spreads
// the blow over every piece in the wall. The stone keeps its own speed: it is
// a frame or two short of the wall, and still has to land.
function shove(v, point, loose, radius, struck) {
	const weights = new Map();
	let total = 0;
	for (const [block, d] of loose) {
		const w = block === struck ? 1 : 0.5 * (1 - d / Math.max(radius, 1e-3));
		weights.set(block, w);
		total += w;
	}
	if (total <= 0) return;
	const p = v.map((n) => n * STONE_MASS * impact.share);
	for (const [block, w] of weights) {
		const k = w / total;
		const at = block === struck ? sub(point, triple(block.position)) : undefined;
		three.physics.applyImpulse(block, p.map((n) => n * k), at);
	}
}

// ---------------------------------------------------------------------------
// The basket and the stones.
// ---------------------------------------------------------------------------

const basketParts = [];
const basketSet = new Set();
let basketAt = [0, 0, 0];

function buildBasket(at) {
	for (const part of basketParts) {
		three.physics.remove(part);
		scene.remove(part);
	}
	basketParts.length = 0;
	basketSet.clear();
	basketAt = at;
	const [x, top, z] = at;
	const [w, d, h] = BASKET;
	const floor = top - h;
	const wicker = [1, 0.85, 0.6];
	const parts = [
		box([w + 2 * WALL, WALL, d + 2 * WALL], [x, floor - WALL / 2, z], woodMaterial, wicker, {}),
		box([WALL, h, d + 2 * WALL], [x - w / 2 - WALL / 2, floor + h / 2, z], woodMaterial, wicker, {}),
		box([WALL, h, d + 2 * WALL], [x + w / 2 + WALL / 2, floor + h / 2, z], woodMaterial, wicker, {}),
		box([w, h, WALL], [x, floor + h / 2, z - d / 2 - WALL / 2], woodMaterial, wicker, {}),
		box([w, h, WALL], [x, floor + h / 2, z + d / 2 + WALL / 2], woodMaterial, wicker, {}),
		box([0.04, floor - WALL, 0.04], [x, (floor - WALL) / 2, z], woodMaterial, [0.6, 0.5, 0.4], {}),
	];
	for (const part of parts) {
		basketParts.push(part);
		basketSet.add(part);
	}
}

function inBasket(p, margin) {
	const [x, top, z] = basketAt;
	return Math.abs(p[0] - x) < BASKET[0] / 2 + margin
		&& Math.abs(p[2] - z) < BASKET[1] / 2 + margin
		&& p[1] > top - BASKET[2] - margin && p[1] < top + margin;
}

const stoneShape = new three.SphereGeometry(STONE_RADIUS, 12, 8);
// Angular damping stands in for rolling resistance: a sphere on flat ground
// otherwise rolls for ever, and keeps awake the rubble it lies in.
const stoneBody = { shape: 'sphere', mass: STONE_MASS, friction: 0.6, restitution: 0.1, angularDamping: 2 };
const stones = [];
for (let k = 0; k < STONES; k++) {
	const stone = new three.Mesh(stoneShape, pebbleMaterial);
	scene.add(stone);
	stones.push(stone);
}
const stoneSet = new Set(stones);

function fillBasket() {
	const [x, top, z] = basketAt;
	stones.forEach((stone, k) => {
		three.physics.remove(stone);
		stone.visible = true;
		// Two layers of four, dropped in from just above the floor.
		const i = k % 4, j = Math.floor(k / 4) % 2, layer = Math.floor(k / 8);
		stone.position.set(x - 0.105 + i * 0.07, top - BASKET[2] + STONE_RADIUS + 0.005 + layer * 0.07, z - 0.04 + j * 0.08);
		three.physics.add(stone, stoneBody);
	});
}

// ---------------------------------------------------------------------------
// The hands. Per hand: a controller model on the grip, and the stone it holds,
// drawn on the grip. A held stone has no body: the castle is out of reach, so
// it has nothing to push, and it cannot knock the others out of the basket.
// ---------------------------------------------------------------------------

const controllerShape = new three.BoxGeometry(0.04, 0.03, 0.12);
const HISTORY = 16;
const hands = [three.xr.left, three.xr.right].map((xr) => {
	const model = new three.Mesh(controllerShape, matte);
	model.color = [0.82, 0.82, 0.86];
	model.collides = false;
	xr.grip.add(model);

	const held = new three.Mesh(stoneShape, pebbleMaterial);
	held.collides = false;
	held.visible = false;
	held.position.set(...HOLD);
	xr.grip.add(held);

	return { xr, model, held, stone: null, history: [] };
});

const sub = (a, b) => [a[0] - b[0], a[1] - b[1], a[2] - b[2]];
const cross = (a, b) => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
const length = (a) => Math.hypot(a[0], a[1], a[2]);
const triple = (v) => [v.x, v.y, v.z];
const rounded = (a, places = 2) => a.map((n) => +n.toFixed(places));

// What the held stone is doing this frame: the grip's motion at the stone, so a
// flick of the wrist adds to the throw.
function remember(hand, now) {
	const grip = hand.xr.grip;
	const v = triple(grip.velocity);
	const w = triple(grip.angularVelocity);
	const r = sub(triple(hand.held.getWorldPosition()), triple(grip.position));
	const c = cross(w, r);
	hand.history.push({ t: now, v: [v[0] + c[0], v[1] + c[1], v[2] + c[2]], w });
	if (hand.history.length > HISTORY) hand.history.shift();
}

function releaseVelocity(hand, now) {
	const h = hand.history;
	const last = h[h.length - 1];
	if (tuning.mode !== 'peak') return { v: last.v, w: last.w, ago: 0 };
	let best = h.length - 1;
	for (let k = h.length - 1; k >= 0 && now - h[k].t <= tuning.window; k--) {
		if (length(h[k].v) > length(h[best].v)) best = k;
	}
	const near = h.slice(Math.max(best - 1, 0), best + 2);
	const mean = (pick) => [0, 1, 2].map((a) => near.reduce((s, e) => s + pick(e)[a], 0) / near.length);
	return { v: mean((e) => e.v), w: mean((e) => e.w), ago: now - h[best].t };
}

function nearestStone(at, within) {
	let best = null;
	let bestDistance = within;
	for (const stone of stones) {
		if (!stone.visible || hands.some((hand) => hand.stone === stone)) continue;
		const d = length(sub(triple(stone.position), at));
		if (d < bestDistance) {
			best = stone;
			bestDistance = d;
		}
	}
	return best;
}

// The stone a squeeze takes: one by the grip, or any in the basket when the
// grip is in it. At a desk, wherever the pointer meets the basket.
function stoneFor(hand) {
	const at = triple(hand.xr.grip.position);
	if (hand.xr.profile === 'emulated') {
		const hit = scene.raycast(hand.xr.aim.position, hand.xr.aim.direction);
		if (hit === null || hit.distance > 2) return null;
		if (!basketSet.has(hit.object) && !stoneSet.has(hit.object)) return null;
		return nearestStone(triple(hit.point), 0.3);
	}
	return nearestStone(at, GRAB_RADIUS) ?? (inBasket(at, GRAB_RADIUS / 2) ? nearestStone(at, 0.5) : null);
}

function take(hand, stone) {
	three.physics.remove(stone);
	stone.visible = false;
	hand.stone = stone;
	hand.held.visible = true;
	hand.model.visible = false;
	hand.history = [];
	hand.xr.vibrate(0.5, 0.04);
}

const throws = [];
// Thrown stones that have not touched anything yet, and ones still fast
// enough to break something; each with its throw.
const flying = new Map();
const striking = new Map();

// Sends a stone off from `from` at `v`, and keeps the throw for reading over
// MCP.
function launch(stone, from, v, w, record) {
	three.physics.remove(stone);
	stone.position.set(...from);
	stone.visible = true;
	three.physics.add(stone, stoneBody);
	three.physics.setVelocity(stone, v);
	three.physics.setAngularVelocity(stone, w);
	Object.assign(record, { speed: +length(v).toFixed(2), velocity: rounded(v), from: rounded(from), hit: null, broke: 0, level: LEVELS[level].name });
	throws.push(record);
	if (throws.length > 20) throws.shift();
	flying.set(stone, record);
	striking.set(stone, record);
	lastThrow = record;
	lastLaunch = three.clock.time;
	return record;
}

let lastThrow = null;
let lastLaunch = 0;

function letGo(hand, now) {
	const stone = hand.stone;
	if (stone === null) return;
	const from = triple(hand.held.getWorldPosition());
	hand.stone = null;
	hand.held.visible = false;
	hand.model.visible = true;

	let v, w, ago = 0;
	const raw = hand.history.length > 0 ? hand.history[hand.history.length - 1].v : [0, 0, 0];
	if (hand.xr.profile === 'emulated') {
		v = triple(hand.xr.aim.direction).map((n) => n * DESK_SPEED);
		w = [0, 0, 0];
	} else if (hand.history.length > 0) {
		({ v, w, ago } = releaseVelocity(hand, now));
		v = v.map((n) => n * tuning.scale);
	} else {
		v = [0, 0, 0];
		w = [0, 0, 0];
	}
	const record = launch(stone, from, v, w, {
		hand: hand.xr.handedness,
		mode: hand.xr.profile === 'emulated' ? 'desk' : tuning.mode,
		rawSpeed: +length(raw).toFixed(2),
		peakAgoMs: Math.round(ago * 1000),
		t: now,
	});
	// Kept off the record's own fields, so reading `siege.throws` stays small.
	Object.defineProperty(record, 'thrower', { value: hand });
	hand.xr.vibrate(0.25, 0.02);
	const how = record.mode === 'desk' ? 'along the pointer' : `raw ${record.rawSpeed}, peak ${record.peakAgoMs} ms before letting go`;
	console.log(`siege: ${record.hand} threw at ${record.speed} m/s (${how})`);
}

// ---------------------------------------------------------------------------
// What happened: hits, loads, breaks, and blocks knocked off.
// ---------------------------------------------------------------------------

function what(object) {
	if (blockSet.has(object)) return 'castle';
	if (object === plinth || object === plinthTurf) return 'plinth';
	if (object === ground) return 'ground';
	if (basketSet.has(object)) return 'basket';
	if (stoneSet.has(object)) return 'stone';
	if (soldiers.some((s) => s.mesh === object)) return 'soldier';
	return 'other';
}

// A thrown stone's first touch is where it landed; a castle hit buzzes the hand
// that threw it.
three.onContact(({ type, a, b, point }) => {
	if (type !== 'start') return;
	for (const [stone, other] of [[a, b], [b, a]]) {
		const record = flying.get(stone);
		if (record === undefined) continue;
		flying.delete(stone);
		record.hit = { what: what(other), at: rounded([point.x, point.y, point.z]) };
		if (record.hit.what === 'castle') record.thrower?.xr.vibrate(0.4, 0.05);
	}
});

// Once a frame: a stone that will reach a castle piece within the next two
// steps breaks the welds round the point it will strike, once.
function strike() {
	const ahead = 2 / (three.physics.rate || 60);
	for (const [stone, record] of striking) {
		const v = three.physics.velocity(stone);
		const speed = v === null ? 0 : Math.hypot(v[0], v[1], v[2]);
		if (speed < impact.speed) {
			striking.delete(stone);
			continue;
		}
		const from = triple(stone.position);
		const to = [from[0] + v[0] * ahead, from[1] + v[1] * ahead, from[2] + v[2] * ahead];
		const hit = three.query.sweep(from, to, { radius: STONE_RADIUS, ignore: stone });
		if (hit === null || !blockSet.has(hit.object)) continue;
		striking.delete(stone);
		const radius = Math.min(impact.reach + impact.perSpeed * (speed - impact.speed), impact.most);
		const point = triple(hit.point);
		const { loose, welds: n } = breakAround(point, radius, hit.object);
		shove([v[0], v[1], v[2]], point, loose, radius, hit.object);
		broken += n;
		record.broke += n;
		record.strike = { speed: +speed.toFixed(2), radius: +radius.toFixed(3), welds: n };
		if (n > 0) record.thrower?.xr.vibrate(0.7, 0.08);
	}
}

// The solver's own breaks: something heavy landing on a wall.
let broken = 0;
three.onJointBreak(({ id }) => {
	const weld = welds.find((w) => w.id === id);
	if (weld !== undefined) weld.id = null;
	broken++;
	if (lastThrow !== null) lastThrow.broke++;
});

// ---------------------------------------------------------------------------
// Soldiers: standing loose on the castle, not welded. One knocked down from
// where it stood, or over, scores.
// ---------------------------------------------------------------------------

const SOLDIER = [0.045, 0.1, 0.04];
const soldierShape = new three.BoxGeometry(...SOLDIER);
const headShape = new three.SphereGeometry(0.018, 10, 8);
const helmetShape = new three.ConeGeometry(0.021, 0.026, 8);
// Each soldier's body, its head, the height it stood at, and whether it is down.
let soldiers = [];

function placeSoldiers(feet) {
	for (const soldier of soldiers) {
		three.physics.remove(soldier.mesh);
		scene.remove(soldier.mesh);
	}
	soldiers = feet.map(([x, y, z], k) => {
		const mesh = new three.Mesh(soldierShape, matte);
		mesh.position.set(x * CELL, PLINTH_TOP + y * CELL + SOLDIER[1] / 2 + 0.001, CASTLE_Z + z * CELL);
		mesh.color = k % 2 === 0 ? [0.72, 0.12, 0.1] : [0.15, 0.22, 0.6];
		scene.add(mesh);
		const head = new three.Mesh(headShape, matte);
		head.position.set(0, SOLDIER[1] / 2 + 0.016, 0);
		head.color = [0.9, 0.72, 0.58];
		head.collides = false;
		mesh.add(head);
		const helmet = new three.Mesh(helmetShape, matte);
		helmet.position.set(0, SOLDIER[1] / 2 + 0.034, 0);
		helmet.color = [0.55, 0.56, 0.6];
		helmet.collides = false;
		mesh.add(helmet);
		three.physics.add(mesh, { shape: 'box', mass: 0.15, friction: 0.7, restitution: 0.05, angularDamping: 1 });
		return { mesh, head, stood: mesh.position.y, down: false };
	});
}

// Fallen from where it stood, or lying down: its head no longer above it.
function knockedDown(soldier) {
	const body = soldier.mesh.position.y;
	return body < soldier.stood - 0.12 || soldier.head.getWorldPosition().y - body < SOLDIER[1] * 0.25;
}

// ---------------------------------------------------------------------------
// The scoreboard: seven-segment digits of glowing boxes on a board beside the
// castle. The interface layer is drawn per eye, so the score lives in the world.
// ---------------------------------------------------------------------------

// Which of a digit's seven segments are lit, a to g as bits 0 to 6.
const SEGMENTS = [0x3f, 0x06, 0x5b, 0x4f, 0x66, 0x6d, 0x7d, 0x07, 0x7f, 0x6f];
const unlitSegment = new three.MeshLambertMaterial({});
const glow = (hex) => new three.MeshLambertMaterial({ emissive: hex, emissiveIntensity: 1.5 });
const segmentShapes = new Map();
function segmentShape(size) {
	const key = size.join();
	if (!segmentShapes.has(key)) segmentShapes.set(key, new three.BoxGeometry(...size));
	return segmentShapes.get(key);
}

class Digit {
	// `height` in metres, on `parent`'s front face; 0.6 of it wide.
	constructor(parent, x, y, height, lit) {
		const w = height * 0.6;
		const t = height * 0.13;
		const across = segmentShape([w - t * 1.2, t, 0.006]);
		const up = segmentShape([t, height / 2 - t * 0.8, 0.006]);
		const places = [
			[0, height / 2 - t / 2, across], [w / 2 - t / 2, height / 4, up], [w / 2 - t / 2, -height / 4, up],
			[0, -height / 2 + t / 2, across], [-w / 2 + t / 2, -height / 4, up], [-w / 2 + t / 2, height / 4, up],
			[0, 0, across],
		];
		this.segments = places.map(([sx, sy, shape]) => {
			const segment = new three.Mesh(shape, unlitSegment);
			segment.position.set(x + sx, y + sy, 0.013);
			segment.color = [0.09, 0.08, 0.07];
			segment.collides = false;
			parent.add(segment);
			return segment;
		});
		this.lit = lit;
		this.value = undefined;
	}

	// A digit 0 to 9, or null for none lit.
	show(n) {
		if (n === this.value) return;
		this.value = n;
		const bits = n === null ? 0 : SEGMENTS[n];
		this.segments.forEach((segment, k) => { segment.material = bits & (1 << k) ? this.lit : unlitSegment; });
	}
}

// A number in a row of digits, right-aligned with no leading zeros; null
// blanks it.
class Readout {
	constructor(parent, count, x, y, height, spacing, lit) {
		this.digits = [];
		for (let i = 0; i < count; i++) this.digits.push(new Digit(parent, x + (i - (count - 1) / 2) * spacing, y, height, lit));
	}

	show(value) {
		const count = this.digits.length;
		const text = value === null ? '' : String(Math.min(Math.max(Math.round(value), 0), 10 ** count - 1));
		this.digits.forEach((digit, i) => {
			const c = text.length - count + i;
			digit.show(c >= 0 ? +text[c] : null);
		});
	}
}

// Left of the castle and turned to face the line.
const BOARD_AT = [-1.25, 1.5, -2.3];
const BOARD = [0.6, 0.34, 0.02];
const boardYaw = Math.atan2(-BOARD_AT[0], -BOARD_AT[2]);
const board = box(BOARD, BOARD_AT, woodMaterial, [0.32, 0.23, 0.17], {}, boardYaw);
const pole = box([0.04, BOARD_AT[1] - BOARD[1] / 2, 0.04], [BOARD_AT[0], (BOARD_AT[1] - BOARD[1] / 2) / 2, BOARD_AT[2]], woodMaterial, [0.4, 0.3, 0.2], {}, boardYaw);
const scoreReadout = new Readout(board, 5, 0, 0.06, 0.13, 0.095, glow(0xffa030));
const levelDigit = new Digit(board, -0.24, -0.095, 0.075, glow(0x8fd16a));
const bestReadout = new Readout(board, 5, -0.02, -0.095, 0.075, 0.052, glow(0x5ab4ff));
const stonesDigit = new Digit(board, 0.235, -0.095, 0.075, glow(0xf0e6d0));
const stoneIcon = new three.Mesh(new three.SphereGeometry(0.018, 10, 8), pebbleMaterial);
stoneIcon.position.set(0.17, -0.095, 0.025);
stoneIcon.collides = false;
board.add(stoneIcon);

// ---------------------------------------------------------------------------
// The round: eight stones, a score, and the best kept per castle.
// ---------------------------------------------------------------------------

// Points for a kilogram of castle brought a metre down, and for a soldier.
// Height rather than "off the plinth": a wall knocked flat on the plinth is
// most of the way to knocked off it, and should score like it.
const POINTS = { perKgMetre: 100, soldier: 250 };
// Once the last stone is out and has stopped, the round ends when the score
// has not risen for SETTLE_SCORE seconds, or LONGEST_WAIT after the last throw.
// A piece counts from a centimetre down, so a castle settling scores nothing.
const SETTLE_SCORE = 1.5;
const LONGEST_WAIT = 8;
const STILL = 0.3;
const SLACK = 0.01;

let best = {};
try {
	best = three.save.read('best') ?? {};
} catch (e) {
	console.warn(`siege: no best scores: ${e.message}`);
}

const round = { state: 'play', score: 0, soldiersDown: 0, dropped: 0, left: STONES, moving: false, risenAt: 0, risenFrom: 0, doneAt: 0, newBest: false };
// Pieces off the plinth, for reading over MCP.
let down = 0;
let nextScore = 0;

// Stones still to throw: in the basket or in a hand.
function stonesLeft() {
	let n = hands.filter((hand) => hand.stone !== null).length;
	for (const stone of stones) if (stone.visible && inBasket(triple(stone.position), 0.02)) n++;
	return n;
}

function speedOf(object) {
	const v = three.physics.velocity(object);
	return v === null ? 0 : Math.hypot(v[0], v[1], v[2]);
}

function scoreRound() {
	let dropped = 0;
	let off = 0;
	for (const block of blocks) {
		const home = homes.get(block);
		// Off the edge of the world counts as on the ground.
		dropped += home.mass * Math.max(0, home.y - Math.max(block.position.y, 0) - SLACK);
		if (block.position.y < PLINTH_TOP) off++;
	}
	// A stone on the ground can no longer change the score.
	round.moving = stones.some((stone) => stone.visible && stone.position.y > STONE_RADIUS + 0.05
		&& !inBasket(triple(stone.position), 0.02) && speedOf(stone) > STILL);
	for (const soldier of soldiers) {
		if (soldier.down || !knockedDown(soldier)) continue;
		soldier.down = true;
		round.soldiersDown++;
		lastThrow?.thrower?.xr.vibrate(0.9, 0.12);
		console.log(`siege: a soldier is down, ${round.soldiersDown} of ${soldiers.length}`);
	}
	round.dropped = dropped;
	const score = Math.round(dropped * POINTS.perKgMetre + round.soldiersDown * POINTS.soldier);
	// Rubble creeps for a while; a rise that small is not the castle falling.
	if (score > round.risenFrom + Math.max(25, round.risenFrom * 0.02)) {
		round.risenAt = three.clock.time;
		round.risenFrom = score;
	}
	round.score = score;
	down = off;
}

function finishRound(now) {
	round.state = 'done';
	round.doneAt = now;
	const name = LEVELS[level].name;
	round.newBest = round.score > (best[name] ?? 0);
	if (round.newBest) {
		best[name] = round.score;
		try {
			three.save.write('best', best);
		} catch (e) {
			console.warn(`siege: the best score was not saved: ${e.message}`);
		}
	}
	for (const hand of hands) hand.xr.vibrate(round.newBest ? 1 : 0.5, round.newBest ? 0.4 : 0.15);
	console.log(`siege: ${name} is over, ${round.score} points${round.newBest ? ', a new best' : ''}, ${round.soldiersDown} of ${soldiers.length} soldiers down`);
}

// Once a frame: the score every tenth of a second, the end of the round once
// every stone is out and everything has stopped, and the board.
function tickRound(now) {
	if (round.state === 'play') {
		if (now >= nextScore) {
			nextScore = now + 0.1;
			scoreRound();
		}
		round.left = stonesLeft();
		const settled = !round.moving && now - round.risenAt >= SETTLE_SCORE;
		if (round.left === 0 && (settled || now - lastLaunch >= LONGEST_WAIT)) {
			scoreRound();
			finishRound(now);
		}
	}
	// The final score blinks for three seconds, then stays.
	const blinking = round.state === 'done' && now - round.doneAt < 3 && Math.floor((now - round.doneAt) / 0.3) % 2 === 1;
	scoreReadout.show(blinking ? null : round.score);
	bestReadout.show(best[LEVELS[level].name] ?? 0);
	levelDigit.show(level + 1);
	stonesDigit.show(round.left);
}

// Anything that rolled or slid off the edge of the ground falls for ever,
// awake; its body goes.
function sweepFallen() {
	for (const object of [...blocks, ...stones, ...soldiers.map((soldier) => soldier.mesh)]) {
		if (object.position.y > -2 || !object.visible) continue;
		three.physics.remove(object);
		object.visible = false;
	}
}

function startRound() {
	Object.assign(round, { state: 'play', score: 0, soldiersDown: 0, dropped: 0, left: STONES, moving: false, risenAt: 0, risenFrom: 0, doneAt: 0, newBest: false });
	down = 0;
	nextScore = 0;
	placeSoldiers(LEVELS[level].soldiers);
}

// ---------------------------------------------------------------------------
// Starting over.
// ---------------------------------------------------------------------------

// Puts the player's head on the line at the world's origin, facing the castle:
// the play area's centre is wherever the headset's guardian put it.
function stepUp() {
	const h = three.xr.head.position;
	const d = three.xr.head.direction;
	const t = three.camera.target;
	const yaw = three.camera.yaw * Math.PI / 180;
	// The head and its heading in tracking space: the rig's turn undone.
	const c = Math.cos(yaw), s = Math.sin(yaw);
	const turn = (x, z, cs, sn) => [x * cs + z * sn, -x * sn + z * cs];
	const [lx, lz] = turn(h.x - t.x, h.z - t.z, c, -s);
	const [fx, fz] = turn(d.x, d.z, c, -s);
	const facing = Math.atan2(-fx, -fz);
	const [wx, wz] = turn(lx, lz, Math.cos(-facing), Math.sin(-facing));
	three.camera.lookAt(-wx, 0, -wz);
	three.camera.orbit(-facing * 180 / Math.PI, 0, 0);
}

function reset() {
	for (const hand of hands) {
		hand.stone = null;
		hand.held.visible = false;
		hand.model.visible = true;
	}
	flying.clear();
	striking.clear();
	lastThrow = null;
	// At the right hip on a headset; at a desk, low and to the right of the view.
	let at = [0.3, DESK_EYE - 0.38, -0.75];
	if (three.xr.presenting) {
		stepUp();
		at = [0.3, Math.min(Math.max(three.xr.head.position.y - 0.75, 0.6), 1.1), -0.12];
	}
	buildBasket(at);
	fillBasket();
	const sections = buildCastle();
	broken = 0;
	startRound();
	console.log(`siege: ${LEVELS[level].name}, ${blocks.length} pieces in ${sections.length} sections, ${welds.length} welds`);
}

function build(name) {
	const k = LEVELS.findIndex((l) => l.name === name);
	if (k < 0) throw new RangeError(`siege.build: no castle '${name}', only ${LEVELS.map((l) => l.name).join(', ')}`);
	level = k;
	reset();
}

// For tuning over MCP. `ratings` is read when a castle is built, so change it
// and call `reset()`. `throwAt` sends a stone from the line at a point, for
// trying a rating without anybody throwing.
globalThis.siege = {
	tuning, throws, ratings, impact, round, best, reset, build,
	throwAt(target, speed = 7) {
		const stone = stones[aimed++ % STONES];
		const from = [0, 1.4, -0.4];
		const d = sub(target, from);
		const flat = Math.hypot(d[0], d[2]);
		// The launch angle that reaches the target at this speed, the flatter of the two.
		const g = 9.81;
		const s2 = speed * speed;
		const root = s2 * s2 - g * (g * flat * flat + 2 * d[1] * s2);
		if (root < 0) throw new RangeError(`siege.throwAt: ${speed} m/s cannot reach that`);
		const angle = Math.atan2(s2 - Math.sqrt(root), g * flat);
		const v = [d[0] / flat * Math.cos(angle) * speed, Math.sin(angle) * speed, d[2] / flat * Math.cos(angle) * speed];
		return launch(stone, from, v, [0, 0, 0], { hand: 'script', mode: 'aimed', t: three.clock.time });
	},
	get level() { return LEVELS[level].name; },
	get armed() { return armed; },
	get broken() { return broken; },
	get down() { return down; },
	get blocks() { return blocks; },
	get welds() { return welds; },
	get soldiers() { return soldiers; },
};

let aimed = 0;
let ready = false;
let waitingSince = null;

three.setAnimationLoop((ms) => {
	const now = ms / 1000;
	if (three.xr.presenting && three.xr.refreshRate !== HZ) three.xr.refreshRate = HZ;
	// A step every frame, so a stone leaves the hand as smoothly as it moved.
	three.physics.rate = three.xr.refreshRate || 60;
	three.physics.substeps = Math.ceil(LEVELS[level].substepRate / three.physics.rate);

	if (!ready) {
		if (!three.xr.presenting) {
			// At a desk: the head on the line, looking at the castle.
			three.camera.lookAt(0, DESK_EYE, 0);
			three.camera.orbit(0, 12, 0);
		} else {
			// The head is placed from the first frame the headset reports one.
			waitingSince ??= now;
			if (!three.xr.head.tracked && now - waitingSince < 2) return;
		}
		ready = true;
		reset();
		return;
	}
	if (!armed && three.clock.time - builtAt >= SETTLE) arm();

	for (const hand of hands) {
		const { xr } = hand;
		if (!xr.connected) {
			// The menu or lost tracking: the stone drops back to where it was held.
			if (hand.stone !== null) {
				hand.history = [];
				letGo(hand, now);
			}
			continue;
		}
		if (hand.stone !== null) remember(hand, now);
		if (xr.pressed('squeeze') && hand.stone === null) {
			const stone = stoneFor(hand);
			if (stone !== null) take(hand, stone);
		}
		if (xr.released('squeeze') && hand.stone !== null) letGo(hand, now);
	}

	if (three.xr.right.pressed('b') || three.xr.left.pressed('y')) reset();
	if (three.xr.left.pressed('x')) {
		level = (level + 1) % LEVELS.length;
		reset();
	}
	strike();
	sweepFallen();
	tickRound(three.clock.time);
});
