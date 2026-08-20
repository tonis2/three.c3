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
physics world with contacts, friction, joints, triggers and events.

	c3c test --trust=full       424 passed, 0 failed, leak-clean

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

- **`PipelineCache` never evicts.** An agent iterating on a shader in a loop
  accumulates one `VkPipeline` per distinct source for the life of the process.
  The cache is keyed on source and cull mode and hands out borrowed pointers, so
  eviction needs a deferred-delete queue that survives the frames in flight —
  which is the same queue §2 wants. Do them together.

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

---

## 2. Deferred by design, and what would undefer it

Each of these was a decision, not an oversight. The trigger is written down so
the decision can be revisited on evidence rather than on somebody's mood.

- **The frame-tagged deletion queue.** What exists is the simple half: one
  `vkDeviceWaitIdle` per sweep, which is right for a level boundary because a
  level boundary is already a stall. A game that streams chunks mid-play wants
  buffers tagged with the frame counter and destroyed two frames on.
  **Trigger:** something unloads during gameplay. Nothing else has to move for
  it, and `PipelineCache` eviction lands on top of it for free.

- **A material cannot have its own texture.** Tier 2 has 68 push bytes and the
  one descriptor binding the mesh pass owns. Push descriptors made this nearly
  free — there is no pool to size and no set to allocate — so the work is a
  `MaterialTexture` on the JS side and a second binding in the template, not a
  new subsystem. **This is the natural first extension of tier 2** and is
  probably the cheapest real feature on this page.

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
the parts.** `lib/ktx.c3l` is already in, ahead of the milestone that uses it,
with `test/ktx_test.c3` holding it to compiling and linking so it does not rot.

**Do the glTF half first and out of order.** `image.c3l` decodes PNG and JPEG and
nothing else, so **every shipped `.glb` using `KHR_texture_basisu` currently
loads with its textures missing** — recorded at M1, worked around by rendering a
141-mesh terrain untextured with one warning, and still true
(`src/scene/asset.c3:1861`). Decoding KTX2 into the existing texture path is
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

**`three.texture(path)`** — PNG and JPEG through `image.c3l`, uploaded down the
same path a glTF texture takes. Small, and there is no verb for it today.

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
- **No render graph, no deferred path, no post-processing stack.**
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
  implementation detail as though it were content.
- **No per-instance texture, and no per-instance alpha blending.** `color.a`
  reaches `shade()` and the opaque pipeline does not blend with it. Transparency
  is a sort order and a pipeline state, not a channel.
- **No line width, and no fourth debug-line shape.** `wideLines` is false on the
  bundled driver, so every line here is one pixel and there is nothing to set.
- **No helper that follows its object.** `BoxHelper.update()` is called by hand,
  as Three.js's is. Making it automatic means either a per-frame walk that costs
  every scene with no helpers in it, or a dirty flag on every object for the
  benefit of a debug tool — and the failure it would prevent is visible in the
  picture the helper is being looked at in.
