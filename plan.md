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
away from the camera.

**That paragraph is as much inventory as this file keeps.** What each of those
does is in its own source file, and `git log -p -- plan.md` has the milestone
accounts that used to be here.

	c3c test --trust=full       680 passed, 0 failed, leak-clean

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

- **The frame-tagged deletion queue exists now, for pipelines only.**
  `gpu/retire.c3`: a retired object records the frame ordinal it was given back
  at and is destroyed once `MAX_FRAMES_IN_FLIGHT` frames have started since,
  which the fence wait at the top of every frame path is what makes sound. It
  was built for `PipelineCache` eviction and carries one list, of pipelines.
  Buffers are a second list beside it and the same ordinal — a tagged union
  before there are two tags to carry would be a name for something that has one.
  The unload sweep and `set_material_map` still use `vkDeviceWaitIdle`, which is
  right for a level boundary because a level boundary is already a stall.
  **Trigger:** something unloads during gameplay.

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

- **A uniform table is capped by the 104-byte push budget** — six rows of four
  floats, or eight of three. It was 52 until §15 moved the geometry contract into
  a buffer and gave the block back; a table of hundreds still needs a device
  buffer behind a BDA, which is now a thing this codebase does once and could do
  twice. **Trigger:** something wants more rows than that.

- **Mesh splitting.** Every AI-generated kit ships as one merged mesh; the town
  square needed an external tool to cut three packs into 23 pieces by connected
  components and layout gaps. The ingredients are already on the CPU —
  `hull_positions` and `hull_triangles` are what the picking tree holds, and the
  export proved they are enough to rebuild a mesh from. A split is a
  connected-components pass over the triangles and then `upload_built` per
  component. **Trigger:** an agent generating kits with no person in the loop.
  Until then a kit that arrives merged can be cut in Blender once, and a
  splitter in the engine is a tool that runs at load time forever to fix a file
  that could have been fixed once.

- **Per-material glTF loading has no unit to load into.** `upload_primitive`
  folds `baseColorFactor` and `baseColorTexture` into the `GpuMesh` and drops
  metallic-roughness, normal, occlusion and emissive on the floor. So this is a
  *modelling* decision — what a glTF material becomes on this side — before it
  is a loading one, and that decision belongs wherever PBR does.
  `load_material_images(i)` is the verb waiting for it and the decode memo is
  keyed the way that verb would want. The *shading* half of one of those four
  now exists — a `ShaderMaterial` can declare a sampler, take a linear texture
  and call `mapped_normal` — so a normal map is reachable from a script and
  unreachable from a `.glb`, which is the asymmetry this entry is about. Note
  what the memo would need: it is keyed on the glTF image index alone, and a
  file using one image as both a colour and a data map wants the colourspace in
  that key the way `claim_texture` now has it.

- **`ConvexGeometry` carries no uvs**, so a hull can only ever be flat-coloured.
  The reason is real — a hull's faces meet at hard creases and there is no unwrap
  of an arbitrary one that does not seam — but it is a sharp edge on the only
  escape hatch from the six parametric shapes, and it has already bitten, on
  gable ends built as hull prisms sitting next to a textured roof.
  **Trigger:** anything wanting a textured rock, crystal or piece
  of debris. Triplanar projection in the shader is probably less work than an
  unwrap, and an extrude/prism primitive with real uvs would cover the
  flat-sided cases outright.

- **glTF `alphaMode` is written on export and ignored on import.** A `.glb`
  authored with `BLEND` loads and renders opaque, because consuming it at load
  would mean the loader creating material slots — and the loader has no concept
  of a material at all: `upload_primitive` folds `baseColorFactor` and
  `baseColorTexture` into the `GpuMesh` and there is nowhere for a blend mode to
  live. That is the same missing unit as the per-material-loading entry above,
  and it should be answered once rather than twice. The workaround is one script
  line — `mesh.material = new three.MeshLambertMaterial({ transparent: true })`
  — which is why the export side closed on its own: this engine's own round trips
  are honest, and only somebody else's file is affected. **Trigger:** shipped
  assets that rely on it, or a round trip through a tool that authors blending.

