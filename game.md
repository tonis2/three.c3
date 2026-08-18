# game.md — three.c3 as a game runtime

The plan for turning the agent tool into something a person can ship a game on,
without turning it into a different program. `plan.md` is the design this builds
on and every rule in it still applies; this document is the eight milestones
between here and a binary that boots a directory of JavaScript and glTF and
plays.

**The order is the one asked for**, and it is the right one: each milestone is
either useless or actively misleading before the one above it.

## The question this answers

	three --assets ./mygame

The binary reads the directory, evaluates `main.js`, and runs. `main.js` imports
its own modules, loads levels, plays animations, steps physics, and drives the
frame. Nobody writes C3 and nobody rebuilds anything.

And, because the two compose:

	three --assets ./mygame --mcp

the same running game answers `run_script` and `screenshot` while it plays. An
agent attaches to a live game, queries the scene it is actually rendering, tries
a change, looks at the result, and edits the `.js` on disk. **That loop is the
reason to build this**, more than the game engine is. Nothing else has it,
because nothing else has both halves already.

## What already exists, which is more than it looks like

The gap is not in the renderer. It is in lifecycle.

- **The frame loop is built.** `JsRuntime.tick` (`js/frame_loop.c3:107`) runs
  keyboard dispatch, then click dispatch, then the `setAnimationLoop` callback,
  then queued jobs. `main.c3:570` drives it, sleeps when nothing is animating,
  and wakes on an MCP request.
- **Input is built.** Held keys, key handlers, click-to-pick, hover, pointer,
  the whole of `event_loop.md`.
- **The scene is built and is in the right place.** Transforms, culling,
  bucketing, instancing, per-copy colour and variant are C3's. JavaScript pays
  only for what it changes, which is what makes a game in a non-JIT interpreter
  viable at all. **The refusal that made scenes fast is what keeps QuickJS off
  the hot path** — the JS never touches the data that would make it slow.
- **`collision.c3l` already contains a complete physics engine.** Not AABBs and
  a raycast — `PhysicsWorld`, `Rigidbody`, GJK/EPA narrowphase, a spatial-hash
  broadphase, XPBD constraint solving, joints, soft bodies, islands, sleeping,
  trigger and contact event streams, a worker pool, and deterministic
  `snapshot`/`restore`/`state_hash`. G5 is a **binding**, not an
  implementation, and that single fact reorders the cost of this whole document.
  It wants two changes of its own — an up-axis it does not have, and a
  `remove_body` nothing has needed until now — and both are small.
- **`gltf.c3l` already parses animation and skinning.** Channels, samplers,
  `Animation.duration`, `loop_time`, `clamp_time`, `find_skin_animations`, a
  16 KB `skinning.c3`, IK, and even `KHR_physics_rigid_bodies`. `scene/asset.c3`
  uses **none** of it — zero mentions of "animation". G3 and G4 are runtime
  work only.
- **`Asset.refs` already exists and already says what G2 is for**, in a comment
  written before anyone asked: *"dropping to zero does not unload yet, because
  unloading under two frames in flight needs the deferred delete queue and
  nothing asks for it before M6."* Something asks for it now.

## What the submodules have to do

Four of the eight milestones need a change in a library rather than in this
repository, and that is a different kind of work — a different repo, a different
test suite, and a change that other users of the library inherit. Collected here
so it can be scheduled rather than discovered:

| library | change | milestone |
|---|---|---|
| ~~`quickjs.c3l`~~ | a module loader — **done**, plus the nested-load fix it needed | G1 |
| `collision.c3l` | gravity-derived `impulse_dir`, and a ground **plane** instead of a `ground_plane_z` scalar, so the solver has no up-axis of its own | G5 |
| `collision.c3l` | `PhysicsWorld.remove_body` | G5 |
| ~~`image.c3l` / a `.ktx` library~~ | KTX2 — **done**, `lib/ktx.c3l` is in as of this plan | G6 |

Two are done. Of the two left, `collision.c3l`'s are both small and both have an
existing shape in the library to copy.

## The one thing that has to stay true

**An instance is still an immutable asset reference plus a transform, and JS
still may not touch vertices.** Nothing below relaxes it, and a game is the
workload it was written for: a fixed set of assets, many instances, transforms
changing every frame.

