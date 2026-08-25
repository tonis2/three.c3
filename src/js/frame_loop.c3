<*
 `three.setAnimationLoop` — a callback the host runs once per frame.

 ## What was actually missing

 Not a loop. `main.c3` has rendered every iteration since M3, and `MeshPass`
 holds one persistent scene and one persistent camera, so the window has always
 been a live view of mutable state. What was missing is a way for a *script* to
 be part of that: every change to the scene had to arrive as a whole tool call,
 which means the smallest possible animation was an agent in the loop at sixty
 frames a second. This file is the second entry point into the engine — the one
 that is not a run.

 ## Why it cannot go through `JsRuntime.run`

 `run` is built for the tool call and every one of its habits is wrong here:

 - It clears `log`, `value` and `error`. Per frame, that erases the result an
   agent is about to read.
 - It starts a fresh GPU validation capture, which would attribute a frame's
   messages to a script that finished minutes ago.
 - It wraps the source in `(async()=>{})()`, allocating a promise sixty times a
   second to run a function that already exists.

 So a tick calls the retained `qjs::Value` directly. What it shares with `run`
 is the interrupt handler, and only because there is one of those per context.

 ## The three ways a callback stops

 A callback is disabled the moment it misbehaves, and the reason is kept for the
 next run to report. **Retrying silently every frame is the failure mode worth
 designing against**: it gives an unusable window and nothing to diagnose it
 with, sixty times a second, which is how a feature becomes a trap. The three
 are a throw, a budget overrun, and returning a promise.

 ## What a tick is deliberately not

 It is not `requestAnimationFrame`: that is the browser's, and Three.js has no
 frame loop in core either. `WebGLRenderer.setAnimationLoop` is the one name for
 this that is genuinely Three.js's, so it is the one used.

 It does not render. The host renders after the tick, in whatever way that host
 renders — which is what lets the whole of this file be driven from a headless
 test with no device at all.
*>
module three;

import std::io;
import std::time;
import std::math::vector;
import qjs;

// What one tick may take before the interrupt handler stops it. Two orders of
// magnitude under a script's budget and one over a frame, which is the gap this
// number wants to sit in: it cannot be reached by anything that is merely slow
// — a callback taking 100 ms has already made the window a slideshow, and
// killing it for that would be the host overruling the author — and it bounds a
// `while (true) {}` to a tenth of a second instead of five.
const long JS_FRAME_BUDGET_MS = 100;

<*
 What a *game's* frame callback may take before anyone is told about it.

 `game.md` G1/S4. Eight milliseconds is half a 60Hz frame, which is the point at
 which a callback has stopped leaving room for the draw it exists to set up.

 **Exceeding it is a report, not a death**, and that is the whole difference
 between the two boot modes. Stopping the callback for good is right for an
 agent — a runaway loop must not wedge the tool surface, and the agent is
 sitting there to be told. It is wrong for a game, where the thing that trips a
 hundred-millisecond budget once is a garbage collection, and killing the game
 loop over one is a crash with a polite message.

 The hard wall does not go away in game mode; it becomes `JS_BUDGET_MS`. A
 callback that genuinely never returns still has to be stopped, because an
 attached agent is the only thing that could diagnose it and it cannot be asked
 while the frame is still running.
*>
const long JS_GAME_FRAME_SOFT_MS = 8;

// A callback that makes a promise gets this many microtask steps to settle it.
// Small on purpose: the script budget's 100 000 is sized for a whole scene
// build, and per frame it is a licence to hang.
const uint JS_FRAME_MAX_JOBS = 1_000;

// How much of what the callback logged is kept for the next run to read. The
// oldest lines are dropped rather than the newest, because a loop that logs
// every frame fills any buffer immediately and the interesting state is the
// state it is in now.
const usz JS_FRAME_LOG_BYTES = 8 * 1024;

fn void JsRuntime.bind_frame_verbs(&self, qjs::Value host)
{
	self.bind(host, "setFrame", &js_set_frame, 1);
	self.bind(host, "setFixed", &js_set_fixed, 1);
}

