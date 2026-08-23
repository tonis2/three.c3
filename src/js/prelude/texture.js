// three.c3 — Texture and DataTexture: images on the device and their handles.

const H = globalThis.__three;

// Which space a texture's bytes are in. Three.js's strings, because a script
// written from memory of Three.js will spell them this way and comparing
// `tex.colorSpace === THREE.SRGBColorSpace` has to mean something.
//
// `NoColorSpace` and `LinearSRGBColorSpace` are one format here — RGBA8 read
// back as stored. They are separate names in Three.js because it also carries
// float textures, where the distinction is real; both are accepted so that a
// line copied from either idiom works.
export const NoColorSpace = '';
export const SRGBColorSpace = 'srgb';
export const LinearSRGBColorSpace = 'srgb-linear';

// **Which one to reach for.** SRGB for a picture of something: a base colour
// map, an albedo, anything an artist looked at while making it. Linear for a
// map whose channels are numbers rather than colours — a normal map's xyz, a
// roughness or metalness or occlusion map, a height field, a lookup table.
//
// Neither mistake announces itself. A colour map loaded linear is washed out
// and reads as a lighting bug; a normal map loaded sRGB has its "no tilt" 0.5
// decoded to 0.21, so every surface leans the same way and the detail goes
// soft — it reads as a bad bake, and the file is fine.
const SPACES = new Map([
	[SRGBColorSpace, 0],
	[LinearSRGBColorSpace, 1],
	[NoColorSpace, 1],
]);

// The options both texture verbs take, checked here so the message can name
// the key that was wrong.
//
// **Unknown keys are refused rather than ignored**, which is the opposite of
// what Three.js does and is deliberate. Three.js's Texture has two dozen
// settable fields and this has two; a script that writes
// `{ magFilter: THREE.NearestFilter }` and is quietly given linear filtering
// has no way to find that out, and the symptom — a blurry sprite — looks like
// the wrong asset rather than an unsupported option.
export function uploadOptions(options, what) {
	if (options === null || options === undefined) return { space: SRGBColorSpace, code: 0, mips: true };
	if (typeof options !== 'object') {
		throw new TypeError(
			`${what} wants an options object like { colorSpace: three.LinearSRGBColorSpace }, `
			+ `not ${typeof options}`);
	}

	for (const key of Object.keys(options)) {
		if (key !== 'colorSpace' && key !== 'generateMipmaps') {
			throw new TypeError(
				`${what} has no option called '${key}' — it takes colorSpace and generateMipmaps`);
		}
	}

	const { colorSpace = SRGBColorSpace, generateMipmaps = true } = options;
	if (!SPACES.has(colorSpace)) {
		throw new TypeError(
			`colorSpace '${colorSpace}' is not one this reads — use three.SRGBColorSpace for a colour map `
			+ 'or three.LinearSRGBColorSpace for a normal, roughness or height map');
	}
	if (typeof generateMipmaps !== 'boolean') {
		throw new TypeError(`generateMipmaps wants true or false, not ${typeof generateMipmaps}`);
	}

	return { space: colorSpace, code: SPACES.get(colorSpace), mips: generateMipmaps };
}

// An image on the device, and the handle a script holds it by.
//
// Three.js's TextureLoader is asynchronous and hands back a Texture that
// fills in later; this one is already uploaded by the time the constructor
// returns, so `width` and `height` are readable immediately and there is no
// onLoad. `await three.texture(...)` still works — awaiting a plain value is
// a no-op — so the Three.js-shaped line an agent writes is correct here.
//
// Deduplicated by the *content* of the decoded image, not by the path: two
// calls naming two files that hold the same picture are one upload, and so
// are a .png on disk and the identical image inside a .glb. Each call still
// answers with its own Texture holding its own reference, so disposing one
// does not disturb the other.
export class Texture {
	constructor(handle, path = null, colorSpace = SRGBColorSpace) {
		const [index, width, height, levels] = handle;
		this._t = index;
		// Null for a DataTexture, which came from no file. Reported as null
		// rather than as a made-up name like '<data>', so a script can ask
		// `if (tex.path)` and get an answer rather than a string that looks
		// like somewhere to look.
		this._path = path;
		this._width = width;
		this._height = height;
		this._levels = levels;
		this._colorSpace = colorSpace;
	}

	get width() { return this._width; }
	get height() { return this._height; }
	get path() { return this._path; }

	// Which space this image's bytes are read in. Fixed at upload: it is the
	// image's Vulkan format and there is nothing to change afterwards, which
	// is why this is a getter and not a settable field as it is in Three.js.
	// Load the file again with the other colourspace to get the other image.
	get colorSpace() { return this._colorSpace; }

	// How many mip levels the image has. 1 means the top level and nothing
	// below it, so the sampler has nothing to fall back on as the surface
	// shrinks — which is what asking for `generateMipmaps: false` buys, and
	// what a device that cannot filter this format gives regardless.
	get levels() { return this._levels; }

	// **Whether it got a chain, not whether one was asked for.** Three.js's
	// name for the request; this is the answer, so a script that asked for
	// mips on a device that cannot make them sees false here rather than the
	// true it passed in.
	get generateMipmaps() { return this._levels > 1; }

	// Whether this handle still names an image. False after dispose(), and
	// the reason a disposed Texture throws rather than quietly texturing
	// something with whatever took its slot.
	get alive() { return this._t >= 0; }

