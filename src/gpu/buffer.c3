<*
 Buffer allocation and upload.

 **Geometry reaches the shader through buffer device addresses, not vertex
 input state** (`plan.md` §1). In crig that was forced by cui; here it is a
 choice, and still the right one — a geometry stream becomes a buffer plus a
 pointer, and creating a pipeline from JS then needs no vertex-format
 description language at all. Three.js's whole `BufferGeometry` attribute-
 binding layer never gets written.

 Indices are the exception and stay ordinary: `vkCmdBindIndexBuffer` is
 independent of vertex bindings, so `SV_VertexID` arrives already resolved
 through the index buffer and the shader indexes the streams with it directly.
*>
module three;

import std::io;
import vk;

<*
 Upload a vertex stream and take its device address.

 Device-local: `vk::new_buffer` sees DEVICE_LOCAL with data attached, adds
 TRANSFER_DST and stages the copy through a host-visible buffer itself.

 @param data : `Tightly packed, exactly as the source file stored it — the shader reads float3 and float2 under scalar layout, so there is no repack anywhere.`
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
 Upload an index buffer. Bound the ordinary way; no address is taken.

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
