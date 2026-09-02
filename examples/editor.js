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
//   click            select · place the stamp · commit a grab
//   1 / 2 / 3        grid / face / marker snap mode
//   g                grab the selection and move it live under the cursor
//   r / shift+r      rotate a quarter turn, the other way with shift
//   arrows           nudge one unit on x/z · pageup/pagedown or [ / ]  y
//   shift+d          duplicate (offset one unit on x) and start a grab
//   delete / x       remove, after a confirm
//   ctrl+z           undo · ctrl+shift+z or ctrl+y   redo
//   escape           cancel a grab, or clear the asset-browser stamp
//   f / home         frame the selection / frame everything
//   shift (held)     while placing or committing: skip the snap, freehand
//
// ## What already exists and is not rebuilt here
//
// The turntable (drag orbit, right-drag pan, wheel zoom) is the host's; this
// script never touches the camera except to aim it, which is why nothing
// below is a drag — every editor interaction is a click or a key, so nothing
// ever fights the turntable for the mouse.
//
// `three.onClick` and `three.input.pointer.clicked` turn out to share one
// `MouseTracker` — both already drop a press that resolves into a camera
// drag (a slop-and-hold test on release, not on press) and both already see
// a blanked cursor while it is over a widget (`Cursor.behind_ui`, applied
// before either one is fed). So there is no click here that needs telling
// apart from a drag by hand. `three.onClick` is used anyway, for the single
// reason it hands back `hit` — the same object `scene.pick` would have cost
// a second BVH walk to ask for.
//
// ## The one thing this script works around
//
// `BoxHelper` must hang from the very parent of the object it outlines, so
// the selection outline cannot live in the same Group the grid does — a
// `Scene.bounds()` (what `frameAll` sees) does not check `visible` either,
// only whether a node is drawable at all, so hiding the grid before framing
// would not shrink the frame; it has to be unparented and reparented. See
// `frameAllExcludingHelpers` and the comment on `helpers` below.
//
// ## The interface is a handful of widget classes
//
// Everything drawn — the dock, the properties panel, the status strip, the
// menu bar, and the confirm/open/kit/save/export dialogs — is `three.Widget`
// classes; `examples/pop.js` is the worked example of the pattern and its
// header comment is worth reading first. `Chrome` is the one floor that owns
// the dock, the properties panel, the status strip and the menu bar — the
// menu bar is its LAST child, so an open dropdown paints over the panels
// beside it rather than under them, which is the layering bug this rewrite
// fixes. `Dialogs` is a second floor (`static layer = 1`) over the top, for
// the modal panels. `Catalog`, `Browser`, `Card`, `Props` and `StatusBar` are
// parts: constructed once, holding their own state, never rebuilt — a field
// write on one marks its owning floor dirty, and only the values that
// actually changed cross to the host.

// ---------------------------------------------------------------------------
// World
// ---------------------------------------------------------------------------

const scene = new three.Scene();
three.light.set([0.4, 0.85, 0.32], 0.35);

// Grid and selection outline both want to sit apart from the level's own
// pieces so a script can tell "the kit" from "the editor's own furniture" at
// a glance — `level.objects` is exactly the first half. Only the grid lives
// here, though: a BoxHelper is refused anywhere but the parent of what it
// outlines, so the selection outline hangs directly off `scene`, beside the
// pieces, and `frameAllExcludingHelpers` only has the grid worth excluding —
// a selection box roughly reads as the piece it wraps anyway.
const helpers = new three.Group();
helpers.name = '__helpers__';
scene.add(helpers);
const gridHelper = new three.GridHelper(40, 40, 0x445566);
helpers.add(gridHelper);
let selectionHelper = null;

function frameAllExcludingHelpers() {
	const parent = helpers.parent;
	if (parent) parent.remove(helpers);
	three.camera.frameAll();
	if (parent) parent.add(helpers);
}

// ---------------------------------------------------------------------------
// Small helpers — geometry and naming, nothing here touches state
// ---------------------------------------------------------------------------

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

