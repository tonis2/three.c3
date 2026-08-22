// three.c3 — the tier-1 scene API, as an agent sees it.
//
// This file is the API surface from `plan.md` §4. It is deliberately JavaScript
// rather than C3: the shape an agent has memorized is Three.js's, and matching
// it means constructors, prototype chains, getters that write through, and a
// `children` array that behaves like an array. Writing that in the host means
// one C3 function per property per class; writing it here means the host only
// has to expose flat verbs, and every Three.js-ism above them is ordinary JS.
//
// `js/bind_scene.c3` installs `globalThis.__three` — the flat verb layer — before
// this runs. Nothing here may assume anything else exists.
//
// ## Local transforms live here, not in the host
//
// `position`/`rotation`/`scale` are JavaScript numbers, and a write pushes all
// nine to the node in one call. That is safe only because nothing on the host
// side ever writes the local transform of a node JS created — the renderer reads
// world matrices, and world matrices are derived. If that ever stops being true,
// these become read-through accessors and this comment is the reason why.
//
// ## An object is not in the scene until it is added
//
// `new three.Mesh(ref)` creates no host node. `scene.add(m)` does, and that is
// what makes an unadded mesh invisible the way it is in Three.js rather than
// quietly rendering. Everything set before the add — transform, name, visibility,
// whole subtrees — is replayed onto the node at that moment (`_materialize`).

