<*
 The shady-backed compile, held to the ABI the engine consumes.

 The adapter is only useful if a `ShaderDef` reaches the pipeline builder as the
 same facts the Slang path produces: the entry points the pass names, the push
 block `check_push_block` already checks against `MESH_PUSH_FIELDS` and friends,
 and the bindings the draw path resolves by name. What these tests hold is
 exactly that, from the def through shady, with no call site flipped.

 The module is validated when `spirv-val` is on PATH, against the Vulkan
 environment rather than the generic one - the same reader kong uses. A missing
 tool skips with a message: it is a developer dependency, not a build one.
*>
module three_tests::shader_adapter;

import three;
import shady;
import slang;
import vk;
import std::core::test;
import std::io;
import std::io::file;
import std::io::path;
import std::os::process;

macro String default_shade()
{
	return `
fn float3 shade(Surface s)
{
	return standard(s);
}
`;
}

macro String identity_post()
{
	return `
fn float3 post(Post p)
{
	return p.color;
}
`;
}

macro String broken_post()
{
	return `
fn float3 post(Post p)
{
	return p.color * notAFunction(p.uv);
}
`;
}

fn void check_validates(char[] spirv, String name)
{
	path::mkdir("build/adapter", recursive: true)!!;
	String out = string::tformat("build/adapter/%s.spv", name);
	file::save(out, spirv)!!;

	int? status = process::run({ "spirv-val", "--target-env", "vulkan1.3", "--scalar-block-layout", out });
	if (catch status)
	{
		io::printfn("adapter: no spirv-val on PATH; %s is kong's to validate", out);
		return;
	}
	test::@check(status == 0, "%s validates for Vulkan (spirv-val said %d)", name, status);
}

<*
 The first port, through the adapter: the draw path's module as the engine will
 take it.

 The push block is compared against `MESH_PUSH_FIELDS` through the same
 `check_push_block` the pipeline builder calls, so this is the engine's contract
 rather than a copy of it. The byte comparison against a direct shady compile of
 the generated text is what says the shading is the def's own - the adapter
 changed no line of it.
*>
fn void the_mesh_def_arrives_with_the_engines_abi() @test
{
	// The material half declares `Surface.uniforms`, so a material def always
	// carries the emitted struct - an empty list emits the reserved padding
	// field that keeps the type the same for every material.
	DString uniforms;
	uniforms.tinit(64);
	three::append_shady_uniforms(&uniforms, {});

	three::ShaderDef def = three::mesh_def(default_shade(), uniforms.str_view());
	three::ShaderModule mod = three::compile_shady(def, three::MeshPush);
	defer mod.free();

	test::@check(mod.ok, "the ported mesh compiles: %s", mod.diagnostic);

	// The entry points `MESH_ENTRIES` names, read back out of the module.
	test::@check(mod.entries.len() == 2, "two entry points, got %d", mod.entries.len());
	bool vertex = false;
	bool fragment = false;
	foreach (entry : mod.entries)
	{
		if (entry.name == "vertexMain" && entry.stage == slang::STAGE_VERTEX) vertex = true;
		if (entry.name == "fragmentMain" && entry.stage == slang::STAGE_FRAGMENT) fragment = true;
	}
	test::@check(vertex, "vertexMain is a vertex shader");
	test::@check(fragment, "fragmentMain is a fragment shader");
	if (catch three::check_entry_points(&mod))
	{
		test::@check(false, "check_entry_points refused the module");
	}

	// The push block is the walked C3 struct plus the emitted member: 24 bytes
	// for the three addresses, then the reserved padding field, rounded to the
	// block's 8-byte alignment because it carries pointers.
	test::@check(mod.layout.push_size == 32,
		"the mesh block is 24 walked + 4 padding rounded to 8, got %d", mod.layout.push_size);
	test::@check(three::MATERIAL_PUSH_START == 24, "MATERIAL_PUSH_START is where the walk ends");
	if (catch three::check_push_block(&mod.layout, three::MESH_PUSH_FIELDS[..]))
	{
		test::@check(false, "check_push_block does not recognise the reflected push block");
	}
	test::@check(mod.layout.field_of("frame") != null && mod.layout.field_of("instances") != null
			&& mod.layout.field_of("draw") != null,
		"every walked field is present by name");
	test::@check(mod.layout.field_of("material_unused") == null,
		"and the reserved padding is not a uniform");

	// The file's own resources reach the layout: set 0's shadow comparison
	// samplers at the engine's own bindings, and the device-wide texture array
	// at set 1. The adapter did not know either of them; it read them out of
	// the module about to run.
	uint shadow_samplers = 0;
	bool textures = false;
	foreach (binding : mod.layout.bindings)
	{
		if (binding.set == 0 && (binding.binding == 18 || binding.binding == 21)
			&& binding.type == DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER)
		{
			shadow_samplers++;
		}
		if (binding.set == 1 && binding.binding == 0
			&& binding.type == DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER)
		{
			textures = true;
		}
	}
	test::@check(mod.layout.set_count == 2, "two sets, got %d", mod.layout.set_count);
	test::@check(shadow_samplers == 2 && textures,
		"the shadow samplers and the texture array are the bindings the module declares");

	// The def's own lines reached the module, and the module is exactly what
	// compiling the generated text produces.
	test::@check(((String)mod.spirv).contains("mesh_vertex"), "the ported vertex path is in the module");

	DString generated;
	generated.tinit(64 * 1024);
	three::append_shader_def(&generated, def, three::MeshPush);
	shady::Diagnostic diagnostic;
	char[]? direct = shady::compile(generated.str_view(), &diagnostic, scalar_layout: true);
	if (catch direct)
	{
		test::@check(false, "the def's own text does not compile: %s", diagnostic.to_string(tmem));
	}
	else
	{
		test::@check((String)mod.spirv == (String)direct, "the module is the def's shading, byte for byte");
		free(direct);
	}
	diagnostic.free();

	check_validates(mod.spirv, "mesh");
}

