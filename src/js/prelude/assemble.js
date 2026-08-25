// three.c3 — a compound mesh from a description of its parts. `notes.md` §22.
//
// ## What this replaces
//
// Five statements per body part, times eleven parts, twice:
//
//     const body = new three.Mesh(BOX, mat.flat);
//     body.scale.set(0.78, 0.82, 0.62);
//     body.position.set(0, 0.86, 0);
//     body.color = 0xd86a1e;
//     spinner.add(body);
//
// against
//
//     const P = three.assemble({
//         body: { box: [0.78, 0.82, 0.62], at: [0, 0.86, 0], color: 0xd86a1e },
//         head: { box: [0.66, 0.56, 0.6],  at: [0, 1.52, 0.02], color: 0xe2762a },
//         arm:  { mirror: 'x', pivot: [0.52, 1.16, 0], box: [0.2, 0.62, 0.2], at: [0, -0.3, 0] },
//         leg:  { mirror: 'x', pivot: [0.22, 0.46, 0], box: [0.26, 0.5, 0.3], at: [0, -0.23, 0] },
//     }, { material: mat.flat, collides: false });
//
//     P.leg[0].rotation.x = swing;
//
// It answers with `{ root, ...parts }` — a plain object, with the Group to add
// to the scene under `root` and every part under its own key, so the pose code
// below it reads exactly as it did. Nothing is added to the scene here: the
// root is a detached description until the caller adds it, which is the rule
// everything else in this API follows.
//
// ## One geometry per SHAPE, not per part
//
// `examples/wumpa_run.js` says it at the top of its shared block — "one geometry
// under a scale, one material per look, so every crate of a kind is one draw
// call" — and then every hand-written assembly has to remember it. Here it is
// structural: `box` is a single unit `BoxGeometry(1, 1, 1)` cached at module
// scope with the size in `mesh.scale`, `sphere` a unit sphere, and so on. A
// hundred assembled characters are a hundred copies of four shapes.
//
//   The host deduplicates primitives by their parameters — two
//   `new three.BoxGeometry(1, 1, 1)` come back with the same asset index and
//   draw as one call — so the cache is not what makes this one draw call. What
//   it saves is the JavaScript object and the crossing, per part, per assembly.
//   What makes it one draw call is that the SIZE is a scale rather than a
//   parameter, and that is the part a hand-written assembly gets wrong.
//
// `cylinder: [rTop, rBottom, h]` is the one shape that cannot always be a unit
// one: a taper is not a scale. It is cached by its RATIO instead — every
// straight cylinder shares one geometry, and a given taper shares one with every
// other part of the same taper.
//
// ## `pivot` is what makes a limb swing
//
// A leg that rotates about its hip is a Group at the hip with the mesh hanging
// below it, which is four more lines and the reason every hand-written character
// in `examples/` has a `legs` array of Groups beside a `lm` mesh nobody keeps.
// `pivot` is that Group, `at` is where the mesh sits inside it, and **the Group
// is what comes back as the part** — so `P.leg[0].rotation.x = swing` swings
// from the hip. Without a `pivot` the part IS the mesh, because a head that
// rotates about its own centre needs nothing else.
//
// ## `mirror` answers with [negative, positive]
//
// `mirror: 'x'` builds two and negates the mirrored axis of the `pivot` — or of
// `at`, when there is no pivot. They come back as a two-element array in the
// order `[-x, +x]`, which is `for (const sx of [-1, 1])`'s order, so pose code
// written against a hand-built pair ports without renumbering.
import { Group } from './object3d.js';
import { Mesh } from './mesh.js';
import { Material } from './material.js';
import { BoxGeometry, SphereGeometry, CylinderGeometry, ConeGeometry } from './geometry.js';
import { readVector } from './math.js';

const WHERE = 'three.assemble(parts, defaults)';

