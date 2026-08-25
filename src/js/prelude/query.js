// three.c3 — bulk spatial queries, the character controller, and the batched
// transform write. `notes.md` §17.
//
// ## Two answer shapes, and which one to reach for
//
// Every verb here comes in a convenient form that allocates an array of
// Object3Ds, and a flat form that fills a buffer the caller keeps. That is not
// indecision: `notes.md` §17 measured the boundary and found that a host call
// answering with a scalar is CHEAPER than the JavaScript it replaces (55 ns
// against 70), while one that allocates to answer costs three times as much —
// so the cost of an answer is the allocation, and whether that matters depends
// entirely on how often the question is asked.
//
//     const near = three.query.sphere(p, 5);        // an Array — read it and move on
//
//     const buf = three.query.buffer(512);          // made once
//     const n = three.query.sphere(p, 5, buf);      // filled every frame, no garbage
//
// The first is right for a click, a spawn check, a one-off. The second is right
// for a hundred agents asking every frame, which is the case the index under
// all of this was built for.
import { Vector3, Box3, readVector } from './math.js';
import { liveObject, objectsForHandles, lazyObject } from './scene.js';

const H = globalThis.__three;

// How many nodes the convenient form will collect before it stops.
//
// A cap rather than a growing array, and the number is chosen to be obviously
// more than a question about a neighbourhood wants: past this the caller is
// asking about the whole level, and the flat form is what that question is for.
// `result.full` is how a script finds out it hit the cap rather than guessing
// from a suspiciously round count.
const DEFAULT_QUERY_CAPACITY = 256;

// A reusable answer: the flat handle pairs the host wrote, and how many of them
// mean anything.
//
// `handles` is the raw Int32Array — two ints per node, an index and a
// generation. A script that only wants to COUNT what is nearby never has to
// turn any of it into an object, which is most of why this shape exists.
export class QueryResult {
	constructor(capacity) {
		const slots = Math.max(1, Math.floor(+capacity));
		this.handles = new Int32Array(slots * 2);
		this.capacity = slots;
		this.count = 0;
	}

	// True when the query filled the buffer, which means there may be more it
	// could not tell you about. A count equal to the capacity is otherwise
	// indistinguishable from a scene that happened to have exactly that many.
	get full() { return this.count >= this.capacity; }

	// The objects, resolved in one walk of the scene — see objectsForHandles.
	// Nodes this scene never built an object for come back as null; a scene
	// opened from the command line is entirely made of those.
	objects() {
		return objectsForHandles(this.handles, this.count).filter(o => o !== null);
	}

	toString() { return `QueryResult(${this.count} of ${this.capacity})`; }
}

function readBox(value, where) {
	if (value instanceof Box3) return [value.min.x, value.min.y, value.min.z, value.max.x, value.max.y, value.max.z];
	if (Array.isArray(value) && value.length === 6) {
		const six = value.map(Number);
		if (six.some(n => !Number.isFinite(n))) throw new TypeError(`${where} was given a box with a non-finite corner`);
		return six;
	}
	if (value !== null && typeof value === 'object' && value.min && value.max) {
		const lo = readVector(value.min, `${where}.min`);
		const hi = readVector(value.max, `${where}.max`);
		return [lo[0], lo[1], lo[2], hi[0], hi[1], hi[2]];
	}
	throw new TypeError(`${where} wants a Box3, a { min, max }, or [minX, minY, minZ, maxX, maxY, maxZ]`);
}

// The shared buffer the convenient form fills before copying out of it.
// One per process, made on first use: the convenient form allocates its answer
// array anyway, so a second allocation for the scratch would be pure waste.
let scratch = null;
function scratchResult() {
	if (scratch === null) scratch = new QueryResult(DEFAULT_QUERY_CAPACITY);
	return scratch;
}

function finish(result, into) {
	// The flat form answers with the count and leaves the handles where the
	// caller can read them; the convenient form turns them into objects.
	return into === undefined || into === null ? result.objects() : result.count;
}

// How many nodes one sweep may be told to ignore — the host's MAX_IGNORED.
const MAX_IGNORED = 8;

// The handle pairs the host reads `ignore` out of.
//
// ONE array for the process, refilled per call. The host reads it synchronously
// while the sweep runs and never keeps it, so there is nothing to alias — and a
// character controller calls this once per character per fixed step, which is
// exactly where a two-element allocation per call turns into garbage nobody
// asked for.
const ignoreScratch = new Int32Array(MAX_IGNORED * 2);

