<*
 Running a material's own shader somewhere the exporter can read the answer.

 `scene/export.c3` writes geometry and loses shading: a `ShaderMaterial` is a
 Slang pipeline and glTF describes surfaces, so every mesh drawn under one
 exports with the base colour its geometry happened to carry. For a scene whose
 whole character is thirteen bodies that is a correct file in a single grey.

 The fix is not a writer change. It is running the body somewhere the writer can
 read the pixels, which is what this file is: one offscreen target, one draw per
 `(mesh, material)`, and a readback.

 ## Rasterised in uv space, not from a camera

 The mesh is drawn with its **uv as its clip position** — `shaders/material.slang`
 under `THREE_BAKE` — so a texel of the target is a point of the surface and the
 fragment stage receives the world position, normal and uv that point really has.
 Not a photograph of the object and not an approximation: the same function on a
 grid.

 What that needs is a mesh whose uvs do not overlap, which is a property of the
 *layout* rather than of the shader. A generated primitive and a terrain field
 both have one; a mesh that packs its uvs into islands has one with seams in it
 — see the dilation note at the bottom.

 What it cannot do is a body that reads `s.position` on a shape drawn in a
 hundred places: the answer differs per copy and one image cannot hold a hundred.
 `Exporter.world_space_body` is where that is decided, and the rule there is that
 a bake never splits a batch.

 ## Unlit, and why that is a define rather than a second shader

 `standard(s, ...)` applies the frame's lighting, so a naive bake puts the sun
 and the shadows into the base colour and a glTF viewer lights the result a
 second time. Every function that adds light is therefore guarded on
 `THREE_BAKE`: `lambert` is the identity, the highlight is zero, `shadow_factor`
 is 1, and `standard` answers with the albedo it was handed.

 The agent's body is unchanged and never sees the define, so this is one template
 and not a second copy of a 44 000-byte shader to keep in step. The vertex body
 still runs first, deliberately — a body that computes its own uv is common
 enough that baking against coordinates the frame never used would be the first
 thing to go wrong.

 ## `discard` comes back as a shape

 The target is cleared to transparent and the material is written `MASK`, so a
 body that discards its leaf shape out of a quad exports as the leaf rather than
 as the quad. That is a visible win independent of colour and is why the bake
 writes four channels rather than three.

 ## Seams

 A uv layout of islands leaves the texels between them unwritten, and a viewer
 does not sample only the texels a triangle covered: bilinear filtering reaches a
 texel past every edge, and each mip level reaches twice as far again. Cleared to
 transparent and read as opaque, that is *black*, and it arrives as a dark rind
 around every island that widens with distance.

 `dilate` is the answer, and it is one sweep forward and one back rather than a
 flood: every unwritten texel takes the colour of approximately the nearest
 written one, so there is no black anywhere left to filter in. **The alpha is not
 dilated**, which is the half that matters — it stays 0, so a body that discards
 still cuts its shape out and only the colour under the cut is filled.

 One bake is one queue idle. `@single_time_command` submits and waits, which is
 the right trade for a verb a script calls once at the end of a run and the wrong
 one per frame — the same call `Texture.read_pixels` makes, for the same reason.
*>
module three;

import std::collections::list;
import std::math;
import std::math::vector;
import std::math::matrix;
import vk;

// There is no device, so there is nothing to run the body on. The one way a bake
// can be refused before a single material is looked at — `scene.export` itself
// needs no GPU, and this is the part of it that does.
faultdef BAKE_NEEDS_A_DEVICE;

<*
 What `scene.export(path, { bake: true })` bakes at, in texels a side. Square,
 because a uv square is what is being rasterised.

 A number and not a derivation, and the honest account is that one scene is not
 enough to derive one. A texel here is a fixed fraction of a *surface*, not of the
 world, so the same number is generous on a plank and coarse on a landscape:
 across a 560 m terrain 512 is a metre a texel, and across a two-metre rock it is
 four millimetres.

 So it is picked for the case there are hundreds of, which is the prop. On the
 scene this feature was written against — 2909 copies, 309 of them written as
 nodes of their own — the three sizes measured:

	256     14 MB     5 s
	512     22 MB    10 s
	1024    44 MB    28 s

 against 9.4 MB and no shading at all. A terrain that wants more says so with a
 number; a scene of three hundred props that wants a smaller file says so the same
 way.
