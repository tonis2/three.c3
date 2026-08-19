# M6 — measuring, placing, and getting the scene back out

The step-by-step record of what M6 builds, where it departs from `plan.md`, and
what was actually run to believe any of it. `base_stage.md` is the same document
for M0/M1, `m2_stage.md` through `m5_stage.md` for M2 to M5, `m5a_stage.md` for
the parametric shapes and `m5b_stage.md` for per-copy colour.

`plan.md` §5 scopes M6 as the glTF export alone. It is written here as the larger
thing that export is one third of, because the milestone's real subject turned
out to be a property the scene had and nobody had named: **it is write-only.** A
script can put geometry in. It cannot measure what is there, see what is there,
or get it back out. Export is the third of those. The first is cheaper, blocks
more, and the exporter wants it too, so it went first.

**The question this answers, asked from outside:** a script has a kit piece and a
wall, and wants the piece's back face flush with the wall. What does it type?

Before this, the honest answer was "carry the piece's dimensions into the script
as a literal and do the arithmetic yourself", because nothing in the API would
tell a script how big anything was. Now:

```js
const kit = three.load("kit/windows_split.glb");
const win = new three.Mesh(kit.mesh("window_04"));
wall.add(win);

win.alignTo(wall, { axis: 'z', mine: 'min', theirs: 'max', offset: -0.28 });
win.align('y', 'min', 2.2);
```

All three thirds are in. The other two are the same shape — one line each, for
questions that used to cost a render and a theory:

```js
scene.add(new three.BoxHelper(win));           // where does it actually end?
win.add(new three.WireframeHelper(win));       // which triangles does it have?
scene.export("out/street.glb");                // and hand the whole thing back
```

## Where this came from

A session that built a town square out of three AI-generated kit packs, and the
record of it is worth keeping because every step below is a thing that went
wrong there rather than a thing that seemed nice.

The script that built it opened with a 23-entry table of piece dimensions,
transcribed by hand out of an external splitting tool. Every placement was
arithmetic over that table. The worst bug of the session came straight out of it:
these windows put their flower box at the *front* of the bounding box and their
frame behind it, so mounting a piece by centring its pivot on the wall plane
buries the frame in the masonry and leaves a flower box floating on blank
plaster. It renders. It looks like the wall is fine and the window failed to
load. Finding it took a render, a zoom, and a wrong theory about draw order
first.

**A hand-written size table is not a workaround, it is a silent-failure
generator.** It is written once, it is never checked against the asset again, and
when it is wrong the scene still draws.

## The steps

### S1 — a mesh's box crosses to JavaScript (`src/scene/asset.c3`, `src/js/bind_asset.c3`, `src/js/bind_scene.c3`)

`GpuMesh.bounds` already existed and was already populated: `Assets.load`
describes a file rather than uploading it, and `bounds` is one of the three
fields filled in from the JSON at parse time — the POSITION accessor's required
`min`/`max`, the same read `inventory.c3` does. Nothing needed computing. It
simply had no door.

`meshBounds(index, generation, mesh)` is that door, answering with six numbers or
`null`. `aabb_value` lands beside `vec3_value` in `bind_scene.c3` because
`js_object_bounds` needs it too.

**Per mesh index, not per mesh name.** A glTF mesh with several primitives
produced several `GpuMesh` entries sharing one name, and a `Mesh` node draws
exactly one of them. Keying on the name would answer with the union of things a
script did not place.

**Reading a box uploads nothing, and that is the property worth protecting.**
Choosing twelve pieces out of a two-hundred-piece kit means measuring two hundred
of them. If measuring uploaded, the cheap question would cost more than the
placement. `measuring_a_loaded_mesh_does_not_upload_it` pins it by asserting
`stats().textures` is still 0 after the measurement.

### S2 — the world-space box of a subtree (`src/scene/scene.c3`, `src/js/bind_scene.c3`)

`Scene.bounds` already unioned `transform_aabb(node.world, mesh.bounds)` over
every drawable node — it is what `frame_camera` aims at. `Scene.subtree_bounds`
is the same union restricted to one node and its descendants, and
`objectBounds(handle, generation)` is its binding.

