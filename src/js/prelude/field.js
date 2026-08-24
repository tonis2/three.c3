// A scalar grid in world coordinates — plan.md §18.4c and §18.4d.
//
// **One object for the terrain's heights and for a splat mask**, and that is
// the whole design rather than a convenience. The plan's answer to "ground
// matching some texture and depth" is that the two come from the same
// description: carve the channel and stroke the mask from the SAME polyline,
// so the mud is where the water is by construction instead of because two
// constants were kept in step. That only works if a height field and a mask
// field are the same kind of thing, so they are.
//
// The village wrote both halves by hand. `ground(x, z)` was a height
// function with a `flats[]` list consulted before the noise; `roadNear(x, z)`
// was point-to-polyline distance evaluated per tile; and `plot()` had to run
// before the tiles were laid or the buildings floated. Nothing in the engine
// could see that these described one surface, so nothing could catch them
// disagreeing — see scene/terrain.c3's header.
//
// Everything here is JavaScript over a Float64Array. There is no host call
// until `.texture()` or the TerrainGeometry that consumes it: a field is a
// description, exactly as a Primitive is, and descriptions do not live on the
// device.

import { DataTexture } from './texture.js';

// Squared distance from (px, pz) to the segment (ax, az)-(bx, bz), and how
// far along it the closest point was. The `t` is returned because a stroke
// with a feather needs the distance and a taper needs the position, and
// computing them twice is how they end up disagreeing at a joint.
function segmentDistance(px, pz, ax, az, bx, bz) {
	const dx = bx - ax;
	const dz = bz - az;
	const lengthSq = dx * dx + dz * dz;
	let t = lengthSq > 0 ? ((px - ax) * dx + (pz - az) * dz) / lengthSq : 0;
	if (t < 0) t = 0;
	else if (t > 1) t = 1;
	const cx = ax + dx * t;
	const cz = az + dz * t;
	return Math.hypot(px - cx, pz - cz);
}

// A polyline as a flat list of [x, z] pairs, however it was written.
// Accepts [[x, z], ...], [{x, z}, ...] and a flat [x, z, x, z, ...], for
// ConvexGeometry's reason: a script describing a road has one of those three
// in hand already and converting is the caller doing the engine's job.
function readPath(path, where) {
	if (!Array.isArray(path) || path.length === 0) {
		throw new TypeError(`${where}: wants a path — [[x, z], ...], [{x, z}, ...] or a flat [x, z, x, z, ...]`);
	}
	const out = [];
	if (typeof path[0] === 'number') {
		if (path.length % 2 !== 0) {
			throw new RangeError(`${where}: a flat path needs an even number of coordinates, got ${path.length}`);
		}
		for (let i = 0; i < path.length; i += 2) out.push([+path[i], +path[i + 1]]);
	} else {
		for (const point of path) {
			if (Array.isArray(point)) out.push([+point[0], +point[1]]);
			else if (point && typeof point === 'object') out.push([+point.x, +point.z]);
			else throw new TypeError(`${where}: a path point must be [x, z] or { x, z }, got ${point}`);
		}
	}
	for (const [x, z] of out) {
		if (!Number.isFinite(x) || !Number.isFinite(z)) {
			throw new RangeError(`${where}: a path point is not finite — (${x}, ${z})`);
		}
	}
	return out;
}

// 1 at the centre of the brush, 0 outside it, and a smoothstep across the
// feather. `feather` is in world units, measured inwards from the edge.
//
// Smoothstep rather than linear because these are BLENDED against existing
// values: a linear falloff leaves a visible crease where its derivative
// jumps, and on a height field that crease is a ridge you can see lit from
// across the map.
function falloff(distance, radius, feather) {
	if (distance >= radius) return 0;
	if (feather <= 0) return 1;
	const inner = radius - feather;
	if (distance <= inner) return 1;
	const t = 1 - (distance - inner) / feather;
	return t * t * (3 - 2 * t);
}

