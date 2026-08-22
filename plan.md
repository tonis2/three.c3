# three.c3 — what is left

This file is the whole plan. Everything it used to contain about work that is
finished has been deleted, because a plan that describes what already happened
is a document nobody can tell the live parts out of.

**The removed records are in git, not gone.** `plan.md` §1–§4 (the load-bearing
decisions, the scene model, the Slang binding, the JS API), `game.md`,
`event_loop.md`, and `m2`–`m6_stage.md` are all at `e4a70bf` and every commit
before it:

	git show e4a70bf:game.md
	git show e4a70bf:m6_stage.md        # and m2, m3, m4, m5, m5a, m5b
	git show e4a70bf:event_loop.md
	git show e4a70bf:plan.md            # §1-§4 are the architecture argument

Reach for them when you want to know *why* something is the way it is. What is
below is only what has not been done.

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
QuickJS with a Three.js-shaped API in `js/prelude.js` and three MCP tools over it.
Slang compiled at runtime, with the descriptor layout and push block read out of
the module. Picking, parametric shapes, per-copy colour and variant. The window
as a control — orbit, pan, zoom, keyboard, click-to-pick, and a frame a script
can drive. Measuring (`bounds`, `boundingBox`, `align`), debug draw, and glTF
export that round-trips per-copy colour through `EXT_mesh_gpu_instancing`.
A game boot (`--assets`, `main.js`), unloading, glTF node animation, and an XPBD
physics world with contacts, friction, joints, triggers and events. PNG and JPEG
textures from a path, pixels generated in a script, and the glTF image table —
all three sharing one content hash, so the same picture is one upload however it
arrived. Colour management end to end: an sRGB target, a decode at the one door
a script's colours come in through, and a round trip a test can assert on.
One directional light with a verb (`three.light`). Velocity and impulse on a
dynamic body, which is what makes a character possible. `texture.read()`, a uv
transform per material, and a glTF export that writes a texture a script made.
Keys a script can hold down, and a budget a script can raise.
`material.dispose()`, an evicting pipeline cache, and a frame-tagged deletion
queue underneath both. Transparent and additive materials, asked for when a
material is built and baked into its pipeline because this device gives no other
choice, with every blended draw sorted farthest-first and recorded after the
opaque ones and under the debug lines. Compiled shaders now outlive the process:
each one is stored under a hash of its own source, entry points and compiler
arguments and checked against them byte for byte on the way back in, so the
second sight of any shader on any later run is a millisecond of reading instead
of seventeen of compiling — and a run that compiles nothing never starts the
fifty-five millisecond Slang session at all, which is most of why a screenshot
now takes 0.19 s warm against 0.28 s cold.
A frame is now measured rather than guessed at: two timestamps written by the
GPU itself around the whole submission — the blit and the readback copy
included, deliberately — collected off the fence that was already being waited
on, and surfaced as `stats().gpuMs` beside the scene's own counters. `render()`
and a screenshot leave behind the frame they just drew; the windowed loop leaves
behind the last one to complete, since it never waits for its own. The number is
joined to `stats()` at each boundary rather than living in `SceneStats`, which
stays a device-free fact about the scene, and it is 0 rather than absent when
there is nothing to ask.
And the finished frame is now something a script can write over: one
agent-authored `float3 post(Post p)` runs across the whole picture, with
`p.color` the scene pixel already decoded to linear, plus `uv`, `resolution` and
a clock. `three.setPost({ fragment, uniforms })` compiles it on the line that
asked and throws Slang's own diagnostic at the body's own line numbers;
`three.setPost(null)` puts the frame back on the path it was on before. With a
pass active the scene renders into a second sampled `_SRGB` image and the post
shader writes the target the blit already reads, so the round trip closes by
format and nothing downstream of `target.color` knows any of it happened —
window, `render()` and every screenshot go through one recording function and
cannot disagree about it. The 112 bytes of push block the pass has to itself are
written live between frames through the same uniforms Proxy a `ShaderMaterial`
has, and the pass belongs to the renderer rather than to the scene, so it
survives `new three.Scene()` and outlives the script that set it.

	c3c test --trust=full       558 passed, 0 failed, leak-clean

**`examples/village` is where most of what follows came from.** A walled village
wearing nothing but generated textures — eleven `DataTexture`s and no image file
anywhere — exported to glTF and then walked around in with a third-person
character: 3,029 meshes in 36 draw calls from 11 geometries. Nothing added below
was found by reading the source looking for holes. Each one stopped the work, and
where it forced a workaround the workaround is named, because that is the honest
measure of what a gap costs.

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

- **A uniform table is capped by the 68-byte push budget** — four rows of four
  floats, or five of three. A table of hundreds needs a device buffer behind a
  BDA in the push block. **Trigger:** something wants more than five rows.

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
  keyed the way that verb would want.

- **`ConvexGeometry` carries no uvs**, so a hull can only ever be flat-coloured.
  The reason is real — a hull's faces meet at hard creases and there is no unwrap
  of an arbitrary one that does not seam — but it is a sharp edge on the only
  escape hatch from the six parametric shapes, and it bit in `examples/village`,
  where the church and watermill gable ends are hull prisms sitting next to a
  textured roof. **Trigger:** anything wanting a textured rock, crystal or piece
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

- **The post chain is built, and what it still cannot express is edges.** This
  entry used to read "the post pass is one pass, and there is no chain", and the
  chain it asked for is `render/chain.c3`: `three.addPass` appends, three images
  serve any length, and the ownership question this entry left open was answered
  the way it guessed — one live pipeline became a list of boxed stages, still
  owned outright rather than through `PipelineCache`, because the swap case a
  cache exists for is not the case a post shader is in.

  Two things underneath it were answered as well, and one of them differently
  than expected: a pass reads its predecessor through binding 0 and image A
  through binding 1, and image A's format **stayed** `_SRGB` while the chain's
  intermediates went float. §13's format section has why.

  What is still absent is the thing this entry never named: **a script cannot say
  which pass another pass reads.** Adjacency is the edge set, plus `p.scene` for
  the original frame, and those two cover bloom. A pass wanting a *third* source,
  or a downsampled one, is where this grows next. **Trigger:** script-authored
  edges — the point at which no human is left in the loop to reason about the
  dependency.

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

