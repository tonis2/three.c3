# three.c3 — what is left

This file is the whole plan. Everything it used to contain about work that is
finished has been deleted, because a plan that describes what already happened
is a document nobody can tell the live parts out of.

**That deletion is a habit, not a one-off event.** The rule is: **when an entry
stops being a decision anybody still has to make, it belongs in history.**
`git log -p -- plan.md` is where every swept entry went.

Three sweeps so far. The first took out the milestone-by-milestone account of
the texture work, the light binding, the physics bindings and the post chain.
The most recent took out everything that had become a description of *built*
code — the skinning design, the pass system's counting and driver measurements,
the material-layer and export and draw-buffer accounts, and the record of what
§9's answered questions cost to answer. What survives a sweep is exactly three
kinds of thing: **work that is not done**, **a decision that constrains work
that is not done**, and **a trap that will cost somebody a session**. A section
whose whole content is "this was built and here is how" is a section that has
moved into the source and into git.

**So a section may be one line long, and several are.** The number is kept even
when the content is nearly gone, because source comments cite these by number —
§4's half-match rule, §12's specular decision, §15's draw record — and
renumbering would break fifty citations to tidy a table of contents.

**The source still cites them by name, and that is on purpose.** Fifty-odd doc
comments carry references like `game.md` G5/S3, `event_loop.md`, `m3_stage.md`
and `base_stage.md` — `git show` above resolves every one, and rewriting fifty
comments to say "see git" would trade a precise citation for a vague one.
`base_stage.md` was already only in history before this file was rewritten, so
the pattern predates the deletion rather than being introduced by it.

	git grep -n 'game\.md' -- src test        # find them all

---

## Where this stands

A window, a Vulkan device, an offscreen target and an exact screenshot. A scene
graph with one instanced draw per unique `(asset, mesh, material)`. QuickJS with
a Three.js-shaped API in `src/js/prelude/` and three MCP tools over it. Slang
compiled at runtime and cached. Picking, parametric shapes, glTF in and out,
physics, animation, skinning, one directional light with a shadow, a post chain,
material layers, and a mouse and keyboard a script can read and a scene can take
away from the camera. The camera follows things now — third person, and first
person as a boom of zero length. And there is a clock: game time, a scale that
zero means paused, a step for a stopped one, and a fixed-rate loop under it.

A post body reads depth in world units and may name a third source; a merged kit
comes apart into its pieces; a hull wears a texture; a uniform table larger than
the push block moves to a buffer on its own; a `.glb`'s normal, emissive,
occlusion and alpha mode reach the script; and nothing stalls the device to
unload any more.

**That paragraph is as much inventory as this file keeps.** What each of those
does is in its own source file, and `git log -p -- plan.md` has the milestone
accounts that used to be here.

	c3c test --trust=full       721 passed, 0 failed, leak-clean

**The thesis, which no milestone below may quietly abandon:** a script describes
shapes and never touches a vertex, and every copy of one shape sharing one
material is one draw call. Two named channels vary per copy — `color` and
`variant` — and nothing else. When a milestone cannot hold that, it says so out
loud and argues for the exception; it does not just stop being true.

---

## 1. Defects in built code

Small, known, and each one is a number or a picture that lies rather than a
missing feature. Worth clearing before anything on the feature list, because
every one of them is something a person will trust and be wrong about.

- **Linux and Windows compile and have never been run.** Both backends
  type-check; neither has had a window on screen since any of the mouse, cursor
  and DPI work. That catches the failure a blind port actually has — a missing
  symbol — and it catches none of the ones that matter: a wrong sign, an event
  that never arrives, a DPI declaration fighting something else in the process.
  §17 added two more readings to that blind surface — `get_scroll_x`, and the
  right and middle latches — and a wrong sign in either is exactly the class of
  fault this entry says compiling cannot find.

- **`WM_DPICHANGED` is not handled** (win32). The awareness context requested is
  per-monitor, so a window dragged between displays of different densities keeps
  the size it was given. The parts that read the scale every frame — the cursor,
  a pan — follow the new display correctly; the window's own size does not.

- **`Window.width`/`height` go stale on Linux.** `getMousePos` flips y against
  them and they are only ever what `new` was asked for, so a resized window
  reports a cursor offset vertically by however much it grew. The win32 backend
  reads `GetClientRect` for exactly this; x11 and wayland could ask their own
  equivalents. Not fixed because it cannot be seen from this machine.

  **`pointer.dy` is almost immune to it, which is worth knowing before somebody
  "fixes" the delta instead.** The offset is constant for a given window size and
  a difference cancels it, so a look is straight even while every reported
  position is wrong. What does not cancel is the frame the resize lands on: the
  offset changes between two readings and the delta carries the whole change as
  one enormous mouse movement. The same is true on every platform for the
  window→image mapping: `WindowView` divides by the swapchain extent, which
  tracks a live resize, so a still cursor maps to a moving image pixel for as
  long as the drag lasts — a spurious movement *every frame of the drag*, not
  one per resize. A mouse-look script polling `dx` turns the camera while
  somebody resizes the window. Derived from the mapping rather than seen on
  screen, and the arithmetic is short enough to check: a cursor at window x=400
  is image x=400 in an 800-wide window and image x=320 once the window is 1000
  wide, so eighty pixels of movement are reported for a hand that did not move.

  **Not fixed, and the fix has a cost worth naming.** `MouseTracker` would have
  to be told that the mapping changed, and it deliberately knows nothing about
  extents — which is what makes it testable with six numbers and no window. So
  either the tracker grows a dependency on `WindowView`, or `main.c3` grows the
  comparison, and `main.c3` is the one file with no checks in it. **Trigger:**
  the first first-person camera, which is what pointer lock is waiting on too.
  Both are about a look that stays honest, and they should be answered together
  rather than one at a time.

- **`ExportBatch` keys on `(asset, mesh)` alone**, so sibling nodes drawing one
  shape with different materials collapse into a single instanced glTF node
  wearing the *first* member's material — its texture, and since blending
  landed, its `alphaMode` too. A wall and a window cut from one pane mesh
  export as two copies of whichever came first, which is the same shape of bug
  the old `texture_slot` collapse was: an export that looks right in the count
  and wrong in the viewer. The fix is the material joining the batch key, which
  splits the instanced node exactly where the frame's own buckets already
  split. Surfaced by the blending work, not caused by it.

---

## 2. Deferred by design, and what would undefer it

Each of these was a decision, not an oversight. The trigger is written down so
the decision can be revisited on evidence rather than on somebody's mood.

**Nine of them have since been built**, and each is kept here as a `*(Built: …)*`
paragraph rather than deleted, because the argument for the deferral is what
makes the shape of the answer readable — and in one case (the driver's pipeline
cache) the measurement says the deferral was right and the thing was built
anyway.

*(Built: the deletion queue carries buffers and images as well as pipelines —
`gpu/retire.c3` has the one verb and the argument for why it is not a tagged
union. `Assets.unload_unused`, every texture whose last reference goes when a
map is replaced, a shadow map resized mid-play and a post chain resized on a
window drag all went from `vkDeviceWaitIdle` to a list push. What still stalls is
teardown and the swapchain, which has to.)*

- **A material nobody disposes is still immortal**, exactly as a texture nobody
  disposes is. `material.dispose()` gives back the handle's reference and the
  collector takes the material once no node names it either, so the mechanism is
  there and an agent's loop is bounded the moment it uses it — but a script that
  never calls it still accumulates one pipeline per distinct shader source.
  Three.js has the same property and the same verb, and the alternative here is
  a `FinalizationRegistry` hooking QuickJS's GC, which would free GPU objects at
  a moment nothing chose and on a schedule nothing can assert on. **Trigger:**
  evidence that scripts in practice do not dispose — at which point the answer
  is probably a warning naming the count, not a finalizer.

*(Built: a uniform table past the 104-byte push budget moves into a device
buffer behind a pointer in the block, so the ceiling is `MATERIAL_TABLE_BUDGET`
— 256 KiB, thousands of rows — rather than six rows of four floats. The **plain**
uniforms stay in the push block, which is what keeps `set_uniform` a memcpy with
nothing to invalidate; only the array columns move, and the body cannot tell
which shape it got. Slang reflects the pointee's offsets, so nothing computes a
layout: `shader/reflect.c3` follows exactly one pointer and `ShaderField.indirect`
is what comes back. The buffer is per frame in flight and refilled at `prepare`,
for the instance array's reason.

A bug worth keeping: the shader **disk** cache stored a push field's name, offset
and size and not `indirect`, so a warm cache came back with a spilled table's
uniforms unnamed. Format version 3, and `a_table_costs_a_row_at_a_time` compiles
twice through the cached door to pin it.)*

*(Built: `scene/split.c3` and `ref.split()`. Connected components over the
triangles — two are in the same piece when they share a vertex, which is right
because a merged kit is merged by *concatenation* — then `upload_built` per
component, through `Assets.read_geometry` so the streams come back exact rather
than through the picking tree. A mesh that is one connected surface answers with
itself and uploads nothing, which is a correctness short-circuit as much as a
saving. Measured on a real pack: `farm_animals.glb` is one primitive and comes
apart into 35 — four animals and the eyes, horns and hooves that were modelled
as separate shells. A piece inherits the source's colour and base colour map and
holds its own reference; a mesh with a layer stack is refused rather than split
into pieces that lost it.)*

*(Built, as a **record** rather than as a material — `GpuMaterial` in
`scene/asset.c3`, `ref.material` on the JS side. The four that were dropped are
loaded with their colourspaces right: normal, occlusion and metallic-roughness
are data and go in `LINEAR`, emissive is a colour and goes in `SRGB`, and the
decode memo was already keyed on `(image, space)`. What it deliberately is not is
a `Material`, because "what a glTF material becomes on this side" is still the
modelling decision this entry named and it still belongs with PBR; what crosses
is what the file said, and the script decides.

`asset.instantiate({ materials: true })` is one answer to that decision, written
down where it is made: normal map to `normal`, emissive to a zero-opacity layer,
`alphaMode` to `transparent`, `doubleSided` to `side`. Occlusion and
metallic-roughness are carried and not applied — §12's specular term is what a
roughness value would feed, and there is no specular term.)*

*(Built: every face gets its own planar projection along its own normal, in the
mesh's local space, at one uv unit per unit. Not an unwrap — the reason there is
no unwrap of an arbitrary hull is unchanged — but an isometry per facet, so
nothing stretches, a texture is the same size on a hull as on a box beside it,
and two coplanar faces tile continuously because the projection is of the
*position*. The only artefact is that facets meeting at a crease do not line up
along the shared edge, which is invisible on the noise and grain a rock wants and
visible on a regular pattern. Triplanar was the alternative and is this with a
three-way blend on top, at the cost of a branch in every mesh in the project.)*

