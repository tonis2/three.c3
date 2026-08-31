<*
 A plugin's MCP tools, registered into three's server.

 `plugin_abi.md` §9. The consequence is the largest single simplification in the
 design and it is not the renderer: **one `run_script` reaches both APIs.** A
 plugin's tools are dispatchable beside `screenshot`, and §8 already put its
 JavaScript namespace on the same context — so an agent scripting a rig is
 scripting the engine in the same breath, and the plugin's own server, transports
 and `run_script` stop existing.

 ## Two substitutions on `mcp::ToolDef`

 The record is already C-shaped, so almost nothing changes. What does:

 - `ToolHandlerFn` answers `String?`. A C3 fault union has a compiler-internal
   return ABI and no stated owner for the string, so across images it becomes a
   bool plus an appended reply.
 - The handler is given a parsed `json::Object*`. That would tie both images to
   one collection's layout for no gain — the plugin gets the JSON as text and
   parses it with whatever it likes.

 ## Once, not per runtime

 `install_tools` is called when the server is built, which is once per run and
 only under `--mcp`. `install_js` is the one that has to be called again after
 every reload; the server outlives every runtime the loop makes.
*>
module three;

import std::collections::list;
import std::collections::object;
import std::io;
import mcp;
import three_abi;

faultdef PLUGIN_TOOL_FAILED;

<*
 One registered tool: what the plugin gave, plus the strings the `ToolDef` holds
 views into.

 Heap and never moved — `mcp::Server` copies the `ToolDef` but not what its
 `String`s point at, so these have to outlive the server. The same rule
 `engine_api` states, one level down.
*>
struct PluginTool @local
{
	three_abi::McpToolFn body;
	void* user;
	String name;
	String description;
	String schema;
}

List{PluginTool*} plugin_tools @local;

// The server being filled, for the duration of `plugin_install_tools` only. A
// plugin that kept `mcp_add_tool` and called it later gets a false rather than a
// write into a server that is already answering requests on another thread.
mcp::Server* plugin_server @local = null;

<*
 One call in flight. The plugin holds its address as an opaque `McpCall` while
 its body is on the stack and never afterwards.
*>
struct PluginToolCall @local
{
	ZString args;
	DString reply;
}

<*
 Lets the plugin register, then closes the window.

 @param server : `Borrowed for this call. Must be the one the loop goes on to serve from.`
*>
fn void plugin_install_tools(PluginHost* plugin, mcp::Server* server)
{
	if (plugin == null || !plugin.active() || plugin.desc.install_tools == null) return;
	plugin_server = server;
	plugin.desc.install_tools(plugin.desc.ctx);
	plugin_server = null;

	// Named at startup because nothing else names them: `get_api_docs` answers a
	// plugin's section when asked for it by name, and its index is three's own,
	// built in JavaScript by `three.getApiDocs`.
	foreach (docs : plugin_docs)
	{
		io::printfn("three: plugin docs under get_api_docs section '%s'", docs.namespace);
	}
}

// Called from `PluginHost.close`. The `ToolDef`s go with the server; these are
// the strings they were pointing at.
fn void plugin_tools_closed()
{
	foreach (tool : plugin_tools)
	{
		tool.name.free(mem);
		tool.description.free(mem);
		tool.schema.free(mem);
		mem::free(tool);
	}
	plugin_tools.clear();
	if (plugin_tools.allocator != null) plugin_tools.free();
}

fn void fill_mcp_api(three_abi::HostApi* api)
{
	api.mcp_add_tool = &host_mcp_add_tool;
	api.mcp_args     = &host_mcp_args;
	api.mcp_reply    = &host_mcp_reply;
	api.mcp_docs     = &host_mcp_docs;
}

// ---------------------------------------------------------------- the verbs

fn bool host_mcp_add_tool(
	ZString name,
	ZString description,
	ZString schema,
	three_abi::McpToolFn body,
	void* user
) @local
{
	if (plugin_server == null || body == null || name == null) return false;

	// Refused rather than shadowed: a client that called `screenshot` and reached
	// something else has no way to find out that it did.
	String wanted = name.str_view();
	for (usz i = 0; i < plugin_server.tools_len; i++)
	{
		if (plugin_server.tools[i].name == wanted)
		{
			io::eprintfn("[%s] tool %s is already registered", plugin_label().str_view(), wanted);
			return false;
		}
	}

	PluginTool* tool = mem::new(PluginTool);
	*tool = {
		.body        = body,
		.user        = user,
		.name        = wanted.copy(mem),
		.description = description == null ? "".copy(mem) : description.str_view().copy(mem),
		.schema      = schema == null ? `{"type":"object"}`.copy(mem) : schema.str_view().copy(mem),
	};
	if (plugin_tools.allocator == null) plugin_tools.init(mem, 4);
	plugin_tools.push(tool);

	plugin_server.add_tool(
		{
			.name         = tool.name,
			.description  = tool.description,
			.input_schema = tool.schema,
			.handler      = &plugin_tool_thunk,
			.user_data    = tool,
		}
	);
	return true;
}

<*
 The one handler every plugin tool is behind.

 The reply is built on `mem` because that is what the protocol frees it with —
 `defer alloc::free(mem, payload)` on the far side of the return.
*>
fn String? plugin_tool_thunk(Object* args, void* user_data, DString* detail) @local
{
	PluginTool* tool = (PluginTool*)user_data;
	if (tool == null) return PLUGIN_TOOL_FAILED~;

	@pool()
	{
		// Re-serialised rather than handed over parsed: text is the one shape both
		// images agree on without sharing a collection type. `{}` for a call that
		// sent no arguments, so a plugin always has an object to parse.
		String text = args == null ? "{}" : string::tformat("%s", args);

		PluginToolCall call = { .args = text.zstr_tcopy() };
		call.reply.init(mem, 256);

		if (!tool.body(tool.user, &call))
		{
			detail.append_string(call.reply.str_view());
			call.reply.free();
			return PLUGIN_TOOL_FAILED~;
		}
		return call.reply.copy_str(mem);
	};
}

fn ZString host_mcp_args(three_abi::McpCall call) @local
{
	PluginToolCall* frame = (PluginToolCall*)call;
	return frame == null ? "{}" : frame.args;
}

fn void host_mcp_reply(three_abi::McpCall call, ZString text) @local
{
	PluginToolCall* frame = (PluginToolCall*)call;
	if (frame == null || text == null) return;
	frame.reply.append_string(text.str_view());
}

<*
 A plugin's documentation section.

 Kept beside three's rather than merged into it — see the ABI. The strings are
 copied because a plugin's `$embed`ed docs outlive the call anyway and a caller
 should not have to know which ones do.
*>
fn void host_mcp_docs(ZString namespace, char* markdown, usz len) @local
{
	if (namespace == null || markdown == null) return;
	if (plugin_docs.allocator == null) plugin_docs.init(mem, 2);
	plugin_docs.push({ namespace.str_view().copy(mem), ((String)markdown[:len]).copy(mem) });
}

struct PluginDocs
{
	String namespace;
	String markdown;
}

// Read by `get_api_docs`; see `mcp/server.c3`.
List{PluginDocs} plugin_docs;
