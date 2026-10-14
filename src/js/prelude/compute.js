// three.c3 — three.compute: buffers, kernels and dispatches.
//
// This is the whole of the compute API a script sees below `three.compute`.
// The host verbs it stands on are numbers and views (see bind_compute.c3); what
// is here is the part that has to be readable — a buffer that knows its own
// element type, a kernel that remembers its threads, and a dispatch you can
// write in one line.
//
// The shapes worth keeping in mind:
//
//     const a = three.compute.f32(count, [...])       // a buffer of floats
//     const sum = three.compute.f32(1)
//     const kernel = three.compute.kernel(`
//         float a[];
//         float out[];
//         struct Push @pushconstant { uint n; }
//         Push push;
//         struct ComputeIn { uint3 thread @builtin(global_invocation_id); }
//         fn void main(ComputeIn input) @compute @threads(64, 1, 1) {
//             uint i = input.thread.x;
//             if (i >= push.n) return;
//             atomicAdd(out[0], a[i]);
//         }
//     `, { name: 'sum' })
//
//     kernel.run({ a, result: sum }, { push: { n: count }, threads: count })
//     sum.read()
//     console.log(sum.bytes[0])
//
// `run` dispatches and waits for the GPU; `read()` brings a buffer's bytes
// back into its own view. They are separate because a chain of kernels has one
// answer and does not want a round trip per step: `kernel.dispatch(...)` records
// without waiting, `three.compute.submit()` runs the whole chain, and the last
// `read()` takes the result. Everything else is the buffer and kernel objects
// themselves.

import { Texture, LinearSRGBColorSpace, NearestFilter, LinearFilter } from './texture.js';

const H = globalThis.__three;

// How a buffer's element type is spelled to the host: a code, its byte width,
// and how JavaScript should read the bytes back.
//
// 'bytes' is the untyped one: a pool, a packed block, whatever the shader says
// the bytes mean. It reads back as a Uint8Array like every other type reads
// back as its own view, so a script that knows its own layout is not forced to
// make one up here.
const TYPES = {
	bytes: { width: 1, view: Uint8Array },
	u8: { width: 1, view: Uint8Array },
	i8: { width: 1, view: Int8Array },
	f16: { width: 2, view: null }, // no JS view: read as bytes and decode yourself
	u16: { width: 2, view: Uint16Array },
	i16: { width: 2, view: Int16Array },
	f32: { width: 4, view: Float32Array },
	u32: { width: 4, view: Uint32Array },
	i32: { width: 4, view: Int32Array },
};

function typeOf(code) {
	const type = TYPES[code];
	if (!type) {
		throw new TypeError(
			`three.compute: no element type '${code}' — the ones there are: ${Object.keys(TYPES).join(', ')}`
		);
	}
	return type;
}

// The bytes a script handed over, whatever it handed over.
//
// A plain array of numbers, a typed array, an ArrayBuffer — all three are
// things a person reaches for, and all three mean the same thing here. What
// comes back is always a Uint8Array, because that is what the host verb reads
// and a view is cheaper to make than a promise about the input.
function asBytes(source, what) {
	if (source instanceof ArrayBuffer) return new Uint8Array(source);
	if (ArrayBuffer.isView(source)) {
		return new Uint8Array(source.buffer, source.byteOffset, source.byteLength);
	}
	if (Array.isArray(source)) return new Uint8Array(Float32Array.from(source).buffer);
	if (source && typeof source.length === 'number') return new Uint8Array(Array.from(source));
	throw new TypeError(`three.compute: ${what} wants an array, a typed array or an ArrayBuffer`);
}