<*
 A def with resources and uniforms: the two things the reflection has to derive
 rather than copy.

 The bindings come out of the SPIR-V, by name, the way `sampler_binding_of` asks
 for them; the uniform fields are the emitted struct's members, flattened to the
 offsets a `Material.set_uniform` writes through. `POST_PUSH_START` is the line
 between the contract's fields and the agent's.
*>
fn void a_post_def_reflects_its_bindings_and_uniforms() @test
{
	three::MaterialUniform[] declared = {
		{ "gain", 1, 1 }, // one float, 4 bytes
		{ "tint", 4, 1 }, // one float4, 16 bytes
	};
	DString uniforms;
	uniforms.tinit(256);
	three::append_shady_uniforms(&uniforms, declared);

	three::ShaderDef def = three::post_def(identity_post(), uniforms.str_view());
	three::ShaderModule mod = three::compile_shady(def, three::PostPush);
	defer mod.free();

	test::@check(mod.ok, "the ported post compiles: %s", mod.diagnostic);
	test::@check(mod.layout.push_size == 24 + 20, "the push block is the header plus the set, got %d", mod.layout.push_size);

	// The four reserved samplers, at the bindings the post path binds them by.
	test::@check(mod.layout.bindings.len() == 4, "four samplers, got %d", mod.layout.bindings.len());
	test::@check(mod.layout.set_count == 1, "in one set, got %d", mod.layout.set_count);
	String[4] names = { "prev", "scene", "depth_buffer", "tap_image" };
	foreach (i, name : names)
	{
		three::ShaderBinding* binding = mod.layout.binding_of(name);
		test::@check(binding != null && binding.binding == (uint)i
				&& binding.set == 0
				&& binding.type == DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
				&& binding.count == 1,
			"%s is set 0 binding %d as a combined image sampler", name, (int)i);
	}
	test::@check(mod.layout.stages
			== (vk::ShaderStageFlags)(vk::ShaderStageFlagBits.SHADER_STAGE_VERTEX_BIT
				| vk::ShaderStageFlagBits.SHADER_STAGE_FRAGMENT_BIT),
		"with both stages, got %d", mod.layout.stages);

	// The flattened uniforms: `p.uniforms.gain` at the first byte past the
	// header, `p.uniforms.tint` after it.
	test::@check(three::POST_PUSH_START == 24 && mod.layout.push_size > three::POST_PUSH_START,
		"the agent's fields start at POST_PUSH_START");
	three::ShaderField* gain = mod.layout.field_of("gain");
	three::ShaderField* tint = mod.layout.field_of("tint");
	test::@check(gain != null && !gain.indirect && gain.offset == 24 && gain.size == 4,
		"gain is a direct field at 24+4");
	test::@check(tint != null && !tint.indirect && tint.offset == 28 && tint.size == 16,
		"tint follows it at 28+16");
	test::@check(mod.layout.field_of("material_unused") == null,
		"and the reserved padding is not a uniform");

	check_validates(mod.spirv, "post");
}

