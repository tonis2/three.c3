<*
 The QuickJS context: one engine, one script at a time, and the four things a
 run always answers with.

 ## `run_script` is the whole contract (`plan.md` §4)

 What comes back is everything the script logged, the value it returned, the
 stats block and — from the layer above — a PNG. **All four, every time, whether
 or not the script succeeded.** A failed run that returns only an error string
 makes the agent guess about how far it got, and guessing is what the loop
 exists to remove. `RunResult` therefore has no failure variant: `ok` is a field,
 not a fault.

 ## Every script is an async function body

 The source is wrapped in `(async()=>{` ... `})()` before it is evaluated, which
 buys two things an agent will assume it has:

 - `await` at the top level. `three.load` is synchronous, so nothing here needs
   it — but `const kit = await three.load(...)` is the line an agent that has
   memorized Three.js will write, and a SyntaxError on it would be the API being
   surprising on the first line of the first script.
 - `return` at the top level, which is where the returned value comes from.

 The open brace carries no newline, so a stack trace's line numbers are the
 script's own. The cost is that a bare trailing expression is *not* the result —
 `return` it. That is stated in `getApiDocs()` because it is the one place this
 shape is visible from the outside.

 The alternative was `JS_EVAL_FLAG_ASYNC`, which does this natively, and
 quickjs.c3l's shim does not expose the flag: `qjs_eval` maps its `type` onto
 GLOBAL or MODULE and nothing else. Reaching it would mean changing that
 submodule.

 ## The device gets to speak into the error too

 A validation error caused by the script is the script's error, even though
 nothing in JavaScript threw. `plan.md` §4 asks for exactly that route, and the
 alternative is a message on a terminal nobody is looking at. `collect_validation`
 is where the two meet; the window it covers, and the one it does not, are
 written down there.

 ## A script cannot run forever

 `Context.on_interrupt` is armed for the whole run and is the only thing that
 stops `while (true) {}`. It is checked against a wall-clock budget rather than
 an instruction count because what matters to the caller is the wait, and a
 budget in milliseconds is a number the caller can be told.

 ## The runtime must not move

 `JsRuntime*` is handed to QuickJS as the opaque pointer behind every host
 function and behind the interrupt handler. Copying or reallocating one after
 `open` leaves the engine calling into the old address.
*>
module three;

import std::io;
import std::time;
import std::collections::list;
import qjs;

faultdef JS_ENGINE_FAILED, JS_PRELUDE_FAILED;

// Enough for a scene script and its strings; small enough that a runaway
// allocation is an exception the agent is told about rather than the process
// being killed by the OS.
const usz JS_MEMORY_LIMIT = 64 * 1024 * 1024;
const usz JS_STACK_LIMIT  = 1 * 1024 * 1024;

// How long a script may run before the interrupt handler stops it. Generous for
// anything that only builds a scene, and short enough that a wedged agent loop
// is a five-second pause rather than a hang.
const long JS_BUDGET_MS = 5_000;

// The most a script may raise its own budget to, through `three.budget`.
//
// **The ceiling is the point, not the default.** A script that simulates rather
// than builds — thirty thousand steps of a character against a hundred colliders,
// which is what proved `examples/village`'s collision — needs minutes, and being
// forced to cut that into five-second pieces means cutting it into pieces that
// fit the budget rather than pieces that mean something. But a budget a script
// can raise without limit is no budget: a wedged loop would hang the process,
// and the whole reason the interrupt exists is that it must not.
//
// Ten minutes is longer than any legitimate scene build by two orders of
// magnitude and shorter than a person's patience with a stuck process.
const long JS_BUDGET_CEILING_MS = 600_000;

// A promise chain gets this many microtask steps to settle after the script's
// own body has finished. A script that awaits something that never resolves is
// reported as unfinished rather than spun on.
const uint JS_MAX_JOBS = 100_000;

