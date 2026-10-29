<*
 Two tools and no more: `run_script` and `screenshot`.

 `run_script` *is* the API surface. Every scene verb an agent could want is
 already a JavaScript call, so a `create_mesh` tool beside it would be a second,
 worse spelling of something the script can already do — and one that has to be
 kept in step with the first. `screenshot` exists because it is the one thing a
 script cannot answer for itself: what the frame looks like.

 What the API *is* is not a tool either. It is the Markdown in `docs/`, and
 `run_script`'s description names where that folder is on this machine, so an
 agent reads and greps it with its own tools.

 ## The answer shape

 `run_script` returns a content array rather than text, because one of the four
 things it always answers with is a PNG and an image block is the only way to
 carry one. The first block is the report — log, value, error, stats, as JSON —
 and the second is the frame. Both, whether or not the script succeeded: a failed
 run that returns only an error makes the agent guess how far it got, and the
 picture of a half-built scene is often the thing that says.

 ## Threading

 `Listener` moves bytes on its own thread and `Listener.pump` runs the handlers
 on the caller's, which is what makes this safe: the scene, the JS context and
 the Vulkan device are all single-threaded, and a handler only ever runs from the
 same loop that renders.
*>
module three;

import std::io::file;
import std::io::path;
import std::math;
import std::collections::object;
import std::encoding::base64;
import image;
import image::png;
import mcp;

faultdef TOOL_NEEDS_SOURCE, TOOL_NEEDS_DEVICE, TOOL_NO_RUNTIME, TOOL_WRITE_FAILED;

<*
 What the tool handlers are given. Must outlive the server.
*>
struct ToolHost
{
	JsRuntime* runtime;
	Renderer* renderer;
}

<*
 Builds the server. The tools are registered here and nowhere else.
*>
fn mcp::Server new_mcp_server(ToolHost* host)
{
	mcp::Server server = mcp::new_server({ .name = "three.c3", .version = VERSION });

	// A script reached through a tool gets a longer default than one reached
	// through a window — `JS_MCP_BUDGET_MS` has the argument. Here rather than at
	// the `run` below, so that it is the *default* that moves and not the run:
	// `three.budget` still works, still clamps, and still persists exactly as it
	// documents. Serving is what changes it, which is why this is in the function
	// that builds the tools.
	// Zero is a host that turned the interrupt off on purpose (a pipeline runner,
	// whose work is minutes long); raising it would put the wall back.
	if (host != null && host.runtime != null && host.runtime.script_budget_ns != 0)
	{
		host.runtime.script_budget_ns = JS_MCP_BUDGET_MS * 1_000_000;
	}

	// And the advice stops going to the terminal, for the same reason and in the
	// same place. `run_script` answers with a `warnings` array, so under a server
	// the terminal is a second copy of it — printed at a person who is watching an
	// agent work and reading advice about a script they did not write.
	// `advise_quiet` has the rest.
	advise_quiet(true);

	server.add_tool(
		{
			.name = "run_script",
			.description = run_script_description(),
			.input_schema = `{"type":"object","properties":{"code":{"type":"string","description":"Alias of source."},"source":{"type":"string","description":"The script. Runs as an async function body, so top-level await works. three.debug.write(x) is how it answers with a value; what it writes arrives in the debug field."},"image":{"type":"boolean","description":"Whether the reply carries a PNG of the frame. Default true. false for a script that only reads or changes data: the reply is the report alone and no frame is drawn for it."}},"anyOf":[{"required":["source"]},{"required":["code"]}]}`,
			.handler = &tool_run_script,
			.user_data = host,
			.raw_content = true,
		}
	);

	server.add_tool(
		{
			.name = "screenshot",
			.description = "Render the current scene and return the frame as a PNG, at most 1568 px on its "
				"longest side. Optionally also write it to a file, at full size. Takes no view arguments — "
				"move three.camera from a script.",
			.input_schema = `{"type":"object","properties":{"path":{"type":"string","description":"Where to also write the PNG. Omit to only receive the image."}}}`,
			.handler = &tool_screenshot,
			.user_data = host,
			.raw_content = true,
		}
	);

	return server;
}

// ============================================================================
// run_script
// ============================================================================

