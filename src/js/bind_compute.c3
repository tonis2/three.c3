<*
The `three.compute` verbs: buffers, kernels, dispatch, submit.

 ## What crosses

 Handles, not pointers. A script holds an integer and the host holds the
 buffer; a handle that has been disposed of is refused by name rather than
 read as whatever now sits at that address. Each handle carries a generation
 for the same reason `NodeId` does - a slot the script gave back and the host
 reused would otherwise be a live handle onto somebody else's data.

 ## Why the argument counts are what they are

 The prelude does the ergonomics: it turns a typed array into the
 `(buffer, byteOffset, elementCount)` triple the host reads, packs a push block
 out of an object, and converts a work-item count into workgroups. What reaches
 this file is already numbers and views, which is the same split `bind_query.c3`
 draws and for the same reason - a host verb earns its keep by doing the thing
 JavaScript cannot, and JavaScript can unpack its own objects.
*>
module three;

import std::collections::list;
import qjs;

// A slot in one of the tables below, addressed by index and generation the way
// a `NodeId` is: the generation is what makes a freed handle distinguishable
// from a live one, and the pair survives the slot being handed out again.
struct ComputeHandle
{
	uint index;
	uint generation;
}

const uint COMPUTE_HANDLE_NONE = 0xFFFF_FFFF;

fn qjs::Value compute_handle_value(ComputeHandle handle)
{
	if (handle.index == COMPUTE_HANDLE_NONE) return qjs::int_value(-1);
	return qjs::int_value((int)((handle.generation << 16) | handle.index));
}

fn ComputeHandle compute_handle_of(int encoded)
{
	if (encoded < 0) return { .index = COMPUTE_HANDLE_NONE };
	return (ComputeHandle) {
		.index = (uint)(encoded & 0xFFFF),
		.generation = (uint)((encoded >> 16) & 0xFFFF),
	};
}

struct StorageSlot
{
	StorageBuffer* buffer;
	uint           generation;
	bool           live;
}

struct KernelSlot
{
	ComputeKernel* kernel;
	uint           generation;
	bool           live;
	// The entry point's workgroup size, as `@threads` declared it. What turns a
	// work-item count into the group counts a dispatch takes - and read here
	// rather than asked of the script, because a script that wrote
	// `@threads(64, 1, 1)` should not have to say 64 again at every call.
	uint[3]        threads;
}

fn void JsRuntime.bind_compute_verbs(&self, qjs::Value host)
{
	self.bind(host, "computeCreateBuffer", &js_compute_create_buffer, 4);
	self.bind(host, "computeWriteBuffer", &js_compute_write_buffer, 4);
	self.bind(host, "computeReadBuffer", &js_compute_read_buffer, 3);
	self.bind(host, "computeFreeBuffer", &js_compute_free_buffer, 1);
	self.bind(host, "computeCreateKernel", &js_compute_create_kernel, 4);
	self.bind(host, "computeFreeKernel", &js_compute_free_kernel, 1);
	self.bind(host, "computeDispatch", &js_compute_dispatch, 6);
	self.bind(host, "computeSubmit", &js_compute_submit, 0);
}

// --- Handles -----------------------------------------------------------------

fn StorageSlot* storage_slot(JsRuntime* self, int encoded, qjs::Context* js, qjs::Value* out) @local
{
	ComputeHandle handle = compute_handle_of(encoded);
	if (handle.index >= self.storage_slots.len()
		|| !self.storage_slots[handle.index].live
		|| self.storage_slots[handle.index].generation != handle.generation)
	{
		*out = js.raise("this buffer handle is not live - it was never made here, or it has been freed");
		return null;
	}
	return &self.storage_slots[handle.index];
}

fn StorageBuffer* storage_buffer(JsRuntime* self, int encoded, qjs::Context* js, qjs::Value* out) @local
{
	StorageSlot* slot = storage_slot(self, encoded, js, out);
	return slot == null ? null : slot.buffer;
}

