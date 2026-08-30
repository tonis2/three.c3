# UI

The plan for binding `cui.c3l` as three.c3's interface layer. `plan.md` §5 is the
task list entry this expands; §21's HUD waits on the same pixel.

This is a design document, not a task list. Tasks that come out of it go to
`plan.md`.

---

## 1. What cui is, and why it is the right dependency

A retained-mode GPU UI library, written to be embedded rather than to host. Every
drawing is an SDF primitive — rounded rects, circles, ellipses, lines, arcs,
shadows, glyphs — and the whole interface reaches the screen in **one instanced
draw call**. Clipping and scrolling resolve per fragment, so nested rounded clips
cost nothing extra and never break the single draw.

It splits in three, and only the first two are ours:

| Layer | What it is | Do we take it |
| --- | --- | --- |
| `cui` | Element tree, `Widget` interface, `Canvas` (drawing list + transform palette + clip list), text and the glyph atlas. No Vulkan, no window. | Yes |
| `cui::vulkan::CanvasPass` | Draws a `Canvas` into a command buffer you supply. Borrows your device, allocator and queue. Two calls a frame. | Yes |
| `cui::vulkan::Renderer` | A standalone host — window, swapchain, input, frame loop — built on `CanvasPass`. | **No.** We are the host. |

`docs/embedding.md` inside `lib/cui.c3l` is written for exactly our case, and
`Renderer.record_scene` in `gpu/frame.c3` already anticipated it: *"with shadows,
a post chain and a UI layer, 'who writes `target.color`, and who closes it' has
two-by-two-by-N answers."* The UI layer is the third entry in a list that was
built to take one.

---

## 2. Build integration

Three things stand between `dependencies: [..., "cui"]` and a build.

**The vendored submodules are empty.** `lib/cui.c3l/lib/{image,font,window}.c3l`
are empty directories in this checkout, and cui's `manifest.json` lists
`lib/image.c3l/src/**`, `lib/font.c3l/src/**` and `lib/window.c3l/main.c3` as
sources. As it stands the dependency compiles nothing.

**Two of those three would collide anyway.** three already depends on `image` and
`c3w`. Compiling cui's copies alongside them is a duplicate-module error, not a
merge.

**`font` is genuinely new.** `src/render/text.c3` imports it and nothing in three
has it.

### The fix

Rewrite `lib/cui.c3l/manifest.json` down to the embedding subset:

```json
{
  "provides": "cui",
  "sources": [
    "src/core/**",
    "src/render/**",
    "src/widgets/**",
    "src/vulkan/canvas_pass.c3",
    "src/vulkan/render_state.c3"
  ]
}
```

That drops exactly two files, and both for the same reason — they belong to the
host half we are replacing:

- `src/vulkan/renderer.c3` — the standalone host. The only file in cui that
  imports `c3w`.
- `src/vulkan/vendored.c3` — loader and driver discovery. `create_instance` in
  `main.c3` already does this, and doing it twice is how a build ends up with two
  loaders.

`render_state.c3` stays and still needs `image`, which three has. Then add
`font.c3l` beside the other libraries and extend `project.json`:

```json
"dependencies": ["vk", "c3w", "gltf", "image", "collision",
                 "quickjs", "mcp", "slang", "ktx", "cui", "font"]
```

Upstream, the same split would be better expressed as a `cui` that ships the
embedding subset by default and a separate target for the reference host. Worth
raising there rather than carrying the local manifest edit forever.

### Device features

cui requires `bufferDeviceAddress`, `scalarBlockLayout`, `shaderDrawParameters`,
and calls `cmdPushDescriptorSetKHR`. The first two and push descriptors are
already queried *and hard-required* in `gpu/device.c3`:

```c3
if (!self.limits.buffer_device_address) return NO_BUFFER_DEVICE_ADDRESS~;
if (!self.limits.dynamic_rendering)     return NO_DYNAMIC_RENDERING~;
if (!self.limits.push_descriptor)       return NO_PUSH_DESCRIPTOR~;
```

`shaderDrawParameters` is a `VkPhysicalDeviceVulkan11Features` member, and `v11`
is queried and handed back to `deviceCreateInfo` unchanged — so it is *enabled*
wherever it is supported, with nothing to add. What is missing is the guard: it
belongs in `GpuLimits` next to the other three, so a device that cannot do it
fails at `Gpu.init` with a name rather than in a shader. `Gpu.report` gains a
line for the same reason.

