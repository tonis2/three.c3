<*
 Materials: the assembly, the push block it lands in, and the line numbers an
 agent reads.

	`c3c test --trust=full --test-noleak --test-filter three_tests::material`

 **No GPU anywhere in this file**, for the same reason `three_tests::shader` has
 none: assembling a module is string work and compiling one needs Slang and
 nothing else. Every check here runs in milliseconds, which matters because the
 loop these tests protect is an agent editing a shading body and asking again.

 `plan.md` §7 asks for the thing rather than the flag, so a material that
 "assembles" is never asserted on the text alone — it is compiled, and the push
 block it produces is read back out of the module that would run. The one place
 text *is* asserted is `every_newline_in_the_module_is_really_a_newline`, and
 that is because §6's trap has no other symptom until the compiler sees it.

 The headline is `a_bad_body_reports_the_line_the_agent_wrote`. Everything about
 the `#line` bracketing exists for it: the agent wrote four lines and got back a
 module of a hundred and eighty, and a diagnostic that names a line in the
 hundred and eighty is a loop that does not close.
*>
module three_tests::material;

import three;
import vk;
import slang;
import std::core::test;
import std::io::path;
import std::io::file;

// A global rather than a function returning a slice literal: a slice literal is
// backed by the stack frame that made it, and c3c says so.
const three::ShaderEntry[2] BOTH_STAGES = {
	{ "vertexMain", slang::STAGE_VERTEX },
	{ "fragmentMain", slang::STAGE_FRAGMENT },
};

macro three::ShaderEntry[] both_stages() => BOTH_STAGES[..];

// `plan.md` §4's tier-2 example, character for character. If this stops
// compiling, the documented API is a lie.
const String PLAN_EXAMPLE = `float3 shade(Surface s) { return s.albedo * tint * (0.5 + 0.5 * sin(time)); }`;

<*
 The 1-based physical line of the first line containing `needle`, or zero.

 The restore `#line` names an absolute line in the assembled module, so a test
 that hardcoded the number would pass for as long as nobody edited the template's
 header comment. This finds it the way the assembler counts it.
*>
fn uint line_containing(String source, String needle)
{
	uint line = 1;
	usz start = 0;
	while (start < source.len)
	{
		usz end = start;
		while (end < source.len && source[end] != '\n') end++;
		if (source[start:end - start].contains(needle)) return line;
		line++;
		start = end + 1;
	}
	return 0;
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

	String source = three::material_source(PLAN_EXAMPLE, uniforms[..])!!;
	defer source.free(mem);

	three::ShaderModule mod = three::compile_slang(source, "material.slang", both_stages())!!;
	defer mod.free();

	test::@check(mod.ok, "it compiled: %s", mod.diagnostic);
	test::@check(mod.spirv.len > 0, "and produced a module");
	test::@check(mod.spirv.len % 4 == 0, "which is a whole number of words");
	test::@check(mod.diagnostic.len == 0, "with nothing to say about it: %s", mod.diagnostic);
	test::@check(mod.entries.len() == 2, "two entry points, got %d", mod.entries.len());
}

<*
 Every newline in the assembled module is a newline (`plan.md` §6).

 The trap is that a `\n` inside a C3 backtick raw string is a backslash and an
 `n`, so a shader built out of raw strings is one enormous line that looks
 correct in the editor. It is not a hypothetical for this file — every line
 boundary in the generated source is an instance of it — and the symptom is a
 `#line` directive that swallows the rest of the module.

 The needle below is itself written as a raw string, so the thing being searched
 for is literally the mistake being guarded against.
*>
fn void every_newline_in_the_module_is_really_a_newline() @test
{
	three::MaterialUniform[2] uniforms = { { "tint", 3, 1 }, { "time", 1, 1 } };

	String source = three::material_source(PLAN_EXAMPLE, uniforms[..])!!;
	defer source.free(mem);

	test::@check(!source.contains(`\n`), "no literal backslash-n survived into the module");
	test::@check(
		line_containing(source, PLAN_EXAMPLE) > 1,
		"and the body is on a line of its own, at %d",
		line_containing(source, PLAN_EXAMPLE)
	);
	test::@check(
		line_containing(source, `#line 1 "material"`) > 0,
		"with the body's #line directive on a line of its own"
	);
}