Two milestones press on it and both are answered rather than excused:

- **G4 (skinning)** is the one place "one draw per unique mesh" stops being
  free, because fifty skinned characters are fifty poses. The answer is a joint
  palette indexed by `SV_InstanceID` — still one draw — and `stats()` reporting
  skinned buckets distinctly so nobody reads `drawCalls: 1` and believes
  something untrue.
- **G5 (physics)** introduces a second writer of transforms. The answer is
  ownership, not arbitration; see G5/S6.

---

# G1 — the boot: `--assets <dir>` and `main.js` — **built**

The smallest milestone that makes the idea real. No new subsystems.

	three --assets ./mygame            play it
	three --assets ./mygame --mcp      play it, and answer tool calls while it plays
	three --assets ./mygame --screenshot a.png    boot, one frame, out

**All five steps are in.** `main.js` is evaluated as an ES module and its
imports resolve, confined to the assets directory; `--assets` composes with
`--mcp` in one loop and one process; a game's frames are warned about and
counted where an agent's are killed; and `three.inventory()` describes every
glTF in the directory without uploading one. Sixteen new tests, and the suite
is 290 and leak-clean under `--test-noleak`.

Four things are worth keeping in view:

- **The bug was in the shim, and a test found it before any game did.**
  `quickjs.c3l`'s loader first compiled straight out of the host's buffer, on
  the reasoning that the source is borrowed and compiled during the call. That
  is wrong: **module loads nest** — compiling a module resolves its own imports,
  which calls the host loader again — so a two-deep chain read the inner
  module's bytes as the outer one's tail. It surfaced as `SyntaxError: unexpected
  end of string`, from a line nobody wrote. The fix is a copy before compiling;
  the test that found it is a fake loader that answers every load out of one
  reused buffer, which is the only shape of fake that could have.
- **A module's top level is private, and an agent attaching discovers that.**
  `run_script` against a booted game cannot see `main.js`'s `const scene` —
  correct ESM, and initially surprising. Publishing a handle is the game's
  choice: `globalThis.game = { scene, rocks }`, and then an agent can drive it.
  Worth documenting for agents rather than "fixing".
- **Refused and missing are different sentences**, which was the point of
  resolving before loading. `cannot import '../outside.js' from 'main.js'` names
  the specifier *and* the importer; `could not load module 'nope.js'` names the
  resolved specifier. A resolver that clamped instead of refusing would have
  turned the first into the second.
- **One loop serves both modes**, and that was a smaller change than expected:
  `serve` became `live`, taking a port that may be zero and an assets root that
  may be empty. `--assets ./game --mcp` needs no arbitration at all, because the
  agent's `run_script` and the game's `setAnimationLoop` are already the two
  things `JsRuntime.tick` interleaves every frame.

## What was measured

A twelve-rock game in three files — `main.js` importing `props/rocks.js`
importing `../lib/spin.js` — booted, rendered, and spun: **1 draw call, 12
instances**, one `ConvexGeometry` shared. With `--mcp` attached, `run_script`
read `frame.running: true, ticks: 968` off the live loop, then scaled and
recoloured all twelve through the published handle and screenshotted the result
while it kept spinning.

A deliberately hitching game — 25 ms of busy-wait every tenth frame — reported
`ticks: 607, overruns: 60` and **kept running**, with one warning naming the
measured 24 ms against the 8 ms budget. Under the agent policy the same callback
is stopped at frame ten, which is the difference the two modes exist for.



## S1 — the mode (`src/main.c3`)

`--assets <dir>` beside the existing flags. Today a bare positional is
`opts.model` (`main.c3:150`); `--assets` is a *mode*, not a file, and the two
compose: `three --assets ./mygame --mcp` serves while it plays.

The directory is scanned once at boot. `.js` files are the program, `.glb` and
`.gltf` files are the inventory.

## S2 — the module loader (`lib/quickjs.c3l`)

**This is where the actual work is, and it is in the binding rather than here.**
`quickjs.c3l` exposes `EVAL_MODULE` (`src/quickjs.c3:46`) and the shim maps it
onto `JS_EVAL_TYPE_MODULE`, but nothing installs a module loader — no
`JS_SetModuleLoaderFunc` anywhere in `qjs_shim.c`, and quickjs-libc is not
linked. So `import './player.js'` compiles and dies at resolution.

