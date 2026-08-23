// three.c3 — the one live Scene, and the lookups that resolve host handles
// against it.

import { Vector3, DEFAULT_BACKGROUND, readColor, readVector } from './math.js';
import { Object3D } from './object3d.js';

const H = globalThis.__three;

// The one live Scene, or null before the first `new three.Scene()`. There is
// only ever one — a second replaces the first and the epoch check above says
// so — which is what makes "the current scene" a thing a click can be
// resolved against without the host being told which scene to use.
export let liveScene = null;

export class Scene extends Object3D {
	constructor() {
		super();
		liveScene = this;
		// What Object3D.add checks for — see the note there.
		this._isScene = true;
		this._e = H.reset();
		const [i, g] = H.root();
		this._i = i;
		this._g = g;
		this._name = 'Scene';
	}

	_check() {
		if (this._e !== H.epoch()) {
			throw new Error('this Scene was replaced by a later new three.Scene() — there is one scene at a time');
		}
	}

	add(...objects) {
		this._check();
		return super.add(...objects);
	}

	remove(...objects) {
		this._check();
		return super.remove(...objects);
	}

	stats() {
		this._check();
		return H.stats();
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
		return H.backgroundGet();
	}

	set background(v) {
		this._check();
		const c = v === null || v === undefined
			? DEFAULT_BACKGROUND
			: readColor(v, 'scene.background');
		H.backgroundSet(c[0], c[1], c[2]);
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
	// goes too. Load the next level after this call, not before it.
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
	// instances, batches, skipped, shaded, bytes }.
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
		const [i, g] = raw.node;
		let object = null;
		this.traverse(o => { if (object === null && o._i === i && o._g === g) object = o; });
		return {
			object,
			name: raw.name,
			distance: raw.distance,
			point: new Vector3(null, raw.point[0], raw.point[1], raw.point[2]),
			normal: new Vector3(null, raw.normal[0], raw.normal[1], raw.normal[2]),
		};
	}
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

// A [x, y, z] handle from the host, back to the object a script is holding.
// The same walk `_intersection` does and for the same reason: a lookup table
// would have to be kept in step with every add, remove and re-parent.
export function objectForHandle(handle) {
	if (!handle) return null;
	if (liveScene === null || liveScene._e !== H.epoch()) return null;
	const [i, g] = handle;
	let found = null;
	liveScene.traverse(o => { if (found === null && o._i === i && o._g === g) found = o; });
	return found;
}
