# Base stage — the renderer foundation (M0 + M1)

Companion to `plan.md`. That file is the whole project; this one is only the first
two milestones, at the level of "which file, in what order, done when".

Everything here is `module three` in one flat namespace, folders for subject only.

## Built

**All nine steps are done and the five "Done" conditions hold.** See the
verification record at the bottom of this file for what was checked and how.
The step descriptions below are kept as written — they are the reasoning that
produced the code, and where the code diverged from them the divergence is
recorded in place.

## Scope

**In:** a window, a Vulkan device, an offscreen render target, a swapchain that
blits it, a screenshot, a triangle, then a `.glb` on screen with its base colour
texture.

**Explicitly out, and do not let them creep in:**

- No QuickJS, no MCP — M3. The base stage is driven by a CLI argument and nothing
  else.
- No runtime shader compilation — M4. Shaders are `.spv` files read from disk (§4).
- No scene graph, no instancing, no `Object3D` — M2. One mesh, one transform.
- No UI, no input handling beyond close and resize.
- No material model. One shader, base colour texture, a hardcoded directional
  light. Anything more is M1 scope creep dressed as polish.

## The frame path

The shape everything else hangs off. Get this right and the rest is filling in.

```
                   ┌──────────────────────────────────────────┐
                   │  gpu/target.c3   offscreen                │
   draw ──────────▶│  colour  R8G8B8A8_UNORM  ─┐               │
                   │  depth   D32_SFLOAT       │               │
                   └───────────────────────────┼───────────────┘
                                               │
                        ┌──────────────────────┴────────────────┐
                        ▼                                       ▼
            ┌───────────────────────┐              ┌────────────────────────┐
            │ gpu/swapchain.c3      │              │ gpu/target.c3 readback │
            │ vkCmdBlitImage        │              │ copy → host buffer     │
            │ → present             │              │ → png::save_file       │
            └───────────────────────┘              └────────────────────────┘
                   the window                            the screenshot
```

**Nothing ever draws into a swapchain image.** The swapchain is one blit and one
present. This is the decision `plan.md` §1 makes and the base stage is where it is
either honoured or quietly lost.

Three things fall out of it that are worth knowing before writing the code:

- **The offscreen extent is independent of the window.** A resize rebuilds the
  swapchain and changes the blit's destination rect. It does *not* touch the render
  target, the depth buffer, the pipeline, or the projection matrix unless three.c3
  decides it should. Most of what makes resize painful goes away.
- **Pick `R8G8B8A8_UNORM` for the target and the BGRA swizzle disappears.** cui's
  `write_screenshot` swaps channels by hand because it reads back a
  `B8G8R8A8_UNORM` *swapchain* image. Reading back a target three.c3 chose the
  format of means the readback is a straight memcpy into `image::Image`.
- **Headless is the same code path minus two calls.** No surface, no swapchain,
  and `render()` + `screenshot()` still work. That is what makes M0 testable in
  `c3c test` with no window server.

## Steps

### S1 — `project.json`, `src/main.c3`, a window

`c3w::new(params: {.x, .y, .width, .height}, name: title)`. Poll events, handle
close, exit cleanly.

**Done when:** a window opens, closes on the close button, and the process exits 0
with no leaks under `c3c test`.

### S2 — instance and device — `gpu/device.c3`

Follow cui's `Renderer.new` closely here; it has already paid for the platform
quirks on this machine. In order:

1. **`init_loader()` before anything asks Vulkan a question.** Every Vulkan command
   in `vulkan.c3l` is a runtime-loaded pointer and this loads the first of them.
   Calling anything before it is a null-pointer crash that looks like a driver bug.
2. Instance extensions: `VK_KHR_surface` plus the platform surface extension —
   `VK_EXT_metal_surface` on macOS, `VK_KHR_win32_surface`, or
   `VK_KHR_wayland_surface`/`VK_KHR_xcb_surface` chosen from `window.getBackend()`.
