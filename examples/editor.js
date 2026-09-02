// editor.js — a kit editor: select, move, rotate, delete, duplicate, undo,
// an asset browser over a kit's own node hierarchy, and placing with three
// snaps in the order they earn their place — grid, face, marker.
//
// The browser is a `tree` of every named node in the kit's file, exactly as
// authored — root empties, cameras and markers included, nested under their
// real parents rather than flattened to "top-level pieces". A kit that
// wraps its walls and roofs in one outer "root" (as an exported Blender
// scene usually does) still opens straight onto them: the first level
// starts expanded, so `root` is one click from `wall_stone`.
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

// The kit's own node hierarchy, for the asset browser — read straight off
// `asset._rows(false)` (the same flattened, parent-indexed table
// `instantiate()` builds objects from; see `js_asset_nodes` in
// src/js/bind_asset.c3 and `Asset._rows` in src/js/prelude/asset.js for the
// row shape: `[name, parent, mesh, ...]`, parents always before children).
// This needs no heuristic for a kit that wraps its pieces in an extra
// "root" empty beside `camera`/`sun` siblings (real kits do) — the parent
// index already says where every node sits.
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

// Depth-0 rows open by default — enough for a `root`-wrapped kit to show its
// pieces right away — everything deeper starts collapsed.
function resetTreeExpansion(tree) {
	const expanded = new Set();
	if (tree) for (let i = 0; i < tree.rows.length; i++) if (tree.depth[i] === 0) expanded.add(i);
	return expanded;
}

// The tree widget's own rule: "nothing is hidden by `expanded`; it only
// points the disclosure mark" — cui draws whatever `rows` it is handed, so
// which rows are visible (an ancestor collapsed or not) is this script's
// job, recomputed against `state.treeExpanded` on every `syncUI()`.
// Answers the widget's own `rows` plus a parallel array back to the raw
// table, since `onSelect`/`onToggle` hand back an index into what was sent.
function visibleTreeRows() {
	if (!assetTree) return { widgetRows: [], indices: [] };
	const { rows, depth, childCount } = assetTree;
	const widgetRows = [];
	const indices = [];
	const visible = new Array(rows.length).fill(false);
	for (let i = 0; i < rows.length; i++) {
		const parent = rows[i][1];
		visible[i] = parent < 0 || (visible[parent] && state.treeExpanded.has(parent));
		if (!visible[i]) continue;
		widgetRows.push({
			label: rows[i][0],
			depth: depth[i],
			expandable: childCount[i] > 0,
			expanded: state.treeExpanded.has(i),
		});
		indices.push(i);
	}
	return { widgetRows, indices };
}

function onTreeToggle(rawIndex) {
	if (state.treeExpanded.has(rawIndex)) state.treeExpanded.delete(rawIndex);
	else state.treeExpanded.add(rawIndex);
	syncUI();
}

// A node whose subtree draws nothing (an empty like `camera`, a marker) is
// not a piece — say so on the status line and clear the stamp instead of
// letting a later `align()` throw on a box that does not exist. Two named
// nodes can share a name in a file; stamping is by name either way and
// `asset.node(name)` picks the first one the loader walked, same as always.
function onTreeSelect(rawIndex) {
	const name = assetTree.rows[rawIndex][0];
	if (!assetTree.hasMesh[rawIndex]) {
		setStatus(`${name} has nothing to draw`);
		state.stamp = null;
		syncUI();
		return;
	}
	editor.stamp(name);
}

// Swaps in a freshly loaded kit and rebuilds the browser's tree model with
// it — every place `currentAsset` changes goes through this rather than
// assigning it directly, so the two never drift apart.
function setCurrentAsset(asset) {
	currentAsset = asset;
	assetTree = buildAssetTree(asset);
	state.treeExpanded = resetTreeExpansion(assetTree);
}

