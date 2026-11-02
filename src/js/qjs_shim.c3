<*
 TEMPORARY: the old quickjs-shaped API over fastjs::js, so the bindings can move to typed
 functions one file at a time. Deleted when the last one has.

 **Ownership follows quickjs's rules**, because the host code was written against them. A `Value`
 handed to the host is owned by it and released with `Context.release`, once. Here that means
 something different underneath: there is no reference count, so an owned value is a GC root
 (an entry in `Vm.roots`) until it is released. Numbers, booleans, null and undefined are not
 on the heap and cost nothing either way.

 Functions that take ownership (`set_property`, `set_index`, `accessor`, a host function's
 `out`) drop the root the host held. Everything else borrows.
*>
module qjs;
import std::io, std::core::dstring, std::collections::list, fastjs::rt, fastjs::compile;
import fastjs::js @norecurse;

alias ModuleLoader = js::ModuleLoader;
alias EmbeddedModule = js::EmbeddedModule;
const usz MAX_MODULE_BYTES = js::MAX_MODULE_BYTES;
const fault MODULE_ESCAPES_ROOT = js::MODULE_ESCAPES_ROOT;
const fault MODULE_SPECIFIER_IS_EMPTY = js::MODULE_SPECIFIER_IS_EMPTY;
const fault MODULE_PATH_TOO_DEEP = js::MODULE_PATH_TOO_DEEP;
fn String? resolve_module(String base, String name, Allocator allocator) => js::resolve_module(base, name, allocator);

// The tags `Value.tag` answers with: quickjs's numbering, so host code comparing them still works.
const int TAG_BIG_INT = -9;
const int TAG_SYMBOL = -8;
const int TAG_STRING = -7;
const int TAG_OBJECT = -1;
const int TAG_INT = 0;
const int TAG_BOOL = 1;
const int TAG_NULL = 2;
const int TAG_UNDEFINED = 3;
const int TAG_UNINITIALIZED = 4;
const int TAG_EXCEPTION = 6;
const int TAG_FLOAT64 = 8;

const int EVAL_GLOBAL = 0;
const int EVAL_MODULE = 1;
// fastjs only: the source is the body of an async function, called at once. `await` and
// `return` work at top level and the value is the call's promise.
const int EVAL_ASYNC = 2;

// Element types for `Context.typed_array` and `View.kind`, in quickjs's numbering.
const int ARRAY_UINT8C = 0;
const int ARRAY_INT8 = 1;
const int ARRAY_UINT8 = 2;
const int ARRAY_INT16 = 3;
const int ARRAY_UINT16 = 4;
const int ARRAY_INT32 = 5;
const int ARRAY_UINT32 = 6;
const int ARRAY_FLOAT32 = 10;
const int ARRAY_FLOAT64 = 11;
// `View.kind` for the views that aren't typed arrays.
const int VIEW_BUFFER = -1;
const int VIEW_DATA = -2;

<*
 A JS value: the engine's own 8-byte NaN-boxed representation, as a type of its own so its
 methods answer in quickjs's terms.
*>
typedef Value = ulong;

// What a host function writes to `out` after `raise`: "an exception is pending".
const Value EXCEPTION = (Value)0xFFFA_0000_0000_00EE;

alias Runtime = void*;
alias ContextRef = void*;
alias InterruptFn = fn int(Runtime rt, void* opaque);
alias HostFn = fn void(ContextRef ctx, Value* this_val, int argc, Value* args, void* opaque, Value* out);
alias ModuleNormalizeFn = rt::ModuleNormalizeFn;
alias ModuleLoadFn = rt::ModuleLoadFn;
alias ModuleHooks = rt::ModuleHooks;

excuse NO_RUNTIME, THREW;

<*
 A handle on an engine. `runtime` and `ctx` both point at it; they are two fields only because
 quickjs's handle has two.
*>
struct Context
{
	Runtime runtime;
	ContextRef ctx;
}

macro rt::Vm* Context.vm(&self) => (rt::Vm*)self.ctx;
macro rt::Value raw(Value v) => (rt::Value)v;
macro Value wrapped(rt::Value v) => (Value)v;