*>
const uint BAKE_SIZE_DEFAULT = 512;
// Under this a bake is not a texture, and over it a single PNG of noise is tens
// of megabytes. Both are refused at the JS boundary by name.
const uint BAKE_SIZE_MIN = 16;
const uint BAKE_SIZE_MAX = 4096;

<*
 What one material is asked to bake: which mesh, and the placement to bake it at.

 The placement is here rather than assumed to be the identity because a body that
 reads `s.normal` is the ordinary case, and a normal is rotated by the instance
 — so a mesh baked at identity and drawn rotated is lit as though it were lying
 down. `Exporter.bake_key` decides *which* placement, and whether one answer
 serves every copy.
*>
struct BakeRequest
{
	AssetId asset;
	uint mesh;
	uint material;
	Matrix4f model;
	Matrix4f normal;
	// Which row of the material's table this copy selected. Clamped in the shader
	// against the rows the material declared, exactly as a frame's is.
	uint variant;
}

// One material's bake pipeline, or the fact that it has none. Remembered either
// way: a body that could not be assembled must not be handed to Slang once per
// mesh that draws it.
struct BakedPipeline @local
{
	uint material;
	MeshPipeline* pipeline;
}

<*
 The target, the buffers and the pipelines one export's bakes share.

 Opened once per export and freed with it. Everything in here is sized by the
 bake resolution and by nothing about the scene, so a scene of one material and a
 scene of fifty allocate the same memory and differ only in draws.
*>
struct MaterialBaker
{
	MeshPass* pass;
	Gpu* gpu;
	Target target;
	uint size;
	// The three buffers a draw reads through `MeshPush`. One each rather than one
	// per frame in flight, because a bake waits for its own submission before the
	// next one is recorded — there is no frame in flight to race with.
	vk::Memory frame;
	vk::Memory instance;
	vk::Memory draw;
	// A spilled material's uniform table, grown to whichever material wanted the
	// most. Zero bytes until one spills, which is every scene until a material
	// declares more uniforms than the push block holds.
	vk::Memory table;
	sz table_capacity;
	vk::Memory readback;
	// `dilate`'s working distances, one per texel. Allocated with the target
	// because it is sized by the same number and reused by every bake.
	uint[] spread;
	List{BakedPipeline} pipelines;
	bool ready;
}

<*
 Opens a baker at `size` texels a side, or fails.

 Fails rather than degrading when there is no device: `scene.export` works with
 no GPU at all — it reads a mesh out of the file it came from or tessellates it
 again — and a bake is the one part of it that cannot. The caller writes the file
 without one and says so in the report.

 @param size : `Texels a side. BAKE_SIZE_MIN..BAKE_SIZE_MAX, checked at the JS boundary.`
 @require size >= BAKE_SIZE_MIN && size <= BAKE_SIZE_MAX
*>
fn MaterialBaker? MeshPass.open_baker(&self, uint size)
{
	Gpu* gpu = self.assets.gpu;
	if (gpu == null) return BAKE_NEEDS_A_DEVICE~;

	MaterialBaker baker = { .pass = self, .gpu = gpu, .size = size };
	baker.target.init(gpu, size, size)!;
	baker.frame = gpu.create_dynamic(FrameBlock::size)!;
	baker.instance = gpu.create_dynamic(Instance::size)!;
	baker.draw = gpu.create_dynamic(DrawRecord::size)!;
	baker.readback = baker.target.create_readback(gpu)!;
	baker.spread = mem::new_array(uint, (sz)size * (sz)size);
	baker.pipelines.init(mem, 8);
	baker.ready = true;
	return baker;
}

fn void MaterialBaker.free(&self)
{
	foreach (built : self.pipelines)
	{
		if (built.pipeline != null) self.pass.pipelines.release(self.gpu, built.pipeline);
	}
	self.pipelines.free();
	if (self.frame.buffer != null) self.frame.free();
	if (self.instance.buffer != null) self.instance.free();
	if (self.draw.buffer != null) self.draw.free();
	if (self.table.buffer != null) self.table.free();
	if (self.readback.buffer != null) self.readback.free();
	if (self.spread.len > 0) mem::free(self.spread);
	self.target.free(self.gpu);
	*self = { };
}

