// three.c3 — the post chain: full-screen passes over the finished frame.

import { NoTexture } from './material.js';
import { uniformShape, uniformValues, uniformsProxy, textureLists, texturesProxy } from './shader.js';

const H = globalThis.__three;

// -----------------------------------------------------------------------
// The post chain
//
// Full-screen shaders over the finished frame, in the order they were added.
// `three.setPost(spec)` makes one pass the whole chain; `three.addPass(spec)`
// puts another at the end of it. Each reads what the pass before it wrote,
// and the original frame as `p.scene` — that is the entire dependency
// declaration, and it is the pass's position in the list.
//
// Verbs and not a class, because there is one chain and it belongs to the
// renderer: a constructor implies an assignment target — somewhere to put a
// second chain, something to swap between — and there is none.
//
// What a script gets back is a handle onto one live pass: the body that is
// running, its index in the chain, and a live uniforms Proxy. It goes stale
// the moment a setPost replaces the chain, and says so, for the reason a
// Scene does: the alternative is `old.uniforms.gain = 2` quietly steering the
// *new* shader's uniform of the same name.

// Bumped by every call that replaces the whole chain — a successful setPost
// and a setPost(null). A handle remembers the number it was made at.
//
// **addPass does not bump it**, and that is the whole difference between the
// two verbs from a handle's point of view: appending leaves every earlier
// pass exactly where it was, at the same index, running the same shader, so
// there is nothing for an existing handle to have gone stale about.
let postEpoch = 0;

// The one write api.js makes here: an imported binding is read-only, so
// replacing the chain bumps the epoch through a verb rather than an assignment.
export function bumpPostEpoch() { postEpoch++; }

function postHandle(fragment, names, declared = { names: [], values: {} }, index = 0, kind = 'fragment', images = []) {
	const epoch = postEpoch;
	// The body under the key it was given as: `fragment` for a fragment pass,
	// `compute` for a compute one, so a handle reads back as the spec it came from.
	const handle = kind === 'compute' ? { compute: fragment, index } : { fragment, index };
	if (images.length > 0) handle.images = images;
	// Off the enumeration, so that returning the handle from a script
	// stringifies as the two things it is — the body and the uniforms — and
	// not as the bookkeeping behind them.
	const internals = {
		_values: {},
		// Every post uniform is one row. The map is here because
		// `uniformsProxy` reads it, and it stays empty because a post pass
		// draws one triangle over the whole frame: there is no instance for a
		// table to be indexed by, and `uniformShape` has already refused one.
		_rows: {},
		_check() {
			if (postEpoch !== epoch) {
				throw new Error(
					'this post handle was replaced by a later three.setPost() — that call replaces the '
					+ 'whole chain, and writing through the old handle would steer whatever is at its '
					+ 'index now. three.addPass() appends and leaves earlier handles alone'
				);
			}
		},
		_column(name) {
			throw new TypeError(
				`uniform '${name}' is not a table — a post pass has no instances to index one by`
			);
		},
		_set(name, v) {
			internals._check();
			const n = uniformValues(name, v);
			H.setPostUniform(name, +n[0], +(n[1] ?? 0), +(n[2] ?? 0), +(n[3] ?? 0), n.length, index);
			internals._values[name] = typeof v === 'number' ? +v : n.map(Number);
		},
		// What the samplers hold, and the write path for changing one. The
		// staleness check is the same one the uniforms make and for the same
		// reason: writing a texture through a replaced handle would put it in
		// the *new* shader's sampler of that name.
		_textureValues: { ...declared.values },
		_setTexture(name, texture) {
			internals._check();
			H.setPostTexture(name, texture === null ? NoTexture : texture._index(), index);
		},
	};
	for (const key of Object.keys(internals)) {
		Object.defineProperty(handle, key, { value: internals[key], enumerable: false });
	}
	handle.uniforms = uniformsProxy(handle, new Set(names), 'the post pass');
	handle.textures = texturesProxy(handle, new Set(declared.names), 'the post pass');
	return handle;
}

// Everything `setPost` and `addPass` do to a spec before it crosses, which is
// all of it. Shared rather than written twice because the two verbs differ by
// where the pass lands and by nothing else — and two copies of this would be
// two chances for the two doors to disagree about what a post spec is.
export function postSpec(spec, wanted) {
	if (spec === null || spec === undefined || typeof spec !== 'object') {
		throw new TypeError(wanted);
	}
	const { fragment, compute, uniforms = {}, textures = {}, reads, images = {}, threads } = spec;
	for (const key of Object.keys(spec)) {
		if (!['fragment', 'compute', 'uniforms', 'textures', 'reads', 'images', 'threads'].includes(key)) {
			throw new TypeError(
				`a post pass has no option called '${key}' — it takes fragment or compute, uniforms, textures, `
				+ 'reads, images and threads'
			);
		}
	}
	if (fragment !== undefined && compute !== undefined) {
		throw new TypeError(
			'a post pass is a `fragment` body or a `compute` entry point, not both — they are two kinds of pass'
		);
	}
	const kind = compute !== undefined ? 'compute' : 'fragment';
	const body = kind === 'compute' ? compute : fragment;
	if (typeof body !== 'string' || body.trim().length === 0) {
		throw new TypeError(
			'a post pass needs a `fragment` body, or a `compute` entry point — see three.setPost and three.addPass in docs/functions.md'
		);
	}
	if (uniforms === null || typeof uniforms !== 'object') {
		throw new TypeError('`uniforms` wants an object like { gain: 1, tint: [1, 0.5, 0.2] }');
	}
	const declared = textureLists(textures, 'this post pass\'s');

	// The enumeration happens here for `ShaderMaterial`'s reason: the
	// QuickJS shim exposes property *get* by name and nothing that lists
	// keys, so the names cross as a joined string. See js/bind_post.c3.
	const names = Object.keys(uniforms);
	const shapes = names.map(n => uniformShape(n, uniforms[n], false));
	const grid = threadsGrid(threads, kind);
	const declaredImages = imageList(images);

	return {
		fragment: body,
		kind,
		names,
		uniforms,
		declared,
		images: declaredImages.map(i => i.name),
		args: [
			body,
			names.join(','),
			shapes.map(s => s[0]).join(','),
			declared.names.join(','),
			declared.ids.join(','),
			readsIndex(reads),
			kind === 'compute' ? 1 : 0,
			grid[0],
			grid[1],
			declaredImages.map(i => i.name).join(','),
			declaredImages.map(i => i.format).join(','),
			declaredImages.map(i => i.size[0]).join(','),
			declaredImages.map(i => i.size[1]).join(','),
			declaredImages.map(i => (i.clear === 'frame' ? 1 : 0)).join(','),
		],
	};
}