- **The driver's own pipeline cache is not persisted.** `shader/disk_cache.c3`
  keeps the seventeen-millisecond half of a shader — the Slang compile — and
  leaves the remaining millisecond, the driver turning SPIR-V into a
  `VkPipeline`, to be paid on every run. Keeping that half means
  `vkCreatePipelineCache` with a blob read off disk, which is a second binary
  format with a second and stricter validity rule: the blob is only valid for the
  device's `pipelineCacheUUID`, a driver update invalidates it with no error, and
  a driver handed a blob from elsewhere is entitled to do anything at all. So it
  needs the same header, version and identity treatment the shader cache has,
  written a second time, to save about a millisecond per distinct pipeline out of
  a startup that is now under two hundred. **Trigger:** pipeline creation
  measurably hurting startup — a scene with dozens of distinct materials, or a
  post chain rebuilt often enough to notice.

- **The Slang version is not in the shader cache key.** `lib/slang.c3l` exposes
  no compiler version — there is no build tag, no version query and nothing
  version-shaped anywhere in the binding — so a stored module is keyed on its
  source, its entry points, `SLANG_ARGUMENTS` and `SHADER_CACHE_FORMAT_VERSION`,
  and on nothing whatever about the compiler that produced it. Upgrading the SDK
  therefore leaves `build/shader-cache` full of modules built by a compiler that
  is no longer installed, and they will be loaded and used. The manual lever is
  the format version: bump it and every stored module fails the loader's version
  check, which `the_cache_key_covers_the_arguments_and_the_format_version` is
  what keeps in place. The blunt lever is `rm -rf build/shader-cache`. Hashing
  `libslang.dylib` was considered and refused — 35 MB of reading per process to
  save seventeen milliseconds. **Trigger:** a Slang upgrade that emits different
  SPIR-V for identical source. Expect it to arrive as "the shader still behaves
  the way it did before the upgrade", true on a machine whose cache is warm and
  not reproducible on one whose cache is empty.

- **A script cannot say which pass another pass reads.** A pass gets its
  predecessor through binding 0 and the frame the geometry left through binding
  1, and adjacency is the whole edge set — which covers bloom and nothing wider.
  A pass wanting a *third* source, or a downsampled one, is where this grows
  next. **Trigger:** script-authored edges — the point at which no human is left
  in the loop to reason about the dependency. §13 has the argument.

- **A post body sees colour and nothing else.** No depth, no normals, no motion
  vectors, so no depth of field, no SSAO, no fog that respects distance and no
  edge detection that is not luminance-based. The depth image exists and is
  already the right size (`target.depth`), so the cost is not the resource: it is
  that the depth attachment would have to be transitioned to
  `DEPTH_STENCIL_READ_ONLY_OPTIMAL` and back around the post pass, a second
  binding appears in `post.slang`, and `Post` grows a field whose value is a
  non-linear device depth that almost every body would want linearized — which
  means shipping the near/far reconstruction with it or shipping a footgun.
  **Trigger:** a first request for depth-aware post. Do it with `p.depth` already
  linearized to world units, using the camera's derived near and far, rather than
  handing over the raw buffer.

- **`p.time` is a wall clock, not a game clock.** `PostPass` reads
  `clock::now()` at `set` and reports the seconds since, so a post pass animates
  at real-time speed and keeps animating while the simulation is paused, stepped
  or scrubbed. Nothing in `render/post.c3` knows a simulation exists — the frame
  loop's elapsed milliseconds are a `frame_loop.c3` concept and the physics
  world's step count is a third clock again — and picking one of them here would
  be choosing on behalf of a caller that has not asked yet. The workaround is a
  uniform: declare `t` and write it from the animation callback, which is one
  line and gives the body exactly the clock the script means. **Trigger:** a
  screenshot test that has to be reproducible with a post pass active, or a
  pause that has to look paused.

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
- **Reading three passes back**, or a pass fanning out to two consumers. `prev`
  and `scene` are the only two edges.
- **MRT** — a pass writing two attachments.
- **Depth, normals or motion vectors in a post body.** §2 has the cost and the
  instruction to hand over `p.depth` already linearized rather than raw.

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

- **The camera cannot be a game camera.** `three.camera` is a turntable, and
  `yaw`, `pitch` and `distance` *throw* on assignment (`js/prelude/api.js`) —
  deliberately, and §4's half-match rule is right that a name Three.js does not
  have is the honest way to describe a turntable. But there is no third-person
  follow and no first person, so the genre list this engine can express is
  "things you look at". What it wants is a second mode rather than a loosened
  turntable: `camera.attach(object, { offset, lag })`, or a free camera whose
  position and orientation a script owns outright, with the turntable as the
  default nobody has to opt out of. **Nothing gates it.** A follow camera the user
  can still drag would be two things fighting over one matrix, and
  `three.controls.enabled = false` already lets a script say which of the two is
  the author.

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

