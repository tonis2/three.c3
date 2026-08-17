# event_loop.md — the window as an input device

Two documents in one, because they are the same subject at two stages.

**The first half is the record for M5c**, which is built: the mouse moves the
camera. It is written the way `m5a_stage.md` and `m5b_stage.md` are — what was
built, where it departed from `plan.md`, and what was actually run to believe
any of it, including the table of re-introduced bugs.

**The second half is the work that is not built**: a per-frame hook a script can
register, a keyboard an agent can bind actions to, and the smaller things either
of those makes worth doing. It is written to be picked up cold, so every task
names the file and the line it starts at and says what the hard part is, which
in almost every case is not the part that sounds hard.

---

# Part one — M5c, built

## The question this answers

A window that can only be moved by running a script is a screenshot with extra
steps. Every camera change went through `three.camera.orbit(...)`, which means
looking at a model from a different angle was a round trip through an agent, and
the person watching the window could do nothing at all.

```
three model.glb          drag to orbit, right-drag to pan, scroll to zoom
three --mcp              the same, while an agent is driving the scene
```

## What it turned out to need

**Almost nothing, because the frame loop already existed.** `src/main.c3:444-465`
has run `renderer.frame()` on every iteration since M3 — deliberately, so that a
window does not stop responding between tool calls — and `MeshPass` holds one
persistent `Scene` and one persistent `Camera` (`src/render/pass.c3:52-53`). The
window was already a live view of mutable state. Two things were missing and
neither was a loop:

1. **The input was being collected and thrown away.** `main.c3` called
   `window.getEvent()` and read exactly one key out of it, `ESCAPE`. `c3w` had
   already been handing back a latched key/button map, `getMousePos()`,
   `get_scroll()`, `get_text()`, `get_scale()` and `set_cursor()` the whole time.
2. **Nothing turned a cursor into a camera.** Which is `scene/controls.c3`, and
   it is short because the camera was already a turntable: orbit *is* yaw, pitch
   and distance. There is no new camera model here and there was never going to
   be one.

## The steps

### S1 — the camera keeps its own invariants (`src/scene/camera.c3`)

Four things moved onto `Camera`, all of them previously either absent or living
in `js_camera_set`:

- `clamp_angles` — pitch to ±89, yaw wrapped into [-180, 180).
- `derive_planes` — near and far from the distance.
- `basis` — the right and up axes in world space.
- `world_per_point` — how much world one screen point covers, at the target.

**The near/far rule was already written down twice and is now written once.**
`js_camera_set` had its own copy; a drag that changed the distance without
re-deriving them would z-fight after a zoom and not before, which is a bug that
only shows up once somebody has been using the thing for a while.
`frame_bounds` deliberately does *not* call `derive_planes` and says so: it
knows the model's radius, so it can do better than a multiple of the distance.

**The pitch clamp fixed a live NaN.** At exactly 90 degrees the eye sits on the
up axis, `look_at`'s cross product is zero, and every entry of the view matrix
is NaN. A script could reach that through `three.camera.orbit(0, 90)` before
this, and the symptom is an empty frame — no error, no validation message, no
log line. `plan.md` §7 is about exactly this class, so the clamp is applied
where angles are *written*, by the script path and the drag path alike.

### S2 — the mouse, as arithmetic (`src/scene/controls.c3`)

`PointerState` is two flags and four numbers. `Controls.apply` folds one frame
of it into a `Camera` and answers whether anything moved.

**Nothing in the file knows what a window is**, and that is the only reason any
of it is under test. The suite is headless; a control scheme that could only be
exercised by a person dragging a mouse would be verified by nobody, ever, and
would drift the first time someone touched it. The `c3w` half — the two lines
that read `is_pressed(LEFT_MOUSE)` and `getMousePos()` — lives in `main.c3` with
the rest of the window handling and is about fifteen lines.

Three decisions worth keeping:

- **Zoom is exponential.** A fixed step per notch is unusable at both ends of
  the same scene at once: it crawls when the camera is far away and slams
  through the model when it is close, because what a person means by "closer" is
  a fraction of where they already are.
- **Pan is exact, not tuned.** `world_per_point` carries the field-of-view term,
  so the point under the cursor when the drag started is the point under the
  cursor for the whole drag, at any distance and any fov. Drop the term and pan
  still works, still feels smooth and is still in the right direction — it just
  drifts, by an amount that gets tuned around with a magic constant instead of
  fixed.
