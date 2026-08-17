# three.c3 — a Three.js-shaped scene API over C3 and Vulkan

## What it is

A retained-mode 3D scene library in C3, driven from JavaScript through QuickJS,
rendering through Vulkan. The JS surface deliberately mimics Three.js — `Scene`,
`Object3D`, `Mesh`, `position/rotation/scale`, `add/remove/traverse` — so that a
model that has memorized Three.js can write for it on the first try.

**The thesis, and the thing not to break: an instance is an immutable asset
reference plus a transform.** JS may place, transform, group, parent and instance.
JS may *not* touch vertices. That single refusal is what makes every scene the API
can express optimized by construction — one uploaded mesh per unique asset, N
transforms, one instanced draw, and a glTF export that is one `mesh` referenced by
N `nodes` rather than N copies of the same triangles. Three.js agents build scenes
out of `BoxGeometry` because that is what the API contains; three.c3 agents build
scenes out of real assets because that is what *this* API contains.

The second thesis: **the agent must be able to see what it made.** A render call, a
screenshot, and a `scene.stats()` that reports draw calls, unique meshes, instance
count and triangle budget. An agent that can look at its own output and read its
own cost corrects itself; one that cannot, does not.

## The shape of the thing

Three parts and no more: **a JS engine, a Vulkan renderer, and an MCP surface that
takes JavaScript and hands back results and a picture.** No UI toolkit, no widget
tree, no window manager, no input handling. The agent writes a script, three.c3
runs it, and what comes back is whatever the script logged, whatever it returned,
and a PNG of what it drew.

Two things follow from that:

**There is a window from the start, and it is a viewer, not the render target.**
Watching the scene live while developing is worth more than the swapchain costs,
so `c3w` is in from M0. But the drawing goes into an **offscreen** image and the
swapchain only blits it (§1) — which keeps the screenshot exact rather than an OS
window grab, keeps headless working for tests and CI at no extra cost, and keeps
the window from ever influencing how anything renders. No widget tree, no input
handling beyond close-and-resize, no UI toolkit.

**The MCP surface is three tools, not thirty.** `run_script`, `screenshot`,
`get_api_docs`. The JS API is the only API; MCP is the pipe it arrives through.
Resist the crig shape here — crig grew 28 typed tools *and* a `run_script`, which
means every capability has to be written twice and the two can disagree. One
language, one surface, one place a feature lands.

## Status

**M0 through M4 are built, the loop this project exists for is closed, and the
shader compiler is inside it.** A window, a Vulkan device, an offscreen
colour+depth target, a swapchain that blits it, an exact screenshot, a triangle
through a buffer device address, a `.glb` on screen with its base colour texture
— then a scene graph over all of it: `Object3D` with world-matrix propagation,
assets and textures deduplicated across files, frustum culling, one instanced
draw per unique mesh, `stats()`, and a raycast — then a QuickJS context, the
tier-1 scene API and three MCP tools over it — and now Slang at runtime, with the
descriptor set layout and the push block read out of the module rather than
declared beside it.

**M5 is built.** Picking reaches JavaScript — `scene.pick(x, y)` answers with the
object under a pixel of the rendered image — and so does tier 2: an agent writes
`float3 shade(Surface s)`, three.c3 writes the module around it, and a bad body
throws a JS error carrying Slang's own diagnostic with the line number the agent
wrote. `c3c test --trust=full` runs a hundred and twenty-seven checks, all
headless, leak-clean.

	three <file.glb>                    open a window on it
	three --mcp                         serve the agent tools on 127.0.0.1:8808
	three --mcp-stdio                   relay stdin/stdout to that server
	three <file.glb> --grid 1000        a thousand copies, one draw call
	three <file.glb> --screenshot a.png render one frame, exit
	three --validate                    validation layers + a device report

**`.mcp.json` is checked in**, and names the relay rather than a URL. A client
asks who a server is the moment it launches and may write it off for the rest of
its run if that fails, so a URL would mean three has to be up before the client
and stay up for as long as it. The relay is up either way: the handshake and the
tool list are answered from the build, and a call made while nothing is serving
comes back naming the port instead of vanishing.

**There is no shader build step.** `shaders/mesh.slang` is compiled at startup,
so editing it and re-running shows the change with nothing rebuilt — not the app,
not the shader. What that removes is in §6: a prepare target that silently does
nothing without `--trust=full`, and a documented `slangc` line that drifted from
the manifest's for a whole milestone.

