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
			const shapes = names.map(n => ShaderMaterial._shape(n, uniforms[n]));
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

			this._m = H.createMaterial(
				fragment,
				names.join(','),
				shapes.map(s => s[0]).join(','),
				shapes.map(s => s[1]).join(','),
			);
			this.fragment = fragment;
			this._rows = {};
			for (const [i, name] of names.entries()) this._rows[name] = shapes[i][1];

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
							`this material has no uniform called '${String(name)}' — it declared ${[...declared].join(', ') || 'none'}`
						);
					}
					owner._set(name, v);
					return true;
				},
			});
			for (const name of names) this._set(name, uniforms[name]);
		}

		// A uniform's shape: how many floats wide, and how many rows.
		//
		// `[1, 0, 0]` is one row of three. `[[1, 0, 0], [0, 1, 0]]` is two rows
		// of three — a **column of the material's table**, indexed in the shader
		// by `s.variant`, which each mesh sets for itself. That is what lets one
		// material give a thousand copies four different looks in one draw call.
		static _shape(name, v) {
			if (typeof v === 'number') return [1, 1];
			if (Array.isArray(v) && v.length >= 1 && v.length <= 4 && v.every(c => typeof c === 'number')) {
				return [v.length, 1];
			}
			if (Array.isArray(v) && v.length >= 1 && v.every(Array.isArray)) {
				const width = v[0].length;
				if (!(width >= 1 && width <= 4)) {
					throw new TypeError(`uniform '${name}': each row is a number or up to four numbers`);
				}
				if (v.some(row => row.length !== width)) {
					throw new TypeError(`uniform '${name}': every row of a table has to be the same width, and the first is ${width}`);
				}
				return [width, v.length];
			}
			throw new TypeError(
				`uniform '${name}' wants a number, an array of up to four numbers, or an array of those for a table`
			);
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
			const n = typeof v === 'number' ? [v] : v;
			if (!Array.isArray(n) || n.length < 1 || n.length > 4) {
				throw new TypeError(`uniform '${name}' wants a number or an array of up to four numbers`);
			}
			for (const c of n) {
				if (!Number.isFinite(+c)) {
					throw new TypeError(`uniform '${name}' was given a non-finite value`);
				}
			}
			H.setUniform(
				this._m, name,
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
			return { fragment: this.fragment, uniforms: { ...this._values } };
		}
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
			if (!geometry || typeof geometry.asset !== 'number' || typeof geometry.mesh !== 'number') {
				throw new TypeError(
					'new three.Mesh(geometry) wants a shape like new three.BoxGeometry(1, 1, 1), '
					+ 'or a mesh reference from asset.mesh(name)'
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
		constructor(type, name, parameters, asset) {
			this.type = type;
			this.name = name;
			this.parameters = parameters;
			this.asset = asset;
			// A generated shape is one mesh, always. Named `mesh` because that is
			// what an asset reference calls it, which is what lets Mesh take both.
			this.mesh = 0;
		}

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
		ShaderMaterial,
		camera,

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

		getApiDocs() { return DOCS; },
	};

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
			'Geometry is BoxGeometry, SphereGeometry, PlaneGeometry, CylinderGeometry, ConeGeometry, TorusGeometry and ConvexGeometry, built for you with Three.js\'s signatures, defaults and orientations. There is no BufferGeometry, no attribute access and no way to read or write a vertex — that refusal is what makes every scene one instanced draw per unique shape.',
			'new three.ConvexGeometry(points) is the way to make a shape that is not one of the six parametric ones: hand over a cloud of points and get its convex hull. Rocks, crystals, gems, debris, the bound of a scan. It takes Vector3s, [x, y, z]s or a flat array of coordinates, needs at least 4 points, is capped at 65536, and is flat shaded with no uvs because a hull has hard creases and no natural unwrap. The points are a description the hull is computed from, not the mesh\'s vertices — most of them are discarded and none can be read back.',
			'Two geometries with the same numbers are ONE asset and one draw call, however many times you construct them. Two different sizes are two. Prefer mesh.scale over a new size when you want variety cheaply.',
			'new three.Mesh(geometry, material) takes either a generated shape or asset.mesh(name); material is optional, as in Three.js.',
			'mesh.color and mesh.variant are the ONLY two things copies sharing a geometry and a material may differ in without becoming separate draw calls. A thousand meshes in a thousand colours is one call; giving two of them different materials is two. There is no InstancedMesh because every mesh is already an instance.',
			'A ShaderMaterial uniform may be a table — { palette: [[1,0,0], [0,1,0]] } becomes float3 palette[2] and mesh.variant picks the row. That is how one material gives many meshes many looks. s.variant is clamped to the table, so an index past the end is the last row.',
			'Colours are linear rgb in 0..1 (hex is divided by 255, not de-gamma\'d): there is no colour management here, and half of one would be worse than none.',
			'There is one scene at a time. new three.Scene() empties it, and handles into the previous scene throw.',
			'There is one camera, a turntable: three.camera.orbit(yaw, pitch, distance) and three.camera.frameAll(). camera.position does not exist.',
			'An object is not in the scene until it is add()ed, and removing it makes it a detached description that can be added again.',
			'ShaderMaterial takes a fragment function, not a whole program: you write float3 shade(Surface s) and three.c3 supplies the vertex stage, the Surface and the uniform block. Uniforms are flat values, not Three.js\'s { value } wrappers.',
			'A mesh with no material draws with the base colour and texture its glTF material carried.',
			'There is no Raycaster. scene.pick(x, y) takes pixels of the rendered image and scene.raycast(origin, direction) takes a world ray; both answer with the closest hit or null, not with an array.',
			'Each run_script call runs in its own function scope. Use globalThis to keep state between calls.',
			'three.setAnimationLoop(fn) runs fn once per frame, with the elapsed milliseconds, until three.setAnimationLoop(null). It is how a scene moves without an agent in the loop. The callback must be synchronous, is stopped for good if it throws or runs longer than 100ms in one frame, and what it logs comes back with the next run_script under an [animation loop] marker.',
			'A running animation loop makes render() and screenshot() no longer repeatable — the scene has moved between them. setAnimationLoop(null) stops the clock so a known state can be captured.',
			'There is a keyboard, which Three.js has no equivalent of at all: three.input.isDown(key) for held keys, three.input.pressed(key)/released(key) for this frame\'s edges, and three.onKeyDown(key, fn)/onKeyUp(key, fn) to bind an action. Key names are the browser\'s KeyboardEvent.key lowercased — three.input.keys() lists every one. It only reports anything while a window is open: --headless has no keyboard.',
			'Keys are read once per frame, so three.input.pressed() and three.input.text mean something inside the animation callback and almost never outside one. isDown() is fine anywhere.',
			'There is a mouse, and it is one thing: three.onClick(fn) calls fn(hit, x, y) with what is under the cursor already picked. three.input.pointer is where the cursor is. There is no mouseDown and no drag events — the left button orbits the camera, and a press that travels or is held is a drag rather than a click.',
			'three.input.pointer and the click are in the rendered image\'s pixels, not the window\'s. The window shows the image stretched to fit it, so the two differ on a retina display and after any resize; scene.pick(x, y) and the PNG use the same pixels the click does, whatever size the window is.',
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
				construct: 'new three.Mesh(geometry, material)',
				note:
					'geometry is a generated shape (new three.BoxGeometry(1, 1, 1)) or a reference from '
					+ 'asset.mesh(name) / asset.meshAt(i). material is optional. N meshes sharing one geometry '
					+ 'AND one material is one draw call.',
				properties: [
					'position', 'rotation', 'scale', 'visible', 'name', 'geometry', 'material', 'children', 'parent',
					'color (per copy, free: [r,g,b], [r,g,b,a] or 0xff8800)',
					'variant (per copy, free: which row of the material\'s table)',
				],
				methods: ['add(...)', 'remove(...)', 'traverse(fn)', 'getObjectByName(name)', 'getWorldPosition()', 'toJSON()'],
			},
			ShaderMaterial: {
				construct: "new three.ShaderMaterial({ fragment, uniforms })",
				note:
					'fragment is a Slang function `float3 shade(Surface s)` returning linear rgb. '
					+ 'Surface has albedo, normal, uv, position, color (this copy\'s own, already in albedo) '
					+ 'and variant (its row of the table, clamped). Each uniform is readable in the body by '
					+ 'its own name; a uniform written as an array of arrays is a table column, read as '
					+ 'name[s.variant]. Compiles on construction, so a bad shader throws here, carrying the '
					+ 'Slang diagnostic with the line number you wrote. Needs a GPU device.',
				properties: [
					'uniforms (live: mat.uniforms.tint = [1, 0, 0], or mat.uniforms.palette[2] = [1, 0, 0])',
					'fragment',
				],
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
				properties: ['type', 'name', 'parameters (what you asked for, defaults filled in)', 'asset', 'mesh'],
				methods: ['toJSON()', 'toString()'],
			},
			BoxGeometry: {
				construct:
					'new three.BoxGeometry(width = 1, height = 1, depth = 1, widthSegments = 1, heightSegments = 1, depthSegments = 1)',
				note: 'A box centred on the origin. The segment counts subdivide it and change nothing about its size.',
				methods: ['toJSON()', 'toString()'],
			},
			SphereGeometry: {
				construct: 'new three.SphereGeometry(radius = 1, widthSegments = 32, heightSegments = 16)',
				note: 'A UV sphere with its poles on the Y axis.',
				methods: ['toJSON()', 'toString()'],
			},
			PlaneGeometry: {
				construct: 'new three.PlaneGeometry(width = 1, height = 1, widthSegments = 1, heightSegments = 1)',
				note:
					'A one-sided rectangle in the XY plane, facing +Z — Three.js\'s orientation, which is '
					+ 'vertical. A floor is this with rotation.x = -Math.PI / 2. From behind it is invisible, '
					+ 'because back faces are culled.',
				methods: ['toJSON()', 'toString()'],
			},
			CylinderGeometry: {
				construct:
					'new three.CylinderGeometry(radiusTop = 1, radiusBottom = 1, height = 1, radialSegments = 32, heightSegments = 1, openEnded = false)',
				note: 'A cylinder or a truncated cone about the Y axis. Either radius may be 0, but not both.',
				methods: ['toJSON()', 'toString()'],
			},
			ConeGeometry: {
				construct:
					'new three.ConeGeometry(radius = 1, height = 1, radialSegments = 32, heightSegments = 1, openEnded = false)',
				note:
					'A cone about the Y axis with its point up. The same triangles as '
					+ 'CylinderGeometry(0, radius, height) — and the same asset, so the two spellings share a draw call.',
				methods: ['toJSON()', 'toString()'],
			},
			TorusGeometry: {
				construct: 'new three.TorusGeometry(radius = 1, tube = 0.4, radialSegments = 12, tubularSegments = 48)',
				note:
					'A ring in the XY plane. radius is measured to the centre of the tube, so the shape is '
					+ '2 * (radius + tube) across and 2 * tube thick.',
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
				methods: ['toJSON()', 'toString()'],
			},
		},
		functions: {
			'three.load(path)': 'Load a .glb or .gltf. Loading the same path twice returns the same asset.',
			'three.render(scene, camera)': 'Draw one frame. camera is optional and must be three.camera.',
			'three.stats()': 'The numbers below, for the whole scene, with culling off.',
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
			'new three.ShaderMaterial({ fragment, uniforms })':
				'Compile a fragment function into a material. Uniforms are at most 68 bytes in total '
				+ '(17 floats); each is a number or an array of up to four numbers.',
			'mesh.material':
				'Assign a ShaderMaterial, or null for the default shader. Meshes sharing a mesh ref AND a '
				+ 'material are one draw call; giving two of them different materials makes two.',
			'material.uniforms.<name>':
				'Read or write a uniform. Writing takes effect on the next render. Only names declared at '
				+ 'construction exist; assigning to any other name throws. A uniform declared as a table is '
				+ 'written a row at a time — material.uniforms.palette[1] = [0, 1, 0] — or all at once.',
			'mesh.color':
				'This copy\'s own tint, multiplied into albedo. [r, g, b], [r, g, b, a], {r, g, b} or a hex '
				+ 'number like 0xff8800. Costs no draw call: copies of one mesh may all differ. Works with no '
				+ 'material at all, and reaches a shade() body as s.color with albedo already tinted.',
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
