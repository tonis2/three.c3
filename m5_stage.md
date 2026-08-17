# M5 — tier 2 materials, and picking

The step-by-step record of what M5 builds, where it departs from `plan.md`, and
what was actually run to believe any of it. `base_stage.md` is the same document
for M0/M1, `m2_stage.md` for M2, `m3_stage.md` for M3 and `m4_stage.md` for M4.

**The done condition, from `plan.md` §5: an agent-written fragment shader renders
and a bad one throws a JS error carrying the Slang diagnostic — and
`scene.raycast()` is exposed to JS.** Both halves are done.

```js
const mat = new three.ShaderMaterial({
  uniforms: { tint: [1, 0.5, 0.2], time: 0 },
  fragment: `float3 shade(Surface s) { return s.albedo * tint * (0.5 + 0.5 * sin(time)); }`
});
mesh.material = mat;
mat.uniforms.tint = [0, 1, 0];   // takes effect on the next render
```

That is `plan.md` §4's tier-2 example, compiling and rendering verbatim.

## The steps

### S1 — picking reaches JavaScript (`src/js/bind_scene.c3`, `src/js/prelude.js`)

`scene/pick.c3` has been built and tested since M2, where it earned its place as
the way the scene-math checks assert without a GPU. What was missing was the
binding, which is three host verbs and about a hundred lines of `prelude.js`:

```js
const hit = scene.pick(x, y);                    // what is under a pixel
const hit = scene.raycast(origin, direction);    // what a world ray meets
const { width, height } = three.renderSize();    // what pick() counts in
```

Both answer with `{ object, name, distance, point, normal }` or `null`.

**`object` is the object the script is holding, not a rebuilt copy of it.** That
is the whole reason to bind this rather than hand back an index — `hit.object
.position.set(...)` is the line an agent writes next, and it has to move the
thing that was hit. The lookup is a `traverse` rather than a table keyed by
handle: a table would have to be kept in step with every add, remove and
re-parent, and picking happens once per gesture rather than once per frame.

`name` rides along because a scene opened from the command line (`three
file.glb`) has nodes that no script ever built an object for. There `object` is
null, and without a name beside it the answer would be a dead end.

#### Three decisions, and what each one refuses

**Not a `Raycaster`.** Three.js's is `raycaster.setFromCamera(ndc, camera)` then
`intersectObjects(objects, recursive)`, answering with a sorted array of every
intersection. This picker answers with the closest drawable node in the whole
scene: an array would never hold more than one element, and the object filter
would be ignored. Wearing that name over those semantics is exactly the
half-match `plan.md` §4 says is worse than a new name — "the agent will not read
the docs for a name it recognizes". So the names are `pick` and `raycast`, the
divergence is the first line of `differences` in `getApiDocs()`, and a miss is
`null` rather than `[]` so that a script written from Three.js memory breaks
loudly on `hits.length` instead of quietly reading `false`.

**`pick` needs a device and `raycast` does not.** A world-space ray needs no GPU:
with nothing loaded there is nothing to hit and `null` is the truth rather than
an error. `pick` needs the extent of an image that does not exist without one, so
it says which piece is missing, in the same shape as `three.load`'s and
`three.render`'s messages. The pair is asserted together in
`picking_without_a_device_says_which_verb_needs_one`, because the interesting
claim is not that either works — it is that the difference between them is
deliberate.

**`renderSize` exists because `pick` takes pixels.** Nothing else in the JS API
had any way to ask how big the rendered image is; an agent driving over MCP
learns it from the `screenshot` reply, but a script running *inside* one
`run_script` call had to be told. `pick(width / 2, height / 2)` is the line it
was added for. It reports the offscreen target's extent, never a window's, which
`plan.md` §1's decision makes free rather than something to keep in step.

### S2 — the half-pixel (`src/scene/pick.c3`)

