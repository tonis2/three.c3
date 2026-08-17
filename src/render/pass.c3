<*
 The mesh pass: update the scene, upload the instance table, bind, push, draw.

 ## One instanced draw per bucket, and no other path

	scene.update      world matrices, cull, sort, write Instance records
	upload            the frame block and the instance array, this slot's copies
	per bucket        bind the texture set, push 60 bytes, vkCmdDrawIndexed(N)

 There is no single-instance shortcut. A lone mesh is a bucket of one, drawn by
 the same call with an instance count of one, reading its transform out of the
 same array — which is what makes `plan.md`'s claim that every scene the API can
 express is optimized *by construction* true rather than aspirational. There is
 nothing to notice and nothing to fall out of.

 ## The instance buffer is per frame slot

 `gpu/frame.c3` says anything the GPU may still be reading must be
 double-buffered, and this is the file that has to obey it — crig's pose palette
 was the same shape and tore. Each slot owns its own array and is only written
 after its fence has been waited on. Growth frees and reallocates *that slot's*
 buffer only, which is safe for the same reason writing it is.
*>
module three;

import std::io;
import std::math;
import std::math::vector;
import std::math::matrix;
import vk;
import collision;

// The instance array starts here and doubles. Small enough that a triangle
// costs nothing, large enough that a normal scene never reallocates.
const sz INITIAL_INSTANCES = 64;

struct MeshPass
{
	MeshPipeline pipeline;
	Assets assets;
	Scene scene;
	Camera camera;
	// xyz: surface-to-light in world space. w: the ambient floor, which keeps
	// unlit faces readable rather than black.
	float[4] light;

	// Per frame in flight — see the header.
	vk::Memory[MAX_FRAMES_IN_FLIGHT] frame_blocks;
	vk::Memory[MAX_FRAMES_IN_FLIGHT] instance_buffers;
	sz[MAX_FRAMES_IN_FLIGHT] instance_capacity;

	bool ready;
}

<*
 Build the pipeline from a SPIR-V module on disk.

 @param spirv_path : `Empty to look in the usual places for mesh.spv.`
*>
fn MeshPass? MeshPass.init(&self, Gpu* gpu, Target* target, String spirv_path = "")
{
	String path = spirv_path;
	@pool()
	{
		if (path.len == 0) path = find_shader("mesh.spv", tmem)!;

		char[] spirv = load_spirv(path, tmem)!;
		self.pipeline.init(gpu, target, spirv, CULL_MODE_BACK_BIT)!;
	};

	self.assets.init();
	self.scene.init();
	self.camera = default_camera();
	self.light = { 0.35, 0.80, 0.45, 0.25 };
	return *self;
}

<*
 Load a `.glb` and put one node on screen for each mesh in it.

 The flat placement is deliberate: this is the CLI's "show me this file", not a
 scene author's `add`. Anything with a hierarchy comes from JS at M3, through
 the same `Scene.add_mesh` this uses.
*>
fn void? MeshPass.load(&self, Gpu* gpu, String path)
{
	uint asset = self.assets.load(gpu, &self.pipeline, path)!;
	self.place(asset, NO_NODE);
	self.frame_camera();
	self.ready = true;
}

<*
 Load the built-in triangle — what `three` shows when given no file.

 It exists to prove the geometry path on its own: a hardcoded triangle
 rendering through a buffer device address is `base_stage.md` S8, and having it
 separate from S9 means a blank window after loading a `.glb` is unambiguous
 about which half broke.
*>
fn void? MeshPass.load_triangle(&self, Gpu* gpu)
{
	uint asset = self.assets.load_triangle(gpu, &self.pipeline)!;
	self.place(asset, NO_NODE);
	self.frame_camera();
	self.ready = true;
}

<*
 One node per mesh in an asset, under `parent`.

 @return `The parent the meshes were placed under.`
*>
fn NodeId MeshPass.place(&self, uint asset, NodeId parent)
{
	Asset* loaded = &self.assets.assets[asset];
	uint count = (uint)loaded.meshes.len();

	for (uint i = 0; i < count; i++)
	{
		// The name is re-read each pass rather than held: `add_mesh` grows the
		// node pool, and the asset pool is a different list, but a pointer taken
		// across a call that takes `&self` is the habit worth not having.
		String name = self.assets.assets[asset].meshes[i].name;
		self.scene.add_mesh(asset, i, parent, name);
		self.assets.retain(asset);
	}
	return parent;
}

<*
 Place `count` copies of an already-loaded asset in a square grid.

 This is `--grid` and it exists to make the M2 claim visible rather than only
 asserted: a thousand copies of a model, one draw call, and `stats()` saying so.
 Each copy is a group with the asset's meshes under it, so it also exercises the
 world-matrix propagation the flat placement above never touches.

 The spacing comes from the asset's own bounds, because a kit piece is a metre
 across and a terrain tile is a kilometre, and a fixed spacing produces either a
 pile or a smear.
*>
fn void? MeshPass.instance_grid(&self, Gpu* gpu, String path, uint count)
{
	if (count == 0) return;

	uint asset = path.len > 0
		? self.assets.load(gpu, &self.pipeline, path)!
		: self.assets.load_triangle(gpu, &self.pipeline)!;

	// Clear whatever `load` put there; the grid is the whole scene.
	self.scene.remove(self.scene.root);

	Vec3 size = self.assets.assets[asset].bounds.size();
	float span = math::max(math::max(size.x, size.z), 0.001f) * 1.25f;

	uint side = 1;
	while (side * side < count) side++;

	for (uint i = 0; i < count; i++)
	{
		uint column = i % side;
		uint row = i / side;

		NodeId group = self.scene.add_group(NO_NODE, "instance");
		self.scene.set_position(group, {
			((float)column - (float)(side - 1) * 0.5f) * span,
			0,
			((float)row - (float)(side - 1) * 0.5f) * span,
		});
		self.place(asset, group);
	}

	self.frame_camera();
	self.ready = true;
}

