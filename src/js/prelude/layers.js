// three.c3 — LayeredMaterial: `CUSTOM_materials_layers` as a generated shading
// body.
//
// **This compiles nothing new about the renderer.** A layer stack is a fragment
// function that samples several images and mixes them, which is exactly what
// `shaders/material.slang`'s tier 2 already is — so this file writes Slang and
// hands it to the same `H.createMaterial` a hand-written `ShaderMaterial` goes
// through. There is no layered pipeline, no second descriptor layout and no new
// push contract; `dispose`, `side`, `blending`, `repeat`, `offset` and `opacity`
// all arrive inherited, and `toJSON` reports the generated body, which is the
// thing worth reading when a stack renders wrong.
//
// ## Most of a layer is a constant, and that is what makes it cheap
//
// The obvious implementation pushes every layer's parameters as uniforms and
// loops over them in the shader. That implementation could not exist when this
// was written: the material push block had 52 bytes for uniforms, which is three
// float4s, and a stack of four would have been out of room before it had a single
// texture. It is 104 now (`shader/material_source.c3`) and the argument is
// unchanged — six float4s is still not a layer stack, and a description the
// generator can read is worth more than one the shader can loop over.
//
// It is also unnecessary, because the generator *knows* the description. A blend
// mode picks which expression is emitted rather than being compared at runtime;
// a mask channel becomes `.g`; `invert` becomes a `1.0 -`; `enabled: false`
// omits the layer and its samplers entirely; and a tint, an opacity and a uv
// scale are literals in the source. **Nothing spends push bytes unless the
// caller asks for it to be live** — `animated: true` on a layer promotes its
// tint and opacity to one float4, and that is the only thing the budget counts.
//
// So the ceiling on layers is the sampler budget rather than the uniform one,
// which is the right way round: images are what a stack is made of.

import { Texture } from './texture.js';
import { FrontSide } from './material.js';
import { ShaderMaterial } from './shader.js';
import {
	BLEND_BY_ORDINAL, CHANNEL_BY_ORDINAL, MASK_NONE, MASK_TEXTURE, MASK_VERTEX_COLOR,
} from './asset.js';

const H = globalThis.__three;

// How many samplers a material may declare on top of `map`, and how many bytes
// its uniforms may take.
//
// **Copies. `src/shader/material_source.c3` is the authority for both**, and the
// host refuses past either of them on its own — this side duplicates the numbers
// only to refuse in the caller's vocabulary. The host's message counts
// *textures*, which is correct for a hand-written shader and misleading here: a
// script that wrote nine layers did not write nine textures, it wrote nine
// layers that need eleven, and being told the second number without the first is
// being told the answer to a sum you cannot see.
//
// If they drift, the host still refuses. That is the floor under this, the same
// way `cull_for_side` is the floor under `Material._checkSide`.
const TEXTURE_LIMIT = 8;
const UNIFORM_BUDGET = 104;

// A `float4` per animated layer — tint in rgb, opacity in a. Six of them fit and
// a seventh does not, which is the whole of the arithmetic.
const ANIMATED_LIMIT = Math.floor(UNIFORM_BUDGET / 16);

// How a layer combines with everything under it, in the extension's own
// vocabulary.
//
// **Strings rather than numbers, unlike `side` and `blending`.** Those two are
// numeric because Three.js is numeric and a script written from memory of
// Three.js has to work; there is no Three.js concept here to match, and the
// precedent that does exist is the extension's own JSON, which spells
// `"blendMode": "MULTIPLY"`. So a script reads the way the file it came from
// reads, and the importer has nothing to translate.
//
// Each entry is a function of `(a, b)` — what is below, and this layer — written
// as Slang source. The result is then mixed back over `a` by the layer's mask,
// which is the extension's rule: `lerp(below, f(below, layer), mask)`.
const BLEND = {
	mix: (a, b) => b,
	multiply: (a, b) => `${a} * ${b}`,
	add: (a, b) => `${a} + ${b}`,
	subtract: (a, b) => `${a} - ${b}`,
	screen: (a, b) => `1.0 - (1.0 - ${a}) * (1.0 - ${b})`,
	// Component-wise, and written as a `lerp` over a `step` rather than as a
	// branch: a ternary on a float3 is not a thing, and `step(0.5, a)` is 1 where
	// the value below is light and 0 where it is dark — so the lerp picks the
	// doubled multiply under a dark base and the doubled screen under a light
	// one, which is what overlay means.
	overlay: (a, b) =>
		`lerp(2.0 * ${a} * ${b}, 1.0 - 2.0 * (1.0 - ${a}) * (1.0 - ${b}), step(0.5, ${a}))`,
	// Blender's own soft light rather than the W3C one, because the exporter this
	// extension comes from is Blender's and a mode that looked different in the
	// viewer than in the file it was authored in is worse than no mode at all.
	softLight: (a, b) =>
		`(1.0 - ${a}) * ${a} * ${b} + ${a} * (1.0 - (1.0 - ${a}) * (1.0 - ${b}))`,
	difference: (a, b) => `abs(${a} - ${b})`,
	darken: (a, b) => `min(${a}, ${b})`,
	lighten: (a, b) => `max(${a}, ${b})`,
};

// Which component of a mask texture a layer's weight is read from.
const CHANNELS = { r: 'r', g: 'g', b: 'b', a: 'a' };

// What a layer may say, so that anything else can be refused by name.
//
// A misspelled option on a sealed object silently does nothing, and a layer that
// quietly ignored `uvscale` would render at the wrong tiling with no complaint —
// the same failure `uniformsProxy` exists to prevent, one level up.
const LAYER_KEYS = new Set([
	'name', 'map', 'normal', 'emissive', 'emissiveFactor', 'tint', 'opacity',
	'blend', 'mask', 'maskSource', 'maskTexture', 'invert', 'uvScale', 'uvOffset',
	'enabled', 'animated', 'roughness', 'metalness', 'metallicRoughness',
	'height', 'bump', 'uvWindow',
]);

