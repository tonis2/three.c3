// three.c3 — the `three` object itself: the light, the camera, the input, and
// every verb an agent calls.

import { Vector3, Box3, readVector, asTriple } from './math.js';
import { Group } from './object3d.js';
import {
	Texture,
	DataTexture,
	uploadOptions,
	NoColorSpace,
	SRGBColorSpace,
	LinearSRGBColorSpace,
} from './texture.js';
import { FrontSide, BackSide, DoubleSide, NoBlending, NormalBlending, AdditiveBlending, Material, MeshLambertMaterial } from './material.js';
import { ShaderMaterial } from './shader.js';
import { LayeredMaterial } from './layers.js';
import { postSpec, postFinish, bumpPostEpoch } from './post.js';
import { Mesh } from './mesh.js';
import { liveScene, Scene, liveObject, objectForHandle } from './scene.js';
import { MeshRef, Asset } from './asset.js';
import { Geometry, BoxGeometry, SphereGeometry, PlaneGeometry, CylinderGeometry, ConeGeometry, TorusGeometry, ConvexGeometry, TerrainGeometry, RibbonGeometry } from './geometry.js';
import { Field, scatter, catmullRom } from './field.js';
import { character } from './character.js';
import { Box3Helper, BoxHelper, AxesHelper, GridHelper, WireframeHelper } from './helpers.js';
import { docsQuery, docsSearch } from './docs.js';

const H = globalThis.__three;

// -----------------------------------------------------------------------
// The camera
//
// A turntable, not a free Object3D, and named so. Three.js's
// `camera.position.set(...)` has no meaning here, so the properties that
// would half-match it do not exist — `orbit()` and `frameAll()` are names
// Three.js does not have, which is `plan.md` §4's rule for a divergence.

// -------------------------------------------------------------------
// The light
//
// One directional light and an ambient floor, which is the whole model the
// shaders implement. Not `scene.add(new three.DirectionalLight(...))`: that
// name would promise adding, removing, colouring and duplicating, and this
// renderer can do none of them. `plan.md` §4's half-match rule — a name
// Three.js does not have is a name nobody expects Three.js's behaviour from.
//
// `direction` hands back a live Vector3, so `three.light.direction.y = -1`
// writes through the same way `mesh.position.y = 1` does. A detached copy
// would be the trap the camera avoided by making yaw and pitch throw on
// assignment — a property that reads back what you wrote and changes nothing.

const light = {
	get direction() {
		const [x, y, z] = H.lightGet();
		const v = new Vector3(null, x, y, z);
		v._o = { _flush() { H.lightSet(v._x, v._y, v._z, H.lightGet()[3]); } };
		return v;
	},
	set direction(v) {
		const [x, y, z] = readVector(v, 'three.light.direction');
		H.lightSet(x, y, z, H.lightGet()[3]);
	},

	// 0 leaves a face turned away from the light black; 1 removes the
	// shading entirely and everything is its own flat colour.
	get ambient() { return H.lightGet()[3]; },
	set ambient(v) {
		const [x, y, z] = H.lightGet();
		H.lightSet(x, y, z, +v);
	},

	// Both at once, because setting them one at a time is two host crossings
	// and reads worse at a call site that always means one change.
	set(direction, ambient = H.lightGet()[3]) {
		const [x, y, z] = readVector(direction, 'three.light.set(direction, ambient)');
		H.lightSet(x, y, z, +ambient);
		return light;
	},

	// The shadow this light casts. `three.light.shadow.bias` and
	// `.intensity` are Three.js's own names on Three.js's own object —
	// `DirectionalLight.shadow` — and they mean here what they mean there.
	//
	// Two divergences and both are deliberate. `enabled` lives here rather
	// than as `castShadow` on the light or `shadowMap.enabled` on a
	// renderer, because there is neither a light object nor a renderer
	// object to hang it on. And `size` is one number where Three.js has
	// `mapSize`, a Vector2: this map is square, and a name Three.js does
	// not have is `plan.md` §4's rule for saying so.
	//
	// A fresh object each read, like `direction` above, so the four
	// properties always answer with what the host holds rather than with
	// what a captured copy remembered.
	get shadow() {
		return {
			// Off by default. Turning it on allocates a depth image and
			// compiles a shader the first frame after, and never before
			// — a project that does not ask pays for none of it.
			get enabled() { return H.shadowGet()[0] !== 0; },
			set enabled(v) {
				const [, size, bias, intensity, distance] = H.shadowGet();
				H.shadowSet(v ? 1 : 0, size, bias, intensity, distance);
			},

			// Texels per side. Clamped to 256..8192 and rounded down to a
			// power of two, so it reads back as what will actually be
			// allocated rather than as what was typed.
			get size() { return H.shadowGet()[1]; },
			set size(v) {
				const [enabled, , bias, intensity, distance] = H.shadowGet();
				H.shadowSet(enabled, +v, bias, intensity, distance);
			},

			// Extra depth offset in the light's clip space, 0 by default.
			// The renderer already offsets each sample along the surface
			// normal by two texels, which is what actually removes the
			// self-shadowing stripes, so this is the knob for the scene
			// that still shows them rather than the one everybody has to
			// tune.
			get bias() { return H.shadowGet()[2]; },
			set bias(v) {
				const [enabled, size, , intensity, distance] = H.shadowGet();
				H.shadowSet(enabled, size, +v, intensity, distance);
			},

			// How dark a shadow is, 0 to 1. 1 takes the whole directional
			// term away and leaves `three.light.ambient`, which is why a
			// shadow is never black unless the ambient floor is zero.
			get intensity() { return H.shadowGet()[3]; },
			set intensity(v) {
				const [enabled, size, bias, , distance] = H.shadowGet();
				H.shadowSet(enabled, size, bias, +v, distance);
			},

			// How far down the view direction the map is fitted, in world
			// units. 0 is the camera's far plane, which is the default and
			// is what a scene the camera can see all of wants.
			//
			// This is the texel-density knob, and it matters more than
			// `size`: the map covers a square this wide, so halving the
			// distance is worth quadrupling the size and costs nothing.
			// Set it to roughly how far away shadows are worth having.
			// Too small and shadows stop at a visible line across the
			// ground; too large and they are soft mush.
			get distance() { return H.shadowGet()[4]; },
			set distance(v) {
				const [enabled, size, bias, intensity] = H.shadowGet();
				H.shadowSet(enabled, size, bias, intensity, +v);
			},

			// Where the map actually landed last frame, read-only.
			//
			// Six numbers instead of an inset picture of the depth
			// buffer, and the reason is that a fitted box is a box: an
			// inset is a thing to squint at and a number is the only one
			// of the two a headless run can assert on.
			//
			//   live    whether a shadow pass ran at all. False, and a
			//           frame with no shadows in it needs no further
			//           explanation.
			//   center  the middle of the fitted box, in world space.
			//   extent  how wide the box is, in world units. Read this
			//           one first — `extent / size` is the world size of
			//           a texel, and that is what decides whether an
			//           edge reads as a shadow or as a staircase.
			//   near    the light's own planes, in world units. They
			//   far     come from the whole scene and not from the
			//           focus box, because a caster standing between the
			//           light and the visible ground has to be in range
			//           or its shadow never lands.
			//   texel   `extent / size`, computed here so it cannot be
			//           computed differently somewhere else.
			//
			// A fresh object each read, like everything else on this
			// object, so it answers about the last frame rather than
			// about whenever it was captured.
			get fit() {
				const [live, cx, cy, cz, extent, near, far, texel] = H.shadowFit();
				return {
					live: live !== 0,
					center: [cx, cy, cz],
					extent, near, far, texel,
				};
			},
		};
	},

	// `three.light.shadow = true` and `= { size: 4096 }` both work, because
	// the first is what somebody writes without reading anything and the
	// second is what they write after. An object sets only the keys it
	// names; a boolean is `{ enabled: it }`.
	set shadow(v) {
		const [enabled, size, bias, intensity, distance] = H.shadowGet();
		if (typeof v === 'boolean' || v == null) {
			H.shadowSet(v ? 1 : 0, size, bias, intensity, distance);
			return;
		}
		if (typeof v !== 'object') {
			throw new TypeError('three.light.shadow takes true, false, or an object with enabled, size, bias, intensity or distance');
		}
		H.shadowSet(
			('enabled' in v ? (v.enabled ? 1 : 0) : enabled),
			('size' in v ? +v.size : size),
			('bias' in v ? +v.bias : bias),
			('intensity' in v ? +v.intensity : intensity),
			('distance' in v ? +v.distance : distance),
		);
	},
};

