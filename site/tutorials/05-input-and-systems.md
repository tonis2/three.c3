---
title: Input and systems
order: 5
summary: Keys into movement, a character that collides with the world, and a frame you can read a line at a time.
---

# Input and systems

This one runs with no assets. It builds a small obstacle course, walks a
capsule around it with `moveAndSlide`, and puts every part of the frame into a
named system so you can see what each one costs.

```bash
./three --script 05-input-and-systems.js
```

## A course to walk around

```js
const scene = new three.Scene();
three.light.set([-0.45, -1, -0.35], 0.3);

const ground = new three.Mesh(new three.PlaneGeometry(60, 60));
ground.rotation.x = -Math.PI / 2;
ground.color = [0.21, 0.24, 0.27, 1];
scene.add(ground);

const block = new three.BoxGeometry(1, 1, 1);
three.seed(7);

for (let i = 0; i < 80; i++) {
	const wall = new three.Mesh(block);
	wall.position.set(three.randFloatSpread(46), 0, three.randFloatSpread(46));
	wall.scale.set(three.randFloat(1, 5), three.randFloat(1, 3.5), three.randFloat(1, 5));
	wall.position.y = wall.scale.y / 2;
	wall.color = three.mixColor([0.35, 0.37, 0.42], [0.55, 0.5, 0.45], three.randFloat(0, 1));
	scene.add(wall);
}

const player = new three.Group();
const body = new three.Mesh(new three.CylinderGeometry(0.35, 0.35, 1.4, 16));
body.color = [0.95, 0.55, 0.2, 1];
player.add(body);
player.position.set(0, 0.7, 0);
scene.add(player);
```

Eighty walls of eighty different sizes and **one** draw call, because `scale`
is a per-copy channel and a new `BoxGeometry` size would not be.

## Reading the keyboard

There are two ways, and which one you want depends on the question:

- **`three.onKeyDown(key, fn)`** — an event. Right for a jump, a fire, a toggle.
- **`three.input.isDown(key)`** — a poll. Right for anything continuous, because
  a held key fires no repeat events.

```js
const input = { fwd: 0, strafe: 0, jump: false };
const state = { vy: 0, grounded: false };

three.onKeyDown('space', () => { input.jump = true; });
three.onKeyDown('r', () => { player.position.set(0, 0.7, 0); state.vy = 0; });
```

Keys are read once per frame, so `three.input.pressed()` and
`three.input.text` mean something inside a frame callback and almost never
outside one. `isDown()` is fine anywhere.

## Gameplay on the fixed clock, drawing on the frame

`three.systems` is an ordered, named list, and **the verb is the clock**:

- `three.systems.step(name, fn)` runs at `three.clock.fixedRate` — zero or more
  times a frame, with the same `dt` every call. This is where the rules go,
  because movement and collision drift when the step they integrate over does
  not.
- `three.systems.frame(name, fn)` runs once per drawn frame, handed what that
  frame was actually worth. This is where the camera, the fades and the uniform
  writes go.

```js
three.systems.frame('input', () => {
	input.fwd = (three.input.isDown('w') ? 1 : 0) - (three.input.isDown('s') ? 1 : 0);
	input.strafe = (three.input.isDown('d') ? 1 : 0) - (three.input.isDown('a') ? 1 : 0);
});
```

## A character that collides with the world

`three.moveAndSlide(position, motion, options)` sweeps a capsule, slides along
what it hits, climbs a ledge under the step height and reports whether it is
standing on anything. It **integrates nothing** — gravity, the velocity and the
jump stay yours — and it touches no rigidbody, because a character built out of
physics is pushed by contacts, tips over and answers a frame late.

```js
const SHAPE = { radius: 0.35, height: 1.4, step: 0.4, slope: 50, ignore: player };

three.systems.step('player', dt => {
	const dir = three.camera.planarMove(input.fwd, input.strafe);
	const speed = 7;

	state.vy = state.grounded && !input.jump ? -2 : state.vy - 22 * dt;
	if (input.jump && state.grounded) state.vy = 8;
	input.jump = false;

	const motion = [dir.x * speed * dt, state.vy * dt, dir.z * speed * dt];
	const moved = three.moveAndSlide(player.position, motion, SHAPE);

	player.position.set(moved.position.x, moved.position.y, moved.position.z);
	state.grounded = moved.grounded;
	if (moved.grounded && state.vy < 0) state.vy = 0;
	if (dir.lengthSq() > 0) player.rotation.y = Math.atan2(dir.x, dir.z);
});
```

Two details that are easy to get wrong:

- **Pass the character's own object as `ignore`, and pass the *Group*** — not
  one mesh out of it. `ignore` leaves the object's whole subtree out, so a
  character built from a body, a head and four limbs does not collide with its
  own chest.
- **`slope` is one number doing three jobs**: whether the ground counts as
  ground, whether a ledge is climbed, and whether a contact is a floor or a
  wall. One number so the three cannot disagree.

Every drawable mesh is collision geometry by default, which is why the eighty
blocks work as walls with nothing else declared. The flip side is that a pickup
lying on a path is a bollard — `object.collides = false` takes one mesh out of
the spatial index entirely while it still draws exactly as before.

## A camera that follows

```js
three.camera.attach(player, { offset: [0, 1.2, 0], distance: 9, lag: 0.12 });
```

`attach` runs **last** in the frame, after the animation, the solver and your
callbacks have all moved things — so the camera is never a frame behind, which
is what makes a trailing camera look like the character sliding. `distance: 0`
puts the eye on the point, and that is first person: not a mode, just a number.

## A timer that survives a slow frame

```js
const dash = three.cooldown(1.2, { recover: 0.35 });

three.onKeyDown('shift', () => {
	if (!dash.ready) return;
	dash.start();
	state.vy = Math.max(state.vy, 3);
});
```

`three.cooldown` is the `if (x > 0) x -= dt` pattern, ticked by a system of its
own rather than read off `three.clock.time`. That is the whole reason it exists:
the game clock advances once per host tick, so a coyote-sized window can span
several fixed steps of one tick and would see no time pass at all if it were
measured off the clock.

## Read the frame

```js
three.systems.frame('hud', () => {
	three.debug.overlay(
		`grounded ${state.grounded ? 'yes' : 'no'}   `
		+ `dash ${dash.ready ? 'ready' : dash.remaining.toFixed(1)}   `
		+ `${three.stats().drawCalls} draw calls`);
});

three.systems.outline();
three.debug.write({ systems: three.systems.report(), stats: scene.stats() });

three.camera.orbit(0, 22, 9);
```

`outline()` prints the tick — the step list on one line, the frame list on the
next, in the order they will run. `report()` gives per-system milliseconds over
`three.clock.wall`, which is the CPU half of what `three.stats()` has done for
the GPU half all along.

Systems run **in the order you register them**, and `{ before: 'name' }` or
`{ after: 'name' }` moves the one that has to break that. A system that throws
is contained, named and counted rather than stopping the others — which is the
real reason to split a frame up. None of this makes anything faster. What it
makes is a frame that reads as a list of named things, and a slow one you can
attribute.

---

That is the tour. From here: `three.Entity` turns a class into a tracked
game object with rules between pairs, `three.nav` bakes the walkable surface
and answers paths and flow fields, and `three.steer` /
`three.moveAndSlideAll` are the bulk forms of everything above — the same frame
written for two hundred agents is 2.20 ms with the single verbs and 0.51 ms with
these. All of it is in [the API reference](../api.html).
