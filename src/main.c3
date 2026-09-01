<*
 three.c3 — the command line.

 three [options]

 --mcp [port]          serve run_script/screenshot/get_api_docs (default 8808)
 --mcp-stdio [port]    relay stdin/stdout to a three that is already serving
 --screenshot <path>   render one frame, write a PNG, exit
 --width <n>           the window's size in points, or the render size headless
 --height <n>          the same, vertically
 --headless            no window, no surface, no swapchain
 --script <file.js>    boot one script, then keep the window running
 --assets <dir>        boot a game: evaluate <dir>/main.js as a module
 --frames <n>          run n frames, then stop. Implies --headless
 --every <n>           with --frames, also shoot every n frames — see frame_path
 --camera <y,p,d>      yaw, pitch, distance, applied over whatever the script set
 --debug               validation layers, @debug_log, and the window's own chords
 --cache-dir <dir>     where compiled shaders are kept — see paths.c3

 This file is now only that: argv in, an `Options` out, and `main`'s exit code.
 Bringing the device up and describing a run is `app/boot.c3`; the window and the
 frame loop are `app/loop.c3`. The seam exists so that an application which links
 the engine's sources rather than running this binary never has to have a command
 line — see `app/boot.c3`'s header.

 There is no file argument. A model is loaded from JavaScript — `three.load`
 hands the script an object it can place, parent and dispose — and a model the
 command line put on screen was none of those things: nothing named it, nothing
 could free it, and it sat in a scene of its own for the life of the process.
 `--script` and `--assets` are the two ways in.

 The window is a viewer and also a control: drag to orbit, right-drag to pan,
 scroll to zoom. It writes the same `pass.camera` a script writes through
 `three.camera`, so the two compose with no arbitration — see
 `scene/controls.c3`, and `app/loop.c3` for the polling.

 `--debug` is the one flag that is about the process rather than the picture,
 and every build has it: the shipped binary and the one on this desk are the same
 binary, and which of the two is diagnosing is a decision taken at the terminal.
 It asks the loader for the Khronos validation layer, compiles nothing in or out
 for `@debug_log`, and unlocks the two chords the window otherwise answers on its
 own — escape to quit, shift+R to reload.

 Nothing behind it costs anything when it is off. A layer that was not requested
 is never inserted into the loader's dispatch chain, so there is no per-call
 branch to pay; the chords are one bool read a frame; and `@debug_log` leaves its
 arguments unevaluated either way, because it is a macro and the `if` is around
 the substituted expressions.

 What belongs behind it is what the engine does *behind the game's back*. A key
 the player never bound that quits the process is that; `three.quit()` and
 `three.reload()` are the game asking, and are answered in every build. See
 `validation_layer_present` in `src/gpu/device.c3` for the layer half.
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

const int DEFAULT_MCP_PORT = 8808;

faultdef BAD_ARGUMENT, MISSING_VALUE;