const camera = {
	get fov() { return H.cameraGet()[6]; },
	set fov(v) {
		const [tx, ty, tz, yaw, pitch, distance] = H.cameraGet();
		H.cameraSet(tx, ty, tz, yaw, pitch, distance, +v);
	},

	get yaw() { return H.cameraGet()[3]; },
	get pitch() { return H.cameraGet()[4]; },
	get distance() { return H.cameraGet()[5]; },

	// The three that `orbit()` writes, and the two that nothing writes, all
	// refuse assignment out loud.
	//
	// A getter with no setter is not silence-free: a script is not evaluated
	// in strict mode, so `camera.far = 500` would *do nothing at all* and
	// report nothing at all — and the whole reason near and far became
	// readable in M6 is that a plane nobody could see had already cost a
	// session. Throwing here is the same call the ShaderMaterial uniform
	// Proxy makes, for the same reason.
	set yaw(_) { throw new TypeError('the turntable is moved by three.camera.orbit(yaw, pitch, distance), not by assigning yaw'); },
	set pitch(_) { throw new TypeError('the turntable is moved by three.camera.orbit(yaw, pitch, distance), not by assigning pitch'); },
	set distance(_) { throw new TypeError('the turntable is moved by three.camera.orbit(yaw, pitch, distance), not by assigning distance'); },
	set near(_) { throw new TypeError('near is derived from the orbit distance and the scene bounds — move the camera, or three.camera.frameAll()'); },
	set far(_) { throw new TypeError('far is derived from the orbit distance and the scene bounds — move the camera, or three.camera.frameAll()'); },

	// Read-only, and both halves of that are deliberate.
	//
	// They are **derived** — from the orbit distance and from the scene's own
	// bounds, every time the camera moves — because a fixed near plane in
	// front of a kilometre-wide model spends the whole depth buffer on the
	// first few metres, and a fixed far plane behind a one-metre one throws
	// the rest of it away. Neither number is a taste setting; both are
	// functions of what is being looked at, so the camera computes them.
	//
	// They are **reported** because being derived does not make them
	// uninteresting. A sky that renders at one zoom level and not at another
	// is `camera.far` moving, and until M6 there was no way to see that
	// happening — only to render, guess, and get it wrong.
	get near() { return H.cameraGet()[7]; },
	get far() { return H.cameraGet()[8]; },

	// Live, like `mesh.position` and unlike `getWorldPosition()` — so
	// `three.camera.target.y = 2` raises the turntable's focus instead of
	// editing a copy nothing reads again. `lookAt` is what it flushes
	// through, so there is one path that moves the target and one place the
	// planes are re-derived.
	get target() {
		const [tx, ty, tz] = H.cameraGet();
		const v = new Vector3(null, tx, ty, tz);
		v._o = { _flush() { camera.lookAt(v.x, v.y, v.z); } };
		return v;
	},
	set target(v) { this.lookAt(v); },

	// Degrees for the angles, world units for the distance — the same units
	// the host camera keeps them in. Any argument may be left out.
	orbit(yaw, pitch, distance) {
		const c = H.cameraGet();
		H.cameraSet(
			c[0], c[1], c[2],
			yaw ?? c[3],
			pitch ?? c[4],
			distance ?? c[5],
			c[6],
		);
		return this;
	},

	lookAt(x, y, z) {
		const c = H.cameraGet();
		if (typeof x === 'object' && x !== null) ({ x, y, z } = x);
		H.cameraSet(+x, +y, +z, c[3], c[4], c[5], c[6]);
		return this;
	},

	// Aim at everything in the scene and back off far enough to see it. What
	// an agent that has just loaded an unfamiliar model wants, because the
	// right distance depends on how big the model is.
	//
	// It refuses while the camera is attached rather than fighting the
	// follow for a frame and losing. Framing the scene means putting the
	// orbit point in the middle of it, and the next tick puts it back on the
	// character — so this would flicker once and change nothing, which is
	// the silent kind of nothing the rest of this object throws to avoid.
	frameAll() {
		if (H.cameraAttached()) {
			throw new Error(
				'three.camera.frameAll() cannot frame the scene while the camera is following '
				+ 'something — the next frame would put it back. three.camera.detach() first.'
			);
		}
		H.frameAll();
		return this;
	},

	// -------------------------------------------------------------------
	// Following something
	//
	// **What `attach` owns is the orbit point, and nothing else.** The
	// object's world position (plus `offset`) becomes `camera.target` every
	// frame, after the animation, the solver and the animation callback have
	// all had their turn at moving it — so the camera is never a frame
	// behind the character, which reads as the character sliding rather than
	// as the camera trailing.
	//
	// Everything else still works while attached: a drag orbits, the wheel
	// zooms, `orbit()` aims. **A pan is the one that stops**, because a pan
	// is the one gesture that writes the orbit point, and the next frame
	// writes it back.
	//
	// **`distance: 0` is first person.** It is not a mode — the eye simply
	// sits on the point it orbits, which is the head. Scroll out and it is a
	// third-person camera again with nothing to switch. The offset is where
	// the head is: `{ offset: [0, 1.7, 0], distance: 0 }` is a person, and
	// `{ offset: [0, 1.5, 0], distance: 4 }` is a camera over their
	// shoulder.
	//
	// `lag` is milliseconds, and it is a time constant rather than a
	// fraction: 0 is rigid, 120 is a camera that takes about an eighth of a
	// second to catch up, and the same number means the same lateness at 60
	// and at 144 frames a second.
	//
	// The offset is in **world space**. A head is [0, 1.7, 0] whichever way
	// a character faces, so this covers first person and a shoulder camera;
	// what it does not cover is a camera bolted into something that pitches
	// and rolls.
	attach(object, { offset = [0, 0, 0], distance = null, lag = 0 } = {}) {
		const target = liveObject(object, 'three.camera.attach');
		const [ox, oy, oz] = asTriple(offset, 'three.camera.attach(object, { offset })');
		const boom = distance === null ? H.cameraGet()[5] : +distance;
		if (!Number.isFinite(boom) || boom < 0) {
			throw new RangeError(
				`three.camera.attach(object, { distance }) wants zero or more — ${distance} is not a boom length`
			);
		}
		H.cameraAttach(target[0], target[1], ox, oy, oz, boom, +lag);
		return this;
	},

	// Stop following. Answers whether it was, and leaves the camera exactly
	// where the last frame put it.
	detach() { return H.cameraDetach(); },

	// -------------------------------------------------------------------
	// Derived directions
	//
	// These are the three vectors a character controller actually needs, and
	// the reason they exist is that you cannot get them by reading the
	// camera: `camera.position` and `getWorldPosition()` do not exist, so a
	// script that wanted "which way is the camera facing" had to hand-roll
	// the orbit trig — and get the signs wrong in a way that read as the
	// character walking sideways. Reading them here means one definition,
	// beside the code that moves the camera.
	//
	// The convention they encode, and which a screenshot can verify: yaw is
	// degrees about +Y from +Z, so `orbit(0, 0)` puts the camera at +Z
	// looking toward -Z, and `orbit(90, 0)` puts it at +X looking toward -X.

	// The camera's eye, in world space — the point `distance` back from the
	// target along the orbit direction. Not `target`, which is what it
	// orbits; not writable, because the turntable owns its own position.
	position() {
		const [tx, ty, tz, yaw, pitch, distance] = H.cameraGet();
		const a = yaw * Math.PI / 180, p = pitch * Math.PI / 180, cp = Math.cos(p);
		return new Vector3(null,
			tx + distance * cp * Math.sin(a),
			ty + distance * Math.sin(p),
			tz + distance * cp * Math.cos(a));
	},

	// The direction the camera looks, world space, unit length, including the
	// pitch. This is "forward" for a view relative to the camera.
	forward() {
		const [, , , yaw, pitch] = H.cameraGet();
		const a = yaw * Math.PI / 180, p = pitch * Math.PI / 180, cp = Math.cos(p);
		return new Vector3(null, -Math.sin(a) * cp, -Math.sin(p), -Math.cos(a) * cp);
	},

	// The camera's right on the ground plane, world space, unit length, y=0.
	// "Screen right" — the `D` key. Flattened so it stays useful for strafe
	// while pitched down at a character.
	right() {
		const [, , , yaw] = H.cameraGet();
		const a = yaw * Math.PI / 180;
		return new Vector3(null, Math.cos(a), 0, -Math.sin(a));
	},

	// The world-space movement direction for a camera-relative input, with
	// `fwd` forward (the `W`/`S` axis, +1 to -1) and `strafe` sideways (the
	// `D`/`A` axis, +1 to -1). Returns a unit Vector3 with y=0, or the zero
	// vector when both inputs are 0. This is the one call that keeps a
	// character from drifting sideways off the camera's forward line.
	planarMove(fwd, strafe) {
		const [, , , yaw] = H.cameraGet();
		const a = yaw * Math.PI / 180;
		const Fx = -Math.sin(a), Fz = -Math.cos(a);
		const Rx = Math.cos(a), Rz = -Math.sin(a);
		let mx = Fx * fwd + Rx * strafe, mz = Fz * fwd + Rz * strafe;
		const len = Math.hypot(mx, mz);
		if (len > 0) { mx /= len; mz /= len; }
		return new Vector3(null, mx, 0, mz);
	},

	// What the camera is following, or null. Also how a script finds out
	// that what it was following has been destroyed: the host drops the
	// attachment silently, because the alternative is throwing from inside a
	// frame nobody called.
	get attached() {
		const handle = H.cameraAttached();
		return handle === null ? null : objectForHandle(handle);
	},
	set attached(_) { throw new TypeError('the camera follows through three.camera.attach(object) and three.camera.detach()'); },

	toJSON() {
		const [x, y, z, yaw, pitch, distance, fov, near, far] = H.cameraGet();
		return { target: { x, y, z }, yaw, pitch, distance, fov, near, far };
	},
};