<*
 Start an engine.

 @param memory_limit : "Bytes the heap may grow to, or 0 for no limit"
 @param stack_limit : "Accepted for compatibility; JS recursion has its own fixed limit here"
 @return? NO_RUNTIME
*>
fn Context? open(usz memory_limit = 0, usz stack_limit = 0)
{
	js::Engine*? e = js::open(memory_limit);
	if (catch e) return NO_RUNTIME~;
	return { .runtime = e, .ctx = e };
}

<*
 Shut the engine down. Safe on a zeroed Context and safe twice.
*>
fn void Context.close(&self)
{
	if (self.ctx)
	{
		((js::Engine*)self.ctx).close();
	}
	*self = {};
}

fn bool Context.open_now(&self) => self.ctx != null;

fn js::Engine* Context.engine(&self) => (js::Engine*)self.ctx;

<*
 The handle for the engine a host function was called from. Never close it.
*>
fn Context wrap(ContextRef ctx) => { .runtime = ctx, .ctx = ctx };

// ---- ownership ----

<*
 Hand v to the host: it stays alive until released.
*>
fn Value Context.own(&self, rt::Value v)
{
	if (v.is_heap()) self.vm().roots.push(v);
	return (Value)v;
}

<*
 Release a value. Exactly once, and not after `close`.
*>
fn void Context.release(&self, Value value)
{
	rt::Value v = raw(value);
	if (!v.is_heap() || !self.ctx) return;
	List {rt::Value}* roots = &self.vm().roots;
	// Owned values are usually released in the reverse order they were taken, so look from the end.
	for (sz i = roots.len() - 1; i >= 0; i--)
	{
		if ((*roots)[i] == v)
		{
			roots.remove_unordered_at(i);
			return;
		}
	}
}

<*
 Another owned reference to the same value, released separately.
*>
fn Value Context.retain(&self, Value value) => self.own(raw(value));

// ---- running code ----

<*
 Run source as a script (EVAL_GLOBAL) or as an ES module (EVAL_MODULE).

 @return "The script's value: its last expression statement's. A module gives a promise for its evaluation."
 @return? THREW : "It threw or would not compile; Context.exception says why"
*>
fn Value? Context.eval(&self, String source, String name = "<eval>", int type = EVAL_GLOBAL)
{
	rt::Vm* vm = self.vm();
	if (type == EVAL_MODULE)
	{
		rt::Value? promise = compile::eval_module(vm, source, name);
		if (catch promise) return THREW~;
		return self.own(promise);
	}
	CompileError err;
	Script*? script = compile::compile_script(vm, source, name, &err, type == EVAL_ASYNC);
	if (catch script)
	{
		(void)vm.throw_error(SYNTAX_ERROR, "%s\n    at %s:%d:%d", err.message, name, err.line, err.col);
		return THREW~;
	}
	rt::Value? result = vm.run_script(script);
	if (catch result) return THREW~;
	return self.own(result);
}

<*
 The pending exception as text, followed by its stack trace when it has one; empty when nothing
 is pending. Taking it clears it.
*>
fn String Context.exception(&self, Allocator allocator = mem)
{
	rt::Vm* vm = self.vm();
	rt::Value thrown = vm.exception;
	vm.exception = rt::EMPTY;
	vm.uncatchable = false;
	if (thrown == rt::EMPTY || thrown.is_nullish() || thrown == rt::UNINITIALIZED) return "".copy(allocator);
	vm.roots.push(thrown);
	defer (void)vm.roots.pop();
	String message = self.text(wrapped(thrown), allocator);
	if (!is_error(thrown)) return message;
	rt::Value stack = vm.get(thrown, vm.atoms.stack) ?? rt::UNDEFINED;
	vm.exception = rt::EMPTY;
	if (!stack.is_string()) return message;
	String trace = self.text(wrapped(stack), allocator);
	if (trace.len == 0)
	{
		alloc::free(allocator, trace.ptr);
		return message;
	}
	// This engine's stack already starts with "Name: message"; don't say it twice.
	if (trace.starts_with(message))
	{
		alloc::free(allocator, message.ptr);
		return trace;
	}
	String joined = string::format(allocator, "%s\n%s", message, trace);
	alloc::free(allocator, message.ptr);
	alloc::free(allocator, trace.ptr);
	return joined;
}

