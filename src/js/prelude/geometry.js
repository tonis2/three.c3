// three.c3 — the generated shapes, with Three.js's signatures and defaults.

import { refBounds, localMatrix3, multiplyMatrix3, applyMatrix3 } from './math.js';
import { catmullRom } from './field.js';
import { Object3D } from './object3d.js';
import { Mesh } from './mesh.js';

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

// One integer crosses instead of a name to be matched, the same reason
// `ui.js`'s `KIND` table exists: `scene/primitive.c3`'s `UvMode` is this order
// written out in C3, and a wrong number is a shape the host refuses by index
// rather than one it silently builds with the wrong layout. See the
// `BoxGeometry` doc entry in docs/classes.md for what the two modes mean.
const UV_MODE = { face: 0, local: 1 };
const UV_MODES = Object.keys(UV_MODE).join(', ');

// Shared by every shape built face by face through `primitive.c3`'s
// `build_face` — currently BoxGeometry and PlaneGeometry. 'face' is the
// default and is Three.js's own layout, so a script that never mentions `uv`
// gets exactly what it got before this option existed.
function readUvOption(options, where) {
	if (options === null || typeof options !== 'object') {
		throw new TypeError(`${where} takes an options object as its last argument`);
	}
	const uv = options.uv ?? 'face';
	if (!Object.prototype.hasOwnProperty.call(UV_MODE, uv)) {
		throw new TypeError(`${where}: uv must be one of ${UV_MODES}, got ${JSON.stringify(uv)}`);
	}
	return uv;
}

