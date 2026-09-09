# Stats

- `drawCalls` — vkCmdDrawIndexed calls for one frame of this scene.
- `uniqueMeshes` — Distinct (asset, mesh) pairs drawn.
- `instances` — Total placed meshes. A thousand of these can be one drawCall.
- `nodes` — Live nodes, groups and the root included.
- `scenes` — How many Scenes exist. `new three.Scene()` shows a new world without freeing the one
  before it, so this is the number a level transition has to bring back down. Each extra scene holds
  a node pool, a physics world, a nav bake and asset references — invisible in every other number
  here, since a scene nobody looks at costs the frame nothing and memory everything. `three.scenes`
  is the list behind the count; `three.disposeInactive()` frees all but the rendered one. A warning
  arrives once the count starts doubling past four.
- `colliders` — Of those, the meshes in the spatial index — what every sweep and raycast tests a box
  against. Drawable meshes are collision geometry by default, so this grows as a level is decorated
  whether anyone meant it to or not; `object.collides = false` takes one out, and
  `asset.instantiate(name, { physics: true })` lets the file's own colliders decide instead. Read it
  beside `nodes`: a large gap plus slowing sweeps is a field of grass acting as a fence. A collider
  that is not a drawing — the proxy a `KHR_implicit_shapes` box or capsule gets — is counted here and
  in `nodes`, and in none of `drawCalls`, `instances` or `triangles`.
- `assets` — Loaded files and generated shapes resident on the device. Watch it across
  `scene.unload()`.
- `triangles` — Summed over instances, so 1000 copies of a 500-triangle mesh is 500000.
- `vertices` — Likewise.
- `textures` — Unique images on the device, deduplicated by content across every loaded file.
- `textureBytes` — What those cost.
- `textureCompressedBytes` — How much of that is block-compressed, so `textureBytes` minus this is
  the uncompressed share. A KTX2 map arrives as BC7 blocks and stays that way; a PNG or a JPEG is
  decoded and held as RGBA8, which is four times the bytes and four times the sampling bandwidth for
  the same picture. Both numbers count the whole mip chain. An uncompressed share worth megabytes is
  a fact about the exporter rather than about the engine — the fix is to write the maps as KTX2, not
  to change anything here. The Evil Forest file reads 99.3 MB with 99.3 MB compressed: every map in
  it is BC7 already.
- `textureSlots` — How many slots of the device-wide texture array hold a live image, and
  `textureSlotCapacity` how many it has. Every image on the device sits in one descriptor array that
  every shader shares, so a material carries indices into it rather than descriptor sets of its own —
  which is what removed the per-material sampler ceiling. `textureSlots` tracks `textures`; the
  capacity is what the card offers, capped at 16384. Both read 0 on a device without descriptor
  indexing, where the array is not built and the old per-draw path runs instead.
- `geometryBytes` — Every vertex stream and index buffer on the device, plus the positions and
  triangle indices kept resident on the CPU for the pick tree. Both halves, because a few hundred
  thousand vertices is tens of megabytes on each side. Falls to zero across a full unload.
- `targetBytes` — The offscreen frame: one colour and one depth image at the render size. About
  17 MB at 1080p, held before a single mesh loads, and the floor under everything else here.
- `postBytes` — The post chain: the always-resident HDR scene image A, as much of the ping-pong pair as the chain needed, and one
  image per tapped pass, at eight bytes a pixel against the target's four — so a two-pass chain at
  1080p is around 50 MB. It starts around 16.6 MB at 1080p for A and is a high-water mark after that:
  `three.setPost(null)` retires the shaders and keeps the images for the next chain at the same
  extent. A nonzero reading with nothing running is that, not a leak. `three.toneMapping = 'agx'`
  with no pass of your own is Image A alone — about 16.6 MB at 1080p — because the tonemap reads the
  scene rather than a ping-pong slot.
- `shadowBytes` — Actual Vulkan allocation bytes for the shared live shadow atlas and its lazy
  static-cache twin, including allocator alignment. All light types share these images. They are
  retained across off/on toggles and recreated together when the chosen atlas extent changes.
