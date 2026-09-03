// three.c3 — the Scene class, the one that is rendered, and the lookups that
// resolve host handles against it.

import { Vector3, DEFAULT_BACKGROUND, readColor, readVector } from './math.js';
import { Texture } from './texture.js';
import { Object3D } from './object3d.js';
import { makeScenePhysics } from './physics.js';
import { makeSceneNav } from './nav.js';

const H = globalThis.__three;

// The Scene being rendered, or null before the first `new three.Scene()`.
//
// There can be several — `new three.Scene()` makes one and shows it without
// destroying the one before it — but only one is drawn, stepped and queried at
// a time, and this is that one. It is what makes "the current scene" a thing a
// click can be resolved against without the host being told which scene to use.
export let liveScene = null;

// Every Scene wrapper this script still has a way to reach, by host id.
//
// The wrapper is the only thing that knows a scene's JavaScript side — its
// children, its physics facade, its nav facade — and the host knows nothing
// about any of it. So a scene handed back by `three.sceneById(id)` has to be the
// SAME object the script built where there is one, or `three.sceneById(s.id) === s`
// would be false and two wrappers would be two `children` arrays over one node
// pool.
//
// Strong references, and bounded by the same thing the host list is: an entry
// goes when the scene is disposed. Holding the wrapper cannot keep a scene alive
// that would otherwise have gone, because nothing frees a scene without being
// told to.
const scenesById = new Map();

// The marker that makes the second constructor form unreachable by accident.
// `new three.Scene()` is public and takes no arguments, so a bare array would be
// a way for a typo to build a wrapper around a number that names nothing.
const ADOPT = Symbol('adopt');

// One of the three numbers on a scene's sky, checked so the message names the
// property rather than arriving as a NaN that renders as a black frame.
//
// A NaN reaching the host is the failure worth the check: it multiplies a colour
// to NaN, the attachment writes whatever the hardware does with one, and the
// symptom is a sky that is black or white with nothing anywhere saying which
// line did it.
function readSkyNumber(v, what, signed = false) {
	if (typeof v !== 'number' || !Number.isFinite(v)) {
		throw new TypeError(`${what} wants a finite number, not ${typeof v === 'number' ? v : typeof v}`);
	}
	if (!signed && v < 0) {
		throw new RangeError(`${what} cannot be negative — 0 turns it off`);
	}
	return v;
}

export class Scene extends Object3D {
	constructor(adopt) {
		super();
		// What Object3D.add checks for — see the note there.
		this._isScene = true;
		const claimed = adopt !== undefined && adopt !== null && adopt[0] === ADOPT;
		const [sid, i, g] = claimed ? adopt[1] : H.sceneCreate();
		this._sid = sid;
		this._i = i;
		this._g = g;
		this._name = 'Scene';
		// The sky, cached on this side — `_writeSky` has why the host is written
		// all five fields at once and why this is where the Texture objects live.
		// Null rather than undefined so `scene.background` and `scene.environment`
		// answer before anything has been assigned.
		this._background = null;
		this._environment = null;
		this.physics = makeScenePhysics(this);
		this.nav = makeSceneNav(this);
		scenesById.set(sid, this);
		// A new Scene is made active by the host and is therefore the live one.
		// An adopted one changed nothing — it is a handle onto a scene that was
		// already whatever it was — so it becomes `liveScene` only if it happens
		// to be the scene being rendered.
		if (!claimed || H.sceneActive() === sid) liveScene = this;
	}

	_check() {
		if (!H.sceneAlive(this._sid)) {
			throw new Error('this Scene was disposed — its objects, its bodies and its nav bake are gone');
		}
	}

	// Whether this is the Scene being rendered.
	//
	// Only one is: a scene that is not active is drawn by nothing, stepped by
	// nothing and queried by nothing, which is exactly what makes building the
	// next level while the current one runs cost the frame nothing.
	get isActive() {
		this._check();
		return H.sceneActive() === this._sid;
	}

	// Show this Scene, and stop showing whichever one was.
	//
	// The switch, and what it does *not* do is the point: the scene being left
	// keeps its objects, its bodies and its nav bake, so activating it again
	// brings the world back exactly as it was. Nothing is freed here — that is
	// `dispose()`.
	//
	// The look comes back with it: the background, every light and the shadow
	// settings belong to the scene, so a level looks the way it looked when it
	// was last on screen — a fill light added for one level does not follow you
	// into the next. What does not come back is the camera's attachment — the
	// follow named an object in the scene being left, so it is dropped.
	activate() {
		this._check();
		H.sceneActivate(this._sid);
		liveScene = this;
		return this;
	}

