<*
 Desktop PCVR host: runs the shared OpenXR loop (`xr/loop.c3`) directly to an
 OpenXR runtime on Linux or Windows (SteamVR, Monado, WiVRn, Oculus PC) with no
 desktop swapchain or vsync contention.
*>
module three;

import std::io;
import std::thread;
import libc;
import xr;

bool desktop_vr_stop_requested @local;

fn void on_desktop_vr_sigint(CInt sig) @local
{
	(void)sig;
	desktop_vr_stop_requested = true;
}

struct DesktopXrShell (XrShell)
{
	DevSession* dev;
	String[] scripts;
}

fn bool DesktopXrShell.pump(&self, int timeout_ms) @dynamic
{
	if (desktop_vr_stop_requested) return false;
	if (timeout_ms > 0) (void)thread::sleep_ms((ulong)timeout_ms);
	return !desktop_vr_stop_requested;
}

fn void? DesktopXrShell.between_frames(&self, JsRuntime* runtime, Renderer* renderer) @dynamic
{
	if (self.dev == null || !self.dev.poll(runtime)) return;
	self.dev.reload_scripts(runtime, renderer, self.scripts)!;
}

<*
 Boots Desktop PCVR (`--vr`) with `profile`, runs the shared OpenXR frame loop,
 and tears everything down cleanly on runtime exit or Ctrl+C.

 @return? xr::LOADER_MISSING, xr::COMMAND_MISSING, xr::CALL_FAILED, Engine.open!, JsRuntime.open!, boot_world!
*>
fn void? run_desktop_vr(Options opts, RenderProfile profile)
{
	desktop_vr_stop_requested = false;
	libc::signal(libc::SIGINT, &on_desktop_vr_sigint);
	defer libc::signal(libc::SIGINT, null);

	XrHost* host = mem::new(XrHost);
	defer mem::free(host);
	defer host.close();

	if (catch err = host.open({ }, profile))
	{
		if (err == xr::LOADER_MISSING)
		{
			io::eprintn("xr: OpenXR loader not found (install an OpenXR runtime such as SteamVR, Monado, or WiVRn)");
		}
		return err~;
	}

	uint width = host.eye_width * 2;
	uint height = host.eye_height;

	Engine* engine = mem::new(Engine);
	defer mem::free(engine);
	defer engine.close();
	engine.open(width, height, headless: true, views: profile.views, samples: profile.msaa, profile: profile)!;
	engine.renderer.profile.report(&engine.renderer.gpu, &engine.renderer.target);

	host.start(&engine.renderer.gpu, engine.renderer.target.views)!;
	engine.renderer.xr_display.passthrough_supported = host.passthrough_supported;

	String[] scripts = opts.scripts();
	if (scripts.len == 0)
	{
		engine.renderer.pass.load_triangle(&engine.renderer.gpu)!;
	}

	JsRuntime runtime;
	runtime.open(&engine.renderer.pass, &engine.renderer)!;
	defer runtime.close();
	boot_world(&runtime, scripts)!;

	// Heap-allocated because MCP tools retain pointers into `dev.tools`.
	DevSession* dev = mem::new(DevSession);
	defer mem::free(dev);
	dev.open(&runtime, &engine.renderer, opts.mcp_port);
	defer dev.close();
	foreach (script : scripts) dev.watch_path(script);

	io::printn("xr: PCVR session active — press Ctrl+C to exit");
	DesktopXrShell shell = { .dev = dev, .scripts = scripts };
	run_xr(&shell, host, &engine.renderer, &runtime)!;
}
