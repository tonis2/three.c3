<*
 A material, as a string: the agent's fragment body and everything Slang needs
 around it.

 `plan.md` §4's tier 2 is one sentence — "three.c3 supplies the vertex stage, the
 `Surface` struct, the descriptor layout and the uniform block; the agent writes
 the shading body" — and this file is the half of it that is not the compiler.
 Nothing here compiles, creates a pipeline or touches the GPU. It reads
 `shaders/material.slang`, replaces three marker lines, and hands back a
 self-contained module.

 ## Why the line numbers are the interesting part

 The agent wrote four lines and gets back a four-hundred-line module. A
 diagnostic that says `material.slang:312` names a file the agent has never seen,
 at a line it did not write, and the loop that `plan.md` §4 calls "the whole
 contract" stalls on the agent trying to find line 312.

 So the body is bracketed by `#line` directives:

	#line 1 "material"
	float3 shade(Surface s)
	{
	    return s.albedo * notAFunction(s.uv);
	}
	#line 141 "three.material"

 and Slang then reports `material:3:24`, echoing the agent's own text under the
 caret. The restore directive is not decoration either: on an arity or overload
 failure Slang emits a `note[E40011]: candidate:` record pointing back into the
 preamble, and `three.material:141` at least says plainly that the line is not
 the agent's. Suppressing that note would be worse — it is usually the half that
 says "expected 2".

 Three things about `#line` were established by experiment rather than assumed,
 and each of them is a way to get this wrong:

 - The filename **must** be a double-quoted string literal. `#line 1 material`
   is `E15102`, a hard preprocessor error that kills the compile. Nothing
   interpolated into a directive here can contain a quote or a backslash, which
   is one of the things `MATERIAL_RESERVED`'s identifier check is really for.
 - The directive numbers the line that *follows* it, so the body starts at `1`
   and not `0`. `0` is accepted and faithfully reported as `:0:`.
 - The restore number is the physical line of the text after the directive,
   which nothing but the assembler can know. `physical` below is counted rather
   than computed, because every marker replacement changes it.

 ## The trap this file is made of

 `plan.md` §6: **a `\n` inside a C3 backtick raw string is a backslash and an
 `n`.** Every newline in a generated shader is an instance of it, and the result
 looks right in the editor and is one enormous line at runtime. There is no
 newline in any literal here — the assembler appends `'\n'` explicitly, once per
 line, which is also what makes `physical` countable.
*>
module three;

import std::io;

faultdef MATERIAL_NAME_INVALID, MATERIAL_TOO_MANY_UNIFORMS, MATERIAL_BODY_EMPTY;

<*
 One material uniform, as the JS side described it.

 `rows` is what makes a uniform a **column of a table** rather than a single
 value: one row is `float3 tint;` and three rows are `float3 tint[3];`, indexed
 in the body by `s.variant` — the per-instance row selector in `scene/scene.c3`.
 That is the whole of "one material, many appearances, one draw call": the
 pipeline and the push block are bucket state and cannot vary per copy, so the
 variation has to be a *lookup* the copies do rather than a value they carry.

 Every column of one material must have the same number of rows. It is a table,
 not a bag of arrays — and it is also what makes `s.variant`'s clamp exact, since
 there is then one row count to clamp against instead of one per column.
*>
struct MaterialUniform
{
	String name;      // borrowed from the caller
	uint components;  // 1..4 floats
	uint rows;        // 1 for a plain uniform, N for a column of an N-row table
}