	// Free this Scene and everything in it — the level boundary.
	//
	// Its nodes go, its physics bodies go, its nav bake goes, and the asset
	// references its meshes held are given back. What is actually reclaimed then
	// depends on what else is holding those assets: two scenes over one kit means
	// disposing either frees nothing, which is right.
	//
	// The active Scene cannot be disposed — activate another one first. A frame
	// with no scene to draw is a black window, which reads as the renderer being
	// broken rather than as the script having freed the world it was looking at.
	//
	// Answers with what the sweep gave back, the same report `unload()` does.
	dispose() {
		this._check();
		if (this.isActive) {
			throw new Error(
				'the Scene being rendered cannot be disposed — call activate() on another one first'
			);
		}
		H.sceneDispose(this._sid);
		forgetScene(this);
		return H.unloadUnused();
	}

	// The host's id for this scene — what three.sceneById(id) takes and what
	// three.scenes lists. Read-only: it names a host object, and assigning it
	// would be pointing a wrapper at somebody else's node pool.
	get id() {
		return this._sid;
	}

	add(...objects) {
		this._check();
		return super.add(...objects);
	}

	remove(...objects) {
		this._check();
		return super.remove(...objects);
	}

	// This scene's numbers, which is not always the rendered one's: a script
	// building the next level can watch it grow before showing it.
	stats() {
		this._check();
		return H.stats(this._sid);
	}

	// What every frame starts on: a colour, or an image.
	//
	// Three.js's name and Three.js's place — it is a property of the Scene
	// there too — and now Three.js's two types as well:
	//
	//     scene.background = 0x87ceeb;                      // a colour
	//     scene.background = three.texture('sky.jpg');      // a sky
	//
	// A Texture here is read as an **equirectangular** image: latitude down,
	// longitude across, which is the projection every HDRI on the internet
	// ships in. There is no CubeTexture in this project and
	// `shaders/sky.slang`'s header has the argument for why one 2D image is the
	// whole feature rather than half of it.
	//
	// Assigning an image does not discard the colour and assigning `null` puts
	// the colour back, which is what makes turning a sky off one line.
	//
	// **A background is a backdrop and lights nothing.** What surfaces reflect
	// is `scene.environment`, and the two are separate for Three.js's reason: an
	// interior lit through a window has an environment and a flat wall behind
	// it. Setting both to the same texture is the ordinary outdoor case and is
	// two lines rather than one on purpose.
	//
	// A colour reads back as `[r, g, b]` rather than as whatever was assigned,
	// because the components are what the pixel gets. An image reads back as
	// the very Texture that was assigned.
	get background() {
		this._check();
		return this._background ?? H.backgroundGet(this._sid);
	}

	set background(v) {
		this._check();
		if (v instanceof Texture) {
			this._background = v;
			this._writeSky();
			return;
		}
		const c = v === null || v === undefined
			? DEFAULT_BACKGROUND
			: readColor(v, 'scene.background');
		this._background = null;
		this._writeSky();
		H.backgroundSet(this._sid, c[0], c[1], c[2]);
	}

	// The image surfaces reflect — Three.js's `scene.environment`, and the
	// half of a sky that actually lights anything.
	//
	//     const sky = three.texture('sky.jpg');
	//     scene.background = sky;
	//     scene.environment = sky;
	//
	// **This is what makes `material.metalness` mean something.** A metal
	// reflects and does not scatter, so a metallic surface takes its colour
	// from what is around it — and with nothing around it, the four punctual
	// lights give it a highlight and the rest is black. Set this and it becomes
	// metal.
	//
	// `material.roughness` chooses how blurred the reflection is, by picking a
	// mip level of this image, so a rough metal wants a texture with a mip
	// chain — which is what `three.texture` builds by default.
	//
	// **The reflection only.** A full image-based light also drives the diffuse
	// half from the same picture; this does not, because the diffuse floor here
	// is `three.light.ambient` and adding a second one would light every
	// existing scene twice the moment somebody set a sky.
	//
	// `null` for none, which is what every scene has until this is assigned —
	// so nothing any scene written before this existed draws has changed.
	get environment() {
		this._check();
		return this._environment ?? null;
	}

