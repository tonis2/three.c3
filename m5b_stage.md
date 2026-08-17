# M5b — per-copy colour and variant

The step-by-step record of what M5b builds, where it departs from `plan.md`, and
what was actually run to believe any of it. `base_stage.md` is the same document
for M0/M1, `m2_stage.md` through `m5_stage.md` for M2 to M5, and `m5a_stage.md`
for the parametric shapes.

**The question this answers, asked from outside:** if a hundred `BoxGeometry`s
are one draw call, how does a scene get any variety out of them? Before this the
only answer was a material per appearance, and a material is a pipeline and a
push block — bucket state, pushed once for the whole `vkCmdDrawIndexed`. So two
boxes in two colours were two draw calls, and the instancing that made the first
hundred free bought nothing the moment they had to look different.

```js
const scene = new three.Scene();
const box = new three.BoxGeometry(1, 1, 1);
for (let i = 0; i < 1000; i++) {
  const cube = new three.Mesh(box);
  cube.position.x = i;
  cube.color = [i / 1000, 0.4, 1 - i / 1000];   // free
  scene.add(cube);
}
return scene.stats();   // { drawCalls: 1, instances: 1000, ... }
```

Measured through the window at 4000 cubes, every one a different colour: **one
draw call.**

## The steps

### S1 — the instance record gains two fields (`src/scene/scene.c3`, `src/scene/node.c3`, `shaders/mesh.slang`, `shaders/material.slang`)

`Instance` goes from 128 bytes to 148: two `float4x4`, a `float4 color` and a
`uint variant`. `Node` carries the same two, `create_slot` resets them to white
and row zero — for `material`'s reason, so a recycled slot cannot hand a new node
the last one's colour — and `build_draw_list` copies them into the record beside
the world matrix.

**Why the instance array is the only place they could go.** Everything else that
decides how a draw looks is pushed once per bucket. The instance array is read by
`SV_InstanceID`, so it is the one channel where copies inside a single call may
disagree. That is the whole design, and it is why these two are *fields of the
record* rather than anything more general.

**Two named channels rather than an open attribute stream**, and that is a
refusal rather than an omission. A per-instance buffer a script could define the
layout of is vertex-adjacent data back in JavaScript's hands, which is what
`plan.md` §"What it is" exists to prevent. A colour and a row index cover what
actually varies per copy, and neither of them is geometry.

The 148 bytes are not padded to a multiple of 16. Under
`-force-glsl-scalar-layout` a struct's alignment is its largest *scalar*, which
is 4, so the array is tightly packed and `SV_InstanceID` indexes it with no
padding rule to get wrong — the same property the `float3` position stream has
relied on since M1. `$assert Instance::size == 148` in `gpu/pipeline.c3` is what
keeps the C3 struct and the two shaders from drifting apart silently.

`color` multiplies albedo in **both** shaders, which is what makes
`mesh.color = [1, 0, 0]` work with no material at all — and it is folded into
`s.albedo` before `shade()` runs, so a body written as
`return s.albedo * lambert(s.normal)` respects it without knowing it exists.
`s.color` carries the raw value for a body that wants it as something else.

### S2 — a uniform may be a table (`src/shader/material_source.c3`, `src/scene/material.c3`)

`MaterialUniform` gains `rows`. One row is `float3 tint;` and four are
`float3 tint[4];`, and the generated module declares
`static const uint MATERIAL_ROWS = 4u` beside it.

**One material is one table, not a bag of arrays.** Every column has to have the
same number of rows, and a ragged one is refused by name in both layers. That is
not a workaround for the clamp — it is the model: the material has a table of N
rows, each uniform is a column, and `mesh.variant` says which row a copy reads.
It also makes the clamp exact, because there is one row count to clamp against
instead of one per column.

**The clamp is in the shader and is load-bearing.** `s.variant` is
`min(instance.variant, MATERIAL_ROWS - 1u)`. An out-of-range index into a
push-constant array is undefined behaviour: it reads whatever is next in the
block, which is another uniform's bytes interpreted as a colour, with no
validation message and nothing to attribute it to. A material with no table
declares one row, so the clamp is `min(x, 0)` and every copy reads row zero —
which is the truth, since there is no table for a variant to select from.

`Material.set_uniform` gained a row and a row count. The row count is *stated by
the caller* rather than derived from `field.size`, and that is what keeps the
width check exact: 32 reflected bytes are equally two `float4`s and four
`float2`s, so a caller with the shape wrong would otherwise write half a row and
be told nothing.

### S3 — the JavaScript (`src/js/prelude.js`, `src/js/bind_scene.c3`, `src/js/bind_shader.c3`)