// Fill the scratch from `ignore`, which is an object, an array of them, or
// nothing. Answers with how many pairs are in it.
//
// **A whole subtree is ignored, not one node**, so passing a character's Group
// is the thing to do — see the host's IgnoreSet. Objects past MAX_IGNORED throw
// rather than being dropped: a sweep quietly colliding with something it was
// told to pass through is a bug that looks like the controller misbehaving, and
// there is nothing a caller can do about it if they are not told.
function fillIgnore(value, where) {
	if (value === null || value === undefined) return 0;

	const many = Array.isArray(value) ? value : [value];
	if (many.length > MAX_IGNORED) {
		throw new RangeError(`${where} takes at most ${MAX_IGNORED} objects, not ${many.length} — ignoring an object ignores everything under it, so a whole character is one entry`);
	}

	let count = 0;
	for (const one of many) {
		if (one === null || one === undefined) continue;
		const [index, generation] = liveObject(one, where);
		ignoreScratch[count * 2] = index;
		ignoreScratch[count * 2 + 1] = generation;
		count++;
	}
	return count;
}

function hitObject(raw) {
	if (raw === null) return null;
	const hit = {
		name: raw.name,
		distance: raw.distance,
		fraction: raw.fraction,
		point: new Vector3(null, raw.point[0], raw.point[1], raw.point[2]),
		normal: new Vector3(null, raw.normal[0], raw.normal[1], raw.normal[2]),
	};
	return lazyObject(hit, 'object', Int32Array.from(raw.node), 0);
}

export const query = {
	// A result buffer to hand the flat form of every verb here. Make it once,
	// outside the loop.
	buffer(capacity = DEFAULT_QUERY_CAPACITY) { return new QueryResult(capacity); },

	// Everything whose bounding box overlaps a box.
	//
	// A BROAD-phase answer: it is box against box, so a node whose box overlaps
	// and whose triangles do not is included. That is the honest semantic for
	// "what is around here", and raycast or sweep is the narrow phase when one
	// is wanted.
	box(box, into) {
		const six = readBox(box, 'three.query.box(box)');
		const result = into ?? scratchResult();
		result.count = H.queryBox(
			six[0], six[1], six[2], six[3], six[4], six[5],
			// The length is in ints, not in node slots: the host takes an
			// element count and there are two per node.
			result.handles.buffer, result.handles.byteOffset, result.handles.length);
		return finish(result, into);
	},

	// Everything whose bounding box reaches within `radius` of a point. The
	// same broad-phase caveat as `box`.
	sphere(centre, radius, into) {
		const [x, y, z] = readVector(centre, 'three.query.sphere(centre, radius)');
		const r = +radius;
		if (!(Number.isFinite(r) && r >= 0)) {
			throw new RangeError(`three.query.sphere(centre, radius) wants a radius of zero or more, not ${radius}`);
		}
		const result = into ?? scratchResult();
		result.count = H.overlapSphere(
			x, y, z, r,
			result.handles.buffer, result.handles.byteOffset, result.handles.length);
		return finish(result, into);
	},

	// Every node a ray hits, not only the nearest — shooting through a window,
	// listing what is behind what, a laser that stops at the first SOLID thing
	// rather than at the first thing.
	//
	// **Not sorted by distance.** Sorting would mean holding every hit before
	// answering, which is the shape this whole layer avoids; a caller that
	// wants the nearest calls scene.raycast, which is cheaper than sorting
	// because it can stop walking.
	raycastAll(origin, direction, options = null) {
		const [ox, oy, oz] = readVector(origin, 'three.query.raycastAll(origin, direction)');
		const [dx, dy, dz] = readVector(direction, 'three.query.raycastAll(origin, direction)');
		const maxDistance = +(options?.maxDistance ?? 0);
		const limit = Math.floor(+(options?.limit ?? 64));
		return H.raycastAll(ox, oy, oz, dx, dy, dz, maxDistance, limit).map(hitObject);
	},

	// Move a sphere or an upright capsule from one point to another and report
	// the first thing it touches. `{ radius }` alone is a sphere; adding
	// `{ height }` makes it a capsule that tall overall.
	//
	// `fraction` on the hit is where along the motion it happened, so the safe
	// position is `from + (to - from) * fraction`.
	//
	// This is the same narrow phase `three.moveAndSlide` is built out of, so a
	// wall this reports and a wall a character slides along cannot be two
	// different walls.
	//
	// `ignore` takes an object or an array of them, and each one's whole
	// subtree is left out — see `three.moveAndSlide`.
	sweep(from, to, options = null) {
		const where = 'three.query.sweep(from, to, { radius, height, ignore })';
		const [fx, fy, fz] = readVector(from, where);
		const [tx, ty, tz] = readVector(to, where);
		const radius = +(options?.radius ?? 0.5);
		if (!(Number.isFinite(radius) && radius > 0)) {
			throw new RangeError(`${where} wants a positive radius, not ${options?.radius}`);
		}
		// `height` is the whole capsule, hemispheres included, because that is
		// what a person measuring a character measures. The host wants the
		// distance from the centre to a hemisphere's centre.
		const height = +(options?.height ?? 0);
		const half = Math.max((height - 2 * radius) * 0.5, 0);
		const ignored = fillIgnore(options?.ignore, `${where}: ignore`);
		return hitObject(H.sweep(
			fx, fy, fz, tx, ty, tz, radius, half,
			ignoreScratch.buffer, ignoreScratch.byteOffset, ignored * 2));
	},
};