function finite(value, where, what) {
	const n = +value;
	if (!Number.isFinite(n)) throw new RangeError(`${where}: ${what} must be a finite number, got ${value}`);
	return n;
}

export class Field {
	// `segments` cells a side, so `(segments + 1)^2` samples — the same grid a
	// TerrainGeometry of the same segment count uses, which is what lets a
	// field be handed straight to one.
	constructor(options = {}) {
		const where = 'new three.Field({ width, depth, segments })';
		if (options === null || typeof options !== 'object') {
			throw new TypeError(`${where} takes an options object`);
		}
		this.width = finite(options.width ?? 100, where, 'width');
		this.depth = finite(options.depth ?? this.width, where, 'depth');
		if (this.width <= 0 || this.depth <= 0) {
			throw new RangeError(`${where}: width and depth must be positive, got ${this.width}x${this.depth}`);
		}
		const segments = Math.floor(+(options.segments ?? 64));
		if (!Number.isFinite(segments) || segments < 1 || segments > 512) {
			throw new RangeError(`${where}: segments must be between 1 and 512, got ${options.segments}`);
		}
		this.segments = segments;
		this.side = segments + 1;
		this.values = new Float64Array(this.side * this.side);
		if (options.value !== undefined) this.values.fill(finite(options.value, where, 'value'));
	}

	// World x, z of a sample. Public because a caller writing its own loop
	// over `values` needs the same mapping the stamps use, and re-deriving it
	// is how the two come to disagree.
	xAt(i) { return -this.width / 2 + (i / this.segments) * this.width; }
	zAt(j) { return -this.depth / 2 + (j / this.segments) * this.depth; }

	// ---------------------------------------------------------------
	// Whole-field
	// ---------------------------------------------------------------

	// `fill(v)` or `fill((x, z) => v)`. The callback takes WORLD coordinates,
	// not indices, so the same function can be reused for the mask, the
	// scatter and the carve without a change of frame.
	fill(source) {
		const f = typeof source === 'function' ? source : () => source;
		for (let j = 0; j < this.side; j++) {
			const z = this.zAt(j);
			for (let i = 0; i < this.side; i++) {
				this.values[j * this.side + i] = finite(f(this.xAt(i), z), 'field.fill', 'the value');
			}
		}
		return this;
	}

	// The same, added rather than replaced — layering a second octave of
	// noise, or lifting the whole field.
	add(source) {
		const f = typeof source === 'function' ? source : () => source;
		for (let j = 0; j < this.side; j++) {
			const z = this.zAt(j);
			for (let i = 0; i < this.side; i++) {
				this.values[j * this.side + i] += finite(f(this.xAt(i), z), 'field.add', 'the value');
			}
		}
		return this;
	}

	// A box blur, `passes` times. Two passes of a 3x3 box is close enough to a
	// Gaussian for a mask and is four adds a sample; a real Gaussian here
	// would be a kernel nobody could tune from a script.
	blur(passes = 1) {
		const n = Math.max(0, Math.floor(+passes));
		for (let pass = 0; pass < n; pass++) {
			const source = this.values.slice();
			for (let j = 0; j < this.side; j++) {
				for (let i = 0; i < this.side; i++) {
					let total = 0;
					let count = 0;
					for (let dj = -1; dj <= 1; dj++) {
						const jj = j + dj;
						if (jj < 0 || jj >= this.side) continue;
						for (let di = -1; di <= 1; di++) {
							const ii = i + di;
							if (ii < 0 || ii >= this.side) continue;
							total += source[jj * this.side + ii];
							count++;
						}
					}
					this.values[j * this.side + i] = total / count;
				}
			}
		}
		return this;
	}

	// ---------------------------------------------------------------
	// The stamps — §18.4c
	// ---------------------------------------------------------------