// The floats, uints or bytes a script handed over, for a push block.
//
// A push block is bytes with a layout the shader wrote down, so a plain object
// has to be packed in the order its keys are listed, and each field in the
// width its C3 type has.
//
// A JavaScript number is a double and nothing about it says whether the shader
// field is a float or a `uint`, so the script says. Bare numbers are floats,
// because that is what most push fields are and `{ scale: 2 }` should mean
// 2.0; an integer field is written `three.compute.uint(n)`, which is one call
// and says which side of the line it is on:
//
//     push: { scale: 0.5, count: three.compute.uint(count) }
//
// Guessing from the value would be worse than asking: `{ n: 4 }` is a float
// field that happens to hold a whole number, and a packer that read integers
// into a `float n;` would put 4.0e-45 there instead of 4.
class UintValue {
	constructor(value) { this.value = value; }
}

function packPush(push, spec) {
	if (push === null || push === undefined) return null;
	if (ArrayBuffer.isView(push)) return new Uint8Array(push.buffer, push.byteOffset, push.byteLength);
	if (push instanceof ArrayBuffer) return new Uint8Array(push);
	if (typeof push !== 'object') {
		throw new TypeError('three.compute: push wants an object of the shader\'s push fields, or raw bytes');
	}

	const fields = spec || Object.keys(push);
	const words = [];
	for (const name of fields) {
		const raw = push[name];
		const whole = raw instanceof UintValue;
		const value = whole ? raw.value : raw;
		if (typeof value !== 'number' || !Number.isFinite(value)) {
			throw new TypeError(`three.compute: push.${name} wants a finite number, and the command object gave '${value}'`);
		}
		// `>>> 0` is the uint32 the shader's `uint` field reads; `floatBits` the
		// float its `float` field reads. Same four bytes, different meaning.
		words.push(whole ? (value >>> 0) : floatBits(value));
	}
	const out = new Uint8Array(words.length * 4);
	const view = new DataView(out.buffer);
	words.forEach((bits, i) => view.setUint32(i * 4, bits, true));
	return out;
}

// One to three counts, whatever shape they came in: `32` is one axis,
// `[32, 8]` is two, and a three-part array is three.
function asCounts(value) {
	if (typeof value === 'number') return [value, 1, 1];
	if (Array.isArray(value) || ArrayBuffer.isView(value)) return value;
	throw new TypeError('three.compute: a count wants a number or an array of up to three numbers');
}

const scratch = new DataView(new ArrayBuffer(4));
function floatBits(value) {
	scratch.setFloat32(0, value, true);
	return scratch.getUint32(0, true);
}

// A buffer, and the view of it a script reads.
//
// One object per handle: `.bytes` is the live view, so `read()` then
// `buf.bytes[i]` is how a result is looked at, and `buf.f32(i)` is the one
// element a script usually wants. The two directions are explicit — `write()`
// uploads, `read()` downloads — and `constructor` puts the two together:
//
//     const a = three.compute.f32(64, values)     // created and uploaded
//     a.write(moreValues)                         // uploaded again
//     a.read(); a.f32(0)                          // downloaded, then read
export class ComputeBuffer {
	constructor(handle, code, count) {
		const type = typeOf(code);
		this._handle = handle;
		this._type = code;
		this._count = count;
		this._byteLength = count * type.width;
		// The host copy is made the first time a script looks at it. A weights
		// buffer is gigabytes that JavaScript never reads, and the JS heap is
		// nowhere near that size.
		this._host = null;
		this._view = null;
		this.disposed = false;
	}

	// How many elements, as the buffer was made.
	get count() { return this._count; }
	// How many bytes those are.
	get byteLength() { return this._byteLength; }

	get _bytes() {
		if (this._host === null) {
			this._host = new Uint8Array(this._byteLength);
			const type = typeOf(this._type);
			this._view = type.view === null ? null : new type.view(this._host.buffer);
		}
		return this._host;
	}
	// The element type's name.
	get type() { return this._type; }