fn KernelSlot* kernel_slot(JsRuntime* self, int encoded, qjs::Context* js, qjs::Value* out) @local
{
	ComputeHandle handle = compute_handle_of(encoded);
	if (handle.index >= self.kernel_slots.len()
		|| !self.kernel_slots[handle.index].live
		|| self.kernel_slots[handle.index].generation != handle.generation)
	{
		*out = js.raise("this kernel handle is not live - it was never made here, or it has been freed");
		return null;
	}
	return &self.kernel_slots[handle.index];
}

<*
 A free slot, or a new one.

 The generation of a reused slot moves, so a handle a script kept past its
 `free()` cannot reach whatever was made in its place.
*>
fn uint storage_slot_for(JsRuntime* self) @local
{
	foreach (i, &slot : self.storage_slots)
	{
		if (slot.live) continue;
		slot.generation++;
		return (uint)i;
	}
	self.storage_slots.push({ .generation = 1 });
	return (uint)(self.storage_slots.len() - 1);
}

fn uint kernel_slot_for(JsRuntime* self) @local
{
	foreach (i, &slot : self.kernel_slots)
	{
		if (slot.live) continue;
		slot.generation++;
		return (uint)i;
	}
	self.kernel_slots.push({ .generation = 1 });
	return (uint)(self.kernel_slots.len() - 1);
}

fn Compute* runtime_compute(JsRuntime* self, qjs::Context* js, qjs::Value* out) @local
{
	if (self.renderer == null)
	{
		*out = js.raise("three.compute needs a GPU device and this context has none");
		return null;
	}
	return &self.renderer.compute;
}

// --- Buffers -----------------------------------------------------------------

<*
 `computeCreateBuffer(size, data, byteOffset, count)` - one storage buffer.

 `size` is bytes and is what the buffer is; the optional `(data, offset,
 count)` triple is an upload of `count` bytes taken from that view, so a script
 can make a buffer and fill it in one call without a staging copy it would have
 to size itself.
*>
fn void js_compute_create_buffer(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	Compute* compute = runtime_compute(self, &js, out);
	if (compute == null) return;

	double size_number = arg_number(&js, argc, args, 0);
	if (size_number <= 0)
	{
		*out = js.raise("three.compute.buffer(size) wants a positive size in bytes");
		return;
	}
	usz size = (usz)size_number;

	// The upload is optional and is the three-part view the other typed-array
	// verbs take. A count of zero is no upload at all rather than an empty one,
	// which is both what a script means by it and what an empty view cannot
	// express: a detached or zero-length array answers with no bytes to point
	// at, and there is nothing to copy either way.
	char[] upload = { };
	if (argc >= 4)
	{
		long offset = (long)arg_number(&js, argc, args, 2);
		long count  = (long)arg_number(&js, argc, args, 3);
		if (offset < 0 || count < 0)
		{
			*out = js.raise("three.compute.buffer(size, data, byteOffset, byteCount) was given a negative view");
			return;
		}
		if (count > 0)
		{
			char[] whole = js.bytes(args[1]);
			if (offset + count > (long)whole.len)
			{
				*out = js.raise("three.compute.buffer(size, data, byteOffset, byteCount) was given a view past the end of the array");
				return;
			}
			upload = whole[(usz)offset:(usz)count];
		}
	}

	uint index = storage_slot_for(self);
	StorageSlot* slot = &self.storage_slots[index];

	StorageBuffer* buffer = alloc::new(mem, StorageBuffer);
	if (catch buffer.create(&self.renderer.gpu, size, upload.len > 0 ? upload.ptr : null))
	{
		alloc::free(mem, buffer);
		self.storage_slots[index].live = false;
		*out = js.raise("three.compute.buffer could not allocate that buffer on this device");
		return;
	}

	slot.buffer = buffer;
	slot.live   = true;
	*out = compute_handle_value({ .index = index, .generation = slot.generation });
}