Found by driving the finished binding over the real MCP wire rather than by
reading it. The script casts a row of picks across a rendered image; the
screenshot from the same call is decoded and the same row read off the pixels.
They should be the same row.

    drawn : ......................####################.........#################......
    picked: .......................###################.........#################......
                                  ^

One column in a hundred and sixty, at the left edge of the left quad. The cause
is that `screen_ray` mapped pixel `x` to `x / width` — the pixel's **left edge**
— while the rasterizer decides coverage at the pixel's **centre**. So every pick
was biased half a pixel, always in the same direction.

Half a pixel is invisible except at an edge, and an edge is precisely where
picking is asked the hard question. It is a bias rather than noise, so no amount
of averaging removes it, and `plan.md`'s whole claim for this subsystem is that
"the ray goes where the picture goes". The fix is `(x + 0.5f) / width`.

**The test for it is not the pixel comparison.** Comparing picks against rendered
pixels only catches this when a triangle edge happens to fall in the right half
of a pixel — one column in a hundred and sixty, on one particular camera, which
is a coin flip dressed as a check. What pins it exactly is a round trip with no
rasterizer in it at all: cast a ray through pixel `(x, y)`, take a point on it,
project that point back through the same view-projection, and require it to land
at `(x + 0.5, y + 0.5)`.

    a ray through column 0 came back at 0.000006, expected 0.500000
      — the ray is not going through the pixel's centre

That is `a_pick_returns_to_the_middle_of_the_pixel_it_named`, and it fails on
every pixel it tries rather than on one in a hundred and sixty. It deliberately
avoids the exact centre of the image: at the middle of an even-sized target the
half cancels against the symmetry and a picker with no half at all passes.

**This paragraph was half wrong, and S8 is what it cost.** A round trip through
one mapping and back cannot see an error that the mapping and its inverse share —
which is exactly what a flipped Y is. Dropping the pixel comparison for it left
the picker able to answer the top of the image with what was drawn at the bottom,
for the rest of the milestone. Both tests are needed, and they are not the same
check written twice: the round trip pins the half-pixel, the pixels pin the
direction.

After the fix, the same row comparison over the wire disagrees on **0 of 160**
columns.

### S3 — a material is a fragment function (`shaders/material.slang`, `src/shader/material_source.c3`, `src/scene/material.c3`, `src/js/bind_shader.c3`)

The agent writes one function. three.c3 writes the module around it: the push
block, the descriptor binding, the vertex stage, the `Surface`, and a
`fragmentMain` that builds one and calls `shade`.

**The uniforms ride in the push block, and that is the decision the rest
followed from.** `mesh.slang` uses 60 of the 128 push bytes every device must
offer, so a material gets the remaining 68 — seventeen floats — appended after
`flags`. The alternative, a `ConstantBuffer` reached by descriptor, costs four
things that do not exist: reflection of uniform-block *members* (Slang reports a
constant buffer as one opaque binding, and the externs to walk inside it are not
declared in `lib/slang.c3l` at all), a `UNIFORM_BUFFER` usage bit, a pool sized
for it, and a per-frame-slot ring so a buffer the GPU may still be reading is
never overwritten. The push block costs none of them: reflection of push fields
by name and byte offset was built at M4 and is tested byte-for-byte.

What it refuses is a material with more than 68 bytes of uniforms — no textures
of its own, no arrays. That is the right trade for a tier whose whole claim is
"a fragment function, not a pipeline".

`check_push_block` had to be corrected to allow it. Its doc comment had always
said extra fields are fine, but the code capped the whole block at
`MeshPush::size` — 64 bytes, four of them spare. The cap exists so that
`cmdPushConstants` never pushes more than exists, and the real bound for that is
`PUSH_BUDGET`. The device's own limit is now checked against the *shader's*
reflected size rather than against the C3 struct, which is the check that
actually matters once the two can differ.

**A `Material` is a pipeline and a 128-byte block laid out as the push block
itself.** Not a list of values: setting a uniform writes at the offset Slang
assigned, and drawing is two memcpys with no per-uniform loop. Nothing in this
project computes a uniform offset — reflection reads them back, and
`-force-glsl-scalar-layout` is what makes them tight.