	// The elements as a typed array — a Float32Array for an `'f32'` buffer, and
	// the same live object every time.
	//
	// **Writing here changes the host copy and not the GPU's.** `write()` is the
	// upload, and `read()` is the download; this view is what the last download
	// landed in, and a fill done here is on its way to the GPU only once
	// `write()` submits it:
	//
	//   for (let i = 0; i < n; i++) a.bytes[i] = i;
	//   a.write(a.bytes);          // one upload for the whole fill, not n
	//
	// The two directions are separate on purpose: a buffer is read by a kernel,
	// not by JavaScript, and an implicit upload per element write would be `n`
	// submissions for a fill a script meant as one.
	get bytes() { const bytes = this._bytes; return this._view === null ? bytes : this._view; }

	// One element, by index. `buf.f32(0)` rather than `buf.f32()[0]`, because
	// the second is a view per call and the first is a byte read.
	f32(at = 0) { return this._float(at, Float32Array); }
	f64(at = 0) { return this._float(at, Float64Array); }
	u32(at = 0) { return this._int(at, Uint32Array); }
	i32(at = 0) { return this._int(at, Int32Array); }
	u8(at = 0) { return this._bytes[at | 0]; }

	_float(at, View) { return this._element(at, View, 4); }
	_int(at, View) { return this._element(at, View, 4); }

	_element(at, View, width) {
		const index = at | 0;
		if (index < 0 || (index + 1) * width > this._bytes.length) {
			throw new RangeError(`three.compute: element ${index} is outside a buffer of ${this._count} elements`);
		}
		return new View(this._bytes.buffer, this._bytes.byteOffset + index * width, 1)[0];
	}

	// Bring the buffer's bytes back from the GPU and into `.bytes`.
	//
	// Implicitly submits first — a read of work that has not run is the wrong
	// answer with no symptom, and the wait costs one device round trip that the
	// caller was going to pay anyway.
	read() {
		this._assertLive();
		H.computeReadBuffer(this._handle, this._bytes, this._byteLength);
		return this;
	}

	// `byteCount` bytes from `byteOffset`, as a new Uint8Array — a slice of a
	// buffer too large to want whole on the host, or a check of one row of it.
	readBytes(byteOffset = 0, byteCount = this._byteLength - byteOffset) {
		this._assertLive();
		const out = new Uint8Array(byteCount);
		H.computeReadBuffer(this._handle, out, byteCount, byteOffset);
		return out;
	}

	// Replace the buffer's contents and upload them.
	//
	// `byteOffset` is where in the buffer they go, zero when left out.
	write(source, byteOffset = 0) {
		this._assertLive();
		const bytes = asBytes(source, 'write()');
		if (bytes.length + byteOffset > this._byteLength) {
			throw new RangeError(
				`three.compute: write() was given ${bytes.length} bytes at ${byteOffset} for a buffer of ${this._byteLength}`
			);
		}
		// The host copy follows along only when there already is one: `read()` is
		// how a script asks for the GPU's bytes, and a write of a weights buffer
		// should not be the thing that allocates its twin in the JS heap.
		if (this._host !== null) this._host.set(bytes, byteOffset);
		// Bytes, not the element view: `js.bytes` takes a Uint8Array or an
		// ArrayBuffer and nothing else — handing it a Float32Array is a silent
		// no-op, which is a write that appears to work and a buffer that never
		// changes. `asBytes` has already made that view.
		H.computeWriteBuffer(this._handle, bytes, 0, bytes.length, byteOffset);
		return this;
	}

	// A range of this buffer, to bind where a whole buffer would go:
	//
	//   attention.dispatch({ q, k: cache.view(layer * layerBytes, layerBytes), ... })
	//
	// Offsets are bytes and must be multiples of `three.compute.limits.bindingAlignment`.
	// A size left out runs to the end of the buffer.
	view(byteOffset = 0, byteSize = 0) {
		this._assertLive();
		return new ComputeView(this, byteOffset, byteSize);
	}

	// What a dispatch binds: the handle, or the handle and a range.
	get _binding() { return this._h; }

	dispose() {
		if (this.disposed) return;
		H.computeFreeBuffer(this._handle);
		this.disposed = true;
		this._handle = null;
	}

