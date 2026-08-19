<*
 The mesh pass: update the scene, upload the instance table, bind, push, draw.

 ## One instanced draw per bucket, and no other path

	scene.update      world matrices, cull, sort, write Instance records
	upload            the frame block and the instance array, this slot's copies
	per bucket        bind the material's pipeline if it changed, push the
	                  texture, push the block, vkCmdDrawIndexed(N)

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
import std::collections::list;
import vk;
import collision;

// The instance array starts here and doubles. Small enough that a triangle
// costs nothing, large enough that a normal scene never reallocates.
const sz INITIAL_INSTANCES = 64;

struct MeshPass
{
	// Compiled on demand and kept by content hash. `pipeline` is borrowed from
	// it — the cache owns every pipeline it hands out and frees them all.
	PipelineCache pipelines;
	MeshPipeline* pipeline;
	// The same shader over `LINE_STATE`. `LINE_MATERIAL` is the index that reaches
	// it, and this is the pointer that index resolves to.
	MeshPipeline* line_pipeline;
	// Every material any node can name. Index 0 is `DEFAULT_MATERIAL`, built in
	// `init` from `pipeline`, so a scene that never mentions a material still has
	// one. Lives here rather than on `JsRuntime` for the same reason `assets`
	// does: `new three.Scene()` resets the graph, and a material an agent
	// compiled should survive that exactly as a loaded `.glb` does.
	List{Material} materials;
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
 Compile the mesh shader and build the pipeline from it.

 M1 read a `.spv` here that a build step had produced. M4 reads the `.slang`
 source and compiles it — which is why editing `shaders/mesh.slang` and re-running
 now shows the change with no build step of any kind in between.

 @param shader_path : `Empty to look in the usual places for mesh.slang.`
*>
fn MeshPass? MeshPass.init(&self, Gpu* gpu, Target* target, String shader_path = "")
{
	self.pipelines.init();

	String path = shader_path;
	@pool()
	{
		if (path.len == 0) path = find_shader("mesh.slang", tmem)!;

		String source = load_source(path, tmem)!;
		self.pipeline = self.pipelines.acquire(gpu, target, source, path, SOLID_STATE)!;

		// The line pipeline is the same shader over a different fixed-function
		// state — `LINE_STATE`, which has the argument — so this is a second
		// `VkPipeline` and *not* a second Slang call: `acquire` keys on the source
		// as well as the state, and the source is byte-identical.
		//
		// It draws nothing until a script asks for a helper. Built here anyway,
		// rather than on demand, because building it on demand would put a 1 ms
		// pipeline creation inside whichever frame first added a box helper, and
		// the whole point of a debug tool is that reaching for it is free.
		self.line_pipeline = self.pipelines.acquire(gpu, target, source, path, LINE_STATE)!;
	};

	// `DEFAULT_MATERIAL` is index 0 and is built here, before anything can ask for
	// a material, so `Node.material` never has to mean "none". Its uniform block
	// is empty: `mesh.slang` declares no fields past `flags`, so nothing above
	// `MATERIAL_PUSH_START` is ever read out of it.
	//
	// `LINE_MATERIAL` is index 1 and is built beside it for the same reason: a
	// node's material is a `uint`, so the pass has to be able to hand out an index
	// that means "draw this as lines" before any script has asked for one.
	self.materials.init(mem, 4);
	self.materials.push({ .pipeline = self.pipeline, .cull = CULL_MODE_BACK_BIT, .fragment = "" });
	// No culling for lines: a segment has no facing, and `CULL_MODE_NONE` is what
	// keeps a wireframe from losing half its edges to a rule about triangles.
	self.materials.push({ .pipeline = self.line_pipeline, .cull = CULL_MODE_NONE, .fragment = "" });

	self.assets.init(gpu);
	self.scene.init();
	// The scene counts references against this table from here on — see
	// `Scene.attach_assets`. Wired at construction rather than at first load,
	// because a node created before the wiring would never be counted and the
	// asset it named could then be swept out from under it.
	self.scene.attach_assets(&self.assets);
	self.camera = default_camera();
	self.light = { 0.35, 0.80, 0.45, 0.25 };

	// Set here rather than by the loaders, which is where it used to be set and
	// was a bug: `ready` guards `record` against running without a *pipeline*,
	// and the pipeline exists as of this function. Gating it on a load instead
	// meant the three CLI entry points switched rendering on and the JS path —
	// which calls `Assets.load` directly and never touches these — did not, so
	// `three.render()` from a script drew nothing at all. Nothing caught it
	// because no JS test asserted on pixels; `mcp_test` checks that a PNG comes
	// back, and a blank PNG comes back fine.
	//
	// An empty scene is already handled a few lines into `record`, where zero
	// buckets returns, so this is not a weaker guard than what it replaces.
	self.ready = true;
	return *self;
}

<*
 Resolve a material index.

