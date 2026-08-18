# event_loop.md — the window as an input device, and the frame as a hook

One document at five stages of the same subject: making the scene move without
an agent in the loop.

**The first five parts are the record for M5c through M5g**, all built: the
mouse moves the camera, a script can register a callback that runs every frame,
a script can read the keyboard and bind actions to it, a click on the window
hands back what is under it, and the window has the manners a window is supposed
to have — it coasts, it dresses the cursor, and it sleeps at 0% CPU when nobody
is asking it for anything. They are written the way `m5a_stage.md` and
`m5b_stage.md` are — what was built, where it departed from `plan.md`, and what
was actually run to believe any of it, including the tables of re-introduced
bugs.

**Three of M5g's changes are in `c3w`**, which is a submodule: an event queue
beside the latch, the stuck-latch fix at its source, and the Windows backend's
missing reads. They were written down as somebody's decision rather than as
tasks, and the decision was made.

**The last part is what is not built**, which after M5g is small and mostly not
code.

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

# Part four — M5f, built

## The question this answers

The picker has existed since M2 and nobody could reach it with a mouse.
`scene.pick(x, y)` takes a pixel of the rendered image, and the only way to
produce one was for an agent to guess a number or to read it off a PNG it had
been handed — which is a fine way to write a test and no way at all to select
something in a window somebody is looking at.

```js
three.onClick((hit, x, y) => {
	if (hit) hit.object.color = 0xff8800;   // what was under the cursor
});
three.input.pointer                          // { x, y, inside, down, clicked }
```

## What it turned out to need

**Not the raycast.** `Scene.raycast` and `screen_ray` were already there, tested
against the rendered image down to the half-pixel, and `js_pick` already joined
them. The four lines that do the work were moved into `JsRuntime.pick_at` so the
click and `scene.pick` ask the identical question, and that was the whole of the
picking change.

What was actually missing is smaller than it sounds and got the two things it
does have wrong on the first try in the same way twice — **both conversions
between a window and an image are invisible to a check that picks at the
centre**:

1. **A window point is not an image pixel**, and the relationship is a fraction
   rather than a scale. This is the one `plan.md`'s own note about T3 got wrong.
2. **A window counts up and an image counts down**, which `screen_ray` documents
   about its own flip and which has to be undone here for the same reason.

And one thing that is not a conversion at all: a click has to be told apart from
the end of an orbit drag, because the same button does both.

## The steps

### S1 — the fraction, not the scale (`src/scene/input.c3`)

`WindowView.cursor` is the only place a window's units exist. It takes what
`c3w` reports and answers in image pixels:

```c3
float across = (at[0] * self.scale) / (float)self.width;
float up     = (at[1] * self.scale) / (float)self.height;
...
	.x = across * (float)self.image_width,
	.y = (1.0f - up) * (float)self.image_height,
```

**The tempting version is `pointer * get_scale()`, and it is what the plan said
to do.** It is also what `drive_camera` does — correctly, because `Controls`
only ever takes *differences* of the pointer and the unit cancels. It does not
cancel for a position, and there is no unit conversion that would work anyway,
because the two extents are not related by one:

- `Viewer.record_blit` copies the **whole** offscreen target onto the **whole**
  swapchain image. No letterbox, no crop. The picture in the window is the image
  stretched to fit it, whatever either size is.
- The target is fixed at `--width`/`--height` for the life of the process; the
  swapchain follows a live resize drag. So they diverge the first time anyone
  touches the window edge and stay diverged.
- On a retina display they start out differing by exactly the backing scale,
  which is why the wrong version looks right on the machine it was written on
  until the window is resized.

`plan.md` §1 — the window is a consumer and never the render target — is the
decision being paid for here, and paying for it is one line.

### S2 — the flip, in one place

`c3w`'s contract is Cocoa's: y grows upward from the bottom-left, and the Linux
backends convert to it rather than the other way round. `screen_ray` counts rows
from the top, because that is how an image is stored. `1.0f - up` is the whole
fix, and putting it in the conversion rather than at the call site is what keeps
everything downstream — the tracker, the handler, `scene.pick`, the PNG — in one
coordinate system.

### S3 — the edge is the gate (`MouseTracker.step`)