*(Built, and answered once with the entry above rather than twice: `alphaMode`
and `alphaCutoff` are on the material record, `ref.material.alphaMode` reads them,
and `instantiate({ materials: true })` is what turns BLEND into a transparent
material. `the_alpha_mode_survives_the_round_trip` is the check, and it asserts
both halves separately — the mode crossing and the mode being acted on — because
only the second one is what made a `.glb` render opaque.)*

*(Built, and **it buys nothing on this machine** — which is written down rather
than quietly dropped. `gpu/driver_cache.c3` is the second binary format the entry
described, with its own header, its own version and the identity the spec
actually names: a blob is only handed to `vkCreatePipelineCache` if this device's
`vendorID`, `deviceID`, `driverVersion` and `pipelineCacheUUID` all match what
wrote it. Measured warm against cold with the Slang half already cached:
`examples/chain.js` 0.21 s either way, `examples/village.js` 0.61–0.68 against
0.62–0.64. MoltenVK does not pay for pipeline creation the way the entry assumed
a driver does — the expensive part is upstream, in the half the shader cache
already keeps. It stays because it is where a desktop driver would need it and
because it costs one read at startup and usually no write at all: MoltenVK's
serialization is not byte-stable, so `save` writes on **growth** rather than on
difference, which converges after two runs instead of rewriting 300 KB forever.)*

*(Built: `slang::build_tag()` — `spGetBuildTagString`, which the binding did not
expose and now does. It reports `2026.12.2` here, is hashed into the cache
filename and written into the file as checked identity, and costs one call
returning a pointer to static storage rather than the 35 MB of reading that
hashing `libslang.dylib` would have. So an SDK upgrade moves every key instead of
shadowing it. What it cannot see is two *untagged* compiler builds, which report
the same string; `SHADER_CACHE_FORMAT_VERSION` is still the lever for that.)*

*(Built, for the third source and not for the downsampled one.
`three.addPass({ fragment, reads: earlierPass })` binds that pass's output as
`tap`, and naming a pass is what makes its output survive: it is given an image
of its own instead of a ping-pong slot, which `PostPass.output_of` decides and is
the whole cost. Still one index rather than an edge list, so adjacency plus the
tapped set is still the barrier derivation and §13's "why not a render graph"
stands. A body that reads `p.tap` having named nothing gets image A — the same
answer `p.scene` gives — because the template fills the field for every body and
reflection cannot tell "reads it" from "does not". **Still not covered:**
downsampled intermediates, which need P0/P1 to become a pool keyed by extent, and
MRT.)*

*(Built, for depth, with the instruction this entry gave: `p.depth` is world
units along the view direction, near-plane distance on the closest thing drawn
and far-plane distance on a pixel nothing was drawn into, and the reconstruction
ships with it rather than the raw buffer. The camera's planes reach the shader as
8 bytes of push block — the post uniform budget went 112 → 104 — and the depth
attachment goes to `DEPTH_STENCIL_READ_ONLY_OPTIMAL` once per frame, beside image
A's barrier, with no barrier back because the next frame's geometry pass opens it
from `UNDEFINED`. Sampled nearest, because `D32_SFLOAT` is not required to filter
and a filtered depth is meaningless at a silhouette anyway. **Still not there:**
normals and motion vectors.)*

- **A stale asset handle is refused at `add()`, not at `new three.Mesh()`.** The
  constructor validates the shape of what it was handed and not the liveness of
  the asset, because checking would be a host crossing per mesh constructed and
  the handle is not used until the add. Documented rather than hidden; not a
  task unless somebody finds it confusing in practice.

---

## 3. Skinning

*(Built: three paths over one shader contract — a baked pose table, a live
palette under `skeleton: true`, and an opt-in compute path. `src/scene/skin.c3`
carries the design and the costs.)*

- **No blending or crossfade between clips.** The baked path cannot express one:
  the pose is a table lookup, so nothing can influence it that was not sampled at
  bake time. The live path is where it would land, and §17 has what a crossfade
  would cost on each.
- **No morph targets.**
- **No sockets.** A bone's world transform is recoverable from the baked table as
  `pose * bind` and `AssetSkin.bind` is kept for it; nothing reads it yet.
- **Do not route a crowd through `skinning: 'compute'`.** It does the vertex
  shader's arithmetic *plus* 24 bytes a vertex written and read back, a dispatch,
  a barrier, and a posed copy per instance per frame in flight. Break-even at two
  passes, and it splits the bucket whether or not a second pass exists.
- **A validation gap, measured rather than assumed.**
  `the_skinning_paths_are_silent_under_validation` covers the dispatch's
  arguments and the buffer lifetimes and does **not** cover the compute→vertex
  barrier: deleting that barrier leaves the test green, under the ordinary layer
  and under synchronization validation both. This machine's layer does not report
  the hazard, so the barrier rests on the spec and on review — worth repeating
  the injection anywhere the layer is fuller.

---

## 4. Textures, async load, and a sky

*(was G6)* **Two things wearing one coat, and the sequencing matters more than
the parts.** `lib/ktx.c3l` is already in, ahead of the milestone that uses it.

**A roughness map has nowhere to go, and that is a lighting decision rather than
a texture one.** Mips, colourspace and normal maps are closed; what a roughness
or metalness map lacks is a term to feed, because the built-in light is one
lambert factor with no specular. So it loads correctly and only a custom `shade`
body can do anything with it. **Do not add a roughness input to `mesh.slang`
before deciding what §12 does about lighting** — a specular term and the light
that drives it are the same decision, and a roughness map wired into lambert
would be a field that changes nothing. §14 is where that rule was tested against
a feature that wanted the fields and did not get them.

**What a script still cannot reach is a mesh's *own* image.** A mesh loaded from
a `.glb` carries its texture on the `GpuMesh` and exposes no `Texture` handle, so
`texture.read()` has nothing to be called on for it — the byte-for-byte export
round trip had to be written in C3 for that reason.
`asset.imageAt(i)` is the shape of the missing verb, and it is small.

**`test/ktx_test.c3` does not exist.** `grep -rn ktx src test` returns nothing:
`ktx` is listed in `project.json`'s dependencies and imported by nobody, so the
rot the dependency comment was written to prevent has already happened. Both this
file and that comment used to claim the test existed and have stopped; writing it
is the half that is still open.

**Do the glTF half first and out of order.** `image.c3l` decodes PNG and JPEG and
nothing else, so **every shipped `.glb` using `KHR_texture_basisu` currently
loads with its textures missing** — recorded at M1, worked around by rendering a
141-mesh terrain untextured with one warning, and still true
(`src/scene/asset.c3:2039`). Decoding KTX2 into the existing texture path is
small, self-contained, independent of the sky, and changes this milestone's value
from "skyboxes" to "shipped assets work". `ktx::vk` is the VkFormat table and
block-size arithmetic `gpu/texture.c3` needs to upload an image it did not
decode; `ktx::basis`/`uastc`/`etc1s`/`bc7`/`bcn` transcode in pure C3, so a
Basis texture becomes BC7 on the device rather than being expanded to RGBA8 —
the difference between a game's texture budget and a demo's.

Two notes carried forward: it needs **no staging step** unlike `slang.c3l`
(`libzstd.a` is checked in per target, reached through the library's own
`linklib-dir`) and no `--recursive`. And **`ktx::vk` collides with `vk`** —
fully qualify at the call site; `project.json` says so where the dependency is.

**Async load is smaller than it was**, because G3 already did the synchronous
half. Now that `three.load` is metadata-only and upload happens per mesh, the
thing worth making async is `asset.mesh(...)` / `asset.instantiate()` — a
bounded, per-mesh unit of work — rather than a whole file. There is little point
streaming 200 meshes in the background that were never going to be placed. The
promise resolves from the job queue `drain_frame_jobs` (`frame_loop.c3:257`)
already drains.

**The sky is a render feature, not a loader**, and bundling them under "image
loading" is how the second one gets underestimated. A cubemap or an equirect, a
pipeline that draws at far depth with depth-write off, and — if it is to light
anything rather than sit behind it — an environment term in the shader.
`ktx::container` already gives faces, so the container problem is solved rather
than pending. **Do not build an LDR-PNG cubemap in the meantime**: it would be
replaced rather than extended, since the pipeline differs in format, mip handling
and whether the shader treats it as radiance.

`ktx::mipgen` is there too. `gpu/texture.c3` generates its chain by blitting each
level from the one above, on the device, which is right for an RGBA8 image it
just uploaded and is **not available for a compressed one** — a BC7 image cannot
be blitted and carries its own levels, which is why `can_generate_mips` asks per
format rather than answering once. So `mipgen` is for the KTX2 path writing an
image the transcoder produced, not a replacement for what is there.

---

## 5. UI and text

*(was G7)* Last of the real features, because there is already a UI rendering
library to bind rather than write. Three decisions decide whether the binding is
pleasant.

**Where it draws.** After the scene, into the same offscreen target, before the
blit — so `--screenshot` and the MCP `screenshot` capture the UI too. **An agent
that cannot see the HUD it just built cannot correct it**, which is the same
argument `getApiDocs()` makes, applied to the HUD.

"Before the blit" was written when a frame had one pass, and it is now ambiguous:
**after the post chain, not before it**, or every effect a script sets bloods into
the HUD. §13 places it as the last stage before the target closes, and prices it —
it needs no attachment of its own and at most one barrier, because it writes the
colour image everything else already writes. A HUD is a pipeline, a vertex buffer
and a glyph atlas; none of the cost is in scheduling, which is why this milestone
is the two decisions below and not a rendering problem.

**Input arbitration is the whole difficulty.** A click on a button must not also
shoot the gun. The UI gets the pointer first and marks the event consumed;
`onClick` and `scene.pick` see only what is left. `MouseTracker`'s edge machinery
in `scene/input.c3` is where the flag belongs — it is already the thing that
decides what a click *is*.

**The coarse half of that landed first and does not answer it.**
`three.controls.enabled = false` takes the mouse away from the camera wholesale
(§17), which is what a script driving its own camera needs and is no use at all
to a HUD: a button and the world behind it both want the same click, and turning
the camera off decides nothing about which of them gets it. The consume flag is
still this milestone's, unbuilt, and still the thing that has to be designed
rather than switched.

**A click cannot say it was handled, and that is decided rather than pending.** A
handler returning `false` was the obvious cheap version and it suppresses
nothing: a click *is* a press and a release that did not travel, so by the time
one is recognised no orbit has happened. The conflict is over the **press**, and
the press is what this milestone has to arbitrate.

**It has been hit rather than anticipated.** A scene binding seven keys to a
character has no way to say so — the controls had to be delivered in a chat
message, because the window has no way to mention them. That is the smallest
possible version of this milestone and it is already missed.

**Retained or immediate.** Immediate-mode costs a full UI rebuild in JavaScript
every frame, inside the frame budget. Retained-mode is a second scene graph with
a second lifetime problem. Follow whatever the library already is, and if it is
immediate, **measure the per-frame cost against the 8 ms soft budget before
building a game on it**. Text needs a font atlas, which is a texture, which is a
path that already exists.

