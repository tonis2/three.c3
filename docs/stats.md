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
  whether anyone meant it to or not; `object.collides = false` takes one out. Read it beside `nodes`:
  a large gap plus slowing sweeps is a field of grass acting as a fence.
- `assets` — Loaded files and generated shapes resident on the device. Watch it across
  `scene.unload()`.
- `triangles` — Summed over instances, so 1000 copies of a 500-triangle mesh is 500000.
- `vertices` — Likewise.
- `textures` — Unique images on the device, deduplicated by content across every loaded file.
- `textureBytes` — What those cost.
- `geometryBytes` — Every vertex stream and index buffer on the device, plus the positions and
  triangle indices kept resident on the CPU for the pick tree. Both halves, because a few hundred
  thousand vertices is tens of megabytes on each side. Falls to zero across a full unload.
- `targetBytes` — The offscreen frame: one colour and one depth image at the render size. About
  17 MB at 1080p, held before a single mesh loads, and the floor under everything else here.
- `postBytes` — The post chain: Image A, as much of the ping-pong pair as the chain needed, and one
  image per tapped pass, at eight bytes a pixel against the target's four — so a two-pass chain at
  1080p is around 40 MB. 0 until a post shader is first set, and a high-water mark after that:
  `three.setPost(null)` retires the shaders and keeps the images for the next chain at the same
  extent. A nonzero reading with nothing running is that, not a leak.
- `shadowBytes` — Two D32 images at `size` squared once anything in the scene is static, one before
  that. 2048 is 34 MB, 4096 is 134 MB, 8192 — the ceiling — is 536 MB: the largest thing one
  assignment can do to a process, which is why the setter says so above the default. 0 until shadows
  are first turned on; after that it follows `shadow.size` up and down, but
  `three.light.shadow.enabled = false` keeps the last map rather than freeing it.
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
- `shadowStaticDraws` — Draw calls into the cached half of the shadow map, and 0 on every frame that
  did not rebuild it — which should be nearly all of them. Equal to the caster count every frame
  means something is invalidating the cache: an unsettled camera, or a static node still being moved.
- `skinnedDraws` — Draw calls whose geometry is posed by a skeleton.
- `skinnedInstances` — Characters in those draws. A hundred here with `skinnedDraws` at 1 is the
  crowd working as intended.
- `preskinnedInstances` — Of those, the ones routed through the compute pass —
  `instantiate({ skinning: 'compute' })`. The expensive kind: each holds a posed copy of its mesh per
  frame in flight and is a draw call of its own.
- `poseBytes` — Device memory holding baked animation poses, uploaded once per rigged file and shared
  by every copy. There is no per-frame palette upload behind a baked character, which is why a
  hundred of them is affordable.
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