- **Orbit wins when both buttons are down.** Both gestures read the same delta,
  so applying both moves the camera twice for one hand movement. Which one wins
  is arbitrary; that one does, predictably, is not.

### S3 — one call per frame (`src/main.c3:380`)

`drive_camera` is the whole platform half, and the units are its entire content.
`c3w` reports the cursor in logical points; `viewer.extent` is in device pixels,
which on a retina display is twice as many. Handing the raw extent to
`Controls.apply` halves the pan speed on exactly the machines this is developed
on, and it looks like a taste problem rather than a units bug. `get_scale()` is
the ratio, and it is the same number `c3w` sets the Metal layer's
`contentsScale` to.

It is called before `listener.pump`, so a drag and a script arriving in the same
iteration resolve in the order they happened.

## Where this departed from `plan.md`

- **`scene/controls.c3` and `test/controls_test.c3` are additions to the source
  tree**, both now listed. `scene/camera.c3` was already an addition, from M1.
- **`plan.md` §5 gained M5c.** The milestone list had no entry for input at all,
  because the window was specified as a viewer and nothing else (§1). It still
  is a viewer as far as *rendering* is concerned — the offscreen target is
  untouched, the swapchain still only blits — and what changed is that it now
  also reports where the mouse is.
- **`js_camera_set` now clamps.** It did not before, and a script could put the
  camera somewhere that renders nothing.

## Verification

    c3c build --trust=full                          clean
    c3c test --trust=full --test-noleak             172 passed, 0 failed
    c3c test --trust=full                           172 passed, leak-clean
    three --mcp 8808, windowed, idle 6s              zero pointer events
    three --mcp 8808, windowed, dragged              smooth stream, stops on release

The suite went from 160 at the end of M5b to **172**, all twelve in
`three_tests::controls`, none of them touching a device or a window.

**Every regression test claimed here was checked by re-introducing the bug it
catches.** Each injection was a pattern that matched exactly once, and both
files were restored from a copy and checksummed afterwards.

| bug injected | test that caught it | result |
|---|---|---|
| orbit yaw sign flipped | `the_scene_turns_with_the_hand` | caught |
| orbit pitch sign flipped | `the_scene_turns_with_the_hand` | caught |
| the drag anchor is used on the press frame | `pressing_a_button_does_not_move_the_camera` | caught |
| the drag anchor is used on the press frame | `a_second_press_does_not_replay_the_gap` | caught |
| the release gate removed | `a_button_already_down_is_not_a_drag_until_it_is_released` | caught |
| a stuck latch is never forgiven | `a_button_already_down_is_not_a_drag_until_it_is_released` | caught |
| the pitch clamp removed from orbit | `the_eye_cannot_reach_the_pole` | caught |
| the field-of-view term dropped from `world_per_point` | `a_pan_tracks_the_cursor_point_for_point` | caught |
| zoom made a fixed step per notch | `zoom_is_a_fraction_of_where_the_eye_already_is` | caught |
| the minimum distance removed | `zoom_cannot_reach_the_target` | caught |
| the planes are not re-derived after a move | `the_planes_follow_the_distance` | caught |
| the yaw wrap removed | `yaw_does_not_wander_off` | caught |
| the zero-viewport guard removed | `a_pan_with_no_viewport_yet_is_skipped` | caught |
| an idle frame reports movement | `an_idle_pointer_changes_nothing` | caught |

### The two mechanisms that hid each other

The first version of `Controls` had two defences against the same bug: the
`dragging && self.dragging` guard, *and* an anchor kept current on every frame
including button-free ones. Both were commented as load-bearing. Neither
injection could be caught, because removing either one left the other doing the
job — and the pair passed every test while being, between them, one mechanism
too many.

The unconditional anchor update was removed. It is not that it was wrong; it is
that it made the guard *unnecessary* rather than merely redundant, and a second
mechanism whose only observable effect is to hide the failure of the first is a
line no test can ever motivate. `plan.md` §7's rule — re-introduce every bug a
regression test claims to catch — is what surfaced it, and it surfaced a design
problem rather than a test problem, which is the second time that has happened.

### The bug no headless test could have found

The first windowed run had the scene turning by itself with nobody touching the
mouse. Instrumenting `drive_camera` showed `orbit=true` on every single frame,
with the cursor stationary at y=746 — *outside* a 720-point content area — from
the moment the window opened.