---

## 6. Audio, saving, and the rest

*(was G8)* The least important and the most likely to be what someone actually
complains about.

- **Audio.** A new dependency and a new thread. `three.sound(path)`, `play`,
  `stop`, volume. Positional audio needs the camera every frame, which is a cheap
  addition to `tick`.
- **Saving.** Today JavaScript cannot touch the disk at all except through
  `three.load(path)` and `scene.export(path)`. A save file needs a write verb,
  and **this is the one place in the whole plan where the sandbox widens on
  purpose** — confined to a single state directory, never to the assets root,
  never to an arbitrary path. Say it in the doc comment so nobody later relaxes
  it as an obvious convenience.
- **Timers, RNG seeding, `structuredClone`,** and whatever else turns out to be
  missing when someone writes a real game and hits it.

---

## 7. Physics — what the world does not expose

The world is built and stepped; these are bindings that do not exist, not
mechanisms that are missing. Velocity and impulse are bound — a dynamic capsule
with its velocity set each frame walks *and* collides — so what is left is:

- **No character controller.** With velocity bound, a dynamic capsule with locked
  rotation *is* a character, so this is the step after rather than a prerequisite.
  What it buys is that every game stops rewriting the same 120 lines: sweep the
  shape, slide along the contact, step up small ledges, and report whether the
  thing is standing on something.
- **No soft bodies.** The library has them and the ground plane they rest on is a
  plane rather than a height, but nothing binds them to JavaScript.
- **No joints from a script.** `add_constraint` exists and `remove_body` cleans up
  after it; there is no `three.physics.joint(...)`.
- **No `snapshot`/`restore` surface**, so "what if" as a tool call is
  free-but-unbuilt — the library supplies the mechanism. This is also what
  lockstep networking would need, if that ever matters.

---

## 8. Hot reload

Unlocked by unloading and still not done. Once a scene can be dropped and its
assets released, re-evaluating `main.js` on a file change is a small addition —
and combined with `--mcp` it means an agent edits a `.js`, the game reloads, and
the screenshot shows the result.

**The code is small and the semantics are not.** Somebody has to say what happens
to a running `setAnimationLoop`, to live physics bodies, and to the camera. See
§9 — this is the open question, and the addition should not land before it is
answered.

---

## 9. Open questions

Decisions nobody has made. Each one is cheap to decide and expensive to discover.

- **Hot reload semantics.** What happens to a running `setAnimationLoop`, to live
  physics bodies, to the camera. See §8.

- **What `main.js` and `run_script` share.** They share globals by design — so
  what happens when an agent's script redefines something the game holds a
  reference to? Probably nothing good, and probably acceptable, but it should be
  a known answer rather than a discovered one.

*(Three of these are answered and gone: `three.controls.enabled` exists, a click
cannot be consumed (§5), and the camera belongs to the host rather than the scene
— the closing section has it. What is left is the two that gate hot reload.)*

---

## 10. Traps carried over

Live, all of them. Each cost real time and none is visible in a diff.

- **`stats()` counts buckets, not draws that happened.** `scene.stats()` and
  `MeshPass.stats` rebuild the draw list out of the scene graph and never
  consult the material table, but `MeshPass.record` skips any bucket whose
  material does not resolve. So a bucket that draws nothing at all still reports
  as a draw call, and a check written on `drawCalls` cannot tell "it drew" from
  "it was going to". Live for the length of one test:
  `a_mesh_keeps_drawing_with_a_disposed_material` was written on the count,
  passed against a deliberately broken material collector, and only started
  failing when it was rewritten to count red pixels. **Anything about whether a
  material reached the screen has to be asserted on the screen.**

- **A failing check does not run your `defer`s, and what leaks can be a thread.**
  `test::@check` failing `longjmp`s to the runner, which unwinds past every
  `defer` in the test — so a fixture macro's `defer runtime.close()` never runs
  and everything it owned is abandoned *in a stack frame the next test reuses*.
  This was live for a whole milestone as "the physics worker pool deadlocks on a
  sleeping body that is moving", recorded in §1, in `Physics.wake` and in
  `an_impulse_wakes_a_settled_body_and_moves_it`, and it was none of those
  things. Deleting the wake makes that check go red; the red check skipped
  `Physics.close`; the solver's worker thread stayed parked on a mutex inside
  the dead frame; the next physics test built its world over those bytes and
  initialized a new pool on top of the sleeping worker. Then `join()` waited on
  a queue two workers were draining and the suite hung, naming neither the check
  nor the cause. **A red check that turns into a hang erases the red check**,
  which is why this is worth more than the bug was. Two things fixed it and only
  one is a fix: `collision.c3l`'s pool now keeps its mutex, condition variables
  and counters in a heap block the workers own (`PoolState`), so an abandoned
  pool leaks a thread rather than capturing the next one
  (`collision_tests::pool::an_abandoned_pool_does_not_capture_the_next_one`,
  whose injected form hangs — that is the shape of what it guards). The general
  lesson is the other one: **anything a fixture hands out that is not memory —
  a thread, a device queue, a file handle — is not released by a failing
  check**, and if it points at the fixture's own frame it will be found again by
  whatever runs next. TSan is what named it in the end (`--sanitize=thread`);
  ASan changed the timing enough to hide it entirely.
- **A destructor that exits the process truncates the suite and reports success.**
  `Window.free` on the darwin backend of `lib/window.c3l` called
  `[NSApp terminate:]`, so the first test to open and free a real window ended the
  *runner* — partway through, with **exit code 0** and a green "Test Result:
  PASSED" covering only the checks that had already run. Nothing in that output
  says a module never ran; the count is wrong only if you already know what it
  should be. The CLI never noticed, because it frees its window as the last thing
  it does before exiting anyway, which is how this survived there. The general
  form: **a destructor may not decide the process is over**, and anything calling
  a platform's quit verb from a `free` is this bug however it is spelled. What
  caught it was counting modules in the runner's output rather than reading its
  verdict.
- **A `\n` inside a C3 raw string is a backslash and an `n`.** Backticks do not
  process escapes. Shader source and JSON written with backticks look right in
  the editor and are wrong at runtime.
- **`Object.is_array()` is false for an empty JSON array** — `std::collections::object`
  only tags a container as a list once something is pushed. `is_indexable` is the
  predicate that means what it says.
- **A zero-valued C3 map or list binds itself to the *temp* allocator on first
  use** (`list.c3:372`, `orderedmap.c3:227`). It does not fail where it is
  caused: `len()` goes on answering because the count is in the struct and only
  the buffer is gone. Cost two landmines in the physics world — one crashed
  inside a hash table, the other looked like physics that ran without moving
  anything. Bind collections explicitly.
- **`SomeEnum::values`** (`::`, not `.`) is how c3c spells enum reflection.
- **Querying an optional feature is not the same as falling back.** Decide
  whether an extension is baseline for the devices this targets — KosmicKrisp and
  mid-range Vulkan parts, not the whole installed base — then either require it
  and say so in one sentence at startup, or write the fallback and test both
  paths. What is forbidden is the third thing: *assuming* it and finding out at
  draw time. A fallback nobody exercises is worse than a requirement, because it
  is only reached on the machine you do not have. `VK_KHR_dynamic_rendering` and
  `VK_KHR_push_descriptor` are both required by name. The requested API version
  is 1.3, so push descriptors are an extension here rather than the core feature
  they became in 1.4.
- **A cache that outlives the process makes a test pass for a different reason on
  its second run.** `shader/disk_cache.c3` is on by default and writes to
  `build/shader-cache`, so the first `c3c test` after a shader changes compiles
  it and every later one loads it. A check written on `PipelineCache.compiles` is
  then green on run one because Slang ran exactly once, and green on run two
  because Slang never ran at all — one assertion measuring two different things,
  and the run that would have caught a regression is the one where the counter is
  stuck at zero for reasons of its own. Nothing in a diff shows this: the
  variable is *when* you ran, not what you changed, and it flips the first time
  somebody runs the suite twice. The fix is a convention rather than a mechanism.
  Every test that reads either cache says which one it means on its **first**
  line — `shader_cache_set_dir("")` for the six that count in-memory compiles, a
  scratch directory of the test's own for the ones that are about the disk — set
  at the start and never restored at the end, because a `defer` does not survive
  a failing check (above) and a restore is precisely the line that does not run
  on the run that needed it. **Anything asserting that work was avoided has to
  name the cache it means.**
- **An extension being present says nothing. The feature bits are the answer,
  and they have to be read on the device.** `VK_EXT_extended_dynamic_state3` is
  advertised by KosmicKrisp on an Apple M5 and every one of its colour-blend bits
  is zero — `ColorBlendEnable`, `ColorBlendEquation` and `ColorWriteMask` all
  false — so `vkCmdSetColorBlendEnableEXT` is unusable on the device this project
  targets. Metal carries blending in `MTLRenderPipelineColorAttachmentDescriptor`,
  inside the compiled pipeline state, with no encoder command to change it
  mid-pass; `PolygonMode` and the multisample bits are zero for the same kind of
  reason. What *is* set on that device: `DepthClampEnable`, `DepthClipEnable`,
  `SampleLocationsEnable`, `ProvokingVertexMode`, `LineRasterizationMode`,
  `TessellationDomainOrigin`, `DepthClipNegativeOneToOne`.

  **This is the exact inverse of the topology case in `gpu/pipeline.c3`**, and
  both halves are worth holding at once. There the bit says no
  (`dynamicPrimitiveTopologyUnrestricted` false) and the driver honours the
  switch anyway, pixel for pixel, because Metal takes the primitive type at draw
  time — so the bit understates what works. Here the bit says no and means it.
  Neither direction is derivable from the extension list; a five-line probe
  calling `vkGetPhysicalDeviceFeatures2` answers in one run and is the only thing
  that should be trusted.

  The consequence for the transparency entry at the end of this file: **a blend
  mode is a field of `PipelineState`, not a command.** That is cheap — a closed
  enum of three or four values shared by every material that asks, so a handful
  of pipelines for the process, and `PipelineCache` already keys on
  `PipelineState`. It is nothing like `material.side`, which is a per-material
  axis an agent varies freely and is exactly why the cull mode went dynamic.
- **A passing `c3c test` check prints nothing.** The runner captures a check's
  output and shows it only on failure, so `io::printn` in a green test is
  invisible on both stdout and stderr — which reads as "the probe did not run".
  Write the answer to a file, or assert on it.
- **Two frames in flight means any buffer the GPU may still be reading must be
  double-buffered.** The per-frame instance buffer is one buffer per frame slot,
  written and grown only after that slot's fence has been waited on.
- **A `String` handed out by a parsed document dies with the document.**
  `gltf::Mesh.name` is freed by `GltfStream.close`, so anything keeping a name
  past the load has to own a copy. Invisible for a whole milestone, because
  nothing read a name until something wanted to look a mesh up by one.
