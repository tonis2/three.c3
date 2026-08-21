<*
 The mesh pipeline: one pipeline, one descriptor layout, one push block — and at
 M4, none of the three declared by hand.

 M1 has no material model, and that is deliberate — `base_stage.md` says one
 shader, a base colour texture and a hardcoded directional light, and calls
 anything more "M1 scope creep dressed as polish". The permutation explosion
 that usually follows a material system is avoided here by a different trick:
 the texture binding is *always* present and carries a 1x1 opaque white image
 when the material has none, so an untextured mesh and a textured one are the
 same pipeline.

 ## The push block

 Mirrors `shaders/mesh.slang` exactly:

	frame        0     8      -> FrameBlock, one per frame in flight
	instances    8     8      -> Instance[], already offset to this bucket
	positions   16     8
	normals     24     8
	uvs         32     8
	base_color  40    16
	flags       56     4      = 60 used, 64 with tail padding

 **That table is `MESH_PUSH_FIELDS` below, and it is checked against the shader
 on every pipeline build.** Until M4 it was only a comment, and a comment is
 exactly as good as a `slangc` line in a manifest — `plan.md` §6 has that trap
 already, from the time `-force-glsl-scalar-layout` was in one and not the other.
 Slang reflects the real offsets out of the module that is about to run, so a
 field added to one side and not the other is now a sentence at startup instead
 of geometry read at the wrong address.

 **128 bytes is the budget and it is not a coincidence** — it is the push
 constant size every Vulkan implementation is required to offer, so this pass
 can never be refused by a device. crig's block grew to 192 and needed a
 `check_push_limit` that turns some machines away. When something new wants to
 ride in here, it goes in a buffer instead.

 M2 is the first time that rule had to be obeyed rather than merely stated. The
 old block spent 64 of its 128 bytes on a per-draw `mvp`, which left no room for
 the instance-array pointer instancing needs — 124 + 8 is 132. The two things in
 it that were never per-draw, the view-projection and the light, moved into a
 `FrameBlock` written once a frame and reached through one pointer. What is left
 is 60 bytes and genuinely per-draw, and the budget stopped being tight rather
 than being widened.

 ## The descriptor set layout is derived

 `shader/reflect.c3` reads the bindings out of the compiled module and this file
 hands them to `vkCreateDescriptorSetLayout` unchanged. Nothing here names
 `base_color_map` or knows it is a combined image sampler. That is M4's done
 condition and it is what makes M5's `ShaderMaterial` possible: an agent-written
 shader that declares a different binding gets a layout for the binding it
 declared.
*>
module three;

import std::io;
import std::math;
import std::math::matrix;
import std::collections::list;
import vk;
import slang;

faultdef
	NO_SCALAR_BLOCK_LAYOUT,
	PUSH_BLOCK_TOO_LARGE,
	PUSH_BLOCK_MISMATCH,
	SHADER_BINDING_UNSUPPORTED,
	SHADER_TOO_MANY_SETS,
	SHADER_MISSING_ENTRY_POINT;

const uint FLAG_HAS_NORMALS = 1;
const uint FLAG_HAS_UVS     = 2;

// The size every implementation must offer. Treated as a budget, not a limit
// to grow into.
const uint PUSH_BUDGET = 128;

// The entry points `mesh.slang` is required to contain, and the stages they are
// compiled for. Named rather than discovered — see `compile_slang`.
const ShaderEntry[*] MESH_ENTRIES = {
	{ "vertexMain", slang::STAGE_VERTEX },
	{ "fragmentMain", slang::STAGE_FRAGMENT },
};

<*
 What every draw in a frame shares. One per frame in flight, written before
 recording and read through `MeshPush.frame`.
*>
struct FrameBlock
{
	Matrix4f view_projection;
	float[4] light; // xyz surface-to-light (world), w ambient floor
}

struct MeshPush
{
	ulong frame; // FrameBlock*
	ulong instances; // Instance*, offset to this bucket's first
	ulong positions;
	ulong normals;
	ulong uvs;
	float[4] base_color; // rgb albedo factor, a material alpha
	uint flags;
	// xy repeat, zw offset — `material.repeat` and `material.offset`, applied to
	// the uv before the sample. The eighth pinned field, added when it turned out
	// that a surface mapping its texture exactly once makes texel density a
	// function of how big the mesh is: `examples/village` covered its ground with
	// 484 separate plane meshes purely so one 128px grass texture would not
	// stretch across 132 units.
	float[4] uv_transform;
}

