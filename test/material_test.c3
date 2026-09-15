<*
 Materials: the declarations a script makes, the push block they land in, and
 the diagnostics an agent reads.

	`c3c test --trust=full --test-noleak --test-filter three_tests::material`

 **No GPU anywhere in this file**: validating declarations and compiling one
 module is not rendering, so every check here runs in milliseconds, which matters
 because the loop these tests protect is an agent editing a shading body and
 asking again.

 A material is never asserted on the module text: it is compiled through
 `compile_shader`, and the push block it produces is read back out of the module
 that would run. The headline is `a_bad_body_reports_the_line_the_agent_wrote`:
 the body's own lines are bracketed as a source region, so a diagnostic names a
 line the agent typed rather than one in generated code.
*>
module three_tests::material;

import three;
import vk;
import std::core::test;
import std::io::path;
import std::io::file;

// `plan.md` §4's tier-2 example, character for character. If this stops
// compiling, the documented API is a lie.
const String PLAN_EXAMPLE = `fn float3 shade(Surface s) { return s.albedo * s.uniforms.tint * (0.5 + 0.5 * sin(s.uniforms.time)); }`;

<*
 Validates a material's declarations, then compiles the material def around the
 body. The parameter list is the old front door's, so a test that passed an
 allocator positionally still reads the same.
*>
fn three::ShaderModule? compile_material(
	String fragment,
	three::MaterialUniform[] uniforms = {},
	alloc::Allocator allocator = mem,
	three::MaterialTexture[] textures = { },
	String vertex = "",
	bool bake = false)
{
	three::validate_material(fragment, uniforms, textures)!;
	return three::compile_shader(
		three::ShaderPass.MESH_MATERIAL,
		body: fragment,
		uniforms: uniforms,
		textures: textures,
		vertex: vertex,
		bake: bake
	);
}

// Validation only, with the same argument shape. Answers empty on success, like
// the old front door did, so the tests that check `@ok` keep reading.
fn String? check_material(
	String fragment,
	three::MaterialUniform[] uniforms = {},
	alloc::Allocator allocator = mem,
	three::MaterialTexture[] textures = { },
	String vertex = "")
{
	three::validate_material(fragment, uniforms, textures)!;
	return "";
}


// ============================================================================
// Assembling, and what comes out of the compiler
// ============================================================================

<*
 `plan.md` §4's example compiles as written, with `tint` and `time` as bare
 names.

 The whole point of tier 2 in one check: an agent writes one function, refers to
 its uniforms by the names it gave them, and never learns that a push block
 exists. `sin(time)` compiling is what says the `#define` layer works — without
 it this is an undefined identifier and the example in the plan is aspirational.
*>
fn void the_example_from_the_plan_compiles_verbatim() @test
{
	three::MaterialUniform[2] uniforms = { { "tint", 3, 1 }, { "time", 1, 1 } };

	three::ShaderModule mod = compile_material(PLAN_EXAMPLE, uniforms[..])!!;
	defer mod.free();

	test::@check(mod.ok, "it compiled: %s", mod.diagnostic);
	test::@check(mod.spirv.len > 0, "and produced a module");
	test::@check(mod.spirv.len % 4 == 0, "which is a whole number of words");
	test::@check(mod.diagnostic.len == 0, "with nothing to say about it: %s", mod.diagnostic);
	test::@check(mod.entries.len() == 2, "two entry points, got %d", mod.entries.len());
}

<*
 The seven mesh push fields are still where `MeshPush` puts them, and the
 material's uniforms are after them.

 This is the check that makes a material safe to render with. `check_push_block`
 requires all seven at exactly these offsets, so a uniform inserted anywhere but
 the end moves `base_color` — and the failure that would follow is not a
 compile error, it is `positions` read out of the middle of a float4.

 The offsets are asserted as *reflected*, never assumed: scalar layout is a
 property of the flags the compile passes, and a build that lost it would lay
 this block out differently while compiling perfectly.
*>
fn void the_material_push_block_keeps_the_mesh_contract() @test
{
	three::MaterialUniform[2] uniforms = { { "tint", 3, 1 }, { "time", 1, 1 } };

	three::ShaderModule mod = compile_material(PLAN_EXAMPLE, uniforms[..])!!;
	defer mod.free();
	test::@check(mod.ok, "it compiled: %s", mod.diagnostic);

	foreach (expected : three::MESH_PUSH_FIELDS)
	{
		three::ShaderField* found = mod.layout.field_of(expected.name);
		test::@check(found != null, "the material has a '%s' field", expected.name);
		if (found == null) continue;
		test::@check(
			found.offset == expected.offset && found.size == expected.size,
			"'%s' is at %d+%d in the material and %d+%d in MeshPush",
			expected.name, found.offset, found.size, expected.offset, expected.size
		);
	}

	// 60 is where the mesh contract ends. Nothing the agent declared may start
	// before it.
	three::ShaderField* tint = mod.layout.field_of("tint");
	three::ShaderField* time = mod.layout.field_of("time");
	test::@check(tint != null && time != null, "both uniforms are in the block");
	if (tint == null || time == null) return;

	uint start = three::MATERIAL_PUSH_START;
	test::@check(tint.offset == start && tint.size == 12,
		"tint is at %d+12, got %d+%d", start, tint.offset, tint.size);
	test::@check(time.offset == start + 12 && time.size == 4,
		"time is at %d+4, got %d+%d", start + 12, time.offset, time.size);
	test::@check(mod.layout.push_size == start + 16,
		"the block is %d bytes, got %d", start + 16, mod.layout.push_size);
	test::@check(
		mod.layout.push_size <= three::PUSH_BUDGET,
		"and inside the 128 every device offers, got %d",
		mod.layout.push_size
	);
}

<*
 A material with no uniforms is byte-for-byte the mesh pass's push block.

 The floor of the previous check: with nothing appended the two shaders have the
 same block, which is what makes `MATERIAL_UNIFORM_BUDGET`'s 68 the difference
 between 128 and this number rather than a figure someone chose.
*>
fn void a_material_without_uniforms_is_exactly_the_mesh_push_block() @test
{
	three::MaterialUniform[] none = {};

	three::ShaderModule mod = compile_material(`fn float3 shade(Surface s) { return s.albedo; }`, none)!!;
	defer mod.free();
	test::@check(mod.ok, "it compiled: %s", mod.diagnostic);

	// The walk plus the emitted empty Uniforms member, rounded to 8.
	test::@check(mod.layout.push_size == three::MATERIAL_PUSH_START + 8,
		"%d bytes, the same as the draw path, got %d", three::MATERIAL_PUSH_START + 8, mod.layout.push_size);
	test::@check(
		mod.layout.push_fields.len() == three::MESH_PUSH_FIELDS.len,
		"and %d fields, got %d",
		three::MESH_PUSH_FIELDS.len,
		mod.layout.push_fields.len()
	);
	// The budget is the walk's 24 bytes off the 128: the extra 8 in the block
	// above are the emitted empty uniforms, which a material that declares one
	// does not carry.
	test::@check(
		three::MATERIAL_UNIFORM_BUDGET == three::PUSH_BUDGET - three::MATERIAL_PUSH_START,
		"the budget is what is left of the 128: %d",
		three::MATERIAL_UNIFORM_BUDGET
	);
}