// Every key a part spec may carry. Listed rather than ignored, because the
// failure this catches is a typo — `colour`, `position`, `rotate` — and a part
// that silently came out white in the wrong place is debugged by looking at the
// picture, which is the loop this API exists to keep short.
const PART_KEYS = [
	'box', 'sphere', 'cylinder', 'cone', 'geometry', 'scale',
	'at', 'rotation', 'pivot', 'mirror', 'color', 'material', 'name', 'parts',
];

// Exactly one of these may appear in a part spec. A part with none and a
// `parts` is a plain Group; a part with none and no `parts` is a typo.
const SHAPE_KEYS = ['box', 'sphere', 'cylinder', 'cone', 'geometry'];

const AXES = { x: 0, y: 1, z: 2 };

// The shared unit shapes, by cache key — see the header. Built on first use
// rather than at module load: a prelude that made four GPU assets every session
// for a feature most scripts never reach would be paying for this file's
// existence rather than for its use.
const shapes = new Map();

// A description of a compound object, built.
export function assemble(parts, defaults = null) {
	if (parts === null || typeof parts !== 'object' || Array.isArray(parts)) {
		throw new TypeError(`${WHERE} wants an object of named parts, like { body: { box: [1, 1, 1] } }`);
	}
	if (defaults !== null && defaults !== undefined && typeof defaults !== 'object') {
		throw new TypeError(`${WHERE} wants an object for its defaults, like { material, collides, name }`);
	}
	const fallback = defaults ?? {};
	if (fallback.material !== undefined && fallback.material !== null && !(fallback.material instanceof Material)) {
		throw new TypeError(`${WHERE}: defaults.material wants a three.MeshLambertMaterial or a three.ShaderMaterial`);
	}

	const root = new Group();
	if (fallback.name !== undefined) root.name = String(fallback.name);

	// `root` is the Group everything hangs from, so a part called `root` would
	// overwrite it in the answer and there would be nothing to add to the scene.
	const out = { root };
	addParts(parts, root, fallback, out);

	// A Group is not geometry — `object.collides` says what one piece of
	// geometry IS — so this is a walk over the meshes rather than one write on
	// the root, and it replaces the `noCollide` traverse every example carried.
	if (fallback.collides !== undefined) {
		const collides = !!fallback.collides;
		root.traverse(o => { if (o instanceof Mesh) o.collides = collides; });
	}
	return out;
}

// -----------------------------------------------------------------------
// Private

function addParts(parts, parent, fallback, out) {
	for (const key of Object.keys(parts)) {
		if (key === 'root') {
			throw new TypeError(`${WHERE}: 'root' is the Group everything hangs from and cannot be a part name`);
		}
		if (key in out) {
			throw new TypeError(`${WHERE}: two parts are called '${key}' — the answer is one flat object, so nested names have to be unique too`);
		}
		const spec = parts[key];
		if (spec === null || typeof spec !== 'object' || Array.isArray(spec)) {
			throw new TypeError(`${WHERE}: part '${key}' wants a spec object, like { box: [1, 1, 1], at: [0, 1, 0] }`);
		}
		for (const name of Object.keys(spec)) {
			if (!PART_KEYS.includes(name)) {
				throw new TypeError(
					`${WHERE}: part '${key}' has no '${name}'. A part takes: ${PART_KEYS.join(', ')}.`
				);
			}
		}

		// Claimed before the part is built, so that a nested part of the same
		// name is caught by the check above rather than quietly replacing its
		// own parent — and so that the answer's keys read parent-first.
		out[key] = null;
		const mirror = readMirror(spec.mirror, key);
		if (mirror < 0) {
			out[key] = buildPart(key, spec, parent, fallback, out, 1, null);
		} else {
			// [negative, positive] — `for (const sx of [-1, 1])`'s order, so
			// pose code written against a hand-built pair ports unchanged.
			out[key] = [
				buildPart(key, spec, parent, fallback, out, -1, mirror),
				buildPart(key, spec, parent, fallback, out, 1, mirror),
			];
		}
	}
}

