// three.c3 — sides, blending, and the two built-in materials.

import { asPair } from './math.js';
import { LinearSRGBColorSpace, Texture } from './texture.js';

const H = globalThis.__three;

// Which faces a material keeps. Three.js's names and Three.js's numbers —
// see `cull_for_side` in scene/material.c3, which is where the numbers stop
// being a convention and become a Vulkan cull mode.
//
// `BackSide` keeps the back faces, so it culls the front ones. That reads
// backwards and is worth saying out loud once: it is the setting that makes
// a sphere visible from *inside*, which is what a skydome is.
export const FrontSide = 0;
export const BackSide = 1;
export const DoubleSide = 2;

// How a material's colour combines with what is already on the screen.
// Three.js's names and Three.js's numbers again — see `blend_for` in
// scene/material.c3, which is where these stop being a convention and become
// a Vulkan blend state.
//
// `NoBlending` is the default and that is worth reading twice, because it is
// the opposite of what "a material has an opacity" suggests: an opaque
// pipeline throws the alpha away, so `opacity` on a material that never asked
// to blend does nothing at all. Three.js behaves the same way. Ask for
// `{ transparent: true }` — or for a blending mode by name — and the opacity
// starts meaning something.
export const NoBlending = 0;
export const NormalBlending = 1;
export const AdditiveBlending = 2;

// What `material.transparent = true` and `material.blending = ...` answer.
// Written once because the two refusals are the same refusal, and two copies
// of a sentence are two things to keep in step.
const BLENDING_IS_BAKED =
	'blending is baked into the pipeline on this device — build a new material '
	+ 'with { transparent } or { blending } instead';
// `Material.texture` in scene/material.c3 — "this material has no image of
// its own, use whatever the mesh brought".
export const NoTexture = -1;

// Which of the built-in material's maps a slot number means —
// `MATERIAL_SLOT_*` in scene/material.c3, which is where they become sampler
// bindings. Not exported: a script names a property, never a slot.
const SLOT_NORMAL = 0;
const SLOT_METALNESS_ROUGHNESS = 1;
const SLOT_OCCLUSION = 2;

// What `material.roughnessMap` and `material.metalnessMap` answer. Three.js
// keeps the two apart and glTF packs them into one image, and this renderer
// follows glTF: the pair is green and blue of `metalnessRoughnessMap`, which is
// the shape every exporter writes and the shape `ref.material` already hands
// over.
const SPLIT_PBR_MAPS =
	'roughness and metalness are one image here, not two — set '
	+ 'metalnessRoughnessMap, which is glTF\'s packing: green is roughness and '
	+ 'blue is metalness';

// What every material here has, which is a pipeline index, a side and a map.
//
// It exists as a base class rather than as duplicated accessors because
// `mesh.material` has to accept both kinds and there is exactly one correct
// answer to "is this a material" — `instanceof Material`. Writing the check
// as a union of the two concrete classes would have to be edited every time
// a third arrives, and the edit that gets forgotten is the one that makes a
// perfectly good material throw.
export class Material {
	constructor(handle, side, blending = NoBlending) {
		this._m = handle;
		this._side = side;
		// Stored rather than asked for, because there is nothing to ask: the
		// blend mode is baked into the pipeline the handle names and the host
		// has no verb that reads one back. It cannot go stale either — see the
		// setter, which is a throw.
		this._blending = blending;
		this._map = null;
	}

	// Whether this handle still names a material. False after dispose().
	get alive() { return this._m >= 0; }

	// The index the host wants, or a throw.
	//
	// Every crossing goes through this rather than reading `_m` directly, so
	// that a disposed handle fails at the line that used it. The alternative
	// — passing -1 along — reaches the host as "no such material", which is
	// the same message a handle from another renderer gets and sends whoever
	// is reading it to the wrong question.
	_index() {
		if (this._m < 0) {
			throw new TypeError(
				'this material was disposed — build it again to use it'
			);
		}
		return this._m;
	}

	// Give back the reference this handle holds.
	//
	// **Not a free**, exactly as `texture.dispose()` is not. The material goes
	// when nothing names it at all, so disposing while a mesh is still drawing
	// with it leaves that mesh correct and collects the material when the mesh
	// goes — which is what makes this safe to call as soon as a script is done
	// *referring* to the material.
	//
	// What it gives back is the pipeline. A material an agent compiled holds a
	// `VkPipeline` for the life of the process otherwise, and an agent
	// iterating on a shader compiles a new one every run — `plan.md` §1.
	//
	// Disposing twice does nothing, so a cleanup path may run more than once.
	// The two built-in materials cannot be disposed at all: `mesh.material =
	// null` is what gives one of those back, and it was never a handle.
	dispose() {
		if (this._m < 0) return;
		H.disposeMaterial(this._m);
		this._m = -1;
	}