Two callbacks: normalize and load, both calling back into C3 to read a file.

**Resolution is confined to the assets root.** A normalized path that escapes it
is refused. A game's `import` is not a general filesystem verb and should not
become one by accident — G8 is where the sandbox is widened, deliberately and
to one directory.

## S3 — two evaluation modes, and one global

`main.js` is a module. `run_script` stays what it is: an async function body,
textually wrapped (`js/runtime.c3:16`). They differ in eval type and that is
fine, because **`three` stays a global in both**. The prelude is `$embed`ed and
evaluates as global source; modules see globals; `import` is for the *user's*
code and nothing else.

**No synthetic `three` module.** `import three from 'three'` would be a second
name for one thing, which is the half-match `plan.md` §4 calls worse than a new
name. One way to reach the API.

## S4 — the frame policy

`JS_FRAME_BUDGET_MS` is 100 and an overrun stops the callback **for good**
(`frame_loop.c3:58`, `stop_frame`). That is exactly right for an agent — a
runaway loop must not wedge the tool surface — and exactly wrong for a game,
where one GC pause would permanently kill it.

So: a `FramePolicy` the boot mode selects.

| | agent (`--mcp` alone) | game (`--assets`) |
|---|---|---|
| soft budget | 100 ms | ~8 ms, warn once, keep going |
| hard wall | 100 ms, stop for good | 5 s, stop for good |
| overruns | — | counted, reported by `stats()` |

**The hard wall stays in game mode**, or a genuine infinite loop wedges the
window with no way to get a tool call in — and the attached agent is the only
thing that could diagnose it. The counter is what makes hitching *visible* to
that agent, which is the whole point of the two modes existing in one binary.

## S5 — the inventory (`src/scene/inventory.c3`)

`.glb` files described without being uploaded, which is what "read only as JSON
info, not actual buffers" asks for. `gltf.c3l`'s stream reader opens a document
without `load_all_buffers`, so names, mesh counts, node counts, bounds,
animation names and skin counts are all readable for the price of the JSON
chunk.

	three.inventory()
	// [{ path: 'kit/rock.glb', meshes: ['rock_a', 'rock_b'],
	//    animations: [], skins: 0, triangles: 1840 }]

**Separately valuable to agents**, which is why it is here rather than deferred:
"what is in this kit" is a question an agent asks constantly and currently
answers by uploading everything to find out.

## What G1 does not do

- **No hot reload.** A reload has to decide what happens to the live scene and
  its assets, and that is G2's question. G2 unlocks it; note it there.
- **No fixed timestep.** `event_loop.md` records this as deliberate and it stays
  deliberate until G5, which is where fixed-step gets its real answer.

---

# G2 — unloading: what turns a scene into levels

The only architecturally load-bearing item in this document.

`Assets.retain`/`release` (`scene/asset.c3:192`) move a counter and nothing
else. `Assets.free` frees everything, at shutdown. `new three.Scene()` empties
the host scene and leaves every upload resident. **Level 1 → level 2 → level 3
grows VRAM monotonically until the process exits.** Invisible to an agent poking
at one scene; fatal to a game.

## S1 — the asset handle gets a generation

Mirror `NodeId` exactly (`scene/node.c3:47`): an index and a generation, a
free-list of dead slots, the generation bumped on reuse so a stale handle is
*detectable* rather than silently valid. `Scene.create_slot` is the pattern,
already written and already proved at M2.

The widening is mostly internal: the prelude already wraps the bare int in an
`Asset` class (`prelude.js:662`), so JavaScript sees an object either way. Every
host verb that takes an asset index takes a generation with it.

## S2 — the refcount comes from the scene, not from JavaScript

`Scene.create_slot` retains, `Scene.kill` releases. `Asset.refs` starts meaning
something.

**The thesis is what makes this sound.** In Three.js you need explicit
`.dispose()` because anything can hold a hidden reference to a buffer. Here
nothing can — there is no accessor from an asset to its data — so *"referenced
by at least one live node"* is a complete answer rather than an optimistic one.
**The refusal that made scenes fast is the same refusal that makes unloading
safe.** That is worth writing into `plan.md` when this lands.

## S3 — the free is explicit, and deliberately not driven by GC

	scene.unload()          // drop this scene's nodes, free what nothing else holds
	three.unloadUnused()    // free every asset at zero refs