fn bool is_error(rt::Value v) => v.is_object() && v.as_object().kind == ERROR;

<*
 quickjs's own predicate, which hosts call directly.
*>
fn int qjs_is_error(ContextRef ctx, Value* v) => is_error(raw(*v)) ? 1 : 0;

// ---- reading values ----

<*
 v as text, as String(v) gives it; empty when it has none. Always allocated, so always freed.
*>
fn String Context.text(&self, Value value, Allocator allocator = mem)
{
	rt::Vm* vm = self.vm();
	rt::Value v = raw(value);
	if (v.is_symbol()) return "".copy(allocator);
	JsString*? s = vm.to_string(v);
	if (catch s)
	{
		vm.exception = rt::EMPTY;
		return "".copy(allocator);
	}
	@pool()
	{
		DString out;
		out.tinit((sz)s.len + 1);
		s.to_utf8(&out);
		return out.str_view().copy(allocator);
	};
}

<*
 v as a number; 0 when it has none.
*>
fn double Context.number(&self, Value value)
{
	rt::Value v = raw(value);
	if (v.is_number()) return v.as_number();
	double? d = self.vm().to_number(v);
	if (catch d)
	{
		self.vm().exception = rt::EMPTY;
		return 0;
	}
	return d;
}

fn bool Context.truth(&self, Value value) => rt::truthy(raw(value));

fn int Value.tag(self)
{
	rt::Value v = raw(self);
	switch
	{
		case self == EXCEPTION: return TAG_EXCEPTION;
		case v.is_int(): return TAG_INT;
		case v.is_double(): return TAG_FLOAT64;
		case v.is_bool(): return TAG_BOOL;
		case v.is_null(): return TAG_NULL;
		case v.is_undefined(): return TAG_UNDEFINED;
		case v.is_string(): return TAG_STRING;
		case v.is_symbol(): return TAG_SYMBOL;
		case v.is_object(): return TAG_OBJECT;
		default: return TAG_UNINITIALIZED;
	}
}

fn bool Value.is_undefined(self) => raw(self).is_undefined();
fn bool Value.is_null(self) => raw(self).is_null();

fn Value Context.global(&self) => self.own(rt::object_value(self.vm().global));

fn rt::Value? Context.key(&self, ZString name) => self.vm().atom_value(name.str_view());

<*
 obj[name], owned. EXCEPTION, with the exception pending, when reading it threw.
*>
fn Value Context.property(&self, Value object, ZString name)
{
	rt::Vm* vm = self.vm();
	rt::Value? v = vm.get(raw(object), self.key(name));
	if (catch v) return EXCEPTION;
	return self.own(v);
}

<*
 obj[name] = value. Takes ownership of value.

 @return "False when it threw"
*>
fn bool Context.set_property(&self, Value object, ZString name, Value value)
{
	defer self.release(value);
	rt::Vm* vm = self.vm();
	rt::Value obj = raw(object);
	if (!obj.is_object())
	{
		(void)vm.throw_error(TYPE_ERROR, "cannot set property '%s' of %s", name, vm.describe(obj));
		return false;
	}
	if (catch vm.set(obj, self.key(name), raw(value))) return false;
	return true;
}

<*
 value as JSON; empty when it has none (undefined, a function, a symbol) or stringifying threw.
*>
fn String Context.json(&self, Value value, Allocator allocator = mem)
{
	rt::Vm* vm = self.vm();
	rt::Value[1] args = { raw(value) };
	vm.native_depth++;
	rt::Value? text = rt::native_json_stringify(vm, rt::UNDEFINED, &args, null);
	vm.native_depth--;
	if (catch text) return "".copy(allocator);
	if (!text.is_string()) return "".copy(allocator);
	return self.text(wrapped(text), allocator);
}

<*
 text parsed as JSON, owned.

 @return? THREW
