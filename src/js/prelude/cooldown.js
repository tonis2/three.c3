// three.c3 — three.cooldown(duration, options): a scalar gameplay timer.
// See `docs.js`'s `Cooldown`/`three.cooldown` entries for the full API; this
// header is only the one decision that needed evidence to make.
//
// Replaces the `if (x > 0) x -= dt` pattern `examples/wumpa_run.js` wrote by
// hand for `ctl.spin`, `ctl.spinCool`, `ctl.hurt` and `ctl.coyote`. `P_STUN`
// and `P_LIFE` in the same file stay CAST COLUMNS — a Cooldown is one object
// per timer, not per crowd member; two hundred of them is `pack.system(...)`
// looping one column, not two hundred Cooldowns.
//
// ## Ticked, not read off `three.clock` — the decision that needed evidence
//
// The cheap version reads `clock.time - startedAt < duration`. It is wrong
// because `three.clock.time` advances ONCE per `JsRuntime.tick`
// (`advance_frame` sets `time`/`dt` once and returns — `src/scene/clock.c3:
// 159-178`, called from `src/js/frame_loop.c3:211`) — *before*
// `take_fixed_steps()` decides how many times the fixed callback runs that
// tick, and `call_fixed` (`frame_loop.c3:342-345`, its own comment: "the dt
// it is handed is a constant") then runs the SAME clock reading through
// every one of those steps. `test/clock_test.c3`'s
// `the_fixed_loop_runs_what_the_clock_owes` proves the multi-step-per-tick
// fact directly: 90ms in one `run.tick()` call is five separate fixed calls.
// A cooldown shorter than one fixed step — the 0.12s coyote window already
// is — would see ZERO elapsed time across however many of those land in one
// catch-up tick.
//
// So every live Cooldown sits in a module-level list per phase, decremented
// by that phase's own `dt` inside a system registered LAZILY on the first
// `three.cooldown()` call that needs it, and removed once the last cooldown
// on that phase disposes. This is not optional: `notes.md` §21 — "a phase's
// host slot is taken only while that phase has systems in it" — means a
// `'fixed'` system registered at module load would take the fixed-loop slot,
// and change `JsRuntime.tick`'s "did anything run" answer
// (`is_animating()`), for every scene that merely imports this file.
// `dispose()` exists only because of this; a clock-based Cooldown would not
// have needed one.
//
// Worth naming rather than relying on by accident: BOTH phases freeze for
// free while the game clock is paused. A `'fixed'` cooldown's system simply
// does not run (`take_fixed_steps()` owes zero steps —
// `a_paused_clock_owes_no_fixed_steps`); a `'frame'` one runs but is handed
// `dt = 0`. And the checks themselves — `.active`, `.ready`, `.remaining` —
// are plain field reads with no host crossing at all.
//
// Wiring the `'frame'` phase is what found the registry handing frame systems
// the cumulative clock instead of a delta — fixed in `systems.js`, recorded in
// `notes.md` §21. The first draft of this file read `three.clock.dt` itself to
// get round it; the workaround went with the bug.
import { systems } from './systems.js';
import { clamp01 } from './math.js';

const WHERE = 'three.cooldown(duration, options)';
const START_WHERE = 'cooldown.start(options)';
const OPTION_KEYS = ['recover', 'phase'];
const START_OPTION_KEYS = ['restart'];
const PHASES = ['fixed', 'frame'];

// One tick list and one lazily-owned system per phase. A Cooldown never
// crosses into the host at all — registering is `systems.add`, already paid
// for by whatever else in a scene uses it — so the whole module is this pair
// of lists and the bookkeeping that keeps their systems installed only while
// there is something to walk.
const _lists = { fixed: [], frame: [] };
const _systemNames = { fixed: 'cooldowns.fixed', frame: 'cooldowns.frame' };

function _tick(phase) {
	const list = _lists[phase];
	return (dt) => {
		// Indexed, not for-of: a cooldown disposing itself from inside its
		// own tick must not skip its neighbour the way a mutating for-of would.
		for (let i = 0; i < list.length; i++) list[i]._advance(dt);
	};
}

