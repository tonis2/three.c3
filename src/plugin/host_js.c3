<*
 The plugin's JavaScript, and three's namespace not growing.

 `plugin_abi.md` §8. A plugin gets `globalThis.crig` and three keeps
 `globalThis.three`; they are two objects on one context, so a verb a plugin
 registers cannot enlarge three's API and `get_api_docs` answers in two sections
 rather than one wall.

 ## Why nothing here is `qjs::` on the plugin's side

 §8 first wrote these verbs in terms of `qjs::Value`, which would have made a
 plugin link quickjs. It cannot: quickjs is a static archive, so a second image
 naming its types gets a second copy of the C engine's statics under one shared
 `JSContext*`. cui survives being compiled into both images because its whole
 state lives in the `Ui` the host allocated; quickjs would not.

 So the frame is opaque and the arguments are read back through `HostApi`. What
 the plugin writes is a flat verb — numbers and strings in, one value out — which
 is what `src/mcp/jsdata.c3` in crig is already made of.

 ## Once per runtime, not once per load

 `install_js` is called from `live` after `runtime.open`, and again after every
 reload, because the runtime on the far side of a reload is a different object.
 Everything registered here belongs to that runtime and dies with it, which is
 why the thunk records are dropped at the same moment.
*>
module three;

import std::collections::list;
import std::io;
import qjs;
import three_abi;

<*
 The runtime a plugin's verbs reach, or null between runtimes.

 The same single-engine assumption as `plugin_renderer`, and set from the same
 place: one process, one loop, one runtime at a time.
*>
JsRuntime* plugin_runtime @local = null;

<*
 One registered verb: what the plugin gave and what the thunk needs to find it.

 Heap, and addressed by pointer from a QuickJS function that outlives this call —
 the same rule `ToolHost` and `engine_api` carry. The list is what owns them, and
 it is emptied when the runtime it was filled for goes away.
*>
struct PluginVerb @local
{
	three_abi::JsVerbFn body;
	void* user;
}

List{PluginVerb*} plugin_verbs @local;

<*
 One call in flight. The plugin holds its address as an opaque `JsCall` for the
 duration of the callback and never afterwards.
*>
struct PluginCall @local
{
	qjs::ContextRef ctx;
	qjs::Value* args;
	int argc;
	qjs::Value out;
	bool answered;
}

<*
 Hands a plugin the runtime and lets it install.

 Called for every runtime, including the ones a reload makes. Null plugin, no
 plugin, or a plugin with no `install_js` all cost one branch.
*>
fn void plugin_js_ready(PluginHost* plugin, JsRuntime* runtime)
{
	drop_plugin_verbs();
	plugin_runtime = runtime;
	if (plugin == null || !plugin.active() || plugin.desc.install_js == null) return;
	plugin.desc.install_js(plugin.desc.ctx);
}

// Everything a runtime's verbs owned. The QuickJS functions themselves go with
// the context; these are the records they pointed at.
fn void drop_plugin_verbs() @local
{
	foreach (verb : plugin_verbs) mem::free(verb);
	plugin_verbs.clear();
	plugin_runtime = null;
}

// Called from `PluginHost.close`, so a run that ends without a reload still
// gives the records back.
fn void plugin_js_closed()
{
	drop_plugin_verbs();
	if (plugin_verbs.allocator != null) plugin_verbs.free();
}

<*
 The eight `HostApi` entries this file owns.

 Filled from here rather than named in `host.c3` because everything below is
 file-local: quickjs stays inside this one file exactly as cui stays inside
 `render/ui.c3`, and the vtable is assembled from both halves.
*>
fn void fill_js_api(three_abi::HostApi* api)
{
	api.js_define        = &host_js_define;
	api.js_arg_number    = &host_js_arg_number;
	api.js_arg_text      = &host_js_arg_text;
	api.js_return_number = &host_js_return_number;
	api.js_return_text   = &host_js_return_text;
	api.js_return_bool   = &host_js_return_bool;
	api.js_throw         = &host_js_throw;
	api.js_eval          = &host_js_eval;
}

// ---------------------------------------------------------------- the verbs

<*
 The one QuickJS function every plugin verb is behind.

 `opaque` is the `PluginVerb*` — per function, which is what makes one thunk
 enough for all of them. The frame is a local: the plugin holds its address only
 while `body` is on the stack, and §6's "no ownership crosses" is what makes that
 safe to say.
*>
fn void plugin_thunk(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	PluginVerb* verb = (PluginVerb*)opaque;
	PluginCall call = { .ctx = ctx, .args = args, .argc = argc, .out = qjs::undefined_value() };
	verb.body(verb.user, &call, argc);
	*out = call.out;
}

