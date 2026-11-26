<*
 The development side of a headset run: the agent tools over `adb forward`, and
 a reload when a script is pushed with adb. Both happen between frames, where
 nothing of JavaScript's is on the stack.

	adb forward tcp:8808 tcp:8808
	adb shell setprop debug.three.mcp 0    # to turn the tools off
*>
module three @feat(ANDROID);

import std::io;
import std::time;
import mcp;
import three::ndk;

struct HeadsetDev
{
	// Addressed by the server's tools, so this struct must not move once open.
	ToolHost tools;
	mcp::Server server;
	mcp::Listener listener;
	bool serving;
	GameWatch watch;
	// Owned; replaced when a reload finds a newly pushed game.
	GameDir game;
	// `<external>/game`, where `adb push` puts a game. Owned; empty without one.
	String pushed;
	Clock started;
}

<*
 Starts the tools and the watch.

 @param [&inout] runtime : "The runtime the tools drive"
 @param [&inout] renderer : "The renderer the tools capture from"
 @param game : "Taken over"
 @param external : "The activity's external data path, or empty"
*>
fn void HeadsetDev.open(&self, JsRuntime* runtime, Renderer* renderer, GameDir game, String external)
{
	self.tools = { .runtime = runtime, .renderer = renderer };
	self.game = game;
	self.started = clock::now();

	self.watch.init(mem);
	if (external.len > 0)
	{
		self.pushed = string::format(mem, "%s/game", external);
		self.watch.add(string::tformat("%s/.reload", self.pushed));
		self.watch.add(string::tformat("%s/%s", self.pushed, ENTRY_MODULE));
		self.watch.add(string::tformat("%s/script.js", self.pushed));
	}

	if (ndk::property("debug.three.mcp") == "0")
	{
		io::printn("mcp: off (debug.three.mcp is 0)");
		return;
	}
	self.server = new_mcp_server(&self.tools);
	// Logcat is the only place advice can go on a headset.
	advise_quiet(false);
	if (catch err = self.listener.start(DEFAULT_MCP_PORT))
	{
		io::eprintfn("mcp: could not listen on %d: %s", DEFAULT_MCP_PORT, err);
		return;
	}
	self.serving = true;
	io::printfn("mcp: http://127.0.0.1:%d/mcp (adb forward tcp:%d tcp:%d)", DEFAULT_MCP_PORT,
		DEFAULT_MCP_PORT, DEFAULT_MCP_PORT);
}

<*
 Answers waiting tool calls, then reloads if a call or a push asked for it.

 @param [&inout] runtime : "The runtime to reload"
 @param [&inout] renderer : "Waited on before the old world is freed"
 @return? reload!
*>
fn void? HeadsetDev.between_frames(&self, JsRuntime* runtime, Renderer* renderer)
{
	if (self.serving) self.listener.pump(&self.server);
	bool pushed = self.watch.step((long)self.started.to_now() / 1_000_000);
	if (!runtime.reload_wanted && !pushed) return;

	// A first push after a launch from the APK switches to the pushed copy.
	if (self.pushed.len > 0)
	{
		// `game_in` keeps the root it is given.
		String root = self.pushed.copy(mem);
		if (try found = game_in(root))
		{
			self.game.free();
			self.game = found;
		}
		else
		{
			free(root);
		}
	}
	Clock took = clock::now();
	// Frames are in flight, and the reload frees what they draw with.
	renderer.gpu.wait_idle();
	String[1] scripts = { self.game.script };
	reload(runtime, &renderer.pass, renderer, null, scripts[..])!;
	io::printfn("three: reloaded %s in %d ms", self.game.script, (long)took.to_now() / 1_000_000);
}

fn void HeadsetDev.close(&self)
{
	if (self.serving) self.listener.stop();
	self.watch.free();
	self.game.free();
	if (self.pushed.len > 0) free(self.pushed);
	*self = {};
}