<*
 What the two loop callbacks are called in the sentences that stop them.

 Constants rather than literals at four call sites, because the frame's three
 sentences are asserted on by name in `test/frame_test.c3` and a second loop
 that phrased its own failures differently would be two vocabularies for one
 mechanism.
*>
const String FRAME_CALLBACK = "the animation callback";
const String FIXED_CALLBACK = "the fixed loop";

<*
 Say that the frames belong to a program somebody is watching, not to an agent.

 The one switch `JS_GAME_FRAME_SOFT_MS` describes from the other side, and both
 boots that come off a command line throw it: `--assets` through
 `set_assets_root`, `--script` through `main.c3`'s `boot_script`. Everything a
 server runs leaves it alone, which is what keeps a runaway `run_script`
 callback from wedging the tool surface.

 One-way on purpose. There is no `stop_playing`: the two callers set it before
 anything can register a callback, and a frame policy that changed underneath a
 running loop would mean the same callback was killed or counted depending on
 when it happened to run long.
*>
fn void JsRuntime.play_frames(&self)
{
	self.game_frames = true;
}

<*
 Whether a tick would do anything: is anything registered at all, **or is a clip
 playing**.

 Exposed because it is also the host's "may this window go to sleep" condition,
 and the two must be the same sentence. A loop that idled while a callback was
 registered would stop it dead; a `tick` that ran with nothing registered would
 keep the loop awake forever. Written once, read twice — see `main.c3`.

 The clip term is `game.md` G3/S6, and it is the term that is easy to miss: a
 game with no `setAnimationLoop` at all can still have a door swinging open, and
 without this the window sleeps in the middle of it. Nothing about that reads as
 a bug in the animation code — the clip is playing, the player is stepping, and
 the frames simply stop arriving.
*>
fn bool JsRuntime.is_animating(&self)
{
	if (self.pass != null && self.pass.scene.is_animating()) return true;
	return self.frame_active || self.fixed_active || self.key_handler_count > 0 || self.click_active;
}

<*
 Advance every playing clip by what this frame is worth.

 **The runtime still keeps no clock**, and now nothing else does either: the
 wall-to-game conversion, the first-tick guard and the stall clamp all moved to
 `GameClock.advance_frame`, which `tick` calls once and hands the result to
 everything that needs a delta. What this used to do on its own is why they
 moved — a second consumer differencing the host's reading after this one had
 consumed it would be told that no time had passed.

 Game milliseconds, so a paused clock stops the clips with no flag to test: the
 delta is zero and the early return below is the pause.

 @param dt_ms : `This frame's game milliseconds, from GameClock.advance_frame.`
*>
fn void JsRuntime.step_animations(&self, double dt_ms)
{
	if (self.pass == null || dt_ms <= 0) return;
	self.pass.scene.step_animations((float)(dt_ms / 1000.0));
}

<*
 Run the callback once, if there is one.

 **The host says what time it is.** The runtime keeps no clock of its own, which
 is not an oversight: a tick that read the wall clock could only be tested by
 waiting, and the tests would assert on whatever the machine happened to do.
 `main.c3` passes the elapsed time it already has, and a test passes whatever it
 wants to have happened.

 **The input arrives here too**, and is taken whether or not anything is
 registered to read it: `three.input.isDown(...)` from an ordinary `run_script`
 answers about the last frame the window drew, which is the only answer that
 could be right.

 **What the host says and what the callback is told are no longer the same
 number.** The host's reading is a wall clock; the callback is handed the *game*
 clock, which is that reading through `GameClock.advance_frame` — scaled,
 clamped and stoppable. They differ by nothing at all on an ordinary frame of an
 unpaused game, which is why the argument keeps Three.js's name, its units and
 its monotonicity; they differ by everything the moment somebody pauses, which
 is the point. A callback computing a rotation from its argument is most of what
 moves in most of these scenes, and a pause that did not reach it would be a
 still world with the propeller still turning.

 @param elapsed_ms : `Milliseconds, monotonic, from whenever the host started counting — a wall clock. What the callback is told is this through the game clock.`
 @param input : `This frame's keyboard and mouse. Default-empty, for a host that has no window and for the checks that only care about the callback.`
 @return `true when something ran, false when nothing is registered — so a caller can tell an idle loop from a running one without asking twice.`