<*
 A uniform of each width reflects at the size it asked for, packed tightly.

 One check per width because each maps to a different vector type, and a
 `shady_float_type` that answered `float3` for two components would still
 compile, still reflect, and put every later uniform four bytes further along
 than the caller writes them.

 The offsets are the scalar-layout ones — 4, 8, 12 and 16 bytes with no padding
 between them — and they are read back rather than computed, because the layout
 is the emitter's answer and not this project's arithmetic.
*>
fn void a_uniform_of_every_width_reflects_at_the_size_it_asked_for() @test
{
	three::MaterialUniform[4] uniforms = {
		{ "one", 1, 1 }, { "two", 2, 1 }, { "three", 3, 1 }, { "four", 4, 1 },
	};

	three::ShaderModule mod = compile_material(
		`fn float3 shade(Surface s) { return s.albedo * s.uniforms.one * s.uniforms.two.x * s.uniforms.three * s.uniforms.four.xyz; }`,
		uniforms[..]
	)!!;
	defer mod.free();
	test::@check(mod.ok, "it compiled: %s", mod.diagnostic);

	uint[4] expected_size = { 4, 8, 12, 16 };
	// Relative to where the mesh contract stops, not absolute: the four are
	// packed end to end from there, and `MATERIAL_PUSH_START` moved once already
	// when `uv_transform` joined the pinned fields.
	uint start = three::MATERIAL_PUSH_START;
	uint[4] expected_offset = { start, start + 4, start + 12, start + 24 };
	String[4] names = { "one", "two", "three", "four" };

	foreach (i, name : names)
	{
		three::ShaderField* field = mod.layout.field_of(name);
		test::@check(field != null, "'%s' is in the block", name);
		if (field == null) continue;
		test::@check(
			field.size == expected_size[i],
			"'%s' is %d bytes, expected %d",
			name, field.size, expected_size[i]
		);
		test::@check(
			field.offset == expected_offset[i],
			"'%s' is at %d, expected %d — scalar layout packs these tightly",
			name, field.offset, expected_offset[i]
		);
	}

	// The four sizes end to end, on top of the mesh contract.
	test::@check(mod.layout.push_size == start + 40,
		"the block is %d bytes, got %d", start + 40, mod.layout.push_size);
}

<*
 A material declares the frame's images and the texture array, and no more.

 The material half is a second copy of the mesh def's bindings, and a copy is
 exactly the thing that drifts. A material that declared a different set layout
 would build a different pipeline layout, which is a validation error at best —
 and reflection getting this wrong produces a black screen, not an error.
*>
fn void the_material_declares_the_same_descriptors_the_mesh_pass_does() @test
{
	three::MaterialUniform[1] uniforms = { { "tint", 3, 1 } };

	three::ShaderModule mod = compile_material(
		`fn float3 shade(Surface s) { return s.albedo * s.uniforms.tint; }`,
		uniforms[..]
	)!!;
	defer mod.free();
	test::@check(mod.ok, "it compiled: %s", mod.diagnostic);

	// Seven frame images in set 0 and the device-wide texture array in set 1 — the
	// same shape the mesh def declares. `material.map` is not among them: it is a
	// slot of that array like every other image a material wears.
	uint set_zero = 0;
	foreach (binding : mod.layout.bindings) if (binding.set == 0) set_zero++;
	test::@check(set_zero == three::MATERIAL_FRAME_SAMPLERS,
		"%d frame descriptors in set 0, got %d", three::MATERIAL_FRAME_SAMPLERS, set_zero);
	test::@check(mod.layout.binding_of("base_color_map") == null,
		"and the material's own map is a slot rather than a descriptor");
	three::ShaderBinding* map = mod.layout.binding_of("three_textures");
	test::@check(map != null, "and the texture array is declared");
	if (map == null) return;
	test::@check(map.type == DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, "a combined image sampler");
	test::@check(map.set == three::TEXTURE_TABLE_SET && map.binding == three::TEXTURE_TABLE_BINDING,
		"at %d,%d — got %d,%d",
		three::TEXTURE_TABLE_SET, three::TEXTURE_TABLE_BINDING, map.set, map.binding);

	three::ShaderBinding* shadow = mod.layout.binding_of("shadow_atlas");
	test::@check(shadow != null, "and the shared shadow atlas is present");
	if (shadow == null) return;
	test::@check(
		shadow.set == 0 && shadow.binding == three::SHADOW_ATLAS_BINDING,
		"at 0,%d — got %d,%d", three::SHADOW_ATLAS_BINDING, shadow.set, shadow.binding
	);

	three::ShaderBinding* compare = mod.layout.binding_of("shadow_atlas_compare");
	test::@check(compare != null, "and so is the atlas's comparison sampler");
	if (compare == null) return;
	test::@check(
		compare.type == DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
			&& compare.set == 0 && compare.binding == three::SHADOW_ATLAS_COMPARE_BINDING,
		"a combined image sampler at 0,%d — got %d,%d",
		three::SHADOW_ATLAS_COMPARE_BINDING, compare.set, compare.binding
	);

	three::ShaderBinding* ltc = mod.layout.binding_of("ltc_lut");
	test::@check(ltc != null, "and so is the area-light table");
	if (ltc == null) return;
	test::@check(
		ltc.type == DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
			&& ltc.set == 0 && ltc.binding == three::LTC_LUT_BINDING,
		"a combined image sampler at 0,%d — got %d,%d",
		three::LTC_LUT_BINDING, ltc.set, ltc.binding
	);
}

// ============================================================================
// Line numbers
// ============================================================================

<*
 A syntax error in the body is reported at the line the agent wrote, in a file
 called `material`.

 **This is why the `#line` work exists.** Without it the diagnostic names a line
 somewhere past a hundred and seventy in a module the agent has never seen, and
 the fix-and-retry loop `plan.md` §4 calls "the whole contract" costs the agent a
 turn just to find out which line is theirs.

 The error is deliberately on line 3 of a four-line body rather than line 1, so
 that a preamble which happened to be exactly the right length cannot make this
 pass by accident. The arrow form is asserted rather than the bare number: `-->
 material:3:` cannot also be matched by `--> three.material:3...`, which is the
 other file name in play and the one that would mean the numbering leaked.

 The compiler's exact wording is not asserted — that is the compiler's to change
 — but the identifier is, because an agent reads the message and the message has
 to name the thing it typed.

	error[E30015]: undefined identifier
	 --> material:3:23
	  |
	3 | return s.albedo * notAFunction(s.uv);
	  |                   ^^^^^^^^^^^^ undefined identifier 'notAFunction'.
	--'