// One copy of one part. `sign` is -1 or 1 and `axis` is the mirrored axis index
// or null; together they are the whole of what makes the two copies differ.
function buildPart(key, spec, parent, fallback, out, sign, axis) {
	const shape = shapeOf(spec, key);
	const nested = spec.parts ?? null;
	if (nested !== null && (nested === undefined || typeof nested !== 'object' || Array.isArray(nested))) {
		throw new TypeError(`${WHERE}: part '${key}' has a 'parts' that is not an object of named parts`);
	}

	const at = spec.at === undefined ? [0, 0, 0] : readVector(spec.at, `${WHERE}: part '${key}' at`);
	const rotation = spec.rotation === undefined ? null : readVector(spec.rotation, `${WHERE}: part '${key}' rotation`);
	const name = sign === 1 && axis === null
		? String(spec.name ?? key)
		: `${String(spec.name ?? key)}.${sign < 0 ? 0 : 1}`;

	// A part with no shape is a plain Group, which is what a `spinner` — a
	// pivot for everything under it, drawing nothing itself — actually is.
	if (shape === null) {
		if (nested === null) {
			throw new TypeError(
				`${WHERE}: part '${key}' has no shape and no parts. Give it one of `
				+ `${SHAPE_KEYS.join(', ')}, or a 'parts' to be a plain Group for.`
			);
		}
		if (spec.pivot !== undefined) {
			throw new TypeError(
				`${WHERE}: part '${key}' has a 'pivot' and no shape — a pivot is where a MESH hangs from, `
				+ 'and a part with no shape is already the Group its children rotate about. Use \'at\'.'
			);
		}
		const group = new Group();
		group.name = name;
		group.position.set(...mirrored(at, sign, axis));
		if (rotation !== null) group.rotation.set(...rotation);
		parent.add(group);
		addParts(nested, group, fallback, out);
		return group;
	}

	const material = spec.material === undefined ? fallback.material : spec.material;
	if (material === undefined || material === null) {
		throw new TypeError(
			`${WHERE}: part '${key}' has no material and there is no defaults.material to fall back on`
		);
	}
	if (!(material instanceof Material)) {
		throw new TypeError(`${WHERE}: part '${key}' wants a three.MeshLambertMaterial or a three.ShaderMaterial for its material`);
	}

	const mesh = new Mesh(shape.geometry, material);
	mesh.scale.set(shape.scale[0], shape.scale[1], shape.scale[2]);
	if (spec.color !== undefined) mesh.color = spec.color;

	// With a pivot the part is the GROUP, so `P.leg[0].rotation.x` swings from
	// the hip; without one the part is the mesh itself.
	let node = mesh;
	if (spec.pivot !== undefined) {
		const pivot = readVector(spec.pivot, `${WHERE}: part '${key}' pivot`);
		const group = new Group();
		group.name = name;
		group.position.set(...mirrored(pivot, sign, axis));
		mesh.name = `${name}.mesh`;
		mesh.position.set(at[0], at[1], at[2]);
		if (rotation !== null) mesh.rotation.set(...rotation);
		group.add(mesh);
		node = group;
	} else {
		mesh.name = name;
		mesh.position.set(...mirrored(at, sign, axis));
		if (rotation !== null) mesh.rotation.set(...rotation);
	}

	parent.add(node);
	if (nested !== null) addParts(nested, node, fallback, out);
	return node;
}

// The one thing the two mirrored copies differ by.
function mirrored(triple, sign, axis) {
	if (axis === null || sign === 1) return triple;
	const out = [triple[0], triple[1], triple[2]];
	out[axis] = -out[axis];
	return out;
}

function readMirror(value, key) {
	if (value === undefined || value === null) return -1;
	const axis = AXES[String(value).toLowerCase()];
	if (axis === undefined) {
		throw new RangeError(`${WHERE}: part '${key}' has mirror: ${JSON.stringify(value)} — it is 'x', 'y' or 'z'`);
	}
	return axis;
}