*>
fn Value? Context.from_json(&self, String text, String name = "<json>")
{
	rt::Vm* vm = self.vm();
	rt::Value s = vm.str_value(text) ?? rt::UNDEFINED;
	if (!s.is_string()) return THREW~;
	rt::Value[1] args = { s };
	vm.native_depth++;
	rt::Value? v = rt::native_json_parse(vm, rt::UNDEFINED, &args, null);
	vm.native_depth--;
	if (catch v) return THREW~;
	return self.own(v);
}

fn Value Context.string(&self, String text)
{
	rt::Value? s = self.vm().str_value(text);
	if (catch s) return EXCEPTION;
	return self.own(s);
}

fn Value Context.object(&self)
{
	rt::Vm* vm = self.vm();
	JsObject*? o = vm.heap.new_object(vm.object_proto);
	if (catch o) return EXCEPTION;
	return self.own(rt::object_value(o));
}

<*
 A new object with proto (borrowed) as its prototype, owned.
*>
fn Value Context.object_of(&self, Value proto)
{
	rt::Vm* vm = self.vm();
	rt::Value p = raw(proto);
	JsObject*? o = vm.heap.new_object(p.is_object() ? p.as_object() : null);
	if (catch o) return EXCEPTION;
	return self.own(rt::object_value(o));
}

<*
 Define name on object as an accessor, enumerable and configurable. Takes ownership of both.
*>
fn bool Context.accessor(&self, Value object, ZString name, Value getter, Value setter = undefined_value())
{
	defer
	{
		self.release(getter);
		self.release(setter);
	}
	rt::Vm* vm = self.vm();
	rt::Value obj = raw(object);
	if (!obj.is_object()) return false;
	if (catch vm.define_accessor(obj.as_object(), self.key(name), raw(getter), raw(setter), { .enumerable = true, .configurable = true })) return false;
	return true;
}

fn Value Context.array(&self)
{
	rt::Vm* vm = self.vm();
	JsArray*? a = vm.heap.new_array(vm.array_proto);
	if (catch a) return EXCEPTION;
	return self.own(rt::object_value(a));
}

<*
 array[index] = value. Takes ownership of value.
*>
fn bool Context.set_index(&self, Value array, uint index, Value value)
{
	defer self.release(value);
	rt::Vm* vm = self.vm();
	rt::Value a = raw(array);
	if (a.is_object() && a.as_object().kind == ARRAY && index <= (uint)int::max)
	{
		((JsArray*)a.as_object()).set(index, raw(value));
		vm.heap.touch(a.as_object());
		return true;
	}
	if (!a.is_object()) return false;
	rt::Value key = index <= (uint)int::max ? rt::integer((int)index) : vm.to_key(rt::double_value((double)index)) ?? rt::UNDEFINED;
	if (catch vm.set(a, key, raw(value))) return false;
	return true;
}

<*
 array[index], owned; undefined when there is none.
*>
fn Value Context.index(&self, Value array, uint index)
{
	rt::Vm* vm = self.vm();
	rt::Value a = raw(array);
	if (a.is_object() && a.as_object().kind == ARRAY)
	{
		rt::Value v = ((JsArray*)a.as_object()).get(index);
		return self.own(v == rt::EMPTY ? rt::UNDEFINED : v);
	}
	rt::Value? v = vm.index_get(a, index);
	if (catch v) return EXCEPTION;
	return self.own(v);
}

<*
 value.length as JS reads it; -1 when there is none or reading it threw.
*>
fn long Context.length(&self, Value value)
{
	rt::Vm* vm = self.vm();
	rt::Value v = raw(value);
	if (v.is_object())
	{
		JsObject* o = v.as_object();
		if (o.kind == ARRAY) return ((JsArray*)o).length;
		if (o.kind == TYPED_ARRAY) return ((JsTypedArray*)o).length;
	}
	if (v.is_string()) return v.as_string().len;
	if (!v.is_object()) return -1;
	rt::Value? len = vm.get(v, vm.atoms.length);
	if (catch len) return -1;
	double? d = vm.to_number(len);
	if (catch d) return -1;
	if (d != d || d < 0) return 0;
	if (d > 9007199254740991.0) return 9007199254740991;
	return (long)d;
}