`Scene.grow_bounds` copies each child list before recursing, for `Scene.kill`'s
reason: the walk reaches the node pool through `self` and a `Node*` held across
it is a pointer into a list that may have moved.

**Empty is `null`, not a unit box.** `Scene.bounds` answers with a unit box when
the scene is empty because the camera has to point somewhere. Here the caller
asked about a specific subtree, and a Group of Groups genuinely has no size —
answering `{-1,-1,-1}..{1,1,1}` would be a number a script would place things
against.

### S3 — two boxes, and the frame each one is in (`src/js/prelude.js`)

`Box3` is `min`, `max`, and `size`/`center` derived rather than stored. `edge(axis, which)`
is one face's coordinate and is what `align` is written in terms of.

Then the split that is the whole design:

| | frame | computed by | works before `add()` |
|---|---|---|---|
| `boundingBox()` | world | host | no |
| `boundsInParent()` | the parent's | JavaScript | yes |

**Placement is in the parent's frame because that is the frame a script writes
`position` in.** A window is positioned inside its building's Group; the Group is
then rotated to face the square. Aligning in world space would mean inverting the
Group's rotation to get back to a local `position` — slower, and a place to be
subtly wrong at exactly 90°, which is the single most common angle anyone
authors.

`boundsInParent` therefore composes the local TRS in JavaScript, which means
`prelude.js` now contains a rotation matrix that has to mean the same thing as
the quaternion `scene/node.c3` composes. That is the one genuinely risky part of
this milestone and S4 is the check for it.

`align(axis, edge, at)` moves along one axis until a chosen face sits at a
coordinate. Only `position` moves: rotation and scale are inputs to where the box
*is*, so they are set first. `alignTo(other, {...})` says the same thing against
a sibling, and **refuses non-siblings by name** — two parents are two frames, and
a box measured in one means nothing in the other. Refusing is the difference
between an error and being wrong by however much the parents differ.

### S4 — the check that the two rotations are the same rotation (`test/bounds_test.c3`)

`the_two_boxes_agree_at_the_root` puts a mesh with all three Euler angles
non-zero and a non-uniform scale under the scene root, where the parent frame and
the world frame are the same frame, and requires the two boxes to agree to 1e-4.

It is the only check in the suite that can catch a wrong Euler convention,
because every other one uses an axis-aligned object, and every convention agrees
about those. It passed on the first run, which says `Rx·Ry·Rz` as documented in
`scene/node.c3` is what `quat_from_euler` actually builds — but the check is what
makes that a fact rather than a reading of a comment.

### S5 — the docs (`src/js/prelude.js`)

`the_docs_name_everything_the_api_exposes` failed with 22 undocumented names the
moment the classes landed, which is the test doing its job. `Box3` and `MeshRef`
gained entries, the three object classes gained the four verbs, every shape
gained `bounds`, and two entries went into `differences` — that list is what an
agent reads before writing anything, so a capability absent from it does not
exist in practice.

One trap while doing it: the blanket edit that added `properties: ['bounds']` to
the seven shapes also hit `Geometry`, which already had a `properties` key. A
duplicate key in an object literal is not an error in JavaScript — the last one
wins — so `Geometry` would have silently lost `type`, `name`, `parameters`,
`asset` and `mesh` from its documentation. Caught by counting the replacements,
not by anything failing.

### S6 — the three environment fixes (`src/scene/camera.c3`, `src/gpu/frame.c3`, `src/scene/material.c3`)

Three unrelated defects, taken together because each of them made a scene render
*wrong rather than fail*, and all three came out of the same session.

**The planes are reported and derived from the scene.** `cameraGet` answers with
`near` and `far` at indices 7 and 8, and `derive_planes` consults the scene's own
AABB the way `frame_bounds` already did instead of taking `distance * 8` alone.
The trap recorded below is what this closes: the far plane moved when the camera
dollied and nothing would say where it was, so the only way to find the limit was
to bracket it with test geometry. Assigning either throws rather than being
ignored — they are derived, and a setter that silently did nothing would be the
worse half of a half-match.