// Walks up from whatever `scene.pick` handed back — often a Mesh several
// levels inside a piece — to the row's own root, identified the way
// `Level` identifies it: the object a row's id is the key for.
function pieceOf(object) {
	for (let o = object; o; o = o.parent) {
		if (level.objects.get(o.name) === o) return o;
	}
	return null;
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

function freshId(piece) {
	let n = 1;
	while (level.objects.has(`${piece}_${n}`)) n++;
	return `${piece}_${n}`;
}

// Wraps a key or click handler so one throw reports on the status line
// instead of unbinding the handler for the rest of the run — onKeyDown,
// onClick, a widget handler and the animation loop are all "stopped for
// good if it throws".
function safe(fn) {
	return (...args) => {
		try { fn(...args); } catch (e) { setStatus(String(e && e.message ? e.message : e)); }
	};
}

// ---------------------------------------------------------------------------
// The kit's own node hierarchy — read straight off `asset._rows(false)` (the
// same flattened, parent-indexed table `instantiate()` builds objects from;
// see `js_asset_nodes` in src/js/bind_asset.c3 and `Asset._rows` in
// src/js/prelude/asset.js for the row shape: `[name, parent, mesh, ...]`,
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
		const parent = rows[i][1];
		if (rows[i][2] !== -1) hasMesh[i] = true;
		if (parent >= 0) childCount[parent]++;
		depth[i] = parent >= 0 ? depth[parent] + 1 : 0; // parent < i always
	}
	// Backward: a child (always a larger index than its parent) is seen
	// before its parent's own turn, so one pass propagates "a mesh sits
	// somewhere in this subtree" all the way up to every ancestor.
	for (let i = n - 1; i >= 0; i--) {
		const parent = rows[i][1];
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
		const parent = rows[i][1];
		if (parent < 0) continue;
		if (!childrenOf.has(parent)) childrenOf.set(parent, []);
		childrenOf.get(parent).push(i);
	}
	let candidates = [];
	for (let i = 0; i < rows.length; i++) if (rows[i][1] < 0 && hasMesh[i]) candidates.push(i);
	while (candidates.length === 1 && rows[candidates[0]][2] === -1) {
		const kids = (childrenOf.get(candidates[0]) ?? []).filter(i => hasMesh[i]);
		if (kids.length === 0) break;
		candidates = kids;
	}
	return candidates.map(i => rows[i][0]);
}

// Swaps in a freshly loaded kit and rebuilds the browser's models with it —
// every place `currentAsset` changes goes through this rather than assigning
// it directly, so the asset, the piece list and the catalog never drift
// apart.
function setCurrentAsset(asset) {
	currentAsset = asset;
	assetTree = buildAssetTree(asset);
	const names = buildPieceList(assetTree);
	state.pieces = names.map(name => ({ name, category: categoryOf(name) }));
	const cards = new Map();
	for (const p of state.pieces) {
		let box = null;
		try { box = asset.node(p.name).boundsInParent(); } catch (e) { box = null; }
		cards.set(p.name, new Card(p.name, p.category, box));
	}
	pieceCards = cards;
	if (state.stamp && !pieceCards.has(state.stamp)) state.stamp = null;
	catalog.refresh();
	browser.update();
}

// ---------------------------------------------------------------------------
// Editor state
// ---------------------------------------------------------------------------

const state = {
	mode: three.persist.mode ?? 'grid',
	selected: null,
	stamp: null,
	grab: null,
	path: null,
	dirty: false,
	showGrid: true,
	markerChoice: null,
	markerChoices: [],
	pieces: [],
	pendingKit: null,
	dockOpen: three.persist.dockOpen ?? true,
	confirmDeleteId: null,
	confirmDeleteOpen: false,
	confirmNewOpen: false,
	openDialogOpen: false,
	kitDialogOpen: false,
	saveAsOpen: false,
	saveAsText: '',
	exportOpen: false,
	exportText: '',
	lastError: '',
};

let undoStack = [];
let redoStack = [];
const UNDO_CAP = 100;

let level;                 // the live three.level.Level — reassigned by undo/open/new
let currentAsset = null;   // three.load(level.kit), kept for the asset browser
let assetTree = null;      // buildAssetTree(currentAsset) — the browser's own model
let pieceCards = new Map(); // piece name -> its Card widget, rebuilt with the asset

function setStatus(message) {
	state.lastError = message;
	syncUI();
}

function markDirty() { state.dirty = true; }

function syncPersist() {
	three.persist.path = state.path;
	three.persist.selected = state.selected;
	three.persist.mode = state.mode;
	three.persist.dockOpen = state.dockOpen;
}

// ---------------------------------------------------------------------------
// Undo / redo — snapshots of level.toJSON(), deep-cloned because toJSON()
// hands back the level's own row objects and mutates them in place on every
// future call, which would otherwise corrupt a stored snapshot silently.
// ---------------------------------------------------------------------------

function snapshot() { return JSON.parse(JSON.stringify(level.toJSON())); }

function pushSnapshot(stack, snap) {
	stack.push(snap);
	if (stack.length > UNDO_CAP) stack.shift();
}

function pushUndo() {
	pushSnapshot(undoStack, snapshot());
	redoStack = [];
}

// Rebuilds a Level from a saved snapshot — `load` without the file: drop
// every current object and replay `add(row)` in order over a fresh
// `three.level.create(kit)`.
function restore(snap) {
	for (const obj of [...level.objects.values()]) if (obj.parent) obj.parent.remove(obj);
	const next = three.level.create(snap.kit);
	next.parent = scene;
	for (const row of snap.rows) next.add(row);
	level = next;
	setCurrentAsset(snap.kit ? three.load(snap.kit) : null);
}

function undo() {
	if (undoStack.length === 0) return;
	pushSnapshot(redoStack, snapshot());
	restore(undoStack.pop());
	select(state.selected && level.objects.has(state.selected) ? state.selected : null);
	markDirty();
	syncUI();
}

function redo() {
	if (redoStack.length === 0) return;
	pushSnapshot(undoStack, snapshot());
	restore(redoStack.pop());
	select(state.selected && level.objects.has(state.selected) ? state.selected : null);
	markDirty();
	syncUI();
}

