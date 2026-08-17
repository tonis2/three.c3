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

Nothing is built. The seven submodules are in place and nothing else — no
`project.json`, no `src/`, no first triangle. Everything below is a plan, not a
description. When something lands, move it from **Milestones** into a section that
describes how it actually works, and keep this file honest about the difference.

**M0 and M1 are broken out step by step in `base_stage.md`** — which file, in what
order, done when. This file stays the whole shape; that one is the next two
milestones.

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

`git clone --recursive`, or `git submodule update --init --recursive` after the
fact. `lib/quickjs.c3l` has its own submodule (`vendor/quickjs-ng`), so the
`--recursive` is not optional.

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

```json
{
	"langrev": "1",
	"warnings": ["no-unused"],
	"dependency-search-paths": ["lib"],
	"dependencies": ["vk", "c3w", "quickjs", "gltf", "image", "collision", "mcp"],
	"version": "0.1.0",
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
`--trust=full` silently doing nothing).

## Planned source tree

One flat `module three`, folders for subject only, on crig's precedent:

```
src/
  main.c3           boot, CLI, the window loop, the MCP server
  gpu/device.c3     instance, physical device selection, logical device, queues
  gpu/target.c3     the offscreen colour+depth attachment and its readback (§1)
  gpu/frame.c3      command buffer submission, per-frame sync, two frames in flight
  gpu/swapchain.c3  surface, swapchain, resize/recreate — blits gpu/target, nothing more
  gpu/buffer.c3     allocation + BDA handles; upload staging
  gpu/texture.c3    images, samplers, the growable descriptor array
  gpu/pipeline.c3   pipeline creation from reflected layout + the hash cache (§3)
  shader/slang.c3   the flat-C Slang binding: compile source -> SPIR-V (§3)
  shader/reflect.c3 SPIR-V/Slang reflection -> descriptor set layout + uniform map
  scene/node.c3     Object3D: parent, children, local TRS, world matrix, dirty flag
  scene/scene.c3    the graph root, traversal, the instance table, stats()
  scene/asset.c3    a loaded glTF: unique meshes, materials, textures; refcounted
  scene/material.c3 material params + which pipeline they resolve to
  scene/pick.c3     scene raycast over collision::TriBVH, in instance-local space
  render/pass.c3    cull, batch by (mesh, material), write instance buffer, draw
  js/runtime.c3     the QuickJS context, module loading, the interrupt/timeout
  js/bind_scene.c3  Scene/Object3D/Mesh prototypes and accessors
  js/bind_asset.c3  load(), asset handles, instancing
  js/bind_shader.c3 the material/shader surface (tier 2, §4)
  mcp/server.c3     three tools and no more: run_script, screenshot, get_api_docs
