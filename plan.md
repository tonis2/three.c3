# three.c3 — what is left

This file is the whole plan. Everything it used to contain about work that is
finished has been deleted, because a plan that describes what already happened
is a document nobody can tell the live parts out of.

**That deletion is a habit, not a one-off event.** This file has been swept again
since — the milestone-by-milestone account of the texture work, the light binding,
the physics bindings and the whole record of building the post chain came out,
because each had turned into a description of the code rather than a claim about
it. `git log -p -- plan.md` is where those went, and the rule going in is the same
as the rule that made this file: **when an entry stops being a decision anybody
still has to make, it belongs in history.**

**The source still cites them by name, and that is on purpose.** Fifty-odd doc
comments carry references like `game.md` G5/S3, `event_loop.md`, `m3_stage.md`
and `base_stage.md` — `git show` above resolves every one, and rewriting fifty
comments to say "see git" would trade a precise citation for a vague one.
`base_stage.md` was already only in history before this file was rewritten, so
the pattern predates the deletion rather than being introduced by it.

	git grep -n 'game\.md' -- src test        # find them all

---

## Where this stands

A window, a Vulkan device, an offscreen target the swapchain blits, and an exact
screenshot. A scene graph with world-matrix propagation, asset and texture dedup,
frustum culling, and **one instanced draw per unique `(asset, mesh, material)`**.
QuickJS with a Three.js-shaped API in `src/js/prelude/` and three MCP tools over
it. Slang compiled at runtime and cached to disk, with the descriptor layout and
push block read out of the module. Picking, parametric shapes, per-copy colour
and variant, transparent and additive materials. The window as a control, and a
frame a script can drive. Measuring, debug draw, and glTF export that round-trips
per-copy colour. A game boot, unloading, node animation, and an XPBD physics
world. Textures from a file, from a script and from a `.glb`, all three sharing
one content hash. Colour management end to end. One directional light. Keys a
script can hold down and a budget it can raise. `stats().gpuMs` measured by the
GPU rather than guessed at. And a post chain — `three.setPost` and
`three.addPass`, linear float between passes, an engine-owned tonemap doing the
display encode last. And material layers — glTF's `CUSTOM_materials_layers`
imported from a file or written in a script, generating its own shading body.
Per-draw data is a record in a buffer rather than push constants, so the geometry
contract and a material's uniforms have stopped competing for the same 128 bytes:
vertex colours are carried and a material has 104 bytes of uniforms rather than 52.

	c3c test --trust=full       617 passed, 0 failed, leak-clean

**What follows was found by using the engine, not by reading it looking for
holes.** Each one stopped the work, and where it forced a workaround the
workaround is named, because that is the honest measure of what a gap costs.

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

- **`WM_DPICHANGED` is not handled** (win32). The awareness context requested is
  per-monitor, so a window dragged between displays of different densities keeps
  the size it was given. The parts that read the scale every frame — the cursor,
  a pan — follow the new display correctly; the window's own size does not.

- **`Window.width`/`height` go stale on Linux.** `getMousePos` flips y against
  them and they are only ever what `new` was asked for, so a resized window
  reports a cursor offset vertically by however much it grew. The win32 backend
  reads `GetClientRect` for exactly this; x11 and wayland could ask their own
  equivalents. Not fixed because it cannot be seen from this machine.

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

**Built, and not the design this section described.** S1–S4 assumed a **live
palette**: joint matrices recomputed per instance per frame and uploaded, costed
here at ~192 KB a frame for fifty characters. What was built instead is a **baked
pose buffer** — every clip of every skin sampled once at 30 fps into a
device-local table, and an instance names a frame with one `uint`. Both exist
now; the live palette is the second of three paths rather than the only one.

**The three paths, and one shader contract.** `Instance.pose` is an offset in
matrices with a selector in its top bit, so which buffer a copy reads is a
property of the *instance* and not of the bucket — which is what lets a hero
character and the crowd behind him share a `vkCmdDrawIndexed`:

| | pose from | blend in | for |
|---|---|---|---|
| default | the baked table, keyed by frame | vertex shader | crowds |
| `skeleton: true` | bone nodes, per frame | vertex shader | IK, look-at, a bone a script writes |
| `skinning: 'compute'` | either | a compute dispatch | a mesh drawn in more than one pass |

**What the baked path costs and buys.** A hundred characters mid-stride at a
hundred phases differ by one `uint` each, so the per-frame cost of the crowd is a
hundred integers and the palette upload the old S2 costed does not exist. It also
cannot tear — `gpu/buffer.c3` records that crig's pose palette did, and an
immutable table has nothing to tear. The price is memory (60 joints × 30 fps ≈
115 KB per second of clip, reported as `stats().poseBytes`), time quantised to
the bake rate, and no blending between clips.

**A character is two nodes, not sixty-two.** Joint-only nodes are pruned at
instantiation — kept only when something hangs off them, so a prop in a hand keeps
its chain — and a skinned mesh becomes a child of the group with an identity
transform, because glTF says its own node transform is ignored and the scene graph
is the honest place to say that. `Instance.model` needs no special case as a
result.

**S3 was right and pointed the wrong way.** It warned that reporting a skinned
bucket like an instanced one would hide a per-frame upload. There is no per-frame
upload behind a baked character, so the hidden cost is the pose memory instead,
and `stats()` reports `skinnedDraws`, `skinnedInstances`, `preskinnedInstances`
and `poseBytes` separately for that reason. The check was written before the code,
as S3 asked.

**S4 stands.** A skinned mesh's `TriBVH` is its bind pose and picking still
answers against a box — but the box is now the union of every baked frame rather
than the bind pose's own, which the same bake computes for free and which culling
uses too. A character with its arms up is no longer culled by the box its
modeller drew.