3. **`VK_KHR_portability_enumeration` is deliberately not enabled.** It is the
   spec's switch for accepting portability implementations, and three.c3 renders
   through the conformant KosmicKrisp `vulkan.c3l` bundles. Leaving it off keeps
   MoltenVK's device out of the enumeration entirely.
4. `apiVersion` 1.3. Debug messenger behind a `--validate` flag.
5. Surface: `window.create_vk_surface(instance, vk::getInstanceProcAddr)` — hand it
   the loader's proc-addr rather than letting it `dlopen` its own, or it can bind a
   different Vulkan than the instance came from.
6. `vk::selectPhysicalDevice(instance, surface, device_extensions)`.
7. Features: build the `PhysicalDeviceFeatures2` → `Vulkan11` → `Vulkan12` →
   `Vulkan13` pNext chain, **query it, then hand the same chain to
   `deviceCreateInfo().setNext()`** so exactly what the device supports is what
   gets enabled.
8. `vk::loadDeviceCommands(device)` after creation — dispatch straight into the
   driver instead of through the loader.
9. `vk::MemoryAllocator { device, pdevice, queue, flags: MEMORY_ALLOCATE_DEVICE_ADDRESS_BIT }.init()`.

**Device extensions:** `VK_KHR_swapchain`, `VK_KHR_dynamic_rendering`,
`VK_KHR_push_descriptor`. Dynamic rendering is the important one — **no
`VkRenderPass`, no `VkFramebuffer`, anywhere in this project.** Attachments are
described at record time.

**Assert `bufferDeviceAddress` is on** in the queried `Vulkan12Features` and fail
loudly if it is not. Everything in §"Geometry" depends on it, and discovering that
at S6 instead of S2 wastes a day.

**Check `scalarBlockLayout` here and write the answer into a comment at the top of
this file** (`plan.md` §1). Two Vulkan drivers are installed on this machine and
they do not agree about optional features. If it is available, enable it and pass
`-force-glsl-scalar-layout` to the shader build; if not, every GPU-facing struct is
`float4`-never-`float3` and needs a comment saying why it is padded.

**Done when:** device and queue are created with validation layers on and no
messages.

### S3 — the offscreen target — `gpu/target.c3`

A colour image (`R8G8B8A8_UNORM`, `COLOR_ATTACHMENT | TRANSFER_SRC`), a depth image
(`vk::findDepthFormat(...)`, `DEPTH_STENCIL_ATTACHMENT`), their views, and an
extent that comes from a parameter — not from the window.

`TRANSFER_SRC` on the colour image is what makes both the blit and the readback
possible, and unlike cui's swapchain case it is unconditional: three.c3 created
this image, so there is no `supportedUsageFlags` to mask against and no
`screenshot_supported` flag to carry.

**Done when:** the target is created and destroyed cleanly at two different
extents, verified under validation.

### S4 — command submission — `gpu/frame.c3`

Command pool, command buffers, a fence per frame slot, `MAX_FRAMES_IN_FLIGHT = 2`.

**Two frames in flight means anything the GPU may still be reading must be
double-buffered.** crig's pose palette tore for exactly this reason. Nothing in the
base stage is per-frame-mutable yet, but the rule belongs in this file's header
comment now, before the first uniform buffer arrives and gets it wrong.

**Done when:** an empty command buffer submits and the fence signals, in a loop,
with no validation errors.

### S5 — clear, blit, present — `gpu/swapchain.c3`

Now the first picture. Begin dynamic rendering on the target, clear to a colour,
end, then transition and `vkCmdBlitImage` to the acquired swapchain image and
present.

**The semaphore rule, taken from cui and not to be re-derived:** acquire semaphores
and fences are **per frame slot**; render-finished semaphores are **per swapchain
image**. A render-finished semaphore shared across slots can be re-signalled while
a presentation of the same image is still waiting on it. This is a genuine hazard
that validation catches only sometimes.

