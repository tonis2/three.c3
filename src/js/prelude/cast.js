// three.c3 — a cast of actors: columns, entities and systems. `notes.md` §21.
//
// ## One Cast is one KIND of thing
//
// The critters, the crates, the pickups — not the whole world. That
// restriction is the design and not a simplification held back for later:
// **every bulk verb in this API takes a contiguous typed array**, so
// `three.steer`, `three.moveAndSlideAll` and `field.sample` are one call each
// only while the things they act on are one dense column. A general entity
// store with an archetype graph would have to gather before every call, and the
// gather is the cost those verbs exist to remove.
//
// So the shape is: **a column IS the buffer the bulk verb takes.** Nothing is
// marshalled between the storage and the call.
//
//     const pack = three.cast({ capacity: 64, name: 'pack' });
//     const position = pack.vec3('position');
//     const motion = pack.vec3('motion');
//     const CHASING = pack.tag('chasing');
//
//     pack.system('steer', (dt) => {
//         three.steer(pack.live(position), pack.live(motion), { field, maxSpeed: 4 });
//     }, { phase: 'fixed' });
//
//     pack.system('walk', (dt) => {
//         const m = pack.live(motion);
//         for (let i = 0; i < m.length; i++) m[i] *= dt;
//         three.moveAndSlideAll(pack.live(position), m, { ...SIZE, self: pack.live(pack.handles) });
//     }, { phase: 'fixed' });
//
//     pack.system('draw', () => { pack.pose(position, 0.575); pack.flush(); });
//
// ## Indices are valid for the frame you got them in
//
// `spawn` and `despawn` are the two things that can move an entity, and the
// rule is one sentence: **a despawn takes effect at the end of the frame.** The
// Cast registers one internal system, `<name>.compact`, that runs last in the
// frame phase and closes the gaps; until then a despawned slot is still there
// with its ALIVE bit cleared, and every index a system is holding still means
// what it meant.
//
// The alternative — compacting on the spot — was rejected in `plan.md` §21: a
// dead critter stepped one more time is invisible, and a system whose indices
// moved under it is a bug that looks like the wrong entity taking damage.
//
// The one exception is a `spawn` that finds the cast full and some slots dead:
// it compacts to make room, because refusing would be worse. That is the only
// place an index moves mid-frame, and it only happens to a cast whose capacity
// is too small for its own churn — `cast.free` is how to notice before then.
//
// ## Compaction is stable, not a swap-remove
//
// Removing entity 3 of 200 shifts 197 entities down by one rather than moving
// entity 199 into the hole. That is O(count) where the textbook answer is O(1),
// and it is the right trade here for two reasons: `count` is a pack rather than
// a particle system, and a crowd that reorders itself whenever something dies
// makes `three.steer`'s separation — which reads neighbours out of the same
// array — behave differently for reasons nothing in the game can see.
//
// ## The capacity is fixed, and that follows from the columns being the API
//
// A growing cast would have to reallocate its columns, and every reference a
// script is holding to one would then point at the old memory. There is no way
// to make that safe that does not amount to handing out accessors instead of
// arrays, which is the thing this is built to avoid.
import { systems } from './systems.js';
import { liveObject } from './scene.js';

const H = globalThis.__three;

// The host's BATCH_EULER — see `bind_query.c3`.
const BATCH_EULER = 2;

// Ten floats per entity of node transform is the widest column here; the cap is
// what keeps an id packable into a double with room for the generation.
const MAX_CAPACITY = 65536;

// Bit 0 of `state`. Reserved, so `tag()` starts at bit 1.
const ALIVE = 1;

// Nine floats: position, an xyz Euler triple, then scale — the layout
// `three.batch(objects, { euler: true })` uses, and for the same reason. A
// game's rotation is a heading and a limb swing, one angle each, typed by a
// person.
const TRANSFORM_STRIDE = 9;

// Not an id. What `spawn` answers with when the cast is full, and what
// `indexOf` answers for anything that has been despawned.
export const NO_ENTITY = -1;

