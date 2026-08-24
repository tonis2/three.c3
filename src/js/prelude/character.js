// three.c3 — a first-class character controller, `three.character(options)`.
//
// This is the pattern every third-person scene ends up writing by hand, and
// writing it by hand is where the bugs come from. The two that cost the most
// work were: the camera and the movement frame disagreeing (which way is
// "forward" kept changing as the camera swung, so W/A/S/D pointed in different
// directions), and hand-rolling the orbit trig for the move direction (whose
// signs read back as the character walking sideways).
//
// A character here is a Group that rides the terrain, with a follow camera.
// It does NOT use physics — the character is kinematic and snaps its feet to a
// height field, which is the cheap, predictable choice for "walk me around the
// scene." (For a body that collides and is pushed, see three.physics.)
//
//     const p = three.character({ terrain, speed, jump, camera: { offset, distance } });
//     three.setAnimationLoop(() => p.step());
//
// Everything the character owns — its own yaw/pitch/distance (the camera's
// look), its heading and position, whether it is moving or airborne — is read
// off the returned object, so a script can inspect or steer it.
//
// The controller calls `globalThis.three` (camera, input) rather than the raw
// host bindings, because the module graph imports it from api.js and `three`
// is only assembled once that's done. Reading it inside `step()` — a runtime
// call, after everything is set up — is the safe time.
//
// ## Nothing here is a magic number a caller cannot reach
//
// The fence the character walks inside, the pitch and zoom limits, the look
// sensitivity and every key are options with defaults, because the first
// version of this file had them as literals and the literals were wrong for
// every scene but the one they were measured in. The fence is the clearest
// case: it was `±118`, which is `examples/terrain_village.js`'s 240-unit
// terrain less a two-unit margin — a number about one example, frozen into the
// API every other scene has to use. It now comes from the terrain itself, the
// way `three.scatter` already reads its own extent, because restating a width
// in two places is how the two drift apart.
//
// ## What `step()` refuses
//
// A `dt` that is not a finite number, because every one of these options ends
// up multiplied by it: one `step()` with nothing to step by used to leave yaw
// and pitch NaN for the rest of the run, with no error and no way back. It
// defaults to `three.clock.dt`, which is what the animation loop is stepping
// and is already clamped against a stall.

import { Group } from './object3d.js';
import { Mesh } from './mesh.js';
import { BoxGeometry, CylinderGeometry } from './geometry.js';
import { MeshLambertMaterial } from './material.js';

const WHERE = 'three.character(options)';

// The keys, as a table rather than as literals in the middle of `step`. Each
// action is a list, so "forward is W and Up" has the same shape as a caller
// rebinding it to one key of their own — and q/e/r/f, which turn and pitch the
// camera for anyone driving without a mouse, are visible here instead of buried
// in an expression.
const DEFAULT_KEYS = {
	forward: ['w', 'arrowup'],
	back: ['s', 'arrowdown'],
	left: ['a', 'arrowleft'],
	right: ['d', 'arrowright'],
	jump: ['space'],
	yawLeft: ['q'],
	yawRight: ['e'],
	pitchUp: ['r'],
	pitchDown: ['f'],
};

// Degrees per pixel of drag, and degrees per second of held key. `sensitivity`
// scales the drag pair only: a key is already a rate, and a caller who wants a
// different one is asking for a different number of degrees per second rather
// than for a different mouse.
const LOOK_PER_PIXEL_YAW = 0.24;
const LOOK_PER_PIXEL_PITCH = 0.2;
const LOOK_PER_SECOND_YAW = 120;
const LOOK_PER_SECOND_PITCH = 60;

const DEFAULT_PITCH_RANGE = [-8, 84];
const DEFAULT_DISTANCE_RANGE = [3, 26];

