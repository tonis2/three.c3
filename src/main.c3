<*
 three.c3 — boot, CLI, the window loop, and the MCP server.

	three [file.glb] [options]

	--mcp [port]          serve run_script/screenshot/get_api_docs (default 8808)
	--screenshot <path>   render one frame, write a PNG, exit
	--width <n>           offscreen render width  (default 1280)
	--height <n>          offscreen render height (default 720)
	--headless            no window, no surface, no swapchain
	--validate            Vulkan validation layers + debug messenger
	--no-validate         turn them off — --mcp turns them on by default
	--grid <n>            n instances of the model, to see M2's claim hold

 **`--mcp` is the driving surface M3 exists for**; everything else here is the
 CLI the base stage was driven by, kept because it is how a human looks at a
 file and how `--stress-resize` and `--grid` stay runnable.

 **`--mcp` implies `--validate`.** `plan.md` §4: "run the validation layers
 whenever a script is executing". Serving is when scripts execute, and a
 validation error only becomes part of `run_script`'s answer if the layer that
 produces it is loaded — so leaving it to the caller would mean the third of the
 four things a run answers with is usually absent. `--no-validate` is the way
 back out; a machine with no layer installed needs neither, because
 `create_instance` skips it and says so.

 The server's handlers run on *this* thread — `Listener` moves bytes on its own
 and `pump` runs the work on the caller's — so a script, the scene it builds and
 the device it draws with are all touched from one place, and none of the three
 needs a lock.
*>
module three;

import std::io;
import std::thread;
import c3w;
import vk;
import image;
import mcp;

const String VERSION = "0.1.0";

struct Options
{
	String model;
	String screenshot;
	uint width;
	uint height;
	bool headless;
	bool validate;
	// Kept apart from `validate` so that "not asked for" and "asked to be off"
	// stay distinguishable while --mcp is deciding the default.
	bool no_validate;
	String shader;
	bool system_driver;
	bool stress_resize;
	uint grid;
	// 0 for "do not serve". The port is only ever bound on 127.0.0.1.
	int mcp_port;
	bool help;
}

const int DEFAULT_MCP_PORT = 8808;

faultdef BAD_ARGUMENT, MISSING_VALUE, RESIZE_HAD_NO_EFFECT;

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
			case "--validate":
				opts.validate = true;
			case "--no-validate":
				opts.no_validate = true;
			case "--system-driver":
				opts.system_driver = true;
			case "--stress-resize":
				opts.stress_resize = true;
			case "--shader":
				if (i + 1 >= args.len) return MISSING_VALUE~;
				opts.shader = args[++i];
			case "--screenshot":
				if (i + 1 >= args.len) return MISSING_VALUE~;
				opts.screenshot = args[++i];
			case "--width":
				if (i + 1 >= args.len) return MISSING_VALUE~;
				opts.width = args[++i].to_uint()!;
			case "--height":
				if (i + 1 >= args.len) return MISSING_VALUE~;
				opts.height = args[++i].to_uint()!;
			case "--grid":
				if (i + 1 >= args.len) return MISSING_VALUE~;
				opts.grid = args[++i].to_uint()!;
			case "--mcp":
				// The port is optional, so a following argument is consumed only
				// when it actually looks like one — otherwise `three --mcp
				// model.glb` would swallow the model and then report no file.
				opts.mcp_port = DEFAULT_MCP_PORT;
				if (i + 1 < args.len)
				{
					if (try port = args[i + 1].to_int())
					{
						opts.mcp_port = port;
						i++;
					}
				}
			default:
				if (arg.starts_with("-"))
				{
					io::printfn("unknown option: %s", arg);
					return BAD_ARGUMENT~;
				}
				opts.model = arg;
		}
	}

	// A screenshot is a one-shot render and has no use for a window; asking for
	// one without --headless is the common case, so imply it rather than
	// opening a window that flashes for a frame.
	if (opts.screenshot.len > 0) opts.headless = true;
	// The probe drives a real window; there is nothing to resize without one.
	if (opts.stress_resize) opts.headless = false;
	// A server that rendered one frame and exited would be no server at all.
	if (opts.mcp_port > 0) opts.screenshot = "";
	// Serving is when scripts run, and a script's validation errors are part of
	// what `run_script` answers with — see the header. `--no-validate` wins
	// outright rather than by position, because a flag whose meaning depends on
	// what came before it on the line is a flag people get wrong.
	if (opts.no_validate) { opts.validate = false; }
	else if (opts.mcp_port > 0) { opts.validate = true; }

	return opts;
}