export class Cast {
	// `{ capacity, name }`. The name prefixes every system this cast
	// registers, so `three.systems.report()` says `pack.chase` rather than
	// `chase` — with two casts running, the unprefixed name is the one thing
	// that makes a report unreadable.
	constructor(options = null) {
		const where = 'three.cast({ capacity, name })';
		const capacity = Math.floor(+(options?.capacity ?? 64));
		if (!(capacity > 0 && capacity <= MAX_CAPACITY)) {
			throw new RangeError(`${where} wants a capacity between 1 and ${MAX_CAPACITY}, not ${options?.capacity}`);
		}
		this.capacity = capacity;
		this.name = String(options?.name ?? 'cast');

		this._count = 0;
		this._dead = 0;

		// The sparse set. `_slotOf` is indexed by HANDLE and `_handleAt` by
		// SLOT, which is what lets a slot move under a script without the id it
		// was given moving with it.
		this._slotOf = new Int32Array(capacity).fill(NO_ENTITY);
		this._handleAt = new Int32Array(capacity).fill(NO_ENTITY);
		this._generation = new Int32Array(capacity).fill(1);
		this._free = new Int32Array(capacity);
		this._freeCount = 0;
		this._issued = 0;

		this._columns = new Map();
		this._strideOf = new Map();
		this._views = new Map();
		this._objects = new Array(capacity).fill(null);
		this._tags = new Map();
		this._nextTag = 1;
		this._transform = null;
		this._systems = [];

		// Bit 0 is ALIVE and the rest are `tag()`s. A built-in column rather
		// than one the caller has to remember to make, because every system
		// filter is written against it.
		this.state = this._column('state', 1, Uint32Array);

		// Two ints per slot — a node index and its generation. **This one array
		// is both things a crowd needs**: the `self` column
		// `three.moveAndSlideAll` takes, so an agent does not collide with its
		// own mesh, and the handle array `setTransforms` takes, so `flush()` is
		// one crossing.
		this.handles = this._column('handles', 2, Int32Array);

		// Last in the frame, so a despawn during any of the frame's fixed steps
		// or during the frame itself takes effect at one known boundary. See
		// the header for why it is not immediate.
		systems.add(`${this.name}.compact`, () => this.compact(), { phase: 'frame', order: Infinity });
		this._systems.push(`${this.name}.compact`);
	}

	// ----------------------------------------------------------------- columns

	// Three floats per entity — a position, a velocity, a colour.
	vec3(name) { return this._column(name, 3, Float32Array); }

	// One float per entity — health, a timer, a heading.
	float(name) { return this._column(name, 1, Float32Array); }

	// One uint per entity, for bit flags of your own. `state` is the built-in
	// one and `tag()` allocates bits in it; this is for a second set.
	flags(name) { return this._column(name, 1, Uint32Array); }

	// `stride` floats per entity, for the answer buffers the bulk verbs write —
	// `cast.buffer('move', three.moveResult.stride)` is the one
	// `three.moveAndSlideAll` fills.
	buffer(name, stride) {
		const width = Math.floor(+stride);
		if (!(width > 0)) throw new RangeError(`cast.buffer(name, stride) wants a positive stride, not ${stride}`);
		return this._column(name, width, Float32Array);
	}

	// The nine-float transform column — position, an xyz Euler triple, scale —
	// and what `flush()` sends. Allocated on first use, because a cast of
	// invisible agents should not carry one.
	//
	// Seeded from each object as it is attached, so a cast attached and
	// immediately flushed changes nothing.
	get transform() {
		if (this._transform === null) this._transform = this._column('transform', TRANSFORM_STRIDE, Float32Array);
		return this._transform;
	}

