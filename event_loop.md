# event_loop.md — the window as an input device, and the frame as a hook

One document at three stages of the same subject: making the scene move without
an agent in the loop.

**The first three parts are the record for M5c, M5d and M5e**, all built: the
mouse moves the camera, a script can register a callback that runs every frame,
and a script can read the keyboard and bind actions to it. They are written the
way `m5a_stage.md` and `m5b_stage.md` are — what was built, where it departed
from `plan.md`, and what was actually run to believe any of it, including the
tables of re-introduced bugs.

**The last part is the work that is not built**: clicking the window to select,
and the smaller things the first three made worth doing. It is written to be picked up cold, so every task names the
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

# Part three — M5e, built

## The question this answers

A window that a person can look at and drag, in a scene that moves on its own,
and no way for the person to *do* anything in it. The original ask was "the
player could use keyboard and JS scripts could bind some actions to them", and
that is two different requests wearing one word.

```js
three.input.isDown('w')                          // held — poll it in the frame
three.onKeyDown('e', () => door.open())          // pressed — once, told to you
```

## What it turned out to need

**Two channels, because holding and pressing are different questions.** A jump
bound to the level state fires sixty times a second and reads as the game being
broken rather than as the binding being wrong; a walk bound to the edge takes
one step per press. Neither substitutes for the other, and a script that has
only the first ends up writing a dispatcher — so it exists once here instead of
once per script.

`c3w` reports a **latch**: a map of what is down right now, which persists
across frames. Level state is a read of it. **An edge is a one-frame difference
against the previous read**, which has to be taken beside the latch, because it
is only meaningful once per frame and JavaScript has no way to know when a frame
happened.

### S1 — the bits and the table (`src/scene/input.c3`)

`KeyBits` is 256 bits indexed by `c3w::EventKey`'s ordinal, so an edge is
`down & ~previous` — thirty-two bytes and two words of work, against the pair of
hash maps the obvious version would have compared per key per frame.

**The names are the API.** `c3w::EventKey` is X11 keycodes, which is the right
identity for a host and the wrong one for a script, so `KEY_NAMES` maps the
browser's `KeyboardEvent.key`, lowercased, onto it: letters and digits are
themselves, punctuation is the character it prints, the rest are the browser's
words. `get_api_docs` lists that same table by calling into it, because two
lists would drift the first time one gained a key — and a documented key that
cannot be bound is worse than an undocumented one that can.

**An unknown name throws.** A typo that silently reports a key which is never
down is the worst failure available here: nothing is broken, nothing is logged,
and the symptom is a control that does nothing — indistinguishable from every
other reason a control might do nothing.

`read_events` is the only function in the file that knows what a window is, and
it is six lines. That is the same seam `controls.c3` uses, for the same reason.

### S2 — handlers on the frame (`src/js/bind_input.c3`)

`three.onKeyDown(key, fn)` is dispatched from `JsRuntime.tick`, before the
animation callback, under the same budget, into the same frame log, with the
same policy when one misbehaves. **There is no second mechanism**, which is the
whole design: everything M5d had to decide about failure was decided once.

Three things that are not obvious:

- **Keys go first.** A handler that moves something and a callback that draws
  the consequence in the same frame is what a person expects; the other order
  shows every keypress one frame late, which is not a bug anyone reports — it is
  a control scheme that feels slightly wrong.
- **One overrun does not take the frame with it.** The budget belongs to the
  frame, so once it is spent every later call would be interrupted on its first
  instruction and stopped *for good*, for a failure that is not its own. The
  rest of the frame is skipped instead, and the next one is clean because the
  handler that spent it is gone.
- **A frame's failures accumulate.** `frame_error` appends rather than replaces
  now that a frame has more than one thing that can fail in it, and the first
  failure is usually the one that explains the rest.

**One handler per key per edge**, replaced by binding again, removed by `null`,
thirty-two at a time. A list would be a lifetime problem — nothing hands back a
token to unregister with — and a script that wants two things on one key has a
JavaScript array.

### S3 — what is not named

- **No mouse buttons**, although the same latch carries them and it would be two
  rows. AppKit swallows the mouse-up that ends a title-bar drag — part one is
  about that — so a script polling `isDown('mouseleft')` would be told the button
  is held for the rest of the session. `Controls` has a release gate; a script
  would have nothing. Clicking belongs with T3, where it can be given one.
- **No numpad.** Sixteen rows, and every row is a line in a list an agent reads.
- **Escape stays the host's.** It closes the window whatever a script binds,
  which is worth saying out loud in the docs rather than discovering.

## Verification

	c3c build --trust=full              Program linked to executable './build/three'.
	c3c test --trust=full               PASSED: 221 passed, 0 failed, 0 skipped.
	c3c test --trust=full --test-noleak PASSED: 221 passed, 0 failed, 0 skipped.