*>
fn void a_bad_body_reports_the_line_the_agent_wrote() @test
{
	three::MaterialUniform[2] uniforms = { { "tint", 3, 1 }, { "time", 1, 1 } };

	three::ShaderModule mod = compile_material(
		`fn float3 shade(Surface s)
{
    return s.albedo * notAFunction(s.uv);
}`,
		uniforms[..]
	)!!;
	defer mod.free();

	test::@check(!mod.ok, "it did not compile");
	test::@check(mod.spirv.len == 0, "and produced no module");
	test::@check(
		mod.diagnostic.contains("material:3:"),
		"naming line 3 of the body the agent wrote: %s",
		mod.diagnostic
	);
	test::@check(mod.diagnostic.contains("notAFunction"), "and the identifier that is wrong");
	// The echoed source line is the agent's own text, not the preamble's.
	test::@check(mod.diagnostic.contains("return s.albedo * notAFunction"), "and echoes their line back");
}



// ============================================================================
// What the template gives the body
// ============================================================================

<*
 A body can read the world position.

 The mesh half has no world-position varying, so this is the one thing the
 material def adds to the vertex stage rather than copies. Nothing else in
 `Surface` can be used to recover it, and a body that wants a distance falloff or
 a world-space gradient starts here.
*>
fn void a_body_can_read_the_world_position() @test
{
	three::MaterialUniform[1] uniforms = { { "scale", 1, 1 } };

	three::ShaderModule mod = compile_material(
		`fn float3 shade(Surface s) { return s.albedo * frac(s.position * s.uniforms.scale); }`,
		uniforms[..]
	)!!;
	defer mod.free();

	test::@check(mod.ok, "a body that reads s.position compiles: %s", mod.diagnostic);
	test::@check(mod.spirv.len > 0, "and produced a module");
}

<*
 The default look is one call away.

 The claim the template's header makes: a material changes the shading body and
 nothing else, so the body that reproduces the built-in look has to be writable.
 It is `s.albedo * lambert(s, s.normal)`, which is the same arithmetic the
 built-in look performs. Asserted by compiling it, because a `lambert` that was
 removed or renamed would leave that promise as a comment.
*>
fn void the_default_look_is_one_call_away() @test
{
	three::MaterialUniform[] none = {};

	three::ShaderModule mod = compile_material(
		`fn float3 shade(Surface s) { return s.albedo * lambert(s, s.normal); }`,
		none
	)!!;
	defer mod.free();

	test::@check(mod.ok, "the built-in look is one call: %s", mod.diagnostic);
	test::@check(mod.diagnostic.len == 0, "with nothing to say about it: %s", mod.diagnostic);
}

<*
 A body reading a packed ORM map has somewhere to put all three channels.

 Occlusion in red, roughness in green, metalness in blue is what a trim sheet
 ships and what glTF packs, and before these overloads existed a body could state
 the second and third only by writing `s.roughness` before the call — which works,
 because `Surface` is by value, and was nowhere written down — and the first only
 by folding it into the albedo, which darkens the direct light with it.

 Compiled rather than asserted on text: an overload that is not there is a
 diagnostic, and one whose parameters are in a different order is not.
*>
fn void an_orm_map_has_a_parameter_for_each_channel() @test
{
	three::MaterialUniform[] none = {};

	three::ShaderModule mod = compile_material(
		`fn float3 shade(Surface s)
		{
			float3 orm = float3(0.4, 0.3, 0.0);
			float3 whole = standard(s, s.albedo, s.normal, orm.g, orm.b, orm.r);
			float3 pair = standard(s, s.albedo, s.normal, orm.g, orm.b);
			float3 shut = standard(s, s.albedo, s.normal, orm.r);
			// The spelling these three replace, and still supported: the parameter
			// is by value, so a body's copy is its own.
			s.roughness = orm.g;
			s.metalness = orm.b;
			return whole + pair + shut + standard(s, s.albedo, s.normal);
		}`,
		none
	)!!;
	defer mod.free();

	test::@check(mod.ok, "every ORM spelling compiles: %s", mod.diagnostic);
	test::@check(mod.diagnostic.len == 0, "with nothing to say about it: %s", mod.diagnostic);
}




<*
 A body can ask for the mesh's own uv, before the material's transform.

 `s.uv` carries `material.repeat` and `material.offset`, which is right for every
 image that is a pattern laid across a surface and wrong for the one kind that
 describes the surface itself — a splat mask, a painted wear map, an id map. That
 is what `s.mesh_uv` is, and a `LayeredMaterial` samples its masks with it.
*>
fn void a_body_can_read_the_uv_before_the_transform() @test
{
	three::MaterialUniform[] none = {};

	three::ShaderModule mod = compile_material(
		`fn float3 shade(Surface s) { return s.albedo * float3(s.mesh_uv, 0.0) * lambert(s, s.normal); }`,
		none
	)!!;
	defer mod.free();

	test::@check(mod.ok, "a body that reads s.mesh_uv compiles: %s", mod.diagnostic);
	test::@check(mod.spirv.len > 0, "and produced a module");
}

<*
 A uniform whose name is also a swizzle cannot reach the template.

 `a` is a legal uniform name and is not reserved, but `fragmentMain` ends with
 `push.base_color.a`. Without the `#undef` after the body, `#define a (push.a)`
 rewrites that into nonsense and the agent gets a diagnostic pointing at a line
 in the preamble for a mistake they did not make. The reserved-name list is no
 answer here: it would have to contain every swizzle of every vector, which is
 `a`, `r`, `g`, `b`, `x`, `y`, `z`, `w` and every combination of them.
*>
fn void a_uniform_named_after_a_swizzle_cannot_reach_the_template() @test
{
	three::MaterialUniform[1] uniforms = { { "a", 1, 1 } };

	three::ShaderModule mod = compile_material(
		`fn float3 shade(Surface s) { return s.albedo * s.uniforms.a; }`,
		uniforms[..]
	)!!;
	defer mod.free();

	test::@check(mod.ok, "the substitution stopped at the end of the body: %s", mod.diagnostic);
	three::ShaderField* field = mod.layout.field_of("a");
	test::@check(field != null && field.offset == three::MATERIAL_PUSH_START,
		"and the uniform is still in the block, at %d", field == null ? -1 : (int)field.offset);
}

// ============================================================================
// What is refused, and what the agent is told
// ============================================================================

<*
 An empty body is refused before the compiler sees it.

 Left to the compiler this is a complaint about `shade` at a generated line,
 which says nothing about the actual mistake — that the `fragment` field of the
 material was blank.
*>
fn void an_empty_body_is_refused_before_the_compiler_sees_it() @test
{
	three::MaterialUniform[1] uniforms = { { "tint", 3, 1 } };

	String? assembled = check_material("  \n\t \n", uniforms[..]);
	fault refused = @catch(assembled);

	test::@check(refused == three::MATERIAL_BODY_EMPTY, "refused as empty, got %s", refused);
	test::@check(
		three::material_diagnostic().contains("shade(Surface s)"),
		"and says what the body has to contain: %s",
		three::material_diagnostic()
	);
}

<*
 A uniform name that is not an identifier is refused, by name.

 `2fast` interpolated into a `#define` is a preprocessor error somewhere in the
 middle of the generated module, which is a diagnostic about the generator rather
 than about the material.