`is_pressed(LEFT_MOUSE)` is a latch: set by a mouse-down, cleared by the
matching mouse-up. **AppKit runs an event loop of its own while a window is
being dragged by its title bar, and the release never reaches
`nextEventMatchingMask`.** So the flag stays set for the rest of the session,
and from then on every stray cursor movement across the window is read as a drag
with no button held.

`Controls` now refuses to believe a held button until it has seen one
button-free frame. That costs nothing when the mouse is behaving — the loop
renders hundreds of them before anyone reaches the window — and it makes a stuck
latch heal at the user's next real click rather than lasting until the process
is restarted. Both halves are under test, the recovery half being the important
one: controls that are dead for the rest of the session would be a worse bug
than the one being fixed.

**The lesson is about where the seam goes.** The pure/platform split is what
made twelve tests possible, and it is also exactly what made this invisible to
them: the fault was in what the window *reported*, not in what was done with it.
Everything on the far side of that seam has to be checked by running it. Six
seconds of a windowed process printing nothing is a real test result and it is
the only one that could have produced this.

## What is deliberately absent

- **No touch or trackpad gestures.** `c3w` reports `get_scroll_precise()`, so a
  two-finger drag is already distinguishable from a wheel, and pinch-to-zoom
  would be a `MAGNIFY` event. Neither is wired up.
- **No inertia or smoothing.** The camera follows the cursor exactly. Damping is
  a per-frame decay, which means it wants the loop from part two.
- **No cursor feedback.** `Window.set_cursor` exists and a closed hand during a
  drag would be the obvious use.
- **No content-rect gating.** A drag whose cursor leaves the window keeps
  orbiting, which is what a person expects. A drag that *starts* outside is
  prevented by the release gate rather than by a bounds check.

---

# Part two — what is left

Ordered by what unlocks what. T1 is the one everything else is easier after.

## T1 — a per-frame hook a script can register

The API is Three.js's own name for it, on the renderer:

```js
three.setAnimationLoop((elapsedMs) => {
  cube.rotation.y += 0.01;
});
three.setAnimationLoop(null);   // stop
```

**The difficulty is not the loop.** The loop exists. Every difficulty is in the
runtime, and none of them is visible from the JavaScript side:

1. **It must not go through `JsRuntime.run`** (`src/js/runtime.c3:222`). That
   call clears `log`, `value` and `error` and starts a fresh GPU validation
   capture (`runtime.c3:230`) — per frame it would erase the result an agent is
   about to read — and it wraps the source in `(async()=>{})()`, allocating a
   promise sixty times a second. This needs a second entry point that calls a
   retained `qjs::Value` directly.

2. **The budget is wrong by three orders of magnitude.** `JS_BUDGET_MS` is 5000
   (`runtime.c3:74`). As a per-frame budget that is a five-second hitch, and
   since the MCP handlers run on the loop's own thread (`main.c3:457`, inside the same loop) a wedged
   callback wedges the server with it. The interrupt machinery is already there
   — `started`, `budget_ns` (`runtime.c3:153`), `on_interrupt` — so a tick just
   stamps a few milliseconds instead.

   **The policy question is the real one:** what happens on overrun? Retrying
   silently every frame gives an unusable window and nothing to diagnose it
   with. The proposal is to disable the callback, keep the error, and report it
   on the next `run_script`.

3. **Per-frame `console.log` currently has nowhere to go.** `run` clears the log
   buffer at the top of every call, so a callback that logs either floods or
   vanishes. Without a bounded ring that the next tool result drains, animation
   is undebuggable — which for an agent-driven project is the difference between
   a feature and a trap. **This is the task most likely to be skipped and most
   likely to be regretted.**

4. **Microtasks.** The callback should be called synchronously and any promise
   it creates drained under a small job cap, not `JS_MAX_JOBS`'s 100 000
   (`runtime.c3:79`). An `async` frame callback is probably worth refusing
   outright, with a message saying so.

5. **Testability.** The loop only runs when there is a window
   (`main.c3:459-465`, the `window != null` arm) and the suite is headless. The tick has to be drivable
   directly from a test — N ticks, then assert on the scene — or none of this
   gets a regression test, which is not how the rest of this codebase is built.

6. **Determinism gets a caveat.** `three.render()` and the `screenshot` tool
   stop being repeatable once a loop is mutating the scene. That is inherent,
   but it belongs in `prelude.js`'s `differences` list, and
   `setAnimationLoop(null)` has to genuinely stop the clock so a screenshot can
   be taken of a known state.