**One dependency needs a step of its own.**
[`lib/slang.c3l`](https://github.com/tonis2/slang.c3) links a Slang SDK: 35 MB of
somebody else's build, machine-specific, so its `lib/` holds symlinks that are
not in git.

	./lib/slang.c3l/native/stage-slang.sh    # once per checkout

It uses an installed SDK when there is one and downloads the pinned release —
checksum-verified, pruned to 36 MB — when there is not, so a checkout with no
Slang anywhere still builds without anyone being told to go and install
something.

**Forgetting it does not reliably fail at the linker**, which is the part worth
knowing. On a machine with another Slang on the default search path —
`/usr/local/lib`, from an installer package — `-lslang` finds that one, links,
and the binary dies at startup in dyld naming a version nobody asked for.
Measured, not imagined; slang.c3l's README has the message.

M5 is built and M6 is still a plan. Everything below the milestone list
describes intent rather than behaviour except where it is marked otherwise;
`base_stage.md`, `m2_stage.md`, `m3_stage.md`, `m4_stage.md` and `m5_stage.md`
have the built parts broken out step by step, each with its own record of what
was verified and how.

**What M0/M1 settled that the rest of the plan assumed:**

- **`scalarBlockLayout` is available and is used.** Apple M5 reports it true
  under KosmicKrisp, so the `float4`-never-`float3` tax does not apply and
  vertex streams are uploaded tightly packed exactly as glTF stored them.
  `gpu/pipeline.c3` refuses a device that lacks it rather than reading geometry
  at the wrong stride. Recorded at the top of `gpu/device.c3` as §1 asks.
- **Drivers do disagree**, as warned: MoltenVK, while it was still being
  selected, reported `fillModeNonSolid` true and `maxPushConstantsSize` 4096
  where KosmicKrisp reports false and 256. Nothing optional is assumed anywhere.
- **MoltenVK is not supported and is actively refused.** The driver is the
  KosmicKrisp `vulkan.c3l` bundles; `VK_KHR_portability_enumeration` is left off
  the instance and `select_device` skips any portability device. See the header
  of `gpu/device.c3`.
- **The push block is 124 bytes** and the 128-byte budget holds.


  **Overtaken at M5, and the defect did not reproduce.** It is now required, and
  it is the only way a texture reaches a draw: there are no descriptor pools or
  sets anywhere in the project. Both halves of the old reasoning had expired —
  something uses it now, and the driver bug was re-measured rather than assumed
  stale, because "we avoided it because it was broken" is the worst possible
  thing to carry forward on trust.

  Two checks, deliberately not one. `consecutive_push_descriptor_draws_each_keep_their_own_state`
  draws four buckets that each push and draw, and requires four distinct colours
  — but every push there carries the *same* image, so a driver that ignored
  writes after the first would still pass it. `two_draws_with_different_textures_do_not_bleed`
  is the one that settles it: the 1x1 white stand-in and a real texture, back to
  back, with every pixel either draw painted required to be unchanged by the
  other's presence. Self-calibrating, so it asserts no colour constants.

  If this ever regresses on another KosmicKrisp build, the second test names it
  precisely, and the fallback is a descriptor pool — which is what the code
  looked like before M5 and is in the history.

**What M2 settled:**

- **The 128-byte push budget held, and holding it cost something.** The old
  block spent 64 of its bytes on a per-draw `mvp`, and 124 + an 8-byte instance
  pointer is 132. The view-projection and the light are not per-draw and moved
  into a `FrameBlock` reached through one pointer; the block is now 64 bytes.
  §1's rule — "when something new wants to ride in here, it goes in a buffer
  instead" — was applied rather than relaxed.
- **`scene/pick.c3` exists now rather than at M5**, because a raycast is how the
  M2 scene-math tests assert without a GPU. §7 already argued this; it turned
  out to be the cheaper way to test M2, not only the eventual feature.
- **A per-instance normal matrix is carried, not derived from the model
  matrix.** The upper-3x3 shortcut is only correct for rotation and uniform
  scale, and `scale.set(1, 2, 1)` is legal in this API. An `Instance` is
  therefore 128 bytes, not 64.
- **Geometry is *not* deduplicated across assets, only textures and materials
  are** — which is what §2 says, and is worth stating because "linked, not
  duplicated" invites the other reading. Two files whose triangles happen to
  match are two uploads.

**What M3 settled:**

- **The Three.js-shaped surface is written in JavaScript, not in the binding.**
  `js/prelude.js` is `$embed`ed and builds `Scene`/`Mesh`/`Group`/`Vector3` on
  top of eighteen flat host verbs. §4 assumed the classes would be assembled out
  of `Context.accessor` calls; in the language that already has classes they are
  a third of the code and match Three.js more exactly. See `m3_stage.md` S1.
- **`NodeId`'s generation paid for itself.** Every host verb that names a node
  revalidates the handle and throws, which is §1's requirement, and it needed no
  change to `Scene` at all — which is what M2 bought by paying for the
  generation early.
- **A script is an async function body**, so top-level `await` and `return` both
  work. `JS_EVAL_FLAG_ASYNC` would do it natively and quickjs.c3l's shim does not
  expose it, so the wrapper is textual — with no newline after the open brace, so
  a stack trace's line numbers are the script's own.
- **An object is not in the scene until it is `add`ed**, as in Three.js. The
  cheaper alternative renders a mesh that was never added, which is precisely the
  half-match §4 says is worse than a new name.
- **There is one scene at a time, and it says so.** `new three.Scene()` empties
  the host scene; the previous `Scene` throws rather than quietly operating on
  the new one's nodes.
- **`--test-noleak` cannot see a one-byte-per-call leak.** `DString.copy_str`
  allocates even when empty, so freeing on `len > 0` leaks whichever result
  fields a run left empty — unbounded in an agent loop, invisible in a suite that
  runs a script once. Only the tracked run caught it.

## Dependencies

Added as git submodules under `lib/`, matching crig's layout:

| Path | Repo | `provides` | For |
|---|---|---|---|
| `lib/vulkan.c3l` | `tonis2/Vulkan.c3` | `vk` | Vulkan bindings |
| `lib/window.c3l` | `tonis2/Window.c3` | `c3w` | Windowing — Cocoa, Wayland/X11, Win32, wasm |
| `lib/quickjs.c3l` | `tonis2/quickjs.c3` | `quickjs` | The JS engine |
| `lib/gltf.c3l` | `tonis2/gltf.c3` | `gltf` | Asset loading — full material/texture model |
| `lib/image.c3l` | `tonis2/image.c3` | `image` | PNG/JPEG decode for textures |
| `lib/collision.c3l` | `tonis2/collision.c3` | `collision` | BVH, AABB, raycast — scene picking and test assertions |
| `lib/mcp.c3l` | `tonis2/mcp.c3l` | `mcp` | JSON-RPC over HTTP/stdio — the agent's driving surface |
| `lib/slang.c3l` | `tonis2/slang.c3` | `slang` | Shader compilation and reflection at runtime — written for this project |

`git clone --recursive`, or `git submodule update --init --recursive` after the
fact. `lib/quickjs.c3l` has its own submodule (`vendor/quickjs-ng`), so the
`--recursive` is not optional.

`lib/slang.c3l` needs one more step — `native/stage-slang.sh`, which symlinks an
installed Slang SDK into place. It is the only dependency that does.

**Why it is not bundled, unlike `quickjs.c3l`'s archives.** Both were tried. The
quickjs archives are 1.3 MB each and freeze a build; libslang is 27 MB and
freezes an *SDK*, so every version bump would add another 14 MB of pack that no
later commit can remove — a repository that grows by a Slang release every time
Slang has one. 1.3 MB to skip a 4-second compile is a good trade; 14 MB and
rising to skip a one-line script is not.

**Deliberately absent:**

- **cui** — three.c3 is a rendering library, not a UI application. Taking cui
  would mean taking its frame loop, its `Ui` tree and its constraint that
  `RenderState.build` hardcodes `setVertexBindingDescriptionCount(0)`. The cost of
  refusing it is real and stated below (§1).
- **font** — no text rendering. If a debug HUD is ever wanted, revisit.

**`collision` and `mcp` are in for testing, and that is the whole reason.** Both
would be easy to mistake for application-layer dependencies that a rendering
library has no business carrying, so the justification is worth writing down:

- **`collision`** gives `TriBVH` and raycast. A test that asserts "the scene
  rendered correctly" by comparing pixels is brittle and slow; a test that asserts
  "a ray through this screen point hits instance 7" is exact, runs with no GPU and
  no window, and catches the class of bug that renders fine and puts things in the
  wrong place. It is also what `scene.raycast()` will be built on when picking
  arrives in M4, so it is not two dependencies wearing one coat. `aabb.c3` doubles
  as the frustum-cull primitive.
- **`mcp`** is the agent's driving surface, and §"What it is" already leans on it:
  the second thesis is that the agent must be able to see what it made. `render`,
  `screenshot`, `set_camera` and `stats` over JSON-RPC is that loop, and it is
  worth having *before* the JS API rather than after — an agent that can drive
  three.c3 while three.c3 has no JS bindings at all is how the bindings get
  designed against real usage instead of guesses. crig's `test/mcp` suite also
  shows the cheap win: drive the wire **in-process**, raw JSON-RPC in and parsed
  JSON out, no socket and no subprocess. That makes the tool surface testable at
  the same speed as a unit test.

Neither may be reached from `scene/` or `render/` for anything load-bearing. If
`collision` ends up in the render path it is because culling wanted its AABB, which
is fine; if `mcp` ends up anywhere but `mcp/` and `main.c3`, something has gone
wrong.

### `project.json` to start with

The built `project.json` carries only the five the base stage imports — `vk`,
`c3w`, `gltf`, `image`, `collision`. `quickjs` and `mcp` go in at M3 with the
code that uses them: listing a dependency links its static library into every
build, and an unused one is link time and confusing link errors for nothing.

```json
{
	"langrev": "1",
	"warnings": ["no-unused"],
	"dependency-search-paths": ["lib"],
	"dependencies": ["vk", "c3w", "quickjs", "gltf", "image", "collision", "mcp", "slang"],
	"version": "0.1.0",
	// Not optional once `slang` is in the list: its dylibs are built for 15.0,
	// c3c targets 11.0, and a manifest is not allowed to say so.
	"macos-min-version": "15.0",
	"script-dir": "./",
	"test-sources": ["test/**"],
	"output": "./build",
	"targets": {
		"three": {
			"type": "executable",
			"sources": ["src/**"]
		}
	}
}
```

No `shaders` prepare target. Shaders compile at runtime (§3) — that is the whole
point — so there is no `slangc` invocation at build time and no `$embed` of a
`.spv`. This alone removes crig's worst trap (`c3c build shaders` without
`--trust=full` silently doing nothing). **Built at M4**, and it removed a second
trap on the way: with no offline invocation there is nothing for the runtime one
to drift from. See §6, and `m4_stage.md` for the flag that drifted anyway.