	set environment(v) {
		this._check();
		if (v !== null && v !== undefined && !(v instanceof Texture)) {
			throw new TypeError(
				'scene.environment wants a Texture — three.texture(path) — or null. A colour is '
				+ 'scene.background, and three.light.ambient is the flat floor under everything.'
			);
		}
		this._environment = v ?? null;
		this._writeSky();
	}

	// How bright the backdrop is drawn, and how much light the scene takes from
	// its environment. Three.js's two names, and two numbers rather than one
	// because they answer different questions: a dim sky behind a bright scene
	// is a look, and so is a bright sky that reflects softly.
	//
	// Both default to 1 and are clamped at 0 — a negative multiplier on a
	// colour is not darker, it is a channel below black that the attachment
	// clamps anyway.
	get backgroundIntensity() {
		this._check();
		return H.skyGet(this._sid)[2];
	}

	set backgroundIntensity(v) {
		this._check();
		this._backgroundIntensity = readSkyNumber(v, 'scene.backgroundIntensity');
		this._writeSky();
	}

	get environmentIntensity() {
		this._check();
		return H.skyGet(this._sid)[3];
	}

	set environmentIntensity(v) {
		this._check();
		this._environmentIntensity = readSkyNumber(v, 'scene.environmentIntensity');
		this._writeSky();
	}

	// Which way the sky is facing, in radians about world Y.
	//
	// **One number, and it turns both.** Three.js has a separate rotation for
	// the background and for the environment; here they are the same value,
	// because a metal reflecting a sky pointing somewhere other than the one on
	// screen is a bug rather than a feature — and turning the sky to put the sun
	// where a level wants it is the request both names exist to serve.
	get environmentRotation() {
		this._check();
		return H.skyGet(this._sid)[4];
	}

	set environmentRotation(v) {
		this._check();
		this._rotation = readSkyNumber(v, 'scene.environmentRotation', true);
		this._writeSky();
	}

	// The five sky fields, written together.
	//
	// One host call because two of the five are counted texture references, and
	// a verb per field would be five places that have to retain and release
	// correctly — `js_sky_set` has the argument. The cached values are this
	// side's, so nothing has to be read back first.
	_writeSky() {
		// The three numbers are read back rather than defaulted, so a wrapper
		// adopting a scene somebody else had already set does not silently reset
		// what it did not touch.
		const held = H.skyGet(this._sid);
		H.skySet(
			this._sid,
			this._background ? this._background._index() : -1,
			this._environment ? this._environment._index() : -1,
			this._backgroundIntensity ?? held[2],
			this._environmentIntensity ?? held[3],
			this._rotation ?? held[4],
		);
	}

	// Empty the scene and give back everything nothing else holds — the
	// level boundary.
	//
	// Not `new three.Scene()`, which also empties the scene but replaces it,
	// so every handle you were holding — including this Scene — starts
	// throwing. This keeps the scene; it is the same object afterwards, with
	// no children.
	//
	// The freeing is deliberately explicit and deliberately not a collector's
	// job: resident memory that depended on when the interpreter felt like
	// running a GC is the worst possible property for the one number a game
	// watches. Answers with what went, and three.stats() is the independent
	// confirmation.
	//
	// An asset you loaded but never added has no references either, so it
	// goes too. To load the next level first, build it in a Scene of its own —
	// its nodes are what hold its assets, so this sweep cannot take them.
	unload() {
		this._check();
		for (const child of [...this.children]) this.remove(child);
		return H.unloadUnused();
	}

