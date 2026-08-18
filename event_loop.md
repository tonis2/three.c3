# event_loop.md — the window as an input device, and the frame as a hook

One document at three stages of the same subject: making the scene move without
an agent in the loop.

**The first two parts are the record for M5c and M5d**, both built: the mouse
moves the camera, and a script can register a callback that runs every frame.
They are written the way `m5a_stage.md` and `m5b_stage.md` are — what was built,
where it departed from `plan.md`, and what was actually run to believe any of
it, including the tables of re-introduced bugs.

**The last part is the work that is not built**: a keyboard an agent can bind
actions to, clicking the window to select, and the smaller things the first two
made worth doing. It is written to be picked up cold, so every task names the
file and the line it starts at and says what the hard part is, which in almost
every case is not the part that sounds hard.

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

# Part two — M5d, built

## The question this answers

A scene that only changes when an agent says so is a slideshow. Every mutation
had to arrive as a whole tool call, which means the smallest possible animation
was a round trip per frame — and the person watching the window saw a still
image between them.

```js
three.setAnimationLoop((ms) => { cube.rotation.y = ms / 1000; });
three.setAnimationLoop(null);   // and the clock genuinely stops
```

## What it turned out to need

**The loop was never the missing part.** `main.c3` has rendered every iteration
since M3. What was missing was a second way *into* the engine, because the only
one that existed is built for the tool call and every one of its habits is wrong
per frame: `JsRuntime.run` clears `log`, `value` and `error`, starts a fresh GPU
validation capture, and wraps the source in `(async()=>{})()` to allocate a
promise sixty times a second for a function that already exists.

So `JsRuntime.tick` calls a retained `qjs::Value` directly. It shares exactly one
thing with `run` — the interrupt handler — and only because there is one of those
per context. Everything difficult below follows from that sharing, or from the
fact that a frame has nobody listening to it.

### S1 — the tick, and the four ways a callback stops

`src/js/frame_loop.c3`. A tick is a call, a thenable check, and a bounded
microtask drain. The interesting half is the failure policy, which is the same
for all four: **stop the callback, keep the reason, report it once.**

The alternative — call it again next frame — is what makes a feature a trap. It
throws sixty times a second into a log nobody drains, in a window that has
visibly stopped moving, and leaves the agent with a scene that does not animate
and no statement anywhere about why. The four are a throw, a budget overrun, a
returned promise, and `setAnimationLoop(null)`.

**Async is refused twice, at two different layers.** `prelude.js` rejects an
`AsyncFunction` at the line that registered it, because the way an async callback
fails reads as nothing happening at all: it returns immediately, does its work on
some later microtask, and the frame it was meant to be part of has been presented
by then. `tick` catches the other spelling — a plain function that happens to
return a promise — at the first frame. One catches the shape, one catches the
behaviour.

**The budget is borrowed, not replaced.** `on_interrupt` reads one field, so a
tick saves `budget_ns`, installs a tenth of a second, and puts it back. 100 ms is
chosen to sit in a gap: it cannot be reached by anything that is merely slow — a
callback taking that long has already made the window a slideshow, and killing it
for that would be the host overruling the author — and it bounds a
`while (true) {}` to a tenth of a second rather than the script's five.

### S2 — two logs

`run` clears the log at the top of every call, so a per-frame `console.log` would
either be erased unread or drown the next result. `js_console` now writes to
whichever log is open: `frame_log` while `in_frame`, and the run's otherwise.

**The frame log is a ring, and the oldest lines go**, because a loop that logs
every frame fills any buffer immediately and the state worth seeing is the state
it is in now. What was dropped is counted and said out loud, since a log that
silently begins in the middle will be read as the beginning. It is drained into
the next run under `[animation loop]` / `[script]` markers, which exist because
unlabelled, a callback's lines arrive above the script's own and read as the
script's own — an agent debugging what it just wrote would be reading output from
a function it registered ten calls ago.

A script that never animates sees no markers at all, and there is a check that
says so: this is the kind of addition that quietly changes every result in the
project.

### S3 — the frame block

`run_script` grew a `"frame"` block — `running`, `ticks` since the last call, and
`error` when there is one. It is the only window an agent has onto the loop:
nothing else reports a callback that has been quietly running, or quietly
stopped, since the last tool call. **Ticks count since the last call** rather than
in total, because "sixty frames since you last looked" is the question being
asked and a running total is the same number every time once it is large.