## Source tree

One flat `module three`, folders for subject only, on crig's precedent. Files
marked **built** exist and do what the line says; the rest are still a plan.

```
src/
  main.c3           built  boot, CLI, the window loop  (+ the MCP server at M3)
  gpu/device.c3     built  instance, device selection, queues, allocator, limits
  gpu/target.c3     built  the offscreen colour+depth attachment and its readback (§1)
  gpu/frame.c3      built  command submission, per-frame sync, two frames in flight
  gpu/swapchain.c3  built  surface, swapchain, resize/recreate — blits gpu/target, nothing more
  gpu/buffer.c3     built  device-local uploads + BDA handles
  gpu/texture.c3    built  images, samplers, content-hash dedup
  gpu/pipeline.c3   built  the mesh pipeline, the push block, the derived layout, the hash cache
  shader/load.c3    built  .slang source from disk, never $embed
  shader/compile.c3 built  Slang at runtime: the session, the flags, the diagnostic
  shader/reflect.c3 built  Slang reflection -> descriptor set layout + push-block map
  shader/material_source.c3
                    built  wraps an agent's fragment body into a whole Slang module
  scene/camera.c3   built  a turntable camera and how it frames what it is shown
  scene/asset.c3    built  the asset table: meshes per file, textures shared across them
  scene/node.c3     built  Object3D: parent, children, local TRS, world matrix, dirty flag
  scene/scene.c3    built  the graph root, traversal, culling, the instance table, stats()
  scene/material.c3 built  a pipeline plus the push-block bytes that go with it
  scene/pick.c3     built  scene raycast over collision::TriBVH, in instance-local space
  render/pass.c3    built  cull, bucket, upload the instance array, one instanced draw each
  js/runtime.c3     built  the QuickJS context, the run contract, the interrupt/timeout
  js/prelude.js     built  the Three.js-shaped API itself, $embed-ed  (§4, and see below)
  js/bind_scene.c3  built  the flat host verbs prelude.js is written against
  js/bind_asset.c3  built  load(), asset paths, mesh names
  js/bind_shader.c3 built  the material/shader surface (tier 2, §4)
  mcp/server.c3     built  three tools and no more: run_script, screenshot, get_api_docs
shaders/
  mesh.slang        built  one shader: BDA streams, base colour texture, one directional light
                           compiled at startup from this file; there is no .spv
  material.slang    built  the ShaderMaterial template: the same module with the
                           shading lifted out into shade(Surface) and three markers
test/
  gpu_test.c3       built  device, target, headless render, readback, reproducibility
  asset_test.c3     built  mesh counts, texture dedup, index width, pixels on screen
  scene_test.c3     built  world matrices, bucketing, culling, picking, the instance buffer
  js_test.c3        built  the run contract, handles, staleness, the scene from JavaScript
  mcp_test.c3       built  the three tools over raw JSON-RPC, in-process
  shader_test.c3    built  compile, diagnostics, reflection, the pipeline cache
  material_test.c3  built  source assembly, the #line remap, the uniform budget
  fixtures/         built  textured.glb and the generator that writes it
```

**`js/prelude.js` is an addition to this list, and `js/bind_scene.c3` is not what
its line above originally said.** The plan assumed the `Scene`/`Object3D`/`Mesh`
prototypes would be assembled in the host out of `Context.accessor` calls. They
are instead written in JavaScript — `class Mesh extends Object3D`, a `children`
array that *is* an array — over a flat verb layer that takes numbers and answers
with numbers. It is a third of the code and matches Three.js more exactly,
because the Three.js-isms are written in the language that has them.
`m3_stage.md` S1 has the full argument, including why `$embed` here does not
contradict `shader/load.c3`'s "never `$embed`".

