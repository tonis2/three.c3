<*
 The mesh pipeline: one pipeline, one descriptor layout, one push block.

 M1 has no material model, and that is deliberate — `base_stage.md` says one
 shader, a base colour texture and a hardcoded directional light, and calls
 anything more "M1 scope creep dressed as polish". The permutation explosion
 that usually follows a material system is avoided here by a different trick:
 the texture binding is *always* present and carries a 1x1 opaque white image
 when the material has none, so an untextured mesh and a textured one are the
 same pipeline.

 ## The push block

 Mirrors `shaders/mesh.slang` exactly. The offsets below are the ones slangc's
 reflection reports, checked rather than assumed:

	mvp          0    64
	base_color  64    16
	light       80    16
	positions   96     8
	normals    104     8
	uvs        112     8
	flags      120     4      = 124 used, 128 with tail padding

 **128 bytes is the budget and it is not a coincidence** — it is the push
 constant size every Vulkan implementation is required to offer, so this pass
 can never be refused by a device. crig's block grew to 192 and needed a
 `check_push_limit` that turns some machines away. When something new wants to
 ride in here, it goes in a buffer instead.
*>
module three;

import std::io;
import std::math;
import std::math::matrix;
import vk;

faultdef NO_SCALAR_BLOCK_LAYOUT, PUSH_BLOCK_TOO_LARGE;

const uint FLAG_HAS_NORMALS = 1;
const uint FLAG_HAS_UVS     = 2;

// The size every implementation must offer. Treated as a budget, not a limit
// to grow into.
const uint PUSH_BUDGET = 128;

struct MeshPush
{
	Matrix4f mvp;
	float[4] base_color; // rgb albedo factor, a material alpha
	float[4] light; // xyz surface-to-light (world), w ambient floor
	ulong positions;
	ulong normals;
	ulong uvs;
	uint flags;
}

$assert MeshPush::size <= PUSH_BUDGET : "the mesh push block outgrew the 128 bytes every device must offer";

struct MeshPipeline
{
	vk::Pipeline handle;
	vk::PipelineLayout layout;
	vk::DescriptorSetLayout descriptor_layout;
}

<*
 Build the mesh pipeline from a SPIR-V module.

 No vertex input state, no `VkRenderPass`, no `VkFramebuffer`: attachment
 formats are declared here through `PipelineRenderingCreateInfo` and the
 attachments themselves at record time.

 @param spirv : `Both entry points live in one module — slangc emits them together and -fvk-use-entrypoint-name keeps their source names.`
 @return? NO_SCALAR_BLOCK_LAYOUT : `The shader reads tightly packed float3 streams, which is only legal with VK_EXT_scalar_block_layout. Refusing here beats rendering geometry read at the wrong stride.`
 @return? PUSH_BLOCK_TOO_LARGE : `The device offers fewer push-constant bytes than the block needs. Cannot happen on a conformant device — 128 is the required minimum — so this is a sentence rather than a fallback.`
*>
fn MeshPipeline? MeshPipeline.init(&self, Gpu* gpu, Target* target, char[] spirv, vk::CullModeFlags cull)
{
	if (!gpu.limits.scalar_block_layout) return NO_SCALAR_BLOCK_LAYOUT~;
	if (MeshPush::size > gpu.limits.max_push_constants_size) return PUSH_BLOCK_TOO_LARGE~;

	self.descriptor_layout = vk::descriptorSetLayoutCreateInfo().setBindings(
		(vk::DescriptorSetLayoutBinding[]) {
			{
				.binding = 0,
				.descriptorType = DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
				.descriptorCount = 1,
				.stageFlags = SHADER_STAGE_FRAGMENT_BIT,
			},
		}
	)
		.build(gpu.handle)!;

	vk::PushConstantRange push_range = {
		.stageFlags = SHADER_STAGE_VERTEX_BIT | SHADER_STAGE_FRAGMENT_BIT,
		.offset = 0,
		.size = MeshPush::size,
	};

	self.layout = vk::pipelineLayoutCreateInfo().setSetLayouts({ self.descriptor_layout })
		.setPushConstantRanges({ push_range })
		.build(gpu.handle)!;

	vk::ShaderModule mod = vk::loadShaderModule(gpu.handle, spirv)!;
	defer mod.free(gpu.handle);

	vk::PipelineShaderStageCreateInfo[2] stages = {
		vk::pipelineShaderStageCreateInfo().setStage(SHADER_STAGE_VERTEX_BIT).setMod(mod).setName("vertexMain"),
		vk::pipelineShaderStageCreateInfo().setStage(SHADER_STAGE_FRAGMENT_BIT).setMod(mod).setName("fragmentMain"),
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

	return *self;
}

fn void MeshPipeline.free(&self, Gpu* gpu)
{
	if (self.handle != null) self.handle.free(gpu.handle);
	if (self.layout != null) self.layout.free(gpu.handle);
	if (self.descriptor_layout != null) self.descriptor_layout.free(gpu.handle);
	*self = { };
}
