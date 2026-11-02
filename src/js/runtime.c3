<*
 The QuickJS context: one engine, one script at a time, and everything a run
 always answers with.

 ## `run_script` is the whole contract

 What comes back is everything the script logged, the value it returned, the
 stats block and — from the layer above — a PNG. All of it, every time, whether
 or not the script succeeded. A failed run that returns only an error string
 makes the agent guess about how far it got. `RunResult` therefore has no failure
 variant: `ok` is a field, not a fault.

 `warnings` is the fifth, and empty on nearly every run: what the renderer
 noticed while the script ran, which before `advice.c3` went to stderr and
 therefore nowhere an agent could read. `collect_advice` has the window.

 ## Every script is an async function body

 The source is evaluated with `qjs::EVAL_ASYNC`, as the body of an async function
 that is called at once, which buys two things an agent will assume it has:

 - `await` at the top level. `three.load` is synchronous, so nothing here needs
 it — but `const kit = await three.load(...)` is the line an agent that has
 memorised Three.js will write, and a SyntaxError on it would be the API being
 surprising on the first line of the first script.
 - `return` at the top level, which is where the returned value comes from.

 A stack trace's line and column numbers are the script's own. The cost is that
 a bare trailing expression is *not* the result — `return` it. `run_script`'s
 input schema says so (`src/mcp/server.c3`), the one place this shape is visible
 from outside.

 ## The device gets to speak into the error too

 A validation error caused by the script is the script's error, even though
 nothing in JavaScript threw. `collect_validation` is where the two meet; the
 window it covers, and the one it does not, are written down there.

 ## A script cannot run forever

 `Context.on_interrupt` is armed for the whole run and is the only thing that
 stops `while (true) {}`. It is checked against a wall-clock budget rather than
 an instruction count, because what matters to the caller is the wait and a
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
import std::collections::map;
import qjs;
import fastjs::js;
import c3w;

faultdef JS_ENGINE_FAILED, JS_PRELUDE_FAILED;

// Enough for a scene script and its strings; small enough that a runaway
// allocation is an exception the agent is told about rather than the process
// being killed by the OS.
const usz JS_MEMORY_LIMIT = 64 * 1024 * 1024;

// How long a script may run before the interrupt handler stops it. Generous for
// anything that only builds a scene, and short enough that a wedged agent loop is
// a five-second pause rather than a hang.
const long JS_BUDGET_MS = 5_000;

<*
 What a `run_script` gets instead, before the script says otherwise.

 The default above is protecting an interactive window from a wedged loop: five
 seconds is how long a person watching the frame should have to wait for a
 mistake. A tool call is not that case. It is already asynchronous to whoever
 made it, it is under the client's own timeout, and the thing it most often does
 is the one thing five seconds is genuinely tight for — a cold build, paying for
 shader compiles and texture uploads a warm process already paid, timing out at
 5,000 ms on the first call and returning in time on the second.

 So the MCP path raises the *default* rather than the ceiling. `three.budget`
 still works, still clamps at `JS_BUDGET_CEILING_MS`, and still takes effect on
 the run that sets it; the frame callback keeps its own 100 ms, which is the
 budget that was never about this. What changes is only what a script gets for
 not having said anything.
*>
const long JS_MCP_BUDGET_MS = 30_000;

// The most a script may raise its own budget to, through `three.budget`.
// 
// The ceiling is the point, not the default. A script that simulates rather than
// builds — thirty thousand steps of a character against a hundred colliders —
// needs minutes, and forcing that into five-second pieces means cutting it into
// pieces that fit the budget rather than pieces that mean something. But a budget
// a script can raise without limit is no budget.
// 
// Ten minutes is longer than any legitimate scene build by two orders of
// magnitude and shorter than a person's patience with a stuck process.
const long JS_BUDGET_CEILING_MS = 600_000;

// A promise chain gets this many microtask steps to settle after the script's own
// body has finished. A script that awaits something that never resolves is
// reported as unfinished rather than spun on.
const uint JS_MAX_JOBS = 100_000;

<*
 The API surface an agent writes against, as JavaScript — ES modules under
 `src/js/prelude/`, embedded whole.

 `$embed` here is not a contradiction of `shader/load.c3`. That trap needs a
 *generated* artifact whose build step can be silently skipped; the prelude is
 hand-written source with no build step, so it is exactly as stale as the `.c3`
 files beside it. Embedding it means the API surface cannot be missing at
 runtime, which for the files that *define* the API is worth more than editing
 them without a rebuild.

 The API's docs are not among them. They are the Markdown in `docs/`, read
 where it lies: the MCP server names the folder in `run_script`'s description,
 and a release ships it beside the binary.
*>
const char[*] PRELUDE          = $embed("prelude/prelude.js");
const char[*] PRELUDE_MATH     = $embed("prelude/math.js");
const char[*] PRELUDE_OBJECT3D = $embed("prelude/object3d.js");
const char[*] PRELUDE_TEXTURE  = $embed("prelude/texture.js");
const char[*] PRELUDE_MATERIAL = $embed("prelude/material.js");
const char[*] PRELUDE_SHADER   = $embed("prelude/shader.js");
const char[*] PRELUDE_LAYERS   = $embed("prelude/layers.js");
const char[*] PRELUDE_POST     = $embed("prelude/post.js");
const char[*] PRELUDE_MESH     = $embed("prelude/mesh.js");
const char[*] PRELUDE_SCENE    = $embed("prelude/scene.js");
const char[*] PRELUDE_ASSET    = $embed("prelude/asset.js");
const char[*] PRELUDE_LEVEL    = $embed("prelude/level.js");
const char[*] PRELUDE_GEOMETRY = $embed("prelude/geometry.js");
const char[*] PRELUDE_FIELD    = $embed("prelude/field.js");
const char[*] PRELUDE_HELPERS  = $embed("prelude/helpers.js");
const char[*] PRELUDE_COMPUTE  = $embed("prelude/compute.js");
const char[*] PRELUDE_QUERY    = $embed("prelude/query.js");
const char[*] PRELUDE_NAV      = $embed("prelude/nav.js");
const char[*] PRELUDE_PHYSICS  = $embed("prelude/physics.js");
const char[*] PRELUDE_SYSTEMS  = $embed("prelude/systems.js");
const char[*] PRELUDE_ENTITY   = $embed("prelude/entity.js");
const char[*] PRELUDE_COOLDOWN = $embed("prelude/cooldown.js");
const char[*] PRELUDE_DECORATORS = $embed("prelude/decorators.js");
const char[*] PRELUDE_API      = $embed("prelude/api.js");
const char[*] PRELUDE_UI       = $embed("prelude/ui.js");
const char[*] PRELUDE_WIDGET   = $embed("prelude/widget.js");

