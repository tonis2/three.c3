// three.c3 — Mesh: one placed copy of a geometry, and the two per-copy knobs.

import { readColor } from './math.js';
import { Object3D } from './object3d.js';
import { Material } from './material.js';

const H = globalThis.__three;

// `new three.Mesh(geometry, material)`, and `geometry` is either half of what
// this project can draw: a shape three.c3 built (`new three.BoxGeometry(...)`)
// or a mesh inside a file somebody made (`kit.mesh("wall_corner_02")`). Both
// are an asset index and a mesh index, which is the whole of what a Mesh
// holds — see the Geometry section.
//
// The material argument is Three.js's second one and is optional here as it
// is there. It goes through the `material` setter rather than into the field,
// so passing something that is not a ShaderMaterial throws at the
// constructor's line instead of at the add().
export class Mesh extends Object3D {
	constructor(geometry, material = null) {
		super();
		if (!geometry || typeof geometry.asset !== 'number' || typeof geometry.mesh !== 'number'
			|| typeof geometry.assetGeneration !== 'number') {
			throw new TypeError(
				'new three.Mesh(geometry) wants a shape like new three.BoxGeometry(1, 1, 1), '
				+ 'or a mesh reference from asset.mesh(name). An asset reference carries '
				+ 'assetGeneration as well as asset, because assets can be unloaded and their '
				+ 'slots reused — a hand-built { asset, mesh } cannot say which load it meant.'
			);
		}
		// **And the handle has to still name something**, which is a question
		// only the host can answer: an asset that has been unloaded gives its
		// slot back, so `assetGeneration` is the whole of what separates "this
		// kit" from "whatever loaded into its slot afterwards".
		//
		// This used to be left to `scene.add()`, on the argument that an unadded
		// Mesh is only a description and a description of nothing harms nobody.
		// It reads worse than it sounds: the line that gets blamed is the add,
		// which is correct, while the line that is wrong is the one that named a
		// handle from before an unload — and in a script that builds a subtree
		// and adds it at the end, those are nowhere near each other.
		//
		// It costs one crossing per Mesh. That is the same order as the `add()`
		// which is the only useful thing to do with one, and it buys the throw at
		// the line an agent has to edit.
		H.checkAsset(geometry.asset, geometry.assetGeneration);
		this._mesh = geometry;
		this._name = geometry.name ?? '';
		this._material = null;
		// White and row zero: the identity for both per-instance channels.
		this._color = [1, 1, 1, 1];
		this._variant = 0;
		if (material !== null && material !== undefined) this.material = material;
	}

	_ref() { return this._mesh; }
	get geometry() { return this._mesh; }

	// **Refused out loud, and the reason is the same one `camera.near` gives.**
	// A script is not evaluated in strict mode, so a getter with no setter
	// swallows the assignment: `mesh.geometry = other` does nothing, reports
	// nothing, reads back the old value, and the frame draws the old shape. That
	// is the worst of the three possible behaviours, and it cost a session.
	//
	// Geometry is immutable by design and not by omission — plan.md's first
	// thesis is that two copies of one shape are one draw call because a shape
	// cannot be edited under them — so this is the same sentence the engine
	// already gives a dynamic body whose transform a script writes.
	set geometry(_) {
		throw new TypeError(
			'mesh.geometry cannot be reassigned — a geometry is immutable, which is what lets '
			+ 'every copy of it share one draw call. Make a new Mesh with the shape you want, or '
			+ 'change mesh.material, mesh.color, mesh.variant or the transform, which are all live.'
		);
	}

	// -------------------------------------------------------------------
	// The two per-copy channels
	//
	// **These are the only things two meshes sharing a geometry and a
	// material may disagree about without becoming two draw calls.** A
	// different material is a different pipeline and a different push block,
	// which is bucket state; these two are read out of the instance array by
	// the GPU, so a thousand differently coloured copies stay one call.
	//
	// It is a plain `[r, g, b, a]` rather than a live object like `position`,
	// because there is nothing to write through *to* — the value is copied
	// into the instance record at render time either way, and a Color class
	// would be a Three.js name for something that is not Three.js's Color.

	get color() { return [...this._color]; }
	set color(v) {
		this._color = readColor(v, 'mesh.color');
		if (this._i >= 0) H.setColor(this._i, this._g, ...this._color);
	}

	// Which row of the material's table this copy draws with. Zero, and
	// meaningless, until the material declares one — see ShaderMaterial.
	get variant() { return this._variant; }
	set variant(v) {
		const n = Math.floor(+v);
		if (!Number.isFinite(n) || n < 0) {
			throw new RangeError(`mesh.variant wants a row index of 0 or more, got ${v}`);
		}
		this._variant = n;
		if (this._i >= 0) H.setVariant(this._i, this._g, n);
	}

