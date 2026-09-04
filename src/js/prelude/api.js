// three.c3 — the `three` object itself: the light, the camera, the input, and
// every verb an agent calls.

import {
	Vector3, Box3, readVector, readColor, asTriple, damp, dampAngle, smoothDamp, CatmullRomCurve3,
	clamp, clamp01, lerp, inverseLerp, mapLinear, smoothstep, smootherstep, band,
	pingpong, euclideanModulo, degToRad, radToDeg, moveTowards,
	wrapAngle, angleDelta, moveTowardsAngle,
	mixColor, tintColor,
	Random, seed, randFloat, randInt, randFloatSpread,
	hash, noise2, fbm2,
} from './math.js';
import { Group } from './object3d.js';
import {
	Texture,
	DataTexture,
	uploadOptions,
	NoColorSpace,
	SRGBColorSpace,
	LinearSRGBColorSpace,
	LinearFilter,
	NearestFilter,
} from './texture.js';
import { FrontSide, BackSide, DoubleSide, NoBlending, NormalBlending, AdditiveBlending, Material, MeshLambertMaterial } from './material.js';
import { ShaderMaterial } from './shader.js';
import { LayeredMaterial } from './layers.js';
import { postSpec, postFinish, bumpPostEpoch } from './post.js';
import { Mesh } from './mesh.js';
import { liveScene, Scene, liveObject, objectForHandle, sceneForId, sceneOverview, disposeInactiveScenes } from './scene.js';
import { MeshRef, Asset } from './asset.js';
import { level, Level } from './level.js';
import { Geometry, BoxGeometry, SphereGeometry, PlaneGeometry, CylinderGeometry, ConeGeometry, TorusGeometry, ConvexGeometry, Path, Shape, ExtrudeGeometry, TerrainGeometry, RibbonGeometry, MergedGeometry, merge } from './geometry.js';
import { Field, scatter, catmullRom } from './field.js';
import { Box3Helper, BoxHelper, AxesHelper, GridHelper, WireframeHelper } from './helpers.js';
import { query, moveAndSlide, moveAndSlideAll, moveResult, moveBuffer, batch, TransformBatch, QueryResult } from './query.js';
import { steer, NavField, makeSceneNav } from './nav.js';
import { makeScenePhysics } from './physics.js';
import { systems, systemLoad, ANIMATION_SYSTEM, FIXED_SYSTEM } from './systems.js';
import { cooldown, Cooldown } from './cooldown.js';
import { track, Entity, instanceOf, emit, setScriptHandler, setClickShaper, report as rulesReport, disposeAll as disposeAllEntities } from './entity.js';
import { ui } from './ui.js';
import { Widget, nodes as uiNodes, unmountAll as unmountAllWidgets } from './widget.js';
import { docsQuery, docsSearch } from './docs.js';

const H = globalThis.__three;

// The node classes onto the namespace that already owns the verbs, so
// `three.ui.set` and `three.ui.Panel` are one place rather than two. Capitalised
// beside lowercase verbs, which is the JavaScript convention for exactly this
// distinction and leaves both lists free to grow.
Object.assign(ui, uiNodes);

// `three.physics` and `three.nav`, which are whichever Scene is being rendered's.
//
// A stand-in Scene whose id is read fresh on every call, rather than the live
// `Scene` object: those two namespaces have to work before the first
// `new three.Scene()` — the host always has a scene, a `--headless` run with no
// script included — and a getter that needed a JavaScript object would refuse
// there. When there is a Scene object, `scene.physics` and this reach the same
// world, because both are named by the same id.
const renderedScene = { get _sid() { return H.sceneActive(); } };
const renderedPhysics = makeScenePhysics(renderedScene);
const renderedNav = makeSceneNav(renderedScene);

// -----------------------------------------------------------------------
// The camera
//
// A turntable, not a free Object3D, and named so. Three.js's
// `camera.position.set(...)` has no meaning here, so the properties that
// would half-match it do not exist — `orbit()` and `frameAll()` are names
// Three.js does not have, which is `plan.md` §4's rule for a divergence.

// -------------------------------------------------------------------
// The lights
//
// Up to four lights and one ambient floor, which is the whole model the
// shaders implement. A light is a direction or a place: `{ direction }` is a
// sun and `{ position, range }` is a lamp, a campfire, a torch — one field on
// the wire, so `range` at 0 is what "directional" means and slot zero, the one
// the shadow map is fitted around, is a direction and refuses to be anything
// else. Not `scene.add(new three.DirectionalLight(...))`:
// that name would promise a light with a position, a light you can parent
// something to, and a light `scene.remove` reaches. A light here is none of
// those — it is a direction, a colour and a slot. `plan.md` §4's half-match
// rule: a name Three.js does not have is a name nobody expects Three.js's
// behaviour from, and `three.lights` is a list of four rather than a graph.
//
// **`three.light` is `three.lights[0]`, the same object.** It is the sun: the
// one the shadow map is fitted around and the only one that casts, which is
// why the shadow settings hang off it and not off the list. Every script
// written before there was a list still means what it meant.
//
// `direction` hands back a live Vector3, so `three.light.direction.y = -1`
// writes through the same way `mesh.position.y = 1` does. A detached copy
// would be the trap the camera avoided by making yaw and pitch throw on
// assignment — a property that reads back what you wrote and changes nothing.

// How many slots the frame block has — `MAX_LIGHTS` in `src/gpu/pipeline.c3`,
// which is where the argument for the number is. Spelled here as well because
// a script that wants to know cannot ask the host for it, and
// `three.lights.max` matching what `add` refuses past is a test rather than a
// comment.
const MAX_LIGHTS = 4;

// One light, by slot.
//
// A fresh object each read, like `three.light.shadow` and for the same
// reason: a slot is a position in a list that `remove` can shift, so an
// object that remembered which light it was would start describing its
// neighbour. What it remembers is the index, which is exactly what
// `three.lights[i]` means.
function lightAt(index) {
	return {
		// Which slot this is. `three.lights.remove(light)` is the reader —
		// a light has no handle, so the index is how one names itself.
		get index() { return index; },

		get direction() {
			const l = H.lightGet(index);
			const v = new Vector3(null, l[0], l[1], l[2]);
			v._o = {
				_flush() {
					const c = H.lightGet(index);
					H.lightSet(index, v._x, v._y, v._z, c[3], c[4], c[5], c[6], c[7]);
				},
			};
			return v;
		},
		// Writing a direction makes this a directional light, whatever it was —
		// the range goes to 0, which is what a direction means. The two are one
		// field on the wire and one of them has to win; the one being written is
		// the one the script is looking at.
		set direction(v) {
			const [x, y, z] = readVector(v, 'light.direction');
			const c = H.lightGet(index);
			H.lightSet(index, x, y, z, c[3], c[4], c[5], c[6], 0);
		},

		// Where a point light stands, as a live Vector3 — the same three
		// numbers `direction` reads, meaning a place instead of a heading.
		//
		// **`range` is what says which.** A light with `range` at 0 is
		// directional and this answers with where its direction points, which
		// is nowhere in particular; setting it turns the light into a point
		// light at that place, and gives it a range if it had none, because a
		// point light with no reach is a light that lights nothing.
		get position() {
			const l = H.lightGet(index);
			const v = new Vector3(null, l[0], l[1], l[2]);
			v._o = {
				_flush() {
					const c = H.lightGet(index);
					H.lightSet(index, v._x, v._y, v._z, c[3], c[4], c[5], c[6], c[7] > 0 ? c[7] : 10);
				},
			};
			return v;
		},
		set position(v) {
			const [x, y, z] = readVector(v, 'light.position');
			const c = H.lightGet(index);
			H.lightSet(index, x, y, z, c[3], c[4], c[5], c[6], c[7] > 0 ? c[7] : 10);
		},

		// How far a point light reaches, in metres, and **0 is what makes it
		// directional** — the two kinds are one field, so this is the switch
		// rather than a property beside one.
		//
		// The falloff inside it is inverse-square with a window that brings it
		// to exactly zero at the range, so `intensity` on a point light is its
		// brightness one metre away: a lamp meant to read like a sun of 1 at
		// three metres wants about 9.
		get range() { return H.lightGet(index)[7]; },
		set range(v) {
			const l = H.lightGet(index);
			H.lightSet(index, l[0], l[1], l[2], l[3], l[4], l[5], l[6], Math.max(0, +v));
		},

		// The light's own colour, as `[r, g, b]` from 0 to 1. White is what
		// every slot starts at, so a scene that never mentions colour is lit
		// exactly as it was before lights had one.
		//
		// Takes whatever `readColor` takes — a hex, a triple, an `{r, g, b}`
		// — and answers with the triple, for `scene.background`'s reason:
		// the components are what the arithmetic uses, and a hex cannot
		// represent what the arithmetic can hold.
		get color() {
			const l = H.lightGet(index);
			return [l[3], l[4], l[5]];
		},
		set color(v) {
			const c = readColor(v, 'light.color');
			const l = H.lightGet(index);
			H.lightSet(index, l[0], l[1], l[2], c[0], c[1], c[2], l[6], l[7]);
		},

		// How strongly this light shines, 1 by default. It multiplies the
		// colour, so it is the knob for "brighter than white" — a colour is
		// clamped to 0..1 and this is not.
		//
		// 0 is how a light is turned off. `three.lights.remove()` is the
		// other way and is not available for light zero, which is the sun.
		get intensity() { return H.lightGet(index)[6]; },
		set intensity(v) {
			const l = H.lightGet(index);
			H.lightSet(index, l[0], l[1], l[2], l[3], l[4], l[5], +v, l[7]);
		},
	};
}

