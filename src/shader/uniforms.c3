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

import std::collections::list;

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
 carried in `DrawRecord.texture_index` - so they are a `Textures` struct of
 `Map`s, built with the same `map_at` the engine's own maps use, which
 `Surface.textures` and `Vertex.textures` carry: a body samples
 `s.textures.noise`, and no name it declared is a global that could collide with
 one of the template's. A material with none still has the type, as `Uniforms`
 does, because `Surface` is the engine's contract rather than a script's.

 A post pass's images are descriptors of its own set, so a name is the sampler
 itself and the body reads it by that name.

 `first` is the row or binding the first declared texture gets; declaration order
 is the numbering, so nothing outside the list remembers a number.
*>
fn void append_shady_textures(DString* out, MaterialTexture[] textures, uint first, bool material)
{
	if (!material)
	{
		foreach (i, texture : textures)
		{
			out.appendf("Sampler2D %s @set(0) @binding(%d);\n", texture.name, first + (uint)i)!!;
		}
		return;
	}

	out.append_string("struct Textures\n{\n");
	if (textures.len == 0) out.append_string("\tuint textures_unused;\n");
	foreach (texture : textures) out.appendf("\tMap %s;\n", texture.name)!!;
	out.append_string("}\n\nfn Textures material_textures()\n{\n\tTextures t;\n");
	if (textures.len == 0) out.append_string("\tt.textures_unused = 0u;\n");
	foreach (i, texture : textures)
	{
		out.appendf("\tt.%s = map_at(%du);\n", texture.name, first + (uint)i)!!;
	}
	out.append_string("\treturn t;\n}\n");
}

<*
 How many bytes one uniform takes in the `Uniforms` struct: its floats, times
 its rows. Every width is a multiple of four under scalar layout, so a field
 starts where the one before it ended.
*>
fn uint uniform_size(MaterialUniform uniform) => uniform.components * 4 * uniform_rows_of(uniform);

<*
 The fields of the `Uniforms` struct `append_shady_uniforms` emits, at their
 offsets, computed from the same list rather than read back off the text.

 `base` is where the struct starts: the end of the walked block for a set that
 fits the push block, zero for one that spilled, whose fields are in the table
 buffer and marked `indirect`. Every field is tagged `uniform`, so a lookup by a
 script's name cannot land on a contract field that happens to share it.

 An empty set is the reserved `material_unused` float, which takes its four
 bytes and produces no field.

 @return `The struct's size in bytes.`
*>
fn uint append_uniform_fields(List{ShaderField}* out, MaterialUniform[] uniforms, uint base, bool spilled)
{
	if (uniforms.len == 0) return 4;
	uint offset = 0;
	foreach (uniform : uniforms)
	{
		uint size = uniform_size(uniform);
		out.push({
			.name = uniform.name.copy(mem),
			.offset = base + offset,
			.size = size,
			.indirect = spilled,
			.uniform = true,
		});
		offset += size;
	}
	return offset;
}
