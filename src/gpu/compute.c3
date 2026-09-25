<*
Compute, as a thing a script can hold: buffers, kernels, and the dispatches
between them.

 ## What this is for

 Everything here is one level below the frame. A draw is a pipeline plus the
 scene state that fills its push block; a dispatch is a pipeline plus a few
 buffers, and the work it does is whatever the shader says - a reduction, a
 matmul, a solver step, a noise bake. None of that has a picture to draw, so
 none of it belongs in `MeshPass`, and none of it wants to be recorded into
 somebody else's frame either.

 So a `Compute` is its own command buffer, its own fence and its own queue
 submissions. `submit()` records, submits and waits; between two `submit()`
 calls a script may record as many dispatches as it likes and the GPU sees one
 submission. That is the shape a compute workload has - long chains, occasional
 boundaries - and the reason the boundary is explicit is that it is also the
 safety valve: a command buffer that takes longer than the driver's watchdog
 timeout is a lost device, and only the caller knows where the work can be cut.

 ## Buffers

 A `StorageBuffer` is device-local, because the thing this exists for is holding
 data too large to want a host mapping: weights, activations, a field. Both
 directions of transfer are allowed, so `write` stages through a host-visible
 copy and `read` the same, and neither is on a path a frame calls.

 ## Push descriptors

 Kernels use `VK_DESCRIPTOR_SET_LAYOUT_CREATE_PUSH_DESCRIPTOR_BIT` and bind
 their storage buffers with `vkCmdPushDescriptorSetKHR`, the same way
 `MeshPass` binds a material's samplers. A dispatch is then a bind and a push -
 no pool, no allocated set, and no ownership question about who frees a set
 whose buffers are a script's to free.
*>
module three;

import vk;
import std::collections::list;

faultdef COMPUTE_NOT_READY, COMPUTE_KERNEL_NO_ENTRY, COMPUTE_UNSUPPORTED_BINDING;

// How many storage buffers one dispatch may bind. Vulkan's guaranteed minimum
// for `maxPerStageDescriptorStorageBuffers` is 4; the drivers this runs on
// report far more, and a kernel that wants more than this is a kernel to split.
const uint COMPUTE_MAX_BINDINGS = 8;

// The largest host-visible staging copy a write or read makes at once. A
// transfer bigger than this goes through the same staging buffer in pieces.
const usz COMPUTE_STAGING_CHUNK = 64 * 1024 * 1024;

<*
 One buffer the GPU reads or writes, with the size it was made at.

 Device-local and both-directions: a storage buffer that could not be read back
 would make every kernel's result unobservable, and one that could not be
 written would make a weights buffer impossible to fill.
*>
struct StorageBuffer
{
	vk::Memory memory;
	usz       size;
}

fn void StorageBuffer.free(&self)
{
	if (self.memory.page != null) self.memory.free();
	*self = { };
}

<*
 A range of one buffer, as a binding sees it: a KV cache's layer, one half of a
 CFG pair, the slice of a packed weights pool a kernel reads.

 A size of zero is "to the end of the buffer", which is what a whole-buffer
 binding means and what `StorageBuffer.view` makes.
*>
struct BufferView
{
	StorageBuffer* buffer;
	usz            offset;
	usz            size;
}

fn BufferView StorageBuffer.view(&self, usz offset = 0, usz size = 0)
{
	return { .buffer = self, .offset = offset, .size = size };
}

fn usz BufferView.range(&self) => self.size == 0 ? self.buffer.size - self.offset : self.size;

<*
 A compiled kernel: the pipeline, the layout of its descriptors, and what to
 bind where.

 `bindings` is per kernel rather than per dispatch because it cannot vary:
 the layout is baked into the pipeline at creation, and a kernel is created for
 one shader with one set of buffer types. `dispatch` checks the count and takes
 the buffers in that order.
