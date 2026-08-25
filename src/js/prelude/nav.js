// three.c3 — navigation and steering. `notes.md` §17.
//
// ## Two verbs, and the split is the whole design
//
// `three.nav.path(from, to)` for one agent. `three.nav.field(goals)` for a
// handle a crowd samples. §17 was explicit that an API offering only
// `path()` guarantees somebody writes the second one badly, and the reason is a
// cost rather than a taste: a path is a solve of the whole reachable set that
// is thrown away after one answer, so a hundred agents heading for the same
// door is a hundred solves for one field. `field()` is that solve, kept.
//
//     const door = three.nav.field([[10, 0, 4]]);      // once
//     three.setAnimationLoop(() => {
//         three.steer(positions, velocities, { field: door, maxSpeed: 3 });
//     });
//     door.dispose();                                   // when the goal changes
//
// ## Nothing is baked for you
//
// `three.nav.bake()` has to be called, and it has to be called after the level
// is built. Baking on demand inside `path()` would hide a cost that
// `three.nav.stats()` exists to make visible, and it would rebake on the first
// call after anything moved — which for a scene with a moving door is every
// frame.
import { Vector3, readVector } from './math.js';

const H = globalThis.__three;

// A solved flow field over a bake.
//
// The handle is a number rather than an object holding host memory, because a
// field is one float per walkable cell — tens of thousands for a town — and
// hanging that off a JavaScript object whose collection the host cannot see is
// exactly the lifetime this API refuses everywhere else. It is freed by
// `dispose()` and by `new three.Scene()`, and a disposed one answers
// "unreachable" rather than reading released memory.
export class NavField {
	constructor(handle) {
		this._h = handle;
	}

	get alive() { return this._h >= 0; }

	// The unit XZ direction that walks towards the nearest goal, or a zero
	// vector for nowhere to go — standing on the goal, off the mesh, or in a
	// pocket no goal reaches. `cost` is how those are told apart.
	//
	// One agent asking once a frame is what this is for. A crowd is
	// `three.steer`, which answers for all of them in one crossing.
	direction(point) {
		const [x, y, z] = readVector(point, 'field.direction(point)');
		const d = H.navDirection(this._h, x, y, z);
		return new Vector3(null, d[0], d[1], d[2]);
	}

	// How far the goal is ALONG THE GROUND, not through walls. `Infinity` for a
	// point off the mesh or one no goal reaches, which is what a script
	// compares against when deciding to give up.
	cost(point) {
		const [x, y, z] = readVector(point, 'field.cost(point)');
		const value = H.navCost(this._h, x, y, z);
		// The host sends -1 for unreachable — see bind_nav.c3. A cost is a
		// distance and can never be negative, so the sentinel is unambiguous
		// and C3 has no infinity constant to send in its place.
		return value < 0 ? Infinity : value;
	}

	// Whether this point can reach any of the goals at all.
	reaches(point) { return Number.isFinite(this.cost(point)); }

	// `direction` and `cost` for a whole crowd, in ONE crossing.
	//
	// **The two above are the wrong verbs to call in a loop, and the reason is
	// not the crossing.** `notes.md` §17 measured the bare host call that
	// answers a number at 143 ns and `cost(point)` — the same call, through the
	// `readVector` that allocates a three-element array and runs three
	// `Number.isFinite` checks to be polite about its argument — at 455 ns. The
	// ergonomics layer costs twice what the boundary does. That is a good trade
	// for a verb called once a frame and a bad one for a verb called once per
	// agent per frame, and both are this verb.
	//
	//     const pos = new Float32Array(n * 3);
	//     const cost = new Float32Array(n);
	//     const dir = new Float32Array(n * 3);
	//     field.sample(pos, { costs: cost, directions: dir });
	//
	// `positions` is read, three floats per agent. `costs` is one float per
	// agent and `directions` is three; either may be left out, so a caller
	// asking only "how far is everyone from the goal" pays for no directions.
	//
	// **A NEGATIVE cost is unreachable here**, where `cost(point)` answers
	// `Infinity`. The two disagree on purpose: converting would mean a
	// JavaScript pass over the array, which is precisely the loop this exists
	// to avoid, and C3 has no infinity constant to write into the array
	// instead. `costs[i] < 0` is the test, and `Number.isFinite` is not.
	sample(positions, options = null) {
		const where = 'field.sample(positions, { costs, directions })';
		if (!(positions instanceof Float32Array)) {
			throw new TypeError(`${where} wants a Float32Array of three floats per agent`);
		}
		const costs = options?.costs ?? null;
		const directions = options?.directions ?? null;
		if (costs === null && directions === null) {
			throw new TypeError(`${where} wants costs, directions or both — with neither there is nothing to write`);
		}
		if (costs !== null && !(costs instanceof Float32Array)) {
			throw new TypeError(`${where}: costs is a Float32Array of ONE float per agent`);
		}
		if (directions !== null && !(directions instanceof Float32Array)) {
			throw new TypeError(`${where}: directions is a Float32Array of THREE floats per agent`);
		}
		return H.navSample(
			this._h,
			positions.buffer, positions.byteOffset, positions.length,
			costs === null ? positions.buffer : costs.buffer,
			costs === null ? 0 : costs.byteOffset,
			costs === null ? 0 : costs.length,
			directions === null ? positions.buffer : directions.buffer,
			directions === null ? 0 : directions.byteOffset,
			directions === null ? 0 : directions.length);
	}