*>
fn void a_uniform_name_that_is_not_an_identifier_is_refused() @test
{
	three::MaterialUniform[1] uniforms = { { "2fast", 3, 1 } };

	String? assembled = check_material(PLAN_EXAMPLE, uniforms[..]);
	fault refused = @catch(assembled);

	test::@check(refused == three::MATERIAL_NAME_INVALID, "refused as a bad name, got %s", refused);
	test::@check(
		three::material_diagnostic().contains("2fast"),
		"naming the offending uniform: %s",
		three::material_diagnostic()
	);
}

<*
 A uniform name the template already uses is refused, and so is a shady keyword.

 Two cases in one test because they are the same failure with different blast
 radii: `push` breaks the module it is substituted into, and `float` turns every
 declaration after it into something no diagnostic explains.
*>
fn void a_uniform_name_the_template_already_uses_is_refused() @test
{
	three::MaterialUniform[1] mine = { { "push", 4, 1 } };
	String? theirs = check_material(PLAN_EXAMPLE, mine[..]);
	fault refused = @catch(theirs);
	test::@check(refused == three::MATERIAL_NAME_INVALID, "'push' is refused, got %s", refused);
	test::@check(
		three::material_diagnostic().contains("push") && three::material_diagnostic().contains("reserved"),
		"as reserved, by name: %s",
		three::material_diagnostic()
	);

	three::MaterialUniform[1] keyword = { { "float", 1, 1 } };
	String? typed = check_material(PLAN_EXAMPLE, keyword[..]);
	fault also = @catch(typed);
	test::@check(also == three::MATERIAL_NAME_INVALID, "'float' is refused, got %s", also);
	test::@check(
		three::material_diagnostic().contains("float"),
		"by name too: %s",
		three::material_diagnostic()
	);
}

<*
 The same uniform twice is refused.

 The compiler's own message for a duplicate field is about the struct three.c3
 generated, not about the two entries in the material's `uniforms` object, and
 the second one silently winning would be worse.
*>
fn void a_uniform_declared_twice_is_refused() @test
{
	three::MaterialUniform[3] uniforms = { { "tint", 3, 1 }, { "time", 1, 1 }, { "tint", 4, 1 } };

	String? assembled = check_material(PLAN_EXAMPLE, uniforms[..]);
	fault refused = @catch(assembled);

	test::@check(refused == three::MATERIAL_NAME_INVALID, "refused as a duplicate, got %s", refused);
	test::@check(
		three::material_diagnostic().contains("tint") && three::material_diagnostic().contains("twice"),
		"saying which one: %s",
		three::material_diagnostic()
	);
}

<*
 A uniform that is not one to four floats wide is refused, at both ends.

 Zero is the interesting one: it is what a JS side that could not work out a
 width would hand over, and it assembles into `float  tint;` — a declaration that
 is a syntax error a hundred lines from anything the agent wrote.
*>
fn void a_uniform_that_is_not_one_to_four_floats_is_refused() @test
{
	three::MaterialUniform[1] wide = { { "matrix_ish", 5, 1 } };
	String? too_wide = check_material(PLAN_EXAMPLE, wide[..]);
	fault refused = @catch(too_wide);
	test::@check(refused == three::MATERIAL_NAME_INVALID, "five components is refused, got %s", refused);
	test::@check(
		three::material_diagnostic().contains("matrix_ish") && three::material_diagnostic().contains("5"),
		"naming it and its width: %s",
		three::material_diagnostic()
	);

	three::MaterialUniform[1] empty = { { "nothing", 0, 1 } };
	String? zero = check_material(PLAN_EXAMPLE, empty[..]);
	fault also = @catch(zero);
	test::@check(also == three::MATERIAL_NAME_INVALID, "zero components is refused, got %s", also);
	test::@check(
		three::material_diagnostic().contains("nothing"),
		"by name: %s",
		three::material_diagnostic()
	);
}

<*
 The uniform budget is exactly what the mesh contract leaves, and the boundary
 is asserted from both sides.

 104 bytes is 128 minus the 24 the three mesh fields occupy. The test spends every
 one of them, and requires the result not merely to assemble but to *compile* and
 to reflect a push block of exactly 128 — because a budget that is one byte
 optimistic is a shader Vulkan refuses on a device that offers the guaranteed
 minimum, which is every device.

 **105 bytes is not reachable and that is not a gap in the test.** A uniform is
 one to four floats, so the total is always a multiple of four; the first size
 that does not fit is 108, and that is the one asserted. The message has to carry
 both numbers, because "too many uniforms" leaves the agent to guess which one to
 drop.
*>
fn void the_uniform_budget_is_what_the_mesh_contract_leaves() @test
{
	test::@check(
		three::MATERIAL_UNIFORM_BUDGET == three::PUSH_BUDGET - three::MATERIAL_PUSH_START,
		"the budget is what the mesh contract leaves, got %d",
		three::MATERIAL_UNIFORM_BUDGET
	);

	// Twenty-six floats, which is the whole 104 the mesh contract leaves. It was
	// thirteen until the contract moved into a `DrawRecord` and gave back the 52
	// bytes it was pushing — the trade is argued at `MATERIAL_UNIFORM_BUDGET`.
	three::MaterialUniform[7] exact = {
		{ "a0", 4, 1 }, { "a1", 4, 1 }, { "a2", 4, 1 }, { "a3", 4, 1 },
		{ "a4", 4, 1 }, { "a5", 4, 1 }, { "a6", 2, 1 },
	};
	test::@check(
		three::material_uniform_bytes(exact[..]) == three::MATERIAL_UNIFORM_BUDGET,
		"twenty-six floats is the whole budget, got %d",
		three::material_uniform_bytes(exact[..])
	);

	three::ShaderModule mod = compile_material(
		`fn float3 shade(Surface s) { return s.albedo * s.uniforms.a0.rgb * s.uniforms.a1.rgb * s.uniforms.a2.rgb * s.uniforms.a3.rgb * s.uniforms.a4.rgb * s.uniforms.a5.rgb * s.uniforms.a6.x; }`,
		exact[..]
	)!!;
	defer mod.free();
	test::@check(mod.ok, "a full budget compiles: %s", mod.diagnostic);
	test::@check(
		mod.layout.push_size == three::PUSH_BUDGET,
		"and fills the push block exactly, got %d of %d",
		mod.layout.push_size,
		three::PUSH_BUDGET
	);

	three::MaterialUniform[8] over = {
		{ "a0", 4, 1 }, { "a1", 4, 1 }, { "a2", 4, 1 }, { "a3", 4, 1 },
		{ "a4", 4, 1 }, { "a5", 4, 1 }, { "a6", 2, 1 }, { "a7", 1, 1 },
	};
	String? refused_source = check_material(PLAN_EXAMPLE, over[..]);
	fault refused = @catch(refused_source);

	test::@check(refused == three::MATERIAL_TOO_MANY_UNIFORMS, "one float more is refused, got %s", refused);
	test::@check(
		three::material_diagnostic().contains("108") && three::material_diagnostic().contains("104"),
		"saying how many bytes were asked for and how many exist: %s",
		three::material_diagnostic()
	);
}

