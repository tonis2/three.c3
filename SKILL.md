---
name: three
description: Build, run and screenshot 3D scenes with the `three` CLI — a Three.js-shaped JavaScript scene API over Vulkan. Use when writing or debugging scene scripts, driving `three --headless` for batch renders and flipbooks, booting a game with `--assets`, or talking to its MCP server (run_script / screenshot / get_api_docs).
---

# three

A single binary that renders a scene described in JavaScript. The API is
Three.js-shaped — `three.Scene`, `three.Mesh`, `position/rotation/scale`,
`add/remove` — but it is **not** Three.js, and the differences are what break
scripts. Read *Traps* below before writing one.

`three --help` lists the flags. `three.getApiDocs()` (or the `get_api_docs` MCP
tool) is the authoritative API reference and is embedded in the binary — when
this file and the docs disagree, the docs are right.

## What has to be next to the binary

`three` is one executable. The shader templates are compiled into it and so is
the Slang compiler, so `three` runs from any directory and there is nothing to
copy alongside it — with one exception, on macOS.

| What | Looked for in | A missing one looks like |
|---|---|---|
| a Vulkan driver (macOS) | `@executable_path` first, then the loader's own ICD discovery | no device, or a silent fall through to whatever else is installed |

On macOS that driver is `libvulkan_kosmickrisp.dylib`, and it has to stay a
file beside the binary because `vk/driver.c3` `dlopen`s it by name. Move the
folder, not the executable. On Linux and Windows the loader is the system's and
the executable travels alone.

**A checkout still overrides.** `shader_source` reads the search path first —
`shaders/<name>` then `build/shaders/<name>` — and falls back to the embedded
copy. So editing `shaders/mesh.slang` and re-running shows the change with no
rebuild, exactly as before; a shipped binary with no `shaders/` beside it uses
what it carries. A *broken* shader on that path wins too, and reports a Slang
error with a line and a column rather than being quietly ignored.


```
error[E00100]: failed to load downstream compiler 'spirv-opt'
note[E99996]: failed to load dynamic library 'slang-glslang-2026.12.2'

three: three::SHADER_COMPILE_FAILED
```

No frame is drawn and no PNG is written, so this one is loud. 

### The one that fails quietly

A shadow shader that will not build for any *other* reason still leaves the run
alive: it renders every frame unshadowed and **exits 0**, and nothing about the
exit status or the PNG says so rather than that you forgot to turn shadows on.
From a script, the tell is that `three.light.shadow.enabled`
**reads back `false` on the next frame after you set it `true`**, and
`three.stats().shadowDraws` stays 0:

```js
three.light.shadow = true;
// ...one frame later...
if (!three.light.shadow.enabled) console.log('the shadow shader did not build');
```

`three.light.shadow.fit.live` is not the check: it describes the *last frame
drawn*, so it reads false on frame 1 whether or not anything is wrong.

`three` also writes its compiled-shader cache to `./build/shader-cache`, again
relative to the working directory, so it creates a `build/` wherever it runs.

## Two ways to work

**MCP — the interactive loop.** `three --mcp` serves three tools on
`http://127.0.0.1:8808/mcp`. You send a script, you get back what it logged,
what it returned, the scene's stats, and a PNG of the frame. Use this when
iterating on a scene.

**CLI — the batch loop.** `three --headless --script s.js --screenshot out.png`
renders and exits. Use this in tests, in CI, and any time you want a file rather
than a conversation.

## Flags

| Flag | Meaning |
|---|---|
| `--headless` | No window, no surface, no swapchain. Required on a machine with no display. |
| `--script <f.js>` | Run one script, then keep running. |
| `--assets <dir>` | Boot a game: evaluate `<dir>/main.js` as a module. Paths in `three.load` become relative to `<dir>` and cannot climb out. |
| `--screenshot <path>` | Write a PNG. Implies `--headless`. |
| `--frames <n>` | Run exactly n frames and exit. Implies `--headless`. |
| `--every <n>` | With `--frames`, shoot every n frames. |
| `--width <n>` / `--height <n>` | Offscreen size. Default 1280×720. |
| `--camera <yaw,pitch,distance>` | Override the camera, over whatever the script set. |
| `--mcp [port]` | Serve the agent tools on 127.0.0.1. Default port 8808. |
| `--mcp-stdio [port]` | Be the stdio end of a `three` that is already serving. |
| `-h`, `--help` | Usage. |

