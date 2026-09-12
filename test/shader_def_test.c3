<*
 A shader program written from C3.

 The generator's claim is that every declaration in the module is the engine's
 own - the wire structs from `abi.c3`, the push block from a C3 struct, the rest
 from the def - so what is checked here is shape: one module with no markers, no
 macros and no `#ifdef`, every part present and in the place the old templates
 had it, and a body bracketed so a fault inside it names the file its author
 wrote.

 Whether the module *compiles* is shady's question, asked where shady is a
 dependency; nothing here can ask it.
*>
module three_tests::shader_def;

import three;
import std::core::test;
import std::io;
import std::io::file;
import std::io::path;

<*
 One whole program: two stages, a sampler, the bindless table, a feature, and a
 body under a `#line`.

 `three::SkyPush` is the push block because it is the smallest wire struct with
 nothing to point at, which keeps the generated text short enough to read.
*>
macro String sky_program(String body_name)
{
	three::ShaderIo[] io = {
		{ "VertexIn", (three::ShaderIoField[]) {
			{ "vid", "uint", "@builtin(vertex_index)" },
		} },
		{ "VertexOutput", (three::ShaderIoField[]) {
			{ "sv_position", "float4", "@position" },
			{ "clip", "float2", "" },
		} },
	};
	three::ShaderResource[] resources = {
		{ "sky_map", "Sampler2D", 0, 0, false },
		{ "three_textures", "Sampler2D", 1, 0, true },
	};
	three::ShaderFeature[] features = { { "SHADOWS", "bool", "true", 0 } };
	three::ShaderStage[] stages = {
		// An entry point takes a struct, not a bare builtin - shady says so, and
		// it is the same rule for a vertex stage as for a compute one.
		{ three::ShaderStageKind.VERTEX, "vertexMain", "VertexIn input",
			"VertexOutput", "VertexOutput output;\nreturn output;\n", "sky", "" },
		{ three::ShaderStageKind.FRAGMENT, "fragmentMain", "VertexOutput input", "float4",
			"return float4(1.0);\n", body_name, "" },
	};
	three::ShaderDef def = {
		.name      = "sky",
		.io        = io,
		.resources = resources,
		.features  = features,
		.stages    = stages,
	};

	DString out;
	out.tinit(16384);
	three::append_shader_def(&out, def, three::SkyPush);
	return out.str_view();
}

fn void a_def_emits_the_whole_module() @test
{
	String source = sky_program("sky");

	// Handed to kong, whose renderer is where a module is asked to compile and
	// draw: `test/generated_shader_test.c3` reads this file.
	path::mkdir("build/shaderdef", recursive: true)!!;
	file::save("build/shaderdef/sky.shady", source)!!;

	// The push block: a C3 struct that became a block, and the variable every
	// entry point reaches it through.
	test::@check(source.contains("struct SkyPush @pushconstant"), "the push struct is marked\n%s", source);
	test::@check(source.contains("SkyPush push;"), "and a variable of it exists");
	test::@check(source.contains("float4x4 inverse_view_projection;"),
		"walked from the C3 struct rather than written in the shader");

	// The structure the def described.
	test::@check(source.contains("struct VertexOutput\n{\n\tfloat4 sv_position @position;\n\tfloat2 clip;\n}"),
		"stage IO is emitted as written: %s", source);
	test::@check(source.contains("const bool SHADOWS @spec(0) = true;"), "the feature is a spec constant");
	test::@check(source.contains("Sampler2D sky_map @set(0) @binding(0);"), "a resource carries its binding");
	test::@check(source.contains("Sampler2D three_textures[] @set(1) @binding(0);"),
		"and a runtime-sized one is the bindless table");

	// The entry points, and the body behind one.
	test::@check(source.contains("fn VertexOutput vertexMain(VertexIn input) @vertex"),
		"the vertex signature is generated");
	test::@check(source.contains("fn float4 fragmentMain(VertexOutput input) @fragment"),
		"and so is the fragment signature");
	test::@check(source.contains("#line 1 \"sky\""), "the body is numbered from one, in the body's name");
	test::@check(!source.contains("#define") && !source.contains("#if") && !source.contains("//@"),
		"and there are no markers and no macros anywhere");
}

<*
 A body is numbered from one under its own name, and the module is numbered again
 after it.

 The restore directive is checked rather than the body's: a directive numbers
 the line that *follows* it, so one written from a template's shape is right
 until a body grows a line, and then points every later diagnostic one line off.
 Counting the physical line here is the same arithmetic the emitter is trusted
 to do.
*>
fn void a_restore_directive_numbers_the_line_after_it() @test
{
	String source = sky_program("material");

	uint line = 1;
	usz  at   = 0;
	while (at < source.len)
	{
		usz end = at;
		while (end < source.len && source[end] != '\n') end++;
		String text = source[at:end - at];

		if (text.starts_with("#line "))
		{
			if (text.contains("three."))
			{
				// `#line N "three.sky"` must name the line straight after itself.
				String expected = string::tformat("#line %d \"", line + 1);
				test::@check(text.starts_with(expected),
					"the restore on line %d should number line %d: %s", line, line + 1, text);
			}
			else
			{
				test::@check(text.starts_with("#line 1 \""), "a body is numbered from one: %s", text);
			}
		}
		line++;
		at = end + 1;
	}
	test::@check(source.contains("#line 1 \"material\""), "the body's own name reaches the directive");
}

fn void a_compute_stage_carries_its_thread_counts() @test
{
	three::ShaderIo[] io = {
		{ "ComputeIn", (three::ShaderIoField[]) { { "id", "uint3", "@builtin(global_invocation_id)" } } },
	};
	three::ShaderStage[] stages = {
		{ three::ShaderStageKind.COMPUTE, "computeMain", "ComputeIn input", "void",
			"return;\n", "cluster", "64, 1, 1" },
	};
	three::ShaderDef def = {
		.name   = "cluster",
		.io     = io,
		.stages = stages,
	};

	DString out;
	out.tinit(8192);
	three::append_shader_def(&out, def, three::ClusterPush);
	String source = out.str_view();

	test::@check(source.contains("fn void computeMain(ComputeIn input) @compute @threads(64, 1, 1)"),
		"the stage kind and its dispatch size are one signature: %s", source);
	test::@check(source.contains("uint3 id @builtin(global_invocation_id);"),
		"and a builtin is a member attribute");
	test::@check(source.contains("struct ClusterPush @pushconstant"), "with the compute pass's own push block");
}