**`scene/material.c3` was the one planned file M2 did not produce**, and that was
deliberate rather than an omission to find later. It arrived at M5, as predicted. At M2 a material is a base
colour factor and a texture index, both carried on `GpuMesh`, and both resolve
to the one pipeline — a `Material` struct with exactly those two fields would be
a name for something that already has one. It arrives at M5 with
`ShaderMaterial`, which is the first thing that makes a material a choice
between pipelines. The consequence to know about: the instance table's bucket
key is `(asset, mesh)` rather than `(mesh, material)`, and those are the same
key only for as long as this stays true.

`scene/camera.c3` is an addition to the plan, from M1: something has to decide
where the eye is before a `.glb` can be looked at, and it is what
`PerspectiveCamera` will replace.

`--stress-resize` is what makes `base_stage.md`'s "aggressive resize produces no
validation errors" checkable without a human at the mouse. The window poking it
needs — `set_size` and `set_minimized` — went into `c3w` rather than living
here: it is a window capability, not a rendering one, and three.c3 is not the
only project that will want to drive a resize from a test.

## 1. Load-bearing decisions

**The render target is always an offscreen image. The swapchain, if it ever
arrives, is a consumer of that image and nothing else.** This is the decision the
rest of the graphics work hangs off, and taking it now is what keeps the project
small.

There *is* a window from M0 — watching the scene while working is worth the code —
but nothing draws into a swapchain image. `render()` draws into an offscreen colour
and depth attachment; `screenshot()` copies that attachment to a host-visible
buffer and encodes a PNG; the swapchain's entire job is `vkCmdBlitImage` from that
same attachment to the acquired image. The window is a viewer.

Why this way round rather than the obvious way round:

- **The screenshot stays exact.** It is the rendered image, not an OS window grab —
  frame-for-frame reproducible, identical on every machine, unaffected by DPI,
  occlusion or compositor. That is what makes image comparison a legitimate test
  instead of a flaky one, and it is what the agent is actually looking at.
- **Headless comes free.** No window server, no surface: the same code path renders
  over SSH, in CI, and inside a `c3c test` check with no window opened at all. If
  the swapchain were the render target, none of that would work without a second
  path — and a second path is a second set of bugs.
- **The window can never change how anything draws.** Resolution, format and sample
  count belong to the offscreen target, so they are not negotiated with a surface
  and do not change when someone drags the corner. If the swapchain ever needs to
  influence rendering, this decision has been broken.

The honest cost: creating the swapchain is small, but **resize and recreation is
where the bugs live** — an out-of-date swapchain, semaphores waited on after the
image they belonged to was destroyed, a blit sized against the old extent. Get
`VK_ERROR_OUT_OF_DATE_KHR` and `VK_SUBOPTIMAL_KHR` handled properly at M0 rather
than leaving it for later; cui's `Renderer.create_swapchain` / `rebuild_surface`
already solved this against `c3w` on this machine and is the reference worth
reading.

**Geometry reaches the shader through buffer device addresses, not vertex input
state.** In crig this was forced by cui. Here it is a choice, and still the right
one: a JS-declared geometry becomes a buffer plus a pointer, and creating a
pipeline from JS then needs no vertex-format description language at all. Three.js's
entire `BufferGeometry` attribute-binding layer evaporates. Keep it.

**Decide scalar block layout once, deliberately, and record the answer here.**
crig is stuck on std430 (`float4`, never `float3`) because cui never enables
`VK_EXT_scalar_block_layout`. three.c3 owns its own device, so it *can* enable it —
it is core in Vulkan 1.2 as `scalarBlockLayout`. Check whether the selected driver
on this machine reports it before committing; there are two Vulkan drivers
installed here and they do not agree about optional features. If it is enabled,
say so at the top of `gpu/device.c3` and pass `-force-glsl-scalar-layout` to
Slang; if it is not, the `float4`-never-`float3` tax applies and every struct the
GPU reads needs a comment saying why it is padded.

**JS holds validated handles; C3 owns every resource.** `quickjs.c3l` exposes no
`JS_NewClass`/finalizer binding, so a JS object cannot own a GPU allocation and be
trusted to release it. Do not add finalizers to work around this. Follow the
pattern crig already proved in `src/mcp/jsdata.c3`: a JS object is a plain object
over a prototype carrying `accessor` getters/setters, holding an opaque id, and
every access revalidates that id against the live scene. A stale handle throws
rather than dereferencing freed memory, and a runaway script leaks nothing because
it never owned anything. Scene teardown is explicit, per script run.

**Assume no optional Vulkan feature.** The bundled KosmicKrisp does not report
`fillModeNonSolid`, and the same is true of `wideLines`. Anything drawn as a
wireframe is a line-list index buffer, not `POLYGON_MODE_LINE`. Support is
KosmicKrisp-only — a portability implementation is refused rather than worked
around — but that narrows *which* driver answers, not whether it is asked.

## 2. The scene model

`Object3D` is the whole hierarchy: a parent, a child list, a local TRS, a cached
world matrix and a dirty flag propagated down on change. A `Mesh` is an
`Object3D` plus an asset reference and a material reference. **Nothing else holds
geometry.**

An `Asset` is one loaded glTF: its unique meshes uploaded once, its materials and
textures deduplicated by content hash across every asset already loaded. Two kit
pieces exported from the same source share their material and their images, and
neither the renderer nor the exporter sees them twice. Assets are refcounted by
the number of live `Mesh` nodes pointing at them.

Rendering is: traverse, cull, bucket by `(mesh, material)`, write one transform per
instance into a per-frame instance buffer, and issue one instanced draw per bucket.
The bucketing is what makes the "linked, not duplicated" claim true at runtime; the
node-per-instance glTF writer is what makes it true on disk.

`scene.stats()` returns that bucketing as numbers — draw calls, unique meshes,
instances, triangles, texture bytes. It exists so the agent can read its own cost.

**Picking is one BVH per unique mesh, never one per instance.** `collision::TriBVH`
is built once when an asset is uploaded and lives beside the geometry; a scene
raycast walks the instance table, transforms the ray into each instance's local
space by the inverse world matrix, and tests against the shared tree. A thousand
copies of a wall cost one BVH, which is the same "linked, not duplicated" rule the
renderer and the exporter follow. Broad-phase over instance AABBs (`aabb.c3`) comes
first and is shared with frustum culling.

## 3. Slang at runtime — the binding

This is the part that makes agent-authored shaders possible, and it is *much*
easier than expected, because Slang exports a **flat C API alongside its COM one**.
No vtable walking, no `ISlangBlob` refcounting on the happy path — plain
`extern fn` declarations.