- **A build step and its documented equivalent drift silently**, and **passing
  the same flags is not enough, because the defaults underneath them differ.**
  `slangc` defaults to column-major matrices; the compile-request API taking the
  identical argv does not. Two modules, no error either way, and a rendered
  picture convincing enough that four tests had to say so. The only trustworthy
  check is comparing the artifacts. There is no shader build step any more, which
  is the only real fix.
- **Blend arithmetic happens in linear light behind an `_SRGB` attachment**, so a
  test expectation computed in sRGB space is simply wrong. The hardware decodes
  the destination, blends, and encodes on write: a half-and-half mix comes back as
  `encode(0.5·a + 0.5·b)` and not as the average of the two encoded values. The
  two differ by **tens of eight-bit levels** through the whole mid-range: 146
  against 100 in one channel of the fixture in
  `a_transparent_material_blends_with_what_is_behind_it`, and 188 against 128 for
  a half mix of black and white. Far outside any tolerance worth having, so a
  check written the wrong way round fails against correct code and reads like a
  blending bug. Compounding it, a *generated* shape
  is not white: `PRIMITIVE_COLOR` is 0.78, 0.78, 0.80 sRGB and `mesh.color`
  multiplies it, so `mesh.color = 0xff0000` renders 199 and not 255. Both are
  written down once, in `encode_srgb` and `primitive_linear` in `js_test.c3`.
- **An intermediate image a shader samples and re-writes has to carry the same
  `_SRGB` format as the target, or the encode happens twice.** The post pass
  renders the scene into image A and then samples it: under `R8G8B8A8_SRGB` the
  attachment encodes on write, the sampler decodes on read, the body works in
  linear like every other shader here, and the `_SRGB` target re-encodes — the
  round trip closes **by format rather than by arithmetic**, and an identity body
  is an identity to within one eight-bit level. Under `_UNORM` the sample arrives
  already encoded, is treated as linear, and is encoded a second time. The
  signature is what makes it expensive: black stays black, white stays white, and
  everything between shifts — **69 levels** at the mid-tones in
  `an_identity_post_pass_leaves_the_frame_where_it_was`, measured by injecting
  exactly that. It does not look like a bug. It looks like the post pass being "a
  bit washed out", which is a sentence that gets a body rewritten instead of a
  format changed. The general form: any offscreen image in a chain is a colour
  *space* decision and not only a memory one.
- **The negative-height viewport does not cancel through a sampled full-screen
  pass.** Every other pipeline in this project sets a negative viewport height to
  undo Vulkan's Y-down NDC so a glm-convention projection lands the right way up,
  and the intuition that two flips — one writing the intermediate, one reading it
  — cancel is wrong, because there is only one. The full-screen pass has no
  projection: its three vertices *are* NDC and its `uv` is the number they were
  built from, so a negative height makes a fragment at framebuffer row `r` carry
  `uv.y = 1 - r/height` and sample row `height - r`. The frame comes back upside
  down and **no validation layer says a word**, because nothing about it is
  invalid. So `PostPass.record` sets a *positive* viewport, `shaders/post.slang`
  has no flip anywhere in it, and the pin is a deliberately asymmetric fixture —
  a top-to-bottom-symmetric one would satisfy the comparison inverted and the
  check would have quietly stopped asking. This plan predicted the cancellation
  and was wrong; it was caught by writing the test the plan asked for rather than
  by reasoning about it a second time.
- **A uniform is a macro, so it collides with anything the agent's own body
  names — including the fields of the structs it was handed.** `#define time
  (push.time)` is live across exactly the lines the script wrote, so a post pass
  with `uniforms: { time: 1 }` has the `p.time` in its own body rewritten to
  `p.(push.time)`. Slang reports macro-expansion failures **at the `#define`
  line**, not at the use, so the diagnostic is a caret under a line of generated
  preamble the agent has never seen, about a member access it wrote correctly.
  This was live from the day uniforms existed and had no test; `time` is the most
  likely uniform name anybody writes for a post pass. The fix is a second reserved
  list per contract — `MATERIAL_CONTRACT_FIELDS`, `POST_CONTRACT_FIELDS` — with
  its own sentence, because "that name is reserved" is true and useless when the
  thing using it is the struct five characters away.

  The mirror image cannot be refused and has to be documented instead: a **local**
  in the body named `push` shadows the push block every uniform expands through,
  and the error arrives as `'t' is not a member of 'float'` against the same
  `#define` line. It cost twenty minutes in `examples/vfx.js`, where the shield's
  vertex body called its displacement amount `push`. Nothing parses the body, so
  nothing can catch it — the note lives in the example that hit it.
- **A gradient sampled as a lookup table wraps at both ends.** Samplers here
  repeat, and a ramp read at `float2(k, 0.5)` with `k` at 0 or 1 lands exactly on
  the seam — where bilinear filtering blends the *first* texel with the *last*.
  So the darkest input comes back as a mix of the darkest and the brightest
  colour in the ramp, and on a 64-wide table that mix is nearly half the bright
  end. The signature is a whole scene lifted towards the ramp's top colour: in
  `examples/vfx.js` a near-black background came back mid-beige, which reads as
  the grade being too strong rather than as a wrap mode, and the same bug lit
  every shield and every ember at full brightness where they should have been
  dark. Half a texel in at each end is the fix — `0.0078 + saturate(k) * 0.9844`
  for a 64-wide ramp — and it belongs in a helper the body calls rather than at
  each lookup, because the lookup that gets forgotten is the one that is only
  wrong at the extremes. This is *not* an argument for `CLAMP_TO_EDGE` on the
  shared sampler: a material's own textures are tiled far more often than they
  are used as tables, and scrolling `s.uv + float2(t, 0)` under clamping is a
  smear instead of a scroll.
- **A pixel is a square, and its coordinate is a corner.** The rasterizer decides
  coverage at the pixel's *centre*, so anything claiming to agree with the
  picture — a picker, a hit test, a readback comparison — has to add the half.
  Leaving it out is a bias rather than noise: always in the same direction,
  invisible except at an edge, and an edge is where the question is being asked.
- **Slang diagnostics are only useful if they are surfaced.** A compile that
  fails and falls back to a previous pipeline is a shader edit that appears to
  work and changes nothing on screen.
- **A window lies about the mouse.** A button arrives as a latch and the release
  that should clear it can be swallowed by the platform's own event loop. Fixed
  at the source on macOS with `+[NSEvent pressedMouseButtons]`, which only ever
  clears and never sets; the release gate in `Controls` is the belt to that
  braces.

  **§17 widened who is exposed to it.** `three.input.pointer` now reports all
  three latches, and a script polling `down` or `right` has no gate of any kind
  in front of it — a stuck latch reads as a button held forever, sixty times a
  second. That is deliberate rather than overlooked: a second release gate here
  would be exactly the "mechanism that hides the failure of the first" that
  `controls.c3` argues against, and it would make the camera's gate stop being
  load-bearing without anybody noticing. `clicked` is still the only *edge*, and
  an edge is the thing a stuck latch cannot fabricate. Said out loud in
  `bind_input.c3` so a script author meets it in the doc rather than in a
  session.
- **A picking check whose fixture is symmetric about the probe cannot see a
  transposition**, and picking code is made almost entirely of transpositions.
  Four separate checks in this project passed for the wrong reason; three of them
  were symmetric fixtures.
- **Resetting a query pool from the host needs `hostQueryReset`, and it is a
  *feature*, not a limit.** `timestampComputeAndGraphics` says the queue can
  write timestamps; it says nothing about whether `vkResetQueryPool` exists, and
  calling it without the feature enabled is undefined behaviour that validation
  will name but a working machine may not. `GpuLimits.timestamps` is therefore
  the *conjunction* of the two, and the reason it cannot drift out of agreement
  with what the device was actually created with is structural: the feature
  chain is queried once and handed to `vkCreateDevice` unchanged, so the bit the
  limit reads is the same bit that was enabled. Anything later that starts
  editing that chain on the way to device creation breaks the argument, not just
  the value.
- **glTF stores rotation as a quaternion, so an euler-built pose cannot
  round-trip bit-exactly.** Measured on a 227-copy scene: positions and scales
  return exactly, worst pose error 1.9 µm on a 30-unit scene, and 0.11% of pixels
  differ — all of them on silhouette edges. Rendering itself is bit-exact
  deterministic, so a pixel diff of a round trip is *not* noise and should not be
  dismissed as such.
- **A `features:` entry in `project.json` makes `-D DEBUG` a no-op, silently.**
  `"features": ["DEBUG"]` defines the feature for *every* build, so `$feat(DEBUG)`
  is true unconditionally, `c3c build --trust=full` produces a debug binary
  carrying the Khronos validation layer, and `--help` reports a flag nobody
  passed. It sat there for two days inside a commit about Vulkan settings, with
  `src/debug.c3` and `claude.md` both documenting the opposite. Nothing fails
  when you add it — that is why it gets added, to stop typing the flag — and
  nothing fails afterwards either, which is why it stays. **A build switch is
  only a switch if the default build does not set it**; `project.json` now
  carries the argument beside the empty list.
- **A guard on the wrong handle hides a whole class of object.** `vk::Memory` is
  one struct for two kinds of allocation: `new_buffer` fills `.buffer` and leaves
  `.image` null, `create_image_buffer` does the reverse. `free_retired_memory`
  asked `if (due.memory.buffer != null)`, so every image the deletion queue ever
  held was dequeued and then skipped — no `vkDestroyImage`, no page block
  returned, for the white 1x1 stand-in, every dropped texture, every resized
  shadow map and chain image. **Nothing in the suite could see it**: a leaked
  image is named by `vkDestroyDevice`, which runs after the last check; the
  validation sink is armed around a script and this is not one; and the picture
  is identical either way. It surfaced the day a `-D DEBUG` build started
  validating without being asked, which is the argument for that default in one
  sentence. The test that now holds it
  (`a_drained_image_is_destroyed_and_not_merely_dequeued`) had to retire *one
  image and nothing else* — a first draft that unloaded a whole asset and
  asserted on total bytes returned passed with the bug in place, because four
  vertex streams came back and outweighed the image that did not.
- **A constant picked to hide a seam is charged to the shadow map.**
  `examples/lumbridge.js` made ground out of 3249 boxes and gave each one a
  depth of 30 units, for one reason: so a low camera could not see under the
  terrain where two tiles step. Nothing about that reason is wrong and nothing
  in the picture changes if it is 8. It cost **1.1 ms of a 3.9 ms frame** —
  around 30 % — because a tile's four side faces are 120 units² each, are buried
  entirely inside the neighbouring tiles, and are rasterised into a 4096² shadow
  map every frame from an angle where they are invisible. **The tell is that the
  cost of the constant scales with the shadow map, not with the scene**: raising
  tile depth from 3 to 30 costs 0.42 ms at 2048 and 1.39 ms at 4096, so it is
  fill and not geometry, and no triangle count anywhere moves. A depth-only pass
  makes this cheap to do by accident — there is no fragment stage to notice that
  a surface is occluded by its own neighbour, and `stats()` reports the same
  `triangles` either way. **Geometry that exists only to be hidden is still
  drawn, and the shadow pass is where you are billed for it.** §18 has the full
  curve; §18.4 is the fix that stops it recurring.