	// The live part of a column, as a subarray — what to hand a bulk verb.
	//
	// Cached and rebuilt only when the live count changes, because a subarray
	// is an allocation and this is called from inside the frame.
	live(column) {
		const stride = this._strideOf.get(column);
		if (stride === undefined) {
			throw new TypeError('cast.live(column) wants a column this cast made — cast.vec3(name), cast.float(name), cast.flags(name) or cast.buffer(name, stride)');
		}
		let cached = this._views.get(column);
		if (cached === undefined || cached.count !== this._count) {
			cached = { count: this._count, view: column.subarray(0, this._count * stride) };
			this._views.set(column, cached);
		}
		return cached.view;
	}

	// A named bit in `state`, allocated once and answered with every time.
	// `if (state[i] & CHASING)` reads as a sentence where a property lookup
	// reads as a lookup, and a mask test is what a system filter wants.
	//
	// Thirty-one of them — bit 0 is ALIVE.
	tag(name) {
		const had = this._tags.get(name);
		if (had !== undefined) return had;
		if (this._nextTag >= 32) {
			throw new RangeError(`cast.tag(${JSON.stringify(name)}): a cast has 31 tags and this one has used them all — a 32nd is a flags(name) column of its own`);
		}
		const bit = 1 << this._nextTag++;
		this._tags.set(name, bit);
		return bit;
	}

	// ---------------------------------------------------------------- entities

	// How many slots the columns are using, dead-but-not-yet-compacted ones
	// included. **This is the number `live()` slices to**, because a bulk verb
	// runs over the whole range and reads the ALIVE bit for nothing.
	get count() { return this._count; }

	// How many are actually alive. `count - alive` is what the next compaction
	// will reclaim.
	get alive() { return this._count - this._dead; }

	// Room for this many more before a spawn has to compact or refuse.
	get free() { return this.capacity - this._count + this._dead; }

	// A new entity, or `NO_ENTITY` when there is no room.
	//
	// **Full is an answer rather than an error**, as `three.nav.field` answering
	// null is: a pool running out is an ordinary runtime condition for debris
	// and projectiles, and a game should drop the spark rather than stop.
	// Check for `NO_ENTITY` where that matters and watch `cast.free` where it
	// does not.
	spawn() {
		if (this._count >= this.capacity) {
			// The one place an index moves mid-frame — see the header.
			if (this._dead === 0) return NO_ENTITY;
			this.compact();
			if (this._count >= this.capacity) return NO_ENTITY;
		}

		const handle = this._freeCount > 0 ? this._free[--this._freeCount] : this._issued++;
		const slot = this._count++;
		this._slotOf[handle] = slot;
		this._handleAt[slot] = handle;
		this._objects[slot] = null;

		// Zeroed, every column, every time. A slot that came back from the free
		// list holding the last occupant's velocity is the kind of bug that
		// shows up as one critter in fifty behaving oddly.
		for (const { array, stride } of this._columns.values()) array.fill(0, slot * stride, slot * stride + stride);
		this.state[slot] = ALIVE;
		this.handles[slot * 2] = NO_ENTITY;
		return handle + this._generation[handle] * MAX_CAPACITY;
	}

	// Retire an entity. Answers with the Object3D it was attached to, or null.
	//
	// **The object is handed back rather than removed**, because a Cast is not
	// a lifetime manager — the rest of this API frees nothing until it is told
	// to, and a cast that quietly deleted nodes would be a local exception to
	// that. `scene.remove(pack.despawn(id))` is the line, and it says at the
	// call site what happens to the mesh.
	//
	// The id is dead immediately: `indexOf` answers `NO_ENTITY` from here on.
	// The SLOT lingers until the end of the frame, with its ALIVE bit clear.
	despawn(id) {
		const slot = this.indexOf(id);
		if (slot < 0) return null;
		const handle = this._handleAt[slot];
		this._slotOf[handle] = NO_ENTITY;
		// Bumped now, so the id that was just handed out can never come back
		// meaning something else — the same contract NodeId's generation has.
		this._generation[handle]++;
		this._free[this._freeCount++] = handle;
		this.state[slot] &= ~ALIVE;
		this._dead++;
		const object = this._objects[slot];
		this._objects[slot] = null;
		return object;
	}