**`#line` is what makes the diagnostic usable**, and it was measured before it
was relied on. `#line 1 "material"` before the agent's body remaps Slang's
error to `material:3:23` with the agent's own source echoed; `#line <n>
"three.material"` after it restores the numbering. The filename must be a quoted
string literal — unquoted is a hard preprocessor error that kills the compile at
a line the agent cannot place. The uniform `#define`s are `#undef`ed after the
body for a reason that is not tidiness: a uniform legally named `a` would
otherwise rewrite `push.base_color.a` in the generated tail.

**The uniforms cross as two joined strings** — `("tint,time", "3,1")` — because
the QuickJS shim has no property enumeration at all. A host verb can read
`uniforms.tint` only if it already knows the word "tint". So `prelude.js` does
the enumerating, in the language that can, which is the same shape as
`setTransform` taking eleven scalars.

**`mat.uniforms` is a `Proxy`, and the first version was wrong.** It was a sealed
object with one accessor per declared name, on the reasoning that assigning an
undeclared property throws. It does — in strict mode. A script is not evaluated
in strict mode, so `mat.uniforms.tnit = [0, 1, 0]` silently did nothing, which
renders unchanged and reads like a shader bug. A `set` trap throws either way.
`an_undeclared_uniform_cannot_be_assigned` is what caught it.

### S4 — the bucket key gains a material, and pipelines bind per bucket (`src/scene/scene.c3`, `src/render/pass.c3`)

`plan.md` §"Source tree" predicted this consequence at M2: "the instance table's
bucket key is `(asset, mesh)` rather than `(mesh, material)`, and those are the
same key only for as long as this stays true."

It is now `(asset, mesh, material)` — **all three**, not the `(mesh, material)`
the plan literally wrote. `two_assets_sharing_an_image_upload_it_once` is why:
two byte-identical assets must stay four draws, and dropping `asset` from the key
collapses them into buckets that draw one asset's geometry with the other's
instances. The plan's wording would have been a silent corruption.

`bucket_key` already spends all 64 bits on two full-range uints, so the material
is carried beside the key rather than folded into it — narrowing either half to
make room would be a wrap rather than an error. Material leads the sort, so
consecutive buckets share a pipeline wherever they can and the new per-bucket
`cmdBindPipeline` is skipped when it has not changed.

**`unique_meshes` stopped being `buckets.len()`**, which is the divergence
`SceneStats`' own header predicted from M2 and reported the field separately for.
One mesh under three materials is three draws and one mesh.

**`create_slot` had to learn the new field.** It resets everything but `children`
and `generation`, and a field left out is a stale value from whoever held the
slot before — a new mesh silently drawing with a stranger's shader.

### S5 — two bugs found by tests that had to be strengthened first

**`three.render()` from a script drew nothing, and had since M3.** `MeshPass.ready`
gates `record` at its first line, and it was set by `MeshPass.load` /
`load_triangle` / `instance_grid` — the three **CLI** entry points. The JS path
calls `Assets.load` directly and never touched them, so every script that
rendered got a cleared frame. Nothing caught it because no JS test had ever
asserted on pixels: `mcp_test` checks that a PNG comes back, and a blank PNG
comes back fine.

`ready` now means what it guards against — the pass has a pipeline — and is set
in `init`. An empty scene was already handled a few lines later, where zero
buckets returns.

It was found by fixing a test of mine that was lying. `an_agent_written_shader_reaches_the_screen`
claimed in its doc comment that "the two frames are compared" and actually
asserted on `drawCalls`, which would have reported success for a material that
compiled and was never bound — precisely the failure it named. Made to count red
pixels, it failed instantly with zero.

**`plan.md`'s M0/M1 findings said push descriptors were broken on this driver.**
S6 below has that, and it is the most important thing in this document.

