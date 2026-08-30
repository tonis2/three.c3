// three.c3 — the ordered system registry. `notes.md` §21.
//
// ## What this is for, and it is not speed
//
// `notes.md` §17's crowd table put every JavaScript-side data layout — arrays
// of structs, structures of arrays, a masked dispatch through a callback —
// between 70 and 150 ns per agent per frame, inside the ±142 ns noise floor of
// the measurement itself. **None of this makes a frame faster.** The speed was
// the three bulk verbs and they are built.
//
// This is for the fact that `setFixedLoop` and `setAnimationLoop` each take ONE
// callback, so a game with five things to do a frame has one function with five
// things in it — and `examples/wumpa_run.js` reached ninety lines of animation
// callback doing the camera look, the key latching, the transform write-back,
// the fruit bob and the debris, none of which know about each other. Adding a
// sixth kind of NPC meant editing that function.
//
//     three.systems.frame('look', cameraLook);
//     three.systems.frame('pose', posePlayer);
//     three.systems.step('walk', walkEveryone);
//
// ## The verb is the phase, and the neighbours are the order
//
// There are two clocks and a script has to pick one per system. `step` is the
// fixed one — the same `dt` every time, however the frame rate is behaving —
// and it is where the rules of the game go, because movement and collision
// drift when the step they integrate over does not. `frame` is once per drawn
// frame, handed what that frame was actually worth, and it is where the camera
// and the fades go, because those follow the screen. Naming the clock in the
// VERB is the whole of that decision; there is no option to look up and no
// string to spell.
//
// The order is the order they were registered in, and for the one system in a
// file that has to break that, `{ before: 'fire' }` says which. A NAME and not
// a number: "before the muzzle flashes" is what was meant, and `order: 10` is a
// coordinate somebody has to keep true by hand while the file grows around it.
// The numeric `order` is still underneath and still accepted — it is how the
// engine's own systems bracket a script's — but a game should never need it.
//
// ## `setAnimationLoop` is a system now, and that is why nothing breaks
//
// The registry owns the host's two callback slots. `three.setAnimationLoop(fn)`
// registers `fn` under the reserved name `animation`, and `setFixedLoop` under
// `fixed` — so a script that has never heard of this file installs exactly one
// system and gets exactly the behaviour it always had, and a script that uses
// both gets them in the order it wrote them.
//
// The alternative — the registry installing itself through `setAnimationLoop`
// like any other caller — was tried on paper and rejected: a later
// `setAnimationLoop` would silently evict the whole list, and the symptom is
// every system quietly not running with nothing raised anywhere.
//
// ## The two reserved entries keep the host's failure contract, exactly
//
// `frame_loop.c3` stops a callback the moment it misbehaves — a throw, a
// budget overrun, or returning a promise — and keeps the reason for the next
// run to report. **That contract belongs to `setAnimationLoop` and it is not
// this file's to change**, so the reserved entries run OUTSIDE the containment
// below and their return value is the registry tick's return value. A script
// that never heard of systems must not find that its error handling quietly
// became something else.
//
// So the two failure behaviours are different on purpose, and the difference is
// the choice a caller makes by which door they came in:
//
//     three.setAnimationLoop(fn)      throws stop it, for good, with the reason
//     three.systems.add(name, fn)     throws are contained, named and counted
//
// A budget overrun is neither: QuickJS's interrupt is not catchable from
// JavaScript, so it goes past `_failed` to the host whichever door was used —
// which is what keeps an endless system from being swallowed here.
//
// ## Systems are handed SECONDS
//
// The animation callback is handed milliseconds because that is what
// `WebGLRenderer.setAnimationLoop` hands its callback, and the name carries the
// units. A system is not a Three.js concept and gets the units the rest of this
// API uses — `three.damp`, `three.clock.dt`, `three.clock.fixedDelta` and
// every integration in `examples/` are in seconds. The reserved `animation`
// entry is the one exception, and it is an exception so that the old contract
// is exactly preserved.
//
// And the two arguments are not the same number in different units. The host
// hands the frame callback what `WebGLRenderer.setAnimationLoop` does —
// `clock.time * 1000`, the milliseconds since the clock started, CUMULATIVE —
// and a system's `dt` is `three.clock.dt`, what this one frame is worth. The
// first version of this file divided the cumulative number by a thousand and
// called it `dt`, so every frame-phase system multiplied by the time since the
// level loaded, and the test that should have caught it asserted that the two
// arguments AGREED — which the wrong number satisfies exactly. `notes.md` §21.
import { clamp01 } from './math.js';

