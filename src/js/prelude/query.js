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

// Where each agent's answer sits inside the `results` array of
// `three.moveAndSlideAll`, and what the flags in it mean.
//
// A flat block rather than an object per agent, because an object per agent is
// exactly the 3.63 us the bulk form exists to not spend — see below. Eight
// floats so the stride is a shift.
export const moveResult = {
	stride: 8,
	// Offsets inside one agent's block.
	remaining: 0,
	normal: 3,
	slope: 6,
	flags: 7,
	// Bits inside the flags float. `(results[i * 8 + 7] | 0) & moveResult.GROUNDED`.
	GROUNDED: 1,
	STEPPED: 2,
	TOUCHED: 4,
};

// A results array for `n` agents. Make it once, outside the loop — the whole
// point of the verb is that it allocates nothing per frame.
export function moveBuffer(count) {
	return new Float32Array(Math.max(1, Math.floor(+count)) * moveResult.stride);
}

// The scratch the convenient form of `self` fills. Grown, never shrunk: a crowd
// changes size rarely and a per-call allocation here would be the thing this
// verb exists to avoid.
let selfScratch = new Int32Array(0);
function selfColumn(value, agents, where) {
	if (value === null || value === undefined) return { view: null, count: 0 };
	if (value instanceof Int32Array) return { view: value, count: value.length >> 1 };
	if (!Array.isArray(value)) {
		throw new TypeError(`${where}: self is an Int32Array of handle pairs — three.batch(objects).handles is one — or an array of objects`);
	}
	if (selfScratch.length < agents * 2) selfScratch = new Int32Array(agents * 2);
	for (let i = 0; i < agents; i++) {
		const object = value[i];
		if (object === null || object === undefined) { selfScratch[i * 2] = -1; continue; }
		const [index, generation] = liveObject(object, where);
		selfScratch[i * 2] = index;
		selfScratch[i * 2 + 1] = generation;
	}
	return { view: selfScratch, count: agents };
}