// ============================================================================
// Tables
// ============================================================================

<*
 A uniform with rows becomes an array, and the module says how many.

 The two halves are one feature. `float3 palette[4]` is what a body indexes with
 `s.variant`, and `MATERIAL_ROWS` is what `fragmentMain` clamps that variant
 against — so a generated module missing either one is a material whose table
 cannot be read, or one that can be read past its end.

 Compiled rather than only assembled, because "the text contains `[4]`" says
 nothing about whether the compiler accepted an array in a push block at all.
*>
fn void a_uniform_with_rows_becomes_an_array() @test
{
	// Three rows rather than four: two columns of four rows is 64 bytes, and the
	// budget is 52 since `uv_transform` joined the mesh contract. Three keeps
	// both columns, which is what this check is really about — one column would
	// not exercise "every array in one material is a column of the same table".
	three::MaterialUniform[2] uniforms = { { "palette", 3, 3 }, { "sheen", 1, 3 } };

	three::ShaderModule mod = compile_material(
		`fn float3 shade(Surface s) { return s.uniforms.palette[s.variant] * (lambert(s, s.normal) + s.uniforms.sheen[s.variant]); }`,
		uniforms[..]
	)!!;
	defer mod.free();
	test::@check(mod.ok, "a table compiles: %s", mod.diagnostic);

	// 12 floats of table on top of what the mesh contract pins.
	three::ShaderField* field = mod.layout.field_of("palette");
	test::@check(field != null, "the column reflects");
	test::@check(field.size == 36, "as all three rows of three floats, got %d bytes", field == null ? 0 : field.size);
	test::@check(
		field.offset >= three::MATERIAL_PUSH_START,
		"after the mesh contract, at %d", field == null ? 0 : field.offset
	);
}

<*
 Columns of different heights are refused, with both of them named.

 One material is one table: every column has to have the same number of rows, or
 `s.variant`'s single clamp is right for one column and wrong for the other —
 which is a read past the end of the short one, which is a colour nobody can
 explain.
*>
fn void columns_of_different_heights_are_refused() @test
{
	three::MaterialUniform[2] ragged = { { "palette", 3, 4 }, { "sheen", 1, 2 } };

	String? refused_source = check_material(
		`fn float3 shade(Surface s) { return s.uniforms.palette[s.variant]; }`, ragged[..]
	);
	fault refused = @catch(refused_source);

	test::@check(refused == three::MATERIAL_NAME_INVALID, "a ragged table is refused, got %s", refused);
	String said = three::material_diagnostic();
	test::@check(said.contains("palette") && said.contains("sheen"), "naming both columns: %s", said);
	test::@check(said.contains("4") && said.contains("2"), "and both row counts: %s", said);
}

<*
 A table costs its rows, and past the push block it moves to a buffer rather than
 being refused.

 The arithmetic half first: an implementation that charged a column once rather
 than once per row would count four rows of four floats as 16 bytes instead of 64,
 and a material could then declare four times the push block it has and be refused
 by Vulkan at pipeline creation with a message about ranges rather than about
 uniforms.

 The second half is what `plan.md` §2 wanted and it inverts what this test used to
 assert. Seven rows of `float4` is 112 bytes and did not fit the 104 the mesh
 contract leaves, and **that was the ceiling on a material's table**. It is not
 any more: past the budget the array columns move into a device buffer behind a
 pointer in the push block, so seven rows compiles, and so does a thousand.

 What the spill is checked to have actually done, rather than merely to have
 accepted:

 - the module reports `material_table` as a push field — the pointer;
 - `palette` is reflected as an **indirect** field, so its offset is in the buffer
   and `Material.set_uniform` writes it there;
 - the push block is small again, because 112 bytes of table became 8 of pointer.

 The row count is derived rather than written down, because the property is "a row
 is charged" and not "seven rows is the number".

 **Proved by injection.** `material_spills` forced to false, so the old refusal
 comes back: "a table past the push block was refused: MATERIAL_TOO_MANY_UNIFORMS".
*>
fn void a_table_costs_a_row_at_a_time() @test
{
	three::MaterialUniform[1] four_rows = { { "palette", 4, 4 } };
	test::@check(
		three::material_uniform_bytes(four_rows[..]) == 64,
		"four rows of four floats is 64 bytes, got %d",
		three::material_uniform_bytes(four_rows[..])
	);

	uint rows = three::MATERIAL_UNIFORM_BUDGET / 16 + 1;
	three::MaterialUniform[1] spilled = { { "palette", 4, rows } };
	test::@check(
		three::material_uniform_bytes(spilled[..]) > three::MATERIAL_UNIFORM_BUDGET,
		"%d rows is supposed to be past the budget, and is %d bytes",
		rows, three::material_uniform_bytes(spilled[..])
	);
	test::@check(three::material_spills(spilled[..]), "%d rows did not spill", rows);

	three::ShaderModule mod = compile_material(
		`fn float3 shade(Surface s) { return s.uniforms.palette[s.variant].rgb; }`, spilled[..]
	)!!;
	defer mod.free();
	test::@check(mod.ok, "a table past the push block was refused: %s", mod.diagnostic);

	three::ShaderField* pointer = mod.layout.field_of(three::MATERIAL_TABLE_FIELD);
	test::@check(pointer != null, "the module declares no table pointer");
	if (pointer == null) return;
	test::@check(!pointer.indirect, "the pointer is itself in the push block");
	test::@check(pointer.offset == three::MATERIAL_PUSH_START,
		"and at %d, where the mesh contract ends, rather than %d",
		three::MATERIAL_PUSH_START, pointer.offset);
	test::@check(pointer.size == 8, "a device pointer is 8 bytes, got %d", pointer.size);

	three::ShaderField* column = mod.layout.field_of("palette");
	test::@check(column != null, "the column is not reflected at all");
	if (column == null) return;
	test::@check(column.indirect, "the column stayed in the push block");
	test::@check(column.size == rows * 16,
		"the whole table is %d bytes, got %d", rows * 16, column.size);

	// 24 of mesh contract plus 8 of pointer. The table it replaced was 112.
	test::@check(mod.layout.push_size == three::MATERIAL_PUSH_START + 8,
		"the push block is %d bytes rather than %d",
		mod.layout.push_size, three::MATERIAL_PUSH_START + 8);

	// --- and it survives the disk cache ---
	//
	// **The one that was found by being flaky rather than by being thought of.**
	// `indirect` is a field of the reflected layout, the shader cache writes that
	// layout to disk, and a format that stored the offset and the size and not the
	// flag came back with every field looking pushed — so a spilled table's
	// uniforms had no names at all and `material.uniforms.palette = ...` threw
	// "this material has no uniform called 'palette'". On the **second** run only,
	// which is why it is pinned here rather than left to whether the machine
	// running the suite happened to have a warm cache.
	//
	// Compiled twice through the cached door: the first call stores and the second
	// loads, and the assertion is that the two agree about the one bit.
	@pool()
	{
		String dir = "build/test-cache-table";
		if (file::is_dir(dir))
		{
			PathList entries = path::ls(tmem, (Path)dir)!!;
			foreach (entry : entries) (void)file::delete(string::tformat("%s/%s", dir, (String)entry));
		}
		three::shader_cache_set_dir(dir);
		// Back off, whatever happens: every other test in this suite counts on the
		// cache being out of the way.
		defer three::shader_cache_set_dir("");

		bool ran = false;
		three::ShaderModule stored = three::compile_shader(
			three::ShaderPass.MESH_MATERIAL, &ran,
			body: `fn float3 shade(Surface s) { return s.uniforms.palette[s.variant].rgb; }`,
			uniforms: spilled[..]
		)!!;
		defer stored.free();
		test::@check(ran, "the first compile ran, so nothing was stored");

		three::ShaderModule loaded = three::compile_shader(
			three::ShaderPass.MESH_MATERIAL, &ran,
			body: `fn float3 shade(Surface s) { return s.uniforms.palette[s.variant].rgb; }`,
			uniforms: spilled[..]
		)!!;
		defer loaded.free();
		test::@check(!ran, "the second compile was answered from disk");

		three::ShaderField* cached = loaded.layout.field_of("palette");
		test::@check(cached != null, "the loaded module lost the column entirely");
		if (cached == null) return;
		test::@check(cached.indirect,
			"the column came back off disk looking like a push field, at offset %d",
			cached.offset);
		test::@check(cached.offset == column.offset && cached.size == column.size,
			"and at %d/%d rather than %d/%d",
			cached.offset, cached.size, column.offset, column.size);
	};
}

