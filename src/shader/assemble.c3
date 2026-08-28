<*
 The marker walk, and the `#line` arithmetic that puts a diagnostic on the line
 the agent wrote.

 Two templates go through here — `shaders/material.slang` (a surface) and
 `shaders/post.slang` (the whole frame) — and they share exactly one thing worth
 sharing: the line counting. Each front door keeps its own rules;
 `material_source` has the mesh contract, the uniform table and
 `MATERIAL_RESERVED`, while `post_source` has one push field, no instances and
 `POST_RESERVED`.

 ## The `#line` arithmetic

 Three things about it were established by experiment, and each is a way to get
 it wrong:

 - the filename in a `#line` directive must be a double-quoted string, or the
   preprocessor dies with `E15102`;
 - the directive numbers the line that *follows* it, so a body starts at 1;
 - the restore number is the physical line of the text after the directive, which
   only the assembler can know — every marker replacement changes it, so
   `physical` is counted rather than computed.

 A second implementation would be a second chance to get all three right, and the
 half that is wrong is the half nobody notices: a restore directive off by one
 does not fail, it points the next `candidate:` note at the wrong line.

 A `\n` inside a C3 backtick raw string is a backslash and an `n`, so there is no
 newline in any literal here — every line ending is an explicit
 `append_char('\n')`, which is also what makes `physical` countable.
*>
module three;

import std::io;

// The marker lines, matched after trimming so a template can indent them to read
// naturally. A template that does not contain one never reaches its branch —
// `post.slang` has no `//@rows`, because a post pass has no instances for a table
// to be indexed by.
const String MARKER_UNIFORMS @private = "//@uniforms";
const String MARKER_ROWS @private = "//@rows";
const String MARKER_DEFINES @private = "//@defines";
// The line that turns `material.slang` into its unlit, uv-space variant. Replaced
// by nothing at all when nothing asked for a bake, so an ordinary material's
// generated source is what it was before the exporter could bake — the same rule
// `//@table` follows. `render/bake.c3` is the only caller that asks.
const String MARKER_BAKE @private = "//@bake";
const String MARKER_TEXTURES @private = "//@textures";
const String MARKER_VDEFINES @private = "//@vdefines";
const String MARKER_VERTEX @private = "//@vertex";
const String MARKER_SHADE @private = "//@shade";
// The spilled uniform table's struct, at global scope above the push block. Only
// `material.slang` has it, and only a material whose uniforms overflow the block
// gets anything written into it — see `material_spills`.
const String MARKER_TABLE @private = "//@table";

<*
 What a material with no vertex body gets instead of one.

 An empty function rather than an absent one, so `vertexMain` calls `displace`
 unconditionally and there is no second spelling of the vertex stage to keep in
 step. Every compiler folds it away, and the SPIR-V is the same either way —
 which `a_material_without_a_vertex_body_is_the_shader_it_was` holds down.
*>
const String IDENTITY_DISPLACE @private = "void displace(inout Vertex v) { }";

<*
 The binding index the first agent-declared sampler gets, per kind of shader.

 Two numbers that happen to be equal, and writing them as one constant is the
 mistake this comment exists to prevent. They were 1 and 1 while both templates
 reserved one binding; 1 and 2 once a post pass reserved `prev` and `scene`; 2
 and 4 once a material reserved `base_color_map` and `shadow_map`; 3 and 4 now
 that `environment_map` is beside those two. A shared constant would mean every material sampler being silently renumbered by whichever
 *other* template moved — reflection agreeing with itself the whole way, and the
 only symptom being textures arriving in the wrong slots of shaders nobody had
 touched.

 Nothing outside this file chooses a binding index. The declaration order the
 caller passed is the binding order, generated here from whichever base the front
 door passed, read back by reflection and resolved by *name* everywhere above —
 which makes inserting a texture at the front of the list a non-event. A script
 that could write `[vk::binding(3, 0)]` itself could collide with the reserved
 names.
*>
const uint MATERIAL_BINDING_FIRST = 3;

// Where a post pass's own samplers begin: after `prev` at 0, `scene` at 1, the
// frame's depth buffer at 2 and `tap_image` at 3 — see `MATERIAL_BINDING_FIRST`
// and `shaders/post.slang`. Moving this constant is the whole of a renumbering:
// every sampler above it is generated from declaration order and resolved by name.
const uint POST_BINDING_FIRST = 4;

// The third source, and a number rather than a name for `SHADOW_BINDING`'s
// reason: only the chain knows which image this is, and resolving it by name
// would let a body claim it by declaring a texture called `tap_image`.
// `POST_RESERVED` is what stops that.
const uint POST_TAP_BINDING = 3;

