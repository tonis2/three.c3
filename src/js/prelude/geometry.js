// three.c3 — the generated shapes, with Three.js's signatures and defaults.

import { refBounds } from './math.js';
import { catmullRom } from './field.js';

const H = globalThis.__three;

// Two boxes of *different* sizes are two assets and two draw calls. That is
// the one thing worth knowing before generating a hundred of them: a scene
// of one box scaled a hundred ways is one draw call, and a scene of a
// hundred BoxGeometries is a hundred. `mesh.scale` is the cheap axis.

// Shared by every shape: what it is called, what it was asked for, and the
// asset the host built or reused.
export class Geometry {
	constructor(type, name, parameters, [asset, assetGeneration]) {
		this.type = type;
		this.name = name;
		this.parameters = parameters;
		this.asset = asset;
		// The other half of the handle — see the Asset class. Carried here so
		// that a generated shape and a reference from asset.mesh(name) are
		// still the same shape of thing, which is what lets Mesh take either.
		this.assetGeneration = assetGeneration;
		// A generated shape is one mesh, always. Named `mesh` because that is
		// what an asset reference calls it, which is what lets Mesh take both.
		this.mesh = 0;
	}

	// The same question a MeshRef answers, for the same reason: a script that
	// scales a box to fit against something needs to know what it is fitting.
	// A parametric shape's box is not always the numbers it was asked for —
	// a TorusGeometry is `2 * (radius + tube)` across and a ConvexGeometry's
	// hull is whatever its point cloud turned out to be.
	get bounds() { return refBounds(this, `${this.type}.bounds`); }

	toJSON() { return { type: this.type, parameters: this.parameters }; }
	toString() { return `${this.type}(${Object.values(this.parameters).join(', ')})`; }
}

// A size that can produce triangles. Zero and negative are refused rather
// than clamped: `new three.BoxGeometry(0, 1, 1)` is a typo every time, and a
// box silently one unit wide is a bug an agent debugs by looking at the
// picture, which is the loop this API exists to keep short.
export function positiveSize(value, where, what) {
	const n = +value;
	if (!Number.isFinite(n) || n <= 0) {
		throw new RangeError(`${where}: ${what} must be a positive number, got ${value}`);
	}
	return n;
}

// Likewise, but zero is allowed — a cone is a cylinder with one radius of it.
function radius(value, where, what) {
	const n = +value;
	if (!Number.isFinite(n) || n < 0) {
		throw new RangeError(`${where}: ${what} cannot be negative, got ${value}`);
	}
	return n;
}

// `least` is 3 for anything going around an axis — two segments enclose no
// volume — and 1 for a subdivision that is allowed to be a single quad. The
// ceiling is MAX_PRIMITIVE_SEGMENTS in scene/primitive.c3, which clamps
// rather than throws; the throw is here so that asking for more is answered
// with a sentence instead of with a different shape.
function segmentCount(value, where, what, least) {
	const n = Math.floor(+value);
	if (!Number.isFinite(n) || n < least) {
		throw new RangeError(`${where}: ${what} must be at least ${least}, got ${value}`);
	}
	if (n > 512) {
		throw new RangeError(`${where}: ${what} is capped at 512 — ${n} segments is a mesh nobody meant to ask for`);
	}
	return n;
}

export class BoxGeometry extends Geometry {
	constructor(width = 1, height = 1, depth = 1, widthSegments = 1, heightSegments = 1, depthSegments = 1) {
		const where = 'new three.BoxGeometry(width, height, depth)';
		const w = positiveSize(width, where, 'width');
		const h = positiveSize(height, where, 'height');
		const d = positiveSize(depth, where, 'depth');
		const ws = segmentCount(widthSegments, where, 'widthSegments', 1);
		const hs = segmentCount(heightSegments, where, 'heightSegments', 1);
		const ds = segmentCount(depthSegments, where, 'depthSegments', 1);
		super(
			'BoxGeometry', 'box',
			{ width: w, height: h, depth: d, widthSegments: ws, heightSegments: hs, depthSegments: ds },
			H.primitive('box', w, h, d, ws, hs, ds, false),
		);
	}
}