The allocator already carries `MEMORY_ALLOCATE_DEVICE_ADDRESS_BIT`, which
`CanvasPass` needs for its three buffers.

The SPIR-V is prebuilt and `$embed`ed in `cui::shader_spirv`. No slang step, no
shader on disk, nothing added to the `shaders` target.

---

## 3. Where the UI sits in the frame

`Renderer.record_scene` in `gpu/frame.c3` is the one place a frame is described,
and it holds one invariant:

> Exactly one stage writes `target.color`, and the close happens exactly once,
> here.

The UI becomes the fourth item in that sequence:

```
prepare  →  shadow  →  scene (into target.color, or post.scene when posted)
         →  cmdEndRendering
         →  [post chain]  → writes target.color
         →  [UI overlay]  → writes target.color        ← new
         →  target.close
```

It has to be a **separate rendering**, not something appended to the scene's, for
three independent reasons:

- **After post.** An interface that gets bloomed, depth-of-fielded and tonemapped
  is not an interface. It is drawn onto the finished frame, not into it.
- **It must not clear.** `LOAD_OP_LOAD`, or it erases the frame it is drawn over.
- **No depth.** cui never tests or writes depth. Create the pass with
  `depth_format = FORMAT_UNDEFINED` and give the rendering no depth attachment.

### What `gpu/target.c3` gains

One function beside `begin_render_to` — `Target.begin_overlay(cmd)`:

- barrier `target.color` into `COLOR_ATTACHMENT_OPTIMAL` from its current layout
  (**not** `UNDEFINED` — `color_attachment_barrier` discards, and the frame we
  are drawing over is exactly what must survive),
- one colour attachment, `LOAD_OP_LOAD` / `STORE_OP_STORE`, no depth,
- `set_full_viewport(cmd, self.extent, flip_y: false)`.

**`flip_y` is false, and this is the one line to get wrong.** Every other pass in
three flips Y because it rasterises glTF geometry into Vulkan's clip space.
cui's `Camera.ui_view()` already bakes the UI orientation and the pixel-exact
scale into its view matrix; flipping again puts the interface upside down and
places every hit test correctly, which is the worst way for it to be broken.

### Where `upload` goes

`CanvasPass.upload` **must run outside a render pass** — it bakes glyphs, may grow
a buffer (idling the GPU) and may rebuild the pipeline when the texture count
changed. It also calls `ui.flush()` for us, bracketed by the two glyph-atlas
syncs it has to sit between; that ordering is the classic embedding bug and cui
deliberately does not leave it to the host.

So it goes at the **top** of `record_scene`, beside `pass.prepare` and before any
`begin_render`.

Its concurrency contract is *"wait for the frame `CANVAS_SLOTS` submissions back,
and call `upload` once per submitted frame"*, with `CANVAS_SLOTS = 2`. That is
exactly `MAX_FRAMES_IN_FLIGHT = 2` plus the fence wait that already opens
`frame()`, `capture()` and `render_offscreen()`. All three paths satisfy it
unchanged — which is the payoff for there being one recording function, and worth
saying in the comment so a fourth path cannot quietly break it.

`CanvasPass.adopt` exists for hosts whose allocator moves. `renderer.gpu.allocator`
does not move, so we do not need it.

---

## 4. Coordinates

The offscreen target is the UI's coordinate space, and this falls out for free.

`WindowView.cursor` in `scene/input.c3` already converts the platform's answer —
window units, bottom-left origin, whatever the backing scale is — into **image
pixels with a top-left origin**. That is cui's coordinate system exactly. The
comment there is already the argument for it: *"the picture in the window is the
offscreen target stretched onto the swapchain image, so a click maps to it by
fraction and never by the backing scale."*

So `ui.size` is `target.extent`, and `Cursor.x/y` goes into `InputFrame.mouse`
with no conversion.

### The alternative, and why not

Drawing the interface onto the **swapchain image**, after `record_blit`, would be
crisper: the target is pinned at `--width`/`--height` and stretched, so on a
retina display the UI is resampled along with the scene. Rejected, for three
reasons:

- `--screenshot` and the MCP `screenshot` tool would lose the UI entirely. An
  agent reading the frame would not see what a person sees.