Verified against the SDK installed at `/Users/tonis/binaries/slang`
(`libslang.dylib`, 258 exported `sp*` symbols):

**Compilation — twelve functions, all present:**

```
spCreateSession            spCreateCompileRequest      spSetCodeGenTarget
spFindProfile              spSetTargetProfile          spAddTranslationUnit
spAddTranslationUnitSourceString                       spAddEntryPoint
spCompile                  spGetEntryPointCode         spGetDiagnosticOutput
spDestroyCompileRequest    spDestroySession
spSetDebugInfoLevel        spSetOptimizationLevel
```

The call sequence is: create a session once for the process → per compile, create a
request, set target `SLANG_SPIRV`, set the profile from `spFindProfile`, add a
translation unit, add the source *as a string* (never a file — the source is coming
from JS), name the entry points, `spCompile`, then read back.

Two details that matter:

- **The right function is `spGetCompileRequestCode`, not `spGetEntryPointCode`** —
  corrected at M4, measured. Both return a raw `void const*` and a size with
  lifetime tied to the request, which is the reason to prefer either over the
  `*Blob` variants that drag COM refcounting in for no gain. But the per-entry-point
  one answers with a **null pointer and a length of zero** under
  `-emit-spirv-directly`, and reports no error: the emitted module holds every
  entry point together, so the whole program is the artifact. Copy the bytes out
  before destroying the request — the next request reuses the address.
- **`spGetDiagnosticOutput` returns a plain `char const*`.** This is the agent's
  error message, and routing it verbatim into the thrown JS exception is most of
  what makes the loop work. A compile error must read like a JS `SyntaxError`, not
  like a silent black screen.

**`spProcessCommandLineArguments(request, argv, argc)` is also exported**, and is
the shortcut worth taking: it accepts the exact flags the CLI takes, so
`-force-glsl-scalar-layout -fvk-use-entrypoint-name -emit-spirv-directly` can be
passed as an argv array instead of hand-mapping every option onto a setter.

**It is not sufficient on its own, and the last sentence of this paragraph used
to say it was.** `slangc` and the compile-request API have different *defaults*
underneath the same flags: the CLI is column-major and the API is row-major, so
passing the documented command line verbatim produced a different module with
every transform read transposed. Adding `-matrix-layout-column-major` makes the
runtime compile **byte-identical** to `slangc`'s. The general lesson is worse
than §6's version of it — two invocations passing the same flags is not enough.
See `m4_stage.md`.

**Reflection — 172 flat symbols, and this is the actual requirement.** Compiling
the shader is the easy half. What makes Three.js's `ShaderMaterial` feel effortless
is that it introspects the shader and wires uniforms up for you; without the
equivalent here, every agent-written shader would need a hand-authored
descriptor-binding declaration beside it and the "just write the shader" property
dies on contact. Verified present:

```
spGetReflection                    spReflection_GetParameterCount
spReflection_GetParameterByIndex   spReflectionParameter_GetBindingIndex
spReflectionParameter_GetBindingSpace
```

plus the full `spReflectionType*` / `spReflectionTypeLayout*` / `spReflectionVariable*`
families for walking parameter types and offsets. `shader/reflect.c3` turns that
walk into a `VkDescriptorSetLayout` and a name → (set, binding, offset, size) map
that the material layer writes uniforms through by name.

**Pipelines must be cached by content hash.** An agent iterating on a shader in a
loop will otherwise create hundreds of `VkPipeline` objects in a session. Key the
cache on `hash(source, entry points, target flags, render state)`; a cache hit must
skip the Slang call entirely, not just the pipeline creation, because compilation
is the expensive half.

**Linking, and the deployment caveat. Built at M4, and no shim was needed** —
nothing in the `sp*` family passes anything by value that is not a scalar or a
pointer, so `lib/slang.c3l` is one `.c3` file and a manifest with `linklib-dir`
and per-target `linked-libraries: ["slang"]`.

The SDK path is machine-specific, so nothing records it:
`native/stage-slang.sh` symlinks the libraries out of an installed SDK into
`lib/<target>/`, finding it through `$SLANG_SDK`, then `slangc` on `PATH`, then
the usual places. The symlinks are gitignored and the manifest carries two
*relative* rpaths.

Vendoring them into git instead was built and then reverted — see the note in
`m4_stage.md` §S2 for what that measured and why 14 MB per SDK bump, forever, was
the wrong price for skipping a one-line script.

**Two libraries, measured.** `libslang-llvm` (102 MB) is indeed only needed for
CPU and host codegen and is omitted — but `libslang-glslang` (8 MB) is *not*
optional, which this paragraph did not anticipate: Slang loads it as the
downstream `spirv-opt` and without it every compile fails with "failed to load
downstream compiler". So 35 MB, not 28 and not 137. Still editor-weight, not
something to link into a shipped game.

**The `sp*` family is formally deprecated** — `slang-deprecated.h` says it is kept
for compatibility and will be dropped over time. All 258 symbols are exported by
the SDK here. The exposure is one file.

## 4. The JS API

`js/runtime.c3` owns one QuickJS context. The binding pattern is `jsdata.c3`'s,
proven: a prototype object built once, `Context.accessor` for every property,
`Context.function` with an opaque back-pointer for every method, and an id that
revalidates on access. `Context.buffer` lays an `ArrayBuffer` directly over host
memory and `Context.typed_array` puts a `Float32Array` on it, so bulk data crosses
as a memcpy rather than as JSON. `Context.on_interrupt` is the script timeout, and
`step_job`/`jobs_waiting` drive promises if async is ever wanted.

**`run_script` is the whole contract, so its return value matters as much as the
API.** What comes back is: everything the script logged, the value it returned, the
stats block, and a PNG. All four, every time, whether or not the script succeeded —
a failed run that returns only an error string makes the agent guess about how far
it got. On failure the exception message must carry the JS stack, and if it came
from a shader compile, the Slang diagnostic verbatim (§3). This is the loop; the
rest of this file is in service of it.

Build the API in two tiers, and ship tier 1 alone first.

**Tier 1 — the scene. No shaders.**

```js
const kit  = await three.load("assets/kit_medieval.glb");
const wall = kit.mesh("wall_corner_02");

const scene = new three.Scene();
for (let i = 0; i < 12; i++) {
  const m = new three.Mesh(wall);
  m.position.set(i * 2, 0, 0);
  m.rotation.y = Math.PI / 2;
  scene.add(m);
}
three.render(scene, camera);
console.log(scene.stats());   // { drawCalls: 1, uniqueMeshes: 1, instances: 12, ... }
```