// ---- binary data ----

<*
 An ArrayBuffer over memory the host owns. Nothing is copied; detach it before the memory goes.
*>
fn Value Context.buffer(&self, char* data, usz bytes)
{
	rt::Vm* vm = self.vm();
	JsArrayBuffer*? b = (JsArrayBuffer*)vm.heap.new_object(vm.array_buffer_proto, ARRAY_BUFFER, JsArrayBuffer::size);
	if (catch b) return EXCEPTION;
	b.data = data;
	b.byte_length = bytes;
	b.external = true;
	return self.own(rt::object_value(b));
}

<*
 An ArrayBuffer the engine owns, filled from data.
*>
fn Value Context.buffer_copy(&self, char* data, usz bytes)
{
	rt::Vm* vm = self.vm();
	JsArrayBuffer*? b = vm.new_buffer(bytes);
	if (catch b) return EXCEPTION;
	if (bytes) mem::copy(b.data, data, (sz)bytes);
	return self.own(rt::object_value(b));
}

<*
 Detach a buffer: it and every view of it become empty.
*>
fn void Context.detach(&self, Value buffer)
{
	rt::Value v = raw(buffer);
	if (!v.is_object() || v.as_object().kind != ARRAY_BUFFER) return;
	self.vm().detach_buffer((JsArrayBuffer*)v.as_object());
}

<*
 Make a buffer read-only for scripts.

 @return "False when the value is not an ArrayBuffer"
*>
fn bool Context.freeze(&self, Value buffer)
{
	rt::Value v = raw(buffer);
	if (!v.is_object() || v.as_object().kind != ARRAY_BUFFER) return false;
	((JsArrayBuffer*)v.as_object()).immutable = true;
	return true;
}

<*
 A typed array of `kind` (an ARRAY_* constant) over buffer (borrowed), owned.
*>
fn Value Context.typed_array(&self, int kind, Value buffer, usz offset, usz count)
{
	rt::Vm* vm = self.vm();
	rt::Value b = raw(buffer);
	rt::TypedKind tkind;
	switch (kind)
	{
		case 0: tkind = UINT8_CLAMPED;
		case 1: tkind = INT8;
		case 2: tkind = UINT8;
		case 3: tkind = INT16;
		case 4: tkind = UINT16;
		case 5: tkind = INT32;
		case 6: tkind = UINT32;
		case 10: tkind = FLOAT32;
		case 11: tkind = FLOAT64;
		default:
			(void)vm.throw_error(TYPE_ERROR, "unsupported typed array kind %d", kind);
			return EXCEPTION;
	}
	if (!b.is_object() || b.as_object().kind != ARRAY_BUFFER)
	{
		(void)vm.throw_error(TYPE_ERROR, "not an ArrayBuffer");
		return EXCEPTION;
	}
	JsArrayBuffer* ab = (JsArrayBuffer*)b.as_object();
	usz byte_offset = offset * tkind.size;
	if (byte_offset + count * tkind.size > ab.byte_length)
	{
		(void)vm.throw_error(RANGE_ERROR, "invalid typed array length");
		return EXCEPTION;
	}
	JsTypedArray*? t = vm.new_typed(tkind, ab, (uint)byte_offset, (uint)count);
	if (catch t) return EXCEPTION;
	return self.own(rt::object_value(t));
}

<*
 The bytes behind a typed array, DataView or ArrayBuffer. Borrowed: copy them before the next
 call into the engine.
*>
fn char[] Context.bytes(&self, Value value)
{
	rt::Value v = raw(value);
	if (!v.is_object()) return {};
	JsObject* o = v.as_object();
	switch (o.kind)
	{
		case ARRAY_BUFFER:
			JsArrayBuffer* b = (JsArrayBuffer*)o;
			return b.data ? b.data[:b.byte_length] : {};
		case TYPED_ARRAY:
			JsTypedArray* t = (JsTypedArray*)o;
			return t.data && t.length ? t.data[:(usz)t.length * t.tkind.size] : {};
		case DATA_VIEW:
			JsTypedArray* t = (JsTypedArray*)o;
			return t.data && t.length ? t.data[:t.length] : {};
		default:
			return {};
	}
}