// Where a layer's weight comes from, in the extension's own two words.
//
// `mask` says which channel and this says which *thing* — a texture, or the
// mesh's own COLOR_0 attribute. It is a separate key rather than a magic value
// of `mask` because that is the shape `LayerMask` has in the file, so the
// importer translates rather than encodes, and because `mask: 'g'` means the
// same thing under both.
const MASK_SOURCES = new Set(['texture', 'vertexColor']);

const TOP_KEYS = new Set([
	'map', 'normal', 'mask', 'layers', 'side', 'transparent', 'blending', 'opacity',
	'roughness', 'metalness', 'reflectance', 'height', 'bump',
]);

// The parts of the extension this renderer parses and cannot evaluate, and the
// sentence each is refused with.
//
// **Refused rather than ignored, and that is the whole point of the table.** A
// value this accepted and dropped would be a material property that provably
// changes no pixel, and the script that set it would spend its next hour on the
// lighting rather than on the one line that says so. The refusal is where that
// hour is saved.
//
// One entry left, and it is the only one whose gap is in the *lighting* rather
// than in this file: roughness, metalness and their map blend per layer now, and
// a height map moves the uv under everything sampled after it. Subsurface needs
// a light transport that does not exist, so there is nothing for a layer to say
// it to.
const UNSUPPORTED = {
	subsurface: 'subsurface scattering needs a light transport this renderer does not have',
};

// A number as Slang source.
//
// The decimal point is not cosmetic: `float3(1, 1, 1) * 8` is legal Slang and
// `s.uv * 8` is legal too, but a literal that reads as an integer is one
// promotion rule away from surprising somebody, and the generated text is read by
// whoever is debugging the stack. Non-finite is refused rather than emitted —
// `NaN` is not a Slang literal at all, and the compile error it causes points at
// generated code.
//
// **The shortest spelling that survives the round trip to float32**, which is the
// half worth explaining. Every number here ends up in a `float` in the shader, and
// most of them arrived as float32 already — a `baseColorFactor` read out of a glTF
// is a float widened to a double, so an opacity of 0.3 reaches this function as
// 0.30000001192092896. Printing that is correct and unreadable, and the generated
// body is the thing somebody reads when a stack looks wrong. So the precision is
// raised until the value parses back to the same float32, which prints `0.3` for
// that number and `0.1234568` for one that genuinely needs the digits. Nothing is
// lost: the device rounds to the same bits either way.
function num(v, what) {
	if (typeof v !== 'number' || !Number.isFinite(v)) {
		throw new TypeError(`${what} wants a finite number, not ${String(v)}`);
	}
	const f = Math.fround(v);
	for (let digits = 1; digits <= 9; digits++) {
		const text = f.toPrecision(digits);
		if (Math.fround(parseFloat(text)) === f) return decimal(text);
	}
	return decimal(String(f));
}

// A number's text with a decimal point in it, so Slang reads a float rather than
// an int. `toPrecision` may answer in exponential form for a very small or very
// large value — `1.0e-7` — which is already a float literal and is left alone.
function decimal(text) {
	if (text.includes('.') || text.includes('e') || text.includes('E')) return text;
	return `${text}.0`;
}

function vec3(v, what) {
	if (!Array.isArray(v) || v.length !== 3) {
		throw new TypeError(`${what} wants three numbers, like [1, 0.5, 0.2]`);
	}
	return `float3(${v.map((c, i) => num(c, `${what}[${i}]`)).join(', ')})`;
}

function checkTexture(v, what) {
	if (v === null || v === undefined) return null;
	if (!(v instanceof Texture)) {
		throw new TypeError(`${what} wants a three.texture(path) or a three.DataTexture, or null for none`);
	}
	return v;
}

// A 0-to-1 number a layer stated, or null for one it left out.
//
// **Null rather than a default, and the pair is the reason.** glTF's own defaults
// for `metallicFactor` and `roughnessFactor` are 1 and 1, so filling them in here
// would turn `{ roughness: 0.2 }` — a layer asking to be smooth — into a layer
// that is also fully metallic, which is the trap the importer spent this long
// avoiding. A layer states what it states, and says nothing about the other.
function factor(v, what) {
	if (v === undefined || v === null) return null;
	if (typeof v !== 'number' || !Number.isFinite(v) || v < 0 || v > 1) {
		throw new TypeError(`${what} wants a number from 0 to 1, not ${String(v)}`);
	}
	return v;
}

// Whether a layer says anything about how light behaves on it, as opposed to
// what colour it is. Asked twice — once to decide whether the stack needs a
// second chain at all, and once per layer to decide whether it joins it.
function surfaces(layer) {
	return layer.roughness !== null || layer.metalness !== null
		|| layer.metallicRoughness !== null;
}

// `{ strength, distance }` — the extension's own two numbers, and Blender's Bump
// node's before that.
//
// **`distance` is in metres**, which is what it means in the file and in the node
// it came out of. `parallax_uv` solves the uv gradient per pixel, so it stays
// metres whatever the surface is tiled at rather than becoming a number that has
// to be retuned per mesh. `strength` is the 0-to-1 amount beside it, and the two
// multiply into the single depth the generated source carries — nothing needs
// them apart except the exporter, which is handed both.
function readBump(raw, what) {
	if (raw === null || raw === undefined) return { strength: 1, distance: 1 };
	if (typeof raw !== 'object' || Array.isArray(raw)) {
		throw new TypeError(`${what}: bump wants { strength, distance }, like { distance: 0.05 }`);
	}
	for (const key of Object.keys(raw)) {
		if (key !== 'strength' && key !== 'distance') {
			throw new TypeError(`${what}: bump has no option called '${key}' — it takes strength, distance`);
		}
	}
	const strength = raw.strength ?? 1;
	const distance = raw.distance ?? 1;
	for (const pair of [['strength', strength], ['distance', distance]]) {
		if (typeof pair[1] !== 'number' || !Number.isFinite(pair[1])) {
			throw new TypeError(`${what}: bump.${pair[0]} wants a finite number, not ${String(pair[1])}`);
		}
	}
	return { strength, distance };
}