	// A building pad. `rect` is centred: { x, z, width, depth }.
	//
	// `y` defaults to the field's own average over the rect, which is the
	// thing a script almost always wants and had to compute by hand in the
	// village: a pad levelled to an arbitrary constant either floats or is
	// buried, and levelling to the mean puts it where the ground already was.
	flatten(rect, y = undefined, feather = 0) {
		const where = 'field.flatten({ x, z, width, depth }, y)';
		if (rect === null || typeof rect !== 'object') throw new TypeError(`${where} wants a rect`);
		const cx = finite(rect.x ?? 0, where, 'x');
		const cz = finite(rect.z ?? 0, where, 'z');
		const w = finite(rect.width ?? 0, where, 'width') / 2;
		const d = finite(rect.depth ?? rect.width ?? 0, where, 'depth') / 2;
		const soft = Math.max(0, +feather || 0);

		let level = y;
		if (level === undefined || level === null) {
			let total = 0;
			let count = 0;
			for (let j = 0; j < this.side; j++) {
				const z = this.zAt(j);
				if (Math.abs(z - cz) > d) continue;
				for (let i = 0; i < this.side; i++) {
					if (Math.abs(this.xAt(i) - cx) > w) continue;
					total += this.values[j * this.side + i];
					count++;
				}
			}
			level = count > 0 ? total / count : 0;
		}
		level = finite(level, where, 'y');

		for (let j = 0; j < this.side; j++) {
			const z = this.zAt(j);
			for (let i = 0; i < this.side; i++) {
				const x = this.xAt(i);
				// The rect's own falloff: distance outside the box, so the
				// feather runs around the whole perimeter including corners.
				const outX = Math.max(0, Math.abs(x - cx) - w);
				const outZ = Math.max(0, Math.abs(z - cz) - d);
				const outside = Math.hypot(outX, outZ);
				const k = soft > 0 ? falloff(outside, soft, soft) : (outside <= 0 ? 1 : 0);
				if (k <= 0) continue;
				const at = j * this.side + i;
				this.values[at] += (level - this.values[at]) * k;
			}
		}
		return this;
	}

	// A watercourse or a sunken road: lower the field along a path.
	//
	// `depth` is how far DOWN, because every caller says "carve a channel two
	// units deep" and a signed offset would be a sign somebody gets wrong once
	// per project. Use `stroke` with a positive value to raise.
	carve(path, width, depth, feather = 0) {
		const where = 'field.carve(path, width, depth)';
		const line = readPath(path, where);
		const half = finite(width, where, 'width') / 2;
		const drop = finite(depth, where, 'depth');
		const soft = Math.max(0, +feather || 0);
		return this._alongPath(line, half, soft, (value, k) => value - drop * k);
	}

	// Paint a value along a path — the mask half of the pair above, and the
	// reason `carve` and `stroke` take the same first three arguments: one
	// polyline, a shallow carve and a dirt stroke is a road.
	stroke(path, width, value, feather = 0) {
		const where = 'field.stroke(path, width, value)';
		const line = readPath(path, where);
		const half = finite(width, where, 'width') / 2;
		const paint = finite(value, where, 'value');
		const soft = Math.max(0, +feather || 0);
		return this._alongPath(line, half, soft, (existing, k) => existing + (paint - existing) * k);
	}

	// A clearing, a pond, a splat of moss.
	circle(x, z, radius, value, feather = 0) {
		const where = 'field.circle(x, z, radius, value)';
		const cx = finite(x, where, 'x');
		const cz = finite(z, where, 'z');
		const r = finite(radius, where, 'radius');
		const paint = finite(value, where, 'value');
		const soft = Math.max(0, +feather || 0);
		for (let j = 0; j < this.side; j++) {
			const dz = this.zAt(j) - cz;
			for (let i = 0; i < this.side; i++) {
				const k = falloff(Math.hypot(this.xAt(i) - cx, dz), r, soft);
				if (k <= 0) continue;
				const at = j * this.side + i;
				this.values[at] += (paint - this.values[at]) * k;
			}
		}
		return this;
	}

