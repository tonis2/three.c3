<*
 Three tools and no more: `run_script`, `screenshot`, `get_api_docs`.

 `run_script` *is* the API surface. Every scene verb an agent could want is
 already a JavaScript call, so a `create_mesh` tool beside it would be a second,
 worse spelling of something the script can already do — and one that has to be
 kept in step with the first. The other two exist because they are the things a
 script cannot answer for itself: what the frame looks like, and what the API is.

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

import std::io;
import std::io::file;
import std::encoding::json;
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
	if (host != null && host.runtime != null) host.runtime.script_budget_ns = JS_MCP_BUDGET_MS * 1_000_000;

	// And the advice stops going to the terminal, for the same reason and in the
	// same place. `run_script` answers with a `warnings` array, so under a server
	// the terminal is a second copy of it — printed at a person who is watching an
	// agent work and reading advice about a script they did not write.
	// `advise_quiet` has the rest.
	advise_quiet(true);

	server.add_tool({
		.name = "run_script",
		.description =
			"Run a JavaScript scene script and get back everything it logged, everything it "
			"wrote with three.debug.write, the scene's stats, and a PNG of the frame. The API "
			"is Three.js-shaped: "
			"three.load, three.Scene, three.Mesh, three.Group, position/rotation/scale, add/remove. "
			"Call get_api_docs first if you have not seen it. Use three.debug.write(x) to send a "
			"value back — from anywhere in the script, including from inside a system or an "
			"animation callback.",
		.input_schema =
			`{"type":"object","properties":{"source":{"type":"string","description":"The script. Runs as an async function body, so top-level await works. three.debug.write(x) is how it answers with a value; what it writes arrives in the debug field."}},"required":["source"]}`,
		.handler = &tool_run_script,
		.user_data = host,
		.raw_content = true,
	});

	server.add_tool({
		.name = "screenshot",
		.description =
			"Render the current scene and return the frame as a PNG. Optionally also write it "
			"to a file. Takes no view arguments — move three.camera from a script.",
		.input_schema =
			`{"type":"object","properties":{"path":{"type":"string","description":"Where to also write the PNG. Omit to only receive the image."}}}`,
		.handler = &tool_screenshot,
		.user_data = host,
		.raw_content = true,
	});

	server.add_tool({
		.name = "get_api_docs",
		.description =
			"The three.c3 scripting API as JSON. With no arguments: the INDEX — the summary, "
			"every place it deliberately differs from Three.js, the stats block and the examples "
			"in full, and the names of the classes and functions. `search` is the grep over the "
			"whole surface: every entry whose name or prose mentions a word, with its text. "
			"`section` opens one of those names. `path` also writes the whole thing to a Markdown "
			"file, which is how you grep it with your own tools instead of asking again. Read the "
			"index before writing a script — the differences are short and each one is a script "
			"that would otherwise fail.",
		.input_schema =
			`{"type":"object","properties":{"search":{"type":"string","description":"A word or phrase. Answers with every entry whose name or text contains it, keyed by the path 'section' takes. This is the grep."},"section":{"type":"string","description":"One entry or one whole section: 'differences', 'classes.ShaderMaterial', 'functions.three.load(path)'. A bare name like 'ShaderMaterial' is found too."},"path":{"type":"string","description":"Where to also write the whole surface as Markdown, one heading per entry. Answers with the path and its size rather than the docs, since the point of a file is not having to read it here."},"all":{"type":"boolean","description":"Everything at once, about 113 KB of JSON. The index and a search cover nearly every reason to want it."}}}`,
		.handler = &tool_get_api_docs,
		.user_data = host,
	});

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
		detail.append_string("run_script needs a `source` string: the JavaScript to run");
		return TOOL_NEEDS_SOURCE~;
	}

	String? source = args.get_string("source");
	if (catch err = source)
	{
		// Naming the argument and its type is the difference between a retry that
		// works and one that guesses again, and it applies most to the one tool an
		// agent calls on every turn.
		detail.append_string("run_script needs a `source` string: the JavaScript to run");
		return TOOL_NEEDS_SOURCE~;
	}

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

	report.append_char('}');

	return content_with_frame(host, report.str_view());
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

	report.append_char('}');
	return content_with_frame(host, report.str_view());
}

// ============================================================================
// get_api_docs
// ============================================================================

<*
 The docs, narrowly.

 The whole object is about 113 KB of JSON — thirty thousand tokens paid before a
 line is written — and from outside this repository there is nothing to grep: the
 strings are embedded in the binary, so an agent that wanted one fact had to take
 all of them or none. So the arguments are the narrowing, and a bare call answers
 with the index rather than the dump.

 The narrowing is `docs.js`'s, not this file's. Every argument here is forwarded
 into `three.getApiDocs`, so the walk over the docs lives beside the strings it
 walks and a script asking from `run_script` and an agent asking over JSON-RPC
 get the same answer by the same code.