**Not a QuickJS finalizer.** A GC-driven free makes resident VRAM depend on when
the interpreter felt like collecting — nondeterminism this project has refused
everywhere else, and the worst possible property for the one number a game
watches. A level boundary is an explicit moment in a game; the free happens
there. An agent can call it too, which is how the effect gets *seen*.

## S4 — deferred destruction

`MAX_FRAMES_IN_FLIGHT` is 2 and the per-slot fences exist (`gpu/frame.c3:41`);
the deletion queue does not. A freed buffer is tagged with the frame counter and
destroyed when the GPU is two frames past it.

**Start with `vkDeviceWaitIdle` at the unload point instead.** A level
transition is already a stall, a full idle costs a frame or two of hitch, and it
is a fraction of the code. The queue is what mid-gameplay unloading needs, and
mid-gameplay unloading is not a G2 requirement. Build the simple one, leave the
queue to whatever first wants it.

## S5 — textures unload too

`Assets.textures` is deduplicated across files and reached by index from
`GpuMesh.texture`. Same problem one level down, same refcount, and it is the
half that actually moves the VRAM number — `texture_bytes()` already computes
it.

## S6 — `stats()` says so

Resident asset count and texture bytes, added to what `stats()` reports. **An
agent that can watch VRAM go back down is the only way anyone believes this
works.**

## What proves it

Load a level, unload it, load it again — a hundred times — and assert the
resident asset count, texture count and texture bytes return to exactly the
number they started at. That single cycle catches every leak this milestone can
have, and the bookkeeping half of it needs no GPU.

## What G2 unlocks

Hot reload. Once a scene can be dropped and its assets released, re-evaluating
`main.js` on a file change is a small addition — and combined with `--mcp` it
means an agent edits a `.js`, the game reloads, and the screenshot shows the
result. Worth doing immediately after, but not inside, this milestone.

## The `gltf.c3l` question

`GltfStream.close` already frees what it owns and the leak is not there. What
the library may want is the *opposite*: a way to keep a parsed document's JSON
around without its buffers, so G1's inventory does not reopen files. Small, and
only if the inventory turns out to be hot.

---

# G3 — glTF node animation

Cheap in principle, and carrying one hidden cost that has to be found now rather
than in week three.

## The hidden cost, stated first

**`Assets.load` flattens.** It produces a flat `List{GpuMesh}` and discards the
glTF node hierarchy entirely (`scene/asset.c3:247`); JavaScript places each mesh
itself. But **animation channels target glTF nodes**, and three.c3 does not keep
them.

So G3's first real step is not sampling. It is:

- recording the glTF node tree on the `Asset` (parents, TRS, mesh bindings),
- and giving JS a way to instantiate it as a node subtree — Three.js's
  `gltf.scene`, roughly `asset.instantiate()`.

That is a genuinely useful feature on its own — a loaded prop with a hierarchy
currently arrives as loose meshes — but it is a bigger job than "sample a
channel and call `set_position`", and it belongs to G3 rather than to whoever
discovers it.

## The second cost: rotation is a quaternion

`Node.rotation` is a `Vec3` euler. glTF rotation channels are **quaternions**.
Converting quat→euler per frame is lossy, gimbal-locked, and produces the class
of bug that looks like "the arm flips once per cycle". `Node` needs to carry a
quaternion, or an animated node needs a separate rotation path.

**This is arguably a prerequisite, not a step**, and the cheapest place to do it
is inside G2's slot rework, where `create_slot` is already being touched.

## S1 — the animation data (`src/scene/animation.c3`)

Channels and samplers read at load and stored per asset. `gltf.c3l` supplies
`Animation.duration`, `loop_time`, `clamp_time` and `find_animation` already.

## S2 — the player is per instance

Two copies of the same tree must be able to wave at different phases, so the
player lives beside the node, not on the asset. **This is the first per-instance
state that is not a transform**, and worth noting as such — it is a new kind of
thing in the scene model.

## S3 — stepping, and the sleep condition

The step happens in the host frame, before the animation callback, so a callback
can read the result and so animation runs with no `setAnimationLoop` registered
at all.

**Which means `main.c3`'s sleep condition has to know about it.**

	quiet = presented && !runtime.is_animating() && !camera_moved && handled == 0;