// How many bytes one bake fills.
fn sz MaterialBaker.bytes(&self) => (sz)self.size * (sz)self.size * 4;

<*
 The bake pipeline for one material, compiled on first use.

 The same `PipelineCache` the frame uses, keyed on the assembled source — so two
 `ShaderMaterial`s written with identical bodies share one bake pipeline, and a
 material's bake and its frame pipeline are two entries over two different
 sources rather than one that has to be told which it is.

 A body that will not assemble or will not compile answers null and is remembered
 as null. That is not a failure of the export: it is a material whose shading the
 file cannot carry, which is exactly what `ExportReport.shaded` has always
 counted.

 @return `The pipeline, or null for a material that cannot be baked.`
*>
fn MeshPipeline* MaterialBaker.pipeline_for(&self, uint index)
{
	foreach (known : self.pipelines)
	{
		if (known.material == index) return known.pipeline;
	}

	MeshPipeline* built = null;
	Material* material = self.pass.material(index);
	if (material != null && material.fragment.len > 0)
	{
		@pool()
		{
			String? source = material_source(
				material.fragment,
				material.declared_uniforms,
				tmem,
				material.declared_textures,
				material.vertex,
				bake: true
			);
			if (try source)
			{
				MeshPipeline*? made = self.pass.pipelines.acquire(
					self.gpu, &self.target, source, "three.bake", BAKE_STATE
				);
				if (try made) built = made;
			}
		};
	}

	self.pipelines.push({ .material = index, .pipeline = built });
	return built;
}

<*
 Draws one mesh into the target and copies it back out.

 Split from `bake` so the whole recording can be one `!`-propagating expression
 and the caller can turn every way it fails into one `false`. Nothing here is
 recoverable: a submission that did not run leaves the readback holding the
 previous bake, which would be written into the file as this material's answer.
*>
fn void? MaterialBaker.record(
	&self, MeshPipeline* pipeline, Material* material, GpuMesh* mesh, ulong table_address
)
{
	self.gpu.handle.@single_time_command(queue: self.gpu.graphics; vk::CommandBuffer cmd)
	{
		// Transparent, so a texel no triangle covers and a texel a body discarded are
		// the same value — which is what `alphaMode: MASK` then cuts out.
		self.target.begin_render(cmd, { 0, 0, 0, 0 });
		// Unflipped, overriding what `begin_render` just set. Every pass that
		// rasterises world geometry flips Y to put +Y up; uv (0,0) is the *top-left*
		// texel of an image, so a bake that inherited the flip would come out
		// mirrored and nothing about the picture would say which way round it was.
		set_full_viewport(cmd, self.target.extent, false);

		vk::cmdBindPipeline(cmd, PIPELINE_BIND_POINT_GRAPHICS, pipeline.handle);
		// Both sides, whatever the material's own is. A triangle's winding in uv
		// space has nothing to do with which way it faces in the world, so culling
		// here would drop whichever half of a layout happened to be mirrored.
		vk::cmdSetCullMode(cmd, CULL_MODE_NONE);

		// The frame's own rule for binding 0: the material's map beats the mesh's
		// image, because a script that set one and got the other would be overruled
		// by an asset it did not write.
		Texture* sampled = material.texture == NO_TEXTURE
			? self.pass.assets.texture_for(mesh)
			: self.pass.assets.texture_at(material.texture);

		SampledBindings samplers;
		samplers.add(0, sampled.descriptor());
		// Asked rather than assumed, and the answer is normally *no*: under
		// `THREE_BAKE` nothing reads `shadow_map`, so Slang drops it and pushing a
		// write for a binding the layout does not declare would be a validation
		// error. The white 1x1 is here for the compile that keeps it anyway.
		if (pipeline_declares_binding(pipeline, SHADOW_BINDING))
		{
			samplers.add(SHADOW_BINDING, self.pass.assets.texture_at(NO_TEXTURE).descriptor());
		}
		samplers.collect(pipeline, &material.textures, &self.pass.assets, MATERIAL_BINDING_FIRST);
		samplers.push(cmd, pipeline);

		MeshPush push = {
			.frame = self.frame.address,
			.instances = self.instance.address,
			.draw = self.draw.address,
		};
		// The mesh contract, then the material's uniforms on top of it, then the
		// table pointer over the stale copy in the block — `MeshPass.record` byte for
		// byte, and it has the argument for each of the three.
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
		if (material.table_pointer != NO_TABLE_POINTER && table_address != 0)
		{
			mem::copy(&staging[material.table_pointer], (char*)&table_address, ulong::size);
		}
		vk::cmdPushConstants(cmd, pipeline.layout, pipeline.shader.stages, 0, push_size, &staging);

		vk::cmdBindIndexBuffer(cmd, mesh.indices.buffer, 0, INDEX_TYPE_UINT32);
		// One copy. A batch's thousand placements are one answer by construction —
		// that is what `Exporter.bake_key` decided before this was called.
		vk::cmdDrawIndexed(cmd, mesh.index_count, 1, 0, 0, 0);

		vk::cmdEndRendering(cmd);
		self.target.close(cmd);
		self.target.record_readback(cmd, &self.readback);
	}!;
}