*(was G4)* **The one milestone that changes the draw model.** Everything needed
on the parse side is already in `gltf.c3l/src/skinning.c3`.

**S1 — joints reach the shader.** Joint indices and weights are two more BDA
streams; `has_skin` joins `has_normals` and `has_uvs` in the push block;
`shaders/mesh.slang` gets the skinned branch.

**S2 — the palette keeps the instanced draw.** Fifty rocks share one instanced
draw. Fifty skinned characters are fifty poses and cannot — *unless* the joint
matrices live in a device buffer indexed by `SV_InstanceID`, which keeps them in
one draw at the cost of uploading the palette every frame. A 60-joint rig across
50 instances is 60 × 50 × 64 bytes ≈ **192 KB per frame**. That is affordable,
and it is the option that keeps the thesis's shape rather than the one that
quietly abandons it.

**S3 — `stats()` must not lie.** A skinned bucket costs per-frame upload that an
instanced bucket does not. Reporting them identically would tell an agent that
fifty characters and fifty rocks cost the same, and it would then build the scene
that proves otherwise. Skinned buckets are reported distinctly. **Write this
check before the code:** the failure mode here is a number that is wrong rather
than a picture that is, and nothing else notices.

**S4 — picking hits the bind pose, and says so.** A skinned mesh's `TriBVH` is
stale the moment it moves, and rebuilding a BVH per frame per character is not
happening. Skinned meshes get an AABB proxy for picking, documented as such. A
raycast that silently answers about a pose the character left two seconds ago is
worse than one that answers about a box.

---

## 4. Textures, async load, and a sky

*(was G6)* **Two things wearing one coat, and the sequencing matters more than
the parts.** `lib/ktx.c3l` is already in, ahead of the milestone that uses it.

**Pixels from a script are done too.** `new three.DataTexture(data, width, height)`
takes a `Uint8Array` (or a plain Array, widened) of RGBA bytes and uploads it
through the same `claim_texture`, so generated pixels and the identical `.png`
are one texture. It needed one new function in `lib/quickjs.c3l` —
`qjs_get_bytes`, over `JS_GetUint8Array`/`JS_GetArrayBuffer` — because the shim
could hand memory *to* the engine and not read it back. It needed a submodule
change and that is now in: `lib/quickjs.c3l` is at `4d6e6ad` and the gitlink was
bumped with the rest of the work at `b0d464e`. Measured: the crossing and upload are 2-5 ms
for 64 KB to 1 MB, and filling the array in JavaScript is 14 ms at 256x256 and
97 ms at 1024x1024 — so build at load, not per frame, and the boundary is not
what costs.

**The PNG/JPEG half is done.** `three.texture(path)` decodes through `image.c3l`
and uploads down the same path a glTF image takes — `Assets.claim_texture`, one
content hash, one table — so a `.png` on disk and the identical image inside a
`.glb` are one upload. `new three.MeshLambertMaterial({ map })` puts it on a
shape without compiling anything, `material.map` works on a `ShaderMaterial` too,
and `Material.texture` beats `GpuMesh.texture` at record time so a script always
overrules the file. `test/texture_test.c3` and eight checks in `test/js_test.c3`
cover it, each proved by injection. What is deliberately not there: mips (so a
textured floor aliases at grazing angles), and any colourspace but sRGB (so a
normal or roughness map through this verb would come back gamma-decoded — the
argument is in `Assets.load_texture_file`).

**The three texture-shaped gaps `examples/village` ran into are closed**, and
what they cost is worth keeping because it is the measure of what a gap is worth:

- **`material.repeat` / `material.offset`.** There was no uv scale anywhere, so a
  surface mapped its texture exactly once and texel density was a function of how
  big the mesh was — the village's ground was **484 separate plane meshes** on a
  six-unit grid, purely to stop one 128px grass texture stretching across 132
  units. One number replaces the lot. It is a *material* property rather than a
  texture one, which is a divergence from Three.js with a reason Three.js does
  not have: textures here are deduplicated by content across every file, so a
  transform on the texture would reach every unrelated surface that used the same
  picture. It cost 16 bytes of the push block, taking `MATERIAL_UNIFORM_BUDGET`
  from 68 to 52 — three rows of four floats rather than four. That trade is
  argued where the constant is.
- **`texture.read()`.** Pixels can come back off the device now, into a
  `Uint8Array` the caller supplies. It makes textures testable, which they were
  not, and it is what lets the exporter write one. Writing it found a real bug
  immediately: texture images were created without `TRANSFER_SRC` usage, so the
  readback was not merely absent but *invalid* — caught by the validation layer
  on the check's first run, with the VUID naming it.
- **The exporter writes a texture a script made.** `Exporter.texture_for` now
  consults `material.map` — which it never did, so an image a script put on a
  shape was invisible to it — and falls back to reading the pixels off the device
  and encoding them with `png::save_bytes` when there is no source file behind
  them. `shaded` was counting every non-default material, including a
  `MeshLambertMaterial`, which glTF describes perfectly well; it now counts only
  what the format cannot carry, which is a `ShaderMaterial`. The village exported
  `images: 0, shaded: 3025 of 3029` and now exports its textures.

**What a script still cannot reach is a mesh's *own* image.** A mesh loaded from
a `.glb` carries its texture on the `GpuMesh` and exposes no `Texture` handle, so
`texture.read()` has nothing to be called on for it — the byte-for-byte export
round trip had to be written in C3 for that reason.
`asset.imageAt(i)` is the shape of the missing verb, and it is small.