export class SphereGeometry extends Geometry {
	constructor(radius_ = 1, widthSegments = 32, heightSegments = 16) {
		const where = 'new three.SphereGeometry(radius, widthSegments, heightSegments)';
		const r = positiveSize(radius_, where, 'radius');
		const ws = segmentCount(widthSegments, where, 'widthSegments', 3);
		const hs = segmentCount(heightSegments, where, 'heightSegments', 2);
		super(
			'SphereGeometry', 'sphere',
			{ radius: r, widthSegments: ws, heightSegments: hs },
			H.primitive('sphere', r, 0, 0, ws, hs, 1, false),
		);
	}
}

export class PlaneGeometry extends Geometry {
	constructor(width = 1, height = 1, widthSegments = 1, heightSegments = 1) {
		const where = 'new three.PlaneGeometry(width, height)';
		const w = positiveSize(width, where, 'width');
		const h = positiveSize(height, where, 'height');
		const ws = segmentCount(widthSegments, where, 'widthSegments', 1);
		const hs = segmentCount(heightSegments, where, 'heightSegments', 1);
		super(
			'PlaneGeometry', 'plane',
			{ width: w, height: h, widthSegments: ws, heightSegments: hs },
			H.primitive('plane', w, h, 0, ws, hs, 1, false),
		);
	}
}

export class CylinderGeometry extends Geometry {
	constructor(radiusTop = 1, radiusBottom = 1, height = 1, radialSegments = 32, heightSegments = 1, openEnded = false) {
		const where = 'new three.CylinderGeometry(radiusTop, radiusBottom, height)';
		const rt = radius(radiusTop, where, 'radiusTop');
		const rb = radius(radiusBottom, where, 'radiusBottom');
		if (rt === 0 && rb === 0) {
			throw new RangeError(`${where}: both radii are zero, which describes a line rather than a shape`);
		}
		const h = positiveSize(height, where, 'height');
		const rs = segmentCount(radialSegments, where, 'radialSegments', 3);
		const hs = segmentCount(heightSegments, where, 'heightSegments', 1);
		super(
			'CylinderGeometry', 'cylinder',
			{ radiusTop: rt, radiusBottom: rb, height: h, radialSegments: rs, heightSegments: hs, openEnded: !!openEnded },
			H.primitive('cylinder', rt, rb, h, rs, hs, 1, !openEnded),
		);
	}
}

// Three.js's ConeGeometry is a CylinderGeometry with no top, and so is this
// one — right down to sharing its asset. `new three.ConeGeometry(1, 2)` and
// `new three.CylinderGeometry(0, 1, 2)` are the same triangles, so they are
// the same upload and, placed together, the same draw call.
export class ConeGeometry extends Geometry {
	constructor(radius_ = 1, height = 1, radialSegments = 32, heightSegments = 1, openEnded = false) {
		const where = 'new three.ConeGeometry(radius, height)';
		const r = positiveSize(radius_, where, 'radius');
		const h = positiveSize(height, where, 'height');
		const rs = segmentCount(radialSegments, where, 'radialSegments', 3);
		const hs = segmentCount(heightSegments, where, 'heightSegments', 1);
		super(
			'ConeGeometry', 'cone',
			{ radius: r, height: h, radialSegments: rs, heightSegments: hs, openEnded: !!openEnded },
			H.primitive('cylinder', 0, r, h, rs, hs, 1, !openEnded),
		);
	}
}

export class TorusGeometry extends Geometry {
	constructor(radius_ = 1, tube = 0.4, radialSegments = 12, tubularSegments = 48) {
		const where = 'new three.TorusGeometry(radius, tube)';
		const r = positiveSize(radius_, where, 'radius');
		const t = positiveSize(tube, where, 'tube');
		const rs = segmentCount(radialSegments, where, 'radialSegments', 3);
		const ts = segmentCount(tubularSegments, where, 'tubularSegments', 3);
		// Three.js's constructor takes radialSegments (around the tube) before
		// tubularSegments (around the ring), and the builder wants them the
		// other way up. The swap is here so the constructor keeps the order an
		// agent has memorized.
		super(
			'TorusGeometry', 'torus',
			{ radius: r, tube: t, radialSegments: rs, tubularSegments: ts },
			H.primitive('torus', r, t, 0, ts, rs, 1, false),
		);
	}
}