// A small voxel person, used when `three.character()` is handed no mesh. Feet
// at y=0, so `position.y = heightAt` stands it on the ground. Returns the group
// plus the two pivots the walk cycle swings.
function defaultMesh() {
	const g = new Group(); g.name = 'character';
	const flat = new MeshLambertMaterial();

	function limb(px, py, pz, w, h, d, color) {
		const pivot = new Group(); pivot.position.set(px, py, pz);
		const m = new Mesh(new BoxGeometry(w, h, d), flat);
		m.position.y = -h / 2; m.color = color; pivot.add(m);
		g.add(pivot); return pivot;
	}

	const torso = new Mesh(new BoxGeometry(0.62, 0.95, 0.36), flat);
	torso.position.y = 1.28; torso.color = 0x8a5a36; g.add(torso);

	const head = new Mesh(new BoxGeometry(0.46, 0.46, 0.46), flat);
	head.position.y = 1.98; head.color = 0xe8c39e; g.add(head);

	const hat = new Mesh(new CylinderGeometry(0.42, 0.42, 0.08, 12), flat);
	hat.position.y = 2.24; hat.color = 0xc9a24a; g.add(hat);

	const legs = [
		limb(-0.17, 0.82, 0, 0.20, 0.82, 0.22, 0x3c2c1c),
		limb(0.17, 0.82, 0, 0.20, 0.82, 0.22, 0x3c2c1c),
	];
	const arms = [
		limb(-0.41, 1.66, 0, 0.16, 0.74, 0.18, 0x6a4630),
		limb(0.41, 1.66, 0, 0.16, 0.74, 0.18, 0x6a4630),
	];
	return { g, legs, arms };
}