	// Write the scene to a `.glb`.
	//
	// The other direction of `three.load`, and the point at which "linked,
	// not duplicated" stops being an internal detail: a thousand walls
	// placed from one kit are a thousand nodes over one mesh in the file,
	// exactly as they are one draw call in the frame. Vertices are written
	// once per (asset, mesh) and referenced; images are written once per
	// unique image, deduplicated across every file they came from by the
	// same content hash the renderer already deduplicates them with.
	//
	// Under `--assets` the path is inside the game directory and cannot
	// climb out of it — the same rule `three.load` follows.
	//
	// Two things are deliberately not in the file:
	//
	// - **Helpers and hidden subtrees.** The export is what the frame
	//   shows; a `.glb` with the debug boxes baked in is a file nobody
	//   wants. `skipped` counts them.
	// - **ShaderMaterials.** A material here is a Slang pipeline and glTF
	//   describes surfaces, not programs. Those meshes are in the file with
	//   the base colour and texture their geometry carries, and `shaded`
	//   counts how many lost a custom shader.
	//
	// **Per-copy colour survives, and so does the draw call.** Sibling
	// copies of one shape are written as a single node carrying an array of
	// transforms — `EXT_mesh_gpu_instancing`, which is standard and which
	// any glTF reader can place — plus a `_COLOR_0` array beside them
	// holding what each copy's `mesh.color` was. A reader that does not
	// know `_COLOR_0` gets the copies in the material's own colour rather
	// than in the wrong place. `batches` counts the nodes written that way.
	//
	// A copy with no sibling drawing the same shape is left alone: it is
	// one draw call however it is written, so it keeps its name, its place
	// in the tree and a material of its own colour. Groups are never
	// collapsed either — what flattens is a run of leaves under one parent,
	// into one node beneath that same parent.
	//
	// **Siblings that share a shape but not a material do not batch**, and
	// they should not: a colour travels per copy in `_COLOR_0`, but a
	// texture, a blend mode, a cull mode and a layer stack have no per-copy
	// channel to travel in. Two materials over one mesh are two draw calls
	// in the frame and two nodes in the file, sharing the geometry either
	// way. So a wall and a window cut from one pane come back as a wall and
	// a window.
	//
	// **`{ flatten: true }` batches copies that are not siblings**, which is
	// the ones `asset.instantiate()` makes: an instantiated subtree arrives
	// wrapped in a group of its own, so no two of them share a parent and the
	// sibling rule never compares them. Untinted that costs nothing — the
	// geometry is shared across the whole scene either way — but a tint has
	// to travel per copy, so six colours become six materials and six draw
	// calls without it.
	//
	// It is off by default because it gives up the hierarchy: every drawing
	// node is taken in world space and written under one root, so the groups
	// and the names of the copies inside them are gone. Leave it off for a
	// file a person will open; turn it on for a file that is a payload.
	//
	// **Characters go out rigged.** A skinned copy is written with a
	// skeleton of its own, a skin naming those joints, and the
	// asset's clips as glTF animations driving them — read back out
	// of the source file, because a rig does not survive as far as a
	// frame. The skeleton is the file's bind pose rather than the
	// pose the copy is standing in, which is the one thing this gives
	// up: a character mid-stride exports standing, with the stride
	// beside it as a clip. `skins`, `bones` and `clips` count what
	// went in.
	//
	// One skeleton per copy, and that is glTF's rule rather than a
	// choice — a reader ignores a skinned node's own transform, so a
	// copy is placed by where its joints are and two copies cannot
	// share a set of them. The vertices, the inverse bind matrices
	// and the keyframes are still written once between them.
	//
	// **Blend shapes go out too**, as morph targets on the primitive,
	// with each copy's weights on its own node — the per-copy channel
	// glTF has for them. Twelve plants at twelve growth stages come
	// back as twelve nodes over one mesh, the way they were drawn.
	// `morphed` counts the copies that carried any.
	//
	// A skinned or morphing copy is never folded into an instanced
	// node: `EXT_mesh_gpu_instancing` has an attribute for a
	// transform and one for a colour, and none for a pose or a
	// weight.
	//
	// Answers with { path, meshes, entries, materials, images,
	// compressedImages, nodes, instances, batches, skipped, shaded,
	// bakedImages, bakedColors, layers, skins, bones, clips, morphed,
	// bytes }.
	//
	// `textures` says what the pictures the scene *made* are encoded
	// as — a bake, a DataTexture, anything read back off the device.
	// One that came out of a file is copied byte for byte whichever is
	// asked for, so this never re-encodes an artist's own compression.
	//
	// 'png' is the default and is exact and universal. 'ktx2' is BC7
	// blocks with a mip chain, which this engine uploads without
	// decoding — fast to load and a quarter of the VRAM, under our own
	// CUSTOM_texture_ktx2. 'basis' is ETC1S under KHR_texture_basisu,
	// which every other glTF toolchain reads: a fifth of BC7's size,
	// visibly lossy, and slow to load back here. compressedImages
	// counts what either of them managed, which can be fewer than
	// images — an encode that refuses falls back to PNG rather than
	// failing the export.
	//
	// Both are build steps: BC7 saturates every core and still takes
	// around half a minute for a 2048 square.
	//
	// `bake` is the option that gets a ShaderMaterial's shading into
	// the file. glTF describes surfaces and a ShaderMaterial is a
	// program, so without it every mesh drawn under one exports with
	// whatever base colour its geometry happened to carry — for a
	// scene whose whole character is its shaders, a correct file in a
	// single grey.
	//
	// With it, each body is run over its mesh's own uv layout and read
	// back: it becomes a baseColorTexture where the answer varies
	// across the surface and a baseColorFactor where it does not, and
	// a body that discards comes back as the shape it cut rather than
	// as the quad it cut it from. `true` bakes at 512 texels a side; a
	// number picks another, 16 to 4096. It is unlit on purpose — a
	// viewer lights what it loads, and a baked-in sun would be applied
	// twice.
	//
	// It needs a GPU, which the rest of export does not, and it costs
	// a render and a readback per material. bakedImages and
	// bakedColors say what it managed; whatever is left is in shaded.
	//
	// `layers` counts CUSTOM_materials_layers records written. Both
	// kinds of stack go back into one: an imported stack is read from
	// the .glb it came from, a LayeredMaterial from the description it
	// was built with. The material is still a generated shader either
	// way, so it is still counted in `shaded` — the two numbers answer
	// different questions.
	export(path, options) {
		this._check();
		if (typeof path !== 'string' || path.length === 0) {
			throw new TypeError('scene.export(path) wants a path to write a .glb to');
		}
		let flatten = false;
		let bake = 0;
		let textures = 0;
		if (options !== undefined && options !== null) {
			if (typeof options !== 'object') {
				throw new TypeError('scene.export(path, options) wants an object for its options, like { flatten: true }');
			}
			if (options.flatten !== undefined) {
				if (typeof options.flatten !== 'boolean') {
					throw new TypeError('scene.export options.flatten is true or false');
				}
				flatten = options.flatten;
			}
			if (options.bake !== undefined && options.bake !== false) {
				if (options.bake === true) {
					bake = 512;
				} else if (typeof options.bake === 'number' && Number.isFinite(options.bake)) {
					bake = Math.round(options.bake);
					if (bake < 16 || bake > 4096) {
						throw new RangeError(
							'scene.export options.bake is a size in texels from 16 to 4096, or true for 512; got ' + options.bake
						);
					}
				} else {
					throw new TypeError(
						'scene.export options.bake is true, false, or a size in texels from 16 to 4096'
					);
				}
			}
			if (options.textures !== undefined) {
				// The host takes a number and not the word, so the three
				// spellings are settled here — one place that knows the
				// order, rather than a string parsed on the other side.
				const formats = { png: 0, ktx2: 1, basis: 2 };
				if (!Object.prototype.hasOwnProperty.call(formats, options.textures)) {
					throw new TypeError(
						"scene.export options.textures is 'png', 'ktx2' or 'basis'; got " +
							JSON.stringify(options.textures)
					);
				}
				textures = formats[options.textures];
			}
		}
		return H.exportScene(path, flatten, bake, textures);
	}