**`test/ktx_test.c3` does not exist**, and both this file and `project.json:42`
claimed it did — "holding it to compiling and linking so it does not rot".
`grep -rn ktx src test` returns nothing: `ktx` is listed in `project.json`'s
dependencies and imported by nobody, so the rot that comment was written to
prevent has already happened. Either write that file or stop claiming it.

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

`ktx::mipgen` is there too, and nothing in this project generates a mip chain
today.

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

**It has now been hit rather than anticipated.** `examples/village` binds seven
keys to a character and has no way to say so — the controls had to be delivered
in a chat message, because the window has no way to mention them. That is the
smallest possible version of this milestone and it is already missed.

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
mechanisms that are missing.

**Velocity and impulse are bound**, which was the one that stopped a character
being built on this world at all. `three.physics.setVelocity(object, [x, y, z])`
assigns a speed, `applyImpulse(object, [x, y, z], at)` adds one, and
`velocity(object)` reads both back — so a dynamic capsule with its velocity set
each frame walks *and* collides, which no combination of the previous verbs
could. Static and kinematic bodies refuse by name rather than absorbing the call:
a static body's inverse mass is zero and a kinematic one has its velocity
overwritten a fraction of a step later, so both would have looked like the verb
doing nothing.

The thing that made it more than a binding was sleep. A settled body is skipped
by integration, so an impulse without a wake changes a number nothing reads.
This was believed to *hang* the solver as well, and it does not — that was the
worker pool being captured by an earlier failing test, which §10 now records in
full. What is left:

- **No character controller.** With velocity bound, a dynamic capsule with locked
  rotation *is* a character, so this is the step after rather than a prerequisite.
  What it buys is that every game stops rewriting the village's 120 lines: sweep
  the shape, slide along the contact, step up small ledges, and report whether
  the thing is standing on something.
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

- **`c3c build` does not rebuild the test binary, and `c3c test` does not rebuild
  the app.** `build` produces `./build/three`; `test` produces and runs
  `./build/testrun`. So `c3c build && ./build/testrun` runs whatever the *last*
  `c3c test` compiled, and a source change appears to have no effect — which
  reads exactly like "the injected bug was not caught" and exactly like "the fix
  did not work". Both misreadings happened in one sitting: an injection appeared
  to pass, and a live check against a stale `./build/three` reported the bug the
  edit had just removed. **`c3c test [<target>]` is the build-and-run verb**;
  `c3c run test` is not, because `run` takes a build target and there is no
  target named `test`. When a result is surprising, check what you actually ran
  before believing what it says.

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
  in Phase D item 2 and was wrong; it was caught by writing the test the plan
  asked for rather than by reasoning about it again.
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

**Assert on the thing, not on the flag.** A mode field says nothing about whether
anything rendered; compare pixels. Three ways a check has passed for the wrong
reason here, all worth guarding against: a symmetric fixture, a comparison that
turned out to be counting draw calls rather than comparing frames, and an
assertion whose probe was outside the region it claimed to test.

**Assert absences too.** "Loading a file uploads nothing" is the only way to keep
a lazy loader lazy — nothing else notices when it quietly starts uploading
everything again.

**The two things that made an input-driven scene untestable are fixed.**
`three.input.press(key)` holds a key down until `release(key)`, through the same
path a real key takes — so `isDown`, `pressed`, `released` and every `onKeyDown`
handler cannot tell a scripted key from a finger, which is the property that
makes a game's input regression-testable rather than merely pokeable. And
`three.budget` lets a script raise its own wall-clock allowance from the default
5,000 ms to at most ten minutes, so a check that *simulates* is cut into pieces
that mean something rather than pieces that fit five seconds. The ceiling stays,
because a limit a script can lift entirely is not a limit and the whole reason
the interrupt exists is that a wedged loop must be a pause rather than a hang.

Two notes carried forward from doing it. The script budget had to become a
*separate field* from the live one a frame borrows, or a raised script budget
would silently have become a raised per-frame budget and one callback could wedge
a game — `a_raised_script_budget_does_not_reach_the_frame_callback` is what says
so. And the sweep that motivated all of this remains the argument in one number:
27,000 simulated steps at running speed found a 13% collision failure rate that
no amount of playing the scene by hand had surfaced.

**`examples/village` has not been rewritten to use any of it**, and until it is,
the scene still hands its internals to `globalThis.village` — the leak that was
the smell rather than the fix. Porting it is the check that these verbs are
actually sufficient, and it is the honest next step for this section.

Checks worth writing *before* the code they check, because each one guards a
number that is wrong rather than a picture that is:

1. **Skinned buckets report distinctly in `stats()`** (§3/S3), asserted against a
   scene containing both a skinned and an instanced bucket.
2. **The physics world is deterministic** — two worlds given the same inputs
   produce the same `state_hash` after N steps, and a `snapshot`/`restore` round
   trip reproduces it. The library supplies the mechanism; the binding is what
   could break it, by stepping at a rate that depends on the frame.
3. **The unload cycle returns to zero** — load, unload, reload, a hundred times,
   with resident assets, resident textures and texture bytes all back where they
   started. Catches every leak that path can have.

---

## 12. Lighting

**The four floats are bound.** `three.light.direction` is a live world-space
surface-to-light vector and `three.light.ambient` is the floor an unlit face
gets; `three.light.set(direction, ambient)` does both, and a new `Scene` restores
the default exactly as it restores the background. It is deliberately not
`scene.add(new three.DirectionalLight(...))`: that name would promise adding,
removing, colouring and duplicating, and this renderer can do none of them.

Two things the doing of it settled. The direction is **not normalized** on the
way in, so it reads back as it was written — normalizing at the door would answer
with numbers the script never typed. And a zero direction is refused by name
rather than accepted, because `normalize` of it is a NaN, every shading term
becomes a NaN with it, and the frame that results is black or undefined with
nothing anywhere pointing at the light.

