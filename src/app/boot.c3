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

 `boot_world` and `boot_script` are here for the same reason: they are what a
 run *is* once the device is up, not how it was asked for.
*>
module three;

import std::io;
import std::io::file;
import std::io::path;
import std::math;
import std::thread;
import std::time;
import c3w;
import vk;
import image;
import mcp;
import qjs;

const String VERSION = "0.1.0";

// Raised by `boot_script` rather than by the command line: a path that cannot be
// read is a fact about the file, and an application that never parsed a flag
// still has to be told. `main.c3` catches it to print its own sentence.
faultdef SCRIPT_NOT_READABLE;

<*
 What the title bar says until a game says otherwise.

 There is no `--title`: a player never types a command line, and a settings
 screen has to be able to change this at runtime anyway. `three.configure({
 title })` at the top of `main.js` is the boot spelling and
 `three.window.title = ...` is the live one — both go through
 `js/bind_input.c3`, which is also where the current value is kept.
*>
const String WINDOW_DEFAULT_TITLE = "three.c3";

struct Options
{
	// The game directory: `.js` to run, `.glb` to describe.
	String assets;
	// One `.js` file, run the way `run_script` runs one — see `boot_script`.
	String script;
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
}


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
struct Engine
{
	c3w::Window window;
	bool windowed;
	vk::Instance instance;
	vk::SurfaceKHR surface;
	Renderer renderer;
	// How far `open` got. See the note above — this is the unwound `defer` chain.
	int stage;
}

<*
 Brings the engine up, or leaves it exactly as far up as it managed.

 Call `close` either way: on the failure path it undoes the stages that
 succeeded, which is what the `defer`s did before it.
*>
fn void? Engine.open(&self, uint width, uint height, bool headless = false)
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
	self.stage = 1;

	self.instance = create_instance(debugging, headless: headless)!;
	self.stage = 2;

	if (self.windowed)
	{
		self.surface = (vk::SurfaceKHR)self.window.create_vk_surface(
			self.instance,
			(c3w::VkGetInstanceProcAddrFn)vk::getInstanceProcAddr
		)!;
	}
	self.stage = 3;

	self.renderer.init(self.instance, self.surface, width, height, debugging)!;
	self.stage = 4;

	// The device table on every debug run, where it used to take a flag of its own.
	// A run that asked for the validation layers is a run somebody is diagnosing,
	// and the first question a diagnosis asks is which device and which limits —
	// `Gpu.report` prints whether validation actually loaded, which is the one
	// thing `--debug` cannot promise on its own.
	if (debugging) self.renderer.gpu.report();

	// The shader is compiled here, from shaders/mesh.slang on disk. Editing it and
	// re-running changes the picture — no rebuild of this binary, and no build step
	// for the shader either.
	self.renderer.pass.init(&self.renderer.gpu, &self.renderer.target)!;
}

<*
 Takes the engine down, in the order the `defer`s would have.

 Reverse of `open` and guarded by the stage it reached, so it is safe on a
 half-open engine and safe to call twice.
