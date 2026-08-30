---
title: Loading a glTF kit
order: 3
summary: Meshes off disk, and how to place them without ever guessing a size.
---

# Loading a glTF kit

The examples in this repository build everything they draw in code, so nothing
here needs an assets folder. This tutorial is the other case: a `.glb` you
downloaded or exported, with a hundred pieces in it, and a level to lay out.

Start the engine with an assets directory. Paths are then relative to it and
cannot climb out of it, which is what makes `three.inventory()` paths safe to
hand straight to `three.load`.

```bash
./three --assets ./assets --script 03-loading-a-gltf-kit.js
```

## Look before you load

```js
const scene = new three.Scene();
three.light.set([-0.45, -1, -0.4], 0.32);

const files = three.inventory();

if (files.length === 0) {
	three.debug.write({
		note: 'No .glb or .gltf found. Start three with --assets <folder> pointing at a kit.',
		hint: 'Any glTF works — a Kenney kit, a Blender export, a Sketchfab download.',
	});
}
```

`three.inventory()` describes every `.glb` and `.gltf` under the assets
directory **without loading any of it**: path, triangle count, node count,
skins, mesh names, animation names and bounds, read straight out of the JSON
chunk. On a 200-piece kit that costs nothing, and it is how you find out what
is worth loading before you load it.

```js
const kitFile = files.sort((a, b) => b.meshes.length - a.meshes.length)[0];
const kit = kitFile ? three.load(kitFile.path) : null;

if (kit) three.debug.write({ file: kit.path, meshes: kit.meshes.length, animations: kit.animations });
```

`three.load` parses the file and uploads **nothing**. A mesh reaches the GPU
when a `Mesh` drawing it is added to a scene, so loading a 200-piece kit to
place twelve costs twelve.

## Two doors into an asset

There are exactly two, and picking the wrong one is the usual first mistake:

| | what it gives you | use it for |
|---|---|---|
| `asset.mesh(name)` | one piece, as a reference you place yourself | placing pieces: walls, props, tiles |
| `asset.instantiate()` | the file's own node hierarchy, as a `Group` | rigs, multi-part props, a level laid out in Blender |

`instantiate()` is Three.js's `gltf.scene`. It is also the door that animations
come through — a glTF clip drives a whole subtree, so `play()` lives on the
`Group` it answers with, not on a mesh.

## Measure, never guess

A kit piece's origin is wherever its exporter left it. A size table written by
hand into a script is the thing that goes stale and sinks pieces into walls, so
**everything placeable can be measured**, and you should:

- `asset.mesh(name).bounds` and `geometry.bounds` — a `Box3` in the piece's own
  space, read out of the glTF JSON, so it costs no upload.
- `object.boundingBox()` — the world-space box of a whole subtree.
- `object.boundsInParent()` — the same box in the parent's frame, and it works
  *before* `add()`.

Then place with `align` rather than with arithmetic. `align(axis, edge, at)`
moves an object until one face of its box sits at a coordinate, and `alignTo`
says the same thing against a sibling.

```js
const row = new three.Group();
scene.add(row);

if (kit) {
	const names = kit.meshes.slice(0, 6);
	let cursor = 0;

	for (let i = 0; i < 12; i++) {
		const piece = new three.Mesh(kit.mesh(names[i % names.length]));
		row.add(piece);

		// Stand it on the ground and butt it against the piece before it —
		// whatever this piece happens to be, and wherever its origin sits.
		piece.align('y', 'min', 0);
		piece.align('x', 'min', cursor);
		cursor = piece.boundsInParent().max.x + 0.05;
	}

	three.debug.write({ placed: row.children.length, width: cursor.toFixed(2) });
}
```

Twelve pieces butted edge to edge, and not one number in that loop came from a
size table. Both verbs work in the **parent's** frame, because that is the
frame a script writes positions in — and set rotation and scale first, since
they are inputs to where the box is.

## When a piece is somewhere you did not expect

Reach for debug draw early; it is the cheap move.

```js
const helpers = new three.Group();
scene.add(helpers);
helpers.add(new three.GridHelper(30, 30));
for (const piece of row.children) helpers.add(new three.BoxHelper(piece));
```

`BoxHelper(object)` boxes what an object actually occupies, `GridHelper` says
where the ground is, `AxesHelper` shows which way a pivot faces, and
`WireframeHelper` draws a mesh's own edges — which is how two faces 0.01 apart
are found, because a z-fighting starburst is invisible in a solid render.

Helpers draw **over** everything: the line pipeline tests no depth, unlike
Three.js's helpers, because the times you ask where something is are the times
it is inside a wall. The cost is the other direction — a helper is an ordinary
mesh, so it is inside `boundingBox()` and inside `frameAll()`. That is why they
hang from a `Group` of their own above, and why the camera is framed on the row
rather than on the scene:

```js
three.camera.frameAll();
three.camera.orbit(28, 20, Math.max(12, row.children.length * 1.6));
three.debug.write(scene.stats());
```

A thousand helpers are still one draw call each by kind, `helper.color` is per
copy and free, and they are **not** pickable — a click goes through the box onto
the thing inside it.

## What it cost

Twelve pieces off one file is twelve instances, and every group of them sharing
a mesh name is one draw call. If the kit has materials you want — a `.glb`
authored with `alphaMode BLEND`, normal maps, emissive maps — pass
`{ materials: true }` to `instantiate()`; it is off by default because it
compiles a shader per distinct glTF material, which a scene that was happy
without them should not pay for.

Next: [Animation and skinning](04-animation-and-skinning.html) — playing the
clips that came in the file, and what a hundred of the same character costs.