`controls.c3` documents a latch that sticks: AppKit runs its own event loop while
a window is dragged by its title bar and swallows the mouse-up, so the button
reads as held for the rest of the session. `Controls` waits for one button-free
frame before believing it.

**Nothing of the sort is here, and that is the design rather than an omission.**
A click requires a press *edge* — a frame where the button was not down and now
is — and a stuck latch produces no edges at all. So the failure mode is no
clicks rather than a click a frame, and it heals identically: the first real
click after a stuck latch is swallowed, because that click's release is what
finally clears the latch and there was no press to match it, and the one after
it works.

This is `controls.c3`'s own argument applied to itself. A release gate here
would be a second mechanism that hides the failure of the first, which is the
line that file says no test can ever motivate.

### S4 — a drag is not a click

Four pixels of travel and half a second, both measured in the *image* — the slop
exists to decide whether the person aimed somewhere else, and somewhere else is
a place in the picture. Both thresholds are deliberately generous in the
direction of not-a-click: a click that has to be repeated is better than an
object picked without being asked for, because the second one changes the scene
and the person then has to work out what it changed.

### S5 — the handler rides the frame (`src/js/bind_input.c3`)

Dispatched from `tick`, after the keys and before the animation callback, under
the frame's budget, into the frame's log, stopped the same way when it throws or
returns a promise. There is no new failure policy and there is not meant to be —
M5d decided all of it once.

One handler rather than a table: a click has no name to key a table by, so the
choice `onKey` has of which of thirty-two rows to replace does not exist. It is
`setAnimationLoop`'s shape.

**The raycast happens in the host**, which is the whole of what `onClick` buys
over `input.pointer` plus `scene.pick`. It costs a BVH walk per gesture — once
per click, not once per frame — and `prelude.js` turns the node index back into
the `Mesh` the script is holding by going through the live `Scene`. There is
exactly one of those at a time (`new three.Scene()` replaces it and the epoch
check says so), which is what makes "the current scene" a thing the host never
has to be told.

## Where this departed from `plan.md`

**`plan.md`'s note on T3 said to use `get_scale()`, and that is wrong.** It is
written down in Part five's history rather than quietly fixed, because the note
was right about there being a units problem and wrong about which one, and that
is the more useful thing to have recorded. The scale is *involved* — it is how
the pointer's unit and the extent's unit are made the same one — but it appears
inside the fraction and not as a multiplier.

Everything else went where §1 and §4 said it would: the pure part in
`scene/`, the surface in `js/`, the window in `main.c3` and nowhere else.

## Verification

	c3c build --trust=full              Program linked to executable './build/three'.
	c3c test --trust=full               PASSED: 247 passed, 0 failed, 0 skipped.
	c3c test --trust=full --test-noleak PASSED: 247 passed, 0 failed, 0 skipped.

Twenty-six new checks. Twenty-four of them need no device: the two conversions
and the click are arithmetic over structs, which is the same seam
`controls_test.c3` and the keyboard use and it is here for the same reason.

**Two need a device**, and they are the two that matter most:
`a_click_picks_the_object_under_it` puts a box at the origin, aims the camera at
it, clicks the centre of the image and asserts `hit.object === box` — the one
check that says the pieces are joined the right way round, and the only way to
reach `asIntersection`'s live-scene branch, which a deviceless click can never
get to because its hit is always `null`. `a_click_on_nothing_is_a_miss` clicks
the corner, where the answer is `null` and a picker that answered with the
nearest thing anyway would pass every other check in the file.

### Every bug the tests claim to catch, re-introduced

`scratchpad/inject_click.py`. Each row asserts its pattern matches exactly once,
applies it, runs the one named check, restores, and compares a sha256 of every
touched file at the end.

