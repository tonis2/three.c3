// three.c3 — Asset and MeshRef: a loaded file and the pieces inside it.

import { refBounds } from './math.js';
import { Object3D } from './object3d.js';
import { Mesh } from './mesh.js';
import { Texture } from './texture.js';
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
	instantiate(name) {
		const rows = H.assetNodes(this._a, this._g);
		const root = new Object3D();
		root.name = name === undefined ? this.path.replace(/^.*[/\\]/, '') : String(name);
		// The root is what carries the animations: a clip drives the whole
		// subtree, so root.play('Walk') is the only sensible place to say it.
		root._clips = this.animations;
		root._asset = [this._a, this._g];

		const built = [];
		for (const [label, parent, mesh, px, py, pz, ex, ey, ez, sx, sy, sz, qx, qy, qz, qw, gltfNode, r, g, b, a] of rows) {
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
			// Only a copy an instanced node placed has anything but white
			// here, and only a Mesh has anywhere to put it — a group's row
			// carries the identity and setting it would define a channel on
			// an object that has none.
			if (mesh >= 0 && !(r === 1 && g === 1 && b === 1 && a === 1)) node.color = [r, g, b, a];
			// Parents always precede their children in the host's walk, so
			// `built[parent]` is there by the time it is asked for.
			(parent < 0 ? root : built[parent]).add(node);
			built.push(node);
		}
		return root;
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