- **There is no game clock.** §2 already records that `p.time` is a wall clock
  that keeps running while a simulation is paused; the general version of that is
  that nothing in the engine has a notion of game time at all. A script gets
  elapsed milliseconds and owns everything else. What is missing is small and
  load-bearing: `dt`, a `timeScale` that zero means paused, a fixed-step
  accumulator so gameplay does not vary with frame rate, and the single source
  the post chain's `p.time` should have been reading. **Nothing can pause today**,
  which is also why the screenshot-reproducibility trigger in §2 is still open.

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

1. **The camera** — a follow mode and a free mode. Nothing gates it, and it is
   what makes the mouse work already done visible.
2. **Pointer lock**, with §1's live-resize delta, once there is a first-person
   camera to make either of them matter.
3. **The clock**, because everything after it is written against `dt`.
4. **The character controller**, then **animation blending** — the point at which
   there is a thing to move and it looks like it is moving.
5. **Navigation**, then the **queries** and **steering** that make it a crowd
   rather than one agent.

### What this does not cover

**No ECS, and no gameplay framework.** That stays where the closing section puts
it: the scene graph is the entity list. Everything above is a *primitive* a
script calls, and the moment one of them starts owning a game's update order it
has become the wrong thing.

**No claim about which of these a game actually needs.** Reading found them;
using would rank them. The first real game built on this engine is the
measurement this section does not have.

---

## What is deliberately absent

- **No `BufferGeometry` and no attribute access.** That is the thesis. Nothing in
  eight milestones has needed one, and a game is the workload that would be worst
  served by it. `ConvexGeometry`'s point cloud is a description too — most of the
  points are discarded and none can be read back.
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
  count. The counting itself was swept; `git log -p -- plan.md` has it, including
  the one place it was out by.
- **What stays absent from the chain: named passes, edges, removal from the
  middle, and downsampled intermediates.** A pass reads its predecessor and the
  original frame and nothing else, so a bloom pyramid at ½ and ¼ is the piece that
  grows first (§13's "what this does not cover"), and reordering is a `setPost`
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
- **No skin in the export.** `scene/export.c3` writes geometry, materials and
  nodes; a rigged character round-trips as its bind pose with no `skins` and no
  `JOINTS_0`/`WEIGHTS_0`. The reading side is built (§3) and the writing side is
  work rather than a decision — `gltf.c3l`'s `add_skin_binding` and
  `add_skeleton` are what it would go through. Listed here so that a round trip
  through `scene.export()` is known to lose the rig rather than discovered to.
- **No `.gltf` output and no external `.bin`.** A `.gltf` beside a `.bin` beside
  a folder of `.png`s is four things to copy and four things to lose.
- **The export writes no camera.** glTF has one and this project has a turntable,
  which is not a `perspective` camera with a transform — inventing one would be
  exporting a fiction as though it were content. (It used to write no *light*
  either, for the same reason. §12 made the light addressable, so that half is
  work rather than a decision now, and it is listed there.)
- **No per-instance texture, and no alpha-to-coverage.** Blending itself is done:
  a blend mode is a `PipelineState` field and a cache key (dynamic blend state is
  unusable here, §10), `mesh.color.a` fades one copy of a shared draw call, and
  every transparent bucket is sorted farthest-first against the near plane and
  recorded after the opaque ones.

  What is still absent, and why. **Per-instance texture**: an instance carries a
  colour and a variant, and a texture per copy would need bindless or an atlas,
  either of which changes what a draw call is. **Alpha-to-coverage** — still the
  cheaper first answer for cutouts than sorting — is static pipeline state that
  needs a multisampled target, and the offscreen one is not multisampled.
  **Sorting inside one instanced bucket**: copies fused into a single draw cannot
  be depth-ordered against each other, which is three.js's limit too, and the
  cost of the fix is the batching this project exists to keep.
- **No line width, and no fourth debug-line shape.** `wideLines` is false on the
  bundled driver, so every line here is one pixel and there is nothing to set.
- **No helper that follows its object.** `BoxHelper.update()` is called by hand,
  as Three.js's is. Making it automatic means either a per-frame walk that costs
  every scene with no helpers in it, or a dirty flag on every object for the
  benefit of a debug tool — and the failure it would prevent is visible in the
  picture the helper is being looked at in.

