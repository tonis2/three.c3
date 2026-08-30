---
title: Input and systems
order: 5
summary: Keys into movement, a character that collides with the world, and a frame you can read a line at a time.
---

# Input and systems

This tutorial needs no assets. It builds a small obstacle course, walks a
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

Eighty walls, eighty different sizes, and **one** draw call — because `scale`
is a per-copy property, while a new `BoxGeometry` size would not be.

## Reading the keyboard

There are two ways to read a key, and which one you want depends on the
question you are asking:

- **`three.onKeyDown(key, fn)`** — an event. Right for a jump, a shot, or a
  toggle.
- **`three.input.isDown(key)`** — a poll. Right for anything continuous,
  because a held key does not fire repeat events.

```js
const input = { fwd: 0, strafe: 0, jump: false };
const state = { vy: 0, grounded: false };

three.onKeyDown('space', () => { input.jump = true; });
three.onKeyDown('r', () => { player.position.set(0, 0.7, 0); state.vy = 0; });
```

Keys are read once per frame, so `three.input.pressed()` and
`three.input.text` only mean something inside a frame callback, and almost
never outside one. `isDown()` works anywhere.

## Gameplay on the fixed clock, drawing on the frame

`three.systems` is an ordered, named list of functions, and **the method you
register with picks the clock**:

- `three.systems.step(name, fn)` runs at `three.clock.fixedRate` — zero or more
  times per frame, with the same `dt` every call. This is where game rules go,
  because movement and collision drift when the time step they integrate over
  keeps changing.
- `three.systems.frame(name, fn)` runs once per drawn frame, and receives the
  real time that frame took. This is where the camera, fades and uniform
  writes go.

```js
three.systems.frame('input', () => {
	input.fwd = (three.input.isDown('w') ? 1 : 0) - (three.input.isDown('s') ? 1 : 0);
	input.strafe = (three.input.isDown('d') ? 1 : 0) - (three.input.isDown('a') ? 1 : 0);
});
```

## A character that collides with the world

`three.moveAndSlide(position, motion, options)` sweeps a capsule through the
world, slides it along whatever it hits, climbs ledges lower than the step
height, and reports whether it is standing on anything. It **integrates
nothing** — gravity, velocity and the jump are still yours to handle. It also
touches no rigidbody, because a character built out of physics gets pushed
around by contacts, tips over, and responds a frame late.

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
  one mesh out of it. `ignore` excludes the object's whole subtree, so a
  character built from a body, a head and four limbs does not collide with
  its own chest.
- **`slope` is one number doing three jobs**: it decides whether the ground
  counts as ground, whether a ledge can be climbed, and whether a contact is a
  floor or a wall. It is one number so that the three can never disagree.

Every drawable mesh is collision geometry by default, which is why the eighty
blocks work as walls without declaring anything. The flip side is that a
pickup lying on a path blocks the way like a bollard. `object.collides = false`
removes one mesh from the spatial index entirely while it still draws exactly
as before.

## A camera that follows

```js
three.camera.attach(player, { offset: [0, 1.2, 0], distance: 9, lag: 0.12 });
```

`attach` runs **last** in the frame, after the animation, the solver and your
callbacks have all moved things. So the camera is never a frame behind — that
lag is what makes a trailing camera look like the character is sliding.
`distance: 0` puts the eye right on the target point, and that is first
person: not a mode, just a number.

## A timer that survives a slow frame

```js
const dash = three.cooldown(1.2, { recover: 0.35 });

three.onKeyDown('shift', () => {
	if (!dash.ready) return;
	dash.start();
	state.vy = Math.max(state.vy, 3);
});
```

`three.cooldown` is the `if (x > 0) x -= dt` pattern, ticked by its own system
rather than read from `three.clock.time`. That is the whole reason it exists:
the game clock advances once per host tick, so a short window (the size of a
coyote-time jump) can span several fixed steps of one tick, and would see no
time pass at all if it were measured from the clock.

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

`outline()` prints the tick: the step list on one line and the frame list on
the next, in the order they will run. `report()` gives per-system milliseconds
measured with `three.clock.wall`. That is the CPU half of the picture;
`three.stats()` has been giving you the GPU half all along.

Systems run **in the order you register them**. `{ before: 'name' }` or
`{ after: 'name' }` moves the one that needs to break that order. A system
that throws is contained, named and counted rather than stopping the others,
and that is the real reason to split a frame up. None of this makes anything
faster. What it gives you is a frame that reads as a list of named parts, and
a slow frame you can pin on one of them.

## Keeping your place across a reload

Shift+R over the window starts this file again from the top in a new context,
as [tutorial 1](01-hello-scene.html) describes. While you are tuning a jump
height, that means the capsule goes back to the middle of the course on every
edit. `three.persist` is the one object that crosses a reload:

```js
three.systems.frame('persist', () => {
	three.persist.at = player.position.toArray();
	three.persist.vy = state.vy;
});

if (three.reloaded && three.persist.at) {
	player.position.set(...three.persist.at);
	state.vy = three.persist.vy;
}
```

`three.reloaded` is false on the first boot of the process and true on every
boot after a shift+R or a `three.reload()`. It is the only way a script can
tell the two apart, and it decides whether `three.persist` holds anything
meaningful.

The state crosses as **JSON**, so put numbers in it, not object handles.
`player` is an index into a node pool that the reload frees, and that index
means nothing on the other side. `player.position.toArray()` is three numbers
and survives; a `Group` does not. A value that `JSON.stringify` refuses (a
cycle, a `Map`, a function) is reported on the terminal and dropped, rather
than half-kept.

That is the loop worth having while you build a game: start it once with
`./three --assets ./game`, leave the window open, edit `main.js`, press
shift+R, and the character is still standing where you left it.

---

That is the tour. From here: `three.Entity` turns a class into a tracked game
object with rules between pairs of entities, `three.nav` bakes the walkable
surface and answers path and flow-field queries, and `three.steer` /
`three.moveAndSlideAll` are the bulk forms of everything above. The same frame
written for two hundred agents takes 2.20 ms with the single verbs and 0.51 ms
with these. All of it is in [the API reference](../api.html).
