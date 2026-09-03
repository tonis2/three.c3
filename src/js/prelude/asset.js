// three.c3 — Asset and MeshRef: a loaded file and the pieces inside it.

import { refBounds } from './math.js';
import { Geometry } from './geometry.js';
import { Object3D } from './object3d.js';
import { Mesh } from './mesh.js';
import { Texture } from './texture.js';
import { LayeredMaterial } from './layers.js';
import { DoubleSide, FrontSide, MeshLambertMaterial } from './material.js';
import { LinearSRGBColorSpace, SRGBColorSpace, uploadOptions } from './texture.js';

const H = globalThis.__three;

// The extension's `LayerBlendMode` and `LayerMaskChannel`, by ordinal.
//
// **The host sends numbers and this names them**, which puts the authority for
// what an ordinal means in exactly one place — `gltf.c3l`'s own enums, which the
// host passes through untranslated. Naming them there and here would be two
// tables to keep in step; naming them only here means a mode added to the
// extension shows up as `undefined` at this line rather than as a wrong blend
// three layers deep in a generated shader.
// Exported because `layers.js` reads them the other way round — a stack a script
// wrote crosses back to the host as ordinals, so a generated material can be
// exported as the extension it describes. Two readers, still one table.
export const BLEND_BY_ORDINAL = [
	'mix', 'multiply', 'add', 'subtract', 'screen', 'overlay', 'softLight',
	'difference', 'darken', 'lighten',
];
export const CHANNEL_BY_ORDINAL = ['r', 'g', 'b', 'a'];

// `LayerMaskSource`: 0 NONE, 1 TEXTURE, 2 VERTEX_COLOR.
export const MASK_NONE = 0;
export const MASK_TEXTURE = 1;
export const MASK_VERTEX_COLOR = 2;

// A texture slot the host handed back, wrapped so a script holds it the way it
// holds any other image.
//
// The host already retained on the way out, so the Texture built here owns that
// reference and `dispose()` on it means what it means everywhere else. `path` is
// null because these came from inside a `.glb` rather than from a file anyone can
// name — the same answer a DataTexture gives, and for the same reason.
//
// **The colourspace comes off the slot rather than from a rule here.** Every
// other Texture in this API knows its space because the script asked for one;
// nothing asks for these, so the importer decided and the host reports what it
// decided. Assuming "a mask is linear" on this side would make `tex.colorSpace`
// a restatement of an assumption instead of a fact about the image — and would
// make an importer that got it wrong report that it got it right.
// glTF's own four, in `gltf::AlphaMode`'s order. CUTOFF is the library's name
// for a MASK it has already resolved a cutoff for, and reports as MASK here
// because that is the word the spec and every exporter use.
const ALPHA_MODE_BY_ORDINAL = ['OPAQUE', 'BLEND', 'MASK', 'MASK'];

function layerTexture(handle) {
	if (handle === null) return null;
	return new Texture(handle, null, handle[4] === 1 ? LinearSRGBColorSpace : SRGBColorSpace);
}

// A plain object would do for the handle — `Mesh` only checks that `asset`,
// `mesh` and `assetGeneration` are numbers, and a generated `Geometry`
// satisfies the same check. This is a class so that `bounds` can be a getter
// rather than a field: measuring is a crossing into the host, and paying for
// it on every `asset.mesh(...)` when most callers only want to place the
// piece would tax the common path to serve the rarer one.
export class MeshRef {
	constructor(asset, assetGeneration, mesh, name) {
		this.asset = asset;
		this.assetGeneration = assetGeneration;
		this.mesh = mesh;
		this.name = name;
	}

	get bounds() { return refBounds(this, `asset.mesh(${JSON.stringify(this.name)}).bounds`); }

