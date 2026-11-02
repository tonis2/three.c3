<*
The `three.compute` verbs: buffers, kernels, dispatch, submit.

 ## What crosses

 Handles, not pointers. A script holds a `BufferHandle` or `KernelHandle` object
 carrying a slot index and a generation, and the host holds the buffer; a handle
 that has been disposed of is refused by name rather than read as whatever now
 sits in its slot. The generation is there for the same reason `NodeId` has one -
 a slot the script gave back and the host reused would otherwise be a live handle
 onto somebody else's data.

 Images are textures and cross as texture indices, like every other texture.

 ## What the prelude does

 The ergonomics: it turns a script's data into bytes, packs a push block out of
 an object, and converts a work-item count into workgroups. What reaches this
 file is already numbers, handles and typed arrays, the same split `bind_query.c3`
 draws - a host verb earns its keep by doing the thing JavaScript cannot.
*>
module three;

import std::collections::list;
import std::io::file;
import fastjs::js;
import fastjs::js::opt;

// A slot in one of the tables below, addressed by index and generation the way
// a `NodeId` is: the generation is what makes a freed handle distinguishable
// from a live one, and the pair survives the slot being handed out again.
struct ComputeHandle
{
	uint index;
	uint generation;
}

// A buffer or a kernel as a verb hands it to a script: a new handle object.
typedef BufferHandle = ComputeHandle;
typedef KernelHandle = ComputeHandle;

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

const String BUFFER_NOT_LIVE = "this buffer handle is not live - it was never made here, or it has been freed";
const String KERNEL_NOT_LIVE = "this kernel handle is not live - it was never made here, or it has been freed";

<*
 @return? js::THREW
*>
fn void? JsRuntime.bind_compute_verbs(&self, js::Value host)
{
	self.compute_buffer_class = self.js.class("BufferHandle")!;
	self.compute_kernel_class = self.js.class("KernelHandle")!;

	self.js.@bind(host, "computeCreateBuffer", &js_compute_create_buffer, self)!;
	self.js.@bind(host, "computeWriteBuffer", &js_compute_write_buffer, self)!;
	self.js.@bind(host, "computeReadBuffer", &js_compute_read_buffer, self)!;
	self.js.@bind(host, "computeFreeBuffer", &js_compute_free_buffer, self)!;
	self.js.@bind(host, "computeCreateKernel", &js_compute_create_kernel, self)!;
	self.js.@bind(host, "computeCreateKernelSpirv", &js_compute_create_kernel_spirv, self)!;
	self.js.@bind(host, "computeKernelThreads", &js_compute_kernel_threads, self)!;
	self.js.@bind(host, "computeSpirv", &js_compute_spirv, self)!;
	self.js.@bind(host, "computeFreeKernel", &js_compute_free_kernel, self)!;
	self.js.@bind(host, "computeDispatch", &js_compute_dispatch, self)!;
	self.js.@bind(host, "computeSubmit", &js_compute_submit, self)!;
	self.js.@bind(host, "computeSubmitAsync", &js_compute_submit_async, self)!;
	self.js.@bind(host, "computeBusy", &js_compute_busy, self)!;
	self.js.@bind(host, "computeCopy", &js_compute_copy, self)!;
	self.js.@bind(host, "computeFill", &js_compute_fill, self)!;
	self.js.@bind(host, "computeBarrier", &js_compute_barrier, self)!;
	self.js.@bind(host, "computeLimits", &js_compute_limits, self)!;
	self.js.@bind(host, "computeCreateImage", &js_compute_create_image, self)!;
	self.js.@bind(host, "computeReadImage", &js_compute_read_image, self)!;
	self.js.@bind(host, "computeWriteImage", &js_compute_write_image, self)!;
	self.js.@bind(host, "computeFreeImage", &js_compute_free_image, self)!;
	self.js.@bind(host, "computeKernelBindings", &js_compute_kernel_bindings, self)!;
}

// --- Handles -----------------------------------------------------------------

<*
 The live slot a handle names in the list `slots` points at, or null. Both slot types carry `live`
 and `generation`, and a handle kept past its `free()` names a moved generation.
*>
macro live_slot(slots, ComputeHandle handle)
{
	if (handle.index >= slots.len()) return null;
	var slot = &(*slots)[handle.index];
	return slot.live && slot.generation == handle.generation ? slot : null;
}

<*
 A free slot in `slots`, or a new one.

 The generation of a reused slot moves, so a handle a script kept past its
 `free()` cannot reach whatever was made in its place.
*>
macro uint free_slot_in(slots)
{
	foreach (i, &slot : *slots)
	{
		if (slot.live) continue;
		slot.generation++;
		return (uint)i;
	}
	slots.push({ .generation = 1 });
	return (uint)(slots.len() - 1);
}

