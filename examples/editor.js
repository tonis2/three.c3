// editor.js — a kit editor: select, move, rotate, delete, duplicate, undo,
// a Blender-style asset browser over a kit's own pieces, and placing with
// three snaps in the order they earn their place — grid, face, marker.
//
// The browser is a dock along the bottom: a catalog column on the left (the
// open kit's file, and a category list built from each piece name's own
// `category_rest` convention — `wall_stone` catalogs under `wall`), and a
// search field over a scrollable grid of thumbnail cards on the right, one
// per piece, each an isometric wireframe of its own bounding box. A kit that
// wraps its pieces in one outer "root" empty (as an exported Blender scene
// usually does) still opens straight onto them — see `buildPieceList` for
// the one rule that decides what counts as a piece. `View > Asset browser`
// toggles the dock; the choice is remembered in `three.persist`, next to
// the others.
//
// Run it against a kit folder (a directory holding one or more .glb files):
//
//     ./build/three --assets /path/to/kit-folder --script examples/editor.js
//
// or copy this file in as that folder's own main.js and boot it directly:
//
//     ./build/three --assets /path/to/kit-folder
//
// ## Controls
//
// The keyboard is the `Keys` class near the end, one method per key, and
// `three.keys()` lists it. The mouse:
//
//   click            select the piece under the cursor, or nothing · commit a grab
//   shift+click      add the piece to the selection, or take it back out
//   ctrl+click       place the asset browser's stamp here
//   shift (held)     while placing or committing: skip the snap, freehand
//
// ## Grabbing and scaling on one axis
//
// `g` then `x`, `y` or `z` is the Blender gesture and means the same thing: the
// move is confined to that direction, measured along the line the piece started
// on, and a line in that axis's own colour is drawn through it while it holds.
// The same key again frees it, a different one switches, and escape steps back
// out of the lock before it gives up on the move. The grid still applies to the
// axis that moved, and shift still skips it.
//
// `s` is the same shape, and takes the same axis keys for a non-uniform scale.
// Its ruler is how far the cursor is from the piece on a plane through it
// facing the camera — pull away to grow, come in to shrink — which is the
// depth-corrected reading of Blender's screen distance, and the only one there
// is here: the API has no world-to-screen projection to measure with.
// The factor rounds to quarters unless shift is held, each piece scales about
// its own pivot, and a click commits exactly as a grab's does.
//
// ## How the file is laid out
//
// Pure helpers first (geometry, naming, the kit's node tree), then `Editor`,
// the one object holding every piece of editor state and every operation on
// it, then the widgets that draw it, then the keys. `globalThis.editor` is the
// scriptable surface over the same `Editor`, for headless drivers.

// ---------------------------------------------------------------------------
// World
// ---------------------------------------------------------------------------

const scene = new three.Scene();
three.light.set([0.4, 0.85, 0.32], 0.35);

// Grid and selection outlines both want to sit apart from the level's own
// pieces so a script can tell "the kit" from "the editor's own furniture" at
// a glance — `level.objects` is exactly the first half. Only the grid lives
// here, though: a BoxHelper is refused anywhere but the parent of what it
// outlines, so a selection outline hangs directly off `scene`, beside the
// pieces, and `frameAllExcludingHelpers` only has the grid worth excluding —
// a selection box roughly reads as the piece it wraps anyway.
const helpers = new three.Group();
helpers.name = '__helpers__';
scene.add(helpers);
const gridHelper = new three.GridHelper(40, 40, 0x445566);
helpers.add(gridHelper);

// The active piece — the last one picked — is the bright outline, because a
// grab and the properties panel are both about that one and nothing else says
// which it is.
const ACTIVE_COLOR = 0xffff00;
const ALSO_COLOR = 0xb08a20;
const CLASH_COLOR = 0xff3333;

// The line drawn along a locked axis, in the colours an axis is always drawn
// in — x red, y green, z blue, the same three `AxesHelper` uses. It lives in
// `helpers` rather than beside the pieces for one reason worth naming: it is
// 200 units long, and `frameAll` measures what is drawable rather than what is
// interesting, so anywhere else a `home` press mid-grab would frame the guide
// instead of the level.
const AXIS_COLOR = { x: 0xff4d4d, y: 0x4dff77, z: 0x4d9dff };
const AXIS_REACH = 100;

function frameAllExcludingHelpers() {
	const parent = helpers.parent;
	if (parent) parent.remove(helpers);
	three.camera.frameAll();
	if (parent) parent.add(helpers);
}

// ---------------------------------------------------------------------------
// Small helpers — geometry and naming, nothing here touches state
// ---------------------------------------------------------------------------

const held = (key) => three.input.isDown(key);

// `three.wrapAngle` folds into [-pi, pi); the brief wants rotation kept in
// [0, 2*pi), which is the more readable "how many quarter turns" number.
function wrapTurn(radians) {
	const twoPi = Math.PI * 2;
	const r = radians % twoPi;
	return r < 0 ? r + twoPi : r;
}

// The world ray through a pixel, met with the horizontal plane at `planeY`
// — `three.camera.ray`'s own doc example, generalised off y = 0 so a grab
// can hold the piece's own height instead of the ground's.
function groundHit(px, py, planeY) {
	const r = three.camera.ray(px, py);
	if (Math.abs(r.direction.y) < 1e-8) return null;
	const t = (planeY - r.origin.y) / r.direction.y;
	if (t < 0) return null;
	return r.origin.clone().addScaledVector(r.direction, t);
}

// How far along `axis` the cursor is, for a grab locked to one direction: the
// point on the line `start + t * axis` closest to the ray through the pixel,
// which is the only reading that works for y as well as for x and z — a
// horizontal plane says nothing about height.
//
// The classic closest-approach of two lines. Answers the axis's new coordinate,
// or null when the camera is looking straight down the axis and the answer is
// a division by nearly zero rather than a position.
function axisUnderCursor(start, axis, px, py) {
	const ray = three.camera.ray(px, py);
	const u = { x: axis === 'x' ? 1 : 0, y: axis === 'y' ? 1 : 0, z: axis === 'z' ? 1 : 0 };
	const v = ray.direction;
	const w = { x: start.x - ray.origin.x, y: start.y - ray.origin.y, z: start.z - ray.origin.z };
	const b = u.x * v.x + u.y * v.y + u.z * v.z;
	const c = v.x * v.x + v.y * v.y + v.z * v.z;
	const uw = u.x * w.x + u.y * w.y + u.z * w.z;
	const vw = v.x * w.x + v.y * w.y + v.z * w.z;
	// a is u·u, and u is a unit axis, so it is 1.
	const denom = c - b * b;
	if (Math.abs(denom) < 1e-6) return null;
	return start[axis] + (b * vw - c * uw) / denom;
}

// How far the cursor is from `anchor`, measured on the plane through it that
// faces the camera — the scale gesture's ruler.
//
// Not the ground plane, which was the first try and is wrong in a way that is
// invisible until it bites: a ray through a cursor above the horizon never
// meets y = 0, so the gesture silently froze whenever the camera was tilted up.
// A camera-facing plane is hit by every ray through the viewport, and the
// distance on it is the depth-corrected version of "how far the cursor is from
// the thing on screen", which is the reading Blender's own scale has.
//
// The anchor is a POINT captured once and not the piece's live centre: a piece
// grows about its pivot, so its centre moves as it is scaled, and measuring to
// something the gesture is itself moving is a feedback loop — the factor
// crept away from what the cursor was asking for, frame after frame.
function cursorReach(anchor) {
	const pointer = three.input.pointer;
	const ray = three.camera.ray(pointer.x, pointer.y);
	const n = three.camera.forward();
	const denom = ray.direction.x * n.x + ray.direction.y * n.y + ray.direction.z * n.z;
	if (Math.abs(denom) < 1e-8) return null;
	const t = ((anchor.x - ray.origin.x) * n.x + (anchor.y - ray.origin.y) * n.y + (anchor.z - ray.origin.z) * n.z) / denom;
	if (!(t > 0)) return null;
	return Math.hypot(
		ray.origin.x + ray.direction.x * t - anchor.x,
		ray.origin.y + ray.direction.y * t - anchor.y,
		ray.origin.z + ray.direction.z * t - anchor.z,
	);
}

// Where the piece is, as three plain numbers that will not move under the
// gesture: its box centre if it has one, its pivot if it does not.
function anchorOf(object) {
	const box = object.boundingBox();
	const at = box ? box.center : object.position;
	return { x: at.x, y: at.y, z: at.z };
}

function snapAxisToGrid(object, axis) {
	const box = object.boundsInParent();
	if (!box) return;
	object.align(axis, 'min', Math.round(box.edge(axis, 'min')));
}

// A marker is a leaf node with no mesh — the same test `object3d.js`'s
// private `markerNames` makes, read back here from the public surface
// (`instanceof three.Mesh` standing in for its `_ref() === null`) since the
// helper itself is not exported.
function markerNamesOf(object) {
	const names = [];
	object.traverse(o => {
		if (o !== object && o.children.length === 0 && !(o instanceof three.Mesh) && o.name) names.push(o.name);
	});
	return names;
}

function commonMarkers(a, b) {
	const theirs = new Set(markerNamesOf(b));
	return markerNamesOf(a).filter(n => theirs.has(n));
}

// The side `snapTo` wants, off a world normal's dominant axis and sign — a
// roof's underside (0,-1,0) goes on a wall's '+y', a wall's left face on the
// next wall's '-x' or '+x' depending which way the normal points.
function sideFromNormal(n) {
	const ax = Math.abs(n.x), ay = Math.abs(n.y), az = Math.abs(n.z);
	if (ax >= ay && ax >= az) return n.x >= 0 ? '+x' : '-x';
	if (ay >= ax && ay >= az) return n.y >= 0 ? '+y' : '-y';
	return n.z >= 0 ? '+z' : '-z';
}