<*
 The spilled shape: the same fields behind a pointer, which is the case that
 makes the module a buffer-device-address one.

 What the engine reads for this shape is two things the adapter has to produce
 from the def: the `material_table` pointer's offset in the push block, and
 every uniform's offset inside the table buffer, marked indirect.
*>
fn void a_spilled_material_carries_the_table_pointer() @test
{
	three::MaterialUniform[] declared = {
		{ "tint", 4, 1 },
		{ "colors", 4, 32 }, // 32 rows of float4: 512 bytes, past the block
		{ "cells", 1, 1 },
	};
	test::@check(three::material_spills(declared), "this set outgrows the push block");

	DString uniforms;
	uniforms.tinit(1024);
	three::append_shady_uniforms(&uniforms, declared, true);

	three::ShaderDef def = three::mesh_def(default_shade(), uniforms.str_view());
	def.uniforms_spilled = true;

	three::ShaderModule mod = three::compile_shady(def, three::MeshPush);
	defer mod.free();

	test::@check(mod.ok, "the spilled material compiles: %s", mod.diagnostic);
	test::@check(mod.layout.push_size == 24 + 8, "the block is the walk plus the pointer, got %d", mod.layout.push_size);

	three::ShaderField* table = mod.layout.field_of(three::MATERIAL_TABLE_FIELD);
	test::@check(table != null && !table.indirect && table.offset == 24 && table.size == 8,
		"the pointer sits where MATERIAL_PUSH_START says");

	// The same names a script sets, at offsets inside the table buffer.
	three::ShaderField* tint = mod.layout.field_of("tint");
	three::ShaderField* colors = mod.layout.field_of("colors");
	three::ShaderField* cells = mod.layout.field_of("cells");
	test::@check(tint != null && tint.indirect && tint.offset == 0 && tint.size == 16,
		"tint is row 0 of the table");
	test::@check(colors != null && colors.indirect && colors.offset == 16 && colors.size == 512,
		"colors is the 32-row column after it");
	test::@check(cells != null && cells.indirect && cells.offset == 528 && cells.size == 4,
		"and cells follows the column");

	test::@check(((String)mod.spirv).contains("SPV_KHR_physical_storage_buffer"),
		"the module reaches the table through a device address");

	check_validates(mod.spirv, "material_spilled");
}

<*
 The module that carries another module's text: its own vertex entry has its
 own name, and its runtime texture array lives at set 1, so the layout has to
 report two sets for `build_layouts` to attach `TextureTable`'s.
*>
fn void a_cutout_shadow_def_reports_its_own_entries_and_sets() @test
{
	three::ShaderDef def = three::shadow_cutout_def();
	three::ShaderModule mod = three::compile_shady(def, three::ShadowPush);
	defer mod.free();

	test::@check(mod.ok, "the ported cutout module compiles: %s", mod.diagnostic);

	bool cutout = false;
	bool fragment = false;
	foreach (entry : mod.entries)
	{
		if (entry.name == "cutoutVertexMain" && entry.stage == slang::STAGE_VERTEX) cutout = true;
		if (entry.name == "fragmentMain" && entry.stage == slang::STAGE_FRAGMENT) fragment = true;
	}
	test::@check(cutout, "the cut-out vertex entry is named cutoutVertexMain");
	test::@check(fragment, "beside the fragment stage");

	test::@check(mod.layout.push_size == 96, "the shadow push block is 96 bytes, got %d", mod.layout.push_size);
	three::ShaderBinding* array = mod.layout.binding_of("three_textures");
	test::@check(array != null && array.set == 1 && array.binding == 0
			&& array.type == DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
		"the texture table is set 1 binding 0");
	test::@check(mod.layout.set_count == 2, "two sets are in use, got %d", mod.layout.set_count);

	check_validates(mod.spirv, "shadow_cutout");
}

<*
 A body that does not compile is the ordinary answer, not a fault: `ok` false,
 no module, and the diagnostic naming the body's own line - the same shape the
 Slang path returns, which is what an agent editing a script reads.
*>
fn void a_broken_def_comes_back_as_a_diagnostic() @test
{
	DString uniforms;
	uniforms.tinit(64);
	three::append_shady_uniforms(&uniforms, {});

	three::ShaderDef def = three::post_def(broken_post(), uniforms.str_view());
	three::ShaderModule mod = three::compile_shady(def, three::PostPush);
	defer mod.free();

	test::@check(!mod.ok, "it did not compile");
	test::@check(mod.spirv.len == 0, "and produced no module");
	test::@check(mod.diagnostic.contains("post_body:4"), "naming the body's own line: %s", mod.diagnostic);
}
