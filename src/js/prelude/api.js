// three.c3 — the `three` object itself: the light, the camera, the input, and
// every verb an agent calls.

import { Vector3, Box3, readVector, asTriple } from './math.js';
import { Group } from './object3d.js';
import { Texture, DataTexture } from './texture.js';
import { FrontSide, BackSide, DoubleSide, NoBlending, NormalBlending, AdditiveBlending, Material, MeshLambertMaterial } from './material.js';
import { ShaderMaterial } from './shader.js';
import { postSpec, postFinish, bumpPostEpoch } from './post.js';
import { Mesh } from './mesh.js';
import { liveScene, Scene, liveObject, objectForHandle } from './scene.js';
import { MeshRef, Asset } from './asset.js';
import { Geometry, BoxGeometry, SphereGeometry, PlaneGeometry, CylinderGeometry, ConeGeometry, TorusGeometry, ConvexGeometry } from './geometry.js';
import { Box3Helper, BoxHelper, AxesHelper, GridHelper, WireframeHelper } from './helpers.js';
import { DOCS } from './docs.js';

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
	frameAll() { H.frameAll(); return this; },

	toJSON() {
		const [x, y, z, yaw, pitch, distance, fov, near, far] = H.cameraGet();
		return { target: { x, y, z }, yaw, pitch, distance, fov, near, far };
	},
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

	// Where the cursor is: { x, y, inside, down, clicked }, in the rendered
	// image's pixels — the same coordinates scene.pick(x, y) takes and the
	// same corner the PNG starts at, whatever size the window has been
	// dragged to. Everything is zero and `inside` is false when there is no
	// window.
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
	Material,
	MeshLambertMaterial,
	ShaderMaterial,

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
	texture(path) {
		if (typeof path !== 'string' || path.length === 0) {
			throw new TypeError('three.texture(path) wants a path to a .png or .jpg');
		}
		return new Texture(H.texture(path), path);
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
	//
	// Those two are the chain's whole dependency model. A pass reads its
	// predecessor and it reads the original picture, and everything a
	// multi-pass effect actually wants is one of those two — bloom is
	// `blur(bright(scene)) + scene`, which is `scene` three passes later.
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
	// and is given the milliseconds since the host started counting — the
	// same argument `WebGLRenderer.setAnimationLoop` passes. It must be
	// synchronous: it has one frame to finish in, and there is no later.
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

	getApiDocs() { return DOCS; },
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