// One layer, checked and reduced to the handful of facts the emitter needs.
//
// Everything the caller may have left out is filled in here rather than at the
// point of use, so the emitter below reads as a description of the *shader* and
// not as a pile of `??`s. `at` is the index and `label` is how a refusal names
// this layer — its own `name` when it has one, because a stack imported from a
// glTF carries the names an artist gave the layers and "layer 3" is a worse
// thing to be told than "layer 3 'moss'".
function readLayer(raw, at) {
	if (raw === null || typeof raw !== 'object') {
		throw new TypeError(`layer ${at} wants an object like { map, mask: 'r', blend: 'multiply' }`);
	}
	const label = typeof raw.name === 'string' && raw.name ? `layer ${at} '${raw.name}'` : `layer ${at}`;

	for (const key of Object.keys(raw)) {
		if (UNSUPPORTED[key] !== undefined) {
			throw new TypeError(`${label}: ${key} is not supported — ${UNSUPPORTED[key]}`);
		}
		if (!LAYER_KEYS.has(key)) {
			throw new TypeError(
				`${label} has no option called '${key}' — it takes ${[...LAYER_KEYS].join(', ')}`
			);
		}
	}

	const blend = raw.blend ?? 'mix';
	if (typeof blend !== 'string' || BLEND[blend] === undefined) {
		throw new TypeError(
			`${label}: '${String(blend)}' is not a blend mode — use one of ${Object.keys(BLEND).join(', ')}`
		);
	}

	// Where the weight comes from, and then which channel of it.
	//
	// **A vertex-colour mask is drawn rather than refused as of the draw buffer.**
	// It used to be the one refusal that was about the mesh rather than about the
	// shader — the loader read positions, normals and uv0 and stopped, and
	// `mesh.color` is per *instance*, one value for a whole copy and so not a thing
	// that can vary across a surface. What changed is that the geometry contract
	// moved out of the push block, so a fourth stream cost 8 bytes of a buffer
	// instead of 8 of the 128 bytes every material's uniforms were competing over.
	// `scene/asset.c3` uploads COLOR_0 and `s.vertex_color` is what this reads.
	const source = raw.maskSource ?? 'texture';
	if (typeof source !== 'string' || !MASK_SOURCES.has(source)) {
		throw new TypeError(
			`${label}: maskSource is '${String(source)}' — it reads from a 'texture' or from 'vertexColor'`
		);
	}
	const vertexMask = source === 'vertexColor';

	const rawMask = raw.mask;
	let channel = null;
	if (rawMask !== null && rawMask !== undefined) {
		if (typeof rawMask !== 'string' || CHANNELS[rawMask] === undefined) {
			throw new TypeError(
				`${label}: mask wants which channel to read the weight from — 'r', 'g', 'b' or 'a'`
			);
		}
		channel = CHANNELS[rawMask];
	}

	const own = checkTexture(raw.maskTexture, `${label}: maskTexture`);
	// Two sources named at once is a contradiction rather than a precedence
	// question: whichever one this file picked, the other is a texture the caller
	// meant to be read and a binding that would be spent on nothing.
	if (own !== null && vertexMask) {
		throw new TypeError(
			`${label}: maskSource is 'vertexColor' and a maskTexture was given too — `
			+ 'the weight comes from one of them, so drop whichever is not meant'
		);
	}
	// A source named without a channel reads red, which is what a single-channel
	// mask painted into a colour attribute or a greyscale image is.
	if ((own !== null || vertexMask) && channel === null) channel = 'r';

	const uvScale = raw.uvScale === undefined ? [1, 1]
		: typeof raw.uvScale === 'number' ? [raw.uvScale, raw.uvScale]
		: raw.uvScale;
	if (!Array.isArray(uvScale) || uvScale.length !== 2) {
		throw new TypeError(`${label}: uvScale wants a number, or [u, v]`);
	}
	const uvOffset = raw.uvOffset ?? [0, 0];
	if (!Array.isArray(uvOffset) || uvOffset.length !== 2) {
		throw new TypeError(`${label}: uvOffset wants [u, v]`);
	}
	// Whether the scale and offset above are a window into the image or a tiling
	// of it. See `layerUv` for what changes and why the two cannot both be the
	// same pair of numbers.
	if (raw.uvWindow !== undefined && typeof raw.uvWindow !== 'boolean') {
		throw new TypeError(`${label}: uvWindow wants true or false, not ${String(raw.uvWindow)}`);
	}
	const uvWindow = raw.uvWindow === true;

	const tint = raw.tint ?? [1, 1, 1];
	if (!Array.isArray(tint) || tint.length !== 3) {
		throw new TypeError(`${label}: tint wants three numbers, like [0.9, 0.95, 1]`);
	}
	const opacity = raw.opacity ?? 1;
	if (typeof opacity !== 'number' || !Number.isFinite(opacity) || opacity < 0 || opacity > 1) {
		throw new TypeError(`${label}: opacity wants a number from 0 to 1, not ${String(raw.opacity)}`);
	}
	// **White when there is a texture and black when there is not**, which is the
	// one place this diverges from glTF's own default of black. In a file the
	// factor is always written, so the divergence never reaches an imported stack;
	// in a script `{ emissive: glow }` with no factor beside it means "this glows",
	// and glTF's default would answer that with a sampler bound, a lerp emitted and
	// a result multiplied by zero — a layer that costs a binding and emits nothing.
	const emissiveTexture = checkTexture(raw.emissive, `${label}: emissive`);
	const emissiveFactor = raw.emissiveFactor ?? (emissiveTexture !== null ? [1, 1, 1] : [0, 0, 0]);
	if (!Array.isArray(emissiveFactor) || emissiveFactor.length !== 3) {
		throw new TypeError(`${label}: emissiveFactor wants three numbers`);
	}

	// The other half of what a layer can say about its surface, and the half
	// that used to be refused. `metallicRoughness` is packed glTF's way — green
	// is roughness and blue is metalness — and the two factors multiply it,
	// exactly as they do on a core material.
	const metallicRoughness = checkTexture(raw.metallicRoughness, `${label}: metallicRoughness`);
	const roughness = factor(raw.roughness, `${label}: roughness`);
	const metalness = factor(raw.metalness, `${label}: metalness`);

	// The relief. `height` with no `bump` beside it takes the extension's own
	// defaults, which are a strength and a distance of 1 — a metre of relief,
	// which is a great deal of it and is what the file says when it says nothing.
	const height = checkTexture(raw.height, `${label}: height`);
	const bump = readBump(raw.bump, label);

	return {
		at,
		label,
		name: typeof raw.name === 'string' ? raw.name : '',
		map: checkTexture(raw.map, `${label}: map`),
		normal: checkTexture(raw.normal, `${label}: normal`),
		emissive: emissiveTexture,
		emissiveFactor,
		metallicRoughness,
		roughness,
		metalness,
		height,
		bump,
		// What the shader carries: one number, because that is all it needs. The
		// two survive separately beside it for the exporter, which writes the
		// extension's own pair back.
		depth: bump.strength * bump.distance,
		tint,
		opacity,
		blend,
		channel,
		vertexMask,
		maskTexture: own,
		invert: raw.invert === true,
		uvScale,
		uvOffset,
		uvWindow,
		enabled: raw.enabled !== false,
		animated: raw.animated === true,
		// Filled in by the emitter, which is the only thing that decides what a
		// binding is called. Nothing above this file spells a sampler name, for
		// the reason `MATERIAL_BINDING_FIRST` spells out about binding numbers.
		samplers: {},
	};
}