<*
 The seven mesh push fields are still where `MeshPush` puts them, and the
 material's uniforms are after them.

 This is the check that makes a material safe to render with. `check_push_block`
 requires all seven at exactly these offsets, so a uniform inserted anywhere but
 the end moves `base_color` — and the failure that would follow is not a
 compile error, it is `positions` read out of the middle of a float4.

 The offsets are asserted as *reflected*, never assumed: scalar layout is a
 property of the flags `compile_slang` passes, and a build that lost
 `-force-glsl-scalar-layout` would lay this block out differently while
 compiling perfectly.
*>
fn void the_material_push_block_keeps_the_mesh_contract() @test
{
	three::MaterialUniform[2] uniforms = { { "tint", 3, 1 }, { "time", 1, 1 } };

	String source = three::material_source(PLAN_EXAMPLE, uniforms[..])!!;
	defer source.free(mem);

	three::ShaderModule mod = three::compile_slang(source, "material.slang", both_stages())!!;
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

	String source = three::material_source(`float3 shade(Surface s) { return s.albedo; }`, none)!!;
	defer source.free(mem);

	three::ShaderModule mod = three::compile_slang(source, "material.slang", both_stages())!!;
	defer mod.free();
	test::@check(mod.ok, "it compiled: %s", mod.diagnostic);

	test::@check(mod.layout.push_size == three::MATERIAL_PUSH_START,
		"%d bytes, the same as mesh.slang, got %d", three::MATERIAL_PUSH_START, mod.layout.push_size);
	test::@check(
		mod.layout.push_fields.len() == three::MESH_PUSH_FIELDS.len,
		"and %d fields, got %d",
		three::MESH_PUSH_FIELDS.len,
		mod.layout.push_fields.len()
	);
	test::@check(
		three::MATERIAL_UNIFORM_BUDGET == three::PUSH_BUDGET - mod.layout.push_size,
		"the budget is what is left of the 128: %d",
		three::MATERIAL_UNIFORM_BUDGET
	);
}

<*
 A uniform of each width reflects at the size it asked for, packed tightly.

 One check per width because each maps to a different Slang type and a
 `slang_type_of` that answered `float3` for two components would still compile,
 still reflect, and put every later uniform four bytes further along than the
 caller writes them.

 The offsets are the scalar-layout ones — 4, 8, 12 and 16 bytes with no padding
 between them — and they are read back rather than computed, because the layout
 is Slang's answer and not this project's arithmetic.
