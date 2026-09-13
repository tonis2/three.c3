<*
 The per-pass compiler table and the dispatch in front of both implementations.

 `c3c test --trust=full --test-filter three_tests::shader_switch`
*>
module three_tests::shader_switch;

import three;
import std::core::test;

<*
 Every compile point has a row, and every row has the spelling an override takes
 and a def worth reading - even the unported passes name the module they wait
 for, or say with an empty string that none exists yet.
*>
fn void every_pass_has_a_table_row_and_a_name() @test
{
	test::@check(three::PASS_COMPILERS.len == (usz)three::ShaderPass.COUNT,
		"one row per pass, got %d", three::PASS_COMPILERS.len);

	foreach (i, row : three::PASS_COMPILERS)
	{
		test::@check(row.name.len > 0, "pass %d has an override spelling", i);
		bool unique = true;
		foreach (j, other : three::PASS_COMPILERS)
		{
			if (i != j && other.name == row.name) unique = false;
		}
		test::@check(unique, "pass %s has one spelling", row.name);
	}
}

<*
 The default the flips leave behind: cluster, skin, shadow, sky and the built-in
 draw path are on shady; a script's material body stays on Slang until the shady
 generator can assemble one, and no other row moved.
*>
fn void the_table_flips_cluster_skin_shadow_sky_and_the_draw_path() @test
{
	test::@check(three::shader_compiler(three::ShaderPass.CLUSTER) == three::ShaderCompiler.SHADY,
		"cluster compiles through shady");
	test::@check(three::shader_compiler(three::ShaderPass.SKIN) == three::ShaderCompiler.SHADY,
		"skin compiles through shady");
	test::@check(three::shader_compiler(three::ShaderPass.SHADOW) == three::ShaderCompiler.SHADY,
		"shadow compiles through shady");
	test::@check(three::shader_compiler(three::ShaderPass.SKY) == three::ShaderCompiler.SHADY,
		"sky compiles through shady");
	test::@check(three::shader_compiler(three::ShaderPass.MESH) == three::ShaderCompiler.SHADY,
		"the built-in draw path compiles through shady");
	// The scripted half is its own row: there is no shady assembly of a body and
	// its uniforms yet, so `MESH_MATERIAL` stays on Slang.
	test::@check(three::shader_compiler(three::ShaderPass.MESH_MATERIAL) == three::ShaderCompiler.SLANG,
		"and a script's material body with it");
	foreach (i, row : three::PASS_COMPILERS)
	{
		if ((three::ShaderPass)i == three::ShaderPass.CLUSTER) continue;
		if ((three::ShaderPass)i == three::ShaderPass.SKIN) continue;
		if ((three::ShaderPass)i == three::ShaderPass.SHADOW) continue;
		if ((three::ShaderPass)i == three::ShaderPass.SKY) continue;
		if ((three::ShaderPass)i == three::ShaderPass.MESH) continue;
		test::@check(row.compiler == three::ShaderCompiler.SLANG,
			"%s is still compiled by Slang", row.name);
	}
}

<*
 An override moves exactly one pass, works in both directions, and clearing it
 puts the table's own answer back.
*>
fn void an_override_moves_one_pass_and_clear_restores_it() @test
{
	defer three::shader_overrides_clear();

	three::shader_override(three::ShaderPass.SKIN, three::ShaderCompiler.SLANG);
	test::@check(three::shader_compiler(three::ShaderPass.SKIN) == three::ShaderCompiler.SLANG,
		"skin follows the override");
	test::@check(three::shader_compiler(three::ShaderPass.CLUSTER) == three::ShaderCompiler.SHADY,
		"and the flipped default beside it is untouched");

	three::shader_override(three::ShaderPass.CLUSTER, three::ShaderCompiler.SLANG);
	test::@check(three::shader_compiler(three::ShaderPass.CLUSTER) == three::ShaderCompiler.SLANG,
		"the other direction is an override too");

	three::shader_overrides_clear();
	test::@check(three::shader_compiler(three::ShaderPass.CLUSTER) == three::ShaderCompiler.SHADY,
		"clearing returns the table's own answer for cluster");
	test::@check(three::shader_compiler(three::ShaderPass.SKIN) == three::ShaderCompiler.SHADY,
		"and for skin");
}

fn void an_override_list_names_passes_by_their_table_names() @test
{
	defer three::shader_overrides_clear();

	three::shader_override_list("cluster, skin", three::ShaderCompiler.SLANG)!!;
	test::@check(three::shader_compiler(three::ShaderPass.CLUSTER) == three::ShaderCompiler.SLANG,
		"cluster was named");
	test::@check(three::shader_compiler(three::ShaderPass.SKIN) == three::ShaderCompiler.SLANG,
		"skin was named");
	test::@check(three::shader_compiler(three::ShaderPass.SKY) == three::ShaderCompiler.SHADY,
		"sky was not");
}