It landed after §1's colour fix, which was the sequencing note this section
carried: a light direction chosen against a pipeline that loses a gamma is one
that gets chosen twice.

**`examples/village` has not been retuned yet.** It still multiplies per-copy
colours by 1.22 across the church, the palisade and both mills to compensate for
the 0.25 ambient floor — a hack that lifts the lit faces exactly as much as the
shadowed ones, trading a wrong answer for a flatter one. Now that the light is
reachable, that scene can raise the floor honestly and delete the fudge, and
doing so is the check that the verb is the right shape.

What is next, in the order they stop being optional: a second light, or a list;
a colour per light rather than white; and shadows, which are a depth pass, a
matrix and a comparison sampler, and are the largest single visual gap left after
the sky in §4. Now that the binding exists, which of them anybody actually misses
is a question that can be answered rather than guessed — which was the argument
for doing the binding first.

---

## 13. The pass system, and what it is not

**Steps 1, 2, 3 and 6 of the order of work below are now built** — the driver
batch, the format decision, the chain, and `three.addPass`. This section was
written *before* that work rather than after it, and it has been edited in place
since rather than rewritten, so that where the design and the code disagreed the
disagreement is still readable. There are three such places and each is marked:
`IMAGE_LAYOUT_GENERAL` (entry 2), depth state out of `PipelineState` (entry 4),
and which image gets the float format (the format section).

It was written first because one of the decisions in it — the format of the image
the scene renders into — looked like a one-line edit before a chain existed and a
three-image, two-pipeline-variant edit afterwards. That turned out to be right
about the urgency and wrong about the image.

It came out of a question §12's "what is next" list could not answer on its own:
post-processing landed, shadows and a UI layer are both wanted, PBR is on the
horizon, and the entry below says there is no render graph and never will be. Is
that still true once a frame has four things in it? It is, and the counting is
here — but the counting also produced the shape those features should land in.

### What a frame was when this was written, counted

	inactive   scene ────────────────────────────────► target.color ──► blit
	active     scene ──► image A ──[sample]──► post ──► target.color ──► blit

Two render passes at most, three owned images (`target.color`, `target.depth`,
`PostPass.image`), and **four barrier call sites in the entire frame path** — two
in `gpu/target.c3`, two in `render/post.c3` — plus the swapchain's two around the
blit. `Renderer.record_scene` is one `if`.

*What it is now, after the chain:* the same when inactive, and
`scene ─► A ─► P0 ─► … ─► tonemap ─► target.color` when not. Two more owned
images, and the barrier count went from four to `3 + N` — one for A, one per pass,
one to close the target — with every one of them still coming out of
`color_attachment_barrier` and `shader_read_barrier`. **No new barrier code was
written**, which is the prediction below that held.

What the named features add to that, which is the number the render graph
question actually turns on:

	shadows        +1 site   the shadow map's attachment transition. The read-side
	                         transition folds into begin_render_to's existing
	                         two-element array. Cascades are layers of one image:
	                         more draw calls, the same two transitions.
	UI             +1 site   or zero. Same target.color, LOAD_OP_LOAD, a different
	                         pipeline, no attachment of its own.
	post chain     +1 site   one ping-pong helper called N times, not one per pass.
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
	apiVersion           1.4.359     <- create_instance asks for 1.3
	device extensions    144
	maxPushConstantsSize 256

	dynamicRenderingLocalRead    true
	unifiedImageLayouts          true
	hostImageCopy                true
	maintenance5, maintenance6   true
	pushDescriptor (1.4 core)    true
	VK_EXT_shader_object         absent

§10 already carries the `VK_EXT_extended_dynamic_state3` half of this same run
and nothing here disturbs it: every colour-blend bit false, so **a blend mode
stays a `PipelineState` field**. `VK_EXT_shader_object` being absent is the other
half of that — it is the extension that would have removed pipeline objects
outright and with them the "am I last" variant problem below. It is not there.

**1. `apiVersion` moves to 1.4.** It is what the device reports, and it makes
`push_descriptor`, `dynamic_rendering_local_read`, `maintenance5`/`6` and
`hostImageCopy` core rather than extension strings — one
`VkPhysicalDeviceVulkan14Features` in place of a list.

*This does not refuse 1.3 devices, which is worth writing down because the
opposite is the natural assumption.* `VkApplicationInfo::apiVersion` declares the
maximum version the app may use; it is not a demand. A 1.4 instance runs on a 1.3
physical device and simply may not call 1.4 core entry points there. The two real
checks are `vkEnumerateInstanceVersion` before `vkCreateInstance` — only a
pre-1.1 loader fails outright — and `VkPhysicalDeviceProperties::apiVersion` **per
device**, which `select_device` already fetches. One comparison, not a rejection
path.

**2. `IMAGE_LAYOUT_GENERAL` was tried, measured and reverted.** It was written in
full — five files, every image this project owns — and taken back out once the
cost below was measured. `gpu/target.c3`'s two-layout contract stands. What
follows is why it looked right, because the reasoning is sound up to the last
step and somebody will have it again.

Two separate facts get merged in the usual argument for it, and only one of them
is about support:

- **`VK_IMAGE_LAYOUT_GENERAL` has been legal on every device since Vulkan 1.0.**
  No extension, no feature bit. Not "most modern GPUs" — all of them, always.
- **`VK_KHR_unified_image_layouts` is the promise that GENERAL costs nothing**,
  and *that* is the rare one. Present here because Metal has no layout concept at
  all, which is the same reason the transitions were always no-ops on this driver.

So GENERAL would be adopted **without gating on the extension**. Two clauses of
the old contract would have survived, and both are load-bearing:

- **`UNDEFINED` stays as a source layout wherever contents are discarded.** That
  is what `color_attachment_barrier` does today, and on a tiler the discard is
  worth more than the layout — it is the difference between loading a tile and
  not.
- **The swapchain image still needs `PRESENT_SRC_KHR`.** `gpu/swapchain.c3` keeps
  a real transition; GENERAL does not reach the thing that gets presented.