*>
fn bool JsRuntime.tick(&self, double elapsed_ms, InputState input = {})
{
	// Keys a script is holding folded in beside the window's, before anything
	// reads them — so `three.input.pressed`, `isDown` and every `onKeyDown`
	// handler see one keyboard rather than two. A no-op until something has
	// called `three.input.press`.
	self.take_input(self.synthetic.merge(input));

	// **The clock first, before anything asks what a frame is worth.** One
	// conversion, one answer: the clip player, the solver, the fixed loop, the
	// follow camera and the callback are all handed this number rather than
	// differencing the host's reading themselves, which is what makes
	// `three.clock.timeScale = 0` a pause instead of five separate ones.
	double delta_ms = self.pass.clock.advance_frame(elapsed_ms);

	// **Taken every frame, whether or not anything is registered to run them.**
	// An accumulator left filling while no fixed loop was set would fire a
	// frame's worth of catch-up the moment one was — a game whose first gameplay
	// step is eight steps long, for no reason a script could see. The count is
	// consumed here and spent below, inside the budget, because spending it is
	// calling into JavaScript.
	int fixed_steps = self.pass.clock.take_fixed_steps();

	// **Animation next, and above the early return.** `game.md` G3/S6: the step
	// happens in the host frame *before* the callback, so a callback can read
	// where a character got to this frame rather than where it was last frame —
	// and so a clip plays with no `setAnimationLoop` registered at all, which is
	// the case the early return below would otherwise refuse.
	self.step_animations(delta_ms);

	// **Physics next, and above the early return, for the same two reasons the
	// animation step is above it** (`game.md` G3/S6, G5/S1): a callback should
	// read where a body got to *this* frame rather than where it was last one,
	// and a scene with bodies but no `setAnimationLoop` still has to fall.
	//
	// The fixed-rate accumulator is inside `Physics.step` and is C3's, not
	// JavaScript's — an accumulator in the callback would run inside the script
	// budget, so a spiral of death would trip the budget and stop the callback
	// for good rather than merely stutter.
	self.physics.step(&self.pass.scene, delta_ms);
	self.report_diverged_bodies();

	// **Last of everything, on every path out of this function**, which is what
	// the `defer` buys and why it is not simply a call at the bottom.
	//
	// Last, because every other step here can move the thing being followed: the
	// clip advances a character, the solver drops it, and the callback below
	// walks it. A follow that ran before any of those would put the camera where
	// the character *was*, and one frame of lateness on a camera reads as the
	// character sliding rather than as the camera trailing — the symptom gets
	// blamed on the physics every time.
	//
	// Every path, because a scene with a falling body and no `setAnimationLoop`
	// takes the early return below and still has a camera that has to keep up.
	// That is the same argument the animation and physics steps make about
	// sitting above it, one step further along.
	defer self.follow_camera(delta_ms);

	if (!self.is_animating())
	{
		// Nothing will run this frame, so nothing will be told. Dropped rather
		// than kept, or a world stepping under a scene with no callback grows
		// a list nobody ever reads.
		self.drop_physics_events();
		return false;
	}

	self.frame_ticks++;

	// The script budget is borrowed, not replaced: `budget_ns` is what the one
	// interrupt handler reads, and a run may have set its own. Saving it here
	// rather than reaching for `JS_BUDGET_MS` is what keeps a caller's shorter
	// budget theirs.
	long budget = self.budget_ns;
	// A game gets the long wall and a soft warning; an agent's script gets the
	// short wall and no second chance. See `JS_GAME_FRAME_SOFT_MS`.
	self.budget_ns = (self.game_frames ? JS_BUDGET_MS : JS_FRAME_BUDGET_MS) * 1_000_000;
	self.started = clock::now();
	self.timed_out = false;
	self.in_frame = true;

	// Input first, then the animation. A handler that moves something and a
	// callback that draws the consequence in the same frame is the order a
	// person expects; the other way round shows every keypress one frame late.
	self.dispatch_keys();
	// Each step is skipped once the budget is gone, rather than called and
	// interrupted on its first instruction: a callback stopped for someone
	// else's overrun would be stopped for good, for a failure that is not its
	// own.
	if (!self.timed_out) self.dispatch_click();
	// After input and before the callback: the events describe the step that
	// already happened, so a handler that reacts to a hit and a callback that
	// draws the consequence run in that order within one frame.
	if (!self.timed_out) self.dispatch_physics_events();
	// **Fixed steps before the frame callback**, so a callback drawing the
	// consequence of a gameplay step draws this frame's rather than last
	// frame's. It is the same ordering argument the clip and the solver make one
	// level up, and it is why both of those are above the early return while
	// this is not: they are the host's work and this is a script's.
	if (!self.timed_out && self.fixed_active) self.call_fixed(fixed_steps);
	if (!self.timed_out && self.frame_active) self.call_frame(self.pass.clock.time * 1000.0);
	if (!self.timed_out) self.drain_frame_jobs();

	self.in_frame = false;
	self.budget_ns = budget;

	// Measured after the callback rather than interrupted during it: a frame
	// that ran long has already cost what it cost, and the only useful thing
	// left to do with that fact is count it where somebody can read it.
	if (self.game_frames && !self.timed_out)
	{
		long spent_ns = (long)self.started.to_now();
		if (spent_ns > JS_GAME_FRAME_SOFT_MS * 1_000_000)
		{
			self.frame_overruns++;
			// Once, and then never again: a callback that overruns every frame
			// would otherwise write sixty lines a second into a log an agent
			// reads in one piece. The count is what carries the rest.
			if (!self.frame_overrun_warned)
			{
				self.frame_overrun_warned = true;
				self.report_frame_failure(string::tformat(
					"the animation callback took %d ms, over the %d ms a frame has — "
					"the count in `frame.overruns` is every time since",
					spent_ns / 1_000_000, JS_GAME_FRAME_SOFT_MS
				));
			}
		}
	}

	self.trim_frame_log();
	return true;
}

