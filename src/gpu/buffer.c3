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

import std::io;
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
 A buffer the CPU rewrites every frame and the shader reads by address — the
 per-frame instance array and the frame block.

 Host-visible rather than device-local with a staging copy, the opposite of
 `upload_stream` and for the opposite reason: the contents change every frame,
 so staging would cost a copy command and a barrier per frame to save a read
 that happens once per vertex. Coherent, so there is nothing to flush and
 `Memory.upload` is a memcpy into the mapped page.

 Allocate one per frame in flight, never one shared. The GPU may still be
 reading last frame's instance array, so writing a slot is only safe after that
 slot's fence has been waited on — which is what `Renderer.frame` and
 `Renderer.capture` do before they record.

 @require size > 0
*>
fn vk::Memory? Gpu.create_dynamic(&self, sz size)
{
	return vk::new_buffer(
		&self.allocator,
		usage: BUFFER_USAGE_STORAGE_BUFFER_BIT | BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT,
		properties: MEMORY_PROPERTY_HOST_VISIBLE_BIT | MEMORY_PROPERTY_HOST_COHERENT_BIT,
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