**The clear colour is a scene property.** `scene.background` takes a colour or
`null`, in any spelling `mesh.color` takes. Not a Texture and not a CubeTexture,
which Three.js also accepts here: there is no environment map anywhere in this
project and accepting one to ignore it is the half-match `plan.md` §4 rules out.
What this removes is not the ability to have a sky — a gradient sky is still
geometry — but the daylight scene rendering against a near-black nobody chose.

**`material.side` is on the material, not the mesh.** It is a property of the
pipeline: two meshes sharing a geometry and a material are one draw call and
would stop being one if they could disagree about it. `three.BackSide` is what
makes a sphere visible from inside, and it exists because the obvious workaround
does not work — scaling a sphere by -1 does not reverse a triangle's winding, so
a skydome built that way is invisible and a sky was five inward-facing planes.
Side is set with `vkCmdSetCullMode` at record time rather than baked into the
pipeline, so two materials differing only in their side share one `VkPipeline`
and flipping one builds nothing;
`flipping_a_side_costs_no_compile_and_no_pipeline` is the check.

### S7 — debug draw (`src/scene/lines.c3`, `src/gpu/pipeline.c3`, `src/render/pass.c3`, `src/js/bind_asset.c3`, `src/js/prelude.js`)

**A helper is an ordinary `Mesh` over an ordinary asset.** Every engine's debug
draw is an immediate-mode side channel — a list of segments refilled and uploaded
each frame — and that would have been a second renderer here, with its own buffer
growth, its own frame-slot problem and its own answer to "how many draw calls was
that". It is not needed: a debug box is a shape, and this project already has one
path for shapes. So the properties fall out rather than being re-engineered. A
thousand box helpers are one draw call, `helper.color` is free per copy,
`scene.remove(helper)` works, and `unloadUnused` gives the memory back.

**Lines, not a fill mode, and the reason survived a driver bump.** `plan.md` §1
settled this before there was anything to draw: `fillModeNonSolid` is false on
the bundled KosmicKrisp, so `POLYGON_MODE_LINE` is not available.

Bumping Mesa to 26.3.0-devel during this stage was partly an attempt to retire
the line *pipeline* too, by way of `dynamicPrimitiveTopologyUnrestricted` — and
that flag is still false. It is false honestly rather than as a stub: Mesa's
KosmicKrisp writes `MTLRenderPipelineDescriptor.inputPrimitiveTopology`
unconditionally, because layered rendering requires the class to be stated on the
PSO, and a driver that has baked the class in cannot promise an unrestricted
switch. The driver then honours the illegal switch anyway, pixel for pixel,
because a Metal draw takes its primitive type at draw time — which is exactly the
trap, since the only thing that says anything is wrong is a validation error on
every frame, and a validation error on every frame is how a real one gets missed.
`PipelineState`'s doc block carries the decision and the VUID.

So `LINE_STATE` stays a second `VkPipeline` over a byte-identical shader — and
not a second Slang call, because `acquire` keys on the source as well as the
state.

**No depth test at all**, which is where this departs from Three.js. A debug line
exists to answer "where is this thing", and the times that is asked are exactly
the times the thing is somewhere it should not be — inside a wall, behind the
terrain, buried in the masonry. The town-square session lost a render to a window
that had sunk into its own stone, and a box helper hidden by that stone would
have been no help. It also removes the hard case for free: a wireframe drawn over
its own mesh is exactly coplanar with it, and coplanar depth is a speckle — which
is the failure the helper exists to *diagnose*, appearing in the diagnostic. The
cost is that lines do not sort with the scene, so `Scene.build_draw_list` puts
the line material last, and that is not an ordering luck gets right.

**A helper is not pickable**, and that too is a consequence rather than a
feature: `upload_built` skips the picking tree for a line mesh because the index
buffer is pairs and `build_bvh` reads it in threes. So a click goes through the
box onto the thing it is drawn around, which is what a script wants.

The JavaScript surface is `Box3Helper`, `BoxHelper`, `AxesHelper`, `GridHelper`
and `WireframeHelper`. Two of them earn a note:

- **`BoxHelper` hangs from the object's own parent and is refused anywhere
  else.** Its box comes from `boundsInParent()`, so a helper under a different
  parent is drawn wherever the two frames happen to differ. That is `alignTo`'s
  rule for `alignTo`'s reason — a box in the wrong place is worse than no box.
- **`WireframeHelper` needs the mesh on the device**, and that is the only
  precondition in the set. A generated shape is uploaded when it is constructed
  and works detached; a mesh out of a file reaches the device when something
  drawing it is added to a scene, and until then there are no triangles to read.
  It is a sentence rather than an empty helper, because an empty helper reads as
  one that does not work.

**The literal that needed a test.** `prelude.js` spells the line material as `1`
because there is no verb that answers it, and nothing in either language connects
that to `scene/material.c3`'s `const uint LINE_MATERIAL = 1`.
`a_helper_draws_with_the_line_material` is the connection: it counts host nodes
carrying the constant itself, so renumbering on either side fails there rather
than in a render months later. Same trick
`the_default_background_is_the_renderer_clear` plays on the clear colour.

### S8 — the export (`src/scene/export.c3`, `lib/gltf.c3l/src/writer.c3`)

`plan.md` §5, and the acceptance is its own sentence: a scene built by a script
round-trips through `.glb` and loads back with the same draw-call count.

**The dedup the plan asks for needed no hashing.** `GpuMesh.texture` is already
an index into `Assets.textures`, which is deduplicated by a hash of the *decoded*
image across every loaded file — so two kit packs sharing an atlas already point
at one slot, and keying the exported image on that index *is* that dedup, reused.
A second hash over the encoded bytes would have been a second answer to a
question already settled, and the two could disagree. Geometry is deduplicated on
`(asset, mesh)`, the pair the renderer buckets on.

**Nothing is read back off the device**, and the note carried into this stage
turned out to be two thirds right. A mesh out of a file is re-read from the file,
which is still open — exact, because the bytes written out are the bytes read in.
A hull is rebuilt from `hull_positions`/`hull_triangles`, and its normals are
recomputed rather than stored, which is exact rather than approximate:
`build_convex` splits a vertex per face, so each vertex belongs to one triangle
and the accumulated normal is that triangle's. But a generated shape does **not**
regenerate from `Primitive.key` — parsing a cache key back into a struct is a
second parser for a format that exists to be compared, not read. The `Primitive`
itself is kept on the `Asset` instead: thirty-two bytes per asset, against the
twenty per vertex that keeping the CPU streams would have cost every scene
whether or not it ever exported.

**`gltf.c3l` could not write a material.** `WritePrimitive` carried a `material`
index and `to_json` emitted it, but there was no `materials` array, no
`textures`, no `images` and nothing to add one with — so the first file this
wrote referenced material 0 of an array that did not exist. The writer gained all
four sections. Two defects in the *reader* came out of the same test:
`Image.from_json` left `name`, `view` and `uri` unassigned when the JSON omitted
them, and the caller declares `Image data;` uninitialized; and the `name` it does
assign is a slice into the JSON document, which does not outlive the load. Read
at export time, that put nine bytes of fill pattern inside a JSON string and
produced a file the parser crashed on. The defaults are fixed and the exporter
does not carry the name across the lifetime boundary — a glTF image name is
decoration, and decoration is not worth a dangling pointer.

**Three things do not survive, each on purpose.**

- **Helpers and hidden subtrees.** One rule with two consequences: the export is
  what the frame shows. A `.glb` with the debug boxes baked in is a file nobody
  wants, and a subtree that is switched off is not part of the picture. `skipped`
  counts them, so it is visible rather than silent.
- **`ShaderMaterial`s.** A material here is a Slang pipeline; glTF describes
  surfaces, not programs. Dropping the mesh would be worse than dropping the
  shader, so the geometry goes out with the base colour and texture it carries
  and `shaded` counts what lost one.
- **Per-copy colour, as a per-copy thing.** This is the one place the round-trip
  claim has a caveat, and it is the format's limit rather than this writer's.
  `mesh.color` is free here because it rides in the instance record; glTF has no
  per-instance channel at all — a material belongs to a primitive, a primitive to
  a mesh, and a node points at a mesh — so each distinct colour needs its own
  material and its own `mesh` entry. The *vertices* are still written once and
  referenced by each, which is what `meshes` counting 1 while `entries` counts 3
  means. What does not survive is the draw call: three colours come back as three
  buckets where they drew as one.

