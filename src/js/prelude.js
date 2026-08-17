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
			if (this._material) H.setMaterial(i, g, this._material._m);
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
	class ShaderMaterial {
		constructor(options) {
			if (options === null || typeof options !== 'object') {
				throw new TypeError('new three.ShaderMaterial({ fragment, uniforms }) wants an options object');
			}
			const { fragment, uniforms = {} } = options;
			if (typeof fragment !== 'string' || fragment.trim().length === 0) {
				throw new TypeError('a ShaderMaterial needs a `fragment` body — see three.getApiDocs()');
			}
			if (uniforms === null || typeof uniforms !== 'object') {
				throw new TypeError('`uniforms` wants an object like { tint: [1, 0.5, 0.2], time: 0 }');
			}

			// The enumeration happens here because it cannot happen in the host:
			// the QuickJS shim exposes property *get* by name and nothing that
			// lists keys. So the names cross as a joined string — see
			// js/bind_shader.c3.
			const names = Object.keys(uniforms);
			const widths = names.map(n => ShaderMaterial._width(n, uniforms[n]));

			this._m = H.createMaterial(fragment, names.join(','), widths.join(','));
			this.fragment = fragment;

			// A Proxy rather than accessors on a sealed object, because a script is
			// not evaluated in strict mode: assigning an unknown property to a
			// sealed object *silently does nothing* there, so `mat.uniforms.tnit =
			// [0, 1, 0]` would be a no-op that renders unchanged and reads like a
			// shader bug. A set trap throws either way. Measured, not assumed —
			// the sealed version was written first and
			// `an_undeclared_uniform_cannot_be_assigned` caught it.
			this._values = {};
			const declared = new Set(names);
			const owner = this;
			this.uniforms = new Proxy({}, {
				get(_, name) { return owner._values[name]; },
				has(_, name) { return declared.has(name); },
				ownKeys() { return [...declared]; },
				getOwnPropertyDescriptor(_, name) {
					if (!declared.has(name)) return undefined;
					return { enumerable: true, configurable: true, value: owner._values[name] };
				},
				set(_, name, v) {
					if (!declared.has(name)) {
						throw new TypeError(
							`this material has no uniform called '${String(name)}' — it declared ${[...declared].join(', ') || 'none'}`
						);
					}
					owner._set(name, v);
					return true;
				},
			});
			for (const name of names) this._set(name, uniforms[name]);
		}

		static _width(name, v) {
			if (typeof v === 'number') return 1;
			if (Array.isArray(v) && v.length >= 1 && v.length <= 4) return v.length;
			throw new TypeError(
				`uniform '${name}' wants a number or an array of up to four numbers`
			);
		}

		_set(name, v) {
			const n = typeof v === 'number' ? [v] : v;
			if (!Array.isArray(n) || n.length < 1 || n.length > 4) {
				throw new TypeError(`uniform '${name}' wants a number or an array of up to four numbers`);
			}
			for (const c of n) {
				if (!Number.isFinite(+c)) {
					throw new TypeError(`uniform '${name}' was given a non-finite value`);
				}
			}
			H.setUniform(this._m, name, +n[0], +(n[1] ?? 0), +(n[2] ?? 0), +(n[3] ?? 0), n.length);
			this._values[name] = typeof v === 'number' ? +v : n.map(Number);
		}

		toJSON() {
			return { fragment: this.fragment, uniforms: { ...this._values } };
		}
	}

	class Mesh extends Object3D {
		constructor(ref) {
			super();
			if (!ref || typeof ref.asset !== 'number' || typeof ref.mesh !== 'number') {
				throw new TypeError('new three.Mesh(ref) wants a mesh reference from asset.mesh(name)');
			}
			this._mesh = ref;
			this._name = ref.name ?? '';
			this._material = null;
		}

		_ref() { return this._mesh; }
		get geometry() { return this._mesh; }

		// Assignable before the mesh is in a scene, like `name` and `visible`, and
		// replayed by `_materialize` for the same reason: an object is a detached
		// description until it is added, and a script that sets up a mesh and then
		// adds it must not lose the setup.
		get material() { return this._material; }
		set material(v) {
			if (v !== null && !(v instanceof ShaderMaterial)) {
				throw new TypeError('mesh.material wants a three.ShaderMaterial, or null for the default');
			}
			this._material = v;
			if (this._i >= 0) H.setMaterial(this._i, this._g, v === null ? 0 : v._m);
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
		ShaderMaterial,
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

		// What `scene.pick(x, y)` counts in, and what the PNG comes back as.
		// It is the offscreen target's, never a window's (`plan.md` §1).
		renderSize() {
			const [width, height] = H.renderSize();
			return { width, height };
		},

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
			'ShaderMaterial takes a fragment function, not a whole program: you write float3 shade(Surface s) and three.c3 supplies the vertex stage, the Surface and the uniform block. Uniforms are flat values, not Three.js\'s { value } wrappers.',
			'A mesh with no material draws with the base colour and texture its glTF material carried.',
			'There is no Raycaster. scene.pick(x, y) takes pixels of the rendered image and scene.raycast(origin, direction) takes a world ray; both answer with the closest hit or null, not with an array.',
			'Each run_script call runs in its own function scope. Use globalThis to keep state between calls.',
			'Return a value from your script with `return`; it comes back as the `value` field.',
		],
		classes: {
			Scene: {
				construct: 'new three.Scene()',
				note: 'Empties the one host scene and becomes its root. It is an Object3D, so moving it moves everything.',
				methods: [
					'add(...objects)', 'remove(...objects)', 'traverse(fn)', 'getObjectByName(name)', 'stats()',
					'pick(x, y)', 'raycast(origin, direction)', 'getWorldPosition()', 'toJSON()',
				],
				properties: ['position', 'rotation', 'scale', 'visible', 'name', 'children', 'parent'],
			},
			Mesh: {
				construct: 'new three.Mesh(assetRef)',
				note: 'assetRef comes from asset.mesh(name) or asset.meshAt(i). N meshes sharing one ref is one draw call.',
				properties: [
					'position', 'rotation', 'scale', 'visible', 'name', 'geometry', 'material', 'children', 'parent',
				],
				methods: ['add(...)', 'remove(...)', 'traverse(fn)', 'getObjectByName(name)', 'getWorldPosition()', 'toJSON()'],
			},
			ShaderMaterial: {
				construct: "new three.ShaderMaterial({ fragment, uniforms })",
				note:
					'fragment is a Slang function `float3 shade(Surface s)` returning linear rgb. '
					+ 'Surface has albedo, normal, uv and position, all world space. Each uniform is readable '
					+ 'in the body by its own name. Compiles on construction, so a bad shader throws here, '
					+ 'carrying the Slang diagnostic with the line number you wrote. Needs a GPU device.',
				properties: ['uniforms (live: mat.uniforms.tint = [1, 0, 0])', 'fragment'],
				methods: ['toJSON()'],
			},
			Group: {
				construct: 'new three.Group()',
				note: 'Transforms its children and draws nothing itself.',
				methods: [
					'add(...)', 'remove(...)', 'traverse(fn)', 'getObjectByName(name)', 'getWorldPosition()',
					'toJSON()',
				],
				properties: ['position', 'rotation', 'scale', 'visible', 'name', 'children', 'parent'],
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
				properties: ['path', 'meshes (names, in load order)'],
				methods: ['mesh(name)', 'meshAt(index)', 'toJSON()'],
			},
		},
		functions: {
			'three.load(path)': 'Load a .glb or .gltf. Loading the same path twice returns the same asset.',
			'three.render(scene, camera)': 'Draw one frame. camera is optional and must be three.camera.',
			'three.stats()': 'The numbers below, for the whole scene, with culling off.',
			'three.renderSize()': '{ width, height } of the offscreen image — what pick() counts in and what the returned PNG is.',
			'three.getApiDocs()': 'This.',
			'toJSON() / toString()':
				'What JSON.stringify sees, and therefore what comes back in the `value` field when you '
				+ 'return an object from a script. Objects report their name, transform and children; a '
				+ 'Vector3 reports [x, y, z]; a ShaderMaterial reports its fragment and uniforms.',
			'new three.ShaderMaterial({ fragment, uniforms })':
				'Compile a fragment function into a material. Uniforms are at most 68 bytes in total '
				+ '(17 floats); each is a number or an array of up to four numbers.',
			'mesh.material':
				'Assign a ShaderMaterial, or null for the default shader. Meshes sharing a mesh ref AND a '
				+ 'material are one draw call; giving two of them different materials makes two.',
			'material.uniforms.<name>':
				'Read or write a uniform. Writing takes effect on the next render. Only names declared at '
				+ 'construction exist; assigning to any other name throws.',
			'scene.pick(x, y)':
				'What is under a pixel of the rendered image, counted from its top-left corner. ' +
				'Answers with an intersection (below) or null. Needs a GPU device.',
			'scene.raycast(origin, direction)':
				'What a world-space ray hits. Either vector may be a Vector3, an {x, y, z} or an [x, y, z], ' +
				'and the direction need not be normalised. Answers with an intersection (below) or null.',
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
		intersection: {
			object: 'The Mesh that was hit. Null only for a node this script did not build — one opened from the command line.',
			name: 'Its name, which identifies it even when object is null.',
			distance: 'World units along the ray. Comparable across objects however each of them is scaled.',
			point: 'Where the ray met the surface, world space, as a Vector3.',
			normal: 'The surface normal there, world space, unit length.',
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
