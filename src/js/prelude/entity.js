// three.c3 — a tracked class: entities as ordinary JavaScript objects, with
// rules that fire on a pair of them. §23.
//
// ## What this replaces, and the defect it fixes
//
// `three.cast` stores N things of one kind as COLUMNS and `three.kind` stores
// them as records addressed by object identity. Both work. The defect is that
// the choice between them is made at declaration time and is irreversible at
// every call site — `c.hp` and `P_HP[slot]` are the same fact written two ways,
// so a kind that grows into a cast rewrites every system that touches it, and
// the words "kind" and "cast" carry no hint of which decides what.
//
// A tracked class is one thing instead of two:
//
//     class Critter {
//         constructor(at) {
//             this.hp = 3;                     // an ordinary field
//             this.position[0] = at.x;         // a window into a shared column
//             this.object = buildCritter();     // a Mesh or a Group
//         }
//     }
//     const Critter = three.track(class Critter { ... }, {
//         parent: groups.pack,
//         columns: { position: 3, motion: 3 },
//         capacity: 32,
//     });
//
//     const c = Critter.spawn(at);          // never `new Critter(at)`
//     Critter.of(hit.object)                // the instance, or null
//     for (const c of Critter) ...          // the live ones
//     three.steer(Critter.column('position'), Critter.column('motion'), { field });
//
// ## The columns are a window, not a copy
//
// `three.steer`, `field.sample` and `three.moveAndSlideAll` take Float32Arrays
// and derive the agent count from the length: agent i IS floats i*3..i*3+2.
// There is no mapping and nothing to look up. `bind_query.c3`'s `typed_view`
// hands C3 a pointer into QuickJS's own buffer, so the host reads and writes the
// script's bytes directly — that is as true of a gathered staging array as of a
// column, and the boundary costs nothing either way.
//
// **So the only question is whether entity i OWNS those three floats.** Here it
// does: `this.position` is `column.subarray(slot * 3, slot * 3 + 3)`, and
// `Critter.column('position')` is the whole live prefix of the same memory.
// Nothing is ever gathered, because the fields a bulk verb reads are declared
// and the ones it does not — `hp`, `stun`, `walk` — are plain fields nobody
// copies anywhere.
//
// **And it is measured, so `columns` is an option rather than a requirement.**
// Against the same work done by copying instances into a staging array before
// the call and reading the results back out, on this machine:
//
//     entities      gather      of an 8 ms frame
//         10      0.0015 ms         0.02 %
//        200      0.023 ms          0.3 %
//       1000      0.112 ms          1.4 %
//       5000      0.575 ms          7 %
//
// — a flat 115 to 148 ns per entity, which is exactly the 70–150 ns band §17
// measured every JavaScript-side layout at. So a game with a few hundred of
// something should not declare a column at all: write the plain field, and reach
// for this at the low thousands where the gather starts costing a percent of the
// frame. QuickJS is an interpreter rather than a JIT, which is why the number is
// what it is and why it does not improve with a cleverer loop.
//
// A view is a function of the SLOT and not of the instance, which is what makes
// compaction cheap: the floats move down, the instance's slot number changes,
// and the getter picks up the right window with nothing to re-seat. The cost of
// that is the one trap here — **a subarray held across a frame boundary points
// at whatever moved into that slot.** Read `c.position` where you use it.
//
// ## Systems are what happens every frame; rules are what happens when
//
// There is deliberately no `update()` to override. A per-entity update method
// puts §21's ninety-line callback back once per class, with the running order
// buried in a hierarchy instead of on the `Critter.frame(...)` lines where a
// person can read it. Continuous work stays a system; discrete work is a rule:
//
//     Critter.on('near', Player, (c, p) => p.spin.active ? c.launch(p) : p.hurt(),
//                { within: 0.95 });
//
// **Subject first, always.** The rule lives on `Critter`, so the handler is
// handed `(critter, player)` in that order and the class IS the argument-order
// declaration — which is the whole reason this is not `three.on(a, verb, b)`.
// The other direction is a rule on `Player`, and both fire when both exist.
//
// ## `three.onTrigger` was `setAnimationLoop` before §21
//
// One handler slot for every trigger in the game, so a fruit pickup is four
// lines of dispatch around one line of game and a second pickup type is an edit
// to that same function. This file owns the host's three handler slots and
// multiplexes them: rules first, contained and counted the way a system is, then
// the script's own handler under exactly its old contract — one handler,
// binding again replaces, and a throw stops it for good.
//
// ## Engine events queue; `three.emit` does not
//
// A trigger fires from inside the solver, and a handler that deletes a body
// there is a hazard the game cannot see. So engine events are queued and drained
// by one system named `rules`, which also puts their cost in
// `three.systems.report()`. The price is one frame of latency on a contact,
// which is invisible for a pickup and for reach. `three.emit(a, verb, b)` is the
// game raising its own event and dispatches at once, because the game knows when
// it is safe and the solver does not.
import { systems } from './systems.js';
import { liveScene, liveObject, objectForHandle } from './scene.js';
import { Object3D } from './object3d.js';
import { Mesh } from './mesh.js';
import { Vector3, readVector } from './math.js';
import { BoxGeometry, SphereGeometry, CylinderGeometry } from './geometry.js';

const H = globalThis.__three;

// Where the queue drains: first in the frame phase, so a rule's effect lands in
// the same frame the game draws.
const DRAIN_ORDER = -1e6;

// Where the volume-follow and the proximity pass run: after the systems that
// move things, before the compaction at Infinity. `follow` is at LATE_ORDER - 2
// and `near` at LATE_ORDER - 1, in that order, because proximity is measured
// against the volume.
//
// Numbers rather than an `after`, because these have to sit outside EVERY
// system a game will ever register, including ones registered after these were
// — which is the one thing naming a neighbour cannot say. It is also why
// `{ last: true }` lands well short of here: a game's last system still runs
// before the write-back that has to see where it left things.
const LATE_ORDER = 1e6;

// How many times one rule may throw the same message before the log stops
// repeating it. A rule that fails does so sixty times a second, and a thousand
// identical traces is how the FIRST one gets scrolled away. `systems.js`'s
// number, for the same reason.
const ERROR_REPEATS = 3;

// The host's BATCH_EULER — see `bind_query.c3`.
const BATCH_EULER = 2;

// Nine floats: position, an xyz Euler triple, then scale — the layout
// `three.batch(objects, { euler: true })` uses, and for the same reason. A
// game's rotation is a heading and a limb swing, one angle each, typed by a
// person.
const TRANSFORM_STRIDE = 9;

// Ten floats per entity of anything is the widest column worth having; the cap
// is what keeps a capacity from being a typo that allocates a gigabyte.
const MAX_CAPACITY = 65536;

// Not enumerable fields: an instance is a plain object a script puts its own
// fields on, and `JSON.stringify(critter)` should not answer with bookkeeping it
// never set.
const SLOT = Symbol('entity.slot');
const DEAD = Symbol('entity.dead');
const TRACK = Symbol('entity.track');

// Every tracked class by name — a duplicate is refused rather than replaced, for
// the reason `kind.js` gives: a class owns entities, and replacing one silently
// would leave a scene full of nodes and bodies that nothing can name any more.
const byName = new Map();

// The class (the raw constructor, not the proxy) back to its Track.
const byClass = new Map();