### S6 — descriptor sets are gone (`src/scene/asset.c3`, `src/gpu/pipeline.c3`, `src/render/pass.c3`)

There are no descriptor pools and no descriptor sets anywhere in the project. The
draw loop specifies the image and sampler inline with `cmdPushDescriptorSetKHR`
against the pipeline's own layout.

**What that bought is not the deleted code, it is the deleted coupling.**
`Assets.load` took a `MeshPipeline*` for the sole purpose of allocating sets
against its descriptor layout, so the asset table knew what a pipeline was and
every texture set was bound to one particular layout. Materials made that
actively uncomfortable: a set baked against the mesh pipeline's layout, bound
into a material pipeline's, is legal only by an argument about layout
compatibility that a future shader could quietly break. Now the question does not
arise, and `Assets` has no idea pipelines exist.

**This was built against a recorded warning, and the warning had to be
re-measured.** `plan.md`'s M0/M1 list said, as the stated reason the extension
was left out: "KosmicKrisp's `vkCmdPushDescriptorSetKHR` breaks subsequent draws
when `descriptorWriteCount > 0`". Carrying "we avoided it because it was broken"
forward on trust is the worst available option, so it was tested rather than
assumed stale.

Two checks, deliberately not one:

- `consecutive_push_descriptor_draws_each_keep_their_own_state` — four buckets
  that each push and draw, requiring four distinct colours. **This one is not
  sufficient on its own**, and saying so is the point: every push in it carries
  the same image, so a driver that ignored writes after the first would pass.
- `two_draws_with_different_textures_do_not_bleed` — the 1x1 white stand-in and a
  real texture, back to back, which is two genuinely different descriptors. Each
  half is rendered alone to learn what it looks like, then both together, and
  every pixel either painted must be unchanged by the other's presence. It
  asserts no colour constants.

Both pass. The defect does not reproduce. If it ever returns on another build the
second test names it precisely, and the fallback is the descriptor pool that is
in the history.

The extension is **required**, not probed-and-worked-around — `Gpu.limits.push_descriptor`
is queried from `maxPushDescriptors` and a device without it is refused by name,
exactly as `VK_KHR_dynamic_rendering` already was. `plan.md` §6's "query it and
fall back" was corrected to say what the code has always done.

### S7 — validation errors reach the script (`src/gpu/device.c3`, `src/js/runtime.c3`, `src/main.c3`)

`plan.md` §4: "a bad descriptor binding in Vulkan is a hang if you are unlucky.
Run the validation layers whenever a script is executing, install a debug
messenger that routes validation errors into the thrown JS exception". Until now
the messenger was `lib/vulkan.c3l`'s, which prints to stdout, never sets
`pUserData`, and is therefore unreachable from anything in this project.

An ERROR produced during a run now fails the run and carries the message; a
WARNING is logged without failing it. Two buffers rather than one tagged buffer,
because those are two different answers and one buffer would mean parsing our own
text back out. `--mcp` implies `--validate`, since that is where scripts run;
`--no-validate` wins regardless of argument order.

**The sink lives on `Gpu` rather than in a file-scope global**, and the reason is
specific to how this project is tested. `shader/compile.c3`'s `shared_session` is
the existing precedent for a process-wide global, but the C3 test runner swaps
`allocators::thread_allocator` per check — so a global `DString` allocated during
one test and appended to during the next is a cross-allocator use-after-free.
Allocating and freeing the sink inside `Gpu.init`/`Gpu.free` keeps it inside one
check.

**The callback returns `uint`, not `bool`.** The vendored `debugCallback` returns
a C3 `bool` — one byte — where the ABI wants a four-byte `VkBool32`, and a garbage
non-zero read tells the loader to abort the call being validated. On arm64 this
happens not to bite, but it is a real mismatch and it is not worth inheriting.
The `PFN_` cast around the by-value struct parameter *is* inherited, because that
defect is in the vendored typedef and is not ours to fix.