// -----------------------------------------------------------------------
// The mouse's other end
//
// `three.controls` is the hand on the window, and it has one property:
// whether it reaches the camera. Three.js spells it the same way on
// `OrbitControls`, which is why it is not a name this project invented —
// §4's rule the other way round, for once. What it is *not* is a
// constructor: there is one turntable, made by the host, and nobody adds a
// second set of controls to it.
//
// **Turn it off to drive the camera yourself.** A follow camera or a
// first-person look writes yaw, pitch and target every frame, and the
// turntable writes them again from whatever the mouse did; the two fight
// over one matrix sixty times a second and the result reads as a camera
// that shudders. Off, the window stops writing and the script is the only
// author.
//
// **It does not touch `three.camera.orbit()`** — that is a script moving
// the camera on purpose, which is the thing being made possible rather than
// the thing being prevented.
//
// **Leaving it off is a bad way to leave a window.** Nobody can move the
// camera in one, and there is no gesture that turns it back on; a script
// that takes the mouse for a mode is the script that gives it back when the
// mode ends.
//
// **It survives `new three.Scene()`,** following the camera rather than the
// background. The three things a rebuild resets — background, light,
// shadow — are reset so that two scripts render the same first frame, and
// this changes no pixel; what it would change is a game that took the mouse
// for its own camera losing it at every level boundary.

const controls = {
	get enabled() { return H.controlsGet(); },
	set enabled(v) { H.controlsSet(!!v); },
};

// -----------------------------------------------------------------------
// The clock
//
// Not a Three.js API in this shape — Three.js has a `Clock` you construct
// and ask for a delta, and nothing that a pause would reach. This one is
// the host's, there is one of it, and everything in a frame that moves is
// downstream of it: the clips, the solver, the fixed loop below, the
// follow camera, the argument the animation callback is handed, and
// `p.time` in a post body.
//
// **That list is the whole feature.** `dt` on its own is a subtraction any
// script could do — and every example here used to. What no subtraction
// buys is `timeScale = 0`, because a script stopping its own arithmetic
// still leaves a world running underneath it: a clip playing, a body
// falling, a post pass animating.
//
// Seconds, everywhere, like Three.js's `Clock` and like `p.time`. The one
// place milliseconds survive is the animation callback's argument, which
// keeps Three.js's units because it keeps Three.js's name — it is this
// same clock, times a thousand.