| re-introduced bug | check | result |
| --- | --- | --- |
| the cursor is not flipped | `the_cursor_is_flipped_because_the_window_counts_up` | caught |
| the cursor is scaled by the backing scale instead of mapped by fraction | `a_retina_window_maps_by_fraction_and_not_by_the_backing_scale` | caught |
| the right and top edges count as inside | `a_cursor_off_the_window_is_not_inside` | caught |
| a window with no size is not guarded | `a_window_with_no_size_answers_nothing` | caught |
| the press anchor is never recorded | `a_press_and_a_release_in_one_place_is_a_click` | caught |
| the press anchor follows the button rather than its edge | `a_stuck_button_never_clicks_and_heals_at_the_next_one` | caught |
| a click is not required to have stayed still | `a_press_that_travels_is_a_drag` | caught |
| a click may be held for as long as it likes | `a_press_that_is_held_is_not_a_click` | caught |
| a press from off the window still starts a click | `a_press_that_starts_outside_is_not_a_click` | caught |
| a release off the window still ends one | `a_release_outside_the_window_is_not_a_click` | caught |
| the click is not an edge | `a_click_is_reported_for_exactly_one_frame` | caught |
| the pointer is taken after the early return, not before | `the_pointer_arrives_with_nothing_registered` | caught |
| a click handler alone does not make a frame | `a_click_handler_alone_is_enough_to_tick` | caught |
| the click is dispatched after the animation callback | `the_click_runs_before_the_animation_callback` | caught |
| the handler fires every frame rather than on the click | `a_click_handler_fires_once_and_says_where` | caught |
| the handler is told the pixel the other way round | `a_click_handler_fires_once_and_says_where` | caught |
| a throwing handler stays bound | `a_throwing_click_handler_is_stopped` | caught |
| a handler that returns a promise stays bound | `a_click_handler_that_returns_a_promise_is_stopped` | caught |
| null does not unbind | `binding_a_click_again_replaces_and_null_unbinds` | caught |
| the pointer answers about the wrong axis | `a_script_can_ask_where_the_pointer_is` | caught |
| an async click handler is accepted | `an_async_click_handler_is_refused_at_registration` | caught |
| a hit is never resolved to the object the script built | `a_click_picks_the_object_under_it` | caught |
| the click picks the middle of the image whatever pixel it was on | `a_click_on_nothing_is_a_miss` | caught |
| the docs do not mention the click | `the_docs_describe_the_click` | caught |

24 of 24 caught; `scene/input.c3`, `js/bind_input.c3`, `js/frame_loop.c3` and
`js/prelude.js` all restore byte-identical.

**Two of these are the reason this milestone exists at all.** "Scaled by the
backing scale" is the implementation `plan.md` asked for, and it passes the
1:1 window check and the flip check and fails only the retina and resize ones.
"Not flipped" passes anything symmetric. Neither is a crash, a warning, or a
wrong-looking picture — they are a picker that agrees with itself and disagrees
with the window, which is `plan.md` §7's whole argument for having a pick suite.

### What running it live added

A window on port 8811, a box at the origin, and a small `mouse` binary built for
the purpose: `CGEventCreate` to read the cursor, `CGWarpMouseCursorPosition` to
place it, and `CGEventPost` for the button. Warping needs no permission; posting
does, and the run was silent until macOS's accessibility prompt was answered —
worth knowing, because a synthetic click that is refused looks exactly like a
click that was not seen.

**The mapping, against a real retina window.** With the cursor warped to a known
screen point and the window's own rect read from `System Events`:

	screen (200, 742)  ->  image (200.00, 150.00)  inside=true
	screen ( 10, 602)  ->  image ( 10.00,  10.00)  inside=true
	screen (1302.84, 158.02) -> image (1302.84, -433.98) inside=false

Exact to two decimals, including the point off the window, where the arithmetic
is the same and unclamped. This is a 400x300-point window showing a 400x300
image on a 2x display, so the swapchain is 800x600 and **the wrong version would
have reported 400 for the centre instead of 200**.

**Five gestures, in one run:**

	click on the box       -> "200,150 -> the box itself"
	click on empty space   -> "15.000000953674316,15.000003814697266 -> nothing"
	drag through the box   -> no click, and the camera turned -57.8 degrees
	hold 900 ms on the box -> no click
	click on the box       -> "200,150 -> the box itself"

The drag is the one worth having: it crossed the box, it ended on the box, and
it selected nothing while orbiting the camera by fifty-seven degrees. That is
the whole reason the slop and the hold exist, and it cannot be observed from a
test that says what the mouse did — only from one where a real gesture had to be
told apart from another real gesture by the same button.

`15.000000953674316` is not noise worth cleaning up: it is the evidence that the
number went through a divide and a multiply rather than being passed along, which
is exactly what was in question.