How they interact:

- `--screenshot` and `--frames` each imply `--headless`.
- `--mcp` **cancels** `--screenshot` and `--frames` — a server that renders one
  frame and exits is not a server.
- `--screenshot` with no `--frames` means one frame.
- Every argument is a flag: unknown ones and bare words are both errors. There
  is no positional file — a model is loaded from a script, with
  `three.load('model.glb')`, which is what hands it back as an object.

### ⚠ The one that will hang you

`--script` and `--assets` keep running after the script returns — that is the
point of them. **Without `--frames` or `--screenshot`, the process never
exits.** In any non-interactive context always bound the run:

```bash
three --headless --script s.js --frames 1 --screenshot out.png
```

## Recipes

```bash
# one frame of a script
three --headless --script scene.js --screenshot out.png

# a flipbook: 6 frames, shoot every 2nd -> fb-000.png, fb-001.png, fb-002.png
three --headless --script spin.js --screenshot 'fb-%03d.png' --frames 6 --every 2

# look at a model from a fixed angle, at a fixed size
three --headless model.glb --screenshot m.png --camera 45,20,12 --width 640 --height 360

# boot a game directory (evaluates game/main.js) for 120 frames
three --headless --assets ./game --frames 120 --screenshot 'run-%03d.png'

# play a level with nobody at the keyboard — the scene presses its own keys
three --headless --assets ./game --frames 1800 --screenshot 'run-%02d.png' --every 300

# serve the agent tools (windowed), or headless on a build box
three --mcp
three --mcp 8808 --headless
```

`%d` / `%03d` in the `--screenshot` path is replaced with the **shot index**
(0, 1, 2…). Without it every shot overwrites the same file. The line it prints
(`wrote fb-001.png (frame 4)`) reports the *frame* number, which is a different
count when `--every` is in play.

Batch runs are deterministic: the same `--frames` count means the same thing on
every machine, which is exactly what a vsynced window takes away.

### What the CLI prints

- `console.log` from the script goes to stdout.
- A script that throws prints `three: <path> did not run: <error>` with a stack
  and **still exits 0**. Only a bad flag or an unreadable `--script` path exits
  1. So in a test, assert on stdout or on the PNG — not on the exit code.
- A script's `return` value is **not** printed on the CLI path. It only comes
  back as `value` from the `run_script` MCP tool. Use `console.log` in batch.

## The MCP tools

Connect over HTTP (`"type": "http"`, `"url": "http://127.0.0.1:8808/mcp"`) or
have the client spawn `three --mcp-stdio`. The stdio relay answers the handshake
from a local catalog even when no app is up, so tools list before the app
starts; the HTTP transport needs the server already running.

**`run_script`** — takes `{ source }`. Runs as an async function body, so
top-level `await` and `return` both work. Answers with two content blocks,
**whether or not the script succeeded**:

1. a JSON report — `{ ok, log, value, stats }`, plus `error` when it threw and
   `warnings` when the renderer had something to say
2. a PNG of the frame

`stats` is `drawCalls, uniqueMeshes, instances, nodes, assets, triangles,
vertices, textures, textureBytes, geometryBytes, targetBytes, postBytes,
shadowBytes, culledLastFrame, shadowCulled` plus six timings — `gpuMs` is the
frame and `prepareMs / shadowMs / sceneMs / postMs / presentMs` are what it was
spent on. The `...Ms` fields measure the last frame drawn, so they move when
nothing about the scene has.

`warnings` is an array and is **advice, not errors** — the run still succeeded.
It is what the host noticed: live scenes climbing, live materials climbing, a
shadow map that just cost 134 MB, a shader that would not compile. Absent on
nearly every run, which is what makes it worth reading on the runs it appears
in. Read it as separate from `log`, which is what your own script printed.

The script budget through `run_script` is **30 s**, not the 5 s a windowed run
gets. `three.budget = 60000;` at the top of the script raises it, up to ten
minutes.