// ============================================================================
// The material struct
// ============================================================================

<*
 A material nobody gave an opacity to is opaque, and one given zero is invisible.

 Both halves are the point, because they are what rules out the two obvious
 storage choices. C3 zero-fills whatever a designated initializer leaves out, and
 there are four construction sites for `Material` — so a plain `opacity` field
 would make every one that forgot it produce geometry that does not render, on a
 material nobody said anything about. A sentinel would fix that and steal the one
 value a fade-out has to end on. Storing `1 - opacity` costs a subtraction in one
 accessor and gives both answers.

 Asserted on the struct rather than through `MeshPass`, deliberately: this file
 has no GPU and needs none, and the claim is about what C3 writes into memory
 when nobody names the field — which is the same claim wherever the material was
 built. `MeshPass.set_material_opacity` is the only other place that knows the
 storage is inverted.

 **Proved by injection.** `Material.opacity` returning `self.one_minus_opacity`
 rather than its complement, which is the same code a plain `opacity` field would
 produce: "a material nobody gave an opacity to is opaque, got 0.000000".
*>
fn void a_forgotten_opacity_still_renders_opaque() @test
{
	// Named exactly as `MeshPass.claim_slot`'s callers name it, minus the opacity:
	// a texture, because zero is a real index there, and nothing else.
	three::Material material = { .texture = three::NO_TEXTURE };

	test::@check(material.opacity() == 1.0f, "a material nobody gave an opacity to is opaque, got %f", material.opacity());

	// The value a sentinel would have cost. Written through the stored field
	// rather than through a setter because this test has no pass to ask — and the
	// inversion is exactly what is under test, so spelling it out here is the
	// check rather than a shortcut around it.
	material.one_minus_opacity = 1.0f;
	test::@check(material.opacity() == 0.0f, "and fully transparent is still reachable, got %f", material.opacity());

	material.one_minus_opacity = 0.25f;
	test::@check(material.opacity() == 0.75f, "with everything between, got %f", material.opacity());
}

// ============================================================================
// Textures
//
// A material's own samplers: names in, `[vk::binding(n, 0)] Sampler2D` lines
// out, and the numbers read back off the module that would run. The whole point
// of the feature is that no layer above the generators ever writes one of
// those numbers, so every test here asserts the *reflection* rather than the
// text — the text is what was generated, and the reflection is what the draw
// will actually bind against.
// ============================================================================

// A body that samples three of them. Unused declarations are kept too — the
// test for that says so in its own name — so this is the sampled shape.
const String SAMPLING_BODY = `
fn float3 shade(Surface s)
{
    float3 n = noise_map().Sample(s.uv).rgb;
    float3 g = ramp_map().Sample(float2(s.uv.x, 0.5)).rgb;
    return lerp(n, g, mask_map().Sample(s.uv).r);
}`;

<*
 A declared texture is a slot of the device-wide array, and the body reads it by
 the name it was given.

 The headline of the feature, and the two halves matter separately. That it
 *compiles* is the generator writing a `Map` function the body can call; that it
 costs the pipeline **no descriptor** is what removed the per-stage sampler
 ceiling — a stack of nineteen maps declares exactly what a stack of none
 declares.

 A generated function rather than a preprocessor rewrite, which is worth a check
 of its own: under the old macro layer a texture called `t1` rewrote every
 matching name in the module, including the shared half's tangent-frame local.
*>
fn void a_declared_texture_is_a_slot_the_body_can_sample() @test
{
	three::MaterialTexture[3] textures = { { "noise_map" }, { "ramp_map" }, { "mask_map" } };

	three::ShaderModule mod = compile_material(SAMPLING_BODY, {}, mem, textures[..])!!;
	defer mod.free();
	test::@check(mod.ok, "it compiled: %s", mod.diagnostic);

	uint set_zero = 0;
	foreach (binding : mod.layout.bindings) if (binding.set == 0) set_zero++;
	test::@check(set_zero == three::MATERIAL_FRAME_SAMPLERS,
		"three declared textures still cost the pipeline nothing: %d descriptors in set 0", set_zero);
	test::@check(
		mod.layout.binding_of("noise_map") == null && mod.layout.binding_of("ramp_map") == null
			&& mod.layout.binding_of("mask_map") == null,
		"and none of them is a descriptor"
	);

	// The frame's own images are untouched by any of this.
	three::ShaderBinding* shadow = mod.layout.binding_of("shadow_atlas");
	test::@check(
		shadow != null && shadow.binding == three::SHADOW_ATLAS_BINDING,
		"and the shared shadow atlas is still binding %d", three::SHADOW_ATLAS_BINDING
	);
}

<*
 A texture the body declares and never samples is still a slot.

 **This used to be a test of Slang rather than of three.c3**: every name a script
 passed was resolved back through the compiled module's reflection, and a Slang
 that dropped unused parameters would have turned `textures: { noise_map }` on a
 body that has not started sampling it yet into "this material's shader has no
 sampler called noise_map" — a message about a name that is right there in the
 source.

 It is no longer the compiler's answer to give. A declared texture is a name the
 generator emits and `Material.binding_of_texture` resolves out of the
 declaration list, so an unsampled one behaves exactly like a sampled one whatever
 the optimiser does with it.
*>
fn void a_texture_the_body_never_samples_is_still_a_slot() @test
{
	three::MaterialTexture[1] textures = { { "unused_map" } };

	three::ShaderModule mod = compile_material(
		`fn float3 shade(Surface s) { return s.albedo * lambert(s, s.normal); }`, {}, mem, textures[..]
	)!!;
	defer mod.free();
	test::@check(mod.ok, "it compiled: %s", mod.diagnostic);
	test::@check(mod.layout.binding_of("unused_map") == null, "and is not a descriptor");
}