// ---------------------------------------------------------------------------
// Placement — the one rule "what does a cursor mean", shared by a fresh
// stamp, a live grab preview and a grab's final commit.
// ---------------------------------------------------------------------------

function snapAxisToGrid(object, axis) {
	const box = object.boundsInParent();
	if (!box) return;
	object.align(axis, 'min', Math.round(box.edge(axis, 'min')));
}

// Moves `object` (already in the scene, rotation already set) according to
// the current mode, a ground-plane candidate point and an optional pick hit.
// Answers the row's new `snap` (or null for freehand) — it does not touch
// the row itself, so a caller can decide when that write happens.
function placeByMode(object, groundPoint, pickHit, opts = {}) {
	const freehand = !!opts.freehand;
	const mode = opts.mode ?? state.mode;

	if (!freehand && (mode === 'face' || mode === 'marker')) {
		const target = pickHit && pickHit.object ? pieceOf(pickHit.object) : null;
		if (target && target !== object) {
			if (mode === 'marker') {
				const common = commonMarkers(object, target);
				state.markerChoices = common;
				const marker = common.includes(state.markerChoice) ? state.markerChoice : common[0];
				if (marker) {
					state.markerChoice = marker;
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

function overlapsAnother(object) {
	const box = object.boundingBox().expandByScalar(-0.01);
	const hits = three.query.box(box);
	for (const hit of hits) {
		const other = pieceOf(hit);
		if (other && other !== object) return true;
	}
	return false;
}

function syncRowById(id, snap) {
	const row = level.rows.find(r => r.id === id);
	const object = level.objects.get(id);
	if (!row || !object) return;
	row.position = object.position.toArray();
	row.rotation = object.rotation.toArray();
	row.scale = object.scale.toArray();
	if (snap !== undefined) {
		if (snap) row.snap = snap; else delete row.snap;
	}
}

function placeNewPiece(piece, groundPoint, pickHit, opts = {}) {
	if (!currentAsset || !currentAsset.nodes.includes(piece)) {
		setStatus(`no piece named '${piece}' in the current kit`);
		return null;
	}
	// The same "nothing to draw" refusal the browser's own pieces already
	// exclude, kept here too: a stamp set straight through editor.stamp() (a
	// script driving this headlessly, say) never saw that filter.
	if (currentAsset.node(piece).boundsInParent() === null) {
		setStatus(`${piece} has nothing to draw`);
		state.stamp = null;
		syncUI();
		return null;
	}
	pushUndo();
	const id = freshId(piece);
	const row = { id, piece, position: [0, 0, 0], rotation: [0, 0, 0] };
	let object;
	try {
		object = level.add(row);
	} catch (e) {
		undoStack.pop();
		setStatus(String(e.message ?? e));
		return null;
	}
	const snap = placeByMode(object, groundPoint, pickHit, opts);
	syncRowById(id, snap);
	select(id);
	markDirty();
	setStatus(`placed ${id}`);
	return id;
}

// ---------------------------------------------------------------------------
// Selection and the outline that follows it
// ---------------------------------------------------------------------------

function rebuildSelectionHelper() {
	if (selectionHelper && selectionHelper.parent) selectionHelper.parent.remove(selectionHelper);
	selectionHelper = null;
	if (state.selected) {
		const object = level.objects.get(state.selected);
		if (object && object.parent) {
			selectionHelper = new three.BoxHelper(object, 0xffff00);
			object.parent.add(selectionHelper);
		}
	}
}

function select(id) {
	state.selected = id && level.objects.has(id) ? id : null;
	state.markerChoice = null;
	state.markerChoices = [];
	rebuildSelectionHelper();
	syncPersist();
	syncUI();
}

// ---------------------------------------------------------------------------
// Grab — a live preview driven by the cursor every frame, committed or
// cancelled on a click / escape.
// ---------------------------------------------------------------------------

function grab() {
	if (!state.selected || state.grab) return;
	const object = level.objects.get(state.selected);
	if (!object) return;
	const row = level.rows.find(r => r.id === state.selected);
	state.grab = {
		id: state.selected,
		original: { position: object.position.toArray(), rotation: object.rotation.toArray() },
		originalSnap: row && row.snap ? { ...row.snap } : null,
		before: snapshot(),
		lastSnap: row ? (row.snap ?? null) : null,
	};
}

function updateGrabPreview() {
	if (!state.grab) return;
	const object = level.objects.get(state.grab.id);
	if (!object) { state.grab = null; return; }
	const pointer = three.input.pointer;
	const groundPoint = groundHit(pointer.x, pointer.y, object.position.y);
	const hit = scene.pick(pointer.x, pointer.y);
	if (groundPoint) {
		state.grab.lastSnap = placeByMode(object, groundPoint, hit, { freehand: three.input.isDown('shift') });
	}
	if (selectionHelper) {
		selectionHelper.update();
		selectionHelper.color = overlapsAnother(object) ? 0xff3333 : 0xffff00;
	}
}

function commit() {
	if (!state.grab) return;
	updateGrabPreview();
	const { id, before } = state.grab;
	syncRowById(id, state.grab.lastSnap ?? null);
	pushSnapshot(undoStack, before);
	redoStack = [];
	state.grab = null;
	select(id);
	markDirty();
}

function cancelGrab() {
	const object = level.objects.get(state.grab.id);
	if (object) {
		const orig = state.grab.original;
		object.position.set(orig.position[0], orig.position[1], orig.position[2]);
		object.rotation.set(orig.rotation[0], orig.rotation[1], orig.rotation[2]);
		syncRowById(state.grab.id, state.grab.originalSnap);
	}
	state.grab = null;
	select(state.selected);
}

function cancel() {
	if (state.grab) cancelGrab();
	else if (state.stamp) state.stamp = null;
	syncUI();
}

// ---------------------------------------------------------------------------
// Rotate, nudge, duplicate, delete
// ---------------------------------------------------------------------------

function rotate(dir) {
	if (!state.selected) return;
	const object = level.objects.get(state.selected);
	if (!object) return;
	if (!state.grab) pushUndo();
	object.rotation.y = wrapTurn(object.rotation.y + dir * Math.PI / 2);
	if (!state.grab) {
		syncRowById(state.selected);
		markDirty();
	}
	if (selectionHelper) selectionHelper.update();
	syncUI();
}

function nudge(dx, dy, dz) {
	if (!state.selected || state.grab) return;
	const object = level.objects.get(state.selected);
	if (!object) return;
	pushUndo();
	object.position.set(object.position.x + dx, object.position.y + dy, object.position.z + dz);
	syncRowById(state.selected);
	if (selectionHelper) selectionHelper.update();
	markDirty();
	syncUI();
}

function duplicate() {
	if (!state.selected || state.grab) return;
	const src = level.rows.find(r => r.id === state.selected);
	const object = level.objects.get(state.selected);
	if (!src || !object) return;
	pushUndo();
	const id = freshId(src.piece);
	const row = {
		id,
		piece: src.piece,
		position: [object.position.x + 1, object.position.y, object.position.z],
		rotation: object.rotation.toArray(),
	};
	level.add(row);
	select(id);
	state.grab = {
		id,
		original: { position: row.position.slice(), rotation: row.rotation.slice() },
		originalSnap: null,
		before: snapshot(),
		lastSnap: null,
	};
	markDirty();
}

function requestRemove() {
	if (!state.selected) return;
	state.confirmDeleteId = state.selected;
	state.confirmDeleteOpen = true;
	syncUI();
}

function confirmRemove() {
	const id = state.confirmDeleteId;
	state.confirmDeleteId = null;
	state.confirmDeleteOpen = false;
	if (!id || !level.objects.has(id)) { syncUI(); return; }
	const blocking = level.rows.find(r => r.snap && r.snap.to === id);
	if (blocking) {
		setStatus(`cannot remove ${id} — ${blocking.id} snaps to it`);
		return;
	}
	pushUndo();
	level.remove(id);
	if (state.selected === id) select(null);
	markDirty();
	setStatus(`removed ${id}`);
}

function cancelRemove() {
	state.confirmDeleteId = null;
	state.confirmDeleteOpen = false;
	syncUI();
}

// ---------------------------------------------------------------------------
// Files
// ---------------------------------------------------------------------------

function doSave(path) {
	// `three.level.save` answers the full filesystem path it actually wrote
	// to, for a log or a status line — not what `state.path` wants, which
	// has to stay assets-relative so a later save, `three.level.load` and
	// `three.persist.path` all keep meaning the same file.
	const target = path ?? state.path ?? 'levels/level.json';
	three.level.save(target, level);
	state.path = target;
	state.dirty = false;
	syncPersist();
	syncUI();
	return state.path;
}

function doOpen(path) {
	for (const obj of [...level.objects.values()]) if (obj.parent) obj.parent.remove(obj);
	const next = three.level.load(path, scene);
	if (!next) {
		setStatus(`no level at ${path}`);
		return null;
	}
	level = next;
	setCurrentAsset(level.kit ? three.load(level.kit) : null);
	state.path = path;
	state.dirty = false;
	undoStack = [];
	redoStack = [];
	select(null);
	syncPersist();
	frameAllExcludingHelpers();
	syncUI();
	return level;
}

function doNewLevel(kit) {
	if (level) for (const obj of [...level.objects.values()]) if (obj.parent) obj.parent.remove(obj);
	const next = three.level.create(kit);
	next.parent = scene;
	level = next;
	setCurrentAsset(kit ? three.load(kit) : null);
	state.path = null;
	state.dirty = false;
	// A kit is now chosen, so whatever asked for one closes — the dialog's
	// own onChoose already does this before calling in on the normal path,
	// but `editor.newLevel()` (a script driving this headlessly, with no
	// dialog to click through) is a second way in that needs it done here.
	state.kitDialogOpen = false;
	undoStack = [];
	redoStack = [];
	select(null);
	syncPersist();
	syncUI();
	return level;
}

function requestNew() {
	state.pendingKit = null;
	if (state.dirty) { state.confirmNewOpen = true; syncUI(); }
	else { state.kitDialogOpen = true; syncUI(); }
}

// Picking a different kit straight off the catalog's library dropdown runs
// the same discard flow as File > New, just already knowing which kit it is
// headed for — `state.pendingKit` is what the confirm dialog's onConfirm
// reads instead of falling back to the file browser.
function requestKitChange(path) {
	if (!path || (level && level.kit === path)) return;
	if (state.dirty) { state.pendingKit = path; state.confirmNewOpen = true; syncUI(); }
	else { doNewLevel(path); }
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
		const stamped = state.stamp === this.name;
		const bg = stamped ? THEME.accent : this.hovered ? THEME.hover : THEME.panel;
		const ops = [
			{ op: 'rect', at: [0, 0], size: [CARD_W, CARD_H], radius: THEME.radius, color: bg, borderColor: THEME.border, borderWidth: 1 },
			...this.wireOps,
			{ op: 'text', at: [8, THUMB + 12], text: this.displayName, size: 12, color: stamped ? [1, 1, 1] : THEME.text },
			{ op: 'text', at: [8, THUMB + 28], text: this.sizeCaption, size: 10, color: stamped ? [0.92, 0.95, 1] : THEME.dim },
		];
		return new Drawing({
			key: this.name, size: [CARD_W, CARD_H], ops,
			onClick: safe(() => editor.stamp(state.stamp === this.name ? null : this.name)),
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

	// Called by setCurrentAsset() whenever the kit (and so the piece list)
	// changes — recomputes the library options and the category counts,
	// keeping whatever category was active if it still exists.
	refresh() {
		this.kitOptions = three.inventory().filter(e => /\.glb$|\.gltf$/i.test(e.path)).map(e => e.path);
		this.kitSelected = level && level.kit ? this.kitOptions.indexOf(level.kit) : -1;

		const counts = new Map();
		for (const p of state.pieces) counts.set(p.category, (counts.get(p.category) ?? 0) + 1);
		const names = [...counts.keys()].sort();
		const activeLabel = this.activeIndex > 0 && this.rows[this.activeIndex] ? this.rows[this.activeIndex].label : null;
		this.rows = [
			{ label: 'All', trailing: String(state.pieces.length) },
			...names.map(name => ({ label: name, trailing: String(counts.get(name)) })),
		];
		this.activeIndex = activeLabel ? Math.max(0, this.rows.findIndex(r => r.label === activeLabel)) : 0;
	}

	render() {
		return new Padding({ insets: 8 },
			new Column({ gap: 10 },
				new Label('Kit', { color: THEME.dim, textSize: 11 }),
				new Select(this.kitOptions.map(kitLabel), this.kitSelected,
					safe(i => requestKitChange(this.kitOptions[i])), { key: 'kitSelect' }),
				new Scroll({ key: 'catalogScroll' },
					new Tree(this.rows, this.activeIndex,
						safe(i => { this.activeIndex = i; browser.update(); }), { key: 'categoryTree' })),
			),
		);
	}
}

// Every piece currently passing the catalog's category filter and the
// browser's own search text — the grid's contents, and what `editor._tree`
// reports.
function visiblePieces() {
	const q = browser.search.trim().toLowerCase();
	const category = catalog.activeCategory;
	return state.pieces.filter(p => (!category || p.category === category) && (!q || p.name.toLowerCase().includes(q)));
}

// The dock's right column: a search header over a scrolling grid of cards.
class Browser extends three.Widget {
	constructor() {
		super();
		this.search = '';
	}

	render() {
		const visible = visiblePieces();
		const cards = visible.map(p => pieceCards.get(p.name)).filter(Boolean);
		const stampText = state.stamp ? `stamp: ${state.stamp} · esc clears` : 'click a piece to stamp it';

		return new Column({},
			new Stack({ size: [0, HEADER_H] },
				new Rect({ color: THEME.header, solid: true }),
				new Anchored({ h: 'start', v: 'center', margin: [10, 0] },
					new Row({ gap: 12, cross: 'center' },
						new TextField({
							key: 'search', text: this.search, placeholder: 'Search', size: [180, 0],
							onChange: safe(t => { this.search = t; }),
						}),
						new Label(`${visible.length} of ${state.pieces.length}`, { color: THEME.dim, textSize: 12 }),
					),
				),
				new Anchored({ h: 'end', v: 'center', margin: [10, 0] },
					new Label(stampText, { color: state.stamp ? THEME.accent : THEME.dim, textSize: 12 }),
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
		this.mode = state.mode;
		this.hasMarker = false;
		this.markerOptions = [];
		this.markerIndex = -1;
		this.hasSelection = false;
		this.id = '';
		this.piece = '';
		this.position = '';
		this.rotation = '';
		this.snap = '';
	}

	// Pulls this frame's numbers off `state`/`level` and writes only the
	// fields that actually changed — the animation loop calls this every
	// frame, so an unchanged value must not touch the proxy.
	sync() {
		if (this.mode !== state.mode) this.mode = state.mode;

		const showMarker = state.mode === 'marker' && !!state.grab && state.markerChoices.length > 0;
		if (this.hasMarker !== showMarker) this.hasMarker = showMarker;
		if (showMarker) {
			if (this.markerOptions.join(' ') !== state.markerChoices.join(' ')) this.markerOptions = state.markerChoices;
			const idx = state.markerChoices.indexOf(state.markerChoice);
			if (this.markerIndex !== idx) this.markerIndex = idx;
		}

		const row = state.selected ? level.rows.find(r => r.id === state.selected) : null;
		const object = state.selected ? level.objects.get(state.selected) : null;
		const has = !!(row && object);
		if (this.hasSelection !== has) this.hasSelection = has;
		if (!has) return;

		if (this.id !== row.id) this.id = row.id;
		if (this.piece !== row.piece) this.piece = row.piece;
		const pos = positionText(object);
		if (this.position !== pos) this.position = pos;
		const turns = Math.round(wrapTurn(object.rotation.y) / (Math.PI / 2)) % 4;
		const rot = `${turns} quarter turn${turns === 1 ? '' : 's'}`;
		if (this.rotation !== rot) this.rotation = rot;
		const snap = row.snap ? `${row.snap.to} ${row.snap.side}` : '(freehand)';
		if (this.snap !== snap) this.snap = snap;
	}

	render() {
		const modes = ['grid', 'face', 'marker'];
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
				new Select(modes, modes.indexOf(this.mode), safe(i => editor.setMode(modes[i])), { key: 'modeSelect' }),
			),
		];
		if (this.hasMarker) {
			children.push(new Row({ gap: 8 },
				new Label('marker', { color: THEME.dim, textSize: 11 }),
				new Select(this.markerOptions, this.markerIndex,
					safe(i => { state.markerChoice = this.markerOptions[i]; }), { key: 'markerSelect' }),
			));
		}
		if (!this.hasSelection) {
			children.push(new Label('(no selection)', { color: THEME.dim, textSize: 12 }));
		} else {
			children.push(
				two('id', this.id), two('piece', this.piece), two('position', this.position),
				two('rotation', this.rotation), two('snap', this.snap),
			);
		}
		return new Panel({
			at: 'top-right', margin: [8, BAR_H + 8], width: PROPS_W, gap: 6, insets: 10,
			color: THEME.panel, radius: THEME.radius, borderColor: THEME.border, borderWidth: 1, solid: true,
		}, ...children);
	}
}

function hintText() {
	if (state.grab) return 'click to commit · esc cancels';
	if (state.stamp) return 'click to place · shift freehand · esc clears';
	if (state.selected) return 'g grab · r rotate · x delete';
	return '';
}

// The bottom status strip: the existing status text on the left, contextual
// key hints on the right.
class StatusBar extends three.Widget {
	constructor() {
		super();
		this.text = '';
		this.hint = '';
	}

	sync() {
		const t = statusText();
		if (this.text !== t) this.text = t;
		const h = hintText();
		if (this.hint !== h) this.hint = h;
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
			items: ['Frame all', 'Toggle grid', 'Refit', '-', { label: 'Asset browser', checked: state.dockOpen }],
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

function toggleDock() {
	state.dockOpen = !state.dockOpen;
	syncUI();
}

function onMenuSelect(menu, item) {
	switch (menuLabel(menu, item)) {
		case 'New': requestNew(); break;
		case 'Open…': state.openDialogOpen = true; syncUI(); break;
		case 'Save': doSave(); break;
		case 'Save as…': state.saveAsText = state.path ?? 'levels/level.json'; state.saveAsOpen = true; syncUI(); break;
		case 'Export .glb…': state.exportText = 'levels/level.glb'; state.exportOpen = true; syncUI(); break;
		case 'Quit': three.quit(); break;
		case 'Undo': undo(); break;
		case 'Redo': redo(); break;
		case 'Duplicate': duplicate(); break;
		case 'Delete': requestRemove(); break;
		case 'Frame all': frameAllExcludingHelpers(); break;
		case 'Toggle grid': state.showGrid = !state.showGrid; gridHelper.visible = state.showGrid; break;
		case 'Refit': pushUndo(); level.refit(); markDirty(); syncUI(); break;
		case 'Asset browser': toggleDock(); break;
	}
}

let chromeRenderCount = 0;

// Floor 0: the dock, the properties panel, the status strip and the menu
// bar, in that order — the menu bar LAST, so its open dropdown paints over
// the panels beside it in this same Stack rather than under them.
class Chrome extends three.Widget {
	render() {
		chromeRenderCount++;
		return new Stack({},
			state.dockOpen && new Anchored({ h: 'start', v: 'end', margin: [0, STATUS_H] },
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
		return new Stack({},
			new ConfirmDialog({
				key: 'deleteConfirm', title: 'Remove piece',
				message: `Remove ${state.confirmDeleteId ?? ''}?`, confirm: 'Remove', decline: 'Keep',
				open: state.confirmDeleteOpen, onConfirm: safe(confirmRemove), onDismiss: safe(cancelRemove),
			}),
			new ConfirmDialog({
				key: 'newConfirm', title: 'Discard changes',
				message: 'This level has unsaved changes — discard them and start a new one?',
				confirm: 'Discard', decline: 'Cancel', open: state.confirmNewOpen,
				onConfirm: safe(() => {
					state.confirmNewOpen = false;
					if (state.pendingKit) { const kit = state.pendingKit; state.pendingKit = null; doNewLevel(kit); }
					else state.kitDialogOpen = true;
					syncUI();
				}),
				onDismiss: safe(() => { state.confirmNewOpen = false; state.pendingKit = null; syncUI(); }),
			}),
			new Dialog({
				key: 'openDialog', title: 'Open level', open: state.openDialogOpen,
				modal: true, closeOutside: true, size: [360, 320],
				onDismiss: safe(() => { state.openDialogOpen = false; syncUI(); }),
			},
				// A FileBrowser sizes itself to its listing and has no scrollbar
				// of its own — the Scroll is what keeps a long directory inside
				// the panel instead of painting down over the scene.
				new Scroll({ key: 'openScroll' },
					new FileBrowser({ key: 'openBrowser', start: 'levels/', mask: ['*.json'], onChoose: safe(path => { state.openDialogOpen = false; doOpen(path); }) })),
			),
			new Dialog({
				key: 'kitDialog', title: 'Choose a kit', open: state.kitDialogOpen,
				modal: true, closeOutside: false, size: [360, 320],
			},
				new Scroll({ key: 'kitScroll' },
					new FileBrowser({ key: 'kitBrowser', mask: ['*.glb', '*.gltf'], onChoose: safe(path => { state.kitDialogOpen = false; doNewLevel(path); }) })),
			),
			new Dialog({
				key: 'saveAsDialog', title: 'Save level as', open: state.saveAsOpen,
				modal: true, closeOutside: true, size: [340, 0],
				onDismiss: safe(() => { state.saveAsOpen = false; syncUI(); }),
			},
				new Column({ gap: 8 },
					new TextField({ key: 'saveAsField', text: state.saveAsText, onChange: t => { state.saveAsText = t; } }),
					new Row({ gap: 8 },
						new Button('Cancel', safe(() => { state.saveAsOpen = false; syncUI(); })),
						new Button('Save', safe(() => { state.saveAsOpen = false; doSave(state.saveAsText); })),
					),
				),
			),
			new Dialog({
				key: 'exportDialog', title: 'Export .glb', open: state.exportOpen,
				modal: true, closeOutside: true, size: [340, 0],
				onDismiss: safe(() => { state.exportOpen = false; syncUI(); }),
			},
				new Column({ gap: 8 },
					new TextField({ key: 'exportField', text: state.exportText, onChange: t => { state.exportText = t; } }),
					new Row({ gap: 8 },
						new Button('Cancel', safe(() => { state.exportOpen = false; syncUI(); })),
						new Button('Export', safe(() => {
							state.exportOpen = false;
							const parent = helpers.parent;
							if (parent) parent.remove(helpers);
							try {
								const result = scene.export(state.exportText || 'levels/level.glb');
								setStatus(`exported ${result.path}`);
							} finally {
								if (parent) parent.add(helpers);
							}
						})),
					),
				),
			),
		);
	}
}

function positionText(object) {
	return `${object.position.x.toFixed(2)}, ${object.position.y.toFixed(2)}, ${object.position.z.toFixed(2)}`;
}

function statusText() {
	const stats = scene.stats();
	let text = `${state.mode} · ${state.selected ?? '(none)'} · ${level.rows.length} piece${level.rows.length === 1 ? '' : 's'}`
		+ ` · ${stats.drawCalls} draws${state.dirty ? ' · *' : ''}`;
	if (state.lastError) text += ` · ${state.lastError}`;
	return text;
}

const catalog = new Catalog();
const browser = new Browser();
const props = new Props();
const statusBar = new StatusBar();
const chrome = new Chrome();
const dialogs = new Dialogs();

// The `three.ui.set`/`patch` era's one entry point, kept as the seam every
// action handler still writes through: it re-syncs the parts that cache
// their own text (so the very next flush is already correct, not one frame
// stale) and marks both floors dirty so whatever structural state changed
// — a dialog opening, a filter, a new kit — is picked up too.
function syncUI() {
	props.sync();
	statusBar.sync();
	chrome.update();
	dialogs.update();
	syncPersist();
}

// ---------------------------------------------------------------------------
// Boot — three.persist.path, or the assets directory's one .glb, or a
// prompt through the kit file browser.
// ---------------------------------------------------------------------------

function boot() {
	const bootPath = three.persist.path ?? 'levels/level.json';
	const loaded = three.level.load(bootPath, scene);
	if (loaded) {
		level = loaded;
		state.path = bootPath;
		setCurrentAsset(level.kit ? three.load(level.kit) : null);
	} else {
		const glbs = three.inventory().filter(e => /\.glb$|\.gltf$/i.test(e.path));
		if (glbs.length === 1) {
			level = three.level.create(glbs[0].path);
			level.parent = scene;
			setCurrentAsset(three.load(glbs[0].path));
		} else {
			level = three.level.create(null);
			level.parent = scene;
			state.kitDialogOpen = true;
		}
	}
	if (three.persist.selected) select(three.persist.selected);
	frameAllExcludingHelpers();
}

boot();
// Make sure the very first frame is already correct rather than waiting for
// the animation loop's first tick.
props.sync();
statusBar.sync();
chrome.mount();
dialogs.mount();

// ---------------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------------

three.onClick(safe((hit, x, y) => {
	if (state.grab) { commit(); return; }
	if (state.stamp) {
		const groundPoint = groundHit(x, y, 0);
		if (!groundPoint) { setStatus('nothing to place on'); return; }
		placeNewPiece(state.stamp, groundPoint, hit, { freehand: three.input.isDown('shift') });
		return;
	}
	const piece = hit && hit.object ? pieceOf(hit.object) : null;
	select(piece ? piece.name : null);
}));

three.onKeyDown('1', safe(() => editor.setMode('grid')));
three.onKeyDown('2', safe(() => editor.setMode('face')));
three.onKeyDown('3', safe(() => editor.setMode('marker')));
three.onKeyDown('g', safe(() => grab()));
three.onKeyDown('r', safe(() => rotate(three.input.isDown('shift') ? -1 : 1)));
three.onKeyDown('f', safe(() => {
	if (!state.selected) return;
	const object = level.objects.get(state.selected);
	if (!object) return;
	const box = object.boundingBox();
	three.camera.lookAt(box.center.x, box.center.y, box.center.z);
}));
three.onKeyDown('home', safe(() => frameAllExcludingHelpers()));
three.onKeyDown('escape', safe(() => cancel()));
three.onKeyDown('delete', safe(() => requestRemove()));
three.onKeyDown('x', safe(() => requestRemove()));
three.onKeyDown('d', safe(() => { if (three.input.isDown('shift')) duplicate(); }));
three.onKeyDown('z', safe(() => {
	if (!three.input.isDown('ctrl')) return;
	if (three.input.isDown('shift')) redo(); else undo();
}));
three.onKeyDown('y', safe(() => { if (three.input.isDown('ctrl')) redo(); }));
three.onKeyDown('arrowleft', safe(() => nudge(-1, 0, 0)));
three.onKeyDown('arrowright', safe(() => nudge(1, 0, 0)));
three.onKeyDown('arrowup', safe(() => nudge(0, 0, -1)));
three.onKeyDown('arrowdown', safe(() => nudge(0, 0, 1)));
three.onKeyDown('pageup', safe(() => nudge(0, 1, 0)));
three.onKeyDown('pagedown', safe(() => nudge(0, -1, 0)));
three.onKeyDown('[', safe(() => nudge(0, -1, 0)));
three.onKeyDown(']', safe(() => nudge(0, 1, 0)));

three.setAnimationLoop(safe(() => {
	if (state.grab) updateGrabPreview();
	statusBar.sync();
	props.sync();
}));

// ---------------------------------------------------------------------------
// The drivable surface — everything a key or a widget calls, so the whole
// editor also runs from a script with no pointer at all.
// ---------------------------------------------------------------------------

const editor = {
	select(id) { select(id); },
	setMode(mode) {
		if (!['grid', 'face', 'marker'].includes(mode)) return;
		state.mode = mode;
		syncUI();
	},
	stamp(piece) { state.stamp = piece; syncUI(); },
	placeAt(x, z, opts = {}) {
		if (!state.stamp) return null;
		return placeNewPiece(state.stamp, { x: +x, y: 0, z: +z }, null, { freehand: !!opts.freehand });
	},
	grab() { grab(); },
	commit() { commit(); },
	cancel() { cancel(); },
	rotate(dir) { rotate(dir); },
	nudge(dx, dy, dz) { nudge(dx, dy, dz); },
	duplicate() { duplicate(); },
	remove() { requestRemove(); confirmRemove(); },
	undo() { undo(); },
	redo() { redo(); },
	save(path) { return doSave(path); },
	open(path) { return doOpen(path); },
	newLevel(kit) { return doNewLevel(kit); },
	state() {
		return {
			path: state.path,
			selected: state.selected,
			mode: state.mode,
			stamp: state.stamp,
			dirty: state.dirty,
			rows: JSON.parse(JSON.stringify(level.toJSON().rows)),
		};
	},

	// Internal hooks for the headless test harness — not part of the
	// documented surface above, but how a `--script` driving this file
	// reaches inside it without a pointer or a window.
	_objectOf(id) { return level.objects.get(id) ?? null; },
	_placeByMode(object, groundPoint, pickHit, opts) { return placeByMode(object, groundPoint, pickHit, opts); },
	_level() { return level; },
	_tree() { return visiblePieces().map(p => p.name); },
	_renderCount() { return chromeRenderCount; },
};
globalThis.editor = editor;

three.debug.write({
	keys: {
		click: 'select · place the stamp · commit a grab',
		'1/2/3': 'grid / face / marker mode',
		g: 'grab', 'r': 'rotate (shift: the other way)',
		delete: 'remove', 'shift+d': 'duplicate',
		'ctrl+z': 'undo', 'ctrl+shift+z / ctrl+y': 'redo',
		escape: 'cancel a grab / clear the stamp',
		f: 'frame selection', home: 'frame all',
	},
	state: editor.state(),
});