<*
 The prelude's modules, by their `three:` specifiers.

 This table is the registry: a part is added here and nowhere else, and a
 specifier it does not know is a load that fails with the engine's own "could not
 load module" naming it — the right message for a typo in an import inside the
 prelude, the only place these can be written. The entry is deliberately not in
 it: it is evaluated directly by `open`, and a part that imported it back would
 re-run nothing and read half-assigned globals.
*>
fn qjs::EmbeddedModule[] prelude_parts()
{
	static qjs::EmbeddedModule[25] parts;
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
		{ "three:level.js", (char[])PRELUDE_LEVEL[..] },
		{ "three:geometry.js", (char[])PRELUDE_GEOMETRY[..] },
		{ "three:field.js", (char[])PRELUDE_FIELD[..] },
		{ "three:helpers.js", (char[])PRELUDE_HELPERS[..] },
		{ "three:compute.js", (char[])PRELUDE_COMPUTE[..] },
		{ "three:query.js", (char[])PRELUDE_QUERY[..] },
		{ "three:nav.js", (char[])PRELUDE_NAV[..] },
		{ "three:physics.js", (char[])PRELUDE_PHYSICS[..] },
		{ "three:systems.js", (char[])PRELUDE_SYSTEMS[..] },
		{ "three:entity.js", (char[])PRELUDE_ENTITY[..] },
		{ "three:cooldown.js", (char[])PRELUDE_COOLDOWN[..] },
		{ "three:decorators.js", (char[])PRELUDE_DECORATORS[..] },
		{ "three:ui.js", (char[])PRELUDE_UI[..] },
		{ "three:widget.js", (char[])PRELUDE_WIDGET[..] },
		{ "three:api.js", (char[])PRELUDE_API[..] },
	};
	return parts[..];
}

<*
 What one script run answers with. Owns every string in it; `free` releases them.
*>
struct RunResult
{
	bool ok;
	// Everything console.log/warn/error wrote, newline separated.
	String log;
	// What the script returned, as JSON. Empty when it returned nothing — which is
	// not the same as returning null, and JSON is why: `null` is four characters
	// and `undefined` has no JSON form at all.
	String value;
	// What `three.debug.write` collected, as a JSON array. Empty when nothing was
	// written, and a different fact from `value`: this is what the script SAID on
	// its way through, `value` is what it answered with at the end.
	String debug;
	// The message and, when the throw carried one, the stack. Empty when `ok`.
	String error;
	<*
	 What the renderer noticed while this ran, one message per line.

	 Beside `log` rather than in it, which is the whole point of it: these are the
	 heuristics that watch for a leak and they are advice, not output. `advice.c3`
	 has the argument and the sink; `collect_advice` has the window this covers.

	 Empty on almost every run — advice is rare and deduplicated, so a run that
	 provokes none says nothing.
	*>
	String warnings;
	SceneStats stats;
	// What the GPU spent on the last frame this run drew, split by pass, in
	// milliseconds — all zero when it drew none or when there is no device to
	// measure. Beside `stats` rather than inside it: a `SceneStats` is a fact
	// about the scene and is produced with no device at all.
	FrameTiming timing;

	// What the animation loop did between the last run and this one, which is the
	// only window an agent has onto it: nothing else reports a callback that has
	// been quietly running — or quietly stopped — since the last tool call.
	bool frame_running;
	long frame_ticks;
	// Frames that ran past JS_GAME_FRAME_SOFT_MS, in a game boot. Always zero
	// under `--mcp` alone, where an overrun is a stop rather than a statistic.
	long frame_overruns;
	// Why the callback was stopped, empty when it was not. Reported exactly once:
	// whichever run reads it clears it.
	String frame_error;
}

<*
 Releases every string.

 Guarded on the pointer, not on the length. `DString.copy_str` allocates even for
 an empty string — one byte, for the terminator — so `if (len > 0)` frees three
 of these and leaks whichever ones a run left empty. Which is most runs: a script
 that succeeds has no `error`, and one that returns nothing has no `value`. The
 leak is a byte at a time, invisible in a test that runs a script once, and
 unbounded in an agent loop.
*>
fn void RunResult.free(&self)
{
	if (self.log.ptr != null) self.log.free(mem);
	if (self.value.ptr != null) self.value.free(mem);
	if (self.debug.ptr != null) self.debug.free(mem);
	if (self.error.ptr != null) self.error.free(mem);
	if (self.warnings.ptr != null) self.warnings.free(mem);
	if (self.frame_error.ptr != null) self.frame_error.free(mem);
	*self = { };
}

<*
 A JavaScript function the runtime holds on to and calls back later: a loop, a
 click handler, a physics event. Only meaningful while `active`.
*>
struct HeldFn
{
	js::Root callback;
	bool active;
}

fn HeldFn held_nothing() => { };

// Replaces whatever was held with `value`.
fn void HeldFn.hold(&self, js::Engine* js, js::Value value)
{
	js.rehold(&self.callback, value);
	self.active = true;
}

fn void HeldFn.release(&self, js::Engine* js)
{
	js.drop(&self.callback);
	self.active = false;
}

fn js::Value HeldFn.get(&self, js::Engine* js) => js.held(self.callback);