- `clusterBytes` — Allocated light/cluster storage across frame slots. The compute grid and its
  fixed-stride index lists are included, even when few lights are present.
- `clusterOverflow` — Local-light references that exceeded cluster capacity in the most recently
  completed frame slot. Overflow clusters use the all-light loop, preserving illumination at extra cost.
- `shadowViews` — Resident atlas tiles, including six per admitted point light. `three.lights.shadow.maxLocal` and each light's own `shadow` decide which local lights are counted here.
- `shadowRejected` — Lights denied shadow residency by the view, texel or atlas limits.
- `lightmapReceivers` — Copies holding a lightmap tile after the last `three.lights.bake()`.
- `lightmapSkipped` — Static receivers the bake refused a tile: no `TEXCOORD_0`, uvs outside
  `[0, 1]`, uvs that overlap themselves, or a `ShaderMaterial` holding every texture slot it
  may declare, which leaves no sampler binding for the atlas. These keep the real-time loop for every light,
  baked ones included, so the gap between the two numbers is what a bake actually covers.
- `lightmapBytes` — The lightmap atlas, `RGBA16F` at eight bytes a texel, or 0 with no bake.
  Those three are the last bake's numbers.
- `lightmapDirty` — Tiles a moved light or a moved receiver has made stale and the catch-up has
  not re-baked yet. They are still displayed while they wait, so this is a number about how far
  behind the cache is rather than about anything missing from the picture. It falls to zero over
  the frames after a change, a few tiles a frame inside `three.lights.bake.budgetMs`.
- `shadowUpdates` — Views refreshed this frame. An unaffected complete cached view costs no update;
  a cache copy that clears an old dynamic overlay counts once.
- `shadowUpdateTexels` — Total rasterized shadow texels this frame. Rebuilding static depth and
  drawing dynamic depth into the same view counts its texels twice.
- `shadowDeferred` — Views awaiting an update budget. New or invalid deferred views contribute light
  without shadows; combined views retain their last complete live depth. Valid untouched static views
  need no update budget.
- `occlusionBytes` — The current ambient-occlusion depth image's actual Vulkan allocation. It is
  zero until `three.light.occlusion` first runs, then remains allocated across off/on toggles and
  follows the render target's extent.
- `materials` — Materials built and not yet collected; the two built-in ones are not counted. A
  material holds a compiled pipeline until `material.dispose()`, so a script that builds one per run
  and drops the handle grows this forever — the host says so past 64. It falls when the material is
  collected, which is after both the dispose and the last mesh naming it, so disposing while
  something still draws with it leaves the number where it was.
- `culledLastFrame` — Instances the camera frustum dropped in the last `render()`. Meaningful with
  shadows on: the shadow pass has its own draw list against the light's box.
- `shadowCulled` — Instances neither pass drew — outside the camera frustum and outside the light's
  box. 0 with shadows off, and smaller than `culledLastFrame`, since a caster the camera cannot see
  is still drawn into the map.
- `shadowDraws` — Draw calls the last shadow pass made, 0 with shadows off. Roughly `drawCalls` minus
  the transparent buckets and helpers, so it is what shadows cost in draws. With static casters it
  counts the movers alone.
- `prepassDraws` — Draw calls the depth prepass made, and 0 with `three.depthPrepass` off or in a
  scene it cannot help. It is at most `drawCalls` minus the transparent buckets and helpers; the gap
  is the materials the prepass has to leave out — a `vertex:` body, a `fragment:` body that
  discards, a stochastically sampled cut-out. A scene where this stays 0 while `fragmentsShaded` is
  high is one paying for its overdraw and not getting the saving.
- `shadowStaticDraws` — Draw calls into the cached half of the shadow map, and 0 on every frame that
  did not rebuild it — which should be nearly all of them. Equal to the caster count every frame
  means something is invalidating the cache: an unsettled camera, or a static node still being moved.
- `shadowCutout` — Whether the cut-out shadow pipeline exists — false until the first frame something in
  the scene has a `material.alphaTest` on it, and true from then on. It is a pipeline that exists rather
  than one that was used this frame, and it is the whole of what alpha-tested shadows cost a scene beyond
  a bind per bucket: a project that never sets `alphaTest` compiles no second shadow shader.