	// Which faces this material keeps.
	//
	// Three.js's property, Three.js's constants, and Three.js's default —
	// `FrontSide`. It is on the material rather than on the mesh because it
	// is a property of the *pipeline*: two meshes drawing the same geometry
	// with the same material are one draw call, and they stop being one the
	// moment they can disagree about which faces to keep. A mesh that wants
	// another side wants a material.
	//
	// This is the setting a sky needs. A sphere seen from the inside shows
	// only its back faces, so under the default it is not merely dark, it is
	// *absent* — and scaling it by -1 does not help, because a negative scale
	// does not reverse a triangle's winding. Before this existed the way
	// round it was five inward-facing planes.
	get side() { return this._side; }

	set side(v) {
		Material._checkSide(v);
		const index = this._index();
		if (v === this._side) return;
		H.setSide(index, v);
		this._side = v;
	}

	// Whether this material blends with what is already on the screen, and
	// how.
	//
	// `transparent` is Three.js's flag and `blending` is Three.js's mode; here
	// the first is derived from the second, because a material that blends is
	// exactly a material whose mode is not NoBlending and two fields that can
	// disagree about one fact are a bug waiting for a script to write both.
	//
	// **Both are read-only, and that is a property of this device rather than
	// a design preference.** Metal bakes blending into the compiled pipeline
	// state, so the Vulkan driver here reports every dynamic colour-blend
	// feature as false (`plan.md` §10 has the probe). Changing this would mean
	// building another pipeline, which needs the device, the target and the
	// assembled shader source read back out of a cache — all to save a script
	// the one line that builds the material it meant.
	get transparent() { return this._blending !== NoBlending; }

	set transparent(v) { throw new TypeError(BLENDING_IS_BAKED); }

	get blending() { return this._blending; }

	set blending(v) { throw new TypeError(BLENDING_IS_BAKED); }

	// How much of this material shows, 0 to 1.
	//
	// **Settable and free**, unlike `blending`: it is one float in the push
	// block, so an animation callback may write it every frame and nothing is
	// rebuilt. It multiplies whatever alpha the mesh itself carries, so a
	// glTF's own transparency and a script's fade compose rather than one
	// overwriting the other.
	//
	// **It does nothing unless the material was built transparent.** An opaque
	// pipeline discards the alpha the shader writes, so this reads back as the
	// number that was set and the picture does not move. That is the hardware's
	// answer rather than a rule chosen here, and it is Three.js's behaviour
	// too — `opacity` without `transparent` is inert there as well.
	get opacity() { return H.getOpacity(this._index()); }

	set opacity(v) {
		if (typeof v !== 'number' || !Number.isFinite(v) || v < 0 || v > 1) {
			throw new TypeError('`opacity` wants a number from 0 to 1, not ' + String(v));
		}
		H.setOpacity(this._index(), v);
	}

	// How rough this surface is, 0 to 1. 1 is the default and is a perfectly
	// diffuse surface — no highlight, which is what every material here was
	// before there was a term that read one.
	//
	// Three.js's name, Three.js's range, and Three.js's default. What differs
	// is `reflectance` below, without which this changes nothing.
	get roughness() { return H.getSurface(this._index())[0]; }

	set roughness(v) { this._surface(0, v, 'roughness'); }

	// How metallic it is, 0 to 1. 0 is the default.
	//
	// A metal has no diffuse: it reflects rather than scatters, so this takes
	// the albedo out of the diffuse term and puts it into the highlight's
	// colour — which is what makes gold look like gold rather than like white
	// plastic.
	//
	// **With nothing to reflect, a metal is dark.** There is no environment map
	// here, so a fully metallic surface is its highlights and the ambient floor
	// and nothing else. That is the honest answer rather than a broken one, and
	// the sky in `plan.md` §4 is what changes it.
	get metalness() { return H.getSurface(this._index())[1]; }

	set metalness(v) { this._surface(1, v, 'metalness'); }

	// How strongly a *non*-metal reflects, 0 to 1. **0 is the default, and this
	// is the switch that turns the specular term on at all.**
	//
	// 0.5 is the 4% that ordinary dielectrics reflect and is the value to reach
	// for on anything that should look wet, polished or glazed; 1 is about the
	// most any dielectric reflects. A metal ignores it.
	//
	// **A name Three.js does not have**, and deliberately — `plan.md` §4's
	// half-match rule. Three.js's nearest is `specularIntensity`, which
	// defaults to 1: every material there has a highlight and every material
	// here starts without one, because every scene in this project was
	// authored against a renderer that had no specular term at all and turning
	// one on for all of them would relight all of them.
	get reflectance() { return H.getSurface(this._index())[2]; }