fn Options? parse_args(String[] args)
{
	Options opts = { .width = 1280, .height = 720 };

	for (usz i = 1; i < args.len; i++)
	{
		String arg = args[i];
		switch (arg)
		{
			case "--help":
			case "-h":
				opts.help = true;
			case "--headless":
				opts.headless = true;
			case "--debug":
				opts.debug = true;
			case "--cache-dir":
				if (i + 1 >= args.len) return MISSING_VALUE~;
				opts.cache_dir = args[++i];
				opts.cache_dir_set = true;
			case "--assets":
				if (i + 1 >= args.len) return MISSING_VALUE~;
				opts.assets = args[++i];
			case "--script":
				if (i + 1 >= args.len) return MISSING_VALUE~;
				opts.script = args[++i];
			case "--screenshot":
				if (i + 1 >= args.len) return MISSING_VALUE~;
				opts.screenshot = args[++i];
			case "--width":
				if (i + 1 >= args.len) return MISSING_VALUE~;
				opts.width = args[++i].to_uint()!;
			case "--height":
				if (i + 1 >= args.len) return MISSING_VALUE~;
				opts.height = args[++i].to_uint()!;
			case "--frames":
				if (i + 1 >= args.len) return MISSING_VALUE~;
				opts.frames = args[++i].to_uint()!;
			case "--every":
				if (i + 1 >= args.len) return MISSING_VALUE~;
				opts.every = args[++i].to_uint()!;
			case "--camera":
				if (i + 1 >= args.len) return MISSING_VALUE~;
				opts.camera = args[++i];
			case "--mcp":
				// The port is optional, so a following argument is consumed only
				// when it actually looks like one — otherwise `three --mcp
				// --headless` would swallow the flag beside it.
				opts.mcp_port = DEFAULT_MCP_PORT;
				if (i + 1 < args.len)
				{
					if (try port = args[i + 1].to_int())
					{
						opts.mcp_port = port;
						i++;
					}
				}
			case "--mcp-stdio":
				// The same optional port, for the same reason — and a port already
				// named by an earlier `--mcp` is kept, so the two flags compose in
				// either order.
				opts.relay_stdio = true;
				if (opts.mcp_port == 0) opts.mcp_port = DEFAULT_MCP_PORT;
				if (i + 1 < args.len)
				{
					if (try port = args[i + 1].to_int())
					{
						opts.mcp_port = port;
						i++;
					}
				}
			default:
				// Everything on the line is a flag. A bare path used to be loaded
				// and displayed, which is the one thing this cannot offer a script:
				// no handle to it, no way to dispose it, and a scene of its own for
				// the rest of the run. Loading is `three.load` inside a script.
				if (arg.starts_with("-"))
				{
					io::printfn("unknown option: %s", arg);
				}
				else
				{
					io::printfn("three takes no file argument: %s", arg);
					io::printn("  A model is loaded from a script: three.load(\"model.glb\").");
					io::printn("  --script <file.js> runs one; --assets <dir> boots <dir>/main.js.");
				}
				return BAD_ARGUMENT~;
		}
	}

	// A screenshot is a one-shot render and has no use for a window; asking for one
	// without --headless is the common case, so imply it rather than opening a
	// window that flashes for a frame.
	if (opts.screenshot.len > 0) opts.headless = true;
	// A bounded run is a batch, for the same reason and with one more: a window
	// that opened, played 600 frames at whatever rate the compositor felt like,
	// and closed is not something anybody asked to watch — and the point of
	// counting frames is that the same count means the same thing on every
	// machine, which a vsynced window is exactly what takes away.
	if (opts.frames > 0) opts.headless = true;
	// A server that rendered one frame and exited would be no server at all — and
	// one that played 600 and exited is the same mistake with a longer fuse.
	if (opts.mcp_port > 0)
	{
		opts.screenshot = "";
		opts.frames = 0;
	}
	// `--screenshot` on its own has always meant one frame. Saying so here is what
	// lets everything below read `frames` and never ask which mode it is in.
	if (opts.frames == 0 && opts.screenshot.len > 0) opts.frames = 1;

	return opts;
}

fn void usage()
{
	io::printn("three.c3 — a Three.js-shaped scene API over C3 and Vulkan");
	io::printfn("version %s", VERSION);
	io::printn("");
	io::printn("  three [options]");
	io::printn("");
	io::printn("  --mcp [port]          serve the agent tools on 127.0.0.1 (default 8808)");
	io::printn("  --mcp-stdio [port]    be the stdio end of a three that is already serving");
	io::printn("  --screenshot <path>   render one frame, write a PNG, exit");
	io::printn("  --width <n>           the window's width, or the render width headless (1280)");
	io::printn("  --height <n>          the window's height, or the render height headless (720)");
	io::printn("  --headless            no window, no surface, no swapchain");
	io::printn("  --script <file.js>    run one script, then keep the window running");
	io::printn("  --assets <dir>        boot a game: evaluate <dir>/main.js as a module");
	io::printn("  --frames <n>          run n frames and stop — implies --headless");
	io::printn("  --every <n>           with --frames, shoot every n frames: shot-%03d.png");
	io::printn("  --camera <yaw,pitch,distance>   look from here, over whatever the script set");
	io::printn("  --debug               diagnose this run — see below");
	io::printn("  --cache-dir <dir>     keep compiled shaders here (empty string: no cache)");
	io::printn("  -h, --help            this");
	io::printn("");
	io::printn("  There is no file argument: a model is loaded from a script, with");
	io::printn("  three.load(\"model.glb\"), which is what hands it back as an object.");
	io::printn("");
	// Said here rather than in the flag list because it is four things, and because
	// this is where somebody goes when a run is misbehaving. Every build has it —
	// the shipped binary is this binary — so the line is the same wherever it prints.
	io::printn("  --debug turns on, in any build:");
	io::printn("    Vulkan validation layers, if the Khronos layer is installed");
	io::printn("    @debug_log — driver, driver cache and shader cache lines");
	io::printn("    the device and limits table, at startup");
	io::printn("    escape to quit and shift+R to reload, in the window");
	io::printn("");
	io::printn("  The shader templates and the compiler that builds them are inside this");
	io::printn("  executable, so it runs from any directory. A shaders/ in the working");
	io::printn("  directory is compiled instead of the built-in copy, and the run says so.");
	io::printn("  Compiled shaders are cached under a checkout's build/, and otherwise in");
	io::printn("  the platform's cache directory — --cache-dir or THREE_CACHE_DIR move it.");
}