<*
 The animation callback, called once.

 @param time_ms : `The game clock in milliseconds. See tick on why it is not the host's reading.`
*>
fn void JsRuntime.call_frame(&self, double time_ms)
{
	if (!self.call_loop(self.frame_fn, time_ms, FRAME_CALLBACK)) self.clear_frame();
}

<*
 The fixed callback, called once per step this frame owes.

 **The dt it is handed is a constant**, which is the whole of what a fixed step
 is for: the same number every call whatever the frame rate did, so an
 integration written against it produces the same trajectory on a slow machine
 as on a fast one. `GameClock` has the accumulator and the cap.

 The loop stops on the first step that fails, rather than running the remaining
 seven into a callback that has already been taken away — and it stops on a
 budget overrun without calling again, for the reason the dispatches in `tick`
 give: a step interrupted on its first instruction would be stopped for
 somebody else's overrun.
*>
fn void JsRuntime.call_fixed(&self, int steps)
{
	double dt = self.pass.clock.fixed_dt();
	for (int i = 0; i < steps; i++)
	{
		if (self.timed_out) break;
		if (!self.call_loop(self.fixed_fn, dt, FIXED_CALLBACK))
		{
			self.clear_fixed();
			return;
		}
	}
}

<*
 Call one of the two loop callbacks once and say whether it survived.

 Shared because the three ways a callback stops are a property of *being called
 inside a frame* rather than of which callback it is — a throw, the budget, and
 returning a promise. What is not shared is which reference gets released, which
 is why this reports the failure and the caller does the clearing.

 @param what : `Which callback, for the sentence: FRAME_CALLBACK or FIXED_CALLBACK.`
 @return `false when it misbehaved and must be taken away. The reason is already reported.`