	// Shared by carve and stroke: walk the grid once, take the nearest
	// distance to any segment, and apply. Bounded to the path's own bounding
	// box plus the brush, so stamping a short road onto a big field does not
	// cost the whole field.
	_alongPath(line, half, soft, apply) {
		let minX = Infinity;
		let maxX = -Infinity;
		let minZ = Infinity;
		let maxZ = -Infinity;
		for (const [x, z] of line) {
			if (x < minX) minX = x;
			if (x > maxX) maxX = x;
			if (z < minZ) minZ = z;
			if (z > maxZ) maxZ = z;
		}
		const reach = half + soft;
		for (let j = 0; j < this.side; j++) {
			const z = this.zAt(j);
			if (z < minZ - reach || z > maxZ + reach) continue;
			for (let i = 0; i < this.side; i++) {
				const x = this.xAt(i);
				if (x < minX - reach || x > maxX + reach) continue;
				let nearest = Infinity;
				if (line.length === 1) {
					nearest = Math.hypot(x - line[0][0], z - line[0][1]);
				} else {
					for (let s = 0; s + 1 < line.length; s++) {
						const d = segmentDistance(x, z, line[s][0], line[s][1], line[s + 1][0], line[s + 1][1]);
						if (d < nearest) nearest = d;
					}
				}
				const k = falloff(nearest, half, soft);
				if (k <= 0) continue;
				const at = j * this.side + i;
				this.values[at] = apply(this.values[at], k);
			}
		}
		return this;
	}

	// ---------------------------------------------------------------
	// Reading it back
	// ---------------------------------------------------------------

	// Bilinear, and the same interpolation `terrain.heightAt` performs — so a
	// script can ask a field where the ground will be BEFORE uploading it,
	// which is what the village needed when it placed buildings during the
	// same pass that laid the tiles.
	valueAt(x, z) {
		const gx = ((+x + this.width / 2) / this.width) * this.segments;
		const gz = ((+z + this.depth / 2) / this.depth) * this.segments;
		const i = Math.floor(gx);
		const j = Math.floor(gz);
		const fx = gx - i;
		const fz = gz - j;
		const at = (ii, jj) => {
			const ci = ii < 0 ? 0 : (ii > this.segments ? this.segments : ii);
			const cj = jj < 0 ? 0 : (jj > this.segments ? this.segments : jj);
			return this.values[cj * this.side + ci];
		};
		const top = at(i, j) + (at(i + 1, j) - at(i, j)) * fx;
		const bottom = at(i, j + 1) + (at(i + 1, j + 1) - at(i, j + 1)) * fx;
		return top + (bottom - top) * fz;
	}

	// The extremes, which is what a caller normalising a noise field into a
	// 0..1 mask needs and would otherwise write a loop for every time.
	range() {
		let low = Infinity;
		let high = -Infinity;
		for (const v of this.values) {
			if (v < low) low = v;
			if (v > high) high = v;
		}
		return [low, high];
	}

	// Rescale into `[low, high]`. A no-op on a constant field rather than a
	// division by zero.
	normalize(low = 0, high = 1) {
		const [min, max] = this.range();
		const span = max - min;
		if (!(span > 0)) return this;
		const scale = (high - low) / span;
		for (let i = 0; i < this.values.length; i++) {
			this.values[i] = low + (this.values[i] - min) * scale;
		}
		return this;
	}

	clamp(low = 0, high = 1) {
		for (let i = 0; i < this.values.length; i++) {
			const v = this.values[i];
			this.values[i] = v < low ? low : (v > high ? high : v);
		}
		return this;
	}

	// ---------------------------------------------------------------
	// As a mask — §18.4d
	// ---------------------------------------------------------------

	// One field in all four channels, which is what a LayeredMaterial reading
	// `mask: 'r'` wants and is the single-layer case.
	//
	// Values are clamped to 0..1 on the way out rather than normalised: a
	// field that was authored as a weight is already in range, and silently
	// rescaling one that is not would make a mask whose meaning depended on
	// its own extremes.
	texture(options = null) { return Field.mask({ r: this, g: this, b: this, a: this }, options); }