export function character(options = {}) {
	if (options === null || typeof options !== 'object') {
		throw new TypeError(`${WHERE} takes an options object`);
	}

	const {
		mesh = null,
		terrain = null,
		height = null,
		camera = {},
		bounds = undefined,
	} = options;

	if (mesh !== null && (typeof mesh !== 'object' || mesh.position === undefined || mesh.rotation === undefined)) {
		throw new TypeError(`${WHERE}: mesh wants a Group or a Mesh to drive — got ${mesh}`);
	}
	if (terrain !== null && (typeof terrain !== 'object' || typeof terrain.heightAt !== 'function')) {
		throw new TypeError(
			`${WHERE}: terrain wants a TerrainGeometry — something with a heightAt(x, z) — got ${terrain}. `
			+ 'For any other ground, pass height: (x, z) => y instead.'
		);
	}
	if (height !== null && typeof height !== 'function') {
		throw new TypeError(`${WHERE}: height wants a function (x, z) => y — got ${height}`);
	}
	if (camera !== false && (camera === null || typeof camera !== 'object')) {
		throw new TypeError(
			`${WHERE}: camera wants { offset, distance, lag, yaw, pitch, sensitivity, pitchRange, `
			+ `distanceRange }, or false to leave the camera alone — got ${camera}`
		);
	}

	const speed = atLeast(options.speed, 8.5, 0, WHERE, 'speed');
	const jump = atLeast(options.jump, 7.5, 0, WHERE, 'jump');
	const gravity = atLeast(options.gravity, 22, 0, WHERE, 'gravity');
	// How far the ground may fall away under the feet in one frame and still
	// count as walking down it. Past this it is a ledge and the character
	// falls, which is the difference between stepping off a cliff and being
	// teleported to the bottom of it.
	const snap = atLeast(options.snap, 0.5, 0, WHERE, 'snap');

	const keys = keysOf(options.keys, WHERE);
	const area = boundsOf(bounds, terrain, WHERE);
	const spawn = spawnOf(options.spawn, WHERE);

	// `camera: false` means the character does not drive the camera at all: no
	// attach, no orbit, and no look state of its own. Movement still reads the
	// camera's frame through `planarMove`, so W is wherever the view points —
	// which is the whole reason a caller would want their own camera and this
	// controller's movement.
	const owns = camera !== false;

	const legs = listOf(options.legs, WHERE, 'legs');
	const arms = listOf(options.arms, WHERE, 'arms');
	const built = mesh ? { g: mesh, legs, arms } : defaultMesh();
	const g = built.g;

	// Where the ground is. `terrain.heightAt` is the fast path (it reads the
	// grid the terrain mesh was built from). `height(x, z)` lets a flat scene
	// or a scripted field answer instead. Neither present -> ground at y=0.
	const groundY = (x, z) =>
		height ? finiteGround(height(x, z), x, z)
		: terrain ? terrain.heightAt(x, z)
		: 0;

	// The character's own copy of the camera's look. Kept here (not read off the
	// camera) so the controller can write yaw/pitch/dist and re-apply them every
	// frame — which is what keeps the view and the movement frame in step.
	const s = {
		yaw: atLeast(owns ? camera.yaw : undefined, 0, -Infinity, WHERE, 'camera.yaw'),
		pitch: atLeast(owns ? camera.pitch : undefined, 14, -Infinity, WHERE, 'camera.pitch'),
		dist: atLeast(owns ? (camera.distance ?? camera.dist) : undefined, 10, 0, WHERE, 'camera.distance'),
		heading: Math.PI,   // radians; PI faces -Z, away from a yaw-0 camera
		vy: 0, grounded: true, moving: false, walkT: 0,
		attached: false, controlsWere: null,
	};

	const sensitivity = atLeast(owns ? camera.sensitivity : undefined, 1, 0, WHERE, 'camera.sensitivity');
	const pitchRange = rangeOf(owns ? camera.pitchRange : undefined, DEFAULT_PITCH_RANGE, s.pitch, WHERE, 'camera.pitchRange');
	const distanceRange = rangeOf(owns ? camera.distanceRange : undefined, DEFAULT_DISTANCE_RANGE, s.dist, WHERE, 'camera.distanceRange');

	// Settle the feet on the ground.
	g.position.set(spawn[0], groundY(spawn[0], spawn[1]), spawn[1]);

	function step(dt = globalThis.three.clock.dt) {
		const delta = +dt;
		if (!Number.isFinite(delta) || delta < 0) {
			throw new RangeError(
				`character.step(dt) wants the seconds this frame is worth — got ${dt}. `
				+ 'Called with nothing it reads three.clock.dt, which is what setAnimationLoop steps.'
			);
		}

		const three = globalThis.three;
		const cam = three.camera, input = three.input;
		const held = binding => keys[binding].some(key => input.isDown(key));
		const axis = (plus, minus) => (held(plus) ? 1 : 0) - (held(minus) ? 1 : 0);

		// --- camera look ---
		//
		// Only when this character owns the camera. The follow is attached lazy,
		// on the first step — which is the first frame, after the caller has done
		// scene.add(character.g). attach needs the object to be in the scene (it
		// reads the world position), and the caller is free to add the mesh at
		// any point after constructing it.
		if (owns) {
			if (!s.attached) {
				cam.attach(g, {
					offset: camera.offset ?? [0, 1.7, 0],
					distance: s.dist,
					lag: camera.lag ?? 0,
				});
				// Remembered rather than assumed, so `dispose()` puts back what
				// the caller had rather than what this file thinks is normal.
				s.controlsWere = three.controls.enabled;
				three.controls.enabled = false;
				s.attached = true;
			}

			const ptr = input.pointer;

			// Mouse-look only while a button is held: this host reports tiny
			// nonzero pointer deltas every frame even when the cursor is idle, and
			// applying them unconditionally makes the look creep (and the move
			// frame rotate) on its own. Drag is this app's own "to orbit"
			// convention, so gating on ptr.down reads as intended rather than
			// surprising.
			if (ptr.down) {
				s.yaw -= ptr.dx * LOOK_PER_PIXEL_YAW * sensitivity;
				s.pitch += ptr.dy * LOOK_PER_PIXEL_PITCH * sensitivity;
			}
			s.yaw += axis('yawLeft', 'yawRight') * LOOK_PER_SECOND_YAW * delta;
			s.pitch += axis('pitchUp', 'pitchDown') * LOOK_PER_SECOND_PITCH * delta;
			s.pitch = clamp(s.pitch, pitchRange[0], pitchRange[1]);
			s.dist = clamp(s.dist + ptr.scroll, distanceRange[0], distanceRange[1]);

			// Point the CAMERA wherever the look state is, so the view and the
			// frame the movement reads off are never different things. Without
			// this the camera stayed where it was last orbit()'d while the move
			// frame rotated away from it — the W/A/S/D "different directions"
			// symptom.
			cam.orbit(s.yaw, s.pitch, s.dist);
		}

		// --- move in the camera's frame. planarMove is the one call that keeps
		// "forward" exactly where the camera points.
		const move = cam.planarMove(axis('forward', 'back'), axis('right', 'left'));
		s.moving = move.length() > 0;
		if (s.moving) {
			s.heading = Math.atan2(move.x, move.z);
			let x = g.position.x + move.x * speed * delta;
			let z = g.position.z + move.z * speed * delta;
			if (area !== null) {
				x = clamp(x, area.x - area.halfW, area.x + area.halfW);
				z = clamp(z, area.z - area.halfD, area.z + area.halfD);
			}
			g.position.x = x;
			g.position.z = z;
		}
		g.rotation.y = s.heading;

		// --- vertical: ride the terrain, jump on space, fall off ledges ---
		const ground = groundY(g.position.x, g.position.z);
		if (s.grounded && held('jump')) {
			s.vy = jump;
			s.grounded = false;
		} else if (s.grounded && ground < g.position.y - snap) {
			// The floor fell away rather than sloped away. Leaving `vy` at zero
			// means the fall starts from rest, which is what walking off an edge
			// looks like; without this branch the feet were re-planted on the new
			// ground every frame and a cliff was a teleport.
			s.vy = 0;
			s.grounded = false;
		}

		if (s.grounded) {
			g.position.y = ground;
		} else {
			s.vy -= gravity * delta;
			g.position.y += s.vy * delta;
			if (g.position.y <= ground) { g.position.y = ground; s.vy = 0; s.grounded = true; }
		}

		// --- a little walk cycle, swinging the pivots if the mesh has any ---
		if (built.legs.length || built.arms.length) {
			if (s.moving) s.walkT += delta * 10;
			const swing = s.moving ? Math.sin(s.walkT) * 0.55 : 0;
			if (built.legs[0]) built.legs[0].rotation.x = swing;
			if (built.legs[1]) built.legs[1].rotation.x = -swing;
			if (built.arms[0]) built.arms[0].rotation.x = -swing * 0.7;
			if (built.arms[1]) built.arms[1].rotation.x = swing * 0.7;
		}
	}

	// Give the camera and the mouse back.
	//
	// The character keeps existing and `step` keeps moving it; what stops is
	// this controller's claim on two things that are global — the follow and
	// `three.controls.enabled`. Detaching is conditional because by the time
	// anyone calls this the camera may be following something else, and taking
	// that away would be a surprise sourced from an object nobody is looking at.
	function dispose() {
		if (!s.attached) return false;
		const three = globalThis.three;
		if (three.camera.attached === g) three.camera.detach();
		if (s.controlsWere !== null) three.controls.enabled = s.controlsWere;
		s.attached = false;
		s.controlsWere = null;
		return true;
	}

	// The look, when this character is not the thing driving it. Read through
	// rather than remembered, so `p.yaw` is the camera's yaw and not a stale
	// copy of a number nothing is applying.
	const look = () => globalThis.three.camera.toJSON();
	const owned = (name, v) => {
		if (!owns) {
			throw new TypeError(
				`character.${name} cannot be set on a character made with { camera: false } — it does `
				+ 'not drive the camera. three.camera.orbit(yaw, pitch, distance) does.'
			);
		}
		const n = +v;
		if (!Number.isFinite(n)) throw new RangeError(`character.${name} wants a finite number — got ${v}`);
		return n;
	};

	return {
		g,
		step,
		dispose,
		// Readable state, so a script can inspect or steer the character.
		get position() { return g.position; },
		get yaw() { return owns ? s.yaw : look().yaw; },
		set yaw(v) { s.yaw = owned('yaw', v); },
		get pitch() { return owns ? s.pitch : look().pitch; },
		set pitch(v) { s.pitch = clamp(owned('pitch', v), pitchRange[0], pitchRange[1]); },
		get dist() { return owns ? s.dist : look().distance; },
		set dist(v) { s.dist = clamp(owned('dist', v), distanceRange[0], distanceRange[1]); },
		get heading() { return s.heading; },
		get moving() { return s.moving; },
		get grounded() { return s.grounded; },
		get bounds() { return area === null ? null : { x: area.x, z: area.z, width: area.halfW * 2, depth: area.halfD * 2 }; },
	};
}