**Handle `VK_ERROR_OUT_OF_DATE_KHR` and `VK_SUBOPTIMAL_KHR` properly here, not
later.** Both `vkAcquireNextImageKHR` and `vkQueuePresentKHR` can return them.
Rebuild = wait idle, destroy the old swapchain and its views, re-query
`currentTransform` and capabilities rather than reusing remembered ones, recreate.
The image count must be settled once and not move across rebuilds, because the
per-image semaphores and command buffers are sized by it.

Resize is the only genuinely fiddly part of the window path, and half-doing it
means every later milestone is debugged through an intermittent failure that has
nothing to do with it.

**Done when:** the window clears to a colour, survives aggressive resizing and a
minimise/restore with no validation errors, and `vkDeviceWaitIdle` on shutdown
leaves nothing outstanding.

### S6 — the screenshot — `gpu/target.c3`

`--screenshot <path>`: render one frame, barrier the colour image
`COLOR_ATTACHMENT_OPTIMAL` → `TRANSFER_SRC_OPTIMAL`, `vkCmdCopyImageToBuffer` into
a `HOST_VISIBLE | HOST_COHERENT` buffer from `vk::new_buffer`, wait the fence, map,
and hand the bytes to `png::save_file` as an `image::Image` with
`format = PixelFormat.RGBA`.

`bufferRowLength`/`bufferImageHeight` of 0 means tightly packed to `imageExtent`.
Force alpha opaque on the way out — a half-transparent PNG of a finished frame is
never what was wanted.

**This is the M0 deliverable that matters most**, because it is what the agent will
eventually be looking at and what every later image test compares against.

**Done when:** `--screenshot out.png` writes a correct image, exits 0, and produces
a **byte-identical** file across runs and across window sizes.

### S7 — shaders on disk — `shader/load.c3`

`shaders/mesh.slang` compiled by `slangc` into `shaders/mesh.spv`, and **read from
disk at startup — never `$embed`ed.**

This is a deliberate departure from crig, which embeds and pays for it: `c3c build
shaders` without `--trust=full` skips the exec, reports success, leaves the `.spv`
untouched, and `$embed` picks up the previous binary — a shader edit that compiles
cleanly and changes nothing on screen. Reading the file removes the trap entirely
and makes iteration a re-run rather than a rebuild.

It also makes M4 a one-function swap: `load_spirv(path)` becomes
`compile_slang(source)` and nothing above it changes.

A `prepare` target invoking `slangc` is fine as a convenience, but **it must not be
the only way the `.spv` gets there**, and it must not be the first target in
`project.json` — `c3c build` with no target builds the first one listed.

**Done when:** the triangle renders from a `.spv` that was never embedded, and
touching the `.slang` + rerunning `slangc` changes the picture with no rebuild.

### S8 — geometry through BDA — `gpu/buffer.c3`

No vertex input state. Upload positions/normals/UVs into device-local buffers, take
their device addresses, and pass the addresses in the push constant block; the
shader dereferences them.

**Keep the push block small and say why.** crig's grew to 192 bytes and needed a
`check_push_limit` that refuses devices offering less, because 128 is the only size
every implementation must offer. Start at 128, treat it as a budget, and put
anything that does not fit into a buffer rather than widening it.

**Done when:** a hardcoded triangle renders through a buffer address, with the
`.spv` from S7.

### S9 — a `.glb` on screen — `scene/asset.c3`

`gltf.c3l` in. Read the first mesh's primitives, upload them, read the base colour
texture through `image.c3l`, upload it, sample it. One hardcoded directional light
and an ambient term.

Two things to get right now rather than at M2:

- **Do not flatten the file into one soup.** crig's `gltf/source.c3` deliberately
  welds an entire scene into a single triangle soup because a rigger wants one
  mesh. three.c3 wants the opposite — one uploaded mesh per glTF mesh, keyed so M2
  can reference them. Flattening here is a decision that has to be unpicked later.
- **Deduplicate textures by content hash from the first upload.** Retrofitting this
  after two assets already share an image is more work than doing it now, and it is
  the same rule the exporter will need at M6.

**Done when:** a kit `.glb` renders with its base colour texture, and loading a
file containing several meshes uploads several meshes rather than one.

## Decisions this stage locks in