Every term there is something that would be lost by sleeping through it
(`event_loop.md`, part five). A playing animation is now another one, or the
window sleeps in the middle of a walk cycle. One term, easy to miss, impossible
to debug from a screenshot.

## S4 — the JS surface

	mesh.animations            // ['Idle', 'Walk', 'Run']
	mesh.play('Walk', { loop: true, speed: 1 })
	mesh.stop()

**Not `AnimationMixer`.** Three.js's mixer/clip/action trio earns its complexity
on crossfading, and crossfading is worth doing when something wants it — after
G4, where blending between clips is what makes a character look right. A
deliberate simplification, said out loud, rather than a partial mixer that
answers to the same name.

---

# G4 — skinning

The one milestone that changes the draw model. Everything it needs on the parse
side is in `gltf.c3l/src/skinning.c3` already.

## S1 — joints reach the shader

Joint indices and weights are two more BDA streams; `has_skin` joins
`has_normals` and `has_uvs` in the push block; `shaders/mesh.slang` gets the
skinned branch.

## S2 — the palette keeps the instanced draw

Fifty rocks share one instanced draw. Fifty skinned characters are fifty poses
and cannot — *unless* the joint matrices live in a device buffer indexed by
`SV_InstanceID`, which keeps them in one draw at the cost of uploading the
palette every frame.

A 60-joint rig across 50 instances is 60 × 50 × 64 bytes ≈ **192 KB per frame**.
That is affordable, and it is the option that keeps the thesis's shape rather
than the one that quietly abandons it.

## S3 — `stats()` must not lie

A skinned bucket costs per-frame upload that an instanced bucket does not.
Reporting them identically would tell an agent that fifty characters and fifty
rocks cost the same, and it would then build the scene that proves otherwise.
Skinned buckets are reported distinctly.

## S4 — picking hits the bind pose, and says so

A skinned mesh's `TriBVH` is stale the moment it moves, and rebuilding a BVH per
frame per character is not happening. **Skinned meshes get an AABB proxy for
picking**, documented as such. A raycast that silently answers about a pose the
character left two seconds ago is worse than one that answers about a box.

---

# G5 — the physics world

**The engine is already written.** `lib/collision.c3l/src/solver/` is XPBD with
GJK/EPA, spatial hashing, islands, sleeping, joints, soft bodies, trigger and
contact events, and a worker pool, entered through
`PhysicsWorld.run_step(time, step_count, sub_steps)`. This milestone is a
binding and a set of decisions, not a solver.

## S1 — one world, stepped in the host, at a fixed rate

The world is host state, stepped in `tick` before the animation callback, with
an accumulator **in C3 rather than in JavaScript**.

That is the answer to `event_loop.md`'s "no fixed timestep, no interpolation":
**physics is fixed-step, the frame callback stays variable-rate, and the two
never argue.** An accumulator written in JS would run inside the frame budget,
and a spiral of death would trip the budget rather than merely stutter.

## S2 — the up-axis, made configurable in the library

**The library's own comment overstates this**, and measuring it changed the
plan. `resolver.c3:292` says:

	// Library convention is z-up: soft-body ground plane, impulse_dir and the
	// specialized capsule tests all assume gravity along -z.

The last clause is **stale**. `shapes.c3:61` and `:70` define the cylinder and
capsule with their axis along **+Y**, and the specialized capsule-vs-triangle
test builds its endpoints at `{0, ±half, 0}` (`resolver.c3:2376`) and then
rotates them by the collider's own orientation — so it is Y-axis geometry and
orientation-agnostic besides. That sentence is the one thing most likely to talk
somebody out of this change, so fixing it is part of the work.

The real Z-up surface is three places:

1. **`DEFAULT_PHYSICS_WORLD.gravity = {0, 0, -9.8}`** (`resolver.c3:295`) — a
   default, not an assumption.
2. **`impulse_dir`** (`resolver.c3:342`) —
   `(self.gravity * body.gravity_factor).z > 0 ? 1 : -1`, a ±1 sign applied to
   angular joint limit axes (`joint.c3:134`). It reads only `.z`. Given Y-up
   gravity it evaluates to `-1` — **the same value the Z-down default
   produces** — so it is accidentally correct today and wrong in principle. It
   would only diverge under inverted gravity.
