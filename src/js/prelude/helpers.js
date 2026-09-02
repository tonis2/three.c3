// three.c3 — debug draw: the line-material meshes that box, gird and wireframe
// a scene.

import { Box3 } from './math.js';
import { Object3D, Group } from './object3d.js';
import { Mesh } from './mesh.js';
import { Geometry, positiveSize } from './geometry.js';

const H = globalThis.__three;

// Index 1 of the host's material table, built in `MeshPass.init` over
// `LINE_STATE`. A number rather than something asked for, because there is
// no verb that answers it — and pinned by `a_helper_draws_with_the_line_material`
// in test/lines_test.c3, which reads the material back off the host node
// rather than trusting this line.
const LINE_MATERIAL = 1;

// A line shape as a Geometry, so `helper.geometry` is the same kind of thing
// a Mesh's is — with `bounds`, `toJSON` and a `type` that says what it is.
function lineGeometry(type, kind, parameters, divisions = 1) {
	return new Geometry(type, kind, parameters, H.lines(kind, divisions));
}

// The base of every helper: a Mesh that draws with the line material, and
// only with the line material.
class LineMesh extends Mesh {
	constructor(geometry, color) {
		super(geometry);
		if (color !== undefined && color !== null) this.color = color;
	}

	_hostMaterial() { return LINE_MATERIAL; }

	// Null rather than a stand-in object: there is no ShaderMaterial here to
	// hand back, and inventing one whose uniforms went nowhere would be worse
	// than saying so.
	get material() { return null; }

	set material(v) {
		throw new TypeError(
			'a helper draws with the line material and cannot be given another: a material is '
			+ 'a pipeline, every pipeline you can build draws triangles, and a helper\'s indices '
			+ 'are pairs — assigning one '
			+ 'would read the pairs as triangles rather than fail. helper.color is per copy and '
			+ 'free, and is the knob a helper has.');
	}
}

// Three.js's Box3Helper: a wire box drawn exactly where a Box3 says.
//
// The primitive the other box helper is built out of, and the one to reach
// for when the box came from somewhere that is not an object — a plot to
// fill, a gap to check, a union of two things.
//
// The box is read in whatever frame the helper's parent is, because that is
// the frame its `position` is in. A box from `boundsInParent()` therefore
// belongs under the same parent, and a box from `boundingBox()` belongs
// under the scene.
export class Box3Helper extends LineMesh {
	constructor(box, color = 0xffff00) {
		if (!(box instanceof Box3)) {
			throw new TypeError(
				'new three.Box3Helper(box) wants a three.Box3 — object.boundsInParent() and '
				+ 'object.boundingBox() answer with one, and new three.Box3(...) builds one.');
		}
		super(lineGeometry('BoxLines', 'box', {}), color);
		this.box = box;
	}

	// Settable, as in Three.js: the helper follows whatever box it is given.
	get box() { return this._box; }
	set box(v) {
		if (!(v instanceof Box3)) throw new TypeError('helper.box wants a three.Box3');
		this._box = v;
		const c = v.center, size = v.size;
		this.position.set(c.x, c.y, c.z);
		// The unit cube is corners at +/- 0.5, so the size *is* the scale. A
		// flat box scales an axis to zero and draws as a rectangle, which is
		// the right picture for a plane.
		this.scale.set(size.x, size.y, size.z);
	}
}

// Three.js's BoxHelper: the box of an object and everything under it.
//
// **It hangs from the object's own parent, and is refused anywhere else.**
// The box comes from `boundsInParent()`, which is measured in that frame, so
// a helper parented elsewhere would be drawn wherever the two frames happen
// to differ — a box in the wrong place, which is worse than no box. `snapTo`
// and `alignTo` get out of the same bind by measuring in world space when the
// frames differ and converting the step back; a helper has no step to convert,
// because it *is* the box.
//
// The usual spelling is therefore the Three.js one, because a piece is
// usually a child of the scene:
//
//   scene.add(piece);
//   scene.add(new three.BoxHelper(piece));
//
// and a nested piece takes `piece.parent.add(...)`.
export class BoxHelper extends Box3Helper {
	constructor(object, color = 0xffff00) {
		if (!(object instanceof Object3D)) {
			throw new TypeError('new three.BoxHelper(object) wants the object to measure');
		}
		const box = object.boundsInParent();
		if (box === null) {
			throw new Error(
				'new three.BoxHelper(object): that object draws nothing, so it has no box — it is a '
				+ 'Group with no meshes under it, or its geometry is not resident.');
		}
		super(box, color);
		this._of = object;
	}

	// What it is drawn around. Read-only: a helper that could be pointed at a
	// different object would need its parent re-checked, and making a new one
	// is a line.
	get object() { return this._of; }

	// Measure again. Nothing here watches the object, so a helper made before
	// a move draws where the object was — call this after moving, scaling or
	// rotating it, exactly as Three.js's `BoxHelper.update()` is called.
	update() {
		const box = this._of.boundsInParent();
		if (box === null) {
			throw new Error('boxHelper.update(): the object it measures no longer draws anything');
		}
		this.box = box;
		return this;
	}

