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

**Nothing did, in the end.** The version of cui in `lib/` names `vk`, `c3w`,
`image` and `font` as dependencies rather than vendoring them, so the collision
this section was written to head off does not exist: three already had `c3w` and
`image`, `font.c3l` was the one genuinely new library, and adding `"cui"` and
`"font"` to `project.json` was the whole of the build integration. The empty
`lib/cui.c3l/lib/{image,font,window}.c3l` directories are unfetched submodules
that nothing in the manifest names. No manifest rewrite, no dropped files.

`src/vulkan/renderer.c3` — the standalone host, and the only file in cui that
imports `c3w` — still compiles as part of the dependency and is simply never
called. Dropping it from the manifest would save a little build time and is
worth doing upstream as a separate embedding target rather than as a local edit
here.

### What did stand in the way: a temp-allocator bug in cui

Worth recording, because it is invisible until an embedder has a `@pool()` and
then it is a wild pointer rather than an error. **A zeroed C3 `List` or `DString`
takes the *temp* allocator on its first write** — `list_ensure_capacity` maps a
null allocator to `tmem`. cui built every long-lived list that way: `Element`'s
`children` and `local_drawings`, the six lists on `Ui`, the `Canvas`'s three, the
font list, and the `CanvasPass`'s two texture lists.

That is harmless in cui's own reference renderer, whose temp arena is never
reset, and fatal here: three opens a `@pool()` in eighty places, including the
one around the script callback that sets the overlay. The tree was built inside
the pool, the pool gave the memory back, and the first layout walked a freed
`children` array.

Fixed in `lib/cui.c3l` by naming the heap at each of those init sites —
`init(mem, 0)` sets the allocator and allocates nothing, so the empty case still
costs nothing. The widgets were already correct (`TextField`, `FileBrowser` and
`ConfirmDialog` all call `init(mem)` in `mount`), which is what makes this an
oversight rather than a design. **It belongs upstream**: any engine embedding cui
hits it the moment it uses a scratch arena.

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
wherever it is supported, with nothing to add. What was missing was the guard,
and it is there now: `GpuLimits.shader_draw_parameters` beside the other three,
`NO_SHADER_DRAW_PARAMETERS` as the fourth hard require, and a line in
`Gpu.report`. A device that cannot do it fails at `Gpu.init` with a name rather
than in a shader.

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

This block — poll, drive the UI, drive the camera, decide the cursor — existed
**twice**: once in `run()`'s window loop and once in `live()`'s. It is now
`drive_window` in `main.c3`, called by both, answering with a `WindowFrame`.

One rule was not in the sketch and is needed: **a camera drag wins over a hover.**
The loop reads `wants_pointer && !controls.dragging`, because a drag that began
on the scene must not stop when the pointer passes over a panel on its way across
the window. cui's own `captured` is the mirror of that rule for a widget's drag,
and the two together are why neither gesture can be stolen mid-flight.

The pointer a script sees is *emptied* rather than moved when the interface has
it — `inside` false as well as the buttons — because `inside` is what stops
`MouseTracker` resolving a click, and clearing the buttons is what stops a press
over a panel from ever starting one.

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

- [x] `font.c3l` added, `shaderDrawParameters` guard in `GpuLimits`. **No
      manifest fix was needed** — see §2.
- [x] `Target.begin_overlay`.
- [x] A cui tree owned by `render/ui.c3` — an `Anchored` over one `Label` — and
      `three.debug.overlay` pointed at it. Proves the frame slot, the glyph
      atlas and the screenshot path in one go.

This alone closes `plan.md` §5's *"Draw the one-line overlay"*:
`three.debug.overlay(string)` already exists and reaches `console.log` and the
run's `debug` array only. Point it at a `Label` at the top of the tree and the
window shows text. §21's `systems.report()` HUD is then the same pixel with more
lines.

### Stage 2 — an owner

- [x] `src/render/ui.c3`, holding the `Ui*`, the `CanvasPass`, the font, the
      input adapter and the consume predicate. Hangs off `Renderer` beside
      `post`; `record_scene` gains the `upload` line and the three-line overlay
      block.

Two rules for that file:

- **Keep every `cui` import inside it.** `three::Camera` and
  `cui::camera::Camera` are different types with the same name, and `Cursor`
  collides too. One file that imports cui is one file that has to qualify.
- **Free before `gpu.free()`.** `CanvasPass` borrows the allocator. Its textures
  do *not* go through `pass.assets`, so the ordering dance `post.release_textures`
  needs does not apply here — but the `Ui` owns heap elements and the atlas, and
  both come down with it.

### Stage 3 — the JS binding

See §8 for the shape. In order, and the order was deliberate:

- [x] **`three.ui.draw(ops)`** — the seven `Painter` primitives as a screen-space
      op list, plus `three.ui.measure`. The smallest possible binding, and the
      most a game gets per line of it: crosshair, health bar, damage flash,
      minimap.