**On the compute path, honestly.** It does the same arithmetic the vertex shader
does, plus 24 bytes a vertex written, read back, a dispatch and a barrier — and a
posed copy of the mesh per instance per frame in flight. Under one pass it is
strictly more work, and it was built anyway for two reasons that are not
speculative: shadows are a known coming pass (§13) and it is the only way to
raycast against the pose rather than the box. It is opt-in per character and it
splits the bucket. **Do not route a crowd through it.**

**What is still absent.** No blending or crossfade between clips — G3/S7's
argument is unchanged and the live palette is where it would land. No morph
targets. No sockets: a bone's world transform is recoverable from the baked table
as `pose * bind` and `AssetSkin.bind` is kept for it, but nothing reads it yet.

**One check does less than its name suggests, and says so.**
`the_skinning_paths_are_silent_under_validation` covers the dispatch's arguments
and the buffer lifetimes; it does **not** cover the compute→vertex barrier.
Deleting that barrier leaves the test green, with the ordinary layer and with
synchronization validation requested through `create_instance(sync: true)`. This
machine's layer does not report the hazard. The barrier rests on the spec and on
review — measured, not assumed, and worth repeating the injection anywhere the
layer is fuller.

---

## 4. Textures, async load, and a sky

*(was G6)* **Two things wearing one coat, and the sequencing matters more than
the parts.** `lib/ktx.c3l` is already in, ahead of the milestone that uses it.

**A roughness map has nowhere to go, and that is a lighting decision rather than
a texture one.** Mips and colourspace are closed — `three.texture(path, {
colorSpace })` uploads UNORM, the chain is generated by blit, and
`mapped_normal` in `shaders/material.slang` rebuilds a tangent frame from
derivatives so a normal map works on a mesh with no tangents. What a roughness
or metalness map still lacks is a term to feed: the built-in light is one
lambert factor with no specular, so the map loads correctly and only a custom
`shade` body can do anything with it. **Do not add a roughness input to
`mesh.slang` before deciding what §12 does about lighting** — a specular term
and the light that drives it are the same decision, and a roughness map wired
into lambert would be a field that changes nothing. §14 is where that rule was
tested against a feature that wanted the fields and did not get them.

**The sampler budget is 8 rather than 4** since §14: a generated layer stack
needs one binding per layer plus one for the packed mask, and four bought three
layers with no room for a normal map on any of them. `MATERIAL_TEXTURE_LIMIT` has
what the extra four cost.

**Meshes carry COLOR_0 as of §15**, read by a body as `s.vertex_color` and by a
vertex body as `v.vertex_color`. It is deliberately *not* folded into `s.albedo`
the way the per-instance colour is: applying it would change how every file
already loaded renders, and the thing that made the stream exist reads the
attribute as a painted weight rather than as a tint. A body that wants glTF's own
rule writes `s.albedo * s.vertex_color.rgb`.

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

- **Shadows.** Not on the list and not obviously wrong to omit, but a game
  without them looks flat in a way no amount of material work fixes. A single
  directional shadow map is the cheapest thing that would change how every
  screenshot in this project looks. **Worth a decision before §3 or §4**, because
  it touches the same shader either way.

- **Hot reload semantics.** What happens to a running `setAnimationLoop`, to live
  physics bodies, to the camera. See §8.

- **What `main.js` and `run_script` share.** They share globals by design — so
  what happens when an agent's script redefines something the game holds a
  reference to? Probably nothing good, and probably acceptable, but it should be
  a known answer rather than a discovered one.

- **Should a script be able to turn the mouse controls off?** `onClick` gave a
  script half the mouse, and the half it did not give — the drag — is the half
  the camera owns. A scene wanting its own drag behaviour has no way to ask.
  `three.controls.enabled = false` is cheap, but it is one more piece of state a
  script can leave in a bad way, and a window nobody can move the camera in is a
  bad way.

- **Should a click be able to say it was handled?** A handler returning `false`
  could suppress the orbit for that gesture — the browser's `preventDefault`, and
  the natural answer to the question above. It is also a rule that has to be
  explained, for a conflict a four-pixel click barely has. **§5's input
  arbitration forces this one**, so decide it there if not before.

- **Does the camera belong to the scene?** The camera survives
  `new three.Scene()` today, so a script that rebuilds the scene keeps whatever
  the user dragged it to. That is almost certainly right for a person watching the
  window, and it is worth writing down before something changes it by accident.
  The animation callback survives a rebuild too, and *that* one is decided and
  tested: the loop belongs to the host as Three.js's belongs to the renderer, so a
  rebuild does not silently lose the animation — what it loses is every handle the
  callback captured, and the stale-handle throw stops it with a sentence rather
  than leaving it running against nothing.

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

1. **Skinned buckets report distinctly in `stats()`** (§3/S3), asserted against a
   scene containing both a skinned and an instanced bucket.
2. **The physics world is deterministic** — two worlds given the same inputs
   produce the same `state_hash` after N steps, and a `snapshot`/`restore` round
   trip reproduces it. The library supplies the mechanism; the binding is what
   could break it, by stepping at a rate that depends on the frame.

---

## 12. Lighting

**There is one directional light and it is four floats** — `three.light.direction`,
`three.light.ambient`, and `three.light.set(direction, ambient)` for both. It is
deliberately not `scene.add(new three.DirectionalLight(...))`: that name would
promise adding, removing, colouring and duplicating, and this renderer can do none
of them. Whatever comes next has to keep that honesty rather than inherit the
Three.js name and disappoint it.

