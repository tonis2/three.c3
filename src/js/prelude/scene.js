// three.c3 — the Scene class, the one that is rendered, and the lookups that
// resolve host handles against it.

import { Vector3, DEFAULT_BACKGROUND, readColor, readVector } from './math.js';
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

	// The colour every frame starts on.
	//
	// Three.js's name and Three.js's place — it is a property of the Scene
	// there too — but a narrower type: a colour, in any of the spellings
	// `mesh.color` takes, or `null` for the default. Three.js also accepts a
	// Texture or a CubeTexture here and this does not, because there is no
	// environment map anywhere in this project and accepting one to ignore it
	// would be the half-match `plan.md` §4 rules out.
	//
	// A sky that is a *gradient* is still geometry. What this removes is the
	// case that was costing a mesh for no reason: a daylight scene rendering
	// against the default near-black, which is not a sky anyone chose.
	//
	// It reads back as `[r, g, b]` rather than as whatever was assigned,
	// because the components are what the pixel gets — a hex value is
	// converted on the way in and there is no colour management to convert it
	// back through.
	get background() {
		this._check();
		return H.backgroundGet(this._sid);
	}

	set background(v) {
		this._check();
		const c = v === null || v === undefined
			? DEFAULT_BACKGROUND
			: readColor(v, 'scene.background');
		H.backgroundSet(this._sid, c[0], c[1], c[2]);
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
	// Answers with { path, meshes, entries, materials, images, nodes,
	// instances, batches, skipped, shaded, layers, bytes }.
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
		}
		return H.exportScene(path, flatten);
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

// The Scene wrapper for a host id: the one the script built, or a new handle
// onto a scene whose wrapper is gone.
//
// The second case is the one this exists for. A scene built inside a run_script
// scope that then ended is alive, counted, holding its nodes and its asset
// references, and named by nothing — so before this there was no way to dispose
// it and no way to look at it. Now there is.
//
// **An adopted handle is a handle, not the tree.** Its `children` is empty even
// where the host scene has hundreds of nodes, because the objects that made
// them were the previous script's and are gone. What it can do is everything
// that goes through the host: activate, dispose, stats, export, background,
// raycast, pick. What it cannot do is give you back objects nothing kept.
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
// `held` says whether this script still has the Scene object that built it,
// which is the difference between a scene you can reach and one you had lost.
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
// Answers with { scenes, assets, textures, bytes }: how many worlds went, and
// what the sweep afterwards actually gave back. Those are different numbers and
// the second is often zero — two scenes over one kit means disposing either
// frees nothing.
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