// Exactly one shape key, turned into a shared geometry and the scale that makes
// it the size asked for. Null for a part that has none, which is a Group.
function shapeOf(spec, key) {
	const named = SHAPE_KEYS.filter(k => spec[k] !== undefined);
	if (named.length === 0) return null;
	if (named.length > 1) {
		throw new TypeError(`${WHERE}: part '${key}' has both a '${named[0]}' and a '${named[1]}' — a part is one shape`);
	}

	const which = named[0];
	const value = spec[which];
	const where = `${WHERE}: part '${key}' ${which}`;

	if (which === 'geometry') {
		if (!value || typeof value.asset !== 'number' || typeof value.mesh !== 'number') {
			throw new TypeError(`${where} wants a geometry — one three.c3 built, or a mesh reference from asset.mesh(name)`);
		}
		const scale = spec.scale === undefined ? [1, 1, 1]
			: typeof spec.scale === 'number' ? [+spec.scale, +spec.scale, +spec.scale]
			: readVector(spec.scale, `${WHERE}: part '${key}' scale`);
		return { geometry: value, scale };
	}
	if (spec.scale !== undefined) {
		throw new TypeError(
			`${WHERE}: part '${key}' has a '${which}' and a 'scale' — the shape's own numbers ARE the scale here, `
			+ "and 'scale' is only for a part built from a geometry you supplied."
		);
	}

	if (which === 'sphere') {
		const r = positive(value, where, 'radius');
		return { geometry: shared('sphere', () => new SphereGeometry(0.5)), scale: [r * 2, r * 2, r * 2] };
	}
	if (which === 'box') {
		const [w, h, d] = sizes(value, where, 3, 'a [width, height, depth]');
		return { geometry: shared('box', () => new BoxGeometry(1, 1, 1)), scale: [w, h, d] };
	}
	if (which === 'cone') {
		const [r, h] = sizes(value, where, 2, 'a [radius, height]');
		return { geometry: shared('cone', () => new ConeGeometry(0.5, 1)), scale: [r * 2, h, r * 2] };
	}
	// A taper is not a scale, so a cylinder is cached by its RATIO — every
	// straight one shares a geometry with every other straight one.
	const [top, bottom, height] = sizes(value, where, 3, 'a [radiusTop, radiusBottom, height]', true);
	const widest = Math.max(top, bottom);
	if (widest <= 0) throw new RangeError(`${where}: a cylinder needs one of its radii to be positive`);
	const ratioTop = top / widest, ratioBottom = bottom / widest;
	return {
		geometry: shared(
			`cylinder:${ratioTop}:${ratioBottom}`,
			() => new CylinderGeometry(0.5 * ratioTop, 0.5 * ratioBottom, 1),
		),
		scale: [widest * 2, height, widest * 2],
	};
}

function shared(key, make) {
	let geometry = shapes.get(key);
	if (geometry === undefined) {
		geometry = make();
		shapes.set(key, geometry);
	}
	return geometry;
}

function positive(value, where, what) {
	const n = +value;
	if (!(n > 0)) throw new RangeError(`${where} wants a positive ${what}, not ${JSON.stringify(value)}`);
	return n;
}

// `count` numbers, all positive — except a cylinder, where one radius may be
// zero because that is how a cone is spelled if you insist on spelling it that
// way.
function sizes(value, where, count, shape, allowZero = false) {
	if (!Array.isArray(value) || value.length !== count) {
		throw new TypeError(`${where} wants ${shape}`);
	}
	return value.map((n, i) => {
		const v = +n;
		if (!Number.isFinite(v) || v < 0 || (v === 0 && !(allowZero && i < 2))) {
			throw new RangeError(`${where} wants ${shape} of positive numbers, and its ${i === 0 ? 'first' : i === 1 ? 'second' : 'third'} is ${JSON.stringify(n)}`);
		}
		return v;
	});
}