	dispose() {
		if (this._h < 0) return false;
		const freed = H.navFieldFree(this._h);
		this._h = -1;
		return freed;
	}

	toString() { return `NavField(${this._h < 0 ? 'disposed' : `#${this._h}`})`; }
}

function readGoals(goals, where) {
	const list = Array.isArray(goals) && !Number.isFinite(goals[0]) ? goals : [goals];
	if (list.length === 0) throw new RangeError(`${where} wants at least one goal`);
	const flat = new Float32Array(list.length * 3);
	list.forEach((goal, i) => {
		const [x, y, z] = readVector(goal, `${where}: goal ${i}`);
		flat[i * 3] = x;
		flat[i * 3 + 1] = y;
		flat[i * 3 + 2] = z;
	});
	return flat;
}

export const nav = {
	// Voxelize the scene's standing room.
	//
	// `{ cell, radius, height, slope, bounds }` — all properties of the AGENT
	// except the last, which is why a scene can hold more than one bake: a
	// crowd of people and a herd of vehicles walk different graphs over the same
	// triangles. (One at a time, though: a second bake replaces the first.)
	//
	// **`cell` decides everything.** It is the resolution and it is also the
	// largest step that can be climbed, because two cells are connected when
	// they are adjacent and one cell up. Half a metre is a generous stair and a
	// cheap bake; a scene with finer stairs wants a finer cell and pays for it
	// as the CUBE.
	//
	// Answers with the same object `stats()` does, or null when there was no
	// standing room in the region — an empty scene, a scene of walls, or a
	// slope limit nothing is under. Null is an answer, not an error.
	//
	// **Look at `components` on what comes back.** A bake with more than one is
	// a level cut into islands, and every other number on it will look healthy
	// while half the agents stand still — `stats()` has the rest.
	bake(options = null) {
		const cell = +(options?.cell ?? 0.5);
		if (!(Number.isFinite(cell) && cell > 0)) {
			throw new RangeError(`three.nav.bake({ cell }) wants a positive cell size, not ${options?.cell}`);
		}
		let six = [0, 0, 0, 0, 0, 0];
		const bounds = options?.bounds ?? null;
		if (bounds !== null) {
			const lo = readVector(bounds.min ?? bounds[0], 'three.nav.bake({ bounds })');
			const hi = readVector(bounds.max ?? bounds[1], 'three.nav.bake({ bounds })');
			six = [lo[0], lo[1], lo[2], hi[0], hi[1], hi[2]];
		}
		return H.navBake(
			cell,
			+(options?.radius ?? 0.35),
			+(options?.height ?? 1.8),
			+(options?.slope ?? 50),
			bounds !== null,
			six[0], six[1], six[2], six[3], six[4], six[5]);
	},

	// What the last bake produced and what it cost, or null if there has not
	// been one. §17 asked for the bake cost to be measured before the
	// shape of this API is settled — "that number decides whether this is a
	// level-boundary operation or a loading-screen one" — and `bakeMs`,
	// `voxels` and `walkable` are how a caller answers it for their own level.
	//
	// `{ cell, radius, height, slope, voxels, solid, floor, walkable,
	// components, largest, bakeMs, bounds }`.
	//
	// **`components` is the one to check, and it is not a cost.** It is how many
	// DISJOINT regions the standing room came out in, and `largest` is the size
	// of the biggest. Every other number here is a total, and a total cannot
	// tell a level an agent can cross from the same level cut into islands: a
	// doorway one cell too narrow, a step one cell too high or a ramp that does
	// not quite reach all leave `walkable` looking exactly right, `field()`
	// returning a live field rather than null, and `direction()` answering
	// (0, 0, 0) for every agent on the wrong side of the break. Anything above
	// 1 means "there is no path" is the honest answer for some pairs of points
	// in this level — usually a `cell` too coarse for the geometry.
	stats() { return H.navStats(); },

	// Throw the bake and every field over it away.
	clear() { H.navClear(); },

	// Solve towards one or more goals and keep the answer.
	//
	// Takes a point or an array of points. Many goals is not "several routes" —
	// it is ONE field whose value is the distance to the nearest of them, which
	// is what a crowd heading for whichever exit is closest wants.
	//
	// Returns null when no goal landed on a walkable cell, which is the usual
	// way a goal is wrong: it was given at the height of the floor's underside,
	// or inside a wall, or outside the baked region.
	field(goals) {
		const flat = readGoals(goals, 'three.nav.field(goals)');
		const handle = H.navField(flat.buffer, flat.byteOffset, flat.length);
		return handle < 0 ? null : new NavField(handle);
	},

	// One agent, one route, shortened against the geometry.
	//
	// **This solves a whole field and throws it away.** For a wanderer
	// replanning every few seconds that is the right trade; for a crowd it is
	// the thing `field()` exists to replace.
	//
	// Answers with an array of Vector3 waypoints on the walking surface,
	// starting at the point given, or an empty array when there is no route.
	// The straight lines between them have been checked with a capsule sweep at
	// the agent's own size, so a corner the agent cannot physically round has
	// not been cut — §17: "a game that walks cell centres looks like
	// it is walking cell centres."
	path(from, to, options = null) {
		const [fx, fy, fz] = readVector(from, 'three.nav.path(from, to)');
		const [tx, ty, tz] = readVector(to, 'three.nav.path(from, to)');
		const limit = Math.max(2, Math.floor(+(options?.limit ?? 64)));
		const out = new Float32Array(limit * 3);
		const count = H.navPath(fx, fy, fz, tx, ty, tz, out.buffer, out.byteOffset, out.length);
		const points = [];
		for (let i = 0; i < count; i++) points.push(new Vector3(null, out[i * 3], out[i * 3 + 1], out[i * 3 + 2]));
		return points;
	},
};

// Fill `velocities` with a desired velocity per agent — the crowd verb.
//
// **One crossing however many agents there are**, which is the whole point.
// `notes.md` §17 measured the boundary and the rule it wrote down is that a
// verb answering with vectors writes into a Float32Array the caller owns; this
// is that rule at crowd scale. A hundred agents cost one call.
//
//     const p = new Float32Array(n * 3);   // where they are
//     const v = new Float32Array(n * 3);   // filled by this
//     three.steer(p, v, { field, maxSpeed: 3, arrive: 1.5, separation: 0.8 });
//
// `positions` is read and never written; `velocities` is written and never
// read. Both are three floats per agent.
//
// Options:
//
//     field        a NavField — knows the way around a wall
//     goal         a point, when there is no field — straight-line seeking
//     maxSpeed     units per second, and the cap on the whole answer
//     arrive       start slowing this far from the goal; 0 never slows
//     separation   how close two agents get before they push apart
//     separationWeight   how hard, relative to the pull towards the goal
//
// A field wins over a goal when both are given: a field already knows the way
// around a wall and a goal does not, so a caller with both meant the field and
// was naming the goal for the arrive.
//
// The answer is a DESIRED velocity, not a position. Integrating it, damping it,
// and deciding whether an agent may actually go there are the caller's — which
// is what lets the same call feed three.moveAndSlide for agents that collide
// and a plain add for agents that do not.
export function steer(positions, velocities, options = null) {
	const where = 'three.steer(positions, velocities, options)';
	if (!(positions instanceof Float32Array) || !(velocities instanceof Float32Array)) {
		throw new TypeError(`${where} wants two Float32Arrays, three floats per agent`);
	}

	const field = options?.field ?? null;
	if (field !== null && !(field instanceof NavField)) {
		throw new TypeError(`${where}: field is what three.nav.field(goals) answered with`);
	}
	const handle = field === null || !field.alive ? -1 : field._h;

	let gx = 0, gy = 0, gz = 0;
	if (options?.goal !== undefined && options.goal !== null) {
		[gx, gy, gz] = readVector(options.goal, `${where}: goal`);
	} else if (handle < 0) {
		throw new TypeError(`${where} wants either a field or a goal — with neither there is nowhere to steer`);
	}

	return H.steer(
		positions.buffer, positions.byteOffset, positions.length,
		velocities.buffer, velocities.byteOffset, velocities.length,
		handle, gx, gy, gz,
		+(options?.maxSpeed ?? 1),
		+(options?.arrive ?? 0),
		+(options?.separation ?? 0),
		+(options?.separationWeight ?? 1));
}