const H = globalThis.__three;

// How fast the rolling average forgets. 0.1 is about a fifteen-frame window,
// which is long enough that one long frame does not dominate the reading and
// short enough that turning a system off shows up while you are still looking.
const REPORT_SMOOTHING = 0.1;

// How many times one system may throw the same message before the log stops
// repeating it. A system that fails does so sixty times a second, and a
// thousand identical stack traces is how the FIRST one gets scrolled away.
const ERROR_REPEATS = 3;

// The reserved names `three.setAnimationLoop` and `three.setFixedLoop` register
// under. Reserved rather than merely conventional: a script that registered its
// own system called `animation` and then called `setAnimationLoop` would find
// one of them silently replacing the other, which is exactly the confusion the
// registry exists to remove.
export const ANIMATION_SYSTEM = 'animation';
export const FIXED_SYSTEM = 'fixed';

// Where `{ first: true }` and `{ last: true }` land on the same scale `order`
// is, and they sit INSIDE the brackets the entity registry keeps for its own
// systems on purpose. The rules drain still runs before a `first` one, because
// an event that fired has to be delivered before anything reads the result of
// it, and the column write-back still runs after a `last` one, because it has
// to see the final positions. Asking to be first is asking to be first among
// the game's own systems, which is what somebody asking means.
const FIRST_ORDER = -1e5;
const LAST_ORDER = 1e5;

// `after: 'walk'` and `after: ['walk', 'draw']` are the same thing said twice,
// and one name is what almost every case is.
function neighbours(value, name, where) {
	if (value === undefined || value === null) return [];
	const list = Array.isArray(value) ? value : [value];
	for (const other of list) {
		if (typeof other !== 'string' || other === '') {
			throw new TypeError(`${where}: ${name}'s after/before wants a system name, not ${JSON.stringify(other)}`);
		}
	}
	return list;
}

class Registry {
	constructor() {
		this._all = [];
		this._sorted = { fixed: null, frame: null };
		this._seq = 0;

		// Names an `after` or `before` pointed at and did not find. Filled by
		// the sort and said once by the next tick — see `_saySkipped` for why
		// it is not raised where it is noticed.
		this._skipped = new Map();
		this._said = new Set();

		// Whether `report()` has anything in it. Two `H.clockWall()` calls per
		// system per call, and a host call answering a number measures 143 ns
		// — about 3 us a frame for ten systems, or four hundredths of one per
		// cent of the eight-millisecond budget. On by default because the
		// question it answers is "why did that frame stutter", and a profiler
		// that has to be switched on first cannot answer it about a stutter
		// that has already happened.
		this.profile = true;

		// The host reads the return value — a callback that answers with a
		// promise is stopped — so the tick answers with whatever the reserved
		// entry answered with, and `undefined` when there is not one.
		this._frameTick = (ms) => this._run('frame', H.clockDelta(), ms);
		this._fixedTick = (dt) => this._run('fixed', dt, dt * 1000);
	}