$assert MeshPush::size <= PUSH_BUDGET : "the mesh push block outgrew the 128 bytes every device must offer";
// Not a bound but an equality, because these two numbers are a wire format
// shared with `shaders/mesh.slang` and a silent change to either side is a
// misread buffer rather than an error. `Instance` is in `scene/scene.c3`.
$assert MeshPush::size == 80 : "the push block no longer matches the layout documented above";
$assert FrameBlock::size == 80 : "FrameBlock no longer matches shaders/mesh.slang";
$assert Instance::size == 148 : "Instance no longer matches shaders/mesh.slang";

<*
 One field of the push block as this side lays it out.

 The `$assert`s above check the C3 struct against itself; this checks it against
 the *shader*, through reflection, which is the half that was a comment until M4.
*>
struct PushFieldLayout
{
	String name;
	uint offset;
	uint size;
}

const PushFieldLayout[*] MESH_PUSH_FIELDS = {
	{ "frame",      0,  8 },
	{ "instances",  8,  8 },
	{ "positions", 16,  8 },
	{ "normals",   24,  8 },
	{ "uvs",       32,  8 },
	{ "base_color", 40, 16 },
	{ "flags",     56,  4 },
	{ "uv_transform", 60, 16 },
};

<*
 The fixed-function state a pipeline is *built* with — as opposed to the state it
 is *told* at record time.

 ## The cull mode is not in here, and that is the interesting part

 Four things vary across the pipelines this project needs: topology, cull mode,
 and the two depth flags. All four are settable dynamically on a Vulkan 1.3
 device — `vkCmdSetCullMode`, `vkCmdSetPrimitiveTopology`,
 `vkCmdSetDepthTestEnable` and `vkCmdSetDepthWriteEnable` are core with no
 feature bit. So in principle none of them needs a pipeline of its own.

 **Topology is the exception, and it was measured rather than assumed.** With
 `dynamicPrimitiveTopologyUnrestricted` false — which is what this machine's
 device reports — `vkCmdSetPrimitiveTopology` may only pick a topology in the
 same *class* as the one the pipeline was built with, and triangles and lines are
 different classes. The bundled KosmicKrisp honours the switch anyway, pixel for
 pixel, because Metal takes the primitive type at draw time and has nothing baked
 in to conflict with. It is still undefined behaviour, and the validation layer
 names it on every single draw:

	VUID-vkCmdDrawIndexed-dynamicPrimitiveTopologyUnrestricted-07500

 A validation error on every frame is how a real one gets missed, so the line
 pass gets a pipeline and topology stays here.

 **The cull mode went dynamic**, and that is where the saving was. It is the one
 of the four a *script* varies — `material.side` — so under a static cull mode
 every distinct side an agent asked for was another `VkPipeline`, built at the
 line that asked for it. It is now `vk::cmdSetCullMode` per bucket, which costs
 one command and no pipeline, and it puts the field where it belongs: topology
 and depth describe the pass, the cull mode describes the material.

 The depth flags could go the same way and deliberately have not. They would save
 nothing — the line pass differs in topology regardless, so it is a second
 pipeline either way — and a pipeline that no longer states its own depth
 behaviour is harder to read for no gain.

 Everything left in here is core Vulkan with no capability bit behind it. That is
 also why a wireframe is a **line-list index buffer** rather than
 `POLYGON_MODE_LINE`: `fillModeNonSolid` is false on the bundled KosmicKrisp, and
 so is `wideLines`, so lines are one pixel and there is no raster state to ask
 for (`plan.md` §1).
*>
struct PipelineState
{
	vk::PrimitiveTopology topology;
	bool depth_test;
	bool depth_write;
}

<*
 What everything drew with before there was a choice: solid triangles, back faces
 culled, depth tested and written.
*>
const PipelineState SOLID_STATE = {
	.topology = PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
	.depth_test = true,
	.depth_write = true,
};

<*
 What debug geometry draws with: line segments, no culling, and **no depth test
 at all**.

 The depth part is the one worth defending, because Three.js's helpers are
 depth-tested and these are not.

 A debug line exists to answer "where is this thing", and the times that question
 is asked are exactly the times the thing is somewhere it should not be — inside
 a wall, behind the terrain, buried in the masonry. The town-square session lost
 a render to a window that had sunk into the stone it was mounted on, and a box
 helper that was also hidden by that stone would have been no help at all.

 It also removes the one hard case for free. A wireframe drawn over its own mesh
 is exactly coplanar with it, and coplanar depth is a speckle rather than a line —
 which is the failure the helper is supposed to *diagnose*, appearing in the
 diagnostic. With no depth test there is nothing to fight.

 The cost is that debug geometry does not sort with the scene, so it has to be
 drawn after all of it. `Scene.build_draw_list` puts the line material last for
 that reason, and it is not an ordering that can be got right by luck.
*>
const PipelineState LINE_STATE = {
	.topology = PRIMITIVE_TOPOLOGY_LINE_LIST,
	.depth_test = false,
	.depth_write = false,
};

