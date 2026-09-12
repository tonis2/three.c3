<*
 The shadow pass, as two `ShaderDef`s.

 What `shaders/shadow.slang` said in text - the wire structs, the push block,
 the stage interfaces and the entry points - is here; the code is
 `shaders/shadow.shady`, which the def carries as its source. The push block is
 the C3 struct the pass fills (`gpu/pipeline.c3`), walked rather than declared
 again.

 Two definitions because this pass has two whole programs, which is the variant
 policy's "interface / whole-program change" row: the pipeline every ordinary
 caster shares has no fragment stage at all - depth is a function of position, so
 there is nothing to write and nothing to sample - and the cut-out pipeline has a
 fragment stage that discards. A specialization constant cannot add a stage or a
 descriptor, so the cut-out is a second module with the base colour map bound and
 a second entry point, built only once something in the scene has asked.

 **The vertex half is one piece of text handed to both** (`shaders/shadow.shady`),
 so the two pipelines cannot pose a vertex differently, and the cut-out's own
 block holds nothing but what the cut-out adds.
*>
module three;

import shady;

<*
 The depth-only module: one vertex stage and no fragment stage.

 `SHADOW_ENTRIES` in `gpu/pipeline.c3` names `vertexMain` alone, and this is why
 it can: a depth pipeline needs no colour attachment to write to.

 A macro rather than a function because a `ShaderDef` is a handful of slices:
 its arrays have to live in the caller's scope, or the def would be a view of
 the frame it was built in.
*>
macro ShaderDef shadow_def(String code)
{
	ShaderIo[] io = {
		{
			"VertexIn",
			(ShaderIoField[]) {
				{ "vid", "uint", "@builtin(vertex_index)" },
				{ "iid", "uint", "@builtin(instance_index)" },
			},
		},
		{
			"VertexOutput",
			(ShaderIoField[]) {
				{ "sv_position", "float4", "@position" },
			},
		},
	};

	ShaderStage[] stages = {
		{
			.kind = shady::Stage.VERTEX,
			.entry = "vertexMain",
			.params = "VertexIn input",
			.returns = "VertexOutput",
			.body = "VertexOutput output;\noutput.sv_position = posed_clip(input.vid, input.iid);\nreturn output;\n",
		},
	};

	ShaderSource[] sources = {
		{ "shadow", code },
	};

	return (ShaderDef) {
		.name    = "shadow",
		.io      = io,
		.sources = sources,
		.stages  = stages,
	};
}

<*
 The cut-out module: the same vertex path, a uv beside the position, and a
 fragment stage that discards below the threshold the draw record carries.

 `vertex_code` is `shaders/shadow.shady` - the same text the depth-only module
 gets - and `cutout_code` is `shaders/shadow_cutout.shady`, which holds the
 sampler, the uv and the discard.
*>
macro ShaderDef shadow_cutout_def(String vertex_code, String cutout_code)
{
	ShaderIo[] io = {
		{
			"VertexIn",
			(ShaderIoField[]) {
				{ "vid", "uint", "@builtin(vertex_index)" },
				{ "iid", "uint", "@builtin(instance_index)" },
			},
		},
		{
			"VertexOutput",
			(ShaderIoField[]) {
				{ "sv_position", "float4", "@position" },
				{ "uv", "float2", "" },
			},
		},
	};

	// One binding, and only in this module: the device-wide texture array at set
	// 1, which `TextureTable` binds once for the whole device. The plain pass
	// declares no resource at all, so an ordinary caster pays neither the
	// binding nor the tap.
	ShaderResource[] resources = {
		{ "three_textures", "Sampler2D", 1, 0, true },
	};

	ShaderStage[] stages = {
		{
			.kind = shady::Stage.VERTEX,
			.entry = "vertexMain",
			.params = "VertexIn input",
			.returns = "VertexOutput",
			.body = "VertexOutput output;\noutput.sv_position = posed_clip(input.vid, input.iid);\noutput.uv = shadow_uv(push.draw[0], push.instances[input.iid], input.vid);\nreturn output;\n",
		},
		{
			.kind = shady::Stage.FRAGMENT,
			.entry = "fragmentMain",
			.params = "VertexOutput input",
			.returns = "void",
			.body = "cutout_fragment(input);\n",
		},
	};

	ShaderSource[] sources = {
		{ "shadow", vertex_code },
		{ "shadow_cutout", cutout_code },
	};

	return (ShaderDef) {
		.name      = "shadow_cutout",
		.io        = io,
		.resources = resources,
		.sources   = sources,
		.stages    = stages,
	};
}