fn void usage()
{
	io::printn("three.c3 — a Three.js-shaped scene API over C3 and Vulkan");
	io::printfn("version %s", VERSION);
	io::printn("");
	io::printn("  three [file.glb] [options]");
	io::printn("");
	io::printn("  --mcp [port]          serve the agent tools on 127.0.0.1 (default 8808)");
	io::printn("  --screenshot <path>   render one frame, write a PNG, exit");
	io::printn("  --width <n>           offscreen render width  (default 1280)");
	io::printn("  --height <n>          offscreen render height (default 720)");
	io::printn("  --headless            no window, no surface, no swapchain");
	io::printn("  --validate            Vulkan validation layers + debug messenger");
	io::printn("  --no-validate         turn them off — --mcp turns them on by default");
	io::printn("  --system-driver       use an installed KosmicKrisp, not the bundled one");
	io::printn("  --grid <n>            place n instances of the model in a grid");
	io::printn("  --stress-resize       walk the window through sizes and exit (dev)");
	io::printn("  --shader <path>       a mesh.slang other than the one on the search path");
	io::printn("  -h, --help            this");
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

	if (opts.help)
	{
		usage();
		return 0;
	}

	if (catch err = run(opts))
	{
		io::printfn("three: %s", err);
		// The one failure with an obvious next step, and the one most likely to
		// be hit: the shader is read from disk relative to the working
		// directory, so running from anywhere but the project root finds
		// nothing. There is no build step to suggest any more — M4 compiles
		// the source at startup.
		if (err == SHADER_NOT_FOUND)
		{
			io::printn("  shaders/mesh.slang is not on the search path.");
			io::printn("  Run from the project root, or point at one with --shader <path>.");
		}
		// Not a shader error — a shader error is a Slang diagnostic, already
		// printed above this by the compiler with a line and a column.
		if (err == SLANG_UNAVAILABLE)
		{
			io::printn("  Slang would not start. The libraries it loads are staged with:");
			io::printn("      ./lib/slang.c3l/native/stage-slang.sh");
		}
		// Two different ways of saying "the only driver here is MoltenVK": the
		// loader refuses to make the instance when that is all it has, and the
		// device filter refuses the device if one reaches it anyway. Neither
		// message says what to do about it, so this does.
		if (err == PORTABILITY_DRIVER_ONLY || err == vk::E_ERROR_INCOMPATIBLE_DRIVER)
		{
			io::printn("  No supported Vulkan driver. three.c3 renders through KosmicKrisp,");
			io::printn("  which vulkan.c3l bundles; MoltenVK is not supported.");
			if (opts.system_driver) io::printn("  Drop --system-driver to use the bundled one.");
		}
		return 1;
	}
	return 0;
}

fn void? run(Options opts)
{
	// The window is a viewer, never a render target (plan.md §1). It is opened
	// first only because the surface has to come from somewhere; nothing about
	// it reaches the offscreen target's extent or format.
	c3w::Window window;
	bool windowed = !opts.headless;
	if (windowed)
	{
		window = c3w::new(
			params: { .x = 0, .y = 0, .width = (int)opts.width, .height = (int)opts.height },
			name: "three.c3"
		)!;
	}
	defer if (windowed) window.free();

	vk::Instance instance = create_instance(
		opts.validate,
		headless: opts.headless,
		bundled_driver: !opts.system_driver
	)!;
	defer instance.free();

	vk::SurfaceKHR surface;
	if (windowed)
	{
		surface = (vk::SurfaceKHR)window.create_vk_surface(
			instance,
			(c3w::VkGetInstanceProcAddrFn)vk::getInstanceProcAddr
		)!;
	}
	defer if (windowed) surface.free(instance);

	Renderer renderer;
	renderer.init(instance, surface, opts.width, opts.height, opts.validate)!;
	defer renderer.free();

	if (opts.validate) renderer.gpu.report();

	// The shader is compiled here, from shaders/mesh.slang on disk. Editing it
	// and re-running changes the picture — no rebuild of this binary, and since
	// M4 no build step for the shader either.
	renderer.pass.init(&renderer.gpu, &renderer.target, opts.shader)!;

	if (opts.grid > 0)
	{
		renderer.pass.instance_grid(&renderer.gpu, opts.model, opts.grid)!;
	}
	else if (opts.model.len > 0)
	{
		renderer.pass.load(&renderer.gpu, opts.model)!;
	}
	else
	{
		renderer.pass.load_triangle(&renderer.gpu)!;
	}

	// The line an agent reads its own cost off. `instances` next to `draw calls`
	// is the whole M2 claim in two numbers: a grid of a thousand is a thousand
	// and one, not a thousand and a thousand.
	SceneStats stats = renderer.pass.stats();
	io::printfn(
		"%s: %d draw calls, %d instances, %d unique meshes, %d textures (%d KiB), %d triangles",
		opts.model.len > 0 ? opts.model : "built-in triangle",
		stats.draw_calls,
		stats.instances,
		stats.unique_meshes,
		stats.textures,
		stats.texture_bytes / 1024,
		stats.triangles
	);

	// Before every one-shot path below: a server does not render one frame and
	// exit, and it works with or without a window.
	if (opts.mcp_port > 0)
	{
		serve(&renderer, windowed ? &window : null, opts.mcp_port)!;
		return;
	}

	if (opts.screenshot.len > 0)
	{
		renderer.screenshot(opts.screenshot)!;
		io::printfn("wrote %s (%dx%d)", opts.screenshot, opts.width, opts.height);
		return;
	}

	// Headless with nothing to write is still worth running: it exercises the
	// whole render path with no window server, which is exactly what the tests
	// do.
	if (!windowed)
	{
		image::Image frame = renderer.capture()!;
		defer frame.free();
		io::printfn("rendered %dx%d headless", frame.width, frame.height);
		return;
	}

	if (opts.stress_resize)
	{
		stress_resize(&renderer, &window)!;
		io::printn("resize stress complete");
		return;
	}

	while (!window.should_close())
	{
		c3w::EventMap events = window.getEvent();
		if (events.is_pressed(ESCAPE)) break;
		renderer.frame()!;
	}
}