---

## 11. Verification

```
c3c build --trust=full
c3c test --trust=full --test-noleak     # while working
c3c test --trust=full                   # with leak tracking; much slower
c3c test --trust=full --test-filter <suite>
```

**Never read a timing off a run with leak tracking on.** The runner installs a
`TrackingAllocator` for the length of each check, and on this machine that
measures roughly 100× the real cost of anything that allocates per element.
`--test-noleak` is a flag of the *test binary*, not of the compiler.

The house standard, unchanged: headless, GPU-free where the logic allows,
leak-clean under both modes, and **every regression test re-proved by injecting
the bug it claims to catch**. An unexercised regression test is an assumption.

**The suite is headless, and the one windowed check is switched off waiting to
move.** `test/resize_test.c3` opens a real window and walks the swapchain through
a spread of awkward sizes and a minimise, because the bugs it exists for — the
blit's destination rect, a swapchain image destroyed while a presentation still
refers to it — are only reachable through `Renderer.frame`, and both headless
frame paths fence-wait after submitting so neither can ever see them. Its `@test`
is commented out: the frames are vsynced, so it costs seconds of watching a
window flicker, three times over in a session that runs the suite plain, under
`-D DEBUG` and leak-tracked.

**It belongs in `lib/window.c3l` and that is why turning it off is not simply the
paragraph above being ignored.** What it exercises is that library's contract —
`set_size`, `set_minimized`, a surface reporting a new extent — and this repo is
only where it happened to get written. Moving it there is the fix; the file
compiles in the meantime so it cannot rot, and until it lands somewhere that runs
it the swapchain resize path is covered by nothing, which is the cost being
accepted. Anything else wanting a window should be asked why it cannot be
headless first.

**Assert on the thing, not on the flag.** A mode field says nothing about whether
anything rendered; compare pixels. Three ways a check has passed for the wrong
reason here, all worth guarding against: a symmetric fixture, a comparison that
turned out to be counting draw calls rather than comparing frames, and an
assertion whose probe was outside the region it claimed to test.

**Assert absences too.** "Loading a file uploads nothing" is the only way to keep
a lazy loader lazy — nothing else notices when it quietly starts uploading
everything again.

**An input-driven scene is testable, and that is what makes a game testable.**
`three.input.press(key)` holds a key down until `release(key)` through the same
path a real key takes, so no handler can tell a scripted key from a finger; and
`three.budget` lets a script raise its own wall-clock allowance from 5,000 ms to
at most ten minutes, so a check that *simulates* is cut into pieces that mean
something rather than pieces that fit five seconds. The ceiling stays, because a
limit a script can lift entirely is not a limit. What it bought is the argument
in one number: 27,000 simulated steps at running speed found a 13% collision
failure rate that no amount of playing the scene by hand had surfaced.

Checks worth writing *before* the code they check, because each one guards a
number that is wrong rather than a picture that is:

1. **The physics world is deterministic** — two worlds given the same inputs
   produce the same `state_hash` after N steps, and a `snapshot`/`restore` round
   trip reproduces it. The library supplies the mechanism; the binding is what
   could break it, by stepping at a rate that depends on the frame.

---

## 12. Lighting

**There is one directional light and it is four floats**, and it casts one
shadow. The naming rule stands for whatever comes next: it is deliberately not
`scene.add(new three.DirectionalLight(...))`, because that name promises adding,
removing, colouring and duplicating and this renderer can do none of them.

What is left, in the order they stop being optional: **a second light, or a
list; a colour per light rather than white; and a specular term.**

**A specular term is what a roughness map is waiting for.** §4 can already load
one in the right colourspace and has nowhere to send it: `lambert()` is the whole
of the built-in light, so roughness and metalness are inputs to an equation this
renderer does not evaluate. That makes them one decision and not two — **do not
add a roughness field anywhere before the term that reads it exists**, or it is a
material property that provably changes no pixel. §14 held that line under
pressure and is the precedent: the layer extension's PBR fields are parsed,
dropped at the importer and refused by name at the JS boundary.

Two properties of the shadow worth knowing before building on it: **the camera
frustum stops culling while the pass is on** (a caster the camera cannot see
still throws a shadow into the frame, so `culledLastFrame` reads 0), and **there
is no `castShadow` per object**, because a third per-copy channel splits buckets
and that is the trade the whole renderer refuses.

**The exporter still writes no light.** Not writing one used to be right, because
a hardcoded directional term is an implementation detail rather than content;
binding it changed that and nothing followed. One directional light and an
ambient floor map onto a glTF `directional` light and nothing else, which is a
small and honest write.

---

## 13. The pass system, and what it is not

*(Built: a frame is a list of stages, the post chain is `three.setPost` plus
`three.addPass`, and the shadow pass took the barrier count from `3 + N` to
`5 + N`. The counting, the driver measurements and the interface argument that
justified all of that are in `git log -p -- plan.md`.)*

### The rule a new pass has to hold

> **Every script-authored pass reads float and writes float. A fixed,
> engine-owned tonemap pass is the only thing that writes `target.color`.**

Without it *"am I last"* becomes a pipeline variant: the same body at slot 3 and
at slot N would be two different `VkPipeline`s, output format would enter the
cache key, and reordering the chain would be a recompile. With it there is one
pipeline shape for every `addPass` body, one fixed pipeline for the encode, and
free reordering. `POST_CHAIN_FORMAT` is `R16G16B16A16_SFLOAT`; `TONEMAP_BODY` is
the one caller that passes `target.color_format`.

**The scene image is not part of that and stays `_SRGB`, and that is what makes
the scene not HDR.** A scene pipeline's colour attachment format is fixed when
the pipeline is built, so a float one makes every mesh pipeline wrong the moment
a post pass is set. Both ways out are large — a second variant of every mesh
pipeline keyed on whether post is active, which puts a format in the pipeline
cache key; or rendering into the chain always and tonemapping every frame of
every scene, which deletes the property that an unposted frame is the code path
it always was. Neither buys anything while **nothing in this renderer produces a
value above 1.0**. What HDR is actually blocked on is physical light intensities
— the material unit below — and when the scene becomes HDR the always-on path
becomes right for a reason that will exist by then.

### What this does not cover

- **Downsampled intermediates.** A bloom pyramid at ½, ¼, ⅛ means per-pass
  extents, so P0/P1 become a pool keyed by extent. Still not a solver, but not
  two fields either. This is the piece that grows first.
- **Reading four passes back**, or a pass fanning out to two consumers. `prev`,
  `scene` and one `reads` tap are the edges; the tap closed §2's "a pass wanting
  a third source", and a second tap per pass is where this would grow next.
- **MRT** — a pass writing two attachments.
- **Normals or motion vectors in a post body.** Depth is built — `p.depth` in
  world units, per §2's instruction — and the other two are not.

### What is left of the order of work

	4. the material unit     §2's blocker. The actual PBR work, and it touches
	                         nothing above it — the pass work and the PBR work are
	                         separable, and only the format rule sits across both.
	5. IBL bake              on texture.c3's one-shot path. hostImageCopy lands here.
	7. fuse the pointwise    local read, measured against the chain rather than
	                         assumed. The first step whose value is a number and
	                         not a shape.

The numbering is kept because 1, 2, 3 and 6 — the driver batch, the format
decision, the chain and `three.addPass` — are referred to by it elsewhere.

### Why not a render graph, and what would change it

A graph's executable form *is* a list — the topological sort is a preprocessing
step that produces one. But the sort is not what a graph is for. The **edges**
are, because barriers and resource lifetimes are derived from them. And that is
the whole argument for the shape above:

> **In a chain, adjacency is the edge set.**

A general DAG needs explicit edges precisely because list position no longer
tells you who reads whom. A chain does not have that problem, so constraining the
topology buys the derived barriers back for nothing. `three.addPass` does not
undermine it: it makes the *order* script-authored, and insertion order is
already the topological order.

**Trigger:** script-authored *edges* — a script naming which pass's output
another pass reads, where the answer is not its predecessor. That is the point at
which no human is left in the loop to reason about the dependency and a solver is
the honest answer. Pass count is not the trigger and never was.

---

## 14. Material layers

*(Built: `three.LayeredMaterial`, the glTF `CUSTOM_materials_layers` importer,
and an exporter that writes a stack back out from the source document.)*

- **Parallax**, from the height data the extension already carries and the
  importer already drops. `heightTexture` and `bump` are refused by name today.
- **The PBR half is §12's, not this section's.** `metalness`, `roughness`,
  `metallicRoughnessTexture` and `subsurface` are parsed, dropped at the importer
  and refused at the JS boundary. When the specular term exists, `GpuLayer` in
  `scene/asset.c3` is where the three fields go back in, and the refusals in
  `js/prelude/layers.js` are what get deleted.

---

## 16. What an exported scene keeps

*(Built: side, texture transform, the three extra maps, the camera and the light
all cross now.)*

- **Lines are the one item deferred.** A line mesh has no CPU copy of its
  vertices (`upload_built` skips `build_bvh`, which is what keeps one) and a
  script's `three.lines()` is indistinguishable from a helper — both draw with
  `LINE_MATERIAL`, which is the test the exporter drops helpers by. Two
  structural changes for the least valuable of the six; `mode: LINES` is waiting
  in the writer for when it is worth paying for.
- **Two things do not cross, and both are deliberate.** The light's **ambient
  floor** has no punctual equivalent — ambient was removed from
  `KHR_lights_punctual` before ratification — so a scene with a high floor
  reloads darker, and folding it into the directional intensity would be a
  different picture rather than the same one. And **metalness and roughness** are
  not written, because §12's rule holds: no specular term means a number in the
  file that never affected a pixel.

---

## 15. The draw buffer

*(Built: per-draw data is a `DrawRecord` in a host-visible buffer and the push
block carries its address. The block is 24 bytes where it was 76, material
uniforms went 52 → 104, and a new vertex stream now costs 8 bytes of a buffer
rather than a trade against them.)*

- **Not `vkCmdDrawIndexedIndirect`, and not yet.** It buys nothing here:
  geometry is one buffer per mesh so `firstIndex` and `vertexOffset` are always
  zero, textures are push descriptors written per bucket, and a `ShaderMaterial`
  is its own pipeline — each of those independently forces one command per
  bucket. An indirect draw would be the same commands plus a buffer read, minus
  the validation layer's ability to check the arguments: a bad record becomes a
  hang instead of an error. **Trigger:** a consolidated geometry arena and
  bindless textures, at which point the record is where the five
  `VkDrawIndexedIndirectCommand` fields go. GPU culling wants the same two first.

