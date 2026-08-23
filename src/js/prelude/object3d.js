// three.c3 — Object3D and Group: the scene graph's nodes and their transforms.

import { Vector3, axisIndex, boxFromSix, refBounds, transformBox, asTriple } from './math.js';

const H = globalThis.__three;

// -----------------------------------------------------------------------
// Object3D

export class Object3D {
	constructor() {
		this._position = new Vector3(this, 0, 0, 0);
		// The rotation vector's owner is a shim rather than `this`, so that
		// writing an Euler angle both flushes and drops `_q`. See `_q`.
		this._rotation = new Vector3({ _flush: () => { this._q = null; this._flush(); } }, 0, 0, 0);
		// Whether the physics solver drives this object's transform, which
		// makes the host the authority on it rather than these numbers.
		// Set by three.physics.add for a dynamic body and by nothing else.
		this._solverOwned = false;
		this.scale = new Vector3(this, 1, 1, 1);
		this.children = [];
		this.parent = null;
		this._name = '';
		this._visible = true;
		// An exact rotation, when this object has one — `[x, y, z, w]`. Only
		// `asset.instantiate()` sets it, because only a glTF node arrives as
		// a quaternion. `rotation` still holds the Euler equivalent and is
		// what a script reads; this is what is actually sent, because the
		// Euler form loses about 3e-4 radians at gimbal lock and a 90°
		// rotation is the most common thing anyone authors. Writing any
		// Euler component clears it — see the constructor.
		this._q = null;
		// Set only on a tree from `asset.instantiate()`: the clip names, the
		// asset they belong to, the glTF node this object came from, and
		// whether the host has been told the map yet. See `play`.
		this._clips = null;
		this._asset = null;
		this._gltfNode = -1;
		this._bound = false;
		// The host node, or -1 for "not in a scene". See the header.
		this._i = -1;
		this._g = -1;
	}

	// **Accessors rather than fields, for the solver's sake.** Everything a
	// script writes is pushed to the host and these numbers stay the truth
	// — except for a body the solver drives, where the host has moved the
	// node and nothing has told JavaScript. Reading refreshes exactly those
	// objects and costs one crossing; every other object answers from here
	// as it always did.
	get position() { this._syncSolver(); return this._position; }
	set position(v) { const [x, y, z] = asTriple(v, 'position'); this._position.set(x, y, z); }

	get rotation() { this._syncSolver(); return this._rotation; }
	set rotation(v) { const [x, y, z] = asTriple(v, 'rotation'); this._rotation.set(x, y, z); }

	_syncSolver() {
		if (!this._solverOwned || this._i < 0) return;
		const t = H.physicsTransform(this._i, this._g);
		if (t === null) return;
		this._position._adopt(t[0], t[1], t[2]);
		this._rotation._adopt(t[3], t[4], t[5]);
		// The host's rotation is authoritative now, so the exact quaternion
		// a glTF node arrived with is no longer what this object is at.
		this._q = null;
	}

	get name() { return this._name; }
	set name(v) {
		this._name = String(v);
		if (this._i >= 0) H.setName(this._i, this._g, this._name);
	}

	get visible() { return this._visible; }
	set visible(v) {
		this._visible = !!v;
		if (this._i >= 0) H.setVisible(this._i, this._g, this._visible);
	}

	// What this object draws, or null for a group. Overridden by Mesh.
	_ref() { return null; }

	// Which of the host's materials this object draws with, or -1 for "say
	// nothing and leave it at the default". A Mesh answers with the
	// ShaderMaterial it was given; a helper answers with the line material,
	// which is the one thing here a script cannot name. A Group has no
	// `_material` at all, so it answers -1 and costs no crossing.
	_hostMaterial() { return this._material ? this._material._index() : -1; }

	// -------------------------------------------------------------------
	// Animation
	//
	// Only an object from `asset.instantiate()` has any: a clip targets
	// glTF nodes, so playing one needs a subtree that came from a file. On
	// anything else `animations` is empty and `play` throws with a sentence
	// saying which door to use, rather than returning false and leaving a
	// script to wonder whether the clip name was wrong.
	//
	// **Deliberately not an AnimationMixer.** Three.js's mixer/clip/action
	// trio earns its complexity on crossfading; there is no crossfading here
	// yet, and a partial mixer answering to the same name would be worse
	// than a smaller thing with a different one. See G3/S7.

	get animations() { return this._clips ? this._clips.slice() : []; }