	// -------------------------------------------------------------------
	// Morph targets
	//
	// A blend shape is a displacement of every vertex, and `weights` is how
	// much of each one this copy wears. `mesh.morphs` is how many the
	// geometry has; a mesh with none answers 0 and `weights` is empty.
	//
	// **Per copy, like colour and variant.** Two faces built from one head
	// mesh wear different expressions and stay one draw call — the
	// displacements are shared, and only the handful of floats per copy is
	// not. Weights outside 0..1 are allowed and do what you would expect;
	// glTF does not clamp them either, and an exaggerated expression is a
	// legitimate thing to ask for.
	//
	// Addressed by index rather than by name because glTF puts target names
	// in `mesh.extras.targetNames`, which is a convention rather than a
	// required field — there is nothing to read on a file that omits it.

	get morphs() {
		if (this._morphs === undefined) {
			const ref = this._ref();
			this._morphs = ref ? H.meshMorphs(ref.asset, ref.assetGeneration, ref.mesh) : 0;
		}
		return this._morphs;
	}

	get weights() {
		if (!this._weights) this._weights = new MorphWeights(this);
		return this._weights;
	}

	// `mesh.weights = [0.5, 0]` as well as `mesh.weights[0] = 0.5`, because
	// setting the whole expression at once is the commoner of the two and a
	// getter with no setter would swallow it — the trap `mesh.geometry`
	// refuses out loud.
	set weights(values) { this.weights.set(values); }

	// Assignable before the mesh is in a scene, like `name` and `visible`, and
	// replayed by `_materialize` for the same reason: an object is a detached
	// description until it is added, and a script that sets up a mesh and then
	// adds it must not lose the setup.
	get material() { return this._material; }
	set material(v) {
		// Any Material, not specifically a ShaderMaterial: a
		// MeshLambertMaterial is one too, and checking for the concrete class
		// would refuse the material a script reaches for to put a picture on
		// a box — which is the commoner of the two by a long way.
		if (v !== null && !(v instanceof Material)) {
			throw new TypeError(
				'mesh.material wants a three.MeshLambertMaterial or three.ShaderMaterial, '
				+ 'or null for the default'
			);
		}
		// Read before the assignment, so a disposed material is refused rather
		// than stored on a mesh that would then draw with nothing.
		const index = v === null ? 0 : v._index();
		this._material = v;
		if (this._i >= 0) H.setMaterial(this._i, this._g, index);
	}
}

// One mesh copy's morph weights, live the way `position` is: writing an element
// reaches the host, and reading one reads what was written.
//
// An indexed accessor per target rather than a Proxy, for the reason the whole
// prelude is JavaScript: an agent writes `head.weights[2] = 1` and expects it to
// work, and defined properties make that ordinary property access rather than a
// trap with its own cost and its own edge cases. The count is fixed at
// construction because a geometry is immutable, so there is no case where the
// number of targets changes under one of these.
//
// **The whole vector is sent on every write.** A face has a handful of targets
// and the alternative is a crossing per element per frame; this is the same
// choice `position` makes for its three numbers and for the same reason.
export class MorphWeights {
	constructor(owner) {
		this._o = owner;
		this._v = new Array(owner.morphs).fill(0);
		for (let i = 0; i < this._v.length; i++) {
			Object.defineProperty(this, i, {
				enumerable: true,
				get: () => this._v[i],
				set: (value) => { this._v[i] = toWeight(value); this._push(); },
			});
		}
	}

	get length() { return this._v.length; }

	// Shorter than the target count leaves the rest where they are, which makes
	// `set([1])` on a twenty-target face one call rather than twenty numbers a
	// script has to carry. Longer is refused, because a script passing more
	// weights than there are targets has miscounted something.
	set(values) {
		if (!Array.isArray(values) && !ArrayBuffer.isView(values)) {
			throw new TypeError('mesh.weights = wants an array of numbers');
		}
		if (values.length > this._v.length) {
			throw new RangeError(
				`this geometry has ${this._v.length} morph target${this._v.length === 1 ? '' : 's'}, `
				+ `got ${values.length} weights`
			);
		}
		for (let i = 0; i < values.length; i++) this._v[i] = toWeight(values[i]);
		this._push();
		return this;
	}

	fill(value) {
		const weight = toWeight(value);
		for (let i = 0; i < this._v.length; i++) this._v[i] = weight;
		this._push();
		return this;
	}

	toArray() { return this._v.slice(); }
	toJSON() { return this.toArray(); }
	[Symbol.iterator]() { return this._v[Symbol.iterator](); }
	toString() { return `[${this._v.join(', ')}]`; }

	// Nothing is sent while the mesh is a detached description; `_materialize`
	// replays it at the add, the way colour and variant are replayed.
	_push() {
		if (this._o._i >= 0) H.setMorphWeights(this._o._i, this._o._g, this._v);
	}
}

function toWeight(value) {
	const weight = +value;
	if (!Number.isFinite(weight)) throw new TypeError(`a morph weight wants a number, got ${value}`);
	return weight;
}

// There is one scene at a time, and `new three.Scene()` is what empties it.
//
// Three.js lets you hold several and render whichever you like; here the
// second one replaces the first, and every handle into the first goes stale.
// That is a divergence, so it is made loud rather than silent: an epoch is
// stamped on each Scene and checked on use, and the older one throws a
// sentence saying what happened instead of quietly operating on the newer