// Wraps a key or click handler so one throw reports on the status line
// instead of unbinding the handler for the rest of the run — onKeyDown,
// onClick and the animation loop are all "stopped for good if it throws".
function safe(fn) {
	return (...args) => {
		try { fn(...args); } catch (e) { setStatus(String(e && e.message ? e.message : e)); }
	};
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
	treeExpanded: new Set(),
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

let level;          // the live three.level.Level — reassigned by undo/open/new
let currentAsset = null;   // three.load(level.kit), kept for the asset browser
let assetTree = null;      // buildAssetTree(currentAsset) — the browser's own model

function setStatus(message) {
	state.lastError = message;
	syncUI();
}

function markDirty() { state.dirty = true; }

function syncPersist() {
	three.persist.path = state.path;
	three.persist.selected = state.selected;
	three.persist.mode = state.mode;
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
	// The same "nothing to draw" refusal the tree's onSelect makes, kept
	// here too: a stamp set straight through editor.stamp() (a script
	// driving this headlessly, say) never saw that check.
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
	undoStack = [];
	redoStack = [];
	select(null);
	syncPersist();
	syncUI();
	return level;
}

function requestNew() {
	if (state.dirty) { state.confirmNewOpen = true; syncUI(); }
	else { state.kitDialogOpen = true; syncUI(); }
}

// ---------------------------------------------------------------------------
// Boot — three.persist.path, or the assets directory's one .glb, or a
// prompt through the kit file browser.
// ---------------------------------------------------------------------------

(function boot() {
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
})();

// ---------------------------------------------------------------------------
// The interface
// ---------------------------------------------------------------------------

function menuSpec() {
	return [
		{ title: 'File', items: ['New', 'Open…', 'Save', 'Save as…', 'Export .glb…', '-', 'Quit'] },
		{ title: 'Edit', items: ['Undo', 'Redo', '-', 'Duplicate', 'Delete'] },
		{ title: 'View', items: ['Frame all', 'Toggle grid', 'Refit'] },
	];
}

function onMenuSelect(menu, item) {
	if (menu === 0) {
		if (item === 0) requestNew();
		else if (item === 1) { state.openDialogOpen = true; syncUI(); }
		else if (item === 2) doSave();
		else if (item === 3) { state.saveAsText = state.path ?? 'levels/level.json'; state.saveAsOpen = true; syncUI(); }
		else if (item === 4) { state.exportText = 'levels/level.glb'; state.exportOpen = true; syncUI(); }
		else if (item === 6) three.quit();
	} else if (menu === 1) {
		if (item === 0) undo();
		else if (item === 1) redo();
		else if (item === 3) duplicate();
		else if (item === 4) requestRemove();
	} else if (menu === 2) {
		if (item === 0) frameAllExcludingHelpers();
		else if (item === 1) { state.showGrid = !state.showGrid; gridHelper.visible = state.showGrid; }
		else if (item === 2) { pushUndo(); level.refit(); markDirty(); syncUI(); }
	}
}

function assetPanelChildren() {
	const { widgetRows, indices } = visibleTreeRows();
	const selectedWidgetIdx = state.stamp ? widgetRows.findIndex(r => r.label === state.stamp) : -1;
	return [
		{ type: 'label', text: currentAsset ? currentAsset.path : '(no kit)' },
		{
			type: 'tree', key: 'pieceTree',
			rows: widgetRows,
			selected: selectedWidgetIdx,
			onSelect: safe(i => onTreeSelect(indices[i])),
			onToggle: safe(i => onTreeToggle(indices[i])),
		},
		{ type: 'label', text: state.stamp ? `stamp: ${state.stamp} (esc to clear)` : 'pick a piece to place it' },
	];
}

function propsPanelChildren() {
	const row = state.selected ? level.rows.find(r => r.id === state.selected) : null;
	const object = state.selected ? level.objects.get(state.selected) : null;
	const modes = ['grid', 'face', 'marker'];
	const children = [
		{
			type: 'row', gap: 4, children: [
				{ type: 'label', text: 'mode' },
				{
					type: 'select', key: 'modeSelect', options: modes, selected: modes.indexOf(state.mode),
					onChange: i => editor.setMode(modes[i]),
				},
			],
		},
	];
	if (state.mode === 'marker' && state.grab && state.markerChoices.length > 0) {
		children.push({
			type: 'row', gap: 4, children: [
				{ type: 'label', text: 'marker' },
				{
					type: 'select', key: 'markerSelect', options: state.markerChoices,
					selected: state.markerChoices.indexOf(state.markerChoice),
					onChange: i => { state.markerChoice = state.markerChoices[i]; },
				},
			],
		});
	}
	if (!row || !object) {
		children.push({ type: 'label', text: '(no selection)' });
		return children;
	}
	const turns = Math.round(wrapTurn(object.rotation.y) / (Math.PI / 2)) % 4;
	children.push(
		{ type: 'label', text: `id: ${row.id}` },
		{ type: 'label', text: `piece: ${row.piece}` },
		{ type: 'label', key: 'propsPos', text: positionText(object) },
		{ type: 'label', key: 'propsRot', text: `rotation: ${turns} quarter turn${turns === 1 ? '' : 's'}` },
		{ type: 'label', text: row.snap ? `snap: ${row.snap.to} ${row.snap.side}` : 'snap: (freehand)' },
	);
	return children;
}

function positionText(object) {
	return `position: ${object.position.x.toFixed(2)}, ${object.position.y.toFixed(2)}, ${object.position.z.toFixed(2)}`;
}

function statusText() {
	const stats = scene.stats();
	let text = `${state.mode} · ${state.selected ?? '(none)'} · ${level.rows.length} piece${level.rows.length === 1 ? '' : 's'}`
		+ ` · ${stats.drawCalls} draws${state.dirty ? ' · *' : ''}`;
	if (state.lastError) text += ` · ${state.lastError}`;
	return text;
}

function buildUI() {
	return {
		type: 'stack',
		children: [
			{ type: 'anchored', h: 'start', v: 'start', child: { type: 'menu', key: 'menu', menus: menuSpec(), onSelect: safe(onMenuSelect) } },
			{
				type: 'anchored', h: 'start', v: 'start', margin: [8, 36],
				child: { type: 'column', key: 'assetPanel', gap: 4, size: [190, 0], insets: 6, children: assetPanelChildren() },
			},
			{
				type: 'anchored', h: 'end', v: 'start', margin: [8, 36],
				child: { type: 'column', key: 'propsPanel', gap: 4, size: [220, 0], insets: 6, children: propsPanelChildren() },
			},
			{
				type: 'anchored', h: 'start', v: 'end', margin: [8, 8],
				child: { type: 'label', key: 'status', text: statusText() },
			},
			{
				type: 'confirmDialog', key: 'deleteConfirm', title: 'Remove piece',
				message: `Remove ${state.confirmDeleteId ?? ''}?`, confirm: 'Remove', decline: 'Keep',
				open: state.confirmDeleteOpen, onConfirm: safe(confirmRemove), onDismiss: safe(cancelRemove),
			},
			{
				type: 'confirmDialog', key: 'newConfirm', title: 'Discard changes',
				message: 'This level has unsaved changes — discard them and start a new one?',
				confirm: 'Discard', decline: 'Cancel', open: state.confirmNewOpen,
				onConfirm: safe(() => { state.confirmNewOpen = false; state.kitDialogOpen = true; syncUI(); }),
				onDismiss: safe(() => { state.confirmNewOpen = false; syncUI(); }),
			},
			{
				type: 'dialog', key: 'openDialog', title: 'Open level', open: state.openDialogOpen,
				modal: true, closeOutside: true, size: [360, 320],
				child: {
					type: 'fileBrowser', key: 'openBrowser', start: 'levels/', mask: ['*.json'],
					onChoose: safe(path => { state.openDialogOpen = false; doOpen(path); }),
				},
				onDismiss: safe(() => { state.openDialogOpen = false; syncUI(); }),
			},
			{
				type: 'dialog', key: 'kitDialog', title: 'Choose a kit', open: state.kitDialogOpen,
				modal: true, closeOutside: false, size: [360, 320],
				child: {
					type: 'fileBrowser', key: 'kitBrowser', mask: ['*.glb', '*.gltf'],
					onChoose: safe(path => { state.kitDialogOpen = false; doNewLevel(path); }),
				},
			},
			{
				type: 'dialog', key: 'saveAsDialog', title: 'Save level as', open: state.saveAsOpen,
				modal: true, closeOutside: true, size: [340, 0],
				child: {
					type: 'column', gap: 8, children: [
						{ type: 'textfield', key: 'saveAsField', text: state.saveAsText, onChange: t => { state.saveAsText = t; } },
						{
							type: 'row', gap: 8, children: [
								{ type: 'button', text: 'Cancel', onClick: safe(() => { state.saveAsOpen = false; syncUI(); }) },
								{ type: 'button', text: 'Save', onClick: safe(() => { state.saveAsOpen = false; doSave(state.saveAsText); }) },
							],
						},
					],
				},
				onDismiss: safe(() => { state.saveAsOpen = false; syncUI(); }),
			},
			{
				type: 'dialog', key: 'exportDialog', title: 'Export .glb', open: state.exportOpen,
				modal: true, closeOutside: true, size: [340, 0],
				child: {
					type: 'column', gap: 8, children: [
						{ type: 'textfield', key: 'exportField', text: state.exportText, onChange: t => { state.exportText = t; } },
						{
							type: 'row', gap: 8, children: [
								{ type: 'button', text: 'Cancel', onClick: safe(() => { state.exportOpen = false; syncUI(); }) },
								{
									type: 'button', text: 'Export', onClick: safe(() => {
										state.exportOpen = false;
										const parent = helpers.parent;
										if (parent) parent.remove(helpers);
										try {
											const result = scene.export(state.exportText || 'levels/level.glb');
											setStatus(`exported ${result.path}`);
										} finally {
											if (parent) parent.add(helpers);
										}
									}),
								},
							],
						},
					],
				},
				onDismiss: safe(() => { state.exportOpen = false; syncUI(); }),
			},
		],
	};
}

function syncUI() {
	three.ui.set(buildUI());
	syncPersist();
}

syncUI();

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
	three.ui.patch('status', { text: statusText() });
	if (state.selected && level.objects.has(state.selected)) {
		const object = level.objects.get(state.selected);
		try { three.ui.patch('propsPos', { text: positionText(object) }); } catch (e) { /* shape changed this frame */ }
		if (state.grab && state.mode === 'marker') {
			try {
				three.ui.patch('markerSelect', {
					options: state.markerChoices,
					selected: state.markerChoices.indexOf(state.markerChoice),
				});
			} catch (e) { /* the row is not in the tree until the next syncUI */ }
		}
	}
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
	_tree() { return visibleTreeRows().widgetRows.map(r => r.label); },
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