- `skinnedDraws` — Draw calls whose geometry is posed by a skeleton.
- `skinnedInstances` — Characters in those draws. A hundred here with `skinnedDraws` at 1 is the
  crowd working as intended.
- `preskinnedInstances` — Of those, the ones routed through the compute pass —
  `instantiate({ skinning: 'compute' })`. The expensive kind: each holds a posed copy of its mesh per
  frame in flight and is a draw call of its own.
- `poseBytes` — Device memory holding baked animation poses, uploaded once per rigged file and shared
  by every copy. There is no per-frame palette upload behind a baked character, which is why a
  hundred of them is affordable.
- `sweep` — What the frame's capsule sweeps cost, as `{ calls, sweeps, gathered, steps }`, zeroed at
  the top of every host tick. The only block here about *work already done* rather than about the
  scene as it stands, and it exists because a slow `three.moveAndSlide` is one of three things and no
  other number can tell them apart: too many triangles per sweep, too many advancement steps per
  sweep, or too many sweeps per call. Read the ratios, not the totals.
  - `calls` — `three.moveAndSlide` calls, plus one per agent of a `three.moveAndSlideAll`.
  - `sweeps` — capsule sweeps under them, plus `three.query.sweep` and the nav bake. About four per
    call for a character walking: the depenetration, the grounded probe, one slide, the floor probe.
    Ten means it is sliding on ground it should be walking along, or climbing every frame.
  - `gathered` — triangles handed to the narrow phase, summed over sweeps. Divided by `sweeps` it is
    what one sweep tests; a few dozen is a level, a few thousand is a field of grass in the index and
    `colliders` above is where to look next.
  - `steps` — conservative advancement steps, summed over sweeps. Divided by `sweeps` it is under two
    for anything a character does; near the cap of 24 is a sweep grazing a surface it never quite
    reaches.
- `gpuMs` — Milliseconds the GPU spent on the frame you just asked for, on the GPU's own clock.
  `three.render()` and a screenshot each leave their own measurement, so render first and read after.
  0 before anything is drawn and 0 for a run with no device — use `renderSize()` to tell those apart.
  The span is the whole submission, blit or readback included.
- `prepareMs` — Of `gpuMs`: uploads, the frame's buffer writes and compute skinning. Everything
  before the first pass.
- `shadowMs` — Of `gpuMs`: the shadow map, 0 with shadows off. Worth looking at first outdoors — the
  map is fitted around the whole scene, so a wide level pays for texels nowhere near the camera and
  `three.light.shadow.size` is the knob.
- `sceneMs` — Of `gpuMs`: the pass that draws the picture.
- `postMs` — Of `gpuMs`: the post chain, 0 with no post shader.
- `presentMs` — Of `gpuMs`: getting the finished image out — the blit to the window, or the readback
  behind a screenshot. The five add up to `gpuMs`, so anything unaccounted for is a bug.
- `fragmentsShaded` — Fragment shader invocations of the pass that drew the picture, from a pipeline
  statistics query — the shadow pass, the depth prepass and the post chain are all outside it, so it
  is the scene pass alone. Overdraw is `fragmentsShaded` divided by `width * height` of
  `renderSize()`: 1 is a frame where every pixel was shaded once, and 3 is a frame paying for its
  lighting three times over. With `three.depthPrepass` on it should sit near 1 — the prepass's own
  cut-out fragments are not in here, and `prepassDraws` is what says the prepass ran. Same "which
  frame" rules as `gpuMs`, and 0 on a device without `pipelineStatisticsQuery`.
- `skippedFrames` — Frames the renderer found identical to the one already on screen and presented
  again instead of drawing — see `three.alwaysRender`. A running total over the process, so the number
  worth reading is how fast it moves: a paused game should add one per frame and a moving one none.
  Always 0 with `three.alwaysRender` on, and 0 for a headless batch or a screenshot, which always draw.
- `renderedFrames` — Frames that were drawn, the other half of `skippedFrames`. The two together are
  every frame the window path recorded.
