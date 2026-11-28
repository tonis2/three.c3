<*
 Bringing the engine up, and the description of a run.

 Split out of `main.c3` so that starting three is not the same thing as being
 three's command line. `main.c3` turns argv into an `Options`; everything here
 takes one already made and knows nothing about how it was written. An
 application that is not three — one that links these sources rather than
 running this binary — fills an `Options` itself and calls `run`, and never
 parses a flag.

 That is the whole of the seam. `Options` is here rather than beside
 `parse_args` because it is the engine's description of a run and not the CLI's
 output: a caller with no argv still has to say how big the window is and
 whether there is one.

 ## What else lives here, and why it is not in the CLI

 `debugging`, `VERSION` and `WINDOW_DEFAULT_TITLE` are read across the engine —
 `gpu/device.c3` asks for the validation layer, `mcp/server.c3` reports the
 version, `js/bind_input.c3` names the window. They were declared in `main.c3`
 for the historical reason that everything was, and a file that only the CLI
 compiles cannot hold a value the renderer reads.

 `boot_world` is here for the same reason: it is what a run *is* once the
 device is up, not how it was asked for.
*>
module three;

import std::io;
import std::io::file;
import std::io::path;
import std::math;
import std::time;
import c3w;
import vk;
import image;
import mcp;

const String VERSION = "0.1.0";

// Raised by `boot_world` rather than by the command line: a path that cannot be
// read is a fact about the file, and an application that never parsed a flag
// still has to be told. `main.c3` catches it to print its own sentence.
excuse SCRIPT_NOT_READABLE;

<*
 What the title bar says until a game says otherwise.

 There is no `--title`: a player never types a command line, and a settings
 screen has to be able to change this at runtime anyway. `three.configure({
 title })` at the top of `main.js` is the boot spelling and
 `three.window.title = ...` is the live one — both go through
 `js/bind_input.c3`, which is also where the current value is kept.
*>
const String WINDOW_DEFAULT_TITLE = "three.c3";

<*
 What an application that links these sources does to a runtime the loop opened:
 install its own host verbs, set a budget, run a config script. `live` calls it
 on the first runtime and `reload` on every one after.
*>
alias JsSetup = fn void(JsRuntime* runtime);

<*
 The most `--script`s one run takes. Far past what a command line holds, and it
 keeps `Options` a plain value with nothing to free.
*>
const usz MAX_SCRIPTS = 8;

struct Options
{
	<*
	 `--script`, in the order given: ES modules, run one after another before the
	 first frame — see `boot_world`. The first one's folder is where relative
	 paths start. `scripts()` is the list.
	*>
	String[MAX_SCRIPTS] script_list;
	usz script_count;
	String screenshot;
	uint width;
	uint height;
	bool headless;
	<*
	 How many frames to run before stopping. 0 is "not asked for", which is the
	 window's endless loop or — with `--screenshot` — the single frame that mode
	 has always rendered.

	 A headless render is one frame, and a frame loop is what physics, the
	 animation callback and the keyboard latch are all downstream of: nothing that
	 moves can be tested against a still.
	*>
	uint frames;
	// With `frames`, write a numbered shot every n of them as well as the last. 0
	// writes only the last one. `frame_path` says how the number gets in.
	uint every;
	// yaw,pitch,distance — applied after the script has run and again before every
	// capture. Empty means the scene keeps its own camera.
	String camera;
	// 0 for "do not serve". The port is only ever bound on 127.0.0.1 — and under
	// `--mcp-stdio` it is the port *connected to* rather than bound, which is what
	// makes `--mcp 9000 --mcp-stdio` relay to 9000.
	int mcp_port;
	// Be the stdio end of somebody else's server rather than a server: no window,
	// no device, no scene. See `serve_relay`.
	bool relay_stdio;
	// `--debug`. Copied into `three::debugging` before anything reads it — the flag
	// is the CLI's, the global is what the rest of the engine asks.
	bool debug;
	<*
	 `--cache-dir`, and whether it was written at all.

	 Two fields because an empty value is a decision: `--cache-dir ""` turns the
	 shader cache off, and is the only way to say so. Nothing but the presence of
	 the flag tells that apart from never having asked.

	 A developer's flag. A game names nothing here — see `paths.c3` for what a run
	 that says nothing gets.
	*>
	String cache_dir;
	bool cache_dir_set;
	bool help;
	// `--quest [scale]`: draw like a Quest 3 eye at this share of its recommended
	// size (`Renderer.draw_like_quest`). 0 draws at the window's own resolution.
	float quest;
}