function positionText(object) {
	return `${object.position.x.toFixed(2)}, ${object.position.y.toFixed(2)}, ${object.position.z.toFixed(2)}`;
}

// ---------------------------------------------------------------------------
// The kit's own node hierarchy — read straight off `asset._rows(false)` (the
// same flattened, parent-indexed table `instantiate()` builds objects from;
// see `js_asset_nodes` in src/js/bind_asset.c3 and `Asset._rows` in
// src/js/prelude/asset.js for the row shape: `{ name, parent, mesh, ... }`,
// parents always before children).
// ---------------------------------------------------------------------------

function buildAssetTree(asset) {
	if (!asset) return null;
	const rows = asset._rows(false);
	const n = rows.length;
	const hasMesh = new Array(n).fill(false);
	const depth = new Array(n).fill(0);
	const childCount = new Array(n).fill(0);
	for (let i = 0; i < n; i++) {
		const parent = rows[i].parent;
		if (rows[i].mesh !== -1) hasMesh[i] = true;
		if (parent >= 0) childCount[parent]++;
		depth[i] = parent >= 0 ? depth[parent] + 1 : 0; // parent < i always
	}
	// Backward: a child (always a larger index than its parent) is seen
	// before its parent's own turn, so one pass propagates "a mesh sits
	// somewhere in this subtree" all the way up to every ancestor.
	for (let i = n - 1; i >= 0; i--) {
		const parent = rows[i].parent;
		if (hasMesh[i] && parent >= 0) hasMesh[parent] = true;
	}
	return { rows, hasMesh, depth, childCount };
}

// The category a piece catalogs under: the text before its first `_`, or the
// whole name when it has none — `wall_stone` catalogs under `wall`, `convex`
// stays `convex`.
function categoryOf(name) {
	const i = name.indexOf('_');
	return i > 0 ? name.slice(0, i) : name;
}

// The shallowest drawable nodes — what the asset browser calls "pieces".
//
// Start with the file's own top-level nodes that have a mesh somewhere in
// their subtree (a bare `camera` or `sun` sibling has none and drops out
// here for free). While there is EXACTLY ONE such node and it has no mesh of
// its own, descend into its drawable children instead — that is the one
// rule that opens a Blender `root`-wrapped kit straight onto its own pieces
// while leaving an already-flat kit flat, and it treats a multi-part piece
// (a door with a frame and a leaf) as one card, because a flat kit's door
// is never the ONLY top-level candidate.
function buildPieceList(tree) {
	if (!tree) return [];
	const { rows, hasMesh } = tree;
	const childrenOf = new Map();
	for (let i = 0; i < rows.length; i++) {
		const parent = rows[i].parent;
		if (parent < 0) continue;
		if (!childrenOf.has(parent)) childrenOf.set(parent, []);
		childrenOf.get(parent).push(i);
	}
	let candidates = [];
	for (let i = 0; i < rows.length; i++) if (rows[i].parent < 0 && hasMesh[i]) candidates.push(i);
	while (candidates.length === 1 && rows[candidates[0]].mesh === -1) {
		const kids = (childrenOf.get(candidates[0]) ?? []).filter(i => hasMesh[i]);
		if (kids.length === 0) break;
		candidates = kids;
	}
	return candidates.map(i => rows[i].name);
}

const isKitPath = (path) => /\.glb$|\.gltf$/i.test(path);

// ---------------------------------------------------------------------------
// Decorators for the editor's own methods
// ---------------------------------------------------------------------------

// A handler that throws is unbound for good — onKeyDown, onClick, a widget
// handler and a system all stop that way — so the UI-facing ones put the
// message on the status line instead. A method decorator, and also a plain
// wrapper for the arrow functions handed to widgets.
function safe(fn) {
	return function (...args) {
		try { return fn.apply(this, args); } catch (e) { ed.setStatus(String(e && e.message ? e.message : e)); }
	};
}

// What an `@undoable` edit answers when it turned out to change nothing, so no
// undo step is kept for it.
const UNCHANGED = Symbol('unchanged');
const UNDO_CAP = 100;

function pushSnapshot(stack, snap) {
	stack.push(snap);
	if (stack.length > UNDO_CAP) stack.shift();
}

// An edit to the level: the level as it stood is kept for undo (unless the
// edit answers UNCHANGED), the level is marked unsaved, and the interface is
// brought up to date. Every edit is the same three steps around a different
// middle, and this is where they are written once.
function undoable(method) {
	return function (...args) {
		const before = this.snapshot();
		const result = method.apply(this, args);
		if (result !== UNCHANGED) {
			this.remember(before);
			this.dirty = true;
		}
		this.sync();
		return result === UNCHANGED ? undefined : result;
	};
}

// A field `three.persist` mirrors under `key`, so it survives `three.reload()`:
// every assignment is written through. Its starting value is the field's own,
// and fills the key only if a previous run left nothing there — `boot` reads
// what was remembered before it replaces it.
function persisted(key) {
	return ({ set }) => ({
		init(value) { three.persist[key] ??= value; return value; },
		set(value) { set.call(this, value); three.persist[key] = value; },
	});
}

// ---------------------------------------------------------------------------
// The editor — every piece of state, and every operation on it
// ---------------------------------------------------------------------------

const SCALE_STEP = 0.25;   // what a factor rounds to unless shift is held
const SCALE_MIN = 0.05;
const SCALE_MAX = 20;
const REACH_MIN = 0.5;     // a cursor on top of the pivot is not a ruler
const MODES = ['grid', 'face', 'marker'];
const DEFAULT_LEVEL = 'levels/level.json';

class Editor {
	// The live three.level.Level — replaced whole by undo, open and new.
	level = null;
	// three.load(level.kit), its node tree, its pieces and one Card per piece:
	// the browser's model, rebuilt together by `useAsset` so they never drift.
	asset = null;
	assetTree = null;
	pieces = [];
	cards = new Map();

	// What a reload keeps.
	@persisted('path') accessor path = null;
	@persisted('mode') accessor mode = three.persist.mode ?? 'grid';
	// The selection, in the order it was picked. The last id is the active one
	// — see the header comment; `activeId` is the only reader of that rule.
	@persisted('selected') accessor selection = [];
	@persisted('dockOpen') accessor dockOpen = three.persist.dockOpen ?? true;

	stamp = null;            // the browser's piece that ctrl+click places
	// The two modal gestures, and only ever one of them live: a grab (`g`) and
	// a scale (`s`). Each keeps an original per piece to measure against or
	// put back, and an optional axis.
	grabbing = null;
	scaling = null;
	dirty = false;
	showGrid = true;
	markerChoice = null;
	markerChoices = [];
	lastError = '';
	undoStack = [];
	redoStack = [];

	// The dialogs.
	pendingKit = null;       // the kit a "discard changes?" is on the way to
	confirmDeleteIds = [];
	confirmDeleteOpen = false;
	confirmNewOpen = false;
	openDialogOpen = false;
	kitDialogOpen = false;
	saveAsOpen = false;
	saveAsText = '';
	exportOpen = false;
	exportText = '';

	// One outline per selected piece, in the selection's order, and the line
	// along a locked axis.
	outlines = [];
	axisGuide = null;

	// Whichever modal gesture is live reads the cursor here — this is the only
	// thing driving either of them, so a branch missing from this line is a key
	// that appears to do nothing at all.
	@three.systems.frame @safe
	follow() {
		if (this.grabbing) this.updateGrabPreview();
		else if (this.scaling) this.updateScalePreview();
		statusBar.sync();
		props.sync();
	}

	// The interface, up to date now rather than a frame late: the parts that
	// cache their own text re-sync, and both floors re-render so whatever
	// structural state changed — a dialog, a filter, a new kit — shows.
	sync() {
		props.sync();
		statusBar.sync();
		chrome.update();
		dialogs.update();
	}

	setStatus(message) {
		this.lastError = message;
		this.sync();
	}

	// ---- Reading the level --------------------------------------------------

	// The active piece: the last one picked, and the one every "there is only
	// room to say this about one of them" reading is about — the properties
	// panel, the snap a grab makes, the marker choice.
	get activeId() {
		return this.selection.length > 0 ? this.selection[this.selection.length - 1] : null;
	}

	// Whether a modal gesture owns the keyboard and the next click.
	get gesture() { return this.grabbing ?? this.scaling ?? null; }

	isSelected(id) { return this.selection.includes(id); }

	rowOf(id) { return this.level.rows.find(r => r.id === id); }

	// Walks up from whatever `scene.pick` handed back — often a Mesh several
	// levels inside a piece — to the row's own root, identified the way
	// `Level` identifies it: the object a row's id is the key for.
	pieceOf(object) {
		for (let o = object; o; o = o.parent) {
			if (this.level.objects.get(o.name) === o) return o;
		}
		return null;
	}

	freshId(piece) {
		let n = 1;
		while (this.level.objects.has(`${piece}_${n}`)) n++;
		return `${piece}_${n}`;
	}

	// Copies the piece's transform back onto its row, and its snap when one is
	// given (null for freehand).
	syncRow(id, snap) {
		const row = this.rowOf(id);
		const object = this.level.objects.get(id);
		if (!row || !object) return;
		row.position = object.position.toArray();
		row.rotation = object.rotation.toArray();
		row.scale = object.scale.toArray();
		if (snap !== undefined) {
			if (snap) row.snap = snap; else delete row.snap;
		}
	}

