# Stats

- `drawCalls` — vkCmdDrawIndexed calls for one frame of this scene.
- `uniqueMeshes` — Distinct (asset, mesh) pairs drawn.
- `instances` — Total placed meshes. The M2 claim is that 1000 of these can be 1 drawCall.
- `nodes` — Live nodes, groups and the root included.
- `scenes` — How many Scenes exist. new three.Scene() shows a new world without freeing the one
  before it, so this is the number a level transition has to bring back down with scene.dispose().
  Every scene past the first holds a node pool, a physics world, a nav bake and a set of asset
  references, and none of it shows up in any other number here — the scenes nobody is looking at
  cost the frame nothing and memory everything. three.scenes is what the count is MADE of, one entry
  per world, and three.disposeInactive() frees every one that is not being rendered. A warning
  arrives in the run_script reply once the count starts doubling past four.
- `colliders` — Of those, the meshes in the spatial index — the ones every sweep and every raycast
  tests a box against. Drawable meshes default to collision geometry, so this grows as a level is
  decorated whether or not anybody meant it to; object.collides = false takes one out entirely
  rather than making it cheap to reject. Read it beside nodes: the gap between them is what has been
  said out loud, and this number climbing while sweeps get slower is a field of grass acting as a
  fence.
- `assets` — Loaded files and generated shapes resident on the device. This is the number a level
  transition has to bring back down; watch it across scene.unload().
- `triangles` — Summed over instances, so 1000 copies of a 500-triangle mesh is 500000.
- `vertices` — Likewise.
- `textures` — Unique images on the device, deduplicated by content across every loaded file.
- `textureBytes` — What those cost.
- `geometryBytes` — What the geometry costs: every vertex stream and index buffer on the device,
  PLUS the positions and triangle indices kept resident on the CPU, because the pick tree points at
  them. Both halves, because there are two — a scene of a few hundred thousand vertices carries tens
  of megabytes on each side. Falls to zero across a full unload, which is the number a count of
  assets cannot prove.
- `targetBytes` — The offscreen frame: one colour image and one depth image at the render size.
  What the process holds before a single mesh is loaded, about 17 MB at 1080p, and the floor under
  everything else here.
- `postBytes` — The post chain: Image A plus as much of the ping-pong pair as the chain needed,
  plus one image per tapped pass, at EIGHT bytes a pixel against the target's four — so a two-pass
  chain at 1080p is around 40 MB, more than the frame it is processing. 0 for a runtime that NEVER
  SET a post shader, and a high-water mark after that: three.setPost(null) retires the shaders and
  KEEPS the images, because the next setPost wants them at the same extent and freeing device images
  is not something a clear should stall for. So this does not fall when a chain is cleared or
  shortened, and a nonzero reading with nothing running is that rather than a leak.
- `shadowBytes` — The shadow map: two D32 images at size squared once anything in the scene is
  static, one before that. 2048 is 34 MB, 4096 is 134 MB and 8192 — the ceiling — is 536 MB. This is
  the single largest thing one assignment can do to a process, which is why the setter says so when
  it is raised above the default. 0 until shadows are turned on for the FIRST time. After that it
  follows shadow.size both up and down while they are on, but three.light.shadow.enabled = false
  keeps the last map rather than freeing it — turning shadows off does not give the memory back, and
  this says so.
- `materials` — Materials you have built and not had collected. The two built-in ones are not
  counted. This is assets for the OTHER resource that has to be given back by hand: a material holds
  a compiled pipeline until material.dispose() gives it back, so a script that builds one per run
  and drops the handle grows this forever — and the host says so in the run_script reply once this
  passes 64. It falls when the material is COLLECTED, which is after both the dispose() and the last
  mesh that named it going, so disposing while something still draws with it leaves the number where
  it was and that is correct.
- `culledLastFrame` — Instances the camera frustum dropped in the last render(). Meaningful with
  shadows on too: the shadow pass has its own draw list against the light's box, so turning shadows
  on no longer costs the camera its cull.
- `shadowCulled` — Instances neither pass drew — outside the camera frustum AND outside the
  light's box. 0 with shadows off. A caster the camera cannot see is still drawn into the map, so
  this is smaller than culledLastFrame, not equal to it.
- `shadowDraws` — Draw calls the last frame's shadow pass made, and 0 with shadows off. Roughly
  drawCalls minus the transparent buckets and the helpers, so this is what shadows cost in draws.
  With static casters in the scene it counts the movers alone — the rest were drawn once and kept.
- `shadowStaticDraws` — Draw calls that went into the cached half of the shadow map, and 0 on
  every frame that did not rebuild it — which should be almost all of them. Zero here with objects
  marked static is the saving working: the map held from one frame to the next. If it equals the
  caster count every frame, something is invalidating the cache — a camera that has not settled, or
  a node marked static that is still being moved.
- `skinnedDraws` — Draw calls whose geometry is posed by a skeleton.
- `skinnedInstances` — Characters in those draws. A hundred here with skinnedDraws at 1 is the
  crowd working as intended.
- `preskinnedInstances` — Of those, the ones routed through the compute pass — instantiate({
  skinning: 'compute' }). The expensive kind: each holds a posed copy of its mesh per frame in
  flight, and each is a draw call of its own.
- `poseBytes` — Device memory holding baked animation poses, uploaded once per rigged file and
  shared by every copy of it. This is what a rigged file costs that an unrigged one does not — there
  is no per-frame palette upload behind a baked character, which is why a hundred of them is
  affordable.
- `gpuMs` — Milliseconds the GPU spent on the frame you just asked for, measured on the GPU's own
  clock rather than timed from here. three.render() and a screenshot each leave their own
  measurement behind, so render first and read this after. 0 before anything has been drawn, and 0
  for the whole run in a context with no device — the same zero either way, so use renderSize() if
  you need to tell "nothing drawn" from "nothing to draw with". The span is the whole submission,
  including the blit or the readback copy that puts the frame where you can see it, so it answers
  what the frame cost rather than what the draws cost.
- `prepareMs` — Of gpuMs: uploads, the frame's buffer writes and compute skinning. Everything
  before the first pass begins.
- `shadowMs` — Of gpuMs: the shadow map. 0 with shadows off. This is the one worth looking at
  first in an outdoor scene — the map is fitted around the whole scene, so a wide level pays for
  texels nowhere near the camera, and three.light.shadow.size is the knob.
- `sceneMs` — Of gpuMs: the pass that draws the picture.
- `postMs` — Of gpuMs: the post chain, and 0 with no post shader.
- `presentMs` — Of gpuMs: getting the finished image out — the blit to the window, or the readback
  copy behind a screenshot. The five add up to gpuMs, so anything unaccounted for is a bug rather
  than a gap.