<*
 The `--script`s, in order. Borrowed from `self`.
*>
fn String[] Options.scripts(&self) => self.script_list[:self.script_count];


<*
 Whether this run was started with `--debug`.

 Written once, by `main`, before anything reads it, and never again — a process
 is diagnosing or it is not, and a switch that could be thrown mid-run would mean
 an instance created without the validation layer being asked to report through
 one. Everything downstream reads it rather than taking a parameter, for the same
 reason it used to be a constant: it is a property of the run, not of the call.

 There is no build that lacks the machinery. The binary somebody ships and the
 binary on the developer's desk are the same binary, so a bug that only appears
 on a player's machine can be looked at on a player's machine.
*>
bool debugging;

<*
 A log line that exists only under `--debug`.

 The arguments are not evaluated without it, which makes this usable where
 composing the message costs more than printing it: `@debug_log("%s", describe())`
 does not call `describe` in an ordinary run.

 That property survives the flag having become a runtime one, and the reason is
 that this is a macro: the argument expressions are substituted *inside* the `if`,
 so the branch is what guards them. A typed parameter list —
 `macro @debug_log(String format, args...)` — would evaluate everything at the
 call site before the branch was reached, which is why the signature is untyped
 varargs and has to stay that way.

 What it costs when off is therefore one read of a global bool, on ten call sites
 that all run at startup. What it costs in the binary is the lines themselves,
 which is the price of the shipped build being able to explain itself.

 This is for the developer at the terminal, not the agent: what a `run_script`
 should see belongs in `log`, which comes back through `RunResult`, and advice
 about the scene belongs in `@advise`, which reaches the agent always and the
 terminal when no server is driving.
*>
macro @debug_log(format, ...)
{
	if (debugging) io::printfn(format, ...$vaarg);
}

<*
 Points the shader cache and its prebake somewhere, once, before anything
 compiles.

 Two directories and one rule each. The writable one is `resolve_cache_dir`'s
 answer — the flag, then the environment, then a checkout's `build/`, then the
 user's cache directory; `paths.c3` argues that order. The read-only one is
 `shader-cache/` beside the executable, which is where a bundle puts the modules
 it shipped warm and nowhere a run will ever write.

 `--cache-dir ""` is the one value that does not go through the resolver. An
 empty directory means "no cache at all", and a resolver that fell through to a
 default on it would make the off switch unreachable.

 The prebake is skipped when it names the writable directory, which is what a
 checkout does: `build/shader-cache` is both, and looking in one place twice is
 not a second chance.
*>
fn void choose_caches(Options opts)
{
	@pool()
	{
		if (opts.cache_dir_set && opts.cache_dir.len == 0)
		{
			shader_cache_set_dir("");
			@debug_log("shader cache: off — --cache-dir was given nothing");
			return;
		}

		String chosen = resolve_cache_dir(opts.cache_dir, tmem);
		shader_cache_set_dir(chosen);
		@debug_log("shader cache: %s", chosen);

		String? beside = executable_dir(tmem);
		if (catch beside) return;
		String bundled = string::tformat("%s/shader-cache", beside);
		if (!path::is_dir((Path)bundled)) return;
		// Compared absolute, because a checkout reaches the same directory by two
		// spellings: `build/shader-cache` from the working directory, and the
		// executable's own `build/` as a full path. Looking in one place twice is
		// not a second chance.
		Path? here = chosen.to_absolute_path(tmem);
		if (try here && (String)here == bundled) return;
		shader_cache_set_read_dir(bundled);
		@debug_log("shader cache: reading %s as well", bundled);
	};
}


<*
 The window, the device and the renderer: everything that must be up before a
 frame can be drawn, and nothing about what is drawn.

 This used to be the first forty lines of `run`, held together by four `defer`s.
 That works exactly once — for the function that also owns the loop. An
 application that links these sources has its own loop and its own reason to
 keep the device alive across several of its own functions, and cannot borrow a
 `defer` chain out of the middle of somebody else's stack frame.

 ## Why `stage` rather than four more defers

 The `defer`s were doing real work that is easy to lose in the move: each one
 was registered *after* the thing it frees was made, so a failure part-way
 through unwound exactly as far as it had got and no further. A `close` that
 always freed all five would double-free on a run where the surface failed, and
 one that freed none would leak the window.

 `stage` is that same staircase written down instead of implied. `open` raises
 it as each piece comes up; `close` walks back down it. Nothing else reads it.