- It needs a second pipeline built for the surface format, which changes on a
  format renegotiation.
- There is no swapchain at all headless, so the code path would be windowed-only
  and untested by the suite.

The sharpness complaint is real but it is a different question — *should the
offscreen target track the window size* — and answering that one fixes the scene
as well as the interface.

---

## 5. Input, and the consume flag

`plan.md` §5 calls this the hard part: *"A click on a button must not also shoot
the gun, and `three.controls.enabled` does not answer it."* cui answers it.

### The adapter

```c3
cui::InputFrame f = {
    .mouse    = { cursor.x, cursor.y },      // already image pixels, top-left
    .buttons  = { cursor.down, cursor.right, cursor.middle },  // LEFT, RIGHT, MIDDLE
    .scroll   = cursor.scroll,
    .scroll_x = cursor.scroll_x,
    .text     = typed_this_frame,
    .keys_down = held,
};
ui.process_input(f, dt_ms / 1000.0f);
```

`cui::MouseButton`'s ordinals are `LEFT, RIGHT, MIDDLE`, which is the order
`Cursor` already carries them in. `cui::Key` values are X11 keycodes chosen to
match `c3w::EventKey.code`, so held keys map with a cast.

### The predicate

Computed once, immediately after `process_input`, and read by everything else:

```c3
bool ui_has_pointer = ui.hovered != null || ui.captured != null;
bool ui_has_keys    = ui.focused  != null;
```

- `ui_has_pointer` gates `drive_camera` — no orbit while a slider is being
  dragged — **and** the `MouseState` a script sees through `MouseTracker.step`,
  so a click on a button does not also fire the gun. `captured` is the half that
  matters for drags: the pointer can leave the widget mid-gesture and the widget
  still owns it.
- `ui_has_keys` suppresses the key latch, so typing in a text field does not
  drive WASD.

cui's hit test picks the topmost rect containing the point *whether or not that
widget handles anything*, and `Label` already sets `ignores_pointer` so a caption
over the viewport does not become a dead zone. Anything we draw over the scene
that is decoration must do the same.

### One loop, not two

This block — poll, drive the UI, drive the camera, decide the cursor — currently
exists **twice**: once in `run()`'s window loop and once in `live()`'s. Adding a
fourth participant to both copies is how they start to disagree. Factor it into
one function before the UI goes in, not after.

### The cursor

cui resolves `ui.cursor` (a `cui::Cursor`) from the hovered element chain after
dispatch, so a handle that closes its hand on the press beginning a drag is right
on the same frame. Map it to `c3w::CursorShape` and feed the existing
`show_cursor` latch, which already avoids an objc call sixty times a second to
say the same thing. The UI's shape wins whenever `ui_has_pointer`; otherwise
`cursor_shape(...)` answers as it does today.

---

## 6. The idle loop

Both loops already carry a `quiet` flag and block in `getEvent(wait: quiet)`.
cui sets `ui.frame_requested` on **every** invalidation — `request_paint`,
`request_layout`, `set_transform`, mount, unmount — and a running animation
re-arms it every frame the way a Flutter `Ticker` does.

So it composes by adding one term:

```c3
quiet = presented && !moved && !ui.frame_requested;
```

and clearing the flag after reading it. The one gap cui names is waking for a
*non-input* reason — a timer, or a background thread calling `request_paint`
while the loop is asleep. `live()` already has this problem and solves it for the
MCP listener; the UI joins that solution rather than needing its own.

---

## 7. Stages

Ordered so each one is worth having on its own.

### Stage 1 — pixels

- [ ] Manifest fix, `font.c3l` added, `shaderDrawParameters` guard in `GpuLimits`.
- [ ] `Target.begin_overlay`.
- [ ] A hard-coded cui tree in `main.c3` — one `Label` — with no JS anywhere near
      it. Proves the frame slot, the input path and the build in one go.

This alone closes `plan.md` §5's *"Draw the one-line overlay"*:
`three.debug.overlay(string)` already exists and reaches `console.log` and the
run's `debug` array only. Point it at a `Label` at the top of the tree and the
window shows text. §21's `systems.report()` HUD is then the same pixel with more
lines.

### Stage 2 — an owner

- [ ] `src/render/ui.c3`, holding the `Ui*`, the `CanvasPass`, the font, the
      input adapter and the consume predicate. Hangs off `Renderer` beside
      `post`; `record_scene` gains three lines.