- [x] `three.ui.set(tree)` over the pure-data nodes — `column`, `row`, `stack`,
      `padding`, `grid`, `clip`, `anchored`, `scroll`, `rect`, `label`, and
      `draw` as a node.
- [x] Callbacks, adding `button`, `checkbox`, `slider`, `select`, `tree`,
      `textfield` — and `onClick`/`onHover` on `draw`.
- [x] `key`, reuse-on-match, and `three.ui.patch(key, props)`.

Left out on purpose, and the docs say so: `MenuBar`, `Dialog`, `FileBrowser` and
the `AreaHost` family. §8.3 has the reason for each.

Three things came out differently from the sketch above, and §8.4 and §8.6 are
rewritten to say what was built instead. Nothing else changed.

### Stage 4 — the consume flag, properly

- [x] The single-loop refactor — `drive_window` in `main.c3` — then
      `wants_pointer` / `wants_keys` wired into `drive_camera`, `ask_hover`, the
      cursor shape and `MouseTracker`.
- [ ] `plan.md` §5's *"A scene has no way to say which keys it binds"* becomes
      answerable now that the UI can display the list. Still open: it is a scene
      API question, not an interface one.

### Stage 5 — tests

- [x] `three_tests::ui`, seven cases. Two of them are the silence checks — one
      over a bare frame and one over a post chain, because with a chain running it
      is the tonemap that leaves `target.color` in `COLOR_ATTACHMENT_OPTIMAL` and
      `begin_overlay` barriers from that layout on both paths.
- [x] The pixel checks, and they are paired on purpose: *the line appeared* and
      *the frame under it survived* fail in opposite directions, and a test for
      either one alone passes on the other's bug — an overlay that clears first
      shows more text on a black frame.
- [x] The pointer cases, now that there are widgets to be over: a click reaching
      the second of two buttons rather than the first, a hovered widget taking
      the pointer and a bare frame not, a caption over the viewport staying
      transparent while `solid` blocks, a drag surviving the pointer leaving the
      widget, and a focused field taking the keyboard.
- [x] The binding, end to end: a tree written in JavaScript arriving as elements,
      a bad type refused by name, an async handler refused, `patch` by key,
      `measure`, and the reentrancy guard — a handler that calls `three.ui.set`
      is held and applied by `flush_ui`, checked in three parts because "it
      worked" and "it was deferred" are different claims.
- [x] The two leaks that would only show after an hour: a thousand patches of one
      label keeping one string, and a replaced draw list replacing rather than
      appending.

31 cases in all.

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

**The rule a script holds in its head is the one that was built:** *give anything
you type into, scroll, or open a key.*

- A snapshot node may carry `key`.
- On `set`, a node whose `key` matches a live node **of the same kind** keeps
  everything a rebuild would have destroyed, and only the fields the snapshot
  named are written.
- A node with no key is rebuilt freely. Stateless nodes never need one.
- `patch(key, props)` addresses the same names.

### What it actually does, and why not `with_id`

The sketch above was going to reuse the *element*. What `render/ui.c3` does
instead is rebuild the element and **carry the state across by key**: the
`TextField`'s text, the `Slider`'s value, the `Checkbox`'s tick, the `Scroll`'s
offset, the `Select`'s selection and whether its popup is open — and the keyboard
focus, which is the one that would have been missed. `UiNodeSpec`'s five `has_`
flags are what make "the snapshot did not mention this" different from "the
snapshot said zero", which is the whole of the contract above.

Element reuse would have meant surgery on a live tree: pulling a reused element
out of its old parent before the old root is released, moving its children into a
holding list so the recursion can claim from them by key, and releasing the
leftovers — with a dangling `Element*` as the failure mode if any of it is wrong.
Carrying the state is a switch over six widget types, and the observable
behaviour is the same. The kind must match, or a `slider` renamed into a
`checkbox` under one key would put a number in a tick box; there is a test for
exactly that.

Focus is the part worth calling out, because a rebuild loses it silently:
`Ui.release` hands `focused` to the parent, which is a container that reads no
keys — so without the carry-over, typing would stop dead the first time a HUD
called `set`.

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
call back into the app, and cui has no app type to name."* `ensure` provides the
`UiLayer*`; a widget callback receives the `Ui`, calls `inherit`, and gets back
here. Nothing is threaded through struct literals, and nothing in cui learns what
three is.

**But `inherit` does not say which button.** cui's callback aliases are
`fn void(Ui*)`, `fn void(Ui*, bool)`, `fn void(Ui*, float)` and so on — the `Ui`
and the value, and no element. Three ways out were on the table:

- **Trampolines.** A generated table of N distinct functions per signature, one
  per node index. Eight families times a hundred and twenty-eight slots of
  generated code, to recover one integer.
- **Wrapper widgets** that set a module-global around the inner widget's own
  dispatch. Works for five of the six, and fails for `Select`, whose options are
  built by its `build` hook — the wrapper's `on_mouse` is not on the stack when
  an option fires.
- **Ask the interactivity state**, which is what `ui_signal` does.