**Barriers do not go away, and expecting them to is the trap.** `srcStageMask`,
`dstStageMask` and the access masks are the actual content of a barrier; only
`oldLayout`/`newLayout` collapse. The barrier *count* is unchanged. What is
deleted is the layout bookkeeping and the class of bug where an image is in the
wrong layout for its next use — which is the half of the `FullscreenPass`
protocol below that C3 could not have typed anyway.

The cost that was expected, stated because it is real rather than free: on desktop
AMD and NVIDIA, GENERAL can disable colour compression and depth in GENERAL can
lose HiZ.

**And the cost that was not expected, which is larger and was measured after the
change was written.** Adopting GENERAL does not delete a bug class. It deletes
the *detector* for one that is still there:

- Core validation catches a missing barrier by noticing that an image is in the
  wrong **layout** for what is about to read it. That is the mechanism, and it is
  the only one core validation has for this.
- With every image in GENERAL there is no layout left to be wrong, so a missing
  barrier — the hazard the barrier actually exists for — is invisible to it.
- Measured, not reasoned: deleting `shader_read_barrier` from `PostPass.record`
  used to produce `VUID-vkCmdDraw-imageLayout-00344`, which
  `the_post_pass_is_silent_under_validation` records as its proof by injection.
  With GENERAL, that same deletion leaves **all 18 post checks green**.
- Synchronization validation does not fill the hole on this driver. Enabled three
  ways — `VkValidationFeaturesEXT` in the instance chain, the deprecated
  `VK_LAYER_ENABLES`, and the layer's current `VK_LAYER_VALIDATE_SYNC=1` — the
  missing barrier still reports nothing. (The first of those the layer now calls
  deprecated outright, which is worth knowing separately.)

That inverts the trade for **this** project specifically. `test/post_test.c3`'s
own header says why: "none of it has a pixel symptom on this driver — a missing
barrier renders correctly here and is a race everywhere else". The layout system
was not bookkeeping this codebase was carrying for nothing; it was the instrument
standing between a missing barrier and a silent race on hardware this project
cannot test on. The layout mistake GENERAL removes is one the code was never
making — the contract was documented and correct. The barrier mistake it hides is
the one that costs a race.

**So it was reverted, and the revert was verified the same way the cost was.**
With the two-layout contract back, deleting `shader_read_barrier` fails
`the_post_pass_is_silent_under_validation` with exactly the VUID that check's own
comment records — image A seen as `SHADER_READ_ONLY_OPTIMAL` by the descriptor
against a previous known layout of `COLOR_ATTACHMENT_OPTIMAL`. The detector is
demonstrably back rather than presumed back.

The general lesson, which outlives this particular extension: **a simplification
that removes a mistake nobody is making, at the cost of an instrument that catches
one they might, is not a simplification.** The layout bookkeeping here reads like
ceremony precisely because it has been working. Anything that proposes to delete a
safety mechanism should be asked to show what still catches the failure
afterwards, and the way to ask is an injection rather than an argument.

**3. `dynamic_rendering_local_read` is a fusion path, and an optimisation rather
than a design.** Within one `cmdBeginRendering` block it can read attachments
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
both to any effect. So this is not a flag to flip later — it is a second path,
which is exactly why the chain is built first: it is correct on any driver, the
fusion is identical output with less bandwidth, and designing the general case
around the special one gets both wrong. **Trigger:** the chain working, and a
measurement.

It also nearly dissolves §2's depth-in-post entry for the pointwise half. Depth
becomes an input attachment in the block that is already using it, so the
transition to `DEPTH_STENCIL_READ_ONLY_OPTIMAL` and back stops existing — for fog
and soft particles, which want the same pixel. Depth of field and SSAO want
neighbours and stay where that entry left them.

**4. `PipelineState` keeps all four fields, and this entry is a retraction.** A
version bump promotes extensions to core; it cannot add support a driver does not
implement, so nothing above buys dynamic blend. `VK_EXT_extended_dynamic_state`
and `…state2` did go core in **1.3** and are mandatory there, this project uses
exactly one thing from them (`DYNAMIC_STATE_CULL_MODE`), and
`DYNAMIC_STATE_DEPTH_TEST_ENABLE` and `…WRITE_ENABLE` really are free for the
asking. This entry used to conclude from that that both depth fields should leave
the cache key, and claimed it would halve the key's cardinality.

**It would halve nothing.** Every `PipelineState` in the program is one of four
constants, and `state_for_blend` (`scene/material.c3:164`) is a pure function from
`BlendMode` to one of them — there is no site anywhere that builds a state with an
independent depth choice. Written out:

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
one call, and the same for `gpu/texture.c3`'s upload. The breadth question answers
itself once 1.4 is declared — `VK_EXT_host_image_copy` was **promoted to core in
1.4**, so every 1.4 device has it and desktop NVIDIA, AMD and Mesa all ship 1.4.
Held back anyway: it is a readback convenience rather than a pass change, it
blocks nothing, and it needs `HOST_TRANSFER` usage set at image creation — so it
belongs with the format work below, decided once rather than twice.

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

`record_scene` today branches twice on one bool. With four stages the question
*who writes `target.color`, and who issues the final `to_transfer_src`* has 2 × 2
× N answers, and written as nested ifs that is exactly where the bug goes — the
"window shows something the screenshot does not" family this function exists to
prevent.

So the frame becomes a sequence with the destination decided once at the top:

	bool posted  = self.post.active;
	bool overlay = self.ui.active;

	if (self.shadows.active) self.shadows.record(cmd, &self.scene)!;
	self.target.begin_render_to(cmd, scene_destination);
	self.draw(cmd)!;
	if (posted)  self.post.record_chain(cmd, &self.target, final_color)!;
	if (overlay) self.ui.record(cmd, &self.target);
	self.target.close(cmd);