What is next, in the order they stop being optional: a second light, or a list;
a colour per light rather than white; and shadows, which are a depth pass, a
matrix and a comparison sampler, and are the largest single visual gap left after
the sky in §4. Now that the binding exists, which of them anybody actually misses
is a question that can be answered rather than guessed — which was the argument
for doing the binding first.

**A specular term belongs on that list and is what a roughness map is waiting
for.** §4 can now load one in the right colourspace and has nowhere to send it:
`lambert()` is the whole of the built-in light, so roughness and metalness are
inputs to an equation this renderer does not evaluate. That makes them one
decision and not two — do not add a roughness field anywhere before the term
that reads it exists, or it is a material property that provably changes no
pixel.

**§14 held that line under pressure and is the precedent.** Material layers
landed with the extension's metallic, roughness and subsurface fields *parsed,
dropped at the importer and refused by name at the JS boundary* — the first time
this rule cost a feature something visible rather than merely deferring one. The
images those fields name are not even uploaded. When the specular term arrives,
`GpuLayer` in `scene/asset.c3` is where the three fields go back in, and the
refusals in `js/prelude/layers.js` are what get deleted.

**And the exporter still writes no light.** Not writing one used to be the right
answer, because a hardcoded directional term is an implementation detail rather
than content; binding it changed that and nothing followed. One directional light
and an ambient floor map onto a glTF `directional` light and nothing else, which
is a small and honest write.

---

## 13. The pass system, and what it is not

The chain is built (`render/chain.c3`). What is left of this section is the part
that constrains what lands on top of it — shadows, a UI layer, PBR — and the one
trigger that would turn the frame's list into a graph.

### The counting the no-graph answer rests on

A frame is `scene ─► target.color ─► blit` with no post pass and
`scene ─► A ─► P0 ─► … ─► tonemap ─► target.color ─► blit` with one: five owned
images and `3 + N` barrier call sites, every one of them coming out of
`color_attachment_barrier` or `shader_read_barrier`. What the named features add:

	shadows        +1 site   the shadow map's attachment transition. The read-side
	                         transition folds into begin_render_to's existing
	                         two-element array. Cascades are layers of one image:
	                         more draw calls, the same two transitions.
	UI             +1 site   or zero. Same target.color, LOAD_OP_LOAD, a different
	                         pipeline, no attachment of its own.
	depth in post  +0 sites  two more elements in arrays that already exist.
	               ────────
	               ~7 total

Seven is not a number that buys a dependency solver. **UI is the one that looks
expensive and is not:** it draws into the colour attachment everything else
already writes, so it costs a pipeline, a vertex buffer and a glyph atlas, and
nothing whatever in scheduling — `pushDescriptor` means the atlas is one more
`SampledBindings.add`, exactly like a material texture. The expensive half of a UI
layer is text layout and hit-testing, and no pass system touches either.

### What the driver offers, measured

Probed rather than assumed, by the method §10 insists on — a temporary test
calling `vk::getDeviceExtensions` and one chained `getPhysicalDeviceFeatures2`,
run once and deleted:

	device               Apple M5, KosmicKrisp (lib/Vulkan.c3l/macos-aarch64)
	apiVersion           1.4.359
	device extensions    144
	maxPushConstantsSize 256

	dynamicRenderingLocalRead    true
	unifiedImageLayouts          true
	hostImageCopy                true
	maintenance5, maintenance6   true
	pushDescriptor (1.4 core)    true
	VK_EXT_shader_object         absent

§10 carries the `VK_EXT_extended_dynamic_state3` half of the same run: every
colour-blend bit false, so **a blend mode stays a `PipelineState` field**.
`VK_EXT_shader_object` being absent is the other half of that — it is the
extension that would have removed pipeline objects outright, and with them the
"am I last" variant problem the format rule below exists to solve.

**`IMAGE_LAYOUT_GENERAL` was tried, measured and reverted — do not try it again
without reading this.** It has been legal on every device since Vulkan 1.0, and
`VK_KHR_unified_image_layouts` — the promise that it costs nothing — is present
here because Metal has no layout concept at all. So the argument for adopting it
is sound right up to the last step, and the last step is where it dies: **core
validation catches a missing barrier by noticing an image is in the wrong
*layout*, and that is the only mechanism it has for this.** With every image in
GENERAL there is no layout left to be wrong. Measured rather than reasoned:
deleting `shader_read_barrier` from the post pass produces
`VUID-vkCmdDraw-imageLayout-00344` today and left **all 18 post checks green**
under GENERAL. Synchronization validation does not fill the hole on this driver —
enabled three ways, including the layer's current `VK_LAYER_VALIDATE_SYNC=1`, the
missing barrier still reports nothing.

That inverts the trade for **this** project specifically, and `test/post_test.c3`'s
own header says why: a missing barrier renders correctly on this driver and is a
race everywhere else, so the layout bookkeeping is the only instrument standing
between the two. **A simplification that removes a mistake nobody is making, at
the cost of an instrument that catches one they might, is not a simplification.**
The bookkeeping reads like ceremony precisely because it has been working.
Anything proposing to delete a safety mechanism should be asked to show what still
catches the failure afterwards, and the way to ask is an injection rather than an
argument.

**`dynamic_rendering_local_read` is the live one, and it is step 7 below.** Within
one `cmdBeginRendering` block it can read attachments
written earlier in that block — the extension mobile deferred renderers live on,
and an Apple tiler is its home. Fusing the tonemap into the scene's block would
cost no image and no round trip: the HDR attachment is `STORE_OP_DONT_CARE` and
on a tiler need never reach main memory, which is ~8 MB of write plus 8 MB of read
a frame at 1080p that image A otherwise spends.

