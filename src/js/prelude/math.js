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


// -----------------------------------------------------------------------
// Damping — notes.md §17
//
// The two verbs a game reaches for between "where it is" and "where it
// should be", and both are here rather than on the host for the reason
// notes.md §17 measured: a host call that allocates in order to answer
// arithmetic costs 185 ns against the 70 ns of the JavaScript it replaced,
// and it costs that on every call forever. These are four multiplies.
//
// **They are the frame-rate-independent forms, and that is the whole
// point of naming them.** The version everybody writes by hand is
// `x += (target - x) * 0.1`, which closes a tenth of the gap per FRAME —
// so it is twice as fast on a 120 Hz display as on a 60 Hz one, and a
// chase that felt right while it was being tuned is loose on one machine
// and snappy on another. Nothing about that reads as a bug: the game just
// feels different, and the difference is not reproducible on the machine
// it was tuned on. `CameraFollow.apply` in `scene/camera.c3` is the same
// arithmetic on the host side and carries the same argument.

// Move `current` towards `target` by a fixed fraction of the remaining
// distance PER SECOND rather than per frame.
//
// `lambda` is the rate: the gap decays by e^-lambda every second, so 1 is
// lazy, 5 is a normal follow and 20 is nearly rigid. `dt` is in seconds —
// `three.clock.dt / 1000`, because the clock reports milliseconds.
//
// Three.js spells this `MathUtils.damp(x, y, lambda, dt)` and means the
// same thing by it.
export function damp(current, target, lambda, dt) {
	const c = +current, t = +target;
	if (!(Number.isFinite(c) && Number.isFinite(t))) {
		throw new TypeError('three.damp(current, target, lambda, dt) wants finite numbers');
	}
	const rate = +lambda, step = +dt;
	// A non-positive step is no time at all, so nothing has had a chance to
	// decay — the honest answer is the value that went in. A non-positive
	// lambda is "no damping", which is the same answer for the same reason.
	if (!(rate > 0) || !(step > 0)) return c;
	return t + (c - t) * Math.exp(-rate * step);
}

// `damp` for an angle in radians, taking the short way round.
//
// The straight one is wrong at exactly one place and that place is the one
// a mouse look crosses constantly: a heading of +3.1 damping towards -3.1
// is 0.08 radians apart the short way and 6.2 the long way, and `damp`
// takes the long way — the character spins a full turn to arrive at a
// heading it was already almost at. Wrapping the DIFFERENCE rather than
// the inputs is what fixes it, and it is why this is a separate verb
// instead of an option: a caller damping a distance must not get angle
// wrapping by accident.
export function dampAngle(current, target, lambda, dt) {
	const c = +current;
	if (!Number.isFinite(c) || !Number.isFinite(+target)) {
		throw new TypeError('three.dampAngle(current, target, lambda, dt) wants finite numbers');
	}
	const TAU = Math.PI * 2;
	let delta = (+target - c) % TAU;
	if (delta > Math.PI) delta -= TAU;
	if (delta < -Math.PI) delta += TAU;
	return damp(c, c + delta, lambda, dt);
}

// A critically damped spring — Unity's `SmoothDamp`, and the one to reach
// for when `damp` overshoots the feel you wanted.
//
// The difference from `damp` is that this one has MOMENTUM. `damp` is a
// pure decay: it is fastest at the start and asymptotically slow at the
// end, which is right for a camera easing onto a target and wrong for
// anything that should look like it was accelerated — a turret slewing, a
// dial spinning up, a menu sliding. A critically damped spring builds
// speed, carries it, and arrives without ringing.
//
// **The velocity is state, and the caller owns it.** That is what the
// `state` argument is: any object, and this writes `state.velocity` into
// it. It has to persist across frames — a `state` created inside the loop
// is a spring that is re-launched from rest sixty times a second, which
// looks exactly like `damp` with a worse constant and is the one way to
// use this and see nothing.
//
//     const spin = { velocity: 0 };
//     three.setAnimationLoop(() => {
//         angle = three.smoothDamp(angle, want, spin, 0.3, three.clock.dt / 1000);
//     });
//
// `smoothTime` is roughly how long the move takes, in seconds. `maxSpeed`
// caps it in units per second and defaults to no cap.
export function smoothDamp(current, target, state, smoothTime, dt, maxSpeed = Infinity) {
	const where = 'three.smoothDamp(current, target, state, smoothTime, dt, maxSpeed)';
	const c = +current;
	let t = +target;
	if (!(Number.isFinite(c) && Number.isFinite(t))) throw new TypeError(`${where} wants finite numbers`);
	if (state === null || typeof state !== 'object') {
		throw new TypeError(`${where}: state is an object this writes .velocity into, and it must OUTLIVE the frame`);
	}
	const step = +dt;
	if (!(step > 0)) return c;

	// Guarded rather than clamped to zero: a smoothTime of 0 is a divide by
	// zero two lines down and a NaN that spreads into whatever this drives,
	// and the failure reads as the object disappearing.
	const time = Math.max(1e-4, +smoothTime);
	let velocity = +(state.velocity ?? 0);
	if (!Number.isFinite(velocity)) velocity = 0;

	// The standard critically-damped step: omega is the natural frequency,
	// and the cubic is a Padé approximation of e^-x that is cheaper and, at
	// the step sizes a frame produces, indistinguishable.
	const omega = 2 / time;
	const x = omega * step;
	const decay = 1 / (1 + x + 0.48 * x * x + 0.235 * x * x * x);

	let delta = c - t;
	const cap = +maxSpeed;
	if (Number.isFinite(cap) && cap > 0) {
		const reach = cap * time;
		delta = Math.max(-reach, Math.min(reach, delta));
	}
	// The target the spring is actually pulled to, after the cap moved it.
	t = c - delta;

	const accel = (velocity + omega * delta) * step;
	velocity = (velocity - omega * accel) * decay;
	let out = t + (delta + accel) * decay;

	// Overshoot guard. Without it a large dt can put the value past the
	// target with velocity still pointing further past it, and the spring
	// runs away instead of settling — the one failure mode of this
	// approximation, and it happens on exactly the frames a tool call ran
	// long.
	if ((+target - c > 0) === (out > +target)) {
		out = +target;
		velocity = (out - +target) / step;
	}

	state.velocity = velocity;
	return out;
}

