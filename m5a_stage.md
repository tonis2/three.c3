# M5a — the parametric shapes

The step-by-step record of what M5a builds, where it departs from `plan.md`, and
what was actually run to believe any of it. `base_stage.md` is the same document
for M0/M1, `m2_stage.md` for M2, `m3_stage.md` for M3, `m4_stage.md` for M4 and
`m5_stage.md` for M5.

**This is not a milestone `plan.md` asked for.** It was asked for from outside,
and the reason it is worth doing is that a scene no longer needs a `.glb` to
exist: an agent told to lay out a room can do it in one script and swap the kit
in later.

```js
const scene = new three.Scene();
for (let i = 0; i < 100; i++) {
  const cube = new three.Mesh(new three.BoxGeometry(1, 1, 1));
  cube.position.set(i % 10, 0, Math.floor(i / 10));
  scene.add(cube);
}
return scene.stats();   // { drawCalls: 1, uniqueMeshes: 1, instances: 100, ... }
```

Six shapes, with Three.js's constructor signatures, defaults and orientations:
`BoxGeometry`, `SphereGeometry`, `PlaneGeometry`, `CylinderGeometry`,
`ConeGeometry`, `TorusGeometry`.

## The steps

### S1 — the shape layer (`src/scene/primitive.c3`)

A `Primitive` is a kind and its numbers. `Primitive.build` fills a
`GeometryBuilder` — three streams and an index list, the same shape
`upload_primitive` reads out of a glTF accessor — and `Assets.primitive` uploads
it through the same path a file takes: `upload_stream`, `upload_indices`,
`build_bvh`, bounds from the vertices.

**The thesis is not spent, and the argument is worth stating rather than
assuming.** `plan.md` §"What it is" says JS may not touch vertices, and observes
in the same paragraph that Three.js agents build scenes out of `BoxGeometry`
while three.c3 agents build them out of real assets. Those were never one claim.
What crosses from JavaScript is a shape's *name and its numbers*; what comes back
is an ordinary asset index. No script can read a vertex, write one, or hand an
array of them over. The rule that keeps it that way is that a shape is
**parametric**: there is no `BufferGeometry`, no attribute access, and there will
not be. That paragraph in `plan.md` now carries the argument, because code that
contradicts the plan it is filed under is worse than either.

**The parameters are the identity.** `Primitive.key` formats them —
`<box 1.000000x1.000000x1.000000 1x1x1>` — and `Assets.primitive` scans
`Asset.path` for it exactly as `Assets.load` scans for a filename. So the
Three.js habit of constructing a geometry per mesh is one upload and one
instanced draw here, rather than N of each as it is under Three.js without
`InstancedMesh`. **The habit an agent already has produces the fast scene**,
which is the most useful thing this feature does.

Six decimals is therefore the resolution at which two shapes are one shape. That
is deliberate: a bit-exact key would make a width computed as `3 / 3` and one
written as `1` two uploads and two draw calls, a performance cliff that depends
on floating-point history and is invisible from JavaScript.

**A cone is a cylinder with a top radius of zero**, normalised on the way in
rather than carried as a sixth kind — which is also what Three.js's
`ConeGeometry` is. So `ConeGeometry(1, 2)` and `CylinderGeometry(0, 1, 2)` reach
the same key, share one upload, and bucket into one draw call.

**Three.js's formulas are copied rather than re-derived.** Positions, winding, UV
layout and orientation: a plane faces +Z, a cylinder's axis is Y, a torus lies in
XY, a sphere's north pole is +Y, a cone points up. An agent that has memorized
Three.js has memorized those too, and a shape that is the right size and the
wrong way up is a bug it has no reason to look for. Copying also carries the
winding across for free, which is the subject of S3.

Two small departures from Three.js's own implementation, both noted where they
are made:

- A cap is a fan around **one** centre vertex. Three.js pushes a copy per
  segment; every copy carries the same position, normal and uv, and exists only
  to keep each triangle's vertices adjacent for its group bookkeeping. There are
  no groups here.