*>
fn bool JsRuntime.call_loop(&self, qjs::Value callback, double arg, String what)
{
	bool survived = true;
	@pool()
	{
		qjs::Value[1] args = { qjs::number_value(arg) };
		qjs::Value? answer = self.js.call(callback, qjs::undefined_value(), args[..]);

		if (catch err = answer)
		{
			self.report_frame_failure(self.timed_out
				? self.loop_timeout_message(what)
				: string::tformat("%s threw and was stopped: %s", what, self.js.exception(tmem)));
			survived = false;
		}
		else
		{
			// Asked before the value is released, and only of an object: a
			// callback that returns nothing — which is all of them — costs one
			// tag comparison.
			bool promised = self.is_thenable(answer);
			self.js.release(answer);

			if (promised)
			{
				self.report_frame_failure(string::tformat(
					"%s returned a promise. It has to finish inside the frame, "
					"so it must be synchronous — do the awaiting in a run_script instead",
					what
				));
				survived = false;
			}
		}
	};
	return survived;
}

<*
 Forget the callback, releasing the reference to it.

 Called by `setAnimationLoop(null)`, by a replacement, by every way a callback
 can fail, and by `JsRuntime.close` — which is the one that matters, because it
 has to happen while there is still a context to release into.
*>
fn void JsRuntime.clear_frame(&self)
{
	if (!self.frame_active) return;
	self.js.release(self.frame_fn);
	self.frame_fn = qjs::undefined_value();
	self.frame_active = false;
}

// The same, for the fixed loop. `close` calls both, and for the same reason:
// the reference has to go back while there is still a context to give it to.
fn void JsRuntime.clear_fixed(&self)
{
	if (!self.fixed_active) return;
	self.js.release(self.fixed_fn);
	self.fixed_fn = qjs::undefined_value();
	self.fixed_active = false;
}

<*
 Stop the callback and keep the reason.

 The reason outlives the callback on purpose. An animation that dies has no
 other way to say so: nobody is reading a terminal, the window simply stops
 moving, and the next tool call is the first moment anyone is listening.
*>
fn void JsRuntime.stop_frame(&self, String why)
{
	self.clear_frame();
	self.report_frame_failure(why);
}

<*
 Keep one reason for the next run to report.

 **Appended rather than replacing**, because a frame now has more than one thing
 that can fail in it — the animation callback and any number of key handlers —
 and the first failure is usually the one that explains the rest. Each of them
 stops the first time it misbehaves, so this is bounded by the number of things
 registered rather than by how long the window has been open.
*>
fn void JsRuntime.report_frame_failure(&self, String why)
{
	if (self.frame_error.len() > 0) self.frame_error.append_char('\n');
	self.frame_error.append_string(why);
}

<*
 Read off `budget_ns` rather than off `JS_FRAME_BUDGET_MS`, for a reason an
 injection found rather than a reason anyone thought of: with the constant in
 the message, a tick that forgot to install the frame budget at all still
 produced the sentence "longer than 100 ms" — after running for the script's
 five seconds. The number and the thing it names have to come from the same
 place or the message is free to be wrong in exactly the case it is read in.
*>
fn String JsRuntime.frame_timeout_message(&self) => self.loop_timeout_message(FRAME_CALLBACK);

// The same sentence for whichever loop ran long. See `frame_timeout_message`
// for why the number comes off `budget_ns` rather than off the constant.
fn String JsRuntime.loop_timeout_message(&self, String what)
{
	return string::tformat(
		"%s ran for longer than %d ms in one frame and was stopped",
		what, self.budget_ns / 1_000_000
	);
}

<*
 Whether the value is a promise, or anything else that would want awaiting.

 Duck-typed rather than checked against `Promise`, which is what `await` itself
 does: a hand-rolled thenable would hang the frame exactly as a promise would.
*>
fn bool JsRuntime.is_thenable(&self, qjs::Value value)
{
	if (value.tag() != qjs::TAG_OBJECT) return false;
	qjs::Value then = self.js.property(value, "then");
	defer self.js.release(then);
	return self.js.is_function(then);
}

<*
 Settle whatever the callback queued, inside the same frame.

 A synchronous callback can still create microtasks — `Promise.resolve().then()`
 is one line — and leaving them queued would run them at some arbitrary later
 tick, with the frame log and the frame budget belonging to a different frame.