// Every object a tracked class owns — drawn roots and trigger volumes alike —
// back to the instance. `three.instanceOf(object)` is the reverse of
// `Class.of(object)` across all of them, and it is what a rule keyed on "what are
// these two things" needs before it can dispatch on either.
const owners = new Map();

// The slot `spawn` has allocated for the instance the constructor is building.
// **This is the one piece of machinery in the design.** A column getter has to
// resolve while the constructor is running — `this.position[0] = at.x` on line
// one — and the slot cannot be a field on `this`, because `this` does not exist
// until the constructor has returned. So `spawn` parks it here and clears it.
let pending = null;

// Volumes are never drawn, so these are as coarse as the collider allows. Built
// on first use: a prelude that made three GPU assets every session for a feature
// most scripts never reach would be paying for this file's existence rather than
// for its use.
const VOLUME_GEOMETRY = { sphere: null, box: null, capsule: null };

// ---------------------------------------------------------------------------
// Rules
// ---------------------------------------------------------------------------

// Every rule, and the same rules bucketed by event name. The bucket is what a
// dispatch walks; the list is what `report` and `dispose` walk.
const rules = [];
const byEvent = new Map();
const ruleByName = new Map();
let ruleSeq = 0;

// Engine events waiting for the drain. Objects rather than a flat array because
// a contact carries a normal and a point.
const queue = [];

// Which host slots have been asked for. A feed is bound on demand — a scene with
// no rules and no `three.onTrigger` must not pay a JS call per contact.
const bound = { trigger: false, contact: false, click: false };
const scriptHandler = { trigger: null, contact: null, click: null };
let clickShaper = null;
let drainRegistered = false;

// ---------------------------------------------------------------------------
// A tracked class
// ---------------------------------------------------------------------------

class Track {
	constructor(Class, options, proxy) {
		this.Class = Class;
		this.proxy = proxy;
		this.name = String(options?.name ?? Class.name);
		this.parent = options?.parent ?? null;
		this.collides = options?.collides === undefined ? undefined : !!options.collides;
		this.body = options?.body ?? null;
		this.volume = readVolumeOption(options, `three.track(${this.name}, options)`);

		this.instances = [];
		this.dead = 0;
		this.issued = 0;
		this.of = new Map();
		this.disposed = false;

		this.capacity = 0;
		this.columns = new Map();
		this.systems = [];

		// The batched draw path, built on first use. A class that never poses
		// should not carry eleven numbers per entity for the privilege.
		this._transform = null;
		this._handles = null;
		this._liveHandles = null;
		this._liveHandleCount = -1;
	}

	// How many are alive. Not the length of the list: an instance removed this
	// frame is still in it until the compaction, and it is not one of these.
	get count() { return this.instances.length - this.dead; }

	// The live prefix of a column, cached and rebuilt only when the count
	// changes — a subarray is an allocation and this is read inside the frame.
	column(name) {
		const col = this.columns.get(name);
		if (col === undefined) {
			const had = [...this.columns.keys()];
			throw new TypeError(
				`${this.name}.column(${JSON.stringify(name)}) wants a column this class declared — `
				+ (had.length === 0
					? `${this.name} declared none. three.track(${this.name}, { columns: { position: 3 } }) is where they are named.`
					: `it has ${had.map(k => JSON.stringify(k)).join(', ')}.`)
			);
		}
		const n = this.instances.length;
		if (col.liveCount !== n) {
			col.live = col.array.subarray(0, n * col.stride);
			col.liveCount = n;
		}
		return col.live;
	}

	// The window one slot owns, built once per slot and cached. Indexed by SLOT
	// and not by instance, which is what lets a compaction move the floats and
	// change the instance's slot number with nothing to re-seat.
	view(col, slot) {
		let v = col.views[slot];
		if (v === undefined) {
			v = col.array.subarray(slot * col.stride, (slot + 1) * col.stride);
			col.views[slot] = v;
		}
		return v;
	}

	// ------------------------------------------------------- the batched draw

	// Two ints per slot — a node index and its generation. **This one array is
	// both things a crowd needs**: the `self` column `three.moveAndSlideAll`
	// takes, so an agent does not collide with its own mesh, and the handle
	// array `setTransforms` takes, so a flush is ONE crossing.
	//
	// Built on first use and seeded from whatever is already alive, so a class
	// that never draws in bulk never allocates it.
	batch() {
		if (this._handles !== null) return;
		if (this.capacity <= 0) {
			throw new Error(
				`${this.name}.pose/flush wants a { capacity } — the batched draw writes one array for `
				+ 'the whole class in a single crossing, and how long that array is has to be known. '
				+ 'Declare a capacity (columns are optional beside it), or move the nodes one at a time.'
			);
		}
		this._handles = new Int32Array(this.capacity * 2).fill(-1);
		this._transform = new Float32Array(this.capacity * TRANSFORM_STRIDE);
		for (let slot = 0; slot < this.instances.length; slot++) this.seat(this.instances[slot], slot);
	}

	// Fill one slot's handle and transform from the instance's object. Called on
	// spawn and when the batch is built late; a slot whose object has left the
	// scene keeps its -1 and the host skips it rather than raising.
	seat(instance, slot) {
		if (this._handles === null) return;
		const object = instance.object ?? null;
		if (object === null || object === undefined) { this._handles[slot * 2] = -1; return; }
		const [index, generation] = liveObject(object, `${this.name}.pose()`);
		this._handles[slot * 2] = index;
		this._handles[slot * 2 + 1] = generation;
		const at = slot * TRANSFORM_STRIDE;
		const t = this._transform;
		t[at] = object.position.x; t[at + 1] = object.position.y; t[at + 2] = object.position.z;
		t[at + 3] = object.rotation.x; t[at + 4] = object.rotation.y; t[at + 5] = object.rotation.z;
		t[at + 6] = object.scale.x; t[at + 7] = object.scale.y; t[at + 8] = object.scale.z;
	}

	get transform() { this.batch(); return this._transform; }

	// The live prefix of the handle array, which is what a sweep's `self` wants.
	get handles() {
		this.batch();
		const n = this.instances.length;
		if (this._liveHandleCount !== n) {
			this._liveHandles = this._handles.subarray(0, n * 2);
			this._liveHandleCount = n;
		}
		return this._liveHandles;
	}

	// Copy a position column into the transform column, with an optional
	// vertical offset and an optional heading — the three lines every
	// presentation system writes, because a capsule's centre and a model's
	// origin are never the same point.
	//
	// `heading` is a column name when there is one and an ordinary instance
	// field otherwise, so a class that keeps its heading as `this.heading`
	// poses exactly like one that declared a column for it.
	pose(field, options = null) {
		this.batch();
		const col = this.columns.get(field);
		if (col === undefined || col.stride !== 3) {
			throw new TypeError(`${this.name}.pose(field, options) wants a 3-float column, not ${JSON.stringify(field)}`);
		}
		const lift = +(options?.lift ?? 0);
		const heading = options?.heading ?? null;
		const headingCol = heading === null ? null : (this.columns.get(heading) ?? null);
		const t = this._transform;
		const p = col.array;
		const list = this.instances;
		for (let slot = 0; slot < list.length; slot++) {
			const at = slot * TRANSFORM_STRIDE, from = slot * 3;
			t[at] = p[from];
			t[at + 1] = p[from + 1] + lift;
			t[at + 2] = p[from + 2];
			if (headingCol !== null) t[at + 4] = headingCol.array[slot];
			else if (heading !== null) t[at + 4] = +(list[slot][heading] ?? 0);
		}
		return list.length;
	}