	// Register a system, or replace one of the same name.
	//
	// `three.systems.step` and `three.systems.frame` are the two doors a script
	// should come in by, and they are this one with the phase already answered.
	// Reach for `add` when the phase is a variable rather than a decision —
	// `cooldown.js` ticks whichever phase its timer was asked for.
	//
	// `{ phase, after, before, first, last, order, enabled, context, millis }`:
	//
	//     phase     'frame' (once a frame, the default) or 'fixed' (zero or
	//               more times a frame, at three.clock.fixedRate)
	//     after     run after these, named — one name or a list of them
	//     before    run before these
	//     first     before the game's other systems in that phase
	//     last      after them
	//     enabled   false to register it switched off
	//     context   passed to the callback as its second argument — what
	//               cast.system() uses to hand a system its own Cast
	//
	// **Registration order is running order**, and `after`/`before` are for the
	// one system in a file that has to break it — the autopilot at the bottom
	// of `examples/tank_yard.js`, which presses the game's keys and so has to
	// go before the muzzle flashes drawn by a system three hundred lines above
	// it. Naming the neighbour says that; `order: 10` says a coordinate, and
	// leaves the reader to work out what is at 20.
	//
	// **A name that is not registered yet is fine.** Every change re-resolves
	// the whole list from the names, so a file may point forwards, the way a
	// rule may name a class that is declared further down. One that is never
	// registered is reported once and otherwise ignored — `_saySkipped`.
	//
	// `order` is still read, and is still the sort key underneath all of this.
	// It is how the engine's own systems bracket a script's, and it is the
	// escape hatch for the case the four words above do not cover.
	//
	// **Replacing by name is deliberate.** A hot-reloaded script re-running its
	// top level should end up with one copy of each system rather than two, and
	// a name is the only identity a re-evaluated closure keeps.
	add(name, fn, options = null) {
		const where = 'three.systems.add(name, fn, options)';
		if (typeof name !== 'string' || name === '') throw new TypeError(`${where} wants a name`);
		if (typeof fn !== 'function') throw new TypeError(`${where}: ${name} is not a function`);
		// The same refusal `setAnimationLoop` makes, and the same reason: an
		// async system returns a promise immediately, does its work later, and
		// the frame it was part of is long gone.
		if (fn.constructor && fn.constructor.name === 'AsyncFunction') {
			throw new TypeError(`${where}: ${name} is async — a system has one frame to finish in and the frame does not wait`);
		}
		const phase = options?.phase ?? 'frame';
		if (phase !== 'frame' && phase !== 'fixed') {
			throw new RangeError(`${where}: phase is 'frame' or 'fixed', not ${JSON.stringify(phase)}`);
		}

		// The two ends of the scale, said in words. The flag wins over an
		// explicit `order`: somebody who wrote both meant the one that reads.
		let order = +(options?.order ?? 0);
		if (options?.first) order = FIRST_ORDER;
		if (options?.last) order = LAST_ORDER;

		const existing = this._all.findIndex(s => s.name === name);
		const system = {
			name, fn, phase, order,
			after: neighbours(options?.after, name, where),
			before: neighbours(options?.before, name, where),
			enabled: options?.enabled !== false,
			context: options?.context ?? this,
			millis: !!options?.millis,
			// Kept across a replace, so hot-reloading a system does not reset
			// the reading you were watching.
			// The two names `setAnimationLoop` and `setFixedLoop` register under
			// — see the header for what they keep that a system does not.
			reserved: name === ANIMATION_SYSTEM || name === FIXED_SYSTEM,
			seq: existing >= 0 ? this._all[existing].seq : this._seq++,
			ms: existing >= 0 ? this._all[existing].ms : 0,
			peak: existing >= 0 ? this._all[existing].peak : 0,
			calls: 0, errors: existing >= 0 ? this._all[existing].errors : 0,
			_ms: 0, _calls: 0, _lastError: '', _repeats: 0,
		};
		const kept = this._all.slice();
		if (existing >= 0) this._all[existing] = system; else this._all.push(system);
		try {
			this._resort();
		} catch (error) {
			// Put back exactly as it was. A loop is a mistake in the call being
			// made, and a registry that kept the half of it that landed would
			// fail the NEXT add too, for a reason no longer on the screen.
			this._all = kept;
			this._resort();
			throw error;
		}
		return system.name;
	}

	// `phase: 'fixed'`, said as a verb.
	//
	// The clock the game's RULES run on. A step is worth the same `dt` whatever
	// the frame rate is doing, which is what keeps movement, collision and
	// timers from drifting when one frame runs long — zero or more of them
	// happen per frame, at `three.clock.fixedRate`.
	step(name, fn, options = null) {
		if (options?.phase !== undefined && options.phase !== 'fixed') {
			throw new RangeError(`three.systems.step(name, fn, options): ${name} is a step system already — the verb is the phase`);
		}
		return this.add(name, fn, { ...options, phase: 'fixed' });
	}

