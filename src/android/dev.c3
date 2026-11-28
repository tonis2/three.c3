<*
 The Android/Quest development wrapper around `DevSession`: watches `<external>/game`
 for `adb push` updates and switches from the APK's bundled copy to the pushed copy
 on reload.

	adb forward tcp:8808 tcp:8808
	adb shell setprop debug.three.mcp 0    # to turn the tools off
*>
module three @feat(ANDROID);

import std::io;
import three::ndk;

struct HeadsetDev
{
	// Fixed address once open: MCP tools point into `session.tools`.
	DevSession session;
	// Owned; replaced when a reload finds a newly pushed game.
	GameDir game;
	// `<external>/game`, where `adb push` puts a game. Owned; empty without one.
	String pushed;
}

<*
 Starts the dev session and watches the pushed game folder.

 @param [&inout] runtime : "The runtime the tools drive"
 @param [&inout] renderer : "The renderer the tools capture from"
 @param game : "Taken over"
 @param external : "The activity's external data path, or empty"
*>
fn void HeadsetDev.open(&self, JsRuntime* runtime, Renderer* renderer, GameDir game, String external)
{
	self.game = game;
	bool mcp_off = ndk::property("debug.three.mcp") == "0";
	if (mcp_off) io::printn("mcp: off (debug.three.mcp is 0)");
	self.session.open(runtime, renderer, mcp_off ? 0 : DEFAULT_MCP_PORT, log_advice: true);
	if (self.session.serving)
	{
		io::printfn("mcp: adb forward tcp:%d tcp:%d", DEFAULT_MCP_PORT, DEFAULT_MCP_PORT);
	}

	if (external.len > 0)
	{
		self.pushed = string::format(mem, "%s/game", external);
		self.session.watch_path(string::tformat("%s/.reload", self.pushed));
		self.session.watch_path(string::tformat("%s/%s", self.pushed, ENTRY_MODULE));
		self.session.watch_path(string::tformat("%s/script.js", self.pushed));
	}
}

<*
 Answers waiting tool calls, then reloads if a call or an `adb push` asked for it.

 @return? reload!
*>
fn void? HeadsetDev.between_frames(&self, JsRuntime* runtime, Renderer* renderer)
{
	if (!self.session.poll(runtime)) return;

	// A first push after a launch from the APK switches to the pushed copy.
	if (self.pushed.len > 0)
	{
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
	String[1] scripts = { self.game.script };
	self.session.reload_scripts(runtime, renderer, scripts[..])!;
}

fn void HeadsetDev.close(&self)
{
	self.session.close();
	self.game.free();
	if (self.pushed.len > 0) free(self.pushed);
	*self = {};
}
