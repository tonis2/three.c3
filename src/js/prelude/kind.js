// three.c3 — a kind of thing in the world, addressed by object identity.
// `notes.md` §22.
//
// ## What a Kind is, and why it is not a Cast
//
// `three.cast` is N things of one kind stored as COLUMNS, because a column is
// the buffer `three.steer` and `three.moveAndSlideAll` take. That is the right
// shape for a crowd that moves every frame and the wrong one for the two dozen
// crates in a level, which are addressed by the object a query or a trigger
// hands back and never appear in a bulk verb at all. `notes.md` §21 says so
// about the fruit — "not everything is a cast, and a design that cannot say so
// is a design being sold" — and then leaves the alternative to be hand-rolled.
//
// This is the alternative. `examples/wumpa_run.js` hand-rolled it three times:
// an array, a `Map` from object back to record, an `alive` flag, and a four-line
// removal ritual that has to remember the body, the node, the map and the flag,
// in that order, at every call site that can destroy one.
//
//     const crate = three.kind('crate', {
//         build: p => { const m = new three.Mesh(BOX, KIND[p.k].mat); m.scale.set(1.35, 1.35, 1.35); return m; },
//         body:  { shape: 'box', mass: 5, friction: 0.7 },
//         data:  p => ({ ...KIND[p.k], variant: p.k }),
//     });
//
//     const c = crate.spawn([x, y, z], { k: 'tnt', yaw });   // the record
//     crate.of(hit.object)                                   // record, or null
//     crate.remove(c)                                        // the whole ritual
//     for (const c of crate) ...                             // the live ones
//     three.kindOf(object)                                   // which kind owns it
//
// ## A removal is immediate and the LIST compacts at the end of the frame
//
// This is the opposite half of the Cast's rule and it is deliberate. A cast is
// indexed by slot, so a removal that closed the gap on the spot would move
// everybody else's index under whatever system was holding one — the bug that
// looks like the wrong entity taking damage. A kind is addressed by object
// identity, and an object does not move: so the thing that has to happen at once
// is the thing a player can SEE. `breakCrate` is called from inside a spin, and
// the crate must stop colliding and stop drawing on that tick, not on the next
// one — a crate you walked through the ghost of would be the bug here.
//
// So `remove` takes the body away, takes the node out of the scene and makes
// `of()` answer null, all before it returns; what it does not do is splice the
// live list, because a `for (const c of crate)` running when a TNT goes off is
// exactly the loop that removes things. The list is compacted by a system named
// `<kind>.compact` registered last in the frame phase — the same shape and the
// same place `Cast` puts its own, for a different reason.
//
// ## The trigger volume is a SIBLING, and that is why it has to be followed
//
// A body-backed node has to be a direct child of the scene: the solver works in
// world space and a parent transform would fight it. So a pickup that draws at
// 0.31 units and is collected at 0.9 is two nodes side by side rather than a
// mesh with a volume under it, and if the drawn one moves the volume does not
// come with it.
//
// A kind with a `trigger` therefore registers `<kind>.follow`, a frame system
// that copies each live record's `object.position` into `volume.position`. A
// write to a transform is a crossing, so that is ONE crossing per entity per
// frame — §17 measured five hundred of them at 0.245 ms, so a few dozen pickups
// is not a number anybody will find in a report and two thousand of them would
// be. It is opt-in by having a trigger at all: a kind that declares none
// registers nothing and costs nothing.
//
//   It runs at order 1e6: after the systems that move things, before the
//   compaction at Infinity. A system that has to see the volume already moved
//   says so with a larger order.
//
// ## A name is a registry entry, so a duplicate raises
//
// `three.systems.add` REPLACES by name, because a hot-reloaded script re-running
// its top level should end up with one copy of each system and a name is the
// only identity a re-evaluated closure keeps. A kind cannot do that: it owns
// entities, and replacing one silently would leave a scene full of nodes and
// bodies that nothing can name any more. So a second `three.kind('crate', …)`
// throws and says that `crate.dispose()` is what frees the name.
import { systems } from './systems.js';
import { liveScene } from './scene.js';
import { Object3D } from './object3d.js';
import { Mesh } from './mesh.js';
import { readVector } from './math.js';
import { BoxGeometry, SphereGeometry } from './geometry.js';

