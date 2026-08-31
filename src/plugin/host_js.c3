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
 One buffer a plugin published zero-copy, and the address it published it over.

 Kept because a detach needs the `ArrayBuffer` value and the plugin can never
 hold one — it cannot name `qjs::Value` at all. The base address is what the
 plugin *can* name, so that is the key `js_drop_buffer` looks up.

 A list rather than a map: a plugin shares a handful of arrays, not thousands,
 and one address may back several views — a document that publishes positions
 and normals out of one allocation is the ordinary case, not a strange one.
*>
struct SharedBuffer @local
{
	char* base;
	qjs::Value buffer;
}

List{SharedBuffer} plugin_buffers @local;

<*
 Hands a plugin the runtime and lets it install.

 Called for every runtime, including the ones a reload makes. Null plugin, no
 plugin, or a plugin with no `install_js` all cost one branch.
*>
fn void plugin_js_ready(PluginHost* plugin, JsRuntime* runtime)
{
	drop_plugin_verbs();
	plugin_runtime = runtime;
	if (plugin == null || !plugin.active()) return;

	// Before `install_js`, so a plugin whose prelude wants to `import` one of its
	// own modules on the first line can.
	if (plugin.scripts.len > 0) runtime.set_plugin_scripts(plugin.scripts);

	if (plugin.desc.install_js != null) plugin.desc.install_js(plugin.desc.ctx);
	plugin_js_entry(plugin, runtime);
}

<*
 Runs the plugin's entry module, once its verbs are in.

 Here rather than in `main.c3` for the reason the whole file exists: `reload`
 calls `plugin_js_ready` too, so a panel edited on disk comes back with shift+R
 and nothing above has to know that.

 A module and not a script — `import` is the point of having a directory. A
 failure is printed and carried on with, exactly as `--assets` handles a game
 that will not boot: the moment a panel is broken is the moment somebody wants
 the application still standing to read the error in.
*>
fn void plugin_js_entry(PluginHost* plugin, JsRuntime* runtime) @local
{
	if (plugin.scripts.len == 0 || plugin.desc.entry == null) return;
	String named = plugin.desc.entry.str_view();
	if (named.len == 0) return;

	@pool()
	{
		String specifier = string::tformat("%s%s", PLUGIN_SCHEME, named);
		RunResult ran = runtime.run_module(specifier);
		defer ran.free();

		if (ran.log.len > 0) io::printn(ran.log);
		if (!ran.ok)
		{
			io::eprintfn("[%s] %s did not run: %s", plugin_label().str_view(), specifier, ran.error);
		}
	};
}

<*
 Gives back the references a plugin's shared buffers hold, before the context
 they live in goes.

 Called from `JsRuntime.close` and belonging to the same list as the six
 `clear_*` calls beside it: a reference into an engine that is about to close
 has to be released while there is still an engine to release it into. QuickJS
 asserts on a non-empty object list at `JS_FreeRuntime`, so a reference left
 standing here is a crash on the next reload rather than a slow leak.

 Not a detach. Detaching protects a script from memory that went away
 underneath it, and nothing survives this to be protected — the views die with
 the context. What is left to do is arithmetic on a refcount.

 Guarded on identity because a process may hold more than one runtime, and only
 one of them is the one a plugin's verbs were installed into.
*>
fn void JsRuntime.release_plugin_buffers(&self)
{
	if (plugin_runtime != self) return;
	foreach (record : plugin_buffers) self.js.release(record.buffer);
	plugin_buffers.clear();
}

<*
 Everything a runtime's verbs owned. The QuickJS functions themselves go with
 the context; these are the records they pointed at.

 The shared buffers are given back here only if nobody has yet: on the reload
 path the runtime this is called for was closed several lines ago, and touching
 quickjs from there would be a read of a freed engine. `ready` is the question
 "is there still a context", and it is false from the moment `close` finishes.
*>
fn void drop_plugin_verbs() @local
{
	foreach (verb : plugin_verbs) mem::free(verb);
	plugin_verbs.clear();

	// Usually already empty: `release_plugin_buffers` runs from
	// `JsRuntime.close`, which comes first on every path that has both. What is
	// left for this line is the path that does not — a plugin closing while its
	// runtime is still open — and the `ready` check is what tells the two apart
	// without either caller having to know which order it is in.
	if (plugin_runtime != null && plugin_runtime.ready) plugin_runtime.release_plugin_buffers();
	plugin_buffers.clear();
	plugin_runtime = null;
}

// Called from `PluginHost.close`, so a run that ends without a reload still
// gives the records back.
fn void plugin_js_closed()
{
	drop_plugin_verbs();
	if (plugin_verbs.allocator != null) plugin_verbs.free();
	if (plugin_buffers.allocator != null) plugin_buffers.free();
}

<*
 The eleven `HostApi` entries this file owns.

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
	api.js_arg_buffer    = &host_js_arg_buffer;
	api.js_return_buffer = &host_js_return_buffer;
	api.js_drop_buffer   = &host_js_drop_buffer;
}

