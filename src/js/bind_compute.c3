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
import std::io::file;
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
	self.bind(host, "computeWriteBuffer", &js_compute_write_buffer, 5);
	self.bind(host, "computeReadBuffer", &js_compute_read_buffer, 4);
	self.bind(host, "computeFreeBuffer", &js_compute_free_buffer, 1);
	self.bind(host, "computeCreateKernel", &js_compute_create_kernel, 3);
	self.bind(host, "computeCreateKernelSpirv", &js_compute_create_kernel_spirv, 3);
	self.bind(host, "computeKernelThreads", &js_compute_kernel_threads, 1);
	self.bind(host, "computeSpirv", &js_compute_spirv, 1);
	self.bind(host, "computeFreeKernel", &js_compute_free_kernel, 1);
	self.bind(host, "computeDispatch", &js_compute_dispatch, 7);
	self.bind(host, "computeSubmit", &js_compute_submit, 0);
	self.bind(host, "computeSubmitAsync", &js_compute_submit_async, 0);
	self.bind(host, "computeBusy", &js_compute_busy, 0);
	self.bind(host, "computeCopy", &js_compute_copy, 6);
	self.bind(host, "computeFill", &js_compute_fill, 5);
	self.bind(host, "computeBarrier", &js_compute_barrier, 0);
	self.bind(host, "computeLimits", &js_compute_limits, 0);
	self.bind(host, "computeCreateImage", &js_compute_create_image, 4);
	self.bind(host, "computeReadImage", &js_compute_read_image, 2);
	self.bind(host, "computeWriteImage", &js_compute_write_image, 2);
	self.bind(host, "computeFreeImage", &js_compute_free_image, 1);
	self.bind(host, "computeKernelBindings", &js_compute_kernel_bindings, 1);
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

<*
 Hand a buffer the host made to the script, as a handle `three.compute.adopt`
 wraps.

 For an embedding program with data of its own to put on the GPU - a model's
 weights, streamed out of a mapped file - which it fills with `StorageBuffer`'s
 own verbs and then gives to JavaScript to bind. The runtime owns the buffer from
 here: `dispose()` or the end of the context frees it.

 @param [&inout] buffer : `Allocated with mem, created. Ownership moves to the runtime.`
 @return `The handle, as the script's integer.`
*>
fn int JsRuntime.adopt_storage_buffer(&self, StorageBuffer* buffer)
{
	uint index = storage_slot_for(self);
	StorageSlot* slot = &self.storage_slots[index];
	slot.buffer = buffer;
	slot.live   = true;
	return (int)((slot.generation << 16) | index);
}

<*
 The buffer behind a script's handle, or null when the handle is not live.

 The host-side half of `adopt_storage_buffer`: a verb an embedding program adds
 takes a `ComputeBuffer`'s handle and writes into, or reads out of, the buffer
 behind it.
*>
fn StorageBuffer* JsRuntime.storage_buffer_of(&self, int encoded)
{
	ComputeHandle handle = compute_handle_of(encoded);
	if (handle.index >= self.storage_slots.len()) return null;
	StorageSlot* slot = &self.storage_slots[handle.index];
	if (!slot.live || slot.generation != handle.generation) return null;
	return slot.buffer;
}

<*
 Submit whatever is recorded and wait for the device, before something a
 recorded command names is freed. A failed submit is a lost device, and the
 free that follows is then the least of anybody's problems.
*>
fn void flush_compute(JsRuntime* self)
{
	if (self.renderer == null) return;
	if (catch self.renderer.compute.submit()) { }
	self.renderer.gpu.handle.waitIdle();
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

	// Zeroes, as a script expects of a buffer it has not written: the memory
	// may be a freed buffer's, and a kernel that accumulates into it would add to
	// that buffer's numbers. Recorded, so it costs nothing until the next submit.
	if (upload.len == 0) compute.clear(buffer);

	slot.buffer = buffer;
	slot.live   = true;
	*out = compute_handle_value({ .index = index, .generation = slot.generation });
}