const light = lightAt(0);

Object.defineProperties(light, {
	// 0 leaves a face turned away from every light black; 1 removes the
	// shading entirely and everything is its own flat colour.
	//
	// **On `three.light` rather than on each light**, because it is not a
	// light: it stands in for every bounce this renderer does not simulate,
	// and four of them summed would be four times the same fudge.
	ambient: {
		enumerable: true,
		get() { return H.ambientGet(); },
		set(v) { H.ambientSet(+v); },
	},

	// The sun and the floor at once, because setting them one at a time is
	// two host crossings and reads worse at a call site that always means
	// one change.
	//
	// **The second argument is the ambient floor and not a colour**, which
	// it was before there were colours and still is. `three.light.color` is
	// how the sun is coloured; changing what this meant would have been a
	// silent reinterpretation of every script that had already called it.
	set: {
		enumerable: true,
		value(direction, ambient = H.ambientGet()) {
			const [x, y, z] = readVector(direction, 'three.light.set(direction, ambient)');
			const l = H.lightGet(0);
			H.lightSet(0, x, y, z, l[3], l[4], l[5], l[6], 0);
			H.ambientSet(+ambient);
			return light;
		},
	},
});

Object.defineProperties(light, {

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
	// A fresh object each read, like `direction` above, so the
	// properties always answer with what the host holds rather than with
	// what a captured copy remembered.
	shadow: {
		enumerable: true,
		get() {
		return {
			// Off by default. Turning it on allocates a depth image and
			// compiles a shader the first frame after, and never before
			// — a project that does not ask pays for none of it.
			get enabled() { return H.shadowGet()[0] !== 0; },
			set enabled(v) {
				const [, size, bias, intensity, distance, follow] = H.shadowGet();
				H.shadowSet(v ? 1 : 0, size, bias, intensity, distance, follow);
			},

			// Texels per side. Clamped to 256..8192 and rounded down to a
			// power of two, so it reads back as what will actually be
			// allocated rather than as what was typed.
			get size() { return H.shadowGet()[1]; },
			set size(v) {
				const [enabled, , bias, intensity, distance, follow] = H.shadowGet();
				H.shadowSet(enabled, +v, bias, intensity, distance, follow);
			},

			// Extra depth offset in the light's clip space, 0 by default.
			// The renderer already offsets each sample along the surface
			// normal by two texels, which is what actually removes the
			// self-shadowing stripes, so this is the knob for the scene
			// that still shows them rather than the one everybody has to
			// tune.
			get bias() { return H.shadowGet()[2]; },
			set bias(v) {
				const [enabled, size, , intensity, distance, follow] = H.shadowGet();
				H.shadowSet(enabled, size, +v, intensity, distance, follow);
			},

			// How dark a shadow is, 0 to 1. 1 takes the whole directional
			// term away and leaves `three.light.ambient`, which is why a
			// shadow is never black unless the ambient floor is zero.
			get intensity() { return H.shadowGet()[3]; },
			set intensity(v) {
				const [enabled, size, bias, , distance, follow] = H.shadowGet();
				H.shadowSet(enabled, size, bias, +v, distance, follow);
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
				const [enabled, size, bias, intensity, , follow] = H.shadowGet();
				H.shadowSet(enabled, size, bias, intensity, +v, follow);
			},

			// Whether the map is fitted around what the camera can see,
			// or around the whole scene. True by default, and true is
			// what makes shadows sharp: the map covers `distance` units
			// of the world rather than all of it.
			//
			// The cost of following is a *rebuild*. A cached shadow map
			// is a picture in one projection, so whenever the fit moves
			// far enough to matter every static caster is drawn again —
			// on a forest that is 39 draw calls over 4,800 instances and
			// 0.27 ms against a 0.10 ms steady pass, which reads as a
			// stutter while a turntable is being dragged. Set this false
			// and nothing about the camera is in the key at all: the map
			// is rebuilt when the light turns, when the level's bounds
			// change, and when something marked `static` moves.
			//
			// What that costs is texels, and the arithmetic is yours to
			// do: a 224-unit village at `size: 2048` is 11 cm a texel
			// fitted whole and 2 cm fitted to a 40-unit view. Big level
			// and a moving camera, or a small one and shadows that never
			// stutter — there is no default that knows which.
			get follow() { return H.shadowGet()[5] !== 0; },
			set follow(v) {
				const [enabled, size, bias, intensity, distance] = H.shadowGet();
				H.shadowSet(enabled, size, bias, intensity, distance, v ? 1 : 0);
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

		// `three.light.shadow = true` and `= { size: 4096 }` both work,
		// because the first is what somebody writes without reading
		// anything and the second is what they write after. An object sets
		// only the keys it names; a boolean is `{ enabled: it }`.
		set(v) {
			const [enabled, size, bias, intensity, distance, follow] = H.shadowGet();
			if (typeof v === 'boolean' || v == null) {
				H.shadowSet(v ? 1 : 0, size, bias, intensity, distance, follow);
				return;
			}
			if (typeof v !== 'object') {
				throw new TypeError('three.light.shadow takes true, false, or an object with enabled, size, bias, intensity, distance or follow');
			}
			H.shadowSet(
				('enabled' in v ? (v.enabled ? 1 : 0) : enabled),
				('size' in v ? +v.size : size),
				('bias' in v ? +v.bias : bias),
				('intensity' in v ? +v.intensity : intensity),
				('distance' in v ? +v.distance : distance),
				('follow' in v ? (v.follow ? 1 : 0) : follow),
			);
		},
	},
});

// The list. Four slots, the sun in the first, and `length` of them lit.
//
// Array-shaped rather than a set of methods, because the thing a script wants
// to do with more than one light is loop over them — and because
// `three.lights[0] === three.light` is the sentence that says the two views
// are of the same four slots.
const lights = {
	get length() { return H.lightCount(); },

	// How many there can be, and the number `add` refuses past. Four, and
	// `plan.md` §19 has why: the fifth light is the trigger for a compute
	// pass that bins them, and a list this short does not need one.
	get max() { return MAX_LIGHTS; },

	// A light in the next free slot, answering with it.
	//
	// `add(direction, color, intensity)` and `add({ direction, color,
	// intensity })` both work, for `three.light.shadow`'s reason: the first
	// is what somebody writes without reading anything and the second is
	// what they write after.
	add(direction, color = 0xffffff, intensity = 1) {
		let d = direction, c = color, i = intensity, range = 0, where = 'direction';
		if (direction !== null && typeof direction === 'object' && !Array.isArray(direction)
			&& !('x' in direction) && !('0' in direction)) {
			// `position` is what makes it a point light, and `range` is what the
			// shader reads — so a description that names a position and no range
			// gets ten metres rather than a light that reaches nowhere. Naming
			// both is a contradiction: one of the three numbers is a place and
			// the other is a heading, and there is one field for them.
			if ('position' in direction && 'direction' in direction) {
				throw new TypeError(
					'three.lights.add takes a direction or a position, not both — a light is one or the other'
				);
			}
			if ('position' in direction) {
				d = direction.position;
				where = 'position';
				range = 'range' in direction ? Math.max(0, +direction.range) : 10;
			} else {
				d = direction.direction;
				range = 0;
			}
			c = 'color' in direction ? direction.color : 0xffffff;
			i = 'intensity' in direction ? direction.intensity : 1;
		}
		if (d === undefined) {
			throw new TypeError('three.lights.add wants a direction — add([x, y, z]) or add({ direction, color, intensity }) or add({ position, range, color, intensity })');
		}
		const [x, y, z] = readVector(d, `three.lights.add(${where})`);
		const rgb = readColor(c, 'three.lights.add(direction, color)');
		return lightAt(H.lightAdd(x, y, z, rgb[0], rgb[1], rgb[2], +i, range));
	},

	// Take one out. The slots above it move down, exactly as
	// `Array.prototype.splice` does — so an index held across this names a
	// different light afterwards, which is the rule an array index has
	// always had.
	//
	// **Light zero cannot be removed**: it is the one the shadow map is
	// fitted around, so taking it out would silently move every shadow in
	// the scene onto whichever light was next. `three.light.intensity = 0`
	// is how the sun is turned off.
	remove(which) {
		const i = typeof which === 'number'
			? which
			: (which && typeof which.index === 'number' ? which.index : -1);
		if (i < 0) {
			throw new TypeError('three.lights.remove wants an index, or a light from three.lights');
		}
		H.lightRemove(i);
	},

	*[Symbol.iterator]() {
		for (let i = 0; i < H.lightCount(); i++) yield lights[i];
	},
};

// The four slots, by index. Getters rather than an array because the list is
// live: a script that reads `three.lights[1]` after a `remove` should see the
// light that is there now, not the one that was.
//
// Slot zero answers with `light` itself, so `three.lights[0] === three.light`
// — one object, one place the shadow settings live.
for (let i = 0; i < MAX_LIGHTS; i++) {
	Object.defineProperty(lights, i, {
		enumerable: true,
		get() {
			if (i >= H.lightCount()) return undefined;
			return i === 0 ? light : lightAt(i);
		},
	});
}

const camera = {
	get fov() { return H.cameraGet()[6]; },
	set fov(v) {
		const c = H.cameraGet();
		H.cameraSet(c[0], c[1], c[2], c[3], c[4], c[5], +v, c[9]);
	},

	get yaw() { return H.cameraGet()[3]; },
	get pitch() { return H.cameraGet()[4]; },
	get distance() { return H.cameraGet()[5]; },

	// The third angle, in DEGREES around the view direction, and the one of
	// the three that is assignable — because it is not part of aiming the
	// turntable. Yaw and pitch say where the camera looks and are written by
	// `orbit()`; roll turns the picture and nothing else writes it.
	//
	// Zero is a level horizon, which is what a camera that never touches this
	// has. It is the half of a vehicle camera that `attach({ local: true })`
	// does not cover: the offset rides the fuselage, and this banks the view
	// with it.
	//
	//     three.camera.attach(plane, { offset: [0, 1.2, 0.4], local: true });
	//     three.setAnimationLoop(() => { three.camera.roll = plane.rotation.z * 180 / Math.PI; });
	//
	// Not clamped and not wrapped, unlike pitch and yaw, so `camera.roll += 1`
	// in a loop reads back as a number that keeps climbing rather than as a
	// sawtooth. See `Camera.roll` for why neither guard is needed here.
	get roll() { return H.cameraGet()[9]; },
	set roll(v) {
		const value = +v;
		if (!Number.isFinite(value)) {
			throw new TypeError(`three.camera.roll wants degrees around the view direction, not ${v}`);
		}
		const c = H.cameraGet();
		H.cameraSet(c[0], c[1], c[2], c[3], c[4], c[5], c[6], value);
	},

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
			// Carried through, like the target and the fov. `cameraSet` writes
			// every field it is given, so leaving roll off would level the
			// camera on the next `orbit()` — which is one drag away, and would
			// read as the roll not working rather than as orbit clearing it.
			c[9],
		);
		return this;
	},

	lookAt(x, y, z) {
		const c = H.cameraGet();
		if (typeof x === 'object' && x !== null) ({ x, y, z } = x);
		H.cameraSet(+x, +y, +z, c[3], c[4], c[5], c[6], c[9]);
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
	// `lag` is seconds, and it is a time constant rather than a fraction: 0
	// is rigid, 0.12 is a camera that takes about an eighth of a second to
	// catch up, and the same number means the same lateness at 60 and at 144
	// frames a second.
	//
	// The offset is in **world space** unless `local` is set. A head is
	// [0, 1.7, 0] whichever way a character faces. `{ behind, height }` is
	// the third-person follow in the object's own heading — behind along its
	// -Z, height up — and implies `local`.
	attach(object, { offset = [0, 0, 0], distance = null, lag = 0, local = false, behind, height } = {}) {
		const target = liveObject(object, 'three.camera.attach');
		let [ox, oy, oz] = asTriple(offset, 'three.camera.attach(object, { offset })');
		let inLocal = !!local;
		if (behind !== undefined || height !== undefined) {
			inLocal = true;
			if (height !== undefined) oy = +height;
			if (behind !== undefined) oz -= +behind;
		}
		const boom = distance === null ? H.cameraGet()[5] : +distance;
		if (!Number.isFinite(boom) || boom < 0) {
			throw new RangeError(
				`three.camera.attach(object, { distance }) wants zero or more — ${distance} is not a boom length`
			);
		}
		const lagSec = +lag;
		if (!Number.isFinite(lagSec) || lagSec < 0) {
			throw new RangeError(`three.camera.attach(object, { lag }) wants seconds — 0 for rigid, not ${lag}`);
		}
		H.cameraAttach(target[0], target[1], ox, oy, oz, boom, lagSec * 1000, inLocal);
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

	// The world-space ray through a pixel of the rendered image, as
	// `{ origin, direction }` — two Vector3s, the direction unit length, and
	// exactly what `scene.raycast(origin, direction)` takes.
	//
	//     const r = three.camera.ray(x, y);
	//     const t = -r.origin.y / r.direction.y;          // where it meets y = 0
	//     const on = r.origin.clone().addScaledVector(r.direction, t);
	//
	// **This is the question `scene.pick(x, y)` cannot be asked.** A pick
	// needs something already under the cursor, so dragging a piece across
	// bare ground and dropping one where nothing is yet — the two things an
	// editor does most — have nothing to pick. Both are this ray met with a
	// plane the script chose.
	//
	// `x` and `y` are the rendered image's pixels from its top-left corner:
	// the same ones `scene.pick(x, y)` takes, `three.input.pointer` answers
	// in and `three.renderSize()` counts, so a cursor position feeds both
	// without conversion. The ray goes through the pixel's CENTRE, which is
	// where the rasterizer decided its colour.
	//
	// It is the same ray a pick casts rather than a second derivation from
	// `position()`, `forward()` and `fov` — so `raycast` on it finds what
	// `pick` finds at that pixel, at the same `distance`. The origin is
	// therefore on the near plane and not at the eye: what sits in front of
	// the near plane is invisible, and a ray taken from the picture does not
	// hit it either.
	ray(x, y) {
		if (!(Number.isFinite(+x) && Number.isFinite(+y))) {
			throw new TypeError('three.camera.ray(x, y) wants two pixel coordinates');
		}
		const r = H.cameraRay(+x, +y);
		return {
			origin: new Vector3(null, r[0], r[1], r[2]),
			direction: new Vector3(null, r[3], r[4], r[5]),
		};
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
		const [x, y, z, yaw, pitch, distance, fov, near, far, roll] = H.cameraGet();
		return { target: { x, y, z }, yaw, pitch, roll, distance, fov, near, far };
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
// **It survives `new three.Scene()` and `activate()`,** following the camera
// rather than the background. The background, the lights and the shadow
// settings belong to a scene and travel with it; the mouse does not belong
// to a scene at all, and a game that took it for its own camera would lose
// it at every level boundary.

const controls = {
	get enabled() { return H.controlsGet(); },
	set enabled(v) { H.controlsSet(!!v); },
};

// -----------------------------------------------------------------------
// The window
//
// Not a Three.js API — the browser has `window` and Three.js takes a
// canvas, so there was nothing to match. What is here is the smallest set
// that answers "how big is this thing" and "make it bigger".
//
// **The picture follows the window.** Everything renders into an offscreen
// target and the swapchain puts that on the window; when the window moves —
// a drag, `resize`, fullscreen, a different display — the target moves with
// it, so what is on screen is its own pixels rather than stretched ones.
// `--width`/`--height` are the size the window OPENS at.
//
// So `three.renderSize()` — what a screenshot comes back as and what
// `scene.pick(x, y)` counts in — tracks the window too, and on a retina
// display it is the DEVICE pixel count, which is twice the logical one.
//
// **`three.setRenderSize(width, height)` pins it**, and that is the render
// scale a settings screen offers: a target below the window is upscaled to
// fill it, which is fewer pixels to shade. While it is pinned the window no
// longer moves the picture, and resizing past it says so in the run's
// `warnings`. `three.setRenderSize(null)` gives the follow back.
//
// **`width` and `height` are device pixels**, read off the surface rather
// than the window, so they are current through a live resize drag and
// honest on a display that is not 1:1. `scale` is device pixels per logical
// point, and `resize` takes the same device pixels these report, so asking
// for a size and reading it back agrees.
//
// **`resize` is a request.** X11's window manager may adjust it and a
// Wayland compositor answers with a configure some frames later, so the new
// size arrives on a later frame rather than on the next line:
//
//     three.window.resize(1600, 900);
//     three.window.width;                    // still the old one
//     three.setAnimationLoop(() => { ... }); // where the new one turns up
//
// Everything is zero and `resize` returns false when there is no window,
// which is `--headless` — the same shape `three.input.pointerLock` uses,
// and for the same reason: a game that resizes its window should still
// start on a machine that has none.
//
// **On Wayland the size never reads back.** That surface answers "whatever
// the swapchain asks for" rather than a size, so the drawable stays what
// the process booted at and the compositor scales it into whatever the
// window became — which also means the picture cannot follow a resize
// there, because nothing ever reports one. X11, macOS and Windows track it.
const windowSurface = {
	get width() { return H.windowSize()[0]; },
	get height() { return H.windowSize()[1]; },
	get scale() { return H.windowSize()[2]; },
	// Resize the window. THE PICTURE FOLLOWS: the offscreen target moves to
	// the window's new drawable on the next frame, so this changes how many
	// pixels are rendered as well as how big they are shown — unless
	// three.setRenderSize has pinned the render size.
	//
	// A REQUEST, not a setting. X11's window manager may adjust it and
	// Wayland answers with a configure some frames later, so read
	// three.window.width back on a later frame. False under --headless.
	resize(width, height) { return H.windowResize(width, height); },

	// What the title bar says. Writable at any time, which is the point:
	// a boot-time name belongs in three.configure, and this is what a
	// pause menu or a level change uses.
	//
	//   three.window.title = `Wumpa Run — ${level.name}`;
	//
	// Reads back what was last set even under --headless, where there is
	// no title bar to put it on.
	get title() { return H.windowTitleGet(); },
	set title(text) { H.windowTitleSet(text); },

	// Whether the window fills a display, and how to ask it to.
	//
	//   three.window.fullscreen = !three.window.fullscreen;
	//
	// ASKING IS NOT GETTING. macOS animates into its own fullscreen space
	// over about half a second, a Wayland compositor answers with a
	// configure some frames later, and an X11 window manager is entitled
	// to refuse outright — so read it back on a later frame rather than on
	// the next line. False under --headless, and setting it there does
	// nothing.
	//
	// The render size follows it, the same way it follows a resize, so
	// fullscreen is sharp rather than stretched — unless three.setRenderSize
	// has pinned it.
	get fullscreen() { return H.windowFullscreenGet(); },
	set fullscreen(on) { H.windowFullscreenSet(!!on); },
};

// -----------------------------------------------------------------------
// Saving
//
// One directory, named by three.configure({ saveDir }) or taken from the
// assets folder's own name, under the platform's application-data root:
// ~/Library/Application Support/three.c3/<name> on macOS, %AppData% on
// Windows, $XDG_CONFIG_HOME or ~/.config elsewhere. three.save.path is
// where it actually landed.
//
// A save is a NAME, not a path: letters, digits, dash, underscore and dot,
// at most 64 of them. There are no subdirectories and no way to leave the
// folder — a name with a '/' in it is refused rather than resolved.
//
// Reading something that was never written answers null rather than
// throwing, because that is every game's first run.

const save = {
	// Where saves go, or null when nothing has named a folder yet.
	get path() { return H.saveDirGet(); },

	// JSON in, JSON out. The common pair.
	//
	//   three.save.write('slot1', { level: 3, hp: 80 });
	//   const s = three.save.read('slot1') ?? { level: 1, hp: 100 };
	write(name, value) { return H.saveWriteText(name, JSON.stringify(value)); },
	read(name) {
		const text = H.saveReadText(name);
		return text === null ? null : JSON.parse(text);
	},

	// The same file as a string, for a game with its own format.
	writeText(name, text) { return H.saveWriteText(name, String(text)); },
	readText(name) { return H.saveReadText(name); },

	// And as bytes. readBytes answers with a Uint8Array the caller owns —
	// it is filled by the host rather than handed out as a view, which is
	// why the size is asked for first.
	writeBytes(name, bytes) { return H.saveWriteBytes(name, bytes); },
	readBytes(name) {
		const size = H.saveSize(name);
		if (size < 0) return null;
		const out = new Uint8Array(size);
		if (size === 0) return out;
		const moved = H.saveReadInto(name, out);
		return moved === size ? out : out.subarray(0, moved);
	},

	// What is in the folder, and how to delete one. list() is [] before
	// anything has been saved and before a folder has even been named, so a
	// load menu needs no guard. remove() answers false for a slot that was
	// not there.
	list() { return H.saveList(); },
	remove(name) { return H.saveRemove(name); },
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

	// The PROCESS's own monotonic clock, in milliseconds, and the one reading
	// here that is not game time.
	//
	// Everything else on this object is scaled by `timeScale` and stops dead
	// when paused, which is what makes `x += speed * three.clock.dt` need no
	// `if`. It is also what makes it useless for the one question a profiler
	// asks: a system timed on the game clock reads zero while paused and four
	// times its true cost in slow motion, so the measurement would be a
	// function of the settings of the thing being measured.
	//
	// So this answers a different question — **how long did that take**, in
	// real milliseconds, whatever the game clock is doing. Two readings and a
	// subtraction; a host call answering a number is 143 ns.
	// `three.systems.report()` is built on it and is usually the thing to reach
	// for instead.
	//
	// Not the same origin as anything else: it starts when the JavaScript
	// runtime opens. Differences are what it is for.
	get wall() { return H.clockWall(); },
	set wall(_) { throw new TypeError('three.clock.wall is the process clock — it is read, and nothing sets it'); },

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
	//
	// **It accumulates into one frame, so n calls before the next frame
	// boundary is one n-long frame and not n frames** — and that is the
	// one way this verb can lie, because a long frame is capped where a
	// short one is not. `PHYSICS_MAX_STEPS` is five and
	// `CLOCK_MAX_FIXED_STEPS` is eight, and both drop the remainder rather
	// than carrying it, which is the `physics-fixed-60hz` note's stutter
	// rule met from the other side: batching manufactures the very long
	// frame that rule exists to survive. Measured against a served headless
	// process — ten `advance(1 / 60)` in one script moved the clock the full
	// 0.167 s and dropped a falling body 1.41 units, where ten stepped
	// frames drop it about 2.8. The time lands and the world does not.
	//
	// So step by calling it once per frame boundary. Under `--mcp` that is
	// one round trip per frame, and there is deliberately no batch verb:
	// one that queued n frames would be `play_frames` (`main.c3`), which
	// counts its own clock from zero and cannot run twice in a process.
	advance(seconds) { H.clockAdvance(+seconds); },
};

// -----------------------------------------------------------------------
// The frame
//
// How the frames have gone, and where the last one went. Not a Three.js
// API — Three.js has no frame loop in core and so has nothing to report
// about one.
//
// `overruns` is how many frames spent more than 8 ms in JavaScript — half
// a 60 Hz frame, the point at which the script has stopped leaving room for
// the draw it sets up. NOTHING IS LOGGED when it happens: a long frame is
// counted here and split in `ms`, and that is the whole of what the engine
// says about it. Under `--mcp` alone it stays 0, because there an overrun
// stops the callback instead of counting it.
//
// `ms` is the last FINISHED frame, split five ways, and the split is the
// point. Read from inside a system it describes the frame before this one,
// because this one is still three spans short of existing.
// The four that add up to `total` are what the eight-millisecond budget is
// measured against:
//
//     handlers   key, click and physics-trigger handlers
//     fixed      every fixed step this frame owed, together
//     frame      the animation callback — the `frame` phase systems
//     jobs       one queued mesh upload, and the microtasks it settled
//
// `solver` is outside `total` because it is outside the budget: the
// physics step runs above the script's window and is the host's own work,
// so it is never what a callback is stopped or counted for. It is reported
// because a frame that spends 10 ms in the solver and 3 ms in script is a
// frame whose script is not the problem, and reading only `total` there is
// how somebody optimises the wrong file.
//
// `three.systems.report()` is the rolling per-system version and the one
// to reach for next: this splits the frame into four spans, that splits
// two of those spans by name.

const frame = {
	get running() { return H.frameStats().running; },
	get ticks() { return H.frameStats().ticks; },
	get overruns() { return H.frameStats().overruns; },
	get ms() { return H.frameStats().ms; },
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

// Edges consumed this frame, so `consume('space')` is true once even when the
// fixed loop runs it eight times. Folded against `frame.ticks` so a new frame
// starts clean without a host callback.
let consumeTick = -1;
const consumedKeys = new Set();
function consumeFrame() {
	const t = H.frameStats().ticks;
	if (t !== consumeTick) { consumedKeys.clear(); consumeTick = t; }
}

const input = {
	isDown(key) { return H.inputDown(String(key)); },
	pressed(key) { return H.inputPressed(String(key)); },
	released(key) { return H.inputReleased(String(key)); },
	// The edge, once. Safe in `phase: 'fixed'`: the first call this frame that
	// sees the key went down answers true, and the rest of the steps do not.
	consume(key) {
		consumeFrame();
		const k = String(key);
		if (consumedKeys.has(k)) return false;
		if (!H.inputPressed(k)) return false;
		consumedKeys.add(k);
		return true;
	},

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

	// -------------------------------------------------------------------
	// Moving the pointer from a script
	//
	// The same argument, for the mouse, and the half of it that reaches
	// further: a headless boot has no pointer either, so the thing a
	// pointer is mostly for — an interface — could not be exercised at
	// all. A panel's buttons, its menus and its drags were reachable only
	// by a person with a window open, which is to say not reachable from a
	// test.
	//
	// **A held button, not an event.** `pressButton(0)` stays down until
	// `releaseButton(0)`, so a drag is four statements that each say what
	// happened:
	//
	//     three.input.movePointer(120, 80);
	//     three.input.pressButton(0);
	//     three.input.movePointer(180, 80);   // a frame apart, each of them
	//     three.input.releaseButton(0);
	//
	// rather than a `drag(a, b)` verb, which would have to invent the
	// frames in between — and inventing them is exactly how a synthesised
	// gesture stops being indistinguishable from a real one. The press
	// captures, so the drag survives leaving the widget.
	//
	// **It goes in above the hit test.** `three.input.pointer`, cui's hit
	// test, `three.onClick` and a `draw` node's `onPointer` are all told
	// the same thing, so a press under an open menu or a modal correctly
	// reaches nothing, and a press on a panel does not also click the
	// scene behind it.
	//
	// `x` and `y` are the rendered image's pixels — the same ones
	// `three.input.pointer` answers in, `scene.pick(x, y)` takes and the
	// PNG starts at, so a place read off a screenshot can be pressed
	// without conversion.
	//
	// It adds to the real mouse: the buttons are or-ed with the window's
	// and the wheel added to it. The position is the one thing that cannot
	// be a union — two positions are not a third — so a placed one stands
	// in for the window's until the real pointer actually moves, and a
	// hand on the mouse takes the cursor straight back.
	//
	// `button` is 0 left, 1 right, 2 middle; anything else is refused by
	// name. `scroll(dy, dx)` is in notches, positive away from the user.
	movePointer(x, y) { H.inputMove(Number(x), Number(y)); },
	pressButton(button) { H.inputButtonHold(button === undefined ? 0 : Number(button), true); },
	releaseButton(button) { H.inputButtonHold(button === undefined ? 0 : Number(button), false); },
	scroll(dy, dx) { H.inputScroll(Number(dy), dx === undefined ? 0 : Number(dx)); },

	// Let go of everything. What a test calls between cases so one does not
	// leak a held key into the next — the mouse buttons included, and they
	// are the half that matters more: a held button captures, so one leaked
	// into the next case makes its first press land inside a drag somebody
	// else started. The unspent wheel goes too; the pointer stays where it
	// was put, because that is what letting go of a button does.
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

	// Take the mouse pointer out of the user's hands — plan.md §17.
	//
	// **What it buys is a look that does not stop.** Without it, `pointer.dx`
	// is a difference of cursor positions, and a cursor stops at the edge of
	// the screen while a hand does not: a mouse look turns until the pointer
	// reaches the edge and then quietly refuses to turn any further. With it,
	// the cursor is hidden and held inside the window and `dx`/`dy` come from
	// the platform's own reading of the mouse, which keeps counting.
	//
	//     three.onClick(() => { three.input.pointerLock = true; });
	//     three.onKeyDown('escape', () => { three.input.pointerLock = false; });
	//
	// **Reading it back tells you whether the platform gave it**, not what you
	// asked for. A headless run has no window and always reads false, and so
	// does a backend with no implementation. Nothing throws — a game should be
	// able to fall back to a drag-look rather than refuse to start — so a
	// script that cares reads the value back after setting it.
	//
	// `three.input.pointer.locked` is the same fact reported beside the deltas
	// it is about, which is the one to test when the question is "are these
	// numbers the good kind".
	get pointerLock() { return H.pointerLockGet(); },
	set pointerLock(on) { H.pointerLockSet(!!on); },

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
	if (liveScene !== null && liveScene.isActive) return liveScene._intersection(raw);
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

	// What the run answers with. Every argument becomes one entry in the `debug`
	// array of the result, as JSON rather than as text inside the log — so an
	// object stays an object. On the command line it prints as `debug: [...]`.
	//
	// One place is not enough: a number is worked out inside a system, or a
	// frame, or halfway down. This can be called wherever that is:
	//
	//   three.debug.write({ crates: Crate.count, wumpa: Wumpa.count });
	//   Player.frame('score', p => { if (p.done) three.debug.write(p.fruit); });
	//
	// Written from a callback, entries are held and reported by the NEXT run
	// rather than lost, the way console.log from one is.
	//
	// Beside `view` because both are the same question — what is this run doing
	// that the frame does not show — answered once in pixels and once in numbers.
	write(...values) {
		// A cycle throws in JSON.stringify and a function stringifies to nothing.
		// Settled here, where String(value) is at hand, rather than in the host:
		// an entry that arrived as text is worth more than one that vanished.
		for (const value of values) {
			let keep = value;
			try { if (JSON.stringify(value) === undefined) keep = String(value); }
			catch (e) { keep = String(value); }
			H.debugWrite(keep);
		}
	},

	// One line, this frame, gone the next. Lives, coins, `r.hit.name` — drawn
	// over the top-left of the frame, and landing in the run's `debug` array as
	// `{ overlay: "..." }` so an agent reads the same line beside the PNG.
	//
	// "Gone the next" is the host's doing: a line has to be set again each frame
	// to stay up, so a HUD is `three.frame(() => three.debug.overlay(...))` and
	// a one-shot note disappears by itself.
	overlay(text) {
		const line = String(text);
		this.write({ overlay: line });
		H.debugOverlay(line);
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
	lights,
	controls,
	clock,
	frame,
	debug,

	// The interface — `three:ui.js`. `set` a tree, `patch` a value, `draw` a
	// list of primitives in frame pixels. Drawn over the finished frame and
	// into the same image a screenshot reads, so an agent sees what a person
	// sees.
	//
	// The node classes are on it too — `three.ui.Panel`, `three.ui.Label`, one
	// per kind — because they are what a `three.Widget` composes and a script
	// destructures them in one line: `const { Panel, Label, Button } = three.ui`.
	ui,

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

	// The sampler a texture is read through, spelled the way Three.js spells
	// it. LinearFilter is the default and is right for a picture;
	// NearestFilter is for pixels meant to be read as squares — pixel art,
	// a palette a shader indexes, anything authored on a grid.
	LinearFilter,
	NearestFilter,

	// Exported for `instanceof` and for building one by hand, which a script
	// wants when it is describing a volume the scene does not hold yet — a
	// plot to fill, a gap to check. Neither is constructed by the host.
	Box3,
	MeshRef,
	// A loaded placement list, not constructed by hand — see `level` below.
	Level,

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
	// A 2D outline with holes, swept along +Z into one closed mesh — the
	// answer to "a shape cannot have a hole in it". Path is the outline
	// (moveTo/lineTo/closePath/absarc); Shape is a Path plus the holes cut
	// out of it; ExtrudeGeometry is what sweeps one. See scene/extrude.c3.
	Path,
	Shape,
	ExtrudeGeometry,
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
	// What `three.merge` answers with — carrying data instead of only
	// parameters, `TerrainGeometry`'s own shape. Exported for `instanceof`,
	// like `Geometry`; not constructed by hand.
	MergedGeometry,
	// MeshRef.split()'s reverse: every Mesh in a subtree, or an explicit array
	// of them, concatenated into one asset with each one's transform baked
	// into its vertices. See scene/merge.c3 and geometry.js for the frame, the
	// material and colour rules, and what is skipped.
	merge,
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
	// The three-dimensional half of the curve pair, and the one a loop
	// samples rather than a bake consumes: a camera rail, a patrol route,
	// a rope. Three.js's class, constructor and method names.
	//
	// getPoint(t) walks the curve's own parameter and getPointAt(u) walks
	// its LENGTH, and the difference is what makes hand-written rail code
	// look wrong — an object moving at constant t speeds up through the
	// widely spaced control points and crawls through the close ones.
	CatmullRomCurve3,

	// The two verbs between "where it is" and "where it should be", and
	// both are frame-rate independent, which is the whole reason they are
	// named rather than written inline. `x += (target - x) * 0.1` closes a
	// tenth of the gap per FRAME, so it is twice as fast at 120 Hz as at
	// 60 — a chase tuned on one machine is a different chase on another,
	// and nothing about it reads as a bug.
	//
	// damp is a decay: fastest at the start, asymptotic at the end, right
	// for a camera easing onto a target. smoothDamp is a critically damped
	// spring: it has momentum, so it accelerates and arrives, which is what
	// a turret slew or a sliding panel wants. dampAngle is damp taking the
	// short way round a circle, which is the one a heading needs.
	//
	// dt is in SECONDS, and so is `three.clock.dt` — pass it straight through.
	damp,
	dampAngle,
	smoothDamp,

	// `moveTowards` is the third one, and it is the LINEAR one: it closes a
	// fixed distance per call and lands exactly on the target, where damp
	// closes a fraction and never quite arrives. A turn rate, a reload timer
	// and a fuel gauge are rules rather than feels, and this is the verb for
	// a rule. `moveTowardsAngle` is it taking the short way round a circle.
	moveTowards,
	moveTowardsAngle,

	// The scalar block four of the eight examples used to open with, spelled
	// slightly differently in each. Three.js's MathUtils names and Three.js's
	// argument order — which is worth reading once, because `smoothstep` here
	// is `(x, min, max)` and GLSL's is `(edge0, edge1, x)`, so the shader body
	// and the script a few lines above it take the same three numbers in
	// different orders.
	//
	// `clamp01` and `band` are the two with no Three.js equivalent: the first
	// is GLSL's saturate, and the second is the splat-mask verb that makes a
	// layered terrain read as bands of material rather than one gradient.
	clamp,
	clamp01,
	lerp,
	inverseLerp,
	mapLinear,
	smoothstep,
	smootherstep,
	band,
	pingpong,
	euclideanModulo,
	degToRad,
	radToDeg,

	// The seam at +/-pi, named. `wrapAngle` folds into (-pi, pi] and
	// `angleDelta(from, to)` is the SHORT way between two headings — +3.1 to
	// -3.1 is 0.08 radians, not 6.2, and a character told to turn 6.2 spins a
	// full circle to arrive where it was already pointing. `dampAngle` and
	// `moveTowardsAngle` are both written in terms of this one function, so
	// there is one spelling of the wrap rather than three.
	wrapAngle,
	angleDelta,

	// Colour arithmetic over whatever `mesh.color` takes — a hex, an [r,g,b],
	// an [r,g,b,a] or an {r,g,b} — answering with four components, so the
	// result feeds straight back in. `tintColor` leaves alpha alone.
	mixColor,
	tintColor,

	// Randomness that can be REPLAYED, and the reason it is here rather than
	// left to Math.random: the fixed step, the solver's own accumulator and
	// state_hash exist so the same inputs give the same frame, and one
	// Math.random() in the gameplay layer costs all of it — a bug that
	// reproduces on the tester's machine and not on yours.
	//
	// randFloat / randInt / randFloatSpread keep Three.js's names and do NOT
	// call Math.random: they draw from a stream three.seed(n) resets. A script
	// that wants an unrepeatable number still has Math.random. new
	// three.Random(seed) is the same generator owned by the caller, for when
	// two systems must not perturb each other's sequence.
	Random,
	seed,
	randFloat,
	randInt,
	randFloatSpread,

	// Noise, sampled AT A POINT rather than baked into a grid — the same call
	// fills a texture in a double loop, feeds field.fill((x, z) => ...) for
	// terrain, and answers one spawn test. `period` is what makes it TILE:
	// pass the number of cells across an image and the left edge meets the
	// right, which fbm2 gets right per octave and a hand-rolled one does not.
	hash,
	noise2,
	fbm2,

	// The spatial questions a game asks that a picture does not: what is
	// within five metres, what does this box overlap, what is behind that
	// wall, and where does this capsule stop if it moves there.
	//
	// They go through an index over the scene's drawable nodes, which is
	// rebuilt by the first query after anything moved and by nothing else — so
	// a frame that asks nothing pays nothing, and the hundredth ground ray in
	// a frame costs a cell walk. scene.raycast goes through the same index and
	// stopped being a scan over every node in the scene because of it.
	query,
	// A reusable answer buffer for the flat form of every query verb —
	// three.query.buffer(n) is the way to make one.
	QueryResult,

	// The character controller: sweep a capsule, slide along what it hits,
	// climb a ledge under the step height, and report whether it is standing
	// on anything. It takes a position and answers with a position — it does
	// not own an object and integrates nothing, so gravity and the jump stay
	// the caller's.
	moveAndSlide,

	// The same controller for a whole crowd, in ONE call — and it exists for
	// the shape of the answer rather than for the crossing. The single form's
	// 7.53 us per agent comes apart: 3.10 us is the sweep, 1.05 us
	// is the crossing and the raw host answer, and 3.63 us — three fifths — is
	// the JavaScript result object, three live Vector3s and two lazy node
	// properties built for a caller who reads four numbers out of them. This
	// writes into arrays the caller owns and builds nothing.
	//
	// positions is the capsule centre and is updated IN PLACE. `self` is the
	// column of handles that stops each agent colliding with its own mesh, and
	// three.batch(objects).handles is already exactly that array. `results` is
	// optional, 8 floats an agent, laid out by three.moveResult.
	//
	// Everyone moves at once: every agent is swept against the world as it was
	// when the call started, because resolving in array order would make the
	// answer depend on how the caller happened to store its crowd.
	moveAndSlideAll,
	// The layout of one agent's block in that results array, and the bits in
	// its flags float. three.moveBuffer(n) makes one of the right size.
	moveResult,
	moveBuffer,

	// Move many nodes in one crossing, through a Float32Array. NOT a faster
	// way to move a dozen things — five hundred ordinary position writes
	// measure three per cent of a frame — but the right shape when
	// the write is already a loop over numbers: a crowd, a particle field, a
	// chunked terrain. The trigger is about two thousand nodes a frame.
	batch,
	TransformBatch,

	// Navigation. three.nav.bake() voxelizes the scene's standing room;
	// three.nav.path(from, to) is one agent's route, shortened against the
	// geometry so it does not look like it is walking cell centres; and
	// three.nav.field(goals) is the solve KEPT, which is what a crowd samples.
	// The two verbs are two because a path is a whole solve thrown away after
	// one answer, and offering only that guarantees somebody writes the second
	// one badly.
	//
	// `nav` itself is the getter further down: a bake belongs to a scene, so
	// three.nav is the rendered scene's and scene.nav is any scene's.
	NavField,

	// Seek, arrive and separation over a whole crowd in one crossing, writing
	// into a Float32Array the caller owns. It answers with a DESIRED velocity:
	// integrating it and deciding whether an agent may actually go there are
	// the caller's, which is what lets the same call feed three.moveAndSlide
	// for agents that collide and a plain add for agents that do not.
	steer,

	// The ordered system registry. setFixedLoop and
	// setAnimationLoop each take ONE callback, so a game with five things to do
	// a frame has one function with five things in it. This is that function
	// split into named parts that run in a declared order, with per-system
	// timings over three.clock.wall.
	//
	// It makes nothing faster and is not meant to: §17's crowd table put every
	// JavaScript-side layout inside the noise floor of the measurement. What it
	// makes is a frame you can read, and a slow one you can attribute — which
	// three.stats() has done for the GPU half since §19 and nothing has done
	// for this half.
	//
	// three.setAnimationLoop and three.setFixedLoop are systems under reserved
	// names, so a script that never touches this is unaffected.
	systems,
	// The registry's rolling cost as a 0..1 fraction of a frame budget, for a
	// HUD that wants a bar rather than a number.
	systemLoad,

	// A scalar gameplay timer — the player's spin, a hurt window, coyote time
	// — for the `if (x > 0) x -= dt` pattern examples/ used to write out by
	// hand. Ticked by a lazily-registered three.systems entry rather than
	// read off three.clock, because the game clock only advances once per
	// host tick and a window shorter than one fixed step would see no time
	// pass across a multi-step catch-up frame.
	cooldown,
	Cooldown,

	// §23. A class is the entity, and three.track is what makes it one: it owns
	// the object -> instance map, the spawn ritual, the body, the trigger
	// volume, the live list and the deferred compaction. c.hp is an ordinary
	// field; the two or three fields a BULK VERB reads are declared as
	// { columns } and the instance holds a subarray window onto the shared
	// column, so three.steer(Critter.column('position'), ...) is handed the
	// storage itself and nothing is ever gathered.
	//
	// Class.spawn(...) rather than new Class(...) — the slot has to exist
	// before the constructor runs, and the answer three.track gives back is a
	// Proxy that says so instead of letting an untracked instance through.
	track,

	// The base class, and the form the docs lead with:
	//
	//     class Critter extends three.Entity {
	//         static capacity = 32;
	//         static columns = { position: 3, motion: 3 };
	//         constructor(at) { super(); this.position[0] = at.x; ... }
	//     }
	//
	// There is no three.track call beside it — the class registers itself on
	// first use, reading its own statics. `super()` first is where the refusal
	// of a bare `new Critter()` lives, which is the one thing the wrapper form
	// needed a Proxy for.
	Entity,

	// A WIDGET IS A CLASS, the way an entity is, and this is the base to extend.
	// `render()` describes the interface as it is now, assigning a field marks
	// the widget for a re-render, and what reaches the host is the DIFFERENCE —
	// one `three.ui.patch` per changed value, and a `set` only when the shape
	// itself changed. So a HUD is written the way an immediate-mode one is and
	// costs what a retained one does, and the two things `set`/`patch` make a
	// script carry — a unique key per value and the rule that every tree must
	// still contain the keys the loop patches — stop existing.
	Widget,

	// Which instance owns this object — a drawn node, one of its meshes, or a
	// trigger volume — or null. Walks up the parent chain, because a raycast
	// answers with the leaf it hit, and an assembled character is a Group of
	// eleven meshes. What a rule keyed on "what are these two things" opens with.
	instanceOf,

	// The game raising its own event: three.emit(player, 'use', door) reaches
	// Door.on('use', Player, fn) exactly as a trigger reaches an 'enter' rule.
	// It dispatches AT ONCE, where an engine event is queued and drained by the
	// `rules` system — the game knows when it is safe to delete something and
	// the solver does not.
	emit,

	// Every registered rule and what it has cost. The pair-dispatch half of
	// three.systems.report().
	rules: rulesReport,

	// A compound mesh from a description of its parts: one shared unit geometry
	// per SHAPE with the size in mesh.scale, `pivot` for a limb that swings
	// about a hip, `mirror` for the pair, and every part named in the answer.
	// It replaces the five statements per body part that every hand-built
	// character in examples/ is made of.

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

	// Decode a PNG, JPEG or KTX2 and upload it. Synchronous, for three.load's
	// reason, and under --assets the path is inside the game directory and
	// cannot climb out of it.
	//
	// The format is read from the file's first bytes rather than from its
	// extension, so a JPEG somebody named .png loads correctly instead of
	// being reported as corrupt.
	//
	// The second argument is `{ colorSpace, generateMipmaps, filter }`, and the
	// two worth knowing about are colorSpace and filter. colorSpace defaults to
	// sRGB, which is right for a picture of something and wrong for a map whose
	// channels are numbers:
	//
	//     const bricks = three.texture('brick.png');
	//     const bumps  = three.texture('brick_normal.png',
	//                                  { colorSpace: three.LinearSRGBColorSpace });
	//
	// filter defaults to linear, which is right for a picture, and Nearest is
	// what pixel art and a shader-indexed table want:
	//
	//     const sprites = three.texture('sprites.png', { filter: three.NearestFilter });
	texture(path, options = null) {
		if (typeof path !== 'string' || path.length === 0) {
			throw new TypeError('three.texture(path) wants a path to a .png, .jpg or .ktx2');
		}
		const chosen = uploadOptions(options, 'three.texture(path, options)');
		return new Texture(H.texture(path, chosen.code, chosen.mips, chosen.nearest), path, chosen.space);
	},

	// A text file out of the assets directory. The third thing that lives
	// there beside the .glb and the .png: the level list that places a kit, a
	// table of stats, a line of dialogue — a file a person edits in the repo,
	// beside the kit it refers to, that ships with the game.
	//
	// It is three.load's door with nothing loaded through it, so the sandbox
	// is the same one: a path that climbs out of the assets directory throws,
	// a leading '/' means that directory rather than the disk's root, and the
	// paths three.inventory() hands back are paths this accepts. Without
	// --assets the path is used as written, exactly as three.load's is.
	//
	// three.writeText(path, text) is this door the other way — the same
	// resolve_write sandbox scene.export(path) writes a .glb through, so a
	// level list saves back to exactly where this reads it from.
	//
	// null for a file that is not there — three.save.readText's answer, not
	// three.load's throw, because "no level here yet" is a question an editor
	// asks rather than a failure. Over 4 MB throws, and so does a file whose
	// bytes are not UTF-8: this reads text, and a .glb read by mistake says so.
	readText(path) {
		if (typeof path !== 'string' || path.length === 0) {
			throw new TypeError('three.readText(path) wants a path to a file in the assets directory');
		}
		return H.assetText(path);
	},

	// The same file, parsed. What three.save.read is to three.save.readText,
	// and for the same reason: JSON is what a level gets written as, and the
	// parse belongs on this side rather than in a second host verb.
	//
	//   const level = three.readJSON('levels/lumbridge.json') ?? [];
	//   for (const [piece, x, y, z, turns] of level) {
	//     const m = kit.mesh(piece);
	//     m.position.set(x, y, z);
	//     m.rotation.y = turns * Math.PI / 2;
	//     scene.add(m);
	//   }
	//
	// null for a file that is not there, like readText. A file that is there
	// and is not JSON throws from JSON.parse, naming the position — which is
	// what a hand-edited level file gets wrong.
	readJSON(path) {
		if (typeof path !== 'string' || path.length === 0) {
			throw new TypeError('three.readJSON(path) wants a path to a file in the assets directory');
		}
		const text = H.assetText(path);
		return text === null ? null : JSON.parse(text);
	},

	// readText's door the other way — a string into the assets directory,
	// through the same sandbox scene.export(path) writes a .glb through
	// rather than a second one: a path that climbs out throws, a leading '/'
	// means the assets directory and not the disk's, and nothing outside it
	// is ever written. Without --assets the path is used as written, exactly
	// as scene.export's is.
	//
	// Answers the path it actually wrote to, so a caller can print where a
	// level landed. Over 4 MB throws, the same limit three.readText stops
	// at — a file this writes is a file that reads back.
	writeText(path, text) {
		if (typeof path !== 'string' || path.length === 0) {
			throw new TypeError('three.writeText(path, text) wants a path to a file in the assets directory');
		}
		return H.assetWriteText(path, String(text));
	},

	// The same file, stringified. What three.save.write is to
	// three.save.writeText.
	//
	//   const path = three.writeJSON('levels/lumbridge.json', rows);
	//   const rows2 = three.readJSON('levels/lumbridge.json');
	writeJSON(path, value) {
		return this.writeText(path, JSON.stringify(value, null, '\t') + '\n');
	},

	// A placement list over a kit: `{ kit, rows: [{ id, piece, position, rotation, snap? }] }`,
	// read with `three.readJSON` and written with `three.writeJSON` — see
	// `docs/functions.md`'s `three.level` for the file and `load`'s `options.refit`.
	//
	//   const level = three.level.load('levels/lumbridge.json', scene);
	//   level.objects.get('wall_2').position.x += 0.3;
	//   three.level.save('levels/lumbridge.json', level);
	level,

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

	// Draw one frame and write it to a .png, answering
	// `{ path, width, height, bytes }`.
	//
	//   three.screenshot('build/sheet.png');
	//
	// The --screenshot flag as a verb, and the difference is that a script can
	// take more than one picture of one run: set something up, call this, set
	// up the next thing, call it again. Without it a script wanting six images
	// had to arrange for the state of each to land on the frame
	// `--frames n --every 1` would capture, which is a script written around
	// the harness rather than around what it is doing.
	//
	// This draws the frame itself — a three.render() on the line before is a
	// wasted frame, not a required one — and what it writes is what the window
	// would show: post-processing, the interface and three.debug.overlay
	// included, at three.renderSize().
	//
	// The path is the one scene.export writes through: under --assets it is
	// inside the game directory and cannot climb out, a folder that is not
	// there yet is made, and with no assets directory it is used as written.
	//
	// Needs a GPU device. Reading one back is three.texture(path), which is
	// how a sheet baked through a post pass becomes a map on a material.
	screenshot(path) {
		if (typeof path !== 'string' || path.length === 0) {
			throw new TypeError('three.screenshot(path) wants a path to write a .png to');
		}
		return H.screenshot(path);
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

	// The rendered scene's. `scene.stats()` is how a scene that is not being
	// rendered answers for itself.
	stats() { return H.stats(); },

	// Every scene that exists, as { id, active, held, nodes }.
	//
	// **This is the number that goes wrong quietly.** `new three.Scene()` shows
	// a new world without freeing the one before it — that is what makes
	// building the next level while the current one is on screen possible — so
	// a script that builds a scene per call, or a game that transitions eight
	// times, holds every one of them: a node pool, a physics world and a set of
	// asset references apiece, drawn by nothing and costing frame time nothing.
	// `stats().scenes` has always been the count. This is what the count is
	// made of.
	//
	// `held` is the half that says what three.sceneById(id) gives you back.
	// True is the same Scene object with its `children` intact, and it stays
	// true across run_scripts: the registry behind it is bounded by dispose,
	// not by the scope that built the scene, so a world built two calls ago is
	// still the one you built. False means no Scene was ever made for it here
	// — the scene the process starts with is the one that reads that way — and
	// sceneById mints a handle onto it instead, which flips this to true.
	// three.disposeInactive() is how you get rid of them without naming any.
	get scenes() { return sceneOverview(); },

	// The Scene for a host id — the one you built, or a handle onto one whose
	// wrapper is gone.
	//
	// Identity holds where it can: three.sceneById(s.id) === s for a scene this
	// script still holds. For one it does not, the handle is real and every
	// verb that goes through the host works on it — activate, dispose, stats,
	// export, background, raycast — but `children` is empty, because the
	// objects that filled it belonged to a script that ended.
	sceneById(id) { return sceneForId(id); },

	// Free every scene except the one being rendered, and sweep.
	//
	// The level transition, minus the step everybody forgets. The ritual is
	// activate the next one, dispose the rest, three.unloadUnused(); this is
	// the last two, and it cannot go wrong in the way doing it by hand does
	// because the host refuses to dispose the scene being rendered.
	//
	// Answers with { scenes, assets, meshes, textures, bytes } — how many
	// worlds went, and what the sweep actually gave back afterwards. The
	// second is often zero and that is right: two scenes over one kit means
	// disposing either frees nothing, and `bytes` is texture bytes alone, so a
	// sweep that gave back nothing but geometry reads zero too.
	// `stats().geometryBytes` before and after is that half.
	disposeInactive() { return disposeInactiveScenes(); },

	// Give the names back so the same file can run again. Disposes every
	// tracked class (even after their scene is already gone), clears the
	// system registry, and drops the post chain. Does not free the scene being
	// rendered — `new three.Scene()` then `disposeInactive()` is still that half.
	reset() {
		unmountAllWidgets();
		disposeAllEntities();
		systems.clear();
		this.setPost(null);
	},

	// Free every asset no live mesh names, and every texture that goes with
	// it. scene.unload() is this plus emptying the scene, and is what a level
	// transition wants; this on its own is for the asset loaded and then
	// changed its mind about.
	//
	// Answers with { assets, meshes, textures, bytes } — how many asset slots
	// went, how many pieces of a still-used file went without it, how many
	// unique images went, and how many bytes of IMAGE that was. `bytes` is
	// textures only: geometry freed here does not appear in it, and
	// `stats().geometryBytes` before and after is where that shows.
	// Costs a full device idle when there is anything to free and nothing at
	// all when there is not, so once per level is right and once per frame is
	// merely wasteful.
	unloadUnused() { return H.unloadUnused(); },

	// Boot this game again from its own source — §8.
	//
	// The same thing shift+R does in a `--debug` window — and unlike the
	// chord this works in every run, which is the reason it is a verb
	// too is `--mcp`: an agent edits a .js, calls this, and the next
	// screenshot is of the edited file. It returns immediately and the
	// reload has not happened yet — the host performs it between this
	// frame and the next, because doing it on the call would free the
	// engine this call is running in.
	//
	// A new JavaScript context: the animation loop, every handler, every
	// live object and every module this script imported are gone, and
	// `main.js` runs again from the top. What survives is the machine —
	// loaded assets, compiled pipelines, the camera — and `persist`.
	//
	// A run with no host loop to perform it (a `--frames` batch, a test)
	// takes the request and never acts on it.
	reload() { H.reload(); },

	// Close the window and end the process — the in-game menu's Quit.
	//
	// It returns, and the process is still up: the host closes between
	// this frame and the next, because closing inside the click handler
	// that asked would free the engine the handler is running in. So the
	// frame already built is the last one shown, and a fade-out that ends
	// on this call gets to finish.
	//
	//   menu.on('quit', () => three.quit());
	//
	// There is nothing after it worth writing, but nothing stops the rest
	// of the handler running either — treat it as a request, not a
	// `return`.
	//
	// Escape does the same thing in the window, but only under `--debug`.
	// This one is how a shipped game closes and works in every run: the
	// engine reaching past the game to the player is the part that is
	// gated, not the game closing itself.
	//
	// A run with no host loop to perform it (a `--frames` batch, a test)
	// takes the request and never acts on it, the same as `reload()`.
	quit() { H.quit(); },

	// The one object that survives a reload, and the whole of what does.
	//
	// Written by the game, read by the game, and carried across as JSON —
	// so what may go in it is what `JSON.stringify` accepts. A Mesh, a
	// Scene or a body is an index into a pool that is about to be freed;
	// put the numbers in, not the handles. A value it cannot serialise
	// (a cycle, a Map, a function) is reported and dropped rather than
	// silently half-kept.
	//
	//   if (three.reloaded) player.position.set(...three.persist.at);
	//   three.setAnimationLoop(() => { three.persist.at = player.position.toArray(); });
	//
	// Empty on a first boot, and never touched by anything but the game.
	persist: {},

	// Whether this boot came from a reload rather than from starting the
	// process. False on the first, true on every one after it, and the
	// only way a script can tell the difference — a game reads it to
	// decide whether `persist` means anything.
	reloaded: false,

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
		if (fn === null || fn === undefined) { systems.remove(ANIMATION_SYSTEM); return; }
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
		// Registered rather than installed: `three.systems` owns the host's
		// callback slot, and this is one system under a reserved name — see
		// systems.js. A script that has never heard of the registry installs
		// exactly one system and gets exactly the behaviour it always had, and
		// `millis` is what keeps this argument Three.js's milliseconds while
		// every other system is handed seconds.
		systems.add(ANIMATION_SYSTEM, fn, { phase: 'frame', millis: true });
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
		if (fn === null || fn === undefined) { systems.remove(FIXED_SYSTEM); return; }
		if (typeof fn !== 'function') {
			throw new TypeError('three.setFixedLoop(fn) wants a function, or null to stop');
		}
		if (fn.constructor && fn.constructor.name === 'AsyncFunction') {
			throw new TypeError(
				'the fixed loop must be synchronous — an async one returns before it has done '
				+ 'anything, and the step does not wait. Do the awaiting in a run_script.'
			);
		}
		// The same reserved-name registration `setAnimationLoop` makes. No
		// `millis`: the fixed callback is handed seconds and always was, which
		// is also what a system is handed.
		systems.add(FIXED_SYSTEM, fn, { phase: 'fixed' });
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
	// It is the offscreen target's, never a window's: `three.window` is the
	// window, and it can be a different size without moving this one.
	renderSize() {
		const [width, height] = H.renderSize();
		return { width, height };
	},

	// How big the window is, what it is called, and whether it fills a
	// display. Zero and false everywhere under `--headless`.
	window: windowSurface,

	// Read and write the game's own save folder. See the block above `save`.
	save,

	// Pin the render size, instead of letting it follow the window.
	//
	//   three.setRenderSize(1280, 720);   // render here, upscale to the window
	//   three.setRenderSize(null);        // back to following the window
	//
	// BY DEFAULT THE PICTURE FOLLOWS THE WINDOW: drag an edge, call
	// three.window.resize, go fullscreen, and the offscreen target moves
	// with it, so the window always shows its own pixels rather than
	// stretched ones. --width/--height are the size the window opens at.
	//
	// This is the escape hatch, and the reason it exists is performance: a
	// render size deliberately below the window is upscaled to fill it,
	// which is the "render scale" slider a settings screen has. Once set,
	// the window no longer moves it — pass null to give it back.
	//
	// After it, three.renderSize(), the PNG a screenshot returns and the
	// coordinates scene.pick(x, y) counts in are all the new size.
	//
	// Returns true when it has already happened and false when it is
	// queued: called from inside the animation loop it takes effect
	// between that frame and the next, because the images it frees are the
	// ones that frame is drawing into. Called from a script or a tool call
	// it is immediate. Either way, read the size back on a later frame.
	//
	// A size the device will not allocate throws, and the old target is
	// still there and still being drawn.
	setRenderSize(width, height) {
		if (width === null || width === undefined) return H.renderFollowWindow();
		return H.renderResize(width, height);
	},

	// What a game declares about itself, at the top of main.js.
	//
	//   three.configure({
	//     title: 'Wumpa Run',
	//     fullscreen: false,
	//     saveDir: 'wumpa-run',
	//   });
	//
	// Every key is optional and anything left out is left alone. There are
	// no command-line flags for these: a player never sees a command line,
	// and a settings screen has to change the same things at runtime — so
	// `title` and `fullscreen` are live properties on `three.window` as
	// well, and this is the one call that sets them before the first frame.
	//
	// `saveDir` is boot-only and has no property beside it, deliberately:
	// moving it mid-run would strand everything already written. It is a
	// FOLDER NAME and not a path — a separator in it is refused — and it
	// answers with where the folder actually is, which is also
	// `three.save.path`.
	//
	// Returns { title, fullscreen, saveDir } as they stand after the call,
	// so a boot log can print one line and be accurate.
	configure(options = {}) {
		if (options === null || typeof options !== 'object') {
			throw new TypeError('three.configure({ title, fullscreen, saveDir }) wants an object');
		}
		if (options.title !== undefined) H.windowTitleSet(String(options.title));
		if (options.fullscreen !== undefined) H.windowFullscreenSet(!!options.fullscreen);
		if (options.saveDir !== undefined) H.saveDirSet(String(options.saveDir));
		return {
			title: H.windowTitleGet(),
			fullscreen: H.windowFullscreenGet(),
			saveDir: H.saveDirGet(),
		};
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
	// entity.js owns the host slot so a 'click' rule and this handler can both
	// have it; the contract here is unchanged.
	onClick(fn) { setScriptHandler('click', fn, 'three.onClick'); },

	// The physics world of the Scene being rendered. See DOCS.classes.Physics.
	//
	// A view onto `scene.physics` and nothing more: a world belongs to a scene,
	// because a body names an object in one, and this is the shortest spelling
	// of "the one on screen". A script preparing the next level names that
	// scene's own — `next.physics.add(floor)` — and the bodies are standing
	// before anybody sees it.
	get physics() { return renderedPhysics; },

	// The navigation bake of the Scene being rendered, on the same terms.
	// `scene.nav` is the one that belongs to a scene, and baking a scene that is
	// not being rendered is exactly as good as baking one that is — it is
	// voxelization over that scene's own triangles and needs no frame.
	get nav() { return renderedNav; },

	// A trigger overlap started or ended:
	// { type: 'enter' | 'exit', trigger, other }.
	// One handler; binding again replaces, null unbinds, and it is stopped
	// for good if it throws — the same rules onClick follows.
	onTrigger(fn) { setScriptHandler('trigger', fn, 'three.onTrigger'); },

	// Two bodies touched or came apart:
	// { type: 'start' | 'end', a, b, normal, point }.
	// `normal` and `point` mean something on a start and are zero on an end
	// — there is no contact left to describe by then.
	onContact(fn) { setScriptHandler('contact', fn, 'three.onContact'); },

	// The documentation, designed to be READ rather than dumped. With no
	// argument this is the index — everything short in full, and the names of
	// the classes and functions; `{ search }` is the grep over the whole
	// surface, `{ section }` the drill-down, `{ all: true }` the old answer.
	// The prose is Markdown under `docs/`, compiled into the data `docs.js`
	// walks, and the MCP tool calls this rather than reimplementing it, so an
	// agent asking over JSON-RPC and a script asking here read the same docs
	// the same way.
	getApiDocs(options) { return docsQuery(options); },
	searchDocs(term) { return docsSearch(term); },
};

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

// entity.js owns the host's three handler slots so that a rule and a script's
// own handler can both have one. It needs the intersection shaper to answer a
// 'click' rule with what `three.onClick` would have been handed, and the shaper
// is this file's — so it is passed over once here rather than written twice.
setClickShaper(asIntersection);