	// What this primitive's glTF material said — everything the loader used to
	// drop on the floor.
	//
	//     { alphaMode, alphaCutoff, doubleSided,
	//       normalMap,
	//       emissive, emissiveMap, emissiveIntensity,
	//       aoMap,
	//       metalness, roughness, metalnessRoughnessMap }
	//
	// The base colour and its map are deliberately NOT in here: the mesh already
	// carries both and a material that names no map draws the mesh's, so
	// restating them would be a second source for one fact. Everything above is
	// what the loader used to drop, and each map arrives with its colourspace
	// already right — normal, occlusion and metallic-roughness are data and load
	// linear, emissive is a colour and loads sRGB. Getting that wrong is the bug
	// `mapped_normal`'s header measures, and it is decided by the importer rather
	// than by you.
	//
	// **This is a description, not a material.** What to build from it is a
	// modelling decision and it is yours:
	//
	//     const d = ref.material;
	//     const m = new three.LayeredMaterial({
	//         normal: d.normalMap,
	//         transparent: d.alphaMode === 'BLEND',
	//         side: d.doubleSided ? three.DoubleSide : three.FrontSide,
	//         layers: d.emissiveMap ? [{ emissive: d.emissiveMap, emissiveFactor: d.emissive }] : [],
	//     });
	//
	// `asset.instantiate({ materials: true })` does exactly that for a whole
	// file, and is the shorter door.
	//
	// **Where each of these goes.** All three maps are properties of a plain
	// `MeshLambertMaterial` now, so a description crosses onto one that compiles
	// nothing:
	//
	//     const m = new three.MeshLambertMaterial({
	//         normalMap: d.normalMap,
	//         metalnessRoughnessMap: d.metalnessRoughnessMap,
	//         aoMap: d.aoMap,
	//         metalness: d.metalness,
	//         roughness: d.roughness,
	//     });
	//
	// The pair the map varies is per material *and* per texel: the numbers are
	// the file's factors and the map multiplies them, which is what glTF says
	// both mean. A `LayeredMaterial` layer takes its own `metallicRoughness`
	// beside these, for a stack that wants one per layer.
	//
	// `metalness` and `roughness` themselves are applied now.
	// `instantiate({ materials: true })` puts them on the material it builds, and
	// they are the file's own numbers — glTF's defaults are 1 and 1, so a file
	// that says nothing about either is a fully metallic surface and will look
	// like one. `scene.environment` is what it reflects.
	//
	// **Reading this uploads the mesh, and every read holds new references**,
	// exactly as `layers` does: the images exist only once the primitive is on the
	// device, and each Texture is a handle of its own. Read it once and keep it.
	//
	// `null` for a primitive that names no material at all, which is a real glTF
	// and means the default one.
	get material() {
		const row = H.meshMaterial(this.asset, this.assetGeneration, this.mesh);
		if (row === null) return null;
		const [
			alphaMode, alphaCutoff, doubleSided, emissiveIntensity,
			er, eg, eb, aoMap, metalness, roughness, normalMap, mrMap, emissiveMap,
		] = row;
		return {
			alphaMode: ALPHA_MODE_BY_ORDINAL[alphaMode] ?? 'OPAQUE',
			alphaCutoff,
			doubleSided,
			normalMap: layerTexture(normalMap),
			emissive: [er, eg, eb],
			emissiveMap: layerTexture(emissiveMap),
			emissiveIntensity,
			aoMap: layerTexture(aoMap),
			metalness,
			roughness,
			metalnessRoughnessMap: layerTexture(mrMap),
		};
	}

