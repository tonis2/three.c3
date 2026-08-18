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
import qjs;

// What one tick may take before the interrupt handler stops it. Two orders of
// magnitude under a script's budget and one over a frame, which is the gap this
// number wants to sit in: it cannot be reached by anything that is merely slow
// — a callback taking 100 ms has already made the window a slideshow, and
// killing it for that would be the host overruling the author — and it bounds a
// `while (true) {}` to a tenth of a second instead of five.
const long JS_FRAME_BUDGET_MS = 100;

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

 @param elapsed_ms : `What the callback is told, as Three.js's setAnimationLoop tells it: milliseconds, monotonic, from whenever the host started counting.`
 @param input : `This frame's keyboard and mouse. Default-empty, for a host that has no window and for the checks that only care about the callback.`
 @return `true when something ran, false when nothing is registered — so a caller can tell an idle loop from a running one without asking twice.`
*>
fn bool JsRuntime.tick(&self, double elapsed_ms, InputState input = {})
{
	self.take_input(input);
	if (!self.frame_active && self.key_handler_count == 0 && !self.click_active) return false;

	self.frame_ticks++;

	// The script budget is borrowed, not replaced: `budget_ns` is what the one
	// interrupt handler reads, and a run may have set its own. Saving it here
	// rather than reaching for `JS_BUDGET_MS` is what keeps a caller's shorter
	// budget theirs.
	long budget = self.budget_ns;
	self.budget_ns = JS_FRAME_BUDGET_MS * 1_000_000;
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
	if (!self.timed_out && self.frame_active) self.call_frame(elapsed_ms);
	if (!self.timed_out) self.drain_frame_jobs();

	self.in_frame = false;
	self.budget_ns = budget;
	self.trim_frame_log();
	return true;
}

<*
 The animation callback, called once.
*>
fn void JsRuntime.call_frame(&self, double elapsed_ms)
{
	@pool()
	{
		qjs::Value[1] args = { qjs::number_value(elapsed_ms) };
		qjs::Value? answer = self.js.call(self.frame_fn, qjs::undefined_value(), args[..]);

		if (catch err = answer)
		{
			self.stop_frame(self.timed_out
				? self.frame_timeout_message()
				: string::tformat("the animation callback threw and was stopped: %s", self.js.exception(tmem)));
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
				self.stop_frame(
					"the animation callback returned a promise. It has to finish inside the frame, "
					"so it must be synchronous — do the awaiting in a run_script instead"
				);
			}
		}
	};
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
fn String JsRuntime.frame_timeout_message(&self)
{
	return string::tformat(
		"the animation callback ran for longer than %d ms in one frame and was stopped",
		self.budget_ns / 1_000_000
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