function _register(coolDown) {
	const list = _lists[coolDown._phase];
	list.push(coolDown);
	if (list.length === 1) {
		// `first`, because a timer that has not been advanced yet is a timer
		// read one step stale, and this system installs itself at whatever
		// moment the game happens to start its first cooldown — which is a
		// place in the running order nobody chose. Under the old numeric
		// scale it landed at 0 and so ran before a game that numbered its own
		// systems from 10 and after one that did not number them at all, for
		// no reason either file could see.
		systems.add(_systemNames[coolDown._phase], _tick(coolDown._phase),
			{ phase: coolDown._phase, first: true });
	}
}

function _unregister(coolDown) {
	const list = _lists[coolDown._phase];
	const at = list.indexOf(coolDown);
	if (at < 0) return;
	list.splice(at, 1);
	// The system leaves the registry the moment nothing needs it — the other
	// half of the lazy install above.
	if (list.length === 0) systems.remove(_systemNames[coolDown._phase]);
}

// Every key in `options` must be one `keys` names, or the call is refused —
// the typo protection an options object deserves.
function _checkOptions(options, keys, where) {
	if (options === null || options === undefined) return;
	if (typeof options !== 'object') {
		throw new TypeError(`${where} wants an options object, not ${JSON.stringify(options)}`);
	}
	for (const key of Object.keys(options)) {
		if (!keys.includes(key)) {
			throw new TypeError(`${where}: '${key}' is not an option — this call takes: ${keys.join(', ')}`);
		}
	}
}

export class Cooldown {
	constructor(duration, options = null) {
		const d = +duration;
		if (!(Number.isFinite(d) && d > 0)) {
			throw new RangeError(`${WHERE} wants a duration in seconds greater than zero, not ${duration}`);
		}
		_checkOptions(options, OPTION_KEYS, WHERE);
		const recover = +(options?.recover ?? 0);
		if (!(Number.isFinite(recover) && recover >= 0)) {
			throw new RangeError(`${WHERE}: recover must be zero or a positive number of seconds, not ${options?.recover}`);
		}
		const phase = options?.phase ?? 'fixed';
		if (!PHASES.includes(phase)) {
			throw new RangeError(`${WHERE}: phase is 'fixed' or 'frame', not ${JSON.stringify(phase)}`);
		}

		// Seconds since the last start() — every getter below is a function
		// of this, which is what makes duration/recover writable mid-run.
		this._elapsed = 0;
		this._phase = phase;
		this._disposed = false;

		this.duration = d;
		this.recover = recover;
		// Whether start() has ever taken — a flag rather than an
		// elapsed === Infinity sentinel every consumer would special-case.
		this.started = false;

		_register(this);
	}

	get active() { return this.started && this._elapsed < this.duration; }
	get recovering() {
		return this.started && this._elapsed >= this.duration && this._elapsed < this.duration + this.recover;
	}
	get ready() { return !this.started || this._elapsed >= this.duration + this.recover; }
	get remaining() { return this.active ? this.duration - this._elapsed : 0; }
	get progress() { return this.started ? clamp01(this._elapsed / this.duration) : 0; }

	// Meaningful only while `started` is true — see the constructor's note.
	// Plateaus at `duration + recover` once fully recovered rather than
	// growing forever.
	get elapsed() { return this._elapsed; }

	start(options = null) {
		_checkOptions(options, START_OPTION_KEYS, START_WHERE);
		if (!options?.restart && !this.ready) return false;
		this._elapsed = 0;
		this.started = true;
		return true;
	}

	// Ends it now: not active, and ready immediately — recovery skipped
	// rather than started, for "the spin was interrupted" and not for "the
	// spin finished early."
	cancel() {
		this._elapsed = this.duration + this.recover;
	}

	// Not in the brief this file was built against — a clock-based Cooldown
	// would not have needed it — but this one does, or a level that makes
	// and discards cooldowns leaks one list entry per discard for the life
	// of the process. Safe to call twice.
	dispose() {
		if (this._disposed) return;
		this._disposed = true;
		_unregister(this);
	}

	toString() {
		const state = this.active ? 'active' : this.recovering ? 'recovering' : 'ready';
		return `Cooldown(${state}, ${this.duration}s)`;
	}

	// Advanced by the phase's system, never called directly. Stops adding
	// once past duration + recover.
	_advance(dt) {
		if (this.started && this._elapsed < this.duration + this.recover) this._elapsed += dt;
	}
}

export function cooldown(duration, options = null) { return new Cooldown(duration, options); }