	// This mesh's `CUSTOM_materials_layers` stack as a `LayeredMaterial`
	// description, or `null` when its material never carried the extension.
	//
	// `new three.LayeredMaterial(ref.layers)` is the whole import path, and that
	// is the point of handing back a description rather than a material: an
	// imported stack goes through the same constructor, the same validation and
	// the same generator a hand-written one does, so there is one implementation
	// of what a layer means. It also means a script can edit the description
	// before building it — drop a layer, retune an opacity, mark one animated —
	// which is not something a finished material would allow.
	//
	// **Reading this uploads the mesh, and every read holds new references.** A
	// stack is texture slots, slots exist only once the primitive is on the
	// device (see `js_mesh_layers`), and each `Texture` handed back holds a
	// reference of its own exactly as `three.texture()` does — two reads is two
	// sets of handles over the same images. Everything else on a MeshRef is
	// free; read this one once and keep the description.
	//
	// A `null` here and a stack of zero layers are different answers: the first
	// means the file was not authored with the extension, the second means it was
	// and every layer in it is off.
	get layers() {
		const stack = H.meshLayers(this.asset, this.assetGeneration, this.mesh);
		if (stack === null) return null;
		const [mask, rows, height, bumpStrength, bumpDistance] = stack;
		return {
			// Masks are weights rather than colours, so `load_material_layers`
			// uploaded this linear. What comes back says which space it really
			// got rather than which one it should have — see `layerTexture`.
			mask: layerTexture(mask),
			// The base material's relief, under the whole stack. It comes from the
			// extension's `base` object because core glTF has nowhere to put a
			// height map, which is the same reason it arrives here rather than on
			// `ref.material` beside the normal map.
			//
			// Both or neither: `bump` on its own scales a displacement that is not
			// there, and a description carrying it would read as relief the material
			// does not have.
			...(height === null ? {} : {
				height: layerTexture(height),
				bump: { strength: bumpStrength, distance: bumpDistance },
			}),
			layers: rows.map(([
				name, enabled, blend, maskSource, channel, invert, opacity,
				r, g, b, a, er, eg, eb, map, normal, emissive, maskTexture,
				metalness, roughness, metallicRoughness, layerHeight,
				layerBumpStrength, layerBumpDistance,
			]) => ({
				name,
				enabled,
				blend: BLEND_BY_ORDINAL[blend] ?? 'mix',
				// The channel and the thing it is a channel *of* stay two fields, as
				// they are in `LayerMask` and in `LayeredMaterial`. A stack that
				// masks itself with a painted colour attribute therefore imports as
				// what it is, rather than as a shape this side had to invent.
				mask: maskSource === MASK_NONE ? null : CHANNEL_BY_ORDINAL[channel] ?? 'r',
				maskSource: maskSource === MASK_VERTEX_COLOR ? 'vertexColor' : 'texture',
				maskTexture: layerTexture(maskTexture),
				invert,
				// The extension carries a layer's alpha in baseColorFactor.a and its
				// own `opacity` beside it. They multiply — one is the material's
				// transparency and the other is how much of the layer is applied —
				// and folding them here means the generated shader has one number
				// rather than two that always appear together.
				opacity: opacity * a,
				tint: [r, g, b],
				emissiveFactor: [er, eg, eb],
				map: layerTexture(map),
				normal: layerTexture(normal),
				emissive: layerTexture(emissive),
				// The file's own two factors, and the map that varies them per texel.
				//
				// **Omitted where the file left them at glTF's defaults**, which are 1
				// and 1 — and the parser cannot tell a layer that wrote them from one
				// that did not, because the absent value and the written one are the
				// same number. Carried through as stated, a terrain whose layers say
				// nothing about metal would import with every layer fully metallic,
				// which is what a viewer implementing the extension would draw and is
				// not what anybody authored.
				//
				// So the same rule the tint already follows one field up: **a default
				// is not a statement.** A layer that means "fully rough, fully
				// metallic" states it with a map, exactly as a layer that means white
				// paint states it with one. Every exporter that means either writes
				// both factors, so the case this drops is the case nobody wrote.
				...(metallicRoughness === null && metalness === 1 && roughness === 1 ? {} : {
					metalness,
					roughness,
					metallicRoughness: layerTexture(metallicRoughness),
				}),
				// This layer's own relief, over whatever the base already has. Both or
				// neither, for the reason the base pair is.
				...(layerHeight === null ? {} : {
					height: layerTexture(layerHeight),
					bump: { strength: layerBumpStrength, distance: layerBumpDistance },
				}),
			})),
		};
	}

	// Cut this mesh into its connected components and get one geometry per
	// piece.
	//
	// The answer to a kit that arrived as one merged mesh: a town square with
	// 23 buildings in it is one transform and one bounding box until it is cut,
	// so nothing in it can be placed, rotated, culled or picked on its own.
	//
	//     const pieces = kit.mesh('town').split();
	//     pieces.forEach((piece, i) => {
	//         const m = new three.Mesh(piece, material);
	//         m.position.x = i * 4;
	//         scene.add(m);
	//     });
	//
	// Two triangles are in the same piece when they share a vertex, which is
	// the right cut for a merged kit and no cut at all for a surface that is
	// genuinely connected — a terrain with the houses extruded out of it comes
	// back as one piece. Length one means "this was already one thing", and the
	// one geometry you get back is this mesh itself: nothing was uploaded.
	//
	// Each piece is an ordinary geometry: instanced, pickable, exportable and
	// unloadable on its own. It carries the source's colour and its base
	// colour map; it does not carry a layer stack, and a mesh that has one
	// throws rather than losing it quietly — read `ref.layers`, build a
	// `LayeredMaterial` from it and put that on the pieces.
	//
	// **Not free and not automatic.** It reads the geometry back on the host
	// and uploads one asset per piece, so it is a load-time step. Splitting the
	// same mesh twice answers with the same assets rather than uploading a
	// second copy.
	split() {
		const pieces = H.splitMesh(this.asset, this.assetGeneration, this.mesh);
		return pieces.map(([index, generation, mesh], i) => {
			const piece = new Geometry(
				'SplitGeometry',
				`${this.name} piece ${i}`,
				{ of: this.name, piece: i, pieces: pieces.length },
				[index, generation]
			);
			// A generated shape is always mesh 0 and a piece usually is, but the
			// one-component answer is this mesh's own handle — see splitMesh.
			piece.mesh = mesh;
			return piece;
		});
	}

	toJSON() { return { name: this.name, mesh: this.mesh }; }
	toString() { return `MeshRef(${this.name})`; }
}

// The tail of a "no node named X" message. Every name for a small file, and a
// prefix plus a count for a kit — a hundred and forty names is not an error
// message anybody reads, and the first two dozen is enough to see the spelling
// convention and find the typo.
const NAMES_SHOWN = 24;