---

## 17. Gameplay — what a game needs that a scene does not

**Nothing below is a rendering problem**, which is the reason for putting it in
one section. The engine draws a village, a crowd, a shadow and a post chain; what
no script can do is let somebody *play* in one, and every gap between those two
sentences is in the same three places — the camera, the mouse, and the clock.
Two of the three are answered below; the mouse is the one still open.

**This section was found by reading, not by using**, and that is a weaker warrant
than the rest of this file has. Every other entry earned its place by stopping a
piece of work; this one came from going down the JS surface asking what a game
would reach for and not find. The measurements below are real. The ordering is an
argument, and the first thing actually built against it should be allowed to
rearrange it.

### The boundary, measured

The premise worth killing first is the obvious one: *arithmetic is slow in
JavaScript, so move it into C3.* Measured, QuickJS, 200k iterations each, on the
`--safe=no -O3` binary:

	JS inline vec3 normalize (locals)           70 ns
	JS vec3 normalize allocating {x,y,z}       210 ns
	host call -> bool                           55 ns   (H.inputDown)
	host call -> number[9]                     185 ns   (H.cameraGet)
	prelude getter -> host -> index            135 ns   (three.camera.yaw)
	live Vector3 read (allocates + a closure)  530 ns   (three.light.direction)

**The crossing is not the cost. The answer is.** A host call that hands back a
boolean is *cheaper than the arithmetic it would replace* — 55 ns against 70 —
and the same crossing handing back nine numbers costs three and a half times as
much. The difference is QuickJS allocating the result, and it is the whole
finding.

So the test for what belongs on the host is not "is it maths":

- **A verb returning a scalar, a boolean or nothing is free.** Cheaper than doing
  the work in JavaScript, in the cases measured above.
- **A verb returning a vector should write into a `Float32Array` the caller
  owns.** That is the only shape whose cost stays flat as the count grows, and it
  is the shape every item in the next two subsections should be built in.
- **A verb that allocates in order to answer arithmetic is a loss.** A native
  `Vector3.add` measures 185 ns against the 70 ns of the JavaScript it replaced,
  and it is slower *on every call, forever*. `math.js` stays where it is, and
  this entry exists so that nobody moves it later on the strength of the
  intuition rather than the number.
- **A verb that allocates once and does real work is fine.** A path, a query
  result, a bake — one allocation amortised over a thousand cells is nothing.

**And the build is part of the measurement.** The same boolean-returning crossing
is **265 ns with contracts on and 55 ns at `--safe=no -O3`** — a five-fold
difference on precisely the path a per-frame script hammers. A number taken on
the default build says nothing about what a game runs at, and any future
measurement of this boundary that does not name its build is not a measurement.

### What a per-frame script costs today

Five hundred instanced boxes, one mesh, one material, 1280×720, same binary,
against the 8 ms soft budget §5 measures a HUD against:

	500 x mesh.position.set(x, y, z)          0.245 ms/frame
	500 x mesh.position.y = v                 0.160 ms/frame
	500 x read mesh.position.x                0.040 ms/frame
	scene.raycast(origin, direction)          0.021 ms      (500-node scene)
	scene.pick(x, y)                          0.037 ms

**Batched transforms are not urgent, and that corrects a guess.** Moving five
hundred objects every frame costs three per cent of the budget. A
`Float32Array`-shaped bulk write is the right *eventual* shape by the rule above,
but it buys nothing anybody can see until the count is in the thousands.
**Trigger:** a scene moving more than about two thousand nodes a frame, which is
0.6 ms and starting to matter.

**Raycasting is the one that is already a constraint.** `Scene.raycast`
(`scene/pick.c3:63`) walks **every node in the scene** with an AABB test apiece
before it reaches any BVH — 42 ns per node, linear in node count and independent
of what the ray could possibly hit. So the 21 µs above is a property of the scene
being 500 nodes, not of the ray. A hundred agents each casting one ground ray is
2.1 ms, a quarter of the frame, in a scene small enough to be a demo. The
broadphase to fix it exists and is unbound — see the queries entry below.

### What blocks a game, and none of it is an algorithm

- **A camera bolted into something that rolls.** *(The rest is built:
  `three.camera.attach(object, { offset, distance, lag })`, and `distance: 0` is
  first person.)* The offset is added in **world space**, which is right for a
  head at `[0, 1.7, 0]` and for a shoulder camera, and cannot express a cockpit
  or a turret. It looks like one 3×3 multiply by the node's world rotation and a
  flag; what makes it bigger than it looks is that a rolled camera also wants the
  view's up vector to roll, and `Camera.view` hardcodes +Y. **Trigger:** the
  first vehicle.

  Two decisions from building it, kept because they are what somebody would undo
  by accident. **The follow writes `Camera.target` and nothing else** — which is
  why a drag, the wheel and `orbit()` all still work while attached, and why
  first person needed no mode: `distance` at zero puts the eye on the point it
  orbits, so third person, first person and scrolling between them are one code
  path. And **it runs last in the tick, on every path out**, because the clip,
  the solver and the animation callback can each move the thing being followed; a
  camera one frame late does not look like a camera problem, it looks like the
  character sliding, and the bug gets filed against the physics.

- **Pointer lock, which is the last of the mouse.** `three.input.pointer` carries
  the position, the movement, all three buttons and both wheel axes; `dx`/`dy`
  keep reporting while the cursor is outside the window, because the window goes
  on saying where it is. Where they genuinely stop is the edge of the *screen*,
  where the platform stops the cursor — so a look works and cannot turn more than
  a screen's width without the hand being lifted, which is playable and is not
  shippable.

  **It is not a binding.** A look that keeps turning needs the cursor recentred
  and hidden every frame, and `window.c3l` exposes no cursor warp and no
  associate-mouse call on any of its four backends: `CGWarpMouseCursorPosition`
  and `CGAssociateMouseAndCursorPosition` on darwin, `XWarpPointer` or the
  pointer-constraints protocol on linux, `SetCursorPos`/`ClipCursor` on win32.
  Window-library work first, a binding afterwards. **Trigger:** the first
  first-person camera, which is the entry above — and §1's live-resize delta
  should be answered in the same pass, for the same reason: both are a look
  telling the truth.

- **No character controller.** §7 already names this and its ingredients are all
  in `collision.c3l`: swept CCD, GJK/EPA, a capsule, and `Physics.transformed`.
  Sweep the capsule, slide along the contact normal, step up ledges under a
  threshold, and report `grounded`, the slope, and what was hit. It is the same
  120 lines in every game that does not have one, written in JavaScript, at
  60 Hz, against a physics world it can only see through bindings.

- **Animation cannot blend, and the reason is structural.** `AnimationPlayer`
  holds one `int clip` (`scene/animation.c3:340`) and switching is a hard cut.
  `scene/skin.c3` says the quiet part already — the baked path gives up
  "quantised time, no blending between clips, and no way to move a bone" —
  so a crossfade is not a missing feature of the player, it is a thing the baked
  pose table cannot express. Two different answers, and they should not be
  confused:

  - **On the live path (`skeleton: true`) it is ordinary work.** Sample two
    clips, blend per target with a weight, and the existing per-frame palette
    write carries it. That is where the hero character lives and where a
    crossfade belongs.
  - **On the baked path it is a shader change with a named lie.** `Instance.pose`
    would carry a second frame index and a weight, and the skin would lerp two
    baked matrices. A matrix lerp is not a rotation blend and it visibly shears
    at large angles — which is fine for the 0.15 s fade that is what a crossfade
    actually is, and wrong for anything held. If it is built, the doc comment
    says that sentence, because somebody will eventually hold one.

  Clip **events** — "footstep at t=0.3", "the hit frame" — are the other half and
  are cheap on both paths: a sorted time list per clip, compared against the
  player's clock as it advances, fired into a JS callback.

### The algorithms, and how much is already written

- **Navigation, which is the one that was asked for.** Both halves have their
  inputs sitting in the repo already.

  The **bake** has its geometry: every uploaded mesh keeps `hull_positions`,
  `hull_triangles` and a `TriBVHNode` on the CPU (`scene/asset.c3:230`), which is
  what picking and export are built on. Transform the static ones into one soup,
  build one tree over it — `create_voxel_grid` already takes a
  `shared_bvh` — and voxelize.

  The **solve** is written and unused. `lib/collision.c3l/src/voxel.c3` is a
  distance-field solver over a voxel set: multi-pass sweeps to convergence
  (`solve_field`), sampling with interpolation (`sample`), nearest reachable cell
  (`nearest_solved`), and a **multi-source** variant (`solve_sources`,
  `nearest_sourced`, `sample_sources`) that answers "which of these N goals is
  nearest, through the geometry" — which is a crowd flow field by another name.
  Its own header says so: it exists to keep "a flow field from routing through a
  wall". **Nothing in `src/` imports it.**

  The one piece genuinely missing is the *complement*: `create_voxel_grid`
  voxelizes the **inside** of a closed mesh, and navigation wants free space
  above a floor. That is Recast's rule in a sentence — a cell is walkable if it
  is empty, the cell below it is solid, and the agent's height of cells above it
  are empty — and it is a sibling of the existing voxelizer rather than a new
  one.

  **Two verbs, not one, and the split is the whole design.** `nav.path(from, to)`
  for one agent going somewhere; `nav.field(goals)` returning a handle a script
  samples per agent, for a crowd. Sampling a solved field is a lookup; running a
  search per agent per frame is the thing that kills a JavaScript game, and an
  API that only offers `path()` guarantees somebody writes the second one badly.
  Extract a path by descending the field, then shorten it against the same BVH
  the raycast uses — the corridor of cell centres is not the path, and a game
  that walks cell centres looks like it is walking cell centres.

  **What to measure before building it.** Resolution is set on the longest side
  (48 by default), so a 100 m town at a 0.5 m cell is 200 cells across and the
  solve is over *interior* volume rather than the box. The bake cost at that
  size is the number that decides whether this is a level-boundary operation or a
  loading-screen one. The alternative bake — a grid of downward `scene.raycast`
  calls — is 21 µs each and therefore 344 ms for a 128², which answers itself.

- **Bulk spatial queries.** "Which enemies are within eight metres" is a full
  scene walk plus a host crossing per object today. `SpatialHash3D`
  (`lib/collision.c3l/src/spatial_hash.c3`) is a broadphase with insert, update
  and `@get_nearby_objects`, used by the solver and exposed to nobody. What a
  game wants over it: `overlapSphere(p, r)`, `queryBox(box)`, `raycastAll`, and
  `sweep(shape, from, to)` — each returning node ids into a caller-owned typed
  array, per the boundary rule. This is also the fix for the linear
  `Scene.raycast` above, which means one binding pays for two entries.