**`create_instance` did not fall back, and I had assumed it did.** It pushed
`VK_LAYER_KHRONOS_validation` unconditionally under `--validate`, which is
`ERROR_LAYER_NOT_PRESENT` — instance creation fails outright — on a machine with
no SDK installed. The layer and `VK_EXT_debug_utils` are now both gated on a
probe, and `Gpu.validation` means "validation is running" rather than "was asked
for".

Probing the entry point alone is *not* sufficient, which is worth writing down:
the loader resolves instance-extension commands whether or not the caller enabled
them, so a null `vkCreateDebugUtilsMessengerEXT` is conclusive and a non-null one
proves nothing.

**The error path is provoked genuinely, not synthetically.** A zero-size
`vkCreateBuffer` breaks `VUID-VkBufferCreateInfo-size-00912`, which the layer
checks *before* forwarding — a real message about a real device with nothing
invalid ever reaching the driver, which matters because §4's own example of a
validation bug is a hang and a test suite is the wrong place to find one. It is
raised from inside a running script through a host function the fixture installs
into the runtime's own context, so the whole chain is exercised: layer →
messenger → sink → `RunResult.error` → MCP reply. Only the WARNING and VERBOSE
cases use `vkSubmitDebugUtilsMessageEXT`, because real warnings are
driver-specific and a VERBOSE message cannot be provoked on demand at all.

**One injection found a hole rather than confirming a test.** Renaming the layer
to something not installed took the suite to 92 passed, 0 failed — six checks
silently returned at their `if (!gpu.validation)` guard. A green suite that has
quietly stopped asking anything is precisely `plan.md` §7's unexercised
regression test, and
`without_the_validation_layer_none_of_these_are_tests` now fails loudly with the
fix in its message instead.

**Three injections were not caught, and are recorded rather than papered over:**
reading the sink after `end_capture`, freeing the sink before destroying the
messenger, and the callback returning `bool`. All three are defensive orderings
whose failure needs a window nothing in this single-threaded project currently
opens. They are argued in doc comments and are not claimed as covered.

**The remaining window.** `content_with_frame` renders the reply's PNG *after*
`RunResult` has copied the log and error, so a validation message caused by that
render takes the printing path — it reaches stdout but is not attributed to the
run. Closing it would mean either capturing across the reply build, which
attributes the next frame to the script that just finished, or restructuring the
reply. Neither is worth it for a message the script did not cause. Everything the
script itself triggers is covered, including a `three.render()` inside it, because
`render_offscreen` waits on its fence before returning.

### S8 — the picker's Y ran the wrong way (found after the milestone closed)

Found by opening the window, serving MCP into it, and building a ring of 252
panels from a script: a pick aimed near the bottom of the ring kept naming a
panel from the top of it.

    scene.pick(640, 185)   the WHITE quad's pixels, world y = +2  ->  DOWN_red, y -2.01
    scene.pick(640, 535)   the RED quad's pixels,   world y = -2  ->  UP_white, y +2.02

`screen_ray` built NDC Y in the same direction as the row index:

    float ndc_y = ((y + 0.5f) / (float)height) * 2.0f - 1.0f;   // top row -> -1

with a comment arguing that the negative-height viewport in `gpu/target.c3`
removes the need for a flip. The premise is true and the conclusion is backwards:
`.y = height, .height = -height` is precisely what puts NDC +1 at the **top** row,
so a row index counted from the top runs from +1 down to −1 and the flip is
required. The renderer was never wrong — a quad at world y = +2 draws at the top
of the image — only the picker was.

**Every existing picking test passed with the bug in**, and the first injection
run failed exactly one check out of 127 — the new one. Why each of the others
missed it:

- `picking_the_centre_of_the_image_finds_what_is_centred` picks the centre, and
  the centre row is the one row a flip leaves alone.
- `picking_respects_an_instance_scale` and `picking_skips_what_is_invisible` use
  fixtures symmetric about that centre.
