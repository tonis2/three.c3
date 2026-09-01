// three.c3 — Object3D and Group: the scene graph's nodes and their transforms.

import {
	Vector3, axisIndex, boxFromSix, refBounds, transformBox, asTriple,
	localMatrix3, multiplyMatrix3, applyMatrix3, invertMatrix3,
} from './math.js';

const H = globalThis.__three;

// -----------------------------------------------------------------------
// Object3D

// The Scene an object hangs under, or null for one that is not in a graph yet.
//
// By the `_isScene` marker rather than `instanceof Scene`, for the reason the
// check inside `add` uses it: the class lives in a module that extends this one.
function sceneOf(object) {
	for (let up = object; up; up = up.parent) {
		if (up._isScene === true) return up;
	}
	return null;
}

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
		// Whether this object is collision geometry — see the accessor. On by
		// default, because the surprising answer is a wall walked through
		// rather than a pickup that blocks.
		this._collides = true;
		// Whether this object is in the half of the shadow map that is drawn
		// once and kept — `plan.md` §19.3. Off by default, and the host refuses
		// it on anything with a skin, which is why the setter reads the answer
		// back rather than assuming it took.
		this._static = false;
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
		// Which of the asset's skins poses this mesh, and whether the compute pass
		// does the posing. -1 on everything that is not a character, which is
		// almost everything. See `_materialize`.
		this._skin = -1;
		this._preskinned = false;
		// Whether this character's palette is computed from its bone nodes each
		// frame rather than keyed out of the baked table — `instantiate({ skeleton: true })`.
		// Carried on the root, because that is what `_bindAnimation` runs on.
		this._liveSkin = false;
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

	// **"This will not move again."** A static object is rasterised into the
	// shadow map once and then left there, so a village costs its shadows on
	// the frame it is built and nothing afterwards — three.stats()
	// .shadowStaticDraws is where that shows. It costs no draw call in the
	// colour pass: the flag orders copies inside their bucket rather than
	// keying one, so a static wall and a moving one over the same geometry are
	// still one draw.
	//
	// Moving it afterwards through position/rotation/scale is safe — the host
	// notices and rebuilds the map — but every such move costs the rebuild, so
	// this is for the things that genuinely stand still. Refused on a skinned
	// mesh, where a pose can change the silhouette without a transform moving,
	// and reading it back is how a script sees that.
	get static() { return this._static; }
	set static(v) {
		const want = !!v;
		this._static = this._i >= 0 ? !!H.setStatic(this._i, this._g, want) : want;
	}

	// **"This is scenery, not a wall."** Off takes the object out of the
	// spatial index entirely: nothing sweeps against it, nothing raycasts it,
	// three.query.sphere does not report it. A pickup lying on a path stops
	// being a bollard and a field of grass stops being a fence.
	//
	// `three.physics` is untouched by it — a body is a body, and a trigger
	// volume on a mesh with `collides = false` is the ordinary way to write a
	// pickup you can walk into and cannot walk into.
	//
	// NOT inherited, unlike `visible`: it says what one piece of geometry is.
	// Hiding a whole character from ONE sweep is `{ ignore }` on that call.
	// Toggling it costs an index rebuild, so it belongs where a level is
	// authored rather than in a loop — `visible` is the free one.
	get collides() { return this._collides; }
	set collides(v) {
		this._collides = !!v;
		if (this._i >= 0) H.setCollides(this._i, this._g, this._collides);
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
	// trio earns its complexity on holding several weighted actions at once.
	// There is a crossfade here — `play(name, { fade })` — and it is two
	// clips and one weight, which is what a locomotion state machine asks
	// for. The third simultaneous clip is where a mixer would have to be a
	// mixer, and it is not here. See G3/S7.

	get animations() { return this._clips ? this._clips.slice() : []; }

	// `fade` crossfades out of whatever is playing, in seconds. **Asking to
	// fade into the clip that is already playing does nothing**, which is
	// what makes `play(state.clip, { fade: 0.2 })` safe to call from a state
	// machine that runs every frame. Restarting a clip outright is `play`
	// without a fade.
	play(name, { loop = true, speed = 1, time = 0, fade = 0 } = {}) {
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
		H.playAnimation(this._i, this._g, String(name), !!loop, +speed, +time, +fade);
		return this;
	}

	stop() {
		if (this._i >= 0 && this._clips) H.stopAnimation(this._i, this._g);
		return this;
	}

	// -------------------------------------------------------------------
	// Sockets
	//
	// "Put the sword in the character's hand." The bone is named by the
	// file — `asset.bones` is the list — and what comes back is an ordinary
	// object to `add` things to.
	//
	// **The two kinds of character answer this differently and on purpose.**
	// With `skeleton: true` the bones already are objects in the tree, so
	// this hands back the bone itself: moving it moves the skin, and what is
	// parented to it rides along through the ordinary graph. A baked
	// character has no bone objects at all — dropping them is what makes a
	// hundred of them a hundred nodes — so this makes one and the host keeps
	// it on the bone, reading the transform out of the pose table the
	// character is already being drawn from. Either way the answer is
	// something you can `add` to.
	//
	// Called twice for one bone on a baked character, it builds two holders.
	// That is deliberate: they are ordinary objects with their own children,
	// and deduping them would make removing one remove the other's contents.
	socket(name) {
		if (this._i < 0) {
			throw new Error(`socket("${name}") needs ${this._name || 'the object'} to be in a scene — add it first`);
		}
		if (this._liveSkin) {
			const bone = this.getObjectByName(String(name));
			if (!bone) throw new Error(`no bone named "${name}" — ${this._boneList()}`);
			return bone;
		}
		const holder = new Object3D();
		holder.name = String(name);
		this.add(holder);
		if (!H.bindSocket(holder._i, holder._g, this._i, this._g, String(name))) {
			this.remove(holder);
			throw new Error(`no bone named "${name}" — ${this._boneList()}`);
		}
		return holder;
	}

	// What the rig does have, for the sentence above. `_bones` is set by
	// `asset.instantiate()`; anything else is not a character and says so.
	_boneList() {
		if (!this._bones) {
			return 'socket() works on a character from asset.instantiate(). This object has no skeleton.';
		}
		return this._bones.length ? `this one has: ${this._bones.join(', ')}` : 'this one has no bones';
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
		H.bindAnimation(this._i, this._g, this._asset[0], this._asset[1], pairs, !!this._liveSkin);
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
		if (!this._collides) H.setCollides(i, g, false);

		const material = this._hostMaterial();
		if (material >= 0) H.setMaterial(i, g, material);
		// Only when they are not the identity: `_materialize` runs once per
		// object added, and a scene of ten thousand default-coloured meshes
		// should not pay twenty thousand crossings to say "white, row zero".
		if (this._color && !(this._color[0] === 1 && this._color[1] === 1 && this._color[2] === 1 && this._color[3] === 1)) {
			H.setColor(i, g, ...this._color);
		}
		if (this._variant) H.setVariant(i, g, this._variant);
		// Replayed like colour and variant, and only when something is actually
		// worn: an all-zero vector is the neutral mesh, which is what the host
		// already has, so sending it would be a crossing to say nothing.
		if (this._weights && this._weights.toArray().some(w => w !== 0)) this._weights._push();
		// A skinned mesh learns its skeleton here and nowhere else: this is the
		// first moment there is a host node to tell, and the host's own
		// `instantiate` — which sets it as it builds — is not the path a script
		// takes. Without it a character from `asset.instantiate()` would draw its
		// bind pose forever.
		if (this._skin >= 0) H.bindSkin(i, g, this._skin, !!this._preskinned);
		// **After `bindSkin`, not before.** The host refuses a static caster that
		// has a skin, and it learns about the skin on the line above — so asking
		// first would be told yes and then quietly overruled, and `this._static`
		// would disagree with the node for the rest of the session.
		if (this._static) this._static = !!H.setStatic(i, g, true);

		for (const child of this.children) child._materialize(this);
		// **A live character needs its player before anything plays**, unlike every
		// other use of the map: the palette is computed from the bone nodes each
		// frame, and the player is what holds the map from the file's joints to
		// this copy's nodes. A script that only wants to aim a head never calls
		// `play`, and without this its bones would move nothing.
		//
		// After the children, because the map is of the whole subtree and they have
		// only just been given host nodes.
		if (this._liveSkin && this._asset) this._bindAnimation();
	}

	// The host node is gone; this object is a detached description again, and
	// re-adding it builds a new node. The whole subtree goes with it, because
	// removing a node removes its descendants.
	_demote() {
		this._i = -1;
		this._g = -1;
		// The host dropped the player along with the nodes, so the map has to be
		// sent again if this subtree is re-added. Without this a character removed
		// and put back would keep its clips and quietly stop being posed by them.
		this._bound = false;
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
			// Two scenes are two node pools, so moving between them would mean
			// destroying the subtree and rebuilding it under the other root — which
			// is exactly what re-parenting is documented NOT to do, because a
			// rebuild invalidates every handle into something that never left the
			// graph. The host refuses this too, and that refusal is the backstop
			// rather than the check: it arrives after the lines below have already
			// moved the object in the JavaScript tree.
			const from = sceneOf(o);
			const to = sceneOf(this);
			if (from !== null && to !== null && from !== to) {
				throw new TypeError('an object cannot be moved between scenes — rebuild it in the one you want it in');
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
		if (box === null) throw new Error(noBox('align()'));
		const key = ['x', 'y', 'z'][axisIndex(axis, 'align()')];
		const to = +at;
		if (!Number.isFinite(to)) throw new TypeError(`align(${axis}, ${edge}, at) wants a number for at`);
		this.position[key] += to - box.edge(axis, edge);
		return this;
	}

	// The same move, expressed against another object instead of a number.
	//
	//   window.alignTo(wall, { axis: 'z', mine: 'min', theirs: 'max', offset: -0.28 })
	//
	// **A placement is usually more than one axis, so a call can be.** Name the
	// axes and the whole sentence is one call — "my back face on your front
	// face, centred on you in x, standing on you in y":
	//
	//   lean.alignTo(hall, { z: { mine: 'min', theirs: 'max' }, x: 'center', y: 'min' })
	//
	// An axis is either a string — one word for both faces, so `'center'` is
	// centred on it and `'min'` is flush with its low side — or the long
	// `{ mine, theirs, offset }`, whose defaults are the `min`-against-`max` of
	// the single-axis form. **An axis nobody named does not move**, which is what
	// makes this safe to reach for after a piece is already standing on the floor.
	// The old four keys still mean what they meant, and mixing the two spellings
	// is allowed: a named axis wins over `axis` naming the same one.
	//
	// Siblings by default, because each box is measured in its own parent's
	// frame and two different parents are two different frames. `world: true`
	// is the cross-parent form — see `_alignInWorld`.
	alignTo(other, options = {}) {
		if (!(other instanceof Object3D)) {
			throw new TypeError('alignTo(other) wants another object as its first argument');
		}
		if (options === null || typeof options !== 'object') {
			throw new TypeError('alignTo(other, options) wants an options object as its second argument');
		}
		const specs = alignSpecs(options, 'alignTo()');
		if (options.world) return this._alignInWorld(other, specs);
		if (other.parent !== this.parent) {
			throw new Error(
				'alignTo() aligns siblings: both objects must share a parent, because a box is '
				+ 'measured in the frame of the parent it hangs from. For two objects in different '
				+ 'frames, pass `world: true` — that measures both in world space and moves this one '
				+ 'by the step that comes to, in its own parent\'s frame.');
		}
		const box = other.boundsInParent();
		if (box === null) throw new Error('alignTo(): the object aligned to draws nothing, so it has no box');
		const mine = this.boundsInParent();
		if (mine === null) throw new Error(noBox('alignTo()'));
		// One measurement for however many axes: a move along x cannot change
		// where this box's y faces are, so the steps are independent and there
		// is nothing to re-measure between them.
		for (const s of specs) {
			this.position[s.key] += box.edge(s.axis, s.theirs) + s.offset - mine.edge(s.axis, s.mine);
		}
		return this;
	}

	// `alignTo(other, { world: true, ... })`: the same sentence about two
	// objects that do NOT share a parent — a lean-to against a hall in another
	// group, a sign on a building, a lid on a crate someone else parented.
	//
	// **The faces are world faces and the axes are world axes.** Both boxes come
	// from the host, in world space, and the step that closes the gap is worked
	// out there. What crosses back into this object's own frame is that step —
	// one vector through the inverse of its parents' rotation-and-scale — and a
	// translation converts exactly, whatever those parents are: a non-uniform
	// scale, a rotation of 30 degrees, an ancestor with both. So the piece lands
	// with its world faces where they were asked for, and `position` may be a
	// diagonal number that looks like nothing in particular. That is the frame
	// change, not a rounding error.
	//
	// The approximation is the one every box here has: a world box is
	// axis-aligned in *world*, so a piece turned 30 degrees is measured by the
	// upright box around it and touches by that box. `boundsInParent()` is the
	// tighter answer whenever the two objects really are siblings, and staying
	// with the sibling form is why this is opt-in rather than the default.
	//
	// Two objects that share a parent after all are allowed rather than refused:
	// the answer is then the sibling answer whenever nothing above them turns or
	// squashes the frame, and the world-axis answer when something does. It
	// costs two host calls where the sibling form costs none.
	_alignInWorld(other, specs) {
		if (this._i < 0 || other._i < 0) {
			throw new Error(
				'alignTo({ world: true }) measures both objects in world space, and world space is '
				+ 'something a scene has — add() them first.');
		}
		const mine = this.boundingBox();
		const theirs = other.boundingBox();
		if (mine === null) throw new Error(noBox('alignTo({ world: true })'));
		if (theirs === null) {
			throw new Error('alignTo({ world: true }): the object aligned to draws nothing, so it has no box');
		}
		// Every axis first, then one conversion. A parent's frame mixes the axes,
		// so converting a step per axis and adding the results up would not be
		// the same move — and for a turned parent it would not even be close.
		const step = [0, 0, 0];
		for (const s of specs) {
			step[s.i] = theirs.edge(s.axis, s.theirs) + s.offset - mine.edge(s.axis, s.mine);
		}
		const inverse = invertMatrix3(worldMatrix3(this.parent));
		if (inverse === null) {
			throw new Error(
				'alignTo({ world: true }): something above this object is scaled to nothing on an '
				+ 'axis, so no local move produces the world one.');
		}
		const local = applyMatrix3(inverse, step);
		const p = this.position;
		p.set(p.x + local[0], p.y + local[1], p.z + local[2]);
		return this;
	}

	// **A run: N pieces edge to edge along one axis.** A wall of panels, a floor
	// of tiles, a fence line — the commonest thing a kit is asked for, and the
	// one shape the two align verbs had no word for.
	//
	//   wall.row('x', panels, { at: -3 });      // butted, starting at x = -3
	//   fence.row('z', posts, { gap: 1.4 });    // spaced, starting where the
	//                                           // first post already stands
	//
	// On the parent because a run has a cursor, and the cursor belongs to
	// whoever owns the sequence. The other half of it — "put me after that one"
	// — is already one `alignTo` call and needs no verb of its own.
	//
	// **The step is measured from each piece, never assumed.** A run of pieces
	// that are not all the same size closes up anyway, and a piece turned a
	// quarter turn steps by the side it now presents, because `boundsInParent()`
	// has the rotation in it. `gap` is that measured step plus a constant, so a
	// negative one laps the pieces over each other — which is what a course of
	// roof tiles is.
	//
	// Only the run axis moves: whatever the pieces were at on the other two is
	// what they stay at. `at` is where the run's low face goes, and leaving it
	// out starts the run at the first piece's own low face — "these follow that
	// one". A piece that is not a child yet is added, since a run is built out
	// of pieces going into this object anyway. For a run that grows the other
	// way, reverse the list.
	row(axis, pieces, { at, gap = 0 } = {}) {
		const key = ['x', 'y', 'z'][axisIndex(axis, 'row()')];
		const step = +gap;
		if (!Number.isFinite(step)) throw new TypeError('row(axis, pieces, { gap }) wants a number for gap');
		let cursor = at === undefined || at === null ? null : +at;
		if (cursor !== null && !Number.isFinite(cursor)) {
			throw new TypeError('row(axis, pieces, { at }) wants a number for at');
		}
		// Copied, so that `parent.row(axis, parent.children)` is not walking the
		// same list `add` splices.
		for (const piece of [...pieces]) {
			if (!(piece instanceof Object3D)) {
				throw new TypeError('row(axis, pieces) wants a list of objects to place');
			}
			if (piece.parent !== this) this.add(piece);
			const box = piece.boundsInParent();
			if (box === null) {
				throw new Error(
					`row(): ${piece.name ? `"${piece.name}"` : 'a piece'} draws nothing, so there is `
					+ 'no step to take from it — a run is measured piece by piece.');
			}
			const lo = box.edge(axis, 'min'), hi = box.edge(axis, 'max');
			if (cursor === null) cursor = lo;
			piece.position[key] += cursor - lo;
			cursor += (hi - lo) + step;
		}
		return this;
	}

	toJSON() {
		return {
			type: this.constructor.name,
			name: this._name,
			position: this.position.toJSON(),
			rotation: this.rotation.toJSON(),
			scale: this.scale.toJSON(),
			visible: this._visible,
			collides: this._collides,
			inScene: this._i >= 0,
			children: this.children.length,
		};
	}
}

// -----------------------------------------------------------------------
// Placing: the shapes `alignTo` reads, and the frame it converts between

// What `align` and everything written on top of it says when there is no box
// to read. One sentence rather than three, because it is one situation.
function noBox(where) {
	return `${where} needs a box, and this object draws nothing — it is a Group with no meshes `
		+ 'under it, or its geometry is not resident. Align a Mesh, or add one first.';
}

const ALIGN_OPTIONS = ['axis', 'mine', 'theirs', 'offset', 'x', 'y', 'z', 'world'];

// One axis of an alignment, out of whichever spelling the caller used:
//
//   'center'                   one word for both faces — centred on the other
//   { mine, theirs, offset }   the long form, defaulting to min-against-max
//
// `i` and `key` come along because every caller wants them and `axisIndex` is
// where a misspelt axis is refused by name.
function alignSpec(axis, value, where) {
	const i = axisIndex(axis, where);
	const spec = { axis, i, key: ['x', 'y', 'z'][i] };
	if (typeof value === 'string') return { ...spec, mine: value, theirs: value, offset: 0 };
	if (value !== null && typeof value === 'object') {
		const { mine = 'min', theirs = 'max', offset = 0 } = value;
		return { ...spec, mine, theirs, offset: +offset };
	}
	throw new TypeError(
		`${where}: ${axis} wants 'min', 'center', 'max' or { mine, theirs, offset }, `
		+ `not ${JSON.stringify(value)}`);
}

// The axes one `alignTo` call was asked about, in the order they will be
// applied. The four original keys are one spec between them; a named axis is a
// spec each and wins over `axis` naming the same one, since it is the more
// specific thing to have written. Nothing named at all is the original default:
// `axis: 'y'`, my min against their max.
function alignSpecs(options, where) {
	for (const key of Object.keys(options)) {
		if (!ALIGN_OPTIONS.includes(key)) {
			throw new TypeError(
				`${where}: no option named ${JSON.stringify(key)} — it takes ${ALIGN_OPTIONS.join(', ')}`);
		}
	}
	const named = ['x', 'y', 'z'].filter(axis => axis in options);
	const byAxis = new Map();
	if (named.length === 0 || 'axis' in options || 'mine' in options
		|| 'theirs' in options || 'offset' in options) {
		const { axis = 'y', mine = 'min', theirs = 'max', offset = 0 } = options;
		const spec = alignSpec(axis, { mine, theirs, offset }, where);
		byAxis.set(spec.i, spec);
	}
	for (const axis of named) {
		const spec = alignSpec(axis, options[axis], where);
		byAxis.set(spec.i, spec);
	}
	return [...byAxis.values()];
}

// The 3x3 that carries an offset in `node`'s frame out to world: every
// ancestor's rotation and scale, outermost first, and the identity for a null
// node — which is the frame of something parented to nothing.
//
// The translations are left out because an offset does not see them, and the
// scene root is in it like any other node: it has a transform and the host
// applies it.
function worldMatrix3(node) {
	const chain = [];
	for (let up = node; up; up = up.parent) chain.push(up);
	let m = [1, 0, 0, 0, 1, 0, 0, 0, 1];
	for (let k = chain.length - 1; k >= 0; k--) {
		const o = chain[k];
		m = multiplyMatrix3(m, localMatrix3(o.rotation, o.scale, o._q));
	}
	return m;
}

// -----------------------------------------------------------------------
// Group

export class Group extends Object3D {}
