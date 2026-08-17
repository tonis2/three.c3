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
}

$assert MeshPush::size <= PUSH_BUDGET : "the mesh push block outgrew the 128 bytes every device must offer";
// Not a bound but an equality, because these two numbers are a wire format
// shared with `shaders/mesh.slang` and a silent change to either side is a
// misread buffer rather than an error. `Instance` is in `scene/scene.c3`.
$assert MeshPush::size == 64 : "the push block no longer matches the layout documented above";
$assert FrameBlock::size == 80 : "FrameBlock no longer matches shaders/mesh.slang";
$assert Instance::size == 128 : "Instance no longer matches shaders/mesh.slang";

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
};

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
	if (layout.push_size > MeshPush::size)
	{
		io::eprintfn(
			"shader: the push block is %d bytes and MeshPush is %d",
			layout.push_size,
			MeshPush::size
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

 @param [&inout] mod : `A module from compile_slang. Its layout is moved into the pipeline.`
 @return? NO_SCALAR_BLOCK_LAYOUT : `The shader reads tightly packed float3 streams, which is only legal with VK_EXT_scalar_block_layout. Refusing here beats rendering geometry read at the wrong stride.`
 @return? PUSH_BLOCK_TOO_LARGE : `The device offers fewer push-constant bytes than the block needs. Cannot happen on a conformant device — 128 is the required minimum — so this is a sentence rather than a fallback.`
 @return? SHADER_TOO_MANY_SETS : `The shader declares bindings in more than one descriptor set and this pass creates one. Not a limitation of the reflection, which reads them all.`
 @return? SHADER_BINDING_UNSUPPORTED : `The shader declares something this pass cannot bind — an acceleration structure, say. Named rather than guessed at.`
*>
fn MeshPipeline? MeshPipeline.init(&self, Gpu* gpu, Target* target, ShaderModule* mod, vk::CullModeFlags cull)
{
	if (!gpu.limits.scalar_block_layout) return NO_SCALAR_BLOCK_LAYOUT~;
	if (MeshPush::size > gpu.limits.max_push_constants_size) return PUSH_BLOCK_TOO_LARGE~;

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

		self.descriptor_layout = vk::descriptorSetLayoutCreateInfo()
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
		.setTopology(PRIMITIVE_TOPOLOGY_TRIANGLE_LIST)
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
		.setCullMode(cull)
		.setFrontFace(FRONT_FACE_COUNTER_CLOCKWISE)
		// POLYGON_MODE_FILL only. fillModeNonSolid is false on the bundled
		// driver here, so a wireframe would have to be a line-list index
		// buffer rather than a raster state (plan.md §1).
		.setPolygonMode(POLYGON_MODE_FILL);

	vk::PipelineMultisampleStateCreateInfo multisample = vk::defaultMultisampleState();

	vk::PipelineColorBlendAttachmentState blend = vk::defaultColorBlendAttachment();
	blend.blendEnable = vk::FALSE;
	vk::PipelineColorBlendStateCreateInfo color_blend = vk::defaultColorBlendState(
		(vk::PipelineColorBlendAttachmentState[]) { blend }
	);

	vk::PipelineDepthStencilStateCreateInfo depth = vk::defaultDepthStencilState()
		.setDepthTestEnable(vk::TRUE)
		.setDepthWriteEnable(vk::TRUE)
		.setDepthCompareOp(COMPARE_OP_LESS_OR_EQUAL);

	vk::DynamicState[2] dynamic_states = { DYNAMIC_STATE_VIEWPORT, DYNAMIC_STATE_SCISSOR };
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

	// The move. Everything above read `mod.layout`; from here the pipeline owns
	// it and the module's copy is empty.
	self.shader = mod.layout;
	mod.layout = {};

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
 One pipeline the cache is keeping, and what it was built from.
*>
struct CachedPipeline
{
	ulong hash;
	// The source that produced it, kept so a hash *hit* can be confirmed rather
	// than trusted. `gpu/texture.c3` compares dimensions before believing its
	// content hash for the same reason, and `plan.md` §6 states the rule
	// generally: compare identity, not a proxy for it. A 64-bit collision here
	// would bind a pipeline compiled from different source, which renders
	// something plausible and wrong.
	String source;
	vk::CullModeFlags cull;
	MeshPipeline pipeline;
}

<*
 Pipelines by content hash.

 `plan.md` §3: an agent iterating on a shader in a loop will otherwise create
 hundreds of `VkPipeline` objects in a session, and **a hit must skip the Slang
 call entirely, not just the pipeline creation, because compilation is the
 expensive half** — measured at about 17 ms per compile against roughly 1 ms for
 the pipeline on this machine.

 Entries are heap-allocated and handed out by pointer, so a later `acquire` that
 grows the list does not move a pipeline something is already drawing with.
*>
struct PipelineCache
{
	List{CachedPipeline*} entries;
	// How many times Slang was actually invoked, and how many acquires were
	// answered without it. Not diagnostics: `the_pipeline_cache_skips_the_compile`
	// asserts on these, because "the same pointer came back" would also be true
	// of a cache that recompiled and threw the result away.
	uint compiles;
	uint hits;
}

fn void PipelineCache.init(&self)
{
	self.entries.init(mem, 2);
}

<*
 The pipeline for this source and this render state, compiling it if it is new.

 @param name : `What diagnostics call the source.`
 @return `A pointer owned by the cache. Valid until the cache is freed.`
*>
fn MeshPipeline*? PipelineCache.acquire(
	&self,
	Gpu* gpu,
	Target* target,
	String source,
	String name,
	vk::CullModeFlags cull
)
{
	ulong hash = content_hash((char[])source) ^ ((ulong)cull * 0x9e3779b97f4a7c15);

	foreach (entry : self.entries)
	{
		if (entry.hash != hash || entry.cull != cull) continue;
		if (entry.source != source) continue;
		self.hits++;
		return &entry.pipeline;
	}

	ShaderModule mod = compile_slang(source, name, MESH_ENTRIES[..])!;
	defer mod.free();
	self.compiles++;

	if (!mod.ok)
	{
		// The diagnostic is the product on this path — printing it here means a
		// shader error reaches a person even when the caller only propagates a
		// fault. `plan.md` §6: a compile that fails quietly is the runtime
		// version of the `$embed` trap.
		io::eprintn(mod.diagnostic);
		return SHADER_COMPILE_FAILED~;
	}
	if (mod.diagnostic.len > 0) io::eprintn(mod.diagnostic);

	// Built into a local first, so a pipeline that fails to build leaves nothing
	// half-allocated behind. Nothing here can fail after this line.
	MeshPipeline built;
	built.init(gpu, target, &mod, cull)!;

	CachedPipeline* entry = mem::new(CachedPipeline);
	entry.hash = hash;
	entry.cull = cull;
	entry.source = source.copy(mem);
	entry.pipeline = built;

	self.entries.push(entry);
	return &entry.pipeline;
}

fn void PipelineCache.free(&self, Gpu* gpu)
{
	foreach (entry : self.entries)
	{
		entry.pipeline.free(gpu);
		if (entry.source.ptr != null) entry.source.free(mem);
		mem::free(entry);
	}
	self.entries.free();
	*self = {};
}