	set reflectance(v) { this._surface(2, v, 'reflectance'); }

	// One of the three, written back with the other two beside it.
	//
	// The host takes all three at once — they are one float4 in the draw
	// record — so a setter reads the current triple, replaces its own, and
	// writes. Shared because three copies of this is three places for the
	// range check to drift.
	_surface(at, v, name) {
		if (typeof v !== 'number' || !Number.isFinite(v) || v < 0 || v > 1) {
			throw new TypeError('`' + name + '` wants a number from 0 to 1, not ' + String(v));
		}
		const index = this._index();
		const s = H.getSurface(index);
		s[at] = v;
		H.setSurface(index, s[0], s[1], s[2]);
	}

	// The base colour image, or null.
	//
	// The material's map wins over whatever image the *mesh* carries, so a
	// glTF's own texture can be overridden by assigning one here and cannot
	// silently override one a script asked for.
	//
	// **A mesh with no uvs shows nothing**, and that is the one case where
	// this looks broken and is not. Every parametric shape and every glTF
	// mesh carries uvs; a ConvexGeometry does not, because a hull of an
	// arbitrary point cloud has no natural parameterisation to give it. On
	// one of those the map is set, correct, and invisible.
	get map() { return this._map; }

	set map(v) {
		if (v !== null && v !== undefined && !(v instanceof Texture)) {
			throw new TypeError('material.map wants a three.texture(path), or null for none');
		}
		const texture = v ?? null;
		H.setMap(this._index(), texture === null ? NoTexture : texture._index());
		this._map = texture;
	}

	// How many times the map repeats across a surface, as [u, v].
	//
	// **This is why one plane can be a ground.** Nothing scales uvs by
	// default: a surface maps its texture exactly once, so texel density is
	// a function of how big the mesh is, and a 128px grass image stretched
	// over 132 world units is a smear. `examples/village` covered its ground
	// with 484 separate plane meshes purely to avoid that — one draw call
	// between them, and 484 nodes to say something one number says.
	//
	// **On the material rather than on the texture**, unlike Three.js. Not
	// for Three.js's reason: textures here are deduplicated by content across
	// every file, so a brick image loaded twice is deliberately one slot, and
	// a transform living there would change a wall's tiling because something
	// unrelated used the same picture.
	//
	// Zero throws. It maps every point of the surface to one texel, which is
	// never what anyone meant and is exactly what an unset field looks like.
	get repeat() {
		const [u, v] = H.getMaterialUv(this._index());
		return [u, v];
	}

	set repeat(value) {
		const [u, v] = asPair(value, 'material.repeat');
		const index = this._index();
		const uv = H.getMaterialUv(index);
		H.setMaterialUv(index, u, v, uv[2], uv[3]);
	}

	// Where the map starts, as [u, v]. One whole repeat is 1, so 0.5 shifts
	// the image half a tile — which is what an atlas or a scrolling texture
	// wants, and what stops two neighbouring walls from having visibly the
	// same crack in the same place.
	get offset() {
		const [, , u, v] = H.getMaterialUv(this._index());
		return [u, v];
	}

	set offset(value) {
		const [u, v] = asPair(value, 'material.offset');
		const index = this._index();
		const uv = H.getMaterialUv(index);
		H.setMaterialUv(index, uv[0], uv[1], u, v);
	}

	// `{ roughness, metalness, reflectance }` off a constructor's options, for
	// every constructor that takes options.
	//
	// After the handle exists rather than as part of it, exactly as `opacity`
	// is: these are writes through the handle, and going through the setters is
	// what keeps the option and the property checked by one piece of code.
	static _applySurface(material, options) {
		if (options.roughness !== undefined) material.roughness = options.roughness;
		if (options.metalness !== undefined) material.metalness = options.metalness;
		if (options.reflectance !== undefined) material.reflectance = options.reflectance;
	}

	static _checkSide(v) {
		if (v !== FrontSide && v !== BackSide && v !== DoubleSide) {
			throw new TypeError(
				'`side` wants three.FrontSide, three.BackSide or three.DoubleSide, not ' + String(v)
			);
		}
	}

	static _checkBlending(v) {
		if (v !== NoBlending && v !== NormalBlending && v !== AdditiveBlending) {
			throw new TypeError(
				'`blending` wants three.NoBlending, three.NormalBlending or three.AdditiveBlending, not '
				+ String(v)
			);
		}
	}