fn Value number_value(double d) => (Value)rt::number(d);
fn Value int_value(int n) => (Value)rt::integer(n);
fn Value bool_value(bool b) => (Value)rt::boolean(b);
fn Value undefined_value() => (Value)rt::UNDEFINED;
fn Value null_value() => (Value)rt::NULL;

// ---- functions ----

<*
 A JS function that calls body, owned.

 @param name : "What the function calls itself in stack traces and String(fn)"
 @param arity : "What fn.length reports"
 @param opaque : "Handed back to body untouched"
*>
fn Value Context.function(&self, HostFn body, ZString name, int arity = 0, void* opaque = null)
{
	rt::Vm* vm = self.vm();
	String copied = name.str_view().copy(mem);
	vm.owned_names.push(copied);
	JsFunction*? f = vm.new_native(copied, &host_trampoline, arity < 0 ? 0 : (uint)arity);
	if (catch f) return EXCEPTION;
	f.host_fn = (void*)body;
	f.host_opaque = opaque;
	return self.own(rt::object_value(f));
}

<*
 How a host function is called: the arguments are borrowed straight off the VM stack, and what it
 writes to `out` becomes the engine's.
*>
fn rt::Value? host_trampoline(rt::Vm* vm, rt::Value this_value, rt::Value[] args, JsFunction* callee)
{
	HostFn body = (HostFn)callee.host_fn;
	Value self = this_value == rt::EMPTY ? undefined_value() : (Value)this_value;
	Value out = undefined_value();
	body((ContextRef)vm, &self, (int)args.len, (Value*)args.ptr, callee.host_opaque, &out);
	if (out == EXCEPTION) return rt::THROWN~;
	Context ctx = wrap(vm);
	rt::Value result = raw(out);
	// Keep it reachable until the interpreter stores it, then drop the host's ownership.
	ctx.release(out);
	return result;
}

fn bool Context.is_function(&self, Value value) => raw(value).is_function();

<*
 Call function with this_val and args, all borrowed. The result is owned.

 @return? THREW
*>
fn Value? Context.call(&self, Value function, Value this_val = undefined_value(), Value[] args = {})
{
	rt::Vm* vm = self.vm();
	rt::Value? r = vm.call(raw(function), raw(this_val), (rt::Value[])args);
	if (catch r) return THREW~;
	return self.own(r);
}

<*
 A new Error with message, owned.
*>
fn Value Context.error(&self, String message)
{
	JsObject*? err = self.vm().make_error(ERROR, message);
	if (catch err) return EXCEPTION;
	return self.own(rt::object_value(err));
}

<*
 Throw an Error with message; returns what a host function then writes to `out`.
*>
fn Value Context.raise(&self, String message)
{
	rt::Vm* vm = self.vm();
	(void)vm.throw_error(ERROR, "%s", message);
	return EXCEPTION;
}

// ---- jobs, interrupts, modules ----

<*
 Ask handler, now and then while a script runs, whether to stop it. Null clears it.
*>
fn void Context.on_interrupt(&self, InterruptFn handler, void* opaque = null)
{
	rt::Vm* vm = self.vm();
	vm.interrupt = (InterruptHandler)handler;
	vm.interrupt_runtime = self.runtime;
	vm.interrupt_opaque = opaque;
	vm.interrupt_countdown = rt::INTERRUPT_INTERVAL;
}

<*
 Run one queued promise job.

 @return "False when the queue was empty or the job threw"
*>
fn bool Context.step_job(&self)
{
	bool? ran = self.vm().run_job();
	if (catch ran) return false;
	return ran;
}

fn bool Context.jobs_waiting(&self) => self.vm().jobs_waiting();

<*
 Collect garbage now. Does nothing when called from inside a host function.
*>
fn void Context.collect(&self)
{
	rt::Vm* vm = self.vm();
	if (vm.native_depth == 0) vm.collect();
}