*>
struct ComputeKernel
{
	vk::Pipeline       pipeline;
	vk::PipelineLayout layout;
	String             name;
	// Names as the shader declares them, in `binding` order, for the error a
	// caller gets when it hands over the wrong buffer.
	List{String} binding_names;
	uint               binding_count;
	// The push block's size, from the module. Kept here because a pipeline
	// layout is write-only - Vulkan has no query for the ranges it was built
	// with - and a push of the wrong size is a misspelled constant rather than
	// a failed call.
	uint               push_size;
}

fn void ComputeKernel.free(&self, vk::Device device)
{
	if (self.pipeline != null) self.pipeline.free(device);
	if (self.layout != null) self.layout.free(device);
	if (self.name.ptr != null) self.name.free(mem);
	foreach (name : self.binding_names) if (name.ptr != null) name.free(mem);
	self.binding_names.free();
	*self = { };
}

<*
 The compute half of the GPU: everything a dispatch needs that a frame does not.

 One command buffer, opened on `init` and re-opened after every `submit`, so a
 sequence of dispatches recorded between two submits is one submission.
*>
struct Compute
{
	Gpu*             gpu;
	vk::CommandPool  pool;
	vk::CommandBuffer cmd;
	vk::Fence        fence;
	List{ComputeKernel} kernels;
	bool             recording;
	// Commands recorded since the last submit. What lets a host-side copy - a
	// `write`, a `read` - know whether the GPU still owes it work that was
	// recorded first, and what lets an empty `submit` cost nothing.
	uint             pending;
}

fn void? Compute.init(&self, Gpu* gpu)
{
	if (!gpu.limits.push_descriptor) return COMPUTE_NOT_READY~;

	self.gpu = gpu;
	self.pool = gpu.handle.createCommandPool(queue: gpu.graphics.index)!;

	vk::CommandBufferList allocated = gpu.handle.createCommandBuffers(self.pool, count: 1)!;
	self.cmd = allocated[0];
	allocated.free();

	self.fence = vk::fenceCreateInfo().setFlags(FENCE_CREATE_SIGNALED_BIT).build(gpu.handle)!;
	self.kernels.init(mem, 8);

	vk::beginCommandBuffer(self.cmd, &&vk::commandBufferBeginInfo())!;
	self.recording = true;
	return;
}

fn void Compute.free(&self)
{
	self.submit()!!;
	foreach (kernel : self.kernels) kernel.free(self.gpu.handle);
	self.kernels.free();
	if (self.fence != null) vk::destroyFence(self.gpu.handle, self.fence, null);
	if (self.pool != null) self.pool.free(self.gpu.handle);
	*self = { };
}

// --- Buffers -----------------------------------------------------------------

<*
 A device-local buffer of `size` bytes.

 `data` may be null, and the usual case is that it is: a kernel's output buffer
 has no host-side shape until the kernel has written it. Its contents are then
 whatever the memory held before - `Compute.clear` is the zero fill, recorded
 rather than uploaded.

 The upload path is `vk::new_buffer`'s: when data is given, it stages the copy
 through a host-visible buffer and waits, which is worth it for a weights
 upload and irrelevant for a scratch buffer.
*>
fn void? StorageBuffer.create(&self, Gpu* gpu, usz size, void* data = null)
{
	self.size = size;
	self.memory = vk::new_buffer(
		&gpu.allocator,
		usage: BUFFER_USAGE_STORAGE_BUFFER_BIT
			| BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT
			| BUFFER_USAGE_TRANSFER_SRC_BIT
			| BUFFER_USAGE_TRANSFER_DST_BIT,
		properties: MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
		data: data,
		// Whole words, so a fill of the whole buffer reaches its last byte:
		// `cmdFillBuffer` writes words, and leaves a trailing part-word alone.
		data_size: (sz)((size + 3) / 4 * 4),
	)!;
	return;
}

<*
 Replace `size` bytes at `offset` with `data`.

 Staged, so it costs a submission; a script filling a megabyte of weights in
 one call pays for one, and a script filling an element at a time would pay for
 one per element. The JS layer is where that shape is decided - see
 `bind_compute.c3` - and this is the one-copy primitive underneath it.