<*
 Bytes of push block available to material uniforms, after the mesh contract.

 128 is the push size every Vulkan implementation must offer and `PUSH_BUDGET`
 treats it as a budget rather than a limit to grow into; the eight fields
 `MESH_PUSH_FIELDS` pins take 76 of it. What is left is what a material may
 spend, and it is spelled here as a number rather than derived from
 `MeshPush::size` on purpose: `MeshPush` is 80 bytes and only 76 of them reflect,
 the difference being C3 tail padding, so deriving it would quietly hand out four
 bytes that the shader's layout does not contain.

 **This was 68 and is now 52**, because `uv_transform` was added to the mesh
 contract. That is four rows of four floats down to three, or five rows of three
 down to four, and it was not free — the trade was made deliberately. Material
 uniforms are a `ShaderMaterial` feature and nothing else; the uv transform is
 needed most by a ground plane wearing a `MeshLambertMaterial`, which has no
 uniform block to put it in. Spending a shared 16 bytes so that every material
 can tile is worth more than a fourth row for the ones that compile a body.

 The way past this for either of them is the same and is written down in
 `plan.md` §2: a device buffer behind a BDA in the push block, at which point the
 budget stops being 128 bytes and starts being memory.
*>
const uint MATERIAL_UNIFORM_BUDGET = 52;

// The template, looked up the same way `mesh.slang` is — `shaders/` first, then
// `build/shaders/`, both relative to the working directory.
const String MATERIAL_TEMPLATE = "material.slang";

<*
 What the agent's own lines are called in a diagnostic.

 Short and lower case because it is read by whoever wrote the body, not by
 whoever wrote the compiler: `material:3:24` is a coordinate in the string the
 agent typed.
*>
const String MATERIAL_BODY_NAME = "material";

<*
 What everything three.c3 generated is called in a diagnostic.

 Deliberately self-describing rather than short. Slang's `candidate:` notes point
 into the preamble whatever the body did, and an agent that sees
 `three.material:141` can tell at a glance that the line is not one of its own —
 which is the only thing it needs to conclude from it.
*>
const String MATERIAL_PREAMBLE_NAME = "three.material";

// The marker lines in `shaders/material.slang`. Matched after trimming, so the
// template can indent them to read naturally.
const String MARKER_UNIFORMS @local = "//@uniforms";
const String MARKER_ROWS @local = "//@rows";
const String MARKER_DEFINES @local = "//@defines";
const String MARKER_SHADE @local = "//@shade";

<*
 Names a material uniform may not take.

 Two groups, and they are refused for different reasons. The first is everything
 `shaders/material.slang` declares or names in a line the `#define`s can reach: a
 uniform called `shade` or `push` produces a substitution that breaks the
 template, and the resulting diagnostic points at generated code the agent cannot
 see. The second is Slang and HLSL's own vocabulary, where `#define float ...`
 is legal, silent, and turns the rest of the module into something no error
 message will explain.

 The list is not complete and cannot be — Slang's standard library is thousands
 of names, and reserving all of them would refuse `time` and `tint` along the
 way. It covers what the template touches and the keywords worth a sentence, and
 anything past it fails as an ordinary Slang diagnostic at `material:<line>`,
 which is where the agent can act on it. That is the trade: a short list of
 collisions turned into a good message, and a long tail turned into a normal one.
*>
const String[*] MATERIAL_RESERVED @local = {
	// What the template declares.
	"push", "s", "shade", "Surface", "VertexOutput", "PushData", "FrameBlock",
	"Instance", "vertexMain", "fragmentMain", "base_color_map", "lambert",
	"srgb_to_linear",
	"FLAG_HAS_NORMALS", "FLAG_HAS_UVS", "MATERIAL_ROWS",
	// The eight push fields the mesh contract pins.
	"frame", "instances", "positions", "normals", "uvs", "base_color", "flags",
	"uv_transform",
	// Types.
	"float", "float2", "float3", "float4", "float2x2", "float3x3", "float4x4",
	"int", "int2", "int3", "int4", "uint", "uint2", "uint3", "uint4",
	"bool", "bool2", "bool3", "bool4", "half", "double", "void",
	"Sampler2D", "Texture2D", "SamplerState",
	// Keywords.
	"return", "if", "else", "for", "while", "do", "switch", "case", "default",
	"break", "continue", "struct", "const", "static", "in", "out", "inout",
	"discard", "true", "false", "typedef", "namespace", "uniform", "cbuffer",
	"groupshared",
};