// The uv a layer's detail maps are sampled at.
//
// `surface` is `s.uv` for an ordinary stack and the parallax-shifted uv for one
// with a base height map, which is what makes a layer's tiling sit on the relief
// rather than beside it.
//
// `s.uv` already carries `material.repeat` and `material.offset` — the fragment
// stage applies them before the body runs (`shaders/material.slang`) — so this
// composes with them rather than replacing them: the material's transform moves
// the whole stack and a layer's own scale tiles that layer inside it. **The mask
// is deliberately not scaled by this.** A splat map describes where things are on
// a specific surface and tiling it would repeat the whole terrain; the detail
// maps are the things that want to repeat, which is the entire reason the two
// numbers are separate.
//
// **`uvWindow: true` turns the same two numbers into a window.** Without it a
// scale and an offset are one affine map, so tiling and windowing are the same
// axis and cannot both happen: `uvScale: 4` beside `uvOffset: [0, 0.5]` runs the
// uv from 0.5 to 4.5 and walks straight out of whatever band the offset put it
// in. With it the surface uv wraps to one tile first, so the scale is a band size
// and the offset is where that band starts — a terrain's four materials come out
// of one sheet, and the tiling is `material.repeat`, which is applied before the
// body runs and is therefore inside the `frac`.
function layerUv(layer, surface) {
	const [su, sv] = layer.uvScale;
	const [ou, ov] = layer.uvOffset;
	let uv = layer.uvWindow ? `frac(${surface})` : surface;
	if (su !== 1 || sv !== 1) uv = `${uv} * float2(${num(su, 'uvScale[0]')}, ${num(sv, 'uvScale[1]')})`;
	if (ou !== 0 || ov !== 0) uv = `${uv} + float2(${num(ou, 'uvOffset[0]')}, ${num(ov, 'uvOffset[1]')})`;
	return uv;
}

// The screen-space gradients of a windowed layer's uv, *unwrapped* — the ones
// the surface actually has, with no `frac` in them.
//
// **This is the whole of whether a window works**, and it is `stochastic_sample`'s
// rule for the same reason: `frac` jumps by a whole tile at every boundary, so the
// derivatives the hardware computes for itself are enormous exactly along the
// seams, which picks the smallest mip there and draws a blurred line around every
// tile. The gradients below are the wrap's own — the band's scale times the
// surface's — so every tap on a windowed layer is a `SampleGrad` with these.
function windowGradients(layer, surface, i) {
	const [su, sv] = layer.uvScale;
	const scale = su !== 1 || sv !== 1
		? ` * float2(${num(su, 'uvScale[0]')}, ${num(sv, 'uvScale[1]')})`
		: '';
	return [
		`    float2 gx${i} = ddx(${surface})${scale};`,
		`    float2 gy${i} = ddy(${surface})${scale};`,
	];
}