	// `phase: 'frame'`, said as a verb.
	//
	// Once per drawn frame, handed what that frame was actually worth. Where
	// the camera, the fades and the uniform writes go: things that should
	// follow the screen rather than the clock, and that judder when they are
	// quantised to a step the screen is not in time with.
	frame(name, fn, options = null) {
		if (options?.phase !== undefined && options.phase !== 'frame') {
			throw new RangeError(`three.systems.frame(name, fn, options): ${name} is a frame system already — the verb is the phase`);
		}
		return this.add(name, fn, { ...options, phase: 'frame' });
	}

	// Take one out. Answers whether there was one.
	remove(name) {
		const at = this._all.findIndex(s => s.name === name);
		if (at < 0) return false;
		this._all.splice(at, 1);
		this._resort();
		return true;
	}

	// Switch one off without forgetting it — which is the point, because the
	// reading in `report()` survives and a system turned off and on again is
	// the cheapest way to find out what it was costing.
	enable(name, on = true) {
		const system = this._all.find(s => s.name === name);
		if (system === undefined) return false;
		system.enabled = !!on;
		return true;
	}

	// Everything registered, in the order it runs — every fixed step first and
	// then the frame, which is the order a tick takes them in.
	//
	// The two sorted lists rather than a sort of its own, so that what this
	// answers and what actually runs cannot drift apart.
	list() {
		return [...this._list('fixed'), ...this._list('frame')]
			.map(s => ({ name: s.name, phase: s.phase, order: s.order, enabled: s.enabled }));
	}

	// The tick as a picture, for whoever is asking "what runs, and when".
	//
	//     step  spawn → player → foes → shots → round
	//     frame autopilot → fire
	//
	// Two lines and not one, because they are two lists: every step this frame
	// owes runs before any frame system, so a flat list invites reading `fire`
	// as though it interleaved with `shots` and `round`. That misreading is
	// most of what the old `{ phase, order }` pair cost people — the numbers
	// looked comparable across phases and never were.
	//
	// A system switched off is in brackets: still registered, still costing
	// nothing, still in the place it will come back to.
	outline() {
		const line = (phase, label) => {
			const list = this._list(phase);
			if (list.length === 0) return '';
			return `${label} ${list.map(s => (s.enabled ? s.name : `(${s.name})`)).join(' → ')}`;
		};
		return [line('fixed', 'step '), line('frame', 'frame')].filter(l => l !== '').join('\n');
	}

	// What each system costs, **most expensive first**, as a rolling average of
	// milliseconds per FRAME — so a fixed system that ran four times this frame
	// reports what all four cost together, which is the number that has to fit
	// in the budget.
	//
	// `peak` is the worst frame since the reading started, because a mean of
	// 0.4 ms hides a system that spends 9 ms once a second and that is the one
	// a player feels. `calls` is how many times it ran in the last frame.
	//
	// Empty of numbers while `three.systems.profile` is false.
	report() {
		return this._all
			.map(s => ({
				name: s.name, phase: s.phase, enabled: s.enabled,
				ms: Math.round(s.ms * 1e4) / 1e4,
				peak: Math.round(s.peak * 1e4) / 1e4,
				calls: s.calls, errors: s.errors,
			}))
			.sort((a, b) => b.ms - a.ms);
	}

	// The whole registry's rolling cost per frame, which is the number to read
	// against the eight-millisecond budget.
	get frameMs() {
		let total = 0;
		for (const s of this._all) total += s.ms;
		return Math.round(total * 1e4) / 1e4;
	}

	get length() { return this._all.length; }

	// Forget every system. What a scene teardown wants, and what
	// `new three.Scene()` does NOT do — a Scene is the contents of the world
	// and these are the rules it runs under, and a script that rebuilds its
	// level between two of its own systems should not have them silently
	// deleted underneath it.
	clear() {
		this._all.length = 0;
		this._resort();
	}