**The hard limit is same-pixel only** — no neighbour sampling — and it splits post
passes in two:

	fusable      tonemap, exposure, colour grade, vignette, depth fog,
	             soft particles. Same pixel. No image, no barrier.
	not fusable  blur, bloom, depth of field, SSAO, edge detect.
	             Neighbourhood reads. The ping-pong chain as designed.

And **fusion and sampling want different images**: local read needs
`INPUT_ATTACHMENT` usage and wants `TRANSIENT_ATTACHMENT` with lazily allocated
memory to earn the memoryless win; the chain needs `SAMPLED`. One image cannot be
both to any effect. So this is not a flag to flip — it is a second path, which is
exactly why the chain was built first: it is correct on any driver, the fusion is
identical output with less bandwidth, and designing the general case around the
special one gets both wrong. **Trigger:** a measurement.

It also nearly dissolves §2's depth-in-post entry for the pointwise half. Depth
becomes an input attachment in the block that is already using it, so the
transition to `DEPTH_STENCIL_READ_ONLY_OPTIMAL` and back stops existing — for fog
and soft particles, which want the same pixel. Depth of field and SSAO want
neighbours and stay where that entry left them.

**`PipelineState` keeps all four fields, and a fifth state is the next question.**
`DYNAMIC_STATE_DEPTH_TEST_ENABLE` and `…WRITE_ENABLE` are free for the asking, and
taking them would still buy nothing: every `PipelineState` in the program is one
of four constants, and `state_for_blend` (`scene/material.c3:164`) is a pure
function from `BlendMode` to one of them — there is no site anywhere that builds a
state with an independent depth choice. Written out:

	                topology       depth_test  depth_write  blend
	SOLID_STATE     TRIANGLE_LIST  true        true         NONE
	LINE_STATE      LINE_LIST      false       false        NONE
	ALPHA_STATE     TRIANGLE_LIST  true        false        ALPHA
	ADDITIVE_STATE  TRIANGLE_LIST  true        false        ADDITIVE

`(depth_test, depth_write)` is a **function of `(topology, blend)`** — no two rows
share the left pair and differ on the right. Dropping both fields therefore
changes the pipeline count by exactly zero, today and for as long as those four
are the only states.

And the cost is not zero. Two commands per bucket is the small half. The real one
is that `ALPHA_STATE`'s doc comment is where the argument lives for why a
transparent instanced draw must not write depth — copies inside one bucket are not
sortable against each other, so a depth write makes visibility depend on
rasteriser order — and `material.c3:161` already records that writing
`depth_write: true` by hand *looks* right in any scene where nothing overlaps
itself. Moving that choice from a named constant to a call site turns a
guarantee into something each bucket can get wrong, in exchange for nothing.

**Trigger:** a pass that genuinely wants a depth combination the four states do
not have. A UI layer is the likely first one — alpha blending with the depth test
*off* is not among the rows above — and at that point the question is whether it
is a fifth constant or a dynamic state, which is a question worth having a real
case for.

**Deferred: `hostImageCopy`.** `vkCopyImageToMemory` moves image data to host
memory with no staging buffer, no command buffer and no submission, which is
`Target.create_readback` + `record_readback` + `decode_readback` collapsing toward
one call, and the same for `gpu/texture.c3`'s upload. It went core in 1.4, so
every 1.4 device has it and desktop NVIDIA, AMD and Mesa all ship 1.4. Held back
anyway: it is a readback convenience rather than a pass change, it blocks nothing,
and it needs `HOST_TRANSFER` usage set at image creation — so it belongs with the
IBL bake, decided once rather than twice.

### Three kinds of pass, and they do not unify

	1. geometry     scene, shadow. Driven by the scene graph, write attachments.
	                gpu, cmd, target, frame slot, instance buffer.
	2. full-screen  the post chain, tonemap. Driven by a list.
	                cmd, target, source view, destination view, assets.
	3. one-shot     mip generation, an IBL bake. Run at load, write persistent
	                textures. No per-frame command buffer at all — texture.c3's
	                @single_time_command is already this, and is where a bake goes.

Unifying all three under one abstraction is what a render graph attempts, and it
is where a graph earns its complexity in an engine with fifteen passes. Here #3
already has a working home, #1 is two stages, and #2 is a list. **Three small
mechanisms that each fit cost less than one that fits all three approximately.**

The line worth writing down, because it says what not to force: the chain is
*full-screen 2D passes over the finished frame, at target extent*. An IBL bake
fails every clause — cubemap, mip chain, wrong extent, runs once, writes a
persistent texture rather than `target.color`.

**PBR is not a pass and does not appear in this list.** It is a BRDF in
`mesh.slang` plus material parameters with nowhere to live, which is §2's
"per-material glTF loading has no unit to load into" — a data-model blocker, not
a scheduling one. The only place PBR touches this section is the format decision
below, and that touch is load-bearing.

### The frame is a list, not a graph

`record_scene` is a sequence with the destination decided once at the top, so a
shadow pass and a UI layer slot into it as lines rather than as nested ifs — the
"window shows something the screenshot does not" family of bug is what that
function exists to prevent:

	if (self.shadows.active) self.shadows.record(cmd, &self.scene)!;
	self.target.begin_render_to(cmd, scene_destination);
	self.draw(cmd)!;
	if (posted)  self.post.record_chain(cmd, &self.target, final_color)!;
	if (overlay) self.ui.record(cmd, &self.target);
	self.target.close(cmd);

