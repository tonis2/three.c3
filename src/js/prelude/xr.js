// three.xr — the headset: its display, and the two hand controllers.
//
// Off a headset the display reads as no display and both hands as
// disconnected, so a game written for the headset still runs on a desktop.
// `three.xr.right.press('trigger')` and its siblings hold a hand down from a
// script, for a test with no controller in it.

import { Group } from './object3d.js';
import { Vector3, asTriple } from './math.js';
import { sceneForId } from './scene.js';

const H = globalThis.__three;

// `Foveation` in `gpu/foveation.c3`, in its order.
const FOVEATION_LEVELS = ['off', 'low', 'medium', 'high'];

// `Hand`, `HandButton` and `HandSpace` in `scene/hands.c3`, in their order.
const HANDS = ['left', 'right'];
const BUTTONS = ['a', 'b', 'x', 'y', 'stick', 'menu', 'trigger', 'squeeze'];
const SPACES = ['grip', 'aim'];

function buttonIndex(name, where) {
	const at = BUTTONS.indexOf(name);
	if (at < 0) throw new RangeError(`${where} wants one of ${BUTTONS.join(', ')}, not ${JSON.stringify(name)}`);
	return at;
}

function finite(value, where) {
	const n = +value;
	if (!Number.isFinite(n)) throw new TypeError(`${where} wants a number`);
	return n;
}

// The grip or aim of one hand: a group the engine moves onto the controller
// every frame, in the world. Add children to it; it cannot be moved itself.
class TrackedSpace extends Group {
	constructor(hand, space) {
		super();
		this._hand = hand;
		this._space = space;
		this._name = `xr.${HANDS[hand]}.${SPACES[space]}`;
		this._tracked = false;
	}

	_where() { return `three.xr.${HANDS[this._hand]}.${SPACES[this._space]}`; }

	_syncSolver() {
		if (this._h === null) return;
		const { position: p, rotation: r } = H.xrHandPose(this._hand, this._space);
		this._position._adopt(p[0], p[1], p[2]);
		this._rotation._adopt(r[0], r[1], r[2]);
		this._q = null;
	}

	_flush() {
		if (this._tracked) {
			throw new Error(`${this._where()} is placed by the headset each frame — add a child to it and move that`);
		}
		super._flush();
	}

	// Where -Z points: for `aim`, where the controller points.
	get direction() {
		const d = H.xrHandPose(this._hand, this._space).direction;
		return new Vector3(null, d[0], d[1], d[2]);
	}

	// How fast it moves, in metres a second, and turns, in radians a second
	// about the axis it turns around: what a thrown object leaves with.
	get velocity() {
		const v = H.xrHandMotion(this._hand, this._space).linear;
		return new Vector3(null, v[0], v[1], v[2]);
	}
	get angularVelocity() {
		const v = H.xrHandMotion(this._hand, this._space).angular;
		return new Vector3(null, v[0], v[1], v[2]);
	}

	// Shown while the controller is connected, hidden while it is not.
	get visible() { return H.xrHand(this._hand).connected; }
	set visible(_) { throw new Error(`${this._where()}.visible follows whether the controller is connected`); }
}

// One TrackedSpace per hand and space in each scene, made on first use. By
// scene id, so `r.grip` is always the shown scene's.
const spaces = new Map();

function trackedSpace(hand, space) {
	const sid = H.sceneActive();
	let row = spaces.get(sid);
	if (row === undefined) {
		row = [[null, null], [null, null]];
		spaces.set(sid, row);
	}
	const held = row[hand][space];
	if (held !== null && held._h !== null && held.parent !== null && H.sceneAlive(sid)) return held;
	const made = new TrackedSpace(hand, space);
	sceneForId(sid).add(made);
	made._h.xrTrack(hand, space, true);
	made._tracked = true;
	row[hand][space] = made;
	return made;
}

// `three.xr.left` and `three.xr.right`.
export class XrHand {
	constructor(hand) {
		this._hand = hand;
	}