	_assertLive() {
		if (this.disposed) throw new TypeError('three.compute: this buffer has been disposed');
	}

	// The handle, for the dispatch verb. Not part of the API a script reads.
	get _h() { this._assertLive(); return this._handle; }
}

// A range of a buffer, made by `buffer.view(offset, size)`.
export class ComputeView {
	constructor(buffer, byteOffset, byteSize) {
		if (!(byteOffset >= 0) || !(byteSize >= 0) || byteOffset + byteSize > buffer.byteLength) {
			throw new RangeError(
				`three.compute: view(${byteOffset}, ${byteSize}) is outside a buffer of ${buffer.byteLength} bytes`
			);
		}
		this.buffer = buffer;
		this.byteOffset = byteOffset;
		this.byteSize = byteSize;
	}
	get _binding() { return [this.buffer._h, this.byteOffset, this.byteSize]; }
}

// A compiled kernel: one shader, its bindings, and the workgroup size it was
// written with.
export class ComputeKernel {
	constructor(handle, source, threads) {
		this._handle = handle;
		this.source = source;
		this.threads = threads;
		this.disposed = false;
		// What each binding is, in binding order — `[name, kind, format]`, the
		// kind one of 'buffer', 'image' and 'texture'. Asked once: it is the
		// module's, and a kernel's module never changes.
		this._bindings = H.computeKernelBindings(handle);
	}

	// The bindings as the shader declares them: `[{ name, kind, format }]` in
	// binding order. `kind` is 'buffer', 'image' (a storage image the kernel
	// loads and stores) or 'texture' (a Sampler2D it samples); `format` is a
	// storage image's declared format, or '' when the host picks it.
	get bindings() {
		return this._bindings.map(([name, kind, format]) => ({ name, kind, format }));
	}

	// Record a dispatch and wait for it.
	//
	// The buffers are named rather than listed when the shader's bindings have
	// names — `run({ a, out, n: constant })` — and listed when they do not:
	//
	//   kernel.run([a, out], { threads: count })        // positional
	//   kernel.run({ a, out }, { threads: count })      // by binding name
	//
	// `threads` is a work-item count, split here by the entry point's own
	// `@threads`; `workgroups` is the group counts themselves, for a dispatch
	// that is about groups rather than about items.
	run(buffers, options = {}) {
		this.dispatch(buffers, options);
		H.computeSubmit();
		return this;
	}

	// Record a dispatch without waiting. `three.compute.submit()` is what runs
	// it — one wait for a chain of them, which is the reason this is separate.
	dispatch(buffers, options = {}) {
		this._assertLive();

		const list = Array.isArray(buffers)
			? buffers
			: this._byName(buffers, options.bindings);

		const push = packPush(options.push, options.pushFields || this.pushFields);
		const threads = options.threads === undefined ? null : options.threads;
		const workgroups = options.workgroups === undefined ? null : options.workgroups;

		let x = 0, y = 0, z = 0;
		if (workgroups !== null) {
			const groups = asCounts(workgroups);
			x = groups[0] | 0;
			y = (groups[1] === undefined ? 1 : groups[1]) | 0;
			z = (groups[2] === undefined ? 1 : groups[2]) | 0;
		} else if (threads !== null) {
			const items = asCounts(threads);
			x = items[0] | 0;
			y = (items[1] === undefined ? 1 : items[1]) | 0;
		}

		// `independent: true` leaves out the barrier after this dispatch: the
		// caller is saying the next command does not read what this one wrote.
		H.computeDispatch(
			this._handle, list.map((b, i) => this._bind(b, i)), push, x, y, z, options.independent === true
		);
		return this;
	}