**The invariant a third stage would break: exactly one stage writes
`target.color`, and the close happens exactly once, here.** It is enforced rather
than merely written down. A second close is a transition out of
COLOR_ATTACHMENT_OPTIMAL on an image the layer knows is in TRANSFER_SRC, so
`the_post_pass_is_silent_under_validation` and `a_chain_is_silent_under_validation`
both fail on it with `VUID-VkImageMemoryBarrier2-oldLayout-01197` — verified by
injecting a second `self.target.close(cmd)`, not by reasoning about it. That is
the thing to know before a shadow pass and a UI layer are added on top of it.

Each stage keeps its own honest signature. A common `record(PassContext*)` across
all three kinds would need a context carrying gpu, cmd, target, slot, assets,
scene, src view, dst view and extent, with every pass reading three of the nine —
and the specific loss is that you could no longer tell from a signature what a
pass touches, in a file where every doc comment exists to say exactly that.

### The chain: three images and two rules

	pass i    reads  P[(i-1)&1] as `prev`, A as `scene`
	          writes P[i&1]
	tonemap   writes target.color

Three images regardless of chain length: A, what the scene renders into, plus two
ping-pong images allocated lazily, so a runtime that never sets a post shader pays
for nothing. N = 1 allocates P0 and not P1, and is two draws rather than one —
the price of user passes having no format to get wrong, paid only by frames that
asked for a post pass.

Each pass issues one `color_attachment_barrier` and the chain closes each
destination with `shader_read_barrier`; `color_attachment_barrier` discards from
`UNDEFINED`, which is already correct for reusing P0 on pass 2 after pass 1
sampled it. **No new barrier code — the existing two functions called N times.**

**Two bindings are reserved, and that is what covers the one non-adjacent read
anybody actually wants.** Binding 0 is `prev`, binding 1 is `scene`, always
available, because bloom is `blur(bright(scene)) + scene` and needs the original
three passes later. *The edge people reach for a DAG to express is a binding, not
a solver.*

The cost is that the first free texture binding is not one number:
`MATERIAL_BINDING_FIRST` is 1, `POST_BINDING_FIRST` is 2, and both are parameters
of `assemble_shader`, `SampledBindings.collect` and `sampler_binding_of`. A shared
bump instead would silently renumber every material sampler. `TextureSlots` is
indexed by the **absolute** binding for the same class of reason: carrying a base
into the accessors would mean a call site passing a material's base for a post
pass read a real texture out of the wrong slot rather than faulting.

**A reserved binding has to be checked against the reflected layout, not
assumed.** Slang drops a parameter nothing reads, so a body that never touches
`p.scene` gives it every reason to drop `scene` — and pushing a descriptor for a
binding the layout does not declare is a validation error.
`pipeline_declares_binding` asks by index what `sampler_binding_of` asks by name.

### The format rule, and why the scene is not HDR yet

> **Every script-authored pass reads float and writes float. A fixed,
> engine-owned tonemap pass is the only thing that writes `target.color`.**

That is the rule any new pass has to hold, and the reason is that without it *"am
I last"* becomes a pipeline variant: the same body at slot 3 and at slot N would
be two different `VkPipeline`s, output format would enter the cache key, and
reordering the chain would be a recompile. With it there is one pipeline shape for
every `addPass` body, one fixed pipeline for the encode, no format in the key, and
free reordering. `POST_CHAIN_FORMAT` is `R16G16B16A16_SFLOAT`; `TONEMAP_BODY` is
the one caller that passes `target.color_format`.

**Image A — what the *scene* renders into — is not part of that and stays
`_SRGB`.** A scene pipeline's colour attachment format is fixed when the pipeline
is built and dynamic rendering checks it against the attachment, so a float A
makes every mesh pipeline wrong the moment a post pass is set. The two ways out
are both large: a second variant of every mesh pipeline keyed on whether post is
active, which puts a format in the pipeline cache key and makes `setPost` rebuild
every material's pipeline — the precise thing the rule above exists to avoid, one
layer down; or rendering the scene into A always and tonemapping every frame of
every scene, which deletes the property that an unposted frame is *the code path
it always was* rather than a new one that agrees with it.

Neither buys anything today, and that is what settles it: **nothing in this
renderer produces a value above 1.0.** What HDR is actually blocked on is physical
light intensities — step 4's material unit — and when the scene becomes HDR, A
joins the chain's format and the always-on path becomes the right answer for a
reason that will exist by then. The chain itself already carries values above 1.0
between passes, which is what a bright pass followed by a blur needs;
`the_chain_carries_values_above_one_between_passes` pins it by injection — the
chain's format set to `R8G8B8A8_SRGB` clamps a ×16 ÷16 round trip by 70 levels.

**The lesson is the same shape as the GENERAL one:** "one line" was a claim about
the *edit*, and the cost was in what the edit was declared against. A format that
lives on a pipeline rather than on an image is not visible from the image, and the
way that surfaces is writing the line and compiling it rather than counting the
files it touches.

### The interface, scoped to one kind

C3 interfaces fit the full-screen chain and nothing else here, because that is the
one kind whose contract is uniform across implementers: read one full-screen image,
write another at the same extent. A user pass is one shader; an engine-provided
bloom is internally a pyramid of twelve. Same contract, different types — which is
what dynamic dispatch is for.

	<*
	 One full-screen pass over the frame.

	 **The protocol, which the interface cannot express and every implementer
	 must honour:** on entry `src` is in SHADER_READ_ONLY_OPTIMAL and `dst` is
	 in whatever last frame left — open it with `color_attachment_barrier`,
	 which discards from UNDEFINED. On exit `dst` is in
	 COLOR_ATTACHMENT_OPTIMAL with rendering ended. `target.depth` is not yours.
	*>
	interface FullscreenPass
	{
		fn void? record(vk::CommandBuffer cmd, PassIo io);
		fn void? resize(Gpu* gpu, vk::Extent2D extent) @optional;
		fn void free(Gpu* gpu) @optional;
	}