Each of these is cheap now and expensive later.

| Decision | Why now |
|---|---|
| Offscreen target, swapchain blits | Retrofitting means rewriting every draw path |
| `R8G8B8A8_UNORM` target | No BGRA swizzle in readback, ever |
| Dynamic rendering, no `VkRenderPass` | Render pass objects infect every pipeline |
| BDA, no vertex input state | The whole `BufferGeometry` layer never gets written |
| `.spv` from disk, never `$embed` | Kills the silent-stale-shader trap; M4 becomes a swap |
| Push block budget 128 bytes | The only size every device must offer |
| One mesh per glTF mesh, not a soup | M2 needs the split; flattening is unpickable |
| Texture dedup by content hash | Same rule the M6 exporter needs |

## Reference — what to read in cui for each piece

cui's `src/vulkan/renderer.c3` already solved the platform work against `c3w` on
this machine. Read it; do not depend on it.

| Step | cui reference |
|---|---|
| S2 instance, driver selection, surface | `Renderer.new`, lines ~197–335 |
| S2 feature chain, device, allocator | `Renderer.new`, lines ~336–430 |
| S5 swapchain create / rebuild | `Renderer.create_swapchain`, `Renderer.rebuild_surface` |
| S5 semaphore and fence layout | `Renderer.new`, lines ~440–450 |
| S6 readback barriers and copy | `Renderer.record_screenshot_copy` |
| S6 PNG write | `Renderer.write_screenshot` |

The one place to *diverge* deliberately is S6: cui reads back a swapchain image, so
it carries a `screenshot_supported` flag and a hand-written BGRA swizzle. three.c3
reads back a target it chose the format of and needs neither.

## Traps for this stage specifically

- **`init_loader()` first.** Anything before it crashes on a null command pointer
  and reads like a broken driver.
- **`VK_KHR_portability_enumeration` stays off**, which is what refuses MoltenVK.
  Its absence has a second effect worth knowing: headless, unvalidated, bundled
  driver, the instance extension list is then genuinely empty, and the builder
  takes `&names[0]` — guard the call or it panics on the empty slice.
- **KosmicKrisp does not report `fillModeNonSolid`**; the same is true of
  `wideLines`. Query every optional feature and fall back. A wireframe, if it
  ever arrives, is a line-list index buffer.
- **HiDPI:** the swapchain is sized in *physical pixels* (`window.get_scale()`),
  while window coordinates are logical. Since the offscreen target has its own
  extent, this affects only the blit destination — but getting it wrong gives a
  quarter-sized image in the corner, which looks like a projection bug.
- **A `\n` inside a C3 raw string is a backslash and an `n`.** Backticks do not
  process escapes. Relevant the moment shader source or JSON is written inline.
- **`c3c build` with no target builds the first target listed** in `project.json`.
  Keep any `prepare` target last.

## Done

The base stage is complete when all of these hold at once:

1. `crig`-style CLI: `three <file.glb>` opens a window showing the model.
2. `three <file.glb> --screenshot out.png` writes a byte-identical PNG across runs
   and exits 0.
3. Aggressive resize, minimise and restore produce no validation errors.
4. Editing `shaders/mesh.slang` and rerunning `slangc` changes the picture with no
   rebuild of the app.
5. A `c3c test --test-noleak` suite covers: device bring-up and teardown with no
   leaks, target creation at two extents, a headless render + readback with no
   window opened at all, and glTF load producing the expected mesh and texture
   counts.

Item 5 is the one that will be tempting to skip, and it is the one that makes M2
onward cheap: **a headless render into a buffer, asserted on pixels, is the only
test that tells you the renderer still works** — and it costs nothing extra,
because the offscreen path was built first on purpose.

## Verification record

What was actually checked, and how, so a later regression has a baseline to be
measured against rather than a claim to be taken on trust.