// Where `<kind>.follow` runs. Late in the frame phase, so a system that moved
// the drawn object has already moved it; before `<kind>.compact`, which is at
// Infinity.
const FOLLOW_ORDER = 1e6;

// Attached to every record by `spawn`, so `data` may not answer with one of
// them. Three names is the whole of what a kind takes out of a record's
// namespace, and taking them silently would be worse than refusing: a record
// whose `kind` field was quietly replaced reads back as the wrong thing with
// nothing raised anywhere.
const RESERVED = ['object', 'volume', 'kind'];

// Not an enumerable field, because a record is a plain object a script puts its
// own fields on and `JSON.stringify(record)` should not answer with a
// bookkeeping flag it never set.
const DEAD = Symbol('kind.dead');

// Every kind by name — see the header for why a duplicate is refused rather
// than replaced.
const registry = new Map();

// Every object a kind owns, drawn nodes and trigger volumes alike, back to the
// Kind that owns it. `three.kindOf(object)` is the reverse of `kind.of(object)`
// across all of them, and it is what a rule keyed on "what are these two
// things" needs before it can ask either kind anything.
const owners = new Map();

// The shapes a trigger volume can take. A volume is never drawn, so these are
// as coarse as the collider allows — the vertices still lie on the sphere, so
// the radius the solver derives from the mesh is the radius asked for.
let TRIGGER_SPHERE = null;
let TRIGGER_BOX = null;

export class Kind {
	// `three.kind(name, spec)`. See the module header for the shape and
	// `docs.js` for the prose.
	constructor(name, spec = null) {
		const where = 'three.kind(name, spec)';
		if (typeof name !== 'string' || name === '') {
			throw new TypeError(`${where} wants a name, not ${JSON.stringify(name)}`);
		}
		if (registry.has(name)) {
			throw new Error(
				`${where}: there is already a kind called '${name}' — a kind owns its entities, so a `
				+ 'second one under the same name would leave the first\'s nodes and bodies with '
				+ `nothing to name them. Call ${name}.dispose() first if that is what you meant.`
			);
		}
		if (spec === null || typeof spec !== 'object') {
			throw new TypeError(`${where} wants a spec object with at least a build(params) in it`);
		}
		if (typeof spec.build !== 'function') {
			throw new TypeError(`${where}: spec.build must be a function of the spawn's params answering an Object3D`);
		}
		if (spec.data !== undefined && typeof spec.data !== 'function') {
			throw new TypeError(`${where}: spec.data must be a function of the spawn's params answering a plain object`);
		}
		if (spec.body !== undefined && spec.body !== null
			&& typeof spec.body !== 'object' && typeof spec.body !== 'function') {
			throw new TypeError(`${where}: spec.body is the options object three.physics.add takes, or a function of params answering one`);
		}
		if (spec.parent !== undefined && spec.parent !== null) {
			if (!(spec.parent instanceof Object3D)) {
				throw new TypeError(`${where}: spec.parent wants a Group to hang the built objects from`);
			}
			// The rule `examples/wumpa_run.js` states at the top of its groups:
			// the solver works in world space, so a parent transform would
			// fight it. Refused rather than ignored, because a crate under a
			// group that happened to be at the origin would work until somebody
			// moved the group.
			if (spec.body !== undefined && spec.body !== null) {
				throw new Error(
					`${where}: a kind with a body cannot have a parent — the solver works in world space, `
					+ 'so a body-backed node has to be a direct child of the scene and a parent transform '
					+ 'would fight it. Drop the parent, or drop the body.'
				);
			}
			if (spec.trigger !== undefined && spec.trigger !== null) {
				throw new Error(
					`${where}: a kind with a trigger cannot have a parent — the trigger volume is a body, `
					+ 'and a body-backed node has to be a direct child of the scene.'
				);
			}
		}
		this._trigger = spec.trigger === undefined || spec.trigger === null
			? null
			: readTrigger(spec.trigger, where);

		this._name = name;
		this._build = spec.build;
		this._data = spec.data ?? null;
		this._body = spec.body ?? null;
		this._parent = spec.parent ?? null;
		this._collides = spec.collides === undefined ? undefined : !!spec.collides;
		this._prefix = spec.name === undefined ? name : String(spec.name);

		// The live list, dead-but-not-yet-compacted records included, and the
		// object -> record map that makes `of` a lookup rather than a scan.
		this._records = [];
		this._of = new Map();
		this._dead = 0;
		this._issued = 0;
		// A disposed kind has no compaction system and no name in the registry,
		// so a spawn on one would put a node in the scene that nothing would
		// ever clean up and nothing could find. See `dispose`.
		this._disposed = false;

		this._systems = [`${name}.compact`];
		systems.add(`${name}.compact`, () => this.compact(), { phase: 'frame', order: Infinity });
		if (this._trigger !== null) {
			this._systems.push(`${name}.follow`);
			systems.add(`${name}.follow`, () => this.follow(), { phase: 'frame', order: FOLLOW_ORDER });
		}

		registry.set(name, this);
	}