*>
enum EngineStage : char
{
	CLOSED,
	WINDOW,
	INSTANCE,
	SURFACE,
	RENDERER,
}

struct Engine
{
	c3w::Window window;
	bool windowed;
	vk::Instance instance;
	vk::SurfaceKHR surface;
	Renderer renderer;
	// How far `open` got, so `close` unwinds only the stages that succeeded.
	EngineStage stage;
}

<*
 Brings the engine up, or leaves it exactly as far up as it managed.

 Call `close` either way: on the failure path it undoes the stages that
 succeeded, which is what the `defer`s did before it.

 @param views : "Views drawn side by side in one multiview pass, where the device has multiview: 2 for a headset"
 @param samples : "Samples per pixel for the scene: 1, or 2 or 4 for MSAA"
*>
fn void? Engine.open(&self, uint width, uint height, bool headless = false, uint views = 1, uint samples = 1)
{
	// The window is a viewer, never a render target. It is opened first only
	// because the surface has to come from somewhere; nothing about it reaches the
	// offscreen target's extent or format.
	self.windowed = !headless;
	if (self.windowed)
	{
		self.window = c3w::new(
			params: { .x = 0, .y = 0, .width = (int)width, .height = (int)height },
			name: WINDOW_DEFAULT_TITLE
		)!;
	}
	self.stage = WINDOW;

	self.instance = create_instance(debugging, headless: headless)!;
	self.stage = INSTANCE;

	if (self.windowed)
	{
		self.surface = (vk::SurfaceKHR)self.window.create_vk_surface(
			self.instance,
			(c3w::VkGetInstanceProcAddrFn)vk::getInstanceProcAddr
		)!;
	}
	self.stage = SURFACE;

	self.renderer.init(self.instance, self.surface, width, height, debugging, views, samples)!;
	self.stage = RENDERER;

	if (debugging) self.renderer.gpu.report();
	self.renderer.pass.init(&self.renderer.gpu, &self.renderer.target)!;
}

<*
 Takes the engine down in reverse order of `open`, safe on a half-open engine or twice.
*>
fn void Engine.close(&self)
{
	if (self.stage >= RENDERER) self.renderer.free();
	if (self.stage >= SURFACE && self.windowed) self.surface.free(self.instance);
	if (self.stage >= INSTANCE) self.instance.free();
	if (self.stage >= WINDOW && self.windowed) self.window.free();
	self.stage = CLOSED;
}

<*
 The window this engine is driving, or null when it is headless.

 The shape every caller wants: `live` and `drive_window` both take a nullable
 window, and `engine.windowed ? &engine.window : null` written at each of them
 is the same conditional three times.
*>
fn c3w::Window* Engine.viewer(&self) => self.windowed ? &self.window : null;

