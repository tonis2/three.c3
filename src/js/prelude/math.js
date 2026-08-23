// three.c3 — vectors, boxes, and the value readers everything else checks with.
//
// The bottom of the prelude's import graph: this module imports nothing, so
// it is the first to evaluate and the right place for the one guard that
// says the host bindings are missing.

const H = globalThis.__three;
if (!H) throw new Error('three.c3: the host bindings are missing');

// -----------------------------------------------------------------------
// Vector3

// A live component vector. `owner` is the Object3D it belongs to, or null
// for a detached one (what `getWorldPosition` hands back) — a detached
// vector is an ordinary value and writing to it changes nothing else.
export class Vector3 {
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
export class Box3 {
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

export function axisIndex(axis, where) {
	const i = { x: 0, y: 1, z: 2, X: 0, Y: 1, Z: 2 }[axis];
	if (i === undefined) {
		throw new TypeError(`${where} wants an axis of 'x', 'y' or 'z', not ${JSON.stringify(axis)}`);
	}
	return i;
}

export function boxFromSix(six) {
	return six === null ? null : new Box3(six[0], six[1], six[2], six[3], six[4], six[5]);
}

// A mesh reference's own box, in the mesh's local space.
//
// Not cached. The numbers never change for a live asset, but caching them
// would mean a reference outliving an `unloadUnused()` kept answering with
// what used to be true — and every other handle in this API revalidates on
// use rather than trusting a copy. The host reads it out of the glTF JSON,
// so this costs no upload.
export function refBounds(ref, where) {
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
export function transformBox(box, position, rotation, scale) {
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
export const DEFAULT_BACKGROUND = [0.10, 0.11, 0.13];

// Read a colour out of whatever the script had to hand: `[r, g, b]`,
// `[r, g, b, a]`, `{ r, g, b }`, or Three.js's hex — `0xff8800`.
//
// **The components are what the pixel gets, and there is no colour
// management anywhere in this project.** A hex value is therefore divided by
// 255 and not de-gamma'd: `mesh.color = 0xff8800` renders the byte values it
// spells, which is also what `base_color` out of a glTF does. Three.js
// converts sRGB to linear on the way in and back on the way out, and doing
// half of that here would be worse than doing neither.
export function readColor(v, where) {
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
export function readVector(v, where) {
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

// A [u, v] pair out of an array or an {x, y}. The two-component sibling of
// asTriple, for the texture-space properties: uvs are named u and v and a
// caller who wrote {x, y} meant the same thing, so both are taken.
export function asPair(value, where) {
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

export function asTriple(value, where) {
	const triple = Array.isArray(value) ? value
		: (value && typeof value === 'object') ? [value.x, value.y, value.z]
		: null;
	if (triple === null || triple.some(n => !Number.isFinite(Number(n)))) {
		throw new TypeError(`${where} wants [x, y, z] or a Vector3`);
	}
	return triple.map(Number);
}