	// Copy the transform column onto the nodes — one crossing, however many
	// entities. Answers with how many landed.
	flush() {
		if (this._transform === null || this.instances.length === 0) return 0;
		const n = this.instances.length;
		return H.setTransforms(
			this._handles.buffer, this._handles.byteOffset, n * 2,
			this._transform.buffer, this._transform.byteOffset, n * TRANSFORM_STRIDE,
			BATCH_EULER);
	}

	// Copy the transform column back onto the Object3Ds, so `object.position`
	// and `object.rotation` agree with what was flushed.
	//
	// **The trap `three.batch` carries, for the same reason**: a flush writes the
	// NODE, and an object's transform is JavaScript numbers the host is never the
	// authority on. So after a flush the objects are stale, and writing any one
	// component of one — `object.position.y = 5` — sends all nine of ITS numbers
	// and undoes the flush for that entity. Call this before touching them by
	// hand. No crossing; this is JavaScript writing JavaScript.
	sync() {
		if (this._transform === null) return 0;
		const t = this._transform;
		let written = 0;
		for (let slot = 0; slot < this.instances.length; slot++) {
			const object = this.instances[slot].object ?? null;
			if (object === null || object === undefined) continue;
			const at = slot * TRANSFORM_STRIDE;
			object.position._x = t[at]; object.position._y = t[at + 1]; object.position._z = t[at + 2];
			object.rotation._x = t[at + 3]; object.rotation._y = t[at + 4]; object.rotation._z = t[at + 5];
			object._q = null;
			object.scale._x = t[at + 6]; object.scale._y = t[at + 7]; object.scale._z = t[at + 8];
			written++;
		}
		return written;
	}

	// Build one, place it, give it a body, and answer with it.
	spawn(args) {
		const where = `${this.name}.spawn(...)`;
		if (this.disposed) {
			throw new Error(
				`${where}: this class has been tracked and then disposed — its systems are out of the `
				+ 'registry and its name is free, so anything spawned now would be a node nothing '
				+ `compacts and nothing can find. three.track(${this.name}, options) makes a new one.`
			);
		}

		let slot = -1;
		if (this.capacity > 0) {
			if (this.instances.length >= this.capacity) {
				// The one place a slot moves mid-frame. Refusing would be worse
				// than compacting, and a class whose capacity is too small for
				// its own churn is what `Class.free` is for noticing before then.
				if (this.dead > 0) this.compact();
				if (this.instances.length >= this.capacity) {
					throw new RangeError(
						`${where}: ${this.name} is full at ${this.capacity} and none of them are dead. `
						+ 'A column cannot grow — every live view into it would dangle — so the capacity '
						+ 'is what it was declared as. Raise it, or remove something first.'
					);
				}
			}
			slot = this.instances.length;
			// Zeroed, every column, every time. A slot that came back holding
			// the last occupant's velocity shows up as one critter in fifty
			// behaving oddly, which is the worst kind of bug to go looking for.
			for (const col of this.columns.values()) {
				col.array.fill(0, slot * col.stride, (slot + 1) * col.stride);
			}
		}

		const outer = pending;
		// Set even when there is no slot: `pending` is what says "this
		// construction came through spawn", which is the check `three.Entity`'s
		// constructor makes, and only the slot half of it is optional.
		pending = { track: this, slot };
		let instance;
		try {
			instance = Reflect.construct(this.Class, args, this.Class);
		} finally {
			pending = outer;
		}
		if (instance === null || typeof instance !== 'object') {
			throw new TypeError(`${where}: the constructor answered with ${typeof instance} rather than an instance`);
		}

		instance[SLOT] = slot;
		instance[TRACK] = this;
		this.instances.push(instance);

		const object = instance.object ?? null;
		if (object !== null) {
			if (!(object instanceof Object3D)) {
				throw new TypeError(
					`${where}: this.object must be a Mesh or a Group — it is ${typeof object}. `
					+ 'It is what a raycast, a query and a trigger hand back, and what Class.of() resolves to.'
				);
			}
			// Named unconditionally, the way a Kind names its records. A mesh
			// already carries its GEOMETRY's name — a fresh box is called
			// 'box' — so "leave it alone if it has one" would never fire, and
			// what a scene tree wants is an identity per entity rather than
			// per shape. A constructor that wants its own name sets it in
			// onSpawn(), which runs after this.
			object.name = `${this.name}#${this.issued}`;
			this.issued++;

			// Not inherited, so it is a walk rather than one write on the root:
			// it says what one piece of GEOMETRY is, and a Group is not
			// geometry. Set before the add, so the materialize replays it in one
			// crossing rather than costing an index rebuild per mesh.
			if (this.collides !== undefined) {
				object.traverse(o => { if (o._ref() !== null) o.collides = this.collides; });
			}

			if (object.parent === null || object.parent === undefined) {
				(this.parent ?? currentScene(where)).add(object);
			}

			this.of.set(object, instance);
			owners.set(object, instance);

			if (this.body !== null) {
				const spec = typeof this.body === 'function' ? this.body(instance) : this.body;
				if (spec !== null && spec !== undefined) globalThis.three.physics.add(object, spec);
			}

			if (this.volume !== null) {
				const v = this.volume;
				const p = worldish(object);
				const volume = new Mesh(volumeGeometry(v.shape));
				volume.name = `${object.name}.volume`;
				volume.scale.set(v.size[0], v.size[1], v.size[2]);
				volume.position.set(p[0] + v.offset[0], p[1] + v.offset[1], p[2] + v.offset[2]);
				// There is nothing to see: a volume is reach, not geometry.
				volume.visible = false;
				volume.collides = false;
				currentScene(where).add(volume);
				// A trigger reports and lets things through; a solid one shoves.
				// Kinematic either way, because `follow` writes its position every
				// frame and a dynamic body would be fighting that write.
				globalThis.three.physics.add(volume, v.trigger
					? { shape: v.shape, mass: 0, trigger: true }
					: { shape: v.shape, mass: 0, kinematic: true });
				instance.volume = volume;
				this.of.set(volume, instance);
				owners.set(volume, instance);
			}
		}

		if (slot >= 0) this.seat(instance, slot);
		if (typeof instance.onSpawn === 'function') instance.onSpawn();
		return instance;
	}

	// The whole removal, in one call: the body goes, the trigger volume and its
	// body go, the node leaves the scene, and `of()` answers null — all before
	// this returns, because a crate broken inside a spin has to stop colliding
	// and stop drawing on this tick. Only the LIST waits for the frame boundary,
	// which is what makes `for (const c of Critter)` safe to remove from.
	//
	// Answers false for something already gone, so removing twice is a no-op:
	// a TNT that takes its neighbours with it reaches the same crate twice by
	// construction.
	remove(instance) {
		if (instance === null || instance === undefined) return false;
		if (instance[DEAD] === true) return false;
		if (instance[TRACK] !== this) return false;
		instance[DEAD] = true;
		this.dead++;

		const three = globalThis.three;
		const object = instance.object ?? null;
		if (object !== null) {
			this.of.delete(object);
			owners.delete(object);
			silentHost(() => { if (this.body !== null) three.physics.remove(object); });
			silentHost(() => { if (object.parent) object.parent.remove(object); });
		}
		const volume = instance.volume ?? null;
		if (volume !== null && volume !== undefined) {
			this.of.delete(volume);
			owners.delete(volume);
			silentHost(() => three.physics.remove(volume));
			silentHost(() => { if (volume.parent) volume.parent.remove(volume); });
		}
		if (typeof instance.onRemove === 'function') instance.onRemove();
		return true;
	}

