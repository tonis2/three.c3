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
import std::io;

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

	test::@check(mod.layout.bindings.len() == 1, "one descriptor, got %d", mod.layout.bindings.len());
	three::ShaderBinding* map = mod.layout.binding_of("base_color_map");
	test::@check(map != null, "and it is base_color_map");
	if (map == null) return;
	test::@check(map.type == DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, "a combined image sampler");
	test::@check(map.set == 0 && map.binding == 0, "at 0,0 — got %d,%d", map.set, map.binding);
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

 68 bytes is 128 minus the 60 the seven mesh fields occupy. The test spends every
 one of them, and requires the result not merely to assemble but to *compile* and
 to reflect a push block of exactly 128 — because a budget that is one byte
 optimistic is a shader Vulkan refuses on a device that offers the guaranteed
 minimum, which is every device.

 **69 bytes is not reachable and that is not a gap in the test.** A uniform is
 one to four floats, so the total is always a multiple of four; the first size
 that does not fit is 56, and that is the one asserted. The message has to carry
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

	// Thirteen floats, which is the whole 52 the mesh contract leaves. It was
	// seventeen until `uv_transform` became a pinned field and took 16 bytes off
	// the top — the trade is argued at `MATERIAL_UNIFORM_BUDGET`.
	three::MaterialUniform[4] exact = {
		{ "a0", 4, 1 }, { "a1", 4, 1 }, { "a2", 4, 1 }, { "a3", 1, 1 },
	};
	test::@check(
		three::material_uniform_bytes(exact[..]) == three::MATERIAL_UNIFORM_BUDGET,
		"thirteen floats is the whole budget, got %d",
		three::material_uniform_bytes(exact[..])
	);

	String source = three::material_source(
		`float3 shade(Surface s) { return s.albedo * a0.rgb * a1.rgb * a2.rgb * a3; }`,
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

	three::MaterialUniform[5] over = {
		{ "a0", 4, 1 }, { "a1", 4, 1 }, { "a2", 4, 1 }, { "a3", 1, 1 }, { "a4", 1, 1 },
	};
	String? refused_source = three::material_source(PLAN_EXAMPLE, over[..]);
	fault refused = @catch(refused_source);

	test::@check(refused == three::MATERIAL_TOO_MANY_UNIFORMS, "one float more is refused, got %s", refused);
	test::@check(
		three::material_diagnostic().contains("56") && three::material_diagnostic().contains("52"),
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
 A table costs its rows of the budget, and the budget is the same 68 bytes.

 The failure this pins is an implementation that charges a column once rather
 than once per row: four rows of four floats is 64 bytes, and counting it as 16
 would let a material declare four times the push block it has and be refused by
 Vulkan at pipeline creation instead of here, with a message about ranges rather
 than about uniforms.
*>
fn void a_table_costs_a_row_at_a_time() @test
{
	three::MaterialUniform[1] four_rows = { { "palette", 4, 4 } };
	test::@check(
		three::material_uniform_bytes(four_rows[..]) == 64,
		"four rows of four floats is 64 bytes, got %d",
		three::material_uniform_bytes(four_rows[..])
	);

	three::MaterialUniform[1] too_many = { { "palette", 4, 5 } };
	String? refused_source = three::material_source(
		`float3 shade(Surface s) { return palette[s.variant].rgb; }`, too_many[..]
	);
	fault refused = @catch(refused_source);
	test::@check(refused == three::MATERIAL_TOO_MANY_UNIFORMS, "a fifth row does not fit, got %s", refused);
	test::@check(
		three::material_diagnostic().contains("80"),
		"saying what it asked for: %s", three::material_diagnostic()
	);
}
