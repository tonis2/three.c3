<*
 A script's uniforms, as a struct a body reads.

 A material declares its uniforms at runtime - name, component count, and how
 many rows a table column has - and a body reads them as fields:

     s.uniforms.tint
     s.uniforms.colors[s.variant]

 **Typed, which is the whole point of not `#define`ing them.** The assembler this
 replaces emitted `#define tint (push.tint)` (or, for a table column,
 `#define tint (push.material_table[0].tint)`), so a body's typo became a compile
 error about a name nobody declared, pointing wherever the macro happened to
 expand, and a name a script chose could rewrite the template's own lines until
 the `#undef` put it back. A struct field has none of those properties: a typo is
 an unknown field at the body's own line, and nothing outside the body can see
 the name at all.

 **One storage per material.** A material whose uniforms fit the push block reads
 them from it; one that spills has its whole uniform set - scalars and table
 columns alike - in the device buffer, and the push block carries only the
 pointer. That is the decision this emitter exists to make possible without a
 macro: two storages are two expressions, so hiding the choice needs a
 preprocessor, and one storage is a memcpy of a few dozen bytes beside a table
 the engine already writes per bucket per frame.

 The struct is emitted as a source region like any other piece of a module, so
 the body's line numbers and the module's `#line` map see it as one more file.
*>
module three;

fn void append_shady_uniforms(DString* out, MaterialUniform[] uniforms)
{
	if (uniforms.len == 0)
	{
		// Nothing to read, and nothing that could read it: a body has no uniforms
		// to name. Emitting an empty struct would declare a type no field could
		// ever resolve against, and a `Surface` field of that type would be a
		// field no body could use.
		return;
	}

	out.append_string("struct Uniforms\n{\n");
	foreach (uniform : uniforms)
	{
		out.append_char('\t');
		out.append_string(shady_float_type(uniform.components));
		out.append_char(' ');
		out.append_string(uniform.name);
		if (uniform.rows > 1)
		{
			// A table column is one field per row, not one field: the row index is
			// the body's, and `s.uniforms.colors[s.variant]` is what the macro used
			// to spell `colors`.
			out.appendf("[%d]", uniform.rows)!!;
		}
		out.append_string(";\n");
	}
	out.append_string("}\n");
}

<*
 The shady spelling of a uniform's components.

 One to four floats and nothing else: a script's uniforms are vec1..vec4 by
 construction - `scene/material.c3` accepts those widths and refuses the rest - so
 there is no case here for a type a body could not index.
*>
fn String shady_float_type(uint components) @private
{
	switch (components)
	{
		case 1: return "float";
		case 2: return "float2";
		case 3: return "float3";
		case 4: return "float4";
	}
	return "float";
}