3. **`SoftBody.generate_ground_collisions`** (`softbody.c3:1028`) — tests
   `p.z < ground_z` and builds the contact at `{p.x, p.y, ground_z}`. This is
   the only place that is genuinely broken by Y-up gravity, and it is
   **soft-body only**, which G5 does not need in its first version.

## S2a — the change: axis-agnostic, not parameterized

An `up_axis` enum would make the library ask a question it does not need to ask.
Two edits remove the concept instead:

- **`impulse_dir` derives from the gravity direction**, not from one component
  of it. The quantity it wants is a sign along gravity; taking it from `.z`
  is that quantity written down for one orientation.
- **The ground plane becomes a plane** — a normal and an offset — rather than a
  `ground_plane_z` scalar. Strictly more general, costs nothing at the call
  site, and lets a soft body rest on a slope, which the scalar never could.

**The default stays `{0, 0, -9.8}`**, so every existing user of the library is
unaffected and nothing outside three.c3 has to change. three.c3 sets
`gravity = {0, -9.8, 0}` at boot and **no swizzle exists anywhere** — the
boundary conversion the earlier draft of this plan called for is not needed and
should not be built. A conversion at the seam would have meant two conventions
meeting in exactly the two functions nobody reads twice.

## S2b — what proves it

**The library's existing suite runs unchanged with gravity rotated to Y-up.**
A physics test that passes at one orientation and not another is testing the
orientation rather than the physics, and this is the cheapest possible way to
find out which ones do. Any test that fails under rotation is a test to fix, not
a reason to keep the axis.

## S3 — the JS surface

	mesh.body = { shape: 'box' | 'sphere' | 'capsule' | 'hull',
	              mass: 1, friction: 0.5, restitution: 0.2, kinematic: false }
	three.physics.add(mesh)
	three.physics.remove(mesh)
	three.physics.gravity = [0, -9.8, 0]     // Y-up, set once at boot, no conversion

## S4 — the collider comes from the asset, and the hull is already free

A `hull` collider is `collision::quickhull` over the mesh's positions — which is
**exactly what `ConvexGeometry` already does**. So a `ConvexGeometry` rock's
collider is its own geometry, computed by the same function, and is exact rather
than approximate. A pleasing symmetry, and one fewer code path.

## S5 — `remove_body`, added to the library

`PhysicsWorld` has `remove_softbody` and no rigid-body equivalent. `bodies` is a
`LinkedHashMap{sz, Rigidbody}`, so the storage supports removal; nothing exposes
it, and removal is not a one-line delete. It has to clear the body from:

- the **spatial hash** (`spatial_map`), or a dead id keeps producing broadphase
  pairs;
- the **island union-find** (`island_parent`), and mark `islands_dirty` — an
  island that loses a member may split, and a stale parent chain silently keeps
  two groups solving together;
- the **active trigger set** and **active contact set**, which are the state
  behind `TriggerEvent` and `ContactEvent`. A body removed while overlapping
  must emit its EXIT events, or a game's `onTriggerExit` never fires for
  anything destroyed inside a trigger — a bug that looks like a gameplay bug
  for a long time before anyone suspects the solver;
- any **joint** referencing it (`joints`, `constraints`), which otherwise
  dereferences a body id that is gone.

**This is a decided library change, not a discovered one**, and it is required
rather than nice — the milestone as asked for is "let the JS API add *and
remove* collision objects", and the removal half is the half that isn't written.

Worth writing the test as a cycle for the same reason G2's is a cycle: add a
hundred bodies, remove them all, assert the world's body count, island map,
spatial hash and both overlap sets return to empty. A leak in any of those four
is invisible until a long-running game slows down for no reason.

## S6 — ownership, not arbitration

The camera resolves a script and a drag by last-writer-wins
(`event_loop.md`, M5c), and that is right there because both are describing the
same intent. **It is wrong here.** A solver and a script both writing a
transform every frame produces jitter, not a compromise.

So: a body-backed node's position and rotation are **owned by the solver**. A JS
write to a dynamic body's transform is refused with a sentence saying why. A
kinematic body is driven through `set_kinematic_target`, which already exists
and is what "I want to move this myself" actually means.

## S7 — events reuse the handler machinery

