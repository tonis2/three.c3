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

	// -----------------------------------------------------------------------
	// Object3D

	class Object3D {
		constructor() {
			this.position = new Vector3(this, 0, 0, 0);
			this.rotation = new Vector3(this, 0, 0, 0);
			this.scale = new Vector3(this, 1, 1, 1);
			this.children = [];
			this.parent = null;
			this._name = '';
			this._visible = true;
			// The host node, or -1 for "not in a scene". See the header.
			this._i = -1;
			this._g = -1;
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

		_flush() {
			if (this._i < 0) return;
			const { position: p, rotation: r, scale: s } = this;
			H.setTransform(this._i, this._g, p._x, p._y, p._z, r._x, r._y, r._z, s._x, s._y, s._z);
		}

		// Create the host node for this object under `parent`, then replay
		// everything set before the add, then do the same for the subtree.
		_materialize(parent) {
			const ref = this._ref();
			const [i, g] = H.add(ref ? ref.asset : -1, ref ? ref.mesh : -1, parent._i, parent._g, this._name);
			this._i = i;
			this._g = g;
			this._flush();
			if (!this._visible) H.setVisible(i, g, false);
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

	class Mesh extends Object3D {
		constructor(ref) {
			super();
			if (!ref || typeof ref.asset !== 'number' || typeof ref.mesh !== 'number') {
				throw new TypeError('new three.Mesh(ref) wants a mesh reference from asset.mesh(name)');
			}
			this._mesh = ref;
			this._name = ref.name ?? '';
		}

		_ref() { return this._mesh; }
		get geometry() { return this._mesh; }
	}

	// There is one scene at a time, and `new three.Scene()` is what empties it.
	//
	// Three.js lets you hold several and render whichever you like; here the
	// second one replaces the first, and every handle into the first goes stale.
	// That is a divergence, so it is made loud rather than silent: an epoch is
	// stamped on each Scene and checked on use, and the older one throws a
	// sentence saying what happened instead of quietly operating on the newer
	// scene's nodes.
	class Scene extends Object3D {
		constructor() {
			super();
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
	}

	// -----------------------------------------------------------------------
	// Assets

	class Asset {
		constructor(index) {
			this._a = index;
			this.path = H.assetPath(index);
			// In load order, which is the order `mesh(name)` resolves in and the
			// order the host's own `find_mesh` walks.
			this.meshes = H.meshNames(index);
		}

		mesh(name) {
			const at = this.meshes.indexOf(name);
			if (at < 0) {
				const have = this.meshes.length ? this.meshes.join(', ') : '(none)';
				throw new Error(`no mesh named "${name}" in ${this.path} — it has: ${have}`);
			}
			return { asset: this._a, mesh: at, name };
		}

		meshAt(i) {
			if (!(i >= 0 && i < this.meshes.length)) {
				throw new RangeError(`mesh index ${i} is outside 0..${this.meshes.length - 1}`);
			}
			return { asset: this._a, mesh: i, name: this.meshes[i] };
		}

		toJSON() { return { path: this.path, meshes: this.meshes }; }
	}

	// -----------------------------------------------------------------------
	// The camera
	//
	// A turntable, not a free Object3D, and named so. Three.js's
	// `camera.position.set(...)` has no meaning here, so the properties that
	// would half-match it do not exist — `orbit()` and `frameAll()` are names
	// Three.js does not have, which is `plan.md` §4's rule for a divergence.

	const camera = {
		get fov() { return H.cameraGet()[6]; },
		set fov(v) {
			const [tx, ty, tz, yaw, pitch, distance] = H.cameraGet();
			H.cameraSet(tx, ty, tz, yaw, pitch, distance, +v);
		},

		get yaw() { return H.cameraGet()[3]; },
		get pitch() { return H.cameraGet()[4]; },
		get distance() { return H.cameraGet()[5]; },

		get target() {
			const [tx, ty, tz] = H.cameraGet();
			return new Vector3(null, tx, ty, tz);
		},

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
			const [x, y, z, yaw, pitch, distance, fov] = H.cameraGet();
			return { target: { x, y, z }, yaw, pitch, distance, fov };
		},
	};

	// -----------------------------------------------------------------------
	// The module

	const three = {
		Scene,
		Mesh,
		Group,
		Vector3,
		Asset,
		camera,

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

		stats() { return H.stats(); },

		getApiDocs() { return DOCS; },
	};

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
			'There is one scene at a time. new three.Scene() empties it, and handles into the previous scene throw.',
			'There is one camera, a turntable: three.camera.orbit(yaw, pitch, distance) and three.camera.frameAll(). camera.position does not exist.',
			'An object is not in the scene until it is add()ed, and removing it makes it a detached description that can be added again.',
			'No materials yet. A mesh draws with the base colour and texture its glTF material carried.',
			'Each run_script call runs in its own function scope. Use globalThis to keep state between calls.',
			'Return a value from your script with `return`; it comes back as the `value` field.',
		],
		classes: {
			Scene: {
				construct: 'new three.Scene()',
				note: 'Empties the one host scene and becomes its root. It is an Object3D, so moving it moves everything.',
				methods: ['add(...objects)', 'remove(...objects)', 'traverse(fn)', 'getObjectByName(name)', 'stats()'],
				properties: ['position', 'rotation', 'scale', 'visible', 'name', 'children', 'parent'],
			},
			Mesh: {
				construct: 'new three.Mesh(assetRef)',
				note: 'assetRef comes from asset.mesh(name) or asset.meshAt(i). N meshes sharing one ref is one draw call.',
				properties: ['position', 'rotation', 'scale', 'visible', 'name', 'geometry', 'children', 'parent'],
				methods: ['add(...)', 'remove(...)', 'traverse(fn)', 'getWorldPosition()'],
			},
			Group: {
				construct: 'new three.Group()',
				note: 'Transforms its children and draws nothing itself.',
			},
			Vector3: {
				construct: 'new three.Vector3(null, x, y, z)',
				note: 'position/rotation/scale are live Vector3s: writing x, y, z or calling set() moves the object.',
				methods: ['set(x,y,z)', 'copy(v)', 'add(v)', 'sub(v)', 'multiplyScalar(s)', 'length()', 'clone()', 'toArray()'],
			},
			Asset: {
				construct: 'three.load(path)',
				properties: ['path', 'meshes (names, in load order)'],
				methods: ['mesh(name)', 'meshAt(index)'],
			},
		},
		functions: {
			'three.load(path)': 'Load a .glb or .gltf. Loading the same path twice returns the same asset.',
			'three.render(scene, camera)': 'Draw one frame. camera is optional and must be three.camera.',
			'three.stats()': 'The numbers below, for the whole scene, with culling off.',
			'three.getApiDocs()': 'This.',
			'three.camera.orbit(yaw, pitch, distance)': 'Degrees, degrees, world units. Any argument may be omitted to leave it alone.',
			'three.camera.lookAt(x, y, z)': 'Point the turntable at a world position.',
			'three.camera.frameAll()': 'Aim at everything in the scene and back off far enough to see it.',
		},
		stats: {
			drawCalls: 'vkCmdDrawIndexed calls for one frame of this scene.',
			uniqueMeshes: 'Distinct (asset, mesh) pairs drawn.',
			instances: 'Total placed meshes. The M2 claim is that 1000 of these can be 1 drawCall.',
			nodes: 'Live nodes, groups and the root included.',
			triangles: 'Summed over instances, so 1000 copies of a 500-triangle mesh is 500000.',
			vertices: 'Likewise.',
			textures: 'Unique images on the device, deduplicated by content across every loaded file.',
			textureBytes: 'What those cost.',
			culledLastFrame: 'Instances the frustum dropped in the last render().',
		},
		example: [
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
