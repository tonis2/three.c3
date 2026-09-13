<*
 A script's uniforms, as a struct a body reads, and the one function that hands
 the set to `Surface.uniforms` from whichever storage it got.

 The same file also emits a script's *textures*, because they are the other half
 of the same sentence: the declarations a body reads by name, generated from the
 list a script gave.

 A material declares its uniforms at runtime - name, component count, and how
 many rows a table column has - and a body reads them as fields:

     s.uniforms.tint
     s.uniforms.colors[s.variant]

 **One storage per material, and the spelling does not move with it.** A set that
 fits the push block is a `Uniforms` member of it and `material_uniforms` returns
 `push.uniforms`; a set that spilled is the *same struct* in a device buffer and
 the push block carries a pointer, so the function returns
 `push.material_table[0]`. The struct is marked `@address` only when spilled,
 because that is what lets the push block point at it - a pointer to a plain
 struct is not a device address (shady refuses it at the declaration).

*>
module three;

fn void append_shady_uniforms(DString* out, MaterialUniform[] uniforms, bool spilled = false)
{
	out.append_string("struct Uniforms");
	if (spilled) out.append_string(" @address");
	out.append_string("\n{\n");
	if (uniforms.len == 0)
	{
		// **A material with no uniforms still has the type.** `Surface.uniforms`
		// would otherwise be a field no material without uniforms could have, and
		// `Surface` is the engine's contract rather than a script's - generating it
		// per material would put the body's whole vocabulary behind a generator.
		// One reserved float is the price, in a push block that has the room.
		out.append_string("\tfloat material_unused;\n");
	}
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

	// The seam `shaders/material.shady` fills `Surface.uniforms` through. A
	// load from the block and a load from the buffer are one line here, so no
	// body - and no `#define` - ever chooses a storage.
	out.append_string("\nfn Uniforms material_uniforms()\n{\n");
	if (spilled)
	{
		// The push block's pointer member needs the `[0]` index; shady lowers it
		// to a device-address load, and a spilled set is a row copy rather than a
		// second layout.
		out.append_string("\treturn push.material_table[0];\n");
	}
	else
	{
		out.append_string("\treturn push.uniforms;\n");
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

<*
 A script's declared textures, emitted where the def that splices the body can
 see them.

 Two shapes, because the two kinds of shader store an image differently. A
 material's images are rows of the device-wide table - one `uint` index each,
 carried in `DrawRecord.texture_index` - so a name is a function returning the
 `Map` the body samples, built with the same `map_at` the engine's own maps use:
 there is no second descriptor scheme and no new binding. A post pass's images
 are descriptors of its own set, so a name is the sampler itself and the body
 reads it exactly as it did against the Slang template.

 `first` is the row or binding the first declared texture gets; declaration order
 is the numbering, so nothing outside the list remembers a number.
*>
fn void append_shady_textures(DString* out, MaterialTexture[] textures, uint first, bool material)
{
	foreach (i, texture : textures)
	{
		if (material)
		{
			out.appendf("fn Map %s()\n{\n\treturn map_at(%du);\n}\n", texture.name, first + (uint)i)!!;
		}
		else
		{
			out.appendf("Sampler2D %s @set(0) @binding(%d);\n", texture.name, first + (uint)i)!!;
		}
	}
}
