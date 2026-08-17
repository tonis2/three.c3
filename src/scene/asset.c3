<*
 Loaded glTF files: meshes uploaded once, textures deduplicated across all of
 them.

 Three decisions here are cheap now and expensive later:

 - **One uploaded mesh per glTF primitive. Never a soup.** crig's
   `gltf/source.c3` deliberately welds a whole scene into a single triangle
   soup, because a rigger wants one mesh. three.c3 wants the exact opposite: the
   thesis is that an instance is an immutable asset reference plus a transform,
   so `Scene` has to be able to name a mesh and place N copies of it.

 - **Textures deduplicated by content hash across every asset already loaded**
   (`plan.md` §2), not merely within one file. Two kit pieces exported from the
   same source share their images, and the whole point is that a scene built out
   of a kit uploads each image once. That is why the texture list and the 1x1
   white stand-in live on `Assets` rather than on `Asset`.

 - **A `TriBVH` per unique mesh, built at upload.** It is not read until
   `scene/pick.c3` needs it, but it is per *mesh* rather than per instance —
   a thousand copies of a wall cost one tree — and building it here is what makes
   that true without a second pass over the file. The cost is honest and worth
   stating: the positions and a triangle index array stay resident on the CPU
   for the life of the asset, because the tree points at them.

 ## There are no descriptor pools

 There were, until M5: one pool sized for exactly the textures a single `load`
 added, plus a one-set pool for the white stand-in, with a `sets` list running
 parallel to `textures`. All of it is gone. `VK_KHR_push_descriptor` lets the
 draw loop specify the image and sampler inline in the command buffer, so there
 is no set to allocate, no pool to size, and no lifetime to keep in step with the
 texture list.

 What that bought is not the deleted code, it is the deleted *coupling*:
 `Assets.load` used to take a `MeshPipeline*` for the sole purpose of allocating
 sets against its descriptor layout, which meant the asset table knew what a
 pipeline was and every texture set was bound to one particular layout. Materials
 made that actively uncomfortable — a set baked against the mesh pipeline's
 layout, bound into a material pipeline's, is legal only by an argument about
 layout compatibility that a future shader could quietly break. Now the question
 does not arise.

 The extension is required, not probed-and-worked-around, exactly as
 `VK_KHR_dynamic_rendering` is: `Gpu.limits.push_descriptor` is queried and a
 device without it is refused with a sentence. Both are baseline on every driver
 this targets.
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
import collision;

faultdef ASSET_HAS_NO_MESHES, UNSUPPORTED_IMAGE;

<*
 One glTF primitive, uploaded.

 A glTF *mesh* is a list of primitives, each with its own material, and the
 renderer's unit of work is the primitive rather than the mesh — so this is what
 the instance table keys on. The mesh's name is carried on every primitive it
 produced so a mesh can still be found by name.
*>
struct GpuMesh
{
	// **Owned.** `gltf::Mesh.name` is freed by `GltfStream.close`, so keeping
	// the pointer would leave every mesh named by freed memory — invisible until
	// something actually reads a name, which is exactly what `Assets.find_mesh`
	// does.
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
	// Index into `Assets.textures`, or -1 for "no texture": the material samples
	// the shared 1x1 white image instead.
	int texture;
	collision::Aabb3 bounds;

	// Picking, in mesh-local space. The tree holds raw pointers into the two
	// arrays beside it, so all three live and die together.
	Vec3[] hull_positions;
	collision::Triangle[] hull_triangles;
	collision::TriBVHNode* bvh;
}

struct Asset
{
	String path; // owned
	List{GpuMesh} meshes;
	collision::Aabb3 bounds;
	// The number of live `Mesh` nodes pointing here (`plan.md` §2). Maintained
	// so that an unused asset is *knowable*; dropping to zero does not unload
	// yet, because unloading under two frames in flight needs the deferred
	// delete queue and nothing asks for it before M6.
	uint refs;
}

fn collision::Aabb3 Asset.aabb(&self) => self.bounds;

<*
 Every loaded asset, and everything shared between them.

 A `GpuMesh*` or `Asset*` handed out from here is valid only until the next
 `load` — the pools are `List`s and growing one moves its contents.
*>
struct Assets
{
	List{Asset} assets;

	// Shared across every asset. Since M5 there is nothing parallel to this:
	// the image and its sampler are pushed straight into the command buffer at
	// draw time, so a texture is a texture and not also a descriptor set.
	List{Texture} textures;

	Texture white;
	bool has_white;