Everything an agent needs to build a level is here, none of it can produce
unoptimized output, and none of it needs a runtime shader compiler. This is where
the whole thesis lives.

**Naming rule: copy Three.js exactly where the semantics match, and clearly
diverge where they do not.** `Scene`, `Object3D`, `Mesh`, `position/rotation/scale`,
`add`, `remove`, `traverse`, `lookAt` mean what they mean in Three.js or they are
not called that. A half-match is worse than a new name, because the agent will not
read the docs for a name it recognizes. Where three.c3 has no equivalent —
`asset()`, `stats()`, the instancing being implicit — use names Three.js does not
have at all.

**Ship `getApiDocs()` from day one.** The agent's one real disadvantage against
Three.js is that it has not memorized this API. A machine-readable dump of the
surface, callable from JS and from whatever tool layer sits above, is the cheapest
possible mitigation — crig already proved the pattern with its `get_api_docs` tool.

**Tier 2 — materials. A fragment function, not a pipeline.**

```js
const mat = new three.ShaderMaterial({
  uniforms: { tint: [1, 0.5, 0.2], time: 0 },
  fragment: `float3 shade(Surface s) { return s.albedo * tint * (0.5 + 0.5 * sin(time)); }`
});
```

three.c3 supplies the vertex stage, the `Surface` struct, the descriptor layout and
the uniform block; the agent writes the shading body. This is what
`ShaderMaterial`/`onBeforeCompile` actually are in practice, and it removes almost
every Vulkan failure mode while keeping the property that makes Three.js pleasant
to generate for.

**Do not expose arbitrary pipeline creation, compute dispatch, or render-graph
authoring from JS.** Those are where "easy like Three.js" stops being true no
matter how good the binding is, and where a bad script stops being an exception and
starts being a device-lost that takes the process with it.

**Errors are the third tier of work and the easiest to under-budget.** A bad shader
in Three.js is a console message; a bad descriptor binding in Vulkan is a hang if
you are unlucky. Run the validation layers whenever a script is executing, install
a debug messenger that routes validation errors into the thrown JS exception, and
keep the interrupt handler armed. The agent's loop is only as good as the error it
gets back.

## 5. Milestones

**M0 — a window, and something in it. Done.** `project.json`, `src/main.c3`,
`c3w` window, Vulkan instance and device, the offscreen colour+depth target, a
swapchain that blits it, and a clear colour. Plus `--screenshot <path>`, which
is a readback of the *offscreen* image and therefore already exact.

Resize was got right here rather than later, and `--stress-resize` is how it
stays right: six aspect ratios and a minimise/restore, rendering throughout,
clean under validation on both installed drivers. `SUBOPTIMAL_KHR` needed the
raw `VkResult` — it is a *success* code, so the binding does not turn it into a
fault and there is nothing to catch. A surface-extent poll at the top of the
frame turned out to be the primary resize path rather than a backstop: a live
macOS drag routinely resizes the surface without either the acquire or the
present ever reporting `OUT_OF_DATE`.

**M1 — a triangle, then a glTF. Done.** BDA geometry upload, one hand-written
Slang shader compiled offline into `shaders/mesh.spv` and read from disk, one
draw. Then `gltf.c3l` in, meshes on screen with their base colour texture.

Two things cost time and neither is visible in a diff:

- **The negative-height viewport does not reverse triangle winding.** It exists
  to *undo* Vulkan's Y-down NDC so a glm-convention projection works unchanged,
  and undoing a flip is not a flip. Setting `FRONT_FACE_CLOCKWISE` on that
  reasoning culled every visible face and produced an empty frame with no
  validation message at all.
- **A texture format the decoder does not handle must not fail the load.** KTX2
  (`KHR_texture_basisu`) is common in shipped assets and `image.c3l` does not
  decode it; a 141-mesh terrain rendering untextured with one warning is worth
  far more than the same file rendering nothing. Finding that also surfaced a
  real leak — a primitive that failed partway had already put buffers on the
  device and nothing else knew about them yet.

**M2 — the scene graph and instancing. Done.** `Object3D`, world-matrix
propagation, asset dedup, bucketing, the instance buffer, one instanced draw per
bucket, `stats()`, and a `collision::TriBVH` per unique mesh built as assets are
uploaded. 1000 instances of one asset is one draw call, and `--grid 1000` is
that claim on screen rather than only in a test.

Three things cost time and none are visible in a diff:

- **The push block ran out of room**, and the fix was to notice that two of the
  things in it were never per-draw. See the findings above.
- **A `String` from a closed glTF document is freed memory.** `GpuMesh.name`
  had held `gltf::Mesh.name` since M1, which `GltfStream.close` frees — invisible
  for as long as nothing read a name, and M2 is where naming a mesh starts to
  matter.
- **`project.json`'s shader target was missing `-force-glsl-scalar-layout`**, so
  `c3c build shaders` and the documented `slangc` line produced different
  modules. Nothing had noticed, because the offsets that differ are the ones M1
  never used.

`m2_stage.md` is the step-by-step record, including which tests catch which
bug and the runs that proved it.

**M3 — the agent loop closes. Done.** QuickJS context, the tier-1 scene API
(`load`/`Mesh`/`Group`/`add`/transform accessors/`render`/`stats`/`getApiDocs`),
and the three MCP tools over it: `run_script`, `screenshot`, `get_api_docs`.
§4's example arrives over JSON-RPC as a string, runs, and comes back as a PNG
plus the stats block — asserted in `three_tests::mcp` and driven by hand over a
real socket.

They shipped together, which is the consequence of the three-tool decision:
`run_script` *is* the JS binding surface, so there was no useful MCP milestone
before the bindings existed. The wire is tested **in-process** — raw JSON-RPC in,
parsed JSON out, no socket and no subprocess — which keeps the whole tool surface
at unit-test speed.

Four things cost time and none are visible in a diff:

- **`lib/quickjs.c3l` has a submodule of its own** and it was uninitialised, so
  the build failed inside the C compiler with no mention of submodules anywhere.
  This file already warned that `--recursive` is not optional; `project.json` now
  says it at the line that adds the dependency.
- **The Three.js-shaped classes belong in JavaScript**, not in the binding. See
  the source-tree note above and `m3_stage.md` S1.