	// Whether `object` is inside anything that is not part of the selection —
	// what turns the outlines red while a grab is live. The whole selection is
	// excluded rather than just this one piece, because a row of walls moving
	// together is not a collision with itself.
	overlapsAnother(object) {
		const box = object.boundingBox().expandByScalar(-0.01);
		for (const hit of three.query.box(box)) {
			const other = this.pieceOf(hit);
			if (other && other !== object && !this.isSelected(other.name)) return true;
		}
		return false;
	}

	// ---- The kit ------------------------------------------------------------

	// Swaps in a freshly loaded kit and rebuilds the browser's models with it.
	useAsset(asset) {
		this.asset = asset;
		this.assetTree = buildAssetTree(asset);
		this.pieces = buildPieceList(this.assetTree).map(name => ({ name, category: categoryOf(name) }));
		const cards = new Map();
		for (const p of this.pieces) {
			let box = null;
			try { box = asset.node(p.name).boundsInParent(); } catch (e) { box = null; }
			cards.set(p.name, new Card(p.name, p.category, box));
		}
		this.cards = cards;
		if (this.stamp && !this.cards.has(this.stamp)) this.stamp = null;
		catalog.refresh();
		browser.update();
	}

	setStamp(piece) {
		this.stamp = piece;
		this.sync();
	}

	setMode(mode) {
		if (!MODES.includes(mode)) return;
		this.mode = mode;
		this.sync();
	}

	// ---- Undo / redo --------------------------------------------------------
	//
	// Snapshots of level.toJSON(), deep-cloned because toJSON() hands back the
	// level's own row objects and mutates them in place on every future call,
	// which would otherwise corrupt a stored snapshot silently.

	snapshot() { return JSON.parse(JSON.stringify(this.level.toJSON())); }

	// Keep `before` as the newest undo step; anything that was redoable no
	// longer follows from it.
	remember(before) {
		pushSnapshot(this.undoStack, before);
		this.redoStack = [];
	}

	undo() { this.travel(this.undoStack, this.redoStack); }
	redo() { this.travel(this.redoStack, this.undoStack); }

	// Restore the newest snapshot on `from`, keeping the level as it is on `to`.
	travel(from, to) {
		if (from.length === 0) return;
		pushSnapshot(to, this.snapshot());
		this.restore(from.pop());
		// The ids that survived the restore, in the order they were picked.
		this.select(this.selection.filter(id => this.level.objects.has(id)));
		this.dirty = true;
		this.sync();
	}

	// Take every current piece out of the scene, ahead of a level replacing it.
	clearLevel() {
		if (!this.level) return;
		for (const obj of [...this.level.objects.values()]) if (obj.parent) obj.parent.remove(obj);
	}

	// Rebuilds a Level from a saved snapshot — `load` without the file: drop
	// every current object and replay `add(row)` in order over a fresh
	// `three.level.create(kit)`.
	restore(snap) {
		this.clearLevel();
		const next = three.level.create(snap.kit);
		next.parent = scene;
		for (const row of snap.rows) next.add(row);
		this.level = next;
		this.useAsset(snap.kit ? three.load(snap.kit) : null);
	}

	// ---- Placement — the one rule "what does a cursor mean", shared by a fresh
	// stamp, a live grab preview and a grab's final commit. ---------------------

	// Moves `object` (already in the scene, rotation already set) according to
	// the current mode, a ground-plane candidate point and an optional pick hit.
	// Answers the row's new `snap` (or null for freehand) — it does not touch
	// the row itself, so a caller can decide when that write happens.
	placeByMode(object, groundPoint, pickHit, opts = {}) {
		const freehand = !!opts.freehand;
		const mode = opts.mode ?? this.mode;

		if (!freehand && (mode === 'face' || mode === 'marker')) {
			const target = pickHit && pickHit.object ? this.pieceOf(pickHit.object) : null;
			if (target && target !== object) {
				if (mode === 'marker') {
					const common = commonMarkers(object, target);
					this.markerChoices = common;
					const marker = common.includes(this.markerChoice) ? this.markerChoice : common[0];
					if (marker) {
						this.markerChoice = marker;
						object.snapTo(target, marker);
						return { to: target.name, side: marker };
					}
					// No marker in common — the documented fallback is face, not grid.
				}
				const side = sideFromNormal(pickHit.normal);
				object.position.copy(pickHit.point);
				object.snapTo(target, side);
				for (const axis of ['x', 'y', 'z']) {
					if (axis !== side[1]) snapAxisToGrid(object, axis);
				}
				return { to: target.name, side };
			}
		}

		// The grid rule — the default mode, and the fallback for face/marker
		// when nothing is under the cursor.
		if (freehand) {
			object.position.x = groundPoint.x;
			object.position.z = groundPoint.z;
			return null;
		}
		object.align('x', 'min', Math.round(groundPoint.x));
		object.align('z', 'min', Math.round(groundPoint.z));
		return null;
	}

	// A new piece of the kit, placed by the mode at a ground point. Answers its
	// id, or nothing when it was refused.
	@undoable
	place(piece, groundPoint, pickHit, opts = {}) {
		if (!this.asset || !this.asset.nodes.includes(piece)) {
			this.setStatus(`no piece named '${piece}' in the current kit`);
			return UNCHANGED;
		}
		// The same "nothing to draw" refusal the browser's own pieces already
		// exclude, kept here too: a stamp set straight through editor.stamp() (a
		// script driving this headlessly, say) never saw that filter.
		if (this.asset.node(piece).boundsInParent() === null) {
			this.stamp = null;
			this.setStatus(`${piece} has nothing to draw`);
			return UNCHANGED;
		}
		const id = this.freshId(piece);
		let object;
		try {
			object = this.level.add({ id, piece, position: [0, 0, 0], rotation: [0, 0, 0] });
		} catch (e) {
			this.setStatus(String(e.message ?? e));
			return UNCHANGED;
		}
		this.syncRow(id, this.placeByMode(object, groundPoint, pickHit, opts));
		this.select(id);
		this.setStatus(`placed ${id}`);
		return id;
	}

	// ---- Selection and the outlines that follow it --------------------------

	rebuildOutlines() {
		for (const { helper } of this.outlines) if (helper.parent) helper.parent.remove(helper);
		this.outlines = [];
		const active = this.activeId;
		for (const id of this.selection) {
			const object = this.level.objects.get(id);
			if (!object || !object.parent) continue;
			const helper = new three.BoxHelper(object, id === active ? ACTIVE_COLOR : ALSO_COLOR);
			object.parent.add(helper);
			this.outlines.push({ id, helper });
		}
	}

	updateOutlines() {
		const active = this.activeId;
		for (const { id, helper } of this.outlines) {
			helper.update();
			const object = this.level.objects.get(id);
			const clash = object ? this.overlapsAnother(object) : false;
			helper.color = clash ? CLASH_COLOR : id === active ? ACTIVE_COLOR : ALSO_COLOR;
		}
	}

	// The one writer of `selection` — everything else goes through `select` or
	// `toggle`, so the outlines, the panel and `three.persist` cannot drift
	// from the list.
	setSelection(ids) {
		// A Set keeps it deduplicated and an array keeps the order it was
		// picked in, which is the order the last-is-active rule reads.
		const seen = new Set();
		const kept = [];
		for (const id of ids) {
			if (!id || seen.has(id) || !this.level.objects.has(id)) continue;
			seen.add(id);
			kept.push(id);
		}
		this.selection = kept;
		this.markerChoice = null;
		this.markerChoices = [];
		this.rebuildOutlines();
		this.sync();
	}

	// One id, a list of them, or null for nothing.
	select(ids) {
		if (ids === null || ids === undefined) { this.setSelection([]); return; }
		this.setSelection(Array.isArray(ids) ? ids : [ids]);
	}

	// What shift+click does: out if it was in, and on the END if it was not,
	// so the piece just added is the active one.
	toggle(id) {
		if (!id || !this.level.objects.has(id)) return;
		this.setSelection(this.isSelected(id) ? this.selection.filter(other => other !== id) : [...this.selection, id]);
	}

	// ---- Axis lock, shared by both gestures ---------------------------------

	showAxisGuide(axis, at) {
		this.hideAxisGuide();
		if (!axis) return;
		const min = { x: at.x, y: at.y, z: at.z };
		const max = { x: at.x, y: at.y, z: at.z };
		min[axis] -= AXIS_REACH;
		max[axis] += AXIS_REACH;
		// A box with two axes of zero size draws as the line along the third:
		// the twelve edges collapse onto one segment, which is the picture
		// wanted and one mesh rather than a new primitive.
		this.axisGuide = new three.Box3Helper(new three.Box3(min.x, min.y, min.z, max.x, max.y, max.z), AXIS_COLOR[axis]);
		helpers.add(this.axisGuide);
	}

	hideAxisGuide() {
		if (this.axisGuide && this.axisGuide.parent) this.axisGuide.parent.remove(this.axisGuide);
		this.axisGuide = null;
	}

	// Lock the live gesture to one direction, or free it again with null. The
	// line is drawn through the active piece as it stands, and a move is
	// measured from where the grab began, so switching from x to z puts back
	// the x it had rather than keeping a half-finished move on an axis nobody
	// chose. A scale recomputes from each piece's original either way.
	setAxis(axis) {
		const op = this.gesture;
		if (!op) return;
		op.axis = axis;
		const lead = this.level.objects.get(this.grabbing ? this.grabbing.id : this.activeId);
		const box = lead ? lead.boundingBox() : null;
		if (axis && box) this.showAxisGuide(axis, box.center); else this.hideAxisGuide();
		if (this.grabbing) this.updateGrabPreview(); else this.updateScalePreview();
		this.sync();
	}

	// Pressing the axis already locked frees it, so the same key is on and off.
	toggleAxis(axis) {
		const op = this.gesture;
		if (op) this.setAxis(op.axis === axis ? null : axis);
	}

