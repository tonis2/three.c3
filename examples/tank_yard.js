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
// `three` script before.
//
// The ground keeps a record of the fight. Tanks leave tread marks and every
// explosion leaves a scorch mark. Compute kernels write them into the image
// the ground material reads its layers from. See "The ground remembers".

// ---------------------------------------------------------------------------
// The level, as a picture
//
// `#` steel (forever), `b` brick (three hits), `P` where the player starts,
// `A` the eagle you are defending. Nothing marks an enemy spawn point: they
// come in along the top row, wherever it is open.
// ---------------------------------------------------------------------------

const MAP = [
	'###############',
	'#.....b.b.....#',
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
// The row enemies drive in on, counted from the steel wall at the top.
const SPAWN_ROW = 1;

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
//
// This is the yard as it is when a round STARTS. The material never reads it:
// it reads `groundMask` below, a copy the fight writes into.
const splatTex = paint(128, (u, v) => {
	const gravel = three.clamp01((three.fbm2(u * 3, v * 3, { octaves: 4, seed: 3, period: 3 }) - 0.42) * 3.4);
	const grass = three.clamp01((three.fbm2(u * 4 + 9, v * 4 + 5, { octaves: 3, seed: 9, period: 4 }) - 0.60) * 4.2);
	// Scorched towards the middle, where the fighting is.
	const d = Math.hypot(u - 0.5, v - 0.5) * 2;
	const scorch = three.clamp01((1 - d) * 1.3) * three.fbm2(u * 5, v * 5, { octaves: 2, seed: 17, period: 5 });
	return [gravel * 255, grass * 255, scorch * 255];
}, TABLE);

// ---------------------------------------------------------------------------
// The ground remembers
//
// The mask the ground material reads is not a picture made once. It is a
// `three.compute.image`, and two kernels write into it while the game runs:
//
//   - `sweep` copies `splatTex` into it at the start of each round, leaving
//     alpha at zero.
//   - `mark` puts a whole frame's marks into it in ONE dispatch. A moving
//     tank's two tracks go into ALPHA, which the ground draws as ruts, and
//     flatten the grass under them. A shell hit or a wreck burns into BLUE,
//     the scorch layer that was already there, and takes the grass with it.
//
// The image is 1024 texels across the 30-unit yard, about 34 to a unit, so a
// track's cleats are there to see. That is 64 times the pixels of `splatTex`.
// Rather than paint that many in JavaScript, the sweep filters the small image
// up on the GPU.
// ---------------------------------------------------------------------------

const GROUND = 1024;
const YARD = CELL * MAP.length;

const groundMask = three.compute.image({ width: GROUND, height: GROUND, format: 'rgba8' });

// The same mapping the kernels use (`world_of` below), run the other way for
// the script: which texel is under (x, z). Row 0 is the near edge, +Z,
// because the plane's uv puts v = 0 there.
const texelOf = (x, z) => [(x / YARD + 0.5) * GROUND, (0.5 - z / YARD) * GROUND];

const sweep = three.compute.kernel(`
image2d<rgba8> ground;
Sampler2D pristine;

struct ComputeIn { uint3 id @builtin(global_invocation_id); }

// Each thread fills a 4x4 block of texels, so the whole image is 65,536
// threads rather than one per texel.
fn void main(ComputeIn at) @compute @threads(8, 8, 1)
{
	int2 corner = int2(at.id.xy) * 4;
	for (int y = 0; y < 4; y++)
	{
		for (int x = 0; x < 4; x++)
		{
			int2 px = corner + int2(x, y);
			float2 uv = (float2(px) + float2(0.5, 0.5)) / ${GROUND}.0;
			ground[px] = float4(pristine.sample_lod(uv, 0.0).rgb, 0.0);
		}
	}
}`, { name: 'sweep' });

// How many marks one dispatch carries. They travel in the push block rather
// than in a buffer: writing a buffer is an upload the CPU waits for, and push
// constants are recorded with the dispatch for nothing. A push block of 128
// bytes is what every Vulkan device allows, and seven marks of 16 bytes plus
// two words of bookkeeping fits in it. Four tanks and three explosions is a
// busy frame, and a frame with more explosions than that leaves the rest for
// the next one.
const MARKS = 7;

// How far a tank's tracks reach from its centre, in units: half the 1.6-long
// footprint, and a little.
const TREAD_REACH = 0.9;

// How far a mark reaches in texels, the way the kernel's `reach_of` works it
// out: a scorch its radius, a tank `TREAD_REACH`, and one texel of margin.
const reachOf = (units) => Math.ceil(units * GROUND / YARD) + 1;

const mark = three.compute.kernel(`
image2d<rgba8> ground;

// A mark is four numbers. A tank's tracks are (x, z, heading x, heading z).
// A scorch is (x, z, radius, seed), and its bit in \`scorched\` says which kind
// a mark is.
struct Push @pushconstant
{
	float4 marks[${MARKS}];
	uint count;
	uint scorched;
}
Push push;

struct ComputeIn { uint3 id @builtin(global_invocation_id); }

// Where on the yard a texel is, in world units, and the texel under a point:
// the same mapping both ways.
fn float2 world_of(int2 px)
{
	float2 uv = (float2(px) + float2(0.5, 0.5)) / ${GROUND}.0;
	return float2(uv.x - 0.5, 0.5 - uv.y) * ${YARD.toFixed(1)};
}

fn int2 texel_of(float2 w)
{
	return int2(int(floor((w.x / ${YARD.toFixed(1)} + 0.5) * ${GROUND}.0)),
		int(floor((0.5 - w.y / ${YARD.toFixed(1)}) * ${GROUND}.0)));
}

fn bool is_scorch(uint i)
{
	return ((push.scorched >> i) & 1u) != 0u;
}

// How many texels mark i reaches from its centre, in each direction.
fn int reach_of(uint i)
{
	float units = is_scorch(i) ? push.marks[i].z : ${TREAD_REACH};
	return int(ceil(units * ${(GROUND / YARD).toFixed(6)})) + 1;
}

// Whether a texel is inside mark i's square.
fn bool covers(uint i, int2 px)
{
	int2 d = px - texel_of(push.marks[i].xy);
	int r = reach_of(i);
	return d.x >= -r && d.x <= r && d.y >= -r && d.y <= r;
}

// The dispatch is one slice per mark: \`id.z\` is the mark, and \`id.xy\` walks
// the square of texels around it. A slice is as wide as the widest mark this
// frame, so a thread past its own mark's square returns at once.
fn void main(ComputeIn at) @compute @threads(8, 8, 1)
{
	uint own = at.id.z;
	int r = reach_of(own);
	int2 offset = int2(at.id.xy) - int2(r, r);
	if (offset.x > r || offset.y > r) return;
	int2 px = texel_of(push.marks[own].xy) + offset;
	if (px.x < 0 || px.y < 0 || px.x >= ${GROUND} || px.y >= ${GROUND}) return;

	// Two marks close together have overlapping squares, and a texel in both
	// is reached by a thread in each slice. It belongs to the first mark that
	// covers it, and every other thread leaves it alone, so each texel is
	// written by exactly one thread and nothing races.
	for (uint j = 0u; j < own; j++)
	{
		if (covers(j, px)) return;
	}

	// The thread that owns the texel folds EVERY mark into it, not only its
	// own: the later mark whose square also covers it is counting on that.
	// Three numbers in, three out, and one read and one write of the image.
	float2 w = world_of(px);
	float grass = 1.0;
	float burn = 0.0;
	float rut = 0.0;
	for (uint i = 0u; i < push.count; i++)
	{
		float4 m = push.marks[i];
		float2 d = w - m.xy;
		if (is_scorch(i))
		{
			float k = length(d) / m.z;
			if (k >= 1.0) continue;
			float a = atan2(d.y, d.x);

			// A ragged edge and streaks thrown outwards. They come from a few
			// sines of the angle, with the seed turning each one, so no two
			// scars match.
			float edge = 0.8 + 0.12 * sin(a * 5.0 + m.w) + 0.08 * sin(a * 13.0 + m.w * 2.7);
			float streak = 0.7 + 0.3 * sin(a * 23.0 + m.w * 5.1);
			float b = (1.0 - smoothstep(edge * 0.45, edge, k)) * lerp(1.0, streak, smoothstep(0.25, 0.8, k));

			// Scorched, the grass gone, and the earth churned as treads churn it.
			grass = min(grass, 1.0 - b);
			burn = max(burn, b);
			rut = max(rut, 0.6 * b);
		}
		else
		{
			float2 ahead = m.zw;
			float along = abs(dot(d, ahead));
			float across = abs(dot(d, float2(-ahead.y, ahead.x)));

			// The tracks the tank is drawn with: 0.28 wide, 0.62 either side of
			// the middle, 1.6 long.
			float track = (1.0 - smoothstep(0.11, 0.15, abs(across - 0.62))) * (1.0 - smoothstep(0.72, 0.8, along));
			if (track <= 0.0) continue;

			// Cleats, four to a unit. They are laid out from the yard's origin,
			// not from the tank, so every frame's mark puts them in the same
			// place and a tank driving over its own tracks leaves one clean row
			// instead of a smear.
			float cleat = smoothstep(0.25, 0.55, abs(frac(dot(w, ahead) * 4.0) - 0.5) * 2.0);
			grass = min(grass, 1.0 - 0.85 * track);
			rut = max(rut, track * (0.5 + 0.5 * cleat));
		}
	}
	if (burn <= 0.0 && rut <= 0.0) return;

	// Max and min rather than adding, so marking the same spot again changes
	// nothing. A tank is marked every frame it moves, and its 1.6-unit
	// footprint covers each texel a dozen times as it drives over.
	float4 g = ground[px];
	ground[px] = float4(g.r, min(g.g, grass), max(g.b, burn), max(g.a, rut));
}`, { name: 'mark' });

// The push block, built in place every frame: `marks` as floats, then the
// count and the scorch bits after it. Handed to the dispatch as raw bytes,
// which it sends as they are.
const markBytes = new ArrayBuffer(MARKS * 16 + 16);
const markFloats = new Float32Array(markBytes);
const markWords = new Uint32Array(markBytes);
const markPush = new Uint8Array(markBytes);

// The yard's memory: the scars waiting to be burnt in, and the system that
// burns them and the tanks' tracks into the mask.
class Ground {
	// Scars waiting for the next frame: one { x, z, size, seed } per explosion.
	// `remember` marks as many as fit and leaves the rest here.
	static scars = [];

	// The seed is worked out from where the scar is, not drawn from
	// `three.seed`'s stream. Drawing from the stream would change every random
	// number after it, so the match would no longer play out the way it did
	// before the ground remembered anything.
	static scar(x, z, size) {
		Ground.scars.push({ x, z, size, seed: Math.abs(x * 12.9898 + z * 78.233) % 6.2832 });
	}

	// The yard is swept: the ground goes back to how `splatTex` paints it, and
	// any scars from the last frame of the old round go with the old round.
	static reset() {
		Ground.scars.length = 0;
		sweep.dispatch({ ground: groundMask, pristine: splatTex }, { threads: [GROUND / 4, GROUND / 4] });
	}

	// Every tank that moved or turned since it was last marked presses its
	// tracks into the mask, and every explosion since the last frame leaves a
	// scar. All of it goes in one dispatch, of one slice of threads per mark. A
	// tank's slice is 72x72, so four tanks and a shell hit is about 26,000
	// threads, and no frame goes past seven slices of that size.
	//
	// This runs once a frame, not once a step. A tank covers less than a fifth
	// of a unit in a frame, and the footprint it marks is 1.6 long, so the
	// tracks still come out unbroken.
	//
	// A dispatch only records work. `submitAsync` sends it and does not wait.
	// The frame drawn next is queued behind it, so that frame already sees the
	// new marks, and the CPU never stops for the GPU.
	@three.systems.frame
	static remember() {
		const scars = Ground.scars;
		let count = 0, scorched = 0, widest = 0;
		const add = (x, z, a, b, reach) => {
			markFloats.set([x, z, a, b], count * 4);
			widest = Math.max(widest, reachOf(reach));
			count++;
		};

		// A scar wider than a tank's tracks gets a frame to itself. Every slice
		// is as wide as the widest mark, so a wreck sharing a frame with four
		// tanks would make all five slices its size. The tanks skip that one
		// frame, and their next mark still overlaps their last.
		const small = (scar) => reachOf(scar.size) <= reachOf(TREAD_REACH);
		if (scars.length > 0 && !small(scars[0])) {
			const s = scars.shift();
			scorched = 1;
			add(s.x, s.z, s.size, s.seed, s.size);
		} else {
			for (const t of Tank) {
				if (count === MARKS) break;
				const p = t.object.position;
				const last = t.printed;
				if (last && last[0] === p.x && last[1] === p.z && last[2] === t.dir) continue;
				t.printed = [p.x, p.z, t.dir];
				add(p.x, p.z, DIRS[t.dir][0], DIRS[t.dir][1], TREAD_REACH);
			}
			while (count < MARKS && scars.length > 0 && small(scars[0])) {
				const s = scars.shift();
				scorched |= 1 << count;
				add(s.x, s.z, s.size, s.seed, s.size);
			}
		}

		if (count > 0) {
			markWords[MARKS * 4] = count;
			markWords[MARKS * 4 + 1] = scorched;
			// One slice per mark, each as wide as the widest mark's square: 2r + 1
			// texels, plus one in case the kernel's float rounding makes r one bigger.
			const groups = Math.ceil((2 * widest + 2) / 8);
			mark.dispatch({ ground: groundMask }, { workgroups: [groups, groups, count], push: markPush });
		}
		three.compute.submitAsync();
	}
}

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
//
// The mask is the image the kernels write. A material does not care that a
// compute image is not a picture loaded from disk. It samples one the same way.
const groundMat = new three.LayeredMaterial({
	mask: groundMask,
	layers: [
		{ name: 'dirt', mask: 'r', map: dirtTex, uvScale: 14 },
		{ name: 'grass', mask: 'g', map: grassTex, uvScale: 18 },
		// No map and no uv of its own: a tint through a mask is a stain. The
		// ruts are only there where the treads have written alpha.
		{ name: 'ruts', mask: 'a', tint: [0.50, 0.44, 0.38], blend: 'multiply' },
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
	fn float2 lut(float k)
	{
	    return float2(0.0078 + saturate(k) * 0.9844, 0.5);
	}

	fn float3 shade(Surface s)
	{
	    // s.color is this copy's own colour, raw and never folded into the
	    // albedo: rgb is the tint this blast was spawned with and ALPHA is how
	    // far through its life it is. One material, one draw call, twenty
	    // fireballs each at their own age.
	    float age = s.color.a;

	    // Two noise taps at different rates, multiplied — the cheapest thing
	    // that reads as burning rather than as a moving picture of fire.
	    float a = s.textures.noise_map.Sample(s.uv * 2.0 + float2(s.uniforms.t * 0.09, -s.uniforms.t * 0.31)).r;
	    float b = s.textures.noise_map.Sample(s.uv * 5.0 - float2(s.uniforms.t * 0.24, s.uniforms.t * 0.57)).r;
	    float heat = saturate(a * b * 3.6) * (1.0 - age);

	    // The shell burns away from the outside in. shade() returns rgb and
	    // never alpha, on purpose — a body that MEANS to make geometry vanish
	    // discards, which is what breaks the ball into tongues as it dies.
	    if (heat < 0.09) discard;
	    return s.textures.ramp_map.Sample(lut(heat)).rgb * s.color.rgb * heat * 2.8;
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

// Every tank's nodes hang off this one Group, which is what the `parent` on
// Tank below points at. A Group draws nothing and costs no draw call; what it
// buys is that the tanks are one thing the scene graph can see.
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
// `FOES_AT_ONCE` are standing in the yard from the first frame of a round;
// `FOE_EVERY` is how long one stays down before its replacement arrives.
const FOES_AT_ONCE = 3, FOES_PER_ROUND = 12, FOE_EVERY = 3.2;

// North, east, south, west — and the heading that faces each one, given that
// a box's local +Z is its front.
const DIRS = [[0, -1], [1, 0], [0, 1], [-1, 0]];
const HEADING = DIRS.map(([dx, dz]) => Math.atan2(dx, dz));
// The keys that drive the player, by direction: an arrow, and WASD beside it.
const DRIVE_KEYS = [['up', 'w'], ['right', 'd'], ['down', 's'], ['left', 'a']];

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
// Six classes, and the `@three.entity` on each one is the whole declaration —
// there is no registration call anywhere below. The decorator registers the
// class as it is defined, so the systems written on it as methods run from the
// first tick, whether or not one has been spawned yet.
//
// A system is a method marked `@three.systems.step` (the fixed clock, where the
// rules of the game go) or `.frame` (once per drawn frame): a static one runs
// once a tick, an instance one on every live entity. They run in the order the
// file declares them, and `three.systems.report()` names each one —
// `Tank.hunt`, `Blast.burn` — which is what makes a slow frame attributable.
// ---------------------------------------------------------------------------

// Steel: it stops everything and it never changes. It is its own class rather
// than a flag on Brick so that the rule about it can be one line.
@three.entity({ body: { shape: 'box', mass: 0 } })
class Steel extends three.Entity {

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
@three.entity({ body: { shape: 'box', mass: 0 } })
class Brick extends three.Entity {

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
@three.entity({ body: { shape: 'box', mass: 0 } })
class Eagle extends three.Entity {

	constructor(col, row) {
		super();
		this.object = new three.Mesh(UNIT, eagleMat);
		this.object.name = 'eagle';
		this.object.scale.set(1.6, 1.5, 1.6);
		this.object.position.set(cellX(col), 0.75, cellZ(row));
	}
}

// A tank. The drawn body is a Group of five tinted boxes, hung off `tanks`; the
// thing bullets actually hit is the invisible kinematic box `volume` declares
// beside it, carried every frame by the `Tank.follow` system the class installs.
@three.entity({
	parent: tanks,
	volume: { shape: 'box', size: [1.5, 1.0, 1.5], offset: [0, 0.5, 0] },
})
class Tank extends three.Entity {
	// The gun's cooldown is ticked by a system until it is disposed, so it goes
	// with the tank: `@three.owned` disposes it when the tank is shot, and when
	// `Tank.clear()` sweeps the yard for a new round.
	@three.owned gun = null;
	// Where `Ground.remember` last pressed this tank's tracks.
	printed = null;

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
		const p = this.object.position;
		Blast.spawn([p.x, 0.7, p.z], 2.2, 0.75, this.foe ? [1.0, 0.72, 0.34] : [1.0, 0.45, 0.30]);
		Ground.scar(p.x, p.z, 1.7);
		this.remove();
	}

	static *foes() {
		for (const t of Tank) if (t.foe) yield t;
	}

	// Whether any of `among` is standing within `reach` of a map square.
	static near(col, row, reach, among = Tank) {
		for (const t of among) {
			const c = t.centre();
			if (Math.hypot(c[0] - cellX(col), c[2] - cellZ(row)) < reach) return true;
		}
		return false;
	}

	// A spawn square with nobody standing on it, so a wave can put several
	// enemies in the yard at once instead of stacking them on one. Null when
	// every open square of the top row is still occupied, which `arrive` reads
	// as "ask again next tick" — sixty tries a second, and one that costs
	// nothing when there is nowhere to put a tank.
	static freeSquare() {
		for (let tries = 0; tries < 8; tries++) {
			const at = G.spawns[three.randInt(0, G.spawns.length - 1)];
			if (!Tank.near(at[0], at[1], 1.8)) return at;
		}
		return null;
	}

	// Enemies arrive along the top row: the whole opening wave at the top of a
	// round, so the yard starts as the fight it is rather than filling up over
	// ten empty seconds, and then one replacement at a time on the `FOE_EVERY`
	// clock.
	@three.systems.step({ when: () => !G.over })
	static arrive(dt) {
		G.since += dt;
		if (G.waiting <= 0) return;
		if ([...Tank.foes()].length >= FOES_AT_ONCE) { G.opening = false; return; }
		// The opening wave is gated by the yard rather than by the clock: every
		// tick that finds a free square adds one until `FOES_AT_ONCE` are standing.
		if (!G.opening && G.since < FOE_EVERY) return;
		const at = Tank.freeSquare();
		if (at === null) return;
		G.since = 0;
		G.waiting--;
		Tank.spawn(at[0], at[1], true);
		// A tank materialising is worth a puff of its own.
		Blast.spawn([cellX(at[0]), 0.7, cellZ(at[1])], 1.6, 0.5, [0.55, 0.80, 1.0]);
	}

	// The player. Keys are polled rather than latched, because driving is a
	// state and not an edge — a held key fires no repeat event.
	@three.systems.step({ when: () => G.player !== null })
	static steer(dt) {
		const dir = DRIVE_KEYS.findIndex((keys) => keys.some((k) => three.input.isDown(k)));
		G.player.drive(dt, dir);
		if (three.input.isDown('space')) G.player.fire();
	}

	// Each enemy. Drive at the eagle, turn when something is in the way, fire
	// on the gun's own cooldown — which is a `three.cooldown` rather than a
	// number counted down by hand, so a paused clock pauses it too.
	@three.systems.step
	hunt(dt) {
		if (!this.foe) return;
		this.turn -= dt;
		if (this.blocked || this.turn <= 0) {
			this.turn = three.randFloat(0.8, 2.2);
			const goal = G.eagle?.object.position;
			// Mostly towards the eagle, sometimes not — a pack that all takes
			// the same corner every round is a pack you have already beaten.
			this.dir = (goal && three.randFloat(0, 1) < 0.6)
				? towards(this.centre(), [goal.x, goal.y, goal.z])
				: three.randInt(0, 3);
		}
		this.drive(dt, this.dir);
		this.fire();
	}
}

// A shot. The only dynamic body in the world, and the only thing that raises a
// contact — which is what every rule below is written against.
// `collides: false` because a bullet is not scenery: without it a tank's
// movement sweep walks into its own shot and stops dead a metre from the barrel.
@three.entity({
	body: { shape: 'sphere', mass: 0.2, friction: 0, restitution: 0 },
	collides: false,
})
class Bullet extends three.Entity {
	constructor(from, dir) {
		super();
		this.foe = from.foe;
		this.velocity = [DIRS[dir][0] * SHOT_SPEED, 0, DIRS[dir][1] * SHOT_SPEED];
		this.object = new three.Mesh(SHOT, shotMat);
		this.object.name = 'shot';
		this.object.color = from.foe ? [1.0, 0.86, 0.55, 1] : [1.0, 0.95, 0.70, 1];
		this.object.position.set(...from.muzzle());
	}

	// Idempotent, because a shot that hits two things in one step is dispatched
	// twice: `remove()` answers false the second time, and that is the guard.
	pop(size = 0.9) {
		const p = this.object.position;
		if (!this.remove()) return;
		Blast.spawn([p.x, p.y, p.z], size, 0.35, [1.0, 0.78, 0.42]);
		Ground.scar(p.x, p.z, size * 0.75);
	}

	// A dynamic body's velocity is recomputed by the solver at the end of every
	// step, so re-asserting it is what keeps a shell flying dead straight
	// instead of drifting off the first thing it grazes.
	@three.systems.step
	fly() {
		three.physics.setVelocity(this.object, this.velocity);
	}
}

// Fire. No body, no collider, nothing to hit — it only draws.
@three.entity({ collides: false })
class Blast extends three.Entity {
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

	// One clock for every fireball: they share the material.
	@three.systems.frame
	static flicker() {
		blastMat.uniforms.t = three.clock.time;
	}

	// Everything here is per-copy — a scale and a colour — which is why twenty
	// blasts are still one draw call.
	@three.systems.frame
	burn(dt) {
		this.age += dt / this.life;
		if (this.age >= 1) { this.remove(); return; }
		// Fast out, then slowing: a square root is the whole easing curve.
		const s = this.size * (0.3 + 0.85 * Math.sqrt(this.age));
		this.object.scale.set(s, s, s);
		this.object.color = [this.tint[0], this.tint[1], this.tint[2], this.age];
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
	Ground.scar(eagle.object.position.x, eagle.object.position.z, 2.6);
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
	round: 0, kills: 0, lost: 0, broken: 0, waiting: FOES_PER_ROUND, opening: false,
	over: 0, since: 0, auto: true,
};

// The steel never changes, so it is built once and outlives every round.
MAP.forEach((line, row) => {
	[...line].forEach((c, col) => {
		if (c === '#') Steel.spawn(col, row);
		if (c === 'P') G.home = [col, row];
		// Every open square of the top row is somewhere an enemy can come in, so
		// a wave arrives across the whole width of the yard rather than out of
		// the same two corners every round. A wall is not a door, which is the
		// only thing this leaves out.
		if (row === SPAWN_ROW && c !== '#' && c !== 'b') G.spawns.push([col, row]);
	});
});

// Its systems are written after the tanks' and the shots', so they run after
// them: a round ends, and the player comes back, on what this tick did.
class Round {
	// A round is the bricks, the eagle and everybody standing in the yard.
	// Losing the eagle rebuilds all of it, which is what makes a long headless
	// run keep having something to look at.
	static start() {
		Bullet.clear();
		Blast.clear();
		Brick.clear();
		Tank.clear();
		Eagle.clear();
		eagleMat.layers[0].opacity = 0;
		Ground.reset();

		MAP.forEach((line, row) => {
			[...line].forEach((c, col) => {
				if (c === 'b') Brick.spawn(col, row);
				if (c === 'A') G.eagle = Eagle.spawn(col, row);
			});
		});
		G.player = Tank.spawn(G.home[0], G.home[1], false);
		G.waiting = FOES_PER_ROUND;
		G.opening = true;
		G.since = 0;
		G.over = 0;
		G.round++;
	}

	// The eagle's ruin layer is the one `animated: true` layer in the file, so
	// the fade is a uniform write per tick rather than a new pipeline.
	@three.systems.step
	static watch(dt) {
		if (G.over) {
			eagleMat.layers[0].opacity = three.moveTowards(eagleMat.layers[0].opacity, 1, dt * 2.2);
			if (three.clock.time - G.over > 3.5) Round.start();
			return;
		}
		// A player who has been shot comes back at the corner he started from,
		// once nothing hostile is standing on it.
		const [col, row] = G.home;
		if (!G.player && !Tank.near(col, row, 3, Tank.foes())) G.player = Tank.spawn(col, row, false);
	}
}

// ---------------------------------------------------------------------------
// The autopilot
//
// `--headless` has no keyboard, so a scene that can only be driven by one is a
// scene no batch run ever exercises. This presses the game's OWN keys through
// `three.input.press`, which goes down the same path a real one does — so every
// headless run is a playtest that says whether the level still plays.
//
// It keeps the set of keys it pressed itself: a key that is down and not in
// that set is somebody taking the controls, and it stands aside. `G.auto` is
// the switch, and `p` flips it.
// ---------------------------------------------------------------------------

class Autopilot {
	static held = new Set();

	static press(k) {
		if (Autopilot.held.has(k)) return;
		three.input.press(k);
		Autopilot.held.add(k);
	}

	static lift(k) {
		if (Autopilot.held.delete(k)) three.input.release(k);
	}

	static liftAll() {
		for (const k of [...Autopilot.held]) Autopilot.lift(k);
	}

	// Before the fire, as the old single system was: what it presses this
	// frame is what the next fixed step reads.
	@three.systems.frame({ before: 'Blast.flicker' })
	static drive() {
		for (const k of [...DRIVE_KEYS.flat(), 'space']) {
			if (three.input.isDown(k) && !Autopilot.held.has(k)) G.auto = false;
		}
		const me = G.player;
		if (!G.auto || !me) { Autopilot.liftAll(); return; }

		// Head for the nearest enemy; back off towards the eagle when there is
		// none in the yard yet.
		const at = me.centre();
		let target = G.eagle ? G.eagle.object.position : null;
		let best = Infinity;
		for (const t of Tank.foes()) {
			const p = t.object.position;
			const d = Math.hypot(p.x - at[0], p.z - at[2]);
			if (d < best) { best = d; target = p; }
		}
		let dir = target ? towards(at, [target.x, target.y, target.z]) : 0;
		// Blocked? Take the other axis rather than grinding against the wall.
		if (me.blocked) dir = (dir + (three.randFloat(0, 1) < 0.5 ? 1 : 3)) % 4;

		const key = DRIVE_KEYS[dir][0];
		for (const [arrow] of DRIVE_KEYS) if (arrow !== key) Autopilot.lift(arrow);
		Autopilot.press(key);
		// The gun's own cooldown decides the rate, so holding fire is enough.
		Autopilot.press('space');
	}

	@three.key('p', 'autopilot on/off')
	static toggle() {
		G.auto = !G.auto;
		Autopilot.liftAll();
	}
}

// ---------------------------------------------------------------------------
// Go
// ---------------------------------------------------------------------------

Round.start();

three.camera.lookAt(0, 0, 0);
three.camera.orbit(0, 62, 34);

three.debug.write({
	// Driving and firing are polled every step; the rest are `@three.key`s.
	keys: { 'arrows / wasd': 'drive', space: 'fire', ...three.keys() },
	map: `${MAP[0].length}x${MAP.length} cells of ${CELL}`,
	steel: Steel.count, brick: Brick.count, tanks: Tank.count,
	materials: 'ground, brick x3 and eagle are LayeredMaterial; the fire is a ShaderMaterial',
	ground: `${groundMask} written by the sweep and mark kernels, one mark dispatch a frame`,
	stats: three.stats(),
});