Two rules for that file:

- **Keep every `cui` import inside it.** `three::Camera` and
  `cui::camera::Camera` are different types with the same name, and `Cursor`
  collides too. One file that imports cui is one file that has to qualify.
- **Free before `gpu.free()`.** `CanvasPass` borrows the allocator. Its textures
  do *not* go through `pass.assets`, so the ordering dance `post.release_textures`
  needs does not apply here — but the `Ui` owns heap elements and the atlas, and
  both come down with it.

### Stage 3 — the JS binding

See §8 for the shape. In order, and the order is deliberate:

- [ ] **`three.ui.draw(ops)` first** — the seven `Painter` primitives as a
      screen-space op list, plus `three.ui.measure`. It is the smallest possible
      binding: no layout, no keys, no callbacks, no lifetimes, one switch over an
      op name. It is also the most a game gets per line of binding code —
      crosshair, health bar, damage flash, minimap, and `three.debug.overlay` is
      a one-op call against it.
- [ ] `three.ui.set(tree)` over the pure-data nodes — `column`, `row`, `stack`,
      `padding`, `grid`, `clip`, `anchored`, `rect`, `label`, and `draw` as a
      node. Still no callbacks and no state.
- [ ] Callbacks through `Ui.provide`, adding `button`, `checkbox`, `slider`,
      `select`, `tree` — and `onClick`/`onHover` on `draw`.
- [ ] `key` → cui id, reuse-on-match, and `three.ui.patch(key, props)`. This is
      what makes `textfield` and `scroll` usable, so it lands with them.

Left out on purpose, and say so in the docs: `MenuBar`, `Dialog`, `FileBrowser`
and the `AreaHost` family. §8.3 has the reason for each.

### Stage 4 — the consume flag, properly

- [ ] The single-loop refactor, then `ui_has_pointer` / `ui_has_keys` wired into
      `drive_camera` and `MouseTracker`.
- [ ] `plan.md` §5's *"A scene has no way to say which keys it binds"* becomes
      answerable once the UI can display the list.

### Stage 5 — tests

- [ ] A `three_tests` case that draws a UI frame and asserts it passes validation
      — that is the check that catches a wrong `LOAD_OP`, a missing barrier, or a
      second `close`.
- [ ] A case asserting drawn UI pixels appear in `capture()`. Because the
      interface lives in the offscreen target, `--screenshot` and the MCP
      screenshot tool get it for free, and *for free* is exactly the kind of claim
      that needs a test under it.

---

## 8. The JavaScript binding

### 8.1 Phase one: drawing directly

The primitives come first, before a single layout widget is bound. Three reasons,
and they all point the same way:

- It is the **smallest** binding — one switch over an op name. No layout, no
  keys, no callbacks, no lifetimes, no state to preserve across a rebuild.
- It is the **most useful per line** — a crosshair, a health bar, a damage flash
  and a minimap are all op lists, and none of them is a widget. So is
  `three.debug.overlay`, which is `plan.md` §5's open task and becomes a one-op
  call.
- It **proves the whole pipeline** end to end — the overlay rendering, the
  glyph atlas, the input coordinates, the screenshot path — with the least
  machinery standing between a bug and its cause.

`Painter` is the *entire* drawing surface of cui. Every built-in widget's `paint`
is some arrangement of these seven calls and nothing else:

| Op | Signature | Style |
| --- | --- | --- |
| `rect` | `pos`, `size` | `RectStyle` — color, border_color, border_width, border_radius {TL,TR,BR,BL}, texture |
| `circle` | `center`, `radius` | `CircleStyle` — color, border_color, border_width, texture |
| `ellipse` | `center`, `radii` | `CircleStyle` |
| `line` | `from`, `to`, `thickness`, `color` | — |
| `arc` | `center`, `radius`, `start`, `sweep`, `thickness`, `color` | — radians, 0 = +x, clockwise |
| `text` | `pos` (top-left of the line box), `str` | `TextStyle` — font, size, color |
| `rect_shadow` | `pos`, `size`, `blur`, `color`, `border_radius` | — |

Every argument is a number, a vector or a colour. There is nothing in that table
a JSON object cannot carry, which means a script handed these seven ops has
**exactly the drawing power a built-in widget has** — not a reduced version of it.
Every primitive is an antialiased SDF, and all of them land in the same single
instanced draw call as the rest of the interface.