- **Steering.** Seek, arrive, separation — or RVO if avoidance has to be real.
  Per-agent per-frame, trivially vectorised over a typed array, and the textbook
  case for the third bullet of the boundary rule. Small enough to arrive with
  navigation and pointless without it.

- **Inverse kinematics.** `collision::ik::solve_chain` (`lib/collision.c3l/src/ik.c3`)
  exists, with a `shortest_arc` beside it, and nothing in `src/` calls either.
  Live skinning already lets a script write a bone, which `skin.c3` names as the
  whole point of the expensive path — so foot planting on a slope, a look-at, and
  a weapon aim are a binding away rather than a feature away.

- **Curves and damping.** Catmull-Rom through a set of points, and
  `damp`/`smoothDamp` with the frame-rate-independent exponential rather than the
  naive lerp everybody writes first. By the measurements above these belong in
  **`math.js`, not in C3** — they are arithmetic on a handful of numbers and
  crossing for them would cost more than doing them. Listed here because they are
  wanted every frame by everything, not because they are a binding.

### The clock, and the rest of the plumbing

- **The clock is built.** *(`three.clock.time` and `.dt` in seconds,
  `.timeScale` where zero is paused, `.advance(seconds)` to step a stopped one,
  `.fixedRate`, and `three.setFixedLoop(fn)` beside `setAnimationLoop`.
  `src/scene/clock.c3` carries the design and `test/clock_test.c3` the twenty
  checks.)* §2's `p.time` deferral went with it and has been swept.

  Three decisions from building it, kept because they are the ones somebody
  would undo by accident.

  **There is one conversion and everything is handed its result.** `tick` calls
  `GameClock.advance_frame` once, before anything asks what a frame is worth,
  and passes the answer to the clip player, the solver, the fixed accumulator,
  the follow camera and the callback. That is what makes the pause a pause:
  there is no `if (paused)` in `scene/animation.c3`, `scene/physics.c3` or
  `scene/camera.c3`, because a stopped clock hands all of them a zero. A second
  consumer differencing the host's reading for itself would be a second clock
  and would keep running, which is precisely the bug this replaced.

  **The animation callback's argument is the game clock, not the host's.** It
  keeps Three.js's name and units and stops being Three.js's number, and the
  reason is that most of what moves in most of these scenes is a function of it
  — every file in `examples/` computes a phase or a delta from that argument. A
  pause that stopped the clips and the solver and left it climbing would be a
  still world with the propellers still turning.

  **The solver keeps its own accumulator**, fed the same game milliseconds and
  running at its own 60 Hz. Two accumulators that agree by construction is worth
  more than one shared one: a script setting `fixedRate = 30` must not quietly
  halve the accuracy of every contact in the scene, and a physics rate is a
  property of that solver's stability rather than of a game's taste.

  What it did **not** answer, and both belong where they already are: a seeded
  RNG, without which the determinism `state_hash` proves is thrown away by one
  `Math.random()` in the gameplay layer (§6), and clip events, which are the
  animation entry above.

- **Timers, seeded RNG, saving** — all three are §6's last bullet, and the RNG one
  is worth more than it looks. `collision.c3l` advertises deterministic lockstep
  and `PhysicsWorld.state_hash` exists to prove it; `Math.random()` in the
  gameplay layer throws that away for free. A seeded generator is twenty lines
  and it is the difference between a replay that works and one that nearly does.

- **Joints and snapshots are written and unbound.** `add_constraint`
  (`solver/resolver.c3:441`), `GenericJoint3D`, and `snapshot`/`restore`
  (`solver/lockstep.c3:125`) — doors, ropes, ragdolls, vehicles, and "what if" as
  a tool call. §7 lists them; they are repeated here only because a gameplay
  reader looking for them would not think to read a section about physics
  bindings.

- **UI and audio are §5 and §6** and neither moves because of this section. §5's
  observation that a scene binding seven keys has no way to say so is a gameplay
  complaint in a rendering section, and it stays there.

### The order of work, and what it is gated on

1. **Pointer lock**, with §1's live-resize delta. There is a first-person camera
   now, so both of them have something to be wrong for: a look that stops at the
   screen edge, and one that spins while the window is resized.
2. ~~**The clock**~~ — built. Everything below is written against
   `three.clock.dt` and belongs in `three.setFixedLoop`.
3. **The character controller**, then **animation blending** — the point at which
   there is a thing to move and it looks like it is moving.
4. **Navigation**, then the **queries** and **steering** that make it a crowd
   rather than one agent.

The numbering is kept with the second entry struck rather than closed up,
because the order was an argument and renumbering it would quietly claim the
argument was different.

### What this does not cover

**No ECS, and no gameplay framework.** That stays where the closing section puts
it: the scene graph is the entity list. Everything above is a *primitive* a
script calls, and the moment one of them starts owning a game's update order it
has become the wrong thing.

**No claim about which of these a game actually needs.** Reading found them;
using would rank them. The first real game built on this engine is the
measurement this section does not have.

---

## 18. Outdoor scenes: terrain, and what the shadow map is actually spending

The first scene built on this engine by an agent rather than by its author is
`examples/lumbridge.js` — a RuneScape village, four thousand placed objects in
nine draw calls. It works, and the two things that fought it the whole way are
the two this section is about. Both are measured; neither is a guess.

### The measurement

Apple M5, 1280x720, the village above, camera pinned, median of eleven renders.
`gpuMs` is read from GPU timestamps, so the validation layers in the build do not
inflate it.

| `three.light.shadow.size` | ms  | delta over the one below |
|---------------------------|-----|--------------------------|
| off (2214 of 4178 culled) | 0.67 | —                       |
| 256                       | 1.27 | —                       |
| 512                       | 1.27 | 0.00                    |
| 1024                      | 1.47 | +0.20                   |
| 2048                      | 2.06 | +0.79                   |
| 4096                      | 3.92 | +2.65                   |
| 8192                      | 10.16 | +8.89                  |

Three facts fall out, and they rank everything below.

**The floor is 1.27 ms.** 256 and 512 cost the same, so beneath 1024 the frame is
not fill-bound at all. That 1.27 is everything a shadow pass costs *except*
rasterising the map: the main pass having lost its frustum cull, plus the shadow
pass's own vertex and submit work for 4178 instances across 9 draws.

**At most 0.60 ms of it is the lost cull.** The main pass with culling costs 0.67;
the floor is 1.27. The difference is the uncull penalty and the shadow pass's own
per-instance work *together*, and nothing here separates them — so 0.60 is a
ceiling on what §18.2 can recover, not an estimate of it. Splitting it needs the
per-pass timings of §18.3, which is why that one is first.

**Everything else is rasterisation, and it is quadratic.** +0.20, +0.79, +2.65,
+8.89 per doubling from 1024 — ratios of 3.95, 3.35, 3.35. Textbook fill. At 4096
the frame is **68 % shadow-map fill, 15 % lost culling, 17 % the scene the user
asked for**.

So: the fix `src/render/shadow.c3` already names — a second draw list — is the
*small* one. The large one is that the map is fitted around the whole scene.

### 18.1 Fit the light's box to what the camera can see

`ShadowMap.fit(&self, float[4] light, collision::Aabb3 bounds)` is called with
`Scene.bounds`. For the village that is 224 units across while the camera frames
about 70, so roughly nine tenths of the texels are outside the picture and every
one of them is rasterised into.

**The signature already takes an arbitrary box.** That is the whole reason this is
worth doing before cascades: the pass, the matrix, the single `FrameBlock` write
and the two barriers are all unchanged. What changes is the argument — the
intersection of the camera frustum with `Scene.bounds`, extruded along the light
direction so casters behind the camera still reach it.

At the village's numbers that is about a tenfold gain in texel density, which is
spendable either way: keep 4096 and get shadows an order of magnitude sharper, or
drop to 1024 for today's quality at **1.47 ms instead of 3.92**.

**The cost is that the box now moves with the camera, and a shadow map whose
texel grid slides under the geometry crawls.** The fix is standard — snap the
light-space origin to whole texels before building the ortho — but it is the part
to get right, and it is the reason this is not a five-line change. The test is a
slow camera pan with a static scene: an unsnapped fit shimmers along every shadow
edge, and it is obvious once seen.

Cascades stay deferred, with `shadow.c3`'s trigger unchanged — the largest size a
device will allocate still being too coarse. 18.1 pushes that trigger a long way
out, because it buys most of what a first cascade would.

### 18.2 Two draw lists rather than one uncalled one

`src/render/shadow.c3:38` already specifies this and names its trigger: *"The
trigger for a second draw list is a scene where that vertex work is measurable."*
It is measurable. 0.60 ms of 3.92, 15 %.

The present behaviour is conservative and correct, not wrong: a caster outside the
camera frustum does throw a shadow into frame, so the shadow pass genuinely needs
the unculled list. What is given away for free is the **main** pass's cull, which
was never the thing at risk. Two lists, two frustums:

- the main pass against the camera, as it was before shadows existed;
- the shadow pass against the light's ortho box — which 18.1 makes small, so this
  cull starts dropping real work rather than nothing.

`stats()` should follow: `culledLastFrame` goes back to meaning the camera cull
even with shadows on, and a new `shadowCulled` reports the light one. Today's
`culledLastFrame == 0` is honest but says nothing, and it is what sent this
investigation down the wrong path first.

### 18.3 Per-pass GPU timings — do this one first

Everything above was bisected by hand: toggle shadows, strip materials, resize the
ground tiles, six runs of the same scene. The device already reports
`timestamps true` with a period of 41.67 ns and `gpuMs` is already a timestamp
difference. Splitting it into `shadowMs`, `sceneMs` and `postMs` is a few more
writes and would have answered "where does 3.7 ms go" in one call instead of six.

It goes first because it is the instrument that tells whether 18.1 and 18.2
worked. A refactor of the culling that is verified by total frame time is a
refactor verified by the wrong number.

### 18.4 Terrain is not a pile of boxes

The village's ground is **3249 `BoxGeometry` copies**, four units square and
thirty deep, one per tile. That was the only shape available for ground that a
scene can stand on, and it cost, measured:

- **1.1 ms at 4096**, purely in shadow fill. Each tile's four side faces are
  120 units² and are buried entirely inside its neighbours — around 13,000 quads
  that cannot be seen from any angle, rasterised into the map every frame. The
  tell is that tile depth costs four times more at 4096 than at 2048: fill, not
  geometry. Thinning the tiles from 30 to 8 units is a one-character fix and is
  worth more than any shader change in the file.
- **The staircase.** A monotonic slope across four-unit tiles is a flight of
  steps. Rolling hills on the horizon had to be abandoned and replaced with a
  treeline, because the terracing was worse than the hard edge it hid.