<*
 Aim the camera at everything in the scene.

 Refitted here rather than left where it was because the caller has no idea how
 big the scene's contents are — see `Camera.frame_bounds`.
*>
fn void MeshPass.frame_camera(&self)
{
	collision::Aabb3 bounds = self.scene.bounds(&self.assets);
	self.camera.frame_bounds(bounds.min, bounds.max);
}

fn collision::Aabb3 MeshPass.bounds(&self) => self.scene.bounds(&self.assets);

<*
 Record the draws.

 @param slot : `Which frame in flight this is. Selects the instance array to write, and must be one whose fence has already been waited on.`
*>
fn void? MeshPass.record(&self, Gpu* gpu, vk::CommandBuffer cmd, Target* target, uint slot)
{
	if (!self.ready) return;

	float aspect = (float)target.extent.width / (float)target.extent.height;
	Matrix4f view_projection = self.camera.view_projection(aspect);

	self.scene.update(&self.assets, view_projection);
	if (self.scene.buckets.len() == 0) return;

	FrameBlock frame = { .view_projection = view_projection, .light = self.light };
	ulong frame_address = self.write_frame_block(gpu, slot, &frame)!;
	ulong instance_address = self.write_instances(gpu, slot)!;

	vk::cmdBindPipeline(cmd, PIPELINE_BIND_POINT_GRAPHICS, self.pipeline.handle);

	foreach (bucket : self.scene.buckets)
	{
		GpuMesh* mesh = self.assets.mesh(bucket.asset, bucket.mesh);
		if (mesh == null) continue;

		vk::DescriptorSet set = self.assets.set_for(mesh);
		vk::cmdBindDescriptorSets(cmd, PIPELINE_BIND_POINT_GRAPHICS, self.pipeline.layout, 0, 1, &set, 0, null);

		MeshPush push = {
			.frame = frame_address,
			// Offset on the CPU rather than passed as a base index: the shader
			// then reads instance zero of its own slice and never has to know
			// whether SV_InstanceID includes firstInstance.
			.instances = instance_address + (ulong)bucket.first * Instance::size,
			.positions = mesh.positions.address,
			.normals = mesh.has_normals ? mesh.normals.address : 0,
			.uvs = mesh.has_uvs ? mesh.uvs.address : 0,
			.base_color = mesh.base_color,
			.flags = (mesh.has_normals ? FLAG_HAS_NORMALS : 0) | (mesh.has_uvs ? FLAG_HAS_UVS : 0),
		};
		vk::cmdPushConstants(
			cmd,
			self.pipeline.layout,
			SHADER_STAGE_VERTEX_BIT | SHADER_STAGE_FRAGMENT_BIT,
			0,
			MeshPush::size,
			&push
		);

		// Index binding is independent of vertex bindings, which is why the
		// pass can have an index buffer and no vertex input state at all.
		vk::cmdBindIndexBuffer(cmd, mesh.indices.buffer, 0, INDEX_TYPE_UINT32);
		vk::cmdDrawIndexed(cmd, mesh.index_count, bucket.count, 0, 0, 0);
	}
}

fn ulong? MeshPass.write_frame_block(&self, Gpu* gpu, uint slot, FrameBlock* frame)
{
	if (self.frame_blocks[slot].buffer == null)
	{
		self.frame_blocks[slot] = gpu.create_dynamic(FrameBlock::size)!;
	}
	self.frame_blocks[slot].upload(frame, FrameBlock::size);
	return self.frame_blocks[slot].address;
}

<*
 Write this frame's instance array into this slot's buffer, growing it first if
 the scene outgrew it.

 Doubling rather than fitting exactly: a scene that adds one instance a frame
 would otherwise reallocate every frame, and the allocator's free-block reuse
 makes a discarded buffer cheap but not free.
*>
fn ulong? MeshPass.write_instances(&self, Gpu* gpu, uint slot)
{
	sz needed = self.scene.instances.len();

	if (self.instance_capacity[slot] < needed)
	{
		sz capacity = self.instance_capacity[slot] > 0 ? self.instance_capacity[slot] : INITIAL_INSTANCES;
		while (capacity < needed) capacity *= 2;

		// Safe only because this slot's fence has been waited on before
		// recording — see the header. Freeing the *other* slot's buffer here
		// would be a use-after-free the validation layers would not always see.
		if (self.instance_buffers[slot].buffer != null) self.instance_buffers[slot].free();

		self.instance_buffers[slot] = gpu.create_dynamic((sz)(capacity * Instance::size))!;
		self.instance_capacity[slot] = capacity;
	}

	self.instance_buffers[slot].upload(self.scene.instances.entries, (sz)(needed * Instance::size));
	return self.instance_buffers[slot].address;
}

<*
 Numbers an agent can read its own cost off.

 `plan.md`'s second thesis is that the agent must be able to see what it made,
 and this is half of it. Computed with culling off — see `Scene.stats`.
*>
fn SceneStats MeshPass.stats(&self) => self.scene.stats(&self.assets);

fn void MeshPass.free(&self, Gpu* gpu)
{
	for (uint i = 0; i < MAX_FRAMES_IN_FLIGHT; i++)
	{
		if (self.frame_blocks[i].buffer != null) self.frame_blocks[i].free();
		if (self.instance_buffers[i].buffer != null) self.instance_buffers[i].free();
		self.instance_capacity[i] = 0;
	}
	self.scene.free();
	self.assets.free(gpu);
	self.pipeline.free(gpu);
	self.ready = false;
}