<*
 An override that names no ported pass is a fault, not a silent no-op.
*>
fn void forcing_an_unported_pass_faults() @test
{
	defer three::shader_overrides_clear();

	three::shader_override(three::ShaderPass.POST, three::ShaderCompiler.SHADY);
	three::ShaderModule? refused = three::compile_shader(
		three::ShaderPass.POST, "", "three.post", three::MESH_ENTRIES[..]);
	if (catch err = refused)
	{
		test::@check(err == three::SHADY_PASS_UNWIRED, "with the wiring fault, got %s", err);
	}
	else
	{
		test::@check(false, "a shady post with no body is refused");
		refused.free();
	}
}

<*
 The cluster call site reaches both compilers through `compile_shader`, and both
 modules pass the contract `init_cluster` holds them to: the entry point by name
 and stage, and the push block at the offsets `ClusterPush` lays out.
*>
fn void the_cluster_call_site_reaches_both_compilers() @test
{
	defer three::shader_overrides_clear();

	String source = three::shader_source("cluster.slang", mem)!!;
	defer source.free(mem);

	three::shader_override(three::ShaderPass.CLUSTER, three::ShaderCompiler.SLANG);
	three::ShaderModule? through_slang = three::compile_shader(
		three::ShaderPass.CLUSTER, source, "cluster.slang", three::CLUSTER_ENTRIES[..]);
	if (catch through_slang)
	{
		test::@check(false, "the Slang path compiled");
		return;
	}
	defer through_slang.free();
	test::@check(through_slang.ok, "the Slang cluster compiles: %s", through_slang.diagnostic);
	if (catch three::check_entry_points(&through_slang, three::CLUSTER_ENTRIES[..]))
	{
		test::@check(false, "the Slang module has computeMain");
	}

	three::shader_override(three::ShaderPass.CLUSTER, three::ShaderCompiler.SHADY);
	three::ShaderModule? through_shady = three::compile_shader(
		three::ShaderPass.CLUSTER, source, "cluster.slang", three::CLUSTER_ENTRIES[..]);
	if (catch through_shady)
	{
		test::@check(false, "the shady path compiled");
		return;
	}
	defer through_shady.free();
	test::@check(through_shady.ok, "the shady cluster compiles: %s", through_shady.diagnostic);
	if (catch three::check_entry_points(&through_shady, three::CLUSTER_ENTRIES[..]))
	{
		test::@check(false, "the shady module has computeMain");
	}
	if (catch three::check_push_block(&through_shady.layout, three::CLUSTER_PUSH_FIELDS[..]))
	{
		test::@check(false, "the shady module's push block matches ClusterPush");
	}

	test::@check(through_shady.layout.push_size == through_slang.layout.push_size,
		"both compilers lay the block out at %d bytes, got %d",
		through_slang.layout.push_size, through_shady.layout.push_size);
	test::@check(through_shady.layout.bindings.len() == 0 && through_shady.layout.set_count == 0,
		"cluster declares no descriptors either way");
}

<*
 The draw path's row reaches the shady def - by the table's own default now, and
 the same way whatever a run overrides it to.

 The module is the built-in one's: the geometry and material halves, the
 `standard(s)` body a material nobody wrote gets, and the walk of `MeshPush`. Its
 push block ends in the emitted `Uniforms` member, which is why this is 32 bytes
 where the Slang module's 24 are.
*>
fn void the_mesh_call_site_is_wired_to_the_shady_def() @test
{
	defer three::shader_overrides_clear();

	String source = three::shader_source("mesh.slang", mem)!!;
	defer source.free(mem);

	three::shader_override(three::ShaderPass.MESH, three::ShaderCompiler.SHADY);
	three::ShaderModule? through_shady = three::compile_shader(
		three::ShaderPass.MESH, source, "mesh.slang", three::MESH_ENTRIES[..]);
	if (catch through_shady)
	{
		test::@check(false, "the shady draw path compiled");
		return;
	}
	defer through_shady.free();
	test::@check(through_shady.ok, "the shady draw path compiles: %s", through_shady.diagnostic);
	if (catch three::check_entry_points(&through_shady))
	{
		test::@check(false, "the shady module has vertexMain and fragmentMain");
	}
	if (catch three::check_push_block(&through_shady.layout, three::MESH_PUSH_FIELDS[..]))
	{
		test::@check(false, "the shady module's push block matches the mesh contract");
	}
	test::@check(through_shady.layout.push_size == 32,
		"the block is 24 walked bytes plus the empty uniforms, got %d", through_shady.layout.push_size);
	test::@check(through_shady.layout.field_of(three::MATERIAL_TABLE_FIELD) == null,
		"and a material with no uniforms has nothing to spill");
}