	// **A phase's slot is taken only while that phase has systems in it.**
	// `JsRuntime.tick` answers "did anything run", and a host callback
	// registered to run an empty list is a tick that claims it did — which is
	// the difference between a stopped loop and a running one, and several
	// checks in `test/frame_test.c3` are about exactly that.
	//
	// **Re-installed on every change rather than once**, and that is not
	// laziness: the host stops a callback for good when it misbehaves, and
	// after that the registry is uninstalled without ever having been told.
	// Registering a system is not a per-frame call, so paying one crossing to be
	// sure is free — and it is what makes adding a system the way to resume
	// after a callback took the loop down.
	_resort() {
		// Cleared before the two sorts refill it, so a name that pointed
		// forwards and has since been registered stops being missing.
		this._skipped.clear();
		this._sorted.fixed = null;
		this._sorted.frame = null;
		H.setFrame(this._list('frame').length > 0 ? this._frameTick : null);
		H.setFixed(this._list('fixed').length > 0 ? this._fixedTick : null);
	}

	_list(phase) {
		if (this._sorted[phase] === null) {
			this._sorted[phase] = this._order(this._all.filter(s => s.phase === phase), phase);
		}
		return this._sorted[phase];
	}

	// One phase's running order: the order they were registered in, moved by
	// whatever `after` and `before` asked for.
	//
	// The base order is `(order, seq)` — the numeric escape hatch first, then
	// registration order, which is all a script with no options at all has. The
	// constraints are then a topological sort OVER that base rather than
	// instead of it: at every step the runnable system that comes earliest in
	// the base order goes next. That is what makes the feature quiet — a file
	// with no constraints comes out exactly as it was written, and a file with
	// one moves exactly the system that asked to move and nothing beside it.
	//
	// Left early when nothing asked, which is the common case and is the whole
	// of the cost for a script that never uses this.
	_order(list, phase) {
		const base = list.sort((a, b) => a.order - b.order || a.seq - b.seq);
		if (!base.some(s => s.after.length > 0 || s.before.length > 0)) return base;

		const here = new Map(base.map(s => [s.name, s]));
		const next = new Map(base.map(s => [s.name, []]));
		const waiting = new Map(base.map(s => [s.name, 0]));
		const edge = (first, then) => {
			next.get(first).push(then);
			waiting.set(then, waiting.get(then) + 1);
		};
		for (const s of base) {
			for (const other of s.after) if (this._named(other, s, phase, here)) edge(other, s.name);
			for (const other of s.before) if (this._named(other, s, phase, here)) edge(s.name, other);
		}

		const out = [];
		const ready = base.filter(s => waiting.get(s.name) === 0);
		while (ready.length > 0) {
			let pick = 0;
			for (let i = 1; i < ready.length; i++) {
				if (ready[i].order < ready[pick].order
					|| (ready[i].order === ready[pick].order && ready[i].seq < ready[pick].seq)) pick = i;
			}
			const system = ready.splice(pick, 1)[0];
			out.push(system);
			for (const name of next.get(system.name)) {
				waiting.set(name, waiting.get(name) - 1);
				if (waiting.get(name) === 0) ready.push(here.get(name));
			}
		}

		if (out.length < base.length) {
			// Raised, unlike a name that pointed at nothing, and raised out of
			// the `add` that closed the loop — there is no order that satisfies
			// what was asked, so there is nothing to carry on with, and the
			// call that made it impossible is still on the screen.
			const stuck = base.filter(s => !out.includes(s)).map(s => s.name);
			throw new RangeError(
				`three.systems: after/before make a loop — ${stuck.join(', ')} each wait for one of the others`);
		}
		return out;
	}

	// Whether a name an `after` or `before` pointed at is one this phase can be
	// ordered against, remembering why when it is not.
	//
	// The other phase is worth its own sentence because it is the mistake the
	// two clocks invite: the phases are two lists that run one after the other,
	// so "this frame system before that step system" is not a thing an order
	// can express, and the answer is already yes.
	_named(name, system, phase, here) {
		if (here.has(name)) return true;
		const elsewhere = this._all.find(s => s.name === name);
		const word = p => (p === 'fixed' ? 'step' : 'frame');
		this._skipped.set(`${system.name} ${name}`, elsewhere !== undefined
			? `'${system.name}' is a ${word(phase)} system and '${name}' is a ${word(elsewhere.phase)} one — `
				+ 'the phase decides which runs first, not the order'
			: `'${system.name}' asked to run beside '${name}', and nothing by that name is registered`);
		return false;
	}