	// -------------------------------------------------------------------
	// Picking
	//
	// Not Three.js's `Raycaster`, and named so. `intersectObjects` answers
	// with a sorted array of every intersection and takes the objects to
	// consider; this answers with the closest drawable hit in the whole
	// scene, or null. An array that never held more than one element would
	// be a fact about this implementation wearing Three.js's name — which
	// is the half-match `plan.md` §4 says is worse than a new name.

	// What a world-space ray hits. The direction need not be normalised;
	// `distance` comes back in world units either way, so hits on
	// differently scaled objects compare directly.
	raycast(origin, direction) {
		this._check();
		const o = readVector(origin, 'scene.raycast(origin, direction)');
		const d = readVector(direction, 'scene.raycast(origin, direction)');
		return this._intersection(H.raycast(o[0], o[1], o[2], d[0], d[1], d[2]));
	}

	// What is under a pixel of the rendered image — (0, 0) is its top-left
	// corner, the same corner the PNG starts at, and three.renderSize()
	// says how big it is. Invisible objects and anything under an invisible
	// parent are skipped: picking what cannot be seen is never what was
	// meant.
	pick(x, y) {
		this._check();
		if (!(Number.isFinite(+x) && Number.isFinite(+y))) {
			throw new TypeError('scene.pick(x, y) wants two pixel coordinates');
		}
		return this._intersection(H.pick(+x, +y));
	}

