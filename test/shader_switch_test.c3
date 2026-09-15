<*
 The one dispatch in front of the defs.

 Every pass compiles through `compile_shader`, which picks the def and the push
 block the pass walks. There is no compiler choice left - the per-pass table
 collapsed when the port finished and Slang was deleted - so these tests hold
 what the call sites reach: the module's entry points, its push block and its
 bindings, checked from the module the pipeline builder is handed.

 `c3c test --trust=full --test-filter three_tests::shader_switch`
*>
module three_tests::shader_switch;

import three;
import vk;
import std::core::test;

<*
 The draw path's call reaches the built-in def: the two entry points, the walk of
 `MeshPush`, and the reserved frame descriptors the pipeline is built against.
*>
fn void the_draw_path_compiles_its_def() @test
{
	three::ShaderModule mod = three::compile_shader(three::ShaderPass.MESH)!!;
	defer mod.free();
	test::@check(mod.ok, "the draw path compiles: %s", mod.diagnostic);
	if (catch three::check_entry_points(&mod))
	{
		test::@check(false, "the module has vertexMain and fragmentMain");
	}
	if (catch three::check_push_block(&mod.layout, three::MESH_PUSH_FIELDS[..]))
	{
		test::@check(false, "the module's push block matches the mesh contract");
	}
	test::@check(mod.layout.push_size == 32,
		"the block is 24 walked bytes plus the empty uniforms, got %d", mod.layout.push_size);
	test::@check(mod.layout.field_of(three::MATERIAL_TABLE_FIELD) == null,
		"and a material with no uniforms has nothing to spill");

	uint set_zero = 0;
	foreach (binding : mod.layout.bindings) if (binding.set == 0) set_zero++;
	test::@check(set_zero == three::MATERIAL_FRAME_SAMPLERS,
		"%d frame descriptors in set 0, got %d", three::MATERIAL_FRAME_SAMPLERS, set_zero);
	three::ShaderBinding* array = mod.layout.binding_of("three_textures");
	test::@check(array != null && array.set == three::TEXTURE_TABLE_SET
			&& array.binding == three::TEXTURE_TABLE_BINDING,
		"and the device-wide texture array is set %d binding %d",
		three::TEXTURE_TABLE_SET, three::TEXTURE_TABLE_BINDING);
}

<*
 The one resource difference between the draw path and its numeric reference.

 The fitted module declares `ltc_lut` at binding 19; the reference module must
 not. **This is why the variant is a module and not a constant**: a spec
 constant cannot remove a binding, so a "reference" that still carried the table
 would keep a sampler on every draw in the frame for nothing - and the frame
 that has no table to bind could not run it.
