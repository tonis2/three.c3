<*
 The game clock — the one number everything that moves in a frame is a function
 of.

	`plan.md` §17, second item in the order of work.

 ## What was missing, and it is not a subtraction

 A script could always difference the milliseconds `setAnimationLoop` hands it,
 and every example did: `const dt = Math.min(0.05, (ms - last) / 1000)`, written
 out again in each one, with a different clamp each time. What no amount of that
 buys is the thing this file is for — **nothing could pause**. The clip player
 advanced off the host's wall clock, the solver's accumulator was fed from it,
 and `p.time` in a post body was seconds since the shader was compiled; a script
 that stopped moving its own objects still had a world running underneath it.

 So the clock is not a convenience over a subtraction. It is the single place
 the frame's delta is decided, and every consumer of a delta was changed to ask
 it rather than to do its own arithmetic on the host's reading.

 ## Wall time in, game time out

 `advance_frame` is the whole conversion and it happens once per tick, before
 anything reads a delta:

 - **The first tick contributes nothing.** `elapsed_ms` is measured from process
   start, so the first one carries the whole boot — window creation, device
   selection, the script's own load. A clip played during boot would begin half a
   second into itself.
 - **A wall delta is clamped to `CLOCK_MAX_STEP_MS`.** A longer one means the
   process was stalled — a breakpoint, a swap storm, a `run_script` that took its
   whole budget — and no clip should teleport through a second of itself for it.
   The clamp is on the *wall* delta, before the scale, so `timeScale = 4` is four
   times as much game time and not a fifth of it.
 - **Then the scale.** Zero is paused, and paused is exactly `dt == 0` reaching
   every consumer rather than a flag each of them has to test. That is the whole
   reason the pause works: there is no `if (paused)` anywhere in the clip player,
   the solver or the follow camera.
 - **Then the debt**, which is `advance()` and is the only way a paused clock
   moves. It is added *after* the scale on purpose: a caller asking for a step of
   1/60 s while the game is stopped means one frame's worth of world, not one
   frame's worth multiplied by a scale that is zero.

 ## Why the fixed accumulator is here rather than in JavaScript

 The same argument `Physics.step` makes, one layer up: an accumulator in the
 animation callback runs inside the script budget, so a frame that owes eight
 steps spends eight steps' worth of somebody's five seconds, and a spiral of
 death stops the callback for good instead of merely stuttering. Here it is C3's
 — `take_fixed_steps` hands back a count and the host does the calling.

 It is deliberately *not* the solver's accumulator, though both default to 60 Hz
 and both are fed the same game milliseconds. `Physics` owns its rate because
 its rate is a property of the solver's stability, and a script lowering the
 gameplay rate to 30 must not quietly halve the physics rate with it.
*>
module three;

<*
 The longest single frame anything advances by, in **wall** milliseconds and
 before the time scale.

 Was `ANIMATION_MAX_STEP_MS` and applied to clips alone; it is the clock's now
 because a stall is a fact about the frame rather than about the clip player,
 and two consumers clamping differently is how a solver and an animation come
 out of a stall disagreeing about what time it is.
*>
const double CLOCK_MAX_STEP_MS = 100.0;

// What a fixed loop runs at until a script says otherwise. The solver's rate,
// so that the default is one rate in the whole engine.
const double CLOCK_FIXED_HZ = 60.0;

// The rates a script may ask for. Below one a "fixed step" stops being a step
// of anything; above 240 it is a request for the interpreter to be the
// bottleneck, and the cap is what keeps `three.clock.fixedRate = 1e9` from
// being a hang rather than a mistake.
const double CLOCK_FIXED_HZ_MIN = 1.0;
const double CLOCK_FIXED_HZ_MAX = 240.0;

<*
 How many fixed steps one frame may run before the rest is dropped.

 `PHYSICS_MAX_STEPS` is five and this is eight, and they are different numbers
 for the same reason rather than by accident: the solver's cap bounds work the
 host does, and this one bounds work a *script* does — eight calls into QuickJS
 against the frame budget. Both drop the remainder rather than carrying it,
 which is the difference between a stutter and a spiral.
*>
const int CLOCK_MAX_FIXED_STEPS = 8;

<*
 The clock, on `MeshPass` beside the camera and the follow.

 **Not on the runtime**, though the runtime is what advances it: the post chain
 reads it while recording a frame and has no runtime to ask, and a second copy
 of the time on the renderer would be a second answer to what time it is — which
 is the whole failure this replaces.

 **It survives `new three.Scene()`**, following the camera rather than the
 background. A rebuild that put the time back to zero would step `p.time`
 backwards and flash every post pass that reads it, and a script rebuilding its
 world is not saying anything about what o'clock it is.