	// A host hit becomes the object the script is holding. The search is a
	// walk rather than a lookup table because a table would have to be kept
	// in step with every add, remove and re-parent, and a picked hit is one
	// per user gesture — the walk is not the expensive part of a raycast.
	//
	// `object` is null only for a node this scene did not build: `three
	// <file.glb>` opens one from the command line, and `name` is what
	// identifies it then.
	_intersection(raw) {
		if (raw === null) return null;
		// `object` is a LAZY getter — see lazyObject. It used to walk the whole
		// scene here, which made a pick 79 us in a 500-node scene against 0.5 us
		// for the raycast itself: a hundred agents casting one ground ray apiece
		// was eight milliseconds of finding JavaScript objects nobody looked at.
		// That is `plan.md` §17's entry arriving one layer above where it was
		// fixed.
		const hit = {
			name: raw.name,
			distance: raw.distance,
			point: new Vector3(null, raw.point[0], raw.point[1], raw.point[2]),
			normal: new Vector3(null, raw.normal[0], raw.normal[1], raw.normal[2]),
		};
		return lazyObject(hit, 'object', Int32Array.from(raw.node), 0);
	}
}

// -----------------------------------------------------------------------
// The scenes that exist

// Empties a wrapper whose host scene has gone. Every field a live Scene is
// identified by, so a handle held past a dispose throws the sentence rather
// than resolving into a reused slot.
function forgetScene(scene) {
	scenesById.delete(scene._sid);
	scene.children.length = 0;
	scene._i = -1;
	scene._g = -1;
	if (liveScene === scene) liveScene = null;
}

// The Scene wrapper for a host id: the one a script built, or a new handle onto
// a scene no script ever wrapped.
//
// The second case is the one this exists for. The scene the process starts with
// is alive, counted, drawn, and named by nothing on this side, so before this
// there was no way to activate it back or dispose it. Now there is.
//
// A scene a *script* built is not that case, however long ago it built it:
// `scenesById` holds it until it is disposed, so this gives back the same object
// with its `children` intact. That is what makes identity survive the end of the
// run_script that built it.
//
// **An adopted handle is a handle, not the tree.** Its `children` is empty even
// where the host scene has hundreds of nodes, because those nodes are the host's
// and no `Object3D` was ever made for them. What it can do is everything that
// goes through the host: activate, dispose, stats, export, background, raycast,
// pick. What it cannot do is give you back objects that never existed here.
export function sceneForId(id) {
	const sid = +id;
	if (!Number.isInteger(sid)) {
		throw new TypeError('three.sceneById(id) wants a scene id — three.scenes lists them');
	}
	const held = scenesById.get(sid);
	if (held !== undefined) return held;

	const found = H.sceneIds().find(([each]) => each === sid);
	if (found === undefined) {
		throw new Error(`there is no scene ${sid} — three.scenes lists the ones there are`);
	}
	return new Scene([ADOPT, found]);
}

// What is alive, in the order the host holds them.
//
// `id` is what three.sceneById(id) takes; `active` is the one being rendered;
// `held` says whether a Scene wrapper exists for it here, which is the
// difference between three.sceneById(id) giving back the tree and giving back a
// bare handle. It stays true once true — the registry is bounded by dispose,
// not by the script that built it — so false is a scene nothing here ever
// wrapped, which the startup scene is until somebody looks it up.
// `nodes` is there because a leaked scene and an empty one look identical
// without it.
export function sceneOverview() {
	const active = H.sceneActive();
	return H.sceneIds().map(([id]) => ({
		id,
		active: id === active,
		held: scenesById.has(id),
		nodes: H.stats(id).nodes,
	}));
}

// Free every scene except the one being rendered, then sweep.
//
// The level transition without the step that gets forgotten. Disposing the
// active scene is refused by the host, so this cannot leave the frame with
// nothing to draw however many scenes it walks — activate the one you want
// first, and this is the rest of it.
//
// Answers with { scenes, assets, meshes, textures, bytes }: how many worlds
// went, and what the sweep afterwards actually gave back. Those are different
// numbers and the second is often zero — two scenes over one kit means
// disposing either frees nothing, and `bytes` counts textures alone, so a sweep
// that gave back only geometry reads zero as well.
export function disposeInactiveScenes() {
	const scenes = H.disposeInactive();
	for (const held of [...scenesById.values()]) {
		if (!H.sceneAlive(held._sid)) forgetScene(held);
	}
	return { scenes, ...H.unloadUnused() };
}