// TEMPORARY: old-API values seen as new ones, for the files not moved yet.
macro js::Value[] as_values(qjs::Value[] list) => ((js::Value*)list.ptr)[:list.len];

<*
 One engine, and the host state it drives.

 `pass` is required and `renderer` is not: the scene graph, the handles, the
 staleness checks and `stats()` are all reachable with no Vulkan device at all,
 which is what lets most of the binding suite run in microseconds with no GPU.
 `load` and `render` are the two verbs that need the device, and they say so.
*>
struct JsRuntime
{
	js::Engine* js;
	// TEMPORARY: the same engine through the old API, for the files not moved yet.
	qjs::Context qjs;
	// Nodes and assets as script objects, one per live id — `bind_args.c3`.
	js::NativeClass* node_class;
	js::NativeClass* asset_class;
	HashMap {ulong, js::Root} node_handles;
	HashMap {ulong, js::Root} asset_handles;
	MeshPass* pass;

	Renderer* renderer;

	DString log;
	DString value;
	// `three.debug.write`, as comma-separated JSON entries with no brackets —
	// `debug_json` puts those on at the end. A sink rather than a return value so
	// that a script can answer from three places instead of gathering everything
	// it wants to say into one live object at the last line.
	DString debug;
	DString error;
	// What `advice.c3` had to say during the run, copied out of the sink so that
	// `RunResult` can own a string like the three above rather than a view into a
	// global. `collect_advice` fills it.
	DString advice;

	// What a *script* gets, as opposed to what a frame callback gets. Raisable
	// from JavaScript through `three.budget`, because 5,000 ms is generous for
	// building a scene and short for simulating thirty thousand steps of one.
	// `JS_BUDGET_CEILING_MS` keeps it from becoming a hang.
	// 
	// Separate from `budget_ns` on purpose: `frame_loop.c3` overwrites that one
	// per frame, so a raised script budget must not silently become a raised
	// per-frame allowance and let one callback wedge a game.
	long script_budget_ns;
	// The run's wall-clock budget. `started` is stamped at the top of `run`.
	Clock started;

	// The process's own monotonic clock, stamped once in `open` and never again —
	// `three.clock.wall`.
	// 
	// A second clock, deliberately, and not the game clock. `GameClock` is scaled
	// by `timeScale` and stops dead when paused, which is right for everything
	// that MOVES and useless for measuring how long something TOOK: a profiler
	// whose readings freeze with the game cannot measure a paused frame, and one
	// that stretches with slow motion reports a system as four times slower for
	// having been watched. `started` above cannot serve either — it is re-stamped
	// per frame and per script, because it is a budget and not a clock.
	Clock wall_clock;
	long budget_ns;
	bool timed_out;

	bool settled;
	bool rejected;

	// The animation loop, all of it owned by `js/frame_loop.c3`. Releasing it is
	// the one piece of cleanup that has to happen before the context closes rather
	// than after, which is why `close` leads with it.
	HeldFn frame_loop;
	// The fixed loop, the same way. Separate from `frame_loop` because they are
	// called a different number of times with a different argument — the clock
	// decides how many of these a frame owes.
	HeldFn fixed_loop;
	// The late systems, the same way again: called once a frame after the follow
	// camera has moved, for whatever has to agree with where the camera ended up.
	HeldFn late_loop;
	bool in_frame;
	long frame_ticks;
	DString frame_log;
	long frame_dropped;
	// `three.debug.write` from inside a callback, held for the next run to report
	// exactly as `frame_log` is. A system that writes every frame writes when no
	// run is listening, and without this its entries would land in `debug` and be
	// cleared unread at the top of the next one.
	DString frame_debug;
	long frame_debug_dropped;
	DString frame_error;
	// The game frame policy, set by `--assets` through `set_assets_root`: a game
	// is warned and counted where an agent is stopped.
	bool game_frames;

	// Whether the two "this happened and is not fatal" sentences have been said
	// yet: the fixed loop dropping steps, and a loop callback overrunning the
	// frame budget without being taken away. Both can happen on every frame of a
	// slow patch, and both are worth saying exactly once.
	bool dropped_reported;
	bool loop_overrun_reported;
	long frame_overruns;
	// Where the last frame went, split by span — `frame_loop.c3`'s `FrameSpend`,
	// filled by every `tick` and read by the overrun report and `three.frame.ms`.
	FrameSpend frame_spend;

	<*
	 The widget callbacks `three.ui.set` attached, one entry per node of the live
	 snapshot — `js/bind_ui.c3`. Retained like `frame_loop`, and released before the
	 context closes for the same reason.

	 `ui_pending` is a snapshot a widget handler asked for while it was being
	 dispatched: cui is mid-walk of the tree at that moment, so the rebuild waits
	 for `flush_ui` at the top of the next thing the loop does.
	*>
	List{UiHandlers} ui_handlers;
	js::Root ui_pending;
	bool ui_pending_held;
	bool ui_pending_active;
	bool ui_dispatching;

	// The keyboard, owned by `js/bind_input.c3`. `input` is one frame old at worst
	// and is replaced whole by every tick; `input_text` backs its `text`, which
	// would otherwise point into a window buffer that clears itself.
	<*
	 The window, when this process has one — `js/bind_input.c3`.

	 Null under `--headless`, and every verb that reaches for it says what it does
	 then. It is here only for what a script may ask of the *window* rather than
	 of the scene — `three.input.pointerLock` and `three.window`: the renderer is
	 a consumer of the window and nothing else in the runtime knows one exists.

	 Owned by `main.c3`'s loop and outliving this runtime, like `pass`.
	*>
	c3w::Window* window;

	<*
	 The most frames a second the host loop may present — `three.window.maxFps`.

	 Zero is no cap beyond the swapchain's own vsync. Read by the loop after every
	 presented frame, which sleeps out the remainder of the period; the headless
	 server loop paces its ticks by it too, so a callback sees the same rate
	 whether or not there is a window.
	*>
	uint max_fps;