<*
 The API surface an agent writes against, as JavaScript — ES modules under
 `src/js/prelude/`, embedded whole.

 **`$embed`, and that is not a contradiction of `shader/load.c3`.** The trap that
 file documents is a *generated* artifact — `c3c build shaders` without
 `--trust=full` skips the exec, reports success, and `$embed` picks up the
 previous SPIR-V. The prelude is hand-written source with no build step to skip,
 so it is exactly as stale as the `.c3` files beside it and no more. Embedding it
 means the API surface cannot be missing at runtime, which for the files that
 *define* the API is worth more than editing them without a rebuild.
*>
const char[*] PRELUDE = $embed("prelude/prelude.js");
const char[*] PRELUDE_MATH = $embed("prelude/math.js");
const char[*] PRELUDE_OBJECT3D = $embed("prelude/object3d.js");
const char[*] PRELUDE_TEXTURE = $embed("prelude/texture.js");
const char[*] PRELUDE_MATERIAL = $embed("prelude/material.js");
const char[*] PRELUDE_SHADER = $embed("prelude/shader.js");
const char[*] PRELUDE_LAYERS = $embed("prelude/layers.js");
const char[*] PRELUDE_POST = $embed("prelude/post.js");
const char[*] PRELUDE_MESH = $embed("prelude/mesh.js");
const char[*] PRELUDE_SCENE = $embed("prelude/scene.js");
const char[*] PRELUDE_ASSET = $embed("prelude/asset.js");
const char[*] PRELUDE_GEOMETRY = $embed("prelude/geometry.js");
const char[*] PRELUDE_HELPERS = $embed("prelude/helpers.js");
const char[*] PRELUDE_API = $embed("prelude/api.js");
const char[*] PRELUDE_DOCS = $embed("prelude/docs.js");

<*
 The prelude's modules, by their `three:` specifiers.

 This table is the registry: a part is added here and nowhere else, and a
 specifier it does not know is a load that fails with the engine's own "could
 not load module" naming it — which is the right message for a typo in an
 import inside the prelude, the only place these can be written. The entry is
 not in it, deliberately: it is evaluated directly by `open`, and a part that
 imported it back would re-run nothing and read half-assigned globals.
*>
fn qjs::EmbeddedModule[] prelude_parts()
{
	static qjs::EmbeddedModule[14] parts;
	parts = {
		{ "three:math.js", (char[])PRELUDE_MATH[..] },
		{ "three:object3d.js", (char[])PRELUDE_OBJECT3D[..] },
		{ "three:texture.js", (char[])PRELUDE_TEXTURE[..] },
		{ "three:material.js", (char[])PRELUDE_MATERIAL[..] },
		{ "three:shader.js", (char[])PRELUDE_SHADER[..] },
		{ "three:layers.js", (char[])PRELUDE_LAYERS[..] },
		{ "three:post.js", (char[])PRELUDE_POST[..] },
		{ "three:mesh.js", (char[])PRELUDE_MESH[..] },
		{ "three:scene.js", (char[])PRELUDE_SCENE[..] },
		{ "three:asset.js", (char[])PRELUDE_ASSET[..] },
		{ "three:geometry.js", (char[])PRELUDE_GEOMETRY[..] },
		{ "three:helpers.js", (char[])PRELUDE_HELPERS[..] },
		{ "three:api.js", (char[])PRELUDE_API[..] },
		{ "three:docs.js", (char[])PRELUDE_DOCS[..] },
	};
	return parts[..];
}

<*
 What one script run answers with. Owns all four strings; `free` releases them.
*>
struct RunResult
{
	bool ok;
	// Everything console.log/warn/error wrote, newline separated.
	String log;
	// What the script returned, as JSON. Empty when it returned nothing — which
	// is not the same as returning null, and JSON is why: `null` is four
	// characters and `undefined` has no JSON form at all.
	String value;
	// The message and, when the throw carried one, the stack. Empty when `ok`.
	String error;
	SceneStats stats;
	// What the GPU spent on the last frame this run drew, in milliseconds, and 0
	// when it drew none or when there is no device to measure — `gpu/timing.c3`
	// argues which frame that is. Beside `stats` rather than inside it: a
	// `SceneStats` is a fact about the scene and is produced with no device at
	// all, so the two are joined here, where the runtime can see both.
	double gpu_ms;