// The whole material, as Slang.
//
// Returns the source and the sampler table beside it, because the two are
// decided together: a layer with no normal map declares no normal sampler, and a
// disabled layer declares nothing at all. Building the table separately would
// mean two places that have to agree about which images a stack actually uses,
// and a binding the layout declares and the draw never writes is undefined
// behaviour no validation layer reports.
function emit(base, layers) {
	const textures = {};
	const uniforms = {};
	const body = [];

	// The shared mask, declared once however many layers read a channel of it.
	// That is the economy the extension's per-layer `channel` field is for: four
	// layers over one RGBA image is one sampler, and four separate greyscale
	// masks is four.
	const sharing = layers.filter(l => l.channel !== null && l.maskTexture === null && !l.vertexMask);
	const shared = sharing.length > 0;
	if (shared) {
		// **Refused rather than left to start white.** An undeclared sampler is
		// bound to the 1x1 opaque white image (`render/bind.c3`), so a channel read
		// off a mask nobody supplied is a weight of exactly 1 — every layer covering
		// everything, in stack order, with only the last one visible. That renders
		// as "the blend modes do not work" and sends whoever is reading it to this
		// file, when what actually happened is that a texture was left out one call
		// higher up.
		if (base.mask === null) {
			throw new TypeError(
				`${sharing.map(l => l.label).join(', ')} read a channel of the shared mask and no `
				+ '`mask` texture was given — pass one, or give the layer its own `maskTexture`'
			);
		}
		textures.layer_mask = base.mask;
	}

	const anyNormal = base.normal !== null || layers.some(l => l.normal !== null);
	const anyEmissive = layers.some(l => l.emissive !== null || l.emissiveFactor.some(c => c !== 0));
	// Whether anything in the stack has an opinion about how light behaves here,
	// as opposed to what colour it finds. A stack with none pays nothing: no
	// second chain, and `standard` reads the material's own pair exactly as it
	// did before a layer could say anything about it.
	const anySurface = layers.some(l => surfaces(l));

	body.push('float3 shade(Surface s)');
	body.push('{');

	// The uv everything on this surface is sampled at.
	//
	// **A base height map moves it, and then it moves for everything** — the base
	// colour, the base normal, the shared mask and every layer's own tiling.
	// Relief is a property of the surface rather than of one image on it, so a
	// stack whose mask stayed put while its colour slid would come apart at
	// exactly the grazing angles parallax exists for.
	//
	// The height is sampled at the *unshifted* uv, because that is the one step
	// this does: the pixel asks what is under it and the answer says where to
	// look instead.
	let surface = 's.uv';
	// Where a mask is sampled, and it is **not** `surface`. A mask describes one
	// specific surface — where the mud is on this terrain — while every other image
	// in a stack is a pattern laid across it, so a stack whose base map wants
	// `material.repeat = [12, 12]` would otherwise get twelve copies of its splat
	// map with it. `s.mesh_uv` is the mesh's own uv with the material's transform
	// left off, which is what a mask has always meant.
	let mask_uv = 's.mesh_uv';
	let albedo = 's.albedo';
	// Whether anything reads a mask, so that the second parallax below is emitted
	// only for a stack that has one.
	const anyMask = shared || layers.some(l => l.maskTexture !== null);
	if (base.height !== null && base.depth !== 0) {
		textures.base_height_map = base.height;
		body.push(
			`    float bh = base_height_map.Sample(s.uv).r;`
		);
		body.push(
			`    float2 puv = parallax_uv(s, s.uv, bh, `
			+ `${num(base.depth, 'LayeredMaterial: bump')});`
		);
		// The same relief, solved in the mesh's own uv. One height and one depth,
		// so it is the same physical displacement — `parallax_uv` works the world
		// size of a uv unit out from the derivatives of whichever uv it is handed,
		// so the two answers agree about where the surface moved to and disagree
		// only about which coordinates say so.
		if (anyMask) {
			body.push(
				`    float2 muv = parallax_uv(s, s.mesh_uv, bh, `
				+ `${num(base.depth, 'LayeredMaterial: bump')});`
			);
			mask_uv = 'muv';
		}
		surface = 'puv';
		// `s.albedo` was sampled at `s.uv` by the template before this body ran, so
		// the base colour is the one thing parallax cannot reach by moving a uv —
		// it has to be built again. `base_albedo` is the template's own line.
		albedo = 'base_albedo(s, puv)';
	}

	// `s.albedo` is the base colour factor times `map` times the instance's own
	// colour, already assembled by the template. So the bottom of the stack costs
	// nothing here and a `LayeredMaterial` with no layers at all shades exactly as
	// a MeshLambertMaterial does.
	body.push(`    float3 c = ${albedo};`);
	if (anyEmissive) body.push('    float3 e = float3(0.0, 0.0, 0.0);');
	// The second chain, starting where the first one does: at what the material
	// itself says. `material.roughness` and `material.metalness` are the bottom of
	// the stack for these two exactly as the base colour is for the first.
	if (anySurface) {
		body.push('    float rough = s.roughness;');
		body.push('    float metal = s.metalness;');
	}
	if (anyNormal) {
		// Flat, in tangent space: 0.5 is "no tilt" on the x and y axes and 1.0 is
		// straight out along z. The layers lerp *texels* over this and one
		// `mapped_normal` decodes the result, which is one cotangent frame for the
		// whole stack rather than one per layer.
		if (base.normal !== null) {
			textures.base_normal_map = base.normal;
			body.push(`    float3 nt = base_normal_map.Sample(${surface}).rgb;`);
		} else {
			body.push('    float3 nt = float3(0.5, 0.5, 1.0);');
		}
	}
	if (shared) body.push(`    float4 mask = layer_mask.Sample(${mask_uv});`);

	for (const layer of layers) {
		const i = layer.at;
		let uv = layerUv(layer, surface);
		// One tap of one of this layer's images. A windowed layer samples with the
		// unwrapped gradients and every other layer samples the ordinary way, so
		// nothing already written changes shape.
		const tap = layer.uvWindow
			? (name, at) => `${name}.SampleGrad(${at}, gx${i}, gy${i})`
			: (name, at) => `${name}.Sample(${at})`;
		body.push('');
		body.push(`    // ${layer.label}${layer.blend === 'mix' ? '' : `, ${layer.blend}`}`);

		// What this layer has to say, before anything is emitted for it.
		//
		// **A layer states a colour when it has one to state**, and white is not
		// one: it is what `baseColorFactor` defaults to in the file and what a
		// script leaves out, so a layer with no `map` and no tint is a layer that
		// said nothing about colour rather than one that asked for white paint.
		// Emitting `lerp(c, white, w)` for it was wrong in both directions — a
		// glow-only layer bleached whatever was under it, and a detail-normal layer
		// did the same while looking like the mask was inverted. A stack that
		// really does want white paint says so with a texture; `blend: 'mix'` over
		// a white `map` is the same thing and is visible in the description.
		const paints = layer.animated || layer.map !== null || layer.tint.some(c => c !== 1);
		const shapes = layer.normal !== null;
		const glows = layer.emissive !== null || layer.emissiveFactor.some(c => c !== 0);
		const rough = surfaces(layer);
		if (!paints && !shapes && !glows && !rough) {
			// Left in the source rather than dropped silently. A stack imported from
			// a file has one of these wherever a layer states only something this
			// renderer has no equation for — subsurface is the one left — and reading
			// "nothing to apply" in the generated body is what tells whoever is
			// debugging it that the layer arrived and was understood, rather than
			// that the importer lost it.
			//
			// A height map alone lands here too, and correctly: parallax moves the uv
			// a layer samples *its own* maps at, so a layer with relief and no images
			// has moved nothing.
			body.push(`    // nothing to apply — no map, tint, normal, emissive or surface`);
			continue;
		}

		// The gradients a window samples with, declared once for the layer and
		// before anything reads them. Nothing is emitted for a layer that has no
		// window, which is every layer written before this existed.
		if (layer.uvWindow) body.push(...windowGradients(layer, surface, i));

		// The weight. A layer with no mask at all is visible everywhere, which is
		// the extension's own default and is what a full-coverage tint or a
		// straight overlay wants.
		let w = '1.0';
		if (layer.vertexMask) {
			// No sampler and no binding: the attribute is interpolated across the
			// triangle and arrives in `Surface`. This is the one mask that costs
			// nothing but the stream the mesh already carries.
			w = `s.vertex_color.${layer.channel}`;
		} else if (layer.maskTexture !== null) {
			const name = `layer${i}_mask`;
			textures[name] = layer.maskTexture;
			layer.samplers.mask = name;
			w = `${name}.Sample(${mask_uv}).${layer.channel}`;
		} else if (layer.channel !== null) {
			w = `mask.${layer.channel}`;
		}
		if (layer.invert) w = `1.0 - ${w}`;

		// The opacity rides on the weight rather than on the colour, so that a
		// half-opaque layer fades towards what is under it instead of towards
		// black — which is what `opacity` means everywhere else in this API.
		if (layer.animated) {
			uniforms[`layer${i}_params`] = [...layer.tint, layer.opacity];
			layer.samplers.params = `layer${i}_params`;
			w = `(${w}) * layer${i}_params.a`;
		} else if (layer.opacity !== 1) {
			w = `(${w}) * ${num(layer.opacity, `${layer.label}: opacity`)}`;
		}

		body.push(`    float w${i} = ${w};`);

		// This layer's own relief, on top of whatever the base already shifted.
		// Local to the layer: it moves this layer's map, normal, emissive and
		// metallic-roughness and nothing else, because that is where the extension
		// puts a per-layer height and it is the only reading under which two layers
		// can each have their own.
		if (layer.height !== null && layer.depth !== 0) {
			const name = `layer${i}_height`;
			textures[name] = layer.height;
			layer.samplers.height = name;
			body.push(`    float2 uv${i} = ${uv};`);
			// The windowed form takes the unwrapped gradients too: `parallax_uv`
			// works out the world size of a uv unit from the derivatives, and a
			// `frac` seam would tell it a texel is the width of the screen.
			body.push(
				layer.uvWindow
					? `    uv${i} = parallax_uv(s, uv${i}, gx${i}, gy${i}, `
						+ `${tap(name, `uv${i}`)}.r, ${num(layer.depth, `${layer.label}: bump`)});`
					: `    uv${i} = parallax_uv(s, uv${i}, ${name}.Sample(uv${i}).r, `
						+ `${num(layer.depth, `${layer.label}: bump`)});`
			);
			uv = `uv${i}`;
		}

		// This layer's own colour, before it is blended with what is below. Only
		// emitted when the layer states one — see `paints` above.
		if (paints) {
			const parts = [];
			if (layer.animated) {
				parts.push(`layer${i}_params.rgb`);
			} else if (layer.tint.some(c => c !== 1)) {
				parts.push(vec3(layer.tint, `${layer.label}: tint`));
			}
			if (layer.map !== null) {
				const name = `layer${i}_map`;
				textures[name] = layer.map;
				layer.samplers.map = name;
				parts.push(`${tap(name, uv)}.rgb`);
			}
			body.push(`    float3 b${i} = ${parts.join(' * ')};`);
			body.push(`    c = lerp(c, ${BLEND[layer.blend](`c`, `b${i}`)}, w${i});`);
		}

		if (layer.normal !== null) {
			const name = `layer${i}_normal`;
			textures[name] = layer.normal;
			layer.samplers.normal = name;
			// The texels are mixed, not the decoded directions. Two normals
			// averaged after decoding drift off the unit sphere and have to be
			// renormalized per layer; mixing what was sampled costs one lerp and
			// leaves exactly one decode at the bottom.
			body.push(`    nt = lerp(nt, ${tap(name, uv)}.rgb, w${i});`);
		}
		if (layer.emissive !== null || layer.emissiveFactor.some(c => c !== 0)) {
			const emissive = [];
			if (layer.emissiveFactor.some(c => c !== 1)) {
				emissive.push(vec3(layer.emissiveFactor, `${layer.label}: emissiveFactor`));
			}
			if (layer.emissive !== null) {
				const name = `layer${i}_emissive`;
				textures[name] = layer.emissive;
				layer.samplers.emissive = name;
				emissive.push(`${tap(name, uv)}.rgb`);
			}
			body.push(`    e = lerp(e, ${emissive.join(' * ')}, w${i});`);
		}

		// The second chain: roughness and metalness, mixed by the same weight and
		// through the same blend mode as the colour.
		//
		// **The same blend mode, deliberately.** Every entry in `BLEND` is
		// arithmetic that works on a scalar as well as it does on a float3, and a
		// layer that multiplies its colour down almost always means to multiply its
		// roughness the same way — moss over stone is one statement, not two. Two
		// rules where one will do is a thing to look up rather than a thing to know.
		if (rough) {
			if (layer.metallicRoughness !== null) {
				const name = `layer${i}_surface`;
				textures[name] = layer.metallicRoughness;
				layer.samplers.metallicRoughness = name;
				// glTF's packing, unchanged: green is roughness and blue is metalness,
				// and red is the occlusion channel this renderer has no term for.
				body.push(`    float2 mr${i} = ${tap(name, uv)}.gb;`);
			}
			const pair = [
				['rough', 'roughness', layer.roughness, `mr${i}.x`],
				['metal', 'metalness', layer.metalness, `mr${i}.y`],
			];
			for (const [into, what, given, sampled] of pair) {
				const parts = [];
				// The factor multiplies the map, which is glTF's own rule — and a
				// factor of 1 beside a map is the map, so it is left out of the source
				// rather than written as a multiply by one.
				if (given !== null && (layer.metallicRoughness === null || given !== 1)) {
					parts.push(num(given, `${layer.label}: ${what}`));
				}
				if (layer.metallicRoughness !== null) parts.push(sampled);
				if (parts.length === 0) continue;
				body.push(`    float ${into}${i} = ${parts.join(' * ')};`);
				body.push(`    ${into} = lerp(${into}, ${BLEND[layer.blend](into, `${into}${i}`)}, w${i});`);
			}
		}
	}

	body.push('');
	// Back onto the surface, because `standard` is what reads them and it reads
	// them off `s`. Clamped once here for the blend modes that can leave the range
	// — `add` and `screen` both can — which is the same clamp `setSurface` applies
	// at the other door into these two numbers.
	if (anySurface) {
		body.push('    s.roughness = saturate(rough);');
		body.push('    s.metalness = saturate(metal);');
	}
	// `mapped_normal` is the template's own — a tangent frame rebuilt per pixel
	// from the screen-space derivatives, because no mesh here carries tangents.
	// Without a normal map anywhere in the stack there is nothing to decode and
	// the interpolated normal is used as it arrives.
	body.push(anyNormal ? '    float3 n = mapped_normal(s, nt);' : '    float3 n = s.normal;');
	// `standard(s, c, n)` rather than `c * lambert(n)`: the blended colour and the
	// mapped normal are the body's own, and so are the roughness and metalness by
	// the time this line runs — the two lines above put them back on `s`, which is
	// where `standard` reads them. `reflectance` stays the material's; no layer has
	// one, because the extension has no field for it. On a stack that changed none
	// of them it is the same arithmetic `c * lambert(n)` was, so nothing already
	// written moves.
	body.push(anyEmissive ? '    return standard(s, c, n) + e;' : '    return standard(s, c, n);');
	body.push('}');

	return { fragment: body.join('\n'), textures, uniforms };
}