| Done item | How it was checked | Result |
|---|---|---|
| 1. `three <file.glb>` opens a window on the model | Windowed runs under `--validate`, plus a screen capture of the window | Window opens and blits the target; the model itself was confirmed through the identical offscreen render the window blits. The final window-with-model capture could not be taken — the screen locked — so the *picture in the window* is verified for the clear colour and by the resize stress with a model loaded, not by a photograph of the model in the window |
| 2. `--screenshot` is byte-identical across runs, exits 0 | Two runs of the triangle, two of `textured.glb`, `shasum` compared; also rendered at 512x384, 640x480, 800x600, 1280x720 | Identical, exit 0 |
| 3. Aggressive resize, minimise and restore produce no validation errors | `--stress-resize --validate`: 900x500, 1600x1000, 320x240, 1440x200, 240x900, 1024x768, then minimise and restore, 20–30 frames each | Clean on the bundled KosmicKrisp *and* on an installed one (`--system-driver`), with and without a model loaded |
| 4. Editing the `.slang` and rerunning slangc changes the picture with no rebuild | Recompiled a tinted variant over `shaders/mesh.spv`, re-ran the same binary, compared the PNG and the binary's mtime | Picture changed, binary untouched |
| 5. `c3c test --test-noleak` covers device bring-up, target at two extents, headless render + readback, glTF counts | 11 checks in `test/gpu_test.c3` and `test/asset_test.c3` | All pass, and all pass again *with* leak tracking |

Two of the regression tests were verified by re-introducing the bug they claim
to catch, on the principle that an unexercised regression test is an
assumption: reading ushort indices as uint fails
`ushort_indices_are_not_read_as_uint`, and dropping the content-hash comparison
fails `identical_textures_upload_once`. The front-face test
(`the_builtin_triangle_reaches_the_screen`) was written *because* the bug
happened — see the note below.

### What the steps got wrong, and what the code does instead

- **S5's front face.** The negative-height viewport does not reverse winding.
  It undoes Vulkan's Y-down NDC so a glm-convention projection works unchanged,
  and undoing a flip is not a flip — so glTF's counter-clockwise front faces
  stay counter-clockwise. Reasoning the other way culled every visible face,
  which validation is entirely happy about and which reads as a broken pipeline
  rather than a raster setting.
- **S2's `VK_KHR_push_descriptor`.** Not requested. Nothing uses it, and
  requiring an unused extension can only turn devices away. The base colour
  texture uses an ordinary descriptor set, which is also what vulkan.c3l's own
  example does after finding that KosmicKrisp's `vkCmdPushDescriptorSetKHR`
  breaks subsequent draws.
- **S2's scalar block layout answer: yes.** `scalarBlockLayout` is true on
  KosmicKrisp, so vertex streams are uploaded tightly packed exactly as glTF
  stored them and there is no repack anywhere. `gpu/pipeline.c3` refuses a
  device that lacks it rather than reading geometry at the wrong stride.
- **MoltenVK is refused, not accommodated.** An earlier revision enabled
  `VK_KHR_portability_subset` after selection, because a device advertising it
  must have it enabled. That has been removed along with the instance's
  portability enumeration: three.c3 supports the KosmicKrisp `vulkan.c3l` bundles
  and nothing else. `select_device` skips portability devices as a second lock,
  and `PORTABILITY_DRIVER_ONLY` distinguishes "wrong driver" from "no GPU". On a
  machine where MoltenVK is the *only* ICD, the loader gets there first and
  fails instance creation with `ERROR_INCOMPATIBLE_DRIVER`; `main.c3` prints the
  same advice for both.
- **S9 says "one hardcoded directional light"; an unsupported texture must not
  be fatal.** KTX2 (`KHR_texture_basisu`) is not decoded by `image.c3l`, and a
  141-mesh terrain rendering untextured with one warning beats the same file
  rendering nothing.
- **One addition to the planned tree**: `scene/camera.c3`, because something has
  to decide where the eye is before a `.glb` can be looked at.
- **`--stress-resize` drives the window through `c3w`**, which grew
  `Window.set_size` and `Window.set_minimized` for it. Those belong to the
  window library rather than here — item 3 above is otherwise only checkable by
  hand, and that is true of any project using c3w, not just this one.