	// The name this kind was registered under, and what prefixes its systems —
	// `crate.compact` rather than `compact`, for the same reason a Cast prefixes
	// its own: with two kinds running, the unprefixed name is the one thing that
	// makes a report unreadable.
	get name() { return this._name; }

	// How many are alive. Not the length of the list: a record removed this
	// frame is still in it until the compaction, and it is not one of these.
	get count() { return this._records.length - this._dead; }

	// --------------------------------------------------------------- entities

	// Build one, place it, give it a body, and answer with its record.
	//
	// `position` is a Vector3, an `{x, y, z}` or an `[x, y, z]`; `params` is
	// handed to `build` and to `data` unchanged, and `params.yaw` — if it is a
	// number — is written to `object.rotation.y`, because a thing placed along a
	// path is placed with a heading and that is the one rotation a game types by
	// hand.
	spawn(position, params = {}) {
		const where = `${this._name}.spawn(position, params)`;
		if (this._disposed) {
			throw new Error(
				`${where}: this kind has been disposed — its systems are out of the registry and its `
				+ 'name is free, so anything spawned now would be a node nothing compacts and nothing '
				+ `can find. three.kind('${this._name}', spec) makes a new one.`
			);
		}
		const [x, y, z] = readVector(position, where);
		if (params === null || typeof params !== 'object') {
			throw new TypeError(`${where} wants an object for its params, or nothing at all`);
		}

		// The record FIRST, and its reserved keys checked before anything is
		// built: a `data` that answers with an `object` is a mistake in the
		// spec rather than in this spawn, and finding out after the node is in
		// the scene and the body is in the solver leaves both behind with
		// nothing holding them.
		const record = this._data === null ? {} : this._data(params);
		if (record === null || typeof record !== 'object' || Array.isArray(record)) {
			throw new TypeError(`${where}: data(params) must answer with a plain object, not ${JSON.stringify(record) ?? typeof record}`);
		}
		for (const key of RESERVED) {
			if (key in record) {
				throw new TypeError(
					`${where}: data(params) answered with a '${key}', and a record's ${RESERVED.join(', ')} `
					+ 'are the kind\'s — they are what makes a record findable from the thing you hit. '
					+ 'Give it another name.'
				);
			}
		}

		const object = this._build(params);
		if (!(object instanceof Object3D)) {
			throw new TypeError(
				`${where}: build(params) must answer with a Mesh or a Group — it answered with `
				+ `${object === null ? 'null' : typeof object}`
			);
		}
		object.name = `${this._prefix}#${this._issued++}`;
		object.position.set(x, y, z);
		if (params.yaw !== undefined) {
			if (!Number.isFinite(+params.yaw)) {
				throw new TypeError(`${where}: params.yaw is a heading in radians, not ${params.yaw}`);
			}
			object.rotation.y = +params.yaw;
		}
		// Not inherited, so it is a walk rather than one write on the root: it
		// says what one piece of GEOMETRY is, and a Group is not geometry. Set
		// before the add, so `_materialize` replays it in one crossing rather
		// than this costing an index rebuild per mesh.
		if (this._collides !== undefined) {
			object.traverse(o => { if (o._ref() !== null) o.collides = this._collides; });
		}

		const scene = currentScene(where);
		(this._parent ?? scene).add(object);

		if (this._body !== null) {
			const options = typeof this._body === 'function' ? this._body(params) : this._body;
			globalThis.three.physics.add(object, options);
		}

		let volume = null;
		if (this._trigger !== null) {
			const t = this._trigger;
			volume = new Mesh(t.shape === 'sphere' ? triggerSphere() : triggerBox());
			volume.name = `${this._prefix}#${this._issued - 1}.volume`;
			volume.scale.set(t.size[0], t.size[1], t.size[2]);
			volume.position.set(x + t.offset[0], y + t.offset[1], z + t.offset[2]);
			// There is nothing to see: the volume is reach, not geometry.
			volume.visible = false;
			volume.collides = false;
			scene.add(volume);
			globalThis.three.physics.add(volume, { shape: t.shape, mass: 0, trigger: true });
		}

		record.object = object;
		record.volume = volume;
		record.kind = this;

		this._records.push(record);
		this._of.set(object, record);
		owners.set(object, this);
		if (volume !== null) {
			this._of.set(volume, record);
			owners.set(volume, this);
		}
		return record;
	}