*>
fn void? StorageBuffer.write(&self, Compute* compute, usz offset, void* data, usz size)
{
	if (offset + size > self.size) return COMPUTE_NOT_READY~;
	if (size == 0) return;

	// The copy below goes out on its own submission, so anything recorded before
	// it has to reach the GPU first: a dispatch that reads this buffer, recorded
	// and not yet submitted, would otherwise run after the new bytes landed.
	if (compute.pending > 0) compute.submit()!;

	// In pieces, through one staging buffer: a weights upload is gigabytes, and a
	// host-visible copy of all of it at once is a second copy of the model.
	usz chunk = size < COMPUTE_STAGING_CHUNK ? size : COMPUTE_STAGING_CHUNK;
	vk::Memory stage = vk::new_buffer(
		&compute.gpu.allocator,
		usage: BUFFER_USAGE_TRANSFER_SRC_BIT,
		properties: MEMORY_PROPERTY_HOST_VISIBLE_BIT | MEMORY_PROPERTY_HOST_COHERENT_BIT,
		data: null,
		data_size: (sz)chunk,
	)!;
	defer stage.free();

	for (usz done = 0; done < size; done += chunk)
	{
		usz part = chunk < size - done ? chunk : size - done;
		mem::copy(stage.data(), &((char*)data)[done], (sz)part);
		compute.gpu.handle.@single_time_command(queue: compute.gpu.graphics; vk::CommandBuffer cmd)
		{
			vk::cmdCopyBuffer(cmd, stage.buffer, self.memory.buffer, 1, (vk::BufferCopy[]){
				{ .srcOffset = 0, .dstOffset = (vk::DeviceSize)(offset + done), .size = (vk::DeviceSize)part }
			});
		}!;
	}
	return;
}

// --- Kernels -----------------------------------------------------------------

<*
 Build a kernel from a compiled module.

 The module comes from the caller rather than from a file, because what a
 compute kernel's source is - a script's text, a shipped `.shady`, a body a
 host spliced - is the JS layer's question and not this one's.

 @param shader : `The compiled module to take the pipeline and the bindings from.`
 @param entry : `Which compute entry point in it to build the pipeline for.`
 @return ? COMPUTE_KERNEL_NO_ENTRY : `The module has no such compute entry.`
 @return ? COMPUTE_UNSUPPORTED_BINDING : `The shader binds something other than storage buffers.`
 @return ? COMPUTE_NOT_READY : `More storage buffers than COMPUTE_MAX_BINDINGS.`