function nameList(names) {
	if (!names.length) return '(none)';
	if (names.length <= NAMES_SHOWN) return names.join(', ');
	return `${names.slice(0, NAMES_SHOWN).join(', ')} … and ${names.length - NAMES_SHOWN} more`;
}

export class Asset {
	constructor([index, generation]) {
		this._a = index;
		this._g = generation;
		this.path = H.assetPath(index, generation);
		// In load order, which is the order `mesh(name)` resolves in and the
		// order the host's own `find_mesh` walks.
		this.meshes = H.meshNames(index, generation);
		// Names and durations are read out of the JSON chunk at load, so
		// this costs nothing and "does this character have a walk cycle" is
		// a question worth asking before deciding to place it.
		this.animations = H.assetClips(index, generation);
		// The rig's joint names, for `character.socket(name)`. Out of the
		// JSON like the two above, and empty for the vast majority of files
		// that carry no skin. Worth having on the Asset rather than only on
		// an instantiation, because a baked character drops its bone nodes
		// and this is then the only place the names exist.
		this.bones = H.assetBones(index, generation);
		// How many pictures the file holds, for `imageAt`. Out of the JSON as
		// well, so a file whose meshes have never been drawn still answers.
		this.images = H.assetImages(index, generation);
	}

	// The host's flattened node table, kept after the first walk.
	//
	// The three doors that read it — `instantiate`, `node` and `nodes` — asked
	// the host for a fresh array every time, and a kit is where that bites:
	// placing 1,557 pieces out of a 39-node file rebuilt 39 rows of 22 values
	// per placement to read eight of them. The rows depend on the asset and the
	// skeleton flag and on nothing else, and an asset does not change under its
	// handle, so the second ask is the first ask's answer. `_nodeNames` already
	// caches on this object for the same reason; `three.load` of a reloaded path
	// hands back a *fresh* Asset, so a cache on the instance cannot outlive the
	// file it describes.
	//
	// Two entries, because `skeleton` is two different walks: keeping the bone
	// nodes and dropping them are not the same tree.
	//
	// **The liveness check stays on the fast path**, which is the whole reason
	// this is not one line. Asking the host was also what made a handle from
	// before an unload throw, and a cache that skipped the crossing would let a
	// script quietly instantiate a freed asset. `checkAsset` is that same refusal
	// with nothing else attached — one crossing, no allocation, the same
	// sentence.
	//
	// The array never leaves this object: `_build` and `node` read it and nothing
	// hands it to a caller, so there is nobody to mutate the cache from.
	_rows(skeleton) {
		H.checkAsset(this._a, this._g);
		const at = skeleton ? 1 : 0;
		if (!this._nodeRows) this._nodeRows = [null, null];
		if (!this._nodeRows[at]) this._nodeRows[at] = H.assetNodes(this._a, this._g, skeleton);
		return this._nodeRows[at];
	}

	// The names of the file's own nodes, in the order the loader walks them —
	// what `node(name)` takes, and what tells you whether a `.glb` is a kit or a
	// single prop.
	//
	// Read on demand rather than at load, because it is the flattened tree and a
	// file placed for its meshes alone should not pay for one. Cached after the
	// first ask: an Asset's file does not change under it.
	get nodes() {
		if (!this._nodeNames) {
			// Each name once. The walk carries a row per *drawn* thing as well as
			// per node — a group whose glTF mesh has three primitives is a group
			// and three children named after the mesh — and listing `box` ninety
			// times would bury the thirty names somebody is looking for. Every
			// name here is still one `node()` takes; a repeat would not have
			// resolved to anything new, since the first in the walk is the answer.
			const seen = new Set();
			for (const row of this._rows(false)) seen.add(row[0]);
			this._nodeNames = [...seen];
		}
		return this._nodeNames;
	}

	mesh(name) {
		const at = this.meshes.indexOf(name);
		if (at < 0) {
			const have = this.meshes.length ? this.meshes.join(', ') : '(none)';
			throw new Error(`no mesh named "${name}" in ${this.path} — it has: ${have}`);
		}
		return new MeshRef(this._a, this._g, at, name);
	}

	meshAt(i) {
		if (!(i >= 0 && i < this.meshes.length)) {
			throw new RangeError(`mesh index ${i} is outside 0..${this.meshes.length - 1}`);
		}
		return new MeshRef(this._a, this._g, i, this.meshes[i]);
	}