const clamp = (v, min, max) => Math.max(min, Math.min(max, v));

// A number this controller will multiply by dt and add to a position. Every one
// of them is refused rather than coerced, because a NaN that gets in here is a
// character that vanishes on the first frame and never comes back — and the
// version of this file that coerced silently is the reason the check exists.
function atLeast(value, fallback, least, where, name) {
	if (value === undefined || value === null) return fallback;
	const n = +value;
	if (!Number.isFinite(n) || n < least) {
		const floor = least === -Infinity ? 'a finite number' : `a finite number of at least ${least}`;
		throw new RangeError(`${where}: ${name} wants ${floor} — got ${value}`);
	}
	return n;
}

// [min, max], widened to hold `must`. A caller who asked for a distance of 40
// and said nothing about the range asked for both, and clamping the first to
// the default of the second is the silent kind of wrong the rest of this API
// throws to avoid. Saying both, and disagreeing, is the error.
function rangeOf(value, fallback, must, where, name) {
	if (value === undefined || value === null) {
		return [Math.min(fallback[0], must), Math.max(fallback[1], must)];
	}
	if (!Array.isArray(value) || value.length !== 2) {
		throw new TypeError(`${where}: ${name} wants [min, max] — got ${value}`);
	}
	const min = +value[0], max = +value[1];
	if (!Number.isFinite(min) || !Number.isFinite(max) || min > max) {
		throw new RangeError(
			`${where}: ${name} wants [min, max] with min no greater than max — got [${value[0]}, ${value[1]}]`
		);
	}
	if (must < min || must > max) {
		throw new RangeError(
			`${where}: ${name} is [${min}, ${max}], which does not hold ${must} — where this camera starts`
		);
	}
	return [min, max];
}