- **`await` at the top level needed a decision.** quickjs.c3l's shim does not
  expose `JS_EVAL_FLAG_ASYNC`, so every script is textually wrapped in an async
  IIFE — with no newline after the open brace, or every stack trace would be off
  by one line and nobody would notice until they tried to fix a script by the
  number in the error.
- **A one-byte leak per call is invisible without leak tracking.**
  `DString.copy_str` allocates even when empty, so freeing on `len > 0` leaks
  whichever result fields a run left empty. `--test-noleak` passes it happily.

`m3_stage.md` is the step-by-step record, including which injected bug each new
regression test was proved against.

**M4 — Slang at runtime. Done.** `lib/slang.c3l` with no shim, the compile
functions, the reflection walk, the pipeline hash cache, and diagnostics carried
back as strings on the success path as well as the failure one. The shader M1
compiled offline now compiles from a string at startup — **byte-identically**, md5
for md5, to what the documented `slangc` line produced — and the descriptor set
layout and the push block are read out of the module rather than declared beside
it. The prepare target and `shaders/mesh.spv` are gone.

Four things cost time and none are visible in a diff:

- **`slangc` and the compile-request API have different defaults under the same
  flags.** Column-major versus row-major matrices, so the documented command line
  passed verbatim gave a different module. The truck rendered a completely
  convincing picture with every transform transposed; only the built-in triangle
  collapsed, to fourteen pixels. See §3.
- **`spGetEntryPointCode` is the wrong function** and says so by returning a null
  pointer, a length of zero, and no error at all.
- **`libslang-glslang` is not optional**, though `libslang-llvm` is. Slang loads
  the first as `spirv-opt` on the SPIR-V path.
- **Reflection reports the bytes the shader uses, not the bytes the struct
  occupies** — 60 against 64 — and mixing them is a push-constant range that
  validation rejects and that renders a *pixel-identical* picture anyway. No test
  catches it; `--validate` does.

`m4_stage.md` is the step-by-step record, including which injected bug each new
regression test was proved against, and the one that no test catches.