	// Both gestures end the same way, committed or not.
	endGesture() {
		this.grabbing = null;
		this.scaling = null;
		this.hideAxisGuide();
		this.select(this.selection);
	}

	commit() {
		if (this.scaling) this.commitScale(); else this.commitGrab();
	}

	// Escape backs out one step at a time: the axis lock first, then the
	// gesture, then the stamp. Undoing a whole move because the axis was the
	// wrong one is the annoyance that made this two steps rather than one.
	cancel() {
		const op = this.gesture;
		if (op && op.axis) { this.setAxis(null); return; }
		if (this.grabbing) this.cancelGrab();
		else if (this.scaling) this.cancelScale();
		else if (this.stamp) this.stamp = null;
		this.sync();
	}

	// ---- Grab — a live preview driven by the cursor every frame, committed or
	// cancelled on a click / escape.
	//
	// The active piece is the one the cursor and the snap rules are about; the
	// rest of the selection holds the offset it had when the grab began, which
	// is what makes moving a wall and its door move the pair rather than stack
	// them. ------------------------------------------------------------------

	grab() {
		if (this.selection.length === 0 || this.gesture) return;
		const id = this.activeId;
		const lead = this.level.objects.get(id);
		if (!lead) return;
		const followers = [];
		const original = new Map();
		for (const other of this.selection) {
			const object = this.level.objects.get(other);
			if (!object) continue;
			const theirRow = this.rowOf(other);
			original.set(other, {
				position: object.position.toArray(),
				rotation: object.rotation.toArray(),
				snap: theirRow && theirRow.snap ? { ...theirRow.snap } : null,
			});
			if (other === id) continue;
			followers.push({
				id: other,
				offset: [
					object.position.x - lead.position.x,
					object.position.y - lead.position.y,
					object.position.z - lead.position.z,
				],
			});
		}
		this.grabbing = {
			id,
			followers,
			original,
			// Which single direction the move is confined to, or null for the
			// cursor's own reading of the ground. `x` / `y` / `z` while grabbing.
			axis: null,
			before: this.snapshot(),
			lastSnap: this.rowOf(id)?.snap ?? null,
		};
	}

	updateGrabPreview() {
		const grab = this.grabbing;
		if (!grab) return;
		const lead = this.level.objects.get(grab.id);
		if (!lead) { this.grabbing = null; return; }
		const pointer = three.input.pointer;
		const freehand = held('shift');

		if (grab.axis) {
			// One coordinate moves and the other two go back to where the grab
			// began — which is what "on this axis only" has to mean, and why the
			// start position is read from `original` rather than from the piece.
			const start = grab.original.get(grab.id).position;
			const from = { x: start[0], y: start[1], z: start[2] };
			const along = axisUnderCursor(from, grab.axis, pointer.x, pointer.y);
			if (along !== null) {
				lead.position.set(
					grab.axis === 'x' ? along : from.x,
					grab.axis === 'y' ? along : from.y,
					grab.axis === 'z' ? along : from.z,
				);
				// The grid still applies, on the one axis that moved; shift is
				// the same "skip the snap" it is everywhere else here.
				if (!freehand) snapAxisToGrid(lead, grab.axis);
			}
			// A constrained move is a move and not a snap: whatever it used to
			// hang off, it is where the axis put it now.
			grab.lastSnap = null;
		} else {
			const groundPoint = groundHit(pointer.x, pointer.y, lead.position.y);
			const hit = scene.pick(pointer.x, pointer.y);
			if (groundPoint) grab.lastSnap = this.placeByMode(lead, groundPoint, hit, { freehand });
		}

		for (const follower of grab.followers) {
			const object = this.level.objects.get(follower.id);
			if (!object) continue;
			object.position.set(
				lead.position.x + follower.offset[0],
				lead.position.y + follower.offset[1],
				lead.position.z + follower.offset[2],
			);
		}
		this.updateOutlines();
	}

	// The grab's own snapshot, taken when it began, is the undo step — not one
	// taken now, which would already hold the move.
	commitGrab() {
		if (!this.grabbing) return;
		this.updateGrabPreview();
		if (!this.grabbing) return;
		const { id, followers, before, lastSnap } = this.grabbing;
		this.syncRow(id, lastSnap ?? null);
		// A follower was carried rather than snapped, so whatever it used to be
		// snapped to is no longer where it is — the row says freehand and means it.
		for (const follower of followers) this.syncRow(follower.id, null);
		this.remember(before);
		this.endGesture();
		this.dirty = true;
	}

	cancelGrab() {
		for (const [id, orig] of this.grabbing.original) {
			const object = this.level.objects.get(id);
			if (!object) continue;
			object.position.set(...orig.position);
			object.rotation.set(...orig.rotation);
			this.syncRow(id, orig.snap);
		}
		this.endGesture();
	}

	// ---- Scale — `s`, the same modal shape as a grab: live under the cursor,
	// locked to an axis with x / y / z, committed with a click and cancelled
	// with escape.
	//
	// The ruler is `cursorReach`. Each piece scales about its own pivot and
	// keeps its position, which is the same choice `rotate` makes: a kit's
	// pieces are placed by their own origins, so scaling around a shared centre
	// would slide four walls off their corners. ---------------------------------

	startScale() {
		if (this.selection.length === 0 || this.gesture) return;
		const lead = this.level.objects.get(this.activeId);
		if (!lead) return;
		const original = new Map();
		for (const id of this.selection) {
			const object = this.level.objects.get(id);
			if (object) original.set(id, object.scale.toArray());
		}
		if (original.size === 0) return;
		const anchor = anchorOf(lead);
		this.scaling = {
			axis: null,
			original,
			anchor,
			// Set only by `editor.scale(factor)` — see `updateScalePreview`.
			pinned: false,
			reach: Math.max(cursorReach(anchor) ?? REACH_MIN, REACH_MIN),
			factor: 1,
			before: this.snapshot(),
		};
		this.sync();
	}

	applyScale() {
		if (!this.scaling) return;
		const { original, axis, factor } = this.scaling;
		for (const [id, base] of original) {
			const object = this.level.objects.get(id);
			if (!object) continue;
			// Always from the ORIGINAL, never from what is on screen: a preview
			// that multiplied what it drew last frame would compound sixty times
			// a second, and locking an axis after a uniform pull could not put
			// the other two back.
			object.scale.set(
				!axis || axis === 'x' ? base[0] * factor : base[0],
				!axis || axis === 'y' ? base[1] * factor : base[1],
				!axis || axis === 'z' ? base[2] * factor : base[2],
			);
		}
	}

	updateScalePreview() {
		const scaling = this.scaling;
		if (!scaling) return;
		if (!this.level.objects.has(this.activeId)) { this.scaling = null; this.hideAxisGuide(); return; }
		// A factor a script named is the factor, and the cursor does not get a
		// vote: without this the next frame — or the read `commitScale` does —
		// would quietly put the pointer's own reading back over it.
		if (!scaling.pinned) {
			const reach = cursorReach(scaling.anchor);
			if (reach !== null) {
				const raw = reach / scaling.reach;
				const free = held('shift');
				const stepped = free ? raw : Math.round(raw / SCALE_STEP) * SCALE_STEP;
				scaling.factor = Math.min(Math.max(stepped, free ? SCALE_MIN : SCALE_STEP), SCALE_MAX);
			}
		}
		this.applyScale();
		this.updateOutlines();
	}

	commitScale() {
		if (!this.scaling) return;
		this.updateScalePreview();
		if (!this.scaling) return;
		const { before, original } = this.scaling;
		// `snap` is left alone: it aligns edges, and a piece that grew still
		// meets the face it was snapped to along the edge the loader will align
		// again.
		for (const id of original.keys()) this.syncRow(id);
		this.remember(before);
		this.endGesture();
		this.dirty = true;
	}

	cancelScale() {
		for (const [id, base] of this.scaling.original) {
			const object = this.level.objects.get(id);
			if (object) object.scale.set(...base);
		}
		this.endGesture();
	}

	// No factor starts the interactive gesture, the way `s` does; a factor is
	// the whole thing at once — start, scale, commit — which is what a script
	// with no cursor to pull actually wants.
	scaleBy(factor) {
		if (factor === undefined) { this.startScale(); return; }
		const wanted = +factor;
		if (!(wanted > 0)) return;
		const live = !!this.scaling;
		if (!live) this.startScale();
		if (!this.scaling) return;
		this.scaling.factor = Math.min(Math.max(wanted, SCALE_MIN), SCALE_MAX);
		this.scaling.pinned = true;
		this.applyScale();
		if (!live) this.commitScale();
	}

	// ---- Rotate, nudge, duplicate, delete -------------------------------------

	// Every selected piece turns about its own centre rather than the group's,
	// which is what a kit wants: four walls each facing the way they were
	// built, turned a quarter each, still make a room. Mid-grab the turn is part
	// of the move, and the grab's commit is its undo step.
	rotate(dir) {
		if (this.selection.length === 0 || this.scaling) return;
		if (!this.grabbing) { this.turnPlaced(dir); return; }
		if (this.turnSelection(dir)) this.sync();
	}

	@undoable
	turnPlaced(dir) {
		if (!this.turnSelection(dir)) return UNCHANGED;
		for (const id of this.selection) this.syncRow(id);
	}

	// Answers how many pieces turned.
	turnSelection(dir) {
		let turned = 0;
		for (const id of this.selection) {
			const object = this.level.objects.get(id);
			if (!object) continue;
			object.rotation.y = wrapTurn(object.rotation.y + dir * Math.PI / 2);
			turned++;
		}
		if (turned > 0) this.updateOutlines();
		return turned;
	}