Both halves of that protocol are real and neither is expressible in a signature.
The layout half is at least *checked* — the GENERAL entry above is the whole story
of finding out that it is the only half core validation can check, which is why it
is still there to be got wrong.

`PassIo` is seven fields and none beyond the obvious three is padding: `prev` and
`scene` are two sources because the chain has two edges; the destination arrives
as an image *and* a view because the pass opens it with a barrier and a barrier
names an image; the sampler is the chain's; and the asset table is what a pass's
own samplers resolve through. What stays absent is the list that matters — no
`Gpu`, no `Target`, no frame slot, no scene, no instance buffer.

**Why not across all three kinds.** An interface types the arguments; it cannot
type the layout protocol. Applied to geometry and full-screen passes together it
would grant compile-time substitutability the GPU does not honour — the compiler
would accept a shadow pass in a full-screen slot, and the failure is a validation
error in a debug build or a black frame in a release one, and since `-D DEBUG`
(`src/debug.c3`) the release build is the one without the layer. The passes simply
having different functions with different arguments prevents that outright, and
that is the stronger guarantee.

Two C3 facts that cost time to find, and that a second implementer will need:

- **Interface values are pointers.** A `List` that grows invalidates every
  interface value taken from it, and `addPass` mutates the list at arbitrary
  times. Take them fresh from `&list[i]` each frame; never cache one.
- **A struct must declare the interfaces it implements** — `struct PostStage
  (FullscreenPass)`, not merely having the methods; `@dynamic` on the methods
  alone gives "'PostStage*' cannot be implicitly cast to 'FullscreenPass'". The
  receiver is implicit in the declaration and explicit in the implementation
  (`fn void? PostStage.record(&self, …) @dynamic`).

`FullscreenPass` is still the project's only interface, and `src/` has `@dynamic`
nowhere else. That is the argument for having introduced exactly one, where it
pays, rather than four.

### What this does not cover

- **Downsampled intermediates.** A bloom pyramid at ½, ¼, ⅛ means per-pass
  extents, so P0/P1 become a pool keyed by extent. Still not a solver, but not two
  fields either. This is the piece that grows first.
- **Reading three passes back**, or a pass fanning out to two consumers. `prev`
  and `scene` are the only two edges.
- **MRT** — a pass writing two attachments.

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
**What doing them was worth beyond the code:** two of the driver batch's four
items did not survive being written down against the actual source. One died on
reading four constants, the other on an injection test, and both would have been
far more expensive to discover with a post chain, a shadow pass and a UI layer
already built on top of them. That is the argument for taking a cheap,
independent, fully-tested batch first, and it is a better argument after the fact
than it was before it.

### Why not a render graph, and what would change it

A graph's executable form *is* a list — the topological sort is a preprocessing
step that produces one. But the sort is not what a graph is for. The **edges** are,
because barriers and resource lifetimes are derived from them. And that is the
whole argument for the shape above:

> **In a chain, adjacency is the edge set.**

A general DAG needs explicit edges precisely because list position no longer tells
you who reads whom. A chain does not have that problem, so constraining the
topology buys the derived barriers back for nothing.

`three.addPass` does not undermine this. It makes the *order* script-authored, and
insertion order is already the topological order — there is no ambiguity for a
sort to resolve, and you would have to make the API worse (declare dependencies
without declaring order) to manufacture one.

**Trigger:** script-authored *edges* — a script naming which pass's output another
pass reads, where the answer is not its predecessor. That is the point at which no
human is left in the loop to reason about the dependency and a solver is the
honest answer. Pass count is not the trigger and never was.

---

## 14. Material layers

**Built.** `three.LayeredMaterial`, `asset.mesh(name).layers`, and the importer
behind them — glTF's `CUSTOM_materials_layers` as far as this renderer can
honestly take it. `lib/gltf.c3l` had parsed the whole extension for a while and
nothing read a field of it; `rtk grep layers_ext src/` was empty.

**It is a generated `ShaderMaterial` and not a new tier.** A layer stack is a
fragment function that samples several images and mixes them, which is exactly
what §4's tier 2 is, so `js/prelude/layers.js` writes the Slang and hands it to
the same `createMaterial` a hand-written body goes through. No pipeline kind, no
descriptor layout and no push contract is new. `mat.fragment` is the generated
source, which is the thing to read first when a stack looks wrong.

**Most of a layer is a compile-time constant, and that is the whole economy.**
The obvious implementation pushes per-layer parameters as uniforms and loops;
that one could not exist when this was written, because 52 bytes is three float4s
and a stack of four would have been out of room before its first texture. §15 has
since made it 104, and the argument is unchanged: six float4s is still not a layer
stack. It is also unnecessary: the
generator knows the description, so a blend mode picks which expression is
emitted, a mask channel becomes `.g`, `invert` becomes a `1.0 -`, and
`enabled: false` omits the layer *and its samplers*. Only `animated: true` spends
push bytes — one float4 for a layer's tint and opacity, six of them at most.

**A layer states a colour only when it has one to state.** White is what
`baseColorFactor` defaults to in the file and what a script leaves out, so it is
the absence of a statement rather than a request for white paint — and a layer
with no map and no tint emits no colour blend at all. That was not the first
implementation, and the first one was wrong in two directions at once: a layer
that only glowed bleached what was under it, and a layer that only added surface
detail did the same while looking like its mask was inverted. Painting white
deliberately is a white `map`, which is visible in the description.