export class BoxGeometry extends Geometry {
	constructor(width = 1, height = 1, depth = 1, widthSegments = 1, heightSegments = 1, depthSegments = 1, options = {}) {
		const where = 'new three.BoxGeometry(width, height, depth)';
		const w = positiveSize(width, where, 'width');
		const h = positiveSize(height, where, 'height');
		const d = positiveSize(depth, where, 'depth');
		const ws = segmentCount(widthSegments, where, 'widthSegments', 1);
		const hs = segmentCount(heightSegments, where, 'heightSegments', 1);
		const ds = segmentCount(depthSegments, where, 'depthSegments', 1);
		const uv = readUvOption(options, where);
		super(
			'BoxGeometry', 'box',
			{ width: w, height: h, depth: d, widthSegments: ws, heightSegments: hs, depthSegments: ds, uv },
			H.primitive('box', w, h, d, ws, hs, ds, false, UV_MODE[uv]),
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
	constructor(width = 1, height = 1, widthSegments = 1, heightSegments = 1, options = {}) {
		const where = 'new three.PlaneGeometry(width, height)';
		const w = positiveSize(width, where, 'width');
		const h = positiveSize(height, where, 'height');
		const ws = segmentCount(widthSegments, where, 'widthSegments', 1);
		const hs = segmentCount(heightSegments, where, 'heightSegments', 1);
		const uv = readUvOption(options, where);
		super(
			'PlaneGeometry', 'plane',
			{ width: w, height: h, widthSegments: ws, heightSegments: hs, uv },
			H.primitive('plane', w, h, 0, ws, hs, 1, false, UV_MODE[uv]),
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
//
// `uv` takes only `'local'`, as a no-op, for symmetry with `BoxGeometry` and
// `PlaneGeometry`'s options object: a hull is always local, there being no
// per-face unit square to fall back to, so `'face'` is refused by name rather
// than silently building something other than what was asked for.
export class ConvexGeometry extends Geometry {
	constructor(points, options = {}) {
		const where = 'new three.ConvexGeometry(points)';
		if (options === null || typeof options !== 'object') {
			throw new TypeError(`${where} takes an options object as its second argument`);
		}
		if ('uv' in options && options.uv !== undefined && options.uv !== 'local') {
			throw new TypeError(
				`${where}: uv is always 'local' on a hull — there is no face to map a 'face' uv per, `
				+ `so 'face' is refused rather than quietly built as 'local' anyway`
			);
		}
		const flat = readPointCloud(points, where);
		super(
			'ConvexGeometry', 'convex',
			{ points: flat.length / 3 },
			H.convex(flat),
		);
	}
}

// A shape cannot have a hole in it, and a kit is mostly made of shapes that
// do — a wall with a window, a floor with a stair well. Three.js's answer is
// `ExtrudeGeometry` over a `Shape`: a 2D outline, holes cut out of it, swept
// to a depth, one closed mesh with no interior faces where a hand-built wall
// would have four boxes and coincident faces nothing will ever see.
//
// `Path` is the outline itself — straight segments and one curve. No bezier,
// quadratic or spline curves: Three.js's `Path` is the whole surface of
// `CurvePath`, and the two this keeps (a straight line and a circular arc)
// are what a kit's outlines are actually drawn from. `docs/differences.md`
// says so.
export class Path {
	// `points` is optional: an array of `[x, y]` pairs or `{x, y}` objects,
	// the whole outline at once — for a shape that already has its points
	// (read from a file, computed in a loop) and would rather not chain
	// `lineTo` once per point. Left out, a path starts empty and is built
	// with `moveTo`/`lineTo`/`absarc`.
	constructor(points) {
		this.points = [];
		if (points !== undefined) {
			if (!Array.isArray(points)) {
				throw new TypeError('new three.Path(points) wants an array of [x, y] or {x, y}');
			}
			for (let i = 0; i < points.length; i++) {
				const p = points[i];
				let x, y;
				if (Array.isArray(p) && p.length >= 2) {
					[x, y] = p;
				} else if (p !== null && typeof p === 'object' && 'x' in p) {
					({ x, y } = p);
				} else {
					throw new TypeError(`new three.Path(points): point ${i} is neither [x, y] nor {x, y}`);
				}
				this._push(x, y, `new three.Path(points): point ${i}`);
			}
		}
	}

	_push(x, y, where) {
		const fx = +x, fy = +y;
		if (!Number.isFinite(fx) || !Number.isFinite(fy)) {
			throw new TypeError(`${where} has a non-finite component`);
		}
		this.points.push([fx, fy]);
		return this;
	}

	// Three.js lets `moveTo` start a new subpath partway through; there is
	// only ever one subpath here — a `Shape`'s outline, or one of its holes —
	// so `moveTo` only makes sense as the first call. `docs/differences.md`
	// says so.
	moveTo(x, y) {
		if (this.points.length > 0) {
			throw new Error(
				'path.moveTo(x, y) only makes sense as the first call on an empty path — this one already has '
					+ 'points, use lineTo'
			);
		}
		return this._push(x, y, 'path.moveTo(x, y)');
	}

	lineTo(x, y) {
		return this._push(x, y, 'path.lineTo(x, y)');
	}

	// A no-op that returns `this`, like every other method here. The outline
	// this crosses to the host is always implicitly closed back to its first
	// point — there is nowhere else for it to go — so nothing needs doing;
	// this exists so a script ported from Three.js does not have to drop the
	// call.
	closePath() {
		return this;
	}

	// A circular arc, sampled immediately into straight segments — there is
	// no deferred curve object here, `this.points` is the whole
	// representation, so the resolution is decided now rather than when the
	// path eventually reaches an `ExtrudeGeometry`.
	//
	// `clockwise` picks which way around the circle the arc travels from
	// `startAngle` to `endAngle`, Three.js's own meaning. The segment count
	// is `curveSegments` — `ExtrudeGeometry`'s default of 12, per full turn —
	// scaled by how much of a turn this arc actually sweeps: a quarter circle
	// is 3 segments, not 12. It does not read a later `ExtrudeGeometry`'s own
	// `curveSegments` option; see `docs/differences.md`.
	absarc(x, y, radius, startAngle, endAngle, clockwise = false) {
		const cx = +x, cy = +y, r = +radius;
		if (!Number.isFinite(cx) || !Number.isFinite(cy)) {
			throw new TypeError('path.absarc(x, y, radius, startAngle, endAngle): center has a non-finite component');
		}
		if (!Number.isFinite(r) || r <= 0) {
			throw new RangeError(`path.absarc: radius must be a positive number, got ${radius}`);
		}
		const start = +startAngle, end = +endAngle;
		if (!Number.isFinite(start) || !Number.isFinite(end)) {
			throw new TypeError('path.absarc(x, y, radius, startAngle, endAngle): angles must be finite numbers');
		}
		let sweep = end - start;
		if (!clockwise && sweep <= 0) sweep += Math.PI * 2;
		if (clockwise && sweep >= 0) sweep -= Math.PI * 2;

		const segments = Math.max(1, Math.round((Math.abs(sweep) / (Math.PI * 2)) * PATH_ARC_SEGMENTS_PER_TURN));
		for (let i = 0; i <= segments; i++) {
			const a = start + sweep * (i / segments);
			this._push(cx + Math.cos(a) * r, cy + Math.sin(a) * r, 'path.absarc');
		}
		return this;
	}
}

// `absarc`'s own resolution — see its doc comment for why this is fixed
// rather than read from an `ExtrudeGeometry` that may not exist yet. It
// matches `ExtrudeGeometry`'s `curveSegments` default so the two numbers an
// agent sees are the same number, even though only one of them does anything.
const PATH_ARC_SEGMENTS_PER_TURN = 12;

// The outline `ExtrudeGeometry` sweeps, plus the holes cut out of it — the
// whole of Three.js's `Shape` this keeps. `holes` is an ordinary array a
// script pushes `Path`s onto; there is no `Shape.holes.push(...)` wrapper
// because there is nothing to validate until `ExtrudeGeometry` reads it.
export class Shape extends Path {
	constructor(points) {
		super(points);
		this.holes = [];
	}
}

const MIN_EXTRUDE_POINTS = 3;

function flattenPathPoints(points, where, what) {
	if (!Array.isArray(points) || points.length < MIN_EXTRUDE_POINTS) {
		throw new RangeError(
			`${where}: ${what} needs at least ${MIN_EXTRUDE_POINTS} points to enclose an area, got `
				+ `${points ? points.length : 0}`
		);
	}
	const flat = [];
	for (let i = 0; i < points.length; i++) {
		const [x, y] = points[i];
		flat.push(x, y);
	}
	return flat;
}

// A `Shape` swept along +z into one closed mesh — Three.js's `ExtrudeGeometry`,
// and the piece a kit is mostly made of: a wall with a window is this shape
// once, instead of four boxes with coincident faces nothing will ever see.
//
// Extrusion runs from z = 0 to z = `depth` along +z, Three.js's own
// convention. There is no bevel — `bevelEnabled` is refused rather than
// quietly ignored, see below — and `curveSegments` is accepted for the same
// signature Three.js has but does nothing here, because the one curve this
// API has (`Path.absarc`) already flattened itself before a shape ever
// reaches this constructor. `docs/differences.md` records both.
//
// `uv` takes only `'local'`, the same no-op `ConvexGeometry` accepts it as:
// a cap's uv is its own (x, y) and a side's is (distance along its ring, z),
// so `'face'` is refused by name rather than quietly built as `'local'`
// anyway.
export class ExtrudeGeometry extends Geometry {
	constructor(shape, options = {}) {
		const where = 'new three.ExtrudeGeometry(shape, options)';
		if (!(shape instanceof Path) || !Array.isArray(shape.points)) {
			throw new TypeError(`${where}: shape must be a three.Shape (or three.Path) with an outline`);
		}
		if (options === null || typeof options !== 'object') {
			throw new TypeError(`${where} takes an options object as its second argument`);
		}
		const depth = positiveSize(options.depth ?? 1, where, 'depth');
		// Validated and otherwise unused — see the class doc comment.
		segmentCount(options.curveSegments ?? 12, where, 'curveSegments', 1);
		if ('uv' in options && options.uv !== undefined && options.uv !== 'local') {
			throw new TypeError(
				`${where}: uv is always 'local' on an extrusion — there is no per-face unit square to fall back `
					+ `to, so 'face' is refused rather than quietly built as 'local' anyway`
			);
		}
		if (options.bevelEnabled) {
			throw new TypeError(
				`${where}: there is no bevel here — bevelEnabled is refused rather than silently ignored, so a `
					+ `script ported from Three.js finds out instead of getting a shape it did not expect. `
					+ `Three.js defaults bevelEnabled to true; a script that never mentions it gets the flat `
					+ `extrude it would have gotten from { bevelEnabled: false }.`
			);
		}

		const outline = flattenPathPoints(shape.points, where, 'the outline');
		const holePaths = Array.isArray(shape.holes) ? shape.holes : [];
		const holeFlat = [];
		const holeCounts = [];
		for (let i = 0; i < holePaths.length; i++) {
			const hole = holePaths[i];
			if (!(hole instanceof Path) || !Array.isArray(hole.points)) {
				throw new TypeError(`${where}: holes[${i}] must be a three.Path`);
			}
			const flat = flattenPathPoints(hole.points, where, `holes[${i}]`);
			holeCounts.push(flat.length / 2);
			for (let j = 0; j < flat.length; j++) holeFlat.push(flat[j]);
		}

		super(
			'ExtrudeGeometry', 'extrude',
			{ points: outline.length / 2, holes: holeCounts.length, depth },
			H.extrude(outline, holeFlat, holeCounts, depth),
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

// -----------------------------------------------------------------------
// Merge — MeshRef.split()'s reverse: every Mesh in a subtree, or an explicit
// array of them, concatenated into one asset with each one's transform
// baked into its vertices. `scene/merge.c3` carries the host half — the
// concatenation itself, the winding fix on a mirrored piece, and why the
// result keeps its own vertex streams instead of falling back to a hull's
// averaged normals and projected uvs.
//
// Two spellings:
//
//   three.merge(root)          every Mesh under root, in root's own frame
//   three.merge([a, b, ...])   exactly these meshes, in their shared parent's
//
// A mesh's transform relative to the frame is the product of the local
// matrices from the mesh up to, but excluding, root (or the shared parent) —
// a mesh whose parent is null carries no ancestor transform to exclude, so
// its own local transform already is the frame it merges in. That is what
// makes `new three.Mesh(three.merge(piece), material)` placed where `piece`
// was draw the same picture `piece` did, as one instance instead of however
// many meshes `piece` was.
//
// **Skipped, silently: helpers and invisible subtrees.** A helper (anything
// drawing with the line material — Box3Helper, BoxHelper, AxesHelper,
// GridHelper, WireframeHelper) has index pairs rather than triangles, and an
// invisible node draws nothing to bake — `visible = false` prunes the whole
// subtree under it, the same as rendering does. There is no flag to opt
// either back in.
//
// **Refused: two materials, or two variants.** Every mesh must share one
// material by identity (`mesh.material === mesh.material`, with the shared
// default `null` counting as one) and one `variant`. A material is a
// pipeline and a variant a row of its table, both chosen once per draw call,
// and a merge is one draw call — so two materials cannot become one asset,
// and this throws naming them rather than keeping one and silently dropping
// the paint job on every mesh that named the other. `mesh.color` has
// nowhere else to disagree from and is not refused: it bakes into the merged
// mesh's own vertex colours instead, so a wall merged with a differently
// tinted door keeps the door's tint. See scene/merge.c3 for why that is
// possible — the built-in shading already reads a vertex colour attribute
// beside the per-instance one.
//
// **Interior faces are still there.** A wall merged with the window frame
// sitting inside it is one mesh with the coincident inside-the-wall faces
// intact — a merge is concatenation and nothing cleverer. ExtrudeGeometry is
// the tool that removes a hole's interior faces by construction, and stays
// the answer for a shape that should never have had them; this is the tool
// for turning a hundred nodes that already draw correctly into one.
//
// **The cost model.** Merging trades instancing for node count, not for draw
// calls on its own: a piece used a hundred times across a level is a hundred
// instances and one draw call whether or not it is merged, because it was
// already one asset. What merging removes is the *node* — forty boxes that
// make up one wall are forty transforms, forty picks and forty scene-graph
// entries, and merging them is one of each, whether or not any two walls in
// the level are ever placed twice. Two different pieces merged into one
// asset are one asset, not two — reuse across a level is a question about
// node count, and merging answers it, never about which pieces look alike.
//
//     const kit = three.load('kit/buildings.glb');
//     const piece = kit.node('wall_stone');
//     scene.add(piece); // or leave it detached — merge works either way
//     const material = new three.MeshLambertMaterial({ map: kit.mesh(piece.name)?.material });
//     const wall = new three.Mesh(three.merge(piece), material);
//     wall.position.copy(piece.position);
//     scene.add(wall);

// A mesh name for a sentence, or a stand-in for one that never got one.
function meshLabel(mesh) {
	return mesh && mesh.name ? `'${mesh.name}'` : '(an unnamed mesh)';
}

// One node's own local rotation, scale and position, composed onto a
// parent-relative frame already expressed as a row-major 3x3 (`M`) and an
// offset (`T`). `object3d.js`'s private `localPoint` walks the identical
// chain for a single point; this keeps the linear part too, because a
// vertex needs it and an offset alone does not carry it.
function composeLocal(M, T, node) {
	const L = localMatrix3(node.rotation, node.scale, node._q);
	const nextM = multiplyMatrix3(M, L);
	const p = applyMatrix3(M, [node.position.x, node.position.y, node.position.z]);
	return [nextM, [p[0] + T[0], p[1] + T[1], p[2] + T[2]]];
}

// `[M, T]` as the sixteen column-major floats scene/merge.c3's `Matrix4f`
// wants — `std::math::matrix`'s own layout, the one every 4x4 already
// crossing this boundary uses, translation in indices 12..14.
function flattenTransform(M, T) {
	const flat = new Array(16).fill(0);
	for (let row = 0; row < 3; row++) {
		for (let col = 0; col < 3; col++) flat[col * 4 + row] = M[row * 3 + col];
	}
	flat[12] = T[0]; flat[13] = T[1]; flat[14] = T[2]; flat[15] = 1;
	return flat;
}

const MERGE_IDENTITY_M = [1, 0, 0, 0, 1, 0, 0, 0, 1];
const MERGE_ZERO_T = [0, 0, 0];

// Depth first under `node`, gathering every eligible Mesh with its transform
// already composed into `node`'s own frame. `M`/`T` is the frame `node`
// itself sits in — identity and zero for the root a merge was asked to walk,
// so root's own transform is excluded exactly as the header says — and each
// child composes its own local transform onto that before being recorded or
// walked in turn. Invisible prunes here, before a single child is reached,
// rather than being filtered out of the list afterwards.
function collectForMerge(node, M, T, into) {
	if (!node.visible) return;
	if (node instanceof Mesh && !node._isHelper) into.push({ mesh: node, M, T });
	for (const child of node.children) {
		const [childM, childT] = composeLocal(M, T, child);
		collectForMerge(child, childM, childT, into);
	}
}

// The result of a merge — a Geometry that carries data instead of only
// parameters, `TerrainGeometry`'s own shape: `parameters.meshes` is how many
// meshes went in and `parameters.triangles` is what came out. Two different
// subtrees that happen to look alike are two different assets; the same
// subtree merged twice is one — see scene/merge.c3's dedup key.
export class MergedGeometry extends Geometry {
	constructor(meshes, triangles, handle) {
		super('MergedGeometry', 'merge', { meshes, triangles }, handle);
	}
}

export function merge(input) {
	const where = 'three.merge(...)';
	const gathered = [];

	if (Array.isArray(input)) {
		if (input.length === 0) {
			throw new TypeError(`${where}: an array of meshes needs at least one element`);
		}
		for (let i = 0; i < input.length; i++) {
			if (!(input[i] instanceof Mesh)) {
				throw new TypeError(`${where}: element ${i} of the array is not a three.Mesh`);
			}
		}
		const parent = input[0].parent;
		for (let i = 1; i < input.length; i++) {
			if (input[i].parent !== parent) {
				throw new TypeError(
					`${where}: every mesh in the array must share one parent to merge in one frame — `
					+ `${meshLabel(input[0])} and ${meshLabel(input[i])} do not. three.merge(root) merges a `
					+ "whole subtree in root's own frame instead."
				);
			}
		}
		for (const mesh of input) {
			if (!mesh.visible || mesh._isHelper) continue;
			const [M, T] = composeLocal(MERGE_IDENTITY_M, MERGE_ZERO_T, mesh);
			gathered.push({ mesh, M, T });
		}
	} else if (input instanceof Object3D) {
		collectForMerge(input, MERGE_IDENTITY_M, MERGE_ZERO_T, gathered);
	} else {
		throw new TypeError(
			`${where} wants an Object3D (merges every Mesh in its subtree) or an array of Mesh `
			+ "(merges them in their common parent's frame)"
		);
	}

	if (gathered.length === 0) {
		throw new Error(`${where}: nothing to merge — no visible, non-helper Mesh was found`);
	}

	const firstMesh = gathered[0].mesh;
	const firstMaterial = firstMesh.material;
	let materialCount = 1;
	let secondMaterialMesh = null;
	for (let i = 1; i < gathered.length; i++) {
		if (gathered[i].mesh.material !== firstMaterial) {
			materialCount++;
			if (secondMaterialMesh === null) secondMaterialMesh = gathered[i].mesh;
		}
	}
	if (materialCount > 1) {
		throw new TypeError(
			`${where}: every mesh must share one material by identity — found ${materialCount} different `
			+ `ones, starting with ${meshLabel(firstMesh)} and ${meshLabel(secondMaterialMesh)}. A merge is `
			+ 'one draw call and a material is a pipeline, so two materials cannot become one asset — give '
			+ 'them the same material first, or merge them separately.'
		);
	}

	const firstVariant = firstMesh.variant;
	for (let i = 1; i < gathered.length; i++) {
		const mesh = gathered[i].mesh;
		if (mesh.variant !== firstVariant) {
			throw new TypeError(
				`${where}: every mesh must share one variant — ${meshLabel(firstMesh)} is row ${firstVariant} `
				+ `and ${meshLabel(mesh)} is row ${mesh.variant}. A variant selects a row of the material's `
				+ "own table, and a merge — one draw, one material — can only ever read one row."
			);
		}
	}

	const assetIndices = [];
	const generations = [];
	const meshIndices = [];
	const matrices = [];
	const colors = [];
	for (const { mesh, M, T } of gathered) {
		const ref = mesh._ref();
		assetIndices.push(ref.asset);
		generations.push(ref.assetGeneration);
		meshIndices.push(ref.mesh);
		const flat = flattenTransform(M, T);
		for (let k = 0; k < 16; k++) matrices.push(flat[k]);
		const c = mesh.color;
		for (let k = 0; k < 4; k++) colors.push(c[k]);
	}

	const [index, generation, triangles] = H.merge(assetIndices, generations, meshIndices, matrices, colors);
	return new MergedGeometry(gathered.length, triangles, [index, generation]);
}