	// The record for a drawn object OR for its trigger volume, or null.
	//
	// Both, because the two things that hand a script an object hand it
	// different ones: a query and a raycast answer with what is DRAWN, and
	// `three.onTrigger` answers with the volume. A caller should not have to
	// know which door the object came through.
	of(object) {
		return this._of.get(object) ?? null;
	}

	// The whole removal, in one call: the body goes, the trigger volume and its
	// body go, the node leaves the scene, and `of()` answers null — all before
	// this returns, because a crate broken inside a spin has to stop colliding
	// and stop drawing on this tick. Only the LIST waits for the frame boundary.
	//
	// Answers false for a record that is already gone, so removing twice is a
	// no-op rather than an error: a TNT that takes its neighbours with it
	// reaches the same crate twice by construction.
	remove(record) {
		if (record === null || record === undefined) return false;
		if (typeof record !== 'object') {
			throw new TypeError(`${this._name}.remove(record) wants a record from ${this._name}.spawn() or ${this._name}.of(object)`);
		}
		if (record[DEAD] === true) return false;
		if (this._of.get(record.object) !== record) return false;
		record[DEAD] = true;
		this._dead++;

		const three = globalThis.three;
		const object = record.object;
		this._of.delete(object);
		owners.delete(object);
		if (this._body !== null) three.physics.remove(object);
		if (object.parent) object.parent.remove(object);

		if (record.volume !== null) {
			this._of.delete(record.volume);
			owners.delete(record.volume);
			three.physics.remove(record.volume);
			if (record.volume.parent) record.volume.parent.remove(record.volume);
		}
		return true;
	}

	// Every live record, in the order they were spawned.
	//
	// Safe to remove from while iterating — `remove` marks and does not splice,
	// and the compaction is a frame boundary away — which is what a TNT taking
	// its neighbours out from inside `for (const c of crate)` needs.
	*[Symbol.iterator]() {
		for (let i = 0; i < this._records.length; i++) {
			const record = this._records[i];
			if (record[DEAD] !== true) yield record;
		}
	}

	// The live records as an ordinary Array — for a caller that wants to sort
	// them, or to hold the list across a removal.
	all() {
		return this._records.filter(r => r[DEAD] !== true);
	}

	// ------------------------------------------------------------------ frame

	// Drop the removed records from the live list. Answers with how many went.
	//
	// Registered as `<kind>.compact` last in the frame phase, so a game using
	// systems never calls this. A game driving its own loop does.
	compact() {
		if (this._dead === 0) return 0;
		const removed = this._dead;
		this._records = this._records.filter(r => r[DEAD] !== true);
		this._dead = 0;
		return removed;
	}