**`screenshot`** — takes `{ path }` (optional). Renders and returns the PNG.
Takes no view arguments; move `three.camera` from a script instead.

**`get_api_docs`** — the reference. Call it before writing a script.
- no arguments → the index: summary, every deliberate difference from Three.js
  in full, the stats block, and the names of every class and function
- `{ search: "..." }` → grep over the whole surface
- `{ section: "classes.ShaderMaterial" }` → one entry or one whole section
- `{ path: "api.md" }` → **currently writes nothing.** It answers with the
  index and no file appears, for a relative path or an absolute one. Until it
  does, the way to get a file to grep is to log it and redirect — note that a
  script's `return` value is not printed on the CLI path, only `console.log`:

      echo 'console.log(JSON.stringify(three.getApiDocs({ all: true })))' > d.js
      three --headless --script d.js --frames 1 | grep -m1 '^{' > api.json

  `grep -m1 '^{'` rather than `head`, because the run prints a line of its own
  before the script's output.
- `{ all: true }` → everything at once (~176 KB of JSON)

## The JavaScript API

`three` is a global. So is `Vector3`. One line each; ask `get_api_docs` for
arguments and detail.

**Scene and objects**
`new three.Scene()` · `scene.add/remove` · `scene.unload()` ·
`scene.activate()` / `scene.dispose()` / `scene.isActive` for more than one ·
`scene.pick(x, y)` · `scene.raycast(origin, direction)` · `scene.export(path)`
writes a .glb · `new three.Group()` for belonging ·
`object.position/rotation/scale` · `object.visible` · `object.name` ·
`object.collides = false` takes one mesh out of the spatial index while it still
draws · `object.boundingBox()` world-space, `object.boundsInParent()` works
before `add()`.

**Loading** — `three.load(path)` reads a .glb/.gltf and is **synchronous**;
`asset.mesh(name)` gives a `MeshRef`, `.bounds` is a `Box3` read from the JSON
so it costs no upload. `three.inventory()` lists what's available under
`--assets`.

**Geometry** — `Box, Sphere, Plane, Cylinder, Cone, Torus, Convex, Terrain,
Ribbon` + `Geometry`. `geometry.bounds` measures it.

**Materials** — `MeshLambertMaterial`, `ShaderMaterial` (Slang fragment +
`material.uniforms.<name>`), `LayeredMaterial`. `mesh.color` and `mesh.variant`
are the per-instance knobs. A mesh with **no** material draws with whatever its
glTF material carried. `three.texture(path)`, `DataTexture`, `texture.read()`.

**Camera** — one camera, a **turntable**: `three.camera.orbit(yaw, pitch,
distance)`, `frameAll()`, `lookAt()`. Read-only accessors `yaw/pitch/distance/
fov/near/far`; `position()/forward()/right()` give world vectors;
`planarMove(fwd, strafe)` turns W/A/S/D into a world direction.
`three.camera.attach(object, { offset, distance, lag })` follows something —
`distance: 0` is first person. There is no `camera.position` to assign.

**Light** — up to four directional lights. `three.light` is the sun and
`three.lights` is the list; `three.lights[0] === three.light`. Each has
`direction`, `color` and `intensity`; `three.lights.add(direction, color,
intensity)` fills the next slot, `three.light.ambient` is the frame-wide floor.
Only the sun casts, and `three.light.shadow` is **off by default** and costs a
draw.

**Surfaces** — `material.reflectance` turns the specular highlight on (0 by
default — nothing has one until you ask; 0.5 is ordinary glass or wet stone),
`material.roughness` spreads it out, `material.metalness` moves a colour out of
the diffuse and into the highlight.

**The loop** — `three.setAnimationLoop(fn)` for drawing,
`three.setFixedLoop(fn)` for gameplay (60 Hz, same `dt` every call — put
gameplay here, not in an accumulator of your own). The clock is
`three.clock.dt / .time / .timeScale / .advance()`; `timeScale = 0` stops the
**world**, not just your arithmetic. `three.systems.add(name, fn)` is the
ordered registry when one callback isn't enough — it makes nothing faster, it
makes a slow frame attributable.

