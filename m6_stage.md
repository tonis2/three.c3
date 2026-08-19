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

Whole suite: **359 passed, 1 failed.** The failure is
`three_tests::js::a_bad_path_says_which_path`, which leaks on the load-error path
and **failed identically before any of this** — recorded here so it is not read
as fallout. It is a real bug and is not M6's.

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
problem is that the value is *invisible*: `cameraGet` does not report `near` or
`far`, so the only way to discover the limit is to bracket it, and the only way
to get it right is to already know the formula. See below.

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

## What is left in M6

In the order the town-square session wanted them:

1. **Debug draw.** Nothing shows where a pivot is, where a box ends, or that two
   faces are coplanar — a z-fighting starburst in that scene's fountain was two
   discs 0.01 apart and cost a render to find. `plan.md` §1 already settles the
   implementation: a line-list index buffer, not `POLYGON_MODE_LINE`, because the
   bundled KosmicKrisp reports no `fillModeNonSolid`.
2. **Three environment fixes.** `cameraGet` should report `near`/`far`, or
   `derive_planes` should consult the scene AABB the way `frame_bounds` already
   does. The clear colour is hardcoded at `gpu/frame.c3:176` and a daylight scene
   renders against a night sky. `material.side` — cull mode is not an optional
   device feature — because a sphere skydome is invisible from inside and
   negative scale does not flip the winding, so a sky is currently five
   inward-facing planes.
3. **The glTF writer**, as `plan.md` §5 scopes it. Two notes from reading for
   this stage: CPU positions and triangles are retained per mesh
   (`hull_positions`/`hull_triangles`) for picking and hulls, but normals and uvs
   are device-only — so the exporter re-reads the source `.glb` by `Asset.path`
   and copies its accessors rather than reading back from the GPU. Generated
   shapes regenerate from `Primitive.key`. The content-hash dedup the asset
   system already does *is* the exporter's dedup.
4. **Mesh splitting**, optional. Every AI-generated kit ships as one merged mesh;
   the town square needed an external tool to cut three packs into 23 pieces by
   connected components and layout gaps. The ingredients are already on the CPU.