- `a_pick_returns_to_the_middle_of_the_pixel_it_named` — S2's round trip, written
  *because* the pixel comparison was called "a coin flip dressed as a check" —
  was blind to it for a reason worth spelling out. It projected a point on the
  ray back to a pixel with `back_y = (ndc_y * 0.5 + 0.5) * H`, which is the
  un-flipped mapping written out by hand: the same wrong assumption `screen_ray`
  held. The round trip therefore proved the two halves were inverses of each
  other, which they were, and said nothing about which way either pointed.

That second finding is the larger one. The correct back projection is not a
convention this suite gets to choose — it is Vulkan's viewport transform applied
to the viewport `gpu/target.c3` binds, `y_framebuffer = height * (1 - ndc_y) / 2`
— so the test now derives it and cites where it comes from. **With that
corrected, putting the flip back fails two checks rather than one**, and the
half-pixel bug S2 found is still caught by the round trip alone. The two are not
the same check written twice: the round trip pins the half-pixel, the pixels pin
the direction.

The new check takes its ground truth from the frame instead of from arithmetic:
render two quads either side of the target, scan the image for the topmost row
with anything drawn in it, and require a pick on that row to name the quad the
renderer put there. A picture is the one source a shared convention error cannot
corrupt. It is `a_pick_agrees_with_the_pixels_it_was_counted_in`.

## Where this departed from `plan.md`

**§5 and the source tree both say `scene.raycast()`, and the built name is
`scene.pick()` for the screen-space one.** `raycast` is kept for the world-space
ray, which is the shape the name describes. Splitting them was worth one extra
verb: overloading a single `raycast` on argument type would have made the error
message for a wrong call have to guess which of the two the caller meant.

**`three.renderSize()` is an addition to §4's surface**, forced by `pick` taking
pixels. It is one line of host code and it is what makes the primary verb usable
from inside a script.

## Verification

    c3c build --trust=full                               clean
    c3c test --trust=full --test-noleak                  124 passed, 0 failed
    c3c test --trust=full                                124 passed, leak-clean
    three --mcp, run_script + screenshot over HTTP       picked row == drawn row

The suite went from 72 at the end of M4 to **124**. Fifty-two new: seven for
picking and one for the half-pixel, eighteen in a new `three_tests::material`
for the source assembly, and the rest across `three_tests::js` and
`three_tests::scene` for materials, bucketing and push descriptors.

**Every regression test claimed here was checked by re-introducing the bug it
catches** (`plan.md` §7: an unexercised regression test is an assumption). Each
injection was applied by a script that asserts the patch matched exactly once
before running anything, and every file restored from a copy and checksummed
afterwards.

| bug injected | test that caught it | result |
|---|---|---|
| a hit hands back a detached rebuild | `a_hit_answers_with_the_object_the_script_built`, `the_object_a_hit_returns_is_the_live_one` | caught |
| a miss answers with an empty array | `a_miss_is_null_not_an_empty_list` | caught |
| the raycast ignores visibility | `picking_skips_what_is_invisible` | caught |
| `pick` ignores its coordinates | `picking_the_centre_of_the_image_finds_what_is_centred` | caught |
| `renderSize` reports height then width | `picking_the_centre_of_the_image_finds_what_is_centred` | caught |
| the zero-direction guard is removed | `a_ray_that_points_nowhere_says_so` | caught |
| `raycast` demands a device it does not need | `picking_without_a_device_says_which_verb_needs_one` | caught |
| the ray goes through the pixel's corner | `a_pick_returns_to_the_middle_of_the_pixel_it_named` | caught |
| `unique_meshes` is the bucket count again | `one_mesh_under_two_materials_is_two_draws_and_one_mesh` | caught |
| a recycled slot keeps the old material | `a_reused_slot_does_not_inherit_a_material` | caught |
| the bucket key ignores the material | `two_materials_over_one_mesh_are_two_draws` | caught |
| the material's uniform bytes are never pushed | `a_uniform_is_what_the_pixels_are` | caught |
| the pipeline bind is hoisted out of the loop | `two_materials_at_once_each_get_their_own_shader` | caught |
| rendering is gated on a load again | `an_agent_written_shader_reaches_the_screen` | caught |
| the Slang diagnostic is dropped by the cache | `a_bad_material_throws_with_the_line_the_agent_wrote` | caught |
| an unknown uniform name is accepted (both layers) | `an_undeclared_uniform_cannot_be_assigned` | caught |
| `ShaderMaterial` is left out of the docs | `the_docs_name_everything_the_api_exposes` | caught |

