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

- **The post pass is one pass, and there is no chain.** `three.setPost` replaces
  whatever was running; there is no way to say "blur, then bloom, then tonemap".
  A chain is ping-pong: a second sampled image, N-1 extra full-screen passes, and
  a rule for which of the two images the last one writes so that `target.color`
  is still what the blit reads. The machinery is nearly all there — `PostPass`
  already owns an image, a sampler and a pipeline, and `Renderer.record_scene`
  already has the branch — but the *ownership* changes: one live pipeline becomes
  a list, and the argument for owning it outright rather than through
  `PipelineCache` (one slot, one key) stops holding. Composing effects inside one
  body is the workaround and it is a real one, because a hand-written combined
  body is cheaper than two passes anyway. **Trigger:** something that genuinely
  cannot be one body — a separable blur, or anything wanting a downsampled
  intermediate.

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
  project does not have: forward, one light, one post pass at most. A graph that
  schedules four passes is a scheduler with nothing to schedule.
- **No post-processing *stack*. One pass is done.** This entry used to read "no
  post-processing stack" as part of the line above, and the whole of it was
  meant. It was revisited at the user's request and the single-pass half was
  built: `three.setPost({ fragment, uniforms })` runs one agent-written
  `float3 post(Post p)` over the finished frame, on the window, on `render()` and
  on every screenshot alike, with the scene rendered into a sampled `_SRGB` image
  and the post shader writing the target the blit already reads. What stays
  absent is the *stack* — no chain, no ping-pong, no named passes to compose, and
  §2 carries the trigger. Composing effects inside one body is not a workaround
  so much as the cheaper thing: two passes cost a second full-screen read and
  write that a combined body does not.
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