fn int main(String[] args)
{
	Options? parsed = parse_args(args);
	if (catch err = parsed)
	{
		usage();
		return 1;
	}
	Options opts = parsed;

	// Before the relay, before the window and before the device: `create_instance`
	// reads it, and an instance is the one thing that cannot be told afterwards.
	debugging = opts.debug;

	choose_caches(opts);

	if (opts.help)
	{
		usage();
		return 0;
	}

	// Before anything that opens a window or a device, and before anything that
	// could print: this process is the stdio end of another one's server, and the
	// only thing a client will tolerate on its stdout is JSON-RPC.
	if (opts.relay_stdio) return serve_relay(opts.mcp_port);

	if (catch err = run(opts))
	{
		io::printfn("three: %s", err);
		// All six templates are in the binary, so this is never a missing
		// shaders/ directory and there is no build step to suggest: it is a name
		// that is on neither the search path nor in here, which is a typo.
		if (err == SHADER_NOT_FOUND)
		{
			io::printn("  No template by that name, on the search path or in this binary. The six");
			io::printn("  are embedded, so this is a typo rather than a missing shaders/ directory");
			io::printn("  — see shader/load.c3.");
		}
		// The path is named here rather than in the fault, because this is the only
		// place that still has it: a `--script` typo is otherwise a bare fault name
		// over a path the shell may well have expanded.
		if (err == SCRIPT_NOT_READABLE)
		{
			io::printfn("  --script %s: not a file this can read.", opts.script);
			io::printn("  A directory is --assets, and it boots main.js as a module.");
		}
		// Not a shader error — a shader error is a Slang diagnostic, already printed
		// above this by the compiler with a line and a column.
		if (err == SLANG_UNAVAILABLE)
		{
			io::printn("  Slang would not start. It is linked into this binary, so this is");
			io::printn("  not a missing file — see the diagnostic above, if there was one.");
		}
		// Two different ways of saying "the only driver here is MoltenVK": the
		// loader refuses to make the instance when that is all it has, and the
		// device filter refuses the device if one reaches it anyway. Neither message
		// says what to do about it, so this does.
		if (err == PORTABILITY_DRIVER_ONLY || err == vk::E_ERROR_INCOMPATIBLE_DRIVER)
		{
			io::printn("  No supported Vulkan driver. three.c3 renders through KosmicKrisp,");
			io::printn("  which vulkan.c3l bundles; MoltenVK is not supported.");
			// The bundled driver failing to *open* looks identical to no driver at
			// all — `vk::findBundledDriver` reads a refused dlopen as "there is
			// none" and falls back — and the commonest reason it is refused is the
			// OS being older than the dylib. KosmicKrisp is built on Metal 4, so the
			// bundle carries a macOS 26 floor that nothing else in it does.
			$if env::DARWIN:
				io::printn("  It is a Metal 4 driver: macOS 26 or newer, on Apple Silicon.");
			$endif
		}
		return 1;
	}
	return 0;
}

