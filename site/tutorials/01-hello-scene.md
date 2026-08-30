---
title: Hello scene
order: 1
summary: A window, a grid of cubes, and the one number that tells you the engine is doing its job.
---

# Hello scene

Everything in this engine starts with a `.js` file. There is no project to
create, nothing to install and nothing to build. `three` reads your script,
draws what it describes, and keeps drawing until you close the window.

```bash
./three --script hello.js
```

Or name the file `main.js`, put it in a folder, and point the engine at the
folder:

```bash
./three --assets ./hello
```

`--assets <dir>` runs `<dir>/main.js` automatically — no `--script`, no file
argument, nothing to configure. This is the form to grow into. `main.js` is
loaded as an ES module, so once your game outgrows one file it can
`import './player.js'`, and `three.load("kit.glb")` looks for files relative to
that folder rather than to whatever directory your shell happens to be in. If
the folder has no `main.js`, the engine tells you and starts with an empty
scene. Everything below works the same with either command.

## A scene and a mesh

A `Scene` is your world. Creating one makes it visible.

```js
const scene = new three.Scene();

const ground = new three.Mesh(new three.PlaneGeometry(30, 30));
ground.rotation.x = -Math.PI / 2;
ground.color = [0.22, 0.24, 0.27, 1];
scene.add(ground);
```

Two things to notice here. First, `rotation.x = -Math.PI / 2` lays the plane
flat, because a `PlaneGeometry` stands upright in the XY plane, just as it does
in Three.js. Second, `color` is a property of the **mesh**, not of a material.
That is not a shortcut — it is a core part of the design, and the next section
explains why.

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

That is 169 cubes drawn with **one draw call**, and you did nothing special to
make that happen. Every mesh that uses the same geometry is instanced, always.
There is no batching step to call, and no way to write a scene that is not
batched.

(A draw call is one drawing command sent to the GPU. Fewer draw calls means
less work per frame, so it is the main number to keep an eye on.)

Two rules follow from this, and they are worth learning now rather than
discovering later:

- **`scale` is free; a new size is not.** Calling
  `new three.BoxGeometry(1, 1, 1)` a hundred times creates one asset, because
  the same numbers describe the same geometry. `new three.BoxGeometry(1, 2, 1)`
  is a second asset, and a second draw call. To vary the size of a shape, use
  `scale`.
- **`color` and `variant` are the only two things copies may differ in.**
  A thousand meshes in a thousand colors is still one draw call. Give two of
  them different *materials* and it becomes two.

## Light it and look at it

```js
three.light.set([-0.5, -1, -0.35], 0.3);

three.camera.frameAll();
three.camera.orbit(35, 28, 34);
```

`three.light.set(direction, ambient)` aims the sun and sets how bright the
shadows are. The camera is a turntable: `orbit(yaw, pitch, distance)` places
it. The camera's position is read-only, so there is no `camera.position` to
assign. `frameAll()` fits everything in the scene into view — the quickest way
to find out that you built something and put it behind the camera.

## Ask what it cost

```js
three.debug.write(scene.stats());
```

`three.debug.write` is how a script reports a value. On the command line it
prints as `debug: [...]`. Here is what comes back:

```
{ drawCalls: 2, uniqueMeshes: 2, instances: 170, triangles: 2030, ... }
```

Two draw calls for two shapes — the plane and the box — and 170 instances
between them. `drawCalls` is the number to watch. If it grows with the number
of objects, something in your scene is creating a new asset per object. Almost
always that is a geometry built inside a loop with different numbers each
time.

## `console.log` and `three.debug.write`

Both of these exist, both are captured by the engine rather than going straight
to your terminal, and they answer different questions. Reaching for the wrong
one is the usual reason a value you were sure you printed never appears.


```js
console.log('placed', scene.children.length, 'objects');
three.debug.write(scene.stats());
three.debug.write({ tallest: 4.9 }, { seed: 7 });
```

```
placed 170 objects
debug: [{"drawCalls":2,"instances":170,...},{"tallest":4.9},{"seed":7}]
```
So: **`console.log` for what happened, `three.debug.write` for what a number
is.** 

**So per-frame debugging is `console.log`, not `three.debug.write`.** Both
buffers are bounded, so a callback that talks sixty times a second cannot fill
memory; what overflows is dropped and counted rather than kept.

> **The third option, and often the best one.** `three.debug.overlay(text)`
> draws one line into the top-left of the frame itself. It lasts exactly one
> frame, so setting it every frame keeps it up and a one-off note clears itself
> — and because it is drawn into the image rather than printed beside it, a
> screenshot carries it. ``three.frame(() => three.debug.overlay(`hp ${hp}`))``
> is a HUD in one line.

## Edit it, then press shift+R

The window is live. Change the file, press **shift+R** with the window focused,
and your script runs again from the top:

```
three: reloaded in 41 ms
```

A reload is a fresh JavaScript context, not a re-run of the old one. The
animation loop, every handler and every object you created are gone, and
`main.js` (or your `--script` file) starts from nothing. What survives is the
expensive part: loaded assets stay in memory and compiled pipelines stay
compiled. A reload costs milliseconds, while restarting the process would load
every file and compile every shader again.

Shift+R and escape are the window's only two reserved keys. `three.reload()`
does the same thing from inside a script — this is how an agent driving the
engine over `--mcp` edits a file and screenshots the result. Anything that
should outlive a reload goes in `three.persist`.
[Tutorial 5](05-input-and-systems.html) uses it to put a moving character back
where it was standing.

> **Getting a picture without a window.** Add `--headless --frames 1
> --screenshot hello.png` and the process renders one frame, saves it, and
> exits. Without these flags, `--script` keeps running after your script
> returns, so a non-interactive run needs `--frames` or `--screenshot` to tell
> it when to stop.

Next: [Creating materials](02-creating-materials.html) — textures, shaders,
and how to give one material many looks without splitting the draw call.
