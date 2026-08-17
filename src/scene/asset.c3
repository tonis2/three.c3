<*
 A loaded glTF: its meshes uploaded, its textures deduplicated.

 Two decisions here are cheap now and expensive later, so `base_stage.md` S9
 asks for both at M1 rather than at M2:

 - **One uploaded mesh per glTF mesh. Never a soup.** crig's `gltf/source.c3`
   deliberately welds a whole scene into a single triangle soup, because a
   rigger wants one mesh. three.c3 wants the exact opposite: the thesis is that
   an instance is an immutable asset reference plus a transform, so M2 has to be
   able to name a mesh and place N copies of it. Flattening here is a decision
   that has to be unpicked later, and unpicking it means re-reading the file.

 - **Textures deduplicated by content hash from the first upload.** Two kit
   pieces exported from the same source share their images. Retrofitting the
   dedup after two assets already share one is more work than doing it now, and
   it is the same rule the M6 exporter needs.

 What is deliberately *not* here: a scene graph, node transforms, instancing,
 or a material model. Those are M2 and M5. This reads meshes and their base
 colour, and stops.
*>
module three;

import std::io;
import std::collections::list;
import std::math;
import std::math::vector;
import vk;
import gltf;
import image;
import image::png;
import image::jpeg;

faultdef ASSET_HAS_NO_MESHES, UNSUPPORTED_IMAGE;

<*
 One glTF primitive, uploaded.

 A glTF *mesh* is a list of primitives, each with its own material, and the
 renderer's unit of work is the primitive rather than the mesh — so this is what
 M2's instance table will key on. The mesh's name is carried on every primitive
 it produced so a mesh can still be found by name.
*>
struct GpuMesh
{
	String name;
	// Streams, tightly packed. `positions` is the only one that must exist.
	vk::Memory positions;
	vk::Memory normals;
	vk::Memory uvs;
	vk::Memory indices;
	uint vertex_count;
	uint index_count;
	bool has_normals;
	bool has_uvs;
	float[4] base_color;
	// Index into `Asset.textures`, or -1 for "no texture": the material samples
	// the shared 1x1 white image instead.
	int texture;
	gltf::Aabb bounds;
}

struct Asset
{
	String path;
	List{GpuMesh} meshes;
	List{Texture} textures;
	// The 1x1 white stand-in every untextured material samples. Owned here so
	// one exists per asset load; M2's shared asset table takes it over.
	Texture white;
	// One descriptor set per texture, plus one for `white`, allocated from a
	// pool sized once at load. Push descriptors would avoid the pool, but
	// KosmicKrisp's vkCmdPushDescriptorSetKHR breaks subsequent draws when
	// descriptorWriteCount > 0 — see vulkan.c3l's textured_cube example.
	vk::DescriptorPool pool;
	List{vk::DescriptorSet} sets;
	vk::DescriptorSet white_set;
	gltf::Aabb bounds;
	// Set once an image the decoder does not handle has been reported, so a
	// file with ninety KTX2 textures says so once rather than ninety times.
	bool warned_unsupported_image;
}

fn gltf::Aabb Asset.aabb(&self) => self.bounds;

<*
 Give every list the heap before anything is pushed into it.

 A List left zero-initialised has a null allocator, and `list_ensure_capacity`
 resolves null to `tmem`: the first push would back the list with temp-arena
 memory, and any `@pool()` open up the stack would free it on the way out.
 Nothing faults there — the entries turn into garbage and the crash lands
 wherever the list is next walked, which for an asset is at draw time or at
 teardown, a long way from the cause. vulkan.c3l's MemoryAllocator carries the
 same note for the same reason.
*>
fn void Asset.init_lists(&self)
{
	self.meshes.init(mem, 8);
	self.textures.init(mem, 4);
	self.sets.init(mem, 4);
}

<*
 Load a `.glb` or `.gltf`, upload everything it needs to draw, and close the
 file.

 @param path : `A .glb or a .gltf; gltf.c3l reads both.`
 @return? ASSET_HAS_NO_MESHES : `The file parsed but contains no drawable geometry, which is almost always the wrong file rather than an empty one.`