	@undoable
	nudge(dx, dy, dz) {
		if (this.selection.length === 0 || this.gesture) return UNCHANGED;
		let moved = 0;
		for (const id of this.selection) {
			const object = this.level.objects.get(id);
			if (!object) continue;
			object.position.set(object.position.x + dx, object.position.y + dy, object.position.z + dz);
			this.syncRow(id);
			moved++;
		}
		if (moved === 0) return UNCHANGED;
		this.updateOutlines();
	}

	// A copy of everything selected, one unit along x, selected in the order the
	// originals were — and then grabbed, so the copies land where the cursor says
	// rather than in the pile they were made in.
	@undoable
	duplicate() {
		if (this.selection.length === 0 || this.gesture) return UNCHANGED;
		const copies = [];
		for (const source of this.selection) {
			const src = this.rowOf(source);
			const object = this.level.objects.get(source);
			if (!src || !object) continue;
			const id = this.freshId(src.piece);
			this.level.add({
				id,
				piece: src.piece,
				position: [object.position.x + 1, object.position.y, object.position.z],
				rotation: object.rotation.toArray(),
			});
			copies.push(id);
		}
		if (copies.length === 0) return UNCHANGED;
		this.select(copies);
		this.grab();
	}

	@undoable
	refit() { this.level.refit(); }

	requestRemove() {
		if (this.selection.length === 0) return;
		this.confirmDeleteIds = [...this.selection];
		this.confirmDeleteOpen = true;
		this.sync();
	}

	@undoable
	confirmRemove() {
		const ids = this.confirmDeleteIds.filter(id => this.level.objects.has(id));
		this.confirmDeleteIds = [];
		this.confirmDeleteOpen = false;
		if (ids.length === 0) return UNCHANGED;

		// A piece snapped to one of these keeps it alive — unless it is going
		// too, which is what makes "remove the wall and the door on it" work
		// while "remove the wall out from under the door" still does not.
		const going = new Set(ids);
		for (const id of ids) {
			const blocking = this.level.rows.find(r => r.snap && r.snap.to === id && !going.has(r.id));
			if (blocking) {
				this.setStatus(`cannot remove ${id} — ${blocking.id} snaps to it`);
				return UNCHANGED;
			}
		}
		for (const id of ids) this.level.remove(id);
		this.select(this.selection.filter(id => !going.has(id)));
		this.setStatus(ids.length === 1 ? `removed ${ids[0]}` : `removed ${ids.length} pieces`);
	}

	cancelRemove() {
		this.confirmDeleteIds = [];
		this.confirmDeleteOpen = false;
		this.sync();
	}

	// The whole selection, not just the active piece — framing one wall of four
	// that were picked together is a camera move nobody asked for.
	frameSelection() {
		let box = null;
		for (const id of this.selection) {
			const theirs = this.level.objects.get(id)?.boundingBox();
			if (theirs) box = box ? box.union(theirs) : theirs;
		}
		if (box) three.camera.lookAt(box.center.x, box.center.y, box.center.z);
	}

	toggleGrid() {
		this.showGrid = !this.showGrid;
		gridHelper.visible = this.showGrid;
	}

	toggleDock() {
		this.dockOpen = !this.dockOpen;
		this.sync();
	}

	// ---- Files ----------------------------------------------------------------

	save(path) {
		// `three.level.save` answers the full filesystem path it actually wrote
		// to, for a log or a status line — not what `path` wants, which has to
		// stay assets-relative so a later save, `three.level.load` and
		// `three.persist.path` all keep meaning the same file.
		const target = path ?? this.path ?? DEFAULT_LEVEL;
		three.level.save(target, this.level);
		this.path = target;
		this.dirty = false;
		this.sync();
		return this.path;
	}

	// A level replacing the current one wholesale: nothing selected, nothing to
	// undo back into.
	adopt(level, path) {
		this.level = level;
		this.useAsset(level.kit ? three.load(level.kit) : null);
		this.path = path;
		this.dirty = false;
		this.undoStack = [];
		this.redoStack = [];
		this.select(null);
	}

	open(path) {
		this.clearLevel();
		const next = three.level.load(path, scene);
		if (!next) {
			this.setStatus(`no level at ${path}`);
			return null;
		}
		this.adopt(next, path);
		frameAllExcludingHelpers();
		this.sync();
		return this.level;
	}

	newLevel(kit) {
		this.clearLevel();
		const next = three.level.create(kit);
		next.parent = scene;
		// A kit is now chosen, so whatever asked for one closes — the dialog's
		// own onChoose already does this before calling in on the normal path,
		// but `editor.newLevel()` (a script driving this headlessly, with no
		// dialog to click through) is a second way in that needs it done here.
		this.kitDialogOpen = false;
		this.adopt(next, null);
		this.sync();
		return this.level;
	}

	requestNew() {
		this.pendingKit = null;
		if (this.dirty) this.confirmNewOpen = true;
		else this.kitDialogOpen = true;
		this.sync();
	}

	// Picking a different kit straight off the catalog's library dropdown runs
	// the same discard flow as File > New, just already knowing which kit it is
	// headed for — `pendingKit` is what the confirm dialog's onConfirm reads
	// instead of falling back to the file browser.
	requestKitChange(path) {
		if (!path || (this.level && this.level.kit === path)) return;
		if (this.dirty) { this.pendingKit = path; this.confirmNewOpen = true; this.sync(); }
		else this.newLevel(path);
	}

	confirmNew() {
		this.confirmNewOpen = false;
		if (this.pendingKit) { const kit = this.pendingKit; this.pendingKit = null; this.newLevel(kit); }
		else this.kitDialogOpen = true;
		this.sync();
	}

	openSaveAs() {
		this.saveAsText = this.path ?? DEFAULT_LEVEL;
		this.saveAsOpen = true;
		this.sync();
	}

	openExport() {
		this.exportText = 'levels/level.glb';
		this.exportOpen = true;
		this.sync();
	}

	// The scene without the editor's own furniture: the grid is not the level.
	exportGlb(path) {
		const parent = helpers.parent;
		if (parent) parent.remove(helpers);
		try {
			this.setStatus(`exported ${scene.export(path || 'levels/level.glb').path}`);
		} finally {
			if (parent) parent.add(helpers);
		}
	}

	// three.persist.path, or the assets directory's one .glb, or a prompt
	// through the kit file browser.
	boot() {
		const bootPath = three.persist.path ?? DEFAULT_LEVEL;
		const loaded = three.level.load(bootPath, scene);
		if (loaded) {
			this.level = loaded;
			this.path = bootPath;
			this.useAsset(loaded.kit ? three.load(loaded.kit) : null);
		} else {
			// Forget a remembered path that no longer loads.
			this.path = null;
			const glbs = three.inventory().filter(e => isKitPath(e.path));
			const kit = glbs.length === 1 ? glbs[0].path : null;
			this.level = three.level.create(kit);
			this.level.parent = scene;
			if (kit) this.useAsset(three.load(kit));
			else this.kitDialogOpen = true;
		}
		// One id is what older runs of this editor remembered; a list is what it
		// remembers now, and both have to open the same way.
		const remembered = three.persist.selected;
		if (remembered) this.select(Array.isArray(remembered) ? remembered : [remembered]);
		frameAllExcludingHelpers();
	}

	// ---- The mouse ------------------------------------------------------------

	// Three clicks, and which one it is decided before anything else happens: a
	// gesture is modal and eats the click, then ctrl places, then shift adds,
	// then a plain click selects the one piece under the cursor. Holding a stamp
	// changes none of it — placing is ctrl+click, never the plain click.
	click(hit, x, y) {
		if (this.grabbing) { this.commitGrab(); return; }
		if (this.scaling) { this.commitScale(); return; }
		const piece = hit && hit.object ? this.pieceOf(hit.object) : null;

		if (held('ctrl')) {
			if (!this.stamp) { this.setStatus('nothing to place — pick a piece in the asset browser first'); return; }
			const groundPoint = groundHit(x, y, 0);
			if (!groundPoint) { this.setStatus('nothing to place on'); return; }
			this.place(this.stamp, groundPoint, hit, { freehand: held('shift') });
			return;
		}

		if (held('shift')) {
			// A shift+click on nothing keeps what is selected: the gesture is
			// "and this one too", and a miss should not undo the four before it.
			if (piece) this.toggle(piece.name);
			return;
		}

		this.select(piece ? piece.name : null);
	}
}

// ---------------------------------------------------------------------------
// The interface — a handful of widget classes; see the header comment.
// ---------------------------------------------------------------------------

const {
	Panel, Stack, Row, Column, Padding, Grid, Anchored, Scroll,
	Rect, Label, Drawing, Select, TextField, Tree, Button,
	ConfirmDialog, MenuBar, FileBrowser, Dialog,
} = three.ui;

const THEME = {
	panel: [0.19, 0.19, 0.19],
	header: [0.16, 0.16, 0.16],
	body: [0.11, 0.11, 0.11],
	accent: [0.28, 0.45, 0.70],
	text: [0.90, 0.90, 0.90],
	dim: [0.62, 0.62, 0.62],
	border: [1, 1, 1, 0.08],
	hover: [0.24, 0.24, 0.24],
	wireHidden: [0.85, 0.85, 0.85, 0.25],
	radius: 4,
};

const BAR_H = 28;    // cui's own default menu bar height (DEFAULT_MENU_STYLE.bar_height)
const STATUS_H = 24;
const DOCK_H = 240;
const HEADER_H = 30;
const CATALOG_W = 200;
const PROPS_W = 260;
const CARD_W = 108;
const CARD_H = 128;
const THUMB = 92;