// The fence the character walks inside, or none.
//
// A terrain's own extent by default, read the way `three.scatter` reads it in
// `field.js` — restating a width in two places is how the two drift apart, and
// the literal this replaces was that drift already frozen. With no terrain
// there is no natural extent, so a `height` function walks forever unless the
// caller draws the fence themselves.
function boundsOf(bounds, terrain, where) {
	if (bounds === false) return null;
	if (bounds === undefined || bounds === null) {
		if (terrain === null) return null;
		const width = terrain.width ?? terrain.parameters?.width ?? 100;
		const depth = terrain.depth ?? terrain.parameters?.depth ?? width;
		return { x: 0, z: 0, halfW: width / 2, halfD: depth / 2 };
	}
	if (typeof bounds !== 'object') {
		throw new TypeError(`${where}: bounds wants { x, z, width, depth }, or false for none — got ${bounds}`);
	}
	const width = size(bounds.width, where, 'bounds.width');
	const depth = bounds.depth === undefined || bounds.depth === null ? width : size(bounds.depth, where, 'bounds.depth');
	return {
		x: atLeast(bounds.x, 0, -Infinity, where, 'bounds.x'),
		z: atLeast(bounds.z, 0, -Infinity, where, 'bounds.z'),
		halfW: width / 2,
		halfD: depth / 2,
	};
}

function size(value, where, name) {
	const n = +value;
	if (!Number.isFinite(n) || n <= 0) {
		throw new RangeError(`${where}: ${name} wants a size greater than zero — got ${value}`);
	}
	return n;
}

// Where to stand at the start, as [x, z] or { x, z }. Two coordinates and not
// three: the third is the ground, and the ground is the one thing here that is
// never a guess.
function spawnOf(value, where) {
	if (value === undefined || value === null) return [0, 0];
	if (Array.isArray(value) && value.length === 2) {
		return [atLeast(value[0], 0, -Infinity, where, 'spawn[0]'), atLeast(value[1], 0, -Infinity, where, 'spawn[1]')];
	}
	if (typeof value === 'object' && value.x !== undefined && value.z !== undefined) {
		return [atLeast(value.x, 0, -Infinity, where, 'spawn.x'), atLeast(value.z, 0, -Infinity, where, 'spawn.z')];
	}
	throw new TypeError(`${where}: spawn wants [x, z] or { x, z } — the ground supplies the y — got ${value}`);
}

// The bindings, merged over the defaults so a caller rebinding `jump` keeps
// W/A/S/D. An action this table does not have is refused rather than ignored:
// a misspelled `foward` that silently did nothing is a controller that reads as
// broken hardware.
function keysOf(value, where) {
	if (value === undefined || value === null) return DEFAULT_KEYS;
	if (typeof value !== 'object') {
		throw new TypeError(`${where}: keys wants { ${Object.keys(DEFAULT_KEYS).join(', ')} } — got ${value}`);
	}
	const bound = { ...DEFAULT_KEYS };
	for (const [action, binding] of Object.entries(value)) {
		if (!(action in DEFAULT_KEYS)) {
			throw new TypeError(
				`${where}: keys has no '${action}' — the actions are ${Object.keys(DEFAULT_KEYS).join(', ')}`
			);
		}
		const list = Array.isArray(binding) ? binding : [binding];
		if (list.length === 0 || list.some(key => typeof key !== 'string' || key.length === 0)) {
			throw new TypeError(`${where}: keys.${action} wants a key name or a list of them — got ${binding}`);
		}
		// Lowercased because the host's names are KeyboardEvent.key lowercased,
		// and 'W' otherwise reads as a key nobody is ever holding.
		bound[action] = list.map(key => key.toLowerCase());
	}
	return bound;
}

function listOf(value, where, name) {
	if (value === undefined || value === null) return [];
	if (!Array.isArray(value)) {
		throw new TypeError(`${where}: ${name} wants an array of pivots for the walk cycle to swing — got ${value}`);
	}
	return value;
}

// A caller's own height function, checked at the point it answers. The terrain
// path cannot produce this — `heightAt` is bilinear over a grid of numbers the
// host already validated — but a script's `(x, z) => y` is arbitrary code, and
// one NaN from it lands in `position.y` and stays there.
function finiteGround(y, x, z) {
	const n = +y;
	if (!Number.isFinite(n)) {
		throw new RangeError(`${WHERE}: height(${x}, ${z}) returned ${y} — the ground must be a finite number`);
	}
	return n;
}