fn ulong PipelineState.hash(self)
{
	return ((ulong)self.topology * 0xbf58476d1ce4e5b9)
		^ (self.depth_test ? 0x94d049bb133111ebUL : 0)
		^ (self.depth_write ? 0x2545f4914f6cdd1dUL : 0);
}

fn bool PipelineState.equals(self, PipelineState other)
{
	return self.topology == other.topology
		&& self.depth_test == other.depth_test
		&& self.depth_write == other.depth_write;
}

struct MeshPipeline
{
	vk::Pipeline handle;
	vk::PipelineLayout layout;
	vk::DescriptorSetLayout descriptor_layout;
	// What the shader said it wants: bindings by name, push fields by name. Owned
	// by the pipeline and freed with it — see `MeshPipeline.init`, which moves it
	// out of the `ShaderModule` it was compiled from.
	ShaderLayout shader;
}

<*
 Check the shader's push block against `MESH_PUSH_FIELDS`.

 Every field this side expects must be present at the same offset and the same
 size. Extra fields in the shader are not an error — a field the C3 struct never
 reads is harmless, and refusing it would mean a shader cannot carry anything
 this pass does not use.

 @return? PUSH_BLOCK_MISMATCH : `The shader's push block does not lay out the way MeshPush does. The offending field is printed, because "they disagree" is not something anyone can act on.`
*>
fn void? check_push_block(ShaderLayout* layout)
{
	// Against the budget, not against `MeshPush::size`. The doc comment above has
	// always said extra fields are allowed, but until M5 this line capped the
	// whole block at the 64 bytes the mesh struct occupies, which left exactly
	// four spare and made a material uniform impossible. What the cap is actually
	// for is that `MeshPass.record` pushes into a `PUSH_BUDGET`-sized staging
	// block — so the budget is the real bound, and the device's own limit is
	// checked separately in `MeshPipeline.init`.
	if (layout.push_size > PUSH_BUDGET)
	{
		io::eprintfn(
			"shader: the push block is %d bytes and the budget is %d",
			layout.push_size,
			PUSH_BUDGET
		);
		return PUSH_BLOCK_MISMATCH~;
	}

	foreach (expected : MESH_PUSH_FIELDS)
	{
		ShaderField* found = layout.field_of(expected.name);
		if (found == null)
		{
			io::eprintfn("shader: the push block has no field '%s'", expected.name);
			return PUSH_BLOCK_MISMATCH~;
		}
		if (found.offset != expected.offset || found.size != expected.size)
		{
			io::eprintfn(
				"shader: push field '%s' is at %d+%d and MeshPush has it at %d+%d",
				expected.name,
				found.offset,
				found.size,
				expected.offset,
				expected.size
			);
			return PUSH_BLOCK_MISMATCH~;
		}
	}
}

<*
 Check the module contains the entry points that will be named at pipeline
 creation.

 `spAddEntryPoint` already fails loudly for a name that is not in the source, so
 this catches the other direction: a module that compiled but emitted a stage
 under a different name — which is what happens without
 `-fvk-use-entrypoint-name`, where both entry points come out called `main`.

 @return? SHADER_MISSING_ENTRY_POINT : `The compiled module does not contain an entry point the pipeline names.`
*>
fn void? check_entry_points(ShaderModule* mod)
{
	foreach (wanted : MESH_ENTRIES)
	{
		bool found = false;
		foreach (entry : mod.entries)
		{
			if (entry.name == wanted.name && entry.stage == wanted.stage) found = true;
		}
		if (!found)
		{
			io::eprintfn("shader: the module has no '%s' entry point", wanted.name);
			return SHADER_MISSING_ENTRY_POINT~;
		}
	}
}

<*
 Build the mesh pipeline from a compiled Slang module.

 No vertex input state, no `VkRenderPass`, no `VkFramebuffer`: attachment
 formats are declared here through `PipelineRenderingCreateInfo` and the
 attachments themselves at record time.

 **The module's `ShaderLayout` is moved into the pipeline**, which then owns it.
 The caller's `ShaderModule` keeps the SPIR-V and the diagnostic and is still
 theirs to free; its `layout` is left empty, and freeing an empty one is a no-op.
 The alternative — a pointer into the module — would make the pipeline outlive
 what it points at the first time a caller freed the module after building.

 @param mod : `A module from compile_slang. Its layout is copied, not moved — the caller keeps the module and may build more pipelines from it.`
 @return? NO_SCALAR_BLOCK_LAYOUT : `The shader reads tightly packed float3 streams, which is only legal with VK_EXT_scalar_block_layout. Refusing here beats rendering geometry read at the wrong stride.`
 @return? PUSH_BLOCK_TOO_LARGE : `The device offers fewer push-constant bytes than the block needs. Cannot happen on a conformant device — 128 is the required minimum — so this is a sentence rather than a fallback.`
 @return? SHADER_TOO_MANY_SETS : `The shader declares bindings in more than one descriptor set and this pass creates one. Not a limitation of the reflection, which reads them all.`
 @return? SHADER_BINDING_UNSUPPORTED : `The shader declares something this pass cannot bind — an acceleration structure, say. Named rather than guessed at.`
