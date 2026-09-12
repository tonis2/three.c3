<*
 The compute skinning pass, as a `ShaderDef`.

 What the Slang file said in text - the push block, the output struct, the morph
 deltas, the one entry point - is here; the arithmetic is `shaders/skin.shady`,
 which the def carries as its source. The push block is the C3 struct the pass
 fills (`gpu/pipeline.c3`), walked rather than declared again, and the structs
 it points at are in every module `abi.c3` writes.

 There are no resources: every buffer this pass touches arrives as a device
 address in the push block. That is why the def is five lines of stage and
 nothing else.
*>
module three;

import shady;

<*
 The whole module, with the ported code passed in rather than read here, so the
 caller decides where source comes from - disk in a checkout, `$embed` in a
 shipped binary, either in a test.

 A macro rather than a function because a `ShaderDef` is a handful of slices:
 its arrays have to live in the caller's scope, or the def would be a view of
 the frame it was built in.
*>
macro ShaderDef skin_def(String code)
{
	ShaderIo[] io = {
		{
			"ComputeIn",
			(ShaderIoField[]) {
				{ "thread", "uint3", "@builtin(global_invocation_id)" },
			},
		},
	};

	// Sixty-four threads: a mesh is thousands of vertices and the dispatch is
	// one dimension, so the number only decides how much of the last workgroup
	// is wasted. Sixty-four is the largest that is a subgroup multiple on every
	// device this runs on, which is what the original's comment says and the
	// reason the number is here rather than in the pass.
	ShaderStage[] stages = {
		{
			.kind = shady::Stage.COMPUTE,
			.entry = "computeMain",
			.params = "ComputeIn input",
			.returns = "void",
			.body = "skin_vertices(input);\n",
			.threads = "64, 1, 1",
		},
	};

	ShaderSource[] sources = {
		{ "skin", code },
	};

	return (ShaderDef) {
		.name    = "skin",
		.io      = io,
		.sources = sources,
		.stages  = stages,
	};
}