*>
fn void a_uniform_of_every_width_reflects_at_the_size_it_asked_for() @test
{
	three::MaterialUniform[4] uniforms = {
		{ "one", 1, 1 }, { "two", 2, 1 }, { "three", 3, 1 }, { "four", 4, 1 },
	};

	String source = three::material_source(
		`float3 shade(Surface s) { return s.albedo * one * two.x * three * four.xyz; }`,
		uniforms[..]
	)!!;
	defer source.free(mem);

	three::ShaderModule mod = three::compile_slang(source, "material.slang", both_stages())!!;
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
 A material declares the one descriptor the mesh pass does, and no more.

 The material template is a second copy of `mesh.slang`'s binding, and a copy is
 exactly the thing that drifts. A material that declared a different set layout
 would build a different pipeline layout, which is a validation error at best —
 and `plan.md` §7 is direct that reflection getting this wrong "produces a black
 screen, not an error".
*>
fn void the_material_declares_the_same_one_descriptor_the_mesh_pass_does() @test
{
	three::MaterialUniform[1] uniforms = { { "tint", 3, 1 } };

	String source = three::material_source(
		`float3 shade(Surface s) { return s.albedo * tint; }`,
		uniforms[..]
	)!!;
	defer source.free(mem);

	three::ShaderModule mod = three::compile_slang(source, "material.slang", both_stages())!!;
	defer mod.free();
	test::@check(mod.ok, "it compiled: %s", mod.diagnostic);

	// The template's two reserved samplers and nothing else, the same two
	// `mesh.slang` declares. `MATERIAL_BINDING_FIRST` rather than a literal 2,
	// because the claim is "a material reserves exactly what the mesh pass
	// reserves" and that constant is the other half of it.
	test::@check(
		mod.layout.bindings.len() == three::MATERIAL_BINDING_FIRST,
		"%d descriptors, got %d", three::MATERIAL_BINDING_FIRST, mod.layout.bindings.len()
	);
	three::ShaderBinding* map = mod.layout.binding_of("base_color_map");
	test::@check(map != null, "and one is base_color_map");
	if (map == null) return;
	test::@check(map.type == DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, "a combined image sampler");
	test::@check(map.set == 0 && map.binding == 0, "at 0,0 — got %d,%d", map.set, map.binding);

	three::ShaderBinding* shadow = mod.layout.binding_of("shadow_map");
	test::@check(shadow != null, "and the other is shadow_map");
	if (shadow == null) return;
	test::@check(
		shadow.set == 0 && shadow.binding == three::SHADOW_BINDING,
		"at 0,%d — got %d,%d", three::SHADOW_BINDING, shadow.set, shadow.binding
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

 Slang's exact wording is not asserted — that is Slang's to change — but the
 identifier is, because an agent reads the message and the message has to name
 the thing it typed.

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

	String source = three::material_source(
		`float3 shade(Surface s)
{
    return s.albedo * notAFunction(s.uv);
}`,
		uniforms[..]
	)!!;
	defer source.free(mem);

	three::ShaderModule mod = three::compile_slang(source, "material.slang", both_stages())!!;
	defer mod.free();

	test::@check(!mod.ok, "it did not compile");
	test::@check(mod.spirv.len == 0, "and produced no module");
	test::@check(
		mod.diagnostic.contains("--> material:3:"),
		"naming line 3 of the body the agent wrote: %s",
		mod.diagnostic
	);
	test::@check(mod.diagnostic.contains("notAFunction"), "and the identifier that is wrong");
	// The echoed source line is the agent's own text, not the preamble's.
	test::@check(mod.diagnostic.contains("return s.albedo * notAFunction"), "and echoes their line back");
}

<*
 After the body, the numbering goes back to the template — at the right line.

 The restore `#line` is the half that is easy to leave out and impossible to
 notice, because a body without an error never reveals it. This forces a
 diagnostic *in the preamble* by giving `shade` an argument `fragmentMain` does
 not pass, and requires the reported line to be the physical line of the call.

 Both halves of Slang's answer are asserted. The error points into
 `three.material`, whose name is deliberately self-describing so that an agent
 seeing it knows the line is not one of theirs. The `note[E40011]: candidate:`
 record points back at `material:1`, which is the agent's declaration — that note
 is a leak of the preamble by construction and is left alone on purpose, because
 "got 1, expected 2" is the most useful sentence in the whole record.
*>
fn void the_numbering_goes_back_to_the_template_after_the_body() @test
{
	three::MaterialUniform[1] uniforms = { { "tint", 3, 1 } };

	String source = three::material_source(
		`float3 shade(Surface s, float k)
{
    return s.albedo * k;
}`,
		uniforms[..]
	)!!;
	defer source.free(mem);

	uint call_line = line_containing(source, "shade(s)");
	test::@check(call_line > 0, "the template calls shade(s) somewhere");

	three::ShaderModule mod = three::compile_slang(source, "material.slang", both_stages())!!;
	defer mod.free();

	test::@check(!mod.ok, "a shade of the wrong arity does not compile");

	@pool()
	{
		String wanted = string::tformat("--> three.material:%d:", call_line);
		test::@check(
			mod.diagnostic.contains(wanted),
			"the call site is reported at %s, got: %s",
			wanted,
			mod.diagnostic
		);
	};

	test::@check(
		mod.diagnostic.contains("--> material:1:"),
		"and the candidate note points back at the agent's own declaration: %s",
		mod.diagnostic
	);
}

<*
 A warning compiles, and still says something.

 `compile_slang` carries the diagnostic on both paths precisely so this case
 exists, and a caller that treated a non-empty diagnostic as failure would throw
 away a working material. Asserted through the material layer as well as through
 the compiler because the `#line` bracketing has to hold for warnings too — a
 warning at a preamble line number is as useless as an error at one.
*>
fn void a_warning_compiles_and_still_says_something() @test
{
	three::MaterialUniform[] none = {};

	String source = three::material_source(
		`float3 shade(Surface s)
{
    float3 c;
    return c;
}`,
		none
	)!!;
	defer source.free(mem);

	three::ShaderModule mod = three::compile_slang(source, "material.slang", both_stages())!!;
	defer mod.free();

	test::@check(mod.ok, "a warning is not a failure");
	test::@check(mod.spirv.len > 0, "and still produced a module");
	test::@check(mod.diagnostic.len > 0, "and Slang had something to say");
	test::@check(
		mod.diagnostic.contains("--> material:4:"),
		"at the agent's line 4: %s",
		mod.diagnostic
	);
}

// ============================================================================
// What the template gives the body
// ============================================================================

<*
 A body can read the world position.

 `mesh.slang` has no world-position varying, so this is the one thing the
 material template adds to the vertex stage rather than copies. Nothing else in
 `Surface` can be used to recover it, and a body that wants a distance falloff or
 a world-space gradient starts here.
*>
fn void a_body_can_read_the_world_position() @test
{
	three::MaterialUniform[1] uniforms = { { "scale", 1, 1 } };

	String source = three::material_source(
		`float3 shade(Surface s) { return s.albedo * frac(s.position * scale); }`,
		uniforms[..]
	)!!;
	defer source.free(mem);

	three::ShaderModule mod = three::compile_slang(source, "material.slang", both_stages())!!;
	defer mod.free();

	test::@check(mod.ok, "a body that reads s.position compiles: %s", mod.diagnostic);
	test::@check(mod.spirv.len > 0, "and produced a module");
}

<*
 The default look is one call away.

 The claim the template's header makes: a material changes the shading body and
 nothing else, so the body that reproduces `mesh.slang` has to be writable. It is
 `s.albedo * lambert(s.normal)`, which is the same arithmetic `mesh.slang`'s
 `fragmentMain` performs. Asserted by compiling it, because a `lambert` that was
 removed or renamed would leave that promise as a comment.
*>
fn void the_default_look_is_one_call_away() @test
{
	three::MaterialUniform[] none = {};

	String source = three::material_source(
		`float3 shade(Surface s) { return s.albedo * lambert(s.normal); }`,
		none
	)!!;
	defer source.free(mem);

	three::ShaderModule mod = three::compile_slang(source, "material.slang", both_stages())!!;
	defer mod.free();

	test::@check(mod.ok, "mesh.slang's shading is one call: %s", mod.diagnostic);
	test::@check(mod.diagnostic.len == 0, "with nothing to say about it: %s", mod.diagnostic);
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

	String source = three::material_source(
		`float3 shade(Surface s) { return s.albedo * a; }`,
		uniforms[..]
	)!!;
	defer source.free(mem);

	three::ShaderModule mod = three::compile_slang(source, "material.slang", both_stages())!!;
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

 Left to Slang this is `undefined identifier 'shade'` at a preamble line, which
 says nothing about the actual mistake — that the `fragment` field of the
 material was blank.
*>
fn void an_empty_body_is_refused_before_the_compiler_sees_it() @test
{
	three::MaterialUniform[1] uniforms = { { "tint", 3, 1 } };

	String? assembled = three::material_source("  \n\t \n", uniforms[..]);
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

	String? assembled = three::material_source(PLAN_EXAMPLE, uniforms[..]);
	fault refused = @catch(assembled);

	test::@check(refused == three::MATERIAL_NAME_INVALID, "refused as a bad name, got %s", refused);
	test::@check(
		three::material_diagnostic().contains("2fast"),
		"naming the offending uniform: %s",
		three::material_diagnostic()
	);
}

<*
 A uniform name the template already uses is refused, and so is a Slang keyword.

 Two cases in one test because they are the same failure with different blast
 radii: `push` breaks the module it is substituted into, and `float` turns every
 declaration after it into something no diagnostic explains.
*>
fn void a_uniform_name_the_template_already_uses_is_refused() @test
{
	three::MaterialUniform[1] mine = { { "push", 4, 1 } };
	String? theirs = three::material_source(PLAN_EXAMPLE, mine[..]);
	fault refused = @catch(theirs);
	test::@check(refused == three::MATERIAL_NAME_INVALID, "'push' is refused, got %s", refused);
	test::@check(
		three::material_diagnostic().contains("push") && three::material_diagnostic().contains("reserved"),
		"as reserved, by name: %s",
		three::material_diagnostic()
	);

	three::MaterialUniform[1] keyword = { { "float", 1, 1 } };
	String? typed = three::material_source(PLAN_EXAMPLE, keyword[..]);
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

 Slang's own message for a duplicate field is about the struct three.c3
 generated, not about the two entries in the material's `uniforms` object, and
 the second one silently winning would be worse.
*>
fn void a_uniform_declared_twice_is_refused() @test
{
	three::MaterialUniform[3] uniforms = { { "tint", 3, 1 }, { "time", 1, 1 }, { "tint", 4, 1 } };

	String? assembled = three::material_source(PLAN_EXAMPLE, uniforms[..]);
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
	String? too_wide = three::material_source(PLAN_EXAMPLE, wide[..]);
	fault refused = @catch(too_wide);
	test::@check(refused == three::MATERIAL_NAME_INVALID, "five components is refused, got %s", refused);
	test::@check(
		three::material_diagnostic().contains("matrix_ish") && three::material_diagnostic().contains("5"),
		"naming it and its width: %s",
		three::material_diagnostic()
	);

	three::MaterialUniform[1] empty = { { "nothing", 0, 1 } };
	String? zero = three::material_source(PLAN_EXAMPLE, empty[..]);
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

	String source = three::material_source(
		`float3 shade(Surface s) { return s.albedo * a0.rgb * a1.rgb * a2.rgb * a3.rgb * a4.rgb * a5.rgb * a6.x; }`,
		exact[..]
	)!!;
	defer source.free(mem);

	three::ShaderModule mod = three::compile_slang(source, "material.slang", both_stages())!!;
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
	String? refused_source = three::material_source(PLAN_EXAMPLE, over[..]);
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
 nothing about whether Slang accepted an array in a push block at all.
*>
fn void a_uniform_with_rows_becomes_an_array() @test
{
	// Three rows rather than four: two columns of four rows is 64 bytes, and the
	// budget is 52 since `uv_transform` joined the mesh contract. Three keeps
	// both columns, which is what this check is really about — one column would
	// not exercise "every array in one material is a column of the same table".
	three::MaterialUniform[2] uniforms = { { "palette", 3, 3 }, { "sheen", 1, 3 } };

	String source = three::material_source(
		`float3 shade(Surface s) { return palette[s.variant] * (lambert(s.normal) + sheen[s.variant]); }`,
		uniforms[..]
	)!!;
	defer source.free(mem);

	test::@check(source.contains("float3 palette[3];"), "the column is declared as an array:\n%s", source);
	test::@check(source.contains("float sheen[3];"), "and so is the second one");
	test::@check(source.contains("MATERIAL_ROWS = 3u"), "and the row count is generated");

	three::ShaderModule mod = three::compile_slang(source, "material.slang", both_stages())!!;
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
 A material with no table still declares one row.

 `s.variant` is clamped against `MATERIAL_ROWS - 1`, so a generated zero would
 make the clamp `min(x, 0xffffffff)` — no clamp at all — and every material
 written before tables existed is one with no table.
*>
fn void a_material_with_no_table_has_one_row() @test
{
	three::MaterialUniform[1] uniforms = { { "tint", 3, 1 } };

	String source = three::material_source(
		`float3 shade(Surface s) { return tint * lambert(s.normal); }`, uniforms[..]
	)!!;
	defer source.free(mem);

	test::@check(source.contains("MATERIAL_ROWS = 1u"), "one row, not zero:\n%s", source);
	test::@check(source.contains("float3 tint;"), "and a plain uniform is not an array");
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

	String? refused_source = three::material_source(
		`float3 shade(Surface s) { return palette[s.variant]; }`, ragged[..]
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

	String source = three::material_source(
		`float3 shade(Surface s) { return palette[s.variant].rgb; }`, spilled[..]
	)!!;
	defer source.free(mem);

	three::ShaderModule mod = three::compile_slang(source, "material.slang", both_stages())!!;
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
		three::ShaderModule stored = three::compile_slang_cached(source, "material.slang", both_stages(), &ran)!!;
		defer stored.free();
		test::@check(ran, "the first compile came off disk, so nothing was stored");

		three::ShaderModule loaded = three::compile_slang_cached(source, "material.slang", both_stages(), &ran)!!;
		defer loaded.free();
		test::@check(!ran, "the second compile ran Slang, so the cache was not read");

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
// of the feature is that no layer above `shader/assemble.c3` ever writes one of
// those numbers, so every test here asserts the *reflection* rather than the
// text — the text is what was generated, and the reflection is what the draw
// will actually bind against.
// ============================================================================

// A body that samples three of them, so nothing here depends on Slang keeping a
// parameter it could prove was unused. The one test that does depend on that
// says so in its own name.
const String SAMPLING_BODY = `
float3 shade(Surface s)
{
    float3 n = noise_map.Sample(s.uv).rgb;
    float3 g = ramp_map.Sample(float2(s.uv.x, 0.5)).rgb;
    return lerp(n, g, mask_map.Sample(s.uv).r);
}`;

<*
 A declared texture is a combined image sampler at binding 1, and the body can
 read it by the name it was given.

 The headline of the feature, and the two halves matter separately. That it
 *compiles* is the assembler putting a declaration where the marker was; that it
 reflects as `COMBINED_IMAGE_SAMPLER` is what `MeshPipeline.init` will hand
 `vkCreateDescriptorSetLayout` — and a `Sampler2D` that came back as
 `SAMPLED_IMAGE` is a black screen with no validation message, which is the
 failure `shader/reflect.c3`'s header spends its longest paragraph on.

 **Proved by injection.** Emitting `Texture2D` instead of `Sampler2D` in
 `assemble_shader` compiles and reflects at the right index — only the type check
 below catches it.
*>
fn void a_declared_texture_is_a_binding_the_body_can_sample() @test
{
	three::MaterialTexture[3] textures = { { "noise_map" }, { "ramp_map" }, { "mask_map" } };

	String source = three::material_source(SAMPLING_BODY, {}, mem, textures[..])!!;
	defer source.free(mem);

	three::ShaderModule mod = three::compile_slang(source, "material.slang", both_stages())!!;
	defer mod.free();
	test::@check(mod.ok, "it compiled: %s", mod.diagnostic);

	test::@check(mod.layout.bindings.len() == three::MATERIAL_BINDING_FIRST + 3,
		"the template's two and the three the body asked for, got %d", mod.layout.bindings.len());

	three::ShaderBinding* noise = mod.layout.binding_of("noise_map");
	test::@check(noise != null, "the first is there by name");
	if (noise == null) return;
	test::@check(noise.type == DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
		"as a combined image sampler, got %d", (uint)noise.type);
	test::@check(noise.set == 0 && noise.binding == three::MATERIAL_BINDING_FIRST,
		"at 0,%d — got %d,%d", three::MATERIAL_BINDING_FIRST, noise.set, noise.binding);
	test::@check(noise.count == 1, "one descriptor, not an array: %d", noise.count);

	// The reserved bindings are still the template's own and are untouched by any
	// of this — a declared texture is numbered *past* them and never into them.
	three::ShaderBinding* map = mod.layout.binding_of("base_color_map");
	test::@check(map != null && map.binding == 0, "and the base colour map is still binding 0");
	three::ShaderBinding* shadow = mod.layout.binding_of("shadow_map");
	test::@check(
		shadow != null && shadow.binding == three::SHADOW_BINDING,
		"and the shadow map is still binding %d", three::SHADOW_BINDING
	);
}

<*
 The binding indices come from the order the textures were declared in, not from
 anything about their names.

 The claim that makes "you never write a binding number" safe: a script reorders
 its `textures` object and every sampler moves, which is fine precisely because
 nothing on either side remembers a number — the assembler numbers them and
 `sampler_binding_of` reads the numbers back by name.

 Asserted with the *same three names in a different order*, so a walk that
 happened to sort, or one that keyed on the name, produces the same answer twice
 and fails.
*>
fn void binding_indices_follow_the_declaration_order() @test
{
	three::MaterialTexture[3] forwards = { { "noise_map" }, { "ramp_map" }, { "mask_map" } };
	three::MaterialTexture[3] backwards = { { "mask_map" }, { "ramp_map" }, { "noise_map" } };

	String first = three::material_source(SAMPLING_BODY, {}, mem, forwards[..])!!;
	defer first.free(mem);
	String second = three::material_source(SAMPLING_BODY, {}, mem, backwards[..])!!;
	defer second.free(mem);

	three::ShaderModule a = three::compile_slang(first, "material.slang", both_stages())!!;
	defer a.free();
	three::ShaderModule b = three::compile_slang(second, "material.slang", both_stages())!!;
	defer b.free();
	test::@check(a.ok && b.ok, "both compiled: %s%s", a.diagnostic, b.diagnostic);

	// Spelled against `MATERIAL_BINDING_FIRST` rather than as literals, because the
	// claim here is about *order* and not about where the run starts — and the
	// start has moved once already, when the shadow map claimed binding 1.
	uint lowest = three::MATERIAL_BINDING_FIRST;
	uint highest = lowest + 2;

	test::@check(a.layout.binding_of("noise_map").binding == lowest, "declared first, bound at %d", lowest);
	test::@check(a.layout.binding_of("mask_map").binding == highest, "declared last, bound at %d", highest);

	test::@check(b.layout.binding_of("mask_map").binding == lowest, "and the other way round it is %d", lowest);
	test::@check(b.layout.binding_of("noise_map").binding == highest, "with the other at %d", highest);
}

<*
 A texture the body declares and never samples still reflects.

 **This is a test of Slang rather than of three.c3**, and it is here because the
 whole `textures:` path depends on the answer. Every name a script passes is
 resolved back through the compiled module's reflection, so a Slang that dropped
 unused parameters would turn `textures: { noise_map }` on a body that has not
 started sampling it yet into "this material's shader has no sampler called
 noise_map" — a message about a name that is right there in the source.

 It holds today. If a Slang upgrade changes it, this fails and says so, and the
 fix is a decision (accept the name silently, or refuse it with the reason) that
 should be made deliberately rather than discovered.
*>
fn void a_texture_the_body_never_samples_still_reflects() @test
{
	three::MaterialTexture[1] textures = { { "unused_map" } };

	String source = three::material_source(
		`float3 shade(Surface s) { return s.albedo * lambert(s.normal); }`, {}, mem, textures[..]
	)!!;
	defer source.free(mem);

	three::ShaderModule mod = three::compile_slang(source, "material.slang", both_stages())!!;
	defer mod.free();
	test::@check(mod.ok, "it compiled: %s", mod.diagnostic);

	test::@check(mod.layout.binding_of("unused_map") != null,
		"a declared-but-unsampled texture is still in the reflected layout — see this test's note if it is not");
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
	float3 shade(Surface s)
	{
	    return s.albedo * tint * gain * noise_map.Sample(s.uv).rgb * ramp_map.Sample(s.uv).rgb;
	}`;

	String bare = three::material_source(body, uniforms[..], mem, {})!!;
	defer bare.free(mem);
	String with_textures = three::material_source(body, uniforms[..], mem, textures[..])!!;
	defer with_textures.free(mem);

	three::ShaderModule a = three::compile_slang(bare, "material.slang", both_stages())!!;
	defer a.free();
	three::ShaderModule b = three::compile_slang(with_textures, "material.slang", both_stages())!!;
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

 The collision that has no other symptom worth reading. A uniform is a `#define`
 live across the agent's lines, so a sampler of the same name is rewritten to
 `push.<name>` at every use — and Slang then reports a push field being called
 like a function, at the agent's own line, about a name they used correctly.
*>
fn void a_texture_name_that_is_also_a_uniform_is_refused() @test
{
	three::MaterialUniform[1] uniforms = { { "tint", 3, 1 } };
	three::MaterialTexture[1] textures = { { "tint" } };

	String? assembled = three::material_source(PLAN_EXAMPLE, uniforms[..], mem, textures[..]);
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
 `material.slang`, so a second one is a redefinition a hundred lines from
 anything the agent wrote — and it is also the binding a script is *meant* to
 reach through `material.map`, so taking the name would be shadowing the property
 that already does the job.
*>
fn void a_texture_name_the_template_already_uses_is_refused() @test
{
	three::MaterialTexture[1] theirs = { { "base_color_map" } };
	fault refused = @catch(three::material_source(PLAN_EXAMPLE, {}, mem, theirs[..]));
	test::@check(refused == three::MATERIAL_NAME_INVALID, "'base_color_map' is refused, got %s", refused);
	test::@check(
		three::material_diagnostic().contains("base_color_map")
			&& three::material_diagnostic().contains("reserved"),
		"as reserved, by name: %s",
		three::material_diagnostic()
	);

	three::MaterialTexture[2] twice = { { "noise_map" }, { "noise_map" } };
	fault again = @catch(three::material_source(PLAN_EXAMPLE, {}, mem, twice[..]));
	test::@check(again == three::MATERIAL_NAME_INVALID, "and a duplicate is refused, got %s", again);
	test::@check(
		three::material_diagnostic().contains("twice"),
		"as a duplicate: %s",
		three::material_diagnostic()
	);

	three::MaterialTexture[1] punctuated = { { "noise-map" } };
	fault third = @catch(three::material_source(PLAN_EXAMPLE, {}, mem, punctuated[..]));
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

		fault refused = @catch(three::material_source(PLAN_EXAMPLE, {}, mem, too_many[..]));
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
		String source = three::material_source(PLAN_EXAMPLE, {}, mem, exactly[..])!!;
		defer source.free(mem);
		test::@check(source.len > 0, "and the limit itself is allowed");
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

const String WAVE_BODY = `void displace(inout Vertex v)
{
    v.position.y += sin(v.local.x * 3.0 + t) * amp;
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

	String source = three::material_source(
		`float3 shade(Surface s) { return s.albedo * lambert(s.normal); }`,
		uniforms[..],
		mem,
		{},
		WAVE_BODY
	)!!;
	defer source.free(mem);

	three::ShaderModule mod = three::compile_slang(source, "material.slang", both_stages())!!;
	defer mod.free();
	test::@check(mod.ok, "it compiled: %s", mod.diagnostic);

	// Both stages, from one module — the vertex body did not displace the
	// fragment one.
	test::@check(mod.entries.len() == 2, "two entry points, got %d", mod.entries.len());
	test::@check(mod.layout.field_of("amp") != null, "and the uniform the body reads is in the push block");
}

<*
 A material with no vertex body is the shader it was.

 The claim behind generating `void displace(inout Vertex v) { }` rather than
 branching the template: the call is there either way, and a compiler that folds
 an empty function leaves a module with the same push block, the same bindings and
 the same entry points as one written before a vertex stage existed.

 Asserted against the *push contract* rather than against the SPIR-V, because the
 SPIR-V is Slang's to optimise and the contract is the thing anything else
 depends on. `the_material_push_block_keeps_the_mesh_contract` covers the same
 ground for a material without either body; this says the identity vertex body
 does not move it.
*>
fn void a_material_without_a_vertex_body_is_the_shader_it_was() @test
{
	three::MaterialUniform[1] uniforms = { { "tint", 3, 1 } };
	String body = `float3 shade(Surface s) { return s.albedo * tint; }`;

	String plain = three::material_source(body, uniforms[..], mem)!!;
	defer plain.free(mem);
	String identity = three::material_source(body, uniforms[..], mem, {}, "")!!;
	defer identity.free(mem);

	test::@check(plain == identity, "an omitted vertex body and an empty one assemble identically");

	three::ShaderModule mod = three::compile_slang(plain, "material.slang", both_stages())!!;
	defer mod.free();
	test::@check(mod.ok, "and it compiles: %s", mod.diagnostic);
	test::@check(mod.layout.push_size == three::MATERIAL_PUSH_START + 12,
		"with the push block it always had, got %d", mod.layout.push_size);
	test::@check(
		mod.layout.bindings.len() == three::MATERIAL_BINDING_FIRST,
		"and the template's own bindings, got %d", mod.layout.bindings.len()
	);
}

<*
 A bad vertex body is reported at `vertex:<line>`, not at `material:<line>`.

 **The reason there are two body names rather than one.** Both bodies are spliced
 into one module and Slang reports one coordinate; an agent that wrote four lines
 of vertex and four of fragment and got `material:3` for a mistake in the first
 would read the wrong four lines and change the wrong thing. The arrow form is
 asserted for `a_bad_body_reports_the_line_the_agent_wrote`'s reason: `--> vertex:3:`
 cannot also be matched by a line in the preamble.

 The error is on line 3 of a four-line body so that a preamble which happened to
 be the right length cannot make this pass by accident.
*>
fn void a_bad_vertex_body_reports_the_vertex_file() @test
{
	String broken = `void displace(inout Vertex v)
{
    v.position.y += notAFunction(v.uv);
}`;

	String source = three::material_source(
		`float3 shade(Surface s) { return s.albedo; }`, {}, mem, {}, broken
	)!!;
	defer source.free(mem);

	three::ShaderModule mod = three::compile_slang(source, "three.material", both_stages())!!;
	defer mod.free();

	test::@check(!mod.ok, "the body does not compile");
	test::@check(mod.diagnostic.contains("--> vertex:3:"),
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
	fault refused = @catch(three::material_source(
		`float3 shade(Surface s) { return s.albedo; }`, clashing[..], mem, {},
		`void displace(inout Vertex v) { v.position += position; }`
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
	fault also = @catch(three::material_source(
		`float3 shade(Surface s) { return s.albedo * albedo; }`, fragment_side[..]
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

	String source = three::material_source(
		`float3 shade(Surface s) { return tint[s.variant] * s.color.rgb * s.albedo; }`,
		uniforms[..],
		mem,
		{},
		`void displace(inout Vertex v)
{
    v.uv = v.uv * 2.0;
    v.color = float4(v.color.rgb * 0.5, v.color.a);
    v.variant = v.index % 2u;
    v.normal = normalize(v.normal + float3(0.0, 0.2, 0.0));
}`
	)!!;
	defer source.free(mem);

	three::ShaderModule mod = three::compile_slang(source, "material.slang", both_stages())!!;
	defer mod.free();
	test::@check(mod.ok, "it compiled: %s", mod.diagnostic);
}