<*
 fastjs only: do up to budget_us microseconds of garbage-collection work now, in time the host
 has to spare (the idle end of a frame), so less of it lands inside scripts. Does nothing when
 called from inside a host function.
*>
fn void Context.gc_step(&self, long budget_us) => self.vm().gc_step(budget_us * 1000);

<*
 Install the module hooks, or clear them with null. They must outlive the engine.
*>
fn void Context.on_modules(&self, ModuleHooks* hooks) => self.vm().module_hooks = hooks;

// ---- fastjs additions: fast host calls, host objects, atoms, views, promise state ----

alias Finalizer = rt::NativeFinalizer;

<*
 A kind of host object (see native_class).
*>
typedef ClassId = uint;

<*
 A property name looked up once, so reading or writing it costs no string work.
*>
typedef Atom = ulong;

excuse NOT_A_VIEW;

struct View
{
	int kind;
	char* ptr;
	usz len;
	usz byte_len;
}

enum PromiseState
{
	NOT_A_PROMISE,
	PENDING,
	FULFILLED,
	REJECTED,
}

<*
 A new kind of host object. finalizer, when given, runs with an instance's data when the
 instance is collected or the engine closes; it must not call into the engine.
*>
fn ClassId Context.native_class(&self, ZString name, Finalizer finalizer = null, void* opaque = null)
{
	rt::NativeClass*? c = self.vm().new_native_class(name.str_view(), finalizer, opaque);
	if (catch c) return (ClassId)uint::max;
	return (ClassId)c.id;
}

<*
 The prototype every instance of cls has, owned: where methods for it go.
*>
fn Value Context.class_prototype(&self, ClassId cls) => self.own(rt::object_value(self.vm().native_classes[(uint)cls].proto));

<*
 A new instance of cls carrying data, owned.
*>
fn Value Context.native_object(&self, ClassId cls, void* data)
{
	rt::Vm* vm = self.vm();
	JsNative*? n = vm.new_native_object(vm.native_classes[(uint)cls], data);
	if (catch n) return EXCEPTION;
	return self.own(rt::object_value(n));
}

<*
 value's host data when it is an instance of cls, else null.
*>
fn void* Context.opaque(&self, Value value, ClassId cls) => rt::native_data_of(raw(value), self.vm().native_classes[(uint)cls]);

<*
 Replace an instance's host data; null makes its methods throw from then on, and skips the
 finalizer.

 @return "False when value is not an instance of cls"
*>
fn bool Context.set_opaque(&self, Value value, ClassId cls, void* data)
{
	rt::Value v = raw(value);
	if (!v.is_object() || v.as_object().kind != NATIVE) return false;
	JsNative* n = (JsNative*)v.as_object();
	if (n.cls.id != (uint)cls) return false;
	n.data = data;
	return true;
}

<*
 The atom for name. Atoms live as long as the engine.
*>
fn Atom Context.atom(&self, String name)
{
	rt::Vm* vm = self.vm();
	rt::Value? s = vm.atom_value(name);
	if (catch s) return (Atom)rt::UNDEFINED;
	rt::Value? key = vm.to_key(s);
	if (catch key) return (Atom)rt::UNDEFINED;
	return (Atom)key;
}

<*
 obj[key], owned. EXCEPTION, with the exception pending, when reading it threw.
*>
fn Value Context.get(&self, Value object, Atom key)
{
	rt::Value? v = self.vm().get(raw(object), (rt::Value)key);
	if (catch v) return EXCEPTION;
	return self.own(v);
}

<*
 obj[key] as a number; fallback when it is missing, not a number, or reading it threw.
*>
fn double Context.get_number(&self, Value object, Atom key, double fallback = 0)
{
	rt::Vm* vm = self.vm();
	rt::Value? v = vm.get(raw(object), (rt::Value)key);
	if (catch v)
	{
		vm.exception = rt::EMPTY;
		return fallback;
	}
	return v.is_number() ? v.as_number() : fallback;
}

<*
 obj[key] as JS truthiness; false when reading it threw.