**Input** — `three.input.isDown/pressed(key)`, `three.input.keys()`,
`three.input.pointer`, `three.onKeyDown/onClick`, `three.controls.enabled`.
`three.input.press(key)` / `release()` let a **script** press keys, which is the
only way to exercise an input-driven scene headlessly.

**Queries and movement** — `three.query.sphere/box/raycastAll/sweep`. Every verb
has two forms: allocating (right for a one-off) and filling a
`three.query.buffer(n)` and answering with a count (right for a loop).
`three.moveAndSlide(position, motion, options)` is the character controller —
it takes a position and answers with a position, owns nothing, so gravity and
the jump stay yours. Pass the character's **Group** as `ignore` or it collides
with its own chest.

**Crowds** — `three.moveAndSlideAll`, `three.steer`, `field.sample` and
`three.batch(objects).flush()` each act on a whole column in one crossing.
Measured at 200 agents: 2.20 ms with the single verbs, 0.51 ms with these.

**Entities and rules** — `class Critter extends three.Entity`, with no
registration call beside it: the class registers itself on first use from
`static capacity` / `columns` / `parent` / `body` / `volume` / `collides`, and
`super()` is where a bare `new Critter()` is refused. `Critter.spawn(...)` is the
way in, `Critter.of(hit.object)` walks up to the instance, `c.remove()` is the
whole removal. `static columns = { position: 3 }` gives each instance a subarray
WINDOW over one shared array, so `three.steer(Critter.column('position'), ...)`
is handed the storage — nothing is gathered. Declare only what a bulk verb reads;
copying costs a flat 115–148 ns per entity, so columns are worth it in the low
thousands and not before. `Critter.on(event, matcher, fn)` is the rules half —
`enter`/`exit`, `touch`/`separate`, `click`, `near` with `{ within }`, or your own
through `three.emit(a, verb, b)` — dispatched SUBJECT FIRST, so the handler gets
`(critter, player)` in that order. `static volume = { shape: 'capsule', radius,
height, offset }` is an invisible kinematic body beside the drawn node, carried
by `<Class>.follow`; `static trigger` is the same with `trigger: true`. It is
what gives a player moved by `three.moveAndSlide` something to trip a trigger
with, and what a `near` rule measures against. `three.track(Class, options)` is
the same registration for a class that cannot extend.

**Terrain and navigation** — `TerrainGeometry` + `Field` (`field.fill/carve/
stroke/sample`), `three.scatter(options)` places a hundred trees,
`three.nav.bake(options)` **after** the level is built, then `three.nav.path`
and `three.nav.field`. A bake belongs to its scene — `scene.nav` is the one that
does, `three.nav` is whichever scene is active — so the next level's paths can be
solved before it is shown.

**Physics** — `three.physics.add(object, { shape, mass, kinematic, trigger })`;
`mass: 0` is static. Steer with `setVelocity`, push with `applyImpulse`.
`three.onTrigger/onContact`. Physics **owns the transform** of a body it holds.
The world belongs to its scene — `scene.physics` — so bodies for the next level
can be built early, but only the active scene's world is stepped.
`three.physics.joint(a, b, { limits })` bolts two bodies together and answers
with an id for `removeJoint`. A joint **is a list of limits** — glTF's
`KHR_physics_rigid_bodies` shape, so a limit out of a `.glb` passes straight in:
`{ linearAxes: [0,1,2] }, { angularAxes: [1,2] }` is a hinge about axis 0, and
**no range is a lock**. `axis` is axis 0; 1 and 2 are derived from it.
`type: 'fixed' | 'point' | 'hinge' | 'slider'` is shorthand for the four lists
people want, with `range: [min, max]` for the free axis. The joint is made
*where the bodies are*. `three.physics.soft(object, { mass })` simulates the
object's own vertices — no collider, its transform is the solver's, `pin`/`unpin`
and `points` are how a script reaches it, and it costs a draw call of its own.

**Post** — `three.setPost({ fragment, uniforms, textures })` runs one Slang
`float3 post(Post p)` over the finished frame; `three.addPass` chains them.