	InputState input;
	// Keys a script is holding down through `three.input.press`. Merged into every
	// frame beside the window's own, which is what makes an input-driven scene
	// testable without a keyboard — `SyntheticKeys` has the argument.
	SyntheticKeys synthetic;
	// The pointer a script is holding through `three.input.movePointer` and the
	// buttons and wheel beside it. Merged into every frame the same way the keys
	// are, and for the same reason — `SyntheticPointer` argues the whole design.
	SyntheticPointer pointer;
	// The press a windowless host is waiting to see the end of.
	//
	// There is never both this and the one `main.c3`'s loop owns: with a window
	// open every pointer this process has, scripted or not, is stepped through
	// that one, because it arrives through `drive_window`. This is the tracker
	// for the host that has no `drive_window` to arrive through — see
	// `JsRuntime.scripted_pointer_frame`.
	MouseTracker scripted_mouse;
	DString input_text;
	KeyHandler[MAX_KEY_HANDLERS] key_handlers;
	usz key_handler_count;

	// The click handler, also `js/bind_input.c3`'s, released with the loops before
	// the context closes.
	HeldFn click_handler;

	// The turntable's hand on the window — `scene/controls.c3`.
	// 
	// It lives here because `enabled` has to survive having no window. A script
	// says `three.controls.enabled = false` under `--mcp --headless` as readily as
	// with a window open, and a flag stored in the window's loop would have
	// nowhere to be written to and would read back as whatever it was.
	// 
	// So the runtime owns the whole struct and `main.c3`'s loop drives *this* one
	// rather than a local of its own. The drag anchor coming along for the ride is
	// the price of there being exactly one; two would be two answers to
	// `three.controls.enabled`. `run()` — a window with no JavaScript in it —
	// keeps its own, and the type stays independent of both.
	Controls controls;

	// The event handlers physics dispatches into — `js/bind_physics.c3`. The world
	// itself is on the `Scene` — a body names a `NodeId` and the node pool those
	// index into is per scene — and these are here because a handler is a property
	// of the script, not of the world it happens to be watching.
	HeldFn trigger_handler;
	HeldFn contact_handler;

	// `import`, wired up by `js/modules.c3` over fastjs's loader. An empty
	// root means no `--assets` boot and no disk imports at all, which is what a
	// plain `--mcp` run wants; the `three:` space works regardless. Addressed by
	// the engine and must not move while the context is open.
	qjs::ModuleLoader modules;

	<*
	 Meshes a script asked for and has not been given yet — `js/bind_asset.c3`.

	 One entry per `asset.meshAsync` / `instantiateAsync` still in flight, each
	 holding the two callbacks the promise was built around. Drained a mesh at a
	 time wherever microtasks are drained, so the uploads land between frames
	 instead of inside one.
	*>
	List{PendingUpload} uploads;
	<*
	 The resolve functions of every `three.nextFrame()` promise still waiting.

	 Settled by the next `tick`, just before it drains the jobs, so the code after
	 the `await` runs in that tick and the frame is drawn after it. While any are
	 waiting the runtime counts as animating: the loop must not sleep through the
	 frame somebody is waiting for.
	*>
	List{js::Root} frame_waiters;
	<*
	 Whether a `fileBrowser` may leave the assets root. False for a game, whose
	 scripts are confined to their directory; a host sets it when its scripts
	 are trusted with the disk anyway, and a browser that could not reach a
	 model file would only be in the way. Set after `open`, like `window`.
	*>
	bool browse_anywhere;

	<*
	 How many texture references this context has handed to JavaScript, one
	 count per `Assets.textures` slot — `js/bind_asset.c3`.

	 A texture index crossing into a script *takes* a reference, always and only
	 through `texture_value`, and `three.texture.dispose()` is the one thing that
	 gives one back. So a context that ends holding some is a context whose
	 handles will never dispose, and this is the record of how many that is.
	 `release_script_textures` is what acts on it.

	 Indexed by slot rather than a list of outstanding handles, because both
	 operations then cost nothing and the table is bounded by the number of
	 images resident rather than by how many handles a script has made.
	*>
	List{uint} texture_handles;

	<*
	 The compute buffers and kernels this context's scripts made — `js/bind_compute.c3`.

	 Two tables of slots rather than lists of live objects, because a script
	 names them by handle and a handle has to survive being freed: the slot keeps
	 its generation so that a handle kept past its `dispose()` is refused rather
	 than reaching whatever was made in its place. Everything left here when the
	 context closes is freed by `release_compute`, which is what stops a run's
	 pipelines from outliving the context that compiled them.
	*>
	List{StorageSlot} storage_slots;
	List{KernelSlot}  kernel_slots;
	// What a script holds for one: `BufferHandle` and `KernelHandle` objects.
	js::NativeClass* compute_buffer_class;
	js::NativeClass* compute_kernel_class;

	<*
	 A `three.setRenderSize()` made from inside a frame, and not performed yet —
	 `js/bind_scene.c3`. Zero width means nothing is pending.

	 Deferred for the reason a reload is: the call can come from the animation
	 callback, and the images a resize frees are the ones the frame around that
	 callback is drawing into. Outside a frame it is done on the spot, because
	 there is nothing to wait for and an agent asking over `--mcp` wants the very
	 next screenshot to be the new size.
	*>
	uint render_width_wanted;
	uint render_height_wanted;

	<*
	 Where `three.save` writes — `js/bind_save.c3`.

	 Empty until something names it: `three.configure({ saveDir })`, or the first
	 save verb falling back to the assets directory's own name. Held as the
	 resolved absolute path rather than the slug, because the platform root is
	 not going to move under a running process and every verb wants the path.
	*>
	DString save_dir;

	// A `three.reload()` a script has asked for and the loop has not performed
	// yet — `reload.c3`. Deferred rather than done on the call, because the call
	// is made from inside the context a reload destroys; the loop reads it
	// between `pump` and the tick, where nothing of JavaScript's is on the stack.
	bool reload_wanted;