const clock = {
	// Game seconds since the first frame. Monotonic, and frozen while
	// paused rather than merely ignored.
	get time() { return H.clockTime(); },
	set time(_) { throw new TypeError('three.clock.time is what the frames have added up to — three.clock.advance(seconds) moves it'); },

	// What the frame being drawn is worth, in game seconds. Zero before
	// the first frame and zero while paused, so `x += speed * three.clock.dt`
	// needs no `if` to respect a pause.
	//
	// Clamped: a frame that took longer than 100 ms of wall time reports
	// 100 ms of it and drops the rest, so a breakpoint or a long tool call
	// stutters rather than teleporting everything a second forward.
	get dt() { return H.clockDelta(); },
	set dt(_) { throw new TypeError('three.clock.dt is what the last frame was worth — three.clock.timeScale is the knob'); },

	// Wall time to game time. 1 is real time, 0.25 is slow motion, 3 is
	// fast forward, 0 is paused. Negative throws: nothing downstream of
	// this can run backwards.
	get timeScale() { return H.clockScaleGet(); },
	set timeScale(v) { H.clockScaleSet(+v); },

	// Whether the clock is stopped. A getter and not a setter, because a
	// `paused` that remembered the scale it interrupted would be a second
	// place the scale comes from, and the next script to read `timeScale`
	// would have to know which of the two was in play. Pause with
	// `timeScale = 0` and resume by writing the scale you want.
	get paused() { return H.clockScaleGet() === 0; },
	set paused(_) { throw new TypeError('pause with three.clock.timeScale = 0, and resume by setting it back to 1'); },

	// How many fixed steps a second of game time is worth. 60 by default,
	// 1 to 240. It does not change the solver's rate, which is 60 Hz and
	// is the solver's business.
	get fixedRate() { return H.clockRateGet(); },
	set fixedRate(hz) { H.clockRateSet(+hz); },

	// One fixed step in seconds — the number `setFixedLoop`'s callback is
	// handed, available outside it for a script that wants to size
	// something against the step.
	get fixedDelta() { return 1 / H.clockRateGet(); },
	set fixedDelta(_) { throw new TypeError('three.clock.fixedDelta follows three.clock.fixedRate — set the rate'); },

	// Move the clock by hand, whatever the scale is. What makes a pause
	// steppable: `three.clock.timeScale = 0` and then `advance(1 / 60)` is
	// exactly one frame of world — the clips, the bodies, the fixed steps
	// and `p.time`, all of it, once.
	//
	// It lands on the next frame rather than immediately, because
	// everything that consumes a delta is downstream of one conversion at
	// the top of the frame. Under `--mcp` that means a run_script that
	// advances is followed by a frame and then a screenshot; in a window
	// the frames are already arriving.
	advance(seconds) { H.clockAdvance(+seconds); },
};

// -----------------------------------------------------------------------
// The keyboard
//
// Not a Three.js API — Three.js has no input layer at all, and this is in
// the `differences` list because of it. The key *names* are the browser's
// (`KeyboardEvent.key`, lowercased), because those are the strings an agent
// has memorized even though the object around them is new.
//
// `isDown` is meaningful whenever it is asked. `pressed`, `released` and
// `text` describe the frame being drawn right now, so they only mean
// something inside the animation callback — between frames they report
// whatever the last frame happened to see, which is almost always nothing.

const input = {
	isDown(key) { return H.inputDown(String(key)); },
	pressed(key) { return H.inputPressed(String(key)); },
	released(key) { return H.inputReleased(String(key)); },

	// -------------------------------------------------------------------
	// Pressing keys from a script
	//
	// A headless boot has no keyboard, so a scene whose whole subject is
	// input could not be exercised at all: `examples/village` binds seven
	// keys to a character, and the only way to test the walking and the
	// collision was for the scene to hand its internals to a global — a
	// scene leaking its own state in order to be testable.
	//
	// **A held key, not an event.** It stays down until released, exactly as
	// a finger does, so a walk is `press('w')`, sixty frames, `release('w')`
	// rather than sixty calls of which one may be forgotten. The edges come
	// out of the same difference a real key's do, so `pressed`, `released`
	// and every onKeyDown handler behave identically — there is one
	// keyboard, not two paths into it.
	//
	// It adds to the real keyboard rather than replacing it, so a scripted
	// demo works with someone still at the keys.
	press(key) { H.inputHold(String(key), true); },
	release(key) { H.inputHold(String(key), false); },

	// Let go of everything. What a test calls between cases so one does not
	// leak a held key into the next.
	releaseAll() { H.inputReleaseAll(); },

	// What was typed this frame, with modifier chords and the function-key
	// range already filtered out. This, and not the key map, is what a text
	// field wants: it has the keyboard layout applied and the shift key
	// already accounted for.
	get text() { return H.inputText(); },

	// Every name there is, in one place, and the same list the host
	// searches. Aliases are included: ctrl, cmd and esc.
	keys() { return H.keyNames(); },

	// The whole mouse for this frame, as one reading of one instant:
	//
	//     { x, y, dx, dy, inside, down, right, middle, clicked,
	//       scroll, scrollX }
	//
	// `x` and `y` are in the rendered image's pixels — the same coordinates
	// scene.pick(x, y) takes and the same corner the PNG starts at, whatever
	// size the window has been dragged to. Everything is zero and `inside`
	// is false when there is no window.
	//
	// **`dx`/`dy` are the movement, and they are not the same question as
	// the position.** A look is built out of the movement, and
	// differencing `x` across two calls answers it with the frame before
	// the one being drawn — a script only ever sees where the cursor was at
	// the moment it asked, while the host differences the reading the frame
	// is actually using. The browser calls these `movementX`/`movementY`.
	//
	// They keep coming while the cursor is outside the window, because the
	// window goes on saying where it is; they stop at the edge of the
	// *screen*, where the platform stops the cursor. Getting past that is
	// pointer lock and there is none — see the note in `plan.md` §17.
	//
	// **`scroll` is positive away from the user**, which is the opposite of
	// the browser's `deltaY` and the same direction the camera's zoom
	// already reads it in. It is notches, or fractions of one from a
	// trackpad, accumulated over the frame and zero on the frames nobody
	// turned it — which is nearly all of them.
	//
	// **`down`, `right` and `middle` are latches, not edges.** The left
	// button orbits and the other two pan unless three.controls.enabled is
	// false, so a script polling them while the camera still has the mouse
	// is reading a gesture it does not own. `clicked` is the one edge, and
	// three.onClick is the one thing dispatched from it.
	get pointer() { return H.pointer(); },

	// True for the one frame a click finished on. A press that travelled or
	// was held is a drag, and a drag belongs to the camera.
	get clicked() { return H.pointer().clicked; },
};

// The host raycasts in image pixels and answers with a node index; turning
// that back into the object a script is holding is the Scene's job, and the
// Scene that does it is the live one. With none — a model opened from the
// command line, or nothing built yet — the hit still carries its name, which
// is the only identity such a node has, and `object` is null.
function asIntersection(raw) {
	if (raw === null) return null;
	if (liveScene !== null && liveScene._e === H.epoch()) return liveScene._intersection(raw);
	return {
		object: null,
		name: raw.name,
		distance: raw.distance,
		point: new Vector3(null, raw.point[0], raw.point[1], raw.point[2]),
		normal: new Vector3(null, raw.normal[0], raw.normal[1], raw.normal[2]),
	};
}

// What the renderer draws instead of the scene, when it is asked to.
//
// **A frame with no visible shadows in it has three explanations** — the pass
// did not run, the pass ran and the map is fitted somewhere else, or everything
// in shot is genuinely inside one big shadow — and until this existed the
// renderer distinguished none of them. `plan.md` §20.2 is the hour that cost,
// and the way it was eventually settled was decoding a PNG in Python and
// averaging the luminance of the lower third of the frame. Each of these views
// is that hour as one render.
//
// It is deliberately not scene state: `new three.Scene()` does not clear it,
// for the same reason it does not move the camera. A script rebuilding the
// world is not a reason to switch off a diagnostic somebody is reading, and
// rebuilding the world is exactly what the caller here does between looks.
const DEBUG_VIEWS = ['off', 'shadow', 'shadowMap'];

