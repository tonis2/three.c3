---
title: Hello scene
order: 1
summary: A window, a grid of cubes, and the one number that says the engine is doing its job.
---

# Hello scene

Everything here is a `.js` file handed to the engine. There is no project to
create, nothing to install and nothing to build — `three` reads your script,
draws what it describes, and keeps drawing until you close the window.

```bash
./three --script hello.js
```

## A scene and a mesh

A `Scene` is a world. Making one shows it.

```js
const scene = new three.Scene();

const ground = new three.Mesh(new three.PlaneGeometry(30, 30));
ground.rotation.x = -Math.PI / 2;
ground.color = [0.22, 0.24, 0.27, 1];
scene.add(ground);
```

Two things to notice. `rotation.x = -Math.PI / 2` lays the plane flat, because
a `PlaneGeometry` stands up in XY the way it does in Three.js. And `color` is a
property of the **mesh**, not of a material — that is not a shortcut, it is the
whole design, and the next section is why.

## A thousand cubes, one draw call

```js
const box = new three.BoxGeometry(1, 1, 1);

for (let x = -6; x <= 6; x++) {
	for (let z = -6; z <= 6; z++) {
		const cube = new three.Mesh(box);
		cube.position.set(x * 1.6, 0.5, z * 1.6);
		cube.scale.y = 1 + Math.abs(x + z) * 0.35;
		cube.color = three.mixColor([0.15, 0.45, 0.9], [0.95, 0.5, 0.2], (x + 6) / 12);
		scene.add(cube);
	}
}
```

That is 169 cubes. It is also **one draw call**, and you did nothing to make it
one: every mesh placed with the same asset reference is instanced, always.
There is no batching step to invoke and no way to write an unbatched scene.

Two rules follow from that, and they are worth learning here rather than
discovering later:

- **`scale` is free, a new size is not.** `new three.BoxGeometry(1, 1, 1)`
  built a hundred times is one asset, because the same numbers are the same
  geometry. `new three.BoxGeometry(1, 2, 1)` is a second asset and a second
  draw call. Vary size with `scale`.
- **`color` and `variant` are the only two things copies may differ in.**
  A thousand meshes in a thousand colours is one call. Give two of them
  different *materials* and it is two.

## Light it and look at it

```js
three.light.set([-0.5, -1, -0.35], 0.3);

three.camera.frameAll();
three.camera.orbit(35, 28, 34);
```

`three.light.set(direction, ambient)` aims the sun and lifts the shadows.
The camera is a turntable — `orbit(yaw, pitch, distance)` — and it is
read-only through accessors, so there is no `camera.position` to assign.
`frameAll()` fits everything in the scene into the view, which is the fastest
way to find out you built something and put it behind you.

## Ask what it cost

```js
three.debug.write(scene.stats());
```

`three.debug.write` is how a script answers with a value; on the command line
it prints as `debug: [...]`. What comes back:

```
{ drawCalls: 2, uniqueMeshes: 2, instances: 170, triangles: 2030, ... }
```

Two calls for two shapes — the plane and the box — and a hundred and seventy
instances between them. `drawCalls` is the number to watch. If it climbs with
the number of objects, something in your scene is making a new asset per
object, and it is almost always a geometry built inside the loop with
different numbers.

> **Getting a picture without a window.** Add `--headless --frames 1
> --screenshot hello.png` and the process renders once and exits. `--script`
> otherwise keeps running after your script returns, so a non-interactive run
> needs `--frames` or `--screenshot` to bound it.

Next: [Creating materials](02-creating-materials.html) — textures, shaders,
and how to give one material many looks without splitting the draw call.