// A cloud of points, on the way to a hull. Accepts what a script is likely
// to have: an array of Vector3s (Three.js's own signature), an array of
// {x, y, z} or [x, y, z], or a flat array or Float32Array of numbers. All
// four flatten to the same thing, which is what the host reads.
//
// The walk validates while it flattens rather than in a pass of its own,
// so a bad component is reported with the index of the point it was in —
// which is the one fact that makes a generated cloud debuggable.
function readPointCloud(value, where) {
	if (value === null || value === undefined) {
		throw new TypeError(`${where} wants an array of points`);
	}

	const flat = [];
	const isFlat = ArrayBuffer.isView(value)
		|| (Array.isArray(value) && (value.length === 0 || typeof value[0] === 'number'));

	if (isFlat) {
		if (value.length % 3 !== 0) {
			throw new RangeError(
				`${where}: a flat array of coordinates must have a length that is a multiple of 3, got ${value.length}`
			);
		}
		for (let i = 0; i < value.length; i++) {
			const n = +value[i];
			if (!Number.isFinite(n)) {
				throw new TypeError(`${where}: coordinate ${i} is ${value[i]}, which is not a finite number`);
			}
			flat.push(n);
		}
	} else if (Array.isArray(value)) {
		for (let i = 0; i < value.length; i++) {
			const p = value[i];
			let x, y, z;
			if (Array.isArray(p) && p.length >= 3) {
				[x, y, z] = p;
			} else if (p !== null && typeof p === 'object' && 'x' in p) {
				({ x, y, z } = p);
			} else {
				throw new TypeError(
					`${where}: point ${i} is neither a Vector3, an {x, y, z} nor an [x, y, z]`
				);
			}
			if (!(Number.isFinite(+x) && Number.isFinite(+y) && Number.isFinite(+z))) {
				throw new TypeError(`${where}: point ${i} has a non-finite component`);
			}
			flat.push(+x, +y, +z);
		}
	} else {
		throw new TypeError(
			`${where} wants an array of Vector3s, of [x, y, z], or a flat array of coordinates`
		);
	}

	const count = flat.length / 3;
	if (count < 4) {
		throw new RangeError(
			`${where}: a convex hull needs at least 4 points to enclose a volume, got ${count}`
		);
	}
	if (count > 65536) {
		throw new RangeError(
			`${where}: capped at 65536 points, got ${count} — decimate the cloud first, `
			+ 'the hull of a subset of a convex body is the same hull'
		);
	}
	return flat;
}

// The convex hull of a point cloud — Three.js's ConvexGeometry, and the only
// shape here whose argument is an array rather than a number.
//
// It is still a description and not a buffer: the points are what the hull
// is computed *from*, most of them are discarded, and nothing can read a
// vertex back out. `scene/convex.c3` carries the full argument for why this
// leaves "JS may not touch vertices" standing, and why the result is flat
// shaded — a hull's faces meet at creases, and smoothing them removes the only
// thing that makes it read as a cut stone. The uvs are a per-face planar
// projection for the same reason: face-on, one unit per unit, and no unwrap of
// an arbitrary hull to seam.
//
// Handing the same points over twice is one asset and one draw call, as with
// every other geometry. The key is bit-exact rather than rounded, though, so
// two clouds built by two runs of Math.random() are two assets: build the
// array once and reuse it if you want the copies instanced.
export class ConvexGeometry extends Geometry {
	constructor(points) {
		const where = 'new three.ConvexGeometry(points)';
		const flat = readPointCloud(points, where);
		super(
			'ConvexGeometry', 'convex',
			{ points: flat.length / 3 },
			H.convex(flat),
		);
	}
}