// Every number above is in interface points, and this is how many pixels one of
// them is worth. It scales the whole interface rather than this file's own
// constants, so the parts nobody here can put a number on — a menu bar's height,
// a dialog's title, a file browser's rows — grow with the rest. Turn it down to
// 1 for the original size.
three.ui.scale = 1.25;

// ---------------------------------------------------------------------------
// Card thumbnails — an isometric wireframe of the piece's own bounding box.
// ---------------------------------------------------------------------------

const CATEGORY_PALETTE = [
	[0.62, 0.78, 0.62], [0.80, 0.62, 0.58], [0.58, 0.68, 0.82], [0.82, 0.72, 0.52],
	[0.74, 0.62, 0.82], [0.56, 0.76, 0.76], [0.82, 0.62, 0.74], [0.68, 0.78, 0.52],
];
function categoryColor(category) {
	let h = 0;
	for (let i = 0; i < category.length; i++) h = (h * 31 + category.charCodeAt(i)) >>> 0;
	return CATEGORY_PALETTE[h % CATEGORY_PALETTE.length];
}

const ISO_COS = Math.cos(Math.PI / 6);
const ISO_SIN = Math.sin(Math.PI / 6);

// `sx = (x - z) * cos30`, `sy = y + (x + z) * sin30`, flipped for screen
// (world up is negative screen y).
function isoProject(x, y, z) {
	return [(x - z) * ISO_COS, -(y + (x + z) * ISO_SIN)];
}

// The 8 corners of a unit box (bit i = the max side of axis i) and its 12
// edges; the 3 touching corner 0 (all-min) are the ones an isometric view
// from the all-max corner hides.
const BOX_CORNERS = [0, 1, 2, 3, 4, 5, 6, 7].map(i => [i & 1, (i >> 1) & 1, (i >> 2) & 1]);
const BOX_EDGES = (() => {
	const edges = [];
	for (let i = 0; i < 8; i++) for (const bit of [1, 2, 4]) { const j = i ^ bit; if (i < j) edges.push([i, j, i === 0]); }
	return edges;
})();

// Draws `box` as a wireframe inside the `size`-square at `at` (both in the
// card's own draw-op coordinates), scaled and centred to fit.
function wireframeOps(box, at, size, visibleColor, hiddenColor) {
	const corners = BOX_CORNERS.map(([bx, by, bz]) => isoProject(
		bx ? box.max.x : box.min.x, by ? box.max.y : box.min.y, bz ? box.max.z : box.min.z,
	));
	let minX = Infinity, maxX = -Infinity, minY = Infinity, maxY = -Infinity;
	for (const [x, y] of corners) {
		if (x < minX) minX = x; if (x > maxX) maxX = x;
		if (y < minY) minY = y; if (y > maxY) maxY = y;
	}
	const w = Math.max(maxX - minX, 1e-4), h = Math.max(maxY - minY, 1e-4);
	const scale = 0.86 * Math.min(size / w, size / h);
	const ox = at[0] + (size - w * scale) / 2 - minX * scale;
	const oy = at[1] + (size - h * scale) / 2 - minY * scale;
	const screen = corners.map(([x, y]) => [ox + x * scale, oy + y * scale]);
	const ops = [];
	for (const [a, b, hidden] of BOX_EDGES) if (hidden) ops.push({ op: 'line', from: screen[a], to: screen[b], thickness: 1, color: hiddenColor });
	for (const [a, b, hidden] of BOX_EDGES) if (!hidden) ops.push({ op: 'line', from: screen[a], to: screen[b], thickness: 1.4, color: visibleColor });
	return ops;
}

function formatSize(box) {
	if (!box) return '';
	const dx = box.max.x - box.min.x, dy = box.max.y - box.min.y, dz = box.max.z - box.min.z;
	return `${dx.toFixed(1)} × ${dy.toFixed(1)} × ${dz.toFixed(1)}`;
}

function ellipsise(text, maxWidth, size) {
	if (three.ui.measure(text, { size })[0] <= maxWidth) return text;
	let out = text;
	while (out.length > 1 && three.ui.measure(out + '…', { size })[0] > maxWidth) out = out.slice(0, -1);
	return out.length > 1 ? out + '…' : out;
}

// A reusable card: one Drawing, one piece, its own hover state. The
// wireframe's screen-space line list, the ellipsised name and the size
// caption are all fixed by the box and the name at construction, so they are
// computed once, here, and kept on the instance — re-rendering it after a
// hover or a stamp change is just the background and text colours changing,
// with `three.ui.measure` (through `ellipsise`) never touched again.
class Card extends three.Widget {
	constructor(name, category, box) {
		super();
		this.name = name;
		this.category = category;
		this.box = box;
		this.hovered = false;
		this.wireOps = box ? wireframeOps(box, [8, 8], THUMB, categoryColor(category), THEME.wireHidden) : [];
		this.displayName = ellipsise(name, CARD_W - 16, 12);
		this.sizeCaption = formatSize(box);
	}

	render() {
		const stamped = ed.stamp === this.name;
		const bg = stamped ? THEME.accent : this.hovered ? THEME.hover : THEME.panel;
		const ops = [
			{ op: 'rect', at: [0, 0], size: [CARD_W, CARD_H], radius: THEME.radius, color: bg, borderColor: THEME.border, borderWidth: 1 },
			...this.wireOps,
			{ op: 'text', at: [8, THUMB + 12], text: this.displayName, size: 12, color: stamped ? [1, 1, 1] : THEME.text },
			{ op: 'text', at: [8, THUMB + 28], text: this.sizeCaption, size: 10, color: stamped ? [0.92, 0.95, 1] : THEME.dim },
		];
		return new Drawing({
			key: this.name, size: [CARD_W, CARD_H], ops,
			onClick: safe(() => ed.setStamp(ed.stamp === this.name ? null : this.name)),
			onHover: entered => { this.hovered = entered; },
		});
	}
}

function kitLabel(path) {
	const parts = path.split('/');
	return parts[parts.length - 1];
}

// The dock's left column: the kit library dropdown and the category list
// that filters the grid.
class Catalog extends three.Widget {
	constructor() {
		super();
		this.kitOptions = [];
		this.kitSelected = -1;
		this.rows = [{ label: 'All', trailing: '0' }];
		this.activeIndex = 0; // index into `rows`; 0 is 'All'
	}

	get activeCategory() {
		return this.activeIndex > 0 && this.rows[this.activeIndex] ? this.rows[this.activeIndex].label : null;
	}

	// Called by `Editor.useAsset` whenever the kit (and so the piece list)
	// changes — recomputes the library options and the category counts,
	// keeping whatever category was active if it still exists.
	refresh() {
		this.kitOptions = three.inventory().filter(e => isKitPath(e.path)).map(e => e.path);
		this.kitSelected = ed.level && ed.level.kit ? this.kitOptions.indexOf(ed.level.kit) : -1;

		const counts = new Map();
		for (const p of ed.pieces) counts.set(p.category, (counts.get(p.category) ?? 0) + 1);
		const names = [...counts.keys()].sort();
		const activeLabel = this.activeCategory;
		this.rows = [
			{ label: 'All', trailing: String(ed.pieces.length) },
			...names.map(name => ({ label: name, trailing: String(counts.get(name)) })),
		];
		this.activeIndex = activeLabel ? Math.max(0, this.rows.findIndex(r => r.label === activeLabel)) : 0;
	}

	render() {
		return new Padding({ insets: 8 },
			new Column({ gap: 10 },
				new Label('Kit', { color: THEME.dim, textSize: 11 }),
				new Select(this.kitOptions.map(kitLabel), this.kitSelected,
					safe(i => ed.requestKitChange(this.kitOptions[i])), { key: 'kitSelect' }),
				new Scroll({ key: 'catalogScroll' },
					new Tree(this.rows, this.activeIndex,
						safe(i => { this.activeIndex = i; browser.update(); }), { key: 'categoryTree' })),
			),
		);
	}
}

// The dock's right column: a search header over a scrolling grid of cards.
class Browser extends three.Widget {
	constructor() {
		super();
		this.search = '';
	}

	// Every piece passing the catalog's category filter and this search text —
	// the grid's contents, and what `editor._tree` reports.
	visible() {
		const q = this.search.trim().toLowerCase();
		const category = catalog.activeCategory;
		return ed.pieces.filter(p => (!category || p.category === category) && (!q || p.name.toLowerCase().includes(q)));
	}

	render() {
		const visible = this.visible();
		const cards = visible.map(p => ed.cards.get(p.name)).filter(Boolean);
		const stampText = ed.stamp ? `stamp: ${ed.stamp} · esc clears` : 'click a piece to stamp it';

		return new Column({},
			new Stack({ size: [0, HEADER_H] },
				new Rect({ color: THEME.header, solid: true }),
				new Anchored({ h: 'start', v: 'center', margin: [10, 0] },
					new Row({ gap: 12, cross: 'center' },
						new TextField({
							key: 'search', text: this.search, placeholder: 'Search', size: [180, 0],
							onChange: safe(t => { this.search = t; }),
						}),
						new Label(`${visible.length} of ${ed.pieces.length}`, { color: THEME.dim, textSize: 12 }),
					),
				),
				new Anchored({ h: 'end', v: 'center', margin: [10, 0] },
					new Label(stampText, { color: ed.stamp ? THEME.accent : THEME.dim, textSize: 12 }),
				),
			),
			new Scroll({ key: 'browserScroll' },
				cards.length > 0
					? new Padding({ insets: 8 }, new Grid({ cell: [CARD_W, CARD_H], gap: 6 }, ...cards))
					: new Padding({ insets: 16 }, new Label('no pieces match', { color: THEME.dim, textSize: 12 }))),
		);
	}
}