`three_tests::material` has fifteen more of its own, including the `#line`
directive dropped, the restore off by one, the `#undef` removed, and a newline
written as a C3 backtick raw string (`plan.md` §6's first trap).

S7 has nineteen more, including `pUserData` removed (caught by eight tests),
every message treated as an error, warnings that fail the run, `--mcp` no longer
implying validation, and `--no-validate` losing to an earlier `--validate`.
**Three of those nineteen were not caught** — reading the sink after
`end_capture`, freeing it before destroying the messenger, and the callback
returning `bool` instead of `uint`. Each is a defensive ordering whose failure
needs a window nothing single-threaded currently opens; they are argued in doc
comments and are explicitly not claimed as covered, which is the honest version
of a table that would otherwise read as nineteen for nineteen.

### Three injections missed on the first attempt, and each said something

**The pipeline bind, hoisted back out of the loop, changed nothing.** Both
materials in the test had *identical* fragment bodies and differed only in a
uniform, so `PipelineCache` correctly handed them one `VkPipeline` — binding once
was right, and the test could not tell. Rewritten with two different bodies, it
fails immediately. The lesson is narrow and worth keeping: a test for "two
materials" is not a test for "two pipelines" unless the sources differ.

**An unknown uniform name is refused twice, independently.** Disabling the
prelude's `set` trap left `Material.set_uniform` rejecting it from the host;
disabling the host check left the prelude rejecting it. Only removing both
reproduces the silent write. That is defence in depth rather than a redundant
check — the prelude names the declared uniforms in its message and the host
guards every other caller — but it means neither injection alone proves the test,
and the table row above is the combined one.

**The docs test could not fail.** It checked that each exported name appeared
somewhere in the dump, so renaming the entry to `_ShaderMaterialUndocumented`
still contained the string `ShaderMaterial`, and prose in `differences` counted
as documentation. Rewritten to require each class to have its own `classes` entry
and each public member to appear *in that entry*, it immediately found eleven
genuinely undocumented members — `toJSON` and `toString` on every class,
`Scene.getWorldPosition`, `Group.getObjectByName` — all of which are now
documented rather than suppressed.

## What is left in M5

Nothing in the done condition. §5's two clauses — an agent-written fragment
shader renders, and a bad one throws a JS error carrying the Slang diagnostic —
are both met, and `scene.raycast()` reached JS at S1.

The milestone's third clause — validation errors routed into the thrown JS
exception — is S7 above.

Two things this milestone deliberately did not take on, recorded so they are
decisions rather than omissions:

- **A material cannot have its own texture.** It has 68 push bytes and the
  descriptor binding the mesh pass owns. Push descriptors make per-material
  textures nearly free now — there is no pool to size and no set to allocate —
  so the work is a `MaterialTexture` on the JS side and a second binding in the
  template, not a new subsystem. That is the natural first extension of tier 2.
- **`PipelineCache` never evicts.** An agent iterating on a shader in a loop
  accumulates one `VkPipeline` per distinct source for the life of the process.
  The cache is keyed on source and cull mode and hands out borrowed pointers, so
  eviction needs the deferred-delete queue M6 wants anyway.

One defect found and left alone because it is outside this milestone and
pre-dates it: `SceneStats.culled_last_frame` is always zero. `Scene.stats()`
rebuilds the draw list with culling off, which sets `self.culled = 0` before the
field is read. The field's own docstring says "from the last `update`, not from
this call", and the code does not deliver that.