**Memory and measurement** — `three.stats()`, `three.unloadUnused()`,
`three.renderSize()`. Nothing is freed until you say so — a scene included:
`scene.dispose()`, and `stats().scenes` is how many are still resident.
`three.scenes` is the list behind that count (`{ id, active, held, nodes }`),
`three.sceneById(id)` gets a handle back onto one whose `Scene` object is gone,
and `three.disposeInactive()` frees every scene except the one being rendered
and sweeps afterwards. `stats()`'s four `...Bytes` beyond `textureBytes` —
`geometryBytes, targetBytes, postBytes, shadowBytes` — are where the memory
actually is. Neither `postBytes` nor `shadowBytes` falls when you clear the post
chain or turn shadows off: the images are kept for the next one, and the numbers
say so.

**The window** — `three.window.width/.height/.scale` in device pixels, and
`three.window.resize(w, h)` to ask for a different size. It moves the *window*
and not the picture: everything renders into an offscreen target fixed at what
`--width`/`--height` asked for at boot, so a bigger window is the same pixels
stretched and `renderSize()`, the screenshot PNG and `pick(x, y)` do not move.
Resizing past the render size says so in `warnings`. Zero and `false` under
`--headless`, and the size never reads back on Wayland.

**Math** — `three.clamp/smoothstep/pingpong/moveTowards/wrapAngle/mixColor/
damp/smoothDamp`, `three.seed(n)`/`three.hash`, `three.catmullRom`, `Vector3`,
`Random`.

## When the character stops

A screenshot cannot tell *standing on the summit* from *wedged against it* —
both are a character next to a platform, and both look correct. Two habits
close that gap, and reaching for them first is the difference between ten
minutes and an afternoon.

**`moveAndSlide` hands you the diagnosis, not just a position.** `r.grounded`
is whether it is standing, `r.ground` is *what* it is standing on, `r.hit` is
what stopped it, and `r.remaining` is the motion it could not spend. Name every
mesh you place and log `r.hit.name`: a character that will not climb its own
staircase prints `hit=summit`, which names the offending object outright and
turns "the movement is broken" into "that cap is too wide".

**Print, do not look.** A batch run that only writes a PNG every 300 frames
tells you nothing about the other 299. A trace system costs nothing and is the
whole debugging loop:

```js
let acc = 0;
three.systems.add('trace', dt => {
    acc += dt; if (acc < 4) return; acc = 0;
    console.log(`t=${three.clock.time.toFixed(0)}s at (${ctl.x.toFixed(1)}, `
        + `${ctl.y.toFixed(1)}, ${ctl.z.toFixed(1)}) grounded=${ctl.grounded} `
        + `on=${ctl.on} hit=${ctl.blocked}`);
}, { phase: 'fixed', order: 90 });
```

**Prefer two numbers next to each other to a jump arc.** A climb whose rise is
0.5 against a `moveAndSlide` `step` of 0.55 is walkable *by construction*. A
climb made of jumps is walkable only if the arc happens to land inside the
platform, and the arithmetic is worse than it looks: the apex is `v² / 2g`, and
for any height below it there are **two** horizontal distances that land there,
one on the way up and one on the way down. So "jump when you are close" lands
on the near edge, the far edge or neither, depending on the approach speed.
Step a route out from the previous element with a fixed rise and a fixed chord
and reachability stops being a thing to test for.

## Driving a scene with no keyboard

`--headless` has no keyboard, so `three.input.press(key)` is the only way to
exercise an input-driven scene in a batch run — and it is worth building the
level's own attract mode out of it, because then every headless run is a
playtest that says whether the level can still be finished.

A scripted press goes through the same path a real one does, so the scene
cannot tell them apart. Keep the set of keys you pressed yourself; a key that
is down and *not* in that set is a person taking the controls:

```js
const mine = new Set();
const press = k => { if (!mine.has(k)) { three.input.press(k); mine.add(k); } };
const lift  = k => { if (mine.has(k))  { three.input.release(k); mine.delete(k); } };

for (const k of ['w', 'a', 's', 'd', 'space'])
    if (three.input.isDown(k) && !mine.has(k)) auto = false;   // somebody is playing
```