	_where(what) { return `three.xr.${HANDS[this._hand]}.${what}`; }

	// 'left' or 'right'.
	get handedness() { return HANDS[this._hand]; }

	// Whether the controller is in the hand and tracked. False off a headset,
	// and while the system menu is open.
	get connected() { return H.xrHand(this._hand).connected; }

	// How far the trigger and the grip button are pulled, 0 to 1.
	get trigger() { return H.xrHand(this._hand).trigger; }
	get squeeze() { return H.xrHand(this._hand).squeeze; }

	// [x, y], each -1 to 1; +y is the stick pushed forward.
	get thumbstick() {
		const s = H.xrHand(this._hand);
		return [s.stickX, s.stickY];
	}

	// Which controller, such as 'oculus/touch_controller'; '' when none.
	get profile() { return H.xrHandProfile(this._hand); }

	// Buttons: 'a' and 'b' on the right, 'x', 'y' and 'menu' on the left, and
	// 'stick', 'trigger' and 'squeeze' on both.
	isDown(name) { return ((H.xrHand(this._hand).down >> buttonIndex(name, this._where('isDown(name)'))) & 1) === 1; }
	pressed(name) { return ((H.xrHand(this._hand).pressed >> buttonIndex(name, this._where('pressed(name)'))) & 1) === 1; }
	released(name) { return ((H.xrHand(this._hand).released >> buttonIndex(name, this._where('released(name)'))) & 1) === 1; }

	// Buzz the controller: amplitude 0 to 1, for `seconds` (0 is the shortest
	// pulse it makes). Amplitude 0 stops a buzz.
	vibrate(amplitude = 1, seconds = 0.1) {
		H.xrVibrate(this._hand, finite(amplitude, this._where('vibrate(amplitude, seconds)')),
			finite(seconds, this._where('vibrate(amplitude, seconds)')));
	}

	// Where the hand holds things, and where the controller points: groups in
	// the shown scene that the engine keeps on the controller.
	get grip() { return trackedSpace(this._hand, 0); }
	get aim() { return trackedSpace(this._hand, 1); }

	// Keep a top-level object of the shown scene on this hand's grip or aim,
	// placed before the physics step: a kinematic body on it meets the solver
	// where the hand is this frame, not where it was the frame before.
	track(object, space = 'grip') {
		const where = this._where('track(object, space)');
		const at = SPACES.indexOf(space);
		if (at < 0) throw new RangeError(`${where} wants a space of ${SPACES.join(' or ')}, not ${JSON.stringify(space)}`);
		if (object === null || typeof object !== 'object' || object._trackedBy === undefined) {
			throw new TypeError(`${where} wants a Mesh or a Group`);
		}
		if (object instanceof TrackedSpace) throw new TypeError(`${where}: ${object._where()} is already on a hand`);
		if (object._h === null || object.parent === null || object.parent._isScene !== true) {
			throw new Error(`${where} wants an object added straight to a scene, the way a body is`);
		}
		if (object._solverOwned) {
			throw new Error(`${where}: a dynamic body is moved by the solver — add it as kinematic to carry it on a hand`);
		}
		if (object.parent._sid !== H.sceneActive()) throw new Error(`${where} wants an object in the shown scene`);
		if (object._h.xrTrack(this._hand, at, false) !== true) throw new Error(`${where} could not keep that object`);
		object._trackedBy = this._where(space);
	}

	// Stop keeping an object on this hand. It stays where the hand last put it.
	untrack(object) {
		if (object === null || typeof object !== 'object' || object._trackedBy === undefined) {
			throw new TypeError(`${this._where('untrack(object)')} wants a Mesh or a Group`);
		}
		if (object._trackedBy === null || object._h === null) return;
		object._syncSolver();
		object._h.xrUntrack();
		object._trackedBy = null;
	}