It is emitted only when there is something to say. A block on every result would
be noise on the overwhelming majority of scripts, and noise on every result is
how a field stops being read.

**`get_api_docs` passes `drain_frame: false`.** It is a `run` the server made up
rather than one the agent asked for, and it reads nothing but `value` — draining
there would silently eat the frame log and the one report of a stopped callback.

### S4 — headless ticks, paced

The open question from part one has an answer: **yes, and at 60 Hz.** A callback
that behaved differently under `--headless` would be a difference an agent cannot
see, since it has no window to look at and no way to ask whether there is one.
Pacing is what makes it the same difference rather than merely present — the
headless loop is bounded by a 4 ms sleep and would otherwise run a callback four
times for every frame a vsynced window gives it.

## Verification

	c3c build --trust=full              Program linked to executable './build/three'.
	c3c test --trust=full               PASSED: 192 passed, 0 failed, 0 skipped.
	c3c test --trust=full --test-noleak PASSED: 192 passed, 0 failed, 0 skipped.

Twenty new checks in `test/frame_test.c3`, 172 to 192, and both runs are the
suite entire rather than the new file. **The tick takes the time as an argument
rather than reading a clock**, which is what makes every one of them a statement
about the callback instead of about how fast the machine was — and it is the
whole reason a feature that only exists while a window is open has tests at all.

### Every bug the tests claim to catch, re-introduced

One at a time, each against the single check that names it, restoring from a
copy and comparing sha256 afterwards. All three files restored byte-identical.

| bug injected | test | result |
|---|---|---|
| a tick claims to have run with nothing registered | `a_runtime_with_no_callback_does_not_tick` | caught |
| the callback is not told the time | `the_callback_is_told_what_time_it_is` | caught |
| the frame budget is never installed | `an_endless_callback_is_stopped_by_the_frame_budget` | caught |
| the script budget is not given back | `the_frame_budget_is_not_the_script_budget` | caught |
| a throwing callback is retried next frame | `a_throwing_callback_is_stopped_and_says_why` | caught |
| a promise-returning callback is allowed | `a_callback_that_returns_a_promise_is_stopped` | caught |
| the microtasks the frame queued are left for later | `a_microtask_the_callback_made_settles_in_the_same_frame` | caught |
| the frame log grows without bound | `a_flood_of_logging_is_bounded_and_says_what_it_dropped` | caught |
| what was dropped is not counted | `a_flood_of_logging_is_bounded_and_says_what_it_dropped` | caught |
| the script half of the log is not marked | `what_a_frame_logged_arrives_with_the_next_run` | caught |
| null does not stop the loop | `null_stops_the_loop` | caught |
| a non-function is retained anyway | `a_non_function_is_refused_by_the_host_too` | caught |
| a frame's log goes into the run's | `what_a_frame_logged_arrives_with_the_next_run` | caught |
| the frame log is never drained | `what_a_frame_logged_arrives_with_the_next_run` | caught |
| a stopped callback is explained on every run from now on | `the_reason_reaches_exactly_one_run` | caught |
| the frame count never resets | `the_frame_count_comes_back_and_resets` | caught |
| the timeout message names the constant rather than the budget | `the_frame_budget_is_not_the_script_budget` | caught |
| an async callback is accepted | `an_async_callback_is_refused_at_registration` | caught |
| the context is closed before the callback is released | (the whole file) | caught — see below |

### The injection that escaped, and what it changed

**"The frame budget is never installed" was NOT CAUGHT on the first pass.** The
check asserted that the reason named 100 ms, and it did — because
`frame_timeout_message` read the constant `JS_FRAME_BUDGET_MS`. With the install
removed, the tick sat there for the script's whole five seconds and then
produced a sentence saying it had stopped after a tenth of one.

Two changes came out of it, and the second is the one worth keeping:

- The message now reads `budget_ns`, the budget actually in force. A number and
  the thing it names have to come from the same place, or the message is free to
  be wrong in exactly the case anybody reads it.
- **The check now reads a clock instead of the sentence.** `plan.md` §7's rule is
  to assert on the thing rather than on the flag, and the thing here is that the
  tick ended in a tenth of a second rather than five. Ten times the budget and
  five times under the failure, so it asserts which budget applied without
  asserting a rate.