// Long enough for any message below with the offending name spelled in full and
// short enough to be a global. A name longer than this is refused before it can
// be quoted anyway.
const usz MATERIAL_DIAGNOSTIC_MAX @local = 512;

// The message the last refusal carried. See `material_diagnostic`.
char[MATERIAL_DIAGNOSTIC_MAX] material_message @local;
usz material_message_len @local;

<*
 What the last `material_source` refused, in words.

 **A value rather than a line on stderr**, which is the same decision
 `compile_slang` made about Slang's diagnostics and for the same reason:
 `plan.md` §4 wants the text inside the thrown JS exception, and a script cannot
 read a file descriptor. A fault on its own says which rule was broken and
 nothing about which uniform broke it, which is not something an agent can fix.

 A fixed buffer rather than an allocation because the caller reads this on the
 failure path, where there is no owned value to free and no allocator in scope to
 free it with.

 @return `A view valid until the next call to material_source. Empty if the last call succeeded.`
*>
fn String material_diagnostic() => (String)material_message[:material_message_len];

fn void material_note(String message) @local
{
	usz n = message.len < MATERIAL_DIAGNOSTIC_MAX ? message.len : MATERIAL_DIAGNOSTIC_MAX;
	material_message[:n] = message[:n];
	material_message_len = n;
}

<*
 What the uniforms cost in the push block.

 `sum(components) * 4`, and no alignment arithmetic: the compile passes
 `-force-glsl-scalar-layout`, under which a float3 is twelve bytes at four-byte
 alignment and every field here is a multiple of four. **The offsets are still
 not computed anywhere** — reflection reads them back off the module that will
 run, which is the only version of them that cannot be wrong.
*>
fn uint material_uniform_bytes(MaterialUniform[] uniforms)
{
	uint total = 0;
	foreach (uniform : uniforms) total += uniform.components * material_rows_of(uniform) * 4;
	return total;
}

fn uint material_rows_of(MaterialUniform uniform) @local => uniform.rows < 1 ? 1 : uniform.rows;

<*
 How many rows this material's table has, or 1 when it declared none.

 Generated into the module as `MATERIAL_ROWS` and used to clamp `s.variant`, so
 every `column[s.variant]` in a body is in bounds by construction. A material
 with no arrays gets 1 and therefore a variant of 0 for every copy, which is the
 truth: there is no table for a variant to select from.
*>
fn uint material_rows(MaterialUniform[] uniforms)
{
	uint rows = 1;
	foreach (uniform : uniforms)
	{
		uint declared = material_rows_of(uniform);
		if (declared > rows) rows = declared;
	}
	return rows;
}

fn String slang_type_of(uint components) @local
{
	switch (components)
	{
		case 2: return "float2";
		case 3: return "float3";
		case 4: return "float4";
		default: return "float";
	}
}

fn bool is_identifier(String name) @local
{
	if (name.len == 0) return false;
	foreach (i, c : name)
	{
		bool alpha = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_';
		bool digit = c >= '0' && c <= '9';
		if (!alpha && !(digit && i > 0)) return false;
	}
	return true;
}

<*
 Everything that can be refused before a line of Slang is written.

 Order matters to the message rather than to the outcome: the body is checked
 first because a material with no body has nothing for the uniforms to be used
 by, and the budget last because "these seventeen floats do not fit" is only
 useful once each of them is known to be a real uniform.

 @return? MATERIAL_BODY_EMPTY : `The fragment body is empty or only whitespace.`
 @return? MATERIAL_NAME_INVALID : `A uniform name is not an identifier, is one the template already uses, is a Slang keyword, is repeated, or is not 1 to 4 floats wide.`
 @return? MATERIAL_TOO_MANY_UNIFORMS : `The uniforms want more of the push block than the mesh contract leaves.`