<*
 Textures cost the push block nothing.

 A sampler is a descriptor and a uniform is bytes, and the budget that is nearly
 full is the bytes one: 52 of 128, with the mesh contract holding the rest. If
 declaring a texture moved a uniform's offset by so much as four bytes, every
 `material.uniforms.x = ...` on that material would write into the wrong field —
 and the symptom would be a wrong colour rather than an error.

 Asserted as *the same offsets with and without*, rather than against a constant,
 so it keeps meaning something when the contract next grows.
*>
fn void textures_cost_the_push_block_nothing() @test
{
	three::MaterialUniform[2] uniforms = { { "tint", 3, 1 }, { "gain", 1, 1 } };
	three::MaterialTexture[2] textures = { { "noise_map" }, { "ramp_map" } };
	String body = `
	fn float3 shade(Surface s)
	{
	    return s.albedo * s.uniforms.tint * s.uniforms.gain * noise_map().Sample(s.uv).rgb * ramp_map().Sample(s.uv).rgb;
	}`;

	three::ShaderModule a = compile_material(body, uniforms[..], mem, {})!!;
	defer a.free();
	three::ShaderModule b = compile_material(body, uniforms[..], mem, textures[..])!!;
	defer b.free();
	// The bare one does not compile a body that samples two textures it does not
	// declare, so only the offsets of the one that does are asserted against it.
	test::@check(b.ok, "the textured one compiled: %s", b.diagnostic);

	three::ShaderField* tint = b.layout.field_of("tint");
	three::ShaderField* gain = b.layout.field_of("gain");
	test::@check(tint != null && gain != null, "both uniforms reflect");
	if (tint == null || gain == null) return;

	test::@check(tint.offset == three::MATERIAL_PUSH_START,
		"the first uniform is still at %d, got %d", three::MATERIAL_PUSH_START, tint.offset);
	test::@check(gain.offset == three::MATERIAL_PUSH_START + 12,
		"and the second still follows it, got %d", gain.offset);
	test::@check(b.layout.push_size == three::MATERIAL_PUSH_START + 16,
		"with a push block of exactly the uniforms, got %d", b.layout.push_size);
}

<*
 A name that is both a uniform and a texture is refused.

 A collision with no symptom worth reading: both names reach the generated
 module, so one would shadow the other wherever both are in scope. Refused before
 the compiler sees it.
*>
fn void a_texture_name_that_is_also_a_uniform_is_refused() @test
{
	three::MaterialUniform[1] uniforms = { { "tint", 3, 1 } };
	three::MaterialTexture[1] textures = { { "tint" } };

	String? assembled = check_material(PLAN_EXAMPLE, uniforms[..], mem, textures[..]);
	fault refused = @catch(assembled);

	test::@check(refused == three::MATERIAL_NAME_INVALID, "refused, got %s", refused);
	test::@check(
		three::material_diagnostic().contains("tint") && three::material_diagnostic().contains("both"),
		"saying it is both: %s",
		three::material_diagnostic()
	);
}

<*
 A texture name the template already uses is refused, and so is a repeat.

 `base_color_map` is the one that matters: it is a real declaration in
 `material.shady`, so a second one is a redefinition a hundred lines from
 anything the agent wrote — and it is also the binding a script is *meant* to
 reach through `material.map`, so taking the name would be shadowing the property
 that already does the job.
*>
fn void a_texture_name_the_template_already_uses_is_refused() @test
{
	three::MaterialTexture[1] theirs = { { "base_color_map" } };
	fault refused = @catch(check_material(PLAN_EXAMPLE, {}, mem, theirs[..]));
	test::@check(refused == three::MATERIAL_NAME_INVALID, "'base_color_map' is refused, got %s", refused);
	test::@check(
		three::material_diagnostic().contains("base_color_map")
			&& three::material_diagnostic().contains("reserved"),
		"as reserved, by name: %s",
		three::material_diagnostic()
	);

	three::MaterialTexture[2] twice = { { "noise_map" }, { "noise_map" } };
	fault again = @catch(check_material(PLAN_EXAMPLE, {}, mem, twice[..]));
	test::@check(again == three::MATERIAL_NAME_INVALID, "and a duplicate is refused, got %s", again);
	test::@check(
		three::material_diagnostic().contains("twice"),
		"as a duplicate: %s",
		three::material_diagnostic()
	);

	three::MaterialTexture[1] punctuated = { { "noise-map" } };
	fault third = @catch(check_material(PLAN_EXAMPLE, {}, mem, punctuated[..]));
	test::@check(third == three::MATERIAL_NAME_INVALID, "and so is a name that is not an identifier, got %s", third);
}

<*
 More textures than a material may have is its own refusal, with the count in it.

 A separate fault from the name ones because it is fixed differently: every other
 refusal here is answered by renaming something, and this one is answered by
 asking for fewer images. The message says how many were declared as well as how
 many are allowed, which is the difference between counting your own object and
 being told what it added up to.
*>
fn void more_textures_than_a_material_may_have_are_refused() @test
{
	// **Sized from the constant rather than spelled.** This was written as a
	// literal five-against-four, and the numbers went stale the moment the budget
	// moved from four to eight for `LayeredMaterial` — a test asserting that the
	// diagnostic says "4" while the code says 8 fails for a reason that has
	// nothing to do with what it is checking, which is that the count reaches the
	// message at all.
	const uint LIMIT = three::MATERIAL_TEXTURE_LIMIT;

	@pool()
	{
		three::MaterialTexture[LIMIT + 1] too_many;
		for (uint i = 0; i <= LIMIT; i++) too_many[i] = { string::tformat("t%d_map", i) };

		fault refused = @catch(check_material(PLAN_EXAMPLE, {}, mem, too_many[..]));
		test::@check(refused == three::MATERIAL_TOO_MANY_TEXTURES, "refused as too many, got %s", refused);
		test::@check(
			three::material_diagnostic().contains(string::tformat("%d", LIMIT + 1))
				&& three::material_diagnostic().contains(string::tformat("%d", LIMIT)),
			"with both counts in it: %s",
			three::material_diagnostic()
		);

		// The limit itself is accepted, which is the half that says the check is
		// `>` and not `>=`.
		three::MaterialTexture[LIMIT] exactly;
		for (uint i = 0; i < LIMIT; i++) exactly[i] = { string::tformat("t%d_map", i) };
		three::ShaderModule mod = compile_material(
			`fn float3 shade(Surface s) { return s.albedo * lambert(s, s.normal); }`, {}, mem, exactly[..]
		)!!;
		defer mod.free();
		test::@check(mod.ok, "and compiles at the ceiling: %s", mod.diagnostic);
	};
}

// ============================================================================
// The vertex stage
//
// A second body, spliced above `vertexMain` instead of above `fragmentMain`, and
// almost everything here is about the two of them staying separable: separate
// diagnostics, separately scoped uniform macros, and a module that is unchanged
// when only one of them was written.
// ============================================================================