<*
 `computeWriteBuffer(handle, data, byteOffset, count)` - stage `count` bytes
 from the view into the buffer at byte zero.

 The write is submitted and waited for here, so a dispatch recorded afterwards
 reads the new bytes. That is the same rule `StorageBuffer.write` follows and
 the reason the verb does not hand back a "pending" flag: an upload that had
 not landed would be a wrong answer with no symptom.
*>
fn void js_compute_write_buffer(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	StorageBuffer* buffer = storage_buffer(self, arg_int(&js, argc, args, 0), &js, out);
	if (buffer == null) return;

	char[] whole = js.bytes(args[1]);
	long offset  = (long)arg_number(&js, argc, args, 2);
	long count   = (long)arg_number(&js, argc, args, 3);
	{
		float first = 0;
		if (count >= 4) mem::copy(&first, whole.ptr + offset, 4);
	}
	if (offset < 0 || count <= 0)
	{
		*out = js.raise("three.compute.write(handle, data, byteOffset, byteCount) was given a negative or empty view");
		return;
	}
	if (whole.len == 0)
	{
		// `js.bytes` reads a Uint8Array or an ArrayBuffer and nothing else. A
		// Float32Array - the view a buffer of floats naturally hands over -
		// answers with no bytes at all, and a write that copied nothing would
		// otherwise look exactly like one that worked.
		*out = js.raise("three.compute.write wants bytes - a Uint8Array or an ArrayBuffer, not a typed array of another element");
		return;
	}
	if (offset + count > (long)whole.len)
	{
		*out = js.raise("three.compute.write(handle, data, byteOffset, byteCount) was given a view past the end of the array");
		return;
	}

	Compute* compute = &self.renderer.compute;
	if (catch buffer.write(compute, 0, whole.ptr + offset, (usz)count))
	{
		*out = js.raise(string::tformat(
			"three.compute.write wanted %d bytes and the buffer holds %d",
			(int)count, (int)buffer.size));
		return;
	}
}

<*
 `computeReadBuffer(handle, target, byteCount)` - fill a script's typed array
 from the buffer's first bytes.

 `submit()` first: this is the verb that turns GPU state into an answer, and
 reading before the dispatch that wrote it has run would copy the buffer as it
 was. The wait is folded in here rather than left to the caller because a
 script that forgot it would get a wrong number rather than an error.
*>
fn void js_compute_read_buffer(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	StorageBuffer* buffer = storage_buffer(self, arg_int(&js, argc, args, 0), &js, out);
	if (buffer == null)
	{
		return;
	}

	char[] target = js.bytes(args[1]);
	long count    = (long)arg_number(&js, argc, args, 2);
	if (count <= 0 || count > (long)target.len)
	{
		*out = js.raise("three.compute.read(handle, target, byteCount) wants a target at least as long as the count");
		return;
	}
	if ((usz)count > buffer.size)
	{
		*out = js.raise(string::tformat(
			"three.compute.read wanted %d bytes and the buffer holds %d",
			(int)count, (int)buffer.size));
		return;
	}

	Compute* compute = &self.renderer.compute;
	if (catch compute.submit())
	{
		*out = js.raise("the compute submission failed before the readback");
		return;
	}
	if (catch buffer.read(compute, 0, target[:(usz)count]))
	{
		*out = js.raise("the compute readback could not copy those bytes out");
		return;
	}
}

fn void js_compute_free_buffer(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	StorageSlot* slot = storage_slot(self, arg_int(&js, argc, args, 0), &js, out);
	if (slot == null) return;

	if (self.renderer != null) self.renderer.gpu.handle.waitIdle();
	slot.buffer.free();
	alloc::free(mem, slot.buffer);
	slot.buffer = null;
	slot.live   = false;
}

// --- Kernels -----------------------------------------------------------------