fn String? tool_run_script(Object* args, void* user_data, DString* detail)
{
	ToolHost* host = (ToolHost*)user_data;
	if (host == null || host.runtime == null)
	{
		detail.append_string("there is no script runtime in this process");
		return TOOL_NO_RUNTIME~;
	}

	if (args == null)
	{
		detail.append_string("run_script needs a `source` (or `code`) string: the JavaScript to run");
		return TOOL_NEEDS_SOURCE~;
	}

	// `code` is accepted as an alias: it is the name callers reach for first.
	String? source = args.get_string("source");
	if (catch err = source) source = args.get_string("code");
	if (catch err = source)
	{
		// Naming the argument and its type is the difference between a retry that
		// works and one that guesses again, and it applies most to the one tool an
		// agent calls on every turn.
		detail.append_string("run_script needs a `source` (or `code`) string: the JavaScript to run");
		return TOOL_NEEDS_SOURCE~;
	}

	bool with_image = true;
	if (try wanted = args.get_bool("image")) with_image = wanted;

	RunResult result = host.runtime.run(source, "<run_script>");
	defer result.free();

	DString report;
	report.init(mem, 2048);
	defer report.free();

	report.append_string(`{"ok":`);
	report.append_string(result.ok ? "true" : "false");

	report.append_string(`,"log":`);
	append_json_string(&report, result.log);

	// Beside `log` and only when there is something in it. The two are different
	// facts — one is what the script printed and the other is what the renderer
	// noticed about it — and an agent that cannot tell them apart stops reading
	// either. Absent on nearly every run, which is what keeps it worth reading on
	// the runs it appears in.
	if (result.warnings.len > 0)
	{
		report.append_string(`,"warnings":`);
		append_json_lines(&report, result.warnings);
	}

	// Spliced rather than escaped: it is already JSON, and quoting it would hand
	// the agent the characters of its own result instead of the result.
	report.append_string(`,"value":`);
	report.append_string(result.value.len > 0 ? result.value : "null");

	// Beside `value` and only when the script wrote one, for the reason `warnings`
	// sits beside `log`: what a script SAID on its way through and what it ANSWERED
	// with are two facts, and a caller that has to guess which one it is holding
	// reads neither. Spliced for the same reason `value` is — it is already JSON.
	if (result.debug.len > 0)
	{
		report.append_string(`,"debug":`);
		report.append_string(result.debug);
	}

	if (!result.ok)
	{
		report.append_string(`,"error":`);
		append_json_string(&report, result.error);
	}

	report.append_string(`,"stats":`);
	append_stats(&report, result.stats, result.timing);

	// Only when there is something to say. A `"frame"` block on every result would
	// be noise on the overwhelming majority of scripts, which never register a
	// callback — and noise on every result is how a field stops being read at all.
	if (result.frame_running || result.frame_ticks > 0 || result.frame_error.len > 0)
	{
		report.append_string(`,"frame":{"running":`);
		report.append_string(result.frame_running ? "true" : "false");
		report.append_string(`,"ticks":`);
		report.appendf("%d", result.frame_ticks)!!;
		// Only in a game boot, where it is ever non-zero — and then always, even at
		// zero, because "no frames ran long" is the answer somebody checking for
		// hitching came to read.
		if (result.frame_overruns > 0)
		{
			report.append_string(`,"overruns":`);
			report.appendf("%d", result.frame_overruns)!!;
		}
		if (result.frame_error.len > 0)
		{
			report.append_string(`,"error":`);
			append_json_string(&report, result.frame_error);
		}
		report.append_char('}');
	}

	return content_with_frame(host, &report, with_image);
}

// ============================================================================
// screenshot
// ============================================================================

fn String? tool_screenshot(Object* args, void* user_data, DString* detail)
{
	ToolHost* host = (ToolHost*)user_data;
	if (host == null || host.renderer == null)
	{
		detail.append_string("this process has no GPU device, so there is nothing to render");
		return TOOL_NEEDS_DEVICE~;
	}

	String path = "";
	if (args != null)
	{
		if (try given = args.get_string("path")) path = given;
	}

	DString report;
	report.init(mem, 256);
	defer report.free();

	report.append_string(`{"width":`);
	report.appendf("%d", host.renderer.target.extent.width)!!;
	report.append_string(`,"height":`);
	report.appendf("%d", host.renderer.target.extent.height)!!;

	if (path.len > 0)
	{
		if (catch err = host.renderer.screenshot(path))
		{
			detail.appendf("could not write %s: %s", path, err)!!;
			return TOOL_WRITE_FAILED~;
		}
		report.append_string(`,"path":`);
		append_json_string(&report, path);
	}

	return content_with_frame(host, &report);
}

