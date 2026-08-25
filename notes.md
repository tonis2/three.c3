# three.c3 — notes

**How things work, why they were decided that way, and what has already cost
somebody a session.** `plan.md` is the task list beside this file and holds
nothing else; anything here is settled, and an entry moves *into* this file the
moment it stops being work somebody has to do.

**Section numbers match `plan.md` and the source comments that cite them** —
§4's half-match rule, §12's specular decision, §15's draw record. A number is
the same number in both files, so a citation resolves against whichever of the
two still has material under it. Renumbering would break fifty citations to tidy
a table of contents.

**The source also cites names that are only in history** — `game.md` G5/S3,
`event_loop.md`, `m3_stage.md`, `base_stage.md`. `git log -p -- plan.md`
resolves every one.

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

	c3c test --trust=full       756 passed, 0 failed, leak-clean

**The thesis, which no milestone below may quietly abandon:** a script describes
shapes and never touches a vertex, and every copy of one shape sharing one
material is one draw call. Two named channels vary per copy — `color` and
`variant` — and nothing else. When a milestone cannot hold that, it says so out
loud and argues for the exception; it does not just stop being true.

---

## 2. Deferred by design — the ones that were built, and what they measured

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

---

## 3. Skinning — how the three paths behave

*(Three paths over one shader contract — a baked pose table, a live palette
under `skeleton: true`, and an opt-in compute path. `src/scene/skin.c3` carries
the design and the costs.)*

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

---

## 4. Textures — the notes the KTX2 work will need

**A roughness map has nowhere to go, and that is a lighting decision rather than
a texture one.** Mips, colourspace and normal maps are closed; what a roughness
or metalness map lacks is a term to feed, because the built-in light is one
lambert factor with no specular. So it loads correctly and only a custom `shade`
body can do anything with it. **Do not add a roughness input to `mesh.slang`
before deciding what §12 does about lighting** — a specular term and the light
that drives it are the same decision, and a roughness map wired into lambert
would be a field that changes nothing. §14 is where that rule was tested against
a feature that wanted the fields and did not get them.

