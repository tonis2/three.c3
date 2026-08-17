<*
 Three tools and no more: `run_script`, `screenshot`, `get_api_docs`.

 ## Why three

 `run_script` *is* the API surface. Every scene verb an agent could want is
 already a JavaScript call, so a `create_mesh` tool beside it would be a second,
 worse spelling of something the script can already do — and one that has to be
 kept in step with the first. The other two exist because they are the things a
 script cannot answer for itself: what the frame looks like, and what the API is.

 That is also why there is no milestone between the bindings and this. `plan.md`
 §5: `run_script` is the JS binding surface, so there is no useful MCP layer
 before the bindings exist.

 ## The answer shape

 `run_script` returns a content array rather than text, because one of the four
 things it always answers with is a PNG and an image block is the only way to
 carry one. The first block is the report — log, value, error, stats, as JSON —
 and the second is the frame. **Both, whether or not the script succeeded**
 (`plan.md` §4): a failed run that returns only an error makes the agent guess
 how far it got, and the picture of a half-built scene is often the thing that
 says.

 ## Threading

 `Listener` moves bytes on its own thread and `Listener.pump` runs the handlers
 on the caller's, which is what makes this safe: the scene, the JS context and
 the Vulkan device are all single-threaded, and a handler only ever runs from the
 same loop that renders.
*>
module three;

import std::io;
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
 Build the server. The tools are registered here and nowhere else.
*>
fn mcp::Server new_mcp_server(ToolHost* host)
{
	mcp::Server server = mcp::new_server({ .name = "three.c3", .version = VERSION });

	server.add_tool({
		.name = "run_script",
		.description =
			"Run a JavaScript scene script and get back everything it logged, the value it "
			"returned, the scene's stats, and a PNG of the frame. The API is Three.js-shaped: "
			"three.load, three.Scene, three.Mesh, three.Group, position/rotation/scale, add/remove. "
			"Call get_api_docs first if you have not seen it. Use `return` to send a value back.",
		.input_schema =
			`{"type":"object","properties":{"source":{"type":"string","description":"The script. Runs as an async function body, so top-level await and return both work."}},"required":["source"]}`,
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
			"The whole three.c3 scripting API as JSON: classes, methods, the stats block, "
			"and every place it deliberately differs from Three.js. Read this before writing "
			"a script — the differences are short and each one is a script that would "
			"otherwise fail.",
		.input_schema = `{"type":"object","properties":{}}`,
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
		// works and one that guesses again — mcp.c3l's own note, and it applies
		// most to the one tool an agent calls on every turn.
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

	// Spliced rather than escaped: it is already JSON, and quoting it would hand
	// the agent the characters of its own result instead of the result.
	report.append_string(`,"value":`);
	report.append_string(result.value.len > 0 ? result.value : "null");

	if (!result.ok)
	{
		report.append_string(`,"error":`);
		append_json_string(&report, result.error);
	}

	report.append_string(`,"stats":`);
	append_stats(&report, result.stats);
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

fn String? tool_get_api_docs(Object* args, void* user_data, DString* detail)
{
	ToolHost* host = (ToolHost*)user_data;
	if (host == null || host.runtime == null)
	{
		detail.append_string("there is no script runtime in this process");
		return TOOL_NO_RUNTIME~;
	}

	// Asked of the runtime rather than kept here, so the docs and the API they
	// describe are one file — `prelude.js` — and cannot drift apart.
	RunResult result = host.runtime.run("return three.getApiDocs();", "<get_api_docs>");
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
 The stats block, camelCase, matching what `three.stats()` hands a script.

 The same names on both sides on purpose: an agent that reads `drawCalls` off a
 tool result and then asserts on `scene.stats().drawCalls` in its next script
 should not have to notice that they were spelled differently.
*>
fn void append_stats(DString* out, SceneStats stats)
{
	out.appendf(
		`{"drawCalls":%d,"uniqueMeshes":%d,"instances":%d,"nodes":%d,"triangles":%d,"vertices":%d,"textures":%d,"textureBytes":%d,"culledLastFrame":%d}`,
		stats.draw_calls,
		stats.unique_meshes,
		stats.instances,
		stats.nodes,
		stats.triangles,
		stats.vertices,
		stats.textures,
		stats.texture_bytes,
		stats.culled_last_frame
	)!!;
}