`TriggerEvent` and `ContactEvent` lists are already produced. Drain them in
`tick` and dispatch exactly as `onKeyDown` does — same registration shape, same
"a handler that throws is stopped for good" policy, same frame log.

## S8 — the threading note

`plan.md`'s design rests on handlers, scene and device all being touched from
one thread, so nothing needs a lock. `worker_pool.c3` is the first thing that
could break it. The pool must be confined to the inside of `run_step` and joined
before it returns; if that is not already true, running the solver
single-threaded is the correct first version.

## S9 — determinism, which nobody asked for and is worth naming

`PhysicsWorld` has `state_hash`, `snapshot` and `restore`. That is replay and
lockstep networking, later. It is also, right now, **a new agent affordance**:
snapshot, run two hundred frames, look at the screenshot, restore, try
something else. "What if" as a tool call. Nothing here builds it; it should be
on the record that the capability arrives free with this milestone.

---

# G6 — async load, images, and a sky

Two things wearing one coat, and the plan should say so.

## S1 — `three.loadAsync(path)`

A real promise, resolved from the job queue `drain_frame_jobs`
(`frame_loop.c3:257`) already drains — the machinery for "finish this on the
frame thread" exists because the frame loop needed it. Upload on a transfer
queue; the parse is the expensive half and can be off-thread.

Today `three.load` blocks, which means a mid-game level load is a hitch of
however long the `.glb` takes.

## S2 — `three.texture(path)`

PNG and JPEG through `image.c3l`, uploaded down the same path a glTF texture
takes. Small.

## S3 — the sky is a render feature, not a loader

A cubemap or an equirect, a pipeline that draws at far depth with depth-write
off, and — if it is to light anything rather than just sit behind it — an
environment term in the shader. **Loading an image and rendering a skybox are
two different milestones**, and bundling them under "image loading" is how the
second one gets underestimated.

## S4 — the format problem, and the `.ktx` library that answers it

**`image.c3l` decodes PNG and JPEG. That is all** — no HDR, no EXR, and no
KTX2, which M1 already recorded as undecodable and worked around by rendering a
141-mesh terrain untextured with one warning.

**`lib/ktx.c3l` is in as of this plan**, ahead of the milestone that uses it, and
`test/ktx_test.c3` holds it to compiling and linking so it does not rot before
G6 arrives. What it brings:

- **`ktx::container`** — `read_file`, `Texture.image(level, layer, face)`,
  `level_width`/`level_height`, `layers()`, key/value metadata. **Faces**, which
  is a cubemap: the sky's container problem is solved rather than pending.
- **`ktx::basis`, `uastc`, `etc1s`, `bc7`, `bcn`** — transcoding, in pure C3.
  So a Basis-compressed texture becomes BC7 on the device rather than being
  expanded to RGBA8, which is the difference between a game's texture budget and
  a demo's.
- **`ktx::vk`** — the VkFormat table and block-size arithmetic, which is exactly
  what `gpu/texture.c3` needs to upload a compressed image it did not decode.
- **`ktx::mipgen`** — mip chains, which nothing in this project generates today.

Three things about it worth having in the plan:

- **It retroactively fixes M1's gap.** `KHR_texture_basisu` is common in shipped
  glTF and every such file currently loads with its textures missing. That is an
  existing limitation removed as a side effect, which changes this milestone's
  value from "skyboxes" to "shipped assets work" — and makes a case for doing the
  glTF half of it early, out of order, since it is independent of the sky.
- **It needs no staging step**, unlike `slang.c3l`: `libzstd.a` is checked in per
  target and reached through the library's own `linklib-dir`. And it needs no
  `--recursive`: its getopt and image submodules belong to a CLI its manifest
  deliberately excludes.
- **`ktx::vk` collides with `vk`.** ktx's format table and vulkan.c3l's binding
  want the same name. Fully qualified at the call site, and noted in
  `project.json` where the dependency is.

So the sequencing is: **the sky waits, but the glTF textures do not.** Building
an LDR-PNG cubemap in the meantime would be a wasted path — replaced rather than
extended, since the pipeline differs in format, mip handling and whether the
shader treats it as radiance — but decoding `KHR_texture_basisu` into the
existing texture path is a small, self-contained job that could land any time
after G1.

---

# G7 — UI and text