**`ktx` needs no staging step** unlike `slang.c3l` (`libzstd.a` is checked in
per target, reached through the library's own `linklib-dir`) and no
`--recursive`. And **`ktx::vk` collides with `vk`** — fully qualify at the call
site; `project.json` says so where the dependency is.

`ktx::vk` is the VkFormat table and block-size arithmetic `gpu/texture.c3` needs
to upload an image it did not decode; `ktx::basis`/`uastc`/`etc1s`/`bc7`/`bcn`
transcode in pure C3, so a Basis texture becomes BC7 on the device rather than
being expanded to RGBA8 — the difference between a game's texture budget and a
demo's.

`ktx::mipgen` is there too. `gpu/texture.c3` generates its chain by blitting each
level from the one above, on the device, which is right for an RGBA8 image it
just uploaded and is **not available for a compressed one** — a BC7 image cannot
be blitted and carries its own levels, which is why `can_generate_mips` asks per
format rather than answering once. So `mipgen` is for the KTX2 path writing an
image the transcoder produced, not a replacement for what is there.

**The sky is a render feature, not a loader**, and bundling them under "image
loading" is how the second one gets underestimated. **Do not build an LDR-PNG
cubemap in the meantime**: it would be replaced rather than extended, since the
pipeline differs in format, mip handling and whether the shader treats it as
radiance. `ktx::container` already gives faces, so the container problem is
solved rather than pending.

**Async load is smaller than it was**, because the synchronous half is done. Now
that `three.load` is metadata-only and upload happens per mesh, the thing worth
making async is `asset.mesh(...)` / `asset.instantiate()` — a bounded, per-mesh
unit of work — rather than a whole file. There is little point streaming 200
meshes in the background that were never going to be placed. The promise
resolves from the job queue `drain_frame_jobs` (`frame_loop.c3:257`) already
drains.

---

## 5. UI and text — the decisions, made before the binding

**Where it draws.** After the scene, into the same offscreen target — so
`--screenshot` and the MCP `screenshot` capture the UI too. **An agent that
cannot see the HUD it just built cannot correct it**, which is the same argument
`getApiDocs()` makes, applied to the HUD. "Before the blit" was written when a
frame had one pass and is now ambiguous: **after the post chain, not before it**,
or every effect a script sets bloods into the HUD. §13 places it as the last
stage before the target closes, and prices it — no attachment of its own and at
most one barrier, because it writes the colour image everything else already
writes.

**Input arbitration is the whole difficulty.** A click on a button must not also
shoot the gun. The UI gets the pointer first and marks the event consumed;
`onClick` and `scene.pick` see only what is left. `MouseTracker`'s edge machinery
in `scene/input.c3` is where the flag belongs — it is already the thing that
decides what a click *is*.

**The coarse half of that landed first and does not answer it.**
`three.controls.enabled = false` takes the mouse away from the camera wholesale,
which is what a script driving its own camera needs and is no use at all to a
HUD: a button and the world behind it both want the same click, and turning the
camera off decides nothing about which of them gets it.

**A click cannot say it was handled, and that is decided rather than pending.** A
handler returning `false` was the obvious cheap version and it suppresses
nothing: a click *is* a press and a release that did not travel, so by the time
one is recognised no orbit has happened. The conflict is over the **press**.

**Retained or immediate.** Immediate-mode costs a full UI rebuild in JavaScript
every frame, inside the frame budget. Retained-mode is a second scene graph with
a second lifetime problem. Follow whatever the library already is, and if it is
immediate, **measure the per-frame cost against the 8 ms soft budget before
building a game on it**.

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
c3c test --trust=full -D DEBUG          # the one that has to pass before done
c3c test --trust=full --test-filter <suite>
```

**Run the `-D DEBUG` suite once, and not the plain one as well.** Leak tracking
is on in both — `--test-noleak` is what turns it off, not the build flag — so
the `-D DEBUG` run already covers everything the plain run covers and adds the
Vulkan validation layers and `@debug_log` on top of it. Running both is a second
build and a second full suite for the `$if !DEBUG_BUILD` branches in
`gpu/device.c3`, which are a `return false` and a diagnostic line nothing
asserts on. `-D DEBUG` is the only switch for the layers; there is no
`--validate` on the command line.

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

---

## 12. Lighting — what the one light is, and what the shadow does

**There is one directional light and it is four floats**, and it casts one
shadow. The naming rule stands for whatever comes next: it is deliberately not
`scene.add(new three.DirectionalLight(...))`, because that name promises adding,
removing, colouring and duplicating and this renderer can do none of them.

Two properties of the shadow worth knowing before building on it: **the camera
frustum stops culling while the pass is on** (a caster the camera cannot see
still throws a shadow into the frame, so `culledLastFrame` reads 0), and **there
is no `castShadow` per object**, because a third per-copy channel splits buckets
and that is the trade the whole renderer refuses.

---

## 13. The pass system, and what it is not

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

## 15. The draw buffer

*(Per-draw data is a `DrawRecord` in a host-visible buffer and the push block
carries its address. The block is 24 bytes where it was 76, material uniforms
went 52 → 104, and a new vertex stream now costs 8 bytes of a buffer rather than
a trade against them.)*

**Not `vkCmdDrawIndexedIndirect`, and not yet.** It buys nothing here: geometry
is one buffer per mesh so `firstIndex` and `vertexOffset` are always zero,
textures are push descriptors written per bucket, and a `ShaderMaterial` is its
own pipeline — each of those independently forces one command per bucket. An
indirect draw would be the same commands plus a buffer read, minus the validation
layer's ability to check the arguments: a bad record becomes a hang instead of an
error.

---

## 16. What an exported scene keeps

*(Side, texture transform, the three extra maps, the camera and the light all
cross.)*

**Two things do not cross, and both are deliberate.** The light's **ambient
floor** has no punctual equivalent — ambient was removed from
`KHR_lights_punctual` before ratification — so a scene with a high floor reloads
darker, and folding it into the directional intensity would be a different
picture rather than the same one. And **metalness and roughness** are not
written, because §12's rule holds: no specular term means a number in the file
that never affected a pixel.

**Lines are the one item deferred.** A line mesh has no CPU copy of its vertices
(`upload_built` skips `build_bvh`, which is what keeps one) and a script's
`three.lines()` is indistinguishable from a helper — both draw with
`LINE_MATERIAL`, which is the test the exporter drops helpers by. Two structural
changes for the least valuable of the six; `mode: LINES` is waiting in the
writer for when it is worth paying for.

---

## 17. Gameplay — what a game needs that a scene does not

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
  is the shape every unbuilt item in §17 of `plan.md` should be built in.
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
broadphase to fix it exists and is unbound — see §17's bulk-spatial-queries
task in `plan.md`, which pays for both.

### What building the camera, the clock and the blending settled

**The follow camera.**

  Two decisions from building it, kept because they are what somebody would undo
  by accident. **The follow writes `Camera.target` and nothing else** — which is
  why a drag, the wheel and `orbit()` all still work while attached, and why
  first person needed no mode: `distance` at zero puts the eye on the point it
  orbits, so third person, first person and scrolling between them are one code
  path. And **it runs last in the tick, on every path out**, because the clip,
  the solver and the animation callback can each move the thing being followed; a
  camera one frame late does not look like a camera problem, it looks like the
  character sliding, and the bug gets filed against the physics.

**Animation blending, and why it is two answers rather than one.**

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

**The clock.**

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

---

## 18. Outdoor scenes — the measurement

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

> **§18.3 was built, and it split them: the lost cull is 0.163 ms, not 0.60.**
> The rest of that 0.60 is the shadow pass's own geometry, which is a different
> item with a different fix. The measurements below were taken by hand before the
> instrument existed and are left as they were written; **§19 has the numbers the
> instrument produced**, and where the two disagree the instrument is right.

**Everything else is rasterisation, and it is quadratic.** +0.20, +0.79, +2.65,
+8.89 per doubling from 1024 — ratios of 3.95, 3.35, 3.35. Textbook fill. At 4096
the frame is **68 % shadow-map fill, 15 % lost culling, 17 % the scene the user
asked for**.

So: the fix `src/render/shadow.c3` already names — a second draw list — is the
*small* one. The large one is that the map is fitted around the whole scene.

### 18.1 Fit the light's box to what the camera can see — built, and the prediction was wrong

**The prediction.** The map was fitted around `Scene.bounds` — 224 units across
for a village the camera frames about 70 of — so roughly nine tenths of the
texels were outside the picture and every one of them was rasterised into.
Fitting to the camera frustum instead was worth "about a tenfold gain in texel
density", spendable either way: keep 4096 for shadows an order of magnitude
sharper, or drop to 1024 for the same quality at 1.47 ms instead of 3.92.

**Built, and the tenfold is not there by default.** `ShadowMap.fit` now takes a
third box — `Camera.view_bounds(aspect, reach)` intersected with `Scene.bounds` —
and spends its texels on that. The extent is the focus box's *diagonal*, so
orbiting cannot change the world size of a texel, capped at the scene's own
light-space extent so a camera that frames everything is fitted exactly as it was
before; and the light-space origin is floored onto the texel grid, so a camera
that moves less than a texel produces a **byte-identical** matrix. That last one
is asserted at the matrix rather than in a picture, because a crawling shadow
edge is invisible in a screenshot.

**What the measurement said, and it corrects the paragraph above.** For the
village the scene's light-space box is 318 x 291 and the focus square is 288 —
**a factor of 1.1, not 10.** The reason is the camera's far plane: it is 640
units and the village is 224, so "what the camera can see" is the whole level and
then some. The frustum was never the thing that bounded the box.

So the item leaves a knob rather than a win: **`three.light.shadow.distance`**,
how far down the view direction to fit, 0 meaning the far plane. With it set the
lever is real — at `distance: 100` the same village renders shadows that differ
from the old 2048 fit in 2.9 % of pixels while running at `size: 1024`, which is
**0.65 ms against 0.99**. Without it, 18.1 buys about 4 % of the shadow pass.

**No default is invented for `distance`.** §18.7's rule stands and this is
exactly the case it was written for: the number that is right depends on how big
the level is and how far the camera stands off, one village is one data point,
and a default picked from it would be picked wrong for a room. The question is
now well posed, though, which it was not before: *what fraction of the far plane
is worth shadowing?* — and it wants a second scene, not more thinking.

### 18.2 Two draw lists rather than one uncalled one — built

**Built, as one list with two ranges rather than two lists.** A draw is kept if
*either* frustum wants it, and the sort puts the camera-visible copies at the
front of their bucket — so `Bucket.visible` is a prefix the colour pass draws and
`Bucket.count` is the whole of it for the shadow pass. One instance array, one
sort, one upload; the second range is a different `instanceCount` on the same
`vkCmdDrawIndexed`. The safety argument is that a caster and the ground it
shadows share x and y in light space and differ only in z, so a caster the light
box rejects laterally cannot be casting into the picture.

Measured on the village at `size` 2048: **1.94 ms to 1.86**, and
`culledLastFrame` back to 2068 from 0.

`stats()` should follow: `culledLastFrame` goes back to meaning the camera cull
even with shadows on, and a new `shadowCulled` reports the light one. Today's
`culledLastFrame == 0` is honest but says nothing, and it is what sent this
investigation down the wrong path first.

### 18.3 Per-pass GPU timings — built

**Built.** `FrameTimer` carries six marks per frame slot rather than a pair, and
`stats()` gained `prepareMs`, `shadowMs`, `sceneMs`, `postMs` and `presentMs`
beside `gpuMs`. They are five consecutive spans between six marks, so they sum to
the frame exactly, and `gpu_test.c3` asserts that they do. The MCP `run_script`
result carries them too, which is the point: the agent that has to ask "where did
this frame go" now reads the answer off the tool result it already gets.

**One caveat, and it is a real one: the total is exact, the split is not.** Apple
runs the vertex stage of one render encoder underneath the fragment stage of the
previous one, so work can be credited to a neighbouring span. The tell, measured:
at 320x180 the scene span reads 0.442 ms with shadows *on* and 4178 instances,
and 0.676 ms with shadows *off* and 2110 — impossible as a like-for-like, and it
is the scene pass's vertex work hiding under the shadow pass's fill. At 1280x720
everything reconciles to within 1 % (0.712 + 1.048 + 0.163 = 1.923 against a
measured 1.941). **So: compare configurations at the same encoder structure, and
trust a delta in `gpuMs` over any single span.**

### 18.4 Terrain is not a pile of boxes — what the box-tile ground cost

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

**The heightfield collider's original premise, kept because §20's leftovers cite
it.** `collision::Heightmap` reported `ShapeType.CONVEX` and its support function
returned one of the four corners of the whole map:

**The premise was wrong.** The note this item carried —
*"collision.c3l already has heightfield testing"* — is true about the file and
false about what it can carry.

`collision::Heightmap` exists, implements `CollisionShape`, and reports
`ShapeType.CONVEX`. Its support function is the problem, and it is worth quoting
what it actually does:

> `Heightmap.furthest_point` builds four `Vec3`s — the four **corners of the
> whole map** — lifts each to its own height, and returns whichever has the
> largest dot product with the direction.

Under GJK that makes the collider a quadrilateral spanning the entire terrain: a
body does not rest on the ground, it rests on the plane through the four corner
samples. On the 200-unit field in `examples/` that is tens of units away from the
surface almost everywhere. Wiring `shape: 'heightfield'` to it would ship a
feature that draws, runs, reports no error and does not work — which is the exact
failure mode every header in this project is written to prevent, so it was not
wired.

**What it would actually take**, and it is solver work rather than a cast: a
heightfield is not a convex shape and cannot be one. The standard construction is
per-contact rather than per-shape — take each nearby body's AABB, find the
terrain cells it overlaps, and collide against **those triangles**, which are
convex and which the library already has a `ShapeType.TRIANGLE` for. That means
generating shapes inside the step rather than owning one per body, which is a
change to how `Physics` feeds the world and not a fifth case in
`build_collider`'s switch.

**What unblocks the NPC phase in the meantime is 18.4b**, and it is worth saying
plainly because it changes the ordering: `terrain.heightAt` and `normalAt` are
how most engines move a character over terrain anyway — sample the ground under
the feet, set the height, use the normal for the slope limit and the lean. A
kinematic character needs no collider at all. What still wants one is a *dynamic*
body — a barrel rolling downhill, a ragdoll — and that is a smaller and later
class of thing than this item assumed.

**18.4a — a heightfield primitive. Built.** `new three.TerrainGeometry({ width,
depth, segments, heights })`, heights being a `Float32Array` or a callback. Built
through the same `GeometryBuilder` and `upload_built` the six existing shapes and
`split.c3` use, so it is one asset, one draw call, no new pipeline and no new
bucket. Normals from the grid, which is the whole difference between ground and
steps. A skirt around the border so the map edge is a wall and not a hole.

**18.4b — query it. Built.** `terrain.heightAt(x, z)`, `terrain.normalAt(x, z)`.
Bilinear over the same grid the mesh was built from, so it *cannot* disagree with
what is drawn — which is exactly the failure the hand-written version was one edit
away from at all times. It is also what makes `align('y', 'min')` mean anything on
open ground, and it is how most engines move a *kinematic* character over terrain:
sample under the feet, set the height, use the normal for the slope limit.

**18.4c — stamping. Built.** `flatten(rect, y)` and `carve(polyline, width,
depth)` — a building pad and a watercourse, the two operations every outdoor scene
needs.

**18.4d — mask authoring. Built.** `three.Mask(size)` with `fill`, `stroke`,
`circle`, `fromHeight`, `blur`, `.texture()`. **The pairing is the point:** carve
the channel and stroke the mask from the *same* polyline, so the mud is where the
water is by construction rather than because two constants were kept in step.

**18.4e — a heightfield collider. Built, in §20.4.**

### 18.5 Three silent failures — built

- **`mesh.geometry = other` throws**, with the reason: a geometry is immutable,
  which is what lets every copy share one draw call. The audit went with it and
  found two more of the same shape — `texture.colorSpace` and
  `texture.generateMipmaps`, both load-time requests spelled the way Three.js
  spells a mutable field, both now refused with the load option to pass instead.
  The other getter-only properties are left alone on purpose: assigning to
  `texture.width` is obviously a mistake in a way that assigning to `colorSpace`
  is not, and a refusal on every derived number is noise.
- **A shader error naming generated code** keeps Slang's text whole and adds a
  sentence after it **only when the reported line is still in the preamble** —
  which after all the `#line` arithmetic means it is genuinely generated — naming
  the uniforms this material declared. The refusal that would have been better,
  "stop using `#define` for uniforms", is still not taken: a uniform has to be
  reachable from a helper at file scope, and a local binding inside the entry
  point is not.
- **The vertex and fragment bodies are one module**, so a helper declared in both
  is `error[E30201]: function 'ripple' already has a body`. One sentence in
  `docs.js`: declare shared helpers in `vertex`, which comes first.

### 18.6 Scatter — the one behaviour a caller has to know

The sampler is bounded rather than exhaustive: it gives up after `count * 24`
tries and returns a shorter list, which a caller reads off `.length`. A hundred
trees in a clearing that fits nine is a scene that ends, not one that hangs.

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

### What §18 delivered, and what it did not

Everything in this section is built except 18.4e, which turned out to rest on a
premise that does not hold — its own entry has the evidence. The corrections the
work produced are worth more than the summary:

- **18.1's tenfold is a factor of 1.1** at the default settings, because the
  camera's far plane and not the frustum was what bounded the box. The item now
  ships a knob, `shadow.distance`, and the win arrives when it is set.
- **18.2's 0.60 ms was 0.163 ms**, because the bound conflated the main pass's
  lost cull with the shadow pass's own geometry. 18.3 separated them.
- **18.4e is solver work, not a cast**, and 18.4b unblocks the NPC phase without
  it.

Two of those three were the estimate being wrong in the pessimistic direction and
one in the optimistic. All three were invisible before 18.3 existed, which is the
argument for having built the instrument first restated as a result rather than
as a prediction.

**What this section does not have** is a second scene. Every number here comes
from one village on one machine, and the shape of that village — wide, flat,
outdoors, shadowed, forty thousand triangles of nothing much — is exactly the
shape that makes shadow-map fill dominate. An interior would rank these
differently, and nothing here has measured one.

---

## 19. Shadows at game scale, and the shading architecture behind them

§18 measured one village and ranked the work inside it. This section is what the
instrument said once it existed, and what it implies for a scene that is not a
village — which is the question §18's own closing caveat left open.

### The two constants

Everything below follows from two numbers, both measured on an M5 at 1280x720
over `examples/lumbridge.js`, 4178 instances, median of fifteen renders.

| `shadow.size` | gpuMs | shadowMs | sceneMs | culled |
|---------------|-------|----------|---------|--------|
| off           | 0.712 | —        | 0.712   | 2068   |
| 256           | 1.314 | 0.496    | 0.806   | 0      |
| 512           | 1.467 | 0.647    | 0.820   | 0      |
| 1024          | 1.570 | 0.721    | 0.840   | 0      |
| 2048          | 1.941 | 1.048    | 0.875   | 0      |
| 4096          | 3.109 | 2.231    | 0.873   | 0      |

**Depth-only geometry costs about 119 ns per instance.** The `size` 256 row is a
depth pass with the fill taken out of it: 0.496 ms for 4178 instances. This is
the number that scales with the world.

**Depth fill runs at about 10 Gtexel/s.** 2048 to 4096 adds 12.6 M texels for
1.183 ms; 1024 to 2048 adds 3.1 M for 0.327. This is the number that scales with
the map, and it is quadratic in `size`.

So a shadow-casting light costs `instances x 119 ns + texels / 10 G`. **At twenty
thousand instances that is 2.4 ms per casting light before a single texel**, and
three casting lights is seven milliseconds of shadow before the picture is drawn.
That is the wall, it arrives long before shading does, and **no choice of forward
or deferred moves it** — it is the cost of rasterising the world once per light
from that light's point of view.

⚠ **Both constants are pessimistic by two to four times, and the reason is the
methodology rather than the machine.** Re-run during §19.3 with sixty warm-up
renders in front of it and the sizes interleaved in one process, the same sweep
reads 0.243 / 0.239 / 0.256 / 0.336 / 0.582 ms — same shape, a geometry floor and
a fill quadratic in `size`, at **about 58 ns an instance and 40–50 Gtexel/s**.
Fifteen renders in a headless process that then exits measures a GPU that never
left its idle clock. The wall is real and arrives in the same order; it is about
1.2 ms per casting light at twenty thousand instances rather than 2.4, so it is
twice as far away as this section assumes. Nothing below changes its conclusion
on that account — §19.1 rejects the prepass by a ratio, and a ratio between two
numbers measured in the same run survives the correction.

### 19.1 The depth prepass, measured and rejected

Tested against the same scene, by measuring the two quantities that bound it
rather than by building it, because they bound it by two and a half times.

- **What it would cost.** A depth-only pass over exactly these instances with
  fill negligible is the 256 row: 0.496 ms. Depth fill for 921 600 screen pixels
  at 10 Gtexel/s adds 0.09. **A camera-side prepass here is about 0.59 ms.**
- **What it could save.** The scene pass against resolution, shadows on so the
  encoder structure is constant: 0.414 ms at 160x90, 0.442 at 320x180, 0.529 at
  640x360, 0.681 at 960x540, 0.874 at 1280x720. Sixty-four times fewer pixels
  costs 2.1 times less, so **0.46 ms is all the fragment work there is** and 0.41
  is a geometry floor a prepass cannot touch. A prepass removes only the
  overdrawn share of that 0.46 — at most half in a scene of this shape.

Pay 0.59 to save at most 0.23. And the mechanism is already partly spent: this is
a tile-based deferred GPU that resolves visibility before shading, which is why
Apple advises against prepasses on their hardware. The data agrees from a second
direction — the same scene with the triplanar and water shaders on costs 0.874 ms
and with plain lambert 0.879. **The fragment cost is not shading, it is
rasterisation and depth bandwidth**, and a prepass would not remove that either.

Revisit only if a scene appears with genuinely expensive fragment work *and* deep
overdraw, and re-run the resolution sweep first — it is four minutes and it
answers the question without writing a pipeline.

### 19.2 Forward+ over deferred, and the reason is the material contract

The instinct to put the passes into a G-buffer and light once at the end is the
right instinct about *lights* and the wrong one about *shadows*: it does nothing
to the paragraph above. What it would change is the shading, and when several
lights arrive that does become the question. The answer for this engine is
**clustered forward**, and the argument is not performance:

- **`float3 shade(Surface s)` returns a lit colour**, with `lambert(s.normal)`
  inside it, and that is the published API every `ShaderMaterial` in every scene
  is written against — the triplanar ground and the water in `lumbridge.js`
  included. Forward+ changes what `lambert` does internally and **not one
  material body has to change**. Deferred requires a material to stop lighting
  and start emitting surface parameters, which breaks every one of them, and
  `shaders/material.slang` has already chosen once that `lambert` is the single
  place lighting lives.
- **This is a TBDR machine.** Forward keeps colour and depth in tile memory; a
  G-buffer is two or three full-screen targets written to main memory and read
  back. Deferred is a desktop-GPU optimisation and a bandwidth tax here.
- Transparency and MSAA both want the forward path anyway, so deferred means
  keeping both.

The shape when it is wanted: a compute pass bins lights into screen-space
clusters, the frame block carries the cluster grid, and `lambert` loops the
cluster's list. Nothing above the shader notices.

**The trigger is a scene with more than a couple of lights in it**, and today
there is exactly one plus an ambient float. This is not next.

### 19.3 Cache the static casters — built, and a settled shadowed frame now costs what an unshadowed one costs

**The largest win available for the kind of game this engine is for, and it was
not close.** In a village the sun does not move and the buildings do not move.
The shadow pass was rasterising 4178 instances every frame to produce a depth
image identical to the previous frame's.

`object.static = true` is the per-node bool, `render/shadow.c3` holds a second
depth image of everything wearing it, and `MeshPass.plan_shadow` picks one of
three shapes per frame: draw everything (nothing is static), draw nothing at all
(nothing that casts is moving — the cached image *is* the map and the colour pass
samples it), or copy the cached image into the live one and draw the movers over
the top.

**Measured on `examples/lumbridge.js`, 1280x720, 4178 instances, `shadow.size`
2048.** Four configurations **interleaved in one process**, five rounds each,
median of thirty renders per round after sixty warm-up renders — see the warning
under the table, because the methodology is the finding.

| | gpuMs | shadowMs |
|---|---|---|
| shadows off | 0.276 | — |
| on, nothing cached | 0.521 | 0.334 |
| on, all static, settled | 0.344 | 0.000 |
| on, one mover over the cache | 0.288 | 0.078 |

The settled row is the result: **0.344 against 0.276 with shadows switched off
entirely.** The pass is gone rather than cheaper, and what is left of the
difference is the nine PCF taps the colour pass now actually runs — with shadows
off `shadow_factor` returns on its first line. The mover row is the honest
general case: a full-image copy plus one draw is 0.078 ms where the whole pass
was 0.334.

At `shadow.size` 4096 the same comparison is 0.766 uncached against 0.341
settled, which is the shape to expect: the cache removes the fill as well as the
geometry, and the fill is the half that grows with the map.

⚠ **These are not comparable with the size-sweep table at the top of §19, and the
reason is worth writing down.** Re-run warm, the whole sweep is two to three
times cheaper than that table records — 0.336 at 2048 against 1.048, 0.582 at
4096 against 2.231 — while its *shape* reproduces exactly (a geometry floor of
about 0.24 and a fill that is quadratic in `size`). The difference is GPU clock
state: a headless process that renders fifteen frames and exits measures a GPU
that never left its idle clock. Anything comparing two shadow configurations
should interleave them in one warmed process, as the table above does; anything
comparing across sessions should not.

Three things the design had to answer, and what each one came out as:

- **It does not split a draw bucket**, which was the condition the whole idea was
  worth having under. The flag is a tiebreak in `build_draw_list`'s sort rather
  than part of the bucket key, so each bucket is laid out
  `[visible dynamic | visible static | hidden static | hidden dynamic]` —
  `visible` stays the prefix `record` has always drawn and the static run is
  contiguous. `Bucket.static_first` carries the diagram. The cost is that the
  *dynamic* casters of a bucket that also holds static ones are two runs and so
  two draw calls in the movers' pass, which is paid on the small half by
  construction.
- **The invalidation is bumped by the world-matrix walk**, not by the setters.
  That is the correction the design needed: a static wall parented to a dynamic
  group moves when the group does, and the setter was handed the group.
  `Scene.update_branch` is the only place that knows a node actually moved, so a
  static node whose world matrix is recomputed bumps `Scene.static_revision`
  there; `Scene.invalidate` covers the changes that have no walk to be seen by —
  adds, removals, re-parenting, a material swap, joining or leaving the set.
  `moving_a_group_rebuilds_its_static_children` is the injection proof.
- **§18.1's fit had to be given hysteresis**, exactly as this entry predicted.
  A stored depth image is only depths in a particular projection, so a fit that
  recentres every frame is a cache thrown away every frame. `ShadowMap.fit` now
  takes `stable`: it fits a square `SHADOW_FIT_SLACK` (15%) larger than the focus
  needs and **keeps it for as long as the focus stays inside it**. That costs 13%
  of the texel density §18.1 won and is charged only to scenes that marked
  something static — a scene with nothing to cache is fitted exactly as before.
  On lumbridge the two frames differ in 2.45% of their bytes by a mean of 2.9/255
  with nothing over 32, which is a shadow edge moving by a texel.

**Refused on anything with a skin.** A character's silhouette is `Node.pose`, an
offset into a palette that an animation rewrites without touching a transform, so
"it does not move" cannot be made true of one. `Scene.set_static_caster` returns
whether it took, and the JS property reads the answer back rather than assuming.

**One measurement that came out backwards, left here rather than acted on.**
`SHADOW_PLAN_STATIC` exists because a frame in which nothing casting moves should
not need to copy an image to sample a copy of it — so it samples the cached image
directly and records no pass at all. It is measurably the *slower* of the two:
forcing that frame through the copy path as well gives 0.289 against 0.344 at
`size` 2048 and 0.324 against 0.341 at 4096, repeatably and with a tight spread.
The copy is nearly free on this hardware (0.078 ms at 2048, 0.094 at 4096 — it
barely scales, so it is not bandwidth-bound), and sampling an image that has only
ever been written by a render pass appears to cost the fragment shader something
that sampling one written by a blit does not; lossless depth compression is the
obvious suspect and is not proven here.

It was not acted on because the gap is 0.02–0.06 ms, the direction may well be
this machine's rather than the design's, and "nothing moved, so nothing is
recorded" is the cheaper answer on any device where a full-image copy is not
free. **The trigger to revisit is a device where the copy shows up** — the
experiment is two lines in `MeshPass.plan_shadow` and the numbers above are what
to beat.

What is left is the fill, which is what §18.1 attacks and §19.4 would finish.

### 19.5 The CPU side of a frame, which nothing measures

`gpuMs` and the five phase spans are GPU timestamps. Everything below is CPU
cost inside `Scene`/`MeshPass` that no counter in the project reports, found by
a review pass over the renderer after §18 landed. Four of the five are fixed; the
one that is left is written down here because nothing about it has changed.

- **Fixed: the draw-list sort was quadratic.** `std::sort::quicksort` pivots on
  `list[l]` with no median-of-three and no three-way partition, so a run the
  comparator calls equal peels one element per pass — *k²/2* for a run of *k*.
  The draw list is a few thousand draws over as many distinct keys as there are
  buckets (nine in the village), pushed in node-slot order and therefore already
  ascending. Measured at 4178 draws in 9 buckets: **8.7M comparisons and 20.4 ms**
  against mergesort's 24.9k and 0.196 ms, same answer element for element.
  `Scene.build_draw_list` and the edge dedup in `lines.c3` now both use
  `mergesort`, which is O(n log n) worst case and stable.
- **Fixed: `Scene.bounds` was exact and uncached.** It transforms *every vertex*
  of every drawable node — 100k–370k vertex transforms on the village — and was
  called once per frame from `prepare` whenever shadows are on, and a second time
  per frame whenever a follow camera is attached, because `follow_camera` calls
  `derive_camera_planes` every tick. The value only changes when the scene does.
  `Scene.bounds_box` is now the answer and `Scene.bounds_current` is whether it is
  still good. The invalidation was the whole of the risk and it is one function:
  `Scene.invalidate`, called by every setter, by `create_slot`/`kill`, by
  `set_parent`, and by the three writers outside `scene.c3` that reach for
  `Node.dirty` directly — `AnimationPlayer.apply`, `Physics.write_back` and
  `setTransform` at the JS boundary, all of which now call `Scene.mark_moved`
  instead. `the_bounds_cache_notices_every_way_a_scene_moves` walks all five
  doors, including the one a naive version misses: a *parent* moving.
- **Fixed: `update_world_matrices` ran three to five times per frame** — once per
  `Scene.bounds`, once from `follow_camera`, once from `Scene.update`. The dirty
  flag saved the matrix arithmetic on the repeats but not the traversal, the
  per-node validation, or the 64-byte by-value `parent_world` copy per recursion.
  `Scene.matrices_current` makes the repeats free, cleared by the same
  `invalidate`. The cost of that is worth stating: `Scene.touch` is no longer
  optional after a hand-written `node.position = ...`, because the walk that used
  to notice on its way past may not run at all.
- **The instance array is written twice.** `build_draw_list` fills a
  `List{Instance}` (~635 KB on the village) that only `write_instances` reads,
  which then `mem::copy`s the whole of it into the mapped buffer. The count is
  known before the coalescing loop, so the loop could write straight into the
  slot's buffer the way `write_live_poses` and `build_draw_records` already do.
- **Fixed: `Scene.stats()` rebuilt the entire draw list**, instance records
  included, to report counts — none of which has ever been read off an `Instance`.
  It is called after every script run, so an agent polling `stats()` paid for
  635 KB of records nothing would look at. `build_draw_list` takes `counts_only`
  now and `stats()` is its only caller; the buckets are still built, because the
  sort that produces them is what `drawCalls` *is*. `stats_counts_without_writing_the_instance_array`
  asserts both halves and that the next frame still builds the list.

**Not doing:** the depth prepass (19.1, measured), and deferred shading (19.2,
the material contract). Both are written down here so that the next person to
have the idea finds the measurement rather than the argument.

---

## 20. Authoring a level, and the four things that cost the time

§18 and §19 measured the renderer from inside it. This section is the other
direction: one level — `examples/crash_canyon.js`, a Crash-Bandicoot-shaped path
through a canyon — built against the shipped API by someone reading
`getApiDocs` rather than the source, and the four places that cost hours instead
of minutes.

**None of the four is a rendering defect.** Three are missing instruments and one
is a contract written to catch a memory bug that now catches scenes. That
distinction is the whole argument of this section: the engine draws this level
correctly at 21 draw calls and 2.4 ms, and told the author almost nothing while
it was being built.

What it ships, for the numbers below to be against something: 126,492 triangles,
21 draw calls, 732 instances, 157 bodies, 16 generated textures, a four-layer
`LayeredMaterial` over a `TerrainGeometry`, and a kinematic capsule that shoves
39 dynamic crates. Boot to first frame is 2.18 s, inside the default 5 s script
budget with no `three.budget` raise.

**All four are built.** Each is kept below as it was written, with a
`*(Built: …)*` paragraph on it — the argument for wanting the thing is what makes
the shape of the answer readable, and in two cases the building turned up a
defect the section had not predicted. Both are recorded where they were found.

### 20.1 The spatial hash refused a level-sized collider, and the assert was load-bearing

The first thing the level tried to do was give the ground one static box. It got:

    @require "box.size().length_sq() < 100000" violated:
    'Aabb box is too big, could be because memory errors'
      collision.PhysicsWorld.add_body (solver/resolver.c3:514)

`spatial_hash.c3:89`, and the note in it is why this is not a one-line deletion.
The contract reads as a debug check left behind, and the temptation is to remove
it. **It is holding up a triple loop.** `SpatialHash3D.insert` walks every cell
the AABB covers at `cell_size = 2.0` and pushes the id into each, and
`@get_pairs` then walks every occupied cell:

| collider | cells inserted |
|---|---|
| one corridor floor slab, 30 x 4 x 34 | 864 |
| the level's 13 slabs and 68 kerb-wall boxes | **13,680** |
| the single 254 x 4 x 254 ground box that was refused | **49,152** |

So deleting the assert does not unblock the scene. It converts a loud failure
into a silent 49,152-entry insert and a broadphase that walks it every step, at
sixty steps a second — which is the failure mode this project's headers are
written to prevent, arrived at from the other side.

**What it actually wants is a large-object bucket.** A body whose AABB spans more
than some cell count — 64 is a reasonable first guess and the number should be
measured, not chosen — goes into a list that is tested against every cell
occupant rather than being smeared across the grid. This is the standard
construction and it is the shape the hash is already missing: static level
geometry is *precisely* the thing that is both large and never moves, so it pays
the insert cost once and the pair cost forever.

**The other half of the same contract is pure debug and should go.**
`size().length_sq() > 0.1` rejects any collider under 0.183 units a side. The
level's crate debris is 0.32-unit chunks, which clears it — barely — and anything
finer does not, so the burst of chips is hand-integrated in the frame loop
instead of being twelve real bodies. A one-cell box costs one cell; there is
nothing for a floor under it to protect.

*(Built: `SpatialHash3D` grew a large bucket. A box covering more than
`LARGE_CELLS` (64, an 8x8x8-cell region) goes into `large` and into no cell at
all; `boxes` keeps every id's AABB, and `@get_pairs` walks the bucket against it
once a step — exact, `large.len() * boxes.len()` box tests, and a number a caller
can see. `insert`, `remove` and `update` handle all four transitions across the
threshold, because a body that ended up in both places or in neither is a pair
against something that is not there. The lower bound is gone as argued. **The
upper bound is gone too, which was not the plan**: with a bucket there is nothing
for it to protect, so what is left of the contract is the half that was never
about size — a NaN corner fails `length_sq() >= 0` and is caught with a caller
still attached. `@get_nearby_objects` had to learn about the bucket as well, or
the one query that answers "what is near this point" would be blind to the floor
the point is standing on.

**The defect this turned up is not in the hash.** The first version guarded the
bucket scan with `if (other == entry.id) continue;` inside a `HashMap.@each` —
whose body is a macro body block, not a loop body, so the `continue` bound to the
enclosing `foreach` and the first self-pair abandoned the whole scan. It compiles.
The symptom is a body falling through the floor, and the only reason it was
caught in minutes rather than in a scene is that `physics_test` drops a ball on
one. Written down in the file, because the next person to guard a clause inside
`@each` will write the same line.)*

### 20.2 Shadows were correct, and diagnosed nothing

The level spent about an hour on a frame with no visible shadows in it. **The
renderer was right the whole time.**

The sun was at 32 degrees of elevation. The canyon walls are 20 units high beside
a corridor 12.6 units wide, and 20 / tan(32 deg) is a 32-unit shadow — so the
entire path was genuinely inside the wall's shadow, every object's own shadow
landed inside a larger one, and the frame read as if the shadow pass were not
running. `stats().shadowDraws` said 19 the whole time, which is true and which
answers a question nobody was asking.

What it took to establish that, in order: an A/B scene proving `LayeredMaterial`
receives shadows at all; four variants of the level bisecting light direction,
the post chain, `unloadUnused` and the static-caster flag; a read of
`ShadowMap.fit` to rule out the fitted extent; and finally decoding the PNG in
Python and averaging the luminance of the lower third of the frame, which settled
it in one number:

| sun elevation | `shadow.intensity` | mean path luminance |
|---|---|---|
| 32 deg | 0.8 | 74.9 |
| 32 deg | 0.0 (off) | 92.2 |
| 58 deg | 0.8 | 104.4 |

Darker *with* shadows than with them off, at the same sun: everything visible was
shadowed. **Nine renders and a PNG decoder to learn a fact the fragment shader
had in a register.**

Three things would have answered it, and none of them is a change to how shadows
are drawn:

- **`three.debug.view = 'shadow'`** — `shadow_factor` written out as greyscale
  over the frame. `setPost` already compiles a body, binds uniforms and applies
  identically to the window, `three.render` and every screenshot. This is a body
  selection, not new plumbing, and it turns the hour into one render.
- **`three.light.shadow.debug = true`** — the depth image blitted into a corner.
  Answers the other half: is anything in the map, and is the fit where the author
  thinks it is. Neither question is answerable today from a script.
- **A derived default for `shadow.distance`.** §18.1 already concedes the default
  is the wrong one — *"the default far plane is much larger than most levels, so a
  wide outdoor scene gets nothing from the fit until you set this"*. This level
  set 70 by trying numbers. The camera knows its own near, far and orbit
  distance, and the focus box is already computed in `fit`; a default that reads
  one of them is strictly better than a default that is known to be wrong.

The third is the one that would have prevented the problem rather than shortened
it, and it is the cheapest.

*(Built, with the middle item in a different shape. `three.debug.view` takes
`'off'`, `'shadow'` or `'shadowMap'` — a `float4` on the frame block and a branch
at the end of both shading shaders, which is the body selection the entry
predicted, though in the shading pass rather than in post: `shadow_factor` lives
there and post has neither the map nor a world position. `'shadowMap'` draws what
the lookup reads and paints **magenta for outside the fitted box**, which is the
"is the fit where I think it is" question answered as a picture in one render.

**The depth-map inset became numbers instead.** `three.light.shadow.fit` returns
`{ live, center, extent, near, far, texel }` for the last frame, read back out of
the same nine numbers `fit` wrote. A fitted box is a box: an inset is a thing to
squint at, and a number is the only one of the two a headless run can assert on —
which is 20.3's whole point, and the two items are better together than either
was alone.

The default for `shadow.distance` is now five times the camera's orbit distance,
derived every frame. Five is one measurement and a geometry argument: at a
45-degree field of view a camera `d` away frames `0.83 d` of world, so `5 d` is
about six frame-heights down the view direction — and it is within ten per cent
of the 70 the level arrived at by trying numbers at an orbit distance of 13.
Setting it explicitly still beats the derived number and the knob stays.)*

### 20.3 Headless rendered one frame, so nothing that moved could be tested

`--headless --script X --screenshot out.png` renders exactly one frame. The frame
loop never runs, and everything a game is made of is downstream of it:

- **Physics never steps.** Crates do not settle, stacks do not stand, triggers do
  not fire. Every claim about the level's 157 bodies had to be made by reasoning
  about a probe run in a *window* and then trusting it.
- **`three.input.press()` does not latch.** Keys are read once per frame, so a
  synthetic press with no frame behind it never becomes `isDown`. Measured
  directly: after `three.input.press('w')`, `isDown('w')` is `false`, while
  `three.camera.planarMove(1, 0)` in the same breath answers
  `[-0.445, 0, -0.896]`, length 1. The movement code was fine and unreachable.
  This is the feature whose own header says it is *"what makes an input-driven
  scene testable at all"*, and it does not work in the mode you would test in.
- **The animation callback never runs**, so the first frame is whatever the
  script left behind. This level's sky needed `sky.uniforms.viewFar` set once at
  setup as well as per frame, purely because a headless render never reaches the
  callback — a real bug in the scene, found by accident.

Two smaller traps, each one wasted round trip:

- **A script is an async function body, so anything after its `return` is dead
  code that runs silently.** A debug camera appended to the end of a scene file
  does nothing, looks exactly like the camera being ignored, and costs a render
  to distinguish.
- **There is no camera override.** Every alternate viewpoint of this level —
  overhead, mid-path, the castle — was a Python script rewriting the source into
  a temporary copy with a different `orbit` call spliced in before the `return`.

**What fixes most of it is one flag.** `--frames N` — run N frames before the
screenshot — steps the solver, runs the callback and latches the keyboard, all
three, because all three are the same missing loop. `--camera yaw,pitch,dist`
removes the source-rewriting. `--screenshot shot-%03d.png --every N` makes a
flipbook out of a run, which is how you would ever see a stack fall.

The gameplay in this level was ultimately verified by monkey-patching
`three.input.isDown` from inside the scene file and calling its own `frame(dt)`
1,600 times: 291.7 units travelled, the corridor fence held to 5.90 against a 5.9
limit, crates broke, a TNT lit and chained, no NaNs. **That harness is the shape
the flag should ship**, and no scene should have to write it.

*(Built: `--frames N`, `--every N` and `--camera yaw,pitch,dist`. `--frames`
implies `--headless` and `--screenshot` alone means `--frames 1`, so everything
downstream reads one field and never asks which mode it is in. The clock is
counted rather than measured — frame `i` is told `i * 16 ms` — so six hundred
frames is ten seconds of game time on every machine and the same run twice is the
same run.

**A frame is a tick and a draw, and the draw was the part that was nearly
missed.** The first version ticked without rendering, which is what the headless
loop has always done — and then `stats().shadowDraws` and
`three.light.shadow.fit` answered "nothing happened" from inside a callback that
had been running for four frames, because the fit is computed in `prepare` and
`prepare` is part of drawing. `render_offscreen` per frame, and exactly one
render per frame either way: `screenshot` draws before it reads back, so a frame
being captured must not also be drawn.

The camera override is applied after the script and again immediately before every
capture, so a scene driving `camera.attach` every frame cannot take the shot back.
Verified end to end: a ball dropped in a `--frames 120` run lands at 0.500 on a
floor whose top is 0, `three.input.press('w')` reads back as `isDown` on frame 1
with `pressed` firing exactly once, and `--every 60` writes `shot-000.png` and
`shot-001.png`.)*

### 20.4 The heightfield collider

§18.4e is correct and its evidence still holds: `collision::Heightmap` reports
`ShapeType.CONVEX`, and its support function returns one of the **four corners of
the whole map**, so under GJK a body rests on the plane through them. It was
right not to wire it.

What has changed is the ordering argument. §18.4e closed by saying a kinematic
character needs no collider, and that what still wants one — *"a barrel rolling
downhill, a ragdoll"* — is *"a smaller and later class of thing than this item
assumed"*. **That class arrived in the next scene.** A Crash level is thirty-nine
dynamic crates that have to rest on, stack on and be knocked across the ground,
and the character being kinematic did not help at all.

The cost of not having it, in this level, is exact: the corridor floor is 13
invisible box colliders and the kerbs are 68 more, which is 81 static bodies and
13,680 spatial-hash cells (20.1) standing in for one terrain shape. It also
forces the level's geometry: **the path is dead flat at y=0 for its entire
length**, not as a style choice but because a flat corridor is the only shape a
chain of axis-aligned boxes can be the floor of. Every slope, step and ramp in
the level is a thing that could not be built.

The construction §18.4e prescribes is per-contact rather than per-shape, and more
of it exists than that entry credits: `Heightmap.query_triangles(Aabb3, List
{TriangleVerts}*)` is written, `ShapeType.TRIANGLE` exists, and the resolver
already has a triangle path in `test_bvh_collision`. What is missing is
`ShapeType.HEIGHTFIELD` and a narrowphase dispatch that routes those pairs to
query-then-collide-triangles instead of to GJK. **It is still solver work and it
is still the largest item here** — but it is dispatch over machinery that exists,
rather than new geometry.

*(Built: `ShapeType.HEIGHTFIELD`, `PhysicsWorld.test_heightfield_collision`, and
`three.physics.add(mesh, { shape: 'heightfield' })` for a `TerrainGeometry`. It
was dispatch over machinery that existed, as the entry said: the per-triangle
work came out of `test_bvh_collision` into `TriangleProbe` and
`triangle_contacts` — one copy of what a one-sided surface means, which is the
kind of rule that otherwise gets fixed in one of two copies — and the heightfield
path is `query_triangles` where the BVH path is `@foreach_triangle`. The collider
is the terrain's own grid rather than a reconstruction, so a body rests on the
same surface `terrain.heightAt(x, z)` reports, by construction.

**`query_triangles` was wound the wrong way round.** Its two triangles per cell
had a face normal of `x cross z` — straight down — which nothing noticed while the
function only ever fed a debug draw, and which disagreed with `get_normal` two
hundred lines above it in the same file. The moment it fed a contact it meant the
ground was a one-sided surface facing away from everything standing on it, and
bodies were pushed through. That is the second defect this section found by
building rather than by predicting, and the more interesting one: the code §18.4e
credited as already written was written and wrong, and no test in the library
would ever have said so.

The gap is closed for the case that motivated it. Six balls dropped on a hill
settle at 0.60 to 0.66 above the ground under them — their own radius, plus what a
sphere on a slope is owed — and a box on a ramp rests at exactly
`half_height / cos(slope)`.

**`crash_canyon.js` was converted, which is where the numbers below come from.**
Thirteen invisible slabs became one `shape: 'heightfield'` body: 157 bodies to
145, the same 21 draw calls and the same 2.24 ms. Over 400 frames the level went
from **eight crates launched at spawn and seven ending up under the terrain** to
none of either — and neither of those two defects was caused by the change, which
is the part worth writing down:

- **Seven crates ended up below the ground with the box floor.** The slab chain
  is 30 x 34 boxes along a path that curves; a crate knocked off the path is off
  the floor as well, and falls. The terrain has no outside until the map ends.
- **Eight were launched thirty units into the air on the first frame**, with the
  boxes and with the heightfield alike. The cause is authoring and it is worth
  knowing: a stack placed in *exact* contact — `level * CRATE`, where `CRATE` is
  the box's own size — is resolved on the first step by pushing the boxes apart.
  Six centimetres of gap per level removes it completely: seven crates moving on
  frame 4 and ten by frame 20, against none at either.
- The conversion also exposed a placement bug the box floor had hidden: a
  three-high stack at `s = 80` was inside the shelf at `s = 79`, whose top is 4.6.

Ruled out rather than assumed: the launch reproduces identically with the large
bucket disabled (`LARGE_CELLS` raised past any real box), so it is not 20.1's.)*

**What this section does not have** is a second author. Every observation here
comes from one level built in one session, and the things that cost time are the
things *that* level happened to need — a canyon, a corridor of crates, and a sun
low enough to matter. An interior, or a scene with no physics in it, would rank
these differently and would find its own four.

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