	// What the animation loop did between the last run and this one, which is
	// the only window an agent has onto it: nothing else reports a callback that
	// has been quietly running — or quietly stopped — since the last tool call.
	// `js/frame_loop.c3` fills these in and says why each one is here.
	bool frame_running;
	long frame_ticks;
	// Frames that ran past JS_GAME_FRAME_SOFT_MS, in a game boot. Always zero
	// under `--mcp` alone, where an overrun is a stop rather than a statistic.
	long frame_overruns;
	// Why the callback was stopped, empty when it was not. Reported exactly
	// once: whichever run reads it clears it.
	String frame_error;
}

<*
 Release all four strings.

 **Guarded on the pointer, not on the length**, and that distinction is the whole
 reason this comment exists: `DString.copy_str` allocates even for an empty
 string — one byte, for the terminator — so `if (len > 0)` frees three of these
 and leaks whichever ones a run left empty. Which is most runs: a script that
 succeeds has no `error`, and one that returns nothing has no `value`. The leak
 is a byte at a time, invisible in a test that runs a script once, and
 unbounded in an agent loop.

 `quickjs.c3l`'s `Context.text` documents the same rule from the other side:
 always allocate, so the caller can always free.
*>
fn void RunResult.free(&self)
{
	if (self.log.ptr != null) self.log.free(mem);
	if (self.value.ptr != null) self.value.free(mem);
	if (self.error.ptr != null) self.error.free(mem);
	if (self.frame_error.ptr != null) self.frame_error.free(mem);
	*self = {};
}

<*
 One engine, and the host state it drives.

 `pass` is required and `renderer` is not: the scene graph, the handles, the
 staleness checks and `stats()` are all reachable with no Vulkan device at all,
 which is what lets most of the binding suite run in microseconds with no GPU.
 `load` and `render` are the two verbs that need the device, and they say so.
*>
struct JsRuntime
{
	qjs::Context js;
	MeshPass* pass;

	Renderer* renderer;

	DString log;
	DString value;
	DString error;

	// What a *script* gets, as opposed to what a frame callback gets. Raisable
	// from JavaScript through `three.budget`, because 5,000 ms is generous for
	// building a scene and short for simulating thirty thousand steps of one —
	// the first collision sweep over `examples/village` was killed by it and had
	// to be cut into pieces that fit the budget rather than pieces that meant
	// something. `JS_BUDGET_CEILING_MS` is what keeps it from becoming a hang.
	//
	// Separate from `budget_ns` on purpose: `frame_loop.c3` overwrites that one
	// per frame, so a raised script budget must not silently become a raised
	// per-frame allowance and let one callback wedge a game.
	long script_budget_ns;
	// The run's wall-clock budget. `started` is stamped at the top of `run`.
	Clock started;
	long budget_ns;
	bool timed_out;

	bool settled;
	bool rejected;

	// Bumped by `new three.Scene()`. A Scene object stamped with an older one
	// throws instead of silently operating on the newer scene's nodes.
	double epoch;

	// The animation loop, all of it owned by `js/frame_loop.c3`. `frame_fn` is a
	// retained reference and is only meaningful while `frame_active`; releasing
	// it is the one piece of cleanup that has to happen before the context
	// closes rather than after, which is why `close` below leads with it.
	qjs::Value frame_fn;
	bool frame_active;
	// The fixed loop, the same way. Separate from `frame_fn` because they are
	// called a different number of times with a different argument — the clock
	// decides how many of these a frame owes, and `scene/clock.c3` has why the
	// accumulator that decides it is here rather than in the script.
	qjs::Value fixed_fn;
	bool fixed_active;
	bool in_frame;
	long frame_ticks;
	DString frame_log;
	long frame_dropped;
	DString frame_error;
	// The game frame policy, set by `--assets` through `set_assets_root`.
	// `game.md` G1/S4: a game is warned and counted where an agent is stopped.
	bool game_frames;
	long frame_overruns;
	bool frame_overrun_warned;

