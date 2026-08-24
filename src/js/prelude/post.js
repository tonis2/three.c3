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

function postHandle(fragment, names, declared = { names: [], values: {} }, index = 0) {
	const epoch = postEpoch;
	const handle = { fragment, index };
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
	const { fragment, uniforms = {}, textures = {}, reads } = spec;
	if (typeof fragment !== 'string' || fragment.trim().length === 0) {
		throw new TypeError('a post pass needs a `fragment` body — see three.getApiDocs()');
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

	return {
		fragment,
		names,
		uniforms,
		declared,
		args: [
			fragment,
			names.join(','),
			shapes.map(s => s[0]).join(','),
			declared.names.join(','),
			declared.ids.join(','),
			readsIndex(reads),
		],
	};
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
	const handle = postHandle(parsed.fragment, parsed.names, parsed.declared, index);
	for (const name of parsed.names) handle._set(name, parsed.uniforms[name]);
	return handle;
}