	// One of the file's own images, as an ordinary Texture.
	//
	//     const kit = three.load('kit.glb');
	//     for (let i = 0; i < kit.images; i++) {
	//         const tex = kit.imageAt(i);
	//         console.log(i, tex.width, tex.height);
	//         tex.dispose();
	//     }
	//
	// **The picture the meshes are drawing with**, not a copy of it: an image a
	// placed mesh already uploaded comes back as that very slot, so `read()` on
	// it reads what is on screen. A `.glb`'s images had no handle at all before
	// this — a mesh carried a texture index and nothing wrapped it — so there
	// was nothing for `texture.read()` to be called on.
	//
	// Indexed the way the file numbers its images, so `i` means the same thing
	// here as in any glTF viewer, and means it before anything has been drawn.
	// `asset.images` is how many there are.
	//
	// **It decodes if nothing has yet**, which is the cost worth knowing about:
	// asking for image 0 of a kit nothing has placed does the PNG decode and the
	// upload the first mesh would have done. Asking again is a retain.
	//
	// `colorSpace` decides how the bytes are read and defaults to sRGB, which is
	// right for a picture and wrong for a normal or roughness map — the same
	// choice `three.texture()` takes, and the reason it is a parameter rather
	// than something guessed from the image. Asking for one image in both spaces
	// costs two uploads, because they are two different images.
	//
	// The Texture holds a reference of its own, so `dispose()` on it is safe
	// while meshes go on drawing with the picture, and null comes back for an
	// image this cannot decode — a format `image.c3l` and `ktx.c3l` do not read
	// between them, or a 16-bit PNG.
	imageAt(i, options = null) {
		if (!Number.isInteger(i)) {
			throw new TypeError(`asset.imageAt(i) wants a whole-number index, not ${typeof i}`);
		}
		if (!(i >= 0 && i < this.images)) {
			const have = this.images === 0 ? 'it has no images' : `0..${this.images - 1}`;
			throw new RangeError(`image index ${i} is outside ${have} in ${this.path}`);
		}
		const chosen = uploadOptions(options, 'asset.imageAt(i, options)');
		const handle = H.assetImage(this._a, this._g, i, chosen.code, chosen.mips);
		// Null rather than a throw: an image that will not decode is the same
		// thing the importer already survives by drawing the mesh untextured,
		// and a script walking every image in a kit should not be stopped by one
		// of them being a format nothing here reads.
		if (handle === null) return null;
		// Null path, like every other image that came out of a file rather than
		// from a name somebody could type — `kit.glb#3` is not somewhere to look.
		return new Texture(handle, null, chosen.space);
	}

	// The same reference, once the mesh is actually on the device.
	//
	//     const wall = await kit.meshAsync('wall_corner_02');
	//     scene.add(new three.Mesh(wall));
	//
	// **What this buys is where the stall happens, not whether there is one.**
	// A `.glb` is parsed at `three.load` and its meshes are uploaded one at a
	// time, when something first draws each of them — so `scene.add` of a kit of
	// ninety pieces does ninety uploads inside one frame, and that frame is the
	// one that hitches. Awaiting instead hands the engine a queue it drains a
	// mesh per frame, so the same kit arrives over ninety frames with the game
	// still drawing.
	//
	// Per mesh, deliberately, and not per file: a level needs its floor before
	// it needs the ninetieth crate, and a promise that waited for the whole file
	// could not express that. Ask for what you need first.
	//
	// **In a one-shot script it is not slower than the synchronous path**,
	// because there is no frame to protect: the queue drains as fast as the
	// awaits ask for it. The difference only appears once an animation loop is
	// running.
	//
	// Rejects if the asset is unloaded before its turn comes up, which is the
	// one thing that can happen between the ask and the answer.
	meshAsync(name) {
		const ref = this.mesh(name);
		return new Promise((ok, no) => {
			H.uploadMesh(this._a, this._g, ref.mesh, () => ok(ref), (why) => no(new Error(why)));
		});
	}

	// `meshAt` by index, awaited the same way.
	meshAtAsync(i) {
		const ref = this.meshAt(i);
		return new Promise((ok, no) => {
			H.uploadMesh(this._a, this._g, ref.mesh, () => ok(ref), (why) => no(new Error(why)));
		});
	}

	// `instantiate`, with every mesh in the tree on the device before it
	// resolves — so the `scene.add(root)` that follows uploads nothing.
	//
	//     const level = await kit.instantiateAsync();
	//     scene.add(level);
	//
	// The tree is built immediately and the awaiting is only the uploads, which
	// is why this takes the same arguments and answers with the same object
	// `instantiate` does. A file whose nodes name one mesh many times waits once
	// for it: the queue is asked per distinct mesh, not per node.
	//
	// It resolves when the last of them lands, so a loop that is running keeps
	// drawing throughout — a mesh a frame, `meshAsync`'s arrangement, over as
	// many frames as the file has distinct meshes.
	async instantiateAsync(name, options = undefined) {
		return this._uploaded(this.instantiate(name, options));
	}

