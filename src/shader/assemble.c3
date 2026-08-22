<*
 The marker walk, and the `#line` arithmetic that puts a diagnostic on the line
 the agent wrote.

 Two templates go through here — `shaders/material.slang` (a surface) and
 `shaders/post.slang` (the whole frame) — and they have exactly one thing in
 common worth sharing: **the line counting**. Everything else about them
 differs, and each front door keeps its own: `material_source` has the mesh
 contract, the uniform table and `MATERIAL_RESERVED`; `post_source` has one push
 field, no instances and `POST_RESERVED`.

 ## Why this file exists rather than a second copy of the walk

 `plan.md`'s Phase D says it in one line: the `#line` arithmetic is too subtle to
 exist twice. Three things about it were established by experiment and each is a
 way to get it wrong (`material_source.c3`'s header has them in full):

 - the filename in a `#line` directive **must** be a double-quoted string, or the
   preprocessor dies with `E15102`;
 - the directive numbers the line that *follows* it, so a body starts at 1;
 - the restore number is the physical line of the text after the directive, which
   only the assembler can know — every marker replacement changes it, so
   `physical` is counted rather than computed.

 A second implementation would be a second chance to get all three right, and the
 half that is wrong is the half nobody notices: a restore directive off by one
 does not fail, it points the next `candidate:` note at the wrong line.

 ## The trap this file is made of

 `plan.md` §6: **a `\n` inside a C3 backtick raw string is a backslash and an
 `n`.** There is no newline in any literal here — every line ending is an
 explicit `append_char('\n')`, which is also what makes `physical` countable.
*>
module three;

import std::io;

// The marker lines, matched after trimming so a template can indent them to read
// naturally. A template that does not contain one simply never reaches its
// branch — `post.slang` has no `//@rows`, because a post pass has no instances
// for a table to be indexed by.
const String MARKER_UNIFORMS @private = "//@uniforms";
const String MARKER_ROWS @private = "//@rows";
const String MARKER_DEFINES @private = "//@defines";
const String MARKER_SHADE @private = "//@shade";

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

 The check is `[A-Za-z_][A-Za-z0-9_]*` and nothing else, but the reason is not
 only Slang's: nothing interpolated into a `#line` directive may contain a quote
 or a backslash, and a uniform name reaches one through the `#undef` block.
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
 Copy a refusal sentence into a fixed buffer and say how long it ended up.

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
 Append `text` line by line, normalising the ending, and say how many lines that
 was.

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
 Read a template, replace its marker lines, and hand back the whole module.

 The result is self-contained: it declares its own `PushData`, its own bindings
 and both entry points, so it goes to `compile_slang` as a string with nothing
 else beside it. Nothing is compiled here and no GPU is involved. **Nothing is
 validated here either** — each front door has already refused what it cannot
 generate, because the messages are the half a caller acts on and they are not
 shared.

 @param template_name : `A file name, looked up by find_shader — shaders/ first, then build/shaders/.`
 @param fragment : `The agent's body, appended verbatim between the two #line directives.`
 @param uniforms : `Names and widths, in the order they should be laid out. Reached from the body as bare names.`
 @param body_name : `What the agent's own lines are called in a diagnostic — "material", "post".`
 @param preamble_name : `What everything three.c3 generated is called — "three.material", "three.post".`
 @return `The whole module, allocated from allocator and owned by the caller.`
 @return? SHADER_NOT_FOUND : `The template is not on the search path — the same condition, and the same fix, as a missing mesh.slang.`
*>
fn String? assemble_shader(
	String template_name,
	String fragment,
	MaterialUniform[] uniforms,
	String body_name,
	String preamble_name,
	alloc::Allocator allocator
) @private
{
	@pool()
	{
		String path = find_shader(template_name, tmem)!;
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
					uint rows = uniform_rows_of(uniform);
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