	// The keyboard, owned by `js/bind_input.c3`. `input` is one frame old at
	// worst and is replaced whole by every tick; `input_text` backs its `text`,
	// which would otherwise point into a window buffer that clears itself.
	InputState input;
	// Keys a script is holding down through `three.input.press`. Merged into
	// every frame beside the window's own, which is what makes an input-driven
	// scene testable without a keyboard — `SyntheticKeys` has the argument.
	SyntheticKeys synthetic;
	DString input_text;
	KeyHandler[MAX_KEY_HANDLERS] key_handlers;
	usz key_handler_count;

	// The click handler, also `js/bind_input.c3`'s. Retained like `frame_fn`,
	// only meaningful while `click_active`, and released with the other two
	// before the context closes.
	qjs::Value click_fn;
	bool click_active;

	// The turntable's hand on the window — `scene/controls.c3`.
	//
	// **It lives here because `enabled` has to survive having no window.** A
	// script says `three.controls.enabled = false` under `--mcp --headless` as
	// readily as it does with a window open, and a flag stored in the window's
	// loop would have nowhere to be written to and would read back as whatever
	// it was — the property that reads back what you did not write, which is the
	// trap `api.js` throws on assignment to avoid three times over.
	//
	// So the runtime owns the whole struct and `main.c3`'s loop drives *this*
	// one rather than a local of its own. The drag anchor coming along for the
	// ride is the price of there being exactly one of these; two would be two
	// answers to `three.controls.enabled`, which is the thing being prevented.
	// `run()` — a window with no JavaScript in it — keeps its own, and the type
	// stays independent of both.
	Controls controls;

	// The physics world, owned by `scene/physics.c3` and stepped by `tick`.
	// On the runtime rather than on the scene because it is the frame that
	// advances it, and `new three.Scene()` empties it for the same reason it
	// empties everything else: the bodies named nodes that are gone.
	Physics physics;
	// The event handlers physics dispatches into — `js/bind_physics.c3`.
	qjs::Value trigger_fn;
	bool trigger_active;
	qjs::Value contact_fn;
	bool contact_active;

	// `import`, wired up by `js/modules.c3` over `quickjs.c3l`'s loader. Empty
	// root means no `--assets` boot and no disk imports at all, which is what a
	// plain `--mcp` run wants; the `three:` space works regardless.
	// **Addressed by the engine and must not move** while the context is open —
	// the same requirement `main.c3` meets for the `Renderer` the server holds.
	qjs::ModuleLoader modules;

	bool ready;
}

<*
 Start the engine and install the API.

 @param pass : `The scene, assets and camera the bindings drive. Must outlive the runtime.`
 @param renderer : `Null for a context with no device: three.load and three.render then throw, and everything else works.`
 @return? JS_ENGINE_FAILED : `QuickJS could not be created — out of memory, and nothing else.`
 @return? JS_PRELUDE_FAILED : `prelude.js did not evaluate. A bug here, not in anything a caller passed.`