*>
fn void the_reference_module_drops_the_fit_table() @test
{
	three::ShaderModule fitted = three::compile_shader(three::ShaderPass.MESH)!!;
	defer fitted.free();
	test::@check(fitted.ok, "the fitted draw path compiles: %s", fitted.diagnostic);
	test::@check(fitted.layout.binding_of("ltc_lut") != null, "the fit declares its table");

	three::ShaderModule reference = three::compile_shader(three::ShaderPass.MESH_REFERENCE)!!;
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
 The lightmap bake: the built-in draw path's default look, compiled with the
 bake's interface - the chart-space vertex stage and the baked diffuse answer.
 The LTC half is carried for its `area_diffuse`, so its table is declared even
 though the bake never reads it.
*>
fn void the_lightmap_call_site_compiles_the_bake() @test
{
	three::ShaderModule mod = three::compile_shader(three::ShaderPass.LIGHTMAP)!!;
	defer mod.free();
	test::@check(mod.ok, "the lightmap bake compiles: %s", mod.diagnostic);
	if (catch three::check_entry_points(&mod))
	{
		test::@check(false, "the lightmap module has vertexMain and fragmentMain");
	}
	test::@check(mod.layout.push_size == 32,
		"the block is 24 walked bytes plus the empty uniforms, got %d", mod.layout.push_size);
	test::@check(mod.layout.binding_of("lightmap_atlas") != null,
		"the atlas the built-in half samples is declared");
	three::ShaderBinding* fit = mod.layout.binding_of("ltc_lut");
	test::@check(fit != null && fit.set == 0 && fit.binding == 19,
		"and the LTC half's own table, at the engine's reserved binding");
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
 modules `compile_shader` actually hands the pipeline builder.
*>
fn void the_shadow_modules_declare_only_what_their_path_uses() @test
{
	three::ShaderModule depth = three::compile_shader(three::ShaderPass.SHADOW)!!;
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
		if (entry.stage == three::STAGE_FRAGMENT) fragment_stage = true;
	}
	test::@check(!fragment_stage, "a vertex one: no fragment stage, so no varying for one to read");

	three::ShaderModule cutout = three::compile_shader(three::ShaderPass.SHADOW_CUTOUT)!!;
	defer cutout.free();
	test::@check(cutout.ok, "the cut-out module compiles: %s", cutout.diagnostic);

	bool carries_uv = false;
	bool reads_uv = false;
	foreach (entry : cutout.entries)
	{
		if (entry.name == "cutoutVertexMain" && entry.stage == three::STAGE_VERTEX) carries_uv = true;
		if (entry.name == "fragmentMain" && entry.stage == three::STAGE_FRAGMENT) reads_uv = true;
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

// The bodies a scripted pass compiles with: one line each, reading a declared
// name so the regions the def emits are exercised.
const String POST_BODY = "fn float3 post(Post p) { return p.color * p.uniforms.gain; }";
const String MATERIAL_BODY = "fn float3 shade(Surface s) { return s.albedo * s.uniforms.tint; }";

<*
 A scripted pass reaches its def: the body is spliced, the declared uniforms are
 emitted into the push block, and the declared textures are declared where the
 body reads them.
*>
fn void a_scripted_post_reaches_the_post_def() @test
{
	three::MaterialUniform[1] gain = { { .name = "gain", .components = 1, .rows = 1 } };
	three::MaterialTexture[1] tint_map = { { .name = "tint_map" } };

	three::ShaderModule mod = three::compile_shader(
		three::ShaderPass.POST, body: POST_BODY, uniforms: gain[..], textures: tint_map[..])!!;
	defer mod.free();
	test::@check(mod.ok, "the scripted post compiles: %s", mod.diagnostic);

	test::@check(mod.layout.push_size == 28, "the header plus the one uniform is 28 bytes, got %d", mod.layout.push_size);
	three::ShaderField* field = mod.layout.field_of("gain");
	test::@check(field != null && field.offset == three::POST_PUSH_START && field.size == 4,
		"gain lands at POST_PUSH_START");
	three::ShaderBinding* declared = mod.layout.binding_of("tint_map");
	test::@check(declared != null && declared.set == 0 && declared.binding == three::POST_BINDING_FIRST,
		"and the declared texture is the next post binding");
}

<*
 A scripted material reaches the material def, and its spill shape is the pushed
 block plus the table pointer.
*>
fn void a_scripted_material_reaches_the_material_def() @test
{
	three::MaterialUniform[2] declared = {
		{ .name = "tint", .components = 3, .rows = 1 },
		{ .name = "swatches", .components = 4, .rows = 8 },
	};
	three::ShaderModule mod = three::compile_shader(
		three::ShaderPass.MESH_MATERIAL, body: MATERIAL_BODY, uniforms: declared[..])!!;
	defer mod.free();
	test::@check(mod.ok, "the scripted material compiles: %s", mod.diagnostic);
	test::@check(three::material_spills(declared[..]), "this set outgrows the push block");

	three::ShaderField* table = mod.layout.field_of(three::MATERIAL_TABLE_FIELD);
	test::@check(table != null && table.offset == three::MATERIAL_PUSH_START && table.size == 8,
		"the table pointer sits at MATERIAL_PUSH_START");
	three::ShaderField* tint = mod.layout.field_of("tint");
	three::ShaderField* swatches = mod.layout.field_of("swatches");
	test::@check(tint != null && tint.indirect && tint.offset == 0,
		"and the whole set is in the table buffer, scalars included");
	test::@check(swatches != null && swatches.indirect && swatches.offset == 12 && swatches.size == 128,
		"with the columns behind it");
}