- **Four hand-written functions that every consumer had to call in the right
  order** — `ground(x, z)`, `riverX(z)`, `roadNear(x, z)` and a `flats` list —
  with `plot()` required to run *before* the tiles were laid or the buildings
  floated. Nothing in the engine could see that these were the same terrain the
  meshes were built from, so nothing could catch them disagreeing.

**18.4a — a heightfield primitive.** `new three.TerrainGeometry({ width, depth,
segments, heights })`, heights being a `Float32Array` or a callback. It is built
through the `GeometryBuilder` and `upload_built` that the six existing shapes and
`split.c3` already use, so it is one asset, one draw call, no new pipeline and no
new bucket. Normals from the grid, which is the whole difference between ground
and steps. A skirt around the border so the map edge is a wall and not a hole.

**18.4b — query it: `terrain.heightAt(x, z)`, `terrain.normalAt(x, z)`.** This is
the piece that makes the rest work, and the piece hand-written above. Everything
that stands outdoors needs it — buildings, fence posts, trees, and every NPC that
will follow. Bilinear over the same grid the mesh was built from, so it *cannot*
disagree with what is drawn, which is exactly the failure the hand-written version
was one edit away from at all times. It is also what makes `align('y', 'min')`
mean anything on open ground.

**18.4c — stamping: `flatten(rect, y)`, `carve(polyline, width, depth)`.** These
two are `plot()` and the river channel, and they are the two operations every
outdoor scene needs. A building pad and a watercourse.

**18.4d — mask authoring.** The *consumption* side is already done and good:
`LayeredMaterial` takes a mask with per-channel layer selection, and
`examples/terrain.js` already paints one from a height function into a
`Uint8Array` by hand. What is missing is the painting: `three.Mask(size)` with
`fill`, `stroke(polyline, width, feather)`, `circle`, `fromHeight(fn)`, `blur`,
`.texture()`. `roadNear()` in the village is `stroke` over the road polylines,
written out longhand and evaluated per tile.

The pairing is the point, and it is the answer to "ground matching some texture
and depth": **carve the channel and stroke the mask from the same polyline**, so
the mud is where the water is by construction rather than because two constants
were kept in step. Same for a road: one polyline, a shallow carve, a dirt stroke.

**18.4e — a heightfield collider.** `body: { shape: 'heightfield' }`. The four
colliders are box, sphere, capsule and hull, and a convex hull of a landscape is
useless. Nothing can walk on the ground until this exists, so it blocks the whole
NPC phase and should be costed with 18.4a rather than after it.
collision.c3l already has heightfield testing

### 18.5 Three silent failures, each cheap

Small, unrelated to the above, and each one cost real time in a single session.

**`mesh.geometry = other` is swallowed.** `src/js/prelude/mesh.js:41` is a getter
with no setter, so a non-strict assignment vanishes: it does not throw, the
property still reads the old value, and the frame still draws the old shape. The
engine already has the right convention and states it deliberately — writing a
dynamic body's transform throws, because a solver and a script fighting over one
transform is jitter rather than a compromise. Immutable geometry deserves the
same sentence. Worth auditing the other getter-only properties at the same time;
`camera.near` and `.far` already throw, so the precedent is set twice.

**Shader errors point at generated code.** A body with a parameter named `t`
produces `--> three.material:512:16 | #define t (push.t)`, naming a line the
author never wrote, because every uniform is spliced in as a `#define`. Two
fixes, either useful: map the error back to the submitted body, since the engine
knows where it spliced it; or refuse a colliding uniform name at `ShaderMaterial`
construction with a sentence saying why. Best of all, stop using `#define` for
uniforms — as struct members the collision cannot happen.

**The vertex and fragment bodies are one module.** A helper declared in both is
`error[E30201]: function 'ripple' already has a body`, which is correct and
surprising. One sentence in `docs.js` — declare shared helpers in `vertex`, which
comes first — costs nobody a compile.

### 18.6 Scatter

Written twice in one file, by hand, both times: a seeded LCG, rejection sampling,
keep-out circles, and point-to-polyline distance. `three.scatter({ count, bounds,
avoid, onTerrain, seed })` is engine-shaped precisely because it wants 18.4b, and
it is the most repeated block in any scene with a landscape in it.

### 18.7 What changed in the example, and what did not

Two constants in `examples/lumbridge.js`, landed ahead of any engine work
because they cost nothing and they are the measurement's own conclusion:

- ground tile depth **30 -> 8**, for §10's trap. 8 rather than 3 because the
  terrain steps about three units at the riverbank and under a levelled building
  pad, and a 3-unit slab shows daylight under the seam.
- `three.light.shadow.size` **4096 -> 2048**. The map is fitted around 224 units,
  so 4096 is 18 texels per unit and 2048 is 9. Nothing in the frame is visibly
  different and it is the difference between 3.9 ms and 1.6 ms.

**No engine default moves.** `shadow.size` has no default to change — a script
asks for a size or gets none at all — and picking one for it would be picking it
for a scene shape nobody has measured yet. The village wants 2048 because it is
wide and flat; the number a room wants is a different number, and §18's closing
caveat is that no room has been measured. The right time to give the fit a
default is after 18.1, when the box is no longer the whole scene and the answer
stops depending on how big the level is.

### Order, and why

1. **18.3, per-pass timings.** The instrument. Everything below is verified by it,
   and a culling change verified by whole-frame time is verified by the wrong
   number.
2. **18.2, two draw lists.** Smallest correct change, already specified in
   `shadow.c3` with a trigger that has now fired. Bounded by 0.60 ms, and 18.3
   says how much of that is real.
3. **18.1, fit to the view.** The large one, about 2.4 ms, and the only item here
   with a genuine new failure mode — texel snapping — so it wants the instrument
   and the easy win landed first.
4. **18.4a + 18.4b + 18.4e, heightfield, query, collider.** Unblocks every outdoor
   scene and every NPC, and deletes the box-tile shadow cost as a side effect.
5. **18.4c + 18.4d, stamping and masks.** Authoring, and only meaningful once a
   terrain object exists to stamp.
6. **18.5, the silent failures.** Hours, not days, and independent of all of it.
7. **18.6, scatter.** After 18.4b.

**What this section does not have** is a second scene. Every number here comes
from one village on one machine, and the shape of that village — wide, flat,
outdoors, shadowed, forty thousand triangles of nothing much — is exactly the
shape that makes shadow-map fill dominate. An interior would rank these
differently, and nothing here has measured one.

---

## What is deliberately absent

- **No ECS.** The scene graph is the entity list and a game's components are
  JavaScript objects keyed by node id. Building an entity system in C3 would be
  building the part JavaScript is good at.
- **The camera does not belong to the scene.** It survives `new three.Scene()`,
  where the background, the light and the shadow are all put back to their
  defaults so that two scripts render the same first frame. The camera is not
  that kind of state: somebody watching a window has dragged it somewhere, and a
  script rebuilding the world is not a reason to throw that away. The animation
  callback and `three.controls.enabled` follow the same rule for the same reason
  — what a rebuild costs is every handle the callback captured, and the
  stale-handle throw is what stops it with a sentence rather than leaving it
  running against nothing.
- **No editor.** The MCP surface is the editor, and it is better than one.
- **No networking.** The physics work makes lockstep *possible* — `state_hash`
  and `snapshot`/`restore` are the hard parts and they exist — and nothing here
  builds it.
- **No render graph and no deferred path.** Both are answers to a pass count this
  project does not have. A frame is five images and `3 + N` barrier call sites;
  the shadow pass took that to `5 + N` and a UI layer and depth-in-post would take
  it to about eight. A graph that schedules four passes is a scheduler with
  nothing to schedule. **§13 keeps the shape the alternative takes** — a stage
  list, a chain whose adjacency is its own edge set, and the one trigger that
  would change the answer, which is script-authored *edges* rather than pass
  count. `three.addPass({ reads })` is one index rather than an edge set and does
  not cross that line: adjacency plus the tapped set is still what the barriers
  are derived from. The counting itself was swept; `git log -p -- plan.md` has it,
  including the one place it was out by.
- **What stays absent from the chain: named passes, removal from the middle, and
  downsampled intermediates.** A pass reads its predecessor, the original frame
  and one earlier pass it names with `reads`, so a bloom pyramid at ½ and ¼ is the
  piece that grows first (§13's "what this does not cover"), and reordering is a `setPost`
  followed by the `addPass` calls you want rather than a mutation — which is what
  keeps a handle from ever pointing at somebody else's shader. The old advice
  holds where it still applies: composing two *pointwise* effects inside one body
  is cheaper than two passes, which cost a full-screen read and write apiece. The
  chain is for the effects that genuinely cannot be one body, which is anything
  sampling its neighbours.
- **No `setPivot`.** Reinterpreting an origin adds a second place a piece's
  position comes from, and the next script has to know which one is in play.
  `align` moves the object to put a *face* where it belongs and leaves the pivot
  alone, which needs no state.
- **No caching of `bounds`.** The numbers never change for a live asset, but a
  cached box would keep answering after `unloadUnused()` freed the thing it
  described. Every other handle in this API revalidates on use.
- **No `.gltf` output and no external `.bin`.** A `.gltf` beside a `.bin` beside
  a folder of `.png`s is four things to copy and four things to lose.


- **No line width, and no fourth debug-line shape.** `wideLines` is false on the
  bundled driver, so every line here is one pixel and there is nothing to set.


TODO:

  
  - §1 defects — Linux/Windows never run; WM_DPICHANGED unhandled; Window.width/height stale on Linux; ExportBatch keys
    on (asset, mesh) so sibling nodes collapse onto the first material.
  - §2 — materials nobody disposes are immortal; a stale asset handle is refused at add() rather than at the
    constructor. (The other nine are built — see the `*(Built: …)*` paragraphs. What they left open: normals and
    motion vectors in a post body, downsampled post intermediates and MRT, and metallic-roughness having nothing to
    shade it, which is §12's.)
  - §3 — no crossfade, no morph targets, no sockets; a measured validation gap on the compute→vertex barrier.
  - §4 — KTX2 decode is the big one: grep -rn ktx src test is empty, so every shipped .glb using KHR_texture_basisu
    loads untextured. Plus asset.imageAt(i), async per-mesh load, and the sky.
  - §5 — UI/text entirely unbuilt; input arbitration (the consume flag) is the hard part, and three.controls.enabled
    doesn't answer it.
  - §6 — audio, saving, timers/RNG/structuredClone.
  - §7 — soft bodies, joints, snapshot/restore, character controller.
  - §8/§9 — hot reload, gated on two undecided semantics questions (what happens to a live
    setAnimationLoop/bodies/camera, and what main.js and run_script share).
  - §12 — second light, per-light colour, specular term (which gates roughness/metalness everywhere: §4's maps, §14's
    PBR fields, §16's export).
  - §13 — the material unit, IBL bake, fusing pointwise passes; downsampled intermediates first, then a second tap.
  - §14 — parallax; the PBR half is §12's.
  - §16 — lines don't export.