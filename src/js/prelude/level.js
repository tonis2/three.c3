// three.c3 — three.level: a placement list over a kit, and the loader that
// replays it.
//
// A `.glb` bakes geometry in, so re-exporting a kit does not update a level
// built from it, and the link back to the piece a placement *is* is gone. A
// list — a piece and a transform per row — is diffable, greppable and
// writable by an agent, which is the point: the same file is what an agent
// generates and what a person then adjusts by hand.
//
// A transform alone bakes the placement the way the `.glb` baked the
// geometry, one level up: re-export the kit with a taller wall and the
// storey above it stays where it was. So a row placed by a snap also carries
// the snap — the target row, the side, the axes — and `refit()` replays those
// rows in file order against the kit as it is now. A plain `load()` takes
// the written transforms as they are and asks nothing; a freehand row (no
// `snap`) never moves, under either.
//
// The file itself is read with `three.readJSON` and written with
// `three.writeJSON`'s own host doors — `H.assetText` / `H.assetWriteText`
// below, since this module sits under `api.js` in the import graph and
// cannot import back from it. Same sandbox, same 4 MB limit, same "not there
// is null" answer.

import { Object3D } from './object3d.js';
import { Asset } from './asset.js';
import { asTriple } from './math.js';

const H = globalThis.__three;

function readJSON(path) {
	const text = H.assetText(path);
	return text === null ? null : JSON.parse(text);
}

function writeJSON(path, value) {
	return H.assetWriteText(path, JSON.stringify(value, null, '\t') + '\n');
}

// The vocabulary a bad `piece` was guessed wrong from, in `markerList`'s
// shape — a name once, quoted, or `(none)`.
function pieceList(names) {
	return names.length ? names.map(n => `'${n}'`).join(', ') : '(none)';
}

// One placed kit: `kit`, the rows that describe it, the objects they built,
// and the parent they hang from. `three.level.load` and `three.level.create`
// are the two doors onto one — see them for what each hands back.
export class Level {
	constructor(kit) {
		this.kit = kit;
		// In file order — the order a snap's backwards reference and `refit()`
		// both depend on.
		this.rows = [];
		this.objects = new Map();
		// Null until `three.level.load` sets it, or a script sets it directly
		// after `three.level.create()` — `add()` needs it and says so.
		this.parent = null;
		// One Asset per path a row has named, loaded once and shared by every
		// row that names it again — `kit` most often, `asset` for the rest.
		this._assets = new Map();
	}

	_assetFor(path) {
		if (typeof path !== 'string' || path.length === 0) {
			throw new TypeError(
				'three.level: a row needs a "kit" on the level or its own "asset" — a path to a .glb or .gltf');
		}
		let asset = this._assets.get(path);
		if (!asset) {
			asset = new Asset(H.load(path));
			this._assets.set(path, asset);
		}
		return asset;
	}

	// Places one row: builds the piece, names it, sets its transform, adds it
	// under `parent`, and — with `options.refit` — snaps it again. `load()`
	// calls this once per row, in file order, which is what makes "add(row)"
	// and "one row of load()" the same operation rather than two that have to
	// be kept in step.
	//
	// Validates what a replay depends on: `id` unique within this level, and
	// a `snap.to` naming a row already placed — a snap may only point
	// backwards, so a replay in file order always finds its target.
	add(row, options = {}) {
		if (!(this.parent instanceof Object3D)) {
			throw new Error(
				'three.level: add(row) needs .parent set to an Object3D or Scene — three.level.load sets '
				+ 'it, or set it directly after three.level.create()');
		}
		if (row === null || typeof row !== 'object') {
			throw new TypeError('three.level: a row must be an object — { id, piece, position, rotation }');
		}
		const { id, piece } = row;
		if (typeof id !== 'string' || id.length === 0) {
			throw new TypeError('three.level: a row needs a string "id"');
		}
		if (this.objects.has(id)) {
			throw new Error(`three.level: id ${JSON.stringify(id)} is used twice`);
		}
		if (typeof piece !== 'string' || piece.length === 0) {
			throw new TypeError(`three.level: row ${JSON.stringify(id)} needs a string "piece"`);
		}

		let target = null;
		if (row.snap) {
			const to = row.snap.to;
			target = this.objects.get(to);
			if (!target) {
				throw new Error(
					`three.level: row ${JSON.stringify(id)}'s snap.to ${JSON.stringify(to)} names no `
					+ 'earlier row — a snap may only point backwards, to a row already placed');
			}
		}

		const asset = this._assetFor(row.asset ?? this.kit);
		if (!asset.nodes.includes(piece)) {
			throw new TypeError(
				`three.level: no piece named ${JSON.stringify(piece)} in ${asset.path} — it has: `
				+ pieceList(asset.nodes));
		}

		const object = asset.node(piece);
		object.name = id;
		// `scale` has no whole-vector setter — only `position` and `rotation`
		// do — so every one of the three is set through `.set(...)` here rather
		// than two of them by assignment and one not.
		object.scale.set(...asTriple(row.scale ?? [1, 1, 1], `three.level: row ${JSON.stringify(id)}'s scale`));
		// Rotation before position and before any snap: snapping measures a box
		// the rotation changes, so a piece is turned before it is placed.
		object.rotation.set(...asTriple(row.rotation ?? [0, 0, 0], `three.level: row ${JSON.stringify(id)}'s rotation`));
		object.position.set(...asTriple(row.position ?? [0, 0, 0], `three.level: row ${JSON.stringify(id)}'s position`));
		this.parent.add(object);

		if ((options?.refit) && row.snap) {
			object.snapTo(target, row.snap.side, row.snap.axes ?? {});
		}

		this.objects.set(id, object);
		this.rows.push(row);
		return object;
	}