	// A `three.quit()` a script has asked for and the loop has not acted on yet —
	// `js_quit` in `main.c3`. Deferred for the same reason a reload is: the call is
	// made from inside the context that shutting down tears apart. The loop reads
	// it beside `reload_wanted` and leaves; a run with no loop — a `--frames` batch
	// past its last frame, a test — never reads it, and nothing is raised about it.
	bool quit_wanted;

	bool ready;
}

<*
 One mesh a script is waiting for, and the two settlement functions of the
 promise it is waiting on (made in JavaScript). Both are held until it settles.
*>
struct PendingUpload
{
	AssetId asset;
	uint mesh;
	js::Root resolve;
	js::Root reject;
}

<*
 Starts the engine and installs the API.

 @param pass : `The scene, assets and camera the bindings drive. Must outlive the runtime.`
 @param renderer : `Null for a context with no device: three.load and three.render then throw, and everything else works.`
 @param memory_limit : `The JS heap's ceiling. A host that runs pipelines rather than scenes - token lists, embeddings read back for a check - raises it; zero is no limit.`
 @return ? JS_ENGINE_FAILED : `The engine could not be created — out of memory, and nothing else.`
 @return ? JS_PRELUDE_FAILED : `prelude.js did not evaluate. A bug here, not in anything a caller passed.`
*>
fn void? JsRuntime.open(&self, MeshPass* pass, Renderer* renderer = null, usz memory_limit = JS_MEMORY_LIMIT)
{
	self.js = js::open(memory_limit) ?? JS_ENGINE_FAILED~!;
	self.js.user = self;
	self.qjs = qjs::wrap(self.js);
	self.node_handles.init(mem);
	self.asset_handles.init(mem);
	self.pass = pass;
	self.renderer = renderer;
	self.controls = DEFAULT_CONTROLS;
	// Started here as well as in `MeshPass.init`, because a `MeshPass` built by
	// hand — every check in `test/` that needs no device — never runs that, and
	// the zero value of a `GameClock` is a clock stopped at nought hertz.
	// 
	// Null is a real configuration: `open(null)` is a context with no scene at
	// all, which is what the module-loader checks want. It has no clock either,
	// and the clock verbs say so.
	if (pass != null) pass.clock.defaults();
	self.wall_clock = clock::now();

	self.log.init(mem, 1024);
	self.advice.init(mem, 256);
	self.value.init(mem, 256);
	self.debug.init(mem, 256);
	self.error.init(mem, 256);
	self.frame_log.init(mem, 512);
	self.frame_debug.init(mem, 256);
	self.frame_error.init(mem, 128);
	self.input_text.init(mem, 64);
	// Written by the first `three.configure` or the first save verb, and never
	// long. Initialised like the rest so it does not take the temp arena.
	self.save_dir.init(mem, 64);
	// The asynchronous upload queue — `js/bind_asset.c3`. Empty for every run
	// that never asks for one, which is most of them.
	self.uploads.init(mem, 8);
	self.frame_waiters.init(mem, 4);
	// One entry per resident image, grown on demand — `hold_texture`.
	self.texture_handles.init(mem, 8);
	// The compute tables — `js/bind_compute.c3`. Grown on demand, and empty
	// for a run that never dispatches anything.
	self.storage_slots.init(mem, 4);
	self.kernel_slots.init(mem, 4);
	// One entry per node of the interface, and empty for every run that never
	// draws one — `js/bind_ui.c3`.
	self.ui_handlers.init(mem, 0);
	self.frame_loop = held_nothing();
	self.fixed_loop = held_nothing();
	self.late_loop = held_nothing();
	self.click_handler = held_nothing();
	self.trigger_handler = held_nothing();
	self.contact_handler = held_nothing();
	self.script_budget_ns = JS_BUDGET_MS * 1_000_000;
	self.budget_ns = self.script_budget_ns;
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
	// Before the context goes, not after: every one of these releases a reference
	// into an engine that would no longer be there to release it into.
	self.clear_frame();
	self.clear_fixed();
	self.clear_late();
	self.clear_key_handlers();
	self.clear_click_handler();
	self.clear_physics_handlers();
	self.clear_uploads();
	self.clear_frame_waiters();
	// The interface's callbacks, and then the interface itself: the layer belongs
	// to the Renderer and outlives this context, so a reload must not leave it
	// holding a listener into the one that just went.
	self.clear_ui_handlers();
	self.release_ui();
	// The same idea as the five above, for the one resource whose reference is
	// held by a *handle* rather than by a callback: the images this context's
	// `Texture` objects own, which will never be disposed now that the context
	// is going. See `release_script_textures`.
	// After whatever the kernels still owe has run: a compute image is a texture,
	// and a dispatch recorded and not yet submitted may name one this releases.
	if (self.renderer != null) flush_compute(self);
	self.release_script_textures();
	// And the compute buffers and kernels, which are the same case again: a
	// script's `three.compute` objects are handles, and a run that made them and
	// forgot them must not leave a pipeline pointing at a freed module.
	self.release_compute();
	// Every Root goes with the engine.
	self.js.close();
	self.node_handles.free();
	self.asset_handles.free();
	// The physics world and the nav bake go with their scene, in `MeshPass.free`.
	self.log.free();
	self.advice.free();
	self.value.free();
	self.debug.free();
	self.error.free();
	self.frame_log.free();
	self.frame_debug.free();
	self.frame_error.free();
	self.input_text.free();
	self.save_dir.free();
	self.texture_handles.free();
	self.ui_handlers.free();
	self.modules.free();
	*self = { };
}

<*
 Runs one script and answers with every field.

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
 Runs `source` as an ES module — the shape `main.js` takes.

 Not the async wrapper `run` uses, and the difference is not cosmetic: a module's
 `import` declarations must be at its top level, so wrapping one in a function
 body is a syntax error before it is anything else. What the two share is
 everything after evaluation, because module evaluation hands back a promise
 exactly as the wrapper does.

 `three` reaches it as a global, which is why there is no import of it and no
 module named for it. See `js/modules.c3`.

 @param specifier : `Root-relative, and also what a stack trace calls it and what its own imports resolve against.`
 @require self.modules.root.len > 0 : "a module needs a root to resolve against"