	// Every mesh in a tree on the device, then the tree. Shared by the two async
	// doors, which differ only in how much of the file they built.
	async _uploaded(root) {
		const wanted = new Set();
		root.traverse((node) => {
			const ref = node.geometry;
			// A Group has no geometry, and a Mesh over a generated shape has one
			// that belongs to a different asset — neither is ours to upload.
			if (ref && ref.asset === this._a && ref.assetGeneration === this._g) {
				wanted.add(ref.mesh);
			}
		});
		await Promise.all([...wanted].map((mesh) => new Promise((ok, no) => {
			H.uploadMesh(this._a, this._g, mesh, () => ok(mesh), (why) => no(new Error(why)));
		})));
		return root;
	}

	// The file's node hierarchy as an Object3D tree — Three.js's
	// `gltf.scene`. A group, with the file's own nodes under it carrying the
	// transforms the file gave them.
	//
	// Nothing here is special: what comes back is ordinary Object3Ds and
	// Meshes that have not been added to anything yet, so a script can move
	// them, hide them, recolour them or pull one out and add it on its own,
	// and `scene.add()` materializes them by the same path as everything
	// else. That is the reason the host answers with a description instead
	// of building host nodes itself.
	//
	// Call it twice for two copies. They share the upload — the host counts
	// one reference per drawing node, so two trees over one asset is two
	// sets of transforms and nothing else.
	// `skeleton: true` keeps the file's bone nodes as objects. By default they
	// are dropped: a baked character's pose comes out of a table the host
	// uploaded once, so the bones would be sixty objects driving nothing — and
	// dropping them is what makes a hundred characters a hundred nodes instead
	// of six thousand. Keeping them switches the character onto a palette
	// computed from those very nodes every frame, so writing one moves the skin.
	//
	// `skinning: 'compute'` poses the vertices in a compute pass before the
	// frame's first draw instead of in the vertex shader. It splits the character
	// off into a draw call of its own and costs a posed copy of the mesh per
	// instance, and it pays for itself only when the same character is drawn more
	// than once a frame. Not a switch to flip on a crowd.
	instantiate(name, options = undefined) {
		const opt = this._instanceOptions(options);
		const rows = this._rows(opt.skeleton);
		const root = new Object3D();
		// The name is what the tree is *called*, not which part of the file it is.
		// `node(name)` is the one that picks — see it for why the two are separate.
		root.name = name === undefined ? this.path.replace(/^.*[/\\]/, '') : String(name);
		this._carry(root, opt);
		this._build(rows, -1, root, opt);
		return root;
	}

	// One named node of the file, and everything under it, as a tree of its own.
	//
	//     const kit  = three.load('buildings.glb');
	//     const wall = kit.node('wall_stone');
	//     wall.position.set(4, 0, -2);
	//     scene.add(wall);
	//
	// **What makes a kit one file rather than ninety.** `instantiate()` builds the
	// whole file every time, which stamps the entire kit at every placement, and
	// `mesh(name)` reaches a piece only when the piece is a single mesh: an
	// exported mesh takes the name of the node that draws it when exactly one node
	// does, and keeps its geometry's name — `box` — when several nodes share the
	// shape, because one name cannot stand for all of them. A node keeps the name
	// the file gave it whatever the piece is made of, so a node is what a piece of
	// any shape can be.
	//
	// Call it twice for two copies, exactly as `instantiate()` does, and the two
	// share the upload: this is a second set of transforms over the same meshes.
	//
	// The subtree arrives carrying its *own* transform and none of its ancestors'
	// — a piece authored at the origin comes back at the origin whatever the file
	// wrapped it in — because what is being asked for is the piece and not where
	// the kit happened to lay it out.
	//
	// `asset.nodes` is the list of names to pass. A file free to name two nodes
	// the same answers with the first, in the order the file walks.
	//
	// Options are `instantiate()`'s and mean the same things. Animation does too:
	// the subtree root carries the file's clips, and a channel naming a node
	// outside the subtree drives nothing rather than failing.
	node(name, options = undefined) {
		const opt = this._instanceOptions(options);
		const rows = this._rows(opt.skeleton);
		const at = rows.findIndex((row) => row[0] === name);
		if (at < 0) {
			throw new Error(`no node named "${name}" in ${this.path} — it has: ${nameList(this.nodes)}`);
		}
		const root = this._build(rows, at, null, opt);
		this._carry(root, opt);
		return root;
	}

	// `node`, with its meshes on the device before it resolves — `instantiateAsync`
	// for one piece, and the shape a kit wants: await the wall, place the wall.
	async nodeAsync(name, options = undefined) {
		return this._uploaded(this.node(name, options));
	}

