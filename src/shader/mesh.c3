<*
 The draw path, as a `ShaderDef`.

 What `shaders/mesh.slang` said in text - the wire structs, the push block, the
 stage interface and the vertex path - is here; the geometry is
 `shaders/mesh.shady` and the pose it shares with the shadow pass is
 `shaders/skinning.shady`, both carried as sources. The push block is the C3
 struct the pass fills (`gpu/pipeline.c3`), walked rather than declared again.

 The fragment stage is not this def's to write. It is the material half - the
 surface library, the material records, and whichever `shade()` body a script
 attached - so it arrives as `fragment_code`, and the def only says where the
 entry point is and what it returns. That keeps one module with two entry points,
 which is what the engine compiles: `MESH_ENTRIES` names `vertexMain` and
 `fragmentMain` and `gpu/pipeline.c3` builds the layouts from both.

 The vertex stage's varyings are a wire format between the two halves, so they are
 declared once, here, in the order `material.slang` declares them.
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
macro ShaderDef mesh_def(String geometry_code, String skinning_code, String fragment_code)
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
				// The interpolated surface frame, and the world position a shadow
				// lookup needs. In the fragment half's order.
				{ "normal", "float3", "" },
				{ "uv", "float2", "" },
				{ "world", "float3", "" },
				// The copy's tint and the mesh's own vertex colour, which the
				// fragment multiplies together.
				{ "color", "float4", "" },
				{ "vertex_color", "float4", "" },
				// xy the atlas uv of this fragment, z 1 where there is a tile.
				{ "lightmap", "float3", "" },
				{ "sv_position", "float4", "@position" },
			},
		},
	};

	// One vertex stage and one fragment stage over the same module: the vertex
	// writes into an `out` parameter rather than returning, which is how the
	// ported body is written - the fragment half replaces the whole of it.
	ShaderStage[] stages = {
		{
			.kind = shady::Stage.VERTEX,
			.entry = "vertexMain",
			.params = "VertexIn input",
			.returns = "VertexOutput",
			.body = "VertexOutput output;\nmesh_vertex(input, output);\nreturn output;\n",
		},
		{
			.kind = shady::Stage.FRAGMENT,
			.entry = "fragmentMain",
			.params = "VertexOutput input",
			.returns = "float4",
			.body = "return mesh_fragment(input);\n",
		},
	};

	ShaderSource[] sources = {
		// The shared pose first: both halves read it, and a reader of the
		// generated module meets the geometry after the functions it calls.
		{ "skinning", skinning_code },
		{ "mesh", geometry_code },
		{ "fragment", fragment_code },
	};

	return (ShaderDef) {
		.name    = "mesh",
		.io      = io,
		.sources = sources,
		.stages  = stages,
	};
}