*>
fn void JsRuntime.drain_frame_jobs(&self)
{
	uint drained = 0;
	while (self.js.jobs_waiting() && drained < JS_FRAME_MAX_JOBS)
	{
		self.js.step_job();
		drained++;
		if (self.timed_out) break;
	}
	if (self.timed_out) self.stop_frame(self.frame_timeout_message());
}

// ============================================================================
// The log the frames write into
// ============================================================================

<*
 Drop the oldest lines once the frame log is over its cap.

 Trimming on a line boundary rather than on a byte matters more than it looks:
 half a line of JSON at the top of a result is the kind of thing an agent tries
 to parse. What is dropped is counted, because a log that silently begins in the
 middle is a log that will be read as the beginning.
*>
fn void JsRuntime.trim_frame_log(&self)
{
	if ((usz)self.frame_log.len() <= JS_FRAME_LOG_BYTES) return;

	String text = self.frame_log.str_view();
	usz cut = text.len - JS_FRAME_LOG_BYTES;
	while (cut < text.len && text[cut] != '\n') cut++;
	if (cut < text.len) cut++;

	long dropped = 0;
	for (usz i = 0; i < cut; i++)
	{
		if (text[i] == '\n') dropped++;
	}
	// One enormous line with no newline in it: something was dropped, so say
	// one rather than none.
	if (dropped == 0) dropped = 1;

	self.frame_dropped += dropped;
	self.frame_log.delete(0, (sz)cut);
}

<*
 Move what the frames logged into the run that is starting.

 **Both halves are labelled.** Unlabelled, the callback's lines arrive above the
 script's own and read as the script's own — an agent debugging its script would
 be reading output from a function it wrote ten calls ago. The markers cost two
 lines and only appear when a frame actually logged something, so a script that
 never touched the animation loop sees exactly what it always saw.
*>
fn void JsRuntime.drain_frame_log(&self)
{
	if (self.frame_log.len() == 0 && self.frame_dropped == 0) return;

	if (self.frame_dropped > 0)
	{
		self.log.appendf("[animation loop, %d earlier lines dropped]\n", self.frame_dropped)!!;
	}
	else
	{
		self.log.append_string("[animation loop]\n");
	}

	String lines = self.frame_log.str_view();
	if (lines.len > 0)
	{
		self.log.append_string(lines);
		// A callback stopped mid-line by the budget leaves one unterminated,
		// and the marker below has to start on its own line regardless.
		if (lines[lines.len - 1] != '\n') self.log.append_char('\n');
	}
	self.log.append_string("[script]\n");

	self.frame_log.clear();
	self.frame_dropped = 0;
}

<*
 Move what the frames said into a host that has a terminal instead of an agent.

 `stop_frame` keeps its reason "for the next run to report", and under `--mcp`
 that is exactly right: nobody is reading a terminal, and the next tool call is
 the first moment anyone is listening. A `--script` or `--assets` boot with no
 listener has no next run at all — the callback dies, the window stops moving,
 and the reason sits in a buffer until the process exits. That is the case this
 exists for, and it is why `main.c3` only calls it when nothing is serving:
 draining it with a server up would take the log away from the agent that is
 about to ask for it.

 The failure comes after the lines rather than before, because it is the last
 thing that happened — a callback logs and *then* throws.

 **Appended, and the caller clears.** One buffer for a whole loop that may run
 for hours is the point; a function that allocated a string per frame would be
 sixty allocations a second to say nothing at all, which is what almost every
 frame has to say.

 @param out : `Appended to. Cleared by the caller, so an empty result is a frame that said nothing.`
*>
fn void JsRuntime.take_frame_output(&self, DString* out)
{
	if (self.frame_dropped > 0)
	{
		out.appendf("[%d earlier lines dropped]\n", self.frame_dropped)!!;
		self.frame_dropped = 0;
	}

	String lines = self.frame_log.str_view();
	if (lines.len > 0)
	{
		out.append_string(lines);
		// A callback stopped mid-line by the budget leaves one unterminated, and
		// whatever is printed next must not continue it.
		if (lines[lines.len - 1] != '\n') out.append_char('\n');
		self.frame_log.clear();
	}

	String why = self.frame_error.str_view();
	if (why.len > 0)
	{
		out.append_string(why);
		if (why[why.len - 1] != '\n') out.append_char('\n');
		self.frame_error.clear();
	}
}