	// Close the gaps left by removals, moving column data down with the
	// instances. Answers with how many went.
	//
	// Stable rather than a swap-remove: `count` is a pack rather than a particle
	// system, and a crowd that reorders itself whenever something dies makes
	// `three.steer`'s separation — which reads neighbours out of the same array
	// — behave differently for reasons nothing in the game can see.
	compact() {
		if (this.dead === 0) return 0;
		const list = this.instances;
		let write = 0;
		for (let read = 0; read < list.length; read++) {
			const instance = list[read];
			if (instance[DEAD] === true) continue;
			if (write !== read) {
				for (const col of this.columns.values()) {
					col.array.copyWithin(write * col.stride, read * col.stride, (read + 1) * col.stride);
				}
				if (this._handles !== null) {
					this._handles.copyWithin(write * 2, read * 2, (read + 1) * 2);
					this._transform.copyWithin(write * TRANSFORM_STRIDE, read * TRANSFORM_STRIDE, (read + 1) * TRANSFORM_STRIDE);
				}
				instance[SLOT] = write;
				list[write] = instance;
			}
			write++;
		}
		const removed = list.length - write;
		list.length = write;
		this.dead = 0;
		// Every cached live prefix is now the wrong length. The per-slot views
		// are still correct: they are a function of the slot, and the data moved
		// to match.
		for (const col of this.columns.values()) col.liveCount = -1;
		this._liveHandleCount = -1;
		return removed;
	}

	// Carry each volume to where its drawn object is. A volume is a SIBLING — a
	// body-backed node has to be a direct child of the scene, because the solver
	// works in world space — so something has to move it when the thing it
	// belongs to moves, and this is that something.
	follow() {
		if (this.volume === null) return 0;
		const offset = this.volume.offset;
		let moved = 0;
		for (const instance of this.live()) {
			const volume = instance.volume;
			const object = instance.object;
			if (volume === null || volume === undefined || object === null) continue;
			const p = worldish(object);
			volume.position.set(p[0] + offset[0], p[1] + offset[1], p[2] + offset[2]);
			moved++;
		}
		return moved;
	}

	*live() {
		const list = this.instances;
		for (let i = 0; i < list.length; i++) {
			if (list[i][DEAD] !== true) yield list[i];
		}
	}

	clear() {
		let removed = 0;
		for (const instance of [...this.live()]) if (this.remove(instance)) removed++;
		this.compact();
		return removed;
	}

	dispose() {
		try { this.clear(); } catch (_) { /* scene already gone — the name still has to come back */ }
		for (const name of this.systems) {
			try { systems.remove(name); } catch (_) {}
		}
		this.systems.length = 0;
		for (let i = rules.length - 1; i >= 0; i--) if (rules[i].track === this) removeRule(rules[i]);
		if (byName.get(this.name) === this) byName.delete(this.name);
		byClass.delete(this.Class);
		if (this.proxy !== null) byClass.delete(this.proxy);
		this.disposed = true;
	}
}

// ---------------------------------------------------------------------------
// three.track
// ---------------------------------------------------------------------------

// Track a class, and answer with it.
//
// **Use the answer.** It is a Proxy whose only job is to refuse a bare
// `new Class()`: an untracked instance has no slot, no body and no place in the
// live list, and every one of those failures is silent. `const Critter =
// three.track(class Critter { ... })` is the shape; ignoring the answer costs
// only that check.
// Drop every tracked class and give the names back. What `three.reset()` is
// for: a `run_script` of the same file cannot otherwise redeclare Player.
export function disposeAll() {
	for (const t of [...byName.values()]) t.dispose();
}

// Host verbs that name a node throw once its scene is gone. Dispose still has
// to free the class name in that case, so those calls are allowed to fail.
function silentHost(fn) {
	try { fn(); } catch (e) {
		const m = String(e && e.message || e);
		if (!/disposed|no longer in the scene/i.test(m)) throw e;
	}
}

export function track(Class, options = null) {
	const t = register(Class, options, 'three.track(Class, options)');

	// The Proxy exists for ONE reason: to refuse `new Class()` on a class with
	// no columns, where nothing else would notice. A class that declares one is
	// already caught by the column getter, and a `three.Entity` subclass by its
	// own constructor — so capturing this answer is optional in both of those
	// cases, and every static is on the class either way.
	const proxy = new Proxy(Class, {
		construct(target, args, newTarget) {
			if (pending === null || pending.track !== t) {
				throw new Error(
					`new ${t.name}() is not how a tracked class is built — ${t.name}.spawn(...) is. It `
					+ 'allocates the column slot before the constructor runs, adds the object to the '
					+ 'scene, gives it its body and puts it in the live list; an instance made with '
					+ '`new` has none of that and nothing would say so.'
				);
			}
			return Reflect.construct(target, args, newTarget);
		},
	});
	byClass.set(proxy, t);
	t.proxy = proxy;
	return proxy;
}