*>
fn String? tool_get_api_docs(Object* args, void* user_data, DString* detail)
{
	ToolHost* host = (ToolHost*)user_data;
	if (host == null || host.runtime == null)
	{
		detail.append_string("there is no script runtime in this process");
		return TOOL_NO_RUNTIME~;
	}

	String search = "";
	String section = "";
	String path = "";
	bool all = false;
	if (args != null)
	{
		if (try given = args.get_string("search")) search = given;
		if (try given = args.get_string("section")) section = given;
		if (try given = args.get_string("path")) path = given;
		if (try given = args.get_bool("all")) all = given;
	}

	if (path.len > 0) return write_api_docs(host, path, detail);

	// A JS object literal built by hand because JSON *is* one, and the escaping
	// that makes an argument safe to splice into source is the escaping the answer
	// already uses. An empty `search` or `section` is not a search for nothing:
	// `docsQuery` reads both as unasked.
	DString source;
	source.init(mem, 256);
	defer source.free();

	source.append_string(`return three.getApiDocs({"all":`);
	source.append_string(all ? "true" : "false");
	source.append_string(`,"search":`);
	append_json_string(&source, search);
	source.append_string(`,"section":`);
	append_json_string(&source, section);
	source.append_string(`});`);

	return ask_the_runtime(host, source.str_view(), detail);
}

<*
 Writes the whole surface to a file, and answers with the path rather than the
 docs.

 The `path` argument `screenshot` already has, with one difference: a screenshot
 writes *and* returns the image, because a file is not something the agent can
 look at, while these docs are something it can grep — and returning 113 KB
 beside "I wrote it to a file you can grep" would undo the reason for the file.

 Markdown rather than JSON because the tools that would read it are line-based:
 one heading per entry means a grep hit is a paragraph and the heading above it
 is the `section` to ask for next.
*>
fn String? write_api_docs(ToolHost* host, String path, DString* detail)
{
	String? docs = ask_the_runtime(host, `return three.getApiDocs({"markdown":true});`, detail);
	if (catch err = docs) return err~;
	defer docs.free(mem);

	// The runtime answers in JSON, so a string comes back quoted and escaped.
	// Parsed rather than unquoted by hand: this prose is full of quotes, newlines
	// and em dashes, and every one of them is an escape here.
	Object*? parsed = json::parse(mem, docs);
	if (catch err = parsed)
	{
		detail.appendf("the docs came back as something other than JSON: %s", err)!!;
		return TOOL_NO_RUNTIME~;
	}
	defer parsed.free();

	if (!parsed.is_string())
	{
		detail.append_string("the docs came back as something other than a string");
		return TOOL_NO_RUNTIME~;
	}
	String markdown = parsed.s;

	if (catch err = file::save(path, (char[])markdown))
	{
		detail.appendf("could not write %s: %s", path, err)!!;
		return TOOL_WRITE_FAILED~;
	}

	DString report;
	report.init(mem, 256);
	defer report.free();

	report.append_string(`{"path":`);
	append_json_string(&report, path);
	report.append_string(`,"bytes":`);
	report.appendf("%d", markdown.len)!!;
	report.append_string(`,"note":`);
	append_json_string(&report,
		"The whole API surface, one heading per entry, and every heading is a path this tool's "
		"`section` argument accepts. Grep it rather than asking again.");
	report.append_char('}');
	return report.copy_str(mem);
}

<*
 Runs one of this tool's own snippets and hands back what it returned.

 `drain_frame: false` — the run is the server's own rather than the agent's, and
 consuming what the animation loop logged would lose it: nothing here reads
 anything but `value`.
*>
fn String? ask_the_runtime(ToolHost* host, String source, DString* detail)
{
	RunResult result = host.runtime.run(source, "<get_api_docs>", drain_frame: false);
	defer result.free();

	if (!result.ok)
	{
		detail.appendf("the runtime could not produce its docs: %s", result.error)!!;
		return TOOL_NO_RUNTIME~;
	}
	return result.value.copy(mem);
}

// ============================================================================
// Building the answer
// ============================================================================

<*
 A content array: the report as text, and the frame as a PNG when there is a
 device to render one with.

 A run with no device is not an error — the scene-math half of the API works
 without one — so the image block is left out rather than the call failing.

 @param report : `The JSON the text block carries. Escaped into it here.`
 @return `The content array, allocated from mem, for a raw_content tool.`
*>
fn String? content_with_frame(ToolHost* host, String report)
{
	DString out;
	out.init(mem, 4096);
	defer out.free();

	out.append_string(`[{"type":"text","text":`);
	append_json_string(&out, report);
	out.append_char('}');

	if (host.renderer != null)
	{
		@pool()
		{
			image::Image? frame = host.renderer.capture(tmem);
			if (try shot = frame)
			{
				char[]? encoded = png::save_bytes(&shot, tmem);
				if (try bytes = encoded)
				{
					out.append_string(`,{"type":"image","mimeType":"image/png","data":"`);
					out.append_string(base64::tencode(bytes));
					out.append_string(`"}`);
				}
			}
		};
	}

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
	usz from = 0;
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