	play(name, { loop = true, speed = 1 } = {}) {
		if (!this._clips) {
			throw new Error(
				'play() works on an object from asset.instantiate(), which is what carries a file\'s '
				+ 'animation clips. This object has none.'
			);
		}
		if (this._i < 0) {
			throw new Error(`play("${name}") needs ${this._name || 'the object'} to be in a scene — add it first`);
		}
		if (!this._clips.includes(name)) {
			const have = this._clips.length ? this._clips.join(', ') : '(none)';
			throw new Error(`no animation named "${name}" — this one has: ${have}`);
		}
		// The host learns the node map on the first play and not before: a
		// prop that never animates never sends it.
		this._bindAnimation();
		H.playAnimation(this._i, this._g, String(name), !!loop, +speed);
		return this;
	}

	stop() {
		if (this._i >= 0 && this._clips) H.stopAnimation(this._i, this._g);
		return this;
	}

	// Flat triples — glTF node index, host node index, host node generation
	// — for every descendant that came from a glTF node. The per-primitive
	// children `instantiate()` synthesizes carry no glTF index and are
	// skipped, because no channel can name them.
	_bindAnimation() {
		if (this._bound) return;
		const pairs = [];
		const walk = (o) => {
			if (o._gltfNode >= 0 && o._i >= 0) pairs.push(o._gltfNode, o._i, o._g);
			for (const c of o.children) walk(c);
		};
		walk(this);
		H.bindAnimation(this._i, this._g, this._asset[0], this._asset[1], pairs);
		this._bound = true;
	}

	_flush() {
		if (this._i < 0) return;
		const { position: p, rotation: r, scale: s } = this;
		H.setTransform(this._i, this._g, p._x, p._y, p._z, r._x, r._y, r._z, s._x, s._y, s._z);
		if (this._q) H.setQuaternion(this._i, this._g, this._q[0], this._q[1], this._q[2], this._q[3]);
	}

	// Create the host node for this object under `parent`, then replay
	// everything set before the add, then do the same for the subtree.
	_materialize(parent) {
		const ref = this._ref();
		const [i, g] = H.add(
			ref ? ref.asset : -1, ref ? ref.assetGeneration : 0, ref ? ref.mesh : -1,
			parent._i, parent._g, this._name,
		);
		this._i = i;
		this._g = g;
		this._flush();
		if (!this._visible) H.setVisible(i, g, false);
		const material = this._hostMaterial();
		if (material >= 0) H.setMaterial(i, g, material);
		// Only when they are not the identity: `_materialize` runs once per
		// object added, and a scene of ten thousand default-coloured meshes
		// should not pay twenty thousand crossings to say "white, row zero".
		if (this._color && !(this._color[0] === 1 && this._color[1] === 1 && this._color[2] === 1 && this._color[3] === 1)) {
			H.setColor(i, g, ...this._color);
		}
		if (this._variant) H.setVariant(i, g, this._variant);
		for (const child of this.children) child._materialize(this);
	}

	// The host node is gone; this object is a detached description again, and
	// re-adding it builds a new node. The whole subtree goes with it, because
	// removing a node removes its descendants.
	_demote() {
		this._i = -1;
		this._g = -1;
		for (const child of this.children) child._demote();
	}

	// Adding something that already has a parent moves it, which is what
	// Three.js does — and moving keeps the node rather than destroying and
	// rebuilding it, so a handle to a re-parented object stays valid and the
	// generation does not climb. Three cases: both in the scene is a
	// re-parent, neither is bookkeeping, and moving a live object under a
	// detached one takes it out of the scene.
	add(...objects) {
		for (const o of objects) {
			if (o === this) throw new TypeError('an object cannot be added to itself');
			if (!(o instanceof Object3D)) throw new TypeError('add() wants a Mesh, a Group or a Scene');
			// By marker rather than `instanceof Scene`: the class lives in a module
			// that extends this one, and a base importing its subclass is the one
			// import cycle module evaluation cannot untangle.
			if (o != null && o._isScene === true) throw new TypeError('a Scene cannot be added to anything');
			// A cycle would make the world-matrix walk recur forever.
			for (let up = this; up; up = up.parent) {
				if (up === o) throw new TypeError(`that would make ${o._name || 'an object'} its own ancestor`);
			}

			if (o.parent) {
				const at = o.parent.children.indexOf(o);
				if (at >= 0) o.parent.children.splice(at, 1);
			}
			o.parent = this;
			this.children.push(o);

			if (this._i >= 0) {
				if (o._i >= 0) {
					H.setParent(o._i, o._g, this._i, this._g);
				} else {
					o._materialize(this);
				}
			} else if (o._i >= 0) {
				H.remove(o._i, o._g);
				o._demote();
			}
		}
		return this;
	}

	remove(...objects) {
		for (const o of objects) {
			const at = this.children.indexOf(o);
			if (at < 0) continue;
			this.children.splice(at, 1);
			o.parent = null;
			if (o._i >= 0) {
				H.remove(o._i, o._g);
				o._demote();
			}
		}
		return this;
	}