// Move a whole crowd of capsules, sliding along what each one hits — one call,
// however many characters.
//
// **This is the same controller as `three.moveAndSlide` and it exists for one
// reason: the shape of the answer.** `notes.md` §17 measured the single form at
// 7.53 us per agent and took it apart — 3.10 us is the sweep, 1.05 us is the
// crossing and the raw host answer, and 3.63 us, three fifths of it, is the
// JavaScript result object: three live `Vector3`s and two lazy node properties,
// built for a caller who reads four numbers out of them. At two hundred agents
// that is 1.5 ms of a fixed step, 0.9 ms of which buys an object. This writes
// into arrays the caller already owns and builds nothing.
//
//     const pos = new Float32Array(n * 3);      // where they are — updated IN PLACE
//     const motion = new Float32Array(n * 3);   // where they want to go this step
//     const out = three.moveBuffer(n);          // made once
//
//     three.setFixedLoop(dt => {
//         three.steer(pos, motion, { field, maxSpeed: 4 });
//         for (let i = 0; i < n * 3; i++) motion[i] *= dt;
//         three.moveAndSlideAll(pos, motion, { radius: 0.4, height: 1.2, results: out, self: crowd.handles });
//         crowd.flush();                        // one more crossing, and they are drawn
//     });
//
// `positions` is the capsule CENTRE, three floats per agent, and it is READ AND
// WRITTEN — it is the caller's position column, updated where it lies, so there
// is nothing to copy back. `motions` is the whole step's motion and is read.
//
// Options are `{ radius, height, step, slope, skin, snap, ignore, self,
// results }` — the same six numbers `three.moveAndSlide` takes, one set for the
// whole crowd, because a crowd is one agent size. Two sizes is two calls over
// two columns, which is also how they would have to be stored.
//
// **`self` is how an agent stops colliding with its own mesh**, and it is a
// column rather than a single object: two ints per agent, that agent's node and
// generation, whose whole SUBTREE it passes through. `three.batch(objects).handles`
// is already exactly that array, which is the intended way to get one; an array
// of objects also works and is filled into a scratch. `ignore` is still the
// shared set — the lift everybody rides — and with a `self` column it takes at
// most seven, because the eighth slot is the agent itself.
//
// **`results` is optional and is 8 floats per agent** — see `three.moveResult`
// for the layout. Leave it out and only the positions are written, which is
// what a crowd that just walks wants.
//
// **Everyone moves at once.** Every agent is swept against the world as it was
// when the call started: nothing is written to a node, so agent 3 does not see
// agent 2's new position. Resolving in sequence instead would make the answer
// depend on the order the caller happened to store its agents in, and
// `three.steer`'s separation already assumes simultaneity. Two agents can
// therefore end a step overlapping; separation is what keeps that rare, and the
// next step's depenetration is what resolves it.
//
// **It answers with no node handles.** `three.moveAndSlide` reports `ground`
// and `hit`; a flat float array cannot, and "what am I standing on" is a
// moving-platform question that belongs to the one character riding the
// platform. That character calls the single form, which still exists.
export function moveAndSlideAll(positions, motions, options = null) {
	const where = 'three.moveAndSlideAll(positions, motions, options)';
	if (!(positions instanceof Float32Array) || !(motions instanceof Float32Array)) {
		throw new TypeError(`${where} wants two Float32Arrays, three floats per agent`);
	}
	const agents = Math.min(positions.length, motions.length) / 3 | 0;
	if (agents === 0) return 0;

	const radius = +(options?.radius ?? MOVE_DEFAULTS.radius);
	const height = +(options?.height ?? MOVE_DEFAULTS.height);
	if (!(Number.isFinite(radius) && radius > 0)) {
		throw new RangeError(`${where} wants a positive radius, not ${options?.radius}`);
	}
	const half = Math.max((height - 2 * radius) * 0.5, 0);

	const results = options?.results ?? null;
	if (results !== null && !(results instanceof Float32Array)) {
		throw new TypeError(`${where}: results is a Float32Array of ${moveResult.stride} floats per agent — three.moveBuffer(n) makes one`);
	}
	if (results !== null && results.length < agents * moveResult.stride) {
		throw new RangeError(`${where}: results holds ${results.length} floats, which is ${moveResult.stride * agents} short of ${agents} agents — three.moveBuffer(${agents})`);
	}

	const own = selfColumn(options?.self, agents, `${where}: self`);
	// One ignore slot per agent is spent on the agent itself, so the shared set
	// may only fill the other seven. Refused rather than silently dropping the
	// eighth: a sweep quietly colliding with something it was told to pass
	// through is a bug that reads as the controller misbehaving.
	const shared = options?.ignore ?? null;
	if (own.count > 0 && Array.isArray(shared) && shared.length > MAX_IGNORED - 1) {
		throw new RangeError(`${where}: with a self column, ignore takes at most ${MAX_IGNORED - 1} objects — the last of the ${MAX_IGNORED} slots is the agent itself`);
	}
	const ignored = fillIgnore(shared, `${where}: ignore`);

	return H.moveAndSlideAll(
		positions.buffer, positions.byteOffset, positions.length,
		motions.buffer, motions.byteOffset, motions.length,
		results === null ? positions.buffer : results.buffer,
		results === null ? 0 : results.byteOffset,
		results === null ? 0 : agents * moveResult.stride,
		own.view === null ? selfScratch.buffer : own.view.buffer,
		own.view === null ? 0 : own.view.byteOffset,
		own.count * 2,
		radius, half,
		+(options?.step ?? MOVE_DEFAULTS.step),
		+(options?.slope ?? MOVE_DEFAULTS.slope),
		+(options?.skin ?? MOVE_DEFAULTS.skin),
		+(options?.snap ?? MOVE_DEFAULTS.snap),
		ignoreScratch.buffer, ignoreScratch.byteOffset, ignored * 2);
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
// the objects are now.
//
// **Two rotation forms, and they are not redundant.** `{ trs: true }` is ten
// floats — position, an xyzw QUATERNION, then scale — and is for a batch
// written by ARITHMETIC, where whatever produced the rotation (a look-at, a
// slerp, a physics read-back) produced a quaternion and converting it to Euler
// angles to send it would be lossy at every gimbal-locked pose. `{ euler: true }`
// is nine floats — position, an xyz EULER triple, then scale — and is for a
// batch written by a GAME, where the rotation is a heading and a limb swing:
// one angle each, typed by a person.
//
// The Euler form is what makes a crowd of characters one crossing instead of
// four. `notes.md` §17 measured a critter writing a group position, a group
// heading and two leg angles at four crossings a frame, about 380 ns apiece —
// and the reason it was four rather than one was that the batch could not
// express the three angles it wanted to write.
//
// **The two seed differently, and that follows from the same argument.** A TRS
// batch is seeded with an identity rotation and a unit scale, because reading
// the objects' own Euler angles and converting them would silently rewrite
// rotations the script had set by hand — a caller using that form is writing
// all ten numbers. An Euler batch IS the script's own numbers, so it is seeded
// from `object.rotation` and `object.scale` and a batch made and immediately
// flushed changes nothing.
//
// A member that leaves the scene is skipped on flush rather than throwing: a
// crowd where one agent was removed this frame is ordinary, and abandoning the
// other nine hundred halfway through would be worse. `flush()` answers with how
// many actually landed.
//
// ## `flush()` writes the NODE, and the object stops agreeing with it
//
// **This is the one thing about a batch that will bite.** `object.position` and
// `object.rotation` are JavaScript numbers this file's header explains — the
// host is never the authority on them — and a batch goes straight to the node.
// So after a flush the object's own numbers are whatever they were before, and
// two things follow:
//
// - Reading `object.position.x` back gives the stale value. `boundingBox()`,
//   `align()` and the follow camera all read the host and are fine.
// - **Writing any single component afterwards undoes the batch.**
//   `object.position.y = 5` sends all nine numbers from the object, so the
//   rotation and scale the batch wrote are overwritten with the object's old
//   ones. It renders as a crowd snapping back to a pose it had frames ago.
//
// `sync()` is the fix and it is opt-in: it copies the array back onto the
// objects, in JavaScript, with no crossing. Call it when a script is going to
// read or write those objects by hand again — and not every frame merely
// because it is available, because the whole reason to reach for a batch is
// that nothing per-object is being paid for.
export class TransformBatch {
	constructor(objects, options = null) {
		const where = 'three.batch(objects, { trs })';
		if (!Array.isArray(objects)) throw new TypeError(`${where} wants an array of scene objects`);

		this.trs = !!options?.trs;
		this.euler = !!options?.euler;
		if (this.trs && this.euler) {
			throw new RangeError(`${where}: trs and euler are two spellings of the rotation, not two things to have — pick one`);
		}
		// The host's BATCH_POSITION / BATCH_TRS / BATCH_EULER.
		this.mode = this.euler ? 2 : (this.trs ? 1 : 0);
		this.stride = this.euler ? 9 : (this.trs ? 10 : 3);
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
			} else if (this.euler) {
				// The object's own numbers, in the object's own units — see the
				// header for why this one is seeded and the TRS one is not.
				this.data[at + 3] = object.rotation.x;
				this.data[at + 4] = object.rotation.y;
				this.data[at + 5] = object.rotation.z;
				this.data[at + 6] = object.scale.x;
				this.data[at + 7] = object.scale.y;
				this.data[at + 8] = object.scale.z;
			}
		});
	}

	// The transform array, named for what is in it. `positions` reads better at
	// the call site than `data` and is the same memory — in the TRS and Euler
	// forms the rotation and the scale are in the same array, `stride` apart.
	get positions() { return this.data; }

	// Where agent `i`'s rotation starts in `data`, or -1 in the position-only
	// form. Written as a method rather than left to the caller to work out
	// because `i * this.stride + 3` is the kind of arithmetic that is wrong
	// once and then wrong everywhere.
	rotationAt(i) { return this.mode === 0 ? -1 : i * this.stride + 3; }

	// Where agent `i`'s scale starts. -1 in the position-only form.
	scaleAt(i) { return this.mode === 0 ? -1 : i * this.stride + (this.euler ? 6 : 7); }

	get length() { return this.objects.length; }

	// Copy the array back onto the objects, so `object.position` and
	// `object.rotation` agree with what was flushed. See the header for the
	// trap this exists for. No crossing — this is JavaScript writing
	// JavaScript, and it deliberately does not touch `_flush`.
	//
	// Answers with how many objects were written, which is every live one.
	sync() {
		let written = 0;
		for (let i = 0; i < this.objects.length; i++) {
			const object = this.objects[i];
			if (object === null || object === undefined) continue;
			const at = i * this.stride;
			object.position._x = this.data[at];
			object.position._y = this.data[at + 1];
			object.position._z = this.data[at + 2];
			if (this.euler) {
				object.rotation._x = this.data[at + 3];
				object.rotation._y = this.data[at + 4];
				object.rotation._z = this.data[at + 5];
				// The Euler triple IS what was sent, so the exact quaternion an
				// `instantiate()` left on the object is no longer what the node
				// holds — dropping it here is what stops the next ordinary
				// write from sending a rotation the batch has already replaced.
				object._q = null;
				object.scale._x = this.data[at + 6];
				object.scale._y = this.data[at + 7];
				object.scale._z = this.data[at + 8];
			}
			// The TRS form is deliberately not copied back: its rotation is a
			// quaternion and `object.rotation` is an Euler triple, so writing
			// one from the other is the lossy conversion that form exists to
			// avoid. A caller using it is writing all ten numbers and reading
			// none of them off the object.
			written++;
		}
		return written;
	}

	flush() {
		return H.setTransforms(
			this.handles.buffer, this.handles.byteOffset, this.handles.length,
			this.data.buffer, this.data.byteOffset, this.data.length,
			this.mode);
	}
}

export function batch(objects, options = null) { return new TransformBatch(objects, options); }