	// What crosses for binding `i`: a buffer's handle or range, or an image's
	// texture index. Checked against what the shader declared there, so an image
	// handed to a buffer is refused naming both rather than reaching the host as
	// a number that happens to be a valid handle of the other kind.
	_bind(value, i) {
		const declared = this._bindings[i];
		const [name, kind] = declared || [`#${i}`, 'buffer'];
		const isImage = value instanceof Texture;
		if (kind === 'buffer') {
			if (isImage || !value || value._binding === undefined) {
				throw new TypeError(
					`three.compute: binding '${name}' is a buffer and was given ${describe(value)}`
				);
			}
			return value._binding;
		}
		if (!isImage) {
			throw new TypeError(
				`three.compute: binding '${name}' is ${kind === 'image' ? 'a storage image' : 'a texture the kernel samples'}`
				+ ` and was given ${describe(value)} — pass a three.compute.image()`
				+ (kind === 'texture' ? ' or a texture' : '')
			);
		}
		if (!value.alive) throw new TypeError(`three.compute: binding '${name}' was given a disposed image`);
		return value._t;
	}

	// The buffers as the shader declares them, in binding order.
	//
	// The names are the shader's own `float a[];` declarations, and the order
	// is the order they are written in, which is the order the host binds them
	// in. A name the shader does not have is refused here rather than becoming
	// a dispatch against the wrong buffer.
	_byName(named, declared) {
		// By the shader's own names when every key is one of them, which is what
		// lets `run({ out, field })` be written in any order. A key the shader
		// does not have keeps the order the keys were written in — what this did
		// before it knew the names, and what a module with no names needs.
		const names = this._bindings.map(([name]) => name);
		const keys = Object.keys(named);
		const byShader = !declared && names.length === keys.length && names.every((n) => n !== '' && n in named);
		const fields = declared || (byShader ? names : keys);
		const out = [];
		for (const name of fields) {
			const buffer = named[name];
			if (!buffer || (buffer._binding === undefined && !(buffer instanceof Texture))) {
				throw new TypeError(
					`three.compute: run() was given nothing to bind as '${name}' — name the shader's own bindings`
				);
			}
			out.push(buffer);
		}
		return out;
	}

	dispose() {
		if (this.disposed) return;
		H.computeFreeKernel(this._handle);
		this.disposed = true;
		this._handle = null;
	}

	_assertLive() {
		if (this.disposed) throw new TypeError('three.compute: this kernel has been disposed');
	}
}

// What a script handed over, for a message: a buffer, an image, or what it was.
function describe(value) {
	if (value instanceof ComputeImage) return `a ${value.format} image`;
	if (value instanceof Texture) return 'a texture';
	if (value instanceof ComputeBuffer || value instanceof ComputeView) return 'a buffer';
	return value === null || value === undefined ? 'nothing' : typeof value;
}

// The typed array a readback of each store fills, keyed by the name the host
// answers with. Half floats arrive as f32: there is no half in JavaScript.
const STORES = {
	f32: Float32Array,
	u8: Uint8Array,
	i8: Int8Array,
	u16: Uint16Array,
	i16: Int16Array,
	u32: Uint32Array,
	i32: Int32Array,
};

// An image a kernel writes: a `Texture` made by `three.compute.image()`.
//
// It is a texture in every sense a script uses one — a material's `map`, a
// post pass's `textures`, a kernel's `Sampler2D` — and one more: a kernel can
// store into it, as an `image2d<format>` binding. `read()` and `write()` move
// its texels as numbers rather than as RGBA bytes, in the typed array its
// format reads as: a Float32Array for rgba16f, r32f and the other float
// formats, a Uint32Array for r32ui.
//
//   const field = three.compute.image({ width: 256, height: 256, format: 'r32f' });
//   kernel.run({ field }, { threads: [256, 256] });
//   const values = field.read();          // Float32Array of 65536
export class ComputeImage extends Texture {
	constructor(fields, format) {
		super(fields, null, LinearSRGBColorSpace);
		this.format = format;
		this._components = fields[4];
		this._store = STORES[fields[5]];
		this._sampled = fields[6];
	}

	// How many numbers one texel reads back as.
	get components() { return this._components; }