<*
 Bakes one material over one mesh.

 The pixels come back sRGB-encoded, which is what the target stores and what a
 PNG is defined to hold — there is no conversion anywhere on this path.

 @param out : `Filled with size*size*4 bytes, RGBA. Untouched when this answers false.`
 @return `False for a mesh that cannot be rasterised in uv space, a material with no bake pipeline, or a submission that did not run.`
*>
fn bool MaterialBaker.bake(&self, BakeRequest request, char[] out)
{
	if (!self.ready || out.len < self.bytes()) return false;

	GpuMesh* mesh = self.pass.assets.mesh(request.asset, request.mesh);
	// No uvs is no layout to rasterise into: `vertexMain` would place every vertex
	// at the same clip position and the bake would be one texel of one triangle.
	// Three indices is the same refusal `geometry_for` makes — a line mesh's
	// indices are pairs.
	if (mesh == null || !mesh.has_uvs || mesh.index_count < 3) return false;

	Material* material = self.pass.material(request.material);
	if (material == null) return false;

	MeshPipeline* pipeline = self.pipeline_for(request.material);
	if (pipeline == null) return false;

	// Read by almost nothing under `THREE_BAKE` — the lighting, the camera and the
	// shadow fit are all behind guards — and written in full anyway, so that a
	// guard removed later fails by baking a lit surface rather than by reading
	// through a null pointer.
	Vec3 eye = self.pass.camera.eye();
	FrameBlock frame = {
		.view_projection = self.pass.frame_view_projection,
		.lighting = { self.pass.lighting.ambient, (float)self.pass.lighting.count, 0, 0 },
		.live_poses = 0,
		.light_view_projection = matrix::IDENTITY4{float},
		.shadow = { 0, 0, 0, 0 },
		.debug = { 0, 0, 0, 0 },
		.camera = { eye.x, eye.y, eye.z, 0 },
		.lights = self.pass.lighting.lights,
	};
	self.frame.upload(&frame, FrameBlock::size);

	// White, and the alpha with it. The copy's own tint stays in the document's
	// `baseColorFactor` — see `Exporter.mesh_entry` — and the alpha channel of the
	// bake is left to mean one thing only: whether the body discarded here.
	Instance instance = {
		.model = request.model,
		.normal = request.normal,
		.color = { 1, 1, 1, 1 },
		.variant = request.variant,
		.pose = 0,
	};
	self.instance.upload(&instance, Instance::size);

	// The mesh's own base colour goes in, so `s.albedo` is what the frame handed
	// the body. Its alpha does not: see `Instance.color` above.
	DrawRecord record = {
		.positions = mesh.positions.address,
		.normals = mesh.has_normals ? mesh.normals.address : 0,
		.uvs = mesh.uvs.address,
		.colors = mesh.has_colors ? mesh.colors.address : 0,
		// A skinned mesh bakes in its bind pose, which is the pose its vertices are
		// written to the file in. Posing it would bake a frame of an animation into
		// a texture that the geometry beside it does not match.
		.joints = 0,
		.weights = 0,
		.palette = 0,
		.posed = 0,
		.base_color = { mesh.base_color[0], mesh.base_color[1], mesh.base_color[2], 1 },
		.flags = (mesh.has_normals ? FLAG_HAS_NORMALS : 0)
			| FLAG_HAS_UVS
			| (mesh.has_colors ? FLAG_HAS_COLORS : 0),
		.skin_stride = 0,
		.uv_transform = material.uv_transform_or_identity(),
		.surface = material.surface(),
	};
	self.draw.upload(&record, DrawRecord::size);

	ulong table_address = 0;
	if (material.table.len > 0)
	{
		if (self.table_capacity < (sz)material.table.len)
		{
			if (self.table.buffer != null) self.table.free();
			vk::Memory? grown = self.gpu.create_dynamic((sz)material.table.len);
			if (catch grown) return false;
			self.table = grown;
			self.table_capacity = (sz)material.table.len;
		}
		mem::copy(self.table.data(), material.table.ptr, material.table.len);
		table_address = self.table.address;
	}

	if (catch self.record(pipeline, material, mesh, table_address)) return false;

	// Host-coherent, and the single-time command has already waited — the same
	// reason `Texture.read_pixels` maps and copies with nothing in between.
	mem::copy(out.ptr, self.readback.data(), self.bytes());
	return true;
}