**M4a — the binding is its own library.** `lib/slang.c3l` is now a submodule of
[`tonis2/slang.c3`](https://github.com/tonis2/slang.c3), with eleven tests of its
own that need no GPU — the diagnostic's line number, a failed compile arriving as
`ok: false` rather than a fault, and every reflected descriptor. It still stages
its libraries from an installed SDK; bundling them was tried and reverted, and
`m4_stage.md` §S2 records both what that cost and the load-time failure it turned
up on the way.

**M5 — tier 2 materials, and picking. Done.**
`ShaderMaterial` with a fragment function over M4's reflection, validation errors
routed into the thrown JS exception, and the raycast exposed to JS. The raycast
itself landed at M2 — `scene/pick.c3` is built and tested — because it is how the
scene-math checks assert without a GPU. Done when an agent-written fragment
shader renders and a bad one throws a JS error carrying the Slang diagnostic.

The binding shipped first, as three verbs: `scene.pick(x, y)` for a pixel of the
rendered image, `scene.raycast(origin, direction)` for a world ray, and
`three.renderSize()` because the first of those takes pixels and nothing else in
the API said how big the image is. Both answer with the `Mesh` the script is
holding — not a handle, not a rebuilt copy — or with `null`.

Two things cost time and neither is visible in a diff:

- **It is not a `Raycaster`, deliberately.** Three.js's answers with a sorted
  array of every intersection and takes the objects to consider; this answers
  with the closest drawable node in the whole scene. An array that never held
  more than one element would be a fact about the implementation wearing
  Three.js's name — §4's half-match, which is worse than a new name.
- **The picker was biased half a pixel** and had been since M2. `screen_ray`
  mapped a pixel to its left edge while the rasterizer decides coverage at the
  pixel's centre, so picks and pixels disagreed at edges — one column in a
  hundred and sixty, which is why nothing had noticed. Found by comparing a row
  of picks against the decoded screenshot from the same `run_script` call, and
  now pinned by a round trip with no rasterizer in it.

Materials landed as `plan.md` §4's tier-2 example, verbatim: `new
three.ShaderMaterial({ uniforms, fragment })` where `fragment` is one
`float3 shade(Surface s)`. Four more things cost time:

- **A material's uniforms live in the push block**, not a uniform buffer. 68
  bytes were free after the mesh contract, and Slang reports a `ConstantBuffer`
  as one opaque binding whose members `lib/slang.c3l` has no externs to walk. The
  push path was already reflected by name and offset and tested byte-for-byte.
  `check_push_block` had to stop capping the block at `MeshPush::size`, which
  left four spare bytes and made this impossible.
- **The bucket key is `(asset, mesh, material)` — all three.** §"Source tree"
  wrote `(mesh, material)`, and dropping `asset` collapses two byte-identical
  assets into one bucket that draws one's geometry with the other's instances.
  `two_assets_sharing_an_image_upload_it_once` is the test that says so.
- **`three.render()` from a script had been drawing nothing since M3.**
  `MeshPass.ready` gates the whole draw and was set only by the three CLI
  loaders; the JS path calls `Assets.load` directly. No JS test had ever asserted
  on pixels, and `mcp_test` checks a PNG comes back — a blank one does. Found by
  fixing a test of this milestone's that claimed to compare frames and actually
  compared draw counts.
- **Descriptor sets are gone entirely**, replaced by `VK_KHR_push_descriptor`.
  That deletes the coupling where `Assets.load` took a `MeshPipeline*` only to
  allocate sets against its layout. It also meant re-measuring the M0/M1 finding
  that this call was broken on KosmicKrisp — it does not reproduce, and two
  tests now hold that down.

`m5_stage.md` is the step-by-step record, including which injected bug each new
regression test was proved against, and the injection that was too weak on the
first attempt.

**M6 — the export.** A glTF writer that emits one `mesh` per unique asset and one
`node` per instance, with materials and textures deduplicated by content hash
across every source file. Done when a scene built by a script round-trips through
`.glb` and loads back with the same draw-call count.

M0–M2 were ordinary graphics work. **M3 is where the project started being the
thing it is for**, and it is done: an agent can drive this over JSON-RPC today.
M4 was the interesting one and took days rather than weeks, as estimated — the
flat C API really is as easy as §3 hoped, and all of the cost was in defaults
that differ silently rather than in anything hard. M5 is now the short one: the
compiler, the reflection and the diagnostics it needs are all in place, and what
is left is the JS surface over them. M6 is where the "linked, not duplicated"
thesis stops being an internal detail and becomes something another engine can
load.

## 6. Traps carried over

Each of these cost real time in crig and none are visible in a diff.

- **A `\n` inside a C3 raw string is a backslash and an `n`.** Backticks do not
  process escapes. Shader source and JSON written with backticks look right in the
  editor and are wrong at runtime.
- **`Object.is_array()` is false for an empty JSON array** — `std::collections::object`
  only tags a container as a list once something is pushed. `is_indexable` is the
  predicate that means what it says.
- **`SomeEnum::values`** (`::`, not `.`) is how c3c spells enum reflection.
- **`Element.widget_as`-style casts are unchecked** in cui, and the same hazard
  applies to any `void*`-keyed handle table here. Compare identity, not type.
- **Two Vulkan drivers on this machine. Query every optional feature — but
  querying is not the same as falling back.** This bullet used to end "query it
  and fall back", and that was already wrong when it was written:
  `VK_KHR_dynamic_rendering` is pushed unconditionally and a device without it is
  refused by name, because there is no `VkRenderPass` anywhere in this project to
  fall back *to*. M5 made the same call for `VK_KHR_push_descriptor`.

  The real rule is: decide whether an extension is baseline for the devices this
  targets — KosmicKrisp and mid-range Vulkan parts, not the whole installed base
  — and then either require it and say so in one sentence at startup, or write
  the fallback and test both paths. What is forbidden is the third thing:
  *assuming* it and finding out at draw time. A fallback nobody exercises is
  worse than a requirement, because it is only reached on the machine you do not
  have.

  Note the API version this requests is 1.3, so push descriptors are an
  extension here rather than the core feature they became in 1.4.
- **Two frames in flight means any buffer the GPU may still be reading must be
  double-buffered.** crig's pose palette tore for exactly this reason. The
  per-frame instance buffer has the same shape — it is one buffer per frame slot
  in `render/pass.c3`, written and grown only after that slot's fence has been
  waited on, and `the_instance_buffer_grows_and_stays_stable` is the check.
- **A `String` handed out by a parsed document dies with the document.**
  `gltf::Mesh.name` is freed by `GltfStream.close`, so anything keeping a name
  past the load has to own a copy. This cost time at M2 and was invisible for
  the whole of M1, because nothing read a name until something wanted to look a
  mesh up by one.
- **A build step and its documented equivalent can drift silently.**
  `project.json`'s `slangc` line was missing `-force-glsl-scalar-layout` while
  the header of `mesh.slang` said to pass it — two different SPIR-V modules, no
  error either way. If a command appears in both a manifest and a comment, one
  of them is going to be wrong eventually. M4 deleted the build step, which is
  the only real fix.
- **And passing the same flags is not enough, because the defaults underneath
  them differ.** `slangc` defaults to column-major matrices; the compile-request
  API that takes the identical argv does not. Two modules, no error either way,
  and a rendered picture convincing enough that four tests had to say so. The
  only trustworthy check is comparing the artifacts.
- **A pixel is a square, and its coordinate is a corner.** The rasterizer decides
  whether a triangle covers a pixel by testing the pixel's *centre*, so anything
  that claims to agree with the picture — a picker, a hit test, a readback
  comparison — has to add the half. Leaving it out is a bias rather than noise:
  it is always in the same direction, invisible except at an edge, and an edge is
  where the question is being asked. Found at M5, present since M2.
- **Slang diagnostics are only useful if they are surfaced.** A compile that fails
  and falls back to a previous pipeline is a shader edit that appears to work and
  changes nothing on screen — the runtime version of crig's `$embed` trap.

## 7. Verification

```
c3c build --trust=full
c3c test --trust=full --test-noleak     # while working
c3c test --trust=full                   # with leak tracking; much slower
c3c test --trust=full --test-filter <suite>
```

**Never read a timing off a run with leak tracking on.** The runner installs a
`TrackingAllocator` for the length of each check, and on this machine that measures
roughly 100× the real cost of anything that allocates per element. `--test-noleak`
is a flag of the *test binary*, not of the compiler.

What the suites should cover, on crig's lesson that the silent failures are the
expensive ones:

- **Scene math** — world-matrix propagation and the dirty flag, on a hierarchy
  small enough to predict by hand. A stale world matrix renders fine and puts
  things in the wrong place.
- **Bucketing** — that N instances of one asset produce one draw call, asserted on
  the bucket list rather than on a flag. This is the thesis; if it silently
  regresses the project has no point.
- **Asset dedup** — that two `.glb` files sharing a texture upload it once.
- **Slang** — that a known-good shader compiles to non-empty SPIR-V, that a
  known-bad one produces a diagnostic containing the line number, and that the
  pipeline cache returns the identical handle for identical source *and skips the
  compile to do it*. Built at M4.
- **Reflection** — a shader with known bindings, asserted against the derived
  descriptor layout. Getting this wrong produces a black screen, not an error.
  Built at M4, against a fixture with six bindings across two sets rather than
  against `mesh.slang`, which has one descriptor and would pass any walk that
  only ever looked at binding range zero.
- **Picking** — a ray through a known screen point hits the expected instance, on
  a scene with two overlapping copies of one asset at different transforms. This is
  the suite that catches a projection and a raycast that disagree, which is the
  half of a 3D app that fails *silently*: everything still renders, it just puts
  things somewhere other than where they were asked for. No GPU, no window.
  Built at M2. The case worth keeping from writing it: an instance with a
  non-uniform scale, where the local-space hit parameter is not a world distance
  and comparing two instances' hits without converting picks the wrong one.
  M5 added the exact version of "the ray goes where the picture goes": cast
  through a pixel, project the hit back through the same view-projection, and
  require it to land in the middle of that pixel. No rasterizer, no tolerance
  beyond floating point, and it fails on every pixel rather than on the one where
  an edge happens to fall in the wrong half.
- **The MCP wire** — driven **in-process**, raw JSON-RPC in and parsed JSON out,
  no socket and no subprocess. Assert the tool surface end to end at unit-test
  speed, including that a malformed request is an error response rather than a
  crash.
- **The JS binding** — that a stale handle throws instead of dereferencing, that a
  script exceeding its interrupt budget is killed, and that neither leaks.

**Assert on the thing, not on the flag.** A mode field says nothing about whether
anything rendered; compare pixels. And re-introduce every bug a regression test
claims to catch — an unexercised regression test is an assumption.