*>
fn void? validate_material(String fragment, MaterialUniform[] uniforms) @local
{
	@pool()
	{
		if (fragment.trim().len == 0)
		{
			material_note("material: the fragment body is empty; it must define `float3 shade(Surface s)`");
			return MATERIAL_BODY_EMPTY~;
		}

		foreach (i, uniform : uniforms)
		{
			if (!is_identifier(uniform.name))
			{
				material_note(string::tformat(
					"material: uniform name '%s' is not an identifier; a name must match [A-Za-z_][A-Za-z0-9_]*",
					uniform.name
				));
				return MATERIAL_NAME_INVALID~;
			}

			foreach (reserved : MATERIAL_RESERVED)
			{
				if (uniform.name != reserved) continue;
				material_note(string::tformat(
					"material: uniform name '%s' is reserved; the shader three.c3 generates around your body already uses it",
					uniform.name
				));
				return MATERIAL_NAME_INVALID~;
			}

			foreach (j, earlier : uniforms)
			{
				if (j >= i) break;
				if (earlier.name != uniform.name) continue;
				material_note(string::tformat(
					"material: uniform '%s' is declared twice",
					uniform.name
				));
				return MATERIAL_NAME_INVALID~;
			}

			if (uniform.components < 1 || uniform.components > 4)
			{
				material_note(string::tformat(
					"material: uniform '%s' is %d floats wide; a uniform is 1 to 4",
					uniform.name,
					uniform.components
				));
				return MATERIAL_NAME_INVALID~;
			}

			// One table, not a bag of arrays — see `MaterialUniform`. Checked
			// against the first column that has more than one row rather than
			// against the maximum, so the message can name both of them.
			uint rows = material_rows_of(uniform);
			foreach (other : uniforms)
			{
				uint other_rows = material_rows_of(other);
				if (other_rows == 1 || rows == 1 || other_rows == rows) continue;
				material_note(string::tformat(
					"material: '%s' has %d rows and '%s' has %d; every array in one material is a column of the same table and they must agree",
					uniform.name,
					rows,
					other.name,
					other_rows
				));
				return MATERIAL_NAME_INVALID~;
			}
		}

		uint wanted = material_uniform_bytes(uniforms);
		if (wanted > MATERIAL_UNIFORM_BUDGET)
		{
			material_note(string::tformat(
				"material: the uniforms want %d bytes of push block and %d are free; the mesh contract takes the other %d of the 128 every device offers",
				wanted,
				MATERIAL_UNIFORM_BUDGET,
				PUSH_BUDGET - MATERIAL_UNIFORM_BUDGET
			));
			return MATERIAL_TOO_MANY_UNIFORMS~;
		}

		material_note("");
	};
}

<*
 Append `text` line by line, normalising the ending, and say how many lines that
 was.

 The count is the point. `#line` restores numbering by absolute line, so the
 assembler has to know exactly how tall the body it just wrote is — and a body
 that arrived without a trailing newline, or with a `\r` on every line because it
 came from a script authored on Windows, must not change that answer.
*>
fn uint append_lines(DString* out, String text) @local
{
	uint lines = 0;
	usz start = 0;
	while (start < text.len)
	{
		usz end = start;
		while (end < text.len && text[end] != '\n') end++;
		usz stop = end;
		if (stop > start && text[stop - 1] == '\r') stop--;
		out.append_string(text[start:stop - start]);
		out.append_char('\n');
		lines++;
		start = end + 1;
	}
	return lines;
}