<*
 The ABI's element kinds to QuickJS's, in the one place the two meet.

 A switch rather than equal constants: `three_abi::BUFFER_*` is a contract two
 separately compiled images share, and `qjs::ARRAY_*` is a third library's enum
 that neither of them links. Making them the same numbers would work until
 quickjs renumbered, and then it would keep working — wrongly.
*>
fn int array_kind(int kind) @local
{
	switch (kind)
	{
		case three_abi::BUFFER_U8:  return qjs::ARRAY_UINT8;
		case three_abi::BUFFER_I32: return qjs::ARRAY_INT32;
		case three_abi::BUFFER_U32: return qjs::ARRAY_UINT32;
		case three_abi::BUFFER_F64: return qjs::ARRAY_FLOAT64;
		// Float32 is both the default and the fallback: it is what a plugin
		// packing geometry means, and answering *something* typed beats
		// answering undefined for a kind that was mistyped.
		default: return qjs::ARRAY_FLOAT32;
	}
}

// Bytes per element for the kinds above, so a byte length becomes an element
// count without the plugin having to send both and the two having to agree.
fn usz kind_stride(int kind) @local
{
	switch (kind)
	{
		case three_abi::BUFFER_U8: return 1;
		case three_abi::BUFFER_F64: return 8;
		default: return 4;
	}
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

<*
 An argument's bytes, borrowed for the verb's duration.

 Any typed array or `ArrayBuffer` answers, and a view's own byte offset is
 honoured, so `positions.subarray(3)` reads where the script meant. Everything
 else — a plain `Array`, a number, a detached view — answers zero with a null
 pointer rather than an exception: this is `js_arg_number` returning 0 and
 `js_arg_text` returning an empty string, and a verb that wants to complain has
 `js_throw` for it.

 Nothing is copied. §6 says no ownership crosses, and the borrow is the whole
 point: the plugin reads a document JavaScript owns without either side
 allocating.
*>
fn usz host_js_arg_buffer(three_abi::JsCall call, int at, char** bytes) @local
{
	if (bytes != null) *bytes = null;
	PluginCall* frame = (PluginCall*)call;
	if (frame == null || at < 0 || at >= frame.argc) return 0;

	qjs::Context js = { .ctx = frame.ctx };
	char[] view = js.bytes(frame.args[at]);
	if (view.len == 0) return 0;

	if (bytes != null) *bytes = view.ptr;
	return view.len;
}

<*
 A typed array as the call's answer, copied or shared.

 The copy is the default a caller should reach for: it is one `memcpy` and it
 ends the conversation. Sharing is for what is large and read every frame, and
 it costs the plugin a promise — `js_drop_buffer` before the memory moves.

 A shared buffer is frozen, so a script can read the plugin's arrays and cannot
 write them behind whatever bookkeeping the plugin keeps about them. The copy is
 deliberately *not* frozen: it is the script's own array, and the plugin has no
 stake in what happens to it.
*>
fn void host_js_return_buffer(
	three_abi::JsCall call,
	char* bytes,
	usz len,
	int kind,
	bool shared
) @local
{
	PluginCall* frame = (PluginCall*)call;
	if (frame == null || bytes == null || len == 0) return;

	qjs::Context js = { .ctx = frame.ctx };
	usz count = len / kind_stride(kind);
	if (count == 0) return;

	qjs::Value buffer = shared ? js.buffer(bytes, len) : js.buffer_copy(bytes, len);
	if (shared) js.freeze(buffer);

	qjs::Value view = js.typed_array(array_kind(kind), buffer, 0, count);

	if (shared)
	{
		// Held, not released: the detach later needs this value, and the view
		// keeps its own reference so the buffer is alive either way.
		if (plugin_buffers.allocator == null) plugin_buffers.init(mem, 4);
		plugin_buffers.push({ .base = bytes, .buffer = buffer });
	}
	else
	{
		// The view owns the copy now, and this was the last other reference.
		js.release(buffer);
	}

	answer(frame, view);
}

<*
 Detach every shared view over `bytes`, before the memory goes away.

 Null means all of them, which is what a plugin rebuilding a whole document
 does. Idempotent, and silent for an address that was never shared — a plugin
 that drops defensively should not have to remember whether it shared.

 Backwards over the list because entries are removed while walking it, and one
 address may back several views.
*>
fn void host_js_drop_buffer(char* bytes) @local
{
	if (plugin_runtime == null || plugin_buffers.len() == 0) return;
	qjs::Context* js = &plugin_runtime.js;

	sz i = plugin_buffers.len();
	while (i > 0)
	{
		i--;
		SharedBuffer record = plugin_buffers[(usz)i];
		if (bytes != null && record.base != bytes) continue;
		js.detach(record.buffer);
		js.release(record.buffer);
		plugin_buffers.remove_at((usz)i);
	}
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