*>
fn RunResult JsRuntime.run_module(&self, String specifier)
{
	String? source = self.modules.read(specifier);
	if (catch err = source)
	{
		self.log.clear();
		self.value.clear();
		self.debug.clear();
		self.error.clear();
		self.error.appendf("could not read %s: %s", specifier, err)!!;
		self.rejected = true;
		self.settled = false;
		return {
			.ok = false,
			.log = self.log.copy_str(mem),
			.value = self.value.copy_str(mem),
			.debug = self.debug.copy_str(mem),
			.error = self.error.copy_str(mem),
			.warnings = self.advice.copy_str(mem),
			.frame_error = self.frame_error.copy_str(mem),
		};
	}
	// Copied off the shared buffer before evaluating: the module's own imports are
	// loaded during the parse and each one overwrites it.
	@pool()
	{
		return self.run_source(source.copy(tmem), specifier, drain_frame: true, as_module: true);
	};
}

fn RunResult JsRuntime.run_source(&self, String source, String name, bool drain_frame, bool as_module)
{
	self.log.clear();
	self.value.clear();
	self.debug.clear();
	self.error.clear();
	// Into the log before the script has written a line of its own, so the two
	// arrive in the order they happened. `drain_frame_log` labels both halves.
	if (drain_frame) self.drain_frame_log();
	// The same window, and ahead of the script for the same reason: what a system
	// wrote between the two runs happened first, so it reads first.
	if (drain_frame) self.drain_frame_debug();
	// The fourth thing cleared, for the same reason as the other three: what the
	// device complained about during *this* run is what this run answers with.
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
		// A script runs as the body of an async function (EVAL_ASYNC), so it can
		// await and return at top level, with its own line numbers. A module's top
		// level is already async.
		js::Value? started = self.js.eval(source, name, as_module ? MODULE : ASYNC);
		if (catch err = started)
		{
			// A parse error, or a throw before the first await — the async body
			// catches neither, because neither happens inside its execution.
			String message = self.js.take_error(tmem);
			self.error.append_string(self.timed_out ? self.timeout_message() : message);
			self.rejected = true;
			self.settled = true;
		}
		else
		{
			// Held while the jobs that settle it run, any of which can collect.
			js::Root promise = self.js.hold(started);
			defer self.js.drop(&promise);
			self.await_settled(promise);
		}
	};

	self.prune_handles();
	self.collect_validation();
	// Only for a run the caller asked for — `collect_advice` has why, and what a
	// run that skips it leaves in the sink for the next one.
	if (drain_frame) self.collect_advice();

	SceneStats stats = self.pass != null ? self.scene_stats() : (SceneStats) { };

	// Always copied, cleared only when this run is the agent's. Copying is free of
	// consequence and the clear is not: a stopped callback has to be explained to
	// exactly one caller, or an old failure looks like a new one on every tool
	// call afterwards.
	// 
	// The copy is unconditional for a second reason. `RunResult.free` frees
	// whatever pointer it finds, and a `""` literal has a perfectly good pointer
	// into static memory — the one shape of empty string that must never reach it.
	String frame_error  = self.frame_error.copy_str(mem);
	long frame_ticks    = self.frame_ticks;
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
		.debug = self.debug_json(mem),
		.error = self.error.copy_str(
			mem
		), // Copied unconditionally like the three above, and for `frame_error`'s
		// second reason: `RunResult.free` frees whatever pointer it finds.
		.warnings = self.advice.copy_str(mem),
		.stats = stats,
		.timing = self.renderer != null ? self.renderer.timing() : (FrameTiming) { },
		.frame_running = self.frame_loop.active,
		.frame_ticks = frame_ticks,
		.frame_overruns = frame_overruns,
		.frame_error = frame_error,
	};
}

<*
 Hands one queued mesh to the device and settles the promise waiting on it.

 One per call rather than the whole queue, because the point of the queue is
 that a kit of ninety pieces does not upload in one breath. Where that matters
 is a frame: `drain_frame_jobs` calls this once, so a script that asked for
 ninety meshes gets them over ninety frames and the game keeps drawing.

 A script that is not in a frame drains the queue as fast as it can ask for it,
 which is the honest answer — there is no frame to protect and nothing to yield
 to — and it is why `await asset.meshAsync(...)` in a one-shot script costs
 exactly what the synchronous path costs.

 @return `True when there was something to do, so a caller can loop until there is not.`
*>
fn bool JsRuntime.step_upload(&self)
{
	if (self.uploads.len() == 0) return false;

	PendingUpload job = self.uploads[0];
	self.uploads.remove_at(0);
	defer self.js.drop(&job.resolve);
	defer self.js.drop(&job.reject);

	// The handle can go stale between the ask and the answer: `three.unloadUnused`
	// is one line and the queue survives it. Rejecting is what lets the `await`
	// fail at the line that asked rather than hang forever.
	bool alive = self.pass != null && self.pass.assets.slot(job.asset) != null;
	if (alive) self.pass.assets.ensure_uploaded(job.asset, job.mesh);

	js::Value settle   = self.js.held(alive ? job.resolve : job.reject);
	js::Value argument = alive ? js::UNDEFINED
		: self.js.string("that asset was unloaded before its mesh finished uploading") ?? js::UNDEFINED;
	js::Value[1] arguments = { argument };
	if (catch self.js.call(settle, js::UNDEFINED, &arguments)) self.js.take_exception();
	return true;
}

<*
 Gives back every queued upload's callbacks without calling either.

 Runs while the context is still open, like the other `clear_` verbs: these are
 references into an engine that is about to go, and a promise nobody can settle
 any more is not worth a rejection nobody can observe.
