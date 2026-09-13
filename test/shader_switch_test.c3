<*
 The per-pass compiler table and the dispatch in front of both implementations.

 `c3c test --trust=full --test-filter three_tests::shader_switch`
*>
module three_tests::shader_switch;

import three;
import slang;
import vk;
import std::core::test;

<*
 Every compile point has a row, and every row has the spelling an override takes
 and a def that compiles it. A row set to shady with no wiring is a fault rather
 than a quiet fall back to Slang, so a def-less row is a table error now - the
 `SHADY_PASS_UNWIRED` path below is the guard for the next pass added.
*>
fn void every_pass_has_a_table_row_and_a_name() @test
{
	test::@check(three::PASS_COMPILERS.len == (usz)three::ShaderPass.COUNT,
		"one row per pass, got %d", three::PASS_COMPILERS.len);

	foreach (i, row : three::PASS_COMPILERS)
	{
		test::@check(row.name.len > 0, "pass %d has an override spelling", i);
		test::@check(row.def.len > 0, "pass %s names the def that compiles it", row.name);
		bool unique = true;
		foreach (j, other : three::PASS_COMPILERS)
		{
			if (i != j && other.name == row.name) unique = false;
		}
		test::@check(unique, "pass %s has one spelling", row.name);
	}
}

<*
 The default the flips leave behind: every row is on shady. cluster, skin, both
 shadow variants, sky, the draw path and its numeric area reference, the engine's
 own post pass, a script's post body, a script's own material body, its lightmap
 bake and the built-in mesh's own lightmap bake. `MESH_MATERIAL` carries the
 script's `shade()` half through the def the built-in path uses, with the script's
 uniforms emitted beside it; `LIGHTMAP_MATERIAL` is the same half compiled as a
 lightmap bake, which stores the baked lights' diffuse instead of a live frame.
 `LIGHTMAP` is the built-in half of that same bake.
