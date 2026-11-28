<*
 Shared MCP server and file-watch hot-reload session, used by both Desktop PCVR
 (`app/xr_desktop.c3`) and Android/Quest (`android/dev.c3`).
*>
module three;

import std::io;
import std::time;
import mcp;

struct DevSession
{
	// Addressed by MCP tools, so this struct must stay at a fixed address once open.
	ToolHost tools;
	mcp::Server server;
	mcp::Listener listener;
	bool serving;
	GameWatch watch;
	Clock started;
}

<*
 Opens the dev session: initializes the file watcher and optionally starts the
 loopback MCP listener on `mcp_port` (0 disables MCP).

 @param [&inout] runtime : "Runtime the MCP tools drive"
 @param [&inout] renderer : "Renderer the MCP tools capture from"
 @param mcp_port : "Port to listen on, or 0 for none"
 @param log_advice : "When true, send engine advice straight to stdout/logcat"
*>
fn void DevSession.open(&self, JsRuntime* runtime, Renderer* renderer, int mcp_port = 0, bool log_advice = false)
{
	self.tools = { .runtime = runtime, .renderer = renderer };
	self.started = clock::now();
	self.watch.init(mem);

	if (mcp_port <= 0) return;
	self.server = new_mcp_server(&self.tools);
	if (log_advice) advise_quiet(false);
	if (catch err = self.listener.start(mcp_port))
	{
		io::eprintfn("mcp: could not listen on %d: %s", mcp_port, err);
		return;
	}
	self.serving = true;
	io::printfn("mcp: http://127.0.0.1:%d/mcp", mcp_port);
}

<* Adds a file path to watch for hot-reload changes. *>
fn void DevSession.watch_path(&self, String path)
{
	if (path.len > 0) self.watch.add(path);
}

<*
 Pumps waiting MCP requests and checks whether a reload was asked for (either by
 a script/tool call or by a watched file changing).

 @return "True when a reload should now run"
*>
fn bool DevSession.poll(&self, JsRuntime* runtime)
{
	if (self.serving) self.listener.pump(&self.server);
	bool changed = self.watch.step((long)self.started.to_now() / 1_000_000);
	return runtime.reload_wanted || changed;
}

<*
 Idles the GPU and reloads `scripts` into `runtime`.

 @return? reload!
*>
fn void? DevSession.reload_scripts(&self, JsRuntime* runtime, Renderer* renderer, String[] scripts)
{
	Clock took = clock::now();
	// Frames may still be in flight, and reload frees what they draw with.
	renderer.gpu.wait_idle();
	reload(runtime, &renderer.pass, renderer, null, scripts)!;
	io::printfn("three: reloaded in %d ms", (long)took.to_now() / 1_000_000);
}

fn void DevSession.close(&self)
{
	if (self.serving) self.listener.stop();
	self.watch.free();
	*self = {};
}