// A live view of one layer: which images it samples, and its tint and opacity
// when it asked to be animated.
//
// It exists so that the generated sampler names stay an implementation detail.
// `mat.layers[1].map = moss` is the line somebody writes; `mat.textures.layer1_map
// = moss` is the line that does the same thing and requires knowing what this
// file called the binding — and a name this file is free to change.
class LayerView {
	constructor(owner, layer) {
		this._owner = owner;
		this._layer = layer;
		this.name = layer.name;
		this.at = layer.at;
	}

	_sampler(which) {
		const name = this._layer.samplers[which];
		if (name === undefined) {
			throw new TypeError(
				`${this._layer.label} declared no ${which} — a sampler is part of the shader this stack `
				+ 'generated, so add it to the description and build the material again'
			);
		}
		return name;
	}

	get map() { return this._owner.textures[this._sampler('map')]; }
	set map(v) { this._owner.textures[this._sampler('map')] = v; }

	get normal() { return this._owner.textures[this._sampler('normal')]; }
	set normal(v) { this._owner.textures[this._sampler('normal')] = v; }

	get emissive() { return this._owner.textures[this._sampler('emissive')]; }
	set emissive(v) { this._owner.textures[this._sampler('emissive')] = v; }

	get maskTexture() { return this._owner.textures[this._sampler('mask')]; }
	set maskTexture(v) { this._owner.textures[this._sampler('mask')] = v; }

