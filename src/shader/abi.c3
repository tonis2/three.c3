<*
 The shader-side declarations of the wire format, emitted from the C3 structs.

 A pass and its shader are two views of one contract: the struct the CPU writes
 and the struct the shader reads are the same bytes, so they are the same
 declaration. This file is the second view, generated from the first; the
 `$assert`s in `gpu/pipeline.c3` pin the first. Nothing is written by hand twice.

 The mapping, and the reason for each line:

  - a scalar keeps its name;
  - a vector, and a fixed array of two to four scalars, is one `float4`-style
    value - both spellings are the same bytes, and the shader reads either as a
    vector;
  - `Matrix4f` is `float4x4`;
  - a struct keeps its own name, so a pass that writes an `Instance` fills what a
    shader declared as an `Instance`. This is why the C3 wire structs carry real
    pointer types: `Vec3* positions` says what the address is an address *of*,
    where a `ulong` said nothing and the pointee lived only in a shader file;
  - a pointer appends `*`.

 An unmapped C3 type is a compile error here, at the field that caused it,
 rather than a name a shader compiler rejects later with a paragraph between it
 and its cause.

 The shader uses the C3 name, so the ported `mesh.slang` says `DrawRecord` where
 the Slang text said `Draw`. A rename table would be the second place the ABI is
 written down - and the place that would drift.
*>
module three;

import std::math;

<*
 Whether a type is one of the four scalars the wire format is built from.

 The scalar array rule below asks this and nothing else; a struct array is an
 array on the shader side whatever its length.
*>
macro bool is_wire_scalar($Type)
{
	$switch $Type::kind:
		$case BOOL:
		$case FLOAT:
		$case SIGNED_INT:
		$case UNSIGNED_INT:
			return true;
		$default:
			return false;
	$endswitch
}

<*
 Append a comptime count - an array's or a vector's length - as decimal text.

 `$Type::len` is compile-time only, so it is read into a macro variable of its
 own and emitted here; writing it at the use site is what the compiler refuses.
*>
macro void append_shady_count(DString* out, $Type)
{
	var $count = $Type::len;
	out.appendf("%d", (int)$count);
}

<*
 The shady spelling of one C3 type, without the member name after it.
*>
macro void append_shady_type(DString* out, $Type)
{
	$switch $Type::kind:
		$case BOOL:
			out.append_string("bool");
		$case FLOAT:
			out.append_string("float");
		$case SIGNED_INT:
			out.append_string("int");
		$case UNSIGNED_INT:
			out.append_string("uint");
		$case VECTOR:
			out.append_string($Type::inner.name);
			append_shady_count(out, $Type);
		$case POINTER:
			append_shady_type(out, $Type::inner);
			out.append_char('*');
		$case STRUCT:
			$if $Type == Matrix4f:
				out.append_string("float4x4");
			$else
				out.append_string($Type::name);
			$endif
		$default:
			$error "the shader ABI has no spelling for this C3 type";
	$endswitch
}

<*
 One member: `Type name;`, or `Type name[N];` for an array.
*>
macro void append_shady_member(DString* out, $Type, String name)
{
	$if $Type::kind == ARRAY &&& is_wire_scalar($Type::inner) &&& $Type::len >= 2 &&& $Type::len <= 4:
		append_shady_type(out, $Type::inner);
		append_shady_count(out, $Type);
		out.append_char(' ');
		out.append_string(name);
	$else
		$if $Type::kind == ARRAY:
			append_shady_type(out, $Type::inner);
			out.append_char(' ');
			out.append_string(name);
			out.append_char('[');
			append_shady_count(out, $Type);
			out.append_char(']');
		$else
			append_shady_type(out, $Type);
			out.append_char(' ');
			out.append_string(name);
		$endif
	$endif
	out.append_string(";\n");
}

<*
 One struct, member for member and in declaration order.

 Members are emitted where they were declared rather than reordered: the layout
 the shader gets is the layout the C3 compiler gave the struct.
*>
macro void append_shady_struct(DString* out, $Type, String attribute)
{
	out.append_string("struct ");
	out.append_string($Type::name);
	if (attribute.len)
	{
		out.append_char(' ');
		out.append_string(attribute);
	}
	out.append_string("\n{\n");
	$foreach $m : $Type::members:
		out.append_char('\t');
		append_shady_member(out, $m.type, $m.name);
	$endforeach
	out.append_string("}\n");
}

<*
 The structures a shader reaches through an address, in dependency order.

 A struct may only name one declared above it, so this order is the one fields
 require rather than the one they were written in. Emitting all of them costs a
 few hundred bytes of source from which the shader compiler drops whatever a
 pass does not read, and it answers for every pass the question of which
 declarations it has to ask for.

 `@address` is what makes the layout a wire layout rather than a shader's own:
 the struct is reached through a pointer a push block or another struct carried,
 exactly as `DrawRecord` is reached through `MeshPush.draw`.

 The push blocks are not here. There is only ever one in a module - Vulkan
 allows exactly one - so `append_push_block` writes it from the type the shader
 def names.
*>
fn void append_shader_abi(DString* out)
{
	append_shady_struct(out, UvVariant, "");
	append_shady_struct(out, SkinnedVertex, "@address");
	append_shady_struct(out, MorphDelta, "@address");
	append_shady_struct(out, Light, "@address");
	append_shady_struct(out, ShadowGpuView, "@address");
	append_shady_struct(out, Instance, "@address");
	append_shady_struct(out, DrawRecord, "@address");
	append_shady_struct(out, FrameBlock, "@address");
}

<*
 The push block: one wire struct, plus the module-level variable every entry
 point reaches it through.

 It is one macro rather than two calls because a **push block must be the only
 one in the module** - Vulkan allows exactly one per pipeline, and shady says so
 - and a struct that is a push block is nothing until that variable is declared.
*>
macro void append_push_block(DString* out, $Type)
{
	append_shady_struct(out, $Type, "@pushconstant");
	out.append_string($Type::name);
	out.append_string(" push;\n");
}