*>
fn Asset? Asset.load(&self, Gpu* gpu, MeshPipeline* pipeline, String path)
{
	self.path = path;
	self.init_lists();

	gltf::GltfStream stream = gltf::open(path)!;
	defer stream.close();
	stream.load_all_buffers()!;
	stream.load_all_images()!;

	if (stream.gltf.meshes.len() == 0) return ASSET_HAS_NO_MESHES~;

	self.white = gpu.create_white_texture()!;

	bool first_bounds = true;

	foreach (mesh : stream.gltf.meshes)
	{
		gltf::Aabb mesh_bounds = stream.gltf.mesh_aabb(mesh);
		if (first_bounds)
		{
			self.bounds = mesh_bounds;
			first_bounds = false;
		}
		else
		{
			self.bounds = self.bounds.merge(mesh_bounds);
		}

		foreach (primitive : mesh.primitives)
		{
			GpuMesh uploaded = self.upload_primitive(gpu, &stream, mesh, primitive)!;
			if (uploaded.vertex_count == 0) continue;
			self.meshes.push(uploaded);
		}
	}

	if (self.meshes.len() == 0) return ASSET_HAS_NO_MESHES~;

	self.build_descriptors(gpu, pipeline)!;
	return *self;
}

<*
 Read one primitive's streams into tightly packed arrays and upload them.

 The `@each_*` macros are used rather than a memcpy of the accessor's range
 because a glTF buffer view may be strided — interleaved attributes are legal
 and common — and `@cast_buffer` is what knows the stride. What lands on the
 GPU is always tightly packed, which is what the shader's scalar-layout
 `float3*` reads expect.
*>
fn GpuMesh? Asset.upload_primitive(
	&self,
	Gpu* gpu,
	gltf::GltfStream* stream,
	gltf::Mesh mesh,
	gltf::Primitive primitive
)
{
	GpuMesh out = { .name = mesh.name, .texture = -1, .base_color = { 1, 1, 1, 1 } };

	// A primitive that fails halfway has already put buffers on the device, and
	// nothing else knows about them yet — the mesh is only handed to `meshes`
	// on the way out. Without this the failure is a leak that surfaces as
	// "child objects not destroyed" when the device goes away, several layers
	// from the cause.
	defer catch out.free_buffers();

	// Heap-backed for the same reason as `init_lists`, even though these are
	// freed in this scope: `@each_texcoord` formats an attribute name through
	// the temp arena, so this function already touches it.
	List{Vec3} positions;
	List{Vec3} normals;
	List{Vec2} uvs;
	List{uint} indices;
	positions.init(mem, 256);
	normals.init(mem, 256);
	uvs.init(mem, 256);
	indices.init(mem, 512);
	defer
	{
		positions.free();
		normals.free();
		uvs.free();
		indices.free();
	}

	stream.@each_position(primitive; Vec3 position, sz i) { positions.push(position); };
	if (positions.len() == 0) return out;

	stream.@each_normal(primitive; Vec3 normal, sz i) { normals.push(normal); };
	stream.@each_texcoord(primitive, 0; Vec2 uv, sz i) { uvs.push(uv); };

	read_indices(stream, primitive, &indices);
	// A primitive with no index accessor is a plain vertex list; give it the
	// trivial index buffer rather than carrying a second draw path for it.
	if (indices.len() == 0)
	{
		for (uint i = 0; i < positions.len(); i++) indices.push(i);
	}

	out.vertex_count = (uint)positions.len();
	out.index_count = (uint)indices.len();
	out.bounds = stream.gltf.primitive_aabb(primitive);

	out.positions = gpu.upload_stream(positions.entries, Vec3::size * positions.len())!;
	out.indices = gpu.upload_indices(indices.entries, uint::size * indices.len())!;

	// A stream that is short is a stream that is absent: the shader indexes
	// every stream with the same SV_VertexID, so a normals array that does not
	// cover every vertex would read past its own buffer.
	out.has_normals = normals.len() == positions.len();
	if (out.has_normals) out.normals = gpu.upload_stream(normals.entries, Vec3::size * normals.len())!;

	out.has_uvs = uvs.len() == positions.len();
	if (out.has_uvs) out.uvs = gpu.upload_stream(uvs.entries, Vec2::size * uvs.len())!;

	// The material, if the primitive names one.
	sz? material_index = primitive.attributes.get("material");
	if (try material_index)
	{
		if (material_index < stream.gltf.materials.len())
		{
			gltf::Material material = stream.gltf.materials[material_index];
			out.base_color = {
				material.baseColorFactor[0],
				material.baseColorFactor[1],
				material.baseColorFactor[2],
				material.baseColorFactor[3],
			};
			if (out.has_uvs) out.texture = self.load_material_texture(gpu, stream, material)!;
		}
	}

	return out;
}