<*
 Where the shadow map is bound, in every shader that shades a surface.

 A number rather than a name, unlike everything a material declares, and for the
 reason `base_color_map` is reached at 0 by hand: only the pass knows what this
 image *is*, and resolving it by name would let a material claim it by declaring
 a texture called `shadow_map`. `pipeline_declares_binding` asks the reflected
 layout whether it is there, because Slang may drop a sampler a linked program
 never reads — both templates do read it, which is why the answer is yes today
 and why it is still asked.
*>
const uint SHADOW_BINDING = 1;

<*
 Where the environment map is bound, in every shader that shades a surface.

 `SHADOW_BINDING`'s argument, one binding along: only the pass knows this image
 is the scene's sky, and a material that declared a texture called
 `environment_map` would otherwise claim it.

 Like the shadow map it is always bound and is white when there is no sky —
 `FrameBlock.environment.x` is what says whether to read it, so shading with an
 environment and shading without one are one pipeline.
*>
const uint ENVIRONMENT_BINDING = 2;

// A declared row count of zero means "not a table", which is the same thing as
// one row. Written once here because the budget arithmetic, the clamp and the
// generated declaration must all agree about it.
fn uint uniform_rows_of(MaterialUniform uniform) @private => uniform.rows < 1 ? 1 : uniform.rows;

fn String slang_type_of(uint components) @private
{
	switch (components)
	{
		case 2: return "float2";
		case 3: return "float3";
		case 4: return "float4";
		default: return "float";
	}
}

<*
 Is this a name a `#define` can safely carry?

 The check is `[A-Za-z_][A-Za-z0-9_]*`, and the reason is not only Slang's:
 nothing interpolated into a `#line` directive may contain a quote or a
 backslash, and a uniform name reaches one through the `#undef` block.
*>
fn bool is_identifier(String name) @private
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
 Everything a list of sampler names can be refused for, as a sentence.

 Shared by both front doors rather than written twice, unlike the uniform checks
 beside it: the uniform rules genuinely differ between a material and a post pass
 (one has tables and a 52-byte budget, the other has neither) while these rules
 are the same rules with a different word in front of them.

 The name must not collide with a *uniform* either, which is the one check that
 could not be inferred from either list alone: a uniform is a `#define` live
 across the body, so a sampler sharing its name would be rewritten to
 `push.<name>` at every use — a diagnostic about a push field the agent never
 mentioned.

 @param prefix : `"material" or "post" — what the sentence calls the thing being built.`
 @param reserved : `The template's own vocabulary, which a sampler may not take either.`
 @param limit : `How many samplers this kind of shader may declare.`
 @return `The empty string when the names are usable, or the sentence to refuse them with. Allocated from tmem.`
*>
fn String texture_problem(
	String prefix,
	MaterialTexture[] textures,
	MaterialUniform[] uniforms,
	String[] reserved,
	uint limit
) @private
{
	// Counted first, so a script that passed eight names is told the number rather
	// than being told about the first one that also happened to be misspelled.
	if (textures.len > limit)
	{
		return string::tformat(
			"%s: %d textures were declared and a %s may have %d; a shader wanting more images than that wants an atlas, which is one texture",
			prefix,
			textures.len,
			prefix,
			limit
		);
	}

	foreach (i, texture : textures)
	{
		if (!is_identifier(texture.name))
		{
			return string::tformat(
				"%s: texture name '%s' is not an identifier; a name must match [A-Za-z_][A-Za-z0-9_]*",
				prefix,
				texture.name
			);
		}

		foreach (word : reserved)
		{
			if (texture.name != word) continue;
			return string::tformat(
				"%s: texture name '%s' is reserved; the shader three.c3 generates around your body already uses it",
				prefix,
				texture.name
			);
		}

		foreach (j, earlier : textures)
		{
			if (j >= i) break;
			if (earlier.name != texture.name) continue;
			return string::tformat("%s: texture '%s' is declared twice", prefix, texture.name);
		}

		foreach (uniform : uniforms)
		{
			if (uniform.name != texture.name) continue;
			return string::tformat(
				"%s: '%s' is both a uniform and a texture; a uniform is a macro live across your body, so it would rewrite the sampler's every use",
				prefix,
				texture.name
			);
		}
	}

	return "";
}

<*
 Copies a refusal sentence into a fixed buffer and says how long it ended up.

 A fixed buffer rather than an allocation because the caller reads this on the
 failure path, where there is no owned value to free and no allocator in scope to
 free it with. Truncation rather than a fault: a message that is too long is
 still a better answer than no message.

 @return `How many bytes of buffer the message took.`