Vertex colour does not rescue this and neither does anything else standard.
`COLOR_0` is a *vertex* attribute on the shared mesh, so it has the same fan-out
plus an array of one repeated colour where the material had four floats.
`EXT_mesh_gpu_instancing` is the one thing designed for the case, and it
standardises only `TRANSLATION`, `ROTATION` and `SCALE` — a colour would be an
underscore-prefixed attribute no other tool reads, and it would take reader
support here to buy back something only this project could see. Recorded because
it is the natural next question and the answer is not obvious.

## Where this departed from `plan.md`

- **M6 is three things, and the export is the last of them.** `plan.md` §5 names
  only the glTF writer. Bounds went first because the exporter wants them, they
  are nearly free, and they unblock every script written in the meantime.
- **`Box3` is a new exported class.** `plan.md` §4's rule is that a divergence
  from Three.js takes a name Three.js does not have. This is the opposite case —
  Three.js *has* `Box3` and this one is a strict subset of it, so it keeps the
  name. What it does not have is `setFromObject`, because the host computes that
  and hands it over.
- **No `Box3.intersects` / `containsPoint` yet.** Nothing needed them. They are
  four lines each when something does.
- **The helpers keep Three.js's names and lose its depth test.** `Box3Helper`,
  `BoxHelper`, `AxesHelper` and `GridHelper` are Three.js's, narrowed —
  `GridHelper` takes one colour where Three.js takes two, which is the same kind
  of narrowing `scene.background` does by refusing a Texture. `WireframeHelper`
  is a name Three.js does not have, by §4's rule: Three.js reaches this through
  `WireframeGeometry` plus a `LineSegments`, and what this takes is different —
  a mesh that is already in the scene, not a geometry.
- **`scene.export(path)` is a name Three.js does not have**, and §4's rule is why.
  Three.js's `GLTFExporter` is a separate object with a callback API that hands
  back an ArrayBuffer; this writes a file, synchronously, from the Scene. Sharing
  the name would have been the half-match.
- **The export writes `EXT_mesh_gpu_instancing` nowhere.** `plan.md` §5 says one
  `node` per instance and that is what it does, which is also the only layout in
  which per-copy colour can be carried at all. The two are alternatives rather
  than additions — see S8.
- **`gltf.c3l` grew a materials writer.** The milestone was scoped as work in
  this repository and half of S8 landed in the submodule, because a glTF writer
  that cannot write a material cannot write a scene. Worth naming here so the
  next person looking for the export does not read only one of the two diffs.

## Verification

```
c3c build && c3c test
```

`test/bounds_test.c3`, 13 checks, all passing:

- a generated shape carries its own box; a torus is `2 * (radius + tube)` across,
  which is a number that appears in no constructor argument
- **the two boxes agree at the root** — S4, the Euler check
- a Group is boxed by what is under it; an empty one answers `null`
- `align` puts a face where it was asked for, and respects a scale set before it
- `alignTo` places a sibling against a sibling, refuses non-siblings, and says why
- a bad axis is quoted back
- measuring a loaded mesh does not upload it
- bounds from a stale reference throw rather than answering with the old size

`test/environment_test.c3`, 15 checks — S6:

- the camera reports the planes it derived, the far plane reaches the scene it
  was shown, and a small scene does not shrink it
- writing a derived plane says which verb moves it, rather than being ignored
- the background round-trips as components, a hex is divided by 255, and the
  default is the renderer's own clear colour — checked against `DEFAULT_CLEAR`
  rather than against a comment
- `BackSide` is what makes a dome visible from inside, an unknown side is refused
  by name, and flipping a side costs no compile and no pipeline

`test/lines_test.c3`, 20 checks — S7. Half of them count vertices and indices,
because those are the numbers a picture cannot check: a wireframe that drew every
shared edge twice looks exactly like one that does not and costs twice the index
buffer. A plane is four vertices and five edges — the four sides and the diagonal
the quad was split along — so ten indices, and twelve would mean the dedup did
nothing.