**The invariant, which is what the current `if (posted) … else end_render()` is
smuggling and what a third stage would break: exactly one stage writes
`target.color`, and the close happens exactly once, here.** It wants a test that
fails when a second stage claims the target.

*As built:* `record_scene` is that sequence, `cmdEndRendering` moved into it so
both paths end the scene's rendering in one place, and `Target.close` is
`end_render`'s second half on its own. **The test it wanted already existed.** A
second close is a transition out of COLOR_ATTACHMENT_OPTIMAL on an image the layer
knows is in TRANSFER_SRC, so `the_post_pass_is_silent_under_validation` and
`a_chain_is_silent_under_validation` both fail on it with
`VUID-VkImageMemoryBarrier2-oldLayout-01197` — verified by injecting a second
`self.target.close(cmd)`, not by reasoning about it. So the rule is enforced
rather than merely written down, which is the thing to know before a shadow pass
and a UI layer are added on top of it.

Each stage keeps its own honest signature. A common `record(PassContext*)` across
all three kinds would need a context carrying gpu, cmd, target, slot, assets,
scene, src view, dst view and extent, with every pass reading three of the nine —
and the specific loss is that you could no longer tell from a signature what a
pass touches, in a file where every doc comment exists to say exactly that.

### The chain: three images and two rules

	pass i    reads  P[(i-1)&1] as `prev`, A as `scene`
	          writes P[i&1]
	pass N-1  writes target.color instead

Three images regardless of chain length: A (what `PostPass.image` already is) plus
two ping-pong images. P0 and P1 are allocated lazily, and a runtime that never
sets a post shader still pays for nothing.

*As built, one clause of that moved:* the format decision below makes the tonemap
— not the last user pass — the thing that writes `target.color`, so a chain of one
writes P0 and the tonemap reads it. **N = 1 allocates P0 and not P1**, and it is
two draws rather than one. That is the price of user passes having no format to
get wrong, it is paid only by frames that asked for a post pass, and it is the
one place where the chain does not literally reduce to the code that came before
it. `an_identity_post_pass_leaves_the_frame_where_it_was` still holds at one
level of tolerance across the extra hop, which was the question.

Each pass issues exactly the `color_attachment_barrier` that `PostPass.record`
already issues, and the chain closes each destination with `shader_read_barrier`.
`color_attachment_barrier` discards from `UNDEFINED`, which is already correct for
reusing P0 on pass 2 after pass 1 sampled it. **No new barrier code — the existing
two functions called N times**, which is what shipped.

**A second reserved binding, and it is not free.** Binding 0 becomes `prev`;
binding 1 becomes `scene`, image A, always available. That is what covers the one
non-adjacent read anybody actually wants — bloom is `blur(bright(scene)) + scene`,
which needs the original three passes later. *The edge people reach for a DAG to
express is a binding, not a solver.*

The cost is that `TEXTURE_BINDING_FIRST` stops being one number. Its own comment
in `shader/assemble.c3` says why it is 1 — "zero is always taken and always
occupied: `base_color_map` in a material, `scene` in a post pass" — and that is a
coincidence of both kinds reserving exactly one. A post pass reserving two ends
it. So the constant becomes a parameter of the assembly (`assemble.c3:400`
generates indices from it) and of the cut in `SampledBindings.collect`
(`bind.c3:120`, `:155`), with materials keeping 1 and post taking 2. Doing that
as a shared bump instead would silently renumber every material sampler.

*As built:* `MATERIAL_BINDING_FIRST` and `POST_BINDING_FIRST`, both parameters of
`assemble_shader`, `SampledBindings.collect` and `sampler_binding_of`. One thing
this did not predict came out of it — `TextureSlots` indexed its array by
`binding - TEXTURE_BINDING_FIRST`, so there was a *third* place the number lived.
It is indexed by the absolute binding now: carrying a base into the accessors
would have meant a call site that passed a material's base for a post pass reading
a real texture out of the wrong slot rather than faulting, and a binding is the
same number to everybody. It costs one `int` per material.

The other thing measurement added: **the reserved bindings have to be checked
against the reflected layout too.** Slang drops a parameter nothing reads, and a
body that never touches `p.scene` gives it every reason to drop `scene` — pushing
a descriptor for a binding the layout does not declare is a validation error. So
`pipeline_declares_binding` asks by index what `sampler_binding_of` asks by name,
and `a_later_pass_reads_the_scene_and_not_only_its_predecessor` reaches it with a
first pass that returns a constant.

On a single pass, bindings 0 and 1 point at the same image, so `p.color == p.scene`
and **every post shader written today keeps working with no edit** — which held:
every post test that existed passed unchanged except the one asserting how many
bindings a module has.

### The format decision, which happened before the chain and moved

PBR with physical light intensities produces values above 1.0, and
`TARGET_COLOR_FORMAT` is `R8G8B8A8_SRGB` — an attachment that clamps them, losing
exactly the highlights bloom and tonemapping exist to shape. Real PBR means the
scene renders into `R16G16B16A16_SFLOAT`, the chain runs in linear HDR, and a
tonemap pass converts to display.

`target.color` stays `_SRGB`. It is the final destination, so `readback_size`'s
`w*h*4`, `decode_readback` and the PNG path are untouched and screenshots keep
working.

**This section used to end "the change is contained to image A and the ping-pong
images", and called it one line. It is one line and it does not compile.** The
retraction is below, after the half that was right.

#### The half that was right, and shipped

`gpu/pipeline.c3:577` and `:739` take their colour attachment format from
`target.color_format`. In an HDR chain the intermediate passes write float and the
last writes `_SRGB`, so *"am I last"* becomes a pipeline variant: the same body at
slot 3 and at slot N is two different `VkPipeline`s, output format enters the
cache key, and reordering the chain is a recompile. The fix is to take the
decision away from user passes:

> **Every script-authored pass reads float and writes float. A fixed,
> engine-owned tonemap pass is the only thing that writes `target.color`.**