**And the thing that was luck rather than design:** halfway through the run the
window moved — from (0, 560) to (171, 287) to (525, 329), because the machine
was in use while the measurement ran. Every reading after the move was still
exact against the new rect, which is the strongest available statement that the
conversion is window-relative and reads the extents fresh rather than caching
what it was told at startup. It would have been a reasonable thing to test on
purpose and it did not occur to me to.

## What is deliberately absent

- **No `mouseDown` / `mouseUp` for scripts.** The same argument the key table
  makes: the latch sticks, and a script polling it would be told the button is
  held forever with no gate of its own. The click is an edge, and an edge is the
  one thing a stuck latch cannot fabricate.
- **No drag events.** The left button orbits the camera. A script that wanted
  its own drag behaviour would first need a way to turn the camera controls off,
  which is Part five's open question and not this milestone's.
- **No right-click and no double-click.** Both are real gestures and neither has
  anything to do yet; the right button already pans.
- **No hover.** `three.input.pointer` polled in the animation callback is a
  hover, and a `scene.pick` per frame on top of it is the script's decision to
  make rather than the host's to make for it.

---


# Part five — M5g, built

The list of smaller things the first four made worth doing, done — including the
three that were written down as somebody's decision rather than as a task,
because they are changes to `c3w` and `c3w` is a submodule. The decision was
made; they are in the submodule's working tree, uncommitted, and the three that
touch platforms this cannot run on are compiled for those platforms rather than
merely written.

## The window sleeps

The windowed loop rendered continuously at whatever rate the swapchain allowed,
which for a viewer sitting open beside an agent is a core spinning to redraw a
picture nobody changed. `getEvent(wait: true)` parks the thread in
`nextEventMatchingMask` at 0% CPU, and the whole difficulty is deciding when it
is allowed to.

**The condition is already written down**, and the discipline is not writing it
twice: `JsRuntime.is_animating()` is `tick`'s own early return, exposed and read
by `main.c3`. A loop that slept while a callback was registered would stop it
dead; a `tick` that ran with nothing registered would keep the loop awake for
ever. One sentence, read from both ends.

	quiet = presented && !runtime.is_animating() && !camera_moved && handled == 0;

Every term is something that would be lost by sleeping through it. `presented`
is false when the frame rebuilt the swapchain instead of drawing, so the loop
owes one more iteration before resting. `camera_moved` covers the coast below —
a drag that ends is followed by a third of a second of frames nobody asked for.
`handled` is a tool call that may have changed the scene and answered before the
frame that shows it.

**The wake was already designed for.** `mcp.c3l`'s `Listener.start` takes a
`WakeFn` and calls it from its own thread once a request is queued —
"on a windowing toolkit that means the post-an-event-to-the-loop primitive" —
and `c3w`'s `Window.wake` is exactly that primitive. Without it a sleeping
window would go on sleeping through every request and the whole tool surface
would answer only when somebody moved the mouse. It is the one place in this
program where the listener's thread and the loop's thread touch, and it touches
through a posted event rather than through any state.

Measured: **0.0% idle**, a tool call answered in 113 ms round trip including
python's own startup, 17.6% and ~125 frames a second with a callback registered,
and back to 0.0% the moment `setAnimationLoop(null)` arrives.

## The scene coasts

An orbit that stopped the instant the button came up was the one gesture here
with no weight, and a turntable is the thing people most expect to keep turning.
`Controls` keeps the last frame's angular velocity and decays it — a time
constant of 60 ms, which is a third of a second of visible travel and about
thirty degrees on a hard flick.

**The velocity is the last frame's, not the drag's average**, and that is the
whole design rather than an implementation detail. A hand that slows down before
it lets go is saying where it wants the scene to stop; an average throws it past
that every time. A hand that stops dead and then releases sets the velocity to
zero, which is the same statement made more firmly, and it falls out of
recording the velocity on every frame of the drag including the ones with no
movement.

Three things it has to get right that are not the arithmetic:

- **Degrees per millisecond, not per frame.** Anything that decays by a fixed
  fraction per frame throws the same flick twice as far on a 120 Hz display.
- **Both ends of the step are clamped.** This loop also answers tool calls, so a
  script that runs for two seconds arrives as one enormous frame; without a
  ceiling it would multiply the last flick by sixty.
- **There is a floor.** An exponential never reaches zero, so without one the
  camera creeps by amounts nobody can see *and* `apply` goes on answering
  "moved" — which is the sentence the paragraph above reads as "do not sleep".
  The window would never idle again, for a gesture that ended a minute ago.