	// A hand held by the script, for a test with no controller in it. Any of
	// these connects the hand; `three.xr.releaseAll()` lets go of everything.
	press(name, value = 1) {
		H.xrHandHold(this._hand, buttonIndex(name, this._where('press(name)')), true, finite(value, this._where('press(name, value)')));
	}
	release(name) { H.xrHandHold(this._hand, buttonIndex(name, this._where('release(name)')), false, 0); }
	tilt(x, y) { H.xrHandTilt(this._hand, finite(x, this._where('tilt(x, y)')), finite(y, this._where('tilt(x, y)'))); }
	// In tracking space: relative to where the rig stands and faces.
	place(position, direction = [0, 0, -1]) {
		const [px, py, pz] = asTriple(position, this._where('place(position)'));
		const [dx, dy, dz] = asTriple(direction, this._where('place(position, direction)'));
		H.xrHandPlace(this._hand, px, py, pz, dx, dy, dz);
	}
	connect() { H.xrHandConnect(this._hand, true); }
}

const left = new XrHand(0);
const right = new XrHand(1);

// The player's head, in the world: between the eyes on a headset, the camera's
// eye at a desk. Read-only; a script moves the player with `three.camera`.
const head = {
	get position() {
		const p = H.xrHead().position;
		return new Vector3(null, p[0], p[1], p[2]);
	},
	// Where the head looks, a unit vector.
	get direction() {
		const d = H.xrHead().direction;
		return new Vector3(null, d[0], d[1], d[2]);
	},
	// Whether this frame's pose is known. While the headset has lost tracking
	// the head stays where it was last seen.
	get tracked() { return H.xrHead().tracked; },
};

// The headset. Off one, the rate reads 0, the list is empty and no hand is
// connected.
export const xr = {
	// Whether frames are going to a headset right now.
	get presenting() { return H.xrPresenting(); },

	// The display's rate in Hz. Setting it asks the headset for the offered
	// rate nearest to it, and the display switches a few frames later; 0
	// hands the choice back to the runtime.
	get refreshRate() { return H.xrRefreshRateGet(); },
	set refreshRate(hz) {
		hz = +hz;
		if (!(hz >= 0)) throw new RangeError('three.xr.refreshRate wants Hz, 0 or more');
		H.xrRefreshRateSet(hz);
	},
	get refreshRates() { return H.xrRefreshRatesGet(); },

	// How coarsely the edge of each eye's view is shaded: 'off', 'low',
	// 'medium' (the default) or 'high'. Always 'off' off a headset.
	get foveation() { return FOVEATION_LEVELS[H.xrFoveationGet()]; },
	set foveation(level) {
		const at = FOVEATION_LEVELS.indexOf(level);
		if (at < 0) throw new RangeError(`three.xr.foveation is one of ${FOVEATION_LEVELS.join(', ')}`);
		H.xrFoveationSet(at);
	},

	// The room, in colour, behind the scene instead of its background: the
	// clear colour and any sky are not drawn while it shows. False off a
	// headset and on one that cannot; a reload turns it off.
	get passthrough() { return H.xrPassthroughGet(); },
	set passthrough(on) { H.xrPassthroughSet(!!on); },
	get passthroughSupported() { return H.xrPassthroughSupported(); },

	// Live eye render scale (0.4 to 1.5 of the runtime's recommended size), applied
	// between frames, and the current single-eye resolution `{ width, height }`.
	get renderScale() { return H.xrRenderScaleGet(); },
	set renderScale(scale) {
		scale = +scale;
		if (!Number.isFinite(scale) || scale < 0.4 || scale > 1.5) {
			throw new RangeError('three.xr.renderScale wants a number between 0.4 and 1.5');
		}
		H.xrRenderScaleSet(scale);
	},
	get eyeSize() { return H.xrEyeSizeGet(); },

	// The mouse and keyboard as the two hands, off a headset: the right hand
	// points where the pointer is. See docs/functions.md for the keys.
	get emulate() { return H.xrEmulateGet(); },
	set emulate(on) { H.xrEmulateSet(!!on); },

	left,
	right,
	head,

	// Lets go of everything `press`, `tilt`, `place` and `connect` held.
	releaseAll() { H.xrHandsReleaseAll(); },
};
