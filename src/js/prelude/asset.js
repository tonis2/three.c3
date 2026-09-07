// three.c3 — Asset and MeshRef: a loaded file and the pieces inside it.

import { refBounds } from './math.js';
import { Geometry } from './geometry.js';
import { Object3D } from './object3d.js';
import { Mesh } from './mesh.js';
import { Texture } from './texture.js';
import { DoubleSide, FrontSide, MeshLambertMaterial } from './material.js';
import { LinearSRGBColorSpace, SRGBColorSpace, uploadOptions } from './texture.js';
// The one import that points back at a module which imports this one. It is
// read inside a method rather than at the top level — `_layeredMaterial` runs
// long after both modules are evaluated — which is what makes the cycle a
// non-event: `layers.js` reads this file's three ordinal tables the same way.
import { LayeredMaterial } from './layers.js';
// The second import that points back at a module which imports this one, and
// read the same way: `three.lights` and `three.camera` are touched inside
// `instantiate`, long after both modules have evaluated. Nothing at this file's
// top level reads it, which is what makes the cycle a non-event.
import { three } from './api.js';

const H = globalThis.__three;

// `gltf::LightType`, by ordinal. The host passes the extension's own enum
// through untranslated and this names it, for `BLEND_BY_ORDINAL`'s reason.
const LIGHT_BY_ORDINAL = ['directional', 'point', 'spot'];

// `AssetShape`'s order, written out here the way `LIGHT_BY_ORDINAL` writes out
// the light types: the host passes the ordinal through untranslated and this is
// the one place the two tables have to agree.
const COLLIDER_BY_ORDINAL = ['mesh', 'hull', 'box', 'sphere', 'capsule', 'cylinder'];

// What each of them becomes in the solver. A mesh and a convex hull are both
// `hull` there — the solver holds no triangle mesh, so the file's triangles are
// collision geometry for every sweep and every raycast and their convex hull is
// what a body rests on.
//
// A **cylinder** is `hull` as well, and that is the nearest thing this solver can
// hold: it has a box, a sphere, a capsule, a hull and a heightfield, and of those
// only a hull has flat ends and a round side. It is the hull of the *proxy*, which
// is the lathe built from the file's own height and radii, so a sixteen-sided drum
// rather than a capsule with the corners rounded off — a shape that is right
// everywhere except between two facets. A capsule wearing the name would be wrong
// at the rim, which is the only place a cylinder is ever stood on.
const SOLVER_SHAPE = {
	mesh: 'hull', hull: 'hull', box: 'box', sphere: 'sphere', capsule: 'capsule', cylinder: 'hull',
};

// ---- The file's intensities, in Blender's units -----------------------------
//
// **The convention is Blender's, and it is arithmetic rather than taste.** glTF
// measures a directional light in lux and a point light in candela; Blender's
// exporter writes neither — it writes the lamp's own Watts — so Blender's own
// shading is the only place those Watts already mean something, and converting
// out of it is division and nothing else.
//
// A **sun** of S W/m² lights a white diffuse face to S/pi, which is Lambert's
// 1/pi and the whole of the first factor.
//
// A **point** lamp of P W delivers P/(4 pi² d²) at d metres — 4 pi for the
// sphere it radiates into and pi again for the same Lambert term — and that is a
// number this renderer already speaks: `lambert` sums `colour * intensity * n·l`
// and `light_toward` in `shaders/surface.slang` falls off inverse-square from one
// metre, so `intensity = P/(4 pi²)` *is* the brightness at one metre and the
// falloff does the rest of the distance. There is no anchor and nothing to tune:
// 2.2 W of sun arrives as 0.700, a 45 W lantern as 1.140, a 60 W one as 1.520.
const DIRECTIONAL_FROM_WATTS = 1 / Math.PI;
const POINT_FROM_WATTS = 1 / (4 * Math.PI * Math.PI);

// Where a point light stops when the file names no `range`. glTF's answer for an
// absent range is "infinite", which a windowed falloff has no way to draw; EEVEE's
// is `light_threshold`, the illumination it stops tracing a lamp below, and its
// default is 0.01. So the reach is where `intensity / d²` falls under it —
// `sqrt(intensity / 0.01)`, 10.7 m for a 45 W lantern and 12.3 m for a 60 W one.
const LIGHT_THRESHOLD = 0.01;

// What an imported material's `reflectance` is, against 0 for one a script wrote.
//
// **Because glTF does state it.** The specification fixes a dielectric's F0 at
// 0.04 and offers no slot to say otherwise, so every material in every file is
// one — and 0.5 is Filament's spelling of that 4%, which is the mapping
// `specular()` in `shaders/surface.slang` already uses. The default stays 0 for a
// scripted material, where nothing has said anything; `scene/material.c3` carries
// that half of the argument.
const IMPORTED_REFLECTANCE = 0.5;

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
	//       metalness, roughness, metalnessRoughnessMap,
	//       repeat, offset }
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
	// `repeat` and `offset` are the file's `KHR_texture_transform`, under the
	// names of the two properties they go on. **One pair for the whole material**,
	// not one per map: glTF puts a transform on every `textureInfo` separately and
	// there is one uv here, so `scene/asset.c3` takes the base colour map's and
	// warns by name when the maps disagree. `[1, 1]` and `[0, 0]` for a file that
	// wrote none, which is what either setter reads as the identity. A rotation is
	// dropped — nothing here turns a uv — and is warned about by name too.
	//
	// It is the whole of why one plane is a ground: a level authored in Blender
	// tiles its terrain with a Mapping node, and without this every surface in the
	// file draws one stretched copy of its texture.
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
			repeatU, repeatV, offsetU, offsetV,
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
			repeat: [repeatU, repeatV],
			offset: [offsetU, offsetV],
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
				uvScaleU, uvScaleV, uvOffsetU, uvOffsetV,
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
				// This layer's `KHR_texture_transform`, **as the step from the base
				// material's** rather than as the file's own numbers — which is what
				// `uvScale` and `uvOffset` mean here, because the base's transform is
				// already on `s.uv` before a layer's uv is computed. So the pair to set
				// beside this description is `material.repeat` and `material.offset`
				// from `ref.material`, and `instantiate({ materials: true })` is what
				// does both.
				uvScale: [uvScaleU, uvScaleV],
				uvOffset: [uvOffsetU, uvOffsetV],
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