*>
fn MeshPipeline? MeshPipeline.init(&self, Gpu* gpu, Target* target, ShaderModule* mod, PipelineState state)
{
	if (!gpu.limits.scalar_block_layout) return NO_SCALAR_BLOCK_LAYOUT~;
	// The *shader's* block, not `MeshPush::size`. Since M5 a material appends its
	// uniforms to the tail, so what gets pushed is no longer bounded by the C3
	// struct — checking the struct would have let a 128-byte material block
	// through on a device offering 64.
	if (mod.layout.push_size > gpu.limits.max_push_constants_size) return PUSH_BLOCK_TOO_LARGE~;

	check_entry_points(mod)!;
	check_push_block(&mod.layout)!;

	if (mod.layout.set_count > 1)
	{
		io::eprintfn("shader: %d descriptor sets declared and this pass creates one", mod.layout.set_count);
		return SHADER_TOO_MANY_SETS~;
	}

	// **Derived, not declared.** Until M4 this array was a literal naming
	// binding 0 as a combined image sampler in the fragment stage; now every
	// field of it comes out of the module that is about to be loaded.
	@pool()
	{
		List{vk::DescriptorSetLayoutBinding} bindings;
		bindings.tinit(4);
		foreach (binding : mod.layout.bindings)
		{
			if (binding.type == DESCRIPTOR_TYPE_UNBINDABLE)
			{
				io::eprintfn("shader: cannot bind '%s' — no Vulkan descriptor type for it", binding.name);
				return SHADER_BINDING_UNSUPPORTED~;
			}
			bindings.push({
				.binding = binding.binding,
				.descriptorType = binding.type,
				.descriptorCount = binding.count,
				.stageFlags = binding.stages,
			});
		}

		// `PUSH_DESCRIPTOR_BIT` makes this a layout that is never allocated from.
		// Sets for it are specified inline by `cmdPushDescriptorSetKHR` at draw
		// time, which is why `Assets` has no pool, no set list and — the part that
		// mattered — no reason to know a pipeline exists. See `scene/asset.c3`.
		self.descriptor_layout = vk::descriptorSetLayoutCreateInfo()
			.setFlags(DESCRIPTOR_SET_LAYOUT_CREATE_PUSH_DESCRIPTOR_BIT)
			.setBindings(bindings.array_view())
			.build(gpu.handle)!;
	};

	vk::PushConstantRange push_range = {
		.stageFlags = mod.layout.stages,
		.offset = 0,
		// The shader's own size rather than `MeshPush::size`: reflection reports
		// the 60 bytes that are used, not the 64 the C3 struct occupies with its
		// tail padding, and a range longer than the block is a validation error
		// on some drivers. `check_push_block` has already proved they agree
		// field for field.
		.size = mod.layout.push_size,
	};

	self.layout = vk::pipelineLayoutCreateInfo().setSetLayouts({ self.descriptor_layout })
		.setPushConstantRanges({ push_range })
		.build(gpu.handle)!;

	vk::ShaderModule module_handle = vk::loadShaderModule(gpu.handle, mod.spirv)!;
	defer module_handle.free(gpu.handle);

	vk::PipelineShaderStageCreateInfo[2] stages = {
		vk::pipelineShaderStageCreateInfo().setStage(SHADER_STAGE_VERTEX_BIT).setMod(module_handle).setName("vertexMain"),
		vk::pipelineShaderStageCreateInfo().setStage(SHADER_STAGE_FRAGMENT_BIT).setMod(module_handle).setName("fragmentMain"),
	};

	vk::PipelineRenderingCreateInfo rendering = vk::pipelineRenderingCreateInfo()
		.setColorAttachmentFormats((vk::Format[]) { target.color_format })
		.setDepthAttachmentFormat(target.depth_format);

	// Empty, and that is the point: geometry arrives as buffer device
	// addresses. There is no attribute-binding layer in this project.
	vk::PipelineVertexInputStateCreateInfo vertex_input = vk::pipelineVertexInputStateCreateInfo();

	vk::PipelineInputAssemblyStateCreateInfo input_assembly = vk::pipelineInputAssemblyStateCreateInfo()
		.setTopology(state.topology)
		.setPrimitiveRestartEnable(vk::FALSE);

	// **Counter-clockwise, the same as glTF's own convention, and the negative
	// viewport does not change that.**
	//
	// It is tempting to reason that `gpu/target.c3`'s negative-height viewport
	// mirrors the image and therefore reverses the winding. It does not, and
	// getting this backwards culls exactly the faces that should be visible —
	// which looks like a broken pipeline rather than a raster setting, because
	// validation is perfectly happy and the screen is empty. The negative
	// viewport exists to *undo* Vulkan's Y-down NDC so a glm-convention
	// projection works unchanged; undoing a flip is not a flip, so a triangle
	// that is counter-clockwise in glTF space is counter-clockwise here.
	vk::PipelineRasterizationStateCreateInfo rasterization = vk::defaultRasterizationState()
		// **Ignored.** `DYNAMIC_STATE_CULL_MODE` is declared below, so the value
		// here is never read and `MeshPass.record` supplies the material's own.
		// Written as the old default rather than left zero, because zero spells
		// CULL_MODE_NONE and a reader who missed the dynamic state would take it
		// for a deliberate choice.
		.setCullMode(CULL_MODE_BACK_BIT)
		.setFrontFace(FRONT_FACE_COUNTER_CLOCKWISE)
		// POLYGON_MODE_FILL only, whatever the topology. fillModeNonSolid is
		// false on the bundled driver here, which is why `LINE_STATE` reaches
		// lines through PRIMITIVE_TOPOLOGY_LINE_LIST and an index buffer of
		// pairs rather than through a raster state (plan.md §1).
		.setPolygonMode(POLYGON_MODE_FILL);

	vk::PipelineMultisampleStateCreateInfo multisample = vk::defaultMultisampleState();

	vk::PipelineColorBlendAttachmentState blend = vk::defaultColorBlendAttachment();
	blend.blendEnable = vk::FALSE;
	vk::PipelineColorBlendStateCreateInfo color_blend = vk::defaultColorBlendState(
		(vk::PipelineColorBlendAttachmentState[]) { blend }
	);

	vk::PipelineDepthStencilStateCreateInfo depth = vk::defaultDepthStencilState()
		.setDepthTestEnable(state.depth_test ? vk::TRUE : vk::FALSE)
		.setDepthWriteEnable(state.depth_write ? vk::TRUE : vk::FALSE)
		.setDepthCompareOp(COMPARE_OP_LESS_OR_EQUAL);

	// `CULL_MODE` alongside the two the swapchain needs. Core in Vulkan 1.3 with no
	// feature bit, so there is nothing to query and nothing to fall back to — see
	// `PipelineState` for why topology is not here beside it.
	vk::DynamicState[3] dynamic_states = {
		DYNAMIC_STATE_VIEWPORT,
		DYNAMIC_STATE_SCISSOR,
		DYNAMIC_STATE_CULL_MODE,
	};
	vk::PipelineDynamicStateCreateInfo dynamic = vk::pipelineDynamicStateCreateInfo()
		.setDynamicStates(dynamic_states[..]);

	vk::PipelineViewportStateCreateInfo viewport = vk::pipelineViewportStateCreateInfo().setViewportCount(1)
		.setScissorCount(1);

	self.handle = vk::graphicsPipelineCreateInfo().setNext(&rendering).setStages(stages[..])
		.setVertexInputState(&vertex_input)
		.setInputAssemblyState(&input_assembly)
		.setViewportState(&viewport)
		.setRasterizationState(&rasterization)
		.setMultisampleState(&multisample)
		.setColorBlendState(&color_blend)
		.setDepthStencilState(&depth)
		.setDynamicState(&dynamic)
		.setLayout(self.layout)
		.build(gpu.handle)!;

	// A copy, not a move. Until the pipeline cache learned to keep modules this
	// took the module's own layout and left it empty, which was right while a
	// module produced exactly one pipeline. It now produces one per render state —
	// the line pass and the solid pass are one `mesh.slang`, and a material's two
	// sides are one source — so the module has to survive with its layout intact.
	//
	// Still owned by the pipeline and still freed with it. `ShaderLayout.copy` has
	// the argument against borrowing instead.
	self.shader = mod.layout.copy();

	return *self;
}