const debug = {
	// One of:
	//
	//   'off'        the scene, which is the default.
	//   'shadow'     how much light reaches each surface, as greyscale.
	//                White is lit and black is fully shadowed. A frame that
	//                is uniformly white is a pass that did not run or a fit
	//                nothing landed in; a frame that is uniformly dark is
	//                the answer that takes the longest to reach by looking.
	//   'shadowMap'  the depth the lookup reads at each surface, as
	//                greyscale near-to-far — the map itself, seen through
	//                the geometry that samples it. **Magenta is outside the
	//                fitted box**, which is the diagnostic: a frame that is
	//                mostly magenta is a `three.light.shadow.distance`
	//                fitted somewhere other than where you are looking.
	//                Dark purple is "no shadow pass ran this frame", which
	//                is the one answer 'shadow' cannot tell from "lit".
	//
	// The sky is not a surface and has no shadow, so a debug view colours
	// only what the geometry covers. That is a property of answering the
	// question in the shading pass, where the answer is, rather than a
	// limitation worth plumbing around.
	get view() { return DEBUG_VIEWS[H.debugViewGet()] ?? 'off'; },
	set view(v) {
		const name = v === null || v === undefined || v === false ? 'off' : String(v);
		const index = DEBUG_VIEWS.indexOf(name);
		// By name, here, rather than by a number the host would have to
		// range-check: a typo is the whole failure mode of a string enum,
		// and it should say so instead of quietly drawing the scene.
		if (index < 0) {
			throw new TypeError(`three.debug.view: unknown view '${name}' — one of ${DEBUG_VIEWS.join(', ')}`);
		}
		H.debugViewSet(index);
	},
};

// -----------------------------------------------------------------------
// The module