So the ceiling is samplers rather than uniforms, which is the right way round.
**`MATERIAL_TEXTURE_LIMIT` went 4 → 8** for this: four bought three layers over
the base with no room for a normal map on any of them. It is a budget rather than
a device limit — `maxPushDescriptors` must be at least 32 — and what it costs is
per-bucket descriptor traffic on every material that declares a sampler.

**The masks pack into one image's four channels**, which is what the extension's
per-layer `channel` field exists for and what makes a four-layer terrain one
binding instead of four. The extension has no shared-mask object, though — the
sharing is implicit in several layers naming one `textureInfo` — so
`hoist_shared_mask` in `scene/asset.c3` makes it explicit at import. Without the
hoist a file renders identically and spends bindings it did not need, which stays
invisible until a layer is refused against a budget that was never really full.

**A mask is a weight and not a colour**, so it uploads `LINEAR`. That forced
`ImageMemo` to carry the colourspace: `claim_texture` already treated the space as
part of a texture's identity, and the memo standing in front of it did not, so one
glTF image used as a base colour by one material and as a mask by another was
answered with whichever format arrived first. The picture is right either way and
every weight is wrong by the sRGB curve — `three_tests::layers` has the check that
fails when the field is removed.

### What it refuses, and why refusing is the feature

- **`metalness`, `roughness`, `metallicRoughnessTexture`, `subsurface`** — §12's
  decision, held. `lambert()` is the whole of the built-in light, so these feed an
  equation nothing evaluates. They are dropped by the importer rather than carried
  to JS, and named by the JS API rather than ignored: a material property that
  provably changes no pixel costs more to discover than an error does.
- **`heightTexture` and `bump`** — no tessellation and no parallax.

**A `VERTEX_COLOR` mask was the third refusal and is now drawn.** It was the only
one that was about the *mesh* rather than the shading: there was no COLOR_0
stream, because a fourth stream meant a ninth pinned push field and the push block
was full. §15 emptied it, and the mask is now `s.vertex_color.g` with no sampler
and no image behind it — `maskSource: 'vertexColor'` in a description, and the
channel beside it exactly as `LayerMask` has them. The refusal is what dated
first, which is the argument for refusing by name: the sentence said what was
missing, so it was obvious what to build.

**A stack now goes back out again.** `lib/gltf.c3l` had only ever parsed the
extension, so `scene.export` flattened a layered material to its base colour and
`report.shaded` said "you lost a shader" — true, and not the loss that mattered.
The library writes it now (`add_material_layers`/`add_layer` in
`materials_layers.c3`, beside the parser, with write structs of its own because a
parsed `textureInfo` holds an *image* index where a written one holds a *texture*
index), and `scene/export.c3` fills it from the **source document rather than
from `GpuLayers`**. That direction is the whole decision: the renderer's copy is
deliberately lossy — the PBR half dropped, the masks rearranged by
`hoist_shared_mask`, and nothing at all before an upload the exporter never does
— so writing it back would state a document the file never contained. The parsed
one is complete, needs no device, and is the same source `read_stream_geometry`
already re-reads the vertices from. `COLOR_0` is written beside it so a
`VERTEX_COLOR` mask still has an attribute to name, and `report.layers` counts
the records, because `shaded` cannot: a layered material is a generated shader
whether or not its stack survived.

**A stack a script built goes out too, by the other door.** The first version of
this left `LayeredMaterial` behind — there is no structured stack behind one,
only generated Slang — and the result was a difference no script could see: a
terrain loaded from a `.glb` exported layered, and an identical one written with
`new three.LayeredMaterial(...)` exported as a flat colour. So the stack now
crosses **twice**: once as a shader through `createMaterial`, and once as a
description through `beginMaterialLayers`/`addMaterialLayer` into
`Material.script_layers`. A shader cannot be read back — "this layer multiplies"
is a choice of expression by the time `emit` is done, and the extension wants the
word.

That path is lossless for the opposite reason to the imported one. There the
source document is complete and `GpuLayers` is not; here the *description* is
complete, because a script stack has no PBR half and no height data to lose —
`layers.js` refuses both by name (§12). What it does not have is a file behind
its images, so those are read off the device and encoded, which is the exporter's
second image source used on its own.

**The record stores bindings and push offsets, not values.** `mat.layers[1].map =
moss` writes through to the material's sampler and an animated tint writes
through to its push block, so keeping copies here would mean a second thing every
setter had to update and a stale image in the file when one forgot. Storing where
to look means there is nothing to keep in step, and it retains nothing: every
image a layer names is already held by the material for its whole life. A script
stack wins over an imported one on the same mesh, which is the rule
`texture_slot` already follows — the material is what the frame drew with.

**What is next, in the order it stops being optional:** parallax from the height
data the extension already carries and this already ignores, and the PBR half,
which is §12's specular term and not this section's.

---

## 16. What an exported scene keeps

**Built.** §5's writer answered "is the geometry right"; this answers "does the
file look like the scene". Going looking after the layer work turned up five
things core glTF or a ratified extension could hold and the exporter simply
never wrote:

- **`material.side`** — `add_material` had taken `double_sided` all along and the
  exporter never passed it, so a `DoubleSide` plane exported invisible from
  behind.
- **`material.repeat` / `material.offset`** — dropped, with
  `KHR_texture_transform` sitting there for exactly this. A tiling floor is the
  most ordinary thing an agent builds and its texture arrived stretched once
  across the whole surface.
- **`normalTexture` / `occlusionTexture` / `emissiveTexture`** — `WriteMaterial`
  said they were absent "because nothing in this writer produces them yet".
  Something did: a mesh from a `.glb` carries them on its source material, in the
  document the exporter already reads for the layer stack. A normal-mapped kit
  round-tripped flat.