- The degenerate row at a sphere's pole and a cone's tip is **not emitted**.
  Three.js drops it too; the reason to be explicit is that a zero-area triangle
  in a `TriBVH` is a leaf that can never be hit and can never be pruned, so every
  ray through that corner of the tree pays for it forever.

### S2 — one host verb, six JavaScript classes (`src/js/bind_asset.c3`, `src/js/prelude.js`)

`__three.primitive(kind, a, b, c, u, v, w, capped)` — one verb for all five host
kinds, because the layer below is already a switch on the kind and a verb per
shape would be five copies differing only in which arguments they ignore. It
takes numbers and answers with a number, which is what every verb in that layer
does.

Everything Three.js-shaped is in `prelude.js`, per `m3_stage.md` S1's rule: the
constructor names, the argument order, the defaults, the `parameters` object, and
the range checks. **The checks are there rather than in the host** for
`ShaderMaterial`'s reason — the error arrives at the line the agent wrote, naming
the argument rather than the failure:

    new three.BoxGeometry(0, 1, 1)
    RangeError: new three.BoxGeometry(width, height, depth): width must be a
                positive number, got 0

The host clamps instead of throwing, and that is not a duplicate of the same
rule: the clamp is the backstop for a script that reaches past the prelude and
calls `__three.primitive` itself, where the alternative to a clamp is a division
by zero or an allocation the size of the device.

A geometry **is** an asset reference — it carries `asset` and `mesh`, which is
what `asset.mesh(name)` carries — so `new three.Mesh(...)` takes either and
cannot tell them apart.

`Mesh` also gained Three.js's **second constructor argument**,
`new three.Mesh(geometry, material)`. Not asked for and not in `plan.md`; it is
here because it is half of the line an agent has memorized, and it costs one
assignment through the existing `material` setter — so a bad material throws at
the constructor rather than at the `add`.

### S3 — what a screenshot cannot check (`test/primitive_test.c3`)

**A shape wound inside-out fills the same silhouette.** Under
`CULL_MODE_BACK_BIT` an inverted sphere draws its far hemisphere instead of its
near one: the same circle, the same colour, the same place. A pixel count, a
coverage fraction and a "did anything render" check all pass. It surfaces later
as objects that vanish when the camera crosses them and as shading that lights
from the wrong side.

So `primitive_test.c3` has no device in it at all, and asserts on the triangles:

- `every_generated_face_points_outward` computes each face's normal from the
  order of its own indices and requires it to point away from the inside — from
  the origin for the four shapes that are star-shaped about it, and from the
  centre line of the tube for the torus, which is not.
- `the_normals_agree_with_the_winding` requires the two statements about which
  side is out to agree.
- `nothing_degenerate_is_emitted`, `texture_coordinates_stay_in_the_unit_square`,
  `the_three_streams_are_the_same_length`, and an extent check per shape read off
  the vertices rather than off the parameters.
- `a_cone_is_shaded_as_a_cone` is exact rather than approximate: the straight
  line from any point on a cone's side to its tip lies *in* the surface, so the
  normal there is perpendicular to it, for a cone of any proportion. Nothing else
  catches the tempting `(sin, 0, cos)` side normal, which is right for a cylinder
  and wrong for everything that tapers.

The invariant all of that rests on is one line in `build_face`: **`u × v` must
equal the normal.** A right-handed frame makes `(a, b, d)` and `(b, c, d)` over
rows running down the v axis come out counter-clockwise seen from outside, on all
six sides of a box, both caps of a cylinder and every quad of a sphere.

The complement — that a shape reaches the screen at all — is
`every_shape_reaches_the_screen` in `js_test.c3`, where there is a device. It is
a weaker claim made a different way, and neither test substitutes for the other.
S4 has the measurement that says so.

## Where this departed from `plan.md`

