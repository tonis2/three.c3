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
		this._bytes = new Uint8Array(count * type.width);
		this._view = type.view === null ? null : new type.view(this._bytes.buffer);
		this.disposed = false;
	}

	// How many elements, as the buffer was made.
	get count() { return this._count; }
	// How many bytes those are.
	get byteLength() { return this._bytes.length; }
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
	get bytes() { return this._view === null ? this._bytes : this._view; }

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
		H.computeReadBuffer(this._handle, this._bytes, this._bytes.length);
		return this;
	}

	// Replace the buffer's contents and upload them.
	write(source) {
		this._assertLive();
		const bytes = asBytes(source, 'write()');
		if (bytes.length > this._bytes.length) {
			throw new RangeError(
				`three.compute: write() was given ${bytes.length} bytes for a buffer of ${this._bytes.length}`
			);
		}
		this._bytes.set(bytes);
		// A Uint8Array over the same memory, not the element view: the host
		// verb reads bytes, and `js.bytes` takes a Uint8Array or an
		// ArrayBuffer and nothing else — handing it the Buffer's own
		// Float32Array is a silent no-op, which is a write that appears to
		// work and a buffer that never changes.
		H.computeWriteBuffer(
			this._handle,
			new Uint8Array(this._bytes.buffer, this._bytes.byteOffset, this._bytes.length),
			0,
			bytes.length
		);
		return this;
	}

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

// A compiled kernel: one shader, its bindings, and the workgroup size it was
// written with.
export class ComputeKernel {
	constructor(handle, source, threads) {
		this._handle = handle;
		this.source = source;
		this.threads = threads;
		this.disposed = false;
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

		const push = packPush(options.push, options.pushFields);
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

		H.computeDispatch(this._handle, list.map((b) => b._h), push, x, y, z);
		return this;
	}

	// The buffers as the shader declares them, in binding order.
	//
	// The names are the shader's own `float a[];` declarations, and the order
	// is the order they are written in, which is the order the host binds them
	// in. A name the shader does not have is refused here rather than becoming
	// a dispatch against the wrong buffer.
	_byName(named, declared) {
		const fields = declared || Object.keys(named);
		const out = [];
		for (const name of fields) {
			const buffer = named[name];
			if (!buffer || typeof buffer._h !== 'number') {
				throw new TypeError(
					`three.compute: run() was given no buffer for '${name}' — name the shader's own bindings`
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

// The workgroup size out of `@threads(x, y, z)`, which the host needs to turn a
// work-item count into group counts.
//
// Read out of the source because the source is the only place it is written:
// the shader language has no reflection verb here and a script that wrote
// `@threads(64, 1, 1)` should not have to say 64 again.
function threadsOf(source) {
	const match = /@threads\s*\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*\)/.exec(source);
	if (!match) return 64;
	const x = Number(match[1]);
	return x > 0 ? x : 64;
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

	// Compile a kernel.
	//
	// The source is a complete shader: its `@storage` buffers, its push block,
	// and a `@compute` entry point. `name` is what a compile error is blamed
	// on; `entry` is which entry point, and is the first `@compute` one when
	// the source has only that one. `pushFields` names the push block's fields
	// in the shader's own order, which is what lets `run({ push: {...} })` pack
	// them without a type table.
	kernel(source, options = {}) {
		if (typeof source !== 'string') throw new TypeError('three.compute.kernel(source) wants the shader source as a string');
		const name = options.name || 'kernel';
		const entry = options.entry || 'main';
		const pushFields = options.pushFields || null;

		const handle = H.computeCreateKernel(source, name, entry, threadsOf(source));
		const kernel = new ComputeKernel(handle, source, threadsOf(source));
		// Kept for the dispatch's own packing. Not part of the class's story
		// above the line — a field of the object that says which fields the
		// push block has.
		kernel.pushFields = pushFields;
		return kernel;
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
};
