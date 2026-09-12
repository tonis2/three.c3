<*
 The sky pass, as a `ShaderDef`.

 What the Slang template used to say in text - the push block, the binding, the
 two stage interfaces and the entry points - is here; the code is
 `shaders/sky.shady`, which the def carries as its source. Nothing about the
 pass is written twice, and the push block is the C3 struct the host already
 fills (`render/sky.c3`), walked rather than declared again.

 The vertex stage is three vertices and no geometry, so the pipeline is created
 with no vertex input state at all; `VertexIn` exists only because an entry
 point takes a struct, which is shady's rule for every stage.
*>
module three;

import shady;

<*
 The whole module, with the ported code passed in rather than read here, so the
 caller decides where source comes from - disk in a checkout, `$embed` in a
 shipped binary, either in a test.

 A macro rather than a function because a `ShaderDef` is a handful of slices:
 its arrays have to live in the caller's scope, or the def would be a view of
 the frame it was built in. The expansion is a few declarations and a literal,
 so there is nothing here a function would have bought.
*>
macro ShaderDef sky_def(String code)
{
	ShaderIo[] io = {
		{
			"VertexIn",
			(ShaderIoField[]) {
				{ "vid", "uint", "@builtin(vertex_index)" },
			},
		},
		{
			"VertexOutput",
			(ShaderIoField[]) {
				{ "sv_position", "float4", "@position" },
				{ "clip", "float2", "" },
			},
		},
	};

	// One image, always bound: there is no draw at all when a scene has no sky -
	// `MeshPass.record_sky` returns before recording anything - so unlike every
	// other sampler in this project there is no white 1x1 standing in for an
	// absent one, and no need for one.
	ShaderResource[] resources = {
		{ "sky_map", "Sampler2D", 0, 0, false },
	};

	// Two entry points around the ported functions: a vertex stage that makes
	// its own three vertices and a fragment stage that samples the image. The
	// bodies are calls, so `body_file` stays empty and a diagnostic inside
	// `sky_vertex` names `sky`, from the source block below.
	ShaderStage[] stages = {
		{
			.kind = shady::Stage.VERTEX,
			.entry = "vertexMain",
			.params = "VertexIn input",
			.returns = "VertexOutput",
			.body = "return sky_vertex(input);\n",
		},
		{
			.kind = shady::Stage.FRAGMENT,
			.entry = "fragmentMain",
			.params = "VertexOutput input",
			.returns = "float4",
			.body = "return sky_fragment(input);\n",
		},
	};

	ShaderSource[] sources = {
		{ "sky", code },
	};

	return (ShaderDef) {
		.name      = "sky",
		.io        = io,
		.resources = resources,
		.sources   = sources,
		.stages    = stages,
	};
}
