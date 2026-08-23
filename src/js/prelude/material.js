// three.c3 — sides, blending, and the two built-in materials.

import { asPair } from './math.js';
import { Texture } from './texture.js';

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
// shader actually computes: one directional light, an ambient floor, and no
// specular term at all. Naming it MeshBasicMaterial would promise unlit and
// deliver lit; naming it MeshStandardMaterial would promise metalness,
// roughness and an environment and deliver none of them.
//
// It has no `color`. `mesh.color` is the per-copy channel and multiplies into
// the sampled texel, so one material can tint a thousand copies differently
// and still be one draw call — a colour here would be a second way to say the
// same thing that also splits the batch.
export class MeshLambertMaterial extends Material {
	constructor(options = {}) {
		if (options === null || typeof options !== 'object') {
			throw new TypeError(
				'new three.MeshLambertMaterial({ map, side, transparent, blending, opacity }) wants an options object'
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
		// After `super`, because it is a write through the handle rather than a
		// part of it — and the setter is what refuses a value outside 0..1, so
		// the option and the property are checked by exactly one piece of code.
		if (options.opacity !== undefined) this.opacity = options.opacity;
	}
}