function register(Class, options, where) {
	if (typeof Class !== 'function' || !Class.prototype) {
		throw new TypeError(`${where} wants a class, not ${Class === null ? 'null' : typeof Class}`);
	}
	if (options !== null && typeof options !== 'object') {
		throw new TypeError(`${where} wants an options object, or nothing at all`);
	}
	if (byClass.has(Class)) {
		throw new Error(`${where}: ${Class.name} is tracked already — ${Class.name}.dispose() frees the name.`);
	}
	const name = String(options?.name ?? Class.name);
	if (name === '') {
		throw new TypeError(`${where}: an anonymous class needs a { name } — it is what prefixes its systems and its rules.`);
	}
	if (byName.has(name)) {
		throw new Error(
			`${where}: there is already a tracked class called '${name}' — it owns entities, so a second `
			+ 'one under the same name would leave the first\'s nodes and bodies with nothing to name '
			+ `them. Call ${name}.dispose() first if that is what you meant.`
		);
	}
	if (options?.parent !== undefined && options.parent !== null) {
		if (!(options.parent instanceof Object3D)) {
			throw new TypeError(`${where}: parent wants a Group to hang the built objects from`);
		}
		// The solver works in world space, so a parent transform would fight it.
		// Refused rather than ignored, because a crate under a group that
		// happened to be at the origin would work until somebody moved the group.
		if (options.body !== undefined && options.body !== null) {
			throw new Error(
				`${where}: a tracked class with a body cannot have a parent — the solver works in world `
				+ 'space, so a body-backed node has to be a direct child of the scene. Drop one of them.'
			);
		}
	}

	const t = new Track(Class, options, null);

	// Columns, and the getters that window them.
	const columns = options?.columns ?? null;
	if (columns !== null && columns !== undefined) {
		if (typeof columns !== 'object' || Array.isArray(columns)) {
			throw new TypeError(`${where}: columns is { position: 3, motion: 3 } — a field name to how many floats it is`);
		}
		const capacity = Math.floor(+(options?.capacity ?? 0));
		if (!(capacity > 0 && capacity <= MAX_CAPACITY)) {
			throw new RangeError(
				`${where}: columns need a { capacity } between 1 and ${MAX_CAPACITY}, not ${options?.capacity}. `
				+ 'A column cannot grow, because every live view into it would dangle — so how many there '
				+ 'can be is decided here rather than discovered.'
			);
		}
		t.capacity = capacity;
		for (const [field, raw] of Object.entries(columns)) {
			const stride = Math.floor(+raw);
			if (!(stride > 0 && stride <= 16)) {
				throw new RangeError(`${where}: columns.${field} is how many floats one entity gets — 1 to 16, not ${raw}`);
			}
			if (field in Class.prototype) {
				throw new TypeError(`${where}: columns.${field} would shadow a ${name} method of the same name`);
			}
			const col = { stride, array: new Float32Array(capacity * stride), views: new Array(capacity), live: null, liveCount: -1 };
			t.columns.set(field, col);
			Object.defineProperty(Class.prototype, field, {
				configurable: true,
				get() {
					const at = slotOf(this, field, name);
					return t.view(col, at);
				},
				// A getter with no setter, on purpose. `c.position[1] = 5` writes
				// the column; `c.position = [0, 5, 0]` would swap the window for
				// a plain array and the entity would silently stop steering,
				// which is a bug found by watching one enemy stand still.
				set(_) {
					throw new TypeError(
						`${name}.${field} is a window into a shared column and cannot be replaced — `
						+ `write through it (${field}[0] = x, or ${field}.set([x, y, z])) instead of `
						+ 'assigning over it.'
					);
				},
			});
		}
	}

	byName.set(name, t);
	byClass.set(Class, t);

	// Statics. Defined on the class rather than on the proxy so that a caller
	// who ignored the answer still gets everything but the `new` refusal.
	define(Class, 'spawn', (...args) => t.spawn(args));
	define(Class, 'of', object => resolve(object, t));
	define(Class, 'remove', instance => t.remove(instance));
	define(Class, 'column', field => t.column(field));
	define(Class, 'pose', (field, opts) => t.pose(field, opts));
	define(Class, 'flush', () => t.flush());
	define(Class, 'sync', () => t.sync());
	Object.defineProperty(Class, 'handles', { configurable: true, get: () => t.handles });
	Object.defineProperty(Class, 'transform', { configurable: true, get: () => t.transform });
	define(Class, 'all', () => [...t.live()]);
	define(Class, 'compact', () => t.compact());
	define(Class, 'clear', () => t.clear());
	define(Class, 'dispose', () => t.dispose());
	define(Class, 'on', (event, matcher, fn, opts) => addRule(t, event, matcher, fn, opts));
	// Registered under this class's name, so a report says `pack.chase` rather
	// than `chase`. With two classes running, the unprefixed name is the one
	// thing that makes a report unreadable.
	const addSystem = (verb, systemName, fn, opts) => {
		const full = `${name}.${systemName}`;
		systems[verb](full, fn, opts);
		if (!t.systems.includes(full)) t.systems.push(full);
		return full;
	};
	define(Class, 'system', (systemName, fn, opts) => addSystem('add', systemName, fn, opts));
	define(Class, 'step', (systemName, fn, opts) => addSystem('step', systemName, fn, opts));
	define(Class, 'frame', (systemName, fn, opts) => addSystem('frame', systemName, fn, opts));
	define(Class, 'off', ruleName => removeRuleByName(ruleName));
	define(Class, Symbol.iterator, () => t.live());
	Object.defineProperty(Class, 'count', { configurable: true, get: () => t.count });
	Object.defineProperty(Class, 'free', { configurable: true, get: () => (t.capacity > 0 ? t.capacity - t.instances.length + t.dead : Infinity) });
	Object.defineProperty(Class, 'capacity', { configurable: true, get: () => t.capacity });
	Object.defineProperty(Class, 'trackName', { configurable: true, get: () => name });

	// An instance's own removal, so `c.remove()` reads the way a person expects
	// and the four-line ritual has nowhere left to hide.
	if (typeof Class.prototype.remove !== 'function') {
		Object.defineProperty(Class.prototype, 'remove', {
			configurable: true, writable: true, enumerable: false,
			value: function () { return (this[TRACK] ?? t).remove(this); },
		});
	}

	systems.frame(`${name}.compact`, () => t.compact(), { order: Infinity });
	t.systems.push(`${name}.compact`);
	if (t.volume !== null) {
		// Two below the proximity pass: a `near` rule measures against the
		// VOLUME, so the volume has to have caught up first.
		systems.frame(`${name}.follow`, () => t.follow(), { order: LATE_ORDER - 2 });
		t.systems.push(`${name}.follow`);
	}

	return t;
}

// ---------------------------------------------------------------------------
// three.Entity
// ---------------------------------------------------------------------------

// The base class. `class Critter extends three.Entity` is the declaration form,
// and there is no `three.track` call beside it: the class is registered on first
// use, reading its own statics.
//
//     class Critter extends three.Entity {
//         static capacity = 32;
//         static parent = groups.pack;
//         static columns = { position: 3, motion: 3 };
//
//         constructor(at) {
//             super();
//             this.position[0] = at.x;      // the column window
//             this.stun = 0;                // an ordinary field
//             this.object = buildCritter().root;
//         }
//     }
//
// **`super()` first, and that is not a formality.** It is where the refusal of a
// bare `new Critter()` lives — no Proxy, no answer to capture, and it works for
// a class with no columns, which is the one case the getter cannot catch.
//
// The statics a subclass may declare are the options `three.track` takes:
// `capacity`, `columns`, `parent`, `body`, `trigger`, `collides`, and `name`
// (which is `Class.name` unless a `static name` overrides it).
//
// `three.track(Class, options)` is still there for a class that already has a
// parent and cannot extend this one. It is the same registration; the only
// difference is where the options are written.
export class Entity {
	constructor() {
		const Class = new.target;
		const t = byClass.get(Class);
		if (t === undefined || pending === null || pending.track !== t) {
			throw new Error(
				`new ${Class.name}() is not how an entity is built — ${Class.name}.spawn(...) is. It `
				+ 'allocates the column slot before the constructor runs, adds the object to the scene, '
				+ 'gives it its body and puts it in the live list; an instance made with `new` has none '
				+ 'of that and nothing would say so.'
			);
		}
	}

	// The whole removal: body, trigger volume, node and map entry, on this tick.
	remove() {
		const t = this[TRACK];
		return t === undefined ? false : t.remove(this);
	}