*>
fn void Engine.close(&self)
{
	if (self.stage >= 4) self.renderer.free();
	if (self.stage >= 3 && self.windowed) self.surface.free(self.instance);
	if (self.stage >= 2) self.instance.free();
	if (self.stage >= 1 && self.windowed) self.window.free();
	self.stage = 0;
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
	Engine engine;
	defer engine.close();
	engine.open(opts.width, opts.height, opts.headless)!;

	Renderer* renderer = &engine.renderer;
	c3w::Window* window = engine.viewer();
	bool windowed = engine.windowed;

	if (opts.script.len == 0 && opts.assets.len == 0)
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
		opts.script.len > 0 || opts.assets.len > 0 ? "empty scene" : "built-in triangle",
		stats.draw_calls,
		stats.instances,
		stats.unique_meshes,
		stats.textures,
		stats.texture_bytes / 1024,
		stats.triangles
	);

	// Before every one-shot path below: neither a server, a game nor a booted
	// script renders one frame and exits, and all three work with or without a
	// window. They compose — `--assets ./game --mcp` plays and answers tool calls
	// at the same time, and `--script` adds one more thing for the same loop to
	// have run before the first frame.
	if (opts.mcp_port > 0 || opts.assets.len > 0 || opts.script.len > 0)
	{
		live(
			renderer,
			window,
			opts.mcp_port,
			assets: opts.assets,
			screenshot: opts.screenshot,
			script: opts.script,
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
			String out = frame_path(opts.screenshot, i);
			renderer.screenshot(out)!;
			io::printfn("wrote %s (%dx%d)", out, opts.width, opts.height);
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
 Runs whatever put a world on screen: a game directory, a script, or both.

 A function rather than two blocks inside `live`, because `reload` needs the same
 two things in the same order — a reload *is* this, with a teardown in front of
 it — and a second spelling of "how a game boots" is how the two would come to
 disagree about which of them runs first.

 Both orders are defensible and this one composes: `--assets ./game --script
 probe.js` runs the script against the world `main.js` built, which is what the
 same two things would do through the server.

 A game that failed to boot is printed and carried on with rather than returned
 as a fault. That is exactly when someone wants to look at it — with `--mcp` that
 means attaching and asking, and with a window it means seeing an empty scene
 beside the reason for it.

 @return ? SCRIPT_NOT_READABLE : `Only from --script: nothing at that path. A game directory that will not boot is reported and not raised.`
*>
fn void? boot_world(JsRuntime* runtime, String assets, String script)
{
	if (assets.len > 0)
	{
		runtime.set_assets_root(assets);
		RunResult booted = runtime.run_module(ENTRY_MODULE);
		defer booted.free();

		if (booted.log.len > 0) io::printn(booted.log);
		if (!booted.ok)
		{
			io::printfn("three: %s/%s did not run: %s", assets, ENTRY_MODULE, booted.error);
		}
	}

	if (script.len > 0) boot_script(runtime, script)!;
}

<*
 Runs one `.js` file the way `run_script` runs one, before the first frame.

 A script and not a module, which is the whole difference from `--assets`: the
 source is wrapped in an async function, so top-level `await` and top-level
 `return` both work and `import` does not. That makes `--script examples/vfx.js`
 mean exactly what pasting the same file into `run_script` means. A program in
 several files is what `--assets` is for.

 For the same reason there is no assets root: a path the script hands to
 `three.load` is relative to where the process was started, as it is for an
 agent, rather than to wherever the script happens to live.

 The frame policy is the game's, though. `game_frames` decides what happens when
 a callback runs long, and the choice is between stopping it for good and
 counting it. Stopping is right when an agent is sitting there to be told and a
 runaway loop would wedge the tool surface; a script booted from a command line
 is somebody watching a window, where the answer to one slow frame is not to kill
 the animation.

 A script that throws is printed and carried on with, exactly as a game that
 fails to boot is.

 @return ? SCRIPT_NOT_READABLE : `Nothing at that path, or it is a directory — a typo on the command line, not something to debug in a running scene.`
*>
fn void? boot_script(JsRuntime* runtime, String path)
{
	// The frame policy, before anything the script does can register a callback.
	runtime.play_frames();

	@pool()
	{
		if (!file::is_file(path)) return SCRIPT_NOT_READABLE~;
		char[]? source = file::load_temp(path);
		if (catch source) return SCRIPT_NOT_READABLE~;

		// Named by the path it was given, so a stack trace says `vfx.js:412` and not
		// `<script>:412`.
		RunResult ran = runtime.run((String)source, path);
		defer ran.free();

		if (ran.log.len > 0) io::printn(ran.log);
		// `value` is not printed and this is, which is the difference between them
		// here: a returned value is an answer to whoever CALLED, and over MCP there
		// is one. A `--script` run has no caller, so what the script wanted said out
		// loud is the only half of the pair that has a reader on this path.
		if (ran.debug.len > 0) io::printfn("debug: %s", ran.debug);
		if (!ran.ok) io::printfn("three: %s did not run: %s", path, ran.error);
	};
}

<*
 The file a `--assets` boot runs.

 Fixed rather than configurable, and named for the same reason `index.html` is: a
 directory that boots has to boot the same way on every machine, and a flag that
 changed the entry point would be one more thing to get wrong in a bug report
 that starts "it works here".
*>
const String ENTRY_MODULE = "main.js";

// What a frame is worth when there is no window to present one: 60Hz, the rate
// the vsynced loop above runs at on the displays this is developed on.
const long HEADLESS_FRAME_MS = 16;

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
fn void js_quit(qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out)
{
	JsRuntime* self = (JsRuntime*)opaque;
	self.quit_wanted = true;
	*out = qjs::undefined_value();
}