fn void? run(Options opts)
{
	// On the heap: at 65 KB the engine is over c3c's stack object limit, and
	// there is exactly one of it for the whole run.
	Engine* engine = mem::new(Engine);
	defer mem::free(engine);
	defer engine.close();
	engine.open(opts.width, opts.height, opts.headless, samples: opts.quest > 0.0f ? XR_MSAA : 1)!;

	Renderer* renderer = &engine.renderer;
	if (opts.quest > 0.0f)
	{
		renderer.draw_like_quest(opts.quest);
		io::printfn("quest: drawing like a Quest 3 eye at %.2f: %.0f pixels per unit of view tangent, %dx MSAA",
			opts.quest, renderer.headset_density, (uint)renderer.target.samples);
	}
	c3w::Window* window = engine.viewer();
	bool windowed = engine.windowed;

	String[] scripts = opts.scripts();
	if (scripts.len == 0)
	{
		// The placeholder for "nothing was given", and only then. A script or a
		// game builds its own scene, and since `new three.Scene()` stopped emptying
		// the one before it, a triangle put here would be a scene nothing draws and
		// nothing can dispose — counted by `stats().scenes` for the rest of the run.
		renderer.pass.load_triangle(&renderer.gpu)!;
	}

	// The line an agent reads its own cost off. `instances` next to `draw calls` is
	// the whole claim in two numbers: a grid of a thousand is a thousand and one,
	// not a thousand and a thousand.
	SceneStats stats = renderer.pass.stats();
	io::printfn(
		"%s: %d draw calls, %d instances, %d unique meshes, %d textures (%d KiB), %d triangles",
		scripts.len > 0
			? "empty scene"
			: "built-in triangle",
		stats.draw_calls,
		stats.instances,
		stats.unique_meshes,
		stats.textures,
		stats.texture_bytes / 1024,
		stats.triangles
	);

	// Before every one-shot path below: neither a server nor a game renders one
	// frame and exits, and both work with or without a window. They compose —
	// `--script game/main.js --mcp` plays and answers tool calls at the same time.
	if (opts.mcp_port > 0 || scripts.len > 0)
	{
		live(
			renderer,
			window,
			opts.mcp_port,
			scripts: scripts,
			screenshot: opts.screenshot,
			frames: opts.frames,
			every: opts.every,
			camera: opts.camera
		)!;
		return;
	}

	if (opts.screenshot.len > 0)
	{
		// No runtime on this path, so nothing can move and nothing can steal the
		// camera back: the override is applied once and the frame count is a count
		// of identical frames. It is still honoured, because `--every` over a static
		// scene is how the flipbook itself gets checked.
		aim_camera(renderer, opts.camera);
		for (uint i = 0; i < math::max(opts.frames, (uint)1); i++)
		{
			@pool()
			{
				String out = frame_path(opts.screenshot, i);
				renderer.screenshot(out)!;
				io::printfn("wrote %s (%dx%d)", out, opts.width, opts.height);
			};
			if (opts.every == 0) break;
		}
		return;
	}

	// Headless with nothing to write is still worth running: it exercises the whole
	// render path with no window server, which is exactly what the tests do.
	if (!windowed)
	{
		image::Image frame = renderer.capture()!;
		defer frame.free();
		io::printfn("rendered %dx%d headless", frame.width, frame.height);
		return;
	}

	Controls controls = DEFAULT_CONTROLS;
	InputTracker keyboard;
	c3w::CursorShape shown;
	Hover hover;
	Clock since_start = clock::now();
	long last_ns;
	// Nothing but the mouse can change this window, so it sleeps between gestures —
	// see `serve`, which has more to wait for and says why there.
	bool quiet        = false;

	while (true)
	{
		WindowFrame poll = drive_window(
			renderer,
			window,
			&controls,
			&keyboard,
			&shown,
			&hover,
			since_start,
			&last_ns,
			quiet
		);
		if (poll.closed) break;

		bool ui_idle   = renderer.ui.idle();
		bool presented = renderer.frame()!;
		quiet = presented && !poll.camera_moved && ui_idle;
	}
}


<*
 Runs the `--script`s, in order: what puts a world on screen.

 A function rather than a loop inside `live`, because `reload` needs the same
 thing — a reload *is* this, with a teardown in front of it.

 **The first script's folder is where relative paths start** — see
 `js/modules.c3`. That is the game's folder when the first script is its
 `main.js`, which is what lets a probe given second run against the world the
 game built, reading the game's paths the way the game does:
 `--script game/main.js --script tools/probe.js`.

 A script that fails is printed and carried on with rather than returned as a
 fault. That is exactly when someone wants to look at it — with `--mcp` that
 means attaching and asking, and with a window it means seeing an empty scene
 beside the reason for it.

 @param scripts : `The files, as typed. Empty boots nothing.`
 @return? SCRIPT_NOT_READABLE : `A path that is not a file: a typo on the command line, raised before anything runs.`
 @return? from_working_directory!
*>
fn void? boot_world(JsRuntime* runtime, String[] scripts)
{
	if (scripts.len == 0) return;
	foreach (script : scripts)
	{
		if (!file::is_file(script)) return SCRIPT_NOT_READABLE~;
	}

	// The frame policy, before anything a script does can register a callback.
	// See `game_frames`: a script booted from a command line is somebody watching
	// a window, where the answer to one slow frame is not to kill the animation.
	runtime.play_frames();

	@pool()
	{
		runtime.set_base(folder_of(from_working_directory(scripts[0], tmem)!))!;
		foreach (script : scripts)
		{
			String file = from_working_directory(script, tmem)!;
			RunResult ran = runtime.run_module(file);
			defer ran.free();
			report_run(ran, script);
		}
	};
}

