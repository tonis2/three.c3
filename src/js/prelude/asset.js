// three.c3 — Asset and MeshRef: a loaded file and the pieces inside it.

import { refBounds } from './math.js';
import { Geometry } from './geometry.js';
import { Object3D } from './object3d.js';
import { Mesh } from './mesh.js';
import { Texture } from './texture.js';
import { LayeredMaterial } from './layers.js';
import { DoubleSide, FrontSide } from './material.js';
import { LinearSRGBColorSpace, SRGBColorSpace } from './texture.js';

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
	// **What nothing shades yet.** `aoMap` has no built-in term — one line in a
	// `shade` body multiplies by it. `metalness`/`roughness` and their map are
	// blocked rather than missing: the built-in light is one lambert factor with
	// no specular, so there is nothing for a roughness value to feed. They cross
	// because a `ShaderMaterial` body may do something else with them and
	// "we parsed it and threw it away" was the previous answer.
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
		const [mask, rows] = stack;
		return {
			// Masks are weights rather than colours, so `load_material_layers`
			// uploaded this linear. What comes back says which space it really
			// got rather than which one it should have — see `layerTexture`.
			mask: layerTexture(mask),
			layers: rows.map(([
				name, enabled, blend, maskSource, channel, invert, opacity,
				r, g, b, a, er, eg, eb, map, normal, emissive, maskTexture,
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
	instantiate(name, { skeleton = false, skinning = 'vertex', materials = false } = {}) {
		const compute = skinning === 'compute';
		// One material per distinct description, keyed on the mesh index that
		// produced it. Two primitives sharing a glTF material produce equal
		// descriptions but not the same object, so this dedupes on the *shape*
		// rather than on identity — which is what keeps a kit of ninety pieces
		// from compiling ninety shaders that differ in nothing.
		const materialCache = materials ? new Map() : null;
		const rows = H.assetNodes(this._a, this._g, !!skeleton);
		const root = new Object3D();
		root.name = name === undefined ? this.path.replace(/^.*[/\\]/, '') : String(name);
		// The root is what carries the animations: a clip drives the whole
		// subtree, so root.play('Walk') is the only sensible place to say it.
		root._clips = this.animations;
		root._asset = [this._a, this._g];
		// Carried on the root because `_bindAnimation` is what tells the host, and
		// that runs on the root.
		root._liveSkin = !!skeleton;

		const built = [];
		for (const [label, parent, mesh, px, py, pz, ex, ey, ez, sx, sy, sz, qx, qy, qz, qw, gltfNode, r, g, b, a, skin] of rows) {
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
			node._preskinned = compute && skin >= 0;
			// Only a copy an instanced node placed has anything but white
			// here, and only a Mesh has anywhere to put it — a group's row
			// carries the identity and setting it would define a channel on
			// an object that has none.
			if (mesh >= 0 && !(r === 1 && g === 1 && b === 1 && a === 1)) node.color = [r, g, b, a];
			if (materials && mesh >= 0) {
				const built = this._importedMaterial(mesh, materialCache);
				if (built) node.material = built;
			}
			// Parents always precede their children in the host's walk, so
			// `built[parent]` is there by the time it is asked for.
			(parent < 0 ? root : built[parent]).add(node);
			built.push(node);
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
	//  - Occlusion and metallic-roughness are not applied. Nothing shades them —
	//    `ref.material` has both and the reason.
	//
	// A description with none of that in it builds nothing: an opaque,
	// single-sided material with no maps is exactly what the default material
	// already is, and one material per mesh that changes no pixel is a pipeline
	// per mesh for nothing.
	_importedMaterial(mesh, cache) {
		const d = new MeshRef(this._a, this._g, mesh, '').material;
		if (d === null) return null;

		const transparent = d.alphaMode !== 'OPAQUE';
		const side = d.doubleSided ? DoubleSide : FrontSide;
		const glow = d.emissiveMap !== null
			|| d.emissive[0] > 0 || d.emissive[1] > 0 || d.emissive[2] > 0;
		if (!transparent && !d.doubleSided && d.normalMap === null && !glow) return null;

		// The images are handles rather than values, so identity is what the key
		// can be built from — two meshes that resolved the same slot get the same
		// `_index()`.
		const key = [
			transparent, side,
			d.normalMap ? d.normalMap._index() : -1,
			d.emissiveMap ? d.emissiveMap._index() : -1,
			d.emissive.join(','),
		].join('|');
		const hit = cache.get(key);
		if (hit) return hit;

		const built = new LayeredMaterial({
			normal: d.normalMap,
			transparent,
			side,
			layers: glow
				? [{
					name: 'emissive',
					emissive: d.emissiveMap,
					emissiveFactor: d.emissive,
					opacity: 0,
				}]
				: [],
		});
		cache.set(key, built);
		return built;
	}

	toJSON() { return { path: this.path, meshes: this.meshes, animations: this.animations }; }
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