// -----------------------------------------------------------------------
// Helpers
//
// The shapes a scene is debugged with rather than built out of: where a box
// ends, where a pivot is, where the ground is, and which triangles a mesh
// actually has. `scene/lines.c3` carries the design; the part that matters
// from here is that **a helper is an ordinary Mesh over an ordinary asset**
// and behaves like one in every direction that has been thought about.
//
// - A thousand box helpers are one draw call. They share the unit-cube
//   asset and differ by transform, which is the same claim the kit pieces
//   make.
// - `helper.color` is per copy and free, which is why an AxesHelper is three
//   meshes over *one* segment asset rather than three assets.
// - `scene.remove(helper)` works, and `three.unloadUnused()` gives the
//   memory back, because there is nothing special about these assets.
// - A helper is not pickable. `upload_built` skips the picking tree for a
//   line mesh, so a click goes through the box onto the thing it is drawn
//   around.
//
// **They draw over everything, on purpose.** The line pipeline tests no
// depth: a box helper exists to answer "where did this go", and the times
// that is asked are the times the thing is inside a wall — where a
// depth-tested helper would be hidden by exactly the geometry being asked
// about. Three.js's helpers are depth-tested and these are not.
//
// **Being ordinary cuts both ways: a helper is inside the boxes.** It draws,
// so it is in `boundingBox()`, in `boundsInParent()` of whatever it hangs
// from, and in `three.camera.frameAll()`. Parent an AxesHelper to a piece
// and the piece measures bigger than it is — so align first and add helpers
// after, or hang them from a Group of their own.

// A surface rather than a pile of boxes — plan.md §18.4.
//
// The one generated shape that carries data instead of parameters, and the
// one that answers questions afterwards. `heightAt` and `normalAt` read the
// same grid the mesh was built from, through the same interpolation, so a
// script cannot place something on ground that disagrees with what is drawn
// — which is exactly what a hand-written `ground(x, z)` beside a hand-built
// tile grid could do at any moment, and did.
export class TerrainGeometry extends Geometry {
	constructor(options = {}) {
		const where = 'new three.TerrainGeometry({ width, depth, segments, heights })';
		if (options === null || typeof options !== 'object') {
			throw new TypeError(`${where} takes an options object`);
		}

		const width = positiveSize(options.width ?? 100, where, 'width');
		const depth = positiveSize(options.depth ?? width, where, 'depth');
		const segments = segmentCount(options.segments ?? 32, where, 'segments', 1);
		const skirt = options.skirt === undefined ? 0 : +options.skirt;
		if (!Number.isFinite(skirt) || skirt < 0) {
			throw new RangeError(`${where}: skirt cannot be negative, got ${options.skirt}`);
		}

		const side = segments + 1;
		const wanted = side * side;
		const heights = new Float64Array(wanted);
		const source = options.heights;

		if (typeof source === 'function') {
			// **Sampled here rather than passed across**, because a callback that
			// crossed into the host would be one QuickJS call per sample — a
			// 256-segment field is sixty-six thousand of them — and because a
			// script's height function is the most natural thing in the world to
			// write in terms of Math.sin and a couple of closures.
			//
			// The arguments are WORLD x and z, not grid indices: a height function
			// written against the same coordinates everything else in the scene
			// uses is one that can be reused for the mask, the scatter and the
			// carve without a change of frame.
			for (let j = 0; j < side; j++) {
				const z = -depth / 2 + (j / segments) * depth;
				for (let i = 0; i < side; i++) {
					const x = -width / 2 + (i / segments) * width;
					const y = +source(x, z);
					if (!Number.isFinite(y)) {
						throw new RangeError(
							`${where}: heights(${x}, ${z}) returned ${y} — every sample must be a finite number`
						);
					}
					heights[j * side + i] = y;
				}
			}
		} else if (source === undefined || source === null) {
			// Flat. A terrain with no heights is a plane you can stand on and
			// stamp into later, which is a perfectly ordinary thing to want and
			// is not worth an error.
		} else if (typeof source.valueAt === 'function' && typeof source.values === 'object') {
			// A three.Field, which is the authoring path: fill it with noise,
			// flatten the pads, carve the river, hand it over. Checked
			// structurally rather than with `instanceof` so that geometry.js
			// does not have to import field.js and field.js does not have to
			// avoid importing geometry.js.
			if (source.segments !== segments || source.values.length !== wanted) {
				throw new RangeError(
					`${where}: the Field is ${source.segments} segments and the terrain is ${segments} — `
					+ 'build both at one resolution, or the surface will not be the field you stamped'
				);
			}
			for (let i = 0; i < wanted; i++) heights[i] = source.values[i];
		} else if (typeof source.length === 'number') {
			if (source.length !== wanted) {
				throw new RangeError(
					`${where}: ${segments} segments wants ${wanted} heights ((segments + 1) squared), got ${source.length}`
				);
			}
			for (let i = 0; i < wanted; i++) {
				const y = +source[i];
				if (!Number.isFinite(y)) {
					throw new RangeError(`${where}: heights[${i}] is ${source[i]} — every sample must be a finite number`);
				}
				heights[i] = y;
			}
		} else {
			throw new TypeError(`${where}: heights must be an array of numbers or a function (x, z) => y`);
		}

		super(
			'TerrainGeometry',
			options.name ?? '',
			{ width, depth, segments, skirt },
			H.terrain(width, depth, segments, skirt, heights)
		);
	}