// `threads` as `[x, y]`, or `[0, 0]` for the frame's own extent — which is what
// every pass that writes the frame wants. A grid is a compute pass's: a fragment
// pass draws one triangle over the frame and has nothing to size.
function threadsGrid(threads, kind) {
	if (threads === undefined || threads === null) return [0, 0];
	if (kind !== 'compute') {
		throw new TypeError('`threads` sizes a compute pass\'s dispatch, and this is a fragment pass');
	}
	const grid = typeof threads === 'number' ? [threads, 1] : threads;
	if (!Array.isArray(grid) || grid.length < 1 || grid.length > 2
		|| !grid.every(n => Number.isInteger(n) && n > 0)) {
		throw new TypeError(
			'`threads` wants a pixel grid like [256, 1], or nothing for the whole frame — got '
			+ JSON.stringify(threads)
		);
	}
	return [grid[0], grid.length > 1 ? grid[1] : 1];
}

// `images` as a list of `{ name, format, size, clear }`.
//
// Each is a format name — `{ history: 'rgba16f' }`, the size of the frame — or
// an object for anything else:
//
//     images: { hist: { format: 'r32ui', size: [256, 1], clear: 'frame' } }
//
// `clear: 'frame'` zeroes the image at the start of every frame, for an
// accumulator that is about one frame; the default, 'never', keeps what the
// last frame left, which is what a history wants. The format and the size are
// checked against what a storage image can be on the host, which has the table.
function imageList(images) {
	if (images === null || typeof images !== 'object' || Array.isArray(images)) {
		throw new TypeError("`images` wants an object like { history: 'rgba16f' }");
	}
	return Object.keys(images).map((name) => {
		const value = images[name];
		const spec = typeof value === 'string' ? { format: value } : value;
		if (spec === null || typeof spec !== 'object') {
			throw new TypeError(`image '${name}' wants a format like 'rgba16f', or { format, size, clear }`);
		}
		for (const key of Object.keys(spec)) {
			if (!['format', 'size', 'clear'].includes(key)) {
				throw new TypeError(`image '${name}' has no option called '${key}' — it takes format, size and clear`);
			}
		}
		const { format, size, clear = 'never' } = spec;
		if (typeof format !== 'string' || format.length === 0) {
			throw new TypeError(`image '${name}' wants a format like 'rgba16f' or 'r32ui'`);
		}
		if (size !== undefined && (!Array.isArray(size) || size.length !== 2
			|| !size.every(n => Number.isInteger(n) && n > 0))) {
			throw new TypeError(`image '${name}' wants a size like [256, 1], or none for the frame's own`);
		}
		if (clear !== 'never' && clear !== 'frame') {
			throw new TypeError(`image '${name}': clear is 'never' (keep it between frames) or 'frame'`);
		}
		return { name, format, size: size || [0, 0], clear };
	});
}

// `reads` as an index, or -1 for a pass that names none.
//
// A handle or a number, because both are things a script has in hand: the
// handle is what `addPass` gave back, and the number is what a script that
// counted its own passes has. `handle.index` is the same integer either way,
// so this is one unwrap and not two paths.
//
// **The range is not checked here.** Whether an index names a pass that is
// already in the chain is a question about the chain, the host owns the chain,
// and a check on this side would be a second copy of it that could disagree.
// What is checked here is the shape, because "reads: {}" reaching the host as
// NaN would arrive as an index rather than as a mistake.
function readsIndex(reads) {
	if (reads === undefined || reads === null) return -1;
	const index = typeof reads === 'object' ? reads.index : reads;
	if (typeof index !== 'number' || !Number.isInteger(index) || index < 0) {
		throw new TypeError(
			'`reads` wants the handle three.addPass() gave you for an earlier pass, or its index — '
			+ 'got ' + JSON.stringify(reads)
		);
	}
	return index;
}

// **After the compile, and not before it.** Putting a shader in the chain
// zeroes that stage's push block — the new shader's uniforms are new fields at
// new offsets, so carrying old bytes over would be writing one shader's values
// into another's layout. So the values the spec gave are written afterwards,
// exactly as a ShaderMaterial writes its own.
export function postFinish(parsed, index) {
	const handle = postHandle(parsed.fragment, parsed.names, parsed.declared, index, parsed.kind, parsed.images);
	for (const name of parsed.names) handle._set(name, parsed.uniforms[name]);
	return handle;
}