<*
 `computeWriteBuffer(handle, data, byteOffset, count, at)` - stage `count` bytes
 from the view into the buffer, starting at byte `at` (zero when left out).

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
	long at      = argc >= 5 ? (long)arg_number(&js, argc, args, 4) : 0;
	if (offset < 0 || count <= 0 || at < 0)
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
	if (catch buffer.write(compute, (usz)at, whole.ptr + offset, (usz)count))
	{
		*out = js.raise(string::tformat(
			"three.compute.write wanted %d bytes at %d and the buffer holds %d",
			(long)count, at, (long)buffer.size));
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
	long at       = argc >= 4 ? (long)arg_number(&js, argc, args, 3) : 0;
	if (at < 0)
	{
		*out = js.raise("three.compute.read(handle, target, byteCount, at) was given a negative offset");
		return;
	}
	if (count <= 0 || count > (long)target.len)
	{
		*out = js.raise("three.compute.read(handle, target, byteCount) wants a target at least as long as the count");
		return;
	}
	if ((usz)(count + at) > buffer.size)
	{
		*out = js.raise(string::tformat(
			"three.compute.read wanted %d bytes at %d and the buffer holds %d",
			(long)count, at, (long)buffer.size));
		return;
	}

	Compute* compute = &self.renderer.compute;
	if (catch compute.submit())
	{
		*out = js.raise("the compute submission failed before the readback");
		return;
	}
	if (catch buffer.read(compute, (usz)at, target[:(usz)count]))
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

	// A dispatch recorded and not yet submitted may still name this buffer, and
	// `waitIdle` only waits for what has been submitted.
	flush_compute(self);
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

	ShaderModule shader = compile_compute_shader_cached(name, source);
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

	install_kernel(self, &js, &shader, name, entry, out);
}

<*
 `computeCreateKernelSpirv(bytes, name, entry)` - build from a compiled module.

 The bytes are a SPIR-V module: one a script read from disk with
 `three.compute.spirv`, or built by a compiler that is not this one. Nothing is
 compiled here, so nothing can be blamed on a line - a module this cannot read
 is refused for what it is.

 The workgroup size is the module's own `LocalSize` rather than something the
 script passes: a precompiled kernel has no source to read it out of, and the
 one place that knows is the module.
*>
fn void js_compute_create_kernel_spirv(
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

	char[] bytes = js.bytes(args[0]);
	String name  = arg_text(&js, argc, args, 1, tmem);
	String entry = arg_text(&js, argc, args, 2, tmem);
	if (bytes.len == 0)
	{
		*out = js.raise("three.compute.kernel(module) wants the module's bytes");
		return;
	}
	if (name.len == 0) name = "kernel";
	if (entry.len == 0) entry = "main";

	// Copied, because the module takes ownership of what it is given and these
	// bytes belong to the script.
	char[] owned = alloc::alloc_array(mem, char, bytes.len);
	mem::copy(owned.ptr, bytes.ptr, bytes.len);

	ShaderModule shader = three::adopt_spirv_module(name, owned, entry);
	defer shader.free();

	if (!shader.ok)
	{
		*out = js.raise(shader.diagnostic.len > 0
			? shader.diagnostic
			: string::tformat("%s is not something this can dispatch", name));
		return;
	}

	install_kernel(self, &js, &shader, name, entry, out);
}

<*
 `computeKernelThreads(handle)` - the workgroup size, as `[x, y, z]`.

 The module wrote it down and the host keeps it: a script that wants to reason
 about a dispatch (how many groups a work-item count becomes, or what a
 dispatch cost) should not have to parse it back out of a shader, and a
 precompiled module has no source to parse.
*>
fn void js_compute_kernel_threads(
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

	qjs::Value array = js.array();
	for (uint i = 0; i < 3; i++)
	{
		js.set_index(array, (uint)i, qjs::number_value((double)slot.threads[i]));
	}
	*out = array;
}

<*
 `computeSpirv(path)` - a module read from disk, as bytes.

 The path is the script's to write and is resolved like every other file here,
 so `three.compute.spirv("../shaders/zimage.spv")` and a path from the command
 line are the same thing. What comes back is a `Uint8Array` the script owns: it
 can be handed to `kernel()` and kept for the next one.
