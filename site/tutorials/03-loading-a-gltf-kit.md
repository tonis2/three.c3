---
title: Loading a glTF kit
order: 3
summary: Meshes off disk, and how to place them without ever guessing a size.
---

# Loading a glTF kit

The examples in this repository build everything they draw in code, so none of
them needs an assets folder. This tutorial covers the other case: a `.glb`
file you downloaded or exported, with a hundred pieces inside it, and a level
to lay out from those pieces.

Start the engine with an assets directory. All paths are then relative to that
directory and cannot escape it, which is what makes it safe to pass the paths
from `three.inventory()` straight to `three.load`.

```bash
./three --assets ./assets --script 03-loading-a-gltf-kit.js
```

Or create `main.js` in assets directory and add the code there

```bash
./three --assets ./assets
```

`main.js` is loaded as an ES module, so a level can be split across files that
`import` one another. Import paths resolve inside the assets directory, and
`..` cannot climb out of it. `--script` alongside `--assets` still has a use
after that: it runs a one-off file against the world that `main.js` has
already built, which is handy for a probe or a screenshot pass.

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
directory **without loading any of them**: path, triangle count, node count,
skins, mesh names, animation names and bounds, all read straight from the
file's JSON chunk. On a 200-piece kit this costs almost nothing, and it is how
you find out what is worth loading before you load it.

```js
const kitFile = files.sort((a, b) => b.meshes.length - a.meshes.length)[0];
const kit = kitFile ? three.load(kitFile.path) : null;

if (kit) three.debug.write({ file: kit.path, meshes: kit.meshes.length, animations: kit.animations });
```

`three.load` parses the file and uploads **nothing** to the GPU. A mesh
reaches the GPU only when a `Mesh` that draws it is added to a scene. So
loading a 200-piece kit and placing twelve pieces costs you twelve.

## Two doors into an asset

There are exactly two ways to get things out of an asset, and picking the
wrong one is the most common first mistake:

| | what it gives you | use it for |
|---|---|---|
| `asset.mesh(name)` | one piece, as a reference you place yourself | placing pieces: walls, props, tiles |
| `asset.instantiate()` | the file's own node hierarchy, as a `Group` | rigs, multi-part props, a level laid out in Blender |

`instantiate()` is the equivalent of Three.js's `gltf.scene`. It is also how
animations come in: a glTF clip drives a whole subtree, so `play()` lives on
the `Group` that `instantiate()` returns, not on a mesh.

## Measure, never guess

A kit piece's origin is wherever its exporter put it. A size table typed by
hand into a script is exactly the kind of thing that goes stale and sinks
pieces into walls. So **everything you can place can be measured**, and you
should measure it:

- `asset.mesh(name).bounds` and `geometry.bounds` — a `Box3` in the piece's
  own space, read from the glTF JSON, so it costs no upload.
- `object.boundingBox()` — the world-space box around a whole subtree.
- `object.boundsInParent()` — the same box in the parent's coordinate frame.
  It works *before* `add()`.

Then place with the placement verbs instead of arithmetic. `align(axis, edge,
at)` moves an object until one face of its box sits at a coordinate.
`snapTo(other, side, axes)` puts a piece on one side of another piece, touching
— `side` is one of `'+x' '-x' '+y' '-y' '+z' '-z'`, and it says which side of
the other object this one goes on.

```js
const row = new three.Group();
scene.add(row);

if (kit) {
	const names = kit.meshes.slice(0, 6);
	let previous = null;

	for (let i = 0; i < 12; i++) {
		const piece = new three.Mesh(kit.mesh(names[i % names.length]));
		row.add(piece);

		// Stand it on the ground and butt it against the piece before it —
		// whatever this piece happens to be, and wherever its origin sits.
		piece.align('y', 'min', 0);
		if (previous) piece.snapTo(previous, '+x', { gap: 0.05 });
		else piece.align('x', 'min', 0);
		previous = piece;
	}

	three.debug.write({ placed: row.children.length });
}
```

Twelve pieces placed edge to edge, and not one number in that loop came from a
size table. `gap` is the sign convention everywhere: positive spaces the pieces,
negative laps them over each other, which is what a course of roof tiles is. The
whole loop is also one call — `row.row('x', pieces, { gap: 0.05 })` — once you
have the pieces in a list.

**An axis nobody names does not move.** A freshly loaded piece sits at the
origin, so a snap that names only the side leaves the other two axes exactly
where they were; that is what makes it safe to reach for after the piece is
already standing on the floor. When a placement should be flush *without*
touching — a chimney centred on a ridge — that is `alignTo(other, axes)`, the
same axes with no side.

Neither verb asks which frame to work in. Two pieces under the same parent are
measured in that parent's frame, which is the frame a script writes positions
in; two under different parents are measured in world space and the step is
converted back. Set rotation and scale first, since they affect where the box
ends up.

## When a piece is somewhere you did not expect

Reach for debug drawing early; it is the cheap option.

```js
const helpers = new three.Group();
scene.add(helpers);
helpers.add(new three.GridHelper(30, 30));
for (const piece of row.children) helpers.add(new three.BoxHelper(piece));
```

`BoxHelper(object)` draws the box an object actually occupies, `GridHelper`
shows where the ground is, `AxesHelper` shows which way a pivot faces, and
`WireframeHelper` draws a mesh's own edges. The wireframe is how you find two
faces 0.01 apart — a z-fighting starburst is invisible in a solid render.

Helpers draw **on top of** everything. Unlike helpers in Three.js, the line
pipeline does no depth testing, because the moments you ask where something is
are the moments it is inside a wall. The trade-off goes the other way too: a
helper is an ordinary mesh, so it counts in `boundingBox()` and in
`frameAll()`. That is why the helpers above hang from their own `Group`, and
why the camera is framed on the row rather than on the whole scene:

```js
three.camera.frameAll();
three.camera.orbit(28, 20, Math.max(12, row.children.length * 1.6));
three.debug.write(scene.stats());
```

A thousand helpers are still one draw call per kind, `helper.color` is per
copy and free, and helpers are **not** pickable — a click goes through the box
to the object inside it.

## What it cost

Twelve pieces from one file is twelve instances, and every group of pieces
sharing a mesh name is one draw call. If the kit has materials you want — a
`.glb` authored with `alphaMode BLEND`, normal maps, emissive maps — pass
`{ materials: true }` to `instantiate()`. This is off by default because it
compiles a shader for every distinct glTF material, and a scene that looks
fine without them should not pay for that.

Next: [Animation and skinning](04-animation-and-skinning.html) — playing the
clips that came in the file, and what a hundred of the same character costs.