One pipeline shape for every `addPass` body, one fixed pipeline for the encode,
no format in the key, free reordering. It also makes the tonemap always present
and always last, which is what physical lighting wants anyway — a user pass that
forgot to encode would be the washed-out failure §10 already carries as a trap.

That is exactly what `render/chain.c3` does. `POST_CHAIN_FORMAT` is
`R16G16B16A16_SFLOAT`, `MeshPipeline.init_post` takes the format as a parameter,
and `TONEMAP_BODY` — the identity, whose whole job today is the encode — is the
one caller that passes `target.color_format`.

`render/post.c3`'s colour argument survives and improves, as this said it would:
a pass's *output* is raw linear float needing no decode by the next pass, the
body works in linear as it does now, and the final write to `_SRGB` encodes. The
8-bit round trip between passes disappears.

#### The half that was wrong: image A is not the float image

Image A is what the *scene* renders into, and a scene pipeline's colour
attachment format is fixed when the pipeline is built. Dynamic rendering checks
the pipeline's declared format against the attachment, so **a float A makes every
mesh pipeline wrong the moment a post pass is set.** The ways out are both large,
and both are the opposite of one line:

- **A second variant of every mesh pipeline**, keyed on whether a post pass is
  active. That puts a format in the pipeline cache key and makes `setPost` rebuild
  every material's pipeline — the precise thing the paragraph above exists to
  avoid, one layer down.
- **Render the scene into A always**, tonemapping even when no script asked for a
  post pass. A full-size attachment and a full-screen draw on every frame of every
  scene, and it deletes the property that an unposted frame is *the code path it
  always was* rather than a new one that agrees with it.

And neither buys anything today, which is the part that settles it: **nothing in
this renderer produces a value above 1.0.** `target.color` has always clamped
them and no shader has ever complained. What HDR is actually blocked on is
physical light intensities — step 4's material unit — not this step.

So the float went where it pays for itself immediately instead. A pass may now
write above 1.0 and the next pass sees it, which is what a bright pass followed
by a blur needs and what an 8-bit intermediate destroys, and
`the_chain_carries_values_above_one_between_passes` pins it by injection: the
chain's format set to `R8G8B8A8_SRGB` clamps a ×16 ÷16 round trip by 70 levels.
When the scene becomes HDR, A joins the chain's format and the always-on path
becomes the right answer — for a reason that will exist by then.

**The lesson is the same shape as entry 2's and worth stating once more:** "one
line" was a claim about the *edit*, and the cost was in what the edit was
declared against. A format that lives on a pipeline rather than on an image is
not visible from the image, and the way that surfaces is writing the line and
compiling it rather than counting the files it touches.

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

Both halves of that are real and neither is expressible in a signature. The layout
half is at least *checked* — entry 2 above is the whole story of finding out that
it is the only half core validation can check, which is why it is still there to
be got wrong.

`PassIo` is three fields — `src` view, `dst` view, extent — because the kind is
narrow. `@optional` earns its keep at once: a single-shader pass needs no
`resize`, a pyramid does.

*As built it is seven*, and none of the four extras is padding: `prev` and `scene`
are two sources because the chain has two edges; the destination arrives as an
image *and* a view because the pass opens it with a barrier and a barrier names an
image; the sampler is the chain's; and the asset table is what a pass's own
samplers resolve through. What stayed absent is the list that mattered — no `Gpu`,
no `Target`, no frame slot, no scene, no instance buffer.

Two things C3 required that this did not know. **A struct must declare the
interfaces it implements** — `struct PostStage (FullscreenPass)`, not merely
having the methods; `@dynamic` on the methods alone gives
"'PostStage*' cannot be implicitly cast to 'FullscreenPass'". And the receiver is
implicit in the declaration and explicit in the implementation
(`fn void? PostStage.record(&self, …) @dynamic`). Both were established by
compiling a twenty-line throwaway before any of this was written, which is the
same move §10 insists on for driver features.

Worth declaring at the point `PostStage` becomes its only implementer, precisely
because it costs nothing at one implementer and means a bloom pass drops in later
without restructuring the chain. **The tonemap made it two implementers on the
first day** — not a second type, but a second *instance* going down the identical
`record` with a different destination and a different pipeline format, which is
the cheapest possible evidence that the contract is a contract rather than a
description of one call site.

**Why not across all three kinds.** An interface types the arguments; it cannot
type the layout protocol. Applied to geometry and full-screen passes together it
would grant compile-time substitutability the GPU does not honour — the compiler
would accept a shadow pass in a full-screen slot, and the failure is a validation
error in a debug build or a black frame in a release one — and since `-D DEBUG`
(`src/debug.c3`) the release build is the one without the layer. Today the passes
simply having different functions with different arguments prevents that
outright, and that is the stronger guarantee.

Two things to know before writing it:

- **Interface values are pointers.** A `List` that grows invalidates every
  interface value taken from it, and `addPass` mutates the list at arbitrary
  times. Take them fresh from `&list[i]` each frame; never cache one.
- **This would be the project's first interface.** `src/` contains no `interface`
  declaration and no `@dynamic` anywhere. That is a reason to introduce exactly
  one, where it pays, rather than four. *It is still exactly one.*

### What this does not cover

- **Downsampled intermediates.** A bloom pyramid at ½, ¼, ⅛ means per-pass
  extents, so P0/P1 become a pool keyed by extent. Still not a solver, but not two
  fields either. This is the piece that grows first.
- **Reading three passes back**, or a pass fanning out to two consumers. `prev`
  and `scene` are the only two edges.
- **MRT** — a pass writing two attachments.