*>
struct GameClock
{
	// Game seconds since the first tick. Monotonic: it never moves backwards,
	// because the scale cannot be negative and the debt cannot be.
	double time;

	// What the frame being drawn is worth, in game seconds. Zero on the first
	// tick and zero while paused, which is what makes a pause need no flag.
	double dt;

	// The multiplier from wall time to game time. Zero is paused. Refused
	// negative at the binding — a rewind is a thing no consumer of this can do:
	// a clip would have to sample backwards and the solver cannot at all.
	double scale;

	// The host's last reading and whether there has been one. Turning
	// "milliseconds since the process started" into "what this frame is worth"
	// is the whole of the state the conversion needs.
	double last_wall_ms;
	bool started;

	// Game milliseconds owed to the next frame — `advance`, and the only thing
	// that moves a stopped clock.
	double owed_ms;

	// The fixed step's accumulator, in game milliseconds, and its rate.
	double fixed_ms;
	double fixed_hz;
}

<*
 A running clock at ordinary speed.

 Called by `MeshPass.init` and by `JsRuntime.open`, because the zero value of
 this struct is a clock stopped at nought hertz and a struct whose default state
 is "paused" is a trap for whoever builds a `MeshPass` by hand next. Both
 callers run once, at startup, before anything can have set a scale.
*>
fn void GameClock.defaults(&self)
{
	*self = { .scale = 1.0, .fixed_hz = CLOCK_FIXED_HZ };
}

<*
 One frame: turn the host's monotonic reading into what this frame is worth.

 Everything else in the tick is handed the result rather than asking the clock
 again, for the reason the old `step_animations` gave when it returned its own
 delta: this consumes `last_wall_ms`, so a second caller asking the same
 question after it would be told that nothing happened.

 @param wall_ms : `Milliseconds since the host started counting. Monotonic; the same reading setAnimationLoop used to be handed.`
 @return `This frame's game milliseconds — scaled, clamped, and never negative.`
*>
fn double GameClock.advance_frame(&self, double wall_ms)
{
	double wall_dt = self.started ? wall_ms - self.last_wall_ms : 0;
	self.last_wall_ms = wall_ms;
	self.started = true;

	// A host that went backwards is a host whose clock is not monotonic, which
	// is a thing tests do on purpose and platforms do by accident. Zero rather
	// than a negative frame: time does not run back here.
	if (wall_dt < 0) wall_dt = 0;
	if (wall_dt > CLOCK_MAX_STEP_MS) wall_dt = CLOCK_MAX_STEP_MS;

	double dt_ms = wall_dt * self.scale + self.owed_ms;
	self.owed_ms = 0;

	self.dt = dt_ms / 1000.0;
	self.time += self.dt;
	self.fixed_ms += dt_ms;
	return dt_ms;
}

<*
 Owe the next frame this much game time, whatever the scale is.

 What makes a stopped clock steppable, and the reason `timeScale = 0` is a pause
 rather than a freezer: pause, advance a sixtieth, look at the picture, advance
 another. `plan.md` §2's screenshot-reproducibility entry is the case it was
 built for — a post pass animating off `p.time` renders the same frame twice if
 the clock only moves when it is told to.

 Added to the next frame rather than applied here, because *every* consumer of a
 delta is downstream of `advance_frame`: applying it on the spot would move the
 time without stepping a clip, a solver or a fixed loop, which is a clock telling
 a different story from the world it times.

 @param seconds : `Game seconds. Negative is ignored rather than refused — this is reached through a binding that has already said no to it.`
*>
fn void GameClock.advance(&self, double seconds)
{
	if (seconds <= 0) return;
	self.owed_ms += seconds * 1000.0;
}

<*
 How many fixed steps this frame owes, consuming them from the accumulator.

 Asked every frame whether or not anything is registered to run them — see
 `JsRuntime.tick`. A remainder past one step is dropped rather than carried,
 which is the cap doing its job: `PHYSICS_MAX_STEPS` has the same line for the
 same reason.
*>
fn int GameClock.take_fixed_steps(&self)
{
	double step_ms = self.fixed_step_ms();
	int steps = 0;
	while (self.fixed_ms >= step_ms && steps < CLOCK_MAX_FIXED_STEPS)
	{
		self.fixed_ms -= step_ms;
		steps++;
	}
	if (self.fixed_ms > step_ms) self.fixed_ms = 0;
	return steps;
}

// One fixed step in game milliseconds. Infinite on a zero-value clock, which is
// what keeps `take_fixed_steps` from spinning on one that was never started.
fn double GameClock.fixed_step_ms(&self) => 1000.0 / self.fixed_hz;

// One fixed step in seconds — what the fixed callback is handed, and what
// `three.clock.fixedDelta` reads.
fn double GameClock.fixed_dt(&self) => 1.0 / self.fixed_hz;