	// Which blend mode a material's options add up to.
	//
	// Two spellings of one thing, so there has to be a rule about which wins,
	// and it is Three.js's: **an explicit `blending` wins**. That is what makes
	// `{ transparent: true, blending: three.NoBlending }` an opaque material in
	// both APIs rather than a contradiction one of them resolves the other way.
	// With no `blending` at all, `transparent: true` is NormalBlending — which
	// is the line an agent writes from memory of Three.js and has to work.
	//
	// A `transparent` that is not a boolean is refused by name rather than
	// coerced: `transparent: 0.5` is somebody meaning `opacity`, and a truthy
	// test would silently build a blended pipeline and leave the surface fully
	// opaque, which is the shape of failure that gets blamed on the renderer.
	static _resolveBlending(options) {
		if (options.blending !== undefined) {
			Material._checkBlending(options.blending);
			return options.blending;
		}
		if (options.transparent === undefined) return NoBlending;
		if (typeof options.transparent !== 'boolean') {
			throw new TypeError(
				'`transparent` wants true or false, not ' + String(options.transparent)
				+ ' — for a partial fade, set opacity'
			);
		}
		return options.transparent ? NormalBlending : NoBlending;
	}

	toJSON() {
		return {
			type: this.constructor.name,
			side: this._side,
			transparent: this.transparent,
			blending: this._blending,
			map: this._map?.toJSON() ?? null,
			alive: this.alive,
			// Only for a live material. A disposed one has no transform to
			// report and `_index` would throw out of a `JSON.stringify`, which
			// is the one place a throw is least expected. `opacity` crosses to
			// the host the same way and is null for the same reason; `blending`
			// is remembered on this side and survives the dispose.
			repeat: this.alive ? this.repeat : null,
			offset: this.alive ? this.offset : null,
			opacity: this.alive ? this.opacity : null,
		};
	}
}

// The built-in shader with an image on it, and the material to reach for when
// what you want is a picture on a shape.
//
// **It compiles nothing.** The pipeline is the one the renderer built at
// startup — the same one every untextured mesh already draws with — so
// constructing one is a list push, it cannot fail with a shader diagnostic,
// and it works in a build with no Slang. That is the whole reason it is not
// a ShaderMaterial with a one-line body.
//
// Lambert rather than Basic or Standard, because that is what the built-in
// shader computes unless asked otherwise: the lights, an ambient floor, and no
// highlight until `reflectance` or `metalness` is set. Naming it
// MeshBasicMaterial would promise unlit and deliver lit; naming it
// MeshStandardMaterial would promise an environment to reflect, which is the one
// part of the standard model this renderer still does not have — and the part a
// metal is dark without.
//
// It has no `color`. `mesh.color` is the per-copy channel and multiplies into
// the sampled texel, so one material can tint a thousand copies differently
// and still be one draw call — a colour here would be a second way to say the
// same thing that also splits the batch.
//
// **Four images, not one.** `map` is the base colour; `normalMap`,
// `metalnessRoughnessMap` and `aoMap` are the three the built-in shader reads
// beside it, and none of them compiles anything either — they are three more
// sampler bindings on the pipeline that already existed. The last three are
// *data* and have to be loaded `LinearSRGBColorSpace`; the setters refuse an
// sRGB one by name.
export class MeshLambertMaterial extends Material {
	constructor(options = {}) {
		if (options === null || typeof options !== 'object') {
			throw new TypeError(
				'new three.MeshLambertMaterial({ map, normalMap, metalnessRoughnessMap, aoMap, side, transparent, blending, opacity, roughness, metalness, reflectance }) wants an options object'
			);
		}
		const { map = null, side = FrontSide } = options;
		if (map !== null && map !== undefined && !(map instanceof Texture)) {
			throw new TypeError('`map` wants a three.texture(path), or null for none');
		}
		Material._checkSide(side);
		// Before `super`, because the blend mode is part of what the material
		// is made of: it chooses which of the three pipelines the pass built at
		// startup this handle names. Nothing is compiled either way.
		const blending = Material._resolveBlending(options);

		const texture = map ?? null;
		super(
			H.createTextureMaterial(texture === null ? NoTexture : texture._index(), side, blending),
			side,
			blending,
		);
		this._map = texture;
		this._normalMap = null;
		this._metalnessRoughnessMap = null;
		this._aoMap = null;
		// After `super`, because it is a write through the handle rather than a
		// part of it — and the setter is what refuses a value outside 0..1, so
		// the option and the property are checked by exactly one piece of code.
		if (options.opacity !== undefined) this.opacity = options.opacity;
		Material._applySurface(this, options);
		// The three maps, through their own setters for the same reason: each
		// takes a reference on the host side, and the option and the property
		// have to be refused by one piece of code rather than two.
		if (options.normalMap !== undefined) this.normalMap = options.normalMap;
		if (options.metalnessRoughnessMap !== undefined) {
			this.metalnessRoughnessMap = options.metalnessRoughnessMap;
		}
		if (options.aoMap !== undefined) this.aoMap = options.aoMap;
	}