	static spawn(...args) { return entityTrack(this, 'spawn').spawn(args); }
	static of(object) { return resolve(object, entityTrack(this, 'of')); }
	static remove(instance) { return entityTrack(this, 'remove').remove(instance); }
	static column(field) { return entityTrack(this, 'column').column(field); }
	static all() { return [...entityTrack(this, 'all').live()]; }
	static compact() { return entityTrack(this, 'compact').compact(); }
	static clear() { return entityTrack(this, 'clear').clear(); }
	static dispose() { return entityTrack(this, 'dispose').dispose(); }
	static pose(field, options) { return entityTrack(this, 'pose').pose(field, options); }
	static flush() { return entityTrack(this, 'flush').flush(); }
	static sync() { return entityTrack(this, 'sync').sync(); }
	static on(event, matcher, fn, options) {
		return addRule(entityTrack(this, 'on'), event, matcher, fn, options);
	}
	static off(name) { return removeRuleByName(name); }
	// `Critter.step(name, fn)` and `Critter.frame(name, fn)` are the two to
	// reach for — the verb is the clock, the same as on `three.systems`, and
	// the class is what prefixes the name in a report. `system` is the same
	// with the phase left as an option, for when it is a variable.
	static system(name, fn, options) { return entitySystem(this, 'add', name, fn, options); }
	static step(name, fn, options) { return entitySystem(this, 'step', name, fn, options); }
	static frame(name, fn, options) { return entitySystem(this, 'frame', name, fn, options); }
	static get count() { return entityTrack(this, 'count').count; }
	static get free() {
		const t = entityTrack(this, 'free');
		return t.capacity > 0 ? t.capacity - t.instances.length + t.dead : Infinity;
	}
	static get handles() { return entityTrack(this, 'handles').handles; }
	static get transform() { return entityTrack(this, 'transform').transform; }
	static get trackName() { return entityTrack(this, 'trackName').name; }
	static [Symbol.iterator]() { return entityTrack(this, 'iteration').live(); }
}

// The Track for a `three.Entity` subclass, registering it on first use from its
// own statics. Lazy rather than eager because a class declaration cannot run
// anything: there is no moment between `class Critter extends three.Entity {}`
// and the first `Critter.spawn()` for a registration call to sit in, and
// inventing one — an explicit `three.track(Critter)` — is the line this form
// exists to remove.
// `Critter.step(...)` and the two beside it, which differ only in which door
// into the registry they take. The class name prefixes the system's, so
// `three.systems.report()` says `Critter.walk` rather than `walk` — with two
// classes running, an unprefixed name is the one thing that makes a report
// unreadable.
function entitySystem(Class, verb, name, fn, options) {
	const t = entityTrack(Class, verb === 'add' ? 'system' : verb);
	const full = `${t.name}.${name}`;
	systems[verb](full, fn, options);
	if (!t.systems.includes(full)) t.systems.push(full);
	return full;
}

function entityTrack(Class, what) {
	const had = byClass.get(Class);
	if (had !== undefined) return had;
	if (Class === Entity) {
		throw new TypeError(
			`three.Entity.${what} is not callable — three.Entity is the base class to extend, and the `
			+ 'entities belong to the subclass. class Critter extends three.Entity { ... } is the form.'
		);
	}
	if (!(Class.prototype instanceof Entity)) {
		throw new TypeError(`${Class.name}.${what} wants a class that extends three.Entity, or three.track(${Class.name})`);
	}
	return register(Class, {
		capacity: Class.capacity,
		columns: Class.columns,
		parent: Class.parent,
		body: Class.body,
		trigger: Class.trigger,
		volume: Class.volume,
		collides: Class.collides,
		name: Class.name,
	}, `class ${Class.name} extends three.Entity`);
}

// Which instance owns this object — a drawn node, one of its meshes, or a
// trigger volume — or null. Walks up the parent chain, because an assembled
// character is a Group of eleven meshes and a raycast hands back a leaf.
export function instanceOf(object) {
	return resolve(object, null);
}

// ---------------------------------------------------------------------------
// Rules
// ---------------------------------------------------------------------------

function addRule(t, event, matcher, fn, options = null) {
	const where = `${t.name}.on(event, matcher, fn, options)`;
	if (typeof event !== 'string' || event === '') {
		throw new TypeError(`${where} wants an event name — 'touch', 'enter', 'exit', 'near', 'click', or one of your own for three.emit`);
	}
	if (typeof fn !== 'function') {
		throw new TypeError(`${where} wants a handler, not ${fn === null ? 'null' : typeof fn}`);
	}
	if (fn.constructor && fn.constructor.name === 'AsyncFunction') {
		throw new TypeError(
			`${where}: a rule must be synchronous — an async one returns before it has done anything, `
			+ 'and the frame does not wait. Do the awaiting in a run_script.'
		);
	}
	if (matcher === undefined) {
		throw new TypeError(`${where} wants a matcher: a tracked class, an Object3D, '*' for anything, or a class name as a string`);
	}
	const within = options?.within === undefined ? 0 : +options.within;
	if (event === 'near' && !(within > 0)) {
		throw new RangeError(
			`${where}: a 'near' rule wants { within } in world units — it is a distance test the engine `
			+ 'runs for you, and without a radius there is nothing to test.'
		);
	}

	const name = String(options?.name ?? `${t.name}.${event}.${matcherName(matcher)}`);
	const rule = {
		track: t,
		event,
		matcher,
		fn,
		within,
		order: +(options?.order ?? 0),
		enabled: options?.enabled === undefined ? true : !!options.enabled,
		name,
		seq: ruleSeq++,
		failed: null,
		failures: 0,
	};

	// Replaced by name rather than added twice. Without this a re-run under a
	// hot reload doubles every rule, and the symptom is enemies dealing exactly
	// twice damage.
	const had = ruleByName.get(name);
	if (had !== undefined) { rule.seq = had.seq; removeRule(had); }

	rules.push(rule);
	ruleByName.set(name, rule);
	let bucket = byEvent.get(event);
	if (bucket === undefined) { bucket = []; byEvent.set(event, bucket); }
	bucket.push(rule);
	bucket.sort((a, b) => (a.order - b.order) || (a.seq - b.seq));

	ensureDrain();
	if (event === 'near') ensureNear(t);
	if (event === 'enter' || event === 'exit') ensureFeed('trigger');
	if (event === 'touch' || event === 'separate') ensureFeed('contact');
	if (event === 'click') ensureFeed('click');
	return name;
}

function removeRule(rule) {
	const at = rules.indexOf(rule);
	if (at >= 0) rules.splice(at, 1);
	const bucket = byEvent.get(rule.event);
	if (bucket !== undefined) {
		const i = bucket.indexOf(rule);
		if (i >= 0) bucket.splice(i, 1);
	}
	if (ruleByName.get(rule.name) === rule) ruleByName.delete(rule.name);
	return true;
}

function removeRuleByName(name) {
	const rule = ruleByName.get(String(name));
	return rule === undefined ? false : removeRule(rule);
}

// Does `other` — an instance or a bare object — satisfy this rule's matcher?
function matches(rule, otherInstance, otherObject) {
	const m = rule.matcher;
	if (m === '*' || m === null) return true;
	if (typeof m === 'string') {
		const t = byName.get(m);
		if (t === undefined) return false;
		return otherInstance !== null && otherInstance[TRACK] === t;
	}
	if (m instanceof Object3D) {
		if (otherObject === null) return false;
		for (let o = otherObject; o !== null && o !== undefined; o = o.parent) if (o === m) return true;
		return false;
	}
	if (typeof m === 'function') {
		return otherInstance !== null && otherInstance instanceof m;
	}
	return false;
}

// Call one rule, contained the way a system is. A rule that fails does so every
// frame, and one bad rule must not end the game.
function fire(rule, subject, other, info) {
	if (!rule.enabled) return;
	if (subject[DEAD] === true) return;
	try {
		rule.fn(subject, other, info);
	} catch (error) {
		const message = String(error && error.message ? error.message : error);
		if (rule.failed === message) {
			rule.failures++;
			if (rule.failures <= ERROR_REPEATS) console.log(`rule ${rule.name} threw: ${message}`);
		} else {
			rule.failed = message;
			rule.failures = 1;
			console.log(`rule ${rule.name} threw: ${message}`);
			if (error && error.stack) console.log(String(error.stack));
		}
	}
}