`damping_ms = 0` turns it off, and the check is read in exactly one place:
recording how fast the hand was going is a fact, and whether to spend it is a
policy. Checking it in both would mean removing either check changed nothing,
which is how a guard stops being load-bearing without anybody noticing.

## The cursor says what the hand is doing

An open hand over the scene, a closed one while dragging, the arrow everywhere
else — and set only when the shape has actually changed, because doing it every
frame is an objc call sixty times a second to say the same thing and, worse, it
overrules whatever AppKit put there the instant the pointer touches a resize
edge.

Three lines, and they are in `scene/input.c3` with a check on them rather than
inline in `main.c3`, which is the one file with no checks in it. The claim they
make — that a *pan* closes the hand as well as an orbit — is exactly the sort
that is true when written and quietly false a milestone later.

## The pointer is read once

`drive_camera` read `getMousePos` for its delta and `serve` read it again for
the click. Both readings are of the same instant and the two are now one, handed
to both: the camera wants a delta in points and the click wants a position in
image pixels, and one reading answering two questions is one fewer way for them
to disagree about where the mouse was.

## Sub-frame key presses — the `c3w` change that started as a measurement

Part three measured it: `osascript`'s `keystroke` presses and releases in the
same instant, and it produced the typed text and **no edge at all**. The latch is
set and cleared between two samples, so the press is invisible. A person cannot
type that fast — eighty milliseconds is five frames — but synthetic input can, a
key repeat that lands badly can, and any frame that runs long can.

`c3w` now keeps `EventLog` beside `EventMap`: the transitions it drained, in
order, cleared per call like the typed text. A fixed 512-entry array rather than
a list, so there is nothing to allocate, initialise or free and a window that is
not being pumped cannot grow it. Filled by all five backends — darwin, x11,
wayland, win32, wasm — and exposed as `Window.events()`.

**The two sources are or-ed, not swapped.** `down & ~previous` is the edge as far
as a latch can describe it; `fired_down` is the press the latch could not see.
Joining them means a backend that fills no log keeps exactly the behaviour it
had rather than losing every edge it used to report, and neither source can
manufacture a false edge — the difference needs a real transition and the queue
needs a real event. It is not a compromise between two answers; it is two ways
of noticing the same thing, taking whichever noticed.

A key that goes down and up inside one frame is now reported as **both** pressed
and released in that frame, which is what happened.

One thing the log made better on its own: `apply_modifier_flags` rewrites every
modifier on every `flagsChanged`, because the event carries the whole set rather
than an edge. Logging those blindly would report a shift press every time
control was touched — so the map's own previous answer is the edge, and it was
already sitting right there.

## The stuck latch, fixed at the source

`controls.c3` has documented since M5c that AppKit swallows the mouse-up ending
a title-bar drag, leaving the button latched for the rest of the session. Every
application built on that map has to work around it, and the workaround has to
live in each of them. `+[NSEvent pressedMouseButtons]` reports what is
physically held, right now, independently of what has been delivered to anybody.

**It only ever clears, and never sets.** A button held down over another
application is not this window's to react to: believing it would turn the very
next mouse movement across this window into a drag nobody started, which is the
same bug pointing the other way. The event stream stays the only thing that can
latch a button; this is only allowed to unlatch one.

`Controls`' release gate stays. It is the portable half — Linux and Windows have
the same class of problem and no equivalent call — and on macOS the source now
clears within a frame instead of at the user's next click.

## Windows parity

`get_scroll`, `get_scroll_x`, `get_text` and `get_scale` were stubs returning
zero, so zoom, typed text and retina scaling were all dead on Windows while
Linux was complete.

- **Scroll** accumulates `WM_MOUSEWHEEL` and `WM_MOUSEHWHEEL`, divided by
  `WHEEL_DELTA` so the answer is in notches — the same unit the X11 backend
  reports, positive away from the user and positive to the right.
- **Text** reads `WM_CHAR`, which `TranslateMessage` posts back into the same
  queue, so it arrives on a later turn of the loop that is already running. It
  carries the layout, the dead keys and the shift state already applied, which
  is the whole reason to read it rather than translating the key map by hand.
  Surrogate pairs are why it is a function and not a line: a character past the
  basic plane arrives as two messages, and appending each on its own writes two
  replacement characters where one emoji was meant.