// One imported stack as a string, so that two meshes wearing one glTF material
// build one material.
//
// **Every image becomes the slot it resolved to.** A Texture is a handle and each
// read of a stack makes new ones, so two descriptions of one material are equal in
// every value and identical in none of their objects — the slot index is the thing
// that is actually the same. Everything else about a layer is a number, a string
// or a boolean and stringifies as itself.
function stackSignature(options) {
	const at = (texture) => (texture ? texture._index() : -1);
	return JSON.stringify({
		...options,
		// **Out of the key deliberately.** The name is what a shed-map warning
		// calls this material and it is the *mesh's*, so two meshes wearing one
		// glTF material carry two of them — leaving it in would compile the same
		// stack twice and name the second one differently for no picture.
		name: undefined,
		mask: at(options.mask),
		height: at(options.height),
		normal: at(options.normal),
		metalnessRoughnessMap: at(options.metalnessRoughnessMap),
		aoMap: at(options.aoMap),
		emissiveMap: at(options.emissiveMap),
		layers: options.layers.map((layer) => ({
			...layer,
			map: at(layer.map),
			normal: at(layer.normal),
			emissive: at(layer.emissive),
			maskTexture: at(layer.maskTexture),
			metallicRoughness: at(layer.metallicRoughness),
			height: at(layer.height),
		})),
	});
}

// Every image one stack description holds, for a caller that has decided not to
// keep it. The core material's own maps are deliberately not in here: when a
// stack is refused the plain path is built out of those very textures.
function stackTextures(stack) {
	const all = [stack.mask, stack.height];
	for (const layer of stack.layers) {
		all.push(layer.map, layer.normal, layer.emissive, layer.maskTexture,
			layer.metallicRoughness, layer.height);
	}
	return all.filter((texture) => texture instanceof Texture);
}

// The tail of a "no node named X" message. Every name for a small file, and a
// prefix plus a count for a kit — a hundred and forty names is not an error
// message anybody reads, and the first two dozen is enough to see the spelling
// convention and find the typo.
const NAMES_SHOWN = 24;

// The Scene an object is in, or null when the tree has not been added to one.
// By marker rather than `instanceof Scene`, for `Object3D.add`'s reason: the
// class lives in a module that imports this one.
function sceneRoot(object) {
	let top = object;
	while (top.parent) top = top.parent;
	return top._isScene === true ? top : null;
}

// Whether an object sits at the same place with a different parent — nothing
// between it and the scene root turns, moves or scales it.
function isPlain(object) {
	const { position: p, rotation: r, scale: s } = object;
	if (p.x !== 0 || p.y !== 0 || p.z !== 0) return false;
	if (s.x !== 1 || s.y !== 1 || s.z !== 1) return false;
	if (r.x !== 0 || r.y !== 0 || r.z !== 0) return false;
	const q = object._q;
	return !q || (q[0] === 0 && q[1] === 0 && q[2] === 0 && q[3] === 1);
}

// Whether this object can become a direct child of the scene without moving,
// which is what the solver requires of a body — world space has to be what a
// body's transform is measured from. True when it is one already, or when
// everything between it and the root is at identity; false when the move would
// take the object somewhere else, which is a body the caller has to report.
function canStandAtRoot(object, scene) {
	if (object.parent === scene) return true;
	for (let up = object.parent; up && up !== scene; up = up.parent) {
		if (!isPlain(up)) return false;
	}
	return true;
}

// `to` ends up where `from` is. The quaternion goes last, because writing the
// Euler triple clears it.
function copyPlacement(to, from) {
	to.position.set(from.position.x, from.position.y, from.position.z);
	to.rotation.set(from.rotation.x, from.rotation.y, from.rotation.z);
	to._q = from._q ? [...from._q] : null;
	to.scale.set(from.scale.x, from.scale.y, from.scale.z);
}

function nameList(names) {
	if (!names.length) return '(none)';
	if (names.length <= NAMES_SHOWN) return names.join(', ');
	return `${names.slice(0, NAMES_SHOWN).join(', ')} … and ${names.length - NAMES_SHOWN} more`;
}

// Squared distance between two triples. Squared because the only thing that
// reads it is a sort, and a sort does not care.
function sqDistance(a, b) {
	const dx = a[0] - b[0], dy = a[1] - b[1], dz = a[2] - b[2];
	return dx * dx + dy * dy + dz * dz;
}