- **The camera and the light** — never written at all, so an exported scene
  opened pointing wherever the viewer decided, lit by whatever it supplied.

**No flag, and that is the decision worth recording.** `flatten` is a parameter
because it genuinely costs the hierarchy. None of these costs anything, and
fidelity that has to be opted into is fidelity agents do not find.

**The dedup key is what gets written, not where it came from.** The first attempt
put the source material's *index* in `ExportSurface` and made the export worse:
`textured.glb`'s two materials name two images whose bytes are identical,
`ExportImage` collapses those to one texture, and keying on the index then kept
two glTF materials that were byte-for-byte the same — materials went 6 → 12 on a
test that had been green for two milestones. The maps are resolved to output
texture indices *before* the dedup check instead, which costs nothing (the memo
answers the second call) and stays in step with the image dedup underneath it.
The layer stack is the one exception, kept as an identity: comparing two stacks
field by field is a deep compare to answer what two integers already answer.

**Two things do not cross.** The light's **ambient floor** has no punctual
equivalent — ambient was removed from `KHR_lights_punctual` before ratification —
so a scene with a high floor reloads darker; folding it into the directional
intensity would be a different picture rather than the same one. And **metalness
and roughness** are not written, §12's rule held: no specular term means a number
in the file that never affected a pixel.

**Lines are the one item deferred.** A line mesh has no CPU copy of its vertices
(`upload_built` skips `build_bvh`, which is what keeps one) and a script's
`three.lines()` is indistinguishable from a helper — both draw with
`LINE_MATERIAL`, which is the test the exporter drops helpers by. Two structural
changes for the least valuable of the six; `mode: LINES` is waiting in the writer
when it is worth paying for.

The camera and light are nodes, so `report.nodes` grew by two and four tests that
asserted a count moved with it. That is the whole ripple.

---

## 15. The draw buffer

**Built.** Per-draw data is a `DrawRecord` in a host-visible buffer, one per
bucket per frame, and the push block carries its address. What is pushed is three
pointers — `frame`, `instances`, `draw` — and 24 bytes, where it was eight fields
and 76.

**The problem it solves is not performance.** The command count is the same, the
draw call is the same `vkCmdDrawIndexed`, and nothing renders faster. What changed
is that the 128 bytes every Vulkan implementation must offer had become a shared
scarcity: the mesh contract wanted 76 of them and material uniforms had the other
52, and *both* halves were blocked on it. §14's vertex-colour mask needed a fourth
vertex stream and could not have one, because an 8-byte pointer would have come
out of the uniforms; §2's uniform table wanted more rows and could not have them
for the same reason from the other side. Neither was worth taking from the other,
which is what an argument about a fixed budget looks like when both sides are
right.

So the geometry contract moved into memory, where a field costs what a field
costs. `MATERIAL_UNIFORM_BUDGET` went 52 → 104 and the sampler-free vertex-colour
mask landed in the same change. **A new vertex stream is now 8 bytes of a buffer
sized by the frame's bucket count** — tangents, a second uv set and joints all
become bookkeeping rather than a trade.

**Why not `vkCmdDrawIndexedIndirect` as well.** The obvious next step, and it buys
nothing here yet: geometry is one buffer per mesh, so `firstIndex` and
`vertexOffset` are always zero and there is nothing to multi-draw across;
textures are push descriptors written per bucket; and a `ShaderMaterial` is its
own pipeline. Each of those independently forces one command per bucket, so an
indirect draw would be the same commands plus a buffer read, minus the validation
layer's ability to check the arguments — a bad record becomes a hang instead of an
error. **Trigger:** a consolidated geometry arena and bindless textures, at which
point the record is where the five `VkDrawIndexedIndirectCommand` fields go and
the change is small. GPU culling wants the same two things first.

**What it cost, and the one thing that had to be rebuilt.** Reflection covers a
push block and not the type behind a pointer, so moving the contract out of the
block moved it out of `check_push_block` — the check `MESH_PUSH_FIELDS` exists to
be. Two tests replace it: one cuts `struct Draw` out of `shaders/mesh.slang` and
compiles it *as* a push block to get Slang's own offsets for `DRAW_RECORD_FIELDS`,
and one compares that declaration against the copy in `material.slang`, which the
two files carry separately for §4's reason. Both were checked by mutation — swap
two fields in one shader and each fails, naming the field and both offsets.

---

## What is deliberately absent, and stays absent

- **No `BufferGeometry` and no attribute access.** That is the thesis. Nothing in
  eight milestones has needed one, and a game is the workload that would be worst
  served by it. `ConvexGeometry`'s point cloud is a description too — most of the
  points are discarded and none can be read back.
- **No ECS.** The scene graph is the entity list and a game's components are
  JavaScript objects keyed by node id. Building an entity system in C3 would be
  building the part JavaScript is good at.
- **No editor.** The MCP surface is the editor, and it is better than one.
- **No networking.** The physics work makes lockstep *possible* — `state_hash`
  and `snapshot`/`restore` are the hard parts and they exist — and nothing here
  builds it.
- **No render graph and no deferred path.** Both are answers to a pass count this
  project does not have. A frame is five images and `3 + N` barrier call sites;
  shadows, a UI layer and depth-in-post together take that to about seven. A graph
  that schedules four passes is a scheduler with nothing to schedule. **§13 is the
  counting and the shape the alternative takes** — a stage list, a chain whose
  adjacency is its own edge set, and the one trigger that would change the answer,
  which is script-authored *edges* rather than pass count.
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

