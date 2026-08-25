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
//     three.systems.add('look', cameraLook);
//     three.systems.add('pose', posePlayer);
//     three.systems.add('walk', walkEveryone, { phase: 'fixed' });
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
// API uses — `three.damp`, `three.clock.fixedDelta` and every integration in
// `examples/` are in seconds, and every one of those call sites currently
// divides by a thousand. The reserved `animation` entry is the one exception,
// and it is an exception so that the old contract is exactly preserved.
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

class Registry {
	constructor() {
		this._all = [];
		this._sorted = { fixed: null, frame: null };
		this._seq = 0;

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
		this._frameTick = (ms) => this._run('frame', ms / 1000, ms);
		this._fixedTick = (dt) => this._run('fixed', dt, dt * 1000);
	}

	// Register a system, or replace one of the same name.
	//
	// `{ phase, order, enabled, context, millis }`:
	//
	//     phase     'frame' (once a frame, the default) or 'fixed' (zero or
	//               more times a frame, at three.clock.fixedRate)
	//     order     lower runs first; equal orders run in the order they were
	//               added, which is the rule that makes a file read top to
	//               bottom
	//     enabled   false to register it switched off
	//     context   passed to the callback as its second argument — what
	//               cast.system() uses to hand a system its own Cast
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

		const existing = this._all.findIndex(s => s.name === name);
		const system = {
			name, fn, phase,
			order: +(options?.order ?? 0),
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
		if (existing >= 0) this._all[existing] = system; else this._all.push(system);
		this._resort();
		return system.name;
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

	// Everything registered, in the order it runs.
	list() {
		return [...this._all]
			.sort((a, b) => (a.phase === b.phase ? 0 : a.phase === 'fixed' ? -1 : 1)
				|| a.order - b.order || a.seq - b.seq)
			.map(s => ({ name: s.name, phase: s.phase, order: s.order, enabled: s.enabled }));
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
		this._sorted.fixed = null;
		this._sorted.frame = null;
		H.setFrame(this._list('frame').length > 0 ? this._frameTick : null);
		H.setFixed(this._list('fixed').length > 0 ? this._fixedTick : null);
	}

	_list(phase) {
		if (this._sorted[phase] === null) {
			this._sorted[phase] = this._all
				.filter(s => s.phase === phase)
				.sort((a, b) => a.order - b.order || a.seq - b.seq);
		}
		return this._sorted[phase];
	}

	_run(phase, dt, ms) {
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