Twenty-nine new checks in `test/input_test.c3`, 192 to 221, in two halves: the
table and the difference, which need no JavaScript at all, and what a script can
see of them. **They are worth separating** — a wrong edge and a wrong binding
fail identically from JavaScript, and only one of them is a bug in the diff.

### Every bug the tests claim to catch, re-introduced

One at a time, each against the single check that names it, restoring from a
copy and comparing sha256 afterwards. All four files restored byte-identical.

| bug injected | test | result |
|---|---|---|
| the press edge is the level state | `a_held_key_is_pressed_once` | caught |
| the release edge is the press edge | `letting_go_is_an_edge_too` | caught |
| the previous frame is never remembered | `a_held_key_is_pressed_once` | caught |
| a two-key name only answers for one of them | `shift_means_either_shift` | caught |
| names are compared case-sensitively | `names_are_case_insensitive` | caught |
| a name that starts with a real one matches it | `an_unknown_name_is_a_fault` | caught |
| a duplicate row shadows a different key | `no_two_names_are_the_same` | caught |
| a duplicate row shadows a different key | `every_name_in_the_table_resolves` | caught |
| the typed text is borrowed rather than copied | `the_typed_text_is_copied_and_not_borrowed` | caught |
| a stopped handler stays in the table | `a_throwing_handler_is_stopped_and_names_its_key` | caught |
| binding a key again adds a second handler | `binding_again_replaces_and_null_unbinds` | caught |
| the handler is not told which key it was | `a_handler_is_told_which_key_it_was` | caught |
| both edges fire on the press | `onkeyup_fires_on_the_other_edge` | caught |
| a full table drops the extras silently | `too_many_handlers_is_a_message` | caught |
| the frame's input is never taken | `a_script_can_ask_what_is_held` | caught |
| keys are not dispatched at all | `a_key_handler_fires_on_the_edge` | caught |
| keys are dispatched after the animation callback | `handlers_run_before_the_animation_callback` | caught |
| a handler alone is not enough to tick | `a_handler_runs_with_no_animation_callback` | caught |
| the animation callback is killed by someone else's overrun | `a_wedged_handler_does_not_stop_the_animation_callback` | caught |
| only the last failure of a frame is kept | `every_failure_in_a_frame_is_reported` | caught |
| an async key handler is accepted | `an_async_handler_is_refused_at_registration` | caught |
| the docs list their own idea of the keys | `the_docs_list_the_whole_table` | caught |

### The check that passed for the wrong reason

**"Both edges fire on the press" was NOT CAUGHT on the first pass.** The check
bound `onKeyDown` and `onKeyUp` to the same key, pressed it, released it, and
asserted the log read `["down", "up"]`. An implementation that fires *both*
handlers on the press produces exactly that: the order is right, and the order
was all that was being asserted.

It now reads the log after each frame — `["down"]`, then `["down", "up"]` —
which asserts *when* each fired rather than what order they ended up in. The
general shape is worth naming, because it is the third time in this document:
**a check that reads the end state can be satisfied by the wrong path to it.**

### What running it live added, including one thing no test would have

`osascript` can hold a real key down, which makes the whole path testable
without a person: a window on port 8809, driven over HTTP while System Events
typed at it.

- **`key down "w"` for half a second gave `down:w`, then 98 frames of
  `isDown('w')`, then `up:w`** — both edges, the level state between them, and
  the handler told which key it was.
- **Shift arrived at all**, which is not a given: macOS never sends modifiers as
  key up/down, only as `FLAGS_CHANGED`, and `c3w` translates that separately.
  `["shift", "shift+a", ...]` is a real chord read one frame at a time.
- **`JUMP` appears before `space` in the same result**, which is the dispatch
  order — handlers before the animation callback — observed in the real loop
  rather than in a test's tick.

**And the thing no test would have found:** the first attempt used
`keystroke "w"`, which presses and releases in the same instant. The typed text
arrived — `text:w` — and **no edge fired at all**. A press that begins and ends
inside one frame is invisible, because the latch is set and cleared before it is
ever sampled.

A person cannot type that fast; ~80 ms on a key is five frames at 60 Hz. But it
is real for synthetic input, for a key repeat that lands badly, and for any
frame that runs long. Fixing it means reading `c3w`'s event *queue* rather than
its map, and `Window.getEvent` returns only the map — so it is a change to the
submodule, and therefore somebody's decision rather than a task. It belongs
beside the `+[NSEvent pressedMouseButtons]` note below.

---

# Part four — what is left

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
- **Sub-frame key presses.** Measured above: a press and release inside one
  frame is invisible, because `c3w` hands back a latch rather than a queue.
  `Window.getEvent` returns only the map, so seeing it would mean the submodule
  exposing the events it already drains. A `c3w` change, and so a decision.
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