<*
 Assemble the full Slang module for a material.

 The result is self-contained: it declares its own `PushData`, its own binding
 and both entry points, so it goes to `compile_slang` as a string with nothing
 else beside it, the same way `mesh.slang` does. Nothing is compiled here and no
 GPU is involved.

 @param fragment : `The agent's body. Must define float3 shade(Surface s); everything else is theirs.`
 @param uniforms : `Names and widths, in the order they should be laid out. Reached from the body as bare names.`
 @return `The whole module, allocated from allocator and owned by the caller.`
 @return? MATERIAL_BODY_EMPTY : `The body is empty. material_diagnostic() has the sentence.`
 @return? MATERIAL_NAME_INVALID : `A uniform name or width is one this cannot generate. material_diagnostic() names it.`
 @return? MATERIAL_TOO_MANY_UNIFORMS : `The uniforms do not fit in what the mesh contract leaves of the push block.`
 @return? SHADER_NOT_FOUND : `shaders/material.slang is not on the search path — the same condition, and the same fix, as a missing mesh.slang.`
*>
fn String? material_source(String fragment, MaterialUniform[] uniforms, alloc::Allocator allocator = mem)
{
	validate_material(fragment, uniforms)!;

	@pool()
	{
		String path = find_shader(MATERIAL_TEMPLATE, tmem)!;
		String template = load_source(path, tmem)!;

		DString out;
		out.tinit(template.len + 1024);

		// Physical lines written so far, counted rather than derived. Every
		// marker replaces one line with a different number of lines, so nothing
		// upstream of here knows what line the text after the body lands on.
		uint physical = 0;

		usz start = 0;
		while (start < template.len)
		{
			usz end = start;
			while (end < template.len && template[end] != '\n') end++;
			String line = template[start:end - start];
			start = end + 1;

			String marker = line.trim();
			if (marker == MARKER_UNIFORMS)
			{
				foreach (uniform : uniforms)
				{
					uint rows = material_rows_of(uniform);
					if (rows > 1)
					{
						out.appendf("    %s %s[%d];", slang_type_of(uniform.components), uniform.name, rows)!!;
					}
					else
					{
						out.appendf("    %s %s;", slang_type_of(uniform.components), uniform.name)!!;
					}
					out.append_char('\n');
					physical++;
				}
				continue;
			}
			if (marker == MARKER_ROWS)
			{
				// A `static const` rather than a `#define`, so it is a typed value
				// the clamp in `fragmentMain` can use and not a token the agent's
				// body could accidentally shadow.
				out.appendf("static const uint MATERIAL_ROWS = %du;", material_rows(uniforms))!!;
				out.append_char('\n');
				physical++;
				continue;
			}
			if (marker == MARKER_DEFINES)
			{
				foreach (uniform : uniforms)
				{
					out.appendf("#define %s (push.%s)", uniform.name, uniform.name)!!;
					out.append_char('\n');
					physical++;
				}
				continue;
			}
			if (marker == MARKER_SHADE)
			{
				// The quotes are not optional: an unquoted filename is E15102, a
				// preprocessor error that kills the compile. Nothing variable goes
				// inside them — both names are constants in this file — so there is
				// no quote or backslash to escape.
				out.appendf(`#line 1 "%s"`, MATERIAL_BODY_NAME)!!;
				out.append_char('\n');
				physical++;

				physical += append_lines(&out, fragment);

				// The directive itself lands on line `physical + 1` and numbers the
				// line after it, so it says `physical + 2` — which is the first
				// `#undef`, or `fragmentMain`'s blank line when there are no
				// uniforms.
				out.appendf(`#line %d "%s"`, physical + 2, MATERIAL_PREAMBLE_NAME)!!;
				out.append_char('\n');
				physical++;

				// Undefined immediately, so the substitution reaches the agent's
				// lines and stops. Without this a uniform named `a` rewrites
				// `push.base_color.a` in `fragmentMain`, and the diagnostic for it
				// points at a line in the preamble.
				foreach (uniform : uniforms)
				{
					out.appendf("#undef %s", uniform.name)!!;
					out.append_char('\n');
					physical++;
				}
				continue;
			}

			out.append_string(line);
			out.append_char('\n');
			physical++;
		}

		return out.copy_str(allocator);
	};
}
