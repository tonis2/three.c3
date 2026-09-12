<*
 The Forward+ light binning pass, as a `ShaderDef`.

 What the Slang file said in text - the push block, the light struct, the one
 entry point - is here; the binning is `shaders/cluster.shady`, which the def
 carries as its source. The push block is the C3 struct the pass fills
 (`gpu/pipeline.c3`), walked rather than declared again, and `Light` is in every
 module `abi.c3` writes.

 There are no resources: the light array and the three output buffers all arrive
 as device addresses in the push block, exactly as the skin pass takes its
 buffers. What this one adds is an atomic, on the one counter a whole dispatch
 shares.

 The grid is not a field: the pass and the shader both bin 16x9x24, and the
 dispatch is sized from the same number in `render/pass.c3`.
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
macro ShaderDef cluster_def(String code)
{
	ShaderIo[] io = {
		{
			"ComputeIn",
			(ShaderIoField[]) {
				{ "thread", "uint3", "@builtin(global_invocation_id)" },
			},
		},
	};

	// One invocation owns one cluster, and the tail is the last workgroup's
	// remainder - the body returns for a cluster past the grid, because the
	// dispatch is rounded up to whole workgroups by definition.
	ShaderStage[] stages = {
		{
			.kind = shady::Stage.COMPUTE,
			.entry = "computeMain",
			.params = "ComputeIn input",
			.returns = "void",
			.body = "bin_lights(input);\n",
			.threads = "64, 1, 1",
		},
	};

	ShaderSource[] sources = {
		{ "cluster", code },
	};

	return (ShaderDef) {
		.name    = "cluster",
		.io      = io,
		.sources = sources,
		.stages  = stages,
	};
}