	get height() { return this._owner.textures[this._sampler('height')]; }
	set height(v) { this._owner.textures[this._sampler('height')] = v; }

	get metallicRoughness() { return this._owner.textures[this._sampler('metallicRoughness')]; }
	set metallicRoughness(v) { this._owner.textures[this._sampler('metallicRoughness')] = v; }

	// The two that are only there when the layer said `animated: true`.
	//
	// The refusal names the flag rather than saying "no such uniform", because
	// the caller did not misspell anything — they asked for a value that was
	// baked into the shader as a literal, and the fix is one word in the
	// description rather than a different property here.
	_params() {
		const name = this._layer.samplers.params;
		if (name === undefined) {
			throw new TypeError(
				`${this._layer.label} baked its tint and opacity into the shader — say { animated: true } `
				+ 'on it to spend 16 of the material\'s 52 uniform bytes and make them settable'
			);
		}
		return name;
	}

	get tint() { return this._owner.uniforms[this._params()].slice(0, 3); }

	set tint(v) {
		const name = this._params();
		const was = this._owner.uniforms[name];
		if (!Array.isArray(v) || v.length !== 3) {
			throw new TypeError(`${this._layer.label}: tint wants three numbers, like [0.9, 0.95, 1]`);
		}
		this._owner.uniforms[name] = [v[0], v[1], v[2], was[3]];
	}

	get opacity() { return this._owner.uniforms[this._params()][3]; }

	set opacity(v) {
		const name = this._params();
		if (typeof v !== 'number' || !Number.isFinite(v) || v < 0 || v > 1) {
			throw new TypeError(`${this._layer.label}: opacity wants a number from 0 to 1, not ${String(v)}`);
		}
		const was = this._owner.uniforms[name];
		this._owner.uniforms[name] = [was[0], was[1], was[2], v];
	}

	toJSON() {
		return {
			name: this._layer.name,
			blend: this._layer.blend,
			mask: this._layer.channel,
			maskSource: this._layer.vertexMask ? 'vertexColor' : 'texture',
			invert: this._layer.invert,
			animated: this._layer.animated,
			// Read back rather than settable, unlike the tint beside them. They are
			// literals in the generated source and there is no `animated` for them:
			// a second float4 per layer would double what the stack spends of the
			// uniform budget for two numbers that describe a material rather than
			// something moving.
			roughness: this._layer.roughness,
			metalness: this._layer.metalness,
			bump: this._layer.height !== null ? { ...this._layer.bump } : null,
			samplers: { ...this._layer.samplers },
		};
	}
}