- the unit box is twelve edges with corners at +/- 0.5, which is what lets a
  helper be placed by copying a box's centre and size with no factor of two
- a line shape is keyed on what it reads: a stray division count on a box is
  still the one box asset, and two grids at two sizes are one asset
- a line mesh has no picking tree, and a click goes through a helper
- **a helper draws with the host's own `LINE_MATERIAL`** — the literal check
- a thousand box helpers are `[1, 1, 1000]`; two AxesHelpers are six arms over
  one asset in one call
- a box helper lands on the box it measured, is stale until `update()`, and
  refuses a parent that is not the object's
- a helper refuses a ShaderMaterial, and nothing is assigned when it does

`test/export_test.c3`, 12 checks — S8. Every check about *sharing* goes through a
reload rather than through the bytes, because a file can be inspected for a mesh
count and still be wrong in the way that matters: two nodes referencing one mesh
and two nodes referencing two identical meshes produce the same picture and
differ by a factor of N in what they cost. `Assets.load` buckets on
`(asset, mesh, material)`, so a file that duplicated its geometry comes back as
one bucket per copy and nothing else can tell them apart.

- **`a_scene_round_trips_with_the_same_draw_calls`** — `plan.md` §5's sentence,
  executed. Three shapes and thirty copies each: `[3, 3, 90]` out, `[3, 3, 90]`
  back
- a thousand copies are one mesh in the file
- a generated shape is tessellated again; a hull comes back out of the picking
  tree with its four faces and twelve split vertices
- a file's mesh keeps its texture, and an image two files share is written once
- helpers and hidden subtrees are not in the file; a ShaderMaterial's geometry is
  and says so
- a colour per copy becomes a material per colour — the caveat, stated
- an empty scene, a scene of only helpers, and an empty path are each refused
  with a sentence and write no file

Whole suite: **407 passed, 0 failed.**

The one failure this document recorded when it was written —
`three_tests::js::a_bad_path_says_which_path`, which leaked on the load-error
path and failed identically before M6 — is fixed. It was ordering rather than a
missing free: `Assets.load` copied the path into `mem`, *then* opened the file
with `!`, and only then registered the `defer catch` that frees the copy. A
`defer catch` covers the statements below it, so a failure on the open unwound
past a cleanup block that did not exist yet, and every failed load leaked one
path. The stream is now opened first, into a local, so the only failure point
that can precede the copy is one that has allocated nothing.

### Against the real assets

The 23-piece table hand-transcribed during the town-square session was checked
against what `bounds` now reports, for all 23 pieces of all three packs: every
axis agreed to within 0.0005, which is the rounding in the transcription. The
API answers with exactly what a person had to work out by hand. (Written as a
throwaway test and deleted — it depends on files outside the repository.)

### The bug, and the fix, in one frame

Two identical walls, the same `window_04`, placed two ways: the left one by
centring the pivot on the wall plane — which is what the old API made natural —
and the right one with `alignTo(wall, { mine: 'min', theirs: 'max' })`. The left
window is swallowed by the wall with fragments of jamb and planter protruding.
The right one sits proud, with its arch and its recessed pane. That is the
town-square bug reproduced deliberately and then fixed by one line.

## A trap, recorded

**The camera's far plane is derived from the orbit distance and moves when the
camera dollies.** `Camera.derive_planes` sets `far = distance * 8`.

The town-square session spent real time on a skybox that vanished and reappeared,
and concluded from bracketing it with test planes that the far plane was "a fixed
~300 units". It is not; the probe simply ran at orbit distance 40. Every symptom
followed from the multiple: a sky box that was fine in the wide shot was clipped
in the close one, because moving in had moved the far plane in with it.

The rationale in `derive_planes` is sound — a fixed near plane against a
kilometre-wide model spends the whole depth buffer on the first few metres. The
problem was that the value was *invisible*: `cameraGet` did not report `near` or
`far`, so the only way to discover the limit was to bracket it with test
geometry, and the only way to get it right was to already know the formula.