	// `{ skeleton, skinning, materials }` as the two instantiating doors read it.
	// One place, so they cannot drift.
	_instanceOptions(options) {
		const { skeleton = false, skinning = 'vertex', materials = false } = options || {};
		return { skeleton: !!skeleton, compute: skinning === 'compute', materials: !!materials };
	}

	// What a tree's root has to carry whether it is the whole file or one node of
	// it: the clips, the asset it came from, and the bone names `socket()` needs.
	_carry(root, opt) {
		// The root is what carries the animations: a clip drives the whole
		// subtree, so root.play('Walk') is the only sensible place to say it.
		root._clips = this.animations;
		root._asset = [this._a, this._g];
		// Carried on the root because `_bindAnimation` is what tells the host, and
		// that runs on the root.
		root._liveSkin = opt.skeleton;
		// For `socket()`, which needs them to say what a rig does have when it
		// is asked for a bone it has not. A baked instantiation drops the bone
		// nodes, so the tree itself cannot answer.
		root._bones = this.bones;
	}

	// The rows as objects. `from` is -1 for the whole file, parenting the roots
	// under `into`, or the row to start at — which becomes the tree's own root and
	// is what comes back.
	//
	// Membership needs no second pass and no set: parents always precede their
	// children in the host's walk, so a row is in the subtree exactly when its
	// parent was built, and `built[parent]` is the whole test.
	_build(rows, from, into, opt) {
		// One material per distinct description, keyed on the mesh index that
		// produced it. Two primitives sharing a glTF material produce equal
		// descriptions but not the same object, so this dedupes on the *shape*
		// rather than on identity — which is what keeps a kit of ninety pieces
		// from compiling ninety shaders that differ in nothing.
		const materialCache = opt.materials ? new Map() : null;
		const built = new Array(rows.length);
		let root = into;
		for (let i = from < 0 ? 0 : from; i < rows.length; i++) {
			const [label, parent, mesh, px, py, pz, ex, ey, ez, sx, sy, sz, qx, qy, qz, qw, gltfNode, r, g, b, a, skin] = rows[i];
			if (from >= 0 && i !== from && !(parent >= 0 && built[parent])) continue;
			const node = mesh < 0
				? new Object3D()
				: new Mesh({ asset: this._a, assetGeneration: this._g, mesh, name: label });
			if (label) node.name = label;
			node.position.set(px, py, pz);
			// The Euler triple is what `node.rotation` reads back as; the
			// quaternion beside it is what the host is actually given,
			// because the two are not the same rotation at gimbal lock.
			// Setting `rotation` clears `_q`, so this order matters.
			node.rotation.set(ex, ey, ez);
			node._q = [qx, qy, qz, qw];
			node.scale.set(sx, sy, sz);
			// Which glTF node this was, so `play` can tell the host what an
			// animation channel's target index became. -1 for the entries
			// the host synthesized, which no channel can name.
			node._gltfNode = gltfNode;
			// Which skin poses it, and how. Replayed by `_materialize`, because a
			// host node does not exist yet and this is the only thing that will
			// remember.
			node._skin = skin;
			node._preskinned = opt.compute && skin >= 0;
			// Only a copy an instanced node placed has anything but white
			// here, and only a Mesh has anywhere to put it — a group's row
			// carries the identity and setting it would define a channel on
			// an object that has none.
			if (mesh >= 0 && !(r === 1 && g === 1 && b === 1 && a === 1)) node.color = [r, g, b, a];
			if (opt.materials && mesh >= 0) {
				const imported = this._importedMaterial(mesh, materialCache);
				if (imported) node.material = imported;
			}
			// The starting row is the tree; everything else hangs off whatever
			// built its parent.
			if (i === from) root = node;
			else (parent < 0 ? into : built[parent]).add(node);
			built[i] = node;
		}
		return root;
	}