fn uint storage_slot_for(JsRuntime* self) @local => free_slot_in(&self.storage_slots);

fn uint kernel_slot_for(JsRuntime* self) @local => free_slot_in(&self.kernel_slots);

<*
 @return? js::THREW
*>
fn js::Value? BufferHandle.to_js(&self, js::Engine* js)
{
	return js.instance(((JsRuntime*)js.user).compute_buffer_class, pack_id(self.index, self.generation));
}

<*
 @return? js::THREW
*>
fn js::Value? KernelHandle.to_js(&self, js::Engine* js)
{
	return js.instance(((JsRuntime*)js.user).compute_kernel_class, pack_id(self.index, self.generation));
}

// The live slot behind a buffer handle object, or null.
fn StorageSlot* JsRuntime.storage_slot_of(&self, js::Value handle)
{
	void* data = js::data_of(handle, self.compute_buffer_class);
	if (!data) return null;
	return live_slot(&self.storage_slots, unpack_id(data, ComputeHandle));
}

// A buffer handle argument, checked to be live.
struct StorageRef
{
	StorageSlot* slot;
}

<*
 @return? js::THREW
*>
fn void? StorageRef.from_js(&self, js::Call* c, int at)
{
	self.slot = ((JsRuntime*)c.js.user).storage_slot_of(c.get(at));
	if (!self.slot) return c.fail(BUFFER_NOT_LIVE)~;
}

// A kernel handle argument, checked to be live.
struct KernelRef
{
	KernelSlot* slot;
}

<*
 @return? js::THREW
*>
fn void? KernelRef.from_js(&self, js::Call* c, int at)
{
	JsRuntime* rt = c.js.user;
	void* data = js::data_of(c.get(at), rt.compute_kernel_class);
	if (data) self.slot = live_slot(&rt.kernel_slots, unpack_id(data, ComputeHandle));
	if (!self.slot) return c.fail(KERNEL_NOT_LIVE)~;
}

<*
 Hand a buffer the host made to the script, as a handle `three.compute.adopt`
 wraps.

 For an embedding program with data of its own to put on the GPU - a model's
 weights, streamed out of a mapped file - which it fills with `StorageBuffer`'s
 own verbs and then gives to JavaScript to bind, by returning the handle from a
 verb of its own. The runtime owns the buffer from here: `dispose()` or the end
 of the context frees it.

 @param [&inout] buffer : `Allocated with mem, created. Ownership moves to the runtime.`
 @return `The handle; a verb returning it gives the script a handle object.`
*>
fn BufferHandle JsRuntime.adopt_storage_buffer(&self, StorageBuffer* buffer)
{
	uint index = storage_slot_for(self);
	StorageSlot* slot = &self.storage_slots[index];
	slot.buffer = buffer;
	slot.live   = true;
	return { index, slot.generation };
}

<*
 The buffer behind a script's handle object, or null when it is not a live one.

 The host-side half of `adopt_storage_buffer`: a verb an embedding program adds
 takes a `ComputeBuffer`'s handle and writes into, or reads out of, the buffer
 behind it.