// ============================================================================
// The docs
// ============================================================================

const String DOCS_ONLINE = "https://github.com/tonis2/three.c3/tree/main/docs";

<*
 `run_script`'s description, with the docs folder named in it.

 Built once and kept in a buffer of its own: `new_mcp_server` runs per
 `run_script` as well as at startup, and the folder cannot move under a running
 process.
*>
fn String run_script_description()
{
	static char[8192] buffer;
	static String text;
	if (text.len) return text;
	char[]? written = io::bprintf(&buffer,
		"Run a JavaScript scene script and get back everything it logged, everything it "
		"wrote with three.debug.write, the scene's stats, and a PNG of the frame (at most "
		"1568 px on its longest side; image:false leaves it out). The API "
		"is Three.js-shaped: "
		"three.load, three.Scene, three.Mesh, three.Group, position/rotation/scale, add/remove. "
		"It is documented in Markdown in %s - read README.md and differences.md there before "
		"your first script (each difference is a script that would otherwise fail), and look "
		"things up in functions.md and classes.md. Use three.debug.write(x) to send a "
		"value back — from anywhere in the script, including from inside a system or an "
		"animation callback.", docs_location());
	if (try done = written)
	{
		text = (String)done;
	}
	else
	{
		text = "Run a JavaScript scene script. The API is documented in Markdown at "
			"https://github.com/tonis2/three.c3/tree/main/docs.";
	}
	return text;
}

<*
 Where the API's Markdown is, as an absolute path an agent can open.

 Beside the executable is a release bundle, which ships `docs/` next to the
 binary; one level up is a checkout's `build/three`; the working directory is a
 binary run from elsewhere inside a checkout. The first that holds `functions.md`
 wins. When none does, the answer is the folder on GitHub.
*>
fn String docs_location()
{
	static char[4096] buffer;
	static String found;
	if (found.len) return found;
	found = DOCS_ONLINE;
	@pool()
	{
		String beside = executable_dir(tmem) ?? "";
		String here = "";
		if (try cwd = path::tcwd()) here = (String)cwd;
		String[3] candidates = {
			beside.len ? string::tformat("%s/docs", beside) : "",
			beside.len ? string::tformat("%s/docs", parent_of(beside)) : "",
			here.len ? string::tformat("%s/docs", here) : "",
		};
		foreach (candidate : candidates)
		{
			if (candidate.len == 0 || candidate.len > buffer.len) continue;
			if (!file::is_file(string::tformat("%s/functions.md", candidate))) continue;
			buffer[:candidate.len] = candidate[..];
			found = (String)buffer[:candidate.len];
			break;
		}
	};
	return found;
}

<*
 The directory above `dir`, which has no trailing separator. Either separator,
 since Windows answers `executable_dir` with backslashes.
*>
fn String parent_of(String dir) @private
{
	sz at = last_separator(dir);
	if (at < 0) return dir;
	return at == 0 ? dir[:1] : dir[:(usz)at];
}

// ============================================================================
// Building the answer
// ============================================================================

<*
 The longest edge a reply's PNG may have, in pixels.

 A client scales a bigger image down to about this before a model sees it, so
 the pixels above it are bytes on the wire that nobody reads.
*>
const uint FRAME_MAX_EDGE = 1568;

<*
 A content array: the report as text, and the frame as a PNG when there is a
 device to render one with and the caller wants one.

 A run with no device is not an error — the scene-math half of the API works
 without one — so the image block is left out rather than the call failing.

 A frame longer than `FRAME_MAX_EDGE` is scaled down to it, and the report then
 gains an `image` block with both sizes, so a pixel read off the picture can be
 turned back into a pixel of the render.

 @param report : `The report's JSON object, still open. Closed and escaped into the text block here.`
 @param with_image : `False to leave the frame out and not draw one.`
 @return `The content array, allocated from mem, for a raw_content tool.`