<*
 Indices, read at whatever width the file stored them.

 glTF allows unsigned byte, short or int, and a chooser that assumes one width
 silently pairs adjacent bytes into one index — a 4-vertex quad comes back
 referring to vertex 770. Everything is widened to uint on the way to the GPU
 so there is a single index type to bind.
*>
fn void read_indices(gltf::GltfStream* stream, gltf::Primitive primitive, List{uint}* out)
{
	sz? attr = primitive.attributes.get("indices");
	if (catch attr) return;

	gltf::Accessor accessor = stream.gltf.accessors[attr];
	for (sz i = 0; i < accessor.count; i++)
	{
		switch (accessor.data_type)
		{
			case gltf::DataType.CHAR:
				out.push((uint)stream.@cast_buffer(accessor, i, char));
			case gltf::DataType.USHORT:
				out.push((uint)stream.@cast_buffer(accessor, i, ushort));
			case gltf::DataType.SHORT:
				out.push((uint)stream.@cast_buffer(accessor, i, short));
			default:
				out.push(stream.@cast_buffer(accessor, i, uint));
		}
	}
}

<*
 Decode and upload a material's base colour texture, or reuse one already here.

 The hash is over the decoded RGBA rather than the encoded file, so two images
 that differ only in how they were compressed still count as one. Dimensions are
 compared too — a hash match with different extents would be a collision, and
 sharing on one would corrupt both.

 @return `An index into Asset.textures, or -1 when the material has no base colour texture.`
*>
fn int? Asset.load_material_texture(&self, Gpu* gpu, gltf::GltfStream* stream, gltf::Material material)
{
	int texture_index = material.baseColorTexture.source;
	if (texture_index < 0) return -1;
	if (texture_index >= stream.gltf.textures.len()) return -1;

	int image_index = stream.gltf.textures[texture_index].source;
	if (image_index < 0 || image_index >= stream.gltf.images.len()) return -1;

	char[]? encoded = stream.get_image_data((uint)image_index);
	if (catch encoded) return -1;

	// A texture that will not decode costs that material its texture and
	// nothing else. Failing the whole load instead would mean one KTX2 image in
	// a ninety-mesh file renders nothing at all, which is strictly less useful
	// than the same file rendered with its base colour factors — and an agent
	// that can see the geometry can tell what it is looking at.
	gltf::ImageType mime = stream.gltf.images[image_index].mimeType;
	image::Image? maybe  = decode_image(mime, encoded);
	if (catch maybe)
	{
		if (!self.warned_unsupported_image)
		{
			io::printfn("three: %s textures are not decoded; those materials render untextured", image_type_name(mime));
			self.warned_unsupported_image = true;
		}
		return -1;
	}
	image::Image decoded = maybe;
	defer decoded.free();

	char[] rgba = decoded.to_rgba();
	defer free(rgba);

	ulong hash = content_hash(rgba);
	foreach (i, existing : self.textures)
	{
		if (existing.hash == hash && existing.width == decoded.width && existing.height == decoded.height)
		{
			return (int)i;
		}
	}

	self.textures.push(gpu.create_texture(rgba, decoded.width, decoded.height)!);
	return (int)self.textures.len() - 1;
}

<*
 PNG and JPEG, which is what `image.c3l` decodes.

 KTX2 (KHR_texture_basisu) is the notable absence and it is common in shipped
 assets. Anything else is not an error the load should die on — see
 `load_material_texture`.
*>
fn image::Image? decode_image(gltf::ImageType mime, char[] encoded)
{
	switch (mime)
	{
		case gltf::ImageType.IMAGE_PNG:
			return png::load_bytes(encoded);
		case gltf::ImageType.IMAGE_JPEG:
			return jpeg::load_bytes(encoded);
		default:
			return UNSUPPORTED_IMAGE~;
	}
}

fn String image_type_name(gltf::ImageType mime)
{
	switch (mime)
	{
		case gltf::ImageType.IMAGE_PNG: return "PNG";
		case gltf::ImageType.IMAGE_JPEG: return "JPEG";
		case gltf::ImageType.IMAGE_BMP: return "BMP";
		case gltf::ImageType.IMAGE_GIF: return "GIF";
		case gltf::ImageType.IMAGE_KTX2: return "KTX2 (KHR_texture_basisu)";
		default: return "an unknown format";
	}
}

<*
 One descriptor set per texture plus one for the white stand-in.

 Allocated in a single pool sized once, after every texture is known — a pool
 that has to grow is a pool that has to be recreated with every set in it
 rebound, and the count is known here for nothing.