	// The slot an id is in, or `NO_ENTITY` if it has been despawned or never
	// was one. The indirection the whole sparse set exists for.
	indexOf(id) {
		if (!(id >= 0)) return NO_ENTITY;
		const handle = id % MAX_CAPACITY;
		if (handle >= this.capacity) return NO_ENTITY;
		if (this._generation[handle] !== (id - handle) / MAX_CAPACITY) return NO_ENTITY;
		return this._slotOf[handle];
	}

	// The id in a slot, or `NO_ENTITY` for a slot that is dead or past the end.
	// What a system holds on to when it needs to remember an entity across
	// frames — an index is only good for the frame it was read in.
	idOf(slot) {
		if (!(slot >= 0 && slot < this._count) || (this.state[slot] & ALIVE) === 0) return NO_ENTITY;
		const handle = this._handleAt[slot];
		return handle + this._generation[handle] * MAX_CAPACITY;
	}

	// Give an entity its scene object. Fills the handle column — which is both
	// the `self` column a sweep wants and the handle array a flush wants — and
	// seeds the transform column from wherever the object already is.
	//
	// The object must be in the scene: an unadded one has no host node, and a
	// cast holding a handle to nothing would flush into nothing forever.
	attach(id, object) {
		const slot = this.indexOf(id);
		if (slot < 0) return false;
		const [index, generation] = liveObject(object, `${this.name}.attach(id, object)`);
		this.handles[slot * 2] = index;
		this.handles[slot * 2 + 1] = generation;
		this._objects[slot] = object;

		const at = slot * TRANSFORM_STRIDE;
		const t = this.transform;
		t[at] = object.position.x; t[at + 1] = object.position.y; t[at + 2] = object.position.z;
		t[at + 3] = object.rotation.x; t[at + 4] = object.rotation.y; t[at + 5] = object.rotation.z;
		t[at + 6] = object.scale.x; t[at + 7] = object.scale.y; t[at + 8] = object.scale.z;
		return true;
	}

	// Take the object back without retiring the entity. Answers with it.
	detach(id) {
		const slot = this.indexOf(id);
		if (slot < 0) return null;
		const object = this._objects[slot];
		this._objects[slot] = null;
		this.handles[slot * 2] = NO_ENTITY;
		return object;
	}

	// The Object3D in a slot, or null.
	objectAt(slot) {
		return slot >= 0 && slot < this._count ? this._objects[slot] : null;
	}

	// ------------------------------------------------------------------- frame

	// Close the gaps left by despawns. Answers with how many slots came back.
	//
	// Registered as `<name>.compact` at the end of the frame phase, so a game
	// using systems never calls this. A game that drives its own loop does.
	compact() {
		if (this._dead === 0) return 0;
		let write = 0;
		for (let read = 0; read < this._count; read++) {
			if ((this.state[read] & ALIVE) === 0) continue;
			if (write !== read) this._move(read, write);
			write++;
		}
		const removed = this._count - write;
		this._count = write;
		this._dead = 0;
		// Every cached subarray is now the wrong length.
		this._views.clear();
		return removed;
	}

	// Copy the transform column onto the nodes — one crossing, however many
	// entities. Answers with how many landed.
	//
	// A slot whose object has left the scene is skipped by the host rather than
	// raising, which is what makes `scene.remove(pack.despawn(id))` safe to
	// write in the middle of a frame: the entity is dead, its slot is still
	// there until the compaction, and its stale handle is simply not written.
	flush() {
		if (this._transform === null || this._count === 0) return 0;
		return H.setTransforms(
			this.handles.buffer, this.handles.byteOffset, this._count * 2,
			this._transform.buffer, this._transform.byteOffset, this._count * TRANSFORM_STRIDE,
			BATCH_EULER);
	}

