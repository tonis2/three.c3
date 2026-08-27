// three.c3 — ShaderMaterial, and the uniform and sampler proxies it shares
// with the post chain.

import { Texture } from './texture.js';
import { FrontSide, NoTexture, Material } from './material.js';

const H = globalThis.__three;

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
export function uniformShape(name, v, tables = true) {
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
export function uniformValues(name, v) {
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
export function uniformsProxy(owner, declared, what) {
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
export function textureLists(textures, what) {
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
export function texturesProxy(owner, declared, what) {
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
export class ShaderMaterial extends Material {
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
			: (vertex ? 'float3 shade(Surface s) { return standard(s); }' : options.fragment);
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
		// A body that never calls `specular(s)` or `standard(s)` is unaffected by
		// these, which is why they are accepted rather than refused on a material
		// whose shading is the agent's: they are three numbers on the surface, and
		// what reads them is the body.
		Material._applySurface(this, options);
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