*>
fn void? JsRuntime.open(&self, MeshPass* pass, Renderer* renderer = null)
{
	self.js = qjs::open(JS_MEMORY_LIMIT, JS_STACK_LIMIT)!;
	self.pass = pass;
	self.renderer = renderer;
	self.controls = DEFAULT_CONTROLS;
	// Started here as well as in `MeshPass.init`, because a `MeshPass` built by
	// hand — which is every check in `test/` that needs no device — never runs
	// that, and the zero value of a `GameClock` is a clock stopped at nought
	// hertz. Both callers run once, before anything can have set a scale.
	//
	// Null is a real configuration: `open(null)` is a context with no scene at
	// all, which is what the module-loader checks want and what nothing that
	// boots does. It has no clock either, and the clock verbs say so.
	if (pass != null) pass.clock.defaults();

	self.log.init(mem, 1024);
	self.value.init(mem, 256);
	self.error.init(mem, 256);
	self.frame_log.init(mem, 512);
	self.frame_error.init(mem, 128);
	self.input_text.init(mem, 64);
	self.frame_fn = qjs::undefined_value();
	self.click_fn = qjs::undefined_value();
	self.script_budget_ns = JS_BUDGET_MS * 1_000_000;
	self.budget_ns = self.script_budget_ns;
	self.epoch = 1;
	self.ready = true;

	self.install_console();
	self.install_bindings();
	// Before the prelude: its own imports are the first thing the loader answers.
	self.install_module_hooks();

	// Evaluated as the entry of the `three:` module space rather than through
	// `run`: it declares the API, so an async function body would scope every
	// class to that body, and its `import`s must sit at a module's top level.
	// Module evaluation answers with a promise even when nothing awaits, so the
	// result goes through the same settling `run_module` uses — a throw during
	// evaluation is a rejection there, not a synchronous exception here.
	RunResult booted = self.run_source((String)PRELUDE[..], "three:prelude.js", drain_frame: false, as_module: true);
	defer booted.free();
	if (!booted.ok)
	{
		io::printfn("three: prelude.js failed to evaluate: %s", booted.error);
		return JS_PRELUDE_FAILED~;
	}

	self.js.on_interrupt(&on_interrupt, self);
}

fn void JsRuntime.close(&self)
{
	if (!self.ready) return;
	// Before the context goes, not after: every one of these releases a
	// reference into an engine that would no longer be there to release it into.
	self.clear_frame();
	self.clear_fixed();
	self.clear_key_handlers();
	self.clear_click_handler();
	self.clear_physics_handlers();
	self.js.close();
	self.physics.close();
	self.log.free();
	self.value.free();
	self.error.free();
	self.frame_log.free();
	self.frame_error.free();
	self.input_text.free();
	self.modules.free();
	*self = {};
}

<*
 Run one script and answer with all four fields.

 @param source : `The script. Evaluated as an async function body — see the header.`
 @param name : `What a stack trace calls it. Never opened.`
 @param drain_frame : `False for a run the caller made up rather than one the agent asked for — it then neither reports nor consumes what the animation loop has been doing. See js/frame_loop.c3.`
 @return `Owned by the caller; free it with RunResult.free.`
*>
fn RunResult JsRuntime.run(&self, String source, String name = "<script>", bool drain_frame = true)
{
	return self.run_source(source, name, drain_frame, as_module: false);
}

<*
 Run `source` as an ES module — `game.md` G1/S3, and the shape `main.js` takes.

 **Not the async wrapper `run` uses**, and the difference is not cosmetic: a
 module's `import` declarations must be at its top level, so wrapping one in a
 function body is a syntax error before it is anything else. What the two share
 is everything after evaluation, because module evaluation hands back a promise
 exactly as the wrapper does — top-level `await` is a module's by right rather
 than by a trick.

 `three` reaches it as a global, which is why there is no import of it and no
 module named for it. See `js/modules.c3`.

 @param specifier : `Root-relative, and also what a stack trace calls it and what its own imports resolve against.`
 @require self.modules.root.len > 0 : "a module needs an assets root to resolve against"
*>
fn RunResult JsRuntime.run_module(&self, String specifier)
{
	String? source = self.modules.read(specifier);
	if (catch err = source)
	{
		self.log.clear();
		self.value.clear();
		self.error.clear();
		self.error.appendf("could not read %s: %s", specifier, err)!!;
		self.rejected = true;
		self.settled = false;
		return {
			.ok = false,
			.log = self.log.copy_str(mem),
			.value = self.value.copy_str(mem),
			.error = self.error.copy_str(mem),
			.frame_error = self.frame_error.copy_str(mem),
		};
	}
	// Copied off the shared buffer before evaluating: the module's own imports
	// are loaded during the parse and each one overwrites it.
	@pool()
	{
		return self.run_source(source.copy(tmem), specifier, drain_frame: true, as_module: true);
	};
}