// One event over a pair of objects, both directions. `a` and `b` are objects
// (or instances, for `three.emit`); a side that is not tracked simply never
// matches as a subject, and can still be the OTHER of a rule matched on `'*'`
// or on that very object.
function dispatch(event, aObject, bObject, info) {
	const bucket = byEvent.get(event);
	if (bucket === undefined || bucket.length === 0) return 0;
	const aInstance = resolve(aObject, null);
	const bInstance = resolve(bObject, null);
	let fired = 0;
	for (let i = 0; i < bucket.length; i++) {
		const rule = bucket[i];
		if (aInstance !== null && aInstance[TRACK] === rule.track && matches(rule, bInstance, bObject)) {
			fire(rule, aInstance, bInstance ?? bObject, info);
			fired++;
		}
		if (bInstance !== null && bInstance[TRACK] === rule.track && matches(rule, aInstance, aObject)) {
			fire(rule, bInstance, aInstance ?? aObject, info);
			fired++;
		}
	}
	return fired;
}

// The game raising its own event. Dispatches AT ONCE, unlike an engine event:
// a quest step, a lever or a spin attack is raised from a place the game chose,
// and the game knows when it is safe to delete something.
export function emit(a, verb, b = null, info = null) {
	if (typeof verb !== 'string' || verb === '') {
		throw new TypeError('three.emit(a, verb, b) wants a verb name — the same string a rule was registered under');
	}
	return dispatch(verb, objectFor(a), objectFor(b), info);
}

// ---------------------------------------------------------------------------
// The feeds
// ---------------------------------------------------------------------------

function ensureDrain() {
	if (drainRegistered) return;
	drainRegistered = true;
	systems.frame('rules', () => drain(), { order: DRAIN_ORDER });
}

// Drain the queued engine events. Answers with how many were delivered, which
// is what makes `three.systems.report()` able to say what rules cost.
export function drain() {
	if (queue.length === 0) return 0;
	// Taken as a batch: a rule that raises its own event through three.emit
	// dispatches at once and must not extend the loop it is running inside.
	const batch = queue.splice(0, queue.length);
	for (let i = 0; i < batch.length; i++) {
		const e = batch[i];
		dispatch(e.event, e.a, e.b, e.info);
	}
	return batch.length;
}

function ensureNear(t) {
	const name = `${t.name}.near`;
	if (t.systems.includes(name)) return;
	t.systems.push(name);
	systems.frame(name, () => nearPass(t), { order: LATE_ORDER - 1 });
}

// Every 'near' rule on this class, as a distance test over the live lists.
//
// This is the event that matters and the one physics does not raise:
// `three.moveAndSlide` produces no contact, so a player moved by it either
// carries a phantom kinematic capsule purely to trip triggers, or the game
// writes the hypot by hand. This is that loop, once.
//
// It fires every tick while the two are within the radius rather than on the
// crossing, because that is what the hand-written version it replaces did — a
// rule that wants the edge keeps its own flag.
function nearPass(t) {
	const bucket = byEvent.get('near');
	if (bucket === undefined) return 0;
	let fired = 0;
	for (let i = 0; i < bucket.length; i++) {
		const rule = bucket[i];
		if (rule.track !== t || !rule.enabled) continue;
		const r2 = rule.within * rule.within;
		const others = othersFor(rule);
		if (others === null) continue;
		for (const subject of t.live()) {
			const a = positionOf(subject);
			if (a === null) continue;
			for (const other of others) {
				const b = positionOf(other);
				if (b === null || other === subject) continue;
				const dx = a[0] - b[0], dy = a[1] - b[1], dz = a[2] - b[2];
				const d2 = dx * dx + dy * dy + dz * dz;
				if (d2 > r2) continue;
				fire(rule, subject, other, { distance: Math.sqrt(d2) });
				fired++;
				if (subject[DEAD] === true) break;
			}
		}
	}
	return fired;
}

// What a 'near' rule tests the subjects against. A tracked class is its live
// list; an Object3D is itself. `'*'` is refused at registration for this event
// — everything in the scene against everything is not a distance test anybody
// meant to ask for.
function othersFor(rule) {
	const m = rule.matcher;
	// An ARRAY and not the live generator: the inner loop runs once per
	// subject, and a generator is exhausted after the first of them — which
	// reads as the rule working for one entity and no others.
	if (typeof m === 'function') {
		const t = byClass.get(m);
		return t === undefined ? null : [...t.live()];
	}
	if (typeof m === 'string') {
		const t = byName.get(m);
		return t === undefined ? null : [...t.live()];
	}
	if (m instanceof Object3D) return [m];
	return null;
}

// Where something is, preferring a declared `position` column over the node —
// the column is where a steered crowd's truth lives, and the node is a frame
// behind it until the draw system runs — and preferring a VOLUME over the drawn
// node, because proximity is about where the collision shape is. A character's
// node sits at its feet and its capsule sits at its middle, and half a body
// height is most of a `within` radius.
function positionOf(thing) {
	if (thing === null || thing === undefined) return null;
	const t = thing[TRACK];
	if (t !== undefined && t.columns.has('position')) {
		const v = t.view(t.columns.get('position'), thing[SLOT]);
		if (v.length >= 3) return v;
	}
	if (t !== undefined && t.volume !== null) {
		const volume = thing.volume;
		if (volume !== null && volume !== undefined) {
			const p = volume.position;
			return [p.x, p.y, p.z];
		}
	}
	const object = thing instanceof Object3D ? thing : (thing.object ?? null);
	if (object === null || object === undefined) return null;
	const p = object.position;
	return [p.x, p.y, p.z];
}

// The host's three handler slots, bound on demand and multiplexed: rules first,
// then the script's own handler under exactly its old contract.
//
// **Each wrapper RETURNS what the script's handler returned.** `frame_loop.c3`
// stops a callback that answers with a promise, and that contract belongs to
// `three.onClick` and `three.onTrigger` rather than to this file — a wrapper
// that swallowed the answer would quietly turn "an async handler is stopped"
// into "an async handler runs forever, doing nothing".
function ensureFeed(which) {
	if (bound[which]) return;
	bound[which] = true;
	if (which === 'trigger') {
		H.onTrigger(raw => {
			const trigger = objectForHandle(raw.trigger);
			const other = objectForHandle(raw.other);
			queue.push({ event: raw.type === 'exit' ? 'exit' : 'enter', a: trigger, b: other, info: { type: raw.type } });
			const fn = scriptHandler.trigger;
			return fn === null ? undefined : fn({ type: raw.type, trigger, other });
		});
	} else if (which === 'contact') {
		H.onContact(raw => {
			const a = objectForHandle(raw.a);
			const b = objectForHandle(raw.b);
			const normal = new Vector3(null, raw.normal[0], raw.normal[1], raw.normal[2]);
			const point = new Vector3(null, raw.point[0], raw.point[1], raw.point[2]);
			queue.push({ event: raw.type === 'end' ? 'separate' : 'touch', a, b, info: { type: raw.type, normal, point } });
			const fn = scriptHandler.contact;
			return fn === null ? undefined : fn({ type: raw.type, a, b, normal, point });
		});
	} else {
		H.onClick((raw, x, y) => {
			const hit = clickShaper === null ? null : clickShaper(raw);
			// A click is one-sided: there is no second thing, so the rule's
			// matcher is tested against nothing and only `'*'` — or the object
			// itself — can match.
			const object = hit === null ? null : hit.object;
			if (object !== null && object !== undefined) {
				dispatch('click', object, null, { x, y, hit });
			}
			const fn = scriptHandler.click;
			return fn === null ? undefined : fn(hit, x, y);
		});
	}
}