export const three = {
	Scene,
	Mesh,
	Group,
	Vector3,
	Asset,
	Texture,
	DataTexture,
	camera,
	light,
	controls,
	clock,
	debug,

	// How long this script may run before the interrupt stops it, in
	// milliseconds. 5,000 by default, and raisable to ten minutes.
	//
	// **Raise it to simulate, not to build.** Five seconds is generous for a
	// script that assembles a scene and short for one that steps it: the
	// check that proved the village's character controller walked 30,000
	// frames against 120 colliders, and the first attempt at it was killed
	// by the default — so it had to be cut into pieces that fit the budget
	// rather than pieces that meant something.
	//
	// The ceiling stays because a limit a script can lift entirely is not a
	// limit, and the whole reason the interrupt exists is that a wedged loop
	// must be a pause rather than a hang. Asking for more is clamped, not
	// refused: a caller asking for an hour means "as long as possible", and
	// throwing would leave them on the default instead.
	//
	// Raising it takes effect on the run that raises it — a script does not
	// know it needs longer until it is already running.
	get budget() { return H.budgetGet(); },
	set budget(ms) { H.budgetSet(+ms); },

	// The materials. `Material` is exported for `instanceof`, not to be
	// constructed: it is the base both concrete kinds share and holds `side`
	// and `map`, which is what makes `mesh.material` one check rather than a
	// list that has to be edited when a third kind arrives.
	//
	// Reach for MeshLambertMaterial to put an image or a side on a shape — it
	// compiles nothing. Reach for ShaderMaterial when you want to write the
	// shading itself.
	//
	// LayeredMaterial is a ShaderMaterial whose body is generated: an ordered
	// stack of materials blended over a base one, which is the renderer's half
	// of glTF's `CUSTOM_materials_layers`. It is what a terrain splat map or a
	// weathering pass wants, and `asset.mesh(name).layers` hands one straight
	// out of a file that was authored with the extension.
	Material,
	MeshLambertMaterial,
	ShaderMaterial,
	LayeredMaterial,

	// `material.side`. Numbers rather than an enum object because that is
	// what Three.js exports and what a script written from memory of it will
	// compare against — `side: 2` means DoubleSide in both.
	FrontSide,
	BackSide,
	DoubleSide,

	// `material.blending`, and Three.js's numbers for the same reason. The
	// usual way to reach for one of these is `{ transparent: true }`, which
	// means NormalBlending; name a mode when what you want is the other one.
	// Three.js's Subtractive and Multiply are 3 and 4 there and are not here,
	// and their numbers are left free so they can arrive without renumbering
	// anything a script hardcoded.
	NoBlending,
	NormalBlending,
	AdditiveBlending,

	// `three.texture(path, { colorSpace })`. Three.js's strings, so that
	// `tex.colorSpace === three.SRGBColorSpace` means what a script written
	// from memory of Three.js expects it to.
	//
	// **This is the difference between a colour map and a normal map.** sRGB
	// is the default and is right for anything an artist looked at while
	// making it; linear is for a map whose channels are numbers rather than
	// colours — normal, roughness, metalness, occlusion, height. NoColorSpace
	// is Three.js's other spelling of linear and is accepted as one.
	NoColorSpace,
	SRGBColorSpace,
	LinearSRGBColorSpace,

	// Exported for `instanceof` and for building one by hand, which a script
	// wants when it is describing a volume the scene does not hold yet — a
	// plot to fill, a gap to check. Neither is constructed by the host.
	Box3,
	MeshRef,

	// The shapes. `Geometry` is exported for `instanceof`, not to be
	// constructed: there is no BufferGeometry and no attribute access, which
	// is the thesis rather than an omission — see scene/primitive.c3.
	// ConvexGeometry takes a cloud of points and is the widest input here;
	// it is still a description of a shape rather than the shape's triangles,
	// and scene/convex.c3 argues why that is the same rule and not an
	// exception to it.
	Geometry,
	BoxGeometry,
	SphereGeometry,
	PlaneGeometry,
	CylinderGeometry,
	ConeGeometry,
	TorusGeometry,
	ConvexGeometry,
	// The one shape that carries data instead of parameters, and the one that
	// answers questions afterwards — heightAt and normalAt read the grid the
	// mesh was built from. See scene/terrain.c3.
	TerrainGeometry,
	// A ribbon that follows a curve — a road, a river, a path, a wall. It is
	// the mesh half of the curve pair (`three.catmullRom` is the path half):
	// give it a hand-written control path and it is smooth between the bends,
	// draped over a terrain when you hand it one, or a flat sheet at `y` when
	// you do not. One asset, one draw call, like every other shape.
	RibbonGeometry,
	// A scalar grid in world coordinates, and the authoring half of the shape
	// above: fill it with noise, flatten a building pad into it, carve a river
	// channel, hand it to a TerrainGeometry. The SAME object is a splat mask —
	// stroke the road's polyline into a second Field and Field.mask packs four
	// of them into the RGBA a LayeredMaterial reads. Carving the channel and
	// painting the mud from one polyline is the point.
	Field,
	// Where to put a hundred trees. Rejection sampling with keep-outs, a
	// slope test and a seed — the block every landscape scene writes by hand,
	// and it wants terrain.heightAt, which is why it lives beside Field.
	scatter,
	// A smooth curve through sparse control points, as a dense polyline — the
	// path half of the ribbon pair. Centripetal Catmull-Rom, so a road through
	// three close landmarks and two far ones passes through all of them instead
	// of swinging wide of the close ones. Feed the result to field.carve /
	// field.stroke / a scatter's avoid corridor, or to a RibbonGeometry.
	catmullRom,
	// A walkable character with a follow camera — the controller every
	// third-person scene writes by hand, and the place the two worst bugs in it
	// (camera/movement frame disagreement, and hand-rolled orbit-trig signs) are
	// already fixed. It rides a terrain height field (or a `height(x, z)`
	// function), moves with WASD relative to the camera, drag-looks, jumps, and
	// swings the mesh's limb pivots as it walks. See character.js.
	character,

	// The helpers. Ordinary meshes over line assets — they cost a draw call
	// each and nothing else, they are not pickable, and they draw over the
	// scene rather than inside it because a helper that could be hidden by
	// the wall a piece had sunk into would be no help at all.
	Box3Helper,
	BoxHelper,
	AxesHelper,
	GridHelper,
	WireframeHelper,

	// Synchronous, despite reading like Three.js's async loader: the file is
	// read and uploaded on this thread and there is nothing to yield to.
	// `await three.load(...)` still works — awaiting a plain value is a
	// no-op — so the Three.js-shaped line an agent writes is correct here.
	load(path) {
		if (typeof path !== 'string' || path.length === 0) {
			throw new TypeError('three.load(path) wants a path to a .glb or .gltf');
		}
		return new Asset(H.load(path));
	},

	// Decode a PNG or JPEG and upload it. Synchronous, for three.load's
	// reason, and under --assets the path is inside the game directory and
	// cannot climb out of it.
	//
	// The format is read from the file's first bytes rather than from its
	// extension, so a JPEG somebody named .png loads correctly instead of
	// being reported as corrupt.
	//
	// The second argument is `{ colorSpace, generateMipmaps }`, and the one
	// worth knowing about is colorSpace. It defaults to sRGB, which is right
	// for a picture of something and wrong for a map whose channels are
	// numbers:
	//
	//     const bricks = three.texture('brick.png');
	//     const bumps  = three.texture('brick_normal.png',
	//                                  { colorSpace: three.LinearSRGBColorSpace });
	texture(path, options = null) {
		if (typeof path !== 'string' || path.length === 0) {
			throw new TypeError('three.texture(path) wants a path to a .png or .jpg');
		}
		const chosen = uploadOptions(options, 'three.texture(path, options)');
		return new Texture(H.texture(path, chosen.code, chosen.mips), path, chosen.space);
	},

	// Draws one frame into the offscreen target. The PNG that `run_script`
	// returns is a render of the final state whether or not this was called,
	// so this is for the error rather than the pixels: a scene that cannot be
	// drawn says so here, at this line, instead of at the end of the script.
	render(scene, cam) {
		if (scene !== undefined) {
			if (!(scene instanceof Scene)) throw new TypeError('three.render(scene) wants the Scene');
			scene._check();
		}
		if (cam !== undefined && cam !== null && cam !== camera) {
			throw new TypeError('three.c3 has one camera — pass three.camera, or nothing');
		}
		H.render();
	},

	// The shaders that run over the finished frame.
	//
	// `three.setPost({ fragment, uniforms })` compiles a `float3 post(Post p)`
	// and makes it the chain every frame goes through — the window,
	// three.render() and every screenshot alike, because there is one
	// recording function behind all three and the branch is inside it.
	// `three.setPost(null)` clears it and puts the frame back on the path it
	// was on before.
	//
	// A verb rather than a class: the chain belongs to the renderer, so a
	// constructor would imply somewhere to put a second chain. What comes back
	// is a handle onto the live pass — `{ fragment, index, uniforms }` — with
	// the same live uniforms Proxy a ShaderMaterial has, so
	// `handle.uniforms.gain = 2` is a 4-byte write that takes effect on the
	// next frame with no compile.
	//
	// It compiles here, at this line, so a body that does not compile throws
	// where it was written and carries Slang's diagnostic with `post:<line>`
	// coordinates counting the agent's own lines. A failed set leaves the
	// previous chain running — it is the old shaders or the new one and never
	// neither.
	//
	// The chain is a property of the renderer and not of the scene, so it
	// survives new three.Scene() and outlives the script that set it. Nothing
	// clears it but three.setPost(null).
	setPost(spec) {
		if (spec === null || spec === undefined) {
			H.clearPost();
			// After the host call, so a handle is only invalidated by a call
			// that actually changed what is running.
			bumpPostEpoch();
			return null;
		}
		const parsed = postSpec(
			spec,
			'three.setPost({ fragment, uniforms }) wants an options object, or null to clear the pass'
		);
		// The first pass of a chain has nothing before it to read, and `setPost`
		// is always the first pass of a chain. Refused rather than ignored: a
		// script that wrote `reads` here meant something, and it is not this.
		if (parsed.args[5] !== -1) {
			throw new TypeError(
				'three.setPost() replaces the whole chain, so this pass is the first one and there is '
				+ 'nothing before it to read — `reads` belongs on a three.addPass()'
			);
		}
		H.setPost(...parsed.args);
		// After the host call, for the same reason the null branch bumps after
		// it: a set that threw changed nothing, and handles from before it are
		// still pointing at what is still running.
		bumpPostEpoch();
		return postFinish(parsed, 0);
	},

	// `three.addPass(spec)` — put another full-screen pass at the end of the
	// chain.
	//
	// The same spec `setPost` takes, and the same handle back. What differs is
	// where it lands and what it reads:
	//
	//     p.color   what the pass before this one wrote — the scene, for the
	//               first pass in the chain
	//     p.scene   the frame as the geometry left it, whatever has run since
	//     p.tap     the pass named by `reads`, or the scene if none was
	//               (its sampler is in scope as `tap_image`)
	//     p.depth   how far this pixel is from the camera, in world units
	//
	// The first two are the chain's dependency model and cover most of what a
	// multi-pass effect wants — bloom is `blur(bright(scene)) + scene`, which
	// is `scene` three passes later.
	//
	// `reads` is the third source, for the case they do not cover: a pass in
	// the *middle* of the chain that two later passes both want, a mask one
	// pass built for another to apply. Hand it the handle addPass gave you:
	//
	//     const bright = three.addPass({ fragment: threshold });
	//     three.addPass({ fragment: blurX });
	//     three.addPass({ fragment: blurY });
	//     three.addPass({ fragment: combine, reads: bright });
	//
	// Naming a pass costs that pass an image of its own — the chain normally
	// ping-pongs two between every pass, and a tapped one cannot be
	// overwritten — so it is one allocation per distinct pass tapped and
	// nothing at all for a chain that taps none.
	//
	// Adding to an empty chain is exactly a setPost, which is what makes
	// addPass usable without one in front of it. **It does not invalidate
	// handles**: earlier passes keep their index and their shader, so a script
	// can hold every handle it made and keep writing uniforms through all of
	// them.
	//
	// There is no removePass. Reordering or dropping one pass out of the
	// middle would renumber the handles after it, and `three.setPost(spec)`
	// followed by the addPass calls you want is the same effect said in a way
	// that cannot leave a handle pointing at somebody else's shader.
	addPass(spec) {
		// No "or null" clause, because there is no such call: addPass appends,
		// and the verb that empties the chain is three.setPost(null).
		const parsed = postSpec(spec, 'three.addPass({ fragment, uniforms }) wants an options object');
		const index = H.addPass(...parsed.args);
		return postFinish(parsed, index);
	},

	stats() { return H.stats(); },

	// Free every asset no live mesh names, and every texture that goes with
	// it. scene.unload() is this plus emptying the scene, and is what a level
	// transition wants; this on its own is for the asset loaded and then
	// changed its mind about.
	//
	// Answers with { assets, textures, bytes } — how many asset slots went,
	// how many unique images went, and how many bytes of image that was.
	// Costs a full device idle when there is anything to free and nothing at
	// all when there is not, so once per level is right and once per frame is
	// merely wasteful.
	unloadUnused() { return H.unloadUnused(); },

	// Three.js's own name for this, on the renderer, and the only name for
	// it that is: `requestAnimationFrame` is the browser's, and Three.js has
	// no frame loop in core either.
	//
	// The callback runs on the host's loop, between the input and the draw,
	// and is given milliseconds — the same argument
	// `WebGLRenderer.setAnimationLoop` passes. It must be synchronous: it
	// has one frame to finish in, and there is no later.
	//
	// **The milliseconds are the game clock's**, which is `three.clock.time`
	// times a thousand and not the host's wall clock. On an ordinary frame
	// of an unpaused game there is no difference; the difference is that
	// `three.clock.timeScale = 0` stops it, and a pause that did not reach
	// this argument would be a still world with the propellers still
	// turning — most of what moves in most of these scenes is a function of
	// this number.
	setAnimationLoop(fn) {
		if (fn === null || fn === undefined) { H.setFrame(null); return; }
		if (typeof fn !== 'function') {
			throw new TypeError('three.setAnimationLoop(fn) wants a function, or null to stop');
		}
		// Caught here rather than at the first tick, because an async
		// callback fails in a way that reads as the loop not running at all:
		// it returns a promise immediately, does its work later, and the
		// frame it was meant to be part of is long gone.
		if (fn.constructor && fn.constructor.name === 'AsyncFunction') {
			throw new TypeError(
				'the animation callback must be synchronous — an async one returns before it '
				+ 'has done anything, and the frame does not wait. Do the awaiting in a run_script.'
			);
		}
		H.setFrame(fn);
	},

	// The other loop: gameplay, at a fixed rate, however fast the frames
	// happen to be arriving.
	//
	// The callback is called zero or more times per frame — as many as the
	// clock owes at `three.clock.fixedRate`, up to eight — and is handed the
	// step in seconds, which is the *same number every call*. That constant
	// is the whole point: an integration written against it produces the
	// same trajectory on a slow machine as on a fast one, which a variable
	// `dt` cannot promise however carefully it is clamped.
	//
	// **The accumulator is the host's**, not something to write in the
	// animation callback. One in a script runs inside the script budget, so
	// a frame that owes eight steps spends eight steps of it, and a spiral
	// of death stops the callback for good rather than merely stuttering —
	// the same reason the solver's accumulator is the host's.
	//
	// It runs before the animation callback and after the frame's physics,
	// so what it writes this frame is drawn this frame and read by the
	// solver on the next one. Stopped the same three ways the animation
	// callback is, and with `three.setFixedLoop(null)`.
	setFixedLoop(fn) {
		if (fn === null || fn === undefined) { H.setFixed(null); return; }
		if (typeof fn !== 'function') {
			throw new TypeError('three.setFixedLoop(fn) wants a function, or null to stop');
		}
		if (fn.constructor && fn.constructor.name === 'AsyncFunction') {
			throw new TypeError(
				'the fixed loop must be synchronous — an async one returns before it has done '
				+ 'anything, and the step does not wait. Do the awaiting in a run_script.'
			);
		}
		H.setFixed(fn);
	},

	// Every .glb and .gltf in the assets directory, described without being
	// loaded — mesh names and triangle counts, animation names, skin count
	// and bounds, read out of the JSON chunk with no buffer touched.
	//
	// Empty outside a `--assets` boot, where there is no directory to
	// describe. That is an answer rather than an error on purpose: a script
	// written for a game still runs under a plain `--mcp`, and finds
	// nothing, which is the truth.
	inventory() {
		return H.inventory();
	},

	// What `scene.pick(x, y)` counts in, and what the PNG comes back as.
	// It is the offscreen target's, never a window's (`plan.md` §1).
	renderSize() {
		const [width, height] = H.renderSize();
		return { width, height };
	},

	input,

	// Bind an action to a key. The handler is called once when the key goes
	// down (or up), from inside the frame, and is given the name it was
	// bound under — so one function can serve 'w', 'a', 's' and 'd'.
	//
	// One handler per key per edge: binding again replaces. null unbinds.
	// A held key does not repeat; polling three.input.isDown in the
	// animation callback is what continuous movement wants.
	onKeyDown(key, fn) { bindKey(key, true, fn); },
	onKeyUp(key, fn) { bindKey(key, false, fn); },

	// Click to pick. The handler is called once, from inside the frame,
	// with what is under the cursor — the same intersection scene.pick(x, y)
	// answers with, or null for a miss — and the pixel it happened at.
	//
	// A click is a press and a release that stayed in the same place: a drag
	// orbits the camera and is not one, which is why there is no
	// onMouseDown beside this.
	//
	// One handler, and binding again replaces it. null unbinds.
	onClick(fn) {
		if (fn === null || fn === undefined) { H.onClick(null); return; }
		if (typeof fn !== 'function') {
			throw new TypeError('three.onClick(fn) wants a function, or null to unbind');
		}
		if (fn.constructor && fn.constructor.name === 'AsyncFunction') {
			throw new TypeError(
				'a click handler must be synchronous — an async one returns before it has done '
				+ 'anything, and the frame does not wait. Do the awaiting in a run_script.'
			);
		}
		H.onClick((raw, x, y) => fn(asIntersection(raw), x, y));
	},

	// The physics world — one of them, stepped by the host at a fixed 60 Hz
	// whatever rate the frame runs at. See DOCS.classes.Physics.
	physics: {
		// Give an object a body. The description is `object.body` if it has
		// one, and `options` wins over it, so a scene can be described once
		// and tweaked at the call.
		//
		// `shape` is one of 'box', 'sphere', 'capsule', 'hull' or
		// 'heightfield', and every one of them comes from the mesh rather
		// than from numbers you supply. 'heightfield' is the odd one and
		// is the reason it is worth naming here: it is only for a
		// TerrainGeometry, and it is the terrain's own grid of heights
		// handed to the solver as one shape — so a body rests on the same
		// surface `terrain.heightAt(x, z)` reports, at any slope, with one
		// collider instead of a chain of invisible boxes under a path that
		// had to be flat to have them.
		add(object, options) {
			const target = liveObject(object, 'three.physics.add');
			const desc = Object.assign({}, object.body || {}, options || {});

			const shape = desc.shape === undefined ? 'box' : String(desc.shape);
			const mass = desc.mass === undefined ? 1 : Number(desc.mass);
			const friction = desc.friction === undefined ? 0.5 : Number(desc.friction);
			const restitution = desc.restitution === undefined ? 0.2 : Number(desc.restitution);

			for (const [name, value] of [['mass', mass], ['friction', friction], ['restitution', restitution]]) {
				if (!Number.isFinite(value)) {
					throw new TypeError(`body.${name} must be a finite number, not ${value}`);
				}
			}
			if (mass < 0) throw new RangeError(`body.mass cannot be negative — ${mass} is not a weight`);

			// One word out of four, decided here rather than by the host so
			// that `mass: 0` means the same thing it means in every other
			// engine: something that does not move.
			const kind = desc.trigger ? 'trigger'
				: desc.kinematic ? 'kinematic'
				: (desc.static || mass === 0) ? 'static'
				: 'dynamic';

			H.physicsAdd(target[0], target[1], kind, shape, mass, friction, restitution);
			object.body = { shape, mass, friction, restitution, kind };
			object._solverOwned = kind === 'dynamic';
			return object;
		},

		// Take the body away. False when it had none, so removing twice is
		// not an error.
		remove(object) {
			const target = liveObject(object, 'three.physics.remove');
			if (object.body) object.body = null;
			object._solverOwned = false;
			return H.physicsRemove(target[0], target[1]);
		},

		// [x, y, z], y-up. An array rather than a live Vector3 because it
		// is a world setting and not a transform: writing to a component of
		// something read back would look like it did something.
		get gravity() { return H.physicsGravityGet(); },
		set gravity(value) {
			const [x, y, z] = asTriple(value, 'three.physics.gravity');
			H.physicsGravitySet(x, y, z);
		},

		// How many bodies the world holds.
		get count() { return H.physicsCount(); },

		// ---------------------------------------------------------------
		// Steering a body
		//
		// Functions taking the object rather than properties on it, because
		// a velocity belongs to the body and an object may not have one —
		// `mesh.velocity` would be a property that exists on everything and
		// means something on almost nothing.
		//
		// **setVelocity assigns and applyImpulse adds**, which is the whole
		// distinction at a call site. A character sets its velocity every
		// frame from the keys that are down, because what it wants is a
		// speed. A jump, an explosion or a bat applies an impulse, because
		// what it wants is a change to whatever the speed already was.
		// Using an impulse where a velocity was meant gives something that
		// accelerates forever.

		// [lx, ly, lz, ax, ay, az] — linear in units per second, angular in
		// radians per second — or null when the object has no body.
		//
		// Null rather than a throw because this gets asked in a loop over
		// things that may or may not have bodies, and answering with both
		// velocities at once because a script that wants one usually wants
		// the other in the same breath.
		velocity(object) {
			const target = liveObject(object, 'three.physics.velocity');
			return H.physicsVelocityGet(target[0], target[1]);
		},

		// World units per second. Only a dynamic body can be given one: a
		// static body's inverse mass is zero and a kinematic body is driven
		// by the transform a script writes, so both throw and say which.
		setVelocity(object, value) {
			const target = liveObject(object, 'three.physics.setVelocity');
			const [x, y, z] = asTriple(value, 'three.physics.setVelocity');
			H.physicsLinearSet(target[0], target[1], x, y, z);
			return object;
		},

		// Radians per second about each world axis; the vector's length is
		// the rate.
		setAngularVelocity(object, value) {
			const target = liveObject(object, 'three.physics.setAngularVelocity');
			const [x, y, z] = asTriple(value, 'three.physics.setAngularVelocity');
			H.physicsAngularSet(target[0], target[1], x, y, z);
			return object;
		},

		// A push, in mass times velocity, so the same impulse moves a heavy
		// thing less. `at` is an offset from the body's centre in world
		// axes, not a world position: give one and the push also tumbles
		// the body, leave it out and it is a pure shove.
		applyImpulse(object, impulse, at) {
			const target = liveObject(object, 'three.physics.applyImpulse');
			const [x, y, z] = asTriple(impulse, 'three.physics.applyImpulse');
			const [px, py, pz] = at === undefined
				? [0, 0, 0]
				: asTriple(at, 'three.physics.applyImpulse(object, impulse, at)');
			H.physicsImpulse(target[0], target[1], x, y, z, px, py, pz);
			return object;
		},

		// A spin with no shove. Separate from an off-centre applyImpulse
		// because "make this rotate" should not require solving for an
		// offset and a force that happen to produce the spin you wanted.
		applyTorqueImpulse(object, impulse) {
			const target = liveObject(object, 'three.physics.applyTorqueImpulse');
			const [x, y, z] = asTriple(impulse, 'three.physics.applyTorqueImpulse');
			H.physicsTorqueImpulse(target[0], target[1], x, y, z);
			return object;
		},
	},

	// A trigger overlap started or ended:
	// { type: 'enter' | 'exit', trigger, other }.
	// One handler; binding again replaces, null unbinds, and it is stopped
	// for good if it throws — the same rules onClick follows.
	onTrigger(fn) {
		bindPhysicsHandler(fn, 'three.onTrigger', H.onTrigger, event => ({
			type: event.type,
			trigger: objectForHandle(event.trigger),
			other: objectForHandle(event.other),
		}));
	},

	// Two bodies touched or came apart:
	// { type: 'start' | 'end', a, b, normal, point }.
	// `normal` and `point` mean something on a start and are zero on an end
	// — there is no contact left to describe by then.
	onContact(fn) {
		bindPhysicsHandler(fn, 'three.onContact', H.onContact, event => ({
			type: event.type,
			a: objectForHandle(event.a),
			b: objectForHandle(event.b),
			normal: new Vector3(null, event.normal[0], event.normal[1], event.normal[2]),
			point: new Vector3(null, event.point[0], event.point[1], event.point[2]),
		}));
	},

	// The documentation, designed to be READ rather than dumped. With no
	// argument this is the index — everything short in full, and the names of
	// the classes and functions; `{ search }` is the grep over the whole
	// surface, `{ section }` the drill-down, `{ all: true }` the old answer.
	// The shapes live in `docs.js` beside the strings they walk, and the MCP
	// tool calls this rather than reimplementing it, so an agent asking over
	// JSON-RPC and a script asking here read the same docs the same way.
	getApiDocs(options) { return docsQuery(options); },
	searchDocs(term) { return docsSearch(term); },
};

// Shared by onTrigger and onContact, including the async refusal a key
// handler and a click handler already make: a handler that returns before
// it has done anything is not a handler, and the frame does not wait.
function bindPhysicsHandler(fn, where, bind, shape) {
	if (fn === null || fn === undefined) { bind(null); return; }
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
	bind(event => fn(shape(event)));
}

// Shared by both, including the async refusal: a key handler runs inside a
// frame for the same reason the animation callback does, and an async one
// would return before it had done anything.
function bindKey(key, down, fn) {
	if (fn === null || fn === undefined) { H.onKey(String(key), down, null); return; }
	if (typeof fn !== 'function') {
		throw new TypeError('three.onKeyDown(key, fn) wants a function, or null to unbind');
	}
	if (fn.constructor && fn.constructor.name === 'AsyncFunction') {
		throw new TypeError(
			'a key handler must be synchronous — an async one returns before it has done '
			+ 'anything, and the frame does not wait. Do the awaiting in a run_script.'
		);
	}
	H.onKey(String(key), down, fn);
}