*>
fn void? Asset.build_descriptors(&self, Gpu* gpu, MeshPipeline* pipeline)
{
	uint count = (uint)self.textures.len() + 1;

	self.pool = vk::descriptorPoolCreateInfo().setMaxSets(count)
		.setPoolSizes(
			(vk::DescriptorPoolSize[]) { { .type = DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = count } }
		)
		.build(gpu.handle)!;

	self.white_set = self.allocate_set(gpu, pipeline, &self.white)!;
	foreach (&texture : self.textures)
	{
		self.sets.push(self.allocate_set(gpu, pipeline, texture)!);
	}
	return;
}

fn vk::DescriptorSet? Asset.allocate_set(&self, Gpu* gpu, MeshPipeline* pipeline, Texture* texture)
{
	vk::DescriptorSet set;
	vk::DescriptorSetAllocateInfo info = vk::descriptorSetAllocateInfo().setDescriptorPool(self.pool)
		.setSetLayouts((vk::DescriptorSetLayout[]) { pipeline.descriptor_layout });
	vk::allocateDescriptorSets(gpu.handle, &info, &set)!;

	vk::DescriptorImageInfo image_info = {
		.sampler = texture.sampler,
		.imageView = texture.view,
		.imageLayout = IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
	};
	vk::WriteDescriptorSet write = vk::writeDescriptorSet().setDstSet(set).setDstBinding(0)
		.setDescriptorType(DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER)
		.setImageInfo({ image_info });
	vk::updateDescriptorSets(gpu.handle, 1, &write, 0, null);

	return set;
}

<*
 The set a mesh draws with: its own texture's, or the white stand-in's.
*>
fn vk::DescriptorSet Asset.set_for(&self, GpuMesh* mesh)
{
	if (mesh.texture < 0 || mesh.texture >= self.sets.len()) return self.white_set;
	return self.sets[mesh.texture];
}

<*
 A hardcoded triangle, uploaded through exactly the same path as a glTF mesh.

 This is `base_stage.md` S8 on its own: geometry reaching the shader through a
 buffer device address, with no file involved. Keeping it separate from the
 glTF path means a blank window is never ambiguous — if the triangle draws and
 a `.glb` does not, the loader is at fault and not the pipeline.

 Wound counter-clockwise as seen from +Z, which is glTF's front-face
 convention, so it is culled by the same rule real geometry is.
*>
fn Asset? Asset.load_triangle(&self, Gpu* gpu, MeshPipeline* pipeline)
{
	self.path = "<triangle>";
	self.init_lists();

	Vec3[3] positions = { { -0.5, -0.5, 0 }, { 0.5, -0.5, 0 }, { 0.0, 0.5, 0 } };
	Vec3[3] normals   = { { 0, 0, 1 }, { 0, 0, 1 }, { 0, 0, 1 } };
	uint[3] indices   = { 0, 1, 2 };

	self.white = gpu.create_white_texture()!;

	GpuMesh mesh = {
		.name = "triangle",
		.vertex_count = 3,
		.index_count = 3,
		.has_normals = true,
		.base_color = { 0.85, 0.55, 0.25, 1.0 },
		.texture = -1,
		.bounds = { .min = { -0.5, -0.5, 0 }, .max = { 0.5, 0.5, 0 } },
	};
	mesh.positions = gpu.upload_stream(&positions, Vec3::size * 3)!;
	mesh.normals = gpu.upload_stream(&normals, Vec3::size * 3)!;
	mesh.indices = gpu.upload_indices(&indices, uint::size * 3)!;

	self.meshes.push(mesh);
	self.bounds = mesh.bounds;

	self.build_descriptors(gpu, pipeline)!;
	return *self;
}

<*
 Release just this mesh's device memory. Separate from `Asset.free` because a
 primitive that fails partway through uploading has to undo its own work before
 anything else has heard of it.
*>
fn void GpuMesh.free_buffers(&self)
{
	if (self.positions.buffer != null) self.positions.free();
	if (self.indices.buffer != null) self.indices.free();
	if (self.normals.buffer != null) self.normals.free();
	if (self.uvs.buffer != null) self.uvs.free();
}

fn void Asset.free(&self, Gpu* gpu)
{
	foreach (&mesh : self.meshes) mesh.free_buffers();
	self.meshes.free();

	foreach (&texture : self.textures) texture.free(gpu);
	self.textures.free();
	self.white.free(gpu);
	self.sets.free();

	if (self.pool != null)
	{
		vk::destroyDescriptorPool(gpu.handle, self.pool, null);
		self.pool = (vk::DescriptorPool)null;
	}
	*self = { };
}