*>
fn usz shader_note_into(char[] buffer, String message) @private
{
	usz n = message.len < buffer.len ? message.len : buffer.len;
	buffer[:n] = message[:n];
	return n;
}

<*
 Appends `text` line by line, normalising the ending, and says how many lines
 that was.

 The count is the point. `#line` restores numbering by absolute line, so the
 assembler has to know exactly how tall the body it just wrote is — and a body
 that arrived without a trailing newline, or with a `\r` on every line because it
 came from a script authored on Windows, must not change that answer.
*>
fn uint append_lines(DString* out, String text) @private
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
 Reads a template, replaces its marker lines, and hands back the whole module.

 The result is self-contained: it declares its own `PushData`, its own bindings
 and both entry points, so it goes to `compile_slang` as a string with nothing
 else beside it. Nothing is compiled here and no GPU is involved, and nothing is
 validated here either — each front door has already refused what it cannot
 generate, because the messages are the half a caller acts on and they are not
 shared.

 @param template_name : `A file name, looked up by shader_source — the search path first, then the copy embedded in the binary.`
 @param fragment : `The agent's body, appended verbatim between the two #line directives.`
 @param uniforms : `Names and widths, in the order they should be laid out. Reached from the body as bare names.`
 @param textures : `Samplers the body wants, in declaration order. Their binding indices are generated from that order — see MATERIAL_BINDING_FIRST.`
 @param binding_first : `What the first of them is numbered — MATERIAL_BINDING_FIRST or POST_BINDING_FIRST, whichever this template reserves up to.`
 @param vertex : `The agent's vertex body, or empty for the identity. Only a template with a //@vertex marker has anywhere to put one.`
 @param body_name : `What the agent's own lines are called in a diagnostic — "material", "post".`
 @param vertex_name : `The same, for the vertex body — "vertex". Unused when there is no vertex body.`
 @param preamble_name : `What everything three.c3 generated is called — "three.material", "three.post".`
 @param bake : `Define THREE_BAKE, which makes material.slang unlit and rasterised in uv space. Only a material has the marker; nothing else may ask.`
 @return `The whole module, allocated from allocator and owned by the caller.`
 @return? SHADER_NOT_FOUND : `The template is not on the search path — the same condition, and the same fix, as a missing mesh.slang.`