An edge is once a **frame** and the fixed loop runs zero to eight times a
frame, so a key held across several fixed steps is still one `pressed()`. To
jump a second time you have to `release()` in between — hold for a step or two,
then let go. And drive movement through `three.camera.planarMove()` the way a
player does: aiming the camera at a target and holding `w` exercises the same
code path the human uses, where writing a velocity directly does not.

## Traps

These are the differences that actually break scripts.

- **`new three.Scene()` does not free the scene before it.** It makes a second
  world and shows it; the first keeps its objects, its bodies and its nav bake
  until you `dispose()` it. That is what lets you build the next level while the
  current one is on screen — `activate()` swaps, then `dispose()` the old one,
  then `three.unloadUnused()`. Only the active scene is drawn, queried and
  **stepped**, so bodies in a scene nobody is looking at stand still; a nav bake
  is the exception and works ahead of time. `stats().scenes` is the count a
  transition has to bring back down, `three.scenes` is the list it is made of,
  and `three.disposeInactive()` is the whole ritual minus the `activate()`. A
  scene built inside a `run_script` that has ended is still alive and no longer
  named by anything — that is the leak, and `three.scenes` is where you see it.
- **The look belongs to the scene.** `scene.background`, `three.lights` and
  `three.light.shadow` are the active scene's, and `activate()` brings back the
  ones that scene had — every light, not just the sun — so a level looks the way
  you left it. The camera is not:
  its attachment is dropped on a switch, because the follow named an object in
  the scene being left.
- **Handles go stale.** Unloading an asset frees its slot; naming an old handle
  throws at the `new three.Mesh()`. Load again for a fresh one.
- **Nothing is freed automatically.** No GC for resources — `scene.unload()` or
  `three.unloadUnused()`, and watch `stats().assets`. A material is the same:
  `material.dispose()` or it holds its pipeline forever, and `stats().materials`
  is the count.
- **`run_script` runs in its own function scope.** Use `globalThis` to keep
  state between calls.
- **The animation callback must be synchronous**, and is stopped *for good* if
  it throws or overruns 100 ms in one frame. What it logs arrives with the
  **next** `run_script`, tagged `[animation loop]`.
- **Measure, never guess.** A kit piece's origin is wherever its exporter left
  it. A size table typed into a script is the thing that goes stale and sinks
  pieces into walls — use `.bounds` / `boundingBox()`.
- **The camera is a turntable and read-only.** Assigning `yaw/pitch/distance`
  throws.
- **Colours are sRGB** and there is no colour management.
- **Every drawable mesh is collision geometry.** A pickup lying on a path is a
  bollard until you set `collides = false`; `stats().colliders` beside
  `stats().nodes` is how many meshes every sweep is testing.
- **Instancing is automatic.** Same asset reference = one draw call; there is no
  batching step to invoke and no way to write an unbatched scene.
- **Shadows are off by default**, there is one shadow map and **only
  `three.light` casts into it** — the other three lights light and do not shadow.
  Turning it on costs a second draw per caster.
- **Nothing is shiny until you say so.** `material.reflectance` is 0 on every
  material, so the specular term contributes exactly nothing; a surface that
  should read as wet, polished or glazed wants `reflectance = 0.5` and a
  `roughness` below 1. A `metalness` of 1 with no sky to reflect is dark, and
  correctly so.
- **A platform wider than the route beneath it is a lid.** Every drawable mesh
  is collision geometry, so a summit cap laid over the top of a spiral
  staircase seals it — and the picture shows a cap and a staircase, both
  exactly as designed. `r.hit` is what says which of the two is in the way.
- **A ledge exactly as tall as `step` is not climbable.** `step` is how high a
  ledge *may* be, so a 0.6 lip against a `step` of 0.55 is a dead stop that
  looks identical to a wall. Make the geometry flush — a cap whose top is level
  with the last stair — rather than making `step` generous, because a generous
  `step` climbs things that were meant to be walls.
- **The follow camera does not collide.** `three.camera.attach` puts the eye
  where `distance` and the orbit say, through whatever is in between, so
  standing on a platform can put the camera inside it and the character behind
  geometry. There is no occlusion pass; shorten `distance` yourself if it
  matters.