	// Set once an image the decoder does not handle has been reported, so a
	// file with ninety KTX2 textures says so once rather than ninety times.
	bool warned_unsupported_image;
	bool started;
}

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
fn Assets* Assets.init(&self)
{
	self.assets.init(mem, 4);
	self.textures.init(mem, 8);
	self.started = true;
	return self;
}

<*
 A mesh by asset and index, or null.

 Bounds-checked rather than asserted because the indices reaching here come out
 of `Scene`, and a node holding a stale asset index should draw nothing rather
 than read a freed list.
*>
fn GpuMesh* Assets.mesh(&self, uint asset, uint mesh)
{
	if (asset >= self.assets.len()) return null;
	Asset* owner = &self.assets[asset];
	if (mesh >= owner.meshes.len()) return null;
	return &owner.meshes[mesh];
}

<*
 Find a mesh inside an asset by its glTF name — `kit.mesh("wall_corner_02")`.

 A glTF mesh with several primitives produced several `GpuMesh` entries sharing
 one name; this returns the first, which is the one a caller naming a mesh means.

 @return `An index into the asset's meshes, or -1.`
*>
fn int Assets.find_mesh(&self, uint asset, String name)
{
	if (asset >= self.assets.len()) return -1;
	foreach (i, &mesh : self.assets[asset].meshes)
	{
		if (mesh.name == name) return (int)i;
	}
	return -1;
}

fn void Assets.retain(&self, uint asset)
{
	if (asset < self.assets.len()) self.assets[asset].refs++;
}

fn void Assets.release(&self, uint asset)
{
	if (asset < self.assets.len() && self.assets[asset].refs > 0) self.assets[asset].refs--;
}

<*
 What every unique texture costs on the device, as `stats()` reports it.

 Counted off the deduplicated list, so two kit pieces sharing an image are
 counted once — which is the number worth showing an agent, because it is the
 one that changes when the sharing breaks.
*>
fn usz Assets.texture_bytes(&self)
{
	usz total = 0;
	foreach (&texture : self.textures) total += (usz)texture.width * texture.height * 4;
	return total;
}

<*
 The texture a mesh draws with: its own, or the white stand-in.

 Answers with the `Texture` rather than a descriptor set because there are no
 descriptor sets any more — `MeshPass.record` pushes the image and sampler into
 the command buffer directly. The white fallback is unchanged and still does the
 same job: the binding is always occupied, so a textured mesh and an untextured
 one are the same pipeline and there is no shader permutation to manage.
*>
fn Texture* Assets.texture_for(&self, GpuMesh* mesh)
{
	if (mesh.texture < 0 || mesh.texture >= self.textures.len()) return &self.white;
	return &self.textures[mesh.texture];
}

// ============================================================================
// Loading
// ============================================================================

<*
 Load a `.glb` or `.gltf`, upload everything it needs to draw, and close the
 file.

 Loading the same path twice returns the first load. That is the coarse half of
 "linked, not duplicated" — the fine half is the content-hash texture dedup
 below, which catches two *different* files sharing an image.

 @param path : `A .glb or a .gltf; gltf.c3l reads both.`
 @return `The asset's index, for Scene.add_mesh.`
 @return? ASSET_HAS_NO_MESHES : `The file parsed but contains no drawable geometry, which is almost always the wrong file rather than an empty one.`
*>
fn uint? Assets.load(&self, Gpu* gpu, String path)
{
	if (!self.started) self.init();

	foreach (i, &existing : self.assets)
	{
		if (existing.path == path) return (uint)i;
	}

	gltf::GltfStream stream = gltf::open(path)!;
	defer stream.close();
	stream.load_all_buffers()!;
	stream.load_all_images()!;

	if (stream.gltf.meshes.len() == 0) return ASSET_HAS_NO_MESHES~;

	self.ensure_white(gpu)!;

	Asset asset = { .path = path.copy(mem) };
	asset.meshes.init(mem, 8);
	// Everything below this point can fail, and a half-loaded asset is not on
	// `self.assets` yet — so its own buffers are its own to undo.
	defer catch
	{
		foreach (&mesh : asset.meshes) mesh.free_buffers();
		asset.meshes.free();
		asset.path.free(mem);
	}

	bool first_bounds = true;

	foreach (mesh : stream.gltf.meshes)
	{
		foreach (primitive : mesh.primitives)
		{
			GpuMesh uploaded = self.upload_primitive(gpu, &stream, mesh, primitive)!;
			if (uploaded.vertex_count == 0) continue;

			if (first_bounds)
			{
				asset.bounds = uploaded.bounds;
				first_bounds = false;
			}
			else
			{
				asset.bounds.expand_by_aabb(uploaded.bounds);
			}
			asset.meshes.push(uploaded);
		}
	}

	if (asset.meshes.len() == 0) return ASSET_HAS_NO_MESHES~;


	self.assets.push(asset);
	return (uint)self.assets.len() - 1;
}