// ============================================================================
// The binding
// ============================================================================

<*
 `__three.setFrame(fn)` — register, replace, or with null stop.

 The type checking that a caller sees lives in `prelude.js` beside the name they
 typed; what is left here is the check that cannot be spelled in JavaScript,
 which is that the thing being retained is callable at all. A script can reach
 `__three` directly and a non-function retained here would throw once a frame
 forever after.
*>
fn void js_set_frame(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	// Whatever happens next, the old one is done — including on the error path,
	// where leaving the previous callback running would make a rejected
	// registration look like it had been accepted.
	self.clear_frame();

	if (argc < 1 || args[0].is_undefined() || args[0].is_null()) return;

	if (!js.is_function(args[0]))
	{
		*out = js.raise("three.setAnimationLoop(fn) wants a function, or null to stop");
		return;
	}

	self.frame_fn = js.retain(args[0]);
	self.frame_active = true;
}

<*
 `__three.setFixed(fn)` — register, replace, or with null stop.

 `js_set_frame`'s shape exactly, and a second callback rather than an argument
 to the first one because the two answer different questions: the animation
 callback runs once a frame and is where a script draws, and this runs however
 many times the clock owes and is where a script *simulates*. A single callback
 told which kind of call it was would be one function with two contracts, and
 the frame-rate independence a fixed step exists for would be an `if` inside it.
*>
fn void js_set_fixed(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	self.clear_fixed();

	if (argc < 1 || args[0].is_undefined() || args[0].is_null()) return;

	if (!js.is_function(args[0]))
	{
		*out = js.raise("three.setFixedLoop(fn) wants a function, or null to stop");
		return;
	}

	self.fixed_fn = js.retain(args[0]);
	self.fixed_active = true;
}

<*
 Move the camera to wherever the thing it is attached to got to this frame.

 `plan.md` §17. A no-op — one boolean — for every scene that has not attached
 anything, which is nearly all of them.

 ## A node that has gone takes the attachment with it

 The camera belongs to the host and survives `new three.Scene()`; the node it was
 following does not, and neither does one that was `remove`d. So the attachment
 is dropped and the camera is left exactly where it was, which is the only
 answer that is not worse: throwing would raise from inside a tick that no script
 called, and keeping a dead `NodeId` would either follow whatever reused the slot
 — the generation check is what stops that — or quietly follow nothing for the
 rest of the session.

 It is dropped *silently*, and `three.camera.attached` reading `null` is how a
 script finds out. A frame log line would be written sixty times a second by the
 one thing that can produce this: a script that destroys what it was following.

 @param dt_ms : `The frame's elapsed milliseconds, for the lag. The same delta the animation step was given.`
*>
fn void JsRuntime.follow_camera(&self, double dt_ms)
{
	if (!self.pass.follow.active) return;

	Node* node = self.pass.scene.node(self.pass.follow.node);
	if (node == null)
	{
		self.pass.follow = {};
		return;
	}

	// The solver writes local transforms and marks nodes dirty; nothing has
	// propagated them to world matrices yet this frame — `Scene.update` does that
	// while building the draw list, which happens after this. Asking here is what
	// makes the anchor this frame's rather than the last one's, and since §19.5 it
	// is not a second walk at all: `Scene.matrices_current` makes the repeat a
	// compare, where before it was the whole traversal with the arithmetic skipped.

	self.pass.scene.update_world_matrices();

	// The whole matrix rather than its translation column, because a follow with
	// `local: true` reads the offset in the node's own frame and the rotation is
	// where that frame lives. `apply_world` pulls the anchor out of it.
	self.pass.follow.apply_world(&self.pass.camera, node.world, (float)dt_ms);

	// The orbit point moved, so the reach the planes were derived against did
	// too. `Controls` calls this after every gesture for the same reason.
	self.pass.derive_camera_planes();
}