- **`plan.md` did not have this milestone**, and §"What it is" argued the other
  way. It now carries the argument for why a parametric shape is not a vertex,
  and §4 and §5 carry the shapes themselves.
- **`Mesh` takes a material in its constructor** (S2). A Three.js-shaped addition
  nobody asked for; it is one line and it is the line an agent writes.
- **`scene/primitive.c3` and `test/primitive_test.c3` are additions to
  §"Source tree"**, and are listed there.

## Verification

    c3c build --trust=full                               clean
    c3c test --trust=full --test-noleak                  148 passed, 0 failed
    c3c test --trust=full                                148 passed, leak-clean
    three --mcp 8808, run_script over HTTP, windowed     73 instances, 7 draws

The suite went from 127 at the end of M5 to **148**. Eleven new in a new
`three_tests::primitive` and ten in `three_tests::js`.

**Every regression test claimed here was checked by re-introducing the bug it
catches** (`plan.md` §7: an unexercised regression test is an assumption). Each
injection was applied by a pattern that matched exactly once, and
`src/scene/primitive.c3` was restored from a copy and checksummed after every
one.

| bug injected | test that caught it | result |
|---|---|---|
| a box's +X face handed a left-handed frame | `every_generated_face_points_outward`, `the_normals_agree_with_the_winding` | caught |
| the degenerate quad at a sphere's poles emitted anyway | `nothing_degenerate_is_emitted` | caught |
| the key stops naming the depth subdivision | `the_key_names_every_number_that_reaches_a_vertex` | caught |
| the dedup scan removed, so every shape uploads | `a_shape_needs_no_file_and_a_hundred_of_them_is_one_draw`, `a_cone_and_the_cylinder_that_spells_it_are_one_draw` | caught |
| a cone's side normals built radially, as a cylinder's | `a_cone_is_shaded_as_a_cone` | caught |
| the top cap wound the same way as the bottom | `every_generated_face_points_outward` | caught |
| the plane's triangles wound the other way | `every_shape_reaches_the_screen` (0 of 30000 pixels), `the_normals_agree_with_the_winding` | caught |

### The injection that was too weak, and what it measured instead

The plane was first inverted by flipping its **normal** from +Z to −Z, to see
`every_shape_reaches_the_screen` catch it. It did not, and it was right not to:
the winding in `build_face` comes from the u and v axes, so flipping the normal
changes the shading and leaves the triangles facing the camera exactly as before.
The frame was still full of plane.

Re-injected properly — `u_axis` negated, normal untouched — the plane vanished:
**0 of 30000 pixels**, from a test that requires more than a fiftieth of the
frame.

Both halves of that are worth keeping. The first injection is caught by
`the_normals_agree_with_the_winding` and *not* by the pixels; the second is
caught by both. That is the complementarity S3 claims, measured rather than
asserted: the arithmetic test sees a normal stream the renderer cannot report on,
and the pixel test sees a whole path the arithmetic cannot reach.

## What is deliberately absent

- **No `BufferGeometry`, and no attribute access.** That is the thesis, not an
  omission (S1). `Geometry` is exported for `instanceof` and is not constructible
  as anything useful on its own.
- **No `CircleGeometry`, `RingGeometry`, `CapsuleGeometry`, `TorusKnotGeometry`
  or the polyhedra.** Each would be another `build_*` and another prelude class
  against the same verb; six is what an agent reaches for and the seventh can be
  added the day something wants it.
- **A generated shape has no material of its own** beyond `PRIMITIVE_COLOR`, a
  light neutral grey. Orange — the built-in triangle's colour — reads as "the
  material is broken" to an agent looking at its own screenshot.
- **The 512 segment cap is stated in two places**, `MAX_PRIMITIVE_SEGMENTS` and
  the prelude's throw. The prose duplication is the established pattern here (the
  uniform budget is duplicated the same way), and the two are cross-referenced;
  a verb to read the limit across the binding would be a third place for it to
  drift.