// The N-panel-style properties card, top-right under the menu bar.
class Props extends three.Widget {
	constructor() {
		super();
		this.mode = ed.mode;
		this.hasMarker = false;
		this.markerOptions = [];
		this.markerIndex = -1;
		this.hasSelection = false;
		this.count = 0;
		this.id = '';
		this.piece = '';
		this.position = '';
		this.rotation = '';
		this.scale = '';
		this.snap = '';
	}

	// Pulls this frame's numbers off the editor. The animation loop calls this
	// every frame, and a widget only re-renders when a field really changes.
	sync() {
		this.mode = ed.mode;
		this.hasMarker = ed.mode === 'marker' && !!ed.grabbing && ed.markerChoices.length > 0;
		if (this.hasMarker) {
			// A list is always a change when assigned, so compare what it says.
			if (this.markerOptions.join(' ') !== ed.markerChoices.join(' ')) this.markerOptions = ed.markerChoices;
			this.markerIndex = ed.markerChoices.indexOf(ed.markerChoice);
		}

		// The panel reads the ACTIVE piece and says how many others came with
		// it — five sets of numbers in a card this size is a wall of digits
		// nobody reads, and the active one is the piece every verb is aimed at.
		const active = ed.activeId;
		const row = active ? ed.rowOf(active) : null;
		const object = active ? ed.level.objects.get(active) : null;
		this.hasSelection = !!(row && object);
		this.count = ed.selection.length;
		if (!this.hasSelection) return;

		this.id = row.id;
		this.piece = row.piece;
		this.position = positionText(object);
		const turns = Math.round(wrapTurn(object.rotation.y) / (Math.PI / 2)) % 4;
		this.rotation = `${turns} quarter turn${turns === 1 ? '' : 's'}`;
		// Empty for a piece nobody has scaled, which is nearly all of them —
		// a row saying "1, 1, 1" forever is a row nobody reads.
		const s = object.scale;
		this.scale = s.x !== 1 || s.y !== 1 || s.z !== 1
			? `${s.x.toFixed(2)}, ${s.y.toFixed(2)}, ${s.z.toFixed(2)}`
			: '';
		this.snap = row.snap ? `${row.snap.to} ${row.snap.side}` : '(freehand)';
	}

	render() {
		// A Row with no size hugs its content, so `main: 'space-between'` has
		// no slack to spend — the caption instead gets a fixed-size column (a
		// Stack, which has a box size to give it) so the value lands at a
		// consistent indent instead of jammed against it. Both axes are fixed
		// — a zero axis fills whatever it is offered, and inside the Panel's
		// own hug-to-content column that offer is unbounded while the Panel
		// is measuring its own size, which would blow this up to fill it.
		const two = (caption, value) => new Row({ gap: 6 },
			new Stack({ size: [64, 16] }, new Label(caption, { color: THEME.dim, textSize: 11 })),
			new Label(value, { textSize: 12 }),
		);
		const children = [
			new Label('Item', { textSize: 13 }),
			new Row({ gap: 8 },
				new Label('mode', { color: THEME.dim, textSize: 11 }),
				new Select(MODES, MODES.indexOf(this.mode), safe(i => ed.setMode(MODES[i])), { key: 'modeSelect' }),
			),
		];
		if (this.hasMarker) {
			children.push(new Row({ gap: 8 },
				new Label('marker', { color: THEME.dim, textSize: 11 }),
				new Select(this.markerOptions, this.markerIndex,
					safe(i => { ed.markerChoice = this.markerOptions[i]; }), { key: 'markerSelect' }),
			));
		}
		if (!this.hasSelection) {
			children.push(new Label('(no selection)', { color: THEME.dim, textSize: 12 }));
		} else {
			if (this.count > 1) children.push(two('selected', `${this.count} pieces`));
			children.push(
				two(this.count > 1 ? 'active' : 'id', this.id),
				two('piece', this.piece), two('position', this.position),
				two('rotation', this.rotation),
			);
			if (this.scale) children.push(two('scale', this.scale));
			children.push(two('snap', this.snap));
		}
		return new Panel({
			at: 'top-right', margin: [8, BAR_H + 8], width: PROPS_W, gap: 6, insets: 10,
			color: THEME.panel, radius: THEME.radius, borderColor: THEME.border, borderWidth: 1, solid: true,
		}, ...children);
	}
}

// The bottom status strip: the status text on the left, contextual key hints
// on the right.
class StatusBar extends three.Widget {
	constructor() {
		super();
		this.text = '';
		this.hint = '';
	}

	sync() {
		this.text = StatusBar.status();
		this.hint = StatusBar.hint();
	}

	static status() {
		const stats = scene.stats();
		const rows = ed.level.rows.length;
		const extra = ed.selection.length - 1;
		const selected = `${ed.activeId ?? '(none)'}${extra > 0 ? ` +${extra}` : ''}`;
		let text = `${ed.mode} · ${selected} · ${rows} piece${rows === 1 ? '' : 's'}`
			+ ` · ${stats.drawCalls} draws${ed.dirty ? ' · *' : ''}`;
		if (ed.lastError) text += ` · ${ed.lastError}`;
		return text;
	}

	static hint() {
		const { grabbing, scaling } = ed;
		if (grabbing) {
			return grabbing.axis
				? `moving on ${grabbing.axis.toUpperCase()} · click commits · esc frees the axis`
				: 'x / y / z locks an axis · click to commit · esc cancels';
		}
		if (scaling) {
			const factor = `×${scaling.factor.toFixed(2)}`;
			return scaling.axis
				? `scaling ${scaling.axis.toUpperCase()} ${factor} · click commits · esc frees the axis`
				: `scaling ${factor} · x / y / z locks an axis · click commits · esc cancels`;
		}
		if (ed.stamp) return 'ctrl+click to place · +shift freehand · esc clears';
		if (ed.selection.length > 0) return 'g grab · s scale · r rotate · x delete';
		return 'click selects · shift+click adds · ctrl+click places the stamp';
	}

	render() {
		return new Anchored({ h: 'start', v: 'end' },
			new Stack({ size: [0, STATUS_H] },
				new Rect({ color: THEME.header, solid: true }),
				new Anchored({ h: 'start', v: 'center', margin: [10, 0] },
					new Label(this.text, { color: THEME.text, textSize: 12 })),
				new Anchored({ h: 'end', v: 'center', margin: [10, 0] },
					new Label(this.hint, { color: THEME.dim, textSize: 11 })),
			),
		);
	}
}

function menuSpec() {
	return [
		{ title: 'File', items: ['New', 'Open…', 'Save', 'Save as…', 'Export .glb…', '-', 'Quit'] },
		{ title: 'Edit', items: ['Undo', 'Redo', '-', 'Duplicate', 'Delete'] },
		{
			title: 'View',
			items: ['Frame all', 'Toggle grid', 'Refit', '-', { label: 'Asset browser', checked: ed.dockOpen }],
		},
	];
}

// The picked item's own label, rather than its index — so dispatch reads
// against what the menu actually says instead of a position that would
// silently go stale the next time an item is added or reordered.
function menuLabel(menu, item) {
	const spec = menuSpec()[menu];
	const entry = spec && spec.items[item];
	if (entry === undefined || entry === null || entry === '-') return null;
	return typeof entry === 'string' ? entry : entry.label;
}

function onMenuSelect(menu, item) {
	switch (menuLabel(menu, item)) {
		case 'New': ed.requestNew(); break;
		case 'Open…': ed.openDialogOpen = true; ed.sync(); break;
		case 'Save': ed.save(); break;
		case 'Save as…': ed.openSaveAs(); break;
		case 'Export .glb…': ed.openExport(); break;
		case 'Quit': three.quit(); break;
		case 'Undo': ed.undo(); break;
		case 'Redo': ed.redo(); break;
		case 'Duplicate': ed.duplicate(); break;
		case 'Delete': ed.requestRemove(); break;
		case 'Frame all': frameAllExcludingHelpers(); break;
		case 'Toggle grid': ed.toggleGrid(); break;
		case 'Refit': ed.refit(); break;
		case 'Asset browser': ed.toggleDock(); break;
	}
}

// Floor 0: the dock, the properties panel, the status strip and the menu
// bar, in that order — the menu bar LAST, so its open dropdown paints over
// the panels beside it in this same Stack rather than under them.
class Chrome extends three.Widget {
	// How many times it has rendered, for `editor._renderCount()`.
	static renders = 0;

	render() {
		Chrome.renders++;
		return new Stack({},
			ed.dockOpen && new Anchored({ h: 'start', v: 'end', margin: [0, STATUS_H] },
				new Stack({ size: [0, DOCK_H] },
					new Rect({ color: THEME.header, solid: true }),
					new Row({},
						new Stack({ size: [CATALOG_W, 0] },
							new Rect({ color: THEME.panel, solid: true }),
							new Anchored({ h: 'end', v: 'start' }, new Rect({ size: [1, 0], color: THEME.border })),
							catalog,
						),
						browser,
					),
				),
			),
			props,
			statusBar,
			new Anchored({ h: 'start', v: 'start' }, new MenuBar(menuSpec(), safe(onMenuSelect))),
		);
	}
}

// Floor 1: the modal panels, over everything on floor 0.
class Dialogs extends three.Widget {
	static layer = 1;