// `three.onTrigger`, `three.onContact` and `three.onClick` write here. Their
// documented contract is unchanged — one handler, binding again replaces, null
// unbinds, an async one is refused and a throw stops it for good — and the only
// difference is that this file owns the host slot so that rules and a script
// handler can both have it.
export function setScriptHandler(which, fn, where) {
	if (fn === null || fn === undefined) {
		scriptHandler[which] = null;
		return;
	}
	if (typeof fn !== 'function') {
		throw new TypeError(`${where}(fn) wants a function, or null to unbind`);
	}
	if (fn.constructor && fn.constructor.name === 'AsyncFunction') {
		throw new TypeError(
			`a ${where.replace('three.on', '').toLowerCase()} handler must be synchronous — an async one `
			+ 'returns before it has done anything, and the frame does not wait. '
			+ 'Do the awaiting in a run_script.'
		);
	}
	scriptHandler[which] = fn;
	ensureFeed(which);
}

// api.js hands its intersection shaper over once, rather than this file growing
// a second copy of it.
export function setClickShaper(fn) { clickShaper = fn; }

// What every rule is costing, beside `three.systems.report()`'s per-system
// milliseconds — the CPU half of the CPU half.
export function report() {
	return rules.map(r => ({
		name: r.name,
		event: r.event,
		subject: r.track.name,
		matcher: matcherName(r.matcher),
		order: r.order,
		enabled: r.enabled,
		failures: r.failures,
	}));
}

// ---------------------------------------------------------------------------
// Private
// ---------------------------------------------------------------------------

function define(target, key, value) {
	Object.defineProperty(target, key, { configurable: true, writable: true, enumerable: false, value });
}

function slotOf(instance, field, className) {
	const at = instance[SLOT];
	if (at !== undefined && at >= 0) return at;
	if (pending !== null && pending.slot >= 0) return pending.slot;
	throw new Error(
		`${className}.${field} is a column and this instance has no slot — it was made with `
		+ `new ${className}() rather than ${className}.spawn(...), so nothing allocated one.`
	);
}

// An object, one of its meshes, or a trigger volume, back to the instance —
// walking up the parent chain, because a query and a raycast answer with the
// leaf that was hit and an assembled character is a Group of eleven of them.
function resolve(object, only) {
	if (object === null || object === undefined) return null;
	// An instance handed straight in — what three.emit takes.
	if (object[TRACK] !== undefined) {
		return only === null || object[TRACK] === only ? object : null;
	}
	if (!(object instanceof Object3D)) return null;
	for (let o = object; o !== null && o !== undefined; o = o.parent) {
		const found = only === null ? owners.get(o) : only.of.get(o);
		if (found !== undefined) return found;
	}
	return null;
}

// The Object3D three.emit should dispatch on: an instance's node, or the thing
// itself when it is already one.
function objectFor(thing) {
	if (thing === null || thing === undefined) return null;
	if (thing[TRACK] !== undefined) return thing;
	return thing;
}

function matcherName(m) {
	if (m === '*' || m === null) return 'any';
	if (typeof m === 'string') return m;
	if (typeof m === 'function') return m.name || 'class';
	if (m instanceof Object3D) return m.name || 'object';
	return 'matcher';
}

function currentScene(where) {
	if (liveScene === null) {
		throw new Error(`${where}: there is no scene yet — new three.Scene() first, then spawn into it`);
	}
	return liveScene;
}

// `volume` and `trigger` are the same declaration; `trigger` is the spelling
// that turns the flag on. A class gets at most one, because a second one would
// need a second field to hold it and a second name to resolve back through.
function readVolumeOption(options, where) {
	const solid = options?.volume ?? null;
	const sensor = options?.trigger ?? null;
	if (solid !== null && sensor !== null) {
		throw new Error(
			`${where}: volume and trigger are the same node — a trigger IS a volume with `
			+ 'trigger: true. Declare one of them.'
		);
	}
	if (sensor !== null) return readVolume(sensor, where, true);
	if (solid !== null) return readVolume(solid, where, false);
	return null;
}

// `{ shape, radius | size | height, offset }` into the scale a unit shape wants.
//
// `radius` is a WORLD radius rather than a scale factor: a unit sphere of radius
// 0.5 scaled by 1.8 is a volume 0.9 across, and a script that wrote 1.8 meaning
// 1.8 would have a pickup half the size it asked for and no way to see it.
function readVolume(spec, where, trigger) {
	const what = trigger ? 'trigger' : 'volume';
	if (typeof spec !== 'object') {
		throw new TypeError(`${where}: ${what} wants { shape: 'sphere', radius }, { shape: 'box', size } or { shape: 'capsule', radius, height }`);
	}
	const shape = spec.shape === undefined ? 'sphere' : String(spec.shape);
	if (shape !== 'sphere' && shape !== 'box' && shape !== 'capsule') {
		throw new RangeError(
			`${where}: ${what}.shape is 'sphere', 'box' or 'capsule', not ${JSON.stringify(spec.shape)} — a `
			+ 'volume is reach rather than geometry, and those are the three shapes reach comes in.'
		);
	}
	let size;
	if (shape === 'box') {
		size = readVector(spec.size ?? null, `${where}: ${what}.size`);
		if (!size.every(n => n > 0)) {
			throw new RangeError(`${where}: ${what}.size must be a positive [width, height, depth], not ${JSON.stringify(spec.size)}`);
		}
	} else {
		const r = +(spec.radius ?? 0);
		if (!(r > 0)) throw new RangeError(`${where}: ${what}.radius must be a positive world radius, not ${spec.radius}`);
		if (shape === 'sphere') {
			size = [r * 2, r * 2, r * 2];
		} else {
			const h = +(spec.height ?? 0);
			if (!(h > 0)) {
				throw new RangeError(
					`${where}: ${what}.height must be the capsule's positive full height, not ${spec.height}`
				);
			}
			size = [r * 2, h, r * 2];
		}
	}
	const offset = spec.offset === undefined || spec.offset === null
		? [0, 0, 0]
		: readVector(spec.offset, `${where}: ${what}.offset`);
	return { shape, size, offset, trigger: !!trigger };
}

function volumeGeometry(shape) {
	if (VOLUME_GEOMETRY[shape] === null) {
		VOLUME_GEOMETRY[shape] = shape === 'sphere' ? new SphereGeometry(0.5, 8, 6)
			: shape === 'capsule' ? new CylinderGeometry(0.5, 0.5, 1)
			: new BoxGeometry(1, 1, 1);
	}
	return VOLUME_GEOMETRY[shape];
}

// Where a volume has to be put. `object.position` is LOCAL, and a drawn node is
// allowed a parent while its volume is not — so a parented one is asked for its
// world position, and everything else stays on the free path.
function worldish(object) {
	const parent = object.parent;
	if (parent === null || parent === undefined || parent === liveScene) {
		const p = object.position;
		return [p.x, p.y, p.z];
	}
	const w = object.getWorldPosition();
	return [w.x, w.y, w.z];
}