<*
 `computeCreateKernel(source, name, entry)` - compile and build.

 The source is the whole program: `@storage` declarations, a `@compute` entry
 point with `@threads`, and whatever else it needs. A refused source answers a
 `TypeError` carrying the compiler's own diagnostic, because that message has a
 line and a column in it and is the only thing that says what to fix.
*>
fn void js_compute_create_kernel(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	Compute* compute = runtime_compute(self, &js, out);
	if (compute == null) return;

	String source = arg_text(&js, argc, args, 0, tmem);
	String name   = arg_text(&js, argc, args, 1, tmem);
	String entry  = arg_text(&js, argc, args, 2, tmem);
	if (source.len == 0)
	{
		*out = js.raise("three.compute.kernel(source) wants the shader source");
		return;
	}
	if (name.len == 0) name = "kernel";
	if (entry.len == 0) entry = "main";

	ShaderModule shader = compile_compute_shader(name, source);
	defer shader.free();

	if (!shader.ok)
	{
		// The kernel's name goes in front of the compiler's own message: the
		// diagnostic has the line, the column and the caret, and what it does
		// not have is which of a script's kernels it was.
		*out = js.raise(shader.diagnostic.len > 0
			? string::tformat("%s: %s", name, shader.diagnostic)
			: string::tformat("%s did not compile", name));
		return;
	}

	uint index = kernel_slot_for(self);
	KernelSlot* slot = &self.kernel_slots[index];

	ComputeKernel* kernel = alloc::new(mem, ComputeKernel);
	if (catch kernel.create(compute, &shader, name, entry))
	{
		alloc::free(mem, kernel);
		self.kernel_slots[index].live = false;
		*out = js.raise(string::tformat(
			"%s has no usable compute entry point `%s`, or binds something other than storage buffers",
			name, entry));
		return;
	}

	slot.kernel  = kernel;
	slot.live    = true;
	slot.threads = {
		argc >= 4 && arg_number(&js, argc, args, 3) > 0 ? (uint)arg_number(&js, argc, args, 3) : 64,
		1,
		1,
	};
	*out = compute_handle_value({ .index = index, .generation = slot.generation });
}

fn void js_compute_free_kernel(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	KernelSlot* slot = kernel_slot(self, arg_int(&js, argc, args, 0), &js, out);
	if (slot == null) return;

	if (self.renderer != null) self.renderer.gpu.handle.waitIdle();
	slot.kernel.free(self.renderer.gpu.handle);
	alloc::free(mem, slot.kernel);
	slot.kernel = null;
	slot.live   = false;
}

// --- Dispatch ----------------------------------------------------------------

<*
 `computeDispatch(kernel, buffers, push, itemsX, itemsY, groupsZ)` - record one
 dispatch.

 `buffers` is a plain Array of handles in the shader's binding order, and
 `push` is the push block's bytes as a typed array. The last three numbers are
 either a work-item count per axis - the usual case, and split here by the
 entry point's own `@threads` - or, when the third is positive, the group counts
 themselves, which is what a dispatch that wants exactly `(4, 1, 1)` says. One
 call rather than two verbs because the difference is three numbers, and the
 prelude is what decides which reading it meant.
