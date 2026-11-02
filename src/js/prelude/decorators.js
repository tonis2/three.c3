// Decorators for game code: systems, keys, eager entity registration and
// owned resources, written on the class that owns them.
//
//     @three.entity({ capacity: 64, parent: groups.pack })
//     class Critter extends three.Entity {
//         @three.owned bite = three.cooldown(0.6);
//
//         @three.systems.step({ when: () => G.mode === 'playing' })
//         walk(dt) { … }                       // every live critter, each fixed step
//
//         @three.systems.frame
//         static flow(dt) { … }                // once a frame, for the pack
//
//         @three.key('space', 'jump')
//         static jump() { … }
//     }
//
// Standard (TC39) decorators. Each one is a plain function; the work happens in
// `context.addInitializer`, or, for an entity class, when the class registers
// (`registerDecorated`), because its statics are defined only after its methods.

import { systems } from './systems.js';

// What a decorated class carries in its metadata, read when it registers.
export const DECORATED_SYSTEMS = Symbol('three.systems');
export const OWNED_FIELDS = Symbol('three.owned');

// Keys bound with `@three.key`, and what each does: `three.keys()`.
const keyTable = new Map();

// The class's own copy of an inherited list, so a subclass adds to its own.
function own(metadata, key) {
	if (!Object.hasOwn(metadata, key)) metadata[key] = [...(metadata[key] ?? [])];
	return metadata[key];
}

function isEntityClass(Class) {
	const Entity = globalThis.three?.Entity;
	return Entity !== undefined && Class.prototype instanceof Entity;
}

// `@three.systems.step` and `@three.systems.step({ … })` both work: the bare form is called
// with the method and its context, the other with options first.
function bareOrOptions(make) {
	return (a, b) => (typeof b === 'object' && b !== null && 'kind' in b && 'metadata' in b)
		? make(null)(a, b)
		: make(a);
}

function guarded(entry, run) {
	const when = entry.when;
	return when === undefined ? run : dt => { if (when()) run(dt); };
}

// One call of the method for a static, or on one instance.
function callOne(entry, target) {
	return guarded(entry, dt => target[entry.name](dt));
}

// The method on every live entity of the class.
function callEach(entry, Class) {
	return guarded(entry, dt => { for (const e of Class) e[entry.name](dt); });
}

function systemDecorator(verb) {
	return bareOrOptions(options => (method, context) => {
		const where = `@three.systems.${verb}`;
		if (context.kind !== 'method') {
			throw new TypeError(`${where} goes on a method — the method is the system — not on a ${context.kind}`);
		}
		if (typeof context.name !== 'string') throw new TypeError(`${where} wants a method with a plain name`);
		const { when, ...rest } = options ?? {};
		if (when !== undefined && typeof when !== 'function') {
			throw new TypeError(`${where}: when is a function answering whether the system runs this tick`);
		}
		const entry = { verb, name: context.name, isStatic: context.static, when, options: rest };
		own(context.metadata, DECORATED_SYSTEMS).push(entry);
		context.addInitializer(function () {
			const Class = context.static ? this : this.constructor;
			// An entity class registers its systems itself, under its own name.
			if (isEntityClass(Class)) return;
			// Anything else: a static method from now on, an instance method on
			// the latest instance made (one name per class, so a rerun replaces).
			systems[verb](`${Class.name}.${entry.name}`, callOne(entry, this), rest);
		});
	});
}

// What `three.systems.step`, `.frame` and `.late` do when they decorate a
// method rather than name a system: `@three.systems.step` is a fixed-step
// system, `.frame` once per drawn frame, `.late` after the camera follow.
// Options are `three.systems.add`'s (`after`, `before`, `order`, `first`,
// `last`, `enabled`, `millis`) plus `when`, a function answering whether to
// run this tick.
export const systemDecorators = {
	step: systemDecorator('step'),
	frame: systemDecorator('frame'),
	late: systemDecorator('late'),
};

// Called by an entity class as it registers, with its own `addSystem`: a
// static method runs once per tick, an instance method on every live entity.
// Statics come first (they are decorated first), which is the order a pack
// wants — the shared work, then each member — unless `after`/`before` say
// otherwise.
export function registerDecorated(Class, addSystem) {
	for (const entry of Class[Symbol.metadata]?.[DECORATED_SYSTEMS] ?? []) {
		const run = entry.isStatic ? callOne(entry, Class) : callEach(entry, Class);
		addSystem(entry.verb, entry.name, run, entry.options);
	}
}

// `@three.key('space', 'jump')`: the method runs when the key goes down (or
// up, with `{ up: true }`). Bound for a static method at once, for an instance
// method when the instance is made — the latest instance owns the key, as a
// second `three.onKeyDown` would. The description is what `three.keys()` lists.
export function key(name, description = '', options = null) {
	if (typeof name !== 'string' || name === '') throw new TypeError('@three.key(name, description) wants a key name');
	// Listed here, as the decorator is evaluated, so `three.keys()` reads in
	// source order: decorators are APPLIED last-first and statics first.
	keyTable.set(name, String(description));
	return (method, context) => {
		if (context.kind !== 'method') throw new TypeError(`@three.key('${name}') goes on a method, not on a ${context.kind}`);
		if (!description) keyTable.set(name, context.name);
		context.addInitializer(function () {
			const target = this;
			globalThis.three[options?.up ? 'onKeyUp' : 'onKeyDown'](name, (...args) => target[context.name](...args));
		});
	};
}

// Every key a `@three.key` bound, and what it does: `{ space: 'jump', … }`.
// What `three.debug.write({ keys: three.keys() })` and a help line want.
export function keys() {
	return Object.fromEntries(keyTable);
}

// `@three.owned bite = three.cooldown(0.6)`: the field's value is disposed
// when its entity is removed. A cooldown, a texture, a material — anything
// with a `dispose()` that would otherwise outlive the entity that made it.
export function owned(value, context) {
	if (context.kind !== 'field' && context.kind !== 'accessor') {
		throw new TypeError(`@three.owned goes on a field holding something to dispose, not on a ${context.kind}`);
	}
	own(context.metadata, OWNED_FIELDS).push(context.name);
}

// What `Entity` removal calls: dispose every owned field once.
export function disposeOwned(instance) {
	for (const name of instance.constructor[Symbol.metadata]?.[OWNED_FIELDS] ?? []) {
		const value = instance[name];
		if (value !== null && typeof value?.dispose === 'function') value.dispose();
	}
}