test/
```

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

**Assume no optional Vulkan feature.** Two drivers are installed on this machine
(MoltenVK and Mesa KosmicKrisp) and only one reports `fillModeNonSolid`; the same
is true of `wideLines`. Anything drawn as a wireframe is a line-list index buffer,
not `POLYGON_MODE_LINE`.

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

- **`spGetEntryPointCode` returns a raw `void const*` and a size**, with lifetime
  tied to the request. That is the whole reason to prefer it over
  `spGetEntryPointCodeBlob` — the blob variant hands back an `ISlangBlob**` and
  drags COM refcounting into the binding for no gain. Copy the bytes out before
  destroying the request.
- **`spGetDiagnosticOutput` returns a plain `char const*`.** This is the agent's
  error message, and routing it verbatim into the thrown JS exception is most of
  what makes the loop work. A compile error must read like a JS `SyntaxError`, not
  like a silent black screen.

**`spProcessCommandLineArguments(request, argv, argc)` is also exported**, and is
the shortcut worth taking: it accepts the exact flags the CLI takes, so
`-force-glsl-scalar-layout -fvk-use-entrypoint-name -emit-spirv-directly` can be
passed as an argv array instead of hand-mapping every option onto a setter. The
runtime compile and any offline `slangc` invocation then cannot drift.

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

**Linking, and the deployment caveat.** The binding is a `.c3l` of its own
(`lib/slang.c3l`) following `quickjs.c3l`'s manifest shape — `linklib-dir`,
per-target `linked-libraries: ["slang"]`, and a `c-include-dirs` if any shim is
needed. The SDK path here is machine-specific
(`/Users/tonis/binaries/slang/{include,lib}`), so it needs either vendoring under
the `.c3l` or an env-var-driven search path; hardcoding an absolute path into the
manifest will break on the next machine. Size is the real cost: `libslang.dylib`
is 28 MB and `libslang-llvm.dylib` is 107 MB. **`libslang-llvm` is only needed for
CPU/host codegen targets and can be omitted** for a SPIR-V-only build; verify that
before assuming the 107 MB is unavoidable. Even so, this is an editor-weight
dependency, not something to link into a shipped game.

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

**M0 — a window, and something in it.** `project.json`, `src/main.c3`, `c3w`
window, Vulkan instance and device, the offscreen colour+depth target, a swapchain
that blits it, and a clear colour. Plus `--screenshot <path>`, which is a readback
of the *offscreen* image and therefore already exact. Done when resize works with
no validation errors and the screenshot is byte-identical across runs.

Get `VK_ERROR_OUT_OF_DATE_KHR` and `VK_SUBOPTIMAL_KHR` right here. Resize is the
only genuinely fiddly part of the window path and leaving it half-done means every
later milestone is debugged through an intermittent failure that has nothing to do
with it.

**M1 — a triangle, then a glTF.** BDA geometry upload, one hand-written Slang
shader compiled *offline* for now, one draw. Then `gltf.c3l` in, one mesh on
screen with its base colour texture. Done when a kit `.glb` renders with materials.

**M2 — the scene graph and instancing.** `Object3D`, world-matrix propagation,
asset dedup, bucketing, the instance buffer, one instanced draw per bucket,
`stats()`. Build a `collision::TriBVH` per unique mesh as assets are uploaded —
not for picking yet, but because it is what the M2 tests assert against without
needing a GPU. Done when 1000 instances of one asset is one draw call.

**M3 — the agent loop closes.** QuickJS context, the tier-1 scene prototypes
(`load`/`Mesh`/`add`/transform accessors/`render`/`stats`), and the three MCP
tools over them: `run_script`, `screenshot`, `get_api_docs`. Done when the example
in §4 arrives over JSON-RPC as a string, runs, and comes back as a PNG plus the
stats block.

These ship together and cannot be split, which is the consequence of the
three-tool decision: `run_script` *is* the JS binding surface, so there is no
useful MCP milestone before the bindings exist. Test the wire **in-process** — raw
JSON-RPC in, parsed JSON out, no socket and no subprocess — so the whole surface
runs at unit-test speed.

This is the milestone the project is for. Everything before it is scaffolding and
everything after it is improvement.

**M4 — Slang at runtime.** `lib/slang.c3l`, the twelve compile functions, the
reflection walk, the pipeline hash cache, diagnostics as strings. Done when the
same shader that M1 compiled offline compiles from a string at startup and the
descriptor layout is derived rather than declared.

**M5 — tier 2 materials, and picking.** `ShaderMaterial` with a fragment function
over M4's reflection, validation errors routed into the thrown JS exception, and
`scene/pick.c3` — `scene.raycast()` over the per-unique-mesh BVHs M2 already
built, the ray transformed into instance-local space. Done when an agent-written
fragment shader renders and a bad one throws a JS error carrying the Slang
diagnostic.

**M6 — the export.** A glTF writer that emits one `mesh` per unique asset and one
`node` per instance, with materials and textures deduplicated by content hash
across every source file. Done when a scene built by a script round-trips through
`.glb` and loads back with the same draw-call count.

M0–M2 are ordinary graphics work. **M3 is where the project starts being the thing
it is for** — everything before it is scaffolding. M4 is the interesting one and
now looks like days rather than weeks. M6 is where the "linked, not duplicated"
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
- **Two Vulkan drivers on this machine.** Never assume an optional feature; query
  it and fall back.
- **Two frames in flight means any buffer the GPU may still be reading must be
  double-buffered.** crig's pose palette tore for exactly this reason. The
  per-frame instance buffer has the same shape and will have the same bug.
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
  pipeline cache returns the identical handle for identical source.
- **Reflection** — a shader with known bindings, asserted against the derived
  descriptor layout. Getting this wrong produces a black screen, not an error.
- **Picking** — a ray through a known screen point hits the expected instance, on
  a scene with two overlapping copies of one asset at different transforms. This is
  the suite that catches a projection and a raycast that disagree, which is the
  half of a 3D app that fails *silently*: everything still renders, it just puts
  things somewhere other than where they were asked for. No GPU, no window.
- **The MCP wire** — driven **in-process**, raw JSON-RPC in and parsed JSON out,
  no socket and no subprocess. Assert the tool surface end to end at unit-test
  speed, including that a malformed request is an error response rather than a
  crash.
- **The JS binding** — that a stale handle throws instead of dereferencing, that a
  script exceeding its interrupt budget is killed, and that neither leaks.

**Assert on the thing, not on the flag.** A mode field says nothing about whether
anything rendered; compare pixels. And re-introduce every bug a regression test
claims to catch — an unexercised regression test is an assumption.