// How far a camera node's up is wound around its own view direction, in
// degrees — `three.camera.roll`.
//
// The host builds a rolled up vector as `level * cos(roll) + sideways *
// sin(roll)` with `sideways` the flattened right and `level` the un-rolled up
// (`Camera.up` in `scene/camera.c3`), so the two dot products are the cosine and
// the sine and `atan2` is the angle. A camera looking straight down has no
// flattened right to measure against; zero is the answer there, and it is also
// the answer for every camera authored level.
function rollOf(forward, up) {
	const [fx, fy, fz] = forward;
	let sx = -fz, sy = 0, sz = fx;
	const len = Math.hypot(sx, sy, sz);
	if (len < 1e-6) return 0;
	sx /= len; sy /= len; sz /= len;
	const lx = sy * fz - sz * fy, ly = sz * fx - sx * fz, lz = sx * fy - sy * fx;
	const sine = up[0] * sx + up[1] * sy + up[2] * sz;
	const cosine = up[0] * lx + up[1] * ly + up[2] * lz;
	return Math.atan2(sine, cosine) * 180 / Math.PI;
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
	_rows(skeleton, physics = false) {
		H.checkAsset(this._a, this._g);
		// Four entries, because the walk depends on two flags and on nothing
		// else: keeping the bone nodes or dropping them, and letting the file's
		// colliders decide the index or leaving every mesh in it.
		const at = (skeleton ? 1 : 0) + (physics ? 2 : 0);
		if (!this._nodeRows) this._nodeRows = [null, null, null, null];
		if (!this._nodeRows[at]) this._nodeRows[at] = H.assetNodes(this._a, this._g, skeleton, physics);
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

	// The file's `KHR_lights_punctual` lights, each placed in world space.
	//
	//     for (const l of asset.lights) console.log(l.name, l.type, l.intensity);
	//
	// A description and not a light: `{ name, type, color, intensity, range,
	// node }`, with `type` one of `'directional'`, `'point'` or `'spot'`, `color`
	// linear rgb, and `intensity` and `range` **exactly as the file wrote them**
	// — glTF's own units, which are not this renderer's. `node` is where the
	// light hangs: `{ index, position, direction }`, the node's world translation
	// and the way the light travels, which is its -Z.
	//
	// The reason it stops there is that there are eight light slots and a level
	// may author twenty, so which of them get lit is a choice.
	// `instantiate({ lights: true })` is one policy over this list and a script
	// is free to write another.
	//
	// A spot also carries `cone: [inner, outer]` in radians. This renderer has no
	// cone, so the two angles are reported and nothing reads them.
	//
	// Read at load out of the JSON chunk, so this costs no upload; cached, for
	// `nodes`' reason.
	get lights() {
		if (!this._lights) {
			H.checkAsset(this._a, this._g);
			this._lights = H.assetLights(this._a, this._g).map((row) => {
				const [name, kind, r, g, b, intensity, range, inner, outer, px, py, pz, dx, dy, dz, node] = row;
				const light = {
					name,
					type: LIGHT_BY_ORDINAL[kind] || 'point',
					color: [r, g, b],
					intensity,
					range,
					node: { index: node, position: [px, py, pz], direction: [dx, dy, dz] },
				};
				if (light.type === 'spot') light.cone = [inner, outer];
				return light;
			});
		}
		return this._lights;
	}

	// The file's cameras, each placed in world space.
	//
	// `{ name, position, target, up, yfov, znear, zfar, aspect }`. A glTF camera
	// is an eye and a heading, so `target` is a point along the node's -Z — the
	// distance to it is where that ray passes the middle of the file's bounds,
	// which is chosen here because the turntable needs an orbit point and the
	// file carries none. The picture does not depend on it: any point on that ray
	// puts the eye in the same place looking the same way.
	//
	// `yfov` is radians and **vertical**, as the file states it and as
	// `three.camera.fov` means it once converted to degrees. `znear` and `zfar`
	// are reported and cannot be applied — this renderer derives both planes from
	// the orbit distance and the scene's bounds every frame, which is why
	// `three.camera.near` and `.far` throw on assignment.
	//
	// An orthographic camera reports zeroes for the four lens numbers, because
	// there is no orthographic projection here to describe.
	get cameras() {
		if (!this._cameras) {
			H.checkAsset(this._a, this._g);
			this._cameras = H.assetCameras(this._a, this._g).map((row) => {
				const [name, px, py, pz, fx, fy, fz, ux, uy, uz, distance, yfov, znear, zfar, aspect, node] = row;
				return {
					name,
					position: [px, py, pz],
					target: [px + fx * distance, py + fy * distance, pz + fz * distance],
					up: [ux, uy, uz],
					yfov, znear, zfar, aspect,
					node: { index: node, position: [px, py, pz], direction: [fx, fy, fz], distance },
				};
			});
		}
		return this._cameras;
	}

	// What the file said collides — its `KHR_physics_rigid_bodies` blocks, node
	// by node.
	//
	//     for (const c of asset.colliders) console.log(c.name, c.shape, c.mass);
	//
	// A description and not a body, for `lights`' reason: the file states what
	// collides and which of it this engine can hold is a choice.
	// `instantiate({ physics: true })` is one policy over this list and a script
	// is free to write another.
	//
	// `{ node, name, shape, collider, trigger, motion, kinematic, mass,
	// gravityFactor, linearDamping, angularDamping, linearVelocity,
	// angularVelocity, material, friction, restitution, proxy, filtered }`.
	// `node` is the glTF node index — `object._gltfNode` on an instantiated tree
	// — and `shape` is one of `'mesh'`, `'hull'`, `'box'`, `'sphere'`,
	// `'capsule'` or `'cylinder'`. Every number is **the file's own**, which for
	// mass, friction and restitution is also this engine's.
	//
	// `proxy` says the shape got a collision-only mesh of its own, which is what
	// a box or a capsule needs to be in a query at all. `filtered` says the file
	// named a `collisionFilter`; this solver has no layers to put one in and it
	// is reported rather than applied.
	//
	// Read at load out of the JSON chunk, so this costs no upload; cached, for
	// `nodes`' reason.
	get colliders() {
		if (!this._colliders) {
			H.checkAsset(this._a, this._g);
			this._colliders = H.assetBodies(this._a, this._g).map((row) => {
				const [
					node, name, shape, collider, trigger, motion, kinematic, mass,
					gravityFactor, linearDamping, angularDamping,
					lvx, lvy, lvz, avx, avy, avz,
					material, friction, restitution, proxy, filtered,
				] = row;
				return {
					node, name,
					shape: COLLIDER_BY_ORDINAL[shape] || 'mesh',
					collider, trigger, motion, kinematic, mass,
					gravityFactor, linearDamping, angularDamping,
					linearVelocity: [lvx, lvy, lvz],
					angularVelocity: [avx, avy, avz],
					material, friction, restitution, proxy, filtered,
				};
			});
		}
		return this._colliders;
	}

	// The file's `physicsJoints`, each resolved to the two nodes it holds.
	//
	// `{ a, b, pivot, collide, limits }`, with `a` and `b` glTF node indices and
	// each limit `{ linearAxes | angularAxes, min, max, stiffness, damping }` —
	// which is exactly what `three.physics.joint` takes, because a glTF joint's
	// description and this one are the same object.
	get physicsJoints() {
		if (!this._physicsJoints) {
			H.checkAsset(this._a, this._g);
			this._physicsJoints = H.assetJoints(this._a, this._g).map((row) => {
				const [a, b, px, py, pz, collide, limits] = row;
				return {
					a, b, pivot: [px, py, pz], collide,
					limits: limits.map(([kind, axes, min, max, stiffness, damping]) => {
						const list = [];
						for (let i = 0; i < 3; i++) if (axes & (1 << i)) list.push(i);
						const out = { min, max, stiffness, damping };
						out[kind === 0 ? 'linearAxes' : 'angularAxes'] = list;
						return out;
					}),
				};
			});
		}
		return this._physicsJoints;
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
		const rows = this._rows(opt.skeleton, opt.physics);
		const root = new Object3D();
		// The name is what the tree is *called*, not which part of the file it is.
		// `node(name)` is the one that picks — see it for why the two are separate.
		root.name = name === undefined ? this.path.replace(/^.*[/\\]/, '') : String(name);
		this._carry(root, opt);
		this._build(rows, -1, root, opt);
		// After the tree, because both write the host's own camera and lights and
		// neither reads it — the order only matters for what a script sees if it
		// throws, and a half-built tree is the more useful half to have.
		if (opt.lights) this._placeLights();
		if (opt.camera) this._placeCamera(opt.camera);
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
		const rows = this._rows(opt.skeleton, opt.physics);
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

	// `{ skeleton, skinning, materials, lights, camera }` as the two
	// instantiating doors read it. One place, so they cannot drift.
	//
	// `lights` and `camera` are `instantiate`'s alone. A file's lighting is a
	// property of the file and not of one piece of it, so `node(name)` parses
	// them and does nothing with them rather than aiming the whole scene's camera
	// at a crate.
	_instanceOptions(options) {
		const {
			skeleton = false, skinning = 'vertex', materials = false,
			lights = false, camera = false, physics = false,
		} = options || {};
		return {
			skeleton: !!skeleton,
			compute: skinning === 'compute',
			materials: !!materials,
			lights: !!lights,
			camera,
			physics: !!physics,
		};
	}

	// `three.lights` filled from the file — `instantiate({ lights: true })`.
	//
	// **The directional light is slot zero and the point lights are the rest.**
	// Slot zero is the sun: it is the only one that casts a shadow and the only
	// one that cannot hold a position, so the file's directional light goes there
	// and nowhere else. A file with no directional light leaves it exactly as the
	// script had it, which is how a level lit only by lanterns keeps whatever sun
	// was set for it.
	//
	// `three.light.direction` is a **surface-to-light** vector and the file's is
	// the direction the light travels, so the one negation in the importer is
	// here.
	//
	// **The remaining slots go to the point lights nearest the file's camera**,
	// or nearest the origin when the file has none. Three slots and six lanterns
	// is the ordinary case for a level, and "nearest the shot" is the only
	// ordering that puts the ones you can see in them. A spot light competes for
	// the same slots as a point standing where it stands: this renderer has no
	// cone, so its `cone` angles are dropped and it lights a sphere.
	//
	// **The Watts are Blender's and so is the arithmetic** — a sun of S becomes
	// S/pi and a lamp of P becomes P/(4 pi²), which is already this renderer's
	// brightness-at-one-metre. See DIRECTIONAL_FROM_WATTS at the top of this file.
	//
	// Everything that did not fit is named once by `console.warn`, because a
	// lantern that quietly does not light is the kind of thing somebody spends an
	// afternoon looking for in a shader.
	_placeLights() {
		const found = this.lights;
		if (!found.length) return;

		const sun = found.find((l) => l.type === 'directional');
		if (sun) {
			const [dx, dy, dz] = sun.node.direction;
			three.light.direction = [-dx, -dy, -dz];
			three.light.color = sun.color;
			three.light.intensity = sun.intensity * DIRECTIONAL_FROM_WATTS;
		}

		// Measured from the file's own camera, which is the shot the lights were
		// placed for. Nothing to measure from is the origin, which is at least a
		// stable answer rather than the file's first light.
		const shot = this.cameras.length ? this.cameras[0].position : [0, 0, 0];
		const near = found
			.filter((l) => l !== sun)
			.map((l) => [l, sqDistance(l.node.position, shot)])
			.sort((a, b) => a[1] - b[1])
			.map(([l]) => l);

		// The script's own lights go before the file's — this is the file's
		// lighting being imported, not added to. Slot zero is never removed
		// because it cannot be; it was written above, or deliberately left.
		while (three.lights.length > 1) three.lights.remove(three.lights.length - 1);

		const room = three.lights.max - 1;
		const lit = near.slice(0, room);
		for (const point of lit) {
			const intensity = point.intensity * POINT_FROM_WATTS;
			three.lights.add({
				position: point.node.position,
				// The file's own reach, or the distance Blender would have stopped
				// tracing it at — see LIGHT_THRESHOLD.
				range: point.range > 0 ? point.range : Math.sqrt(intensity / LIGHT_THRESHOLD),
				color: point.color,
				intensity,
			});
		}

		const dropped = found.filter((l) => l !== sun && !lit.includes(l));
		if (dropped.length) {
			console.warn(
				`${this.path}: ${found.length} lights and ${three.lights.max} slots — `
				+ `lit ${sun ? `${sun.name} as the sun and ` : ''}${lit.length} of them, `
				+ `left out ${nameList(dropped.map((l) => l.name))}`
			);
		}
	}

	// `three.camera` aimed from the file — `instantiate({ camera: true })`, or
	// `{ camera: 'Camera' }` to pick one of several by name.
	//
	// The turntable is a target, a boom and two angles and a glTF camera is an
	// eye and a heading, so the import is: look at the point the file's -Z ray
	// passes the middle of the file at, then orbit back along that ray to the
	// eye. The eye lands exactly where the file put it, which is the whole of what
	// makes the frame match.
	//
	// `fov` is the file's `yfov` in degrees. Both are **vertical** — this
	// renderer's projection is `matrix::perspective(fov, aspect, …)`, whose first
	// argument is the vertical half-angle doubled — so the conversion is the
	// radians and nothing else.
	//
	// `roll` comes from the node's up: zero for every camera authored level, and
	// the reason a shot composed with a tilted horizon does not arrive straight.
	//
	// `near` and `far` are not applied. They are derived here from the orbit
	// distance and the scene's bounds every frame, and a file's fixed pair would
	// be overwritten before the first draw — `asset.cameras` reports them so a
	// script can see what the file asked for.
	_placeCamera(which) {
		const all = this.cameras;
		if (!all.length) return;
		const cam = typeof which === 'string'
			? all.find((c) => c.name === which)
			: all[0];
		if (!cam) {
			throw new Error(`no camera named "${which}" in ${this.path} — it has: ${nameList(all.map((c) => c.name))}`);
		}

		const [ex, ey, ez] = cam.position;
		const [tx, ty, tz] = cam.target;
		const bx = ex - tx, by = ey - ty, bz = ez - tz;
		const boom = Math.hypot(bx, by, bz);
		if (cam.yfov > 0) three.camera.fov = cam.yfov * 180 / Math.PI;
		three.camera.lookAt(tx, ty, tz);
		three.camera.orbit(
			Math.atan2(bx, bz) * 180 / Math.PI,
			Math.asin(boom > 0 ? by / boom : 0) * 180 / Math.PI,
			boom,
		);
		three.camera.roll = rollOf(cam.node.direction, cam.up);
	}

	// `three.physics` filled from the file — `instantiate({ physics: true })`.
	//
	// **The index is decided by the tree and the bodies are decided here.** Which
	// meshes collide is already settled by the time this runs: the walk gave every
	// node the file's answer and gave every implicit shape a collision-only proxy,
	// and that is what the character controller and every raycast read. What is
	// left is the solver, which is a smaller thing and a stricter one.
	//
	// Every collider node gets `object.body` — the description
	// `three.physics.add(object)` reads with no options — whether or not a body is
	// made here, so a script can make its own later with one call.
	//
	// **A body is made when the file describes something that moves.** A `motion`
	// or a `trigger` is that; a plain collider is a wall, and a wall exists in the
	// solver only to hold a body up. So a file with no motion and no trigger in it
	// — a level, which is the common case — gets no solver bodies at all and pays
	// for none, while a file with a crate in it gets the ground under the crate.
	//
	// **A body's transform is world space**, which is the solver's rule and not
	// this importer's: a body has to be a direct child of the scene. A node the
	// file made a body is therefore lifted to the scene root when everything
	// between it and the root sits at identity — which is where `instantiate`
	// leaves its own group — and reported when it does not, because moving it then
	// would move the object.
	//
	// Everything that did not fit is named once by `console.warn`, the way
	// `_placeLights` names the lanterns it could not light.
	_placePhysics(root) {
		const bodies = this.colliders;
		if (!bodies.length) return;

		const scene = sceneRoot(root);
		if (scene === null) return;

		const byNode = new Map();
		root.traverse((o) => { if (o._gltfNode >= 0) byNode.set(o._gltfNode, o); });

		// A wall is only worth a body when something can fall onto it.
		const moving = bodies.some((b) => b.motion || b.trigger);
		const skipped = [];
		const made = new Map();
		let filtered = 0;

		for (const body of bodies) {
			if (!body.collider) {
				// A `motion` with no collider of its own is a compound body, whose
				// pieces are the colliders on the nodes under it. The solver holds one
				// shape per body, so it cannot be that.
				if (body.motion) skipped.push(`${body.name} is a compound body, which the solver has no shape for`);
				continue;
			}
			const object = byNode.get(body.node);
			if (object === undefined) continue;

			const shape = SOLVER_SHAPE[body.shape];
			if (shape === null) {
				skipped.push(`${body.name} is a ${body.shape}, which the solver has no shape for`);
				continue;
			}

			const kind = body.trigger ? 'trigger'
				: body.motion ? (body.kinematic ? 'kinematic' : 'dynamic')
				: 'static';
			const spec = {
				shape,
				mass: body.motion ? body.mass : 0,
				friction: body.material ? body.friction : 0.5,
				restitution: body.material ? body.restitution : 0.2,
				gravityFactor: body.gravityFactor,
				linearDamping: body.linearDamping,
				angularDamping: body.angularDamping,
			};
			if (body.kinematic) spec.kinematic = true;
			if (body.trigger) spec.trigger = true;
			// The description goes on whether or not a body is made from it, so
			// `three.physics.add(object)` later needs no arguments.
			object.body = spec;

			if (!moving && kind === 'static') continue;

			if (!canStandAtRoot(object, scene)) {
				skipped.push(`${body.name} sits under a transformed parent, and a body's transform is world space`);
				continue;
			}

			let carrier;
			if (kind === 'static' || kind === 'trigger') {
				// **A wall does not move, so its body is a copy standing where the
				// wall stands** — the file's tree is left exactly as it was, and the
				// copy is made from the *shape*, so a solver body and the proxy the
				// sweep uses are the same box. `Entity`'s trigger volume is the same
				// arrangement, made from a class instead of a file.
				const shaped = (body.proxy && object.children.find((c) => c.collisionOnly)) || object;
				if (!shaped.geometry) {
					skipped.push(`${body.name} has no mesh for the solver to measure`);
					continue;
				}
				carrier = new Mesh(shaped.geometry);
				// `<node>.body`, so it is not confused with `<node>.collider`, which
				// is the proxy standing in the same place for the sweep.
				carrier.name = `${object.name}.body`;
				carrier.visible = false;
				// The drawing — or its proxy — is already in the index; a second box
				// there would be a second thing every sweep tests.
				carrier.collides = false;
				copyPlacement(carrier, object);
				scene.add(carrier);
			} else {
				// **A body that moves is the object itself**, so that
				// `crate.position` is the crate's and a script that knows the node by
				// name knows the body. It leaves the file's tree to be one: the
				// solver writes world transforms, and a body has to hang off the
				// scene root. The size comes from the drawing rather than from the
				// implicit shape beside it, which is the same mesh the shape was
				// measured from.
				if (!object.geometry) {
					skipped.push(`${body.name} draws nothing, so the solver has no shape to measure`);
					continue;
				}
				scene.add(object);
				carrier = object;
			}

			scene.physics.add(carrier, spec);
			made.set(body.node, carrier);
			if (body.filtered) filtered++;
			if (body.motion && !body.kinematic) {
				const [lx, ly, lz] = body.linearVelocity;
				const [ax, ay, az] = body.angularVelocity;
				if (lx || ly || lz) scene.physics.setVelocity(carrier, [lx, ly, lz]);
				if (ax || ay || az) scene.physics.setAngularVelocity(carrier, [ax, ay, az]);
			}
		}

		for (const joint of this.physicsJoints) {
			const a = made.get(joint.a);
			const b = made.get(joint.b);
			if (a === undefined || b === undefined || !joint.limits.length) {
				skipped.push(`a joint between nodes ${joint.a} and ${joint.b} holds something that has no body`);
				continue;
			}
			scene.physics.joint(a, b, { limits: joint.limits, pivot: joint.pivot, collide: joint.collide });
		}

		// One line for the file, not one per collider: a level names the same
		// filter on all of them and would otherwise say so a hundred times.
		if (filtered) {
			skipped.push(`${filtered} name a collision filter, which this solver has no layers for`);
		}
		if (skipped.length) {
			console.warn(
				`${this.path}: ${made.size} of ${bodies.length} colliders became bodies — ${skipped.join('; ')}`
			);
		}
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
		// The solver's half of `physics: true`, deferred to the moment the tree is
		// in a scene: a body hangs on a host node and there is no host node until
		// something adds this. The index's half is already in the tree.
		if (opt.physics) root._onAdded = (added) => this._placePhysics(added);
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
			const [label, parent, mesh, px, py, pz, ex, ey, ez, sx, sy, sz, qx, qy, qz, qw, gltfNode, r, g, b, a, skin, collides, collisionOnly] = rows[i];
			if (from >= 0 && i !== from && !(parent >= 0 && built[parent])) continue;
			// **A `MeshRef` rather than the bare `{ asset, mesh }` this used to
			// build.** A Mesh only needs the three numbers, so the plain object drew
			// exactly the same picture — but it is also what a script reads back off
			// `o.geometry`, and there it was a dead end: the stack, the glTF material
			// and the bounds of the piece were all one `asset.meshAt(o.geometry.mesh)`
			// away, which is a detour that has to be found before it can be taken.
			// The reference costs the same and answers all three.
			const node = mesh < 0
				? new Object3D()
				: new Mesh(new MeshRef(this._a, this._g, mesh, label));
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
			// What the file said collides. True and false for every row of every
			// file walked without `physics: true`, so this writes the defaults it
			// found and `_materialize` sends nothing.
			node._collides = collides;
			node._collisionOnly = collisionOnly;
			// Only a copy an instanced node placed has anything but white
			// here, and only a Mesh has anywhere to put it — a group's row
			// carries the identity and setting it would define a channel on
			// an object that has none.
			if (mesh >= 0 && !(r === 1 && g === 1 && b === 1 && a === 1)) node.color = [r, g, b, a];
			if (opt.materials && mesh >= 0) {
				const imported = this._importedMaterial(node.geometry, materialCache);
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
	//  - **Every map goes on a `MeshLambertMaterial`.** The normal map, the
	//    occlusion map, the metallic-roughness pair and the emissive map are four
	//    sampler bindings on the pipeline the renderer built at startup, so a
	//    file's whole surface arrives without compiling a shader for it.
	//  - `alphaMode: 'BLEND'` becomes `transparent: true`; **`MASK` becomes
	//    `alphaTest: alphaCutoff`**, which is what it has always meant and what
	//    there was no path for until §28. The two are now different things here:
	//    a blend is sorted, writes no depth and casts no shadow, and a cut-out
	//    does all three — which is the difference between a tree that reads as
	//    foliage and one that reads as a stack of glass.
	//  - `doubleSided` becomes `side: three.DoubleSide`.
	//  - `metallicFactor` and `roughnessFactor` go on as `metalness` and
	//    `roughness`, which is what the specular and environment terms read.
	//    **This is the file's numbers and not a guess**, and glTF's defaults for
	//    them are 1 and 1 — so a file that never wrote a `pbrMetallicRoughness`
	//    block imports as a fully metallic surface and looks like one. It is dark
	//    without a `scene.environment`, correctly: a metal is what it reflects.
	//  - The emissive factor and map go on as `emissive` and `emissiveMap`, and
	//    the map multiplies the factor exactly as glTF says. A file with a glow
	//    texture and no `emissiveFactor` therefore glows black, which is the
	//    specification's own answer and not this importer's.
	//  - `KHR_texture_transform` becomes `repeat` and `offset`. **A material that
	//    says nothing else still gets built when it tiles**, unlike the rule below,
	//    because a transform is the one thing in this list that changes every pixel
	//    of a mesh drawn with the file's own base colour map — the map is the
	//    mesh's and the tiling is the material's, so dropping the material drops
	//    the tiling and a ground draws one stretched copy of its grass.
	//
	// **What used to happen instead, and why it stopped.** A normal map or a glow
	// routed the material through a `LayeredMaterial` — a generated shading body,
	// a Slang compile and a pipeline per glTF material — because those were the
	// only maps that had a home. `plan.md` §26 gave the built-in shader all four,
	// so the layered path was compiling a shader for something the startup
	// pipeline does. Occlusion and the metallic-roughness map were dropped
	// entirely on the way past; they are applied now. A *stack* still compiles a
	// body, and that is not the same mistake: a stack is a description of a
	// shading body and there is no pipeline that draws one already.
	//
	// **A mesh whose material carried `CUSTOM_materials_layers` gets the stack**,
	// as a `LayeredMaterial`, and that is the only path by which a level authored
	// in Blender draws what was authored. There is no second option to pass: a
	// stack *is* one of the file's materials, and a `{ layers: true }` beside this
	// would mean a file that needs both draws its masks as albedo until somebody
	// notices which flag was missing. `_layeredMaterial` has what is carried over
	// and what a refusal does.
	//
	// A description with none of that in it builds nothing: an opaque,
	// single-sided material with no maps and this renderer's own surface defaults
	// is exactly what the default material already is, and one material per mesh
	// that changes no pixel is a handle per mesh for nothing.
	_importedMaterial(ref, cache) {
		const d = ref.material;
		if (d === null) return null;

		const transparent = d.alphaMode === 'BLEND';
		// A cutoff of zero is glTF's way of saying nothing is cut, and is also this
		// renderer's way of saying the test is off — so `MASK` with a zero cutoff
		// arrives as an ordinary opaque material rather than as a special case.
		const alphaTest = d.alphaMode === 'MASK' ? d.alphaCutoff : 0;
		const side = d.doubleSided ? DoubleSide : FrontSide;

		// The stack, if the file wrote one. Asked before anything below is decided,
		// because it answers a different question: what is *on* this surface, rather
		// than what the surface is.
		const stack = ref.layers;
		if (stack !== null) {
			const layered = this._layeredMaterial(ref, d, stack, { transparent, alphaTest, side }, cache);
			// Null is a stack that would not build — the sampler budget, most likely.
			// The mesh keeps whatever the plain path makes of the same material, which
			// is its base colour, its base colour map and its normal map: a piece of
			// the level drawn without its weathering rather than a level that did not
			// load.
			if (layered !== null) return layered;
		}

		const glow = d.emissiveMap !== null
			|| d.emissive[0] > 0 || d.emissive[1] > 0 || d.emissive[2] > 0;
		const tiled = d.repeat[0] !== 1 || d.repeat[1] !== 1
			|| d.offset[0] !== 0 || d.offset[1] !== 0;
		// Against this renderer's defaults rather than against glTF's, because the
		// question is whether saying it changes anything. `scene/material.c3` has
		// why they are 1 and 0.
		const surface = d.roughness !== 1 || d.metalness !== 0;
		const maps = d.normalMap !== null || d.aoMap !== null
			|| d.metalnessRoughnessMap !== null;
		if (!transparent && alphaTest === 0 && !d.doubleSided && !glow && !surface && !maps && !tiled) {
			return null;
		}

		// The images are handles rather than values, so identity is what the key
		// can be built from — two meshes that resolved the same slot get the same
		// `_index()`.
		const key = [
			transparent, alphaTest, side, d.roughness, d.metalness,
			d.normalMap ? d.normalMap._index() : -1,
			d.aoMap ? d.aoMap._index() : -1,
			d.metalnessRoughnessMap ? d.metalnessRoughnessMap._index() : -1,
			d.emissiveMap ? d.emissiveMap._index() : -1,
			d.emissive.join(','), d.emissiveIntensity,
			// Two meshes tiled differently are two materials: the transform is a
			// property of the pipeline's uniforms, not of the images in it, so a
			// shared entry would draw the second mesh at the first one's density.
			d.repeat.join(','), d.offset.join(','),
		].join('|');
		const hit = cache.get(key);
		if (hit) return hit;

		const built = new MeshLambertMaterial({
			transparent,
			side,
			alphaTest,
			roughness: d.roughness,
			metalness: d.metalness,
			// **An imported material is a dielectric and glTF says so.** 0 is the
			// default because a scripted material is one nothing states — see
			// `scene/material.c3` — but a file is not silent here: the
			// specification fixes a non-metal's F0 at 0.04, which is Filament's
			// 0.5 and is Blender's Specular IOR Level of 0.5 as well. Leaving it at
			// 0 draws the file's wet stone, glazed pot and varnished wheel as
			// perfectly matte.
			reflectance: IMPORTED_REFLECTANCE,
			normalMap: d.normalMap,
			aoMap: d.aoMap,
			metalnessRoughnessMap: d.metalnessRoughnessMap,
			emissiveMap: d.emissiveMap,
			emissive: d.emissive,
			emissiveIntensity: d.emissiveIntensity,
		});
		// After construction rather than in the options, because they are properties
		// every material has — the two setters are the one place a zero repeat is
		// refused by name.
		if (tiled) {
			built.repeat = d.repeat;
			built.offset = d.offset;
		}
		cache.set(key, built);
		return built;
	}

	// One imported `CUSTOM_materials_layers` stack as a material, or null when the
	// stack will not build.
	//
	// **What the core material lends the stack, and why only these.** The extension
	// puts the base surface where core glTF already had it, so the two halves have
	// to be put back together here:
	//
	//  - `normal` is `normalTexture`. It is the bottom of the stack's normal chain
	//    — every layer's own normal is lerped over it — and the extension has no
	//    slot of its own for one, deliberately, because core glTF's is not extra.
	//  - `side` and `transparent` are the material's, exactly as on the plain path:
	//    a leaf is double-sided whether or not moss grows on it.
	//  - `alphaTest` is set after construction rather than passed, because a
	//    LayeredMaterial takes the ShaderMaterial options and a cut-out is a
	//    property every material has.
	//  - `roughness` and `metalness` are the file's own numbers, as they are on the
	//    plain path, and a layer that states either blends over them.
	//  - `metalnessRoughnessMap`, `aoMap` and `emissiveMap` are the core material's
	//    other three maps, under the names it hands them over with. They used to be
	//    dropped here — a `LayeredMaterial` is a generated body and none of the
	//    built-in map bindings exists on it — so a stack imported off a material
	//    with an occlusion map drew without it and nothing said so. They are three
	//    samplers of the stack's own budget now, which is what they cost.
	//  - `emissive` and `emissiveIntensity` go on after construction, because they
	//    are properties every material has rather than options a stack declares.
	//    Without them the emissive map above would multiply a factor of zero.
	//  - `repeat` and `offset` are the core material's `KHR_texture_transform`, and
	//    they are the base of the stack's tiling in exactly the way `normal` is the
	//    base of its normal chain: the fragment stage puts them on `s.uv` before the
	//    generated body runs, and each layer's own `uvScale` arrived measured from
	//    them. Set after construction, for `emissive`'s reason.
	//  - `name` is the mesh's, and is only ever read by a warning.
	//
	// **A stack that will not build costs its own mesh and nothing else.** Twelve
	// samplers is a real ceiling, and a stack over it sheds its per-layer relief
	// before it refuses anything (`layers.js`) — so what reaches the catch here is
	// a stack asking for more albedos, normals or masks than a material has
	// bindings for. That mesh keeps the plain material and the rest of the file
	// draws its stacks; throwing instead would lose a whole level to one surface.
	// The warning names the mesh, once per distinct stack, because the fix is in
	// the file and the file names the mesh.
	_layeredMaterial(ref, d, stack, look, cache) {
		const options = {
			...stack,
			...(d.normalMap === null ? {} : { normal: d.normalMap }),
			...(d.metalnessRoughnessMap === null ? {} : { metalnessRoughnessMap: d.metalnessRoughnessMap }),
			...(d.aoMap === null ? {} : { aoMap: d.aoMap }),
			...(d.emissiveMap === null ? {} : { emissiveMap: d.emissiveMap }),
			name: ref.name,
			side: look.side,
			transparent: look.transparent,
			roughness: d.roughness,
			metalness: d.metalness,
			// The plain path's, for the plain path's reason.
			reflectance: IMPORTED_REFLECTANCE,
		};
		// Two meshes wearing one glTF material read two descriptions of one stack,
		// and the images in them are the same slots — so the signature dedupes them
		// and a kit of ninety pieces over eight materials compiles eight bodies.
		// The emissive pair is in the key because it is set after construction and
		// so is not in the signature — two materials differing only in how brightly
		// they glow are two materials.
		// The transform is in the key for the same reason the emissive pair is: it is
		// set after construction and so is not in the signature.
		const key = `layers|${look.alphaTest}|${d.emissive.join(',')}|${d.emissiveIntensity}`
			+ `|${d.repeat.join(',')}|${d.offset.join(',')}|${stackSignature(options)}`;
		if (cache.has(key)) {
			// Built already, off another mesh wearing the same glTF material. The
			// handles this read produced are a second set over the same images and
			// nothing is going to hold them, so they go back now — `ref.layers` says
			// every read holds new references, and this is the caller obeying it.
			for (const texture of stackTextures(stack)) texture.dispose();
			return cache.get(key);
		}

		let built = null;
		try {
			built = new LayeredMaterial(options);
		} catch (why) {
			console.warn(
				`three: "${ref.name}" is drawn with its plain material — its layer stack `
				+ `would not build: ${why.message}`
			);
			// The images this description holds are handles of their own and nothing
			// is going to use them, so they go back here rather than at the next
			// unload. The core material's maps are *not* in the list: the plain path
			// is about to build a material out of those very textures.
			for (const texture of stackTextures(stack)) texture.dispose();
		}
		// After the construction rather than in the options: a cut-out and a glow are
		// properties every material has and not ones a stack declares.
		if (built !== null && look.alphaTest > 0) built.alphaTest = look.alphaTest;
		if (built !== null && (d.emissive.some(c => c > 0) || d.emissiveMap !== null)) {
			built.emissive = d.emissive;
			built.emissiveIntensity = d.emissiveIntensity;
		}
		if (built !== null && (d.repeat[0] !== 1 || d.repeat[1] !== 1)) built.repeat = d.repeat;
		if (built !== null && (d.offset[0] !== 0 || d.offset[1] !== 0)) built.offset = d.offset;
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