<*
 Spreads the baked colour into the texels no triangle covered.

 A two-pass chamfer sweep rather than a flood: forward over the image carrying
 each texel's distance to the nearest written one, then backward doing the same
 from the other side. Two linear passes fill the whole image, which is what makes
 this affordable at one bake per mesh — a repeated 3x3 spread would need a pass
 per texel of gap and is where the obvious implementation of this becomes the
 slowest thing in an export.

 The distances are approximate, in the way every chamfer transform's are, and it
 does not matter at all: what is wanted is a plausible colour where there was
 none, not the exactly nearest one.

 **Only the colour moves.** The alpha stays where the rasteriser left it, so a
 body that discards still has its shape and what this fills is the colour
 *underneath* the cut — which is exactly what stops a filtered edge from fringing
 dark.

 @require texels.len >= (sz)self.size * (sz)self.size * 4
*>
fn void MaterialBaker.dilate(&self, char[] texels)
{
	uint size = self.size;
	sz count = (sz)size * (sz)size;
	if (self.spread.len < count) return;

	// Zero is written, `uint::max` is "nothing has reached here yet". A written
	// texel never moves, because nothing can be closer to it than itself.
	for (sz i = 0; i < count; i++)
	{
		self.spread[i] = texels[i * 4 + 3] >= 128 ? 0 : uint::max;
	}

	for (uint y = 0; y < size; y++)
	{
		for (uint x = 0; x < size; x++)
		{
			self.reach(texels, x, y, x - 1, y);
			self.reach(texels, x, y, x, y - 1);
			self.reach(texels, x, y, x - 1, y - 1);
			self.reach(texels, x, y, x + 1, y - 1);
		}
	}
	for (uint y = size; y > 0; y--)
	{
		for (uint x = size; x > 0; x--)
		{
			self.reach(texels, x - 1, y - 1, x, y - 1);
			self.reach(texels, x - 1, y - 1, x - 1, y);
			self.reach(texels, x - 1, y - 1, x, y);
			self.reach(texels, x - 1, y - 1, x - 2, y);
		}
	}
}

<*
 One step of the sweep: take `from`'s colour if it stands closer to a written
 texel than anything that has reached `to` so far.

 The coordinates are unsigned and the neighbours are written as `x - 1`, so a
 step off the left or top edge wraps to a very large number rather than going
 negative — which the bounds check catches either way. Written that way because
 the alternative is signed coordinates everywhere and a cast at every index.
*>
fn void MaterialBaker.reach(&self, char[] texels, uint x, uint y, uint fx, uint fy)
{
	uint size = self.size;
	if (x >= size || y >= size || fx >= size || fy >= size) return;

	sz to = (sz)y * (sz)size + (sz)x;
	sz from = (sz)fy * (sz)size + (sz)fx;
	if (self.spread[from] == uint::max) return;

	uint reached = self.spread[from] + 1;
	if (reached >= self.spread[to]) return;

	self.spread[to] = reached;
	texels[to * 4] = texels[from * 4];
	texels[to * 4 + 1] = texels[from * 4 + 1];
	texels[to * 4 + 2] = texels[from * 4 + 2];
}