// An ordered stack of materials blended over a base one — the renderer's half of
// `CUSTOM_materials_layers`.
//
// The base material stays where core glTF puts it, in `map` and the mesh's own
// base colour factor, so a stack is genuinely *extra*: drop every layer and what
// is left renders as it always did. That is the property the extension is built
// around and it survives intact here, because `s.albedo` is where the stack
// starts.
export class LayeredMaterial extends ShaderMaterial {
	constructor(options) {
		if (options === null || typeof options !== 'object') {
			throw new TypeError(
				'new three.LayeredMaterial({ map, mask, layers }) wants an options object'
			);
		}
		for (const key of Object.keys(options)) {
			// `TOP_KEYS` first, because `roughness` and `metalness` are in both
			// tables: they are the material's to set and not a layer's, and the
			// entry in `UNSUPPORTED` is the sentence a *layer* is refused with.
			if (TOP_KEYS.has(key)) continue;
			if (UNSUPPORTED[key] !== undefined) {
				throw new TypeError(`LayeredMaterial: ${key} is not supported — ${UNSUPPORTED[key]}`);
			}
			{
				throw new TypeError(
					`LayeredMaterial has no option called '${key}' — it takes ${[...TOP_KEYS].join(', ')}`
				);
			}
		}

		const raw = options.layers ?? [];
		if (!Array.isArray(raw)) {
			throw new TypeError('`layers` wants an array of layer descriptions, outermost last');
		}
		const bump = readBump(options.bump, 'LayeredMaterial');
		const base = {
			map: checkTexture(options.map, 'LayeredMaterial: map'),
			normal: checkTexture(options.normal, 'LayeredMaterial: normal'),
			mask: checkTexture(options.mask, 'LayeredMaterial: mask'),
			// The base material's own relief, which is where the extension puts it
			// too — under `base`, beside nothing else, because core glTF has no slot
			// for a height map at all. It moves the uv for the whole stack.
			height: checkTexture(options.height, 'LayeredMaterial: height'),
			bump,
			depth: bump.strength * bump.distance,
		};

		// Read every layer before rejecting any of them for budget, so that a
		// description with a typo in layer 5 is told about the typo rather than
		// about the total — the typo is the thing they can act on.
		const all = raw.map((layer, at) => readLayer(layer, at));
		// **A disabled layer is dropped here rather than emitted and multiplied by
		// zero**, which is what makes `enabled: false` the way to get back under
		// the sampler budget rather than a flag that costs the same as being on.
		const layers = all.filter(l => l.enabled);

		const animated = layers.filter(l => l.animated);
		if (animated.length > ANIMATED_LIMIT) {
			throw new TypeError(
				`${animated.length} layers asked to be animated and a material has room for ${ANIMATED_LIMIT}: `
				+ `each one spends a float4 of the ${UNIFORM_BUDGET} uniform bytes in the push block. `
				+ `${animated.map(l => l.label).join(', ')} — drop \`animated\` from the ones that do not change.`
			);
		}

		const { fragment, textures, uniforms } = emit(base, layers);
		const count = Object.keys(textures).length;
		if (count > TEXTURE_LIMIT) {
			throw new TypeError(
				`this stack needs ${count} samplers and a material may declare ${TEXTURE_LIMIT}: `
				+ `${layers.length} layers over ${base.mask ? 'a shared mask' : 'no shared mask'}. `
				+ 'Pack the masks into the four channels of one texture, drop a layer\'s normal, '
				+ 'height or metallicRoughness map, or turn a layer off with { enabled: false }.'
			);
		}

		super({
			fragment,
			textures,
			uniforms,
			side: options.side ?? FrontSide,
			...(options.transparent !== undefined ? { transparent: options.transparent } : {}),
			...(options.blending !== undefined ? { blending: options.blending } : {}),
			...(options.opacity !== undefined ? { opacity: options.opacity } : {}),
			...(options.roughness !== undefined ? { roughness: options.roughness } : {}),
			...(options.metalness !== undefined ? { metalness: options.metalness } : {}),
			...(options.reflectance !== undefined ? { reflectance: options.reflectance } : {}),
		});

		// The base map goes through the inherited `map` setter rather than through
		// a sampler of its own: it is binding 0, the template samples it into
		// `s.albedo` before the body runs, and a second copy in a declared sampler
		// would be the same image bound twice and multiplied in twice.
		if (base.map !== null) this.map = base.map;

		this._layers = layers;
		this.layers = layers.map(l => new LayerView(this, l));

		// **The stack crosses a second time, as a description.** The first
		// crossing was the shader, and a shader cannot be read back: "this layer
		// multiplies" is a choice of expression by the time `emit` is done, and
		// `scene.export` needs the word to write `CUSTOM_materials_layers`. Until
		// this existed a stack loaded from a .glb exported intact and an identical
		// one written here exported as a flat colour, which is a difference no
		// script could see and none should have had to.
		//
		// Sampler *names* rather than the images behind them: the host resolves
		// them to bindings once and reads whatever is bound at export time, so
		// `mat.layers[1].map = moss` needs no second crossing to stay true.
		// `js/bind_shader.c3` and `ScriptLayer` carry that argument.
		H.beginMaterialLayers(
			this._index(),
			textures.layer_mask !== undefined ? 'layer_mask' : '',
			textures.base_normal_map !== undefined ? 'base_normal_map' : '',
			textures.base_height_map !== undefined ? 'base_height_map' : '',
			base.bump.strength,
			base.bump.distance,
		);
		for (const l of layers) {
			H.addMaterialLayer(
				this._index(),
				l.name,
				[
					l.samplers.map ?? '', l.samplers.normal ?? '', l.samplers.emissive ?? '',
					l.samplers.mask ?? '', l.samplers.params ?? '',
					l.samplers.metallicRoughness ?? '', l.samplers.height ?? '',
				].join(','),
				BLEND_BY_ORDINAL.indexOf(l.blend),
				l.vertexMask ? MASK_VERTEX_COLOR : (l.channel !== null ? MASK_TEXTURE : MASK_NONE),
				Math.max(0, CHANNEL_BY_ORDINAL.indexOf(l.channel ?? 'r')),
				l.invert,
				l.opacity,
				l.tint[0], l.tint[1], l.tint[2],
				l.emissiveFactor[0], l.emissiveFactor[1], l.emissiveFactor[2],
				// The extension's own defaults where the layer said nothing, because
				// this is the file's vocabulary rather than the description's: `null`
				// means "stated nothing" here and there is no such value in a glTF.
				// A layer that never mentioned either writes the two numbers a layer
				// that never mentioned either is read back as.
				l.metalness ?? 1,
				l.roughness ?? 1,
				l.bump.strength,
				l.bump.distance,
			);
		}
	}

	toJSON() {
		return {
			...super.toJSON(),
			type: 'LayeredMaterial',
			layers: this.layers.map(l => l.toJSON()),
		};
	}
}