*>
fn void? ComputeKernel.create(&self, Compute* compute, ShaderModule* shader, String name, String entry = "main")
{
	Gpu* gpu = compute.gpu;

	bool entry_found = false;
	foreach (candidate : shader.entries)
	{
		if (candidate.stage == STAGE_COMPUTE && candidate.name == entry) entry_found = true;
	}
	if (!entry_found) return COMPUTE_KERNEL_NO_ENTRY~;

	// The layout the module says it wants, in binding order. Set 0 only: a
	// compute script declares buffers and nothing else, so a set it never
	// mentioned would be a binding no dispatch could fill.
	uint count = 0;
	foreach (binding : shader.layout.bindings)
	{
		if (binding.type != DESCRIPTOR_TYPE_STORAGE_BUFFER) return COMPUTE_UNSUPPORTED_BINDING~;
		if (binding.set != 0) return COMPUTE_UNSUPPORTED_BINDING~;
		if (binding.binding + 1 > count) count = binding.binding + 1;
	}
	if (count == 0) return COMPUTE_UNSUPPORTED_BINDING~;
	if (count > COMPUTE_MAX_BINDINGS) return COMPUTE_NOT_READY~;

	self.name = name.copy(mem);
	self.binding_names.init(mem, count);
	self.binding_count = count;

	// By binding number, not by declaration order: the two agree for anything
	// shady emits, and if they ever stopped agreeing the name a caller is told
	// would be the wrong one.
	for (uint i = 0; i < count; i++)
	{
		String found = "";
		foreach (binding : shader.layout.bindings)
		{
			if (binding.binding == i) found = binding.name;
		}
		self.binding_names.push(found.copy(mem));
	}

	vk::DescriptorSetLayoutBinding[COMPUTE_MAX_BINDINGS] vk_bindings;
	for (uint i = 0; i < count; i++)
	{
		vk_bindings[i] = {
			.binding = i,
			.descriptorType = DESCRIPTOR_TYPE_STORAGE_BUFFER,
			.descriptorCount = 1,
			.stageFlags = SHADER_STAGE_COMPUTE_BIT,
		};
	}

	vk::DescriptorSetLayout desc_layout = vk::descriptorSetLayoutCreateInfo()
		.setFlags(DESCRIPTOR_SET_LAYOUT_CREATE_PUSH_DESCRIPTOR_BIT)
		.setBindings(vk_bindings[0..count - 1])
		.build(gpu.handle)!;
	defer desc_layout.free(gpu.handle);

	vk::PushConstantRange range = {
		.stageFlags = SHADER_STAGE_COMPUTE_BIT,
		.offset = 0,
		.size = shader.layout.push_size,
	};
	self.push_size = shader.layout.push_size;

	self.layout = range.size > 0
		? vk::pipelineLayoutCreateInfo().setSetLayouts({ desc_layout }).setPushConstantRanges({ range }).build(gpu.handle)!
		: vk::pipelineLayoutCreateInfo().setSetLayouts({ desc_layout }).build(gpu.handle)!;

	vk::ShaderModule shader_module = vk::loadShaderModule(gpu.handle, shader.spirv)!;
	defer shader_module.free(gpu.handle);

	vk::ComputePipelineCreateInfo info = vk::computePipelineCreateInfo()
		.setStage(vk::pipelineShaderStageCreateInfo()
			.setStage(SHADER_STAGE_COMPUTE_BIT)
			.setMod(shader_module)
			.setName(entry))
		.setLayout(self.layout);

	vk::createComputePipelines(gpu.handle, gpu.driver_cache.handle, 1, &info, null, &self.pipeline)!;
	return;
}

// --- Dispatch ----------------------------------------------------------------

<*
 Record one dispatch.

 The buffers are bound in the shader's own binding order and the push constants
 are written whole, which is the same contract every other dispatch in this
 project has: the C3 struct on one side, the block on the other, one set of
 bytes.

 A barrier is inserted after every dispatch, so a chain of kernels that reads
 what the one before it wrote is correct without the caller saying anything.
 The cost is one barrier on pairs that did not need one - the alternative is a
 caller who has to know which of its kernels alias, and a wrong answer there is
 a wrong number rather than an error.
*>
fn void? Compute.dispatch(&self, ComputeKernel* kernel, StorageBuffer[] buffers, void* push_constants,
	uint groups_x, uint groups_y = 1, uint groups_z = 1)
{
	if (buffers.len < kernel.binding_count) return COMPUTE_NOT_READY~;
	BufferView[COMPUTE_MAX_BINDINGS] views;
	for (uint i = 0; i < kernel.binding_count; i++) views[i] = buffers[i].view();
	return self.dispatch_views(kernel, views[:kernel.binding_count], push_constants, groups_x, groups_y, groups_z);
}

<*
 `dispatch`, over ranges of buffers rather than whole ones.

 `barrier` false is the caller saying the next command does not read what this
 one writes - the Q, K and V projections of one layer, three matmuls over the
 same input - so the GPU may overlap them. The barrier then comes from whichever
 command after them does ask for one, and it covers all of them.

 Each view's offset has to be a multiple of the device's
 `minStorageBufferOffsetAlignment`. The caller checks that, because the caller
 knows which binding it was and can say so.