fn RunResult JsRuntime.run_source(&self, String source, String name, bool drain_frame, bool as_module)
{
	self.log.clear();
	self.value.clear();
	self.error.clear();
	// Into the log before the script has written a line of its own, so the two
	// arrive in the order they happened. `drain_frame_log` labels both halves.
	if (drain_frame) self.drain_frame_log();
	// The fourth thing cleared, for the same reason as the other three: what the
	// device complained about during *this* run is what this run answers with.
	// See `collect_validation`.
	if (self.renderer != null) self.renderer.gpu.begin_capture();
	self.timed_out = false;
	self.settled = false;
	self.rejected = false;
	// A script's budget, not a frame's. `frame_loop.c3` writes `budget_ns` per
	// frame from its own constant and this puts it back for the next run, so the
	// two cannot bleed into one another in either direction.
	self.budget_ns = self.script_budget_ns;
	self.started = clock::now();

	@pool()
	{
		// No newline after the brace: the script's line 1 stays line 1 in every
		// stack trace. See the header. A module needs neither — its top level is
		// already async and its line 1 is already its own.
		String wrapped = as_module ? source : string::tformat("(async()=>{%s\n})()", source);

		qjs::Value? started = self.js.eval(wrapped, name, as_module ? qjs::EVAL_MODULE : qjs::EVAL_GLOBAL);
		if (catch err = started)
		{
			// A parse error, or a throw before the first await — the async
			// wrapper does not catch either, because neither happens inside the
			// function body's execution.
			String message = self.js.exception(mem);
			defer message.free(mem);
			self.error.append_string(self.timed_out ? self.timeout_message() : message);
			self.rejected = true;
			self.settled = true;
		}
		else
		{
			defer self.js.release(started);
			self.await_settled(started);
		}
	};

	self.collect_validation();

	SceneStats stats = self.pass != null ? self.pass.stats() : (SceneStats){};

	// Always copied, cleared only when this run is the agent's. Copying is free
	// of consequence and the clear is not: a stopped callback has to be
	// explained to exactly one caller, or an old failure looks like a new one on
	// every tool call afterwards.
	//
	// The copy is unconditional for a second reason. `RunResult.free` frees
	// whatever pointer it finds, and a `""` literal has a perfectly good pointer
	// into static memory — the one shape of empty string that must never reach
	// it.
	String frame_error = self.frame_error.copy_str(mem);
	long frame_ticks = self.frame_ticks;
	long frame_overruns = self.frame_overruns;
	if (drain_frame)
	{
		self.frame_error.clear();
		self.frame_ticks = 0;
		self.frame_overruns = 0;
	}

	return {
		.ok = !self.rejected && self.settled,
		.log = self.log.copy_str(mem),
		.value = self.value.copy_str(mem),
		.error = self.error.copy_str(mem),
		.stats = stats,
		.gpu_ms = self.renderer != null ? self.renderer.gpu_ms() : 0.0,
		.frame_running = self.frame_active,
		.frame_ticks = frame_ticks,
		.frame_overruns = frame_overruns,
		.frame_error = frame_error,
	};
}

<*
 Attach handlers to the script's promise and run the microtask queue until it
 settles.

 Reading the result through `then` rather than through `JS_PromiseResult` is not
 a preference: the shim does not export the promise-state calls, and the two that
 would do it pass `JSValue` by value — which is the ABI bet the whole shim exists
 to avoid.