<*
 Read one primitive's streams into tightly packed arrays and upload them.

 The `@each_*` macros are used rather than a memcpy of the accessor's range
 because a glTF buffer view may be strided — interleaved attributes are legal
 and common — and `@cast_buffer` is what knows the stride. What lands on the
 GPU is always tightly packed, which is what the shader's scalar-layout
 `float3*` reads expect.
*>
fn GpuMesh? Assets.upload_primitive(
	&self,
	Gpu* gpu,
	gltf::GltfStream* stream,
	gltf::Mesh mesh,
	gltf::Primitive primitive
)
{
	GpuMesh out = { .texture = -1, .base_color = { 1, 1, 1, 1 } };

	// A primitive that fails halfway has already put buffers on the device, and
	// nothing else knows about them yet — the mesh is only handed to `meshes`
	// on the way out. Without this the failure is a leak that surfaces as
	// "child objects not destroyed" when the device goes away, several layers
	// from the cause.
	defer catch out.free_buffers();

	// Heap-backed for the same reason as `Assets.init`, even though these are
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

	out.name = mesh.name.copy(mem);
	out.vertex_count = (uint)positions.len();
	out.index_count = (uint)indices.len();

	gltf::Aabb box = stream.gltf.primitive_aabb(primitive);
	out.bounds = { .min = box.min, .max = box.max };

	out.positions = gpu.upload_stream(positions.entries, Vec3::size * positions.len())!;
	out.indices = gpu.upload_indices(indices.entries, uint::size * indices.len())!;

	// A stream that is short is a stream that is absent: the shader indexes
	// every stream with the same SV_VertexID, so a normals array that does not
	// cover every vertex would read past its own buffer.
	out.has_normals = normals.len() == positions.len();
	if (out.has_normals) out.normals = gpu.upload_stream(normals.entries, Vec3::size * normals.len())!;

	out.has_uvs = uvs.len() == positions.len();
	if (out.has_uvs) out.uvs = gpu.upload_stream(uvs.entries, Vec2::size * uvs.len())!;

	out.build_bvh(positions.array_view(), indices.array_view());

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
 Build the picking tree, and keep the geometry it points at.

 `collision::TriBVHNode` stores raw pointers to the vertex and triangle arrays
 rather than copying them, so these two allocations are part of the tree and are
 freed with it. That is the memory cost named in the header: roughly 24 bytes per
 vertex-and-triangle pair, resident for as long as the asset is loaded.

 A degenerate primitive — fewer than three indices — gets no tree rather than a
 tree of nothing, because `create_indexed_tri_bvh` requires a positive triangle
 count.
*>
fn void GpuMesh.build_bvh(&self, Vec3[] positions, uint[] indices)
{
	usz triangle_count = indices.len / 3;
	if (triangle_count == 0 || positions.len == 0) return;

	self.hull_positions = mem::new_array(Vec3, (sz)positions.len);
	self.hull_positions[..] = positions[..];

	self.hull_triangles = mem::new_array(collision::Triangle, (sz)triangle_count);
	for (usz i = 0; i < triangle_count; i++)
	{
		self.hull_triangles[i] = { indices[i * 3], indices[i * 3 + 1], indices[i * 3 + 2] };
	}

	self.bvh = collision::create_indexed_tri_bvh(self.hull_positions.ptr, self.hull_triangles.ptr, (sz)triangle_count);
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
 Decode and upload a material's base colour texture, or reuse one already here
 — from this file or from any file loaded before it.

 The hash is over the decoded RGBA rather than the encoded file, so two images
 that differ only in how they were compressed still count as one. Dimensions are
 compared too — a hash match with different extents would be a collision, and
 sharing on one would corrupt both.

 @return `An index into Assets.textures, or -1 when the material has no base colour texture.`
*>
fn int? Assets.load_material_texture(&self, Gpu* gpu, gltf::GltfStream* stream, gltf::Material material)
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

// ============================================================================
// Descriptors
// ============================================================================

<*
 The 1x1 white stand-in, created once for the whole table.

 It is what keeps this to a single pipeline: the sampler binding is always
 occupied, so an untextured mesh and a textured one are the same pipeline and
 there is no permutation to manage.

 Took a `MeshPipeline*` until M5, for the sole purpose of allocating a descriptor
 set against its layout. With push descriptors there is no set to allocate, and
 the asset table no longer needs to know that pipelines exist — which is the
 coupling this change was worth making for. A material with its own shader used
 to mean texture sets baked against a *different* pipeline's layout, legal only
 by an argument about layout compatibility that somebody had to keep true.
*>
fn void? Assets.ensure_white(&self, Gpu* gpu)
{
	if (self.has_white) return;

	self.white = gpu.create_white_texture()!;
	self.has_white = true;
}

<*
 The descriptor write for a texture, ready to push.

 Built per draw rather than once per texture, which is the trade push descriptors
 make: no pool, no allocation, no lifetime, and the cost is re-specifying sixteen
 bytes of image info at each bucket. At this project's draw counts — the whole
 thesis is that a thousand instances are one draw — that is not a cost worth
 caching to avoid.
*>
fn vk::DescriptorImageInfo Texture.descriptor(&self)
{
	return {
		.sampler = self.sampler,
		.imageView = self.view,
		.imageLayout = IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
	};
}

// ============================================================================
// The built-in triangle
// ============================================================================

<*
 A hardcoded triangle, uploaded through exactly the same path as a glTF mesh.

 This is `base_stage.md` S8 on its own: geometry reaching the shader through a
 buffer device address, with no file involved. Keeping it separate from the
 glTF path means a blank window is never ambiguous — if the triangle draws and
 a `.glb` does not, the loader is at fault and not the pipeline.

 Wound counter-clockwise as seen from +Z, which is glTF's front-face
 convention, so it is culled by the same rule real geometry is.

 @return `The asset's index, for Scene.add_mesh.`
*>
fn uint? Assets.load_triangle(&self, Gpu* gpu)
{
	if (!self.started) self.init();

	Vec3[3] positions = { { -0.5, -0.5, 0 }, { 0.5, -0.5, 0 }, { 0.0, 0.5, 0 } };
	Vec3[3] normals   = { { 0, 0, 1 }, { 0, 0, 1 }, { 0, 0, 1 } };
	uint[3] indices   = { 0, 1, 2 };

	self.ensure_white(gpu)!;

	Asset asset = { .path = "<triangle>".copy(mem) };
	asset.meshes.init(mem, 1);

	GpuMesh mesh = {
		.name = "triangle".copy(mem),
		.vertex_count = 3,
		.index_count = 3,
		.has_normals = true,
		.base_color = { 0.85, 0.55, 0.25, 1.0 },
		.texture = -1,
		.bounds = { .min = { -0.5, -0.5, 0 }, .max = { 0.5, 0.5, 0 } },
	};
	defer catch
	{
		mesh.free_buffers();
		asset.meshes.free();
		asset.path.free(mem);
	}

	mesh.positions = gpu.upload_stream(&positions, Vec3::size * 3)!;
	mesh.normals = gpu.upload_stream(&normals, Vec3::size * 3)!;
	mesh.indices = gpu.upload_indices(&indices, uint::size * 3)!;
	mesh.build_bvh(positions[..], indices[..]);

	asset.bounds = mesh.bounds;
	asset.meshes.push(mesh);

	self.assets.push(asset);
	return (uint)self.assets.len() - 1;
}

// ============================================================================
// Teardown
// ============================================================================

<*
 Release just this mesh's memory, device and host. Separate from `Assets.free`
 because a primitive that fails partway through uploading has to undo its own
 work before anything else has heard of it.
*>
fn void GpuMesh.free_buffers(&self)
{
	if (self.positions.buffer != null) self.positions.free();
	if (self.indices.buffer != null) self.indices.free();
	if (self.normals.buffer != null) self.normals.free();
	if (self.uvs.buffer != null) self.uvs.free();

	// `free_indexed` rather than `free`: the root owns the sorted-index array
	// that every node below it points into, and the plain `free` leaves it.
	if (self.bvh != null)
	{
		self.bvh.free_indexed();
		mem::free(self.bvh);
		self.bvh = null;
	}
	if (self.hull_positions.len > 0) mem::free(self.hull_positions);
	if (self.hull_triangles.len > 0) mem::free(self.hull_triangles);
	self.hull_positions = {};
	self.hull_triangles = {};

	if (self.name.len > 0) self.name.free(mem);
	self.name = "";
}

fn void Assets.free(&self, Gpu* gpu)
{
	foreach (&asset : self.assets)
	{
		foreach (&mesh : asset.meshes) mesh.free_buffers();
		asset.meshes.free();
		if (asset.path.len > 0) asset.path.free(mem);
	}
	self.assets.free();

	foreach (&texture : self.textures) texture.free(gpu);
	self.textures.free();

	if (self.has_white)
	{
		self.white.free(gpu);
		self.has_white = false;
	}


	*self = { };
}