*>
fn bool Context.get_bool(&self, Value object, Atom key)
{
	rt::Vm* vm = self.vm();
	rt::Value? v = vm.get(raw(object), (rt::Value)key);
	if (catch v)
	{
		vm.exception = rt::EMPTY;
		return false;
	}
	return rt::truthy(v);
}

<*
 obj[key] = value. Takes ownership of value.

 @return "False when it threw"
*>
fn bool Context.set(&self, Value object, Atom key, Value value)
{
	defer self.release(value);
	rt::Vm* vm = self.vm();
	rt::Value obj = raw(object);
	if (!obj.is_object())
	{
		(void)vm.throw_error(TYPE_ERROR, "cannot set a property of %s", vm.describe(obj));
		return false;
	}
	if (catch vm.set(obj, (rt::Value)key, raw(value))) return false;
	return true;
}

<*
 Object.keys(obj), owned: an array of its own enumerable string keys. EXCEPTION when it threw.
*>
fn Value Context.keys(&self, Value object)
{
	rt::Vm* vm = self.vm();
	rt::Value[1] args = { raw(object) };
	vm.native_depth++;
	rt::Value? keys = rt::native_object_keys(vm, rt::UNDEFINED, &args, null);
	vm.native_depth--;
	if (catch keys) return EXCEPTION;
	return self.own(keys);
}

<*
 Where value keeps its bytes, for a typed array, DataView or ArrayBuffer.

 @return? NOT_A_VIEW : "value is none of those, or its buffer was detached"
*>
fn View? Context.view(&self, Value value)
{
	rt::Value v = raw(value);
	if (!v.is_object()) return NOT_A_VIEW~;
	JsObject* o = v.as_object();
	switch (o.kind)
	{
		case ARRAY_BUFFER:
			JsArrayBuffer* b = (JsArrayBuffer*)o;
			if (!b.data && b.external) return NOT_A_VIEW~;
			return { VIEW_BUFFER, b.data, b.byte_length, b.byte_length };
		case TYPED_ARRAY:
			JsTypedArray* t = (JsTypedArray*)o;
			if (!t.data && t.buffer.external) return NOT_A_VIEW~;
			return { typed_kind_code(t.tkind), t.data, t.length, (usz)t.length * t.tkind.size };
		case DATA_VIEW:
			JsTypedArray* t = (JsTypedArray*)o;
			if (!t.data && t.buffer.external) return NOT_A_VIEW~;
			return { VIEW_DATA, t.data, t.length, t.length };
		default:
			return NOT_A_VIEW~;
	}
}

fn int typed_kind_code(rt::TypedKind kind)
{
	switch (kind)
	{
		case INT8: return ARRAY_INT8;
		case UINT8: return ARRAY_UINT8;
		case UINT8_CLAMPED: return ARRAY_UINT8C;
		case INT16: return ARRAY_INT16;
		case UINT16: return ARRAY_UINT16;
		case INT32: return ARRAY_INT32;
		case UINT32: return ARRAY_UINT32;
		case FLOAT32: return ARRAY_FLOAT32;
		case FLOAT64: return ARRAY_FLOAT64;
	}
}

fn JsPromise* promise_of(rt::Value v)
{
	if (!v.is_object() || v.as_object().kind != PROMISE) return null;
	return (JsPromise*)v.as_object();
}

<*
 Whether value is a promise, and how it stands.
*>
fn PromiseState Context.promise_state(&self, Value value)
{
	JsPromise* p = promise_of(raw(value));
	if (!p) return NOT_A_PROMISE;
	switch (p.state)
	{
		case PENDING: return PENDING;
		case FULFILLED: return FULFILLED;
		case REJECTED: return REJECTED;
	}
}

<*
 A settled promise's value or rejection reason, owned; undefined while it is pending. Reading a
 rejection counts as handling it, so it isn't reported as unhandled.
*>
fn Value Context.promise_result(&self, Value value)
{
	JsPromise* p = promise_of(raw(value));
	if (!p || p.state == PENDING) return undefined_value();
	if (p.state == REJECTED && !p.handled)
	{
		self.vm().forget_unhandled(p);
		p.handled = true;
	}
	return self.own(p.result);
}