### Order of work

	1. driver batch          DONE, and half of it by deletion. apiVersion 1.4 with
	                         the per-device check, and dynamicRenderingLocalRead
	                         enabled and not yet used — those two shipped. GENERAL
	                         was written in full and reverted (entry 2); depth state
	                         out of PipelineState was dropped before it was written
	                         (entry 4). Both are recorded above with the measurement
	                         that killed them.
	2. image A's format      DONE, and not where this said. The *chain* is
	                         R16G16B16A16_SFLOAT; image A stayed `_SRGB`, because
	                         the format is declared on the scene's pipelines and
	                         not on the image — see "The format decision".
	3. chain + ping-pong     DONE. render/chain.c3 — three images, two rules,
	                         FullscreenPass, an engine-owned tonemap. Every test
	                         that existed stayed green; five new ones cover N > 1.
	4. the material unit     §2's blocker. The actual PBR work; touches none of the above.
	5. IBL bake              on texture.c3's one-shot path. hostImageCopy lands here.
	6. three.addPass         DONE, with the chain. Handles carry a stage index and
	                         an append does not invalidate the ones already held.
	7. fuse the pointwise    local read, measured against 3 rather than assumed. The
	                         first step whose value is a number and not a shape.

3 and 4 do not touch each other, which is the useful part: the pass work and the
PBR work are separable, and only the format decision sits across both — which is
the sentence entry 5 below turned out to be about.

**6 came with 3 rather than after it, and the reason is worth keeping.** It was
listed second so that the chain could be proven before a script could reach it,
and once the chain existed `addPass` was one C3 verb, one binding and a stage
index on the handles — while *not* shipping it would have left `record_chain`
looping over a list that could only ever hold one entry, which is a loop no test
could exercise. The proving happened in the tests instead, which is where it
belonged: four of the five new checks are only reachable at N > 1.

**1 was worth doing on its own, and half of what it was worth was finding out
which half was wrong.** Two of its four items did not survive being written down
against the actual code — one died on reading four constants, the other on an
injection test — and both would have been far more expensive to discover with a
post chain, a shadow pass and a UI layer already built on top of them. That is the
argument for taking the cheap, independent, fully-tested batch first, and it is a
better argument after the fact than it was before it.

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
  project does not have. A frame is two render passes, three images and four
  barrier call sites; shadows, a UI layer, a post chain and depth-in-post together
  take that to about seven. A graph that schedules four passes is a scheduler with
  nothing to schedule. **§13 is the counting and the shape the alternative takes**
  — a stage list, a chain whose adjacency is its own edge set, and the one trigger
  that would change the answer, which is script-authored *edges* rather than pass
  count. This entry used to read "forward, one light, one post pass at most",
  which was written before `setPost` existed and read as though post were
  hypothetical.
- **The post-processing stack is a chain, and it is built.** This entry has been
  overtaken twice. It first read "no post-processing stack" as part of the line
  above and the whole of it was meant; then the single-pass half was built at the
  user's request (`three.setPost({ fragment, uniforms })`, one agent-written
  `float3 post(Post p)` over the finished frame, on the window, on `render()` and
  on every screenshot alike); now the chain is.
  `three.addPass({ fragment, uniforms })` puts another full-screen pass at the end
  of the list, each reading what the one before it wrote as `p.color` and the
  frame the geometry left as `p.scene`, in linear float end to end, with an
  engine-owned tonemap doing the display encode last. Three images whatever the
  length, and the barriers derived from adjacency rather than declared. §13 is the
  whole argument.
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
- **No `.gltf` output and no external `.bin`.** A `.gltf` beside a `.bin` beside
  a folder of `.png`s is four things to copy and four things to lose.
- **The export writes no camera and no lights.** glTF has both and this project
  has one turntable and a hardcoded directional term, neither of which is a scene
  object a script can address. Writing them out would be exporting an
  implementation detail as though it were content. **Half of that has now
  changed**: §12 bound `three.light`, so the light *is* addressable and the
  reason not to export it is gone. One directional light and an ambient floor map
  onto a glTF `directional` light and nothing else, which is a small and honest
  write. The camera's half of the argument stands — a turntable is not a
  `perspective` camera with a transform, and inventing one would be exporting a
  fiction. Splitting this entry is the next edit to it.
- **No per-instance texture, and no alpha-to-coverage. Blending itself is
  done.** This entry used to read "no per-instance alpha blending", and it named
  its own trigger — "water, glass or foliage cards, at which point the work is
  back-to-front ordering against instanced buckets, not the blend state" — which
  is exactly the work that was then done. A blend mode is a `PipelineState` field
  and a cache key (dynamic blend state is unusable here, §10), `mesh.color.a`
  fades one copy of a shared draw call, and every transparent bucket is sorted
  farthest-first against the near plane and recorded after the opaque ones.
  `examples/village` no longer has to fade its chimney smoke by walking the
  colour toward white.

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


TODO:

- There is no vertex stage. The splice point is fragment-only; the vertex shader is fixed. No GPU vertex displacement — no waving banners, no ribbon trails, no GPU-simulated particles. Motion is JS moving nodes in setAnimationLoop, which stays one draw call but is CPU work under a 100 ms/frame kill switch.
- No per-pixel alpha. Soft fade is material.opacity (whole material) or mesh.color[3] (per copy). Per-pixel is discard (hard edge) or additive (black is transparent). Covers most energy/fire/dissolve looks; doesn't cover a soft-edged alpha smoke puff.
- Blending is baked at construction, so "fade from solid to additive" is two materials, not a property write.
- 13 floats is tight — a 3-row float3 table plus a clock is already 52 bytes and the 14th float is refused by name. Bake constants into the shader text, spend uniforms only on what moves.

What's actually off the table

- No depth in post — p.depth doesn't exist (verified: "'depth' is not a member of 'Post'"). So no depth of field, no soft particles, no depth fog, no SSAO.
- Passes chain (three.addPass) but do not branch: a pass reads the one before it and the original frame, nothing else, and every pass runs at full resolution. Bloom is a threshold-and-blur at full res, not a downsample pyramid, and there is no way to say "this pass reads that one".
- No render-to-texture / feedback — no accumulation trails, no motion blur history.