	// The texels, as numbers: width * height * components of them, row by row
	// from the top. `into` is optional, and is the array to fill — this copies
	// the image off the device and waits, so a caller doing it every frame
	// should hand the same one back.
	read(into) {
		if (this._t < 0) throw new TypeError('three.compute: read() of a disposed image');
		const count = this._width * this._height * this._components;
		const out = into === undefined ? new this._store(count) : into;
		if (!(out instanceof this._store) || out.length < count) {
			throw new TypeError(
				`three.compute: a ${this.format} image reads into a ${this._store.name} of ${count}, `
				+ `and was given ${out && out.constructor ? out.constructor.name : typeof out}`
				+ (out && out.length !== undefined ? ` of ${out.length}` : '')
			);
		}
		H.computeReadImage(this._t, new Uint8Array(out.buffer, out.byteOffset, out.byteLength));
		return out;
	}

	// Replace every texel: the same layout `read()` gives, so a readback written
	// back is the image it came from. A plain array of numbers is accepted and
	// converted.
	write(data) {
		if (this._t < 0) throw new TypeError('three.compute: write() of a disposed image');
		const count = this._width * this._height * this._components;
		const values = data instanceof this._store ? data
			: Array.isArray(data) || ArrayBuffer.isView(data) ? this._store.from(data)
			: null;
		if (values === null || values.length < count) {
			throw new TypeError(
				`three.compute: a ${this._width}x${this._height} ${this.format} image is written from `
				+ `${count} numbers, and was given ${values === null ? typeof data : values.length}`
			);
		}
		H.computeWriteImage(this._t, new Uint8Array(values.buffer, values.byteOffset, values.byteLength));
		return this;
	}

	// Gives the image back. Like a texture's, a material still drawing with it
	// keeps it; unlike one, whatever the kernels have recorded runs first.
	dispose() {
		if (this._t < 0) return;
		H.computeFreeImage(this._t);
		this._t = -1;
	}

	// A material's map, or a post pass's texture. An integer image is neither:
	// a sampler would read its integers as floats.
	_index() {
		if (this._t >= 0 && !this._sampled) {
			throw new TypeError(
				`this ${this.format} image holds ${this.format.endsWith('ui') ? 'unsigned integers'
					: this.format.endsWith('i') ? 'integers' : 'texels this device cannot sample'} `
				+ 'and cannot be a texture — read it in a kernel as an image2d, or read() it back'
			);
		}
		return super._index();
	}

	save(path) {
		if (this.format !== 'rgba8') {
			throw new TypeError(`three.compute: save() writes rgba8 images, and this one is ${this.format} — read() it instead`);
		}
		return super.save(path);
	}

	toString() {
		return `ComputeImage(${this.format} ${this._width}x${this._height})`;
	}
}

// Whether a value is bytes a compiled module could be in: a typed array or an
// ArrayBuffer. A string is not, which is how `kernel` tells a shader source
// from a module that is already SPIR-V.
function hasBytes(value) {
	return value instanceof ArrayBuffer || ArrayBuffer.isView(value);
}