*>
fn void JsRuntime.clear_uploads(&self)
{
	foreach (&job : self.uploads)
	{
		self.js.drop(&job.resolve);
		self.js.drop(&job.reject);
	}
	self.uploads.free();
}

<*
 Runs the microtask queue until the script's promise settles, then reads its
 value or its rejection straight off the promise.
*>
fn void JsRuntime.await_settled(&self, js::Root promise)
{
	if (js::promise_state(self.js.held(promise)) == NOT_A_PROMISE)
	{
		// Cannot happen with EVAL_ASYNC, and is a clear message rather than a
		// silent empty result if it ever does.
		self.error.append_string("the script did not produce a promise");
		self.rejected = true;
		self.settled = true;
		return;
	}

	uint drained = 0;
	while (drained < JS_MAX_JOBS)
	{
		if (self.js.jobs_waiting())
		{
			self.step_job();
		} // Nothing runnable and the script has not finished: it can only be waiting
		// on a queued upload, so hand it one. **Only while it is still waiting** —
		// a script that started an upload and returned without awaiting it leaves
		// the queue for the frames to drain, which is the entire point of there
		// being a queue. Draining it here regardless would make
		// `instantiateAsync` in a `main.js` cost exactly what the synchronous
		// path costs, on the one code path where it matters most.
		else if (js::promise_state(self.js.held(promise)) != PENDING || !self.step_upload())
		{
			break;
		}
		drained++;
		if (self.timed_out) break;
	}
	self.take_settlement(self.js.held(promise));

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
		// An await on something that never resolves. Worth its own sentence: "no
		// error and no value" is otherwise indistinguishable from a script that
		// returned nothing.
		self.error.append_string("the script never finished — it is awaiting something that will not resolve");
		self.rejected = true;
		self.settled = true;
	}
}

<*
 Reads off `budget_ns` rather than off `JS_BUDGET_MS`, because there are two
 budgets: a script's, and the much shorter one a frame callback runs under
 (`js/frame_loop.c3`). A message naming a constant the run did not use sends the
 reader looking for a five-second pause that never happened.

 It names the fix as well as the fault. A cold build crossing the default is the
 commonest single failure an agent hits here — the docs carry a whole entry about
 it — and that entry only has to exist because the sentence stopped one word
 short of the one-line answer. A frame callback gets a different sentence
 entirely (`loop_timeout_message`), which is right: its budget is not raisable
 and pointing at `three.budget` there would name a setting that does not reach
 it.
*>
fn String JsRuntime.timeout_message(&self)
{
	return string::tformat(
		"the script ran for longer than %d ms and was stopped. `three.budget = 60000;` at the top of "
			"the script raises it (ten minutes is the ceiling), and takes effect on the run that sets it",
		self.budget_ns / 1_000_000
	);
}

<*
 `MeshPass.stats`, plus the two memory numbers only the renderer can answer.

 The split is `SceneStats`': the shadow map and the asset table are the pass's
 and it fills those in itself, while the target and the post chain belong to the
 `Renderer`. This is the one place that holds both, so it is the one place the
 whole block can be assembled — and it is why `run_source` and `js_stats` both go
 through here rather than calling `MeshPass.stats` directly.

 Zero for both in a runtime with no device, along with every other number here
 that needs one.

 @param scene : `Null for the rendered one. A scene being built answers for itself; the memory numbers are the process's either way.`
 @require self.pass != null : "no scene to report on"
*>
fn SceneStats JsRuntime.scene_stats(&self, Scene* scene = null)
{
	SceneStats stats = self.pass.stats(scene);
	if (self.renderer != null)
	{
		stats.target_bytes = self.renderer.target.bytes();
		stats.post_bytes = self.renderer.post.bytes();
	}
	return stats;
}

<*
 Folds what the validation layer said during the run into the run's answer.

 There is nothing to fold without `--debug`, which is what loads the layer, and
 the early return on `gpu.validation` is where that lands. So a server started
 without it answers every run with no validation half at all — not "the driver
 was happy", but "nobody was watching" — and an agent chasing a frame that draws
 wrong wants the server restarted with the flag before it believes a clean answer.

 An ERROR fails the run, because a run reporting `ok: true` beside a frame the
 driver refused to draw is the loop lying to the agent, and the agent has no
 other way to find out. A WARNING does not fail it: a warning is advice, and an
 agent that cannot tell advice from a defect stops believing either. So warnings
 go where the script's own `console.warn` would have gone.

 The script's own error is kept. Validation text is appended after it, never in
 place of it — they are two different facts, and the second rarely explains the
 first.

 The sink is read *before* capture is released. In between, a message would take
 the messenger's printing path and be gone; the two statements are adjacent and
 on one thread, so in between is nothing, and it stays nothing only because the
 order is written down.

 What this does not reach: anything the layer says *after* the run returns.
 `mcp/server.c3` renders the reply's PNG once the RunResult has been built, and a
 message from that render lands in a buffer the next `begin_capture` clears. A
 script that calls `three.render()` itself is inside the window, which is what
 makes the messages attributable at all.
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

<*
 Folds what the renderer advised into the run's answer, and empties the sink.

 ## The window is "since the last answered run", not "during this one"

 `collect_validation` above clears its sink at the *start* of a run, because the
 validation layer is loud and a message from the frame before would be attributed
 to the wrong script. Advice is the other case: it is rare, it is deduplicated,
 and every source of it is something a caller wants to hear about once. So the
 sink is emptied here, on the way out, and whatever accumulated since the last
 run comes with it — the shader cache that could not be written at boot, the
 advisory a frame callback provoked between two tool calls, the shadow shader
 that would not compile during the render `mcp/server.c3` does after the
 `RunResult` was built. All of those used to be lost and now arrive one run late,
 which is the whole distance between unreadable and readable.

 ## Not on a run the caller did not make

 `drain_frame` is false exactly for the runs this process invented — the prelude,
 evaluated inside `open`, whose `RunResult` nobody sees. Collecting there would
 empty the sink into a value that is freed immediately, and a boot-time advisory
 would be gone before the first tool call.