This is a different fault from M5c's, and worth telling apart. M5c had two
mechanisms doing one job, each hiding the other's removal. Here there was one
mechanism and one *witness*, and the witness was independent of what it claimed
to be witnessing.

### The bug QuickJS caught, which no check would have

`JsRuntime.close` releases the retained callback **before** `js.close()`. Swapping
those two lines does not fail a check — it aborts the process:

	Assertion failed: (list_empty(&rt->gc_obj_list)), function JS_FreeRuntime, quickjs.c:2704

The engine's own leak assertion, which is a better test than any I would have
written, and the reason the ordering has a comment on it rather than being
obvious from the line.

### What running it live added

The M5c lesson was that everything on the far side of the pure/platform seam has
to be checked by running it, and `main.c3`'s wiring is on that side. A window on
port 8809, driven over HTTP:

- **A callback moved the camera and the window showed it**, at 1301 ticks in one
  two-second gap and 243 in the next — the frame block reporting and resetting
  each time.
- **`setAnimationLoop(null)` genuinely stops the clock.** Two reads a second
  apart both answered `-22.5613`, which is item 6's determinism requirement:
  a screenshot of a known state has to be possible.
- **A throwing callback came back with its stack**, once, in a run that was
  itself `ok: true` — the animation's failure is not the script's.
- **`() => { while (true) {} }` was stopped in one frame and the server kept
  answering**, which is the concern that made the budget worth having: the MCP
  handlers run on the loop's own thread.
- **A flood was bounded to 8 KB with "205 earlier lines dropped"**, newest kept.
- **Headless ticked 152 times in three seconds** — about 50 Hz, against the
  ~250 Hz the unpaced loop would have given.

## What is deliberately absent

- **No `three.animationLoop` getter.** Three.js has none either, and the `frame`
  block already answers the question from the side that can be trusted.
- **No second callback.** Registering replaces; a list of callbacks is a
  lifetime problem and a JavaScript array solves it inside one callback.
- **No fixed timestep, no interpolation.** The callback gets the elapsed
  milliseconds and decides for itself.
- **The camera is not touched by the tick.** A drag and a callback that both
  write it compose the way a drag and `three.camera.orbit(...)` already do: last
  writer wins, frame by frame.

---

# Part three — what is left

Ordered by what unlocks what.

## T2 — the keyboard, and actions bound to it

```js
three.onKeyDown('space', () => { ... });      // edge
three.input.isDown('w');                       // level
```

**Two channels, because the two uses are different.** Movement wants level state
polled inside the frame callback; an action wants the edge, once. `c3w`'s map is
latched level state, so edges are a one-frame diff against the previous map —
cheap, and it has to live beside the map rather than in JS.

**T1 is built, which is what this was waiting for.** Level state polled inside
the frame callback is the shape movement wants, and that callback now exists:
`three.input.isDown('w')` inside `setAnimationLoop` is the whole pattern.

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
- **Damping.** A per-frame decay on the orbit velocity. `drive_camera` is
  already called once a frame beside the tick, so what it wants now is the time
  delta rather than the call — `serve()` computes one for `tick` and does not
  hand it to `Controls`.
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
  on-demand loop that sleeps in the kernel at 0%. Now decidable, and the
  condition is already a field: a runtime with `frame_active` set is never idle
  and must not sleep; one without it can. The awkward half is that the MCP
  listener has to be able to wake the loop, which is `Window.wake` from the
  listener's thread — the one place in the program where those two threads would
  touch.

## Open questions

- **Should a script be able to turn the mouse controls off?** A scene that binds
  its own drag behaviour would want to. `three.controls.enabled = false` is
  cheap, but it is one more piece of state a script can leave in a bad way, and
  the window becoming uncontrollable is a bad way.
- **Does the camera belong to the scene?** The camera survives
  `new three.Scene()` today, so a script that rebuilds the scene keeps whatever
  the user dragged it to. That is almost certainly right for a person watching
  the window and it is worth writing down before something changes it by
  accident. **The animation callback survives it too**, and that one is decided
  and tested: the loop belongs to the host as Three.js's belongs to the
  renderer, so a rebuild does not silently lose the animation — what it loses is
  every handle the callback captured, and the stale-handle throw stops it with a
  sentence rather than leaving it running against nothing.