// Wrapped so the classes and helpers below stay out of the global lexical
// scope: a script that declares its own `Mesh` should shadow nothing here.
(() => {
	'use strict';

	const H = globalThis.__three;
	if (!H) throw new Error('three.c3: the host bindings are missing');

	// -----------------------------------------------------------------------
	// Vector3

	// A live component vector. `owner` is the Object3D it belongs to, or null
	// for a detached one (what `getWorldPosition` hands back) — a detached
	// vector is an ordinary value and writing to it changes nothing else.
	class Vector3 {
		constructor(owner, x = 0, y = 0, z = 0) {
			this._o = owner;
			this._x = x;
			this._y = y;
			this._z = z;
		}

		get x() { return this._x; }
		set x(v) { this._x = +v; this._o?._flush(); }

		get y() { return this._y; }
		set y(v) { this._y = +v; this._o?._flush(); }

		get z() { return this._z; }
		set z(v) { this._z = +v; this._o?._flush(); }

		// Take a value the host already has, without pushing it back.
		// `set` would flush, and flushing a solver-owned transform is the one
		// write the host refuses — so a read-back would throw on every frame.
		_adopt(x, y, z) {
			this._x = x;
			this._y = y;
			this._z = z;
			return this;
		}

		set(x, y, z) {
			this._x = +x;
			this._y = +y;
			this._z = +z;
			this._o?._flush();
			return this;
		}

		copy(v) { return this.set(v.x, v.y, v.z); }
		add(v) { return this.set(this._x + v.x, this._y + v.y, this._z + v.z); }
		sub(v) { return this.set(this._x - v.x, this._y - v.y, this._z - v.z); }
		multiplyScalar(s) { return this.set(this._x * s, this._y * s, this._z * s); }
		length() { return Math.hypot(this._x, this._y, this._z); }
		clone() { return new Vector3(null, this._x, this._y, this._z); }
		toArray() { return [this._x, this._y, this._z]; }

		// So `console.log(m.position)` and a returned value both read as numbers
		// rather than as "[object Object]".
		toJSON() { return { x: this._x, y: this._y, z: this._z }; }
		toString() { return `Vector3(${this._x}, ${this._y}, ${this._z})`; }
	}

	// An axis-aligned box, and the answer to "how big is this actually".
	//
	// **Why this exists at all.** A kit piece's origin is wherever whoever
	// exported it left it — the centre of the bounding box, one corner, the
	// world origin of the scene it was authored in. Nothing about a transform
	// says where the piece's *faces* are, so "put this window on that wall" is
	// unanswerable from `position` alone. Without a box a script has to carry a
	// hand-copied table of piece sizes, and that table goes stale silently: the
	// piece still draws, it just sinks into the masonry.
	//
	// `size` and `center` are derived rather than stored, because a box that can
	// disagree with itself is worse than one arithmetic operation.
	class Box3 {
		constructor(minX, minY, minZ, maxX, maxY, maxZ) {
			this.min = new Vector3(null, minX, minY, minZ);
			this.max = new Vector3(null, maxX, maxY, maxZ);
		}

		get size() {
			return new Vector3(null, this.max.x - this.min.x, this.max.y - this.min.y, this.max.z - this.min.z);
		}

		get center() {
			return new Vector3(null,
				(this.min.x + this.max.x) / 2, (this.min.y + this.max.y) / 2, (this.min.z + this.max.z) / 2);
		}

		// One face's coordinate on one axis. `align` is written in terms of this
		// and so is every placement a script does by hand.
		edge(axis, which) {
			const i = axisIndex(axis, 'box.edge');
			const lo = this.min.toArray()[i], hi = this.max.toArray()[i];
			switch (which) {
				case 'min': return lo;
				case 'max': return hi;
				case 'center': return (lo + hi) / 2;
				default: throw new TypeError(
					`box.edge(axis, which) wants 'min', 'center' or 'max', not ${JSON.stringify(which)}`);
			}
		}

		union(other) {
			return new Box3(
				Math.min(this.min.x, other.min.x), Math.min(this.min.y, other.min.y), Math.min(this.min.z, other.min.z),
				Math.max(this.max.x, other.max.x), Math.max(this.max.y, other.max.y), Math.max(this.max.z, other.max.z));
		}

		clone() {
			return new Box3(this.min.x, this.min.y, this.min.z, this.max.x, this.max.y, this.max.z);
		}

		toJSON() {
			return { min: this.min.toArray(), max: this.max.toArray(), size: this.size.toArray(), center: this.center.toArray() };
		}
		toString() { return `Box3(min ${this.min}, max ${this.max})`; }
	}

	function axisIndex(axis, where) {
		const i = { x: 0, y: 1, z: 2, X: 0, Y: 1, Z: 2 }[axis];
		if (i === undefined) {
			throw new TypeError(`${where} wants an axis of 'x', 'y' or 'z', not ${JSON.stringify(axis)}`);
		}
		return i;
	}

	function boxFromSix(six) {
		return six === null ? null : new Box3(six[0], six[1], six[2], six[3], six[4], six[5]);
	}

	// A mesh reference's own box, in the mesh's local space.
	//
	// Not cached. The numbers never change for a live asset, but caching them
	// would mean a reference outliving an `unloadUnused()` kept answering with
	// what used to be true — and every other handle in this API revalidates on
	// use rather than trusting a copy. The host reads it out of the glTF JSON,
	// so this costs no upload.
	function refBounds(ref, where) {
		const six = H.meshBounds(ref.asset, ref.assetGeneration, ref.mesh);
		if (six === null) throw new Error(`${where}: that mesh reference names nothing`);
		return boxFromSix(six);
	}

	// The rotation part of a local TRS as a 3x3, in the order `scene/node.c3`
	// documents: Rx * Ry * Rz, Three.js's default Euler order.
	function eulerMatrix3(x, y, z) {
		const cx = Math.cos(x), sx = Math.sin(x);
		const cy = Math.cos(y), sy = Math.sin(y);
		const cz = Math.cos(z), sz = Math.sin(z);
		return [
			cy * cz,                  -cy * sz,                 sy,
			sx * sy * cz + cx * sz,   -sx * sy * sz + cx * cz,  -sx * cy,
			-cx * sy * cz + sx * sz,  cx * sy * sz + sx * cz,   cx * cy,
		];
	}

	// A box through a local TRS, still axis-aligned: the standard
	// centre-and-half-extent form, where the extent is |M| times the old extent.
	function transformBox(box, position, rotation, scale) {
		const m = eulerMatrix3(rotation.x, rotation.y, rotation.z);
		const c = box.center, h = box.size.multiplyScalar(0.5);
		const sx = scale.x, sy = scale.y, sz = scale.z;
		const cx = c.x * sx, cy = c.y * sy, cz = c.z * sz;
		const hx = Math.abs(h.x * sx), hy = Math.abs(h.y * sy), hz = Math.abs(h.z * sz);
		const out = [];
		for (let r = 0; r < 3; r++) {
			const a = m[r * 3], b = m[r * 3 + 1], d = m[r * 3 + 2];
			out.push(a * cx + b * cy + d * cz, Math.abs(a) * hx + Math.abs(b) * hy + Math.abs(d) * hz);
		}
		return new Box3(
			position.x + out[0] - out[1], position.y + out[2] - out[3], position.z + out[4] - out[5],
			position.x + out[0] + out[1], position.y + out[2] + out[3], position.z + out[4] + out[5]);
	}

	// What `scene.background = null` restores. Kept in step with `DEFAULT_CLEAR`
	// in gpu/frame.c3 by `the_default_background_is_the_renderer_clear` rather
	// than by a comment, because two spellings of one constant is exactly the
	// kind of drift that renders fine and is wrong.
	const DEFAULT_BACKGROUND = [0.10, 0.11, 0.13];

	// Read a colour out of whatever the script had to hand: `[r, g, b]`,
	// `[r, g, b, a]`, `{ r, g, b }`, or Three.js's hex — `0xff8800`.
	//
	// **The components are what the pixel gets, and there is no colour
	// management anywhere in this project.** A hex value is therefore divided by
	// 255 and not de-gamma'd: `mesh.color = 0xff8800` renders the byte values it
	// spells, which is also what `base_color` out of a glTF does. Three.js
	// converts sRGB to linear on the way in and back on the way out, and doing
	// half of that here would be worse than doing neither.
	function readColor(v, where) {
		if (typeof v === 'number') {
			if (!Number.isFinite(v) || v < 0 || v > 0xffffff) {
				throw new RangeError(`${where} wants a hex colour between 0x000000 and 0xffffff, got ${v}`);
			}
			const hex = Math.floor(v);
			return [((hex >> 16) & 255) / 255, ((hex >> 8) & 255) / 255, (hex & 255) / 255, 1];
		}
		let c;
		if (Array.isArray(v) && v.length >= 3 && v.length <= 4) {
			c = [+v[0], +v[1], +v[2], v.length === 4 ? +v[3] : 1];
		} else if (v !== null && typeof v === 'object' && 'r' in v) {
			c = [+v.r, +v.g, +v.b, v.a === undefined ? 1 : +v.a];
		} else {
			throw new TypeError(`${where} wants [r, g, b], [r, g, b, a], {r, g, b} or a hex number like 0xff8800`);
		}
		for (const n of c) {
			if (!Number.isFinite(n)) throw new TypeError(`${where} was given a non-finite component`);
		}
		return c;
	}

	// Read a position or a direction out of whatever the script had to hand: a
	// Vector3, a plain `{x, y, z}`, or a three-element array. An agent that
	// wrote `[0, -1, 0]` should not have to find out which one this wanted, and
	// the three are unambiguous.
	function readVector(v, where) {
		let x, y, z;
		if (Array.isArray(v) && v.length >= 3) {
			[x, y, z] = v;
		} else if (v !== null && typeof v === 'object' && 'x' in v) {
			({ x, y, z } = v);
		} else {
			throw new TypeError(`${where} wants a Vector3, an {x, y, z} or an [x, y, z]`);
		}
		if (!(Number.isFinite(+x) && Number.isFinite(+y) && Number.isFinite(+z))) {
			throw new TypeError(`${where} was given a vector with a non-finite component`);
		}
		return [+x, +y, +z];
	}

	// -----------------------------------------------------------------------
	// Object3D

	class Object3D {
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
				if (o instanceof Scene) throw new TypeError('a Scene cannot be added to anything');
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
	// Group, Mesh, Scene

	class Group extends Object3D {}

	// Which faces a material keeps. Three.js's names and Three.js's numbers —
	// see `cull_for_side` in scene/material.c3, which is where the numbers stop
	// being a convention and become a Vulkan cull mode.
	//
	// `BackSide` keeps the back faces, so it culls the front ones. That reads
	// backwards and is worth saying out loud once: it is the setting that makes
	// a sphere visible from *inside*, which is what a skydome is.
	const FrontSide = 0;
	const BackSide = 1;
	const DoubleSide = 2;

	// How a material's colour combines with what is already on the screen.
	// Three.js's names and Three.js's numbers again — see `blend_for` in
	// scene/material.c3, which is where these stop being a convention and become
	// a Vulkan blend state.
	//
	// `NoBlending` is the default and that is worth reading twice, because it is
	// the opposite of what "a material has an opacity" suggests: an opaque
	// pipeline throws the alpha away, so `opacity` on a material that never asked
	// to blend does nothing at all. Three.js behaves the same way. Ask for
	// `{ transparent: true }` — or for a blending mode by name — and the opacity
	// starts meaning something.
	const NoBlending = 0;
	const NormalBlending = 1;
	const AdditiveBlending = 2;

	// What `material.transparent = true` and `material.blending = ...` answer.
	// Written once because the two refusals are the same refusal, and two copies
	// of a sentence are two things to keep in step.
	const BLENDING_IS_BAKED =
		'blending is baked into the pipeline on this device — build a new material '
		+ 'with { transparent } or { blending } instead';

	// An image on the device, and the handle a script holds it by.
	//
	// Three.js's TextureLoader is asynchronous and hands back a Texture that
	// fills in later; this one is already uploaded by the time the constructor
	// returns, so `width` and `height` are readable immediately and there is no
	// onLoad. `await three.texture(...)` still works — awaiting a plain value is
	// a no-op — so the Three.js-shaped line an agent writes is correct here.
	//
	// Deduplicated by the *content* of the decoded image, not by the path: two
	// calls naming two files that hold the same picture are one upload, and so
	// are a .png on disk and the identical image inside a .glb. Each call still
	// answers with its own Texture holding its own reference, so disposing one
	// does not disturb the other.
	class Texture {
		constructor(handle, path = null) {
			const [index, width, height] = handle;
			this._t = index;
			// Null for a DataTexture, which came from no file. Reported as null
			// rather than as a made-up name like '<data>', so a script can ask
			// `if (tex.path)` and get an answer rather than a string that looks
			// like somewhere to look.
			this._path = path;
			this._width = width;
			this._height = height;
		}

		get width() { return this._width; }
		get height() { return this._height; }
		get path() { return this._path; }

		// Whether this handle still names an image. False after dispose(), and
		// the reason a disposed Texture throws rather than quietly texturing
		// something with whatever took its slot.
		get alive() { return this._t >= 0; }

		// The pixels, copied back off the device, as a Uint8Array of RGBA
		// bytes — width * height * 4 of them, row by row from the top.
		//
		// **The bytes that went in, not the ones the shader sees.** The copy
		// converts nothing, so a texture made from a DataTexture reads back
		// byte-for-byte identical to the array it was built from, and a PNG
		// reads back as the PNG's own pixels. The sampler's sRGB-to-linear
		// decode happens at sample time and is not in here.
		//
		// `into` is optional and exists because this is not free: it copies the
		// image off the device and waits for the queue, so a caller doing it
		// repeatedly should hand the same array back rather than allocate one
		// per call. Without it a fresh Uint8Array is made each time.
		read(into) {
			if (this._t < 0) {
				throw new TypeError('this texture has been disposed — read() it before dispose(), or keep a reference');
			}
			const need = this._width * this._height * 4;
			const out = into === undefined ? new Uint8Array(need) : into;
			if (!(out instanceof Uint8Array)) {
				throw new TypeError('texture.read(into) wants a Uint8Array, or nothing at all');
			}
			if (out.length < need) {
				throw new RangeError(
					`texture.read(into) needs ${need} bytes for this ${this._width}x${this._height} image, `
					+ `and was given ${out.length}`);
			}
			H.textureRead(this._t, out);
			return out;
		}

		// Give back the reference this handle holds.
		//
		// **Not a free.** The image goes only when nothing names it at all, so
		// disposing while a material still draws with it leaves that material
		// correct — which is what makes this safe to call as soon as a script is
		// done *referring* to the texture, rather than something to be timed
		// against the materials that use it.
		//
		// Disposing twice is not an error. The second call has nothing to give
		// back and says so by doing nothing, which is what makes dispose() safe
		// in a cleanup path that may run more than once.
		dispose() {
			if (this._t < 0) return;
			H.textureDispose(this._t);
			this._t = -1;
		}

		// What the host wants for a `map`: the index, or NoTexture for none.
		// Throws rather than falling back to NoTexture, because a disposed
		// texture assigned to a material is a mistake whose symptom is an
		// untextured mesh — indistinguishable from having forgotten the line.
		_index() {
			if (this._t < 0) {
				throw new TypeError(
					`this texture was disposed${this._path ? ` (${this._path})` : ''} — `
					+ `${this._path ? 'load' : 'build'} it again to use it`
				);
			}
			return this._t;
		}

		toJSON() {
			return { path: this._path, width: this._width, height: this._height, alive: this.alive };
		}

		toString() {
			return `${this.constructor.name}(${this._path ?? 'data'} ${this._width}x${this._height})`;
		}
	}

	// Pixels a script built, uploaded as a texture — Three.js's name for exactly
	// this, and the reason `Texture` is a class rather than a plain object.
	//
	// `new THREE.DataTexture(data, width, height, format)` there takes a format
	// argument and needs `.needsUpdate = true` before it does anything. This one
	// is RGBA8 only and is on the device by the time the constructor returns, so
	// there is nothing to flag and nothing to schedule.
	//
	// **Deduplicated against every other texture**, which is worth knowing before
	// building one in a loop: generated pixels and the identical image loaded
	// from a .png land in one slot, because the content hash has no idea where
	// bytes came from. Regenerating the same texture every frame costs one
	// upload and a hash of the bytes — not nothing, but not an upload.
	//
	// A plain Array is accepted and widened. It is what a script most naturally
	// builds, it has no contiguous bytes for the host to read, and refusing it
	// over a detail of which container was used would be refusing the obvious
	// thing for no reason the author can see. A Uint8Array skips the copy.
	class DataTexture extends Texture {
		constructor(data, width, height) {
			if (!Number.isInteger(width) || !Number.isInteger(height)) {
				throw new TypeError(
					'new three.DataTexture(data, width, height) wants whole-number dimensions'
				);
			}
			// Before the byte count, and that order is the point. 0x0 wants zero
			// bytes, so a count check reached first would answer "0 RGBA bytes and
			// 4 were given" — arithmetically true and useless. The dimensions are
			// what is wrong.
			if (width < 1 || height < 1) {
				throw new RangeError(
					`new three.DataTexture(data, width, height) wants positive dimensions, got ${width}x${height}`
				);
			}
			const bytes = data instanceof Uint8Array ? data
				: (Array.isArray(data) || data instanceof Uint8ClampedArray) ? new Uint8Array(data)
				: null;
			if (bytes === null) {
				throw new TypeError(
					'new three.DataTexture(data, ...) wants a Uint8Array or an Array of RGBA bytes, '
					+ `not ${data === null ? 'null' : typeof data}`
				);
			}
			// Checked here as well as in the host so the message can do the
			// arithmetic — "you gave 12288 and 64x64 needs 16384" is a sentence
			// somebody can act on without reaching for a calculator.
			if (bytes.length !== width * height * 4) {
				throw new RangeError(
					`${width}x${height} is ${width * height * 4} RGBA bytes and ${bytes.length} were given `
					+ '— four per pixel, in r, g, b, a order'
				);
			}
			super(H.dataTexture(bytes, width, height), null);
		}
	}

	// `Material.texture` in scene/material.c3 — "this material has no image of
	// its own, use whatever the mesh brought".
	const NoTexture = -1;

	// What every material here has, which is a pipeline index, a side and a map.
	//
	// It exists as a base class rather than as duplicated accessors because
	// `mesh.material` has to accept both kinds and there is exactly one correct
	// answer to "is this a material" — `instanceof Material`. Writing the check
	// as a union of the two concrete classes would have to be edited every time
	// a third arrives, and the edit that gets forgotten is the one that makes a
	// perfectly good material throw.
	class Material {
		constructor(handle, side, blending = NoBlending) {
			this._m = handle;
			this._side = side;
			// Stored rather than asked for, because there is nothing to ask: the
			// blend mode is baked into the pipeline the handle names and the host
			// has no verb that reads one back. It cannot go stale either — see the
			// setter, which is a throw.
			this._blending = blending;
			this._map = null;
		}

		// Whether this handle still names a material. False after dispose().
		get alive() { return this._m >= 0; }

		// The index the host wants, or a throw.
		//
		// Every crossing goes through this rather than reading `_m` directly, so
		// that a disposed handle fails at the line that used it. The alternative
		// — passing -1 along — reaches the host as "no such material", which is
		// the same message a handle from another renderer gets and sends whoever
		// is reading it to the wrong question.
		_index() {
			if (this._m < 0) {
				throw new TypeError(
					'this material was disposed — build it again to use it'
				);
			}
			return this._m;
		}

		// Give back the reference this handle holds.
		//
		// **Not a free**, exactly as `texture.dispose()` is not. The material goes
		// when nothing names it at all, so disposing while a mesh is still drawing
		// with it leaves that mesh correct and collects the material when the mesh
		// goes — which is what makes this safe to call as soon as a script is done
		// *referring* to the material.
		//
		// What it gives back is the pipeline. A material an agent compiled holds a
		// `VkPipeline` for the life of the process otherwise, and an agent
		// iterating on a shader compiles a new one every run — `plan.md` §1.
		//
		// Disposing twice does nothing, so a cleanup path may run more than once.
		// The two built-in materials cannot be disposed at all: `mesh.material =
		// null` is what gives one of those back, and it was never a handle.
		dispose() {
			if (this._m < 0) return;
			H.disposeMaterial(this._m);
			this._m = -1;
		}

		// Which faces this material keeps.
		//
		// Three.js's property, Three.js's constants, and Three.js's default —
		// `FrontSide`. It is on the material rather than on the mesh because it
		// is a property of the *pipeline*: two meshes drawing the same geometry
		// with the same material are one draw call, and they stop being one the
		// moment they can disagree about which faces to keep. A mesh that wants
		// another side wants a material.
		//
		// This is the setting a sky needs. A sphere seen from the inside shows
		// only its back faces, so under the default it is not merely dark, it is
		// *absent* — and scaling it by -1 does not help, because a negative scale
		// does not reverse a triangle's winding. Before this existed the way
		// round it was five inward-facing planes.
		get side() { return this._side; }

		set side(v) {
			Material._checkSide(v);
			const index = this._index();
			if (v === this._side) return;
			H.setSide(index, v);
			this._side = v;
		}

		// Whether this material blends with what is already on the screen, and
		// how.
		//
		// `transparent` is Three.js's flag and `blending` is Three.js's mode; here
		// the first is derived from the second, because a material that blends is
		// exactly a material whose mode is not NoBlending and two fields that can
		// disagree about one fact are a bug waiting for a script to write both.
		//
		// **Both are read-only, and that is a property of this device rather than
		// a design preference.** Metal bakes blending into the compiled pipeline
		// state, so the Vulkan driver here reports every dynamic colour-blend
		// feature as false (`plan.md` §10 has the probe). Changing this would mean
		// building another pipeline, which needs the device, the target and the
		// assembled shader source read back out of a cache — all to save a script
		// the one line that builds the material it meant.
		get transparent() { return this._blending !== NoBlending; }

		set transparent(v) { throw new TypeError(BLENDING_IS_BAKED); }

		get blending() { return this._blending; }

		set blending(v) { throw new TypeError(BLENDING_IS_BAKED); }

		// How much of this material shows, 0 to 1.
		//
		// **Settable and free**, unlike `blending`: it is one float in the push
		// block, so an animation callback may write it every frame and nothing is
		// rebuilt. It multiplies whatever alpha the mesh itself carries, so a
		// glTF's own transparency and a script's fade compose rather than one
		// overwriting the other.
		//
		// **It does nothing unless the material was built transparent.** An opaque
		// pipeline discards the alpha the shader writes, so this reads back as the
		// number that was set and the picture does not move. That is the hardware's
		// answer rather than a rule chosen here, and it is Three.js's behaviour
		// too — `opacity` without `transparent` is inert there as well.
		get opacity() { return H.getOpacity(this._index()); }

		set opacity(v) {
			if (typeof v !== 'number' || !Number.isFinite(v) || v < 0 || v > 1) {
				throw new TypeError('`opacity` wants a number from 0 to 1, not ' + String(v));
			}
			H.setOpacity(this._index(), v);
		}

		// The base colour image, or null.
		//
		// The material's map wins over whatever image the *mesh* carries, so a
		// glTF's own texture can be overridden by assigning one here and cannot
		// silently override one a script asked for.
		//
		// **A mesh with no uvs shows nothing**, and that is the one case where
		// this looks broken and is not. Every parametric shape and every glTF
		// mesh carries uvs; a ConvexGeometry does not, because a hull of an
		// arbitrary point cloud has no natural parameterisation to give it. On
		// one of those the map is set, correct, and invisible.
		get map() { return this._map; }

		set map(v) {
			if (v !== null && v !== undefined && !(v instanceof Texture)) {
				throw new TypeError('material.map wants a three.texture(path), or null for none');
			}
			const texture = v ?? null;
			H.setMap(this._index(), texture === null ? NoTexture : texture._index());
			this._map = texture;
		}

		// How many times the map repeats across a surface, as [u, v].
		//
		// **This is why one plane can be a ground.** Nothing scales uvs by
		// default: a surface maps its texture exactly once, so texel density is
		// a function of how big the mesh is, and a 128px grass image stretched
		// over 132 world units is a smear. `examples/village` covered its ground
		// with 484 separate plane meshes purely to avoid that — one draw call
		// between them, and 484 nodes to say something one number says.
		//
		// **On the material rather than on the texture**, unlike Three.js. Not
		// for Three.js's reason: textures here are deduplicated by content across
		// every file, so a brick image loaded twice is deliberately one slot, and
		// a transform living there would change a wall's tiling because something
		// unrelated used the same picture.
		//
		// Zero throws. It maps every point of the surface to one texel, which is
		// never what anyone meant and is exactly what an unset field looks like.
		get repeat() {
			const [u, v] = H.getMaterialUv(this._index());
			return [u, v];
		}

		set repeat(value) {
			const [u, v] = asPair(value, 'material.repeat');
			const index = this._index();
			const uv = H.getMaterialUv(index);
			H.setMaterialUv(index, u, v, uv[2], uv[3]);
		}

		// Where the map starts, as [u, v]. One whole repeat is 1, so 0.5 shifts
		// the image half a tile — which is what an atlas or a scrolling texture
		// wants, and what stops two neighbouring walls from having visibly the
		// same crack in the same place.
		get offset() {
			const [, , u, v] = H.getMaterialUv(this._index());
			return [u, v];
		}

		set offset(value) {
			const [u, v] = asPair(value, 'material.offset');
			const index = this._index();
			const uv = H.getMaterialUv(index);
			H.setMaterialUv(index, uv[0], uv[1], u, v);
		}

		static _checkSide(v) {
			if (v !== FrontSide && v !== BackSide && v !== DoubleSide) {
				throw new TypeError(
					'`side` wants three.FrontSide, three.BackSide or three.DoubleSide, not ' + String(v)
				);
			}
		}

		static _checkBlending(v) {
			if (v !== NoBlending && v !== NormalBlending && v !== AdditiveBlending) {
				throw new TypeError(
					'`blending` wants three.NoBlending, three.NormalBlending or three.AdditiveBlending, not '
					+ String(v)
				);
			}
		}

		// Which blend mode a material's options add up to.
		//
		// Two spellings of one thing, so there has to be a rule about which wins,
		// and it is Three.js's: **an explicit `blending` wins**. That is what makes
		// `{ transparent: true, blending: three.NoBlending }` an opaque material in
		// both APIs rather than a contradiction one of them resolves the other way.
		// With no `blending` at all, `transparent: true` is NormalBlending — which
		// is the line an agent writes from memory of Three.js and has to work.
		//
		// A `transparent` that is not a boolean is refused by name rather than
		// coerced: `transparent: 0.5` is somebody meaning `opacity`, and a truthy
		// test would silently build a blended pipeline and leave the surface fully
		// opaque, which is the shape of failure that gets blamed on the renderer.
		static _resolveBlending(options) {
			if (options.blending !== undefined) {
				Material._checkBlending(options.blending);
				return options.blending;
			}
			if (options.transparent === undefined) return NoBlending;
			if (typeof options.transparent !== 'boolean') {
				throw new TypeError(
					'`transparent` wants true or false, not ' + String(options.transparent)
					+ ' — for a partial fade, set opacity'
				);
			}
			return options.transparent ? NormalBlending : NoBlending;
		}

		toJSON() {
			return {
				type: this.constructor.name,
				side: this._side,
				transparent: this.transparent,
				blending: this._blending,
				map: this._map?.toJSON() ?? null,
				alive: this.alive,
				// Only for a live material. A disposed one has no transform to
				// report and `_index` would throw out of a `JSON.stringify`, which
				// is the one place a throw is least expected. `opacity` crosses to
				// the host the same way and is null for the same reason; `blending`
				// is remembered on this side and survives the dispose.
				repeat: this.alive ? this.repeat : null,
				offset: this.alive ? this.offset : null,
				opacity: this.alive ? this.opacity : null,
			};
		}
	}

	// The built-in shader with an image on it, and the material to reach for when
	// what you want is a picture on a shape.
	//
	// **It compiles nothing.** The pipeline is the one the renderer built at
	// startup — the same one every untextured mesh already draws with — so
	// constructing one is a list push, it cannot fail with a shader diagnostic,
	// and it works in a build with no Slang. That is the whole reason it is not
	// a ShaderMaterial with a one-line body.
	//
	// Lambert rather than Basic or Standard, because that is what the built-in
	// shader actually computes: one directional light, an ambient floor, and no
	// specular term at all. Naming it MeshBasicMaterial would promise unlit and
	// deliver lit; naming it MeshStandardMaterial would promise metalness,
	// roughness and an environment and deliver none of them.
	//
	// It has no `color`. `mesh.color` is the per-copy channel and multiplies into
	// the sampled texel, so one material can tint a thousand copies differently
	// and still be one draw call — a colour here would be a second way to say the
	// same thing that also splits the batch.
	class MeshLambertMaterial extends Material {
		constructor(options = {}) {
			if (options === null || typeof options !== 'object') {
				throw new TypeError(
					'new three.MeshLambertMaterial({ map, side, transparent, blending, opacity }) wants an options object'
				);
			}
			const { map = null, side = FrontSide } = options;
			if (map !== null && map !== undefined && !(map instanceof Texture)) {
				throw new TypeError('`map` wants a three.texture(path), or null for none');
			}
			Material._checkSide(side);
			// Before `super`, because the blend mode is part of what the material
			// is made of: it chooses which of the three pipelines the pass built at
			// startup this handle names. Nothing is compiled either way.
			const blending = Material._resolveBlending(options);

			const texture = map ?? null;
			super(
				H.createTextureMaterial(texture === null ? NoTexture : texture._index(), side, blending),
				side,
				blending,
			);
			this._map = texture;
			// After `super`, because it is a write through the handle rather than a
			// part of it — and the setter is what refuses a value outside 0..1, so
			// the option and the property are checked by exactly one piece of code.
			if (options.opacity !== undefined) this.opacity = options.opacity;
		}
	}

	// -----------------------------------------------------------------------
	// Uniforms
	//
	// Two things in this file have uniforms — a ShaderMaterial and the one post
	// pass — and everything about how a script reaches them is the same. So it
	// is written once here rather than twice: one Proxy implementation, one
	// shape reader, one value check, and therefore one set of sentences a script
	// can be refused with.

	// A uniform's shape: how many floats wide, and how many rows.
	//
	// `[1, 0, 0]` is one row of three. `[[1, 0, 0], [0, 1, 0]]` is two rows
	// of three — a **column of the material's table**, indexed in the shader
	// by `s.variant`, which each mesh sets for itself. That is what lets one
	// material give a thousand copies four different looks in one draw call.
	//
	// `tables` is false for the post pass, which draws one triangle over the
	// whole frame and has no instance for a row to belong to. It changes the
	// sentence and not only the answer, because "an array of those for a table"
	// is advice a post body cannot take.
	function uniformShape(name, v, tables = true) {
		if (typeof v === 'number') return [1, 1];
		if (Array.isArray(v) && v.length >= 1 && v.length <= 4 && v.every(c => typeof c === 'number')) {
			return [v.length, 1];
		}
		if (tables && Array.isArray(v) && v.length >= 1 && v.every(Array.isArray)) {
			const width = v[0].length;
			if (!(width >= 1 && width <= 4)) {
				throw new TypeError(`uniform '${name}': each row is a number or up to four numbers`);
			}
			if (v.some(row => row.length !== width)) {
				throw new TypeError(`uniform '${name}': every row of a table has to be the same width, and the first is ${width}`);
			}
			return [width, v.length];
		}
		// A table where tables are not a thing gets its own sentence rather than
		// the general one, because "wants a number or an array" is true and does
		// not say why the array it was given is the wrong kind. `validate_post`
		// refuses it one layer down in the same words.
		if (!tables && Array.isArray(v) && v.length >= 1 && v.every(Array.isArray)) {
			throw new TypeError(
				`uniform '${name}' is a table, and a post pass draws one triangle over the whole frame — `
				+ 'there are no instances to select a row with'
			);
		}
		throw new TypeError(
			tables
				? `uniform '${name}' wants a number, an array of up to four numbers, or an array of those for a table`
				: `uniform '${name}' wants a number or an array of up to four numbers`
		);
	}

	// The numbers one write is made of, checked. Not the shape — this is the
	// value side, run on every assignment rather than once at construction.
	function uniformValues(name, v) {
		const n = typeof v === 'number' ? [v] : v;
		if (!Array.isArray(n) || n.length < 1 || n.length > 4) {
			throw new TypeError(`uniform '${name}' wants a number or an array of up to four numbers`);
		}
		for (const c of n) {
			if (!Number.isFinite(+c)) {
				throw new TypeError(`uniform '${name}' was given a non-finite value`);
			}
		}
		return n;
	}

	// The live `uniforms` object: reads give the last value written, writes go
	// to the device.
	//
	// A Proxy rather than accessors on a sealed object, because a script is
	// not evaluated in strict mode: assigning an unknown property to a sealed
	// object *silently does nothing* there, so `mat.uniforms.tnit = [0, 1, 0]`
	// would be a no-op that renders unchanged and reads like a shader bug. A set
	// trap throws either way. Measured, not assumed — the sealed version was
	// written first and `an_undeclared_uniform_cannot_be_assigned` caught it.
	//
	// `owner` supplies `_values`, `_rows`, `_set` and `_column`; `what` is how
	// the refusal names the thing that has no such uniform.
	function uniformsProxy(owner, declared, what) {
		return new Proxy({}, {
			get(_, name) {
				// A table hands back a proxy of its own, so that
				// `mat.uniforms.palette[2] = [1, 0, 0]` writes row 2 to the
				// device. Handing back the plain array instead would make that
				// line mutate a JavaScript value nothing ever reads again —
				// the same silent no-op the `set` trap below exists to
				// prevent, one level down.
				if (owner._rows[name] > 1) return owner._column(name);
				return owner._values[name];
			},
			has(_, name) { return declared.has(name); },
			ownKeys() { return [...declared]; },
			getOwnPropertyDescriptor(_, name) {
				if (!declared.has(name)) return undefined;
				return { enumerable: true, configurable: true, value: owner._values[name] };
			},
			set(_, name, v) {
				if (!declared.has(name)) {
					throw new TypeError(
						`${what} has no uniform called '${String(name)}' — it declared ${[...declared].join(', ') || 'none'}`
					);
				}
				owner._set(name, v);
				return true;
			},
		});
	}

	// The declared samplers of a shader, as `{ name: texture }`, checked before
	// anything crosses.
	//
	// Two lists come back rather than one object, because that is the shape the
	// host takes — names joined and ids joined, the same crossing the uniforms
	// make and for the same reason (the QuickJS shim reads a property by name and
	// cannot enumerate one).
	//
	// **`null` is a legal value and is not the same as leaving the name out.**
	// Leaving it out means the shader does not declare that sampler at all; `null`
	// means it declares it and starts it white, which is what a body that fills a
	// texture in later wants. `NoTexture` is what says so on the wire.
	function textureLists(textures, what) {
		if (textures === null || textures === undefined) return { names: [], ids: [], values: {} };
		if (typeof textures !== 'object') {
			throw new TypeError(`\`textures\` wants an object like { noise_map: three.texture('noise.png') }`);
		}
		const names = Object.keys(textures);
		const values = {};
		const ids = names.map((name) => {
			const v = textures[name];
			if (v !== null && v !== undefined && !(v instanceof Texture)) {
				throw new TypeError(
					`${what} texture '${name}' wants a three.texture(path) or a three.DataTexture, `
					+ 'or null for a sampler that starts white'
				);
			}
			values[name] = v ?? null;
			return v ? v._index() : NoTexture;
		});
		return { names, ids, values };
	}

	// The live `textures` object: reads give the texture last put in a sampler,
	// writes send it to the device.
	//
	// `uniformsProxy`'s shape and every one of its arguments — a Proxy rather than
	// a sealed object, because a script is not in strict mode and assigning an
	// unknown property to a sealed object silently does nothing, which here would
	// be a texture that never appears and a shader that looks broken.
	//
	// It is a *separate* proxy from `uniforms` rather than a merged one, because
	// the two are separate in the shader as well: a uniform is push-block bytes and
	// a texture is a descriptor, they are refused for different reasons, and a name
	// that is both is refused outright by `texture_problem`.
	function texturesProxy(owner, declared, what) {
		return new Proxy({}, {
			get(_, name) { return owner._textureValues[name]; },
			has(_, name) { return declared.has(name); },
			ownKeys() { return [...declared]; },
			getOwnPropertyDescriptor(_, name) {
				if (!declared.has(name)) return undefined;
				return { enumerable: true, configurable: true, value: owner._textureValues[name] };
			},
			set(_, name, v) {
				if (!declared.has(name)) {
					throw new TypeError(
						`${what} has no texture called '${String(name)}' — it declared ${[...declared].join(', ') || 'none'}`
					);
				}
				if (v !== null && v !== undefined && !(v instanceof Texture)) {
					throw new TypeError(
						`texture '${String(name)}' wants a three.texture(path) or a three.DataTexture, `
						+ 'or null to put white back'
					);
				}
				const texture = v ?? null;
				owner._setTexture(String(name), texture);
				owner._textureValues[name] = texture;
				return true;
			},
		});
	}

	// A shader written by whoever is driving, compiled the moment it is
	// constructed.
	//
	// Three.js's ShaderMaterial takes a whole vertex and fragment program and a
	// uniforms object of `{ value }` wrappers. This takes a fragment *function* —
	// `float3 shade(Surface s)` — and a flat uniforms object, because three.c3
	// supplies the vertex stage, the Surface, the descriptor layout and the push
	// block. That is what `plan.md` §4 calls tier 2, and it is what removes almost
	// every Vulkan failure mode while keeping the property that makes Three.js
	// pleasant to generate for.
	//
	// Compiling in the constructor rather than at first use is deliberate: the
	// error names the line the agent wrote, and it arrives at the line that wrote
	// it rather than three statements later inside render().
	class ShaderMaterial extends Material {
		constructor(options) {
			if (options === null || typeof options !== 'object') {
				throw new TypeError('new three.ShaderMaterial({ fragment, uniforms }) wants an options object');
			}
			const { uniforms = {}, textures = {}, vertex = '', bounds = 0, side = FrontSide } = options;
			if (vertex !== '' && typeof vertex !== 'string') {
				throw new TypeError('`vertex` wants a Slang body — void displace(inout Vertex v) { ... }');
			}
			// **The fragment body is optional once there is a vertex one**, and
			// defaults to the shading the built-in shader does. A material that
			// only wants to move geometry should not have to retype the default
			// look to say so — and the default is written here, once, rather than
			// left to whoever is generating the script to remember.
			const fragment = (typeof options.fragment === 'string' && options.fragment.trim().length > 0)
				? options.fragment
				: (vertex ? 'float3 shade(Surface s) { return s.albedo * lambert(s.normal); }' : options.fragment);
			if (typeof fragment !== 'string' || fragment.trim().length === 0) {
				throw new TypeError('a ShaderMaterial needs a `fragment` body — see three.getApiDocs()');
			}
			// A displacement the frustum does not know about is geometry that
			// vanishes at the edge of the screen and comes back when the camera
			// turns — which reads as a bug in the renderer. So the number is asked
			// for rather than guessed, and refused when it is not one.
			if (typeof bounds !== 'number' || !Number.isFinite(bounds) || bounds < 0) {
				throw new TypeError(
					'`bounds` wants how far your vertex body can move a vertex, in world units — a number of 0 or more'
				);
			}
			if (uniforms === null || typeof uniforms !== 'object') {
				throw new TypeError('`uniforms` wants an object like { tint: [1, 0.5, 0.2], time: 0 }');
			}
			// Every sampler the body wants, checked here so that a mistyped value
			// is refused before a shader is compiled for it. The names become
			// `[vk::binding(1, 0)] Sampler2D <name>;` lines in the generated
			// module, in this order — and nothing on this side ever says which
			// number: the host resolves them back by name through reflection.
			const declared = textureLists(textures, 'this material\'s');
			Material._checkSide(side);
			// After the fragment and the uniforms, so that a material with a
			// missing body is told about the body first — the blend mode is the
			// least of what is wrong with it.
			const blending = Material._resolveBlending(options);

			// The enumeration happens here because it cannot happen in the host:
			// the QuickJS shim exposes property *get* by name and nothing that
			// lists keys. So the names cross as a joined string — see
			// js/bind_shader.c3.
			const names = Object.keys(uniforms);
			const shapes = names.map(n => uniformShape(n, uniforms[n]));
			// Every table in one material is a column of the same table, so the
			// row counts have to agree. Checked here as well as in the host so
			// the message can name both columns before a shader is written.
			const tabled = names.filter((n, i) => shapes[i][1] > 1);
			if (tabled.length > 1) {
				const rows = tabled.map(n => shapes[names.indexOf(n)][1]);
				if (rows.some(r => r !== rows[0])) {
					throw new TypeError(
						`the arrays in one material are columns of one table and must have the same number of rows: `
						+ tabled.map((n, i) => `${n} has ${rows[i]}`).join(', ')
					);
				}
			}

			// `super` before any `this`, which is why the compile happens in the
			// argument: the material index is what the base class is made of.
			super(H.createMaterial(
				fragment,
				names.join(','),
				shapes.map(s => s[0]).join(','),
				shapes.map(s => s[1]).join(','),
				side,
				blending,
				declared.names.join(','),
				declared.ids.join(','),
				vertex,
				bounds,
			), side, blending);
			this.fragment = fragment;
			this.vertex = vertex;
			this.bounds = bounds;
			if (options.opacity !== undefined) this.opacity = options.opacity;
			this._rows = {};
			for (const [i, name] of names.entries()) this._rows[name] = shapes[i][1];

			// Bound by the host during `createMaterial` — the constructor took the
			// ids with it — so this is the record of what went in rather than a
			// second pass of crossings.
			this._textureValues = { ...declared.values };
			this.textures = texturesProxy(this, new Set(declared.names), 'this material');

			// The Proxy is `uniformsProxy` above, shared with the post pass: one
			// implementation of "assigning an undeclared uniform throws", and so
			// no way for the two to drift apart.
			this._values = {};
			this.uniforms = uniformsProxy(this, new Set(names), 'this material');
			for (const name of names) this._set(name, uniforms[name]);
		}

		// The whole uniform: one row, or every row of a column.
		_set(name, v) {
			if (this._rows[name] > 1) {
				if (!Array.isArray(v) || v.length !== this._rows[name]) {
					throw new TypeError(
						`uniform '${name}' is a table of ${this._rows[name]} rows — assign all of them, or one at a time with ${name}[i] = ...`
					);
				}
				this._values[name] = [];
				for (let i = 0; i < v.length; i++) this._setRow(name, i, v[i]);
				return;
			}
			this._setRow(name, 0, v);
		}

		_setRow(name, row, v) {
			const rows = this._rows[name] ?? 1;
			if (!(row >= 0 && row < rows)) {
				throw new RangeError(`uniform '${name}' has ${rows} row${rows === 1 ? '' : 's'}, so row ${row} is not one of them`);
			}
			const n = uniformValues(name, v);
			H.setUniform(
				this._index(), name,
				+n[0], +(n[1] ?? 0), +(n[2] ?? 0), +(n[3] ?? 0), n.length,
				row, rows,
			);
			const stored = typeof v === 'number' ? +v : n.map(Number);
			if (rows > 1) {
				this._values[name][row] = stored;
			} else {
				this._values[name] = stored;
			}
		}

		// One sampler, sent to the device. `null` puts white back rather than
		// leaving the binding empty — a binding the draw does not write is
		// undefined behaviour that nothing reports, so there is no such thing as
		// "empty" past this line.
		_setTexture(name, texture) {
			H.setMaterialTexture(this._index(), name, texture === null ? NoTexture : texture._index());
		}

		// A live view of one column: reads give the row, writes send it to the
		// device. Rebuilt per access rather than cached, because it holds nothing
		// but the name and a script that keeps one is holding a view rather than
		// a copy either way.
		_column(name) {
			const owner = this;
			return new Proxy(owner._values[name], {
				get(rows, key) {
					if (key === 'length') return rows.length;
					if (typeof key === 'string' && /^\d+$/.test(key)) return rows[+key];
					const value = rows[key];
					return typeof value === 'function' ? value.bind(rows) : value;
				},
				set(_, key, v) {
					if (!(typeof key === 'string' && /^\d+$/.test(key))) {
						throw new TypeError(`uniform '${name}' is a table — write a row, like ${name}[0] = [1, 0, 0]`);
					}
					owner._setRow(name, +key, v);
					return true;
				},
			});
		}

		toJSON() {
			return {
				fragment: this.fragment,
				// Both only when there is one, so a material that does not move its
				// geometry serialises as it did before a vertex stage existed.
				...(this.vertex ? { vertex: this.vertex, bounds: this.bounds } : {}),
				side: this._side,
				transparent: this.transparent,
				blending: this._blending,
				// Live only, for `Material.toJSON`'s reason: reading it is a host
				// crossing and a disposed handle has nothing to cross with.
				opacity: this.alive ? this.opacity : null,
				map: this._map?.toJSON() ?? null,
				uniforms: { ...this._values },
				// The names as well as the images, so a material with a sampler it
				// has not filled yet still says the sampler is there.
				textures: Object.fromEntries(
					Object.keys(this._textureValues).map(n => [n, this._textureValues[n]?.toJSON() ?? null])
				),
			};
		}
	}

	// -----------------------------------------------------------------------
	// The post chain
	//
	// Full-screen shaders over the finished frame, in the order they were added.
	// `three.setPost(spec)` makes one pass the whole chain; `three.addPass(spec)`
	// puts another at the end of it. Each reads what the pass before it wrote,
	// and the original frame as `p.scene` — that is the entire dependency
	// declaration, and it is the pass's position in the list.
	//
	// Verbs and not a class, because there is one chain and it belongs to the
	// renderer: a constructor implies an assignment target — somewhere to put a
	// second chain, something to swap between — and there is none.
	//
	// What a script gets back is a handle onto one live pass: the body that is
	// running, its index in the chain, and a live uniforms Proxy. It goes stale
	// the moment a setPost replaces the chain, and says so, for the reason a
	// Scene does: the alternative is `old.uniforms.gain = 2` quietly steering the
	// *new* shader's uniform of the same name.

	// Bumped by every call that replaces the whole chain — a successful setPost
	// and a setPost(null). A handle remembers the number it was made at.
	//
	// **addPass does not bump it**, and that is the whole difference between the
	// two verbs from a handle's point of view: appending leaves every earlier
	// pass exactly where it was, at the same index, running the same shader, so
	// there is nothing for an existing handle to have gone stale about.
	let postEpoch = 0;

	function postHandle(fragment, names, declared = { names: [], values: {} }, index = 0) {
		const epoch = postEpoch;
		const handle = { fragment, index };
		// Off the enumeration, so that returning the handle from a script
		// stringifies as the two things it is — the body and the uniforms — and
		// not as the bookkeeping behind them.
		const internals = {
			_values: {},
			// Every post uniform is one row. The map is here because
			// `uniformsProxy` reads it, and it stays empty because a post pass
			// draws one triangle over the whole frame: there is no instance for a
			// table to be indexed by, and `uniformShape` has already refused one.
			_rows: {},
			_check() {
				if (postEpoch !== epoch) {
					throw new Error(
						'this post handle was replaced by a later three.setPost() — that call replaces the '
						+ 'whole chain, and writing through the old handle would steer whatever is at its '
						+ 'index now. three.addPass() appends and leaves earlier handles alone'
					);
				}
			},
			_column(name) {
				throw new TypeError(
					`uniform '${name}' is not a table — a post pass has no instances to index one by`
				);
			},
			_set(name, v) {
				internals._check();
				const n = uniformValues(name, v);
				H.setPostUniform(name, +n[0], +(n[1] ?? 0), +(n[2] ?? 0), +(n[3] ?? 0), n.length, index);
				internals._values[name] = typeof v === 'number' ? +v : n.map(Number);
			},
			// What the samplers hold, and the write path for changing one. The
			// staleness check is the same one the uniforms make and for the same
			// reason: writing a texture through a replaced handle would put it in
			// the *new* shader's sampler of that name.
			_textureValues: { ...declared.values },
			_setTexture(name, texture) {
				internals._check();
				H.setPostTexture(name, texture === null ? NoTexture : texture._index(), index);
			},
		};
		for (const key of Object.keys(internals)) {
			Object.defineProperty(handle, key, { value: internals[key], enumerable: false });
		}
		handle.uniforms = uniformsProxy(handle, new Set(names), 'the post pass');
		handle.textures = texturesProxy(handle, new Set(declared.names), 'the post pass');
		return handle;
	}

	// Everything `setPost` and `addPass` do to a spec before it crosses, which is
	// all of it. Shared rather than written twice because the two verbs differ by
	// where the pass lands and by nothing else — and two copies of this would be
	// two chances for the two doors to disagree about what a post spec is.
	function postSpec(spec, wanted) {
		if (spec === null || spec === undefined || typeof spec !== 'object') {
			throw new TypeError(wanted);
		}
		const { fragment, uniforms = {}, textures = {} } = spec;
		if (typeof fragment !== 'string' || fragment.trim().length === 0) {
			throw new TypeError('a post pass needs a `fragment` body — see three.getApiDocs()');
		}
		if (uniforms === null || typeof uniforms !== 'object') {
			throw new TypeError('`uniforms` wants an object like { gain: 1, tint: [1, 0.5, 0.2] }');
		}
		const declared = textureLists(textures, 'this post pass\'s');

		// The enumeration happens here for `ShaderMaterial`'s reason: the
		// QuickJS shim exposes property *get* by name and nothing that lists
		// keys, so the names cross as a joined string. See js/bind_post.c3.
		const names = Object.keys(uniforms);
		const shapes = names.map(n => uniformShape(n, uniforms[n], false));

		return {
			fragment,
			names,
			uniforms,
			declared,
			args: [
				fragment,
				names.join(','),
				shapes.map(s => s[0]).join(','),
				declared.names.join(','),
				declared.ids.join(','),
			],
		};
	}

	// **After the compile, and not before it.** Putting a shader in the chain
	// zeroes that stage's push block — the new shader's uniforms are new fields at
	// new offsets, so carrying old bytes over would be writing one shader's values
	// into another's layout. So the values the spec gave are written afterwards,
	// exactly as a ShaderMaterial writes its own.
	function postFinish(parsed, index) {
		const handle = postHandle(parsed.fragment, parsed.names, parsed.declared, index);
		for (const name of parsed.names) handle._set(name, parsed.uniforms[name]);
		return handle;
	}

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
	class Mesh extends Object3D {
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

	// There is one scene at a time, and `new three.Scene()` is what empties it.
	//
	// Three.js lets you hold several and render whichever you like; here the
	// second one replaces the first, and every handle into the first goes stale.
	// That is a divergence, so it is made loud rather than silent: an epoch is
	// stamped on each Scene and checked on use, and the older one throws a
	// sentence saying what happened instead of quietly operating on the newer
	// scene's nodes.
	// The one live Scene, or null before the first `new three.Scene()`. There is
	// only ever one — a second replaces the first and the epoch check above says
	// so — which is what makes "the current scene" a thing a click can be
	// resolved against without the host being told which scene to use.
	let liveScene = null;

	class Scene extends Object3D {
		constructor() {
			super();
			liveScene = this;
			this._e = H.reset();
			const [i, g] = H.root();
			this._i = i;
			this._g = g;
			this._name = 'Scene';
		}

		_check() {
			if (this._e !== H.epoch()) {
				throw new Error('this Scene was replaced by a later new three.Scene() — there is one scene at a time');
			}
		}

		add(...objects) {
			this._check();
			return super.add(...objects);
		}

		remove(...objects) {
			this._check();
			return super.remove(...objects);
		}

		stats() {
			this._check();
			return H.stats();
		}

		// The colour every frame starts on.
		//
		// Three.js's name and Three.js's place — it is a property of the Scene
		// there too — but a narrower type: a colour, in any of the spellings
		// `mesh.color` takes, or `null` for the default. Three.js also accepts a
		// Texture or a CubeTexture here and this does not, because there is no
		// environment map anywhere in this project and accepting one to ignore it
		// would be the half-match `plan.md` §4 rules out.
		//
		// A sky that is a *gradient* is still geometry. What this removes is the
		// case that was costing a mesh for no reason: a daylight scene rendering
		// against the default near-black, which is not a sky anyone chose.
		//
		// It reads back as `[r, g, b]` rather than as whatever was assigned,
		// because the components are what the pixel gets — a hex value is
		// converted on the way in and there is no colour management to convert it
		// back through.
		get background() {
			this._check();
			return H.backgroundGet();
		}

		set background(v) {
			this._check();
			const c = v === null || v === undefined
				? DEFAULT_BACKGROUND
				: readColor(v, 'scene.background');
			H.backgroundSet(c[0], c[1], c[2]);
		}

		// Empty the scene and give back everything nothing else holds — the
		// level boundary.
		//
		// Not `new three.Scene()`, which also empties the scene but replaces it,
		// so every handle you were holding — including this Scene — starts
		// throwing. This keeps the scene; it is the same object afterwards, with
		// no children.
		//
		// The freeing is deliberately explicit and deliberately not a collector's
		// job: resident memory that depended on when the interpreter felt like
		// running a GC is the worst possible property for the one number a game
		// watches. Answers with what went, and three.stats() is the independent
		// confirmation.
		//
		// An asset you loaded but never added has no references either, so it
		// goes too. Load the next level after this call, not before it.
		unload() {
			this._check();
			for (const child of [...this.children]) this.remove(child);
			return H.unloadUnused();
		}

		// Write the scene to a `.glb`.
		//
		// The other direction of `three.load`, and the point at which "linked,
		// not duplicated" stops being an internal detail: a thousand walls
		// placed from one kit are a thousand nodes over one mesh in the file,
		// exactly as they are one draw call in the frame. Vertices are written
		// once per (asset, mesh) and referenced; images are written once per
		// unique image, deduplicated across every file they came from by the
		// same content hash the renderer already deduplicates them with.
		//
		// Under `--assets` the path is inside the game directory and cannot
		// climb out of it — the same rule `three.load` follows.
		//
		// Two things are deliberately not in the file:
		//
		// - **Helpers and hidden subtrees.** The export is what the frame
		//   shows; a `.glb` with the debug boxes baked in is a file nobody
		//   wants. `skipped` counts them.
		// - **ShaderMaterials.** A material here is a Slang pipeline and glTF
		//   describes surfaces, not programs. Those meshes are in the file with
		//   the base colour and texture their geometry carries, and `shaded`
		//   counts how many lost a custom shader.
		//
		// **Per-copy colour survives, and so does the draw call.** Sibling
		// copies of one shape are written as a single node carrying an array of
		// transforms — `EXT_mesh_gpu_instancing`, which is standard and which
		// any glTF reader can place — plus a `_COLOR_0` array beside them
		// holding what each copy's `mesh.color` was. A reader that does not
		// know `_COLOR_0` gets the copies in the material's own colour rather
		// than in the wrong place. `batches` counts the nodes written that way.
		//
		// A copy with no sibling drawing the same shape is left alone: it is
		// one draw call however it is written, so it keeps its name, its place
		// in the tree and a material of its own colour. Groups are never
		// collapsed either — what flattens is a run of leaves under one parent,
		// into one node beneath that same parent.
		//
		// **`{ flatten: true }` batches copies that are not siblings**, which is
		// the ones `asset.instantiate()` makes: an instantiated subtree arrives
		// wrapped in a group of its own, so no two of them share a parent and the
		// sibling rule never compares them. Untinted that costs nothing — the
		// geometry is shared across the whole scene either way — but a tint has
		// to travel per copy, so six colours become six materials and six draw
		// calls without it.
		//
		// It is off by default because it gives up the hierarchy: every drawing
		// node is taken in world space and written under one root, so the groups
		// and the names of the copies inside them are gone. Leave it off for a
		// file a person will open; turn it on for a file that is a payload.
		//
		// Answers with { path, meshes, entries, materials, images, nodes,
		// instances, batches, skipped, shaded, bytes }.
		export(path, options) {
			this._check();
			if (typeof path !== 'string' || path.length === 0) {
				throw new TypeError('scene.export(path) wants a path to write a .glb to');
			}
			let flatten = false;
			if (options !== undefined && options !== null) {
				if (typeof options !== 'object') {
					throw new TypeError('scene.export(path, options) wants an object for its options, like { flatten: true }');
				}
				if (options.flatten !== undefined) {
					if (typeof options.flatten !== 'boolean') {
						throw new TypeError('scene.export options.flatten is true or false');
					}
					flatten = options.flatten;
				}
			}
			return H.exportScene(path, flatten);
		}

		// -------------------------------------------------------------------
		// Picking
		//
		// Not Three.js's `Raycaster`, and named so. `intersectObjects` answers
		// with a sorted array of every intersection and takes the objects to
		// consider; this answers with the closest drawable hit in the whole
		// scene, or null. An array that never held more than one element would
		// be a fact about this implementation wearing Three.js's name — which
		// is the half-match `plan.md` §4 says is worse than a new name.

		// What a world-space ray hits. The direction need not be normalised;
		// `distance` comes back in world units either way, so hits on
		// differently scaled objects compare directly.
		raycast(origin, direction) {
			this._check();
			const o = readVector(origin, 'scene.raycast(origin, direction)');
			const d = readVector(direction, 'scene.raycast(origin, direction)');
			return this._intersection(H.raycast(o[0], o[1], o[2], d[0], d[1], d[2]));
		}

		// What is under a pixel of the rendered image — (0, 0) is its top-left
		// corner, the same corner the PNG starts at, and three.renderSize()
		// says how big it is. Invisible objects and anything under an invisible
		// parent are skipped: picking what cannot be seen is never what was
		// meant.
		pick(x, y) {
			this._check();
			if (!(Number.isFinite(+x) && Number.isFinite(+y))) {
				throw new TypeError('scene.pick(x, y) wants two pixel coordinates');
			}
			return this._intersection(H.pick(+x, +y));
		}

		// A host hit becomes the object the script is holding. The search is a
		// walk rather than a lookup table because a table would have to be kept
		// in step with every add, remove and re-parent, and a picked hit is one
		// per user gesture — the walk is not the expensive part of a raycast.
		//
		// `object` is null only for a node this scene did not build: `three
		// <file.glb>` opens one from the command line, and `name` is what
		// identifies it then.
		_intersection(raw) {
			if (raw === null) return null;
			const [i, g] = raw.node;
			let object = null;
			this.traverse(o => { if (object === null && o._i === i && o._g === g) object = o; });
			return {
				object,
				name: raw.name,
				distance: raw.distance,
				point: new Vector3(null, raw.point[0], raw.point[1], raw.point[2]),
				normal: new Vector3(null, raw.normal[0], raw.normal[1], raw.normal[2]),
			};
		}
	}

	// -----------------------------------------------------------------------
	// Assets

	// A loaded file. The handle is two numbers, not one: which slot the host
	// filed it in, and which occupant of that slot it is. Slots are reused after
	// an unload, so an index on its own could name a different file than the one
	// that was loaded — the generation is what makes a stale reference throw a
	// sentence instead of quietly placing somebody else's mesh.
	// What `asset.mesh(name)` answers with: the handle, plus the one question
	// worth asking about a piece before placing it.
	//
	// A plain object would do for the handle — `Mesh` only checks that `asset`,
	// `mesh` and `assetGeneration` are numbers, and a generated `Geometry`
	// satisfies the same check. This is a class so that `bounds` can be a getter
	// rather than a field: measuring is a crossing into the host, and paying for
	// it on every `asset.mesh(...)` when most callers only want to place the
	// piece would tax the common path to serve the rarer one.
	class MeshRef {
		constructor(asset, assetGeneration, mesh, name) {
			this.asset = asset;
			this.assetGeneration = assetGeneration;
			this.mesh = mesh;
			this.name = name;
		}

		get bounds() { return refBounds(this, `asset.mesh(${JSON.stringify(this.name)}).bounds`); }

		toJSON() { return { name: this.name, mesh: this.mesh }; }
		toString() { return `MeshRef(${this.name})`; }
	}

	class Asset {
		constructor([index, generation]) {
			this._a = index;
			this._g = generation;
			this.path = H.assetPath(index, generation);
			// In load order, which is the order `mesh(name)` resolves in and the
			// order the host's own `find_mesh` walks.
			this.meshes = H.meshNames(index, generation);
			// Names and durations are read out of the JSON chunk at load, so
			// this costs nothing and "does this character have a walk cycle" is
			// a question worth asking before deciding to place it.
			this.animations = H.assetClips(index, generation);
		}

		mesh(name) {
			const at = this.meshes.indexOf(name);
			if (at < 0) {
				const have = this.meshes.length ? this.meshes.join(', ') : '(none)';
				throw new Error(`no mesh named "${name}" in ${this.path} — it has: ${have}`);
			}
			return new MeshRef(this._a, this._g, at, name);
		}

		meshAt(i) {
			if (!(i >= 0 && i < this.meshes.length)) {
				throw new RangeError(`mesh index ${i} is outside 0..${this.meshes.length - 1}`);
			}
			return new MeshRef(this._a, this._g, i, this.meshes[i]);
		}

		// The file's node hierarchy as an Object3D tree — Three.js's
		// `gltf.scene`. A group, with the file's own nodes under it carrying the
		// transforms the file gave them.
		//
		// Nothing here is special: what comes back is ordinary Object3Ds and
		// Meshes that have not been added to anything yet, so a script can move
		// them, hide them, recolour them or pull one out and add it on its own,
		// and `scene.add()` materializes them by the same path as everything
		// else. That is the reason the host answers with a description instead
		// of building host nodes itself.
		//
		// Call it twice for two copies. They share the upload — the host counts
		// one reference per drawing node, so two trees over one asset is two
		// sets of transforms and nothing else.
		instantiate(name) {
			const rows = H.assetNodes(this._a, this._g);
			const root = new Object3D();
			root.name = name === undefined ? this.path.replace(/^.*[/\\]/, '') : String(name);
			// The root is what carries the animations: a clip drives the whole
			// subtree, so root.play('Walk') is the only sensible place to say it.
			root._clips = this.animations;
			root._asset = [this._a, this._g];

			const built = [];
			for (const [label, parent, mesh, px, py, pz, ex, ey, ez, sx, sy, sz, qx, qy, qz, qw, gltfNode, r, g, b, a] of rows) {
				const node = mesh < 0
					? new Object3D()
					: new Mesh({ asset: this._a, assetGeneration: this._g, mesh, name: label });
				if (label) node.name = label;
				node.position.set(px, py, pz);
				// The Euler triple is what `node.rotation` reads back as; the
				// quaternion beside it is what the host is actually given,
				// because the two are not the same rotation at gimbal lock.
				// Setting `rotation` clears `_q`, so this order matters.
				node.rotation.set(ex, ey, ez);
				node._q = [qx, qy, qz, qw];
				node.scale.set(sx, sy, sz);
				// Which glTF node this was, so `play` can tell the host what an
				// animation channel's target index became. -1 for the entries
				// the host synthesized, which no channel can name.
				node._gltfNode = gltfNode;
				// Only a copy an instanced node placed has anything but white
				// here, and only a Mesh has anywhere to put it — a group's row
				// carries the identity and setting it would define a channel on
				// an object that has none.
				if (mesh >= 0 && !(r === 1 && g === 1 && b === 1 && a === 1)) node.color = [r, g, b, a];
				// Parents always precede their children in the host's walk, so
				// `built[parent]` is there by the time it is asked for.
				(parent < 0 ? root : built[parent]).add(node);
				built.push(node);
			}
			return root;
		}

		toJSON() { return { path: this.path, meshes: this.meshes, animations: this.animations }; }
	}

	// -----------------------------------------------------------------------
	// Geometry
	//
	// The shapes Three.js has, with Three.js's constructor signatures, its
	// defaults and its orientations: a plane faces +Z, a cylinder's axis is Y, a
	// torus lies in the XY plane, a cone points up. `scene/primitive.c3` builds
	// them, and says there why the formulas are copied rather than re-derived —
	// the winding and the UV layout come along with the positions, and a face
	// wound the wrong way is a hole rather than a dark patch.
	//
	// ## A geometry *is* an asset reference
	//
	// `new three.BoxGeometry(1, 1, 1)` answers with something carrying `asset`
	// and `mesh`, which is exactly what `asset.mesh("wall_corner_02")` answers
	// with. `new three.Mesh(...)` takes either and cannot tell them apart, and
	// the thesis is intact either way: a script named a shape and got a handle,
	// never a vertex.
	//
	// ## The same numbers are the same asset
	//
	// A fresh geometry per mesh is the Three.js habit, and here it is free — the
	// host keys the built mesh by its parameters, so a thousand identical
	// `BoxGeometry`s are one upload and one instanced draw call.
	//
	// Two boxes of *different* sizes are two assets and two draw calls. That is
	// the one thing worth knowing before generating a hundred of them: a scene
	// of one box scaled a hundred ways is one draw call, and a scene of a
	// hundred BoxGeometries is a hundred. `mesh.scale` is the cheap axis.

	// Shared by every shape: what it is called, what it was asked for, and the
	// asset the host built or reused.
	class Geometry {
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
	function positiveSize(value, where, what) {
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

	class BoxGeometry extends Geometry {
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

	class SphereGeometry extends Geometry {
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

	class PlaneGeometry extends Geometry {
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

	class CylinderGeometry extends Geometry {
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
	class ConeGeometry extends Geometry {
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

	class TorusGeometry extends Geometry {
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
	// shaded with no uvs — a hull's faces meet at creases, and smoothing them
	// removes the only thing that makes it read as a cut stone.
	//
	// Handing the same points over twice is one asset and one draw call, as with
	// every other geometry. The key is bit-exact rather than rounded, though, so
	// two clouds built by two runs of Math.random() are two assets: build the
	// array once and reuse it if you want the copies instanced.
	class ConvexGeometry extends Geometry {
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
	class Box3Helper extends LineMesh {
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
	// to differ — a box in the wrong place, which is worse than no box. This is
	// `alignTo`'s rule and it is refused for `alignTo`'s reason.
	//
	// The usual spelling is therefore the Three.js one, because a piece is
	// usually a child of the scene:
	//
	//   scene.add(piece);
	//   scene.add(new three.BoxHelper(piece));
	//
	// and a nested piece takes `piece.parent.add(...)`.
	class BoxHelper extends Box3Helper {
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
	class AxesHelper extends Group {
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
	class GridHelper extends LineMesh {
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
	class WireframeHelper extends LineMesh {
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

	// -----------------------------------------------------------------------
	// The camera
	//
	// A turntable, not a free Object3D, and named so. Three.js's
	// `camera.position.set(...)` has no meaning here, so the properties that
	// would half-match it do not exist — `orbit()` and `frameAll()` are names
	// Three.js does not have, which is `plan.md` §4's rule for a divergence.

	// -------------------------------------------------------------------
	// The light
	//
	// One directional light and an ambient floor, which is the whole model the
	// shaders implement. Not `scene.add(new three.DirectionalLight(...))`: that
	// name would promise adding, removing, colouring and duplicating, and this
	// renderer can do none of them. `plan.md` §4's half-match rule — a name
	// Three.js does not have is a name nobody expects Three.js's behaviour from.
	//
	// `direction` hands back a live Vector3, so `three.light.direction.y = -1`
	// writes through the same way `mesh.position.y = 1` does. A detached copy
	// would be the trap the camera avoided by making yaw and pitch throw on
	// assignment — a property that reads back what you wrote and changes nothing.

	const light = {
		get direction() {
			const [x, y, z] = H.lightGet();
			const v = new Vector3(null, x, y, z);
			v._o = { _flush() { H.lightSet(v._x, v._y, v._z, H.lightGet()[3]); } };
			return v;
		},
		set direction(v) {
			const [x, y, z] = readVector(v, 'three.light.direction');
			H.lightSet(x, y, z, H.lightGet()[3]);
		},

		// 0 leaves a face turned away from the light black; 1 removes the
		// shading entirely and everything is its own flat colour.
		get ambient() { return H.lightGet()[3]; },
		set ambient(v) {
			const [x, y, z] = H.lightGet();
			H.lightSet(x, y, z, +v);
		},

		// Both at once, because setting them one at a time is two host crossings
		// and reads worse at a call site that always means one change.
		set(direction, ambient = H.lightGet()[3]) {
			const [x, y, z] = readVector(direction, 'three.light.set(direction, ambient)');
			H.lightSet(x, y, z, +ambient);
			return light;
		},
	};

	const camera = {
		get fov() { return H.cameraGet()[6]; },
		set fov(v) {
			const [tx, ty, tz, yaw, pitch, distance] = H.cameraGet();
			H.cameraSet(tx, ty, tz, yaw, pitch, distance, +v);
		},

		get yaw() { return H.cameraGet()[3]; },
		get pitch() { return H.cameraGet()[4]; },
		get distance() { return H.cameraGet()[5]; },

		// The three that `orbit()` writes, and the two that nothing writes, all
		// refuse assignment out loud.
		//
		// A getter with no setter is not silence-free: a script is not evaluated
		// in strict mode, so `camera.far = 500` would *do nothing at all* and
		// report nothing at all — and the whole reason near and far became
		// readable in M6 is that a plane nobody could see had already cost a
		// session. Throwing here is the same call the ShaderMaterial uniform
		// Proxy makes, for the same reason.
		set yaw(_) { throw new TypeError('the turntable is moved by three.camera.orbit(yaw, pitch, distance), not by assigning yaw'); },
		set pitch(_) { throw new TypeError('the turntable is moved by three.camera.orbit(yaw, pitch, distance), not by assigning pitch'); },
		set distance(_) { throw new TypeError('the turntable is moved by three.camera.orbit(yaw, pitch, distance), not by assigning distance'); },
		set near(_) { throw new TypeError('near is derived from the orbit distance and the scene bounds — move the camera, or three.camera.frameAll()'); },
		set far(_) { throw new TypeError('far is derived from the orbit distance and the scene bounds — move the camera, or three.camera.frameAll()'); },

		// Read-only, and both halves of that are deliberate.
		//
		// They are **derived** — from the orbit distance and from the scene's own
		// bounds, every time the camera moves — because a fixed near plane in
		// front of a kilometre-wide model spends the whole depth buffer on the
		// first few metres, and a fixed far plane behind a one-metre one throws
		// the rest of it away. Neither number is a taste setting; both are
		// functions of what is being looked at, so the camera computes them.
		//
		// They are **reported** because being derived does not make them
		// uninteresting. A sky that renders at one zoom level and not at another
		// is `camera.far` moving, and until M6 there was no way to see that
		// happening — only to render, guess, and get it wrong.
		get near() { return H.cameraGet()[7]; },
		get far() { return H.cameraGet()[8]; },

		// Live, like `mesh.position` and unlike `getWorldPosition()` — so
		// `three.camera.target.y = 2` raises the turntable's focus instead of
		// editing a copy nothing reads again. `lookAt` is what it flushes
		// through, so there is one path that moves the target and one place the
		// planes are re-derived.
		get target() {
			const [tx, ty, tz] = H.cameraGet();
			const v = new Vector3(null, tx, ty, tz);
			v._o = { _flush() { camera.lookAt(v.x, v.y, v.z); } };
			return v;
		},
		set target(v) { this.lookAt(v); },

		// Degrees for the angles, world units for the distance — the same units
		// the host camera keeps them in. Any argument may be left out.
		orbit(yaw, pitch, distance) {
			const c = H.cameraGet();
			H.cameraSet(
				c[0], c[1], c[2],
				yaw ?? c[3],
				pitch ?? c[4],
				distance ?? c[5],
				c[6],
			);
			return this;
		},

		lookAt(x, y, z) {
			const c = H.cameraGet();
			if (typeof x === 'object' && x !== null) ({ x, y, z } = x);
			H.cameraSet(+x, +y, +z, c[3], c[4], c[5], c[6]);
			return this;
		},

		// Aim at everything in the scene and back off far enough to see it. What
		// an agent that has just loaded an unfamiliar model wants, because the
		// right distance depends on how big the model is.
		frameAll() { H.frameAll(); return this; },

		toJSON() {
			const [x, y, z, yaw, pitch, distance, fov, near, far] = H.cameraGet();
			return { target: { x, y, z }, yaw, pitch, distance, fov, near, far };
		},
	};

	// -----------------------------------------------------------------------
	// The keyboard
	//
	// Not a Three.js API — Three.js has no input layer at all, and this is in
	// the `differences` list because of it. The key *names* are the browser's
	// (`KeyboardEvent.key`, lowercased), because those are the strings an agent
	// has memorized even though the object around them is new.
	//
	// `isDown` is meaningful whenever it is asked. `pressed`, `released` and
	// `text` describe the frame being drawn right now, so they only mean
	// something inside the animation callback — between frames they report
	// whatever the last frame happened to see, which is almost always nothing.

	const input = {
		isDown(key) { return H.inputDown(String(key)); },
		pressed(key) { return H.inputPressed(String(key)); },
		released(key) { return H.inputReleased(String(key)); },

		// -------------------------------------------------------------------
		// Pressing keys from a script
		//
		// A headless boot has no keyboard, so a scene whose whole subject is
		// input could not be exercised at all: `examples/village` binds seven
		// keys to a character, and the only way to test the walking and the
		// collision was for the scene to hand its internals to a global — a
		// scene leaking its own state in order to be testable.
		//
		// **A held key, not an event.** It stays down until released, exactly as
		// a finger does, so a walk is `press('w')`, sixty frames, `release('w')`
		// rather than sixty calls of which one may be forgotten. The edges come
		// out of the same difference a real key's do, so `pressed`, `released`
		// and every onKeyDown handler behave identically — there is one
		// keyboard, not two paths into it.
		//
		// It adds to the real keyboard rather than replacing it, so a scripted
		// demo works with someone still at the keys.
		press(key) { H.inputHold(String(key), true); },
		release(key) { H.inputHold(String(key), false); },

		// Let go of everything. What a test calls between cases so one does not
		// leak a held key into the next.
		releaseAll() { H.inputReleaseAll(); },

		// What was typed this frame, with modifier chords and the function-key
		// range already filtered out. This, and not the key map, is what a text
		// field wants: it has the keyboard layout applied and the shift key
		// already accounted for.
		get text() { return H.inputText(); },

		// Every name there is, in one place, and the same list the host
		// searches. Aliases are included: ctrl, cmd and esc.
		keys() { return H.keyNames(); },

		// Where the cursor is: { x, y, inside, down, clicked }, in the rendered
		// image's pixels — the same coordinates scene.pick(x, y) takes and the
		// same corner the PNG starts at, whatever size the window has been
		// dragged to. Everything is zero and `inside` is false when there is no
		// window.
		get pointer() { return H.pointer(); },

		// True for the one frame a click finished on. A press that travelled or
		// was held is a drag, and a drag belongs to the camera.
		get clicked() { return H.pointer().clicked; },
	};

	// The host raycasts in image pixels and answers with a node index; turning
	// that back into the object a script is holding is the Scene's job, and the
	// Scene that does it is the live one. With none — a model opened from the
	// command line, or nothing built yet — the hit still carries its name, which
	// is the only identity such a node has, and `object` is null.
	function asIntersection(raw) {
		if (raw === null) return null;
		if (liveScene !== null && liveScene._e === H.epoch()) return liveScene._intersection(raw);
		return {
			object: null,
			name: raw.name,
			distance: raw.distance,
			point: new Vector3(null, raw.point[0], raw.point[1], raw.point[2]),
			normal: new Vector3(null, raw.normal[0], raw.normal[1], raw.normal[2]),
		};
	}

	// -----------------------------------------------------------------------
	// The module

	const three = {
		Scene,
		Mesh,
		Group,
		Vector3,
		Asset,
		Texture,
		DataTexture,
		camera,
		light,

		// How long this script may run before the interrupt stops it, in
		// milliseconds. 5,000 by default, and raisable to ten minutes.
		//
		// **Raise it to simulate, not to build.** Five seconds is generous for a
		// script that assembles a scene and short for one that steps it: the
		// check that proved the village's character controller walked 30,000
		// frames against 120 colliders, and the first attempt at it was killed
		// by the default — so it had to be cut into pieces that fit the budget
		// rather than pieces that meant something.
		//
		// The ceiling stays because a limit a script can lift entirely is not a
		// limit, and the whole reason the interrupt exists is that a wedged loop
		// must be a pause rather than a hang. Asking for more is clamped, not
		// refused: a caller asking for an hour means "as long as possible", and
		// throwing would leave them on the default instead.
		//
		// Raising it takes effect on the run that raises it — a script does not
		// know it needs longer until it is already running.
		get budget() { return H.budgetGet(); },
		set budget(ms) { H.budgetSet(+ms); },

		// The materials. `Material` is exported for `instanceof`, not to be
		// constructed: it is the base both concrete kinds share and holds `side`
		// and `map`, which is what makes `mesh.material` one check rather than a
		// list that has to be edited when a third kind arrives.
		//
		// Reach for MeshLambertMaterial to put an image or a side on a shape — it
		// compiles nothing. Reach for ShaderMaterial when you want to write the
		// shading itself.
		Material,
		MeshLambertMaterial,
		ShaderMaterial,

		// `material.side`. Numbers rather than an enum object because that is
		// what Three.js exports and what a script written from memory of it will
		// compare against — `side: 2` means DoubleSide in both.
		FrontSide,
		BackSide,
		DoubleSide,

		// `material.blending`, and Three.js's numbers for the same reason. The
		// usual way to reach for one of these is `{ transparent: true }`, which
		// means NormalBlending; name a mode when what you want is the other one.
		// Three.js's Subtractive and Multiply are 3 and 4 there and are not here,
		// and their numbers are left free so they can arrive without renumbering
		// anything a script hardcoded.
		NoBlending,
		NormalBlending,
		AdditiveBlending,

		// Exported for `instanceof` and for building one by hand, which a script
		// wants when it is describing a volume the scene does not hold yet — a
		// plot to fill, a gap to check. Neither is constructed by the host.
		Box3,
		MeshRef,

		// The shapes. `Geometry` is exported for `instanceof`, not to be
		// constructed: there is no BufferGeometry and no attribute access, which
		// is the thesis rather than an omission — see scene/primitive.c3.
		// ConvexGeometry takes a cloud of points and is the widest input here;
		// it is still a description of a shape rather than the shape's triangles,
		// and scene/convex.c3 argues why that is the same rule and not an
		// exception to it.
		Geometry,
		BoxGeometry,
		SphereGeometry,
		PlaneGeometry,
		CylinderGeometry,
		ConeGeometry,
		TorusGeometry,
		ConvexGeometry,

		// The helpers. Ordinary meshes over line assets — they cost a draw call
		// each and nothing else, they are not pickable, and they draw over the
		// scene rather than inside it because a helper that could be hidden by
		// the wall a piece had sunk into would be no help at all.
		Box3Helper,
		BoxHelper,
		AxesHelper,
		GridHelper,
		WireframeHelper,

		// Synchronous, despite reading like Three.js's async loader: the file is
		// read and uploaded on this thread and there is nothing to yield to.
		// `await three.load(...)` still works — awaiting a plain value is a
		// no-op — so the Three.js-shaped line an agent writes is correct here.
		load(path) {
			if (typeof path !== 'string' || path.length === 0) {
				throw new TypeError('three.load(path) wants a path to a .glb or .gltf');
			}
			return new Asset(H.load(path));
		},

		// Decode a PNG or JPEG and upload it. Synchronous, for three.load's
		// reason, and under --assets the path is inside the game directory and
		// cannot climb out of it.
		//
		// The format is read from the file's first bytes rather than from its
		// extension, so a JPEG somebody named .png loads correctly instead of
		// being reported as corrupt.
		texture(path) {
			if (typeof path !== 'string' || path.length === 0) {
				throw new TypeError('three.texture(path) wants a path to a .png or .jpg');
			}
			return new Texture(H.texture(path), path);
		},

		// Draws one frame into the offscreen target. The PNG that `run_script`
		// returns is a render of the final state whether or not this was called,
		// so this is for the error rather than the pixels: a scene that cannot be
		// drawn says so here, at this line, instead of at the end of the script.
		render(scene, cam) {
			if (scene !== undefined) {
				if (!(scene instanceof Scene)) throw new TypeError('three.render(scene) wants the Scene');
				scene._check();
			}
			if (cam !== undefined && cam !== null && cam !== camera) {
				throw new TypeError('three.c3 has one camera — pass three.camera, or nothing');
			}
			H.render();
		},

		// The shaders that run over the finished frame.
		//
		// `three.setPost({ fragment, uniforms })` compiles a `float3 post(Post p)`
		// and makes it the chain every frame goes through — the window,
		// three.render() and every screenshot alike, because there is one
		// recording function behind all three and the branch is inside it.
		// `three.setPost(null)` clears it and puts the frame back on the path it
		// was on before.
		//
		// A verb rather than a class: the chain belongs to the renderer, so a
		// constructor would imply somewhere to put a second chain. What comes back
		// is a handle onto the live pass — `{ fragment, index, uniforms }` — with
		// the same live uniforms Proxy a ShaderMaterial has, so
		// `handle.uniforms.gain = 2` is a 4-byte write that takes effect on the
		// next frame with no compile.
		//
		// It compiles here, at this line, so a body that does not compile throws
		// where it was written and carries Slang's diagnostic with `post:<line>`
		// coordinates counting the agent's own lines. A failed set leaves the
		// previous chain running — it is the old shaders or the new one and never
		// neither.
		//
		// The chain is a property of the renderer and not of the scene, so it
		// survives new three.Scene() and outlives the script that set it. Nothing
		// clears it but three.setPost(null).
		setPost(spec) {
			if (spec === null || spec === undefined) {
				H.clearPost();
				// After the host call, so a handle is only invalidated by a call
				// that actually changed what is running.
				postEpoch++;
				return null;
			}
			const parsed = postSpec(
				spec,
				'three.setPost({ fragment, uniforms }) wants an options object, or null to clear the pass'
			);
			H.setPost(...parsed.args);
			// After the host call, for the same reason the null branch bumps after
			// it: a set that threw changed nothing, and handles from before it are
			// still pointing at what is still running.
			postEpoch++;
			return postFinish(parsed, 0);
		},

		// `three.addPass(spec)` — put another full-screen pass at the end of the
		// chain.
		//
		// The same spec `setPost` takes, and the same handle back. What differs is
		// where it lands and what it reads:
		//
		//     p.color   what the pass before this one wrote — the scene, for the
		//               first pass in the chain
		//     p.scene   the frame as the geometry left it, whatever has run since
		//
		// Those two are the chain's whole dependency model. A pass reads its
		// predecessor and it reads the original picture, and everything a
		// multi-pass effect actually wants is one of those two — bloom is
		// `blur(bright(scene)) + scene`, which is `scene` three passes later.
		//
		// Adding to an empty chain is exactly a setPost, which is what makes
		// addPass usable without one in front of it. **It does not invalidate
		// handles**: earlier passes keep their index and their shader, so a script
		// can hold every handle it made and keep writing uniforms through all of
		// them.
		//
		// There is no removePass. Reordering or dropping one pass out of the
		// middle would renumber the handles after it, and `three.setPost(spec)`
		// followed by the addPass calls you want is the same effect said in a way
		// that cannot leave a handle pointing at somebody else's shader.
		addPass(spec) {
			// No "or null" clause, because there is no such call: addPass appends,
			// and the verb that empties the chain is three.setPost(null).
			const parsed = postSpec(spec, 'three.addPass({ fragment, uniforms }) wants an options object');
			const index = H.addPass(...parsed.args);
			return postFinish(parsed, index);
		},

		stats() { return H.stats(); },

		// Free every asset no live mesh names, and every texture that goes with
		// it. scene.unload() is this plus emptying the scene, and is what a level
		// transition wants; this on its own is for the asset loaded and then
		// changed its mind about.
		//
		// Answers with { assets, textures, bytes } — how many asset slots went,
		// how many unique images went, and how many bytes of image that was.
		// Costs a full device idle when there is anything to free and nothing at
		// all when there is not, so once per level is right and once per frame is
		// merely wasteful.
		unloadUnused() { return H.unloadUnused(); },

		// Three.js's own name for this, on the renderer, and the only name for
		// it that is: `requestAnimationFrame` is the browser's, and Three.js has
		// no frame loop in core either.
		//
		// The callback runs on the host's loop, between the input and the draw,
		// and is given the milliseconds since the host started counting — the
		// same argument `WebGLRenderer.setAnimationLoop` passes. It must be
		// synchronous: it has one frame to finish in, and there is no later.
		setAnimationLoop(fn) {
			if (fn === null || fn === undefined) { H.setFrame(null); return; }
			if (typeof fn !== 'function') {
				throw new TypeError('three.setAnimationLoop(fn) wants a function, or null to stop');
			}
			// Caught here rather than at the first tick, because an async
			// callback fails in a way that reads as the loop not running at all:
			// it returns a promise immediately, does its work later, and the
			// frame it was meant to be part of is long gone.
			if (fn.constructor && fn.constructor.name === 'AsyncFunction') {
				throw new TypeError(
					'the animation callback must be synchronous — an async one returns before it '
					+ 'has done anything, and the frame does not wait. Do the awaiting in a run_script.'
				);
			}
			H.setFrame(fn);
		},

		// Every .glb and .gltf in the assets directory, described without being
		// loaded — mesh names and triangle counts, animation names, skin count
		// and bounds, read out of the JSON chunk with no buffer touched.
		//
		// Empty outside a `--assets` boot, where there is no directory to
		// describe. That is an answer rather than an error on purpose: a script
		// written for a game still runs under a plain `--mcp`, and finds
		// nothing, which is the truth.
		inventory() {
			return H.inventory();
		},

		// What `scene.pick(x, y)` counts in, and what the PNG comes back as.
		// It is the offscreen target's, never a window's (`plan.md` §1).
		renderSize() {
			const [width, height] = H.renderSize();
			return { width, height };
		},

		input,

		// Bind an action to a key. The handler is called once when the key goes
		// down (or up), from inside the frame, and is given the name it was
		// bound under — so one function can serve 'w', 'a', 's' and 'd'.
		//
		// One handler per key per edge: binding again replaces. null unbinds.
		// A held key does not repeat; polling three.input.isDown in the
		// animation callback is what continuous movement wants.
		onKeyDown(key, fn) { bindKey(key, true, fn); },
		onKeyUp(key, fn) { bindKey(key, false, fn); },

		// Click to pick. The handler is called once, from inside the frame,
		// with what is under the cursor — the same intersection scene.pick(x, y)
		// answers with, or null for a miss — and the pixel it happened at.
		//
		// A click is a press and a release that stayed in the same place: a drag
		// orbits the camera and is not one, which is why there is no
		// onMouseDown beside this.
		//
		// One handler, and binding again replaces it. null unbinds.
		onClick(fn) {
			if (fn === null || fn === undefined) { H.onClick(null); return; }
			if (typeof fn !== 'function') {
				throw new TypeError('three.onClick(fn) wants a function, or null to unbind');
			}
			if (fn.constructor && fn.constructor.name === 'AsyncFunction') {
				throw new TypeError(
					'a click handler must be synchronous — an async one returns before it has done '
					+ 'anything, and the frame does not wait. Do the awaiting in a run_script.'
				);
			}
			H.onClick((raw, x, y) => fn(asIntersection(raw), x, y));
		},

		// The physics world — one of them, stepped by the host at a fixed 60 Hz
		// whatever rate the frame runs at. See DOCS.classes.Physics.
		physics: {
			// Give an object a body. The description is `object.body` if it has
			// one, and `options` wins over it, so a scene can be described once
			// and tweaked at the call.
			add(object, options) {
				const target = liveObject(object, 'three.physics.add');
				const desc = Object.assign({}, object.body || {}, options || {});

				const shape = desc.shape === undefined ? 'box' : String(desc.shape);
				const mass = desc.mass === undefined ? 1 : Number(desc.mass);
				const friction = desc.friction === undefined ? 0.5 : Number(desc.friction);
				const restitution = desc.restitution === undefined ? 0.2 : Number(desc.restitution);

				for (const [name, value] of [['mass', mass], ['friction', friction], ['restitution', restitution]]) {
					if (!Number.isFinite(value)) {
						throw new TypeError(`body.${name} must be a finite number, not ${value}`);
					}
				}
				if (mass < 0) throw new RangeError(`body.mass cannot be negative — ${mass} is not a weight`);

				// One word out of four, decided here rather than by the host so
				// that `mass: 0` means the same thing it means in every other
				// engine: something that does not move.
				const kind = desc.trigger ? 'trigger'
					: desc.kinematic ? 'kinematic'
					: (desc.static || mass === 0) ? 'static'
					: 'dynamic';

				H.physicsAdd(target[0], target[1], kind, shape, mass, friction, restitution);
				object.body = { shape, mass, friction, restitution, kind };
				object._solverOwned = kind === 'dynamic';
				return object;
			},

			// Take the body away. False when it had none, so removing twice is
			// not an error.
			remove(object) {
				const target = liveObject(object, 'three.physics.remove');
				if (object.body) object.body = null;
				object._solverOwned = false;
				return H.physicsRemove(target[0], target[1]);
			},

			// [x, y, z], y-up. An array rather than a live Vector3 because it
			// is a world setting and not a transform: writing to a component of
			// something read back would look like it did something.
			get gravity() { return H.physicsGravityGet(); },
			set gravity(value) {
				const [x, y, z] = asTriple(value, 'three.physics.gravity');
				H.physicsGravitySet(x, y, z);
			},

			// How many bodies the world holds.
			get count() { return H.physicsCount(); },

			// ---------------------------------------------------------------
			// Steering a body
			//
			// Functions taking the object rather than properties on it, because
			// a velocity belongs to the body and an object may not have one —
			// `mesh.velocity` would be a property that exists on everything and
			// means something on almost nothing.
			//
			// **setVelocity assigns and applyImpulse adds**, which is the whole
			// distinction at a call site. A character sets its velocity every
			// frame from the keys that are down, because what it wants is a
			// speed. A jump, an explosion or a bat applies an impulse, because
			// what it wants is a change to whatever the speed already was.
			// Using an impulse where a velocity was meant gives something that
			// accelerates forever.

			// [lx, ly, lz, ax, ay, az] — linear in units per second, angular in
			// radians per second — or null when the object has no body.
			//
			// Null rather than a throw because this gets asked in a loop over
			// things that may or may not have bodies, and answering with both
			// velocities at once because a script that wants one usually wants
			// the other in the same breath.
			velocity(object) {
				const target = liveObject(object, 'three.physics.velocity');
				return H.physicsVelocityGet(target[0], target[1]);
			},

			// World units per second. Only a dynamic body can be given one: a
			// static body's inverse mass is zero and a kinematic body is driven
			// by the transform a script writes, so both throw and say which.
			setVelocity(object, value) {
				const target = liveObject(object, 'three.physics.setVelocity');
				const [x, y, z] = asTriple(value, 'three.physics.setVelocity');
				H.physicsLinearSet(target[0], target[1], x, y, z);
				return object;
			},

			// Radians per second about each world axis; the vector's length is
			// the rate.
			setAngularVelocity(object, value) {
				const target = liveObject(object, 'three.physics.setAngularVelocity');
				const [x, y, z] = asTriple(value, 'three.physics.setAngularVelocity');
				H.physicsAngularSet(target[0], target[1], x, y, z);
				return object;
			},

			// A push, in mass times velocity, so the same impulse moves a heavy
			// thing less. `at` is an offset from the body's centre in world
			// axes, not a world position: give one and the push also tumbles
			// the body, leave it out and it is a pure shove.
			applyImpulse(object, impulse, at) {
				const target = liveObject(object, 'three.physics.applyImpulse');
				const [x, y, z] = asTriple(impulse, 'three.physics.applyImpulse');
				const [px, py, pz] = at === undefined
					? [0, 0, 0]
					: asTriple(at, 'three.physics.applyImpulse(object, impulse, at)');
				H.physicsImpulse(target[0], target[1], x, y, z, px, py, pz);
				return object;
			},

			// A spin with no shove. Separate from an off-centre applyImpulse
			// because "make this rotate" should not require solving for an
			// offset and a force that happen to produce the spin you wanted.
			applyTorqueImpulse(object, impulse) {
				const target = liveObject(object, 'three.physics.applyTorqueImpulse');
				const [x, y, z] = asTriple(impulse, 'three.physics.applyTorqueImpulse');
				H.physicsTorqueImpulse(target[0], target[1], x, y, z);
				return object;
			},
		},

		// A trigger overlap started or ended:
		// { type: 'enter' | 'exit', trigger, other }.
		// One handler; binding again replaces, null unbinds, and it is stopped
		// for good if it throws — the same rules onClick follows.
		onTrigger(fn) {
			bindPhysicsHandler(fn, 'three.onTrigger', H.onTrigger, event => ({
				type: event.type,
				trigger: objectForHandle(event.trigger),
				other: objectForHandle(event.other),
			}));
		},

		// Two bodies touched or came apart:
		// { type: 'start' | 'end', a, b, normal, point }.
		// `normal` and `point` mean something on a start and are zero on an end
		// — there is no contact left to describe by then.
		onContact(fn) {
			bindPhysicsHandler(fn, 'three.onContact', H.onContact, event => ({
				type: event.type,
				a: objectForHandle(event.a),
				b: objectForHandle(event.b),
				normal: new Vector3(null, event.normal[0], event.normal[1], event.normal[2]),
				point: new Vector3(null, event.point[0], event.point[1], event.point[2]),
			}));
		},

		getApiDocs() { return DOCS; },
	};

	// The handle a host verb wants, having checked the object is one this scene
	// can still reach. A body needs a world position, so an object that has not
	// been added has nowhere to put one.
	function liveObject(object, where) {
		if (object === null || object === undefined || typeof object._i !== 'number') {
			throw new TypeError(`${where}(object) wants a scene object`);
		}
		if (object._i < 0) {
			throw new Error(
				`${where}: add the object to the scene first — a body is placed at a world position, `
				+ 'and an object that is not in the scene does not have one yet'
			);
		}
		return [object._i, object._g];
	}

	// A [x, y, z] handle from the host, back to the object a script is holding.
	// The same walk `_intersection` does and for the same reason: a lookup table
	// would have to be kept in step with every add, remove and re-parent.
	function objectForHandle(handle) {
		if (!handle) return null;
		if (liveScene === null || liveScene._e !== H.epoch()) return null;
		const [i, g] = handle;
		let found = null;
		liveScene.traverse(o => { if (found === null && o._i === i && o._g === g) found = o; });
		return found;
	}

	// A [u, v] pair out of an array or an {x, y}. The two-component sibling of
	// asTriple, for the texture-space properties: uvs are named u and v and a
	// caller who wrote {x, y} meant the same thing, so both are taken.
	function asPair(value, where) {
		const pair = Array.isArray(value) ? value
			: (value && typeof value === 'object')
				? [value.u ?? value.x, value.v ?? value.y]
				: (typeof value === 'number') ? [value, value]
				: null;
		if (pair === null || pair.length < 2 || pair.some(n => !Number.isFinite(Number(n)))) {
			throw new TypeError(`${where} wants [u, v], an {x, y}, or one number for both`);
		}
		return [Number(pair[0]), Number(pair[1])];
	}

	function asTriple(value, where) {
		const triple = Array.isArray(value) ? value
			: (value && typeof value === 'object') ? [value.x, value.y, value.z]
			: null;
		if (triple === null || triple.some(n => !Number.isFinite(Number(n)))) {
			throw new TypeError(`${where} wants [x, y, z] or a Vector3`);
		}
		return triple.map(Number);
	}

	// Shared by onTrigger and onContact, including the async refusal a key
	// handler and a click handler already make: a handler that returns before
	// it has done anything is not a handler, and the frame does not wait.
	function bindPhysicsHandler(fn, where, bind, shape) {
		if (fn === null || fn === undefined) { bind(null); return; }
		if (typeof fn !== 'function') {
			throw new TypeError(`${where}(fn) wants a function, or null to unbind`);
		}
		if (fn.constructor && fn.constructor.name === 'AsyncFunction') {
			throw new TypeError(
				`a ${where.replace('three.on', '').toLowerCase()} handler must be synchronous — an async one `
				+ 'returns before it has done anything, and the frame does not wait. '
				+ 'Do the awaiting in a run_script.'
			);
		}
		bind(event => fn(shape(event)));
	}

	// Shared by both, including the async refusal: a key handler runs inside a
	// frame for the same reason the animation callback does, and an async one
	// would return before it had done anything.
	function bindKey(key, down, fn) {
		if (fn === null || fn === undefined) { H.onKey(String(key), down, null); return; }
		if (typeof fn !== 'function') {
			throw new TypeError('three.onKeyDown(key, fn) wants a function, or null to unbind');
		}
		if (fn.constructor && fn.constructor.name === 'AsyncFunction') {
			throw new TypeError(
				'a key handler must be synchronous — an async one returns before it has done '
				+ 'anything, and the frame does not wait. Do the awaiting in a run_script.'
			);
		}
		H.onKey(String(key), down, fn);
	}

	// -----------------------------------------------------------------------
	// The docs
	//
	// `plan.md` §4: ship this from day one. The agent's one real disadvantage
	// against Three.js is that it has not memorized this API, and a
	// machine-readable dump of the surface is the cheapest possible mitigation.
	// It lives beside the code it describes so the two drift together or not
	// at all.

	const DOCS = {
		version: '0.1.0',
		summary:
			'A Three.js-shaped scene API over Vulkan. Every mesh placed with the same ' +
			'asset reference is one instanced draw call — there is no batching step to ' +
			'invoke and no way to write an unbatched scene.',
		differences: [
			'three.load(path) is synchronous; await works but is not needed.',
			'Everything placeable can be MEASURED, and you should measure rather than guess. asset.mesh(name).bounds and geometry.bounds are a Box3 in the piece\'s own space, read out of the glTF JSON so it costs no upload; object.boundingBox() is the world-space box of a subtree, from the host; object.boundsInParent() is the same box in the parent\'s frame and works before add(). A kit piece\'s origin is wherever its exporter left it, so a size table written by hand into a script is the thing that goes stale and sinks pieces into walls.',
			'object.align(axis, edge, at) moves an object until one face of its box sits at a coordinate — align(\'y\', \'min\', 0) stands a piece on the ground, align(\'z\', \'min\', wallZ) puts its back flush with a wall. object.alignTo(other, {axis, mine, theirs, offset}) says the same thing against a sibling. Both work in the PARENT\'s frame, because that is the frame a script writes positions in; alignTo refuses objects with different parents rather than being wrong by whatever the parents differ by. Set rotation and scale first — they are inputs to where the box is.',
			'There is DEBUG DRAW, and reaching for it is the cheap move: three.BoxHelper(object) boxes what an object actually occupies, three.Box3Helper(box) boxes a Box3 you worked out yourself, three.AxesHelper(size) shows where a pivot is and which way it faces, three.GridHelper(size, divisions) says where the ground is, and three.WireframeHelper(mesh) draws a mesh\'s own edges — which is how two faces 0.01 apart are found, because a z-fighting starburst is invisible in a solid render. They are ordinary meshes: a thousand of them are one draw call, helper.color is per copy and free, scene.remove(helper) works, and they are NOT pickable, so a click goes through the box onto the thing inside it.',
			'Helpers draw OVER everything — the line pipeline tests no depth, unlike Three.js\'s helpers. That is deliberate: the times you ask where something is are the times it is inside a wall, and a depth-tested helper would be hidden by exactly the geometry being asked about. The cost of being ordinary meshes is the other direction: a helper draws, so it is inside boundingBox(), inside the boundsInParent() of whatever it hangs from, and inside three.camera.frameAll(). Align first and add helpers after, or hang them from a Group of their own.',
			'A helper cannot be given a ShaderMaterial. A material is a pipeline and every pipeline you can build draws triangles, while a helper\'s indices are pairs — assigning one would read the pairs as triangles rather than fail, so it throws instead. helper.color is the knob a helper has.',
			'Geometry is BoxGeometry, SphereGeometry, PlaneGeometry, CylinderGeometry, ConeGeometry, TorusGeometry and ConvexGeometry, built for you with Three.js\'s signatures, defaults and orientations. There is no BufferGeometry, no attribute access and no way to read or write a vertex — that refusal is what makes every scene one instanced draw per unique shape.',
			'new three.ConvexGeometry(points) is the way to make a shape that is not one of the six parametric ones: hand over a cloud of points and get its convex hull. Rocks, crystals, gems, debris, the bound of a scan. It takes Vector3s, [x, y, z]s or a flat array of coordinates, needs at least 4 points, is capped at 65536, and is flat shaded with no uvs because a hull has hard creases and no natural unwrap. The points are a description the hull is computed from, not the mesh\'s vertices — most of them are discarded and none can be read back.',
			'Two geometries with the same numbers are ONE asset and one draw call, however many times you construct them. Two different sizes are two. Prefer mesh.scale over a new size when you want variety cheaply.',
			'new three.Mesh(geometry, material) takes either a generated shape or asset.mesh(name); material is optional, as in Three.js.',
			'mesh.color and mesh.variant are the ONLY two things copies sharing a geometry and a material may differ in without becoming separate draw calls. A thousand meshes in a thousand colours is one call; giving two of them different materials is two. There is no InstancedMesh because every mesh is already an instance.',
			'A ShaderMaterial uniform may be a table — { palette: [[1,0,0], [0,1,0]] } becomes float3 palette[2] and mesh.variant picks the row. That is how one material gives many meshes many looks. s.variant is clamped to the table, so an index past the end is the last row.',
			'A ShaderMaterial has a vertex stage as well as a fragment one: { vertex: `void displace(inout Vertex v) { v.position.y += sin(v.local.x * 3 + t) * 0.4; }` } moves geometry per vertex with no draw call, no upload and no geometry change — the mesh is still the same asset and a thousand copies of it are still one call. Vertex is the varyings: position (world), normal, uv, color and variant are read back after your body runs, and local (object space) and index (the vertex number) are inputs. The normal is not recomputed for you. Always pass `bounds` with a vertex body — the number of world units it can displace by — because culling tests the mesh\'s undisplaced box and geometry outside it is dropped while still on screen.',
			'A ShaderMaterial or a post pass may declare up to four samplers of its own: { textures: { noise_map: tex } } makes noise_map.Sample(uv) work in the body. You never write a binding number — the shader is generated with the bindings in it and the host resolves each name through the compiled module\'s reflection, so adding one at the front of the list renumbers nothing. material.map is separate and is still the base colour image. A sampler declared and left null reads 1x1 white rather than reading nothing, and both objects are live: mat.textures.noise_map = other swaps the image with no compile.',
			'Colours are linear rgb in 0..1 (hex is divided by 255, not de-gamma\'d): there is no colour management here, and half of one would be worse than none.',
			'There is one scene at a time. new three.Scene() empties it, and handles into the previous scene throw.',
			'Nothing is freed until you say so. scene.unload() empties the scene and gives back every asset and texture nothing else holds; three.unloadUnused() does the freeing without the emptying. Neither is a garbage collector — resident memory that depended on when the interpreter felt like collecting would be the worst possible property for the one number a game watches — and stats().assets is how you watch it work.',
			'An asset handle goes stale when the asset is unloaded, because the host reuses the slot. Placing one throws a sentence saying so — at the scene.add(), which is where the handle is used, not at the new three.Mesh(), which is still only a description. Loading the file again gives a fresh handle. This is the same rule object handles follow across new three.Scene().',
			'There is one camera, a turntable: three.camera.orbit(yaw, pitch, distance) and three.camera.frameAll(). camera.position does not exist.',
			'The near and far planes are derived, not set: from the orbit distance and from the scene\'s own bounds, every time the camera moves. Three.js makes them constructor arguments to PerspectiveCamera. Read them — three.camera.near and .far — when something has stopped being drawn, because geometry past far is absent rather than dim and is culled as well as clipped. Assigning either throws rather than being ignored.',
			'There is one light and it is not an Object3D: three.light.direction is a world-space surface-to-light vector and three.light.ambient is the floor an unlit face gets, 0 to 1. three.light.set(direction, ambient) does both. Not scene.add(new DirectionalLight(...)), because there is no second light, no colour per light and no shadow — the name is different so nothing reads as a promise the renderer cannot keep. The direction is not normalized, so it reads back as you wrote it, and a zero one throws rather than turning every shaded pixel into a NaN. Defaults to [0.35, 0.8, 0.45] with an ambient of 0.25, and a new Scene restores that.',
			'scene.background is a colour or null, never a Texture: [r,g,b], 0x87ceeb, or null for the default. There is no environment map and no scene.environment. A gradient sky is still geometry — what this removes is having to build one to escape the default near-black.',
			'Every colour you state is sRGB — the components a colour picker gives. mesh.color = 0xff8040 renders as 0xff8040 under a full light, scene.background = 0x2060a0 screenshots as 0x2060a0, and a texture\'s bytes come back out as the bytes that went in. The shading arithmetic in between is linear and the conversion is the renderer\'s job, so nothing in a script should ever apply a gamma of its own; a scene that pre-corrects its own textures will now be twice corrected.',
			'material.side is on the material and not on the mesh, because it is a property of the pipeline: two meshes sharing a geometry and a material are one draw call and would stop being one if they could disagree about it. three.BackSide is how a skydome is made visible from inside; scaling a sphere by -1 does not work, because a negative scale does not reverse a triangle\'s winding.',
			'An object is not in the scene until it is add()ed, and removing it makes it a detached description that can be added again.',
			'A Group is how several objects stay one object. Nothing else records that they belong together: siblings built by one loop and placed by the same arithmetic have no relationship the scene graph can see, so a later edit that moves one leaves the others where they were. Parent the pieces of a thing to a Group, place them relative to it once, and move the Group instead. It costs a node and no draw call.',
			'name is empty until a script sets it and getObjectByName answers null for a miss, both as in Three.js — so a node nobody named is reachable only through traverse, and a misspelled one is a null that throws somewhere else. Name whatever a later script will look for. asset.instantiate() trees need no help: the root takes the file name and every node under it keeps the name the file gave it.',
			'ShaderMaterial takes a fragment function, not a whole program: you write float3 shade(Surface s) and three.c3 supplies the vertex stage, the Surface and the uniform block. Uniforms are flat values, not Three.js\'s { value } wrappers.',
			'There is post-processing and it is a CHAIN, not an EffectComposer: three.setPost({ fragment }) runs a float3 post(Post p) over the finished frame, three.addPass({ fragment }) puts another after it, and three.setPost(null) stops all of them. There are no render targets to manage and no dependency declarations — a pass reads what the pass before it wrote as p.color and the frame as the geometry left it as p.scene, and those two are the whole model. The chain runs in linear float, so a pass may return values above 1 and the next one still sees them, which is what a bright pass followed by a blur needs; the encode to the display happens once, at the end, and is the engine\'s. It applies to the window, to render() and to screenshots alike, and it belongs to the renderer rather than to the scene, so it survives new three.Scene() and outlives the script that set it.',
			'A mesh with no material draws with the base colour and texture its glTF material carried.',
			'There is no Raycaster. scene.pick(x, y) takes pixels of the rendered image and scene.raycast(origin, direction) takes a world ray; both answer with the closest hit or null, not with an array.',
			'Each run_script call runs in its own function scope. Use globalThis to keep state between calls.',
			'three.setAnimationLoop(fn) runs fn once per frame, with the elapsed milliseconds, until three.setAnimationLoop(null). It is how a scene moves without an agent in the loop. The callback must be synchronous, is stopped for good if it throws or runs longer than 100ms in one frame, and what it logs comes back with the next run_script under an [animation loop] marker.',
			'A running animation loop makes render() and screenshot() no longer repeatable — the scene has moved between them. setAnimationLoop(null) stops the clock so a known state can be captured.',
			'There is a keyboard, which Three.js has no equivalent of at all: three.input.isDown(key) for held keys, three.input.pressed(key)/released(key) for this frame\'s edges, and three.onKeyDown(key, fn)/onKeyUp(key, fn) to bind an action. Key names are the browser\'s KeyboardEvent.key lowercased — three.input.keys() lists every one. It only reports anything while a window is open: --headless has no keyboard.',
			'A script can press keys itself: three.input.press(key), three.input.release(key) and three.input.releaseAll(). A pressed key stays down until released, exactly as a finger does, and goes through the same path a real one does — so isDown, pressed, released and every onKeyDown handler cannot tell the two apart. It adds to the real keyboard rather than replacing it. This is what makes an input-driven scene testable at all: a headless boot has no keyboard, so without it the only way to exercise a character was for the scene to hand its internals to a global.',
			'Keys are read once per frame, so three.input.pressed() and three.input.text mean something inside the animation callback and almost never outside one. isDown() is fine anywhere.',
			'There is a mouse, and it is one thing: three.onClick(fn) calls fn(hit, x, y) with what is under the cursor already picked. three.input.pointer is where the cursor is. There is no mouseDown and no drag events — the left button orbits the camera, and a press that travels or is held is a drag rather than a click.',
			'three.input.pointer and the click are in the rendered image\'s pixels, not the window\'s. The window shows the image stretched to fit it, so the two differ on a retina display and after any resize; scene.pick(x, y) and the PNG use the same pixels the click does, whatever size the window is.',
			'There is a physics world, which Three.js has no equivalent of at all: object.body = { shape, mass } describes a body and three.physics.add(object) gives the object one. It is XPBD with real contacts, friction, restitution, joints and triggers — not a demo. Y is down: three.physics.gravity is [0, -9.8, 0] and there is no axis to configure.',
			'A dynamic body is steered with three.physics.setVelocity(object, [x, y, z]) and pushed with three.physics.applyImpulse(object, [x, y, z]) — set a speed for a character, add an impulse for a jump or a hit. Between them a dynamic capsule with a velocity set each frame is a character controller: it walks and it collides, which no combination of the other verbs can do. Reading back is three.physics.velocity(object). Static and kinematic bodies refuse both by name, because for those the transform is the only thing that moves them.',
			'The solver owns a dynamic body\'s transform, and writing to it throws. That is the one place in this API where two writers are not resolved by last-writer-wins — a solver and a script writing the same transform every frame produce jitter rather than a compromise. Give the body kind \'kinematic\' to drive it from a script, or three.physics.remove(object) to take the body away. A body with mass 0 is static and is not owned, because it never moves.',
			'Physics runs at a fixed 60 Hz whatever rate frames arrive at, and the accumulator is the host\'s rather than the animation callback\'s — so a slow frame stutters instead of spending the script budget and stopping the callback for good. A frame that ran very long catches up at most five steps and drops the rest, which is the difference between a stutter and a spiral.',
			'A collider comes from the mesh, not from numbers you supply: \'box\' and \'sphere\' are its own bounds, \'capsule\' is the bounds about Y, and \'hull\' is the convex hull of its points — which is the same collision::quickhull that built a ConvexGeometry, so a convex rock\'s collider is exactly its own geometry rather than an approximation of it.',
			'The scene comes back OUT with scene.export(path, options) — a .glb with one mesh per unique geometry, so what the file says about sharing is what the frame says. Round-trips: export it, three.load it, and the draw-call count is the same, per-copy colours included. Sibling copies of one shape are written as a single node carrying an array of transforms (EXT_mesh_gpu_instancing, which any glTF reader can place) with a _COLOR_0 array beside them holding each copy\'s mesh.color; a reader that does not know _COLOR_0 gets them in the material\'s own colour rather than in the wrong place. A copy with no sibling drawing the same shape keeps its name and its own material instead, which costs no draw call, and groups are never collapsed. Two things are left out on purpose — helpers and hidden subtrees, because the export is what the frame shows, and ShaderMaterials, because a material here is a Slang pipeline and glTF describes surfaces rather than programs.',
			'Return a value from your script with `return`; it comes back as the `value` field.',
		],
		classes: {
			Scene: {
				construct: 'new three.Scene()',
				note: 'Empties the one host scene and becomes its root. It is an Object3D, so moving it moves everything.',
				methods: [
					'add(...objects)', 'remove(...objects)', 'traverse(fn)', 'getObjectByName(name)', 'stats()',
					'unload()', 'export(path)', 'pick(x, y)', 'raycast(origin, direction)', 'getWorldPosition()',
					'boundingBox()', 'boundsInParent()', 'align(axis, edge, at)', 'alignTo(other, opts)',
					'play(name, opts)', 'stop()', 'toJSON()',
				],
				properties: [
					'position', 'rotation', 'scale', 'visible', 'name', 'children', 'parent', 'animations',
					'background (the clear colour: [r,g,b], 0x87ceeb, or null for the default)',
					// three.light rather than a scene property: it is per renderer, like
					// three.camera, and listing it here would suggest two scenes could
					// disagree about it.
				],
			},
			Mesh: {
				construct: 'new three.Mesh(geometry, material)',
				note:
					'geometry is a generated shape (new three.BoxGeometry(1, 1, 1)) or a reference from '
					+ 'asset.mesh(name) / asset.meshAt(i). material is optional. N meshes sharing one geometry '
					+ 'AND one material is one draw call.',
				properties: [
					'position', 'rotation', 'scale', 'visible', 'name', 'geometry', 'material', 'children', 'parent',
					'color (per copy, free: [r,g,b], [r,g,b,a] or 0xff8800)',
					'variant (per copy, free: which row of the material\'s table)',
					'animations (empty unless this came from asset.instantiate())',
				],
				methods: [
					'add(...)', 'remove(...)', 'traverse(fn)', 'getObjectByName(name)', 'getWorldPosition()',
					'boundingBox()', 'boundsInParent()', 'align(axis, edge, at)', 'alignTo(other, opts)',
					'play(name, opts)', 'stop()', 'toJSON()',
				],
			},
			Material: {
				construct: 'not constructed — it is what MeshLambertMaterial and ShaderMaterial share',
				note:
					'The base both materials extend, exported for instanceof and for the two properties '
					+ 'they have in common. mesh.material accepts anything that is one. Assigning a '
					+ 'material to a helper throws whatever kind it is: a helper draws line pairs and '
					+ 'every pipeline you can build draws triangles.',
				properties: [
					'map (a three.texture, or null; wins over whatever image the mesh itself carries)',
					'side (three.FrontSide, three.BackSide or three.DoubleSide)',
					'transparent (whether it blends; derived from blending, and read-only — see blending)',
					'blending (three.NoBlending, three.NormalBlending or three.AdditiveBlending; decided at construction and NOT settable — this device bakes blending into the pipeline, so a change is a new material, which is one line)',
					'opacity (0 to 1, settable and free — it rides the push block. Does NOTHING unless the material was built transparent, because an opaque pipeline discards the alpha; that is the hardware\'s answer and Three.js behaves the same way)',
					'repeat ([u, v], or one number for both: how many times the map is laid across the surface. 1 by default; zero throws)',
					'offset ([u, v]: where the map starts, in whole repeats)',
					'alive (false once dispose() has been called on it)',
				],
				methods: ['dispose()', 'toJSON()'],
			},
			DataTexture: {
				construct: 'new three.DataTexture(data, width, height)',
				note:
					'Pixels a script built, uploaded as a texture. data is a Uint8Array (or a plain '
					+ 'Array, which is copied) of width*height*4 bytes in r, g, b, a order, row-major '
					+ 'from the bottom-left corner — uv (0,0) is bottom-left, as it is in Three.js. '
					+ 'RGBA8 only, and it is on the device when the constructor returns: there is no '
					+ 'needsUpdate here and nothing to schedule. Deduplicated against every other '
					+ 'texture by content, so generated pixels and the identical .png are one upload. '
					+ 'It is a Texture in every other way — map, dispose, width, height. Generating '
					+ '256x256 in JavaScript costs about 16ms before any of this, so build at load '
					+ 'rather than per frame. path is null; the side limit is 8192.',
				properties: ['width', 'height', 'path (null)', 'alive'],
				methods: ['read(into)', 'dispose()', 'toJSON()', 'toString()'],
			},
			Texture: {
				construct: 'three.texture(path)',
				note:
					'A PNG or JPEG on the device. Synchronous — it is uploaded by the time the call '
					+ 'returns, so width and height are readable immediately and there is no onLoad. '
					+ 'The format is read from the file\'s first bytes, not its extension. Images are '
					+ 'deduplicated by content: two paths holding the same picture, or a .png and the '
					+ 'identical image inside a .glb, are one upload — each call still answers with its '
					+ 'own handle. Under --assets the path is inside the game directory and cannot climb '
					+ 'out of it. Put it on something with new three.MeshLambertMaterial({ map }). '
					+ '16-bit PNGs are refused by name; save as 8-bit. read() copies the pixels back '
					+ 'off the device.',
				properties: ['width', 'height', 'path', 'alive'],
				methods: ['read(into)', 'dispose()', 'toJSON()', 'toString()'],
			},
			MeshLambertMaterial: {
				construct: 'new three.MeshLambertMaterial({ map, side, transparent, blending, opacity })',
				note:
					'The built-in shader with an image on it — the material to reach for when what you '
					+ 'want is a picture on a shape. It compiles nothing and cannot fail with a shader '
					+ 'diagnostic. Lambert is what it actually computes: one directional light and an '
					+ 'ambient floor, no specular and no environment. It has no color, because mesh.color '
					+ 'is the per-copy channel and multiplies into the sampled texel — so one material '
					+ 'tints a thousand copies differently and is still one draw call. With no map it is '
					+ 'the cheapest way to ask for a side, which is what a skydome needs.',
				properties: [
					'map (a three.texture, or null; settable)',
					'side (three.FrontSide, three.BackSide or three.DoubleSide; settable)',
					'transparent (whether it blends; derived from blending, and read-only — see blending)',
					'blending (three.NoBlending, three.NormalBlending or three.AdditiveBlending; decided at construction and NOT settable — this device bakes blending into the pipeline, so a change is a new material, which is one line)',
					'opacity (0 to 1, settable and free — it rides the push block. Does NOTHING unless the material was built transparent, because an opaque pipeline discards the alpha; that is the hardware\'s answer and Three.js behaves the same way)',
					'repeat ([u, v], or one number for both: how many times the map is laid across the surface. 1 by default; zero throws)',
					'offset ([u, v]: where the map starts, in whole repeats)',
					'alive (false once dispose() has been called on it)',
				],
				methods: ['dispose()', 'toJSON()'],
			},
			ShaderMaterial: {
				construct: "new three.ShaderMaterial({ fragment, vertex, uniforms, textures, bounds, side, transparent, blending, opacity })",
				note:
					'fragment is a Slang function `float3 shade(Surface s)` returning linear rgb. '
					+ 'Surface has albedo, normal, uv, position, color (this copy\'s own, already in albedo) '
					+ 'and variant (its row of the table, clamped). Each uniform is readable in the body by '
					+ 'its own name; a uniform written as an array of arrays is a table column, read as '
					+ 'name[s.variant]. textures is the same idea for images: { noise_map: tex } declares a '
					+ 'Sampler2D called noise_map that the body samples by that name — noise_map.Sample(uv) — '
					+ 'and up to four of them. You never write a binding number: the shader is generated with '
					+ 'the bindings in it and the host resolves each name back through the compiled module\'s '
					+ 'own reflection. Sample with any uv you like, which is the point — s.uv + float2(t, 0) '
					+ 'scrolls, s.uv * 4 tiles, float2(k, 0.5) reads a gradient as a lookup table. A sampler '
					+ 'left null, or one you never fill, reads as 1x1 opaque white rather than as nothing. '
					+ 'Compiles on construction, so a bad shader throws here, carrying the '
					+ 'Slang diagnostic with the line number you wrote. Needs a GPU device. '
					+ 'shade() returns rgb and never alpha: how much of the surface shows is the '
					+ 'material\'s opacity times this copy\'s mesh.color alpha, so a body cannot make '
					+ 'geometry invisible by accident and a script can, deliberately. discard works in a '
					+ 'body and is how a dissolve or a cutout is done, since the alpha is not yours to return. '
					+ 'vertex is the other half: a Slang function `void displace(inout Vertex v)` that runs '
					+ 'per vertex, before anything is projected. Vertex IS the varyings — write v.position '
					+ '(world space, after the mesh\'s own transform) to move the vertex, and v.normal, v.uv, '
					+ 'v.color and v.variant to change what the fragment stage receives; v.local (object '
					+ 'space, before the transform) and v.index (the vertex number, a per-vertex seed) are '
					+ 'inputs only. Waves, flags, breathing, jitter, explosions, a mesh that inflates on a '
					+ 'hit — all of them are one line here and none of them costs a draw call, because the '
					+ 'geometry never changes. The normal is NOT recomputed from what you do to the position: '
					+ 'write v.normal yourself if you moved the surface enough for the lighting to care. '
					+ 'A sampler reads with SampleLevel(uv, 0) in a vertex body, not Sample — there are no '
					+ 'derivatives to pick a mip with. Omitting fragment is allowed once vertex is given: it '
					+ 'defaults to the built-in lit look. '
					+ 'bounds is what a vertex body owes the renderer: how far, in world units, it can move '
					+ 'a vertex. Culling tests a mesh\'s own bounds, so a body that pushes geometry outside '
					+ 'them draws something the frustum was never told about — and the symptom is geometry '
					+ 'vanishing at the edge of the screen and coming back when the camera turns, which reads '
					+ 'as a renderer bug. Set it to the largest displacement your body can produce; too big '
					+ 'costs a draw call that could have been skipped, too small drops geometry you can see.',
				properties: [
					'uniforms (live: mat.uniforms.tint = [1, 0, 0], or mat.uniforms.palette[2] = [1, 0, 0])',
					'textures (live: mat.textures.noise_map = otherTexture, or null to put white back. Only the names given at construction exist; assigning any other throws)',
					'fragment',
					'vertex (the displace body, or an empty string; read-only, like fragment — a new body is a new material)',
					'bounds (how far the vertex body moves a vertex, world units; read-only, and what the frustum test is widened by)',
					'map (a three.texture, or null; sampled as Surface.albedo before your shade() runs)',
					'side (three.FrontSide, three.BackSide or three.DoubleSide; settable, and cheap after the first time each side is asked for)',
					'transparent (whether it blends; derived from blending, and read-only — see blending)',
					'blending (three.NoBlending, three.NormalBlending or three.AdditiveBlending; decided at construction and NOT settable — this device bakes blending into the pipeline, so a change is a new material, which is one line)',
					'opacity (0 to 1, settable and free — it rides the push block. Does NOTHING unless the material was built transparent, because an opaque pipeline discards the alpha; that is the hardware\'s answer and Three.js behaves the same way)',
					'repeat ([u, v], or one number for both: how many times the map is laid across the surface. 1 by default; zero throws)',
					'offset ([u, v]: where the map starts, in whole repeats)',
					'alive (false once dispose() has been called on it)',
				],
				methods: ['dispose()', 'toJSON()'],
			},
			Group: {
				construct: 'new three.Group(), or asset.instantiate()',
				note:
					'Transforms its children and draws nothing itself, which makes it the way to keep several '
					+ 'objects one object: parent the pieces, place them relative to the Group once, and afterwards '
					+ 'there is one transform to move rather than a convention to remember. '
					+ 'asset.instantiate() answers with one '
					+ 'of these carrying the file\'s own node hierarchy, and that one is what animations, '
					+ 'play(name, {loop, speed}) and stop() work on — a glTF clip drives a whole subtree, so '
					+ 'its root is where it is played. On a hand-built Group animations is empty and play() '
					+ 'throws saying which door to use. There is no AnimationMixer: one clip at a time, no '
					+ 'crossfade.',
				methods: [
					'add(...)', 'remove(...)', 'traverse(fn)', 'getObjectByName(name)', 'getWorldPosition()',
					'boundingBox()', 'boundsInParent()', 'align(axis, edge, at)', 'alignTo(other, opts)',
					'play(name, opts)', 'stop()', 'toJSON()',
				],
				properties: [
					'position', 'rotation', 'scale', 'visible', 'name', 'children', 'parent',
					'animations (clip names, from asset.instantiate())',
				],
			},
			Box3: {
				construct: 'new three.Box3(minX, minY, minZ, maxX, maxY, maxZ)',
				note:
					'An axis-aligned box, and the answer to "how big is this actually". A kit piece\'s origin '
					+ 'is wherever whoever exported it left it, so nothing about a transform says where the '
					+ 'piece\'s faces are — which is what "put this window on that wall" is really asking. '
					+ 'size and center are derived from min/max rather than stored. '
					+ 'edge(axis, which) is one face\'s coordinate, and is what align() is written in terms of.',
				properties: ['min', 'max', 'size', 'center'],
				methods: ['edge(axis, \'min\' | \'center\' | \'max\')', 'union(other)', 'clone()', 'toJSON()', 'toString()'],
			},
			MeshRef: {
				construct: 'not constructible — asset.mesh(name) and asset.meshAt(i) answer with these',
				note:
					'One piece of a loaded file: the handle new three.Mesh() wants, plus bounds. Reading bounds '
					+ 'costs no upload — the box comes out of the glTF JSON at load, so asking how big two '
					+ 'hundred kit pieces are before placing twelve of them still uploads twelve. It is not '
					+ 'cached: a reference that outlives its asset throws rather than answering with the size '
					+ 'the mesh used to be.',
				properties: ['asset', 'assetGeneration', 'mesh', 'name', 'bounds (a Box3 in the mesh\'s own space)'],
				methods: ['toJSON()', 'toString()'],
			},
			Vector3: {
				construct: 'new three.Vector3(null, x, y, z)',
				note: 'position/rotation/scale are live Vector3s: writing x, y, z or calling set() moves the object.',
				methods: [
					'set(x,y,z)', 'copy(v)', 'add(v)', 'sub(v)', 'multiplyScalar(s)', 'length()', 'clone()',
					'toArray()', 'toJSON()', 'toString()',
				],
			},
			Asset: {
				construct: 'three.load(path)',
				properties: ['path', 'meshes (names, in load order)', 'animations (clip names)'],
				methods: ['mesh(name)', 'meshAt(index)', 'instantiate(name?)', 'toJSON()'],
				note:
					'instantiate() is Three.js\'s gltf.scene: the file\'s own node hierarchy as Object3Ds, '
					+ 'with the transforms the file gave them. Use it for anything whose pieces are '
					+ 'positioned by nodes rather than baked into the vertices — a rig, a prop with parts, '
					+ 'a level laid out in Blender. asset.mesh(name) is the other door and is what you want '
					+ 'when you are placing pieces yourself. Instantiating twice gives two independent trees '
					+ 'over one upload.',
			},
			Geometry: {
				construct: 'not constructible — use one of the seven shapes below',
				note:
					'What every shape is: a handle three.c3 built, carrying the numbers you asked for. Hand it '
					+ 'to new three.Mesh(). Constructing the same shape twice answers with the same asset, so a '
					+ 'geometry per mesh costs nothing and a thousand identical ones are one draw call; two '
					+ 'different sizes are two. There is no BufferGeometry and no attribute access — a script '
					+ 'describes shapes, never vertices, and ConvexGeometry\'s point cloud is a description too. '
					+ 'Sizes are world units and must be positive, segment counts '
					+ 'are capped at 512, Y is up, and every shape is centred on its own origin.',
				properties: [
					'type', 'name', 'parameters (what you asked for, defaults filled in)', 'asset', 'mesh',
					'bounds (a Box3 in the shape\'s own space — what it IS, which is not always what it was asked for)',
				],
				methods: ['toJSON()', 'toString()'],
			},
			BoxGeometry: {
				construct:
					'new three.BoxGeometry(width = 1, height = 1, depth = 1, widthSegments = 1, heightSegments = 1, depthSegments = 1)',
				note: 'A box centred on the origin. The segment counts subdivide it and change nothing about its size.',
				properties: ['bounds'],
				methods: ['toJSON()', 'toString()'],
			},
			SphereGeometry: {
				construct: 'new three.SphereGeometry(radius = 1, widthSegments = 32, heightSegments = 16)',
				note: 'A UV sphere with its poles on the Y axis.',
				properties: ['bounds'],
				methods: ['toJSON()', 'toString()'],
			},
			PlaneGeometry: {
				construct: 'new three.PlaneGeometry(width = 1, height = 1, widthSegments = 1, heightSegments = 1)',
				note:
					'A one-sided rectangle in the XY plane, facing +Z — Three.js\'s orientation, which is '
					+ 'vertical. A floor is this with rotation.x = -Math.PI / 2. From behind it is invisible, '
					+ 'because back faces are culled.',
				properties: ['bounds'],
				methods: ['toJSON()', 'toString()'],
			},
			CylinderGeometry: {
				construct:
					'new three.CylinderGeometry(radiusTop = 1, radiusBottom = 1, height = 1, radialSegments = 32, heightSegments = 1, openEnded = false)',
				note: 'A cylinder or a truncated cone about the Y axis. Either radius may be 0, but not both.',
				properties: ['bounds'],
				methods: ['toJSON()', 'toString()'],
			},
			ConeGeometry: {
				construct:
					'new three.ConeGeometry(radius = 1, height = 1, radialSegments = 32, heightSegments = 1, openEnded = false)',
				note:
					'A cone about the Y axis with its point up. The same triangles as '
					+ 'CylinderGeometry(0, radius, height) — and the same asset, so the two spellings share a draw call.',
				properties: ['bounds'],
				methods: ['toJSON()', 'toString()'],
			},
			TorusGeometry: {
				construct: 'new three.TorusGeometry(radius = 1, tube = 0.4, radialSegments = 12, tubularSegments = 48)',
				note:
					'A ring in the XY plane. radius is measured to the centre of the tube, so the shape is '
					+ '2 * (radius + tube) across and 2 * tube thick.',
				properties: ['bounds'],
				methods: ['toJSON()', 'toString()'],
			},
			ConvexGeometry: {
				construct: 'new three.ConvexGeometry(points)',
				note:
					'The convex hull of a cloud of points, and the way to make a shape that is not one of the '
					+ 'six parametric ones — a rock, a crystal, a gem, a chunk of debris, the bound of a scan. '
					+ 'points is an array of Vector3s, of [x, y, z] or of {x, y, z}, or a flat array or '
					+ 'Float32Array of coordinates; at least 4 points, at most 65536. The hull is flat shaded '
					+ 'and carries no uvs: its faces meet at hard creases, and there is no unwrap of an '
					+ 'arbitrary hull that does not seam. The points describe the shape, they are not its '
					+ 'vertices — most are discarded and none can be read back. parameters.points is the count '
					+ 'you handed over. Two identical arrays are one asset; two runs of Math.random() are two, '
					+ 'because the key is bit-exact.',
				properties: ['bounds'],
				methods: ['toJSON()', 'toString()'],
			},
			Box3Helper: {
				construct: 'new three.Box3Helper(box, color = 0xffff00)',
				note:
					'A wire box drawn exactly where a three.Box3 says. The helper to reach for when the box '
					+ 'came from somewhere that is not one object — a plot to fill, a gap to check, the union '
					+ 'of two things. `box` is settable and the helper follows it. It is read in the frame of '
					+ 'whatever the helper is added to, so a box from boundsInParent() belongs under the same '
					+ 'parent and a box from boundingBox() belongs under the scene. Draws over everything: the '
					+ 'line pipeline tests no depth, because the times you ask where something is are the '
					+ 'times it is inside a wall.',
				properties: [
					'box (settable — the helper moves and rescales to it)',
					'position', 'rotation', 'scale', 'visible', 'name', 'geometry', 'children', 'parent',
					'color (per copy, free: [r,g,b] or 0xff8800)',
					'material (always null, and assigning throws — a helper draws with the line material)',
					'variant (meaningless here: the line material has no table)',
					'animations (always empty)',
				],
				methods: [
					'add(...)', 'remove(...)', 'traverse(fn)', 'getObjectByName(name)', 'getWorldPosition()',
					'boundingBox()', 'boundsInParent()', 'align(axis, edge, at)', 'alignTo(other, opts)',
					'play(name, opts)', 'stop()', 'toJSON()',
				],
			},
			BoxHelper: {
				construct: 'new three.BoxHelper(object, color = 0xffff00)',
				note:
					'The box of an object and everything under it — "how big is that actually, and where '
					+ 'does it end". It must hang from the SAME PARENT as the object it measures, and is '
					+ 'refused anywhere else: the box is measured in that frame, so a helper parented '
					+ 'elsewhere would be drawn wherever the two frames differ, which is a box in the wrong '
					+ 'place rather than no box. The usual spelling is therefore the Three.js one — '
					+ 'scene.add(piece); scene.add(new three.BoxHelper(piece)) — and a nested piece takes '
					+ 'piece.parent.add(...). Nothing watches the object, so call update() after moving it.',
				properties: [
					'object (what it measures, read-only)',
					'box (the box it is currently drawn on)',
					'position', 'rotation', 'scale', 'visible', 'name', 'geometry', 'children', 'parent',
					'color (per copy, free)',
					'material (always null, and assigning throws)',
					'variant (meaningless here)',
					'animations (always empty)',
				],
				methods: [
					'update()', 'add(...)', 'remove(...)', 'traverse(fn)', 'getObjectByName(name)',
					'getWorldPosition()', 'boundingBox()', 'boundsInParent()', 'align(axis, edge, at)',
					'alignTo(other, opts)', 'play(name, opts)', 'stop()', 'toJSON()',
				],
			},
			AxesHelper: {
				construct: 'new three.AxesHelper(size = 1)',
				note:
					'Red +X, green +Y, blue +Z from the origin — where a pivot is and which way it faces, '
					+ 'which is the question a kit piece whose origin is in an unexpected corner makes '
					+ 'somebody ask. Parent it to an object to see THAT object\'s pivot. It is a Group of '
					+ 'three meshes over one segment asset, so a hundred of them are still one draw call. '
					+ 'Remember that a helper parented to a piece is inside that piece\'s box: align first, '
					+ 'add the axes after.',
				properties: [
					'size (settable — rescales the three arms, builds nothing)',
					'position', 'rotation', 'scale', 'visible', 'name', 'children', 'parent',
					'animations (always empty)',
				],
				methods: [
					'add(...)', 'remove(...)', 'traverse(fn)', 'getObjectByName(name)', 'getWorldPosition()',
					'boundingBox()', 'boundsInParent()', 'align(axis, edge, at)', 'alignTo(other, opts)',
					'play(name, opts)', 'stop()', 'toJSON()',
				],
			},
			GridHelper: {
				construct: 'new three.GridHelper(size = 10, divisions = 10, color = 0x888888)',
				note:
					'A ruled square in the XZ plane, centred on the origin: where the ground is and how big '
					+ 'a metre looks. ONE colour, not Three.js\'s two — the darker centre line would be a '
					+ 'second mesh here for a distinction nothing has needed. Keyed on the divisions alone, '
					+ 'so GridHelper(100, 10) and GridHelper(40, 10) are one asset at two scales and one '
					+ 'draw call. There is no `size` to read back because the size IS the scale: grid.scale.x, '
					+ 'and it is live. Divisions are capped at 256.',
				properties: [
					'divisions (read-only — a different count is a different mesh)',
					'position', 'rotation', 'scale', 'visible', 'name', 'geometry', 'children', 'parent',
					'color (per copy, free)',
					'material (always null, and assigning throws)',
					'variant (meaningless here)',
					'animations (always empty)',
				],
				methods: [
					'add(...)', 'remove(...)', 'traverse(fn)', 'getObjectByName(name)', 'getWorldPosition()',
					'boundingBox()', 'boundsInParent()', 'align(axis, edge, at)', 'alignTo(other, opts)',
					'play(name, opts)', 'stop()', 'toJSON()',
				],
			},
			WireframeHelper: {
				construct: 'new three.WireframeHelper(meshOrGeometry, color = 0xffffff)',
				note:
					'A mesh\'s own triangles as the edges between them — the tool for two faces 0.01 apart '
					+ 'z-fighting into a starburst, which is invisible in a solid render and obvious the '
					+ 'moment the edges are drawn. Takes a Mesh that is already in the scene, or the '
					+ 'geometry / asset.mesh(name) it draws. THE MESH HAS TO BE ON THE DEVICE: a generated '
					+ 'shape is uploaded when it is constructed and works straight away, but a mesh out of a '
					+ 'file reaches the device when something drawing it is added to a scene, and until then '
					+ 'there are no triangles to read — you get a sentence saying so, not an empty helper. '
					+ 'Add it as a CHILD of the mesh — piece.add(new three.WireframeHelper(piece)) — because '
					+ 'the edges are in the mesh\'s own space and a child at the identity transform overlays '
					+ 'it to the pixel. Each shared edge is drawn once. A Group has no triangles of its own: '
					+ 'traverse it and make one per Mesh.',
				properties: [
					'of (the name of the mesh these edges belong to)',
					'position', 'rotation', 'scale', 'visible', 'name', 'geometry', 'children', 'parent',
					'color (per copy, free)',
					'material (always null, and assigning throws)',
					'variant (meaningless here)',
					'animations (always empty)',
				],
				methods: [
					'add(...)', 'remove(...)', 'traverse(fn)', 'getObjectByName(name)', 'getWorldPosition()',
					'boundingBox()', 'boundsInParent()', 'align(axis, edge, at)', 'alignTo(other, opts)',
					'play(name, opts)', 'stop()', 'toJSON()',
				],
			},
		},
		functions: {
			'three.load(path)':
				'Read a .glb or .gltf. Nothing is uploaded: this parses the JSON and answers with an Asset '
				+ 'that knows its meshes, their bounds and the file\'s node tree. A mesh reaches the GPU when '
				+ 'a Mesh drawing it is added to a scene, so loading a 200-piece kit to place twelve costs '
				+ 'twelve. Under --assets the path is relative to the assets directory and cannot climb out '
				+ 'of it, so three.inventory() paths go straight in; otherwise it is relative to where three '
				+ 'was started. Loading the same path twice returns the same asset — unless it was unloaded '
				+ 'in between, which gives a fresh one and makes the old handle throw. '
				+ 'asset.instantiate() for the file\'s own hierarchy, asset.mesh(name) for one piece of it.',
			'three.render(scene, camera)': 'Draw one frame. camera is optional and must be three.camera.',
			'three.stats()':
				'The numbers below, for the whole scene, with culling off. gpuMs is the one exception: it is '
				+ 'not a fact about the scene but a measurement of the last frame drawn, so it moves when '
				+ 'nothing about the scene has.',
			'three.unloadUnused()':
				'Free every asset no live mesh names, every mesh of a still-used file that nothing draws, and '
				+ 'every texture that goes with them. Answers with { assets, meshes, textures, bytes } — '
				+ 'meshes counts the pieces given back without their file, which is what lets a level swap '
				+ 'which parts of a kit it places without reloading the kit. scene.unload() is this plus '
				+ 'emptying the scene and is what a level transition wants. An asset loaded but never added '
				+ 'has no references either, so it goes too — load the next level after unloading, not before.',
			'three.inventory()':
				'Every .glb and .gltf under the assets directory, described without loading any of it: '
				+ '[{ path, triangles, nodes, skins, meshes: [{ name, triangles }], animations: [name], '
				+ 'bounds: { min, max } }]. Read out of the JSON chunk, so it is cheap on a kit of any size — '
				+ 'ask this before three.load to find out what is worth loading. `path` is what three.load wants. '
				+ 'Empty when three was not started with --assets, since there is then no directory to describe.',
			'scene.export(path)':
				'Write the scene to a .glb, and answer with { path, meshes, entries, materials, images, '
				+ 'nodes, instances, batches, skipped, shaded, bytes }. One mesh per unique (asset, mesh), '
				+ 'so a thousand walls from one kit are one mesh in the file exactly as they are one draw '
				+ 'call in the frame. Sibling copies of one shape are written as a single node carrying an '
				+ 'array of transforms — EXT_mesh_gpu_instancing, which any glTF reader can place — with a '
				+ '_COLOR_0 array beside them holding each copy\'s mesh.color, so a scene of many colours '
				+ 'reloads as the one draw call it drew as. batches counts the nodes written that way. A '
				+ 'copy with no sibling drawing the same shape keeps its name and its own material instead, '
				+ 'which costs no draw call, and groups are never collapsed. Copies made with '
				+ 'asset.instantiate() are not siblings — each arrives in a group of its own — so they do '
				+ 'not batch, which only matters if you tinted them: pass { flatten: true } to batch every '
				+ 'copy of a shape in world space instead, giving up the hierarchy and the copies\' names '
				+ 'to do it. Images are written once and '
				+ 'shared across every file they came from. Under --assets the path is inside the game '
				+ 'directory and cannot climb out of it, as three.load\'s is. Helpers and hidden subtrees '
				+ 'are not in the file (skipped counts them) and a ShaderMaterial is not either, because it '
				+ 'is a Slang pipeline and glTF describes surfaces rather than programs — those meshes are '
				+ 'exported with the base colour and texture their geometry carries, and shaded counts them.',
			'three.renderSize()': '{ width, height } of the offscreen image — what pick() counts in and what the returned PNG is.',
			'three.getApiDocs()': 'This.',
			'three.input.isDown(key)':
				'Whether a key is held right now. Poll this in the animation callback for continuous '
				+ 'movement — a held key fires no repeat events.',
			'three.input.pressed(key) / released(key)':
				'Whether the key went down (or up) during the frame being drawn. Meaningful inside the '
				+ 'animation callback; between frames it reports the last frame, which is almost always nothing.',
			'three.input.text':
				'What was typed this frame, as UTF-8, with modifier chords, control characters and the '
				+ 'function-key range filtered out. The layout and the shift key are already applied, so '
				+ 'this is what a text field wants rather than the key map.',
			'three.input.keys()':
				'Every key name there is. The same list the host searches, so it cannot be out of date.',
			'three.onKeyDown(key, fn) / three.onKeyUp(key, fn)':
				'Call fn(keyName) once when the key goes down (or up), from inside the frame. One handler '
				+ 'per key per edge — binding again replaces, null unbinds, and up to 32 exist at a time. '
				+ 'Synchronous only, and stopped for good if it throws, exactly as the animation callback is. '
				+ 'Escape is the host\'s: it closes the window whatever a script binds.',
			'three.input.pointer':
				'{ x, y, inside, down, clicked } — where the cursor is, in the rendered image\'s pixels '
				+ 'counted from its top-left corner, which is what scene.pick(x, y) takes. `inside` is '
				+ 'false when the cursor has left the window, and everything is zero when there is no '
				+ 'window at all. Read it in the animation callback.',
			'three.onClick(fn)':
				'Call fn(hit, x, y) once when the window is clicked, from inside the frame. `hit` is what '
				+ 'is under the cursor — the same intersection scene.pick(x, y) answers with, or null for '
				+ 'a miss — so click-to-select is one call. A click is a press and a release in the same '
				+ 'place: dragging orbits the camera and does not fire this. One handler; binding again '
				+ 'replaces, null unbinds. Synchronous only, and stopped for good if it throws.',
			'three.physics.add(object, options)':
			'Give an object a body and answer with the object. The description is object.body if it has one and `options` wins over it, so a scene can be described once and tweaked at the call: { shape: \'box\' | \'sphere\' | \'capsule\' | \'hull\', mass: 1, friction: 0.5, restitution: 0.2, kinematic: false, trigger: false }. mass 0 means static. The object has to be in the scene already — a body is placed at a world position — and has to be a child of the scene rather than of another object, because the solver works in world space and a parent transform would fight it. A group draws nothing and so has no size to take a collider from; give the body to a mesh.',
		'three.physics.remove(object)':
			'Take the body away, and answer whether there was one. A body removed while it is inside a trigger still emits its exit event, so a script that destroys something in a trigger volume still hears it leave.',
		'three.physics.gravity':
			'[x, y, z], y-up, read and written as an array. Set once at boot; it is a world setting and not a transform, which is why it is not a live Vector3.',
		'three.physics.count':
			'How many bodies the world holds.',
		'three.budget':
			'How long this script may run before the interrupt stops it, in milliseconds. 5,000 by default. '
			+ 'Raise it to SIMULATE, not to build: five seconds is generous for assembling a scene and short '
			+ 'for stepping one — a check that walks a character 30,000 frames against its colliders needs '
			+ 'minutes, and being forced under five seconds means cutting it into pieces that fit the budget '
			+ 'rather than pieces that mean something. Raising it applies to the run that raises it, because '
			+ 'a script does not know it needs longer until it is already running. Ten minutes is the ceiling '
			+ 'and asking for more clamps rather than throws; zero or negative throws, because there is no way '
			+ 'to turn the interrupt off. It does not reach the animation callback, which keeps its own 100 ms '
			+ 'so that one slow frame is a stutter rather than a hang.',
		'material.repeat / material.offset':
			'How the map is laid across a surface. repeat is [u, v] — or one number for both — and is how '
			+ 'many times the image is tiled; offset is [u, v] in whole repeats, for shifting it. Without '
			+ 'this a surface maps its texture exactly ONCE, so texel density is a function of how big the '
			+ 'mesh is and a 128px image across 100 units is a smear — the way round it used to be cutting '
			+ 'the surface into hundreds of small meshes. On the MATERIAL, not on the texture as in '
			+ 'Three.js: textures here are deduplicated by content across every file, so a transform on '
			+ 'the texture would change every unrelated surface that used the same picture. Two densities '
			+ 'of one image is two materials, which is what they already had to be. A repeat of zero '
			+ 'throws — it maps the whole surface onto one texel.',
		'texture.read(into)':
			'The pixels, copied back off the device: a Uint8Array of width * height * 4 RGBA bytes. '
			+ 'The bytes that went IN, not the ones the shader sees — the copy converts nothing, so a '
			+ 'DataTexture reads back byte-for-byte identical to the array it was built from and a PNG '
			+ 'reads back as its own pixels; the sRGB decode happens at sample time and is not in here. '
			+ '`into` is optional and lets you reuse a buffer: this copies off the device and waits for '
			+ 'the queue, so it belongs at load or in a test rather than in a frame. It is also what '
			+ 'makes a texture testable and what lets scene.export write a generated one.',
		'three.physics.velocity(object)':
			'[lx, ly, lz, ax, ay, az] — linear in world units per second, angular in radians per second — or '
			+ 'null when the object has no body. Both at once because a script that wants one usually wants '
			+ 'the other; null rather than a throw because this gets asked in a loop over things that may or '
			+ 'may not have bodies.',
		'three.physics.setVelocity(object, [x, y, z])':
			'Assign a body\'s speed, in world units per second. This is what a character uses: set it every '
			+ 'frame from the keys that are down, because what you want is a speed. Only a dynamic body can '
			+ 'be given one — a static body\'s inverse mass is zero so nothing would happen, and a kinematic '
			+ 'body is driven by the transform your script writes so it would be discarded a fraction of a '
			+ 'step later. Both throw and say which. The solver recomputes the velocity from what actually '
			+ 'happened at the end of every step, so this survives one integration by design.',
		'three.physics.setAngularVelocity(object, [x, y, z])':
			'Radians per second about each world axis; the vector\'s length is the rate. Same dynamic-only '
			+ 'rule as setVelocity.',
		'three.physics.applyImpulse(object, [x, y, z], at)':
			'A push, in mass times velocity — so the same impulse moves a heavy thing less, and this is what '
			+ 'a jump, a bat or an explosion wants rather than setVelocity. It ADDS to whatever the body was '
			+ 'already doing. `at` is optional and is an offset from the body\'s centre in world axes, not a '
			+ 'world position: give one and the push tumbles the body as well as shoving it. A sleeping body '
			+ 'is woken first, so a settled crate and a rolling one answer the same push the same way.',
		'three.physics.applyTorqueImpulse(object, [x, y, z])':
			'A spin with no shove, so "make this rotate" does not mean solving for an offset and a force '
			+ 'that happen to produce the spin you wanted.',
		'object.body':
			'What kind of body three.physics.add would give this object, and what it gave it: { shape, mass, friction, restitution, kind }. Set it yourself to describe one, or read it back after add to see the defaults filled in. null once the body is removed.',
		'three.onTrigger(fn)':
			'Call fn({ type: \'enter\' | \'exit\', trigger, other }) when a trigger body starts or stops overlapping something, from inside the frame. `trigger` and `other` are the objects, or null for one whose node has already gone. One handler; binding again replaces, null unbinds. Synchronous only, and stopped for good if it throws — the same rules onClick follows.',
		'three.onContact(fn)':
			'Call fn({ type: \'start\' | \'end\', a, b, normal, point }) when two bodies touch or come apart. Unlike a trigger, a contact also produced a physical response. `normal` and `point` describe the touch and mean something only on a start — by the end there is no contact left to describe. Same registration and same rules as onTrigger.',
		'three.setAnimationLoop(fn)':
				'Run fn(elapsedMs) once per frame, or null to stop. Synchronous only. The next '
				+ 'run_script reports how many frames it ran, whether it is still running, and why it '
				+ 'stopped if it did. Only one callback exists: registering a second replaces the first. '
				+ 'It survives new three.Scene(), so a callback holding meshes from the old scene will '
				+ 'throw on the next frame and be stopped — re-register it after rebuilding.',
			'toJSON() / toString()':
				'What JSON.stringify sees, and therefore what comes back in the `value` field when you '
				+ 'return an object from a script. Objects report their name, transform and children; a '
				+ 'Vector3 reports [x, y, z]; a ShaderMaterial reports its fragment and uniforms.',
			'three.texture(path)':
				'Decode a PNG or JPEG and upload it, answering with a Texture. Synchronous. The format '
				+ 'comes from the file\'s first bytes rather than its name. Deduplicated by the decoded '
				+ 'image, so the same picture reached by two paths — or by a path and a .glb — is one '
				+ 'upload, and three.stats().textures counts it once.',
			'new three.DataTexture(data, width, height)':
				'Upload pixels a script generated. Rows run bottom-to-top, four bytes per pixel. '
				+ 'The bytes are read and copied inside the call, so the array is yours again '
				+ 'immediately. Wrong byte counts are refused with the arithmetic in the message '
				+ 'rather than uploaded skewed.',
			'texture.dispose()':
				'Give back the reference this handle holds. Not a free: the image goes only when nothing '
				+ 'names it, so disposing while a material still draws with it leaves that material '
				+ 'correct. Disposing twice does nothing. Using a disposed texture throws.',
			'new three.MeshLambertMaterial({ map, side })':
				'The built-in shader with an image. Compiles nothing, needs no Slang, and cannot fail '
				+ 'with a shader diagnostic — this is the way to put a picture on a shape. With no map it '
				+ 'is a side and nothing else, which is the cheapest skydome.',
			'material.map':
				'The base colour image, or null. The material\'s map wins over whatever texture the mesh '
				+ 'itself carries, so a glTF\'s own image can be overridden and cannot silently override '
				+ 'yours. A mesh with no uvs shows nothing: every parametric shape and every glTF mesh '
				+ 'has them, a ConvexGeometry does not — on one of those the map is set, correct, and '
				+ 'invisible.',
			'new three.ShaderMaterial({ fragment, uniforms })':
				'Compile a fragment function into a material. Uniforms are at most 68 bytes in total '
				+ '(17 floats); each is a number or an array of up to four numbers.',
			'mesh.material':
				'Assign a MeshLambertMaterial or a ShaderMaterial, or null for the default shader. Meshes '
				+ 'sharing a mesh ref AND a material are one draw call; giving two of them different '
				+ 'materials makes two.',
			'material.dispose()':
				'Give back the reference this handle holds, and with it the pipeline the material was '
				+ 'compiled into. Not a free: the material goes when no mesh names it either, so disposing '
				+ 'while a mesh still draws with it leaves that mesh correct and collects the material when '
				+ 'the mesh goes. Call it on a ShaderMaterial you are done with — an agent iterating on a '
				+ 'shader compiles a new pipeline every run, and without this they accumulate for the life '
				+ 'of the process. Disposing twice does nothing; using a disposed material throws. The '
				+ 'default and line materials are shared and cannot be disposed.',
			'material.uniforms.<name>':
				'Read or write a uniform. Writing takes effect on the next render. Only names declared at '
				+ 'construction exist; assigning to any other name throws. A uniform declared as a table is '
				+ 'written a row at a time — material.uniforms.palette[1] = [0, 1, 0] — or all at once.',
			'three.setPost({ fragment, uniforms, textures })':
				'Run one shader over the whole finished frame. fragment is a Slang function '
				+ '`float3 post(Post p)` returning linear rgb; Post has color (this pixel of the rendered '
				+ 'scene, already decoded to linear), uv (0..1 across the frame, (0,0) top left), resolution '
				+ '(the frame in pixels — 1.0 / p.resolution is one texel, which is what a blur steps by) and '
				+ 'time (seconds since this shader was set, wall clock rather than a game clock). Each '
				+ 'uniform is readable in the body by its own name; they are at most 112 bytes in total (28 '
				+ 'floats), each a number or an array of up to four numbers, and NOT a table — a post pass '
				+ 'draws one triangle over the whole frame, so there are no instances for a row to belong to. '
				+ 'textures is a ShaderMaterial\'s: { grade_lut: tex } declares a Sampler2D the body reads by '
				+ 'that name, up to four, with no binding number written anywhere. They are what a frame '
				+ 'cannot supply about itself — a ramp to grade through with grade_lut.Sample(float2(p.color.r, '
				+ '0.5)), a noise field to distort or dither by, a mask that says where the effect applies. '
				+ 'Tile one by the frame rather than by uv, p.uv * p.resolution / 256, or it stretches with '
				+ 'the window. A sampler you leave null reads white. '
				+ 'Compiles on the call, so a bad body throws here carrying the Slang diagnostic with '
				+ 'post:<line> counting the lines you wrote; a failed set leaves the previous chain running, '
				+ 'so it is the old shaders or the new one and never neither. Needs a GPU device. '
				+ 'It applies identically to the window, to three.render() and to every screenshot — there is '
				+ 'one recording path and the branch is inside it — so what you see is what a PNG comes back '
				+ 'as. post() returns rgb and never alpha, for shade()\'s reason and one more: a screenshot '
				+ 'forces alpha opaque anyway, so a body that could dim it would make the window and the file '
				+ 'disagree. setPost REPLACES the whole chain (the old pipelines are retired for you) and '
				+ 'three.addPass adds to it. The chain belongs to the renderer rather than to the scene, so '
				+ 'it survives new three.Scene() and outlives the script that set it. three.setPost(null) is '
				+ 'the only thing that clears it.',
			'three.addPass({ fragment, uniforms, textures })':
				'Put another full-screen pass at the end of the chain. The same spec three.setPost takes and '
				+ 'the same handle back, and the difference is what the body reads: p.color is what the pass '
				+ 'BEFORE this one wrote, and p.scene is the frame as the geometry left it, whatever has run '
				+ 'since. Those two are the whole dependency model — a pass reads its predecessor and it '
				+ 'reads the original picture — and between them they cover what a multi-pass effect wants: '
				+ 'bloom is blur(bright(scene)) + scene, which is p.scene three passes later. For the first '
				+ 'pass in a chain the two are the same image, so a body written for setPost keeps working '
				+ 'unchanged. Everything between passes is linear float rather than 8-bit, so a pass may '
				+ 'return values above 1 and the next one still sees them; the display encode happens once, '
				+ 'after the last pass, and is not yours to write. Adding to an empty chain is exactly a '
				+ 'setPost. It does NOT invalidate handles you already hold — earlier passes keep their '
				+ 'index and their shader — which is what lets a script animate every pass at once. There is '
				+ 'no removePass: dropping one out of the middle would renumber the handles after it, and a '
				+ 'setPost followed by the addPass calls you want is the same effect said in a way that '
				+ 'cannot leave a handle pointing at somebody else\'s shader.',
			'the handle three.setPost() and three.addPass() answer with':
				'{ fragment, index, uniforms, textures } — the body that is running, where in the chain it '
				+ 'runs, and live uniforms and textures objects exactly like a material\'s: '
				+ 'post.uniforms.gain = 2 is a 4-byte write that takes effect on the next frame with no '
				+ 'compile and no pipeline, which is what makes an animated post pass free, and '
				+ 'post.textures.grade_lut = other swaps an image the same way. Only names given at the call '
				+ 'exist; assigning any other throws. A later setPost replaces the whole chain, and writing '
				+ 'through a handle from before it throws rather than steering whatever is at that index '
				+ 'now. addPass leaves earlier handles working.',
			'mesh.color':
				'This copy\'s own tint, multiplied into albedo. [r, g, b], [r, g, b, a], {r, g, b} or a hex '
				+ 'number like 0xff8800. Costs no draw call: copies of one mesh may all differ. Works with no '
				+ 'material at all, and reaches a shade() body as s.color with albedo already tinted. '
				+ 'The fourth channel fades this copy when — and only when — its material was built '
				+ 'transparent: it multiplies the material\'s own opacity, so one of a thousand copies '
				+ 'sharing a draw call can be half there while the rest are solid. On an opaque material '
				+ 'the alpha is discarded by the pipeline and changes nothing.',
			'mesh.variant':
				'Which row of the material\'s uniform table this copy draws with, as s.variant in the body. '
				+ 'Costs no draw call either. Zero and meaningless until the material declares a table; past '
				+ 'the end it is clamped to the last row rather than reading rubbish.',
			'scene.pick(x, y)':
				'What is under a pixel of the rendered image, counted from its top-left corner. ' +
				'Answers with an intersection (below) or null. Needs a GPU device.',
			'scene.raycast(origin, direction)':
				'What a world-space ray hits. Either vector may be a Vector3, an {x, y, z} or an [x, y, z], ' +
				'and the direction need not be normalised. Answers with an intersection (below) or null.',
			'three.camera.orbit(yaw, pitch, distance)': 'Degrees, degrees, world units. Any argument may be omitted to leave it alone.',
			'three.camera.lookAt(x, y, z)': 'Point the turntable at a world position.',
			'three.camera.frameAll()': 'Aim at everything in the scene and back off far enough to see it.',
			'three.camera.near / three.camera.far':
				'Where the depth range starts and ends, in world units. Read-only: both are derived, from '
				+ 'the orbit distance and from the scene\'s own bounds, every time the camera moves. They '
				+ 'are worth reading when something has stopped being drawn — geometry beyond far is not '
				+ 'dim, it is absent, and it is culled as well as clipped, so stats().culledLastFrame moves too.',
			'three.light.direction / three.light.ambient':
				'The one directional light. direction is a world-space surface-to-light vector — the way a '
				+ 'face has to point to be fully lit — and is a live Vector3, so three.light.direction.y = -1 '
				+ 'writes through. It is not normalized, so it reads back as you wrote it, and a zero one '
				+ 'throws rather than making every shaded pixel a NaN. ambient is the floor a face turned '
				+ 'right away from the light gets, 0 to 1: at 0 it is black, at 1 there is no shading at all '
				+ 'and everything is its own flat colour. Defaults to [0.35, 0.8, 0.45] and 0.25.',
			'three.light.set(direction, ambient)':
				'Both at once. ambient may be omitted to leave it alone. There is no second light, no colour '
				+ 'per light and no shadow, which is why this is not scene.add(new DirectionalLight(...)) — '
				+ 'a name Three.js has would be read as a promise of the three things it cannot do.',
			'three.NoBlending / three.NormalBlending / three.AdditiveBlending':
				'The values material.blending takes — 0, 1 and 2, Three.js\'s numbers again. '
				+ 'NormalBlending is what { transparent: true } means and is what glass, water and a '
				+ 'foliage card want; AdditiveBlending never darkens what is behind it and is what fire, '
				+ 'a glow and a beam want. Both are decided when the material is constructed and neither '
				+ 'can be assigned afterwards: this device bakes blending into the pipeline, so changing '
				+ 'it is building another material, which is one line. Three things follow and are worth '
				+ 'knowing before a scene is built on them. Transparent draws are sorted farthest-first '
				+ 'against the near plane and drawn after every opaque one, so glass shows the wall '
				+ 'behind it. Copies inside ONE instanced bucket are not sorted against each other — '
				+ 'they are one draw call, and the depth order within it is whatever the vertex order '
				+ 'is; Three.js\'s per-object sort has the same limit, and the fix in both is to space '
				+ 'the panes out or split them. And a transparent frame may issue more draw calls than '
				+ 'stats().drawCalls reports, deliberately: depth interleaving splits buckets and the '
				+ 'split depends on where the camera is, so stats() answers what the scene costs rather '
				+ 'than what this angle cost. The number is a floor, never an over-estimate.',
			'three.FrontSide / three.BackSide / three.DoubleSide':
				'The values material.side takes — 0, 1 and 2, the same numbers Three.js gives them. '
				+ 'BackSide keeps the back faces, which is what makes a sphere visible from inside: it is '
				+ 'how a skydome is built, and scaling one by -1 instead does nothing, because a negative '
				+ 'scale does not reverse a triangle\'s winding. DoubleSide keeps both and is what a plane '
				+ 'seen from either direction wants — a flag, a leaf card, a piece of a wall you can walk past.',
		},
		// The whole key table, from the host, so the names an agent reads and the
		// names the host searches are one list. Aliases included: ctrl, cmd, esc.
		// No numpad and no mouse buttons — mesh.pick and the mouse are the
		// camera's, and a latched mouse button is a trap the window has already
		// been caught by once.
		keys: H.keyNames(),
		stats: {
			drawCalls: 'vkCmdDrawIndexed calls for one frame of this scene.',
			uniqueMeshes: 'Distinct (asset, mesh) pairs drawn.',
			instances: 'Total placed meshes. The M2 claim is that 1000 of these can be 1 drawCall.',
			nodes: 'Live nodes, groups and the root included.',
			assets: 'Loaded files and generated shapes resident on the device. This is the number a level transition has to bring back down; watch it across scene.unload().',
			triangles: 'Summed over instances, so 1000 copies of a 500-triangle mesh is 500000.',
			vertices: 'Likewise.',
			textures: 'Unique images on the device, deduplicated by content across every loaded file.',
			textureBytes: 'What those cost.',
			culledLastFrame: 'Instances the frustum dropped in the last render().',
			gpuMs: 'Milliseconds the GPU spent on the frame you just asked for, measured on the GPU\'s own '
				+ 'clock rather than timed from here. three.render() and a screenshot each leave their own '
				+ 'measurement behind, so render first and read this after. 0 before anything has been drawn, '
				+ 'and 0 for the whole run in a context with no device — the same zero either way, so use '
				+ 'renderSize() if you need to tell "nothing drawn" from "nothing to draw with". The span is '
				+ 'the whole submission, including the blit or the readback copy that puts the frame where you '
				+ 'can see it, so it answers what the frame cost rather than what the draws cost.',
		},
		intersection: {
			object: 'The Mesh that was hit. Null only for a node this script did not build — one opened from the command line.',
			name: 'Its name, which identifies it even when object is null.',
			distance: 'World units along the ray. Comparable across objects however each of them is scaled.',
			point: 'Where the ray met the surface, world space, as a Vector3.',
			normal: 'The surface normal there, world space, unit length.',
		},
		example: [
			'const scene = new three.Scene();',
			'',
			'// One geometry per mesh is fine — the same numbers are the same asset,',
			'// so this whole grid is a single instanced draw call.',
			'for (let x = -4; x <= 4; x++) {',
			'  for (let z = -4; z <= 4; z++) {',
			'    const cube = new three.Mesh(new three.BoxGeometry(1, 1, 1));',
			'    cube.position.set(x * 1.5, 0, z * 1.5);',
			'    cube.scale.y = 1 + Math.abs(x + z) * 0.4;   // scale is free, a new size is not',
			'    scene.add(cube);',
			'  }',
			'}',
			'',
			'const ball = new three.Mesh(',
			'  new three.SphereGeometry(1.2, 48, 24),',
			'  new three.ShaderMaterial({',
			'    uniforms: { tint: [1, 0.4, 0.2] },',
			'    fragment: "float3 shade(Surface s) { return lambert(s.normal) * tint; }",',
			'  }),',
			');',
			'ball.position.y = 3;',
			'scene.add(ball);',
			'',
			'three.camera.frameAll();',
			'three.render(scene, three.camera);',
			'return scene.stats();   // { drawCalls: 2, uniqueMeshes: 2, instances: 82, ... }',
		].join('\n'),
		exampleFromFile: [
			'const kit = three.load("assets/kit.glb");',
			'const wall = kit.mesh("wall_corner_02");',
			'const scene = new three.Scene();',
			'for (let i = 0; i < 12; i++) {',
			'  const m = new three.Mesh(wall);',
			'  m.position.set(i * 2, 0, 0);',
			'  m.rotation.y = Math.PI / 2;',
			'  scene.add(m);',
			'}',
			'three.camera.frameAll();',
			'three.render(scene, three.camera);',
			'return scene.stats();   // { drawCalls: 1, instances: 12, ... }',
		].join('\n'),
	};

	globalThis.three = three;
	globalThis.Vector3 = Vector3;
})();