// -----------------------------------------------------------------------
// The character controller — notes.md §17, and §7's first entry before it was built.

const MOVE_DEFAULTS = {
	radius: 0.3,
	height: 1.8,
	step: 0.35,
	slope: 50,
	skin: 0.02,
	snap: 0.3,
};

// Move a capsule through the scene's geometry, sliding along what it hits.
//
// **It takes a position and answers with a position.** It does not move an
// object, and that is deliberate: the capsule's centre and a character's origin
// are almost never the same point, a write would have to invert the parent's
// world matrix to land in local space, and an agent with no mesh yet could not
// be moved at all. Copying the answer onto whatever is being driven is one
// assignment and there is nothing to get wrong.
//
//     let feet = [0, 0, 0], vy = 0;
//     three.setAnimationLoop(() => {
//         const dt = three.clock.dt / 1000;
//         vy -= 9.8 * dt;
//         const motion = [move.x * dt, vy * dt, move.z * dt];
//         const r = three.moveAndSlide([feet[0], feet[1] + 0.9, feet[2]], motion, { ignore: player });
//         if (r.grounded) vy = 0;
//         feet = [r.position.x, r.position.y - 0.9, r.position.z];
//     });
//
// Options are `{ radius, height, step, slope, skin, snap, ignore }`. `height`
// is the whole capsule; `step` is how high a ledge may be and still be walked
// up; `slope` is the steepest ground in degrees that still counts as ground,
// and it decides `grounded`, whether a step-up is taken and whether a contact
// is a floor or a wall — one number, because three would disagree.
//
// **`ignore` takes an object or an array of them, and it ignores each one's
// whole SUBTREE.** Pass the character's Group and every mesh under it is out of
// the sweep — a character built out of a body, a head and four limbs used to
// collide with its own chest, because this took a single node. Up to eight, and
// a ninth throws rather than being quietly dropped. It is per call: a thing that
// should never be collision geometry for anybody is `object.collides = false`.
//
// It integrates nothing and remembers nothing between calls: gravity, velocity
// and the jump are the caller's.
export function moveAndSlide(position, motion, options = null) {
	const where = 'three.moveAndSlide(position, motion, options)';
	const [px, py, pz] = readVector(position, where);
	const [mx, my, mz] = readVector(motion, where);

	const radius = +(options?.radius ?? MOVE_DEFAULTS.radius);
	const height = +(options?.height ?? MOVE_DEFAULTS.height);
	if (!(Number.isFinite(radius) && radius > 0)) {
		throw new RangeError(`${where} wants a positive radius, not ${options?.radius}`);
	}
	const half = Math.max((height - 2 * radius) * 0.5, 0);
	const ignored = fillIgnore(options?.ignore, `${where}: ignore`);

	const raw = H.moveAndSlide(
		px, py, pz, mx, my, mz,
		radius, half,
		+(options?.step ?? MOVE_DEFAULTS.step),
		+(options?.slope ?? MOVE_DEFAULTS.slope),
		+(options?.skin ?? MOVE_DEFAULTS.skin),
		+(options?.snap ?? MOVE_DEFAULTS.snap),
		ignoreScratch.buffer, ignoreScratch.byteOffset, ignored * 2);

	// `ground` and `hit` are LAZY — see lazyObject. A walking character reads
	// grounded, slope and position every frame and looks at what it is standing
	// on almost never, and resolving both eagerly is two walks of the scene per
	// character per frame for numbers nobody asked for.
	const pairs = new Int32Array(4);
	pairs[0] = raw.ground ? raw.ground[0] : -1;
	pairs[1] = raw.ground ? raw.ground[1] : 0;
	pairs[2] = raw.hit ? raw.hit[0] : -1;
	pairs[3] = raw.hit ? raw.hit[1] : 0;

	const result = {
		position: new Vector3(null, raw.position[0], raw.position[1], raw.position[2]),
		remaining: new Vector3(null, raw.remaining[0], raw.remaining[1], raw.remaining[2]),
		normal: new Vector3(null, raw.normal[0], raw.normal[1], raw.normal[2]),
		grounded: raw.grounded,
		slope: raw.slope,
		stepped: raw.stepped,
		slides: raw.slides,
	};
	lazyObject(result, 'ground', pairs, 0);
	lazyObject(result, 'hit', pairs, 1);
	return result;
}