*>
fn void? Compute.dispatch_views(&self, ComputeKernel* kernel, BufferView[] views, void* push_constants,
	uint groups_x, uint groups_y = 1, uint groups_z = 1, bool barrier = true)
{
	if (views.len < kernel.binding_count) return COMPUTE_NOT_READY~;

	vk::cmdBindPipeline(self.cmd, vk::PipelineBindPoint.PIPELINE_BIND_POINT_COMPUTE, kernel.pipeline);

	vk::DescriptorBufferInfo[COMPUTE_MAX_BINDINGS] infos;
	vk::WriteDescriptorSet[COMPUTE_MAX_BINDINGS]   writes;
	for (uint i = 0; i < kernel.binding_count; i++)
	{
		BufferView view = views[i];
		if (view.offset + view.range() > view.buffer.size) return COMPUTE_NOT_READY~;
		infos[i] = {
			.buffer = view.buffer.memory.buffer,
			.offset = (vk::DeviceSize)view.offset,
			.range = (vk::DeviceSize)view.range(),
		};
		writes[i] = vk::writeDescriptorSet()
			.setDstBinding(i)
			.setDescriptorType(DESCRIPTOR_TYPE_STORAGE_BUFFER)
			.setBufferInfo(infos[i..i]);
	}

	vk::cmdPushDescriptorSetKHR(
		self.cmd,
		vk::PipelineBindPoint.PIPELINE_BIND_POINT_COMPUTE,
		kernel.layout,
		0,
		kernel.binding_count,
		&writes[0]
	);

	if (push_constants != null && kernel.push_size > 0)
	{
		vk::cmdPushConstants(self.cmd, kernel.layout, SHADER_STAGE_COMPUTE_BIT, 0, kernel.push_size, push_constants);
	}

	vk::cmdDispatch(self.cmd, groups_x, groups_y, groups_z);
	self.pending++;
	if (barrier) self.barrier();
	return;
}

<*
 Everything written before this - by a dispatch, a copy or a fill - is visible
 to everything recorded after it.

 One barrier for all three kinds of command, because a pipeline mixes them
 freely (a copy of a latent between two kernels, a cleared accumulator before a
 matmul) and the cost of the wider stage mask is nothing next to a missed one.
*>
fn void Compute.barrier(&self)
{
	vk::MemoryBarrier2 barrier = vk::memoryBarrier2()
		.setSrcStageMask(PIPELINE_STAGE_2_COMPUTE_SHADER_BIT | PIPELINE_STAGE_2_ALL_TRANSFER_BIT)
		.setSrcAccessMask(ACCESS_2_SHADER_WRITE_BIT | ACCESS_2_TRANSFER_WRITE_BIT)
		.setDstStageMask(PIPELINE_STAGE_2_COMPUTE_SHADER_BIT | PIPELINE_STAGE_2_ALL_TRANSFER_BIT)
		.setDstAccessMask(ACCESS_2_SHADER_READ_BIT | ACCESS_2_SHADER_WRITE_BIT
			| ACCESS_2_TRANSFER_READ_BIT | ACCESS_2_TRANSFER_WRITE_BIT);
	vk::cmdPipelineBarrier2(self.cmd, &&vk::dependencyInfo().setMemoryBarriers({ barrier }));
}

<*
 Record a GPU-side copy of `size` bytes, in order with the dispatches around it.

 This is how a pipeline saves a latent before the conditional pass and puts it
 back before the unconditional one, or writes a step's keys into a cache: no
 round trip through the host, and no submission of its own.
*>
fn void? Compute.copy(&self, StorageBuffer* source, usz source_offset,
	StorageBuffer* destination, usz destination_offset, usz size, bool barrier = true)
{
	if (size == 0) return;
	if (source_offset + size > source.size) return COMPUTE_NOT_READY~;
	if (destination_offset + size > destination.size) return COMPUTE_NOT_READY~;

	vk::cmdCopyBuffer(self.cmd, source.memory.buffer, destination.memory.buffer, 1, (vk::BufferCopy[]){
		{
			.srcOffset = (vk::DeviceSize)source_offset,
			.dstOffset = (vk::DeviceSize)destination_offset,
			.size = (vk::DeviceSize)size,
		}
	});
	self.pending++;
	if (barrier) self.barrier();
	return;
}