The third is the smallest and the only one with no special case. `process_input`
has just finished setting `captured`, `hovered` and `focused`, and every callback
fires from inside one of the three dispatches those describe: `captured` for
anything mid-gesture, `hovered` for a press (dispatched before the capture is
recorded), `focused` for a key. So the shim walks up from each in turn, looking
for the nearest element that is a node **of the kind that asked** — and the kind
is what makes a button inside a tree row find the button. `Select` needs nothing
extra: its option element chains up through the popup to the `Select` itself.

Callbacks run from inside `process_input`, which runs **before** the tree is
mutated and before `flush`. A JS handler that calls `three.ui.set` would mutate
the tree cui is mid-dispatch on — cui's own warning is that handlers may unmount
from their own subtree but must not restructure unrelated parts of it. So a `set`
arriving during a dispatch is **retained and held**, and `JsRuntime.flush_ui`
applies it the moment `UiLayer.feed` returns, which `drive_window` calls one line
later. A `patch` needs none of that: it writes a field and asks for paint.

### 8.7 Strings are borrowed

`Label.text`, `Button.text`, `Checkbox.label`, `Slider.label`, `Select.options`,
`Tree.rows` and `Menu`'s items are all *borrowed — must outlive the element*. A
JS string is transient and a `patch` replaces one every frame.

So `UiNode` owns the strings and copies at the boundary — `keep` for the ones a
widget's own fields borrow, `keep_listed` for the ones an array borrows, and they
are two lists because a `patch` that replaces a `select`'s options must free
exactly those and not the label the widget is still holding. Nothing below
`bind_ui.c3` ever hands a widget a pointer into QuickJS memory. This is the one
memory rule that fails quietly: a freed label reads as garbage glyphs or as
nothing, never as a crash.

Two shapes of leak fall out of that and both have a test. A `patch` that copied
would keep a string per call, which is a readout at sixty hertz and an hour of
play — so `retext` writes into one buffer per node and the old bytes are dead the
instant the widget is re-pointed at the new ones. And a replaced list has to
*replace*: `reset_list` frees what only that list was holding, the pushes refill
it, and `relist` re-points the widget once the list has stopped growing, which is
also why the array views are assigned at `commit_tree` and not at `push_node`.

---

## 9. Open questions

**Where does the font come from?** cui ships none — its own tests borrow
`lib/font.c3l/test/DejaVuSans.ttf`. `Ui.load_font_bytes` takes bytes and copies
them, so `$embed` of one default face is the clean answer. A path would put the
debug overlay behind the assets sandbox, which is the wrong dependency for the
one thing that has to work when nothing else does. A script loading *additional*
faces by path is a separate, later question, and that one does belong in the
sandbox.

**Gamma — answered.** The target is `R8G8B8A8_SRGB` and the hardware encodes on
write, so a colour handed to `three.ui` is **linear**, exactly like
`mesh.material.color` and for the same reason. That is the answer that makes the
interface agree with the scene it is drawn over: both write linear and both are
encoded by the same attachment. It is *not* CSS's convention — `0x808080` is a
brighter grey here than in a browser — and the docs say so under
`no-colour-management`, which is where a script already had to look. cui's own
palette is authored the same way, so the built-in widgets land as intended.

**Resolution.** The target is fixed at `--width`/`--height`, so `ui.resize` is a
startup call and the interface stretches with the picture. Acceptable now; it is
the same knob as §4's sharpness question and should be answered once, for both.

**Textures — still open, and deliberately not implied.** `CanvasPass.load_image` /
`load_pixels` hand out `cui::Texture` handles that are 1-based indices into *its
own* sampler array — a separate table from `pass.assets`. A script that wants a
scene texture in the UI cannot pass an `Assets` handle across. So there is no
`texture` field on a `rect` or on a draw op, and no JS spelling that suggests one
is coming: `UiOp` and `UiNodeSpec` carry no texture at all. Either the binding
copies or the two tables get unified, and `RectStyle.texture` is one field away
once that is decided.

**Styling stops at a theme.** cui's `CheckboxStyle`, `SliderStyle`,
`TextFieldStyle`, `TreeStyle` and `MenuStyle` are twenty or thirty fields
between them, and every one of them is data a snapshot could carry. What crossed
instead is six colours and two text fields — `color`, `accent`, `hoverColor`,
`pressColor`, `textColor`, `borderColor`, `font`, `textSize` — layered over each
widget's own default rather than replacing it, because those structs are
all-or-nothing and a zeroed one takes the default whole. That is enough to
restyle an interface and not enough to reproduce every design. Widening it is one
more field on `UiNodeSpec` per knob, which is why it was worth stopping
somewhere rather than deciding the whole surface up front.

**Does a script get its own fonts?** `Label.font` is a `FontId` from
`Ui.load_font`, so the snapshot can name a face per node — but only from faces
something has loaded. The embedded default (above) needs no path. A
`three.ui.font(path)` returning an id is the natural second step, and it is the
one part of the UI API that has to go through the assets sandbox.