	// Copy the transform column back onto the Object3Ds, so `object.position`
	// and `object.rotation` agree with what was flushed.
	//
	// **The same trap `three.batch` carries, and for the same reason**: a flush
	// writes the NODE, and an object's transform is JavaScript numbers the host
	// is never the authority on. So after a flush the objects are stale, and
	// writing any single component of one — `object.position.y = 5` — sends all
	// nine of ITS numbers and undoes the flush for that entity. Call this
	// before touching them by hand. No crossing; this is JavaScript writing
	// JavaScript.
	sync() {
		if (this._transform === null) return 0;
		let written = 0;
		for (let slot = 0; slot < this._count; slot++) {
			const object = this._objects[slot];
			if (object === null) continue;
			const at = slot * TRANSFORM_STRIDE;
			const t = this._transform;
			object.position._x = t[at]; object.position._y = t[at + 1]; object.position._z = t[at + 2];
			object.rotation._x = t[at + 3]; object.rotation._y = t[at + 4]; object.rotation._z = t[at + 5];
			object._q = null;
			object.scale._x = t[at + 6]; object.scale._y = t[at + 7]; object.scale._z = t[at + 8];
			written++;
		}
		return written;
	}

	// Copy a position column into the transform column, with an optional
	// vertical offset and an optional heading column — the three lines every
	// presentation system writes, because the capsule's centre and the model's
	// origin are never the same point.
	//
	//     pack.pose(position, { lift: -0.575, heading });
	//
	// `lift` is added to y. `heading` is a one-float column written into the
	// transform's y rotation. Answers with how many entities were posed.
	pose(position, options = null) {
		const stride = this._strideOf.get(position);
		if (stride !== 3) {
			throw new TypeError(`${this.name}.pose(position, options) wants a cast.vec3 column`);
		}
		const lift = +(options?.lift ?? 0);
		const heading = options?.heading ?? null;
		if (heading !== null && this._strideOf.get(heading) !== 1) {
			throw new TypeError(`${this.name}.pose(position, { heading }) wants a cast.float column`);
		}
		const t = this.transform;
		for (let slot = 0; slot < this._count; slot++) {
			const at = slot * TRANSFORM_STRIDE, from = slot * 3;
			t[at] = position[from];
			t[at + 1] = position[from + 1] + lift;
			t[at + 2] = position[from + 2];
			if (heading !== null) t[at + 4] = heading[slot];
		}
		return this._count;
	}

	// ----------------------------------------------------------------- systems

	// Register a system under this cast's name, so the report says
	// `pack.chase`. The callback is handed `(dt, cast)` — seconds, and this
	// cast — and everything `three.systems.add` takes is taken here.
	system(name, fn, options = null) {
		const full = `${this.name}.${name}`;
		systems.add(full, fn, { ...(options ?? {}), context: this });
		if (!this._systems.includes(full)) this._systems.push(full);
		return full;
	}

	// Take every system this cast registered out of the registry, including the
	// compaction pass. It does NOT touch the scene: the objects are the
	// caller's, as `despawn` says.
	dispose() {
		for (const name of this._systems) systems.remove(name);
		this._systems.length = 0;
		this._count = 0;
		this._dead = 0;
		this._views.clear();
	}

	toString() { return `Cast(${this.name}: ${this.alive} of ${this.capacity})`; }

	// ------------------------------------------------------------------ private

	_column(name, stride, Kind) {
		const had = this._columns.get(name);
		if (had !== undefined) {
			if (had.stride !== stride || had.array.constructor !== Kind) {
				throw new TypeError(`${this.name}: column '${name}' already exists with a stride of ${had.stride} — one name is one column`);
			}
			return had.array;
		}
		const array = new Kind(this.capacity * stride);
		this._columns.set(name, { array, stride });
		this._strideOf.set(array, stride);
		return array;
	}

	_move(from, to) {
		for (const { array, stride } of this._columns.values()) {
			array.copyWithin(to * stride, from * stride, from * stride + stride);
		}
		const handle = this._handleAt[from];
		this._handleAt[to] = handle;
		this._slotOf[handle] = to;
		this._objects[to] = this._objects[from];
		this._objects[from] = null;
	}
}

export function cast(options = null) { return new Cast(options); }
