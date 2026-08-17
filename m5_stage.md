# M5 — tier 2 materials, and picking

The step-by-step record of what M5 builds, where it departs from `plan.md`, and
what was actually run to believe any of it. `base_stage.md` is the same document
for M0/M1, `m2_stage.md` for M2, `m3_stage.md` for M3 and `m4_stage.md` for M4.

**The done condition, from `plan.md` §5: an agent-written fragment shader renders
and a bad one throws a JS error carrying the Slang diagnostic — and
`scene.raycast()` is exposed to JS.** The second half is done. The first is not
started.

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

After the fix, the same row comparison over the wire disagrees on **0 of 160**
columns.

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
    c3c test --trust=full --test-noleak                  80 passed, 0 failed
    c3c test --trust=full                                80 passed, leak-clean
    three --mcp, run_script + screenshot over HTTP       picked row == drawn row

Eight of those are new: seven in `three_tests::js` and one in
`three_tests::scene`. The suite went from 72 to 80.

**Every regression test claimed here was checked by re-introducing the bug it
catches** (`plan.md` §7: an unexercised regression test is an assumption). Each
injection was applied by a script that asserts the patch matched before running
anything, and the file restored from a copy taken beforehand.

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

One row says something the table alone does not. **The first injection was too
weak on the first attempt**: handing back `{ ...o }` breaks identity and breaks
`name`, so two tests caught it — but `the_object_a_hit_returns_is_the_live_one`
passed, because a shallow spread still shares the live `Vector3` and writing
`hit.object.position.x` still moved the node. The injection was strengthened to
detach the position too, which is what a real rebuilt-from-the-handle binding
would do, and then both fail. The weak version passing is the useful part: it
says the identity check and the liveness check are testing different things
rather than the same thing twice.

## What is left in M5

- `scene/material.c3` and `ShaderMaterial` — the fragment-function surface over
  M4's reflection (`plan.md` §4, tier 2). Not started.
- Validation errors routed into the thrown JS exception (`plan.md` §4, "errors
  are the third tier of work"). Not started.
