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

<*
 The light a renderer starts on: down and to the right, from slightly in front,
 with a quarter of the surface's colour reaching the shadowed side.

 Named rather than written twice for `DEFAULT_CLEAR`'s reason — it is now
 something a script can ask to be restored to, and two spellings of a default
 drift. `three.light` is the verb; `the_default_light_is_the_pass_light` keeps
 `prelude.js` agreeing with this number.

 **Not normalized here.** The shaders normalize on read, so the magnitude of the
 direction has never meant anything, and normalizing at the door would make
 `three.light.direction` answer with numbers a script did not write.
*>
const float[4] DEFAULT_LIGHT = { 0.35, 0.80, 0.45, 0.25 };

struct MeshPass
{
	// Compiled on demand and kept by content hash. `pipeline` is borrowed from
	// it — the cache owns every pipeline it hands out and frees them all.
	PipelineCache pipelines;
	MeshPipeline* pipeline;
	// The same shader over `LINE_STATE`. `LINE_MATERIAL` is the index that reaches
	// it, and this is the pointer that index resolves to.
	MeshPipeline* line_pipeline;
	// The same shader again, over `ALPHA_STATE` and `ADDITIVE_STATE`. These are
	// what a `three.MeshLambertMaterial` with `transparent: true` draws with.
	//
	// Held here rather than acquired when one is asked for, and that is a design
	// decision rather than an optimisation: `create_texture_material` promises in
	// its own doc block that putting a picture on a box needs no device, no Slang
	// and no new pipeline, and a lazily-acquired variant would break all three the
	// first time a script wrote `transparent: true`. Building them here costs one
	// `VkPipeline` each — about a millisecond, no Slang at all, since `acquire`
	// keys the compile on the source and this is the same `mesh.slang` byte for
	// byte — and it happens once at startup where nothing is waiting on a frame.
	MeshPipeline* alpha_pipeline;
	MeshPipeline* additive_pipeline;
	// Every material any node can name. Index 0 is `DEFAULT_MATERIAL`, built in
	// `init` from `pipeline`, so a scene that never mentions a material still has
	// one. Lives here rather than on `JsRuntime` for the same reason `assets`
	// does: `new three.Scene()` resets the graph, and a material an agent
	// compiled should survive that exactly as a loaded `.glb` does.
	List{Material} materials;
	Assets assets;
	Scene scene;
	Camera camera;
	// The render target's width over its height, kept current by `record`.
	// `frame_camera` needs it and has no target to ask — it is reached from a
	// script, between frames — and fitting a 16:9 frame as though it were square
	// is most of why `frameAll` used to leave the subject at a third of the
	// width. Seeded in `init` so the very first fit, before any frame has been
	// recorded, is already right.
	float aspect;
	// xyz: surface-to-light in world space. w: the ambient floor, which keeps
	// unlit faces readable rather than black.
	float[4] light;
	// How many materials have had their handle given back and are still named by
	// a node. Nonzero is the only thing that makes `record` walk the scene for
	// collectible materials, so the sweep costs nothing in the overwhelmingly
	// common case of a scene where nobody has disposed anything.
	uint pending_materials;

	// Per frame in flight — see the header.
	vk::Memory[MAX_FRAMES_IN_FLIGHT] frame_blocks;
	vk::Memory[MAX_FRAMES_IN_FLIGHT] instance_buffers;
	sz[MAX_FRAMES_IN_FLIGHT] instance_capacity;
	// One `DrawRecord` per bucket, for the same reason and with the same lifetime
	// as the instance array beside it: written by the CPU during recording, read
	// by the GPU when the frame runs, and safe to overwrite only once this slot's
	// fence has been waited on.
	vk::Memory[MAX_FRAMES_IN_FLIGHT] draw_buffers;
	sz[MAX_FRAMES_IN_FLIGHT] draw_capacity;

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