	// The ground at a world (x, z) — §18.4b, and the piece everything that
	// stands outdoors needs. Bilinear, so it is continuous: a query that
	// snapped to the nearest sample would put a walker through a staircase on
	// a smooth hill, which is the defect this shape exists to remove.
	//
	// Outside the field the edges extend outwards, so walking off the map
	// keeps the ground it last stood on rather than dropping through zero.
	heightAt(x, z) { return this._at(x, z, 'heightAt')[0]; }

	// The surface normal there, unit length, blended exactly as the shading
	// blends it — so something laid flush with the ground agrees with what
	// the light does to it.
	normalAt(x, z) {
		const [, nx, ny, nz] = this._at(x, z, 'normalAt');
		return [nx, ny, nz];
	}

	_at(x, z, what) {
		const answer = H.terrainAt(this.asset, this.assetGeneration, +x, +z);
		if (answer.length === 0) {
			throw new Error(
				`terrain.${what}() — this handle no longer names a live terrain, `
				+ 'which happens after scene.unload() or three.unloadUnused()'
			);
		}
		return answer;
	}
}

// A flat or ground-draped strip that follows a curve — a road, a river, a
// path, a wall. The shape a hand-written landscape scene reaches for once it
// has a curve to follow, and the thing that makes it smooth: a road built from
// per-tile boxes is a staircase, and a RibbonGeometry along `three.catmullRom`'s
// centerline is the same road as one mesh.
//
// **It is authored from sparse control points, not from a finished polyline.**
// `path` is bent by centripetal Catmull-Rom internally (same curve as
// `three.catmullRom`), sampling `samples` cross-sections per control segment.
// So the agent writes the bends it can see and the ribbon is smooth everywhere
// between them — there is no two-step "smooth then build" to get right, and no
// way to hand over a polyline whose corners still show.
//
// Two modes, chosen by the options:
// - **Flat (`y`).** The whole strip sits at one height, whatever the ground
//   does. That is a river or a pond — a water surface is a plane, not a drape.
// - **Draped (`terrain`).** Every vertex samples `terrain.heightAt(x, z)` (or
//   `Field.valueAt`), so the strip hugs the ground. That is a road or a path.
//   `lift` raises it a hair so it does not z-fight the surface it lies on.
//   `terrain` may be a `TerrainGeometry` or a `Field`; both are accepted
//   because authoring is sometimes before the upload.
//
// The cross-section is `columns` vertices across the width, which matters on a
// draped strip: two corners is a straight chord across a crowned or banked
// surface, while three or five let the road follow the camber. `width` is the
// full width in world units, `columns` is how the width is sampled.
//
// It is one asset and one draw call per unique ribbon, like every other shape.
// The uv runs u across the width and v along the length, so a texture flows
// with the road instead of tiling across it.
export class RibbonGeometry extends Geometry {
	constructor(options = {}) {
		const where = 'new three.RibbonGeometry({ path, width, y, terrain, lift, samples, columns })';
		if (options === null || typeof options !== 'object') {
			throw new TypeError(`${where} takes an options object`);
		}

		const width = positiveSize(options.width ?? 1, where, 'width');
		const half = width / 2;
		const columns = Math.max(2, Math.floor(+(options.columns ?? 2)));
		if (!Number.isFinite(columns) || columns > 64) {
			throw new RangeError(`${where}: columns is between 2 and 64, got ${options.columns}`);
		}
		const samples = Math.max(2, Math.floor(+(options.samples ?? 24)));
		if (!Number.isFinite(samples)) {
			throw new RangeError(`${where}: samples must be at least 2, got ${options.samples}`);
		}
		const lift = options.lift === undefined ? 0 : +options.lift;
		if (!Number.isFinite(lift)) throw new RangeError(`${where}: lift must be a finite number, got ${options.lift}`);

		const terrain = options.terrain ?? null;
		const heightOf = terrain === null
			? null
			: (typeof terrain.heightAt === 'function' ? (x, z) => terrain.heightAt(x, z)
				: (typeof terrain.valueAt === 'function' ? (x, z) => terrain.valueAt(x, z) : null));
		if (terrain !== null && heightOf === null) {
			throw new TypeError(`${where}: terrain wants a three.TerrainGeometry or a three.Field`);
		}
		const base = options.y === undefined || options.y === null ? 0 : +options.y;
		if (!Number.isFinite(base)) throw new RangeError(`${where}: y must be a finite number, got ${options.y}`);

		// Smooth the sparse control points into a dense centerline. `catmullRom`
		// already validated the path shape, so this is thrown only for a bad
		// `samples` — which is the caller's, reported above.
		const center = catmullRom(options.path, { samples });

		const rows = center.length;
		const positions = [];
		const uvs = [];

		// Cross-section vertices, laid out row-major: `rows` along the path,
		// `columns` across it. Easing the offset across the width puts the
		// outmost column at each edge and anything between them on the camber.
		for (let k = 0; k < rows; k++) {
			const [cx, cz] = center[k];
			const prev = center[k > 0 ? k - 1 : 0];
			const next = center[k < rows - 1 ? k + 1 : rows - 1];
			let tx = next[0] - prev[0];
			let tz = next[1] - prev[1];
			const tl = Math.hypot(tx, tz) || 1;
			tx /= tl;
			tz /= tl;
			// A 90° offset in the xz plane: the across direction, unit length.
			const wx = -tz;
			const wz = tx;
			for (let c = 0; c < columns; c++) {
				const across = columns === 1 ? 0.5 : c / (columns - 1);
				const off = (across - 0.5) * width;
				const x = cx + wx * off;
				const z = cz + wz * off;
				const y = heightOf === null ? base + lift : heightOf(x, z) + lift;
				positions.push(x, y, z);
				uvs.push(across, rows > 1 ? k / (rows - 1) : 0);
			}
		}

		// Normals from the strip itself, not a guess: at each vertex the across
		// run and the along run meet on the surface, and their cross product is
		// the unit normal the light should treat as up. Central differences,
		// degraded to forward/backward at an edge by clamping the far neighbour
		// to the near one — which is the same trick Heightfield.grid_normal uses,
		// and keeps an edge vertex from reading itself as both ends of a zero
		// vector. Flipped if it points down, so a camera under a banked ribbon
		// still sees the top lit as the top.
		const normals = new Array(rows * columns * 3);
		for (let k = 0; k < rows; k++) {
			for (let c = 0; c < columns; c++) {
				const at = (r, cc) => (
					Math.max(0, Math.min(rows - 1, r)) * columns
					+ Math.max(0, Math.min(columns - 1, cc))
				) * 3;
				// across = P(k, c+1) - P(k, c-1); along = P(k+1, c) - P(k-1, c).
				const iM = at(k, c - 1);
				const iP = at(k, c + 1);
				const jM = at(k - 1, c);
				const jP = at(k + 1, c);
				const ax = positions[iP] - positions[iM];
				const ay = positions[iP + 1] - positions[iM + 1];
				const az = positions[iP + 2] - positions[iM + 2];
				const bx = positions[jP] - positions[jM];
				const by = positions[jP + 1] - positions[jM + 1];
				const bz = positions[jP + 2] - positions[jM + 2];
				// across x along, so a strip lying in xz (across +z, along +x)
				// comes out +y before the flip guard.
				let nx = ay * bz - az * by;
				let ny = az * bx - ax * bz;
				let nz = ax * by - ay * bx;
				const nl = Math.hypot(nx, ny, nz) || 1;
				if (ny < 0) { nx = -nx; ny = -ny; nz = -nz; }
				const a = at(k, c);
				normals[a] = nx / nl;
				normals[a + 1] = ny / nl;
				normals[a + 2] = nz / nl;
			}
		}

		super(
			'RibbonGeometry', 'ribbon',
			{ width, samples, columns, rows },
			H.ribbon(positions, normals, uvs, columns, rows),
		);
	}
}