// -----------------------------------------------------------------------
// Assets

// A loaded file. The handle is two numbers, not one: which slot the host
// filed it in, and which occupant of that slot it is. Slots are reused after
// an unload, so an index on its own could name a different file than the one
// that was loaded — the generation is what makes a stale reference throw a
// sentence instead of quietly placing somebody else's mesh.
// What `asset.mesh(name)` answers with: the handle, plus the one question
// worth asking about a piece before placing it.
// The handle a host verb wants, having checked the object is one this scene
// can still reach. A body needs a world position, so an object that has not
// been added has nowhere to put one.
export function liveObject(object, where) {
	if (object === null || object === undefined || typeof object._i !== 'number') {
		throw new TypeError(`${where}(object) wants a scene object`);
	}
	if (object._i < 0) {
		throw new Error(
			`${where}: add the object to the scene first — a body is placed at a world position, `
			+ 'and an object that is not in the scene does not have one yet'
		);
	}
	return [object._i, object._g];
}

// A node handle, resolved on FIRST ACCESS rather than eagerly.
//
// Turning a handle back into the Object3D a script built means walking the
// scene — there is no lookup table, because one would have to be kept in step
// with every add, remove and re-parent. Measured: `scene.traverse` over a
// 501-node scene is **79 us** in QuickJS, against 0.5 us for the host raycast
// underneath it. So the walk is not a detail of the answer, it IS the answer's
// cost, and it is paid for a property most callers never read: a character
// reads `grounded` sixty times a second and looks at what it hit almost never.
//
// The result reads exactly as it did — `hit.object` is still a property — and
// a caller that does read it pays what it always cost. What changes is that a
// caller that does not pays nothing.
export function lazyObject(target, key, pairs, at) {
	let resolved;
	let done = false;
	Object.defineProperty(target, key, {
		enumerable: true,
		get() {
			if (!done) { resolved = objectsForHandles(pairs, pairs.length / 2)[at]; done = true; }
			return resolved;
		},
	});
	return target;
}

// Many handles at once, resolved in ONE walk of the scene.
//
// `objectForHandle` below traverses the whole tree per handle, which is the
// right trade for a pick (one handle, and no table to keep in step). A bulk
// query answers with hundreds, and hundreds of walks over a five-hundred-node
// scene is the cost the query was built to remove, arriving one layer up.
//
// The key packs the pair into one number: both halves are below 2^31 and the
// product is under 2^53, so it is exact.
//
// `pairs` is an Int32Array of [index, generation, ...] as the host wrote it.
// Handles the walk cannot place come back as null — a node the host knows and
// this scene never built an object for, which is every node of a scene opened
// from the command line.
export function objectsForHandles(pairs, count) {
	if (count <= 0) return [];
	if (liveScene === null || !liveScene.isActive) return new Array(count).fill(null);

	const wanted = new Map();
	for (let i = 0; i < count; i++) {
		// A negative index is the host's spelling of "nothing here" — a move
		// that hit no wall, a sweep that touched nothing. Skipped rather than
		// looked for, and if they are ALL absent the walk is skipped entirely:
		// a traverse of a five-hundred-node scene to find nothing is the
		// commonest single call this makes, once per character per frame.
		if (pairs[i * 2] < 0) continue;
		wanted.set(pairs[i * 2] * 4294967296 + pairs[i * 2 + 1], i);
	}

	const found = new Array(count).fill(null);
	if (wanted.size === 0) return found;

	let left = wanted.size;
	liveScene.traverse(o => {
		if (left === 0) return;
		const at = wanted.get(o._i * 4294967296 + o._g);
		if (at === undefined) return;
		found[at] = o;
		left--;
	});
	return found;
}

// A [x, y, z] handle from the host, back to the object a script is holding.
// The same walk `_intersection` does and for the same reason: a lookup table
// would have to be kept in step with every add, remove and re-parent.
export function objectForHandle(handle) {
	if (!handle) return null;
	if (liveScene === null || !liveScene.isActive) return null;
	const [i, g] = handle;
	let found = null;
	liveScene.traverse(o => { if (found === null && o._i === i && o._g === g) found = o; });
	return found;
}