fn void MeshPipeline.free(&self, Gpu* gpu)
{
	if (self.handle != null) self.handle.free(gpu.handle);
	if (self.layout != null) self.layout.free(gpu.handle);
	if (self.descriptor_layout != null) self.descriptor_layout.free(gpu.handle);
	self.shader.free();
	*self = { };
}

// ============================================================================
// The cache
// ============================================================================

<*
 One compiled shader the cache is keeping, and the source that produced it.

 ## Why this is a level of its own

 A pipeline is `(source, render state)`. A *compile* is source alone — Slang emits
 byte-identical SPIR-V for a line pipeline and a solid one, because topology, cull
 mode and the depth flags are `VkGraphicsPipelineCreateInfo` fields the shader
 never sees.

 Until M6 nothing asked for two states over one source, so the cache keyed both
 levels together and nobody paid for it. Debug lines and `material.side` both ask,
 and under the single key each of them called Slang again on source it had already
 compiled: measured at `compiles=2, hits=0` for a `MeshPass.init` that builds one
 shader. The header below states the ratio that makes that matter — roughly 17 ms
 for the compile against 1 ms for the pipeline — so splitting the levels is worth
 seventeen eighteenths of the cost, and dynamic state would have been worth the
 other eighteenth.
*>
struct CachedModule
{
	ulong hash;
	// The source that produced it, kept so a hash *hit* can be confirmed rather
	// than trusted. `gpu/texture.c3` compares dimensions before believing its
	// content hash for the same reason, and `plan.md` §6 states the rule
	// generally: compare identity, not a proxy for it. A 64-bit collision here
	// would build a pipeline out of a different shader, which renders something
	// plausible and wrong.
	String source;
	ShaderModule mod;
	// How many `CachedPipeline` entries were built from it. Not how many callers
	// asked: two render states over one source are two entries and one module,
	// and the SPIR-V has to outlive both of them. At zero the module is freed
	// outright rather than kept warm, because a source with no pipeline left is
	// exactly the accumulation eviction exists to stop.
	uint refs;
}