Two ways in, because a game wants both:

**A screen-space layer, no layout involved.** The crosshair, the health bar, the
damage flash, the minimap — things positioned in pixels against the frame, not
against a parent:

```js
three.ui.draw([
  { op: "arc", center: [110, 110], radius: 90, start: -1.57, sweep: hp * 6.28,
    thickness: 10, color: [0.2, 0.9, 0.4, 1] },
  { op: "text", at: [92, 100], text: `${(hp * 100) | 0}%`, size: 18,
    color: [1, 1, 1, 1] },
  { op: "line", from: [630, 360], to: [650, 360], thickness: 2,
    color: [1, 1, 1, 0.7] },
]);
```

**A node inside the layout tree,** so drawing composes with everything else — it
clips, it scrolls, it sits in a `Column`, it gets hit-tested:

```js
{ type: "draw", size: [220, 220], ops: [ /* same op objects, element-local */ ] }
```

The two are the same widget; the screen-space verb is that node filling the root.
Coordinates are element-local in both cases, which for the screen-space layer
means frame pixels — the same top-left pixels `Cursor.x/y` already arrives in, so
a script positions a reticle at the cursor with no conversion.

Two things that come with it and should ship at the same time:

- **`three.ui.measure(text, {font, size}) → [w, h]`**. Drawing text by hand is
  useless without it — centring a readout in an arc is arithmetic on a measured
  width. `TextSystem.measure` is already public and is what `Painter.text`
  returns anyway.
- **An optional `transform` on a `draw` node.** `Element.set_transform` writes a
  slot in the palette that the shader applies, so a rotating compass or a scaled
  reticle costs one matrix rather than recomputed vertices. Clips travel with the
  transform (Flutter-consistent), so it composes with `clip` correctly.

**It is retained, and that is better than immediate mode here.** cui caches paint
output — a draw list that did not change costs nothing on the next frame, and
`three.ui.draw` only re-emits when called. An immediate-mode API would rebuild
the same list sixty times a second to show the same picture. So the guidance to a
script is the same as everywhere else in three: call it when something changed,
not every frame.

### 8.2 Phase two: the widgets

Drawing puts pixels anywhere, but it puts them at coordinates a script computed
itself. The widgets are what stop it doing arithmetic: a settings panel that
reflows, a list that scrolls, a row of buttons that stays centred when one of
them changes width.

Everything cui ships for that is reachable, and the reason is the same
data/code split phase one relies on — **all of cui's layout, all of its built-in
widgets and all of their styling are plain data.** Only new widget *types* are out
of reach (§8.3).

cui's layout widgets are pure data. Not "mostly data" — every field is a number,
an enum or a colour, and none of them holds a callback or owns a buffer:

| Widget | Fields |
| --- | --- |
| `Column` / `Row` | `gap`, `size`, `main_align` (START, CENTER, END, SPACE_BETWEEN), `cross_align` |
| `Stack` | `size` — children laid out loosely, placed by whoever holds them |
| `Padding` | `insets` {left, top, right, bottom} |
| `Grid` | `cell`, `gap_x`, `gap_y`, `size` — reflows by available width |
| `Clip` | `radii` {TL, TR, BR, BL}, clipping resolved per fragment |
| `Anchored` | `h`, `v`, `margin` — pins a child to a corner or edge of the space it fills |
| `Scroll` | `size`, `scroll_offset`, `step`, `radii`, `thumb_color` |
| `Rectangle` | `size`, `style` {color, border_color, border_width, border_radius, texture} |
| `Label` | `text`, `font`, `size`, `color` |

That is a whole layout language, and it goes into JSON with no loss:

```js
three.ui.set({
  type: "anchored", h: "start", v: "start", margin: [16, 16],
  child: {
    type: "column", gap: 8, cross: "start",
    children: [
      { key: "fps", type: "label", text: "60 fps", size: 14, color: [1, 1, 1, 1] },
      { type: "row", gap: 6, children: [
          { type: "button", text: "Reset", onClick: () => resetScene() },
          { type: "checkbox", label: "Wireframe", checked: wire,
            onChange: v => setWire(v) },
      ]},
      { type: "slider", label: "Damping", value: 0.9, max: 1, decimals: 2,
        suffix: "×", onChange: v => rig.damping = v },
    ],
  },
});
```