	// A tangent-space normal map, or null.
	//
	// The frame is rebuilt per pixel from screen-space derivatives, so this
	// works on any mesh with uvs — including a generated PlaneGeometry — and
	// no mesh here has or needs a TANGENT attribute. A mirrored uv island
	// comes out mirrored rather than flipped, which is the price of that.
	//
	// **It has to be loaded linear.** Through an sRGB view the stored 0.5 that
	// means "no tilt" arrives as 0.21, so every surface leans the same way and
	// the detail goes soft — it reads as a bad bake and the file is fine. The
	// setter refuses an sRGB texture by name rather than letting that happen.
	get normalMap() { return this._normalMap; }

	set normalMap(v) { this._normalMap = this._setSlot(SLOT_NORMAL, v, 'normalMap'); }

	// glTF's metallic-roughness image, or null: **green is roughness and blue
	// is metalness**, one texture rather than two, because that is how every
	// exporter writes the pair and how `ref.material` hands it over.
	//
	// **It multiplies `roughness` and `metalness` rather than replacing them**,
	// which is what glTF says its two factors mean. The consequence is the one
	// thing to remember: this renderer's default metalness is 0, so a map on a
	// material nobody set `metalness` on is multiplied away. Set
	// `metalness: 1` — glTF's own default — to let the blue channel speak.
	//
	// Loaded linear, for `normalMap`'s reason.
	get metalnessRoughnessMap() { return this._metalnessRoughnessMap; }

	set metalnessRoughnessMap(v) {
		this._metalnessRoughnessMap = this._setSlot(
			SLOT_METALNESS_ROUGHNESS, v, 'metalnessRoughnessMap'
		);
	}

	// An ambient occlusion map, red channel, or null.
	//
	// **It darkens the ambient floor and the environment reflection, and not
	// the lights.** An AO map records how much of the sky a crevice can see; a
	// lamp pointed into that crevice still lights it. Applied to everything it
	// reads as dirt painted where the light is, which looks plausible enough to
	// ship and is wrong.
	//
	// So a scene with `three.light.ambient` at 0 and no environment sees
	// nothing from this, correctly.
	get aoMap() { return this._aoMap; }

	set aoMap(v) { this._aoMap = this._setSlot(SLOT_OCCLUSION, v, 'aoMap'); }

	// Three.js has these two as separate images and this renderer does not —
	// glTF packs them into one, `ref.material` hands one over, and the shader
	// reads two channels of it. Refused by name rather than ignored, because a
	// property that silently does nothing is the shape of failure that gets
	// blamed on the renderer.
	set roughnessMap(v) { throw new TypeError(SPLIT_PBR_MAPS); }

	set metalnessMap(v) { throw new TypeError(SPLIT_PBR_MAPS); }

	// One of the three, checked and written through.
	//
	// The colourspace check is the half worth having: all three are *data* and
	// not pictures, the host uploads whatever space the texture was loaded in,
	// and an sRGB view of a normal map is the bug that reads as a bad bake.
	// `ref.material` already hands back linear handles, so an imported map
	// passes this without anybody having to know it exists.
	_setSlot(slot, v, name) {
		if (v !== null && v !== undefined && !(v instanceof Texture)) {
			throw new TypeError(
				'material.' + name + ' wants a three.texture(path, '
				+ '{ colorSpace: three.LinearSRGBColorSpace }), or null for none'
			);
		}
		const texture = v ?? null;
		if (texture !== null && texture.colorSpace !== LinearSRGBColorSpace) {
			throw new TypeError(
				'material.' + name + ' is data rather than a picture and has to be loaded '
				+ 'with { colorSpace: three.LinearSRGBColorSpace } — through an sRGB view '
				+ 'every value in it arrives bent'
			);
		}
		H.setMaterialSlot(this._index(), slot, texture === null ? NoTexture : texture._index());
		return texture;
	}

	toJSON() {
		return {
			...super.toJSON(),
			normalMap: this._normalMap?.toJSON() ?? null,
			metalnessRoughnessMap: this._metalnessRoughnessMap?.toJSON() ?? null,
			aoMap: this._aoMap?.toJSON() ?? null,
		};
	}
}