	_materialize(parent) {
		if (this._of.parent === null) {
			throw new Error(
				`a BoxHelper is drawn in the frame of ${this._of.name || 'the object'}'s parent, and that `
				+ 'object is not in a scene yet — add it first, then add the helper beside it.');
		}
		if (this.parent !== this._of.parent) {
			throw new Error(
				`a BoxHelper must hang from the same parent as the object it measures: the box is `
				+ `measured in that frame, and drawn in this one. Add it to `
				+ `${this._of.name ? `${this._of.name}.parent` : 'the object\'s parent'} instead — or `
				+ 'measure with boundingBox() and use a Box3Helper under the scene.');
		}
		super._materialize(parent);
	}
}

// Three.js's AxesHelper: red +X, green +Y, blue +Z, one unit long by default.
//
// The answer to "where is this thing's pivot and which way is it facing",
// which is the question a kit piece with an origin in an unexpected corner
// makes somebody ask. Parent it to the object to see that object's pivot.
//
// Three meshes over one segment asset, so a hundred of these are still one
// draw call: the colour rides in the instance record and the direction is a
// rotation, neither of which is a new asset.
export class AxesHelper extends Group {
	constructor(size = 1) {
		super();
		const n = positiveSize(size, 'new three.AxesHelper(size)', 'size');
		// The segment asset points along +X, so +Y is a quarter turn about Z
		// and +Z is a quarter turn the other way about Y.
		for (const [color, rx, ry, rz] of [
			[0xff0000, 0, 0, 0],
			[0x00ff00, 0, 0, Math.PI / 2],
			[0x0000ff, 0, -Math.PI / 2, 0],
		]) {
			const arm = new LineMesh(lineGeometry('SegmentLines', 'segment', {}), color);
			arm.rotation.set(rx, ry, rz);
			this.add(arm);
		}
		this.size = n;
	}

	// How long each arm is, in the parent's units. Live: writing it rescales
	// the three arms rather than rebuilding anything.
	get size() { return this._size; }
	set size(v) {
		const n = positiveSize(v, 'axes.size', 'size');
		this._size = n;
		for (const arm of this.children) arm.scale.set(n, n, n);
	}
}

// Three.js's GridHelper: a ruled square in the XZ plane, centred on the
// origin — where the ground is, and how big a metre looks.
//
// One colour rather than Three.js's two. Three.js draws the centre lines
// darker, which would be a second mesh here for a distinction nothing has
// needed; `scene.background` and `helper.color` are the two knobs.
//
// Keyed on the divisions alone, so `new three.GridHelper(100, 10)` and
// `new three.GridHelper(40, 10)` are one asset at two scales and one draw
// call. The size is the scale, which is why there is no `size` to read back:
// `grid.scale.x` is it, and it is live.
export class GridHelper extends LineMesh {
	constructor(size = 10, divisions = 10, color = 0x888888) {
		const where = 'new three.GridHelper(size, divisions, color)';
		const s = positiveSize(size, where, 'size');
		const d = Math.floor(+divisions);
		if (!Number.isFinite(d) || d < 1) {
			throw new RangeError(`${where}: divisions must be at least 1, got ${divisions}`);
		}
		if (d > 256) {
			throw new RangeError(
				`${where}: divisions is capped at 256 — ${d} lines is a wall of pixels rather than a `
				+ 'reference, and the grid is meant to be read through.');
		}
		super(lineGeometry('GridLines', 'grid', { divisions: d }, d), color);
		this._divisions = d;
		this.scale.set(s, 1, s);
	}

	// How many cells across, which is what picks the asset. Read-only: a
	// different count is a different mesh, and `new three.GridHelper(...)`
	// against the same count is free.
	get divisions() { return this._divisions; }
}

// A mesh's own triangles, as the edges between them. Three.js reaches this
// through `WireframeGeometry` and a `LineSegments`; the name here is one
// Three.js does not have, because what it takes is different — a mesh that
// is already in the scene, not a geometry.
//
// The tool for the failure that started this: two faces 0.01 apart
// z-fighting into a starburst, invisible in a solid render and obvious the
// moment the edges are drawn.
//
// **The mesh has to be in the scene already.** The edges are read off the
// CPU copy of the triangles, which is filled at upload — and a mesh reaches
// the device when something drawing it is added to a scene. So:
//
//   scene.add(piece);
//   piece.add(new three.WireframeHelper(piece));   // exactly over it
//
// A child of the mesh, because the edges are in the mesh's own space and a
// child at the identity transform overlays it to the pixel. Anywhere else
// and the transform is the caller's to match.
export class WireframeHelper extends LineMesh {
	constructor(target, color = 0xffffff) {
		const ref = target instanceof Object3D ? target._ref() : target;
		if (!ref || typeof ref.asset !== 'number' || typeof ref.mesh !== 'number'
			|| typeof ref.assetGeneration !== 'number') {
			throw new TypeError(
				'new three.WireframeHelper(target) wants a Mesh that is in the scene, or the '
				+ 'asset.mesh(name) / geometry it draws. A Group has no triangles of its own — '
				+ 'traverse it and make one per Mesh.');
		}
		// Keyed by the source mesh rather than by a shape, which is why this
		// is the other host verb and not another `lineGeometry` kind.
		super(
			new Geometry(
				'WireframeLines', 'wireframe', { of: ref.name || '' },
				H.wireframe(ref.asset, ref.assetGeneration, ref.mesh),
			),
			color,
		);
		this._of = ref.name || '';
	}

	// Which mesh's edges these are, for a stats dump and for a script that
	// collected several.
	get of() { return this._of; }
}