	// Depth first, this object included — Three.js's order. The child list is
	// copied so a callback that removes things does not skip siblings.
	traverse(fn) {
		fn(this);
		for (const child of [...this.children]) child.traverse(fn);
	}

	getObjectByName(name) {
		let found = null;
		this.traverse(o => { if (found === null && o.name === name) found = o; });
		return found;
	}

	getWorldPosition() {
		if (this._i < 0) throw new Error('this object is not in a scene yet — add() it first');
		const [x, y, z] = H.worldPosition(this._i, this._g);
		return new Vector3(null, x, y, z);
	}

	// -------------------------------------------------------------------
	// Measuring, and placing against what was measured
	//
	// Two boxes, and the split between them is the whole design:
	//
	//   boundingBox()      world space, computed by the host, for asking
	//                      where something *ended up*.
	//   boundsInParent()   the parent's space, computed here, for deciding
	//                      where something *should go*.
	//
	// Placement is the second one because that is the frame a script writes
	// in. A window is positioned inside its building's group; the group is
	// then rotated to face the square. Aligning in world space would mean
	// undoing that rotation to write a local `position`, and the round trip
	// through a matrix inverse is both slower and a place to be subtly wrong
	// at 90°, which is the single most common angle anyone types.

	// The world-space box of this object and everything under it, or null
	// when nothing in the subtree draws. Throws if this is not in a scene:
	// world space is a thing a scene has, and answering with the local box
	// would be a wrong answer rather than a missing one.
	boundingBox() {
		if (this._i < 0) throw new Error('this object is not in a scene yet — add() it first');
		return boxFromSix(H.objectBounds(this._i, this._g));
	}

	// This object's box in its parent's coordinates — its own mesh, its
	// descendants, and its own local transform applied. Works before `add()`,
	// which is the point: a kit piece can be sized and placed while it is
	// still a detached description.
	boundsInParent() {
		const ref = this._ref();
		let box = ref === null ? null : refBounds(ref, 'boundsInParent()');
		for (const child of this.children) {
			const inner = child.boundsInParent();
			if (inner === null) continue;
			box = box === null ? inner : box.union(inner);
		}
		if (box === null) return null;
		return transformBox(box, this.position, this.rotation, this.scale);
	}

	// Move along one axis until a chosen face of this object's box sits at
	// `at`, in the parent's coordinates. The verb that replaces arithmetic
	// on a hand-copied size table.
	//
	//   piece.align('y', 'min', 0)          // stand it on the ground
	//   piece.align('z', 'min', wallZ)      // back face flush with the wall
	//
	// Only `position` moves; rotation and scale are inputs to where the box
	// is, so set them first.
	align(axis, edge, at) {
		const box = this.boundsInParent();
		if (box === null) {
			throw new Error(
				'align() needs a box, and this object draws nothing — it is a Group with no meshes '
				+ 'under it, or its geometry is not resident. Align a Mesh, or add one first.');
		}
		const key = ['x', 'y', 'z'][axisIndex(axis, 'align()')];
		const to = +at;
		if (!Number.isFinite(to)) throw new TypeError(`align(${axis}, ${edge}, at) wants a number for at`);
		this.position[key] += to - box.edge(axis, edge);
		return this;
	}

	// The same move, expressed against a sibling instead of a number.
	//
	//   window.alignTo(wall, { axis: 'z', mine: 'min', theirs: 'max', offset: -0.28 })
	//
	// Siblings, because each box is measured in its own parent's frame and
	// two different parents are two different frames. Refused rather than
	// silently wrong — see the note above `boundingBox`.
	alignTo(other, { axis = 'y', mine = 'min', theirs = 'max', offset = 0 } = {}) {
		if (!(other instanceof Object3D)) {
			throw new TypeError('alignTo(other) wants another object as its first argument');
		}
		if (other.parent !== this.parent) {
			throw new Error(
				'alignTo() aligns siblings: both objects must share a parent, because a box is '
				+ 'measured in the frame of the parent it hangs from. For anything else, measure '
				+ 'with boundsInParent() and place with align(axis, edge, number).');
		}
		const box = other.boundsInParent();
		if (box === null) throw new Error('alignTo(): the object aligned to draws nothing, so it has no box');
		return this.align(axis, mine, box.edge(axis, theirs) + (+offset));
	}

	toJSON() {
		return {
			type: this.constructor.name,
			name: this._name,
			position: this.position.toJSON(),
			rotation: this.rotation.toJSON(),
			scale: this.scale.toJSON(),
			visible: this._visible,
			inScene: this._i >= 0,
			children: this.children.length,
		};
	}
}

// -----------------------------------------------------------------------
// Group

export class Group extends Object3D {}