*>
fn void JsRuntime.collect_advice(&self)
{
	self.advice.clear();
	self.advice.append_string(advice_all());
	usz lost = advice_dropped();
	if (lost > 0)
	{
		if (self.advice.len() > 0) self.advice.append_char('\n');
		// Its own line, so it comes back as its own entry in the array rather than
		// as a tail on somebody else's sentence.
		self.advice.appendf("%d more advisories were not kept — the sink holds %d", lost, ADVICE_MAX)!!;
	}
	advice_clear();
}

// ============================================================================
// The engine's callbacks
// ============================================================================

<*
 Called between bytecode instructions; non-zero aborts the script.

 Must not call back into the context, which is why it only reads a clock and sets
 a flag.
*>
fn int on_interrupt(void* engine, void* opaque) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	if (self == null || self.budget_ns <= 0) return 0;
	if ((long)self.started.to_now() < self.budget_ns) return 0;
	self.timed_out = true;
	return 1;
}

<*
 What a settled script promise answered: its value as JSON, or its rejection
 described. A pending one leaves `settled` false for `await_settled` to explain.
*>
fn void JsRuntime.take_settlement(&self, js::Value promise)
{
	js::PromiseState state = js::promise_state(promise);
	if (state == PENDING) return;
	js::Value result = self.js.promise_result(promise);
	self.settled = true;
	self.rejected = state == REJECTED;
	@pool()
	{
		// A rejection reads as the error and its stack; a value as JSON, where
		// `undefined` has none — an empty `value`, unlike the four characters `null`.
		if (self.rejected)
		{
			self.error.append_string(self.js.error_text(result, tmem));
		}
		else
		{
			self.value.append_string(self.js.json(result, tmem));
		}
	};
}

<*
 Run one promise job. One that throws (a queueMicrotask callback) has nobody to
 tell, so its exception is dropped.
*>
fn void JsRuntime.step_job(&self)
{
	if (catch self.js.step_job()) self.js.take_exception();
}

// ============================================================================
// console
// ============================================================================

<*
 `console.log` and friends, all writing into the run's log.

 Nothing reaches stdout: the log is one of the four things a run answers with,
 and a script driven over JSON-RPC has no terminal to print to. A host that wants
 it on screen prints `RunResult.log`.

 There are two logs, and `in_frame` picks between them. A line written from
 inside an animation callback belongs to no run — the run that would have owned
 it finished long ago — so it goes to the bounded `frame_log` that the next run
 drains. Sending it to `self.log` instead would either flood the next result with
 sixty frames a second of output or, worse, be cleared unread at the top of that
 run.
*>
fn void JsRuntime.install_console(&self)
{
	js::Value console = self.js.object()!!;
	foreach (name : (String[]){ "log", "info", "warn", "error", "debug" })
	{
		self.js.set(console, name, self.js.function(&js_console, name, 1, self)!!)!!;
	}
	self.js.set(self.js.global(), "console", console)!!;
}

fn js::Value? js_console(js::Call* c) @local
{
	JsRuntime* self = c.host;
	DString* sink = self.in_frame ? &self.frame_log : &self.log;
	foreach (i, v : c.args)
	{
		if (i > 0) sink.append_char(' ');
		sink.append_string(display(c.js, v, tmem));
	}
	sink.append_char('\n');
	return js::UNDEFINED;
}

<*
 A value the way a log wants to read it.

 Objects and arrays go through JSON rather than `String(value)`, because
 `console.log(scene.stats())` printing `[object Object]` would make the one call
 an agent makes to see its own cost useless. Errors are the exception: their JSON
 is `{}` and their string form is the message.
*>
fn String display(js::Engine* js, js::Value value, Allocator allocator) @local
{
	if (value.is_object() && !js::is_error(value) && !value.is_function())
	{
		String json = js.json(value, allocator);
		if (json.len > 0) return json;
	}
	return js.text(value, allocator);
}

<*
 `three.debug.write` — a value the run answers with, without returning it.

 The sink `console.log` writes to is a string, so anything structured put there
 arrives at the caller escaped inside one, mixed with every other line. This is
 the same crossing with the structure kept: entries are JSON and reach the tool
 result as JSON, which is what `value` gets for returning and nothing else did.

 Why a sink at all when `return` exists: a return is one expression at one place,
 and it does not exist at all inside a frame callback. This can be called from
 wherever the number was computed, as many times as there are numbers.

 Each argument is its own entry, the way `console.log`'s are their own words.
*>
fn js::Value? js_debug_write(js::Call* c)
{
	JsRuntime* self = c.host;
	DString* sink = self.in_frame ? &self.frame_debug : &self.debug;
	foreach (v : c.args)
	{
		// The frame's sink is the one that grows while nobody is reading, so it is
		// the one with a ceiling. Oldest kept rather than newest: an entry boundary
		// is not findable by scanning, because a comma inside a string looks like
		// the comma between two entries.
		if (self.in_frame && (usz)sink.len() >= JS_FRAME_DEBUG_BYTES)
		{
			self.frame_debug_dropped++;
			continue;
		}
		// JSON made here rather than trusted from the prelude: `__three` is
		// reachable from a script. `null` for what has no JSON form, so the array
		// always parses.
		String entry = c.js.json(v, tmem);
		if (sink.len() > 0) sink.append_char(',');
		sink.append_string(entry.len > 0 ? entry : "null");
	}
	return js::UNDEFINED;
}

<*
 The debug sink as the JSON array a caller reads.

 Bracketed here rather than kept bracketed in the sink, because every append
 would then have to reopen it and `drain_frame_debug` would have to splice two.

 @return `Owned by the caller. Empty — not "[]" — when nothing was written, which is what tells a caller the script said nothing.`
*>
fn String JsRuntime.debug_json(&self, Allocator allocator)
{
	if (self.debug.len() == 0) return self.debug.copy_str(allocator);
	return string::format(allocator, "[%s]", self.debug.str_view());
}