`gap`, `cross`, `main`, `margin`, `insets`, `radii` — a script writes the same
things a C3 struct literal writes, because there is nothing else in those structs
to write.

The interactive built-ins add exactly one thing: a function. Everything else is
still data.

| Widget | Data | Callbacks |
| --- | --- | --- |
| `Button` | `size`, `style`, `hover_style`, `press_style`, `text` | `onClick()` |
| `Checkbox` | `label`, `checked`, `style` | `onChange(checked)` |
| `Slider` | `label`, `suffix`, `value`, `min`, `max`, `step`, `curve`, `decimals`, `disabled` | `onChange(v)` every value the drag passes, `onCommit(v)` once on release |
| `Select` | `options[]`, `selected`, `width` | `onChange(index)` |
| `Tree` | `rows[{label, trailing, depth, expandable, expanded}]`, `selected` | `onSelect(row)`, `onToggle(row)` |
| `TextField` | `placeholder`, `style` | `onChange(text)`, `onSubmit(text)` |

Slider reporting twice is worth exposing rather than flattening: `onChange` is
what a live preview wants and `onCommit` is what a save wants, and a binding that
offers only one makes the other impossible.

Styling is data all the way down. `RectStyle`, `CheckboxStyle`, `SliderStyle`,
`TextFieldStyle`, `MenuStyle`, `TreeStyle`, `DialogStyle` are all colours, radii,
paddings and text sizes — so a script can restyle every widget, and a theme is an
object it spreads into nodes.

### 8.3 Where the ceiling actually is

With `draw` in, two things are left that a script cannot do — and both are
narrower than they first sound.

**It cannot implement `Widget`.** `paint`, `layout` and `on_mouse` are C3 function
pointers called from inside cui's passes. But `draw` covers `paint`, and a `draw`
node inside `Column`/`Row`/`Grid`/`Anchored` covers most of why anyone wanted
`layout`. What is genuinely out of reach is a **custom layout algorithm** — a
radial menu that places children on a circle, a text flow that wraps around a
shape. Compose the built-ins, or place by hand inside one `draw`.

**It cannot receive input on a `draw` node** beyond what the binding chooses to
forward. Worth deciding early rather than bolting on: an `onClick`/`onHover` pair
on the `draw` node, hit-tested against its rect like any other element, is enough
for a clickable minimap and costs one callback slot. Per-primitive hit testing is
not something cui does at all — hit testing is per element rect — so do not imply
it.

**And some widgets are not snapshot-shaped.** `MenuBar` items carry a `MenuQuery`
function pointer evaluated at paint time; `Dialog.body` is a `ViewBuilder` — a
*function* cui calls on every open, not a subtree. The `AreaHost` / `AreaPane` /
`AreaSplit` family borrows an `AreaLayout*` the app owns and mutates
structurally; it is a document with a lifetime, not a description. Leave all of
these out of the first binding. `Dialog` can come back later as a node whose
`body` is just more snapshot, with the binding supplying the `ViewBuilder` that
reads it.

### 8.4 The shape, and the state problem

Three shapes were on the table:

**(a) Retained handles.** `three.ui.column({gap: 8}, [...])` returns objects a
script keeps and mutates. Matches cui exactly, cheapest frames. Costs a large
binding surface and puts element lifetimes into JavaScript, where a disposed
handle is a runtime fault rather than a compile error.

**(b) Immediate mode.** The script calls `three.ui.label(...)` inside
`setAnimationLoop` and the binding diffs frame to frame. Familiar, no lifetimes.
Costs a diff engine, and spends every frame making a retained library pretend to
be an immediate one.

**(c) Declarative snapshot.** `three.ui.set(tree)` when the interface changes.
No lifetimes, no diff engine, invalidation explicit.

**Take (c)** — but it has one problem, and it must be solved in the API rather
than after it.

**Some widgets own state a rebuild destroys.** `TextField` creates its `DString`
in `mount` and holds a cursor byte-offset; `Scroll` holds `scroll_offset`;
`Select` and `Dialog` hold `open`; `FileBrowser` owns a directory and a listing.
A snapshot that rebuilds the tree wholesale resets the text under someone's
fingers and scrolls a list back to the top. That is not a rough edge, it is the
API being unusable for anything but a HUD.