<*
 Serve the three tools until the window closes, or until interrupted when there
 is no window.

 **The handlers run on this loop's thread.** `Listener` gives its own thread to
 moving bytes — accept, read one message, queue it — and `pump` is where
 `handle_message` actually runs, which is what makes the scene, the JS context
 and the Vulkan device reachable from a tool without a lock between them. All
 three are single-threaded and none of them is prepared to be otherwise.

 @param window : `Null when headless: the loop then only serves, and there is nothing to present.`
*>
fn void? serve(Renderer* renderer, c3w::Window* window, int port)
{
	JsRuntime runtime;
	runtime.open(&renderer.pass, renderer)!;
	defer runtime.close();

	// Addressed by pointer from every tool, so it must not move while the
	// server lives — which is why it is a local of the function that owns the
	// loop rather than something returned from a builder.
	ToolHost host = { .runtime = &runtime, .renderer = renderer };
	mcp::Server server = new_mcp_server(&host);

	mcp::Listener listener;
	listener.start(port)!;
	defer listener.stop();

	io::printfn("mcp: http://127.0.0.1:%d/mcp", port);
	io::printn("     run_script, screenshot, get_api_docs");
	if (window == null) io::printn("     headless — ctrl-c to stop");

	while (true)
	{
		if (window != null)
		{
			if (window.should_close()) break;
			c3w::EventMap events = window.getEvent();
			if (events.is_pressed(ESCAPE)) break;
		}

		usz handled = listener.pump(&server);

		if (window != null)
		{
			// Kept running whether or not anything arrived: a window that only
			// redrew when a tool was called would stop responding between
			// requests, which reads as a hung application.
			renderer.frame()!;
		}
		else if (handled == 0)
		{
			// A tight loop here would peg a core for as long as the server is
			// idle, which is most of its life.
			thread::sleep_ms(4)!!;
		}
	}
}

<*
 Walk the window through a spread of sizes, then a minimise and a restore,
 rendering the whole way. Run it under `--validate`: the pass condition is that
 nothing is printed.

 The sizes are deliberately awkward — a near-square, a very wide one, a very
 tall one, one small enough to be mostly title bar — because the bugs here are
 in the blit's destination rect and in swapchain images being destroyed while a
 presentation still refers to them, and both hide at comfortable aspect ratios.
*>
fn void? stress_resize(Renderer* renderer, c3w::Window* window)
{
	int[2][*] sizes = {
		{ 900, 500 }, { 1600, 1000 }, { 320, 240 }, { 1440, 200 }, { 240, 900 }, { 1024, 768 },
	};

	// Checked, not assumed: a `set_size` that silently did nothing would leave
	// every frame below rendering at one extent, and "no validation errors"
	// would still hold. The test would pass by never testing anything.
	uint changes = 0;
	vk::Extent2D previous = renderer.viewer.extent;

	foreach (size : sizes)
	{
		window.set_size(size[0], size[1]);
		pump(renderer, window, 20)!;

		vk::Extent2D now = renderer.viewer.extent;
		if (now.width != previous.width || now.height != previous.height) changes++;
		io::printfn("  %d x %d requested -> surface %d x %d", size[0], size[1], now.width, now.height);
		previous = now;
	}

	if (changes == 0) return RESIZE_HAD_NO_EFFECT~;

	// Minimised, the surface reports a zero extent and there is nothing to
	// build a swapchain for. The frame path has to notice and skip rather than
	// spin on an acquire that keeps failing.
	//
	// `set_minimized(false)` restores on macOS, X11 and Win32 but is a no-op on
	// Wayland, where xdg-shell has no un-minimise request — so on Wayland the
	// frames after this are the minimised case running twice, which is a
	// weaker check rather than a broken one.
	window.set_minimized(true);
	pump(renderer, window, 30)!;
	window.set_minimized(false);
	pump(renderer, window, 30)!;
}

fn void? pump(Renderer* renderer, c3w::Window* window, uint frames)
{
	for (uint i = 0; i < frames; i++)
	{
		window.getEvent();
		renderer.frame()!;
	}
}