		// And the two blended variants, for the same reason and at the same price.
		// Neither is claimed by a built-in material — nothing draws with them until
		// a script asks for a transparent one — so unlike the two above they take
		// no second reference here: what `acquire` handed back is the pass's own,
		// and `create_texture_material` retains per material on top of it.
		self.alpha_pipeline = self.pipelines.acquire(gpu, target, source, path, ALPHA_STATE)!;
		self.additive_pipeline = self.pipelines.acquire(gpu, target, source, path, ADDITIVE_STATE)!;
	};

	// `DEFAULT_MATERIAL` is index 0 and is built here, before anything can ask for
	// a material, so `Node.material` never has to mean "none". Its uniform block
	// is empty: `mesh.slang` declares no fields past `flags`, so nothing above
	// `MATERIAL_PUSH_START` is ever read out of it.
	//
	// `LINE_MATERIAL` is index 1 and is built beside it for the same reason: a
	// node's material is a `uint`, so the pass has to be able to hand out an index
	// that means "draw this as lines" before any script has asked for one.
	//
	// Both name `NO_TEXTURE` explicitly. Leaving it out would zero-fill the field
	// to texture 0, so every untextured node in the scene would draw with the
	// first image any asset happened to upload — see `Material.texture`.
	//
	// Both take a reference on the pipeline they draw with, on top of the one
	// `acquire` gave the field above. Every stored `MeshPipeline*` in this file is
	// a counted borrow without exception — the alternative, "the pass's own two
	// are special", is a rule that has to be remembered at every future release.
	self.materials.init(mem, 4);
	self.pipelines.retain(self.pipeline);
	self.claim_slot({
		.pipeline = self.pipeline, .cull = CULL_MODE_BACK_BIT, .fragment = "", .texture = NO_TEXTURE
	});
	// No culling for lines: a segment has no facing, and `CULL_MODE_NONE` is what
	// keeps a wireframe from losing half its edges to a rule about triangles.
	self.pipelines.retain(self.line_pipeline);
	self.claim_slot({
		.pipeline = self.line_pipeline, .cull = CULL_MODE_NONE, .fragment = "", .texture = NO_TEXTURE
	});

	self.assets.init(gpu);
	self.scene.init();
	// The scene counts references against this table from here on — see
	// `Scene.attach_assets`. Wired at construction rather than at first load,
	// because a node created before the wiring would never be counted and the
	// asset it named could then be swept out from under it.
	self.scene.attach_assets(&self.assets);
	self.camera = default_camera();
	self.light = DEFAULT_LIGHT;
	// The first `frame_camera` can run before any frame has been recorded — the
	// CLI loads a file and fits the camera to it during startup — so the aspect
	// starts from the target rather than from zero. A zero-height target would
	// make this a NaN that `frame_bounds` reads as "no aspect given"; it is
	// guarded there rather than here, because the same is true of every later
	// resize and one guard at the point of use is the one that cannot be missed.
	self.aspect = (float)target.extent.width / (float)target.extent.height;

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
 Put a material in the table and answer the index that names it.

 **The one place a material becomes live.** `alive` is never written at a
 construction site, so C3's zero fill cannot produce a material that is dead the
 moment it is built — the mirror of the hazard `Material.texture` describes,
 where the zero fill produces something that is wrong rather than something that
 is missing.

 A collected slot is reused before the list grows. That is what keeps an agent
 building a material per run from growing this table for the life of the
 process, and it is safe for the same reason the collection was: a slot is only
 free once no node names it and the script's handle has been given back, so
 there is no live index left to be surprised by the new occupant.
*>
fn uint MeshPass.claim_slot(&self, Material material)
{
	material.alive = true;

	foreach (i, &existing : self.materials)
	{
		if (existing.alive) continue;
		*existing = material;
		return (uint)i;
	}

	uint index = (uint)self.materials.len();
	self.materials.push(material);
	return index;
}

<*
 Resolve a material index.

 @return `The material, or null if the index names nothing — which the draw loop treats as "skip this bucket" rather than as a fault.`