<*
 Record a zero fill of the whole buffer: what a new buffer holds before anything
 writes it, so an accumulator starts at nought rather than at whatever the last
 buffer in that memory left behind.
*>
fn void Compute.clear(&self, StorageBuffer* buffer)
{
	vk::cmdFillBuffer(self.cmd, buffer.memory.buffer, 0, vk::WHOLE_SIZE, 0);
	self.pending++;
	self.barrier();
}

<*
 Record a fill of `size` bytes with one repeated 32-bit word - zero, usually,
 for an accumulator or a cache that has to start empty.

 Vulkan wants both the offset and the size in whole words.
*>
fn void? Compute.fill(&self, StorageBuffer* buffer, usz offset, usz size, uint word = 0, bool barrier = true)
{
	if (size == 0) return;
	if (offset % 4 != 0 || size % 4 != 0) return COMPUTE_NOT_READY~;
	if (offset + size > buffer.size) return COMPUTE_NOT_READY~;

	vk::cmdFillBuffer(self.cmd, buffer.memory.buffer, (vk::DeviceSize)offset, (vk::DeviceSize)size, word);
	self.pending++;
	if (barrier) self.barrier();
	return;
}

<*
 Submit everything recorded since the last submit and wait for it.

 The wait is what makes the next `read` mean anything, and it is why this is a
 verb rather than something a dispatch does on the caller's behalf: the one
 round trip a script needs is the one it asks for.
*>
fn void? Compute.submit(&self)
{
	if (!self.recording) return;
	// Nothing recorded is nothing to wait for. A `read` submits first whether or
	// not a script dispatched anything, and that should not cost a round trip.
	if (self.pending == 0) return;
	self.pending = 0;
	vk::endCommandBuffer(self.cmd)!;

	vk::CommandBufferSubmitInfo cmd_info = vk::commandBufferSubmitInfo().setCommandBuffer(self.cmd);
	vk::SubmitInfo2 submit = vk::submitInfo2().setCommandBufferInfos({ cmd_info });

	vk::queueSubmit2(self.gpu.graphics.handle, 1, &submit, self.fence)!;
	self.fence.wait(self.gpu.handle)!;
	self.fence.reset(self.gpu.handle)!;

	vk::beginCommandBuffer(self.cmd, &&vk::commandBufferBeginInfo())!;
	return;
}

<*
 `size` bytes at `offset`, copied out of the buffer.

 The wait before the copy is the caller's - `submit` - because this is the
 verb that turns GPU state into a host answer and there is exactly one moment
 where that is true.
*>
fn void? StorageBuffer.read(&self, Compute* compute, usz offset, char[] into)
{
	if (offset + into.len > self.size) return COMPUTE_NOT_READY~;
	if (into.len == 0) return;

	// A read of work that is recorded and not submitted would copy the buffer as
	// it was before that work.
	if (compute.pending > 0) compute.submit()!;

	usz chunk = into.len < COMPUTE_STAGING_CHUNK ? into.len : COMPUTE_STAGING_CHUNK;
	vk::Memory stage = vk::new_buffer(
		&compute.gpu.allocator,
		usage: BUFFER_USAGE_TRANSFER_DST_BIT,
		properties: MEMORY_PROPERTY_HOST_VISIBLE_BIT | MEMORY_PROPERTY_HOST_COHERENT_BIT,
		data: null,
		data_size: (sz)chunk,
	)!;
	defer stage.free();

	for (usz done = 0; done < into.len; done += chunk)
	{
		usz part = chunk < into.len - done ? chunk : into.len - done;
		compute.gpu.handle.@single_time_command(queue: compute.gpu.graphics; vk::CommandBuffer cmd)
		{
			vk::cmdCopyBuffer(cmd, self.memory.buffer, stage.buffer, 1, (vk::BufferCopy[]){
				{ .srcOffset = (vk::DeviceSize)(offset + done), .dstOffset = 0, .size = (vk::DeviceSize)part }
			});
		}!;
		mem::copy(&into[done], stage.data(), (sz)part);
	}
	return;
}