	// The pixels, copied back off the device, as a Uint8Array of RGBA
	// bytes — width * height * 4 of them, row by row from the top.
	//
	// **The bytes that went in, not the ones the shader sees.** The copy
	// converts nothing, so a texture made from a DataTexture reads back
	// byte-for-byte identical to the array it was built from, and a PNG
	// reads back as the PNG's own pixels. The sampler's sRGB-to-linear
	// decode happens at sample time and is not in here — which is also why
	// `colorSpace` makes no difference to what this returns.
	//
	// Level 0. The generated mip levels are approximations this engine made
	// up rather than anything a script handed over, and there is no verb to
	// ask for one.
	//
	// `into` is optional and exists because this is not free: it copies the
	// image off the device and waits for the queue, so a caller doing it
	// repeatedly should hand the same array back rather than allocate one
	// per call. Without it a fresh Uint8Array is made each time.
	read(into) {
		if (this._t < 0) {
			throw new TypeError('this texture has been disposed — read() it before dispose(), or keep a reference');
		}
		const need = this._width * this._height * 4;
		const out = into === undefined ? new Uint8Array(need) : into;
		if (!(out instanceof Uint8Array)) {
			throw new TypeError('texture.read(into) wants a Uint8Array, or nothing at all');
		}
		if (out.length < need) {
			throw new RangeError(
				`texture.read(into) needs ${need} bytes for this ${this._width}x${this._height} image, `
				+ `and was given ${out.length}`);
		}
		H.textureRead(this._t, out);
		return out;
	}

	// Give back the reference this handle holds.
	//
	// **Not a free.** The image goes only when nothing names it at all, so
	// disposing while a material still draws with it leaves that material
	// correct — which is what makes this safe to call as soon as a script is
	// done *referring* to the texture, rather than something to be timed
	// against the materials that use it.
	//
	// Disposing twice is not an error. The second call has nothing to give
	// back and says so by doing nothing, which is what makes dispose() safe
	// in a cleanup path that may run more than once.
	dispose() {
		if (this._t < 0) return;
		H.textureDispose(this._t);
		this._t = -1;
	}

	// What the host wants for a `map`: the index, or NoTexture for none.
	// Throws rather than falling back to NoTexture, because a disposed
	// texture assigned to a material is a mistake whose symptom is an
	// untextured mesh — indistinguishable from having forgotten the line.
	_index() {
		if (this._t < 0) {
			throw new TypeError(
				`this texture was disposed${this._path ? ` (${this._path})` : ''} — `
				+ `${this._path ? 'load' : 'build'} it again to use it`
			);
		}
		return this._t;
	}

	toJSON() {
		return {
			path: this._path,
			width: this._width,
			height: this._height,
			colorSpace: this._colorSpace,
			levels: this._levels,
			alive: this.alive,
		};
	}

	toString() {
		return `${this.constructor.name}(${this._path ?? 'data'} ${this._width}x${this._height})`;
	}
}

// Pixels a script built, uploaded as a texture — Three.js's name for exactly
// this, and the reason `Texture` is a class rather than a plain object.
//
// `new THREE.DataTexture(data, width, height, format)` there takes a format
// argument and needs `.needsUpdate = true` before it does anything. This one
// is RGBA8 only and is on the device by the time the constructor returns, so
// there is nothing to flag and nothing to schedule. The fourth argument is
// the same options object `three.texture` takes rather than a format, and
// `{ generateMipmaps: false }` is worth reaching for here more than there:
// generated pixels are as often a table indexed exactly — a palette, a ramp,
// a noise field — as a picture, and a blurred level of a table approximates
// nothing.
//
// **Deduplicated against every other texture**, which is worth knowing before
// building one in a loop: generated pixels and the identical image loaded
// from a .png land in one slot, because the content hash has no idea where
// bytes came from. Regenerating the same texture every frame costs one
// upload and a hash of the bytes — not nothing, but not an upload.
//
// A plain Array is accepted and widened. It is what a script most naturally
// builds, it has no contiguous bytes for the host to read, and refusing it
// over a detail of which container was used would be refusing the obvious
// thing for no reason the author can see. A Uint8Array skips the copy.
export class DataTexture extends Texture {
	constructor(data, width, height, options = null) {
		if (!Number.isInteger(width) || !Number.isInteger(height)) {
			throw new TypeError(
				'new three.DataTexture(data, width, height) wants whole-number dimensions'
			);
		}
		// Before the byte count, and that order is the point. 0x0 wants zero
		// bytes, so a count check reached first would answer "0 RGBA bytes and
		// 4 were given" — arithmetically true and useless. The dimensions are
		// what is wrong.
		if (width < 1 || height < 1) {
			throw new RangeError(
				`new three.DataTexture(data, width, height) wants positive dimensions, got ${width}x${height}`
			);
		}
		const bytes = data instanceof Uint8Array ? data
			: (Array.isArray(data) || data instanceof Uint8ClampedArray) ? new Uint8Array(data)
			: null;
		if (bytes === null) {
			throw new TypeError(
				'new three.DataTexture(data, ...) wants a Uint8Array or an Array of RGBA bytes, '
				+ `not ${data === null ? 'null' : typeof data}`
			);
		}
		// Checked here as well as in the host so the message can do the
		// arithmetic — "you gave 12288 and 64x64 needs 16384" is a sentence
		// somebody can act on without reaching for a calculator.
		if (bytes.length !== width * height * 4) {
			throw new RangeError(
				`${width}x${height} is ${width * height * 4} RGBA bytes and ${bytes.length} were given `
				+ '— four per pixel, in r, g, b, a order'
			);
		}
		const chosen = uploadOptions(options, 'new three.DataTexture(data, width, height, options)');
		super(H.dataTexture(bytes, width, height, chosen.code, chosen.mips), null, chosen.space);
	}
}
