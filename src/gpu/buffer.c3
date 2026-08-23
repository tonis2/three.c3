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

<*
 A buffer the CPU rewrites every frame and the shader reads by address — the
 per-frame instance array and the frame block.

 **Host-visible rather than device-local-with-a-staging-copy**, which is the
 opposite of `upload_stream`, and for the opposite reason: this content changes
 every frame, so a staged upload would be a copy command and a barrier per frame
 to save a read that happens once per vertex. Coherent, so there is nothing to
 flush; `Memory.upload` is a memcpy into the mapped page.

 **One of these per frame in flight, never one shared.** `gpu/frame.c3` states
 the rule and this is the first thing in the project it applies to: the GPU may
 still be reading last frame's instance array, and crig's pose palette tore for
 exactly this reason. Writing a slot is only safe after that slot's fence has
 been waited on, which is what `Renderer.frame` and `Renderer.capture` do before
 they record.

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
 A buffer the GPU writes and the GPU reads, with no host mapping and nothing
 uploaded into it.

 The third kind, and the one compute skinning writes its posed vertices into. It
 differs from `upload_stream` in having no initial contents — there is nothing to
 stage, because the first thing that ever touches it is a dispatch — and from
 `create_dynamic` in not being host-visible, because the CPU never reads or writes
 a byte of it. A host-visible heap would cost bandwidth for a mapping nothing
 uses.

 **Still per frame in flight where it is used**, for `create_dynamic`'s reason
 rather than for its own: the GPU may still be reading last frame's posed vertices
 while this frame's dispatch wants to overwrite them, and a barrier inside one
 frame says nothing about the frame before it.

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