	// Up to four fields packed into one RGBA image — the shape
	// `LayeredMaterial` consumes, with its per-channel layer selection.
	//
	// The four must share a resolution, and that is checked rather than
	// resampled: two masks at different segment counts is a mistake about
	// which field is which, and a silent resample would produce a picture
	// where one layer is subtly offset from the geometry it was carved with.
	static mask(channels, options = null) {
		const where = 'three.Field.mask({ r, g, b, a })';
		const order = ['r', 'g', 'b', 'a'];
		let side = 0;
		for (const key of order) {
			const field = channels?.[key];
			if (!field) continue;
			if (!(field instanceof Field)) throw new TypeError(`${where}: ${key} is not a three.Field`);
			if (side === 0) side = field.side;
			else if (field.side !== side) {
				throw new RangeError(
					`${where}: ${key} is ${field.side}x${field.side} and an earlier channel is ${side}x${side} — `
					+ 'pack fields of one resolution, or the layers will not line up with the ground'
				);
			}
		}
		if (side === 0) throw new TypeError(`${where}: give at least one of r, g, b, a`);

		const bytes = new Uint8Array(side * side * 4);
		for (let c = 0; c < 4; c++) {
			const field = channels[order[c]];
			if (!field) continue;
			for (let i = 0; i < side * side; i++) {
				const v = field.values[i];
				bytes[i * 4 + c] = v <= 0 ? 0 : (v >= 1 ? 255 : Math.round(v * 255));
			}
		}
		// Linear, always: a mask is a weight and not a colour, and reading one
		// through an sRGB curve would bend every blend it controls.
		return new DataTexture(bytes, side, side, { ...(options ?? {}), colorSpace: 'srgb-linear' });
	}
}

// Where to put a hundred trees — plan.md §18.6.
//
// **Written by hand three times before this existed**, twice in one file: a
// seeded LCG, rejection sampling, keep-out circles, point-to-polyline
// distance, and a slope test. It is the most repeated block in any scene with
// a landscape in it, and it is engine-shaped precisely because it wants
// `terrain.heightAt` and `normalAt` — which is why it lands here and not
// before §18.4b.
//
// Rejection sampling rather than a Poisson disc: `spacing` is a minimum
// separation and not a guarantee of one, the sampler gives up after a bounded
// number of tries, and it reports how many it placed. A Poisson disc would be
// better distributed and would need a grid, a queue and a tuning parameter
// nobody could see the effect of — and the thing being placed is a tree.
//
// **It returns placements, it does not build anything.** A scatter that
// created meshes would have to know about materials, colours and variants,
// and the caller almost always wants to vary those per point anyway. What
// comes back is `[{ x, y, z, normal, index }]`, and the loop that turns those
// into meshes is three lines the caller can read.
const LCG_A = 1103515245;
const LCG_C = 12345;
const LCG_M = 0x7fffffff;