*>
fn void JsRuntime.await_settled(&self, qjs::Value promise)
{
	qjs::Value then = self.js.property(promise, "then");
	defer self.js.release(then);

	if (!self.js.is_function(then))
	{
		// Cannot happen with the async wrapper in place, and is a clear message
		// rather than a silent empty result if it ever does.
		self.error.append_string("the script did not produce a promise");
		self.rejected = true;
		self.settled = true;
		return;
	}

	qjs::Value on_ok = self.js.function(&js_settled, "resolve", 1, self);
	qjs::Value on_err = self.js.function(&js_rejected, "reject", 1, self);
	defer self.js.release(on_ok);
	defer self.js.release(on_err);

	qjs::Value[2] handlers = { on_ok, on_err };
	qjs::Value? attached = self.js.call(then, promise, handlers[..]);
	if (catch err = attached)
	{
		String message = self.js.exception(mem);
		defer message.free(mem);
		self.error.append_string(message);
		self.rejected = true;
		self.settled = true;
		return;
	}
	self.js.release(attached);

	uint drained = 0;
	while (self.js.jobs_waiting() && drained < JS_MAX_JOBS)
	{
		self.js.step_job();
		drained++;
		if (self.timed_out) break;
	}

	if (self.timed_out)
	{
		self.error.clear();
		self.error.append_string(self.timeout_message());
		self.rejected = true;
		self.settled = true;
		return;
	}

	if (!self.settled)
	{
		// An await on something that never resolves. Worth its own sentence:
		// "no error and no value" is otherwise indistinguishable from a script
		// that returned nothing.
		self.error.append_string(
			"the script never finished — it is awaiting something that will not resolve"
		);
		self.rejected = true;
		self.settled = true;
	}
}

<*
 Read off `budget_ns` rather than off `JS_BUDGET_MS`, because there are now two
 budgets: a script's, and the much shorter one a frame callback runs under
 (`js/frame_loop.c3`). A message naming a constant the run did not use is worse
 than no number at all — it sends the reader looking for a five-second pause
 that never happened.
*>
fn String JsRuntime.timeout_message(&self)
{
	return string::tformat("the script ran for longer than %d ms and was stopped", self.budget_ns / 1_000_000);
}

<*
 Fold what the validation layer said during the run into the run's answer.

 This is `plan.md` §4's "routes validation errors into the thrown JS exception".
 **An ERROR fails the run**, because a run that reports `ok: true` beside a frame
 the driver refused to draw is the loop lying to the agent, and the agent has no
 other way to find out. A WARNING does not fail it: a warning is advice, and an
 agent that cannot tell advice from a defect stops believing either. So warnings
 go where the script's own `console.warn` would have gone.

 **The script's own error is kept.** Validation text is appended after it, never
 in place of it — they are two different facts, and the second rarely explains
 the first. A script that threw *because* the render failed needs both halves to
 say so.

 The sink is read **before** capture is released. In between, a message would
 take the messenger's printing path and be gone; the two statements are adjacent
 and on one thread, so in between is nothing, and it stays nothing only because
 the order is written down.

 What this does not reach: anything the layer says *after* the run returns.
 `mcp/server.c3` renders the reply's PNG once the RunResult has been built, and
 a message from that render lands in a buffer the next `begin_capture` clears. A
 script that calls `three.render()` itself is inside the window — `render_offscreen`
 waits on its fence — which is what makes the messages attributable at all.
*>
fn void JsRuntime.collect_validation(&self)
{
	if (self.renderer == null) return;
	Gpu* gpu = &self.renderer.gpu;
	if (!gpu.validation) return;

	String warnings = gpu.sink.warnings.str_view();
	if (warnings.len > 0) self.log.append_string(warnings);

	String errors = gpu.sink.errors.str_view();
	if (errors.len > 0)
	{
		if (self.error.len() > 0) self.error.append_char('\n');
		// The sink newline-terminates its lines so they stack; an error is one
		// string handed to one caller and should not trail off into one.
		self.error.append_string(errors[errors.len - 1] == '\n' ? errors[:errors.len - 1] : errors);
		self.rejected = true;
		self.settled = true;
	}

	gpu.end_capture();
}

// ============================================================================
// The engine's callbacks
// ============================================================================

<*
 Called between bytecode instructions; non-zero aborts the script.

 Must not call back into the context, which is why it only reads a clock and
 sets a flag.