`mesh.color` takes `[r, g, b]`, `[r, g, b, a]`, `{ r, g, b }` or Three.js's hex —
`0xff8800`. The hex is divided by 255 and **not** de-gamma'd: there is no colour
management anywhere in this project, the renderer writes what it is given, and
doing half of sRGB conversion here would be worse than doing none. It is
documented in `differences` rather than left to be discovered.

`mesh.variant` is an integer row index, replayed by `_materialize` like the name,
the transform and the material — an object is a detached description until it is
added, and a script that sets a colour and then adds must not lose it. Both are
replayed only when they are not the identity, so a scene of ten thousand
default-coloured meshes does not pay twenty thousand crossings to say "white, row
zero".

A table uniform hands back **a proxy, not the stored array**:
`mat.uniforms.palette[1] = [0, 1, 0]` writes row 1 to the device. Returning the
plain array would make that line mutate a JavaScript value nothing ever reads
again — it renders unchanged, with no error — which is the same silent no-op the
`uniforms` set trap was written for one level up, and
`a_table_row_can_be_written_on_its_own` is the check.

Neither channel lives on `Object3D`. A `Group` is not drawn, so a colour on one
would have nowhere to go, and inheriting it down the tree would contradict the
rule `material` already follows.

## Where this departed from `plan.md`

- **`plan.md` §2 said the instance record is a transform.** It now says what else
  it carries and why those two and no more.
- **The uniform budget is unchanged at 68 bytes**, so a table is four rows of four
  floats or five of three. That ceiling is real and is written down in
  §5 and in the docs rather than discovered: a table of hundreds needs a device
  buffer behind a BDA in the push block, which is a change to make when something
  wants it.
- **`Instance` is a wire format that three files share**, and it grew. The
  `$assert` and `the_material_push_block_keeps_the_mesh_contract` are what make a
  future change to one of them an error rather than a garbled frame.

## Verification

    c3c build --trust=full                               clean
    c3c test --trust=full --test-noleak                  160 passed, 0 failed
    c3c test --trust=full                                160 passed, leak-clean
    three --mcp 8808, windowed, 4000 cubes               1 draw call, 4000 colours
    three --mcp 8808, windowed, 3 shapes x 4 rows        3 draw calls, 1 material

The suite went from 148 at the end of M5a to **160**. Two in
`three_tests::scene`, four in `three_tests::material`, six in `three_tests::js`.

**Every regression test claimed here was checked by re-introducing the bug it
catches.** Each injection was a pattern that matched exactly once, and every file
was restored from a copy and checksummed afterwards.

| bug injected | test that caught it | result |
|---|---|---|
| the node's colour never reaches the instance record | `a_colour_per_copy_costs_no_draw_call`, `a_thousand_colours_are_still_one_draw_call` | caught |
| the variant never leaves the vertex stage | `a_variant_picks_a_row_of_the_material_table`, `a_table_row_can_be_written_on_its_own` | caught |
| the variant clamp removed | `a_variant_picks_a_row_of_the_material_table` | caught |
| every row of a table written at row 0 | `a_variant_picks_a_row_of_the_material_table`, `a_table_row_can_be_written_on_its_own` | caught |
| the colour is not replayed onto the node at add | `a_colour_set_before_the_add_survives_it`, `a_thousand_colours_are_still_one_draw_call` | caught |
| the variant is not replayed onto the node at add | `a_variant_picks_a_row_of_the_material_table` | caught |

### The test that passed for the wrong reason

`a_colour_set_before_the_add_survives_it` was written against the textured
fixture's `quad_left`, and asserted that the frame came back reddish. With the
colour replay deleted from `_materialize` it **still passed**: the fixture's quads
carry a warm base colour texture, so "reddish" was true whether or not the tint
had arrived.

Rewritten against a generated `BoxGeometry` — which has no texture, so the only
possible source of red is the instance colour — the same injection fails it at 0
red pixels. The lesson is `m5_stage.md`'s and this is the second time it has been
paid for: **a fixture that is already the colour you are testing for cannot tell
you the colour arrived.**

## What is deliberately absent

- **No per-instance texture.** Selecting an image per copy needs a descriptor
  array and a bindless-adjacent path; the variant selects uniforms, which is
  where the cheap win is.
- **No table larger than the push block.** See §"Where this departed".
- **No per-instance alpha blending.** `color.a` reaches `shade()` and the opaque
  pipeline does not blend with it. Transparency is a sort order and a pipeline
  state, not a channel, and pretending otherwise here would produce a value that
  looks like it should work.
- **Neither channel is inherited down a group**, matching `material`.