<*
 One pipeline the cache is keeping: which module, and over which state.

 The module is a pointer rather than a copy because a `CachedModule` holds the
 SPIR-V. It is borrowed from `PipelineCache.modules`, whose entries are
 heap-boxed for the same reason the pipelines are — a later `acquire` that grows
 either list must not move something already in use.
*>
struct CachedPipeline
{
	CachedModule* compiled;
	PipelineState state;
	MeshPipeline pipeline;
	// How many live borrows there are. `acquire` hands one out, `retain` takes
	// another, `release` gives one back — and **an entry at zero is not yet
	// freed**, it is merely evictable. See `PipelineCache.trim`.
	uint refs;
	// The cache's own ordinal at the moment `refs` last reached zero, which is
	// what makes the eviction order least-recently-released rather than
	// whichever the scan reached first. Meaningless while `refs > 0`.
	ulong released_at;
}

<*
 Pipelines by content hash.

 `plan.md` §3: an agent iterating on a shader in a loop will otherwise create
 hundreds of `VkPipeline` objects in a session, and **a hit must skip the Slang
 call entirely, not just the pipeline creation, because compilation is the
 expensive half** — measured at about 17 ms per compile against roughly 1 ms for
 the pipeline on this machine.

 That ratio is why there are two levels rather than one key. A shader compiles
 once; a pipeline is built once per render state over it. See `CachedModule`.

 Entries in both lists are heap-allocated and handed out by pointer, so a later
 `acquire` that grows either one does not move a pipeline something is already
 drawing with, or a module a pipeline entry points at.
*>
struct PipelineCache
{
	// Two levels, keyed differently. See `CachedModule` for why they are not one.
	List{CachedModule*} modules;
	List{CachedPipeline*} entries;
	// How many times Slang was actually invoked, and how many acquires were
	// answered without it. Not diagnostics: `the_pipeline_cache_skips_the_compile`
	// asserts on these, because "the same pointer came back" would also be true
	// of a cache that recompiled and threw the result away.
	uint compiles;
	uint hits;
	// How many `VkPipeline` objects were built. Separate from `compiles` since the
	// split, because they are no longer the same number and the whole point of the
	// split is that the cheap one can happen without the expensive one — a test
	// that only watched `compiles` would pass on a cache that had stopped caching
	// pipelines at all.
	uint builds;
	// How many entries have been evicted and their pipelines retired. Asserted on
	// for the same reason `compiles` is: "the cache did not grow" would also be
	// true of a cache that never cached anything.
	uint evictions;
	// Ticks once per release-to-zero. Only its order is read — see
	// `CachedPipeline.released_at`.
	ulong clock;
}

<*
 How many unreferenced entries the cache keeps before it starts evicting.

 **Not zero, and that is the whole design.** Dropping an entry the instant its
 last borrow goes would make this a refcounted allocator rather than a cache: a
 script that disposes a material and builds the same one again — which is what
 an agent iterating on a scene does every run — would pay to rebuild a pipeline
 it had just given back. Keeping a few costs a handful of driver objects and
 makes that case free.

 **Not unbounded, which is what it was.** `plan.md` §1: an agent iterating on a
 shader accumulated one `VkPipeline` per distinct source for the life of the
 process, because nothing ever came off this list.

 Eight is one bucket per material an interactive scene plausibly cycles through,
 and it is not a number anybody measured. `the_pipeline_cache_evicts_what_nothing_uses`
 pins the behaviour rather than the constant.
*>
const uint MAX_UNUSED_PIPELINES = 8;