*>
fn void js_compute_spirv(
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

	String asked = arg_text(&js, argc, args, 0, tmem);
	if (asked.len == 0)
	{
		*out = js.raise("three.compute.spirv(path) wants the module's path");
		return;
	}

	char[]? bytes = file::load(tmem, asked);
	if (catch err = bytes)
	{
		*out = js.raise(string::tformat("could not read %s: %s", asked, err));
		return;
	}
	if (bytes.len < 4 || *(uint*)bytes.ptr != SPIRV_MAGIC)
	{
		*out = js.raise(string::tformat(
			"%s is not a SPIR-V module - three.compute.spirv reads modules, and a shading source "
				"goes to three.compute.kernel as text",
			asked));
		return;
	}

	// `buffer_copy` so the bytes belong to the script: the file is read into
	// temporary memory that is gone by the time the script runs. The view holds
	// the buffer on its own, so the host's own reference to it goes.
	qjs::Value buffer = js.buffer_copy(bytes.ptr, bytes.len);
	defer js.release(buffer);
	*out = js.typed_array(qjs::ARRAY_UINT8, buffer, 0, bytes.len);
}

<*
 The tail both creation paths share: a slot, a pipeline, and the handle a
 script holds.
*>
fn void install_kernel(
	JsRuntime* self,
	qjs::Context* js,
	ShaderModule* shader,
	String name,
	String entry,
	qjs::Value* out
) @local
{
	uint index = kernel_slot_for(self);
	KernelSlot* slot = &self.kernel_slots[index];
	Compute* compute = &self.renderer.compute;

	ComputeKernel* kernel = alloc::new(mem, ComputeKernel);
	if (catch err = kernel.create(compute, shader, name, entry))
	{
		// Whatever `create` got as far as making - a name, a set layout - goes
		// with it; every field is null until it is made.
		kernel.free(self.renderer.gpu.handle);
		alloc::free(mem, kernel);
		self.kernel_slots[index].live = false;
		GpuLimits* limits = &self.renderer.gpu.limits;
		switch (err)
		{
			case COMPUTE_UNSUPPORTED_SUBGROUP_SIZE:
				*out = js.raise(string::tformat(
					"%s is written for a subgroup of %d lanes, and this device %s", name, shader.subgroup_size,
					limits.subgroup_size_control
						? string::tformat("runs %d to %d", limits.min_subgroup_size, limits.max_subgroup_size)
						: "cannot be asked for a subgroup size"));
			case COMPUTE_KERNEL_NO_ENTRY:
				*out = js.raise(string::tformat("%s has no compute entry point `%s`", name, entry));
			case COMPUTE_UNSUPPORTED_BINDING:
				*out = js.raise(string::tformat(
					"%s binds something a kernel cannot: storage buffers, storage images (image2d<...>) and "
						"sampled textures (Sampler2D) are what a kernel takes, one per binding and all in set 0",
					name));
			case COMPUTE_IMAGE_FEATURE:
				*out = js.raise(string::tformat(
					"%s declares a storage image this device cannot have: an extended format needs "
						"shaderStorageImageExtendedFormats, and an image2d<float4> whose format the host picks needs "
						"shaderStorageImage%sWithoutFormat - name the format, e.g. image2d<rgba16f>",
					name, limits.storage_image_read_without_format ? "Write" : "Read"));
			case COMPUTE_TOO_MANY_IMAGES:
				*out = js.raise(string::tformat(
					"%s declares more storage images than the %d this device binds per kernel",
					name, limits.max_per_stage_storage_images));
			case COMPUTE_NOT_READY:
				*out = js.raise(string::tformat(
					"%s declares more than %d bindings - split it", name, COMPUTE_MAX_BINDINGS));
			default:
				*out = js.raise(string::tformat("%s could not be built: %s", name, err));
		}
		return;
	}

	// The module's own workgroup size, not a number from the script: `@threads`
	// is in the module and a work-item count is divided by it, so a disagreeing
	// value here would dispatch the wrong number of groups.
	if (shader.local_size[0] == 0)
	{
		kernel.free(self.renderer.gpu.handle);
		alloc::free(mem, kernel);
		self.kernel_slots[index].live = false;
		*out = js.raise(string::tformat(
			"%s declares no compute workgroup size - a module whose size is an `OpExecutionModeId` "
				"cannot be dispatched by this host yet",
			name));
		return;
	}

	slot.kernel  = kernel;
	slot.live    = true;
	slot.threads = shader.local_size;
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

	flush_compute(self);
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
	// one it forgot rather than dispatching against a stale binding. An element
	// is a handle, or `[handle, byteOffset, byteSize]` for a range of one - a
	// size of zero runs to the end of the buffer.
	qjs::Value list = argc >= 2 ? args[1] : qjs::undefined_value();
	int given = (int)js.length(list);
	if (given < 0) given = 0;

	ComputeBinding[COMPUTE_MAX_BINDINGS] views;
	if ((uint)given != kernel.binding_count)
	{
		*out = js.raise(string::tformat(
			"this kernel binds %d buffers and images and %d were given - they go in the shader's own order",
			(int)kernel.binding_count, given));
		return;
	}
	ulong alignment = self.renderer.gpu.limits.min_storage_buffer_offset_alignment;
	if (alignment == 0) alignment = 1;
	for (int i = 0; i < given; i++)
	{
		qjs::Value element = js.index(list, (uint)i);
		defer js.release(element);

		// An image binding is a texture index - the prelude checked it is an
		// image rather than a buffer, and this checks it is still there and is
		// the image the shader declared.
		ComputeBindingInfo* info = &kernel.info[i];
		if (info.is_image())
		{
			int index = (int)js.number(element);
			if (self.pass == null || !self.pass.assets.texture_alive(index))
			{
				*out = js.raise(string::tformat(
					"binding %d (%s) is an image that has been disposed", i, kernel.binding_names[i]));
				return;
			}
			Texture* image = self.pass.assets.texture_at(index);
			String wrong = storage_image_mismatch(&self.renderer.gpu, info, image);
			if (wrong.len > 0)
			{
				*out = js.raise(string::tformat("binding %d (%s) cannot take this image: %s",
					i, kernel.binding_names[i], wrong));
				return;
			}
			views[i] = { .image = image };
			continue;
		}

		long handle = 0;
		long offset = 0;
		long size   = 0;
		if (js.length(element) >= 2)
		{
			qjs::Value h = js.index(element, 0);
			qjs::Value o = js.index(element, 1);
			qjs::Value n = js.index(element, 2);
			handle = (long)js.number(h);
			offset = (long)js.number(o);
			size   = (long)js.number(n);
			js.release(h);
			js.release(o);
			js.release(n);
		}
		else
		{
			handle = (long)js.number(element);
		}

		StorageBuffer* buffer = storage_buffer(self, (int)handle, &js, out);
		if (buffer == null) return;
		if (offset < 0 || size < 0 || (usz)(offset + size) > buffer.size || (usz)offset >= buffer.size)
		{
			*out = js.raise(string::tformat(
				"binding %d (%s) asks for %d bytes at %d of a buffer of %d",
				i, kernel.binding_names[i], size, offset, (long)buffer.size));
			return;
		}
		if ((ulong)offset % alignment != 0)
		{
			*out = js.raise(string::tformat(
				"binding %d (%s) starts at byte %d, and this device binds at multiples of %d",
				i, kernel.binding_names[i], offset, (long)alignment));
			return;
		}
		views[i] = { .buffer = buffer.view((usz)offset, (usz)size) };
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

	// The seventh argument is `independent`: true skips the barrier after this
	// dispatch, for a caller that knows the next command does not read it.
	bool barrier = !(argc >= 7 && js.truth(args[6]));

	if (catch compute.dispatch_bindings(kernel, views[:kernel.binding_count],
		push.len > 0 ? push.ptr : null, groups_x, groups_y, groups_z, barrier))
	{
		*out = js.raise("the dispatch could not be recorded");
		return;
	}
}

<*
 `computeCopy(source, sourceOffset, destination, destinationOffset, byteCount,
 independent)` - a GPU-side copy, recorded in order with the dispatches.
*>
fn void js_compute_copy(
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

	StorageBuffer* source = storage_buffer(self, arg_int(&js, argc, args, 0), &js, out);
	if (source == null) return;
	StorageBuffer* destination = storage_buffer(self, arg_int(&js, argc, args, 2), &js, out);
	if (destination == null) return;

	long source_offset      = (long)arg_number(&js, argc, args, 1);
	long destination_offset = (long)arg_number(&js, argc, args, 3);
	long count              = (long)arg_number(&js, argc, args, 4);
	bool barrier            = !(argc >= 6 && js.truth(args[5]));

	if (source_offset < 0 || destination_offset < 0 || count <= 0
		|| (usz)(source_offset + count) > source.size
		|| (usz)(destination_offset + count) > destination.size)
	{
		*out = js.raise(string::tformat(
			"three.compute.copy of %d bytes from %d (of %d) to %d (of %d) does not fit",
			count, source_offset, (long)source.size, destination_offset, (long)destination.size));
		return;
	}

	if (catch compute.copy(source, (usz)source_offset, destination, (usz)destination_offset, (usz)count, barrier))
	{
		*out = js.raise("the copy could not be recorded");
	}
}

<*
 `computeFill(buffer, byteOffset, byteCount, word, independent)` - a recorded
 fill with one 32-bit word. Offset and count are whole words.
*>
fn void js_compute_fill(
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

	StorageBuffer* buffer = storage_buffer(self, arg_int(&js, argc, args, 0), &js, out);
	if (buffer == null) return;

	long offset  = (long)arg_number(&js, argc, args, 1);
	long count   = (long)arg_number(&js, argc, args, 2);
	uint word    = (uint)(ulong)arg_number(&js, argc, args, 3);
	bool barrier = !(argc >= 5 && js.truth(args[4]));

	if (offset < 0 || count <= 0 || offset % 4 != 0 || count % 4 != 0 || (usz)(offset + count) > buffer.size)
	{
		*out = js.raise(string::tformat(
			"three.compute.fill of %d bytes at %d does not fit a buffer of %d, or is not in whole 4-byte words",
			count, offset, (long)buffer.size));
		return;
	}

	if (catch compute.fill(buffer, (usz)offset, (usz)count, word, barrier))
	{
		*out = js.raise("the fill could not be recorded");
	}
}

<*
 `computeBarrier()` - the barrier a run of `independent` commands skipped.
*>
fn void js_compute_barrier(
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
	compute.barrier();
}

<*
 `computeLimits()` - what this device lets a kernel do, so a script can choose
 between variants: a cooperative-matrix matmul or a tiled one, a subgroup
 reduction or a shared-memory one.
*>
fn void js_compute_limits(
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

	GpuLimits* limits = &self.renderer.gpu.limits;
	qjs::Value object = js.object();
	js.set_property(object, "device", js.string(((ZString)&limits.device_name).str_view()));
	js.set_property(object, "cooperativeMatrix", qjs::bool_value(limits.cooperative_matrix));
	js.set_property(object, "subgroupSize", qjs::number_value((double)limits.subgroup_size));
	js.set_property(object, "maxSharedMemory", qjs::number_value((double)limits.max_compute_shared_memory));
	js.set_property(object, "maxWorkgroupInvocations", qjs::number_value((double)limits.max_compute_workgroup_invocations));
	js.set_property(object, "maxBindingRange", qjs::number_value((double)limits.max_storage_buffer_range));
	js.set_property(object, "maxAllocation", qjs::number_value((double)limits.max_memory_allocation_size));
	js.set_property(object, "bindingAlignment", qjs::number_value((double)limits.min_storage_buffer_offset_alignment));
	js.set_property(object, "maxPushConstants", qjs::number_value((double)limits.max_push_constants_size));
	js.set_property(object, "maxBindings", qjs::number_value((double)COMPUTE_MAX_BINDINGS));

	// Storage images. The format list is the one question a script cannot answer
	// from the spec: the core thirteen are everywhere, and which of the rest a
	// device stores is a per-format answer the device alone has.
	qjs::Value formats = js.array();
	uint stored = 0;
	foreach (format : STORAGE_IMAGE_FORMATS)
	{
		if (!self.renderer.gpu.can_have_storage(format)) continue;
		js.set_index(formats, stored++, js.string(format.name));
	}
	js.set_property(object, "storageImageFormats", formats);
	js.set_property(object, "storageImageReadWithoutFormat", qjs::bool_value(limits.storage_image_read_without_format));
	js.set_property(object, "storageImageWriteWithoutFormat", qjs::bool_value(limits.storage_image_write_without_format));
	js.set_property(object, "maxStorageImages", qjs::number_value((double)limits.max_per_stage_storage_images));
	js.set_property(object, "maxImageSize", qjs::number_value((double)limits.max_image_dimension_2d));
	*out = object;
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
 `computeSubmitAsync()` - send what is recorded and return at once.

 The script then asks `computeBusy()` once a frame; see `Compute.submit_async`.
*>
fn void js_compute_submit_async(
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

	if (catch compute.submit_async()) *out = js.raise("the compute submission failed");
}

<*
 `computeBusy()` - whether the GPU is still running the last async submission.
*>
fn void js_compute_busy(
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

	bool? busy = compute.busy();
	if (catch busy)
	{
		*out = js.raise("the compute submission failed");
		return;
	}
	*out = qjs::bool_value(busy);
}

<*
 Free everything a run left behind.

 Called when a script run finishes rather than from a script, so a kernel a
 script made and forgot cannot keep a pipeline alive across runs. The script's
 buffers go with it: they were made by that run and nothing else can name them.
*>
fn void JsRuntime.release_compute(&self)
{
	flush_compute(self);

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


// --- Images ------------------------------------------------------------------

<*
 `computeCreateImage(width, height, format, nearest)` - an image a kernel
 writes, zeroed, answering a texture as `texture_value` builds one plus how it
 reads back: `[index, width, height, levels, components, store]`, where
 `store` names the typed array a readback fills (`'f32'`, `'u8'`, ...).

 A texture because it is one: a slot in `Assets.textures`, an index a material
 can be handed, a reference the context's handle holds and gives back on
 close - see `Gpu.create_storage_texture` for the one way it differs.
*>
fn void js_compute_create_image(
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

	if (runtime_compute(self, &js, out) == null) return;
	if (self.pass == null)
	{
		*out = js.raise("three.compute.image needs a scene's asset table and this context has none");
		return;
	}

	Gpu* gpu = &self.renderer.gpu;
	long width = (long)arg_number(&js, argc, args, 0);
	long height = (long)arg_number(&js, argc, args, 1);
	uint largest = gpu.limits.max_image_dimension_2d;
	if (width < 1 || height < 1 || width > largest || height > largest)
	{
		*out = js.raise(string::tformat(
			"three.compute.image wants a width and a height from 1 to %d, and was given %dx%d",
			largest, width, height));
		return;
	}

	@pool()
	{
		String name = arg_text(&js, argc, args, 2, tmem);
		StorageImageFormat? format = storage_format_named(name);
		if (catch format)
		{
			String hint = storage_format_hint(name);
			*out = js.raise(hint.len > 0
				? string::tformat("'%s' is not a storage image format - did you mean %s?", name, hint)
				: string::tformat("'%s' is not a storage image format - rgba16f, rgba8, r32f and r32ui are the "
					"common ones, and three.compute.limits.storageImageFormats lists this device's", name));
			return;
		}
		bool nearest = arg_truth_or(&js, argc, args, 3, false);

		Texture? made = gpu.create_storage_texture((uint)width, (uint)height, format, nearest);
		if (catch err = made)
		{
			*out = js.raise(err == STORAGE_FORMAT_UNSUPPORTED
				? string::tformat("this device cannot store to %s images%s", format.name,
					format.extended ? " - it is an extended format, and the device does not have them" : "")
				: string::tformat("could not create the %dx%d %s image: %s", width, height, format.name, err));
			return;
		}

		// Into the table only where a material could sample it: a float format
		// the device can sample. An r32ui image is still a texture - a kernel and a
		// readback reach it by index - and its row stays white.
		bool sampled = format.is_float() && gpu.can_sample(format.vk);
		int index = self.pass.assets.install_texture(gpu, made, write_table: sampled);

		qjs::Value fields = texture_value(self, &js, index, self.pass.assets.texture_at(index));
		js.set_index(fields, 4, qjs::int_value((int)format.read_components()));
		js.set_index(fields, 5, js.string(texel_store_name(format.store)));
		js.set_index(fields, 6, qjs::bool_value(sampled));
		*out = fields;
	};
}

<*
 The name of the typed array a readback of this store fills.
*>
fn String texel_store_name(TexelStore store) @local
{
	switch (store)
	{
		case F32:
		case F16: return "f32";
		case U8: return "u8";
		case S8: return "i8";
		case U16: return "u16";
		case S16: return "i16";
		case U32:
		case PACKED32: return "u32";
		case S32: return "i32";
	}
}

<*
 The storage image behind a texture index, or a raised error naming why not.
*>
fn Texture* compute_image(JsRuntime* self, qjs::Context* js, int index, String verb, qjs::Value* out) @local
{
	if (self.pass == null || !self.pass.assets.texture_alive(index))
	{
		*out = js.raise(string::tformat("%s: this image has been disposed", verb));
		return null;
	}
	Texture* image = self.pass.assets.texture_at(index);
	if (image.storage == FORMAT_UNDEFINED)
	{
		*out = js.raise(string::tformat("%s: this is an uploaded texture, not a three.compute.image", verb));
		return null;
	}
	return image;
}

<*
 `computeReadImage(index, into)` - the whole image, as numbers: `into` is the
 bytes of the typed array the prelude made for it, sized by the components and
 the store `computeCreateImage` answered with.
*>
fn void js_compute_read_image(
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
	Texture* image = compute_image(self, &js, arg_int(&js, argc, args, 0), "image.read()", out);
	if (image == null) return;

	char[] into = argc > 1 ? js.bytes(args[1]) : (char[]) { };
	sz need = image.storage_read_size();
	if (into.len < need)
	{
		*out = js.raise(string::tformat("image.read() needs %d bytes for this image and was given %d", need, into.len));
		return;
	}
	if (catch err = image.read_storage(compute, into))
	{
		*out = js.raise(string::tformat("image.read() could not copy the image back: %s", err));
	}
}

<*
 `computeWriteImage(index, bytes)` - the whole image, replaced: the same layout
 `computeReadImage` fills, so a readback written back is the image it was.
*>
fn void js_compute_write_image(
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
	Texture* image = compute_image(self, &js, arg_int(&js, argc, args, 0), "image.write()", out);
	if (image == null) return;

	char[] values = argc > 1 ? js.bytes(args[1]) : (char[]) { };
	sz need = image.storage_read_size();
	if (values.len < need)
	{
		*out = js.raise(string::tformat("image.write() needs %d bytes for this image and was given %d", need, values.len));
		return;
	}
	if (catch err = image.write_storage(compute, values))
	{
		*out = js.raise(string::tformat("image.write() could not upload the image: %s", err));
	}
}

<*
 `computeFreeImage(index)` - `textureDispose` for an image a kernel may still be
 writing: whatever the kernels owe runs first, so a recorded dispatch never
 names an image that is gone.
*>
fn void js_compute_free_image(
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

	int index = arg_int(&js, argc, args, 0);
	if (self.pass == null || !self.pass.assets.texture_alive(index)) return;
	flush_compute(self);
	Gpu* gpu = self.renderer == null ? null : &self.renderer.gpu;
	self.pass.assets.release_texture(gpu, index);
	self.drop_texture(index);
}

<*
 `computeKernelBindings(kernel)` - `[[name, kind, format], ...]` in binding
 order, `kind` one of `'buffer'`, `'image'` and `'texture'` and `format` the
 declared storage format's name or `''`.

 What lets the prelude bind `run({ field, histogram })` by the shader's own names
 and tell a script which binding wanted an image before the host has to.
*>
fn void js_compute_kernel_bindings(
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

	qjs::Value list = js.array();
	for (uint i = 0; i < kernel.binding_count; i++)
	{
		ComputeBindingInfo info = kernel.info[i];
		String kind = info.type == DESCRIPTOR_TYPE_STORAGE_IMAGE ? "image"
			: info.type == DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER ? "texture" : "buffer";
		String format = "";
		if (info.type == DESCRIPTOR_TYPE_STORAGE_IMAGE && info.storage_format != 0)
		{
			if (try declared = storage_format_of(info.storage_format)) format = declared.name;
		}
		qjs::Value row = js.array();
		js.set_index(row, 0, js.string(kernel.binding_names[i]));
		js.set_index(row, 1, js.string(kind));
		js.set_index(row, 2, js.string(format));
		js.set_index(list, i, row);
	}
	*out = list;
}