*>
fn int on_interrupt(qjs::Runtime runtime, void* opaque) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	if (self == null || self.budget_ns <= 0) return 0;
	if ((long)self.started.to_now() < self.budget_ns) return 0;
	self.timed_out = true;
	return 1;
}

fn void js_settled(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	self.settled = true;
	self.rejected = false;

	if (argc < 1) return;
	// `undefined` has no JSON form, which is exactly the answer wanted for a
	// script that returned nothing: an empty `value`, distinguishable from the
	// four characters `null`.
	String json = js.json(args[0], mem);
	defer json.free(mem);
	self.value.append_string(json);
}

fn void js_rejected(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	self.settled = true;
	self.rejected = true;

	if (argc < 1)
	{
		self.error.append_string("the script rejected with nothing");
		return;
	}

	String described = describe_throw(&js, args[0], mem);
	defer described.free(mem);
	self.error.append_string(described);
}

<*
 A thrown value as a sentence, with its stack when it carried one.

 `Context.exception` does this for the *pending* exception; a rejection arrives
 as an ordinary argument instead, so the same walk is repeated here rather than
 reached.
*>
fn String describe_throw(qjs::Context* js, qjs::Value thrown, Allocator allocator) @local
{
	String message = js.text(thrown, allocator);
	if (qjs::qjs_is_error(js.ctx, &thrown) == 0) return message;

	qjs::Value stack = js.property(thrown, "stack");
	defer js.release(stack);
	if (stack.is_undefined()) return message;

	String trace = js.text(stack, allocator);
	defer trace.free(allocator);
	if (trace.len == 0) return message;

	String joined = string::format(allocator, "%s\n%s", message, trace);
	message.free(allocator);
	return joined;
}

// ============================================================================
// console
// ============================================================================

<*
 `console.log` and friends, all writing into the run's log.

 Nothing reaches stdout: the log is one of the four things a run answers with,
 and a script driven over JSON-RPC has no terminal to print to. A host that
 wants it on screen prints `RunResult.log`.

 **There are two logs, and `in_frame` picks between them.** A line written from
 inside an animation callback belongs to no run — the run that would have owned
 it finished long ago — so it goes to the bounded `frame_log` that the next run
 drains. Sending it to `self.log` instead would either flood the next result
 with sixty frames a second of output or, worse, be cleared unread at the top of
 that run. See `js/frame_loop.c3`.
*>
fn void JsRuntime.install_console(&self)
{
	qjs::Value global = self.js.global();
	defer self.js.release(global);

	qjs::Value console = self.js.object();
	self.js.set_property(console, "log", self.js.function(&js_console, "log", 1, self));
	self.js.set_property(console, "info", self.js.function(&js_console, "info", 1, self));
	self.js.set_property(console, "warn", self.js.function(&js_console, "warn", 1, self));
	self.js.set_property(console, "error", self.js.function(&js_console, "error", 1, self));
	self.js.set_property(console, "debug", self.js.function(&js_console, "debug", 1, self));
	self.js.set_property(global, "console", console);
}

fn void js_console(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	DString* sink = self.in_frame ? &self.frame_log : &self.log;

	for (int i = 0; i < argc; i++)
	{
		if (i > 0) sink.append_char(' ');
		String text = display(&js, args[i], mem);
		defer text.free(mem);
		sink.append_string(text);
	}
	sink.append_char('\n');
}

<*
 A value the way a log wants to read it.

 Objects and arrays go through JSON rather than `String(value)`, because
 `console.log(scene.stats())` printing `[object Object]` would make the one call
 an agent makes to see its own cost useless. Errors are the exception: their JSON
 is `{}` and their string form is the message.
*>
fn String display(qjs::Context* js, qjs::Value value, Allocator allocator) @local
{
	if (value.tag() == qjs::TAG_OBJECT
		&& qjs::qjs_is_error(js.ctx, &value) == 0
		&& !js.is_function(value))
	{
		String json = js.json(value, allocator);
		if (json.len > 0) return json;
		json.free(allocator);
	}
	return js.text(value, allocator);
}