**Not a `requestAnimationFrame`.** Three.js has no frame loop in core either —
`rAF` is the browser's. Matching `WebGLRenderer.setAnimationLoop` keeps the one
name that is actually Three.js's.

## T2 — the keyboard, and actions bound to it

```js
three.onKeyDown('space', () => { ... });      // edge
three.input.isDown('w');                       // level
```

**Two channels, because the two uses are different.** Movement wants level state
polled inside the frame callback; an action wants the edge, once. `c3w`'s map is
latched level state, so edges are a one-frame diff against the previous map —
cheap, and it has to live beside the map rather than in JS.

Depends on T1 for anything continuous, which is most of it.

**This is not a Three.js API and must be documented as an invention.** Three.js
has no input layer at all: `OrbitControls` is `examples/jsm` and takes a DOM
element, and key handling is the browser's `addEventListener`. It goes in
`prelude.js`'s `differences` list beside the hex-colour note.

Two sub-questions to settle:

- **Key naming.** `c3w`'s `EventKey` is an enum of X11 keycodes. The JS side
  should take strings — `'w'`, `'space'`, `'shift'`, `'arrowup'` — which means a
  name table somewhere, and it should be the same table `get_api_docs` lists.
- **Typed text is separate from keys.** `Window.get_text()` already accumulates
  UTF-8 per frame with the modifier chords and function-key range filtered out.
  A script that wants a text field wants that, not a key map.

## T3 — click to pick

`Scene.raycast` and `screen_ray` already exist (`src/scene/pick.c3:63` and
`:151`) and `scene.pick(x, y)` is already in the JS API. Clicking the window to
select is close to free once the mouse position is in hand, which it now is.

Two things to get right, neither of them the raycast:

- **`screen_ray` counts rows from the top** and says so in a comment; the
  pointer counts from the bottom on macOS. The flip is one line and it is
  invisible to any test that picks at the centre.
- **The scale.** `screen_ray` takes pixels, the pointer is in points. Same
  `get_scale()` as `drive_camera`.

A click must also be distinguishable from the end of an orbit drag — the usual
rule is a press and release within a few points and a short time.

## T4 — the smaller ones

- **Cursor feedback.** `Window.set_cursor(CLOSED_HAND)` while orbiting,
  `OPEN_HAND` over the window otherwise. macOS only; the other backends are
  no-op stubs, which is fine.
- **Damping.** A per-frame decay on the orbit velocity. Wants T1's tick, or at
  least a per-frame call, and wants a real time delta rather than a frame count.
- **Windows parity.** `lib/window.c3l/win32/main.c3:651-661` stubs `get_scroll`,
  `get_scroll_x`, `get_text` and `get_scale` to zero, so zoom, typed text and
  retina scaling are all dead there. Linux is complete. This is a change to
  `c3w`, which is a submodule, so it is somebody's decision rather than a task.
- **The stuck-latch fix at the source.** The release gate is a workaround in the
  right place, but the real answer is `+[NSEvent pressedMouseButtons]`, which
  reports the physically-held buttons independently of the event stream — one
  objc call, and it would let a stuck latch clear on the very next frame instead
  of at the next click. Also a `c3w` change, and also therefore a decision
  rather than a task.
- **Idle CPU.** The windowed loop renders continuously at whatever rate the
  swapchain allows, and `getEvent(wait: true)` plus `Window.wake` exist for an
  on-demand loop that sleeps in the kernel at 0%. Attractive, and it conflicts
  directly with T1: a scene with a frame callback is never idle. Worth deciding
  once T1 exists rather than before.

## Open questions

- **Does the frame callback fire headless?** `serve()` with no window has no
  frames at all (`main.c3:459-465`, the `window != null` arm). Firing it on a timer there would make
  `--headless --mcp` behave like the windowed one; not firing it makes the
  window a behavioural difference an agent cannot see. T1's item 5 needs an
  answer to this anyway, since the tests are headless.
- **Should a script be able to turn the mouse controls off?** A scene that binds
  its own drag behaviour would want to. `three.controls.enabled = false` is
  cheap, but it is one more piece of state a script can leave in a bad way, and
  the window becoming uncontrollable is a bad way.
- **Does the camera belong to the scene?** The camera survives
  `new three.Scene()` today, so a script that rebuilds the scene keeps whatever
  the user dragged it to. That is almost certainly right for a person watching
  the window and it is worth writing down before something changes it by
  accident.