**cui already has the answer, and it is a string.** `Element.with_id(String)`
names a node, and `find_id` / `get_widget_id` / `request_paint_id` /
`@modify_id` are the whole family built on it — cui's documented analogue of a
Flutter `GlobalKey`. So:

- A snapshot node may carry `key`. The binding stamps it as the cui id.
- On `set`, a node whose `key` matches a live element of the same type is
  **reused, not rebuilt** — its own state survives, and only the fields the
  snapshot names are written.
- A node with no key is rebuilt freely. Stateless nodes never need one.

That makes the rule a script can hold in its head: *give anything you type into,
scroll, or open a key.*

### 8.5 Two verbs, because a HUD updates every frame

`set` alone would mean rebuilding the tree sixty times a second to change one
number, which is the one thing a retained UI exists to avoid. So:

```js
three.ui.set(tree)                      // structure changed
three.ui.patch("fps", { text: "58 fps" })   // this value changed
```

`patch` is `find_id` plus a typed mutate plus `request_paint` — three lines
against machinery cui already ships. The binding remembers each key's node type
from the last `set`, which is what lets it pick the `$Type` for `@modify_id`.

This is also the graceful path to (a) later: `patch` *is* the retained API, keyed
by string instead of by handle, and adding real handles later would not change
the semantics of anything already written.

### 8.6 Callbacks

`Ui.provide` is cui's answer to exactly this, and it says so: *"a Button has to
call back into the app, and cui has no app type to name."* Provide a `JsRuntime*`
once at startup. A widget callback receives the `Ui`, calls `inherit`, and
dispatches to a JS function table by key. Nothing is threaded through struct
literals, and nothing in cui learns what three is.

Callbacks run from inside `process_input`, which runs **before** the tree is
mutated and before `flush`. A JS handler that calls `three.ui.set` therefore
mutates the tree cui is mid-dispatch on. Queue snapshot changes and apply them
after `process_input` returns — cui's own warning is that handlers may unmount
from their own subtree but must not restructure unrelated parts of the tree.

### 8.7 Strings are borrowed

`Label.text`, `Button.text`, `Checkbox.label`, `Slider.label`, `Select.options`,
`Tree.rows` and `Menu`'s items are all *borrowed — must outlive the element*. A
JS string is transient and a `patch` replaces one every frame.

So the binding owns a string table per key, frees the previous value only after
the element stops referencing it, and never hands a widget a pointer into
QuickJS memory. This is the one memory rule that fails quietly: a freed label
reads as garbage glyphs or as nothing, never as a crash.

---

## 9. Open questions

**Where does the font come from?** cui ships none — its own tests borrow
`lib/font.c3l/test/DejaVuSans.ttf`. `Ui.load_font_bytes` takes bytes and copies
them, so `$embed` of one default face is the clean answer. A path would put the
debug overlay behind the assets sandbox, which is the wrong dependency for the
one thing that has to work when nothing else does. A script loading *additional*
faces by path is a separate, later question, and that one does belong in the
sandbox.

**Gamma.** The target is `R8G8B8A8_SRGB` and the hardware encodes on write.
cui's reference host draws into a swapchain that is normally sRGB too, so the two
should agree — but `WHITE` and `BLACK` land correctly under any convention, so
they prove nothing. Check a mid-grey against a cui example before trusting it.

**Resolution.** The target is fixed at `--width`/`--height`, so `ui.resize` is a
startup call and the interface stretches with the picture. Acceptable now; it is
the same knob as §4's sharpness question and should be answered once, for both.

**Textures.** `CanvasPass.load_image` / `load_pixels` hand out `cui::Texture`
handles that are 1-based indices into *its own* sampler array — a separate table
from `pass.assets`. A script that wants a scene texture in the UI cannot pass an
`Assets` handle across. Either the binding copies, or the two tables get unified
later; do not let a JS API imply the second before it is true. `RectStyle.texture`
is otherwise pure data, so an image in the interface is one field away as soon as
the handle question is answered.

**Does a script get its own fonts?** `Label.font` is a `FontId` from
`Ui.load_font`, so the snapshot can name a face per node — but only from faces
something has loaded. The embedded default (above) needs no path. A
`three.ui.font(path)` returning an id is the natural second step, and it is the
one part of the UI API that has to go through the assets sandbox.