// -----------------------------------------------------------------------
// CatmullRomCurve3 — notes.md §17
//
// The three-dimensional half of the curve pair. `three.catmullRom` in
// field.js is a GROUND path: [x, z] in, a dense polyline out, built to be
// handed straight to field.carve, field.stroke, a scatter corridor or a
// RibbonGeometry. This is the gameplay one — a camera rail, a patrol
// route, a projectile arc, a rope — where the y matters and where the
// caller wants to ask "where am I at t" every frame rather than to be
// handed an array once.
//
// So the two differ in what they RETURN, which is the reason there are
// two of them and not one with a flag. A polyline is a description a
// bake consumes; this is an object a loop samples.
//
// Three.js's name, constructor and method names, because that is what an
// agent will write from memory: getPoint(t), getPointAt(u), getTangent(t),
// getLength(), getPoints(n), getSpacedPoints(n).
//
// **getPoint and getPointAt are not the same function**, and the gap
// between them is the thing that makes hand-written curve code look
// wrong. `t` is the curve's own parameter and is spread evenly over the
// CONTROL SEGMENTS, so an object moving at a constant `t` per second
// speeds up through the widely spaced ones and crawls through the close
// ones. `u` is spread evenly over the LENGTH. A camera on a rail wants
// getPointAt; nothing much wants getPoint except another curve.
export class CatmullRomCurve3 {
	// `closed` joins the last point back to the first. `curveType` is
	// 'centripetal' (the default, and Three.js's), 'chordal' or 'uniform' —
	// field.js's catmullRom carries the argument for why centripetal.
	constructor(points, closed = false, curveType = 'centripetal', tension = 0.5) {
		const where = 'new three.CatmullRomCurve3(points, closed, curveType, tension)';
		if (!Array.isArray(points)) throw new TypeError(`${where} wants an array of points`);
		this.points = points.map((p, i) => {
			const v = readVector(p, `${where}: point ${i}`);
			return new Vector3(null, v[0], v[1], v[2]);
		});
		if (this.points.length < 2) {
			throw new RangeError(`${where}: a curve needs at least 2 control points, got ${this.points.length}`);
		}
		if (!['centripetal', 'chordal', 'uniform'].includes(curveType)) {
			throw new RangeError(`${where}: curveType is 'centripetal', 'chordal' or 'uniform', got ${JSON.stringify(curveType)}`);
		}
		this.closed = !!closed;
		this.curveType = curveType;
		this.tension = +tension;
		this._arc = null;
	}

	// The control point at `i`, with the ends handled by whichever rule
	// `closed` chose: wrapped for a loop, and the end point repeated for an
	// open curve so a segment at the edge has a real neighbour to lean
	// against instead of an index to clamp.
	_control(i) {
		const n = this.points.length;
		if (this.closed) return this.points[((i % n) + n) % n];
		return this.points[Math.max(0, Math.min(n - 1, i))];
	}

	get _segments() { return this.closed ? this.points.length : this.points.length - 1; }

	// Position at the curve parameter, t in [0, 1].
	getPoint(t) {
		const segments = this._segments;
		let u = +t;
		if (!Number.isFinite(u)) throw new TypeError('curve.getPoint(t) wants a number in 0..1');
		u = Math.max(0, Math.min(1, u));
		const scaled = u * segments;
		// The last point is on the last segment's end, not on a segment that
		// does not exist — without the clamp, t = 1 indexes one past the end
		// and reads undefined.
		let index = Math.min(Math.floor(scaled), segments - 1);
		const local = scaled - index;
		return this._segment(index, local);
	}