// -----------------------------------------------------------------------
// Batched transforms — notes.md §17

// Move many nodes in one crossing.
//
// **This is not a faster way to move a dozen things and should not be reached
// for as one.** `notes.md` §17 measured five hundred `mesh.position.set(x,y,z)`
// at 0.245 ms a frame — three per cent of the eight-millisecond budget — and
// set the trigger at about two thousand nodes a frame. Below that the ordinary
// property write is clearer and costs nothing anybody can see.
//
// What it is for is the case where the write is ALREADY a loop over numbers: a
// crowd whose positions come out of three.steer, a particle field, a chunked
// terrain.
//
//     const crowd = three.batch(agents);
//     three.setAnimationLoop(() => {
//         three.steer(crowd.positions, velocity, { field, maxSpeed: 3 });
//         for (let i = 0; i < velocity.length; i++) crowd.positions[i] += velocity[i] * dt;
//         crowd.flush();
//     });
//
// `positions` is a Float32Array of three floats per object, seeded from where
// the objects are now. With `{ trs: true }` the array is ten floats per object
// — position, an xyzw QUATERNION, then scale — because a batch is written by
// arithmetic and the arithmetic that produced a rotation produced a quaternion.
//
// A member that leaves the scene is skipped on flush rather than throwing: a
// crowd where one agent was removed this frame is ordinary, and abandoning the
// other nine hundred halfway through would be worse. `flush()` answers with how
// many actually landed.
export class TransformBatch {
	constructor(objects, options = null) {
		const where = 'three.batch(objects, { trs })';
		if (!Array.isArray(objects)) throw new TypeError(`${where} wants an array of scene objects`);

		this.trs = !!options?.trs;
		this.stride = this.trs ? 10 : 3;
		this.objects = objects.slice();
		this.handles = new Int32Array(objects.length * 2);
		this.data = new Float32Array(objects.length * this.stride);

		objects.forEach((object, i) => {
			const [index, generation] = liveObject(object, where);
			this.handles[i * 2] = index;
			this.handles[i * 2 + 1] = generation;
			// Seeded from where each object already is, so a batch made and
			// immediately flushed changes nothing. A zero-filled one would
			// teleport the whole crowd to the origin on its first flush, which
			// is a spectacular way to find out the array was not initialised.
			const at = i * this.stride;
			this.data[at] = object.position.x;
			this.data[at + 1] = object.position.y;
			this.data[at + 2] = object.position.z;
			if (this.trs) {
				// Identity rotation and unit scale: the object's own Euler
				// angles are not a quaternion and converting them here would
				// make `three.batch(objects, { trs: true })` silently rewrite
				// rotations the script had set by hand. A caller using the TRS
				// form is writing all ten numbers.
				this.data[at + 6] = 1;
				this.data[at + 7] = 1;
				this.data[at + 8] = 1;
				this.data[at + 9] = 1;
			}
		});
	}

	// The transform array, named for what is in it. `positions` reads better at
	// the call site than `data` and is the same memory.
	get positions() { return this.data; }

	get length() { return this.objects.length; }

	flush() {
		return H.setTransforms(
			this.handles.buffer, this.handles.byteOffset, this.handles.length,
			this.data.buffer, this.data.byteOffset, this.data.length,
			this.trs ? 1 : 0);
	}
}

export function batch(objects, options = null) { return new TransformBatch(objects, options); }