fn void PipelineCache.init(&self)
{
	self.modules.init(mem, 2);
	self.entries.init(mem, 2);
}

<*
 The compiled module for this source, compiling it if it is new.

 Split out of `acquire` because it is the level with the cost in it: the SPIR-V
 depends on the source and on nothing else, so two render states over one shader
 come through here once.

 @return `Borrowed from the cache, which owns it. Null is never returned — a failure is a fault.`
*>
fn CachedModule*? PipelineCache.module_for(&self, String source, String name, String* diagnostic)
{
	ulong hash = content_hash((char[])source);

	foreach (existing : self.modules)
	{
		if (existing.hash != hash) continue;
		// Identity, not the hash — see `CachedModule.source`.
		if (existing.source != source) continue;
		self.hits++;
		return existing;
	}

	ShaderModule mod = compile_slang(source, name, MESH_ENTRIES[..])!;
	self.compiles++;

	// Handed over before the `ok` check, because a successful compile can still
	// warn and the caller asked for the text, not for the failures.
	if (diagnostic != null && mod.diagnostic.len > 0) *diagnostic = mod.diagnostic.copy(mem);

	if (!mod.ok)
	{
		// Printed only when nobody took delivery. `plan.md` §6: a compile that
		// fails quietly is the runtime version of the `$embed` trap, so the text
		// has to reach *someone* on every path.
		if (diagnostic == null) io::eprintn(mod.diagnostic);
		// Freed rather than kept. A cached failure would be handed to the next
		// caller as though it were a shader, and the next caller is usually the
		// agent having just fixed the typo.
		mod.free();
		return SHADER_COMPILE_FAILED~;
	}
	if (diagnostic == null && mod.diagnostic.len > 0) io::eprintn(mod.diagnostic);

	CachedModule* entry = mem::new(CachedModule);
	entry.hash = hash;
	entry.source = source.copy(mem);
	entry.mod = mod;
	self.modules.push(entry);
	return entry;
}

<*
 The pipeline for this source and this render state, compiling it if it is new.

 ## Who gets the diagnostic

 Until M5 this printed the Slang diagnostic to stderr and returned a bare fault,
 which threw the text away for every caller. That was right while the only shader
 was `mesh.slang` and the only reader was whoever started the process; it is
 wrong the moment an agent's own fragment body is what failed, because
 `plan.md` §5's done condition for M5 is a JS error *carrying* the diagnostic.

 So `diagnostic`, when non-null, receives the text — on failure and on success
 alike, since a warning arrives with `ok == true` and is worth surfacing too.
 The caller owns the string. Passing null keeps the old behaviour exactly, which
 is what the CLI and the built-in mesh pipeline still want.

 @param name : `What diagnostics call the source.`
 @param state : `Topology, cull mode and depth behaviour. Part of the key, so two states over one source are two pipelines and one compile.`
 @param [out] diagnostic : `Receives Slang's output verbatim, or is left alone if null. Set on warnings as well as errors — check the fault, not this.`
 @return `A pointer owned by the cache. Valid until the cache is freed.`
*>
fn MeshPipeline*? PipelineCache.acquire(
	&self,
	Gpu* gpu,
	Target* target,
	String source,
	String name,
	PipelineState state,
	String* diagnostic = null
)
{
	// The module first, and by source alone. A state this cache has not seen
	// before must not reach Slang: `CachedModule` has the measurement.
	CachedModule* compiled = self.module_for(source, name, diagnostic)!;

	foreach (entry : self.entries)
	{
		// Pointer identity is exact here in a way a hash is not — both entries
		// came out of `module_for`, which has already confirmed the source.
		if (entry.compiled != compiled || !entry.state.equals(state)) continue;
		// A hit takes a borrow like a miss does, so the caller's `release` is the
		// same call either way and does not have to know which it got.
		entry.refs++;
		return &entry.pipeline;
	}

	// Built into a local first, so a pipeline that fails to build leaves nothing
	// half-allocated behind. Nothing here can fail after this line.
	MeshPipeline built;
	built.init(gpu, target, &compiled.mod, state)!;
	self.builds++;

	CachedPipeline* entry = mem::new(CachedPipeline);
	entry.compiled = compiled;
	entry.state = state;
	entry.pipeline = built;
	entry.refs = 1;
	// The module is kept alive by its pipelines and by nothing else. A build that
	// failed on the line above leaves a freshly compiled module at zero — cached,
	// so the retry is free, and released at `free` rather than by eviction, which
	// only ever runs off an entry. That is a driver-level failure and one module.
	compiled.refs++;

	self.entries.push(entry);
	return &entry.pipeline;
}

<*
 The entry a handed-out pipeline belongs to, or null if it came from elsewhere.

 By pointer identity, which is what the cache promised: entries are heap-boxed
 precisely so the address it returned stays the address it owns.