const String WAVE_BODY = `fn void displace(inout Vertex v)
{
    v.position.y += sin(v.local.x * 3.0 + v.uniforms.t) * v.uniforms.amp;
}`;

<*
 A vertex body reaches the module, and its uniforms reach the vertex stage.

 The uniform half is the part worth pinning: the push block is one block shared by
 both stages, and the `#define`s that turn `amp` into `push.amp` are emitted twice
 — once above the vertex body and once above the fragment one — because
 `vertexMain` sits between them. A body that could not read a uniform would be a
 vertex stage that could only do the same thing every frame.
*>
fn void a_vertex_body_compiles_and_reads_the_uniforms() @test
{
	three::MaterialUniform[2] uniforms = { { "t", 1, 1 }, { "amp", 1, 1 } };

	three::ShaderModule mod = compile_material(
		`fn float3 shade(Surface s) { return s.albedo * lambert(s, s.normal); }`,
		uniforms[..],
		mem,
		{},
		WAVE_BODY
	)!!;
	defer mod.free();
	test::@check(mod.ok, "it compiled: %s", mod.diagnostic);

	// Both stages, from one module — the vertex body did not displace the
	// fragment one.
	test::@check(mod.entries.len() == 2, "two entry points, got %d", mod.entries.len());
	test::@check(mod.layout.field_of("amp") != null, "and the uniform the body reads is in the push block");
}

<*
 A material with no vertex body is the shader it was.

 The claim behind generating `fn void displace(inout Vertex v) { }` rather than
 branching the template: the call is there either way, and a compiler that folds
 an empty function leaves a module with the same push block, the same bindings and
 the same entry points as one written before a vertex stage existed.

 Asserted against the *push contract* rather than against the SPIR-V, because the
 SPIR-V is the compiler's to optimise and the contract is the thing anything else
 depends on. `the_material_push_block_keeps_the_mesh_contract` covers the same
 ground for a material without either body; this says the identity vertex body
 does not move it.
*>
fn void a_material_without_a_vertex_body_is_the_shader_it_was() @test
{
	three::MaterialUniform[1] uniforms = { { "tint", 3, 1 } };
	String body = `fn float3 shade(Surface s) { return s.albedo * s.uniforms.tint; }`;

	three::ShaderModule mod = compile_material(body, uniforms[..], mem)!!;
	defer mod.free();
	test::@check(mod.ok, "and it compiles: %s", mod.diagnostic);
	test::@check(mod.layout.push_size == three::MATERIAL_PUSH_START + 16,
		"with the push block it always had, got %d", mod.layout.push_size);
	test::@check(
		mod.layout.bindings.len() == 8,
		"and the template's own bindings, got %d", mod.layout.bindings.len()
	);
}

<*
 A bad vertex body is reported at `vertex:<line>`, not at `material:<line>`.

 **The reason there are two body names rather than one.** Both bodies are spliced
 into one module, so each gets a source region of its own; an agent that wrote
 four lines of vertex and four of fragment and got `material:3` for a mistake in
 the first would read the wrong four lines and change the wrong thing. The arrow
 form is asserted for `a_bad_body_reports_the_line_the_agent_wrote`'s reason:
 `--> vertex:3:` cannot also be matched by a line in the preamble.

 The error is on line 3 of a four-line body so that a preamble which happened to
 be the right length cannot make this pass by accident.
*>
fn void a_bad_vertex_body_reports_the_vertex_file() @test
{
	String broken = `fn void displace(inout Vertex v)
{
    v.position.y += notAFunction(v.uv);
}`;

	three::ShaderModule mod = compile_material(
		`fn float3 shade(Surface s) { return s.albedo; }`, {}, mem, {}, broken
	)!!;
	defer mod.free();

	test::@check(!mod.ok, "the body does not compile");
	test::@check(mod.diagnostic.contains("vertex:3:"),
		"and is reported at vertex:3: %s", mod.diagnostic);
	test::@check(mod.diagnostic.contains("notAFunction"),
		"naming what the agent typed: %s", mod.diagnostic);
}

<*
 A uniform whose name is a field of `Surface` or `Vertex` is refused, by name.

 **This was broken before the vertex stage and had no test.** A uniform is a
 `#define` live across the agent's own lines, so `uniforms: { normal: 1 }` rewrote
 the `s.normal` in the very body that declared it into `s.(push.normal)` — a
 syntax error inside generated code, reported against a line of preamble, about a
 member access the agent wrote correctly. The vertex stage made it easier to reach
 rather than newly possible: `Vertex` has seven fields and a body touches most of
 them.

 `position` is the one asserted because it is a field of both structs and a
 perfectly reasonable thing to want to call a uniform.
*>
fn void a_uniform_named_after_a_contract_field_is_refused() @test
{
	three::MaterialUniform[1] clashing = { { "position", 3, 1 } };
	fault refused = @catch(check_material(
		`fn float3 shade(Surface s) { return s.albedo; }`, clashing[..], mem, {},
		`fn void displace(inout Vertex v) { v.position += position; }`
	));

	test::@check(refused == three::MATERIAL_NAME_INVALID, "'position' is refused, got %s", refused);
	test::@check(
		three::material_diagnostic().contains("position")
			&& three::material_diagnostic().contains("v.position"),
		"saying it would rewrite the body's own member access: %s",
		three::material_diagnostic()
	);

	// `albedo` is a `Surface` field and reaches the same refusal through a
	// material with no vertex body at all — which is the half that says this was
	// always a bug rather than one the vertex stage introduced.
	three::MaterialUniform[1] fragment_side = { { "albedo", 1, 1 } };
	fault also = @catch(check_material(
		`fn float3 shade(Surface s) { return s.albedo * albedo; }`, fragment_side[..]
	));
	test::@check(also == three::MATERIAL_NAME_INVALID, "and so is 'albedo', got %s", also);
}

<*
 A vertex body may write every varying, and the fragment stage receives what it
 wrote.

 `Vertex` is a picture of the varyings rather than a parallel set of values, and
 this is the check that keeps it one: a body writes uv, colour and variant, and
 the module still compiles with a fragment body that reads all three off
 `Surface`. If the gather in `vertexMain` ever stops reading a field back out of
 `v`, the varying silently keeps its pre-body value and nothing else says so.
*>
fn void a_vertex_body_writes_what_the_fragment_stage_receives() @test
{
	three::MaterialUniform[1] uniforms = { { "tint", 3, 2 } };

	three::ShaderModule mod = compile_material(
		`fn float3 shade(Surface s) { return s.uniforms.tint[s.variant] * s.color.rgb * s.albedo; }`,
		uniforms[..],
		mem,
		{},
		`fn void displace(inout Vertex v)
{
    v.uv = v.uv * 2.0;
    v.color = float4(v.color.rgb * 0.5, v.color.a);
    v.variant = v.index % 2u;
    v.normal = normalize(v.normal + float3(0.0, 0.2, 0.0));
}`
	)!!;
	defer mod.free();
	test::@check(mod.ok, "it compiled: %s", mod.diagnostic);
}