Last of the real features, because there is already a UI rendering library to
bind rather than write. Three decisions decide whether the binding is pleasant.

## S1 — where it draws

After the scene, into the same offscreen target, before the blit — so
`--screenshot` and the MCP `screenshot` capture the UI too. **An agent that
cannot see the HUD it just built cannot correct it**, which is the second thesis
and applies here exactly as it applies to the scene.

## S2 — input arbitration is the whole difficulty

A click on a button must not also shoot the gun. The UI gets the pointer first
and marks the event consumed; `onClick` and `scene.pick` see only what is left.
`MouseTracker`'s edge machinery in `scene/input.c3` is where the flag belongs —
it is already the thing that decides what a click *is*.

## S3 — retained or immediate

Immediate-mode costs a full UI rebuild in JavaScript every frame, inside the
frame budget G1/S4 sets. Retained-mode is a second scene graph with a second
lifetime problem.

Follow whatever the library already is, and if it is immediate, measure the
per-frame cost against the 8 ms soft budget before building a game on it. Text
needs a font atlas, which is a texture, which is a path that already exists.

---

# G8 — audio, saving, and the rest

The least important and the most likely to be what someone actually complains
about.

- **Audio.** A new dependency and a new thread. `three.sound(path)`, `play`,
  `stop`, volume. Positional audio needs the camera every frame, which is a
  cheap addition to `tick` and a reason to do it after G5 rather than before.
- **Saving.** Today JavaScript cannot touch the disk at all except through
  `three.load(path)`. A save file needs a write verb, and **this is the one
  place in the whole plan where the sandbox widens on purpose** — confined to a
  single state directory, never to the assets root, never to an arbitrary path.
  Say it in the doc comment so nobody later relaxes it as an obvious
  convenience.
- **Timers, RNG seeding, `structuredClone`,** and whatever else turns out to be
  missing when someone writes a real game and hits it.

---

# What is deliberately absent

- **No `BufferGeometry`, still.** Nothing in eight milestones needs one, and a
  game is the workload that would be worst served by it.
- **No ECS.** The scene graph is the entity list and a game's components are
  JavaScript objects keyed by node id. Building an entity system in C3 would be
  building the part JavaScript is good at.
- **No editor.** The MCP surface is the editor, and it is better than one.
- **No networking.** G5 makes lockstep *possible* — `state_hash` and
  `snapshot`/`restore` are the hard parts and they exist — and nothing here
  builds it.
- **No render graph, no deferred path, no post-processing stack.**
- **No shadows**, which is the absence most likely to be regretted; see below.

# Open questions

- **Shadows.** Not on the list and not obviously wrong to omit, but a game
  without them looks flat in a way no amount of material work fixes. A single
  directional shadow map is the cheapest thing that would change how every
  screenshot in this project looks. Worth a decision, probably between G4 and
  G5.
- **`Node.rotation` as a quaternion.** Written under G3, but the cheapest place
  to do it is inside G2. Decide when G2 starts, not when G3 does.
- **Hot reload semantics.** What happens to a running `setAnimationLoop`, to
  live physics bodies, to the camera. G2 unlocks it; somebody has to say what it
  means.
- **What `main.js` and `run_script` share.** They share globals by design (G1/S3)
  — so what happens when an agent's script redefines something the game holds a
  reference to? Probably nothing good, and probably acceptable, but it should be
  a known answer rather than a discovered one.

# Verification

The house standard applies unchanged: headless tests, GPU-free where the logic
allows, leak-clean under both `c3c test --trust=full` and `--test-noleak`, and
every milestone's claims re-proved by injecting the bug the test says it catches.

Three checks matter more than the rest and should be written before the code
they check:

1. **G2's cycle.** Load, unload, reload, a hundred times; resident assets,
   resident textures and texture bytes all return to their starting values.
   Catches every leak the milestone can have.
2. **G4's honesty.** `stats()` reports skinned and instanced buckets
   differently, asserted against a scene containing both — because the failure
   mode here is a number that is wrong rather than a picture that is.
3. **G5's determinism.** Two `PhysicsWorld`s given the same inputs produce the
   same `state_hash` after N steps, and a `snapshot`/`restore` round trip
   reproduces it. The library supplies the mechanism; the binding is what could
   break it, by stepping at a rate that depends on the frame.