export function scatter(options = {}) {
	const where = 'three.scatter({ count, bounds, onTerrain })';
	if (options === null || typeof options !== 'object') throw new TypeError(`${where} takes an options object`);

	const count = Math.floor(+(options.count ?? 0));
	if (!Number.isFinite(count) || count < 0) {
		throw new RangeError(`${where}: count must be a whole number, got ${options.count}`);
	}

	const terrain = options.onTerrain ?? null;
	if (terrain !== null && typeof terrain.heightAt !== 'function' && typeof terrain.valueAt !== 'function') {
		throw new TypeError(`${where}: onTerrain wants a three.TerrainGeometry, or a three.Field`);
	}
	// A Field answers `valueAt`; a TerrainGeometry answers `heightAt`. Both are
	// accepted because the caller may be scattering before the upload — which
	// the village needed, and which is the whole reason `Field.valueAt` exists.
	const heightOf = terrain === null
		? () => 0
		: (typeof terrain.heightAt === 'function' ? (x, z) => terrain.heightAt(x, z) : (x, z) => terrain.valueAt(x, z));
	const normalOf = terrain !== null && typeof terrain.normalAt === 'function'
		? (x, z) => terrain.normalAt(x, z)
		: () => [0, 1, 0];

	// The area to fill. A terrain's own extent by default, because scattering
	// over exactly the ground that exists is what every caller means and
	// restating its width in two places is how they drift apart.
	const area = options.bounds ?? (terrain !== null
		? { x: 0, z: 0, width: terrain.width ?? terrain.parameters?.width ?? 100, depth: terrain.depth ?? terrain.parameters?.depth ?? 100 }
		: { x: 0, z: 0, width: 100, depth: 100 });
	const cx = +(area.x ?? 0);
	const cz = +(area.z ?? 0);
	const halfW = +(area.width ?? 100) / 2;
	const halfD = +(area.depth ?? area.width ?? 100) / 2;

	const minY = options.minHeight ?? -Infinity;
	const maxY = options.maxHeight ?? Infinity;
	// As the cosine of the surface normal against +Y, so the caller writes
	// degrees and the test is one compare. 90 accepts anything.
	const maxSlope = Math.cos((+(options.maxSlope ?? 90) * Math.PI) / 180);
	const spacing = Math.max(0, +(options.spacing ?? 0));
	const accept = typeof options.accept === 'function' ? options.accept : null;

	// Keep-out: circles as { x, z, radius }, and paths as { path, width }.
	const avoid = Array.isArray(options.avoid) ? options.avoid : (options.avoid ? [options.avoid] : []);
	const circles = [];
	const paths = [];
	for (const item of avoid) {
		if (!item || typeof item !== 'object') continue;
		if (item.path) paths.push({ line: readPath(item.path, `${where}: avoid`), half: +(item.width ?? 0) / 2 });
		else circles.push({ x: +(item.x ?? 0), z: +(item.z ?? 0), radius: +(item.radius ?? 0) });
	}

	let seed = Math.floor(+(options.seed ?? 1)) & LCG_M;
	if (seed <= 0) seed = 1;
	const random = () => (seed = (seed * LCG_A + LCG_C) & LCG_M) / LCG_M;

	// Bounded, so a request that cannot be satisfied — a hundred trees in a
	// clearing that fits nine — ends rather than spinning. The caller sees a
	// short list and can read `length` off it, which is a better answer than a
	// hang and a better answer than silently packing them tighter.
	const tries = Math.max(64, count * 24);
	const placed = [];
	const spacingSq = spacing * spacing;

	for (let attempt = 0; attempt < tries && placed.length < count; attempt++) {
		const x = cx + (random() - 0.5) * 2 * halfW;
		const z = cz + (random() - 0.5) * 2 * halfD;

		const y = heightOf(x, z);
		if (y < minY || y > maxY) continue;

		const normal = normalOf(x, z);
		if (normal[1] < maxSlope) continue;

		let blocked = false;
		for (const c of circles) {
			if (Math.hypot(x - c.x, z - c.z) < c.radius) { blocked = true; break; }
		}
		if (!blocked) {
			for (const p of paths) {
				let nearest = Infinity;
				for (let s = 0; s + 1 < p.line.length; s++) {
					const d = segmentDistance(x, z, p.line[s][0], p.line[s][1], p.line[s + 1][0], p.line[s + 1][1]);
					if (d < nearest) nearest = d;
				}
				if (nearest < p.half) { blocked = true; break; }
			}
		}
		if (blocked) continue;

		if (spacingSq > 0) {
			for (const other of placed) {
				const dx = other.x - x;
				const dz = other.z - z;
				if (dx * dx + dz * dz < spacingSq) { blocked = true; break; }
			}
			if (blocked) continue;
		}

		// Last, because it is the only test that can run arbitrary script and
		// the cheap ones should have rejected most candidates before it.
		if (accept !== null && !accept(x, y, z, normal)) continue;

		placed.push({ x, y, z, normal, index: placed.length });
	}

	return placed;
}
