<*
 Buffer allocation and upload.

 Geometry reaches the shader through buffer device addresses rather than vertex
 input state. A geometry stream is therefore just a buffer plus a pointer, and
 creating a pipeline from JS needs no vertex-format description at all — the
 whole three.js `BufferGeometry` attribute-binding layer never has to exist.

 Indices are the exception and stay ordinary: `vkCmdBindIndexBuffer` is
 independent of vertex bindings, so `SV_VertexID` arrives already resolved
 through the index buffer and the shader indexes the streams with it directly.
*>
module three;

import vk;

<*
 Uploads a vertex stream and returns its device address.

 Device-local: `vk::new_buffer` sees DEVICE_LOCAL with data attached, adds
 TRANSFER_DST and stages the copy through a host-visible buffer itself.

 @param data : `Tightly packed, exactly as the source file stored it — the shader reads float3 and float2 under scalar layout, so nothing is repacked anywhere.`
 @require data != null && size > 0
*>
fn vk::Memory? Gpu.upload_stream(&self, void* data, sz size)
{
	return vk::new_buffer(
		&self.allocator,
		usage: BUFFER_USAGE_STORAGE_BUFFER_BIT | BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT,
		properties: MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
		data: data,
		data_size: size,
	);
}

<*
 Uploads an index buffer. Bound the ordinary way; no address is taken.

 @require data != null && size > 0
*>
fn vk::Memory? Gpu.upload_indices(&self, void* data, sz size)
{
	return vk::new_buffer(
		&self.allocator,
		usage: BUFFER_USAGE_INDEX_BUFFER_BIT,
		properties: MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
		data: data,
		data_size: size,
	);
}

<*
 Whether the device has a host-visible memory type that is also cached.

 `create_dynamic` asks for one when it exists. The property set is a request, not
 a preference: the allocator answers the first type carrying every bit asked for,
 and on a device without a cached host-visible type that answer would be a type
 with no `HOST_VISIBLE` at all rather than a slower one.
*>
fn bool Gpu.has_cached_dynamic_memory(&self)
{
	vk::PhysicalDeviceMemoryProperties memory;
	vk::getPhysicalDeviceMemoryProperties(self.pdevice, &memory);
	vk::MemoryPropertyFlags wanted = MEMORY_PROPERTY_HOST_VISIBLE_BIT
		| MEMORY_PROPERTY_HOST_COHERENT_BIT | MEMORY_PROPERTY_HOST_CACHED_BIT;
	for (uint i = 0; i < memory.memoryTypeCount; i++)
	{
		if ((memory.memoryTypes[i].propertyFlags & wanted) == wanted) return true;
	}
	return false;
}

<*
 A buffer the CPU rewrites every frame and the shader reads by address — the
 per-frame instance array and the frame block.

 Host-visible rather than device-local with a staging copy, the opposite of
 `upload_stream` and for the opposite reason: the contents change every frame,
 so staging would cost a copy command and a barrier per frame to save a read
 that happens once per vertex. Coherent, so there is nothing to flush and
 `Memory.upload` is a memcpy into the mapped page.

 **Cached, when the device offers it**, because the CPU reads these pages back:
 `MeshPass.fold_frame_key` folds the whole instance array into the picture key
 every frame, and an uncached mapping of the same bytes runs that hash at a
 fortieth of the speed — measured at 10.4 ms of a 12.9 ms frame on a
 4,586-instance scene. The GPU reads these buffers either way, so the fallback
 only gives up the host's read bandwidth.

 Allocate one per frame in flight, never one shared. The GPU may still be
 reading last frame's instance array, so writing a slot is only safe after that
 slot's fence has been waited on — which is what `Renderer.frame` and
 `Renderer.capture` do before they record.

 @require size > 0
*>
fn vk::Memory? Gpu.create_dynamic(&self, sz size)
{
	vk::MemoryPropertyFlags properties = MEMORY_PROPERTY_HOST_VISIBLE_BIT | MEMORY_PROPERTY_HOST_COHERENT_BIT;
	if (self.has_cached_dynamic_memory()) properties |= MEMORY_PROPERTY_HOST_CACHED_BIT;
	return vk::new_buffer(
		&self.allocator,
		usage: BUFFER_USAGE_STORAGE_BUFFER_BIT | BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT,
		properties: properties,
		data_size: size,
	);
}

<*
 A buffer the GPU both writes and reads, with no host mapping and no upload —
 what compute skinning writes its posed vertices into.

 Unlike `upload_stream` it has no initial contents, since the first thing to
 touch it is a dispatch; unlike `create_dynamic` it is not host-visible, since
 the CPU never reads or writes a byte and a host-visible heap would cost
 bandwidth for a mapping nothing uses.

 Still one per frame in flight where it is used: the GPU may be reading last
 frame's posed vertices while this frame's dispatch wants to overwrite them, and
 a barrier inside one frame says nothing about the frame before it.

 @require size > 0
*>
fn vk::Memory? Gpu.create_device_storage(&self, sz size)
{
	return vk::new_buffer(
		&self.allocator,
		usage: BUFFER_USAGE_STORAGE_BUFFER_BIT | BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT,
		properties: MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
		data_size: size,
	);
}