	// Carry each trigger volume to where its drawn object is. Answers with how
	// many moved.
	//
	// Registered as `<kind>.follow` only when the kind declares a trigger — see
	// the module header for why the volume is a sibling and not a child.
	follow() {
		if (this._trigger === null) return 0;
		const offset = this._trigger.offset;
		let moved = 0;
		for (const record of this) {
			const p = record.object.position;
			record.volume.position.set(p.x + offset[0], p.y + offset[1], p.z + offset[2]);
			moved++;
		}
		return moved;
	}

	// ------------------------------------------------------------- teardown

	// Remove every entity and keep the kind — a level boundary for one sort of
	// thing. The systems stay registered and the name stays taken.
	clear() {
		let removed = 0;
		for (const record of this.all()) if (this.remove(record)) removed++;
		this.compact();
		return removed;
	}

	// Remove every entity, take this kind's systems out of the registry and give
	// the name back. The Kind is dead afterwards and a spawn on it throws.
	dispose() {
		this.clear();
		for (const name of this._systems) systems.remove(name);
		this._systems.length = 0;
		if (registry.get(this._name) === this) registry.delete(this._name);
		this._disposed = true;
	}

	toString() { return `Kind(${this._name}: ${this.count})`; }
}

// A kind of thing in the world, addressed by object identity.
export function kind(name, spec = null) { return new Kind(name, spec); }

// Which Kind owns this object — the drawn node or a trigger volume — or null.
//
// The reverse map every kind writes into, kept globally rather than per kind so
// that a caller holding two objects and no idea what either is can ask. That is
// the question a rule keyed on "what are these two things" opens with, and
// asking every kind in turn is the loop this exists to remove.
export function kindOf(object) {
	return owners.get(object) ?? null;
}

// -----------------------------------------------------------------------
// Private

function currentScene(where) {
	if (liveScene === null) {
		throw new Error(`${where}: there is no scene yet — new three.Scene() first, then spawn into it`);
	}
	return liveScene;
}

// `{ shape, radius | size, offset }` into the scale a unit shape wants.
//
// `radius` is a WORLD radius rather than a scale factor, which is worth saying
// because the shape underneath it is a unit one: a sphere of radius 0.5 scaled
// by 1.8 is a volume 0.9 across, and a script that wrote 1.8 meaning 1.8 would
// have a pickup half the size it asked for and no way to see that from here.
function readTrigger(spec, where) {
	if (typeof spec !== 'object') {
		throw new TypeError(`${where}: spec.trigger wants { shape: 'sphere', radius } or { shape: 'box', size }`);
	}
	const shape = spec.shape === undefined ? 'sphere' : String(spec.shape);
	if (shape !== 'sphere' && shape !== 'box') {
		throw new RangeError(
			`${where}: spec.trigger.shape is 'sphere' or 'box', not ${JSON.stringify(spec.shape)} — `
			+ 'a volume is reach rather than geometry, and those are the two shapes reach comes in.'
		);
	}
	let size;
	if (shape === 'sphere') {
		const r = +(spec.radius ?? 0);
		if (!(r > 0)) {
			throw new RangeError(`${where}: spec.trigger.radius must be a positive world radius, not ${spec.radius}`);
		}
		size = [r * 2, r * 2, r * 2];
	} else {
		size = readVector(spec.size ?? null, `${where}: spec.trigger.size`);
		if (!size.every(n => n > 0)) {
			throw new RangeError(`${where}: spec.trigger.size must be a positive [width, height, depth], not ${JSON.stringify(spec.size)}`);
		}
	}
	const offset = spec.offset === undefined || spec.offset === null
		? [0, 0, 0]
		: readVector(spec.offset, `${where}: spec.trigger.offset`);
	return { shape, size, offset };
}

// Built on first use rather than at module load: a prelude that made two GPU
// assets every session for a feature most scripts never reach would be paying
// for this file's existence rather than for its use.
function triggerSphere() {
	if (TRIGGER_SPHERE === null) TRIGGER_SPHERE = new SphereGeometry(0.5, 8, 6);
	return TRIGGER_SPHERE;
}

function triggerBox() {
	if (TRIGGER_BOX === null) TRIGGER_BOX = new BoxGeometry(1, 1, 1);
	return TRIGGER_BOX;
}