 @return `The material, or null if the index names nothing — which the draw loop treats as "skip this bucket" rather than as a fault.`
*>
fn Material* MeshPass.material(&self, uint index)
{
	if (index >= self.materials.len()) return null;
	return &self.materials[index];
}

<*
 Load a `.glb` and put one node on screen for each mesh in it.

 The flat placement is deliberate: this is the CLI's "show me this file", not a
 scene author's `add`. Anything with a hierarchy comes from JS at M3, through
 the same `Scene.add_mesh` this uses.
*>
fn void? MeshPass.load(&self, Gpu* gpu, String path)
{
	AssetId asset = self.assets.load(gpu, path)!;
	self.place(asset, NO_NODE);
	self.frame_camera();
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
	AssetId asset = self.assets.load_triangle(gpu)!;
	self.place(asset, NO_NODE);
	self.frame_camera();
}

<*
 An asset's node hierarchy, under `parent`.

 Was "one node per mesh, all at the origin" until G3, which is the same thing
 for a file that bakes its transforms into its vertices and visibly wrong for one
 that does not. `Scene.instantiate` is where that is fixed and where the reasons
 are written down; this stays as the verb the CLI and `load` reach for.

 @return `The group the asset was instantiated into, or the parent it was given if the handle names nothing.`
*>
fn NodeId MeshPass.place(&self, AssetId asset, NodeId parent)
{
	NodeId group = self.scene.instantiate(asset, parent);
	return group.is_set() ? group : parent;
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

	AssetId asset = path.len > 0
		? self.assets.load(gpu, path)!
		: self.assets.load_triangle(gpu)!;

	// Clear whatever `load` put there; the grid is the whole scene.
	self.scene.remove(self.scene.root);

	Vec3 size = self.assets.slot(asset).bounds.size();
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
 Re-derive the camera's near and far planes against what the scene actually holds.

 `Camera.derive_planes` on its own only knows the orbit distance, and the far
 plane it picks from that is a guess that fails silently — see its header. This
 is the caller that has a scene to measure, so it measures: the eye's distance to
 the far side of the bounding sphere is exactly how far the camera can need to
 see, and the multiple-of-distance floor stays underneath it.

 The bounding *sphere* rather than the box's furthest corner, for
 `frame_bounds`'s reason: it is orientation independent, so the answer does not
 change as the turntable turns and the far plane does not breathe during a drag.

 Costs one walk of the node array, on camera moves only — not per frame. An
 empty scene answers with a unit box, whose reach is under the floor, so nothing
 special-cases it.
*>
fn void MeshPass.derive_camera_planes(&self)
{
	collision::Aabb3 bounds = self.scene.bounds(&self.assets);
	Vec3 centre = (bounds.min + bounds.max) * 0.5f;
	float radius = (bounds.max - bounds.min).length() * 0.5f;
	self.camera.derive_planes((self.camera.eye() - centre).length() + radius);
}

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

	// Bound per bucket since M5, because a bucket is now (asset, mesh, material)
	// and the material chooses the pipeline. `build_draw_list` sorts
	// material-major precisely so this stays one bind per material rather than
	// one per bucket — `bound` is what turns that ordering into skipped calls.
	vk::Pipeline bound = (vk::Pipeline)null;

	foreach (bucket : self.scene.buckets)
	{
		GpuMesh* mesh = self.assets.mesh(bucket.asset, bucket.mesh);
		if (mesh == null) continue;

		// A bucket whose material does not resolve is skipped rather than drawn
		// with the default. Falling back would put the wrong shader on screen and
		// look like a shader bug; drawing nothing looks like what it is.
		Material* material = self.material(bucket.material);
		if (material == null) continue;
		MeshPipeline* pipeline = material.pipeline;

		if (pipeline.handle != bound)
		{
			vk::cmdBindPipeline(cmd, PIPELINE_BIND_POINT_GRAPHICS, pipeline.handle);
			bound = pipeline.handle;
		}

		// Dynamic, so `material.side` costs a command rather than a pipeline —
		// `PipelineState` has the argument and the measurement. Set per bucket
		// rather than tracked like `bound`, because the draw list is material-major
		// already: consecutive buckets usually share a material and the driver
		// folds a repeated set, whereas a `last_cull` variable here would be a
		// second thing to keep in step with the pipeline bind for no measured gain.
		vk::cmdSetCullMode(cmd, material.cull);

		// Pushed, not bound. There is no descriptor set anywhere in this project:
		// the image and sampler are specified inline against this pipeline's own
		// layout, so a material's shader gets its texture through its own layout
		// rather than through one baked at load time against a different pipeline.
		// `scene/asset.c3`'s header has the argument.
		vk::DescriptorImageInfo image_info = self.assets.texture_for(mesh).descriptor();
		vk::WriteDescriptorSet write = vk::writeDescriptorSet().setDstBinding(0)
			.setDescriptorType(DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER)
			.setImageInfo({ image_info });
		vk::cmdPushDescriptorSetKHR(cmd, PIPELINE_BIND_POINT_GRAPHICS, pipeline.layout, 0, 1, &write);

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
		// **The reflected size, not `MeshPush::size`.** They are not the same
		// number: Slang reports the 60 bytes the shader uses and the C3 struct
		// occupies 64 with its tail padding, and pushing 64 into a 60-byte range
		// is a validation error.
		//
		// Worth knowing how it fails, because it is not how it sounds: the
		// picture is **pixel-identical** either way on this driver, so no test
		// here catches it and only `--validate` does, naming both numbers. It is
		// still undefined behaviour, and a driver that took the spec literally
		// would drop the push and render nothing at all.
		//
		// Both this and the range in `MeshPipeline.init` read the same reflected
		// field, so they cannot drift without an edit that hardcodes one of them.
		// `check_push_block` has already proved the first `push_size` bytes of
		// `MeshPush` are exactly the fields the shader declares.
		// The mesh contract first, the material's uniforms on top of it. A
		// `Material.block` is laid out *as the push block itself* rather than as a
		// list of values, so this is two memcpys with no per-uniform loop and no
		// offset arithmetic here — Slang decided those offsets and reflection read
		// them back. Everything below `MATERIAL_PUSH_START` in the material's copy
		// is dead space that this overwrites every draw.
		char[PUSH_BUDGET] staging;
		uint push_size = pipeline.shader.push_size;
		mem::copy(&staging[0], (char*)&push, MeshPush::size);
		if (push_size > MATERIAL_PUSH_START)
		{
			mem::copy(
				&staging[MATERIAL_PUSH_START],
				&material.block[MATERIAL_PUSH_START],
				(sz)(push_size - MATERIAL_PUSH_START)
			);
		}

		vk::cmdPushConstants(cmd, pipeline.layout, pipeline.shader.stages, 0, push_size, &staging);

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

<*
 Compile a material from an agent's fragment body.

 The pipeline comes from the same `PipelineCache` the built-in shader uses, keyed
 on the assembled source, so two `ShaderMaterial`s written with identical bodies
 share one `VkPipeline` and the second one skips the Slang call entirely
 (`plan.md` §7). They are still two materials — uniform values are pushed per
 draw, so two materials over one pipeline are two buckets with different bytes.

 The diagnostic is handed back rather than printed, which is the whole point:
 `plan.md` §5's done condition for M5 is that a bad shader throws a JS error
 carrying the Slang text. It is set on success too, because a warning arrives
 with `ok == true` and an agent that never sees its warnings writes the same
 mistake twice.

 @param side : `SIDE_FRONT, SIDE_BACK or SIDE_DOUBLE — which faces survive culling.`
 @param [out] diagnostic : `Slang's output verbatim, on failure and on warnings alike. Owned by the caller.`
 @return `The material index, for Node.material.`
*>
fn uint? MeshPass.create_material(
	&self,
	Gpu* gpu,
	Target* target,
	String fragment,
	MaterialUniform[] uniforms,
	int side = SIDE_FRONT,
	String* diagnostic = null
)
{
	uint index;
	@pool()
	{
		String source = material_source(fragment, uniforms, tmem)!;
		MeshPipeline* pipeline = self.pipelines.acquire(
			gpu, target, source, "three.material", SOLID_STATE, diagnostic
		)!;

		index = (uint)self.materials.len();
		self.materials.push({
			.pipeline = pipeline,
			.cull = cull_for_side(side),
			.fragment = fragment.copy(mem),
		});
	};
	return index;
}

<*
 `material.side = ...` — change which faces this material keeps.

 One field, and no pipeline. It was a re-`acquire` for about an hour: the cull
 mode used to be baked into `PipelineState`, so a new side meant a new
 `VkPipeline` built from the material's own source — which also meant this
 needed a device, a target, the assembled source read back out of the pipeline
 cache, and a fault path for each of those going wrong.

 Making the cull mode dynamic deleted all of it. `MeshPass.record` sets it per
 bucket from this field, so two sides of one material are one pipeline and this
 is an assignment. See `PipelineState`.

 **The built-in materials are refused.** `DEFAULT_MATERIAL` is shared by every
 node that was never given a material of its own, so turning its faces round
 would turn every such node's faces round — a scene-wide change made through a
 handle that reads like it names one thing. `LINE_MATERIAL` is refused for a
 different reason: a debug line has no facing to cull, and offering the setting
 would be offering one that does nothing.

 @return? MATERIAL_UNKNOWN : `No such material, or one of the two built-in ones, which are shared.`
*>
fn void? MeshPass.set_material_side(&self, uint index, int side)
{
	if (index == DEFAULT_MATERIAL || index == LINE_MATERIAL) return MATERIAL_UNKNOWN~;
	Material* material = self.material(index);
	if (material == null) return MATERIAL_UNKNOWN~;

	material.cull = cull_for_side(side);
}

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
	// Before the cache, which owns the pipelines these borrow.
	foreach (&material : self.materials) material.free();
	self.materials.free();
	self.pipelines.free(gpu);
	self.pipeline = null;
	self.line_pipeline = null;
	self.ready = false;
}