- **Scale** is `GetDpiForWindow / 96`, and it answers 1.0 unless the process has
  declared itself DPI-aware — which is the application's manifest and not
  something a window library may decide on its behalf, because turning it on
  changes what every coordinate in the process means, including the size the
  window was asked for. So the answer is the same 1.0 the stub gave, now for a
  reason rather than for want of an implementation.
- **`get_scroll_precise`** stays false, and that is now the truth rather than a
  stub: the flag means "continuous units, from a trackpad", and the classic
  `WM_MOUSEWHEEL` path reports notches whatever the hardware is.

## Verification

	c3c build --trust=full              Program linked to executable './build/three'.
	c3c test --trust=full               PASSED: 264 passed, 0 failed, 0 skipped.
	c3c test --trust=full --test-noleak PASSED: 264 passed, 0 failed, 0 skipped.

Seventeen new checks. **And the platforms this cannot run are compiled rather
than hoped for**, which turned out to be available and worth the two minutes:

	c3c build test-win                  Program linked to executable './build/test-win.exe'
	c3c compile-only --target linux-x64 linux/*.c3 main.c3
	                                    Object files written to './obj/linux-x64'
	c3c build test-wasm                 Program linked to './test/web/test-wasm.wasm'

The Win32 backend cross-compiles *and links* against the MSVC SDK, and both
Linux backends type-check for `linux-x64`. That is not a running test and it is
not nothing: it catches the whole class of "written blind and does not build",
which is the failure a blind port actually has.

### Every bug the tests claim to catch, re-introduced

`scratchpad/inject_part5.py`, same harness: each row asserts its pattern matches
once, applies it, runs one check, restores, and compares a sha256 at the end.

| re-introduced bug | check | result |
| --- | --- | --- |
| the velocity is never remembered | `a_flick_keeps_turning_after_the_hand_lets_go` | caught |
| the coast runs backwards | `a_flick_keeps_turning_after_the_hand_lets_go` | caught |
| the coast never decays | `the_coast_decays` | caught |
| the coast has no floor and so never stops | `the_coast_slows_down_and_stops` | caught |
| the velocity is the whole drag rather than its last frame | `a_hand_that_stops_before_it_lets_go_does_not_throw_the_scene` | caught |
| the press frame does not reset the velocity | `grabbing_a_coasting_scene_stops_it` | caught |
| a pan does not catch the coast | `a_pan_catches_the_coast_as_well` | caught |
| damping cannot be turned off | `damping_off_stops_the_scene_dead` | caught |
| the coast keeps claiming it moved when it did not | `a_caller_with_no_clock_never_coasts` | caught |
| a long frame is not clamped | `a_very_long_frame_does_not_fling_the_camera` | caught |
| a pan does not close the hand | `the_cursor_says_what_the_hand_is_doing` | caught |
| the hand is shown off the window too | `the_cursor_says_what_the_hand_is_doing` | caught |
| the queue is ignored and only the latch is read | `a_key_tapped_inside_one_frame_is_still_seen` | caught |
| the queue replaces the latch instead of joining it | `the_latch_alone_still_reports_edges` | caught |
| the queue's presses are latched and so repeat for ever | `the_queue_does_not_re_press_a_held_key` | caught |
| a release event is read as a press | `the_window_queue_becomes_the_frames_edges` | caught |
| a tapped key is reported as held | `the_window_queue_becomes_the_frames_edges` | caught |
| a mouse button in the queue becomes a keyboard edge | `the_window_queue_becomes_the_frames_edges` | caught |
| a two-key name does not answer for a tapped key | `a_tapped_chord_key_answers_for_its_name` | caught |
| a click handler is not enough to keep the loop awake | `a_click_handler_alone_is_enough_to_tick` | caught |
| a key handler is not enough to keep the loop awake | `a_handler_runs_with_no_animation_callback` | caught |

21 of 21 caught; `scene/controls.c3`, `scene/input.c3` and `js/frame_loop.c3`
restore byte-identical.

### The injections that found redundancy rather than a bug

**Five escaped on the first pass, and only two of them were the tests' fault.**

Two — "damping cannot be turned off" and "a caller with no clock coasts anyway"
— were not caught because the guard existed in *two* places, `remember_spin` and
`coast`, and removing either changed nothing. That is not a test gap, it is the
thing `controls.c3` already argues against in as many words: a second mechanism
that hides the failure of the first. The fix was to the code, not the check —
`damping_ms` is now read in one place, and the two `dt_ms` guards were kept
because they are required for different reasons (one cannot divide by zero time,
the other must not answer "moved" for a frame that moved nothing).

Two more — "a release event is read as a press" and "a tapped key is reported as
held" — escaped because every check fed `InputTracker.step` a `FrameKeys`
directly, which is the right way to say what the keyboard *did* and says nothing
at all about the one function that reads `c3w`. `the_window_queue_becomes_the_frames_edges`
is that function: an event list in, two bitsets out.

The fifth was a bad injection — it happened to be neutralised by the pan branch
— and was replaced with one that isolates what the check is actually about.

### What was measured live, and what was not

The idle loop was measured directly, and needs no mouse: **0.0% CPU** across
repeated samples with the window open, a `run_script` answered while it slept,
another after a further idle stretch, and 0.0% again after. The
`+[NSEvent pressedMouseButtons]` call was smoke-tested against a real window —
the selector resolves, the ABI is right, and it answers false with nothing held.

**The coast's positive case was not confirmed live.** What was seen, in a
per-frame trace before live mouse testing was stopped, is the drag itself
applying -9.60 degrees a frame and then nothing after the release — which is the
*negative* case behaving correctly, because the synthetic drag's last twenty
milliseconds were stationary and a hand that stops before it lets go is meant to
stop the scene. The positive case rests on the nine headless checks and the ten
injections above.

---

# Part six — what is left

Everything the list here held is built — see Part five. What is left is smaller
and mostly not code.

## The smaller ones

- **Hover feedback.** The cursor already says whether the hand is on the scene
  and whether it is holding it. What it does not say is whether there is
  anything *under* it worth clicking, and `POINTING_HAND` over a pickable node
  would. That is a `scene.pick` every frame the mouse moves, so it is a decision
  about cost rather than a one-liner — and `three.input.pointer` already lets a
  script do it for itself, which is the argument for leaving it there.
- **A DPI-aware manifest for Windows.** `get_scale` now reads the real DPI and
  will keep answering 1.0 until the *application* declares per-monitor
  awareness, because that declaration changes what every coordinate in the
  process means, including the size the window was asked for. It belongs to
  whoever ships a Windows build of this, not to `c3w`.
- **`should_close` on Windows.** Still `false`, with `WM_QUIT` latching `ESCAPE`
  instead. It is the one remaining piece of the Windows backend that is a stub
  rather than an answer, and it was left out of the parity work deliberately:
  the other four were reads, and this one changes when the loop exits.
- **A running window on Linux and Windows.** Both backends compile — Win32
  links against the MSVC SDK, both Linux backends type-check for `linux-x64` —
  and neither has been *run* since any of this was written. Compiling catches
  the failure a blind port actually has, and it does not catch a wrong sign or a
  message that never arrives.

## Open questions

- **Should a script be able to turn the mouse controls off?** Sharper now than
  it was: `onClick` gave a script half the mouse, and the half it did not give —
  the drag — is the half the camera owns. A scene that wanted its own drag
  behaviour has no way to ask for it. `three.controls.enabled = false` is cheap,
  but it is one more piece of state a script can leave in a bad way, and a
  window nobody can move the camera in is a bad way.
- **Should a click be able to say it was handled?** A handler that returns
  `false` could suppress the orbit for that gesture. It is the browser's
  `preventDefault` and it would be the natural answer to the question above —
  and it is also a rule that has to be explained, for a conflict that a
  four-pixel click barely has.
- **Does the camera belong to the scene?** The camera survives
  `new three.Scene()` today, so a script that rebuilds the scene keeps whatever
  the user dragged it to. That is almost certainly right for a person watching
  the window and it is worth writing down before something changes it by
  accident. **The animation callback survives it too**, and that one is decided
  and tested: the loop belongs to the host as Three.js's belongs to the
  renderer, so a rebuild does not silently lose the animation — what it loses is
  every handle the callback captured, and the stale-handle throw stops it with a
  sentence rather than leaving it running against nothing.