*>
fn Material* MeshPass.material(&self, uint index)
{
	if (index >= self.materials.len()) return null;
	Material* material = &self.materials[index];
	// A collected slot names nothing. It answers null rather than handing back
	// the zeroed struct, which would resolve to a null pipeline and crash the
	// draw loop instead of skipping the bucket the way an unknown index does.
	if (!material.alive) return null;
	return material;
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
 are written down; this stays as the verb `load` and `load_triangle` reach for.

 @return `The group the asset was instantiated into, or the parent it was given if the handle names nothing.`
*>
fn NodeId MeshPass.place(&self, AssetId asset, NodeId parent)
{
	NodeId group = self.scene.instantiate(asset, parent);
	return group.is_set() ? group : parent;
}

<*
 Aim the camera at everything in the scene.

 Refitted here rather than left where it was because the caller has no idea how
 big the scene's contents are — see `Camera.frame_bounds`.
*>
fn void MeshPass.frame_camera(&self)
{
	collision::Aabb3 bounds = self.scene.bounds(&self.assets);
	self.camera.frame_bounds(bounds.min, bounds.max, self.aspect);
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

 @param slot : `Which frame in flight this is. Selects the instance array and the draw records to write, and must be one whose fence has already been waited on.`
*>
fn void? MeshPass.record(&self, Gpu* gpu, vk::CommandBuffer cmd, Target* target, uint slot)
{
	if (!self.ready) return;

	// Before the draw list is built, so a material whose last node died in the
	// same breath as the dispose does not have its pipeline held for one more
	// frame than it needs to be. Costs nothing unless something is pending.
	self.collect_materials(gpu);

	float aspect = (float)target.extent.width / (float)target.extent.height;
	// Remembered for `frame_camera`, which runs between frames and so has no
	// target of its own to measure. A resize therefore reaches the next fit.
	self.aspect = aspect;
	Matrix4f view_projection = self.camera.view_projection(aspect);

	// **The whole of what `Scene` is told about materials**, and deliberately not a
	// pointer to them. `Scene.set_material`'s doc block draws the boundary: the
	// scene graph has no view of `MeshPass.materials`, and giving it one would put
	// the render pass inside the scene graph to save a loop. Draw ordering needs
	// exactly one bit per material index — does this one blend — so one bit per
	// index is what crosses: a flat `bool[]` off the temp arena, built here, read
	// only for the length of the call.
	//
	// Indexed by material index and exactly as long as the table, so a node naming
	// a material past the end reads as opaque — which is the right answer for a
	// bucket the draw loop below is going to skip anyway. `alive` is asked for the
	// same reason `MeshPass.material` asks it: a collected slot names nothing, and
	// reading a blend mode off one would be reading a material that is not there.
	// `Material.free` happens to zero the field, so this guard changes no answer
	// today; it is here so that it never has to.
	@pool()
	{
		bool[] transparent = alloc::new_array(tmem, bool, self.materials.len());
		// Beside it and built in the same pass, because it answers a question of
		// the same shape — something the *material* knows that the *scene* needs
		// while it is culling. See `Material.bounds`: a body that moves a vertex
		// draws outside the box the frustum was asked about.
		float[] margins = alloc::new_array(tmem, float, self.materials.len());
		foreach (i, &material : self.materials)
		{
			transparent[i] = material.alive && material.blend != BlendMode.NONE;
			margins[i] = material.alive ? material.bounds : 0;
		}
		self.scene.update(&self.assets, view_projection, transparent, margins);
	};
	if (self.scene.buckets.len() == 0) return;

	FrameBlock frame = { .view_projection = view_projection, .light = self.light };
	ulong frame_address = self.write_frame_block(gpu, slot, &frame)!;
	ulong instance_address = self.write_instances(gpu, slot)!;

	// The draw records are written *into* the loop below rather than in a pass of
	// their own: a record is exactly the fields the push block used to carry, so
	// building it needs the mesh, the material and the base colour that the draw
	// already resolves, and a second loop would be a second copy of that
	// resolution to keep in step. The buffer is host-visible and coherent and the
	// frame is not submitted until recording ends, so writing it as the commands
	// are recorded is the same thing as writing it beforehand.
	//
	// Sized against every bucket, including the ones the loop skips. Their records
	// are stale bytes nothing points at — the counter below only advances for a
	// bucket that draws — and the alternative is a count that has to predict which
	// buckets those are.
	self.reserve_draws(gpu, slot, self.scene.buckets.len())!;
	ulong draw_address = self.draw_buffers[slot].address;
	DrawRecord* records = (DrawRecord*)self.draw_buffers[slot].data();
	uint recorded = 0;

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
		//
		// **The material's own texture wins over the mesh's.** `material.map` is
		// the explicit statement and the mesh's image is what a file happened to
		// bring, so a script that sets one and gets the other would be overruled
		// by an asset it did not write. This costs nothing to decide here: the
		// descriptor is already written per bucket, and a bucket is
		// `(asset, mesh, material)` — so two nodes over one mesh with different
		// maps are already two buckets and stay two correct draws.
		Texture* sampled = material.texture == NO_TEXTURE
			? self.assets.texture_for(mesh)
			: self.assets.texture_at(material.texture);

		// Binding 0 by hand and everything above it from the shader's own
		// reflection — `render/bind.c3` has the argument, and the short version is
		// that only this line knows binding 0 is "the material's map or the mesh's
		// image". A body that declared `noise_map` gets it at whatever index the
		// assembler generated, resolved by name, with white in any sampler the
		// script left empty.
		SampledBindings samplers;
		samplers.add(0, sampled.descriptor());
		samplers.collect(pipeline, &material.textures, &self.assets, MATERIAL_BINDING_FIRST);
		samplers.push(cmd, pipeline);

		// The mesh's own factor, faded by the material's opacity. Multiplied rather
		// than replaced so that a glTF's own alpha and a script's `opacity` compose
		// — the file said what the surface is, the script says how much of it to
		// show — and it is the only place the two meet.
		//
		// Costs nothing on an opaque material: `Material.opacity` is 1 unless
		// somebody set it, and the opaque pipeline discards the alpha regardless.
		float[4] base_color = mesh.base_color;
		base_color[3] *= material.opacity();

		records[recorded] = {
			.positions = mesh.positions.address,
			.normals = mesh.has_normals ? mesh.normals.address : 0,
			.uvs = mesh.has_uvs ? mesh.uvs.address : 0,
			.colors = mesh.has_colors ? mesh.colors.address : 0,
			.base_color = base_color,
			.flags = (mesh.has_normals ? FLAG_HAS_NORMALS : 0)
				| (mesh.has_uvs ? FLAG_HAS_UVS : 0)
				| (mesh.has_colors ? FLAG_HAS_COLORS : 0),
			.uv_transform = material.uv_transform_or_identity(),
		};

		MeshPush push = {
			.frame = frame_address,
			// Offset on the CPU rather than passed as a base index: the shader
			// then reads instance zero of its own slice and never has to know
			// whether SV_InstanceID includes firstInstance.
			.instances = instance_address + (ulong)bucket.first * Instance::size,
			// And the record just written, for the same reason — `push.draw[0]`
			// is this bucket's, whatever else is in the buffer.
			.draw = draw_address + (ulong)recorded * DrawRecord::size,
		};
		recorded++;
		// **The reflected size, not `MeshPush::size`.** The two agree at 24 today
		// and have not always: the block used to end in a `uint` that C3 followed
		// with four bytes of tail padding, so Slang reported 76 where the struct
		// occupied 80, and pushing 80 into a 76-byte range is a validation error.
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
 Make sure this slot's draw buffer holds `count` records, growing it if not.

 The twin of `write_instances` and deliberately shaped like it — doubling rather
 than fitting, freeing the old buffer only after the slot's fence has been waited
 on — with one difference: this reserves and does not write. The records are
 filled through the mapped pointer as `record` walks the buckets, because what
 goes in one is what the draw itself has just resolved.

 A count of zero still allocates, so `record` can take `.data()` without a null
 check; `INITIAL_INSTANCES` is the floor for both buffers and a frame with no
 buckets has already returned by the time this is called.
*>
fn void? MeshPass.reserve_draws(&self, Gpu* gpu, uint slot, sz count)
{
	if (self.draw_capacity[slot] >= count) return;

	sz capacity = self.draw_capacity[slot] > 0 ? self.draw_capacity[slot] : INITIAL_INSTANCES;
	while (capacity < count) capacity *= 2;

	if (self.draw_buffers[slot].buffer != null) self.draw_buffers[slot].free();

	self.draw_buffers[slot] = gpu.create_dynamic((sz)(capacity * DrawRecord::size))!;
	self.draw_capacity[slot] = capacity;
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

 The blend mode is part of the pipeline and so is decided here, once. It costs
 **no extra compile**: the cache keys the SPIR-V on the source and the pipeline
 on the render state, so a body written twice — once opaque, once transparent —
 is one Slang call and two `VkPipeline` objects. There is no setter for the same
 reason; `Material.blend` says why.

 @param side : `SIDE_FRONT, SIDE_BACK or SIDE_DOUBLE — which faces survive culling.`
 @param blending : `BLENDING_NONE, BLENDING_NORMAL or BLENDING_ADDITIVE. Baked into the pipeline, so it cannot change afterwards.`
 @param textures : `Samplers the body wants, in declaration order. Declared here and filled afterwards, one set_material_texture per name, because that is where the references are taken.`
 @param vertex : `A void displace(inout Vertex v) body, or empty for a material that does not move its geometry.`
 @param bounds : `How far that body can move a vertex, world units. Grows the box the frustum is tested against — see Material.bounds.`
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
	int blending = BLENDING_NONE,
	MaterialTexture[] textures = {},
	String vertex = "",
	float bounds = 0,
	String* diagnostic = null
)
{
	uint index;
	BlendMode blend = blend_for(blending);
	@pool()
	{
		String source = material_source(fragment, uniforms, tmem, textures, vertex)!;
		MeshPipeline* pipeline = self.pipelines.acquire(
			gpu, target, source, "three.material", state_for_blend(blend), diagnostic
		)!;

		// The reference `acquire` handed out is the material's from here — no
		// retain, because there is no second holder.
		index = self.claim_slot({
			.pipeline = pipeline,
			.cull = cull_for_side(side),
			.blend = blend,
			.fragment = fragment.copy(mem),
			// Copied only when there is one, so a material without a vertex body
			// carries a zero slice rather than a pointer into static memory that
			// `Material.free` would hand to the allocator.
			.vertex = vertex.len > 0 ? vertex.copy(mem) : (String){},
			.bounds = bounds,
			// A `ShaderMaterial` can be given a `map` afterwards like any other
			// material — `material.slang` declares the same binding 0 that
			// `mesh.slang` does, so `Surface.uv` samples it either way. It just
			// does not start with one.
			.texture = NO_TEXTURE,
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

<*
 `material.opacity = ...` — how much of what is behind this material shows
 through it.

 Settable, unlike the blend mode beside it, and the difference is the whole
 shape of this file: opacity is *push data*, multiplied into the alpha `record`
 sends with the draw, so changing it costs a float and reaches the next frame.
 Blending is pipeline state, so changing that would cost a pipeline. One is a
 setter, the other is a constructor argument, and which is which is decided by
 the hardware rather than by taste.

 **It does nothing on a material that is not transparent**, and that is stated
 rather than enforced: an opaque pipeline discards the alpha it writes, so the
 number is stored, reported and simply never read. Refusing it would be refusing
 the order a script naturally writes things in, and Three.js behaves the same way.

 Stored as its complement — `Material.one_minus_opacity` has the argument, and
 this is one of the two places that knows.

 **The built-in materials are refused**, for `set_material_side`'s reason:
 `DEFAULT_MATERIAL` is shared by every node that was never given a material of
 its own, so fading it would fade the entire scene through a handle that reads
 like it names one thing. `LINE_MATERIAL` is refused because debug lines draw
 over everything by design and a half-faded helper is not a thing anyone asked
 for.

 The range is not checked here. The JS boundary refuses anything outside 0..1 by
 name, which is where a script's mistake can be reported against the line that
 made it; this is the floor under that.

 @return? MATERIAL_UNKNOWN : `No such material, or one of the two built-in ones, which are shared.`
*>
fn void? MeshPass.set_material_opacity(&self, uint index, float opacity)
{
	if (index == DEFAULT_MATERIAL || index == LINE_MATERIAL) return MATERIAL_UNKNOWN~;
	Material* material = self.material(index);
	if (material == null) return MATERIAL_UNKNOWN~;

	material.one_minus_opacity = 1.0f - opacity;
}

<*
 What `material.opacity` reads back as.

 An index that names nothing answers 1.0 rather than faulting, which is
 `material_uv`'s rule: a getter on a disposed handle should say what a material
 that never asked for anything would say, and every material starts opaque.
*>
fn float MeshPass.material_opacity(&self, uint index)
{
	Material* material = self.material(index);
	if (material == null) return 1.0f;
	return material.opacity();
}

<*
 A material that is the built-in shader plus an image — `three.MeshLambertMaterial`.

 **No Slang, no device, no new pipeline.** It borrows one of the pass's own
 pipelines — `self.pipeline` is the very one `DEFAULT_MATERIAL` draws with — so
 building one is a push onto a list and a retain. That is why it is its own verb
 rather than a `ShaderMaterial` with a one-line body: putting a picture on a box
 should not compile a shader, it should not be able to fail with a compiler
 diagnostic, and in a build with no Slang it could not happen at all.

 **That promise is what makes the blend variants prebuilt.** A blend mode is a
 pipeline field on this device (`BlendMode` has the measurement), so a
 transparent material needs a different `VkPipeline` from an opaque one — and
 building it here would need the `Gpu` and the `Target` this signature does not
 take, inside whichever frame first said `transparent: true`. `MeshPass.init`
 builds all three up front instead: same `mesh.slang`, so no Slang call, about a
 millisecond each, once, at startup. This function stays a list push and a
 retain, and picks among them.

 **It has no colour of its own, deliberately.** `mesh.color` is the per-copy
 channel and `mesh.slang` multiplies it into the sampled texel, so a tinted
 textured mesh already works and a thousand of them are still one draw call. A
 colour on the material would be a second way to say the same thing that also
 splits the bucket.

 The texture is retained here and released by `MeshPass.free` or by
 `set_material_map` pointing this material somewhere else. The reference the
 script's own handle holds is a different one, and `dispose()` drops only that:
 a material outlives the handle that supplied its image.

 **`NO_TEXTURE` is allowed and is not a pointless material.** It is the built-in
 shader with a `side` of its own, which is the cheapest possible skydome: a
 sphere seen from inside shows only back faces, and before this the only way to
 ask for `BackSide` was to compile a `ShaderMaterial` for it. A material that
 wants neither an image nor a side should still be `DEFAULT_MATERIAL`, which
 costs no slot at all.

 @param texture : `An index into Assets.textures, or NO_TEXTURE for the mesh's own image.`
 @param side : `SIDE_FRONT, SIDE_BACK or SIDE_DOUBLE — which faces survive culling.`
 @param blending : `BLENDING_NONE, BLENDING_NORMAL or BLENDING_ADDITIVE. Selects one of the three pipelines built in init; nothing is compiled here whichever it is.`
 @return `The material index, for Node.material.`
 @return? MATERIAL_TEXTURE_UNKNOWN : `No such texture: a disposed handle, or one from another context.`
*>
fn uint? MeshPass.create_texture_material(&self, int texture, int side = SIDE_FRONT, int blending = BLENDING_NONE)
{
	if (texture != NO_TEXTURE && !self.assets.texture_alive(texture)) return MATERIAL_TEXTURE_UNKNOWN~;

	// Retained before the push, so the count says the material names the slot
	// from the first instant it does. A no-op for `NO_TEXTURE`, which names none.
	self.assets.retain_texture(texture);

	BlendMode blend = blend_for(blending);
	MeshPipeline* pipeline = self.pipeline;
	switch (blend)
	{
		case ALPHA: pipeline = self.alpha_pipeline;
		case ADDITIVE: pipeline = self.additive_pipeline;
		case NONE: break;
	}
	// Retained rather than acquired. This borrows a pipeline the pass already
	// holds instead of asking the cache for the built-in shader again — it knows
	// the answer — so the reference has to be taken by hand.
	self.pipelines.retain(pipeline);
	return self.claim_slot({
		.pipeline = pipeline,
		.cull = cull_for_side(side),
		.blend = blend,
		.fragment = "",
		.texture = texture,
	});
}

<*
 `material.repeat` / `material.offset` — how the texture is laid across a
 surface.

 ## Why this is on the material and not on the texture

 Three.js puts `repeat` and `offset` on the `Texture`, and it is a well-known
 trap there: two materials sharing a texture cannot disagree, so the answer is to
 clone the texture. Here it would be worse than a trap. Textures are
 deduplicated by a content hash across every file and every `DataTexture`, so a
 `.png` on disk and the identical image inside a `.glb` are deliberately **one**
 slot — putting a transform on that slot would make a brick wall's tiling change
 because something unrelated used the same brick image, with nothing in either
 script mentioning the other.

 On the material it costs nothing extra: `map` already lives there, a material is
 already one bucket, and two surfaces wanting the same image at different
 densities are two materials, which is what they already had to be.

 ## Zero is refused rather than accepted

 A repeat of zero maps every texel of a surface to one point of the texture, so
 it is never what anyone meant — and it is exactly what a struct field left
 unset looks like. `Material.uv_transform_or_identity` reads all-zero as "no
 transform"; this refuses to write one, so the two cannot be confused.

 @param repeat_u : `Times across. Must not be zero.`
 @return? MATERIAL_UNKNOWN : `No such material in this context.`
 @return? MATERIAL_REPEAT_IS_ZERO : `A repeat of zero collapses the surface onto one texel.`
*>
fn void? MeshPass.set_material_uv(&self, uint index, float repeat_u, float repeat_v, float offset_u, float offset_v)
{
	if (index >= self.materials.len()) return MATERIAL_UNKNOWN~;
	if (repeat_u == 0 || repeat_v == 0) return MATERIAL_REPEAT_IS_ZERO~;

	self.materials[index].uv_transform = { repeat_u, repeat_v, offset_u, offset_v };
}

<*
 What `material.repeat` and `material.offset` read back as.
*>
fn float[4] MeshPass.material_uv(&self, uint index)
{
	if (index >= self.materials.len()) return UV_IDENTITY;
	return self.materials[index].uv_transform_or_identity();
}

<*
 `material.map = texture` — point a material at an image, or at `NO_TEXTURE`.

 **The built-in materials are refused**, for `set_material_side`'s reason and
 more sharply. `DEFAULT_MATERIAL` is what every node draws with until it is given
 something else, so a map set on it would texture the entire scene through a
 handle that reads like it names one material. `LINE_MATERIAL` is refused because
 a debug line carries no uvs, so the setting would be one that silently does
 nothing.

 **A mesh with no uvs is not refused and cannot be**, which is the one surprise
 worth stating out loud: `mesh.slang` samples only under `FLAG_HAS_UVS`, so a map
 on a convex hull — which has no natural parameterisation and uploads no uv
 stream — renders exactly as it did without one. The material is not wrong and
 the texture is not missing; there is nowhere on that geometry to put it. The
 parametric shapes and glTF meshes all carry uvs, so this is the hull case and
 the hull case only.

 @param gpu : `For the wait below. Null in a scene-math runtime, which has nothing in flight.`
 @return? MATERIAL_UNKNOWN : `No such material, or one of the two built-in ones, which are shared.`
 @return? MATERIAL_TEXTURE_UNKNOWN : `No such texture.`
*>
fn void? MeshPass.set_material_map(&self, Gpu* gpu, uint index, int texture)
{
	if (index == DEFAULT_MATERIAL || index == LINE_MATERIAL) return MATERIAL_UNKNOWN~;
	Material* material = self.material(index);
	if (material == null) return MATERIAL_UNKNOWN~;
	if (texture != NO_TEXTURE && !self.assets.texture_alive(texture)) return MATERIAL_TEXTURE_UNKNOWN~;
	if (material.texture == texture) return;

	// **Retain before release**, even though it reads redundant. The two indices
	// can name the same slot — a script can reach one texture through two
	// handles, and both resolve to one entry because the table deduplicates by
	// content — and releasing first would take that entry to zero, destroy the
	// image, and retain a slot that had just been freed.
	if (texture != NO_TEXTURE) self.assets.retain_texture(texture);

	// The old image goes only if nothing else names it, and a frame in flight may
	// still be sampling the one about to be destroyed — the hazard `unload_unused`
	// waits for. Waited only when this release is the last one, so re-pointing a
	// map inside a frame callback costs no stall at all.
	if (gpu != null && self.assets.texture_refs(material.texture) == 1) gpu.wait_idle();
	self.assets.release_texture(gpu, material.texture);

	material.texture = texture;
}

<*
 `material.textures.<name> = texture` — put an image in one of the sampler
 bindings the body declared.

 `set_material_map` for the bindings above zero, and the differences are all in
 the first line: the binding is found **by name, through the shader's own
 reflection**, so a script says `noise_map` and never says `1`. `map` keeps its
 own verb because binding 0 is the one binding no agent declared — it is the
 template's, it is what an untextured mesh falls back through, and reaching it by
 the name the template happens to use would make `base_color_map` part of the
 script-facing API.

 **The built-in materials are refused**, for `set_material_map`'s reason and more
 simply: neither declares a sampler past binding 0, so there is no name here that
 could resolve.

 The retain/release dance is `set_material_map`'s exactly — retain before release
 because the two indices can name the same slot, and wait for the device only when
 this release is the last reference to an image a frame in flight may be sampling.

 @param name : `The sampler as the body spells it.`
 @param texture : `An index into Assets.textures, or NO_TEXTURE to put white back.`
 @return? MATERIAL_UNKNOWN : `No such material, or one of the two built-in ones.`
 @return? MATERIAL_TEXTURE_UNKNOWN : `No such texture: a disposed handle, or one from another context.`
 @return? MATERIAL_SAMPLER_UNKNOWN : `This material's shader has no sampler by that name.`
*>
fn void? MeshPass.set_material_texture(&self, Gpu* gpu, uint index, String name, int texture)
{
	if (index == DEFAULT_MATERIAL || index == LINE_MATERIAL) return MATERIAL_UNKNOWN~;
	Material* material = self.material(index);
	if (material == null) return MATERIAL_UNKNOWN~;
	if (texture != NO_TEXTURE && !self.assets.texture_alive(texture)) return MATERIAL_TEXTURE_UNKNOWN~;

	uint binding = material.binding_of_texture(name);
	if (binding == 0) return MATERIAL_SAMPLER_UNKNOWN~;

	int held = material.textures.at(binding);
	if (held == texture) return;

	if (texture != NO_TEXTURE) self.assets.retain_texture(texture);
	if (gpu != null && self.assets.texture_refs(held) == 1) gpu.wait_idle();
	self.assets.release_texture(gpu, held);

	material.textures.set(binding, texture);
}

<*
 Which texture is in one of a material's own sampler bindings.

 `NO_TEXTURE` for a material that does not exist and for a name that is not one of
 its samplers alike, which is `material_opacity`'s rule: a getter answers what a
 material that was never given anything would answer rather than faulting, and the
 *setter* is where a bad name is reported against the line that wrote it.
*>
fn int MeshPass.material_texture(&self, uint index, String name)
{
	Material* material = self.material(index);
	if (material == null) return NO_TEXTURE;
	return material.textures.at(material.binding_of_texture(name));
}

<*
 `material.dispose()` — give back the script's reference to a material.

 **Not a free**, and the wording is `texture.dispose()`'s on purpose because the
 rule is the same one. A material is collected when the handle has been given
 back *and* no node still names it. Disposing while a mesh is still drawing with
 it leaves that mesh correct and collects the material when the mesh goes —
 which is what makes this safe to call as soon as a script is done *referring* to
 the material, rather than something that has to be timed against the scene.

 The alternative was to refuse the call while a node still names it. That reads
 stricter and is worse: `new three.Scene()` followed by a rebuild is the shape
 an agent iterating actually writes, and under a refusal every one of those runs
 would have to dispose in an order nobody wants to think about.

 **The built-in materials are refused**, for `set_material_side`'s reason.
 `DEFAULT_MATERIAL` is what every node without a material of its own draws with,
 so collecting it would take the pipeline out from under the whole scene.

 Disposing twice is not an error — the second call has nothing to give back.

 @param gpu : `For the collection this may trigger. Null defers it to the next one that has a device.`
 @return? MATERIAL_UNKNOWN : `No such material, or one of the two built-in ones, which are shared.`
*>
fn void? MeshPass.dispose_material(&self, Gpu* gpu, uint index)
{
	if (index == DEFAULT_MATERIAL || index == LINE_MATERIAL) return MATERIAL_UNKNOWN~;
	Material* material = self.material(index);
	if (material == null) return MATERIAL_UNKNOWN~;
	if (material.released) return;

	material.released = true;
	self.pending_materials++;
	self.collect_materials(gpu);
}

<*
 Free every material whose handle is gone and which no node names.

 Run from `dispose_material`, which is when the first half becomes true, and
 from `record`, which is the only reliable point at which the *second* half
 changes: nodes die through `Scene.kill` and through `new three.Scene()`, and
 neither tells the pass anything. Guarded on `pending_materials`, so a scene
 nobody has disposed in never walks its nodes for this at all.

 One pass over the nodes rather than one per candidate. The candidates are
 usually one and the nodes are usually thousands, so the loop that has to be
 cheap is the one over nodes.
*>
fn void MeshPass.collect_materials(&self, Gpu* gpu)
{
	if (self.pending_materials == 0) return;

	@pool()
	{
		bool[] named = alloc::new_array(tmem, bool, self.materials.len());
		foreach (&node : self.scene.nodes)
		{
			if (!node.alive) continue;
			if (node.material < named.len) named[node.material] = true;
		}

		foreach (i, &material : self.materials)
		{
			if (!material.alive || !material.released || named[i]) continue;
			self.free_material(gpu, (uint)i);
			self.pending_materials--;
		}
	};
}

<*
 Give back everything one material holds, and empty its slot.

 The texture first and the pipeline second, which is the order the two tables
 were built in. Both are releases rather than frees: an image several materials
 share outlives this one, and so does a pipeline — `PipelineCache.release` has
 the argument for why a last release is still not a destroy.
*>
fn void MeshPass.free_material(&self, Gpu* gpu, uint index)
{
	Material* material = &self.materials[index];

	// The same wait `set_material_map` makes, for the same reason and only when
	// this release is the last one: a frame in flight may still be sampling the
	// image about to be destroyed. The pipeline below needs no equivalent — it
	// goes through the deletion queue, which is that hazard's other answer, and
	// routing images through it too is what `plan.md` §2 wants next.
	//
	// **This can land inside a frame**, since `record` collects. It lands at the
	// top of one, before the draw list is built and immediately after the frame's
	// own fence wait, which is the cheapest moment a stall can happen at — and it
	// happens only when a disposed material held the last reference to an image.
	if (gpu != null && self.assets.texture_refs(material.texture) == 1) gpu.wait_idle();
	self.assets.release_texture(gpu, material.texture);

	// The agent's own samplers, on the same terms. Walked by binding rather than
	// by the reflected layout, because this runs *after* a shader may have been
	// swapped out from under the material and the slots are the record of what is
	// actually held: a reference is released by whoever took it, not by whoever
	// still declares a name for it.
	for (uint binding = MATERIAL_BINDING_FIRST; binding < MATERIAL_BINDINGS_END; binding++)
	{
		int held = material.textures.at(binding);
		if (held == NO_TEXTURE) continue;
		if (gpu != null && self.assets.texture_refs(held) == 1) gpu.wait_idle();
		self.assets.release_texture(gpu, held);
	}

	self.pipelines.release(gpu, material.pipeline);
	material.free();
}

fn void MeshPass.free(&self, Gpu* gpu)
{
	for (uint i = 0; i < MAX_FRAMES_IN_FLIGHT; i++)
	{
		if (self.frame_blocks[i].buffer != null) self.frame_blocks[i].free();
		if (self.instance_buffers[i].buffer != null) self.instance_buffers[i].free();
		self.instance_capacity[i] = 0;
		if (self.draw_buffers[i].buffer != null) self.draw_buffers[i].free();
		self.draw_capacity[i] = 0;
	}
	self.scene.free();
	// Before `assets.free`, which frees every texture slot outright: releasing
	// afterwards would decrement counts in a freed list. The device is idle by
	// the time a pass is torn down, so no wait is needed here as it is in
	// `set_material_map`.
	// Live slots only. A collected one released its image when it was collected,
	// and `Material.free` leaves `texture` at `NO_TEXTURE` so that a second pass
	// over it here would be a no-op even if this forgot to ask.
	foreach (&material : self.materials)
	{
		if (!material.alive) continue;
		self.assets.release_texture(gpu, material.texture);
		// And the agent's own samplers, on the same terms as `map`. The counts do
		// not survive the next line either way — `assets.free` destroys every slot
		// whatever it is holding — but a teardown that gave back one of a
		// material's five references and not the other four would be the kind of
		// asymmetry that reads as a bug in whichever of the two is looked at
		// second.
		for (uint b = MATERIAL_BINDING_FIRST; b < MATERIAL_BINDINGS_END; b++)
		{
			self.assets.release_texture(gpu, material.textures.at(b));
		}
	}
	self.assets.free(gpu);
	// Before the cache, which owns the pipelines these borrow. No release, unlike
	// `free_material`: `PipelineCache.free` destroys every entry whatever its
	// count says, and routing a teardown through the eviction path would push
	// pipelines into a deletion queue that is about to be drained anyway.
	foreach (&material : self.materials) material.free();
	self.materials.free();
	self.pipelines.free(gpu);
	self.pipeline = null;
	self.line_pipeline = null;
	// The same treatment and for the same reason: these are borrows into a cache
	// that has just destroyed every entry it owned, so there is nothing to give
	// back — only a pointer that must stop looking live.
	self.alpha_pipeline = null;
	self.additive_pipeline = null;
	self.ready = false;
}