*>
fn CachedPipeline* PipelineCache.entry_for(&self, MeshPipeline* pipeline)
{
	if (pipeline == null) return null;
	foreach (entry : self.entries)
	{
		if (&entry.pipeline == pipeline) return entry;
	}
	return null;
}

<*
 Take another borrow of a pipeline `acquire` already handed out.

 For a second holder of one pointer that did not go through `acquire` to get it
 — `MeshPass.create_texture_material` copies `MeshPass.pipeline` rather than
 asking the cache for the built-in shader again, because it knows the answer.

 A pointer this cache never handed out is ignored rather than faulted on. There
 is exactly one caller and it cannot produce one; a fault path here would be an
 unreachable branch in every build.
*>
fn void PipelineCache.retain(&self, MeshPipeline* pipeline)
{
	CachedPipeline* entry = self.entry_for(pipeline);
	if (entry == null) return;
	entry.refs++;
}

<*
 Give a borrow back.

 **Not a free.** At zero the entry becomes *evictable*, which is the same
 distinction `texture.dispose()` draws and for the same reason: the thing goes
 when nothing wants it and the cache has run out of room to be generous, not the
 instant one holder lets go. `MAX_UNUSED_PIPELINES` is where that room is
 argued.

 @param gpu : `The device the pipeline was built on, for the retire. Null defers the trim to the next release that has one — a pipeline cannot be destroyed without the device that made it, and holding an extra entry is the cheaper half of that trade.`
*>
fn void PipelineCache.release(&self, Gpu* gpu, MeshPipeline* pipeline)
{
	CachedPipeline* entry = self.entry_for(pipeline);
	if (entry == null || entry.refs == 0) return;

	entry.refs--;
	if (entry.refs > 0) return;

	entry.released_at = ++self.clock;
	self.trim(gpu);
}

<*
 Evict least-recently-released entries until the unused ones fit in the cap.

 Linear in the number of entries, per eviction, which is the right shape here:
 the list is bounded by the cap plus whatever is live, and the alternative — a
 second list threaded in release order — is a second thing to keep in step for a
 scan over a few dozen pointers.
*>
fn void PipelineCache.trim(&self, Gpu* gpu)
{
	if (gpu == null) return;

	while (true)
	{
		uint unused = 0;
		sz oldest = 0;
		bool found = false;
		foreach (i, entry : self.entries)
		{
			if (entry.refs > 0) continue;
			unused++;
			if (!found || entry.released_at < self.entries[oldest].released_at)
			{
				oldest = (sz)i;
				found = true;
			}
		}
		if (!found || unused <= MAX_UNUSED_PIPELINES) return;
		self.evict_at(gpu, oldest);
	}
}

<*
 Drop one entry: off the list, into the deletion queue, and its module with it if
 that was the last pipeline holding it.

 The pipeline is copied out before the entry is freed, and retired rather than
 destroyed — a command buffer submitted two frames ago may still bind it, which
 is the hazard `gpu/retire.c3` exists for.
*>
fn void PipelineCache.evict_at(&self, Gpu* gpu, sz index)
{
	CachedPipeline* entry = self.entries[index];
	self.entries.remove_at(index);

	gpu.retire_pipeline(entry.pipeline);

	CachedModule* compiled = entry.compiled;
	if (compiled != null && compiled.refs > 0)
	{
		compiled.refs--;
		// Freed outright rather than kept warm. A module whose pipelines have all
		// been evicted is SPIR-V for a source nothing draws with, and holding it
		// would leave half of what §1 called a leak still accumulating.
		if (compiled.refs == 0) self.drop_module(compiled);
	}

	mem::free(entry);
	self.evictions++;
}

<*
 Free a module and take it off the list. Its last pipeline is already gone.
*>
fn void PipelineCache.drop_module(&self, CachedModule* compiled)
{
	foreach (i, existing : self.modules)
	{
		if (existing != compiled) continue;
		self.modules.remove_at((sz)i);
		break;
	}
	compiled.mod.free();
	if (compiled.source.ptr != null) compiled.source.free(mem);
	mem::free(compiled);
}

fn void PipelineCache.free(&self, Gpu* gpu)
{
	// Pipelines before modules, because a pipeline borrows the module it was built
	// from. Nothing here reads it — the layout was copied, not borrowed — but the
	// order is the one the ownership says, so a future field that does borrow does
	// not become a use-after-free discovered at teardown.
	foreach (entry : self.entries)
	{
		entry.pipeline.free(gpu);
		mem::free(entry);
	}
	self.entries.free();

	foreach (compiled : self.modules)
	{
		compiled.mod.free();
		if (compiled.source.ptr != null) compiled.source.free(mem);
		mem::free(compiled);
	}
	self.modules.free();
	*self = {};
}