	render() {
		const close = (flag) => safe(() => { ed[flag] = false; ed.sync(); });
		return new Stack({},
			new ConfirmDialog({
				key: 'deleteConfirm', title: 'Remove piece',
				message: ed.confirmDeleteIds.length === 1
					? `Remove ${ed.confirmDeleteIds[0]}?`
					: `Remove ${ed.confirmDeleteIds.length} pieces?`,
				confirm: 'Remove', decline: 'Keep',
				open: ed.confirmDeleteOpen,
				onConfirm: safe(() => ed.confirmRemove()), onDismiss: safe(() => ed.cancelRemove()),
			}),
			new ConfirmDialog({
				key: 'newConfirm', title: 'Discard changes',
				message: 'This level has unsaved changes — discard them and start a new one?',
				confirm: 'Discard', decline: 'Cancel', open: ed.confirmNewOpen,
				onConfirm: safe(() => ed.confirmNew()),
				onDismiss: safe(() => { ed.confirmNewOpen = false; ed.pendingKit = null; ed.sync(); }),
			}),
			new Dialog({
				key: 'openDialog', title: 'Open level', open: ed.openDialogOpen,
				modal: true, closeOutside: true, size: [360, 320],
				onDismiss: close('openDialogOpen'),
			},
				// A FileBrowser sizes itself to its listing and has no scrollbar
				// of its own — the Scroll is what keeps a long directory inside
				// the panel instead of painting down over the scene.
				new Scroll({ key: 'openScroll' },
					new FileBrowser({ key: 'openBrowser', start: 'levels/', mask: ['*.json'], onChoose: safe(path => { ed.openDialogOpen = false; ed.open(path); }) })),
			),
			new Dialog({
				key: 'kitDialog', title: 'Choose a kit', open: ed.kitDialogOpen,
				modal: true, closeOutside: false, size: [360, 320],
			},
				new Scroll({ key: 'kitScroll' },
					new FileBrowser({ key: 'kitBrowser', mask: ['*.glb', '*.gltf'], onChoose: safe(path => { ed.kitDialogOpen = false; ed.newLevel(path); }) })),
			),
			new Dialog({
				key: 'saveAsDialog', title: 'Save level as', open: ed.saveAsOpen,
				modal: true, closeOutside: true, size: [340, 0],
				onDismiss: close('saveAsOpen'),
			},
				new Column({ gap: 8 },
					new TextField({ key: 'saveAsField', text: ed.saveAsText, onChange: t => { ed.saveAsText = t; } }),
					new Row({ gap: 8 },
						new Button('Cancel', close('saveAsOpen')),
						new Button('Save', safe(() => { ed.saveAsOpen = false; ed.save(ed.saveAsText); })),
					),
				),
			),
			new Dialog({
				key: 'exportDialog', title: 'Export .glb', open: ed.exportOpen,
				modal: true, closeOutside: true, size: [340, 0],
				onDismiss: close('exportOpen'),
			},
				new Column({ gap: 8 },
					new TextField({ key: 'exportField', text: ed.exportText, onChange: t => { ed.exportText = t; } }),
					new Row({ gap: 8 },
						new Button('Cancel', close('exportOpen')),
						new Button('Export', safe(() => { ed.exportOpen = false; ed.exportGlb(ed.exportText); })),
					),
				),
			),
		);
	}
}

// ---------------------------------------------------------------------------
// The keyboard — one method per key, and its description is what
// `three.keys()` and the debug line list.
// ---------------------------------------------------------------------------

class Keys {
	@three.key('1', 'grid snap') @safe static grid() { ed.setMode('grid'); }
	@three.key('2', 'face snap') @safe static face() { ed.setMode('face'); }
	@three.key('3', 'marker snap') @safe static marker() { ed.setMode('marker'); }
	@three.key('g', 'grab the selection, live under the cursor') @safe static grab() { ed.grab(); }
	@three.key('s', 'scale the selection — pull away to grow, in to shrink') @safe static scale() { ed.startScale(); }
	@three.key('r', 'rotate a quarter turn (shift: the other way)') @safe static rotate() { ed.rotate(held('shift') ? -1 : 1); }
	@three.key('f', 'frame the selection') @safe static frame() { ed.frameSelection(); }
	@three.key('home', 'frame everything') @safe static home() { frameAllExcludingHelpers(); }
	@three.key('escape', 'free the axis, then cancel the gesture, then clear the stamp') @safe static escape() { ed.cancel(); }
	@three.key('delete', 'remove, after a confirm') @safe static remove() { ed.requestRemove(); }

	// x / y / z belong to the gesture while one is live, and to what they always
	// did otherwise. The modifier is the tell: a bare press during a gesture is
	// an axis, and a ctrl press is still undo or redo, because those never meant
	// an axis.
	static lockAxis(axis) {
		if (!ed.gesture || held('ctrl')) return false;
		ed.toggleAxis(axis);
		return true;
	}

	@three.key('x', 'remove, after a confirm · mid-gesture: lock to x')
	@safe static x() { if (!Keys.lockAxis('x')) ed.requestRemove(); }

	@three.key('y', 'ctrl: redo · mid-gesture: lock to y')
	@safe static y() { if (!Keys.lockAxis('y') && held('ctrl')) ed.redo(); }

	@three.key('z', 'ctrl: undo, ctrl+shift: redo · mid-gesture: lock to z')
	@safe static z() {
		if (Keys.lockAxis('z') || !held('ctrl')) return;
		if (held('shift')) ed.redo(); else ed.undo();
	}

	@three.key('d', 'shift: duplicate and grab the copies')
	@safe static d() { if (held('shift')) ed.duplicate(); }

	@three.key('arrowleft', 'nudge -x') @safe static left() { ed.nudge(-1, 0, 0); }
	@three.key('arrowright', 'nudge +x') @safe static right() { ed.nudge(1, 0, 0); }
	@three.key('arrowup', 'nudge -z') @safe static up() { ed.nudge(0, 0, -1); }
	@three.key('arrowdown', 'nudge +z') @safe static down() { ed.nudge(0, 0, 1); }
	@three.key('pageup', 'nudge +y') @safe static raise() { ed.nudge(0, 1, 0); }
	@three.key('pagedown', 'nudge -y') @safe static lower() { ed.nudge(0, -1, 0); }
	@three.key('[', 'nudge -y') @safe static lowerBracket() { ed.nudge(0, -1, 0); }
	@three.key(']', 'nudge +y') @safe static raiseBracket() { ed.nudge(0, 1, 0); }
}

// ---------------------------------------------------------------------------
// Boot
// ---------------------------------------------------------------------------

// The editor first: every widget reads it, starting in Props' constructor.
const ed = new Editor();
const catalog = new Catalog();
const browser = new Browser();
const props = new Props();
const statusBar = new StatusBar();
const chrome = new Chrome();
const dialogs = new Dialogs();

ed.boot();
// Make sure the very first frame is already correct rather than waiting for
// the editor's first tick.
props.sync();
statusBar.sync();
chrome.mount();
dialogs.mount();

three.onClick(safe((hit, x, y) => ed.click(hit, x, y)));

// ---------------------------------------------------------------------------
// The drivable surface — everything a key or a widget calls, so the whole
// editor also runs from a script with no pointer at all.
// ---------------------------------------------------------------------------

const editor = {
	// One id, a list of them, or null — the plain click and the whole
	// selection in one verb, so a script says what it means either way.
	select(ids) { ed.select(ids); },
	// What shift+click does: in if it was out, out if it was in.
	toggle(id) { ed.toggle(id); },
	selection() { return [...ed.selection]; },
	setMode(mode) { ed.setMode(mode); },
	stamp(piece) { ed.setStamp(piece); },
	placeAt(x, z, opts = {}) {
		if (!ed.stamp) return null;
		return ed.place(ed.stamp, { x: +x, y: 0, z: +z }, null, { freehand: !!opts.freehand }) ?? null;
	},
	grab() { ed.grab(); },
	// The keyboard's x / y / z during a grab, for a script with no keyboard.
	// Null frees it; anything that is not an axis is ignored rather than
	// silently taken as "free", which would look like the lock never held.
	axis(which) {
		if (which === null || which === undefined) { ed.setAxis(null); return; }
		if (['x', 'y', 'z'].includes(which)) ed.setAxis(which);
	},
	scale(factor) { ed.scaleBy(factor); },
	commit() { ed.commit(); },
	cancel() { ed.cancel(); },
	rotate(dir) { ed.rotate(dir); },
	nudge(dx, dy, dz) { ed.nudge(dx, dy, dz); },
	duplicate() { ed.duplicate(); },
	remove() { ed.requestRemove(); ed.confirmRemove(); },
	undo() { ed.undo(); },
	redo() { ed.redo(); },
	save(path) { return ed.save(path); },
	open(path) { return ed.open(path); },
	newLevel(kit) { return ed.newLevel(kit); },
	state() {
		return {
			path: ed.path,
			// The active piece, and the whole list beside it — a driver that
			// only ever selects one still reads the field it always read.
			selected: ed.activeId,
			selection: [...ed.selection],
			mode: ed.mode,
			axis: ed.gesture?.axis ?? null,
			scaling: ed.scaling ? ed.scaling.factor : null,
			stamp: ed.stamp,
			dirty: ed.dirty,
			rows: JSON.parse(JSON.stringify(ed.level.toJSON().rows)),
		};
	},

	// Internal hooks for the headless test harness — not part of the
	// documented surface above, but how a `--script` driving this file
	// reaches inside it without a pointer or a window.
	_objectOf(id) { return ed.level.objects.get(id) ?? null; },
	_placeByMode(object, groundPoint, pickHit, opts) { return ed.placeByMode(object, groundPoint, pickHit, opts); },
	_level() { return ed.level; },
	_tree() { return browser.visible().map(p => p.name); },
	_renderCount() { return Chrome.renders; },
};
globalThis.editor = editor;

three.debug.write({
	keys: {
		click: 'select one · commit a grab',
		'shift+click': 'add to / take out of the selection',
		'ctrl+click': 'place the stamp',
		...three.keys(),
	},
	state: editor.state(),
});