*>
fn String? assemble_shader(
	String template_name,
	String fragment,
	MaterialUniform[] uniforms,
	MaterialTexture[] textures,
	String vertex,
	String body_name,
	String vertex_name,
	String preamble_name,
	uint binding_first,
	alloc::Allocator allocator,
	// Only ever true for a material. `post.slang` has no `//@table` marker and no
	// instances for a table to be indexed by, so its caller never asks.
	bool spill = false,
	// The same again for `//@bake`: a post pass shades the whole frame and has no
	// surface to bake.
	bool bake = false
) @private
{
	@pool()
	{
		String template = shader_source(template_name, tmem)!;

		DString out;
		out.tinit(template.len + 1024);

		// Physical lines written so far, counted rather than derived. Every marker
		// replaces one line with a different number of lines, so nothing upstream
		// knows what line the text after the body lands on.
		uint physical = 0;

		usz start = 0;
		while (start < template.len)
		{
			usz end = start;
			while (end < template.len && template[end] != '\n') end++;
			String line = template[start:end - start];
			start = end + 1;

			String marker = line.trim();
			if (marker == MARKER_BAKE)
			{
				if (!bake) continue;
				out.append_string("#define THREE_BAKE 1");
				out.append_char('\n');
				physical++;
				continue;
			}
			if (marker == MARKER_TABLE)
			{
				// Nothing at all for a material that fits the push block, so the
				// generated source for one is byte for byte what it was before the
				// table could spill.
				if (!spill) continue;
				out.appendf("struct %s", MATERIAL_TABLE_TYPE)!!;
				out.append_char('\n');
				out.append_string("{");
				out.append_char('\n');
				physical += 2;
				foreach (uniform : uniforms)
				{
					uint rows = uniform_rows_of(uniform);
					if (rows == 1) continue;
					out.appendf("    %s %s[%d];", slang_type_of(uniform.components), uniform.name, rows)!!;
					out.append_char('\n');
					physical++;
				}
				out.append_string("};");
				out.append_char('\n');
				physical++;
				continue;
			}
			if (marker == MARKER_UNIFORMS)
			{
				// The pointer first, so it lands at `MATERIAL_PUSH_START` — a
				// multiple of eight — and scalar layout has no alignment padding to
				// insert in front of it. After a `float` it would.
				if (spill)
				{
					out.appendf("    %s* %s;", MATERIAL_TABLE_TYPE, MATERIAL_TABLE_FIELD)!!;
					out.append_char('\n');
					physical++;
				}
				foreach (uniform : uniforms)
				{
					uint rows = uniform_rows_of(uniform);
					// An array column is in the table struct above rather than here
					// when this material spilled, and here when it did not.
					if (rows > 1)
					{
						if (spill) continue;
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
					// The body cannot tell which shape it got, which is the point of
					// doing this with a macro: `tint[s.variant]` reads the push block
					// or the table buffer depending on a decision the agent never
					// made and never has to know about.
					if (spill && uniform_rows_of(uniform) > 1)
					{
						out.appendf(
							"#define %s (push.%s[0].%s)",
							uniform.name, MATERIAL_TABLE_FIELD, uniform.name
						)!!;
					}
					else
					{
						out.appendf("#define %s (push.%s)", uniform.name, uniform.name)!!;
					}
					out.append_char('\n');
					physical++;
				}
				continue;
			}
			if (marker == MARKER_VDEFINES)
			{
				// Nothing at all when there is no vertex body, which is the half
				// that matters. A `#define tint (push.tint)` left live here would
				// reach `vertexMain`'s own lines rather than the agent's, and the
				// reason the fragment block is `#undef`ed straight after the body is
				// that the template's code must not be rewritten by a name a script
				// chose.
				if (vertex.len > 0)
				{
					foreach (uniform : uniforms)
					{
						// The same substitution the fragment block gets, for the same
						// reason: a vertex body indexes a spilled column exactly as a
						// fragment body does, and neither knows where it lives.
						if (spill && uniform_rows_of(uniform) > 1)
						{
							out.appendf(
								"#define %s (push.%s[0].%s)",
								uniform.name, MATERIAL_TABLE_FIELD, uniform.name
							)!!;
						}
						else
						{
							out.appendf("#define %s (push.%s)", uniform.name, uniform.name)!!;
						}
						out.append_char('\n');
						physical++;
					}
				}
				continue;
			}
			if (marker == MARKER_VERTEX)
			{
				if (vertex.len == 0)
				{
					out.append_string(IDENTITY_DISPLACE);
					out.append_char('\n');
					physical++;
					continue;
				}

				// `#line 1 "vertex"`, so a diagnostic in a vertex body reads
				// `vertex:3:12` and one in a fragment body reads `material:3:12`.
				// Two names rather than one, because an agent that wrote both needs
				// to know which the compiler is talking about before it can read the
				// line number at all.
				out.appendf(`#line 1 "%s"`, vertex_name)!!;
				out.append_char('\n');
				physical++;

				physical += append_lines(&out, vertex);

				out.appendf(`#line %d "%s"`, physical + 2, preamble_name)!!;
				out.append_char('\n');
				physical++;

				foreach (uniform : uniforms)
				{
					out.appendf("#undef %s", uniform.name)!!;
					out.append_char('\n');
					physical++;
				}
				continue;
			}
			if (marker == MARKER_TEXTURES)
			{
				// A declaration, not a `#define`. A uniform is a push field reached
				// through a macro that is undefined again after the body; a sampler
				// is a global of the module, so the agent's name *is* the
				// declaration's name and there is nothing to undo. That also means a
				// sampler is visible to the template's own lines as well as to the
				// body — harmless here, and why `MATERIAL_RESERVED` refuses the same
				// names for both.
				foreach (i, texture : textures)
				{
					out.appendf(
						"[vk::binding(%d, 0)] Sampler2D %s;",
						binding_first + (uint)i,
						texture.name
					)!!;
					out.append_char('\n');
					physical++;
				}
				continue;
			}
			if (marker == MARKER_SHADE)
			{
				// The quotes are not optional: an unquoted filename is E15102, a
				// preprocessor error that kills the compile. Nothing variable goes
				// inside them — both names are constants at every call site — so
				// there is no quote or backslash to escape.
				out.appendf(`#line 1 "%s"`, body_name)!!;
				out.append_char('\n');
				physical++;

				physical += append_lines(&out, fragment);

				// The directive itself lands on line `physical + 1` and numbers the
				// line after it, so it says `physical + 2` — which is the first
				// `#undef`, or `fragmentMain`'s blank line when there are no
				// uniforms.
				out.appendf(`#line %d "%s"`, physical + 2, preamble_name)!!;
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