	// The material one primitive's glTF material describes, or null when it
	// describes nothing this can build.
	//
	// **Everything here is a modelling decision and it is written down rather
	// than buried**, because "what a glTF material becomes on this side" is the
	// question `plan.md` §2 left open and this is one answer to it, not the
	// answer:
	//
	//  - The normal map goes to `normal`, which is the slot a hand-written
	//    LayeredMaterial puts one in. Same shading path, same code.
	//  - The emissive map and factor become a single layer at zero opacity. A
	//    layer's `opacity` is how much of its *colour* is applied and its
	//    emissive is added regardless, so zero is "add the glow and change
	//    nothing else" — which is what a glTF emissive is.
	//  - `alphaMode: 'BLEND'` becomes `transparent: true`, and MASK does too:
	//    there is no alpha-test path here, and a cutout drawn as a blend is the
	//    nearer of the two wrong answers.
	//  - `doubleSided` becomes `side: three.DoubleSide`.
	//  - `metallicFactor` and `roughnessFactor` go on as `metalness` and
	//    `roughness`, which is what the specular and environment terms read.
	//    **This is the file's numbers and not a guess**, and glTF's defaults for
	//    them are 1 and 1 — so a file that never wrote a `pbrMetallicRoughness`
	//    block imports as a fully metallic surface and looks like one. It is dark
	//    without a `scene.environment`, correctly: a metal is what it reflects.
	//  - Occlusion and the metallic-roughness *map* are not applied. Both shade
	//    on a `MeshLambertMaterial` now, so this is a gap in the importer rather
	//    than in the renderer: applying them here would change what every
	//    existing `{ materials: true }` import looks like, and it wants its own
	//    change with its own before-and-after. `ref.material` hands both over
	//    for a script that wants them today.
	//
	// **Two materials come out of this, and which one is the whole economy of it.**
	// A normal map or a glow needs a generated shading body and so a
	// `LayeredMaterial`; the surface pair does not, because the built-in shader
	// already reads it. So a file whose materials differ only in their PBR numbers
	// — which is most files — gets `MeshLambertMaterial`s, and those compile
	// nothing at all: the pipeline is the one the renderer built at startup. Going
	// through the layered path for two floats would have been a shader per glTF
	// material for a body identical to the built-in one.
	//
	// The normal map no longer *needs* the layered path either — `material.normalMap`
	// is one binding on that same startup pipeline — so a file with a normal map
	// and no glow could stop compiling a shader as well. That is the same
	// deliberate change as the line above and is not this one.
	//
	// A description with none of that in it builds nothing: an opaque,
	// single-sided material with no maps and this renderer's own surface defaults
	// is exactly what the default material already is, and one material per mesh
	// that changes no pixel is a handle per mesh for nothing.
	_importedMaterial(mesh, cache) {
		const d = new MeshRef(this._a, this._g, mesh, '').material;
		if (d === null) return null;

		const transparent = d.alphaMode !== 'OPAQUE';
		const side = d.doubleSided ? DoubleSide : FrontSide;
		const glow = d.emissiveMap !== null
			|| d.emissive[0] > 0 || d.emissive[1] > 0 || d.emissive[2] > 0;
		// Against this renderer's defaults rather than against glTF's, because the
		// question is whether saying it changes anything. `scene/material.c3` has
		// why they are 1 and 0.
		const surface = d.roughness !== 1 || d.metalness !== 0;
		const body = d.normalMap !== null || glow;
		if (!transparent && !d.doubleSided && !body && !surface) return null;

		// The images are handles rather than values, so identity is what the key
		// can be built from — two meshes that resolved the same slot get the same
		// `_index()`.
		const key = [
			transparent, side, d.roughness, d.metalness,
			d.normalMap ? d.normalMap._index() : -1,
			d.emissiveMap ? d.emissiveMap._index() : -1,
			d.emissive.join(','),
		].join('|');
		const hit = cache.get(key);
		if (hit) return hit;

		const built = body
			? new LayeredMaterial({
				normal: d.normalMap,
				transparent,
				side,
				roughness: d.roughness,
				metalness: d.metalness,
				layers: glow
					? [{
						name: 'emissive',
						emissive: d.emissiveMap,
						emissiveFactor: d.emissive,
						opacity: 0,
					}]
					: [],
			})
			: new MeshLambertMaterial({
				transparent,
				side,
				roughness: d.roughness,
				metalness: d.metalness,
			});
		cache.set(key, built);
		return built;
	}

	toJSON() { return { path: this.path, meshes: this.meshes, animations: this.animations, bones: this.bones }; }
}

// -----------------------------------------------------------------------
// Geometry
//
// The shapes Three.js has, with Three.js's constructor signatures, its
// defaults and its orientations: a plane faces +Z, a cylinder's axis is Y, a
// torus lies in the XY plane, a cone points up. `scene/primitive.c3` builds
// them, and says there why the formulas are copied rather than re-derived —
// the winding and the UV layout come along with the positions, and a face
// wound the wrong way is a hole rather than a dark patch.
//
// ## A geometry *is* an asset reference
//
// `new three.BoxGeometry(1, 1, 1)` answers with something carrying `asset`
// and `mesh`, which is exactly what `asset.mesh("wall_corner_02")` answers
// with. `new three.Mesh(...)` takes either and cannot tell them apart, and
// the thesis is intact either way: a script named a shape and got a handle,
// never a vertex.
//
// ## The same numbers are the same asset
//
// A fresh geometry per mesh is the Three.js habit, and here it is free — the
// host keys the built mesh by its parameters, so a thousand identical
// `BoxGeometry`s are one upload and one instanced draw call.
//