*>
fn void js_compute_dispatch(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	KernelSlot* slot = kernel_slot(self, arg_int(&js, argc, args, 0), &js, out);
	if (slot == null) return;
	ComputeKernel* kernel = slot.kernel;

	Compute* compute = &self.renderer.compute;

	// The buffers, in binding order: a plain Array whose length is checked
	// against the kernel's own count, so a script that forgot one is told which
	// one it forgot rather than dispatching against a stale binding.
	qjs::Value list = argc >= 2 ? args[1] : qjs::undefined_value();
	int given = (int)js.length(list);
	if (given < 0) given = 0;

	StorageBuffer[COMPUTE_MAX_BINDINGS] buffers;
	if ((uint)given != kernel.binding_count)
	{
		*out = js.raise(string::tformat(
			"this kernel binds %d buffers and %d were given - they go in the shader's own order",
			(int)kernel.binding_count, given));
		return;
	}
	for (int i = 0; i < given; i++)
	{
		qjs::Value element = js.index(list, (uint)i);
		StorageBuffer* buffer = storage_buffer(self, (int)js.number(element), &js, out);
		if (buffer == null) return;
		buffers[i] = *buffer;
	}

	char[] push = argc >= 3 ? js.bytes(args[2]) : (char[]){ };
	if (push.len > 0 && push.len < kernel.push_size)
	{
		*out = js.raise(string::tformat(
			"this kernel's push block is %d bytes and %d were given", (int)kernel.push_size, (int)push.len));
		return;
	}

	// What to cover: either a work-item count per axis, which is split here by
	// the entry point's own `@threads`, or group counts passed as
	// `{ workgroups: [x, y, z] }`, which the prelude signals by putting them in
	// the last three arguments.
	uint groups_x = 1;
	uint groups_y = 1;
	uint groups_z = 1;
	if (argc >= 6 && arg_number(&js, argc, args, 5) > 0)
	{
		groups_x = (uint)arg_number(&js, argc, args, 3);
		groups_y = (uint)arg_number(&js, argc, args, 4);
		groups_z = (uint)arg_number(&js, argc, args, 5);
	}
	else
	{
		ulong items_x = (ulong)arg_number(&js, argc, args, 3);
		ulong items_y = (ulong)arg_number(&js, argc, args, 4);
		if (items_x > 0) groups_x = (uint)((items_x + slot.threads[0] - 1) / slot.threads[0]);
		if (items_y > 0) groups_y = (uint)((items_y + slot.threads[1] - 1) / slot.threads[1]);
	}
	if (groups_x == 0) groups_x = 1;
	if (groups_y == 0) groups_y = 1;
	if (groups_z == 0) groups_z = 1;

	if (push.len >= 4)
	{
		uint word = 0;
		mem::copy(&word, push.ptr, 4);
	}
	else
	{
	}
	{
	}
	if (catch compute.dispatch(kernel, buffers[0..kernel.binding_count - 1],
		push.len > 0 ? push.ptr : null, groups_x, groups_y, groups_z))
	{
		*out = js.raise("the dispatch could not be recorded");
		return;
	}
	if (catch compute.submit()) { }
	{
		char[16] peek;
		if (catch buffers[1].read(compute, 0, peek[..])) { }
		else
		{
			float* f = (float*)&peek;
			}
	}
}

<*
 `computeSubmit()` - record, submit, wait.

 The boundary a script draws itself: it is one wait, and it is also where a
 long chain is cut so that no single submission outlives a driver's patience.
*>
fn void js_compute_submit(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	Compute* compute = runtime_compute(self, &js, out);
	if (compute == null) return;

	if (catch compute.submit()) *out = js.raise("the compute submission failed");
}

<*
 Free everything a run left behind.

 Called when a script run finishes rather than from a script, so a kernel a
 script made and forgot cannot keep a pipeline alive across runs. The script's
 buffers go with it: they were made by that run and nothing else can name them.
*>
fn void JsRuntime.release_compute(&self)
{
	if (self.renderer != null) self.renderer.gpu.handle.waitIdle();

	foreach (&slot : self.storage_slots)
	{
		if (!slot.live) continue;
		slot.buffer.free();
		alloc::free(mem, slot.buffer);
		slot.buffer = null;
		slot.live   = false;
	}
	foreach (&slot : self.kernel_slots)
	{
		if (!slot.live) continue;
		slot.kernel.free(self.renderer.gpu.handle);
		alloc::free(mem, slot.kernel);
		slot.kernel = null;
		slot.live   = false;
	}
	self.storage_slots.free();
	self.kernel_slots.free();
}