fn bool host_js_define(
	ZString namespace,
	ZString name,
	int arity,
	three_abi::JsVerbFn body,
	void* user
) @local
{
	if (plugin_runtime == null || body == null) return false;
	qjs::Context* js = &plugin_runtime.js;

	qjs::Value global = js.global();
	defer js.release(global);

	// Reused rather than replaced, so a plugin may install its verbs in several
	// calls — and so a second `js_define` does not orphan the first one's object
	// with the first one's verbs still on it.
	qjs::Value target = js.property(global, namespace);
	if (target.is_undefined() || target.is_null())
	{
		js.release(target);
		target = js.object();
		// `set_property` takes ownership, so the object is retained first: the
		// namespace has to survive being handed over and go on being written to.
		js.set_property(global, namespace, js.retain(target));
	}
	defer js.release(target);

	PluginVerb* verb = mem::new(PluginVerb);
	*verb = { .body = body, .user = user };
	if (plugin_verbs.allocator == null) plugin_verbs.init(mem, 8);
	plugin_verbs.push(verb);

	js.set_property(target, name, js.function(&plugin_thunk, name, arity, verb));
	return true;
}

fn double host_js_arg_number(three_abi::JsCall call, int at) @local
{
	PluginCall* frame = (PluginCall*)call;
	if (frame == null || at < 0 || at >= frame.argc) return 0;
	qjs::Context js = { .ctx = frame.ctx };
	return js.number(frame.args[at]);
}

<*
 An argument as text, into the plugin's buffer.

 The full length is the answer whether or not it fitted, so a truncation is
 visible rather than silent. Zero-terminated whenever there is room for the
 terminator, because the plugin reads it as a `ZString`.
*>
fn usz host_js_arg_text(three_abi::JsCall call, int at, char* buffer, usz cap) @local
{
	PluginCall* frame = (PluginCall*)call;
	if (frame == null || at < 0 || at >= frame.argc)
	{
		if (buffer != null && cap > 0) buffer[0] = 0;
		return 0;
	}
	qjs::Context js = { .ctx = frame.ctx };
	@pool()
	{
		String text = js.text(frame.args[at], tmem);
		if (buffer != null && cap > 0)
		{
			usz room = text.len < cap - 1 ? text.len : cap - 1;
			if (room > 0) buffer[:room] = text[:room];
			buffer[room] = 0;
		}
		return text.len;
	};
}

// Writing an answer twice is the second one winning: the first value is released
// rather than leaked, and `answered` is what tells them apart from the
// `undefined` a verb starts with.
fn void answer(PluginCall* frame, qjs::Value value) @local
{
	if (frame == null) return;
	if (frame.answered)
	{
		qjs::Context js = { .ctx = frame.ctx };
		js.release(frame.out);
	}
	frame.out = value;
	frame.answered = true;
}

fn void host_js_return_number(three_abi::JsCall call, double value) @local
{
	answer((PluginCall*)call, qjs::number_value(value));
}

fn void host_js_return_text(three_abi::JsCall call, ZString value) @local
{
	PluginCall* frame = (PluginCall*)call;
	if (frame == null) return;
	qjs::Context js = { .ctx = frame.ctx };
	answer(frame, js.string(value == null ? "" : value.str_view()));
}

fn void host_js_return_bool(three_abi::JsCall call, bool value) @local
{
	answer((PluginCall*)call, qjs::bool_value(value));
}

fn void host_js_throw(three_abi::JsCall call, ZString message) @local
{
	PluginCall* frame = (PluginCall*)call;
	if (frame == null) return;
	qjs::Context js = { .ctx = frame.ctx };
	answer(frame, js.raise(message == null ? "plugin error" : message.str_view()));
}

<*
 The plugin's prelude, which is the layer over its flat verbs.

 Evaluated as a global script rather than a module, matching three's own
 preludes: a module's bindings would not be reachable from `globalThis` and the
 whole point is a namespace an agent can call into.
*>
fn bool host_js_eval(ZString name, char* source, usz len) @local
{
	if (plugin_runtime == null || source == null) return false;
	qjs::Context* js = &plugin_runtime.js;
	qjs::Value? result = js.eval((String)source[:len], name == null ? "<plugin>" : name.str_view());
	if (catch result)
	{
		@pool()
		{
			io::eprintfn("[%s] %s", plugin_label().str_view(), js.exception(tmem));
		};
		return false;
	}
	js.release(result);
	return true;
}