	// One segment, evaluated with the same Barry–Goldman pyramid on a
	// non-uniform knot vector that field.js's catmullRom uses — see there
	// for why the knots are spaced by chord length raised to alpha.
	_segment(index, local) {
		const p0 = this._control(index - 1);
		const p1 = this._control(index);
		const p2 = this._control(index + 1);
		const p3 = this._control(index + 2);

		const alpha = this.curveType === 'chordal' ? 1 : (this.curveType === 'uniform' ? 0 : 0.5);
		const span = (a, b) => Math.pow(Math.hypot(b.x - a.x, b.y - a.y, b.z - a.z), alpha);
		const t0 = 0;
		const t1 = t0 + Math.max(1e-6, span(p0, p1));
		const t2 = t1 + Math.max(1e-6, span(p1, p2));
		const t3 = t2 + Math.max(1e-6, span(p2, p3));
		const at = t1 + (t2 - t1) * local;

		const blend = (u, v, tu, tv) => (tv - tu < 1e-12) ? u : ((tv - at) * u + (at - tu) * v) / (tv - tu);
		const axis = (k) => {
			const A1 = blend(p0[k], p1[k], t0, t1);
			const A2 = blend(p1[k], p2[k], t1, t2);
			const A3 = blend(p2[k], p3[k], t2, t3);
			const B1 = blend(A1, A2, t0, t2);
			const B2 = blend(A2, A3, t1, t3);
			return blend(B1, B2, t1, t2);
		};
		return new Vector3(null, axis('x'), axis('y'), axis('z'));
	}

	// The unit direction of travel at t. Differenced rather than
	// differentiated: the analytic derivative of the non-uniform pyramid is
	// a page of algebra for a vector that is normalized immediately
	// afterwards, and the difference is exact to the precision anything
	// downstream can use.
	getTangent(t) {
		const step = 1e-4;
		const a = this.getPoint(Math.max(0, +t - step));
		const b = this.getPoint(Math.min(1, +t + step));
		const dx = b.x - a.x, dy = b.y - a.y, dz = b.z - a.z;
		const length = Math.hypot(dx, dy, dz);
		// A curve can genuinely stand still — two coincident control points —
		// and normalizing a zero vector is three NaNs that spread into
		// whatever this aims. +Z is the arbitrary answer, and it is a
		// direction rather than a hole.
		if (length < 1e-9) return new Vector3(null, 0, 0, 1);
		return new Vector3(null, dx / length, dy / length, dz / length);
	}

	// The arc-length table, built once and kept. `divisions` per segment is
	// how finely the length is measured; the default is fine enough that
	// getPointAt is within a fraction of a percent of even spacing on
	// anything a hand-written control path produces.
	_arcTable(divisions = 32) {
		if (this._arc !== null && this._arc.divisions === divisions) return this._arc;
		const steps = this._segments * divisions;
		const lengths = new Float64Array(steps + 1);
		let previous = this.getPoint(0);
		let total = 0;
		for (let i = 1; i <= steps; i++) {
			const point = this.getPoint(i / steps);
			total += Math.hypot(point.x - previous.x, point.y - previous.y, point.z - previous.z);
			lengths[i] = total;
			previous = point;
		}
		this._arc = { divisions, steps, lengths, total };
		return this._arc;
	}

	getLength() { return this._arcTable().total; }

	// Position at a constant SPEED along the curve, u in [0, 1]. See the
	// class header for why this is the one a moving object wants.
	getPointAt(u) {
		const table = this._arcTable();
		let want = Math.max(0, Math.min(1, +u)) * table.total;
		if (!(table.total > 0)) return this.getPoint(0);

		// Binary search for the sample the distance falls in, then linear
		// interpolation inside it.
		let low = 0, high = table.steps;
		while (low < high) {
			const mid = (low + high) >> 1;
			if (table.lengths[mid] < want) low = mid + 1; else high = mid;
		}
		const index = Math.max(1, low);
		const before = table.lengths[index - 1];
		const after = table.lengths[index];
		const inner = after - before < 1e-12 ? 0 : (want - before) / (after - before);
		return this.getPoint((index - 1 + inner) / table.steps);
	}

	// `count` points spread evenly in the curve parameter, as Three.js does:
	// count + 1 of them, both ends included.
	getPoints(count = 20) {
		const n = Math.max(1, Math.floor(+count));
		const out = [];
		for (let i = 0; i <= n; i++) out.push(this.getPoint(i / n));
		return out;
	}

	// The same, spread evenly in LENGTH. What to hand a RibbonGeometry or a
	// line helper when the cross-sections should be the same distance apart.
	getSpacedPoints(count = 20) {
		const n = Math.max(1, Math.floor(+count));
		const out = [];
		for (let i = 0; i <= n; i++) out.push(this.getPointAt(i / n));
		return out;
	}

	toString() { return `CatmullRomCurve3(${this.points.length} points, ${this.closed ? 'closed' : 'open'})`; }
}
