<*
 The mesh pass: bind the pipeline, push the block, draw.

 At M1 this is one loop over one asset's primitives with one transform, because
 `base_stage.md` says no scene graph and no instancing until M2. What M2 adds is
 the middle of this loop — cull, bucket by `(mesh, material)`, write one
 transform per instance into a per-frame buffer, one instanced draw per bucket —
 and the shape here is chosen so that arrives as a change to `record` rather
 than a change to everything above it.

 The per-frame instance buffer M2 brings has the same shape as crig's pose
 palette, which tore because it was single-buffered against two frames in
 flight. `gpu/frame.c3` says the rule; this is the file that will have to obey
 it.
*>
module three;

import std::io;
import std::math;
import std::math::vector;
import std::math::matrix;
import vk;
import gltf;

struct MeshPass
{
	MeshPipeline pipeline;
	Asset asset;
	Camera camera;
	// xyz: surface-to-light in world space. w: the ambient floor, which keeps
	// unlit faces readable rather than black.
	float[4] light;
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

	self.camera = default_camera();
	self.light = { 0.35, 0.80, 0.45, 0.25 };
	return *self;
}

<*
 Load a `.glb` and frame the camera on it.

 The camera is refitted here rather than left where it was because the caller
 has no idea how big the file's contents are — see `Camera.frame_bounds`.
*>
fn void? MeshPass.load(&self, Gpu* gpu, String path)
{
	self.asset.load(gpu, &self.pipeline, path)!;
	self.camera.frame_bounds(self.asset.bounds.min, self.asset.bounds.max);
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
	self.asset.load_triangle(gpu, &self.pipeline)!;
	self.camera.frame_bounds(self.asset.bounds.min, self.asset.bounds.max);
	self.ready = true;
}

<*
 Record the draws.

 One `vkCmdDrawIndexed` per primitive. The push block carries the whole
 per-draw state — matrix, material factor, light, and the three stream
 addresses — so there is nothing else to bind between draws but the texture's
 descriptor set.
*>
fn void MeshPass.record(&self, vk::CommandBuffer cmd, Target* target)
{
	if (!self.ready) return;

	float aspect = (float)target.extent.width / (float)target.extent.height;
	Matrix4f mvp = self.camera.view_projection(aspect);

	vk::cmdBindPipeline(cmd, PIPELINE_BIND_POINT_GRAPHICS, self.pipeline.handle);

	foreach (&mesh : self.asset.meshes)
	{
		vk::DescriptorSet set = self.asset.set_for(mesh);
		vk::cmdBindDescriptorSets(cmd, PIPELINE_BIND_POINT_GRAPHICS, self.pipeline.layout, 0, 1, &set, 0, null);

		MeshPush push = {
			.mvp = mvp,
			.base_color = mesh.base_color,
			.light = self.light,
			.positions = mesh.positions.address,
			.normals = mesh.has_normals ? mesh.normals.address : 0,
			.uvs = mesh.has_uvs ? mesh.uvs.address : 0,
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
		vk::cmdDrawIndexed(cmd, mesh.index_count, 1, 0, 0, 0);
	}
}

<*
 Numbers an agent can read its own cost off.

 `plan.md`'s second thesis is that the agent must be able to see what it made,
 and `scene.stats()` is half of that. This is the M1 shape of it — one draw per
 primitive, because there is no bucketing yet. When M2 makes N instances of one
 asset a single draw call, this is the number that has to change to prove it.
*>
struct PassStats
{
	uint draw_calls;
	uint meshes;
	uint textures;
	uint triangles;
	uint vertices;
}

fn PassStats MeshPass.stats(&self)
{
	PassStats stats = { .meshes = (uint)self.asset.meshes.len(), .textures = (uint)self.asset.textures.len() };
	foreach (&mesh : self.asset.meshes)
	{
		stats.draw_calls++;
		stats.triangles += mesh.index_count / 3;
		stats.vertices += mesh.vertex_count;
	}
	return stats;
}

fn void MeshPass.free(&self, Gpu* gpu)
{
	self.asset.free(gpu);
	self.pipeline.free(gpu);
	self.ready = false;
}