*>
fn StorageBuffer* JsRuntime.storage_buffer_of(&self, js::Value handle)
{
	StorageSlot* slot = self.storage_slot_of(handle);
	return slot == null ? null : slot.buffer;
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

<*
 @return? js::THREW
*>
fn Compute*? runtime_compute(JsRuntime* self) @local
{
	if (self.renderer == null) return self.js.fail("%s needs a GPU device and this context has none", "three.compute")~;
	return &self.renderer.compute;
}

// --- Buffers -----------------------------------------------------------------

<*
 `computeCreateBuffer(size, data)` - one storage buffer of `size` bytes.

 `data`, when given and not empty, is its first contents, so a script can make
 a buffer and fill it in one call without a staging copy it would have to size
 itself. Without it the buffer holds zeroes.

 @return? js::THREW
*>
fn BufferHandle? js_compute_create_buffer(JsRuntime* self, double size_number, char[] data)
{
	Compute* compute = runtime_compute(self)!;
	if (size_number <= 0) return self.js.fail("three.compute.buffer(size) wants a positive size in bytes")~;
	usz size = (usz)size_number;

	uint index = storage_slot_for(self);
	StorageSlot* slot = &self.storage_slots[index];

	@pool()
	{
		// The device copy reads the whole buffer, rounded up to whole words, from
		// the upload; anything shorter is padded with zeroes first.
		char[] upload = data;
		usz whole = (size + 3) / 4 * 4;
		if (upload.len > 0 && upload.len < whole)
		{
			upload = alloc::new_array(tmem, char, (sz)whole);
			upload[:data.len] = data[..];
		}

		StorageBuffer* buffer = alloc::new(mem, StorageBuffer);
		if (catch buffer.create(&self.renderer.gpu, size, upload.len > 0 ? upload.ptr : null))
		{
			alloc::free(mem, buffer);
			slot.live = false;
			return self.js.fail("three.compute.buffer could not allocate that buffer on this device")~;
		}

		// Zeroes, as a script expects of a buffer it has not written: the memory
		// may be a freed buffer's, and a kernel that accumulates into it would add to
		// that buffer's numbers. Recorded, so it costs nothing until the next submit.
		if (upload.len == 0) compute.clear(buffer);

		slot.buffer = buffer;
		slot.live   = true;
	};
	return { index, slot.generation };
}

<*
 `computeWriteBuffer(handle, data, at)` - stage the bytes of `data` into the
 buffer, starting at byte `at` (zero when left out).

 The write is submitted and waited for here, so a dispatch recorded afterwards
 reads the new bytes. That is the same rule `StorageBuffer.write` follows and
 the reason the verb does not hand back a "pending" flag: an upload that had
 not landed would be a wrong answer with no symptom.

 @return? js::THREW
*>
fn void? js_compute_write_buffer(JsRuntime* self, StorageRef ref, char[] data, double at_number)
{
	StorageBuffer* buffer = ref.slot.buffer;
	long at = (long)at_number;
	if (at < 0 || data.len == 0)
	{
		return self.js.fail("three.compute.write(handle, data, byteOffset) was given a negative offset or empty data")~;
	}

	Compute* compute = &self.renderer.compute;
	if (catch buffer.write(compute, (usz)at, data.ptr, data.len))
	{
		return self.js.fail("three.compute.write wanted %d bytes at %d and the buffer holds %d",
			(long)data.len, at, (long)buffer.size)~;
	}
}

<*
 `computeReadBuffer(handle, target, byteCount, at)` - fill a script's typed array
 with `byteCount` bytes of the buffer from byte `at` (zero when left out).

 `submit()` first: this is the verb that turns GPU state into an answer, and
 reading before the dispatch that wrote it has run would copy the buffer as it
 was. The wait is folded in here rather than left to the caller because a
 script that forgot it would get a wrong number rather than an error.

 @return? js::THREW
*>
fn void? js_compute_read_buffer(JsRuntime* self, StorageRef ref, char[] target, double count_number, double at_number)
{
	StorageBuffer* buffer = ref.slot.buffer;
	long count = (long)count_number;
	long at    = (long)at_number;
	if (at < 0) return self.js.fail("three.compute.read(handle, target, byteCount, at) was given a negative offset")~;
	if (count <= 0 || count > (long)target.len)
	{
		return self.js.fail("three.compute.read(handle, target, byteCount) wants a target at least as long as the count")~;
	}
	if ((usz)(count + at) > buffer.size)
	{
		return self.js.fail("three.compute.read wanted %d bytes at %d and the buffer holds %d",
			count, at, (long)buffer.size)~;
	}

	Compute* compute = &self.renderer.compute;
	if (catch compute.submit()) return self.js.fail("the compute submission failed before the readback")~;
	if (catch buffer.read(compute, (usz)at, target[:(usz)count]))
	{
		return self.js.fail("the compute readback could not copy those bytes out")~;
	}
}

fn void js_compute_free_buffer(JsRuntime* self, StorageRef ref)
{
	StorageSlot* slot = ref.slot;
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
 point with `@threads`, and whatever else it needs. A refused source answers an
 error carrying the compiler's own diagnostic, because that message has a line
 and a column in it and is the only thing that says what to fix.

 @return? js::THREW
*>
fn KernelHandle? js_compute_create_kernel(JsRuntime* self, String source, String name, String entry)
{
	runtime_compute(self)!;
	if (source.len == 0) return self.js.fail("three.compute.kernel(source) wants the shader source")~;
	if (name.len == 0) name = "kernel";
	// NUL-terminated: Vulkan takes the entry point's name as a C string.
	entry = entry.len == 0 ? "main" : entry.zstr_tcopy().str_view();

	ShaderModule shader = compile_compute_shader_cached(name, source);
	defer shader.free();

	if (!shader.ok)
	{
		// The kernel's name goes in front of the compiler's own message: the
		// diagnostic has the line, the column and the caret, and what it does
		// not have is which of a script's kernels it was.
		if (shader.diagnostic.len > 0) return self.js.fail("%s: %s", name, shader.diagnostic)~;
		return self.js.fail("%s did not compile", name)~;
	}

	return install_kernel(self, &shader, name, entry);
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

 @return? js::THREW
*>
fn KernelHandle? js_compute_create_kernel_spirv(JsRuntime* self, char[] bytes, String name, String entry)
{
	runtime_compute(self)!;
	if (bytes.len == 0) return self.js.fail("three.compute.kernel(module) wants the module's bytes")~;
	if (name.len == 0) name = "kernel";
	// NUL-terminated: Vulkan takes the entry point's name as a C string.
	entry = entry.len == 0 ? "main" : entry.zstr_tcopy().str_view();

	// Copied, because the module takes ownership of what it is given and these
	// bytes belong to the script.
	char[] owned = alloc::alloc_array(mem, char, bytes.len);
	mem::copy(owned.ptr, bytes.ptr, bytes.len);

	ShaderModule shader = three::adopt_spirv_module(name, owned, entry);
	defer shader.free();

	if (!shader.ok)
	{
		if (shader.diagnostic.len > 0) return self.js.fail("%s", shader.diagnostic)~;
		return self.js.fail("%s is not something this can dispatch", name)~;
	}

	return install_kernel(self, &shader, name, entry);
}

<*
 `computeKernelThreads(handle)` - the workgroup size, as `[x, y, z]`.

 The module wrote it down and the host keeps it: a script that wants to reason
 about a dispatch (how many groups a work-item count becomes, or what a
 dispatch cost) should not have to parse it back out of a shader, and a
 precompiled module has no source to parse.
*>
fn uint[<3>] js_compute_kernel_threads(JsRuntime* self, KernelRef ref)
{
	return { ref.slot.threads[0], ref.slot.threads[1], ref.slot.threads[2] };
}

<*
 `computeSpirv(path)` - a module read from disk, as a `Uint8Array`.

 The path is the script's to write and is resolved like every other file here,
 so `three.compute.spirv("../shaders/zimage.spv")` and a path from the command
 line are the same thing. What comes back is a copy the script owns: it can be
 handed to `kernel()` and kept for the next one.

 @return? js::THREW
*>
fn js::Value? js_compute_spirv(JsRuntime* self, String asked)
{
	if (asked.len == 0) return self.js.fail("three.compute.spirv(path) wants the module's path")~;

	char[]? bytes = file::load(tmem, asked);
	if (catch err = bytes) return self.js.fail("could not read %s: %s", asked, err)~;
	if (bytes.len < 4 || *(uint*)bytes.ptr != SPIRV_MAGIC)
	{
		return self.js.fail("%s is not a SPIR-V module - three.compute.spirv reads modules, and a shading source "
			"goes to three.compute.kernel as text",
			asked)~;
	}
	return self.js.typed_copy(UINT8, bytes);
}

<*
 The tail both creation paths share: a slot, a pipeline, and the handle a
 script holds.

 @return? js::THREW
*>
fn KernelHandle? install_kernel(JsRuntime* self, ShaderModule* shader, String name, String entry) @local
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
		slot.live = false;
		GpuLimits* limits = &self.renderer.gpu.limits;
		switch (err)
		{
			case COMPUTE_UNSUPPORTED_SUBGROUP_SIZE:
				return self.js.fail("%s is written for a subgroup of %d lanes, and this device %s",
					name, shader.subgroup_size, limits.subgroup_size_control
					? string::tformat("runs %d to %d", limits.min_subgroup_size, limits.max_subgroup_size)
					: "cannot be asked for a subgroup size")~;
			case COMPUTE_KERNEL_NO_ENTRY:
				return self.js.fail("%s has no compute entry point `%s`", name, entry)~;
			case COMPUTE_UNSUPPORTED_BINDING:
				return self.js.fail("%s binds something a kernel cannot: storage buffers, storage images (image2d<...>) and "
					"sampled textures (Sampler2D) are what a kernel takes, one per binding and all in set 0",
					name)~;
			case COMPUTE_IMAGE_FEATURE:
				return self.js.fail("%s declares a storage image this device cannot have: an extended format needs "
					"shaderStorageImageExtendedFormats, and an image2d<float4> whose format the host picks needs "
					"shaderStorageImage%sWithoutFormat - name the format, e.g. image2d<rgba16f>",
					name, limits.storage_image_read_without_format ? "Write" : "Read")~;
			case COMPUTE_TOO_MANY_IMAGES:
				return self.js.fail("%s declares more storage images than the %d this device binds per kernel",
					name, limits.max_per_stage_storage_images)~;
			case COMPUTE_NOT_READY:
				return self.js.fail("%s declares more than %d bindings - split it", name, COMPUTE_MAX_BINDINGS)~;
			default:
				return self.js.fail("%s could not be built: %s", name, err)~;
		}
	}

	// The module's own workgroup size, not a number from the script: `@threads`
	// is in the module and a work-item count is divided by it, so a disagreeing
	// value here would dispatch the wrong number of groups.
	if (shader.local_size[0] == 0)
	{
		kernel.free(self.renderer.gpu.handle);
		alloc::free(mem, kernel);
		slot.live = false;
		return self.js.fail("%s declares no compute workgroup size - a module whose size is an `OpExecutionModeId` "
			"cannot be dispatched by this host yet",
			name)~;
	}

	slot.kernel  = kernel;
	slot.live    = true;
	slot.threads = shader.local_size;
	return { index, slot.generation };
}

fn void js_compute_free_kernel(JsRuntime* self, KernelRef ref)
{
	KernelSlot* slot = ref.slot;
	flush_compute(self);
	slot.kernel.free(self.renderer.gpu.handle);
	alloc::free(mem, slot.kernel);
	slot.kernel = null;
	slot.live   = false;
}

// --- Dispatch ----------------------------------------------------------------

<*
 `computeDispatch(kernel, bindings, push, x, y, z, independent)` - record one
 dispatch.

 `bindings` is a plain Array in the shader's binding order: a buffer handle,
 `[handle, byteOffset, byteSize]` for a range of one (a size of zero runs to the
 end of the buffer), or a texture index for an image binding. `push` is the push
 block's bytes, or undefined. `x, y, z` are either a work-item count per axis -
 the usual case, split here by the entry point's own `@threads` - or, when `z`
 is positive, the group counts themselves, which is what a dispatch that wants
 exactly `(4, 1, 1)` says. `independent` skips the barrier after this dispatch,
 for a caller that knows the next command does not read it.

 @return? js::THREW
*>
fn void? js_compute_dispatch(JsRuntime* self, KernelRef ref, js::Value list, char[] push,
	double x, double y, double z, bool independent)
{
	KernelSlot* slot = ref.slot;
	ComputeKernel* kernel = slot.kernel;
	Compute* compute = &self.renderer.compute;

	// The length is checked against the kernel's own count, so a script that
	// forgot one is told which one it forgot rather than dispatching against a
	// stale binding.
	long given = self.js.length(list)!;
	if (given < 0) given = 0;
	if ((uint)given != kernel.binding_count)
	{
		return self.js.fail("this kernel binds %d buffers and images and %d were given - they go in the shader's own order",
			(int)kernel.binding_count, given)~;
	}

	ComputeBinding[COMPUTE_MAX_BINDINGS] views;
	ulong alignment = self.renderer.gpu.limits.min_storage_buffer_offset_alignment;
	if (alignment == 0) alignment = 1;
	for (int i = 0; i < given; i++)
	{
		js::Value element = self.js.get(list, i)!;

		// An image binding is a texture index - the prelude checked it is an
		// image rather than a buffer, and this checks it is still there and is
		// the image the shader declared.
		ComputeBindingInfo* info = &kernel.info[i];
		if (info.is_image())
		{
			int index = (int)self.js.number(element)!;
			if (self.pass == null || !self.pass.assets.texture_alive(index))
			{
				return self.js.fail("binding %d (%s) is an image that has been disposed", i, kernel.binding_names[i])~;
			}
			Texture* image = self.pass.assets.texture_at(index);
			String wrong = storage_image_mismatch(&self.renderer.gpu, info, image);
			if (wrong.len > 0)
			{
				return self.js.fail("binding %d (%s) cannot take this image: %s", i, kernel.binding_names[i], wrong)~;
			}
			views[i] = { .image = image };
			continue;
		}

		js::Value handle = element;
		long offset = 0;
		long size   = 0;
		if (!js::data_of(element, self.compute_buffer_class) && self.js.length(element)! >= 2)
		{
			handle = self.js.get(element, 0)!;
			offset = (long)self.js.get_number(element, 1)!;
			size   = (long)self.js.get_number(element, 2)!;
		}

		StorageBuffer* buffer = self.storage_buffer_of(handle);
		if (buffer == null) return self.js.fail(BUFFER_NOT_LIVE)~;
		if (offset < 0 || size < 0 || (usz)(offset + size) > buffer.size || (usz)offset >= buffer.size)
		{
			return self.js.fail("binding %d (%s) asks for %d bytes at %d of a buffer of %d",
				i, kernel.binding_names[i], size, offset, (long)buffer.size)~;
		}
		if ((ulong)offset % alignment != 0)
		{
			return self.js.fail("binding %d (%s) starts at byte %d, and this device binds at multiples of %d",
				i, kernel.binding_names[i], offset, (long)alignment)~;
		}
		views[i] = { .buffer = buffer.view((usz)offset, (usz)size) };
	}

	if (push.len > 0 && push.len < kernel.push_size)
	{
		return self.js.fail("this kernel's push block is %d bytes and %d were given", (int)kernel.push_size, (int)push.len)~;
	}

	uint groups_x = 1;
	uint groups_y = 1;
	uint groups_z = 1;
	if (z > 0)
	{
		groups_x = (uint)x;
		groups_y = (uint)y;
		groups_z = (uint)z;
	}
	else
	{
		ulong items_x = (ulong)x;
		ulong items_y = (ulong)y;
		if (items_x > 0) groups_x = (uint)((items_x + slot.threads[0] - 1) / slot.threads[0]);
		if (items_y > 0) groups_y = (uint)((items_y + slot.threads[1] - 1) / slot.threads[1]);
	}
	if (groups_x == 0) groups_x = 1;
	if (groups_y == 0) groups_y = 1;
	if (groups_z == 0) groups_z = 1;

	if (catch compute.dispatch_bindings(kernel, views[:kernel.binding_count],
		push.len > 0 ? push.ptr : null, groups_x, groups_y, groups_z, !independent))
	{
		return self.js.fail("the dispatch could not be recorded")~;
	}
}

<*
 `computeCopy(source, sourceOffset, destination, destinationOffset, byteCount,
 independent)` - a GPU-side copy, recorded in order with the dispatches.

 @return? js::THREW
*>
fn void? js_compute_copy(JsRuntime* self, StorageRef from, double source_at, StorageRef to,
	double destination_at, double count_number, bool independent)
{
	Compute* compute = runtime_compute(self)!;
	StorageBuffer* source = from.slot.buffer;
	StorageBuffer* destination = to.slot.buffer;
	long source_offset      = (long)source_at;
	long destination_offset = (long)destination_at;
	long count              = (long)count_number;

	if (source_offset < 0 || destination_offset < 0 || count <= 0
		|| (usz)(source_offset + count) > source.size
		|| (usz)(destination_offset + count) > destination.size)
	{
		return self.js.fail("three.compute.copy of %d bytes from %d (of %d) to %d (of %d) does not fit",
			count, source_offset, (long)source.size, destination_offset, (long)destination.size)~;
	}

	if (catch compute.copy(source, (usz)source_offset, destination, (usz)destination_offset, (usz)count, !independent))
	{
		return self.js.fail("the copy could not be recorded")~;
	}
}

<*
 `computeFill(buffer, byteOffset, byteCount, word, independent)` - a recorded
 fill with one 32-bit word. Offset and count are whole words.

 @return? js::THREW
*>
fn void? js_compute_fill(JsRuntime* self, StorageRef ref, double offset_number, double count_number,
	uint word, bool independent)
{
	Compute* compute = runtime_compute(self)!;
	StorageBuffer* buffer = ref.slot.buffer;
	long offset = (long)offset_number;
	long count  = (long)count_number;

	if (offset < 0 || count <= 0 || offset % 4 != 0 || count % 4 != 0 || (usz)(offset + count) > buffer.size)
	{
		return self.js.fail("three.compute.fill of %d bytes at %d does not fit a buffer of %d, or is not in whole 4-byte words",
			count, offset, (long)buffer.size)~;
	}

	if (catch compute.fill(buffer, (usz)offset, (usz)count, word, !independent))
	{
		return self.js.fail("the fill could not be recorded")~;
	}
}

<*
 `computeBarrier()` - the barrier a run of `independent` commands skipped.

 @return? js::THREW
*>
fn void? js_compute_barrier(JsRuntime* self)
{
	runtime_compute(self)!.barrier();
}

<*
 What this device lets a kernel do, so a script can choose between variants: a
 cooperative-matrix matmul or a tiled one, a subgroup reduction or a
 shared-memory one.
*>
struct ComputeLimitsInfo
{
	String device;
	bool cooperative_matrix;
	uint subgroup_size;
	uint max_shared_memory;
	uint max_workgroup_invocations;
	uint max_binding_range;
	ulong max_allocation;
	ulong binding_alignment;
	uint max_push_constants;
	uint max_bindings;
	// The one question a script cannot answer from the spec: the core thirteen
	// are everywhere, and which of the rest a device stores is a per-format
	// answer the device alone has.
	js::Value storage_image_formats;
	bool storage_image_read_without_format;
	bool storage_image_write_without_format;
	uint max_storage_images;
	uint max_image_size;
}

<*
 `computeLimits()` - see `ComputeLimitsInfo`.

 @return? js::THREW
*>
fn ComputeLimitsInfo? js_compute_limits(JsRuntime* self)
{
	runtime_compute(self)!;
	GpuLimits* limits = &self.renderer.gpu.limits;

	js::Value formats = self.js.array()!;
	foreach (format : STORAGE_IMAGE_FORMATS)
	{
		if (!self.renderer.gpu.can_have_storage(format)) continue;
		self.js.push(formats, self.js.string(format.name)!);
	}

	return {
		.device = ((ZString)&limits.device_name).str_view(),
		.cooperative_matrix = limits.cooperative_matrix,
		.subgroup_size = limits.subgroup_size,
		.max_shared_memory = limits.max_compute_shared_memory,
		.max_workgroup_invocations = limits.max_compute_workgroup_invocations,
		.max_binding_range = limits.max_storage_buffer_range,
		.max_allocation = limits.max_memory_allocation_size,
		.binding_alignment = limits.min_storage_buffer_offset_alignment,
		.max_push_constants = limits.max_push_constants_size,
		.max_bindings = COMPUTE_MAX_BINDINGS,
		.storage_image_formats = formats,
		.storage_image_read_without_format = limits.storage_image_read_without_format,
		.storage_image_write_without_format = limits.storage_image_write_without_format,
		.max_storage_images = limits.max_per_stage_storage_images,
		.max_image_size = limits.max_image_dimension_2d,
	};
}

<*
 `computeSubmit()` - record, submit, wait.

 The boundary a script draws itself: it is one wait, and it is also where a
 long chain is cut so that no single submission outlives a driver's patience.

 @return? js::THREW
*>
fn void? js_compute_submit(JsRuntime* self)
{
	Compute* compute = runtime_compute(self)!;
	if (catch compute.submit()) return self.js.fail("the compute submission failed")~;
}

<*
 `computeSubmitAsync()` - send what is recorded and return at once.

 The script then asks `computeBusy()` once a frame; see `Compute.submit_async`.

 @return? js::THREW
*>
fn void? js_compute_submit_async(JsRuntime* self)
{
	Compute* compute = runtime_compute(self)!;
	if (catch compute.submit_async()) return self.js.fail("the compute submission failed")~;
}

<*
 `computeBusy()` - whether the GPU is still running the last async submission.

 @return? js::THREW
*>
fn bool? js_compute_busy(JsRuntime* self)
{
	Compute* compute = runtime_compute(self)!;
	bool? busy = compute.busy();
	if (catch busy) return self.js.fail("the compute submission failed")~;
	return busy;
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
 A new storage image: the texture fields every texture has, and how it reads
 back - `store` names the typed array a readback fills (`'f32'`, `'u8'`, ...).
*>
struct ComputeImageInfo
{
	int index;
	uint width;
	uint height;
	uint levels;
	uint components;
	String store;
	bool sampled;
}

<*
 `computeCreateImage(width, height, format, nearest)` - an image a kernel
 writes, zeroed.

 A texture because it is one: a slot in `Assets.textures`, an index a material
 can be handed, a reference the context's handle holds and gives back on
 close - see `Gpu.create_storage_texture` for the one way it differs.

 @return? js::THREW
*>
fn ComputeImageInfo? js_compute_create_image(JsRuntime* self, long width, long height, String name, Opt {bool} nearest)
{
	runtime_compute(self)!;
	if (self.pass == null) return self.js.fail("three.compute.image needs a scene's asset table and this context has none")~;

	Gpu* gpu = &self.renderer.gpu;
	uint largest = gpu.limits.max_image_dimension_2d;
	if (width < 1 || height < 1 || width > largest || height > largest)
	{
		return self.js.fail("three.compute.image wants a width and a height from 1 to %d, and was given %dx%d",
			largest, width, height)~;
	}

	StorageImageFormat? format = storage_format_named(name);
	if (catch format)
	{
		String hint = storage_format_hint(name);
		if (hint.len > 0) return self.js.fail("'%s' is not a storage image format - did you mean %s?", name, hint)~;
		return self.js.fail("'%s' is not a storage image format - rgba16f, rgba8, r32f and r32ui are the "
			"common ones, and three.compute.limits.storageImageFormats lists this device's", name)~;
	}

	Texture? made = gpu.create_storage_texture((uint)width, (uint)height, format, nearest.or(false));
	if (catch err = made)
	{
		if (err == STORAGE_FORMAT_UNSUPPORTED)
		{
			return self.js.fail("this device cannot store to %s images%s", format.name,
				format.extended ? " - it is an extended format, and the device does not have them" : "")~;
		}
		return self.js.fail("could not create the %dx%d %s image: %s", width, height, format.name, err)~;
	}

	// Into the table only where a material could sample it: a float format
	// the device can sample. An r32ui image is still a texture - a kernel and a
	// readback reach it by index - and its row stays white.
	bool sampled = format.is_float() && gpu.can_sample(format.vk);
	int index = self.pass.assets.install_texture(gpu, made, write_table: sampled);
	Texture* image = self.pass.assets.texture_at(index);
	// The script's reference, counted the way `texture_value` counts one.
	self.hold_texture(index);

	return {
		.index = index,
		.width = image.width,
		.height = image.height,
		.levels = image.levels,
		.components = format.read_components(),
		.store = texel_store_name(format.store),
		.sampled = sampled,
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
 The storage image behind a texture index, or a thrown error naming why not.

 @return? js::THREW
*>
fn Texture*? compute_image(JsRuntime* self, int index, String verb) @local
{
	if (self.pass == null || !self.pass.assets.texture_alive(index))
	{
		return self.js.fail("%s: this image has been disposed", verb)~;
	}
	Texture* image = self.pass.assets.texture_at(index);
	if (image.storage == FORMAT_UNDEFINED)
	{
		return self.js.fail("%s: this is an uploaded texture, not a three.compute.image", verb)~;
	}
	return image;
}

<*
 `computeReadImage(index, into)` - the whole image, as numbers: `into` is the
 typed array the prelude made for it, sized by the components and the store
 `computeCreateImage` answered with.

 @return? js::THREW
*>
fn void? js_compute_read_image(JsRuntime* self, int index, char[] into)
{
	Compute* compute = runtime_compute(self)!;
	Texture* image = compute_image(self, index, "image.read()")!;

	sz need = image.storage_read_size();
	if (into.len < need)
	{
		return self.js.fail("image.read() needs %d bytes for this image and was given %d", need, into.len)~;
	}
	if (catch err = image.read_storage(compute, into))
	{
		return self.js.fail("image.read() could not copy the image back: %s", err)~;
	}
}

<*
 `computeWriteImage(index, values)` - the whole image, replaced: the same layout
 `computeReadImage` fills, so a readback written back is the image it was.

 @return? js::THREW
*>
fn void? js_compute_write_image(JsRuntime* self, int index, char[] values)
{
	Compute* compute = runtime_compute(self)!;
	Texture* image = compute_image(self, index, "image.write()")!;

	sz need = image.storage_read_size();
	if (values.len < need)
	{
		return self.js.fail("image.write() needs %d bytes for this image and was given %d", need, values.len)~;
	}
	if (catch err = image.write_storage(compute, values))
	{
		return self.js.fail("image.write() could not upload the image: %s", err)~;
	}
}

<*
 `computeFreeImage(index)` - `textureDispose` for an image a kernel may still be
 writing: whatever the kernels owe runs first, so a recorded dispatch never
 names an image that is gone.
*>
fn void js_compute_free_image(JsRuntime* self, int index)
{
	if (self.pass == null || !self.pass.assets.texture_alive(index)) return;
	flush_compute(self);
	Gpu* gpu = self.renderer == null ? null : &self.renderer.gpu;
	self.pass.assets.release_texture(gpu, index);
	self.drop_texture(index);
}

<*
 One binding as the shader declares it: `kind` is `'buffer'`, `'image'` or
 `'texture'`, and `format` the declared storage format's name or `''`.
*>
struct KernelBindingInfo
{
	String name;
	String kind;
	String format;
}

<*
 `computeKernelBindings(kernel)` - `[{ name, kind, format }, ...]` in binding order.

 What lets the prelude bind `run({ field, histogram })` by the shader's own names
 and tell a script which binding wanted an image before the host has to.

 @return? js::THREW
*>
fn js::Value? js_compute_kernel_bindings(JsRuntime* self, KernelRef ref)
{
	ComputeKernel* kernel = ref.slot.kernel;
	js::Value list = self.js.array(kernel.binding_count)!;
	for (uint i = 0; i < kernel.binding_count; i++)
	{
		ComputeBindingInfo info = kernel.info[i];
		KernelBindingInfo row = {
			.name = kernel.binding_names[i],
			.kind = info.type == DESCRIPTOR_TYPE_STORAGE_IMAGE ? "image"
				: info.type == DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER ? "texture" : "buffer",
		};
		if (info.type == DESCRIPTOR_TYPE_STORAGE_IMAGE && info.storage_format != 0)
		{
			if (try declared = storage_format_of(info.storage_format)) row.format = declared.name;
		}
		self.js.push(list, self.js.@object_of(row)!);
	}
	return list;
}