	_run(phase, dt, ms) {
		if (this._skipped.size > 0) this._saySkipped();

		// The frame phase runs last in a tick — `frame_loop.c3` takes the fixed
		// steps first — so folding here means a fixed system's four calls this
		// frame are one reading rather than four.
		//
		// A registry of nothing but fixed systems has no frame to fold at, and
		// reports per STEP rather than per frame. Saying so is cheaper than the
		// alternatives: a frame slot taken to do nothing but fold would make
		// `JsRuntime.tick` claim a stopped loop was running.
		const boundary = phase === 'frame' || this._list('frame').length === 0;
		if (boundary && this.profile) this._fold();

		const list = this._list(phase);
		let answer;
		for (let i = 0; i < list.length; i++) {
			const system = list[i];
			if (!system.enabled) continue;
			const started = this.profile ? H.clockWall() : 0;
			if (system.reserved) {
				// Outside the containment, and its answer is the tick's — see
				// the header. A throw from here goes to the host, which stops
				// the callback and keeps the reason, exactly as it did before
				// there was a registry to run it.
				answer = system.fn(system.millis ? ms : dt, system.context);
			} else {
				try {
					system.fn(system.millis ? ms : dt, system.context);
				} catch (error) {
					this._failed(system, error);
				}
			}
			if (this.profile) {
				system._ms += H.clockWall() - started;
				system._calls++;
			}
		}
		return answer;
	}

	_fold() {
		for (const s of this._all) {
			s.ms += (s._ms - s.ms) * REPORT_SMOOTHING;
			if (s._ms > s.peak) s.peak = s._ms;
			s.calls = s._calls;
			s._ms = 0;
			s._calls = 0;
		}
	}

	// **A system that throws does not stop the others**, and that is the whole
	// reason the split is worth having: with one callback a throw in the fruit
	// code stops the camera, and the report reads as "the camera broke".
	//
	// This is not reached for the two reserved entries, which keep the host's
	// own contract — see the header.
	//
	// It is not swallowed either. The message names the system, and it repeats
	// a few times and then goes quiet — a failing system fails sixty times a
	// second, and a thousand identical traces is how the first one scrolls
	// away. `report()` keeps counting them, and nothing is disabled behind your
	// back: a system silently switched off is a second thing to discover.
	// An `after` or `before` that pointed at nothing, said once.
	//
	// Not raised, unlike a loop. The sort runs while systems are being
	// registered — where a forward reference is not yet resolvable and is not
	// yet wrong — and again on the first tick after any change, where a throw
	// would take the whole loop down over a misspelt name.
	//
	// Not silent either, for `_failed`'s reason: the system still runs, in a
	// place nobody asked for, and an out-of-order frame does not announce
	// itself. It reads as a bug in whatever ran next.
	_saySkipped() {
		for (const [where, why] of this._skipped) {
			if (this._said.has(where)) continue;
			this._said.add(where);
			console.log(`three.systems: ${why}`);
		}
		this._skipped.clear();
	}

	_failed(system, error) {
		system.errors++;
		const message = String(error && error.message ? error.message : error);
		if (message !== system._lastError) {
			system._lastError = message;
			system._repeats = 0;
		}
		if (system._repeats < ERROR_REPEATS) {
			system._repeats++;
			const tail = system._repeats === ERROR_REPEATS ? ' (further repeats of this one are quiet)' : '';
			console.log(`three.systems: '${system.name}' threw — ${message}${tail}`);
		}
	}
}

export const systems = new Registry();

// A 0..1 reading of how much of the frame budget the registry is using, for a
// HUD that wants a bar rather than a number. Eight milliseconds is the budget
// `notes.md` §5 measures against.
export function systemLoad(budgetMs = 8) { return clamp01(systems.frameMs / budgetMs); }