*>
fn void the_table_flips_the_draw_path_and_a_scripted_post() @test
{
	test::@check(three::shader_compiler(three::ShaderPass.CLUSTER) == three::ShaderCompiler.SHADY,
		"cluster compiles through shady");
	test::@check(three::shader_compiler(three::ShaderPass.SKIN) == three::ShaderCompiler.SHADY,
		"skin compiles through shady");
	test::@check(three::shader_compiler(three::ShaderPass.SHADOW) == three::ShaderCompiler.SHADY,
		"shadow compiles through shady");
	test::@check(three::shader_compiler(three::ShaderPass.SHADOW_CUTOUT) == three::ShaderCompiler.SHADY,
		"and the cut-out variant, whose module carries the same pose plus the stage that cuts");
	test::@check(three::shader_compiler(three::ShaderPass.SKY) == three::ShaderCompiler.SHADY,
		"sky compiles through shady");
	test::@check(three::shader_compiler(three::ShaderPass.MESH) == three::ShaderCompiler.SHADY,
		"the built-in draw path compiles through shady");
	test::@check(three::shader_compiler(three::ShaderPass.MESH_REFERENCE) == three::ShaderCompiler.SHADY,
		"and its numeric area reference is a module of its own on shady");
	test::@check(three::shader_compiler(three::ShaderPass.MESH_MATERIAL) == three::ShaderCompiler.SHADY,
		"a script's material body compiles through shady");
	test::@check(three::shader_compiler(three::ShaderPass.LIGHTMAP_MATERIAL) == three::ShaderCompiler.SHADY,
		"and so does the scripted lightmap bake, which is the same half with the bake on");
	// The tonemap is the post preamble with the engine's own curve, and the
	// engine can spell that body for either compiler, so this row moves.
	test::@check(three::shader_compiler(three::ShaderPass.TONEMAP) == three::ShaderCompiler.SHADY,
		"the engine's own post pass compiles through shady");
	test::@check(three::shader_compiler(three::ShaderPass.POST) == three::ShaderCompiler.SHADY,
		"and a script's post body compiles through shady too");
	test::@check(three::shader_compiler(three::ShaderPass.LIGHTMAP) == three::ShaderCompiler.SHADY,
		"the built-in mesh's own lightmap bake compiles through shady");
	foreach (i, row : three::PASS_COMPILERS)
	{
		test::@check(row.compiler == three::ShaderCompiler.SHADY,
			"%s is on shady", row.name);
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
 The lightmap bake's call site reaches the shady def - by the table's own default
 now, and the same way whatever a run overrides it to.

 The module is the built-in draw path's with `MATERIAL_LIGHTMAP_BAKE` on: the
 chart-space vertex stage, the baked diffuse answer and the walk of `MeshPush`.
 It carries the LTC half, whose `area_diffuse` is the polygon form factor the
 original's bake integrates, so the fit table is declared even though the bake
 never reads it. The lightmap descriptor walk binds every declared sampler to
 the shared white, which is what makes an unread one cost nothing but a binding.
*>
fn void the_lightmap_call_site_is_wired_to_the_shady_def() @test
{
	defer three::shader_overrides_clear();

	three::shader_override(three::ShaderPass.LIGHTMAP, three::ShaderCompiler.SHADY);
	three::ShaderModule? through_shady = three::compile_shader(
		three::ShaderPass.LIGHTMAP, "", "three.lightmap", three::MESH_ENTRIES[..]);
	if (catch through_shady)
	{
		test::@check(false, "the shady lightmap bake compiled");
		return;
	}
	defer through_shady.free();
	test::@check(through_shady.ok, "the shady lightmap bake compiles: %s", through_shady.diagnostic);
	if (catch three::check_entry_points(&through_shady))
	{
		test::@check(false, "the lightmap module has vertexMain and fragmentMain");
	}
	if (catch three::check_push_block(&through_shady.layout, three::MESH_PUSH_FIELDS[..]))
	{
		test::@check(false, "the lightmap module's push block matches the mesh contract");
	}
	test::@check(through_shady.layout.push_size == 32,
		"the block is 24 walked bytes plus the empty uniforms, got %d", through_shady.layout.push_size);
	test::@check(through_shady.layout.binding_of("lightmap_atlas") != null,
		"the atlas the built-in half samples is declared");
	three::ShaderBinding* fit = through_shady.layout.binding_of("ltc_lut");
	test::@check(fit != null && fit.set == 0 && fit.binding == 19,
		"and the LTC half's own table, at the engine's reserved binding");
}

<*
 The cluster call site reaches both compilers through `compile_shader`, and both
 modules pass the contract `init_cluster` holds them to: the entry point by name
 and stage, and the push block at the offsets `ClusterPush` lays out.
*>
fn void the_cluster_call_site_reaches_both_compilers() @test
{
	defer three::shader_overrides_clear();

	String source = three::shader_source(three::ShaderFile.CLUSTER_SLANG, mem)!!;
	defer source.free(mem);

	three::shader_override(three::ShaderPass.CLUSTER, three::ShaderCompiler.SLANG);
	three::ShaderModule? through_slang = three::compile_shader(
		three::ShaderPass.CLUSTER, source, three::ShaderFile.CLUSTER_SLANG.name, three::CLUSTER_ENTRIES[..]);
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
		three::ShaderPass.CLUSTER, source, three::ShaderFile.CLUSTER_SLANG.name, three::CLUSTER_ENTRIES[..]);
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

	String source = three::shader_source(three::ShaderFile.MESH_SLANG, mem)!!;
	defer source.free(mem);

	three::shader_override(three::ShaderPass.MESH, three::ShaderCompiler.SHADY);
	three::ShaderModule? through_shady = three::compile_shader(
		three::ShaderPass.MESH, source, three::ShaderFile.MESH_SLANG.name, three::MESH_ENTRIES[..]);
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

<*
 The one resource difference between the draw path and its numeric reference.

 The fitted module declares `ltc_lut` at binding 19; the reference module must
 not. **This is why the variant is a module and not a constant**: a spec
 constant cannot remove a binding, so a "reference" that still carried the table
 would keep a sampler on every draw in the frame for nothing - and the frame
 that has no table to bind could not run it.

 Both answers come through the table's own default, so the wiring and the
 module text are pinned together.
*>
fn void the_reference_module_drops_the_fit_table() @test
{
	defer three::shader_overrides_clear();

	three::shader_override(three::ShaderPass.MESH, three::ShaderCompiler.SHADY);
	three::ShaderModule? fitted = three::compile_shader(
		three::ShaderPass.MESH, "", "three.mesh", three::MESH_ENTRIES[..]);
	if (catch fitted)
	{
		test::@check(false, "the fitted draw path compiled");
		return;
	}
	defer fitted.free();
	test::@check(fitted.ok, "the fitted draw path compiles: %s", fitted.diagnostic);
	test::@check(fitted.layout.binding_of("ltc_lut") != null,
		"the fit declares its table");

	three::shader_override(three::ShaderPass.MESH_REFERENCE, three::ShaderCompiler.SHADY);
	three::ShaderModule? reference = three::compile_shader(
		three::ShaderPass.MESH_REFERENCE, "", "three.mesh_reference", three::MESH_ENTRIES[..]);
	if (catch reference)
	{
		test::@check(false, "the reference draw path compiled");
		return;
	}
	defer reference.free();
	test::@check(reference.ok, "the reference draw path compiles: %s", reference.diagnostic);
	test::@check(reference.layout.binding_of("ltc_lut") == null,
		"the numeric integration declares no fit table");
	if (catch three::check_entry_points(&reference))
	{
		test::@check(false, "the reference module has vertexMain and fragmentMain");
	}
	if (catch three::check_push_block(&reference.layout, three::MESH_PUSH_FIELDS[..]))
	{
		test::@check(false, "the reference module's push block matches the mesh contract");
	}
	// The numeric half's own text is what actually ran: a module that declared
	// no table but still carried the fitted helpers would compile and shade.
	test::@check(reference.layout.bindings.len() == fitted.layout.bindings.len() - 1,
		"one binding fewer than the fitted module: %d against %d",
		reference.layout.bindings.len(), fitted.layout.bindings.len());
}

<*
 The shadow modules declare only what their own path uses.

 **The decision the split exists to protect.** The depth-only module is the one
 every ordinary caster in the scene draws through, so a sampler or a fragment
 stage added to it would put a descriptor binding and a varying on all of them
 for nothing. The cut-out module is the other half of the same pair of files and
 must declare both: the sampler is where the discard reads its alpha from, and
 the fragment stage is where the discard happens. Neither claim is visible in a
 picture — a path that gained a binding still draws — so it is asserted on the
 modules the switch actually hands the pipeline builder.

 Checked through `compile_shader` and the table's own default, so the wiring and
 the module text are pinned together.
*>
fn void the_shadow_modules_declare_only_what_their_path_uses() @test
{
	defer three::shader_overrides_clear();

	three::shader_override(three::ShaderPass.SHADOW, three::ShaderCompiler.SHADY);
	three::ShaderModule? depth = three::compile_shader(
		three::ShaderPass.SHADOW, "", "three.shadow", three::SHADOW_ENTRIES[..]);
	if (catch depth)
	{
		test::@check(false, "the depth-only module compiled");
		return;
	}
	defer depth.free();
	test::@check(depth.ok, "the depth-only module compiles: %s", depth.diagnostic);
	test::@check(
		depth.layout.bindings.len() == 0 && depth.layout.set_count == 0,
		"it declares no sampler: %d bindings in %d sets",
		depth.layout.bindings.len(), depth.layout.set_count
	);
	test::@check(depth.entries.len() == 1, "and one entry point, got %d", depth.entries.len());
	bool fragment_stage = false;
	foreach (entry : depth.entries)
	{
		if (entry.stage == slang::STAGE_FRAGMENT) fragment_stage = true;
	}
	test::@check(!fragment_stage, "a vertex one: no fragment stage, so no varying for one to read");

	three::shader_override(three::ShaderPass.SHADOW_CUTOUT, three::ShaderCompiler.SHADY);
	three::ShaderModule? cutout = three::compile_shader(
		three::ShaderPass.SHADOW_CUTOUT, "", "three.shadow_cutout", three::SHADOW_CUTOUT_SHADY_ENTRIES[..]);
	if (catch cutout)
	{
		test::@check(false, "the cut-out module compiled");
		return;
	}
	defer cutout.free();
	test::@check(cutout.ok, "the cut-out module compiles: %s", cutout.diagnostic);

	bool carries_uv = false;
	bool reads_uv = false;
	foreach (entry : cutout.entries)
	{
		if (entry.name == "cutoutVertexMain" && entry.stage == slang::STAGE_VERTEX) carries_uv = true;
		if (entry.name == "fragmentMain" && entry.stage == slang::STAGE_FRAGMENT) reads_uv = true;
	}
	test::@check(carries_uv, "it declares cutoutVertexMain, the vertex entry that carries the uv");
	test::@check(reads_uv, "and a fragment stage, the only place the uv can be read and discarded");
	test::@check(cutout.layout.bindings.len() == 1, "one sampler, got %d", cutout.layout.bindings.len());
	three::ShaderBinding* sampler = cutout.layout.binding_of("three_textures");
	test::@check(
		sampler != null && sampler.set == 1 && sampler.binding == 0
			&& sampler.type == DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER && sampler.count == 1,
		"set 1 binding 0, the device texture table"
	);
	test::@check(cutout.layout.set_count == 2, "reaching its second set, got %d", cutout.layout.set_count);
}
