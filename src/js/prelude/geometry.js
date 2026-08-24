// three.c3 — the generated shapes, with Three.js's signatures and defaults.

import { refBounds } from './math.js';

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