<*
 Prints what a run logged, what it asked to have said, and why it failed.

 `value` is not printed and `debug` is, which is the difference between them
 here: a returned value is an answer to whoever CALLED, and over MCP there is
 one. A run from the command line has no caller, so what the script wanted said
 out loud is the only half of the pair that has a reader on this path.
*>
fn void report_run(RunResult ran, String what)
{
	if (ran.log.len > 0) io::printn(ran.log);
	if (ran.debug.len > 0) io::printfn("debug: %s", ran.debug);
	if (!ran.ok) io::printfn("three: %s did not run: %s", what, ran.error);
}

<*
 The file a game folder boots: what the headset runs from the folder it was
 given, and what a desktop run names with `--script <folder>/main.js`.

 Fixed rather than configurable, and named for the same reason `index.html` is: a
 folder that boots has to boot the same way on every machine.
*>
const String ENTRY_MODULE = "main.js";

// What a frame is worth when there is no window to present one: 60Hz, the rate
// the vsynced loop above runs at on the displays this is developed on. Exactly
// a sixtieth, not 16 — see `GameClock.frame_ms` for what the 0.67 ms cost.
const double HEADLESS_FRAME_MS = 1000.0 / 60.0;

<*
 Answers JSON-RPC on stdin and stdout by forwarding it to a `three --mcp` that is
 already running. This is `three --mcp-stdio`, and it is what `.mcp.json` names.

 What it buys over pointing a client at the port is lifetime. A client asks who a
 server is the moment it launches, and is entitled to write that server off for
 the whole of its run if the question fails — so a bare URL means three has to be
 up before the client and stay up for as long as it. A relay is up whether or not
 three is, and a call that cannot reach one comes back as an error naming the
 port rather than as a server that never started.

 It is not a second server. It binds nothing, opens no window, creates no device
 and holds no scene: `mcp::relay` makes one connection per message and closes it.
 Several may run at once beside a windowed three without any of them knowing
 about the others.

 The catalog answers the four questions a client asks before it has done anything
 — `initialize`, `ping`, `tools/list`, `resources/list` — out of the registration
 table, so those answers are the same whether or not three is up. It is
 registered over a zeroed `ToolHost` on this stack and nothing ever dereferences
 it: `Server.answers_offline` lets only those four through, and all three
 handlers begin by refusing a null runtime or renderer in any case.

 @return `0 when stdin ends, which is how the client says it is finished.`
*>
fn int serve_relay(int port)
{
	ToolHost catalog_host = { };
	mcp::Server catalog   = new_mcp_server(&catalog_host);
	mcp::relay("127.0.0.1", port, &catalog);
	return 0;
}

<*
 Pokes the window's event loop awake. Called on the listener's thread.

 The one thing a foreign thread may do to a Cocoa run loop: `Window.wake` posts
 an application-defined event, which `getEvent` falls through its switch and
 hands to `NSApp`, which ignores it. So a wake costs exactly one extra iteration
 and changes nothing else.

 Null for a headless server, where the parameter is the window itself and there
 is nothing to wake — the loop there paces itself with a sleep instead.
*>
fn void wake_window(void* ctx)
{
	c3w::Window* window = (c3w::Window*)ctx;
	if (window == null) return;
	window.wake();
}

<*
 `three.quit()` — the game closing itself.

 Here rather than beside the other scene verbs because it is not one: it is a
 statement about the process, and this file is what owns the process. `live`
 reads the flag between `pump` and the tick and leaves the loop; every `defer`
 from `run` down unwinds in order, so the device is torn down and the leak
 checker still has something to say. There is no exit code and no argument — a
 game that closed on purpose succeeded.

 It is not behind `--debug`, and that is the point of the split: escape is the
 engine reaching past the game, and this is the game itself. Most games close
 from a menu, and a menu that only worked in a debug build would be a menu
 shipped untested.

 Deferred rather than immediate for the same reason `three.reload()` is: this
 runs inside the JavaScript context, with the click handler that called it still
 on the stack, and closing from here would free the engine the call is in. The
 frame the game had already built is drawn first, so a fade-out that ends on
 `three.quit()` shows its last frame.

 A run with no loop reading the flag — a `--frames` batch, a test — takes the
 request and never acts on it, exactly as `three.reload()` does there. The same
 script has to work in both, and a verb that threw under `--frames` would make a
 game unrunnable in the mode that checks it.
*>
fn void js_quit(JsRuntime* self)
{
	self.quit_wanted = true;
}