**Closed by S6.** The planes are reported and the far one consults the scene's
own bounds, so a script that has lost its sky can read the number instead of
inferring it. The trap is kept here rather than deleted because the *shape* of it
outlives the fix: a derived value that nothing reports is discovered by
experiment, and an experiment run at one orbit distance produces a constant that
is wrong everywhere else.

## What is deliberately absent

- **No `setPivot`.** Reinterpreting an origin sounds like the fix for "the pivot
  is in the wrong place", and it is not: it adds a second place a piece's
  position comes from, and the next script has to know which one is in play.
  `align` moves the object to put a *face* where it belongs and leaves the pivot
  alone, which needs no state.
- **No caching of `bounds`.** The numbers never change for a live asset, but a
  cached box would keep answering after `unloadUnused()` freed the thing it
  described. Every other handle in this API revalidates on use; this one does too.
- **No world-space `align`.** It would need a matrix inverse to write back a
  local `position`, and the sibling form covers the case that actually occurs.
  `boundsInParent()` plus `align(axis, edge, number)` is the escape hatch.
- **No helper that follows its object.** `BoxHelper.update()` is called by hand,
  as Three.js's is. Making it automatic means either a per-frame walk that costs
  every scene that has no helpers in it, or a dirty flag on every object for the
  benefit of a debug tool — and the failure it would prevent, a box drawn where
  something used to be, is visible in the picture the helper is being looked at
  in.
- **No line width, and no fourth line shape.** `wideLines` is false on the
  bundled driver, so every line here is one pixel and there is nothing to set. A
  box says where something ends, an axis says where its pivot is, a grid says how
  big a metre looks; a fourth would want a reason of its own.
- **No `.gltf` output, and no external `.bin`.** `save_glb` writes one file with
  the images inside it. A `.gltf` beside a `.bin` beside a folder of `.png`s is
  four things to copy and four things to lose, and every consumer reads `.glb`.
- **The export writes no camera and no lights.** glTF has both and this project
  has one turntable and a hardcoded directional term, neither of which is a
  scene object a script can address. Writing them out would be exporting an
  implementation detail as though it were content.

## What is left in M6

**One thing, and it is the optional one.**

**Mesh splitting.** Every AI-generated kit ships as one merged mesh; the town
square needed an external tool to cut three packs into 23 pieces by connected
components and layout gaps. The ingredients have been on the CPU the whole time —
`hull_positions` and `hull_triangles` are what the picking tree already holds,
and S8 proved they are enough to rebuild a mesh from, because that is how a hull
is exported. A split is a connected-components pass over the triangles and then
`upload_built` per component, which is the verb every generator here already ends
on.

It stayed optional because nothing in this milestone needed it and because the
case for it is weaker than it looks: a kit that arrives merged can be cut in
Blender once, and a splitter in the engine is a tool that runs at load time
forever to fix a file that could have been fixed once. What would change that is
an agent generating kits with no person in the loop — which is the direction the
project is going, so this is a "not yet" rather than a "no".

## What this milestone turned out to be about

`plan.md` §5 scoped M6 as the glTF export alone, and the export is the third of
three things in it. The reason it grew is in the header: the scene was
**write-only**. A script could put geometry in and could not measure what was
there, see what was there, or get it back out. Those are the three, and they went
in that order because each one is the cheapest tool for a failure the one before
it could only produce:

- **Measuring** (S1–S5) replaced a hand-written size table, which is not a
  workaround but a silent-failure generator — written once, never checked against
  the asset again, and when it is wrong the scene still draws.
- **Seeing** (S6–S7) replaced a render, a zoom and a theory. The environment
  fixes belong with debug draw rather than beside it: an invisible far plane, a
  clear colour nobody chose and a skydome that could not be built are all the
  same failure as a z-fighting starburst — the picture is wrong and nothing in it
  says why.
- **Getting it back out** (S8) is where "linked, not duplicated" stops being an
  internal claim and becomes something another program can check. The file says
  what the frame says about sharing, and the reload is the proof.

The through-line is that all three exist to shorten the loop between an agent
making a change and finding out what it did. That is the same argument
`getApiDocs()` makes in `plan.md` §4, applied to the scene instead of to the API.