*>
fn String? content_with_frame(ToolHost* host, DString* report, bool with_image = true)
{
	DString out;
	out.init(mem, 4096);
	defer out.free();

	@pool()
	{
		String data = "";
		if (with_image && host.renderer != null)
		{
			image::Image? frame = host.renderer.capture(tmem);
			if (try shot = frame)
			{
				image::Image sent = shot;
				uint edge = math::max(shot.width, shot.height);
				bool scaled = edge > FRAME_MAX_EDGE;
				// Rounded up, so a thin frame cannot lose a side to zero.
				if (scaled)
				{
					uint width = (uint)(((ulong)shot.width * FRAME_MAX_EDGE + edge - 1) / edge);
					uint height = (uint)(((ulong)shot.height * FRAME_MAX_EDGE + edge - 1) / edge);
					sent = shot.resize(width, height, tmem);
				}
				char[]? encoded = png::save_bytes(&sent, tmem);
				if (try bytes = encoded)
				{
					data = base64::tencode(bytes);
					if (scaled)
					{
						report.appendf(`,"image":{"width":%d,"height":%d,"renderWidth":%d,"renderHeight":%d}`,
							sent.width, sent.height, shot.width, shot.height)!!;
					}
				}
			}
		}
		report.append_char('}');

		out.append_string(`[{"type":"text","text":`);
		append_json_string(&out, report.str_view());
		out.append_char('}');

		if (data.len > 0)
		{
			out.append_string(`,{"type":"image","mimeType":"image/png","data":"`);
			out.append_string(data);
			out.append_string(`"}`);
		}
	};

	out.append_char(']');
	return out.copy_str(mem);
}

fn void append_json_string(DString* out, String text)
{
	out.append_char('"');
	mcp::json_escape_into(out, text);
	out.append_char('"');
}

<*
 One newline-separated string as a JSON array of strings.

 The shape `RunResult.warnings` arrives in, and the reason an array is built here
 rather than in `advice.c3`: the sink has fixed storage and no allocator, and
 this has a `DString` already open. Splitting on newlines is exact because the
 sink flattens a message's own newlines to spaces on the way in — `advice.c3` has
 that rule and this is the reader it exists for.
*>
fn void append_json_lines(DString* out, String text)
{
	out.append_char('[');
	usz from   = 0;
	bool first = true;
	for (usz i = 0; i <= text.len; i++)
	{
		if (i < text.len && text[i] != '\n') continue;
		if (i > from)
		{
			if (!first) out.append_char(',');
			append_json_string(out, text[from:i - from]);
			first = false;
		}
		from = i + 1;
	}
	out.append_char(']');
}

<*
 The stats block, camelCase, matching what `three.stats()` hands a script.

 The same names on both sides on purpose: an agent that reads `drawCalls` off a
 tool result and then asserts on `scene.stats().drawCalls` in its next script
 should not have to notice that they were spelled differently.

 The timings ride along for the same reason, and are a separate argument because
 they are not scene facts: `SceneStats` is device-free, and the millisecond
 counts belong to whichever frame the run last drew.

 The five phases are here and not only in `stats()` because this is the result an
 agent reads without being asked to: a tool result that already says
 `"shadowMs":2.66` next to `"gpuMs":3.92` saves finding out where a frame went by
 editing the scene six times. They sum to `gpuMs`, so the block is a breakdown
 rather than a sample.

 Six decimal places rather than two: a headless 200x150 frame costs tens of
 microseconds, and `%.2f` would report every one of them as `0.00` — a number
 that looks like the "nothing was measured" zero and is not one.
*>
fn void append_stats(DString* out, SceneStats stats, FrameTiming timing)
{
	out.appendf(
		`{"drawCalls":%d,"uniqueMeshes":%d,"instances":%d,"nodes":%d,"assets":%d,"triangles":%d,"vertices":%d,"textures":%d,"textureBytes":%d,"geometryBytes":%d,"targetBytes":%d,"postBytes":%d,"shadowBytes":%d,"culledLastFrame":%d,"shadowCulled":%d,"gpuMs":%f,"prepareMs":%f,"shadowMs":%f,"sceneMs":%f,"postMs":%f,"presentMs":%f}`,
		stats.draw_calls,
		stats.unique_meshes,
		stats.instances,
		stats.nodes,
		stats.assets,
		stats.triangles,
		stats.vertices,
		stats.textures,
		stats.texture_bytes,
		stats.geometry_bytes,
		stats.target_bytes,
		stats.post_bytes,
		stats.shadow_bytes,
		stats.culled_last_frame,
		stats.shadow_culled_last_frame,
		timing.total,
		timing.prepare,
		timing.shadow,
		timing.scene,
		timing.post,
		timing.present
	)!!;
}