export const compute = {
	// A buffer of `count` elements of `code` — `'f32'`, `'u32'`, `'bytes'`, and
	// the rest of TYPES above.
	//
	// `data` is optional and is the buffer's first contents: a plain array of
	// numbers for the float and int types, bytes for `'bytes'`. Without it the
	// buffer holds zeroes, which is what an output or a scratch buffer wants.
	//
	//   const a = three.compute.f32(1024, [1, 2, 3])
	//   const out = three.compute.f32(1024)
	buffer(code, count, data) {
		const type = typeOf(code);
		if (!(count > 0) || !Number.isInteger(count)) {
			throw new TypeError(`three.compute.buffer('${code}', count): count wants a positive whole number`);
		}

		const byteLength = count * type.width;
		let upload = null;
		if (data !== undefined && data !== null) {
			const bytes = asBytes(data, 'buffer()');
			if (bytes.length > byteLength) {
				throw new RangeError(
					`three.compute.buffer('${code}', ${count}, data): data holds ${bytes.length} bytes and the buffer holds ${byteLength}`
				);
			}
			upload = bytes;
		}

		const handle = H.computeCreateBuffer(
			byteLength,
			upload === null ? new Uint8Array(0) : upload,
			0,
			upload === null ? 0 : upload.length
		);
		return new ComputeBuffer(handle, code, count);
	},

	// A buffer of floats. The common case, spelled the common way.
	f32(count, data) { return compute.buffer('f32', count, data); },
	// A push field the shader declares as an integer: `three.compute.uint(n)`.
	uint(value) { return new UintValue(value); },
	// A buffer of unsigned ints.
	u32(count, data) { return compute.buffer('u32', count, data); },
	// A buffer of bytes.
	bytes(count, data) { return compute.buffer('bytes', count, data); },
	// A buffer the host made and handed over by handle — a weights tensor an
	// embedding program streamed onto the GPU itself. `code` and `count` say how
	// the script should read it; the bytes are already there.
	adopt(handle, code = 'bytes', count) {
		if (typeof handle !== 'number' || handle < 0) {
			throw new TypeError('three.compute.adopt(handle) wants a buffer handle from the host');
		}
		return new ComputeBuffer(handle, code, count);
	},

	// A kernel: from a shader source, or from a module that is already SPIR-V.
	//
	// A string is a complete shader — its `@storage` buffers, its push block,
	// and a `@compute` entry point — and it is compiled here. A `Uint8Array`
	// (or anything else with bytes) is a compiled module instead, dispatched as
	// it is: `three.compute.spirv(path)` returns one, and a module built by
	// another compiler works the same way.
	//
	// `name` is what an error is blamed on; `entry` is which entry point, and
	// is `main` when the module has only that one. `pushFields` names the push
	// block's fields in the shader's own order, which is what lets
	// `run({ push: {...} })` pack them without a type table.
	kernel(source, options = {}) {
		const compiled = typeof source === 'string';
		if (!compiled && !hasBytes(source)) {
			throw new TypeError(
				'three.compute.kernel(source) wants the shader source as a string, or a compiled module as bytes'
			);
		}
		const name = options.name || 'kernel';
		const entry = options.entry || 'main';
		const pushFields = options.pushFields || null;

		const handle = compiled
			? H.computeCreateKernel(source, name, entry)
			: H.computeCreateKernelSpirv(source, name, entry);
		// The workgroup size is the module's, and both paths ask for it rather
		// than parsing `@threads` back out of the text: a dispatch splits a
		// work-item count by this, so a wrong one is a wrong dispatch.
		const kernel = new ComputeKernel(handle, compiled ? source : null, H.computeKernelThreads(handle));
		// Kept for the dispatch's own packing. Not part of the class's story
		// above the line — a field of the object that says which fields the
		// push block has.
		kernel.pushFields = pushFields;
		return kernel;
	},

	// A compiled module read from disk, as bytes — `kernel(spirv(path), ...)`.
	//
	// The path is resolved the way every other file in the project is, so a
	// module shipped next to the binary is `spirv('shaders/zimage.spv')`. The
	// bytes come back a `Uint8Array` the script owns, so one module can be
	// read once and used for several kernels.
	spirv(path) {
		if (typeof path !== 'string' || path.length === 0) {
			throw new TypeError('three.compute.spirv(path) wants the module\'s path');
		}
		return H.computeSpirv(path);
	},

	// The shader language's own view of a buffer, for a script that wants to
	// read one back without a `ComputeBuffer` around it: `three.compute.read(buf)`
	// is `buf.read()`, kept because it reads better in a chain.
	read(buffer) { return buffer.read(); },
	// Run everything recorded since the last submit.
	//
	// A `read()` submits on its own, and so does `kernel.run()`, so this is for
	// the one case that wants them apart: a chain of dispatches that should
	// reach the GPU as one submission rather than one each.
	submit() { H.computeSubmit(); },
	// `submit()` without the wait: send the chain and let frames draw while the
	// GPU runs it. Recording anything before it is done waits for it.
	//
	//   three.compute.submitAsync();
	//   while (three.compute.busy()) await three.nextFrame();
	submitAsync() { H.computeSubmitAsync(); },
	busy() { return H.computeBusy(); },

	// A GPU-side copy, recorded in order with the dispatches around it — no
	// round trip, no submission of its own.
	//
	//   three.compute.copy(latent, saved)                                  // whole buffer
	//   three.compute.copy(k, cache, { dstOffset: pos * rowBytes, size: rowBytes })
	copy(source, destination, options = {}) {
		const srcOffset = options.srcOffset || 0;
		const dstOffset = options.dstOffset || 0;
		const size = options.size === undefined
			? Math.min(source.byteLength - srcOffset, destination.byteLength - dstOffset)
			: options.size;
		H.computeCopy(source._h, srcOffset, destination._h, dstOffset, size, options.independent === true);
	},

	// Fill a buffer, or a range of it, with one repeated 32-bit word. Offset and
	// size are bytes, in whole words.
	fill(buffer, word = 0, options = {}) {
		const offset = options.offset || 0;
		const size = options.size === undefined ? buffer.byteLength - offset : options.size;
		H.computeFill(buffer._h, offset, size, word >>> 0, options.independent === true);
	},
	// `fill(buffer, 0)`.
	zero(buffer, options = {}) { compute.fill(buffer, 0, options); },

	// The barrier a run of `independent` commands left out.
	barrier() { H.computeBarrier(); },

	// An image a kernel writes and anything else may read: a material's map, a
	// post pass's texture, another kernel's input.
	//
	//   const img = three.compute.image({ width: 512, height: 512, format: 'rgba16f' });
	//
	// `format` is a storage format as the shader spells it — 'rgba16f' (the
	// default), 'rgba8', 'r32f', 'r32ui', and the rest
	// `three.compute.limits.storageImageFormats` lists. `filter` is how a
	// material samples it, three.LinearFilter or three.NearestFilter. `data`
	// fills it, in `read()`'s layout; without it the image starts at zero.
	image(options = {}) {
		if (options === null || typeof options !== 'object') {
			throw new TypeError('three.compute.image({ width, height, format }) wants an options object');
		}
		for (const key of Object.keys(options)) {
			if (!['width', 'height', 'format', 'filter', 'data'].includes(key)) {
				throw new TypeError(
					`three.compute.image has no option called '${key}' — it takes width, height, format, filter and data`
				);
			}
		}
		const { width, height, format = 'rgba16f', filter = LinearFilter, data } = options;
		if (!Number.isInteger(width) || !Number.isInteger(height)) {
			throw new TypeError('three.compute.image({ width, height }) wants whole-number dimensions');
		}
		if (typeof format !== 'string') {
			throw new TypeError(`three.compute.image: format wants a name like 'rgba16f', not ${typeof format}`);
		}
		if (filter !== LinearFilter && filter !== NearestFilter) {
			throw new TypeError('three.compute.image: filter is three.LinearFilter or three.NearestFilter');
		}
		const image = new ComputeImage(H.computeCreateImage(width, height, format, filter === NearestFilter), format);
		if (data !== undefined && data !== null) image.write(data);
		return image;
	},

	// What this device lets a kernel do: `{ device, cooperativeMatrix,
	// subgroupSize, maxSharedMemory, maxWorkgroupInvocations, maxBindingRange,
	// maxAllocation, bindingAlignment, maxPushConstants, maxBindings,
	// storageImageFormats, storageImageReadWithoutFormat,
	// storageImageWriteWithoutFormat, maxStorageImages, maxImageSize }`.
	get limits() { return H.computeLimits(); },
};