	// Takes the object out of `parent` and the row out of `rows`. Throws
	// rather than leaving a dangling reference behind: a level with a snap
	// naming a row that is no longer there cannot be replayed, and the
	// message says which row to re-point or clear first.
	remove(id) {
		const object = this.objects.get(id);
		if (!object) throw new Error(`three.level: remove(id) — no row named ${JSON.stringify(id)}`);
		const blocking = this.rows.find(r => r.snap && r.snap.to === id);
		if (blocking) {
			throw new Error(
				`three.level: remove(${JSON.stringify(id)}) — row ${JSON.stringify(blocking.id)}'s `
				+ 'snap.to points at it; re-point or clear that snap before removing this one');
		}
		if (object.parent) object.parent.remove(object);
		this.objects.delete(id);
		const at = this.rows.findIndex(r => r.id === id);
		if (at >= 0) this.rows.splice(at, 1);
	}

	// Replays every snapped row in place, in file order — the re-fit a kit
	// re-exported with a taller wall needs, without touching a freehand row:
	// `refit()` only ever calls `snapTo` on a row that carries a `snap`.
	refit() {
		for (const row of this.rows) {
			if (!row.snap) continue;
			const object = this.objects.get(row.id);
			const target = this.objects.get(row.snap.to);
			object.snapTo(target, row.snap.side, row.snap.axes ?? {});
		}
		return this;
	}

	// What `three.level.save` writes. Reads each row's position, rotation and
	// scale back from its object first — a piece nudged after loading is
	// saved where it is now — by mutating the row objects themselves rather
	// than rebuilding them, which is what keeps a field an editor added, e.g.
	// `"locked": true`, through the round trip.
	toJSON() {
		for (const row of this.rows) {
			const object = this.objects.get(row.id);
			row.position = object.position.toArray();
			row.rotation = object.rotation.toArray();
			row.scale = object.scale.toArray();
		}
		return { kit: this.kit, rows: this.rows };
	}
}

// Reads `path` through `three.readJSON`'s own door, loads each asset a row
// names once, and places every row in file order — `level.add(row, options)`
// for each, which is the whole loop.
//
// `options.refit` is false by default: a plain load takes the written
// transform as it is and asks nothing, which is what makes a saved level
// exactly reproducible. `refit: true` re-snaps every row that carries a
// `snap` against the object its `to` row just produced, so a kit whose wall
// grew taller lifts the storey snapped on top of it; a freehand row is left
// exactly where the file says either way.
//
// Null for a file that is not there, the same answer `three.readJSON` gives
// — a cold editor start is one `??` rather than a guard.
export function load(path, parent, options = {}) {
	if (typeof path !== 'string' || path.length === 0) {
		throw new TypeError('three.level.load(path, parent) wants a path to a level file');
	}
	if (!(parent instanceof Object3D)) {
		throw new TypeError('three.level.load(path, parent) wants the Object3D or Scene to load into');
	}
	const data = readJSON(path);
	if (data === null) return null;

	const refit = !!(options?.refit);
	const level = new Level(data.kit);
	level.parent = parent;
	for (const row of data.rows ?? []) level.add(row, { refit });
	return level;
}

// Writes `level` to `path` through `three.writeJSON`'s own door —
// `level.toJSON()` first, so the file gets each row's current transform.
// Answers what that write answers with: the path it actually wrote to.
export function save(path, level) {
	if (!(level instanceof Level)) {
		throw new TypeError('three.level.save(path, level) wants a Level as its second argument');
	}
	return writeJSON(path, level.toJSON());
}

// An empty Level over `kit`, for an editor that starts from nothing rather
// than from a file on disk. `.parent` is null until something sets it —
// `add()` needs it set and says so if it is not.
export function create(kit) {
	return new Level(kit);
}

export const level = { load, save, create };
