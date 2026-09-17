<*
 The engine's compile.

 `compile_shady` takes a `ShaderDef` - a name, the module's text sources, and the
 `Uniforms` region a script's declarations emitted - and produces the
 `ShaderModule` the pipeline builder reads: the SPIR-V, the entry points it
 really contains, and the `ShaderLayout`.

 ## Where each part of the layout comes from

 push block      walked from the C3 struct the pass fills, plus the trailing
                 uniforms member the generator appends; `MATERIAL_PUSH_START`
                 is where the walk ends, not a number copied beside it
 bindings        OpDecorate / OpVariable / OpType* of the module about to run
 entries         OpEntryPoint of the same module
 stages          the union of those entries, computed by `reflect.c3`'s own
                 `stage_union`

 Nothing is written down a second time. The push block is the one exception,
 because it is the one thing that is not fully inside the def: its first half is
 a C3 struct and its second is a struct a script declared, so one is walked and
 the other is read from the region `append_shady_uniforms` emitted.

 ## The compile flags a generated module needs

 `scalar_layout: true`, because every struct in a generated module is a C3 wire
 struct and std430 would stride `SkinnedVertex` by 32 rather than 24. The
 buffer-device-address capability is not passed here: shady emits
 `PhysicalStorageBuffer` for a module that reaches anything through an
 `@address` pointer, which is exactly the spilled-material module. The device
 feature is enabled once in `gpu/device.c3` (the queried Vulkan 1.2 features are
 handed to `deviceCreateInfo`), and the pipeline layout has nothing to say
 about it - a `VkPipelineLayout` has no BDA flag.
*>
module three;

import std::collections::list;
import vk;
import shady;

faultdef SHADY_UNIFORMS_UNREADABLE;

<*
 The kind of one SPIR-V type, as far as descriptor reflection needs to tell
 them apart. Zero is `NONE`, so a zeroed id table says "not a type".
*>
enum ShadyType : char
{
	NONE,
	SAMPLED_IMAGE_TYPE, // `Sampler2D`: one combined image sampler
	IMAGE_TYPE,        // `texture2d`: the sampled operand says sampled or storage
	SAMPLER_TYPE,
	ARRAY_TYPE,        // `[N]`: `op_a` is the element, `op_b` the length constant
	RUNTIME_ARRAY_TYPE,
	STRUCT_TYPE,
	POINTER_TYPE,      // `op_a` is the storage class, `op_b` the pointee
}

struct ShadyVariable
{
	uint id;
	uint pointer; // its OpTypePointer id
	uint storage; // StorageClass
}

// The options `shady::compile` is called with. In the cache key beside the
// source, so a change here cannot be shadowed by a module an earlier build
// wrote.
const String[*] SHADY_ARGUMENTS = { "scalar-layout" };

<*
 Compiles a `ShaderDef` through shady.

 `$Type` is the push block: a type parameter rather than a field of `ShaderDef`
 because a struct cannot hold a type, and the block is walked rather than
 described.

 @param def : `The module: name, sources, and the emitted uniforms region.`
 @param $Type : `The C3 push struct the pass fills - MeshPush, PostPush, ...`
 @return `The module, with ok false and the diagnostic attached when shady
 refused the source. Owned and freed like any other ShaderModule.`
*>
macro ShaderModule compile_shady(ShaderDef def, $Type)
{
	return compile_shady_inner(def, $Type, null, { });
}

<*
 Compile one plain source string into a module, with no wire structs.

 The render passes have `compile_shady`, which walks a C3 push struct into the
 module so the block cannot drift from the struct the pass fills. A compute
 shader has no such struct: its source is the whole program - a script's
 string, or a `.shady` beside the engine's own - and its push block is a
 `@pushconstant` struct in that source, like every other declaration it makes.

 So this is the same compile without the walked half. The flags are the same
 ones every module in this project gets, `scalar_layout` included: a shader
 whose structs pack differently from the host that fills them is a wrong number
 rather than an error. Storage buffers are the exception and say so in the
 layout rules - see `Codegen.block_layout` in shady.

 @param name : `What diagnostics call the source - a script's kernel name, a file's.`
 @return `The module. A refused source answers with ok false and the compiler's message in the diagnostic, which callers show rather than throw: a bad shader is a thing a person fixes.`
*>
fn ShaderModule compile_compute_shader(String name, String source)
{
	ShaderModule mod = { };
	mod.entries.init(mem, 4);
	mod.layout.bindings.init(mem, 8);
	// A compute shader's push block is a struct in its own source, so nothing
	// walks one - and a zeroed list is what `ShaderModule.free` expects.
	mod.layout.push_fields.init(mem, 1);

	shady::Diagnostic diagnostic;
	shady::DiagnosticList warnings;
	warnings.init(mem, 4);

	char[]? compiled = shady::compile(source, &diagnostic, scalar_layout: true, warnings: &warnings);
	if (catch compiled)
	{
		mod.ok = false;
		mod.diagnostic = diagnostic.render(mem);
		diagnostic.free();
		copy_compute_warnings(&mod, &warnings);
		foreach (warning : warnings) warning.free();
		warnings.free();
		return mod;
	}
	diagnostic.free();

	if (compiled.len < 4 || *(uint*)compiled.ptr != SPIRV_MAGIC)
	{
		// Unreachable for this emitter, but a module that is not SPIR-V is not
		// something a pipeline can load.
		mod.ok = false;
		mod.diagnostic = "three: shady returned something that is not a SPIR-V module".copy(mem);
		alloc::free(mem, compiled);
		copy_compute_warnings(&mod, &warnings);
		foreach (warning : warnings) warning.free();
		warnings.free();
		return mod;
	}
	mod.spirv = compiled;

	reflect_shady_module(mod.spirv, &mod.entries, &mod.layout.bindings, &mod.layout.set_count);
	mod.layout.stages = stage_union(mod.entries.array_view());
	// Not walked from a C3 struct, so it is read out of the module's own
	// `@pushconstant` block instead - see `reflect_push_block_size`.
	mod.layout.push_size = reflect_push_block_size(mod.spirv);

	mod.ok = true;
	copy_compute_warnings(&mod, &warnings);
	foreach (warning : warnings) warning.free();
	warnings.free();
	return mod;
}

fn void copy_compute_warnings(ShaderModule* mod, shady::DiagnosticList* warnings) @local
{
	@pool()
	{
		DString notes;
		notes.tinit(256);
		foreach (warning : *warnings)
		{
			if (notes.str_view().len > 0) notes.append_char('\n');
			notes.append_string(warning.to_string(tmem));
		}
		if (notes.str_view().len > 0) mod.diagnostic = notes.copy_str(mem);
	};
}

<*
 The byte size of a module's `@pushconstant` block, read back out of the
 SPIR-V.

 Nothing walks a compute shader's push block the way `compile_shady` walks a
 pass's - the block is a struct in the shader's own source - so the size is
 what the module says it is: the last member's offset plus that member's own
 size, with strides folded in for the arrays and matrices on the way.

 Only what the walk needs is gathered, and only from `OpDecorate` /
 `OpMemberDecorate`. A module with no push block answers zero, which is what
 `Compute.dispatch` checks before pushing anything.

 @return `Bytes, or zero when the module declares no push block.`
*>
fn uint reflect_push_block_size(char[] spirv) @local
{
	usz count = spirv.len / 4;
	if (count < 5) return 0;
	uint* words = (uint*)spirv.ptr;
	uint bound = words[3];

	// What the size walk needs: the type table, plus the three decorations that
	// are part of a size rather than a binding.
	ushort[] type_op   = alloc::new_array(mem, ushort, bound);
	uint[]   op_a      = alloc::new_array(mem, uint, bound);
	uint[]   op_b      = alloc::new_array(mem, uint, bound);
	uint[]   op_c      = alloc::new_array(mem, uint, bound);
	uint[]   array_stride  = alloc::new_array(mem, uint, bound);
	uint[]   matrix_stride = alloc::new_array(mem, uint, bound);
	uint[]   block_id  = alloc::new_array(mem, uint, 1);

	defer
	{
		alloc::free(mem, type_op);
		alloc::free(mem, op_a);
		alloc::free(mem, op_b);
		alloc::free(mem, op_c);
		alloc::free(mem, array_stride);
		alloc::free(mem, matrix_stride);
		alloc::free(mem, block_id);
	};

	block_id[0] = 0;

	// Two passes, because the block's pointer and the struct it points at are
	// written wherever the emitter put them - the struct is declared after the
	// variable that uses it, so one pass would look up a type table that is not
	// filled in yet.
	usz i = 5;
	while (i < count)
	{
		uint word  = words[i];
		usz length = (usz)(word >> 16);
		if (length == 0 || i + length > count) break;

		switch ((shady::Opcode)(word & 0xffff))
		{
			case shady::Opcode.TYPE_VECTOR:
				if (length >= 4 && words[i + 1] < bound)
				{
					type_op[words[i + 1]] = (ushort)shady::Opcode.TYPE_VECTOR;
					op_a[words[i + 1]]    = words[i + 2]; // component
					op_b[words[i + 1]]    = words[i + 3]; // count
				}
			case shady::Opcode.TYPE_MATRIX:
				if (length >= 4 && words[i + 1] < bound)
				{
					type_op[words[i + 1]] = (ushort)shady::Opcode.TYPE_MATRIX;
					op_a[words[i + 1]]    = words[i + 2]; // column type
					op_b[words[i + 1]]    = words[i + 3]; // columns
				}
			case shady::Opcode.TYPE_ARRAY:
				if (length >= 4 && words[i + 1] < bound)
				{
					type_op[words[i + 1]] = (ushort)shady::Opcode.TYPE_ARRAY;
					op_a[words[i + 1]]    = words[i + 2]; // element
					op_b[words[i + 1]]    = words[i + 3]; // length constant id
				}
			case shady::Opcode.TYPE_STRUCT:
				if (length >= 2 && words[i + 1] < bound)
				{
					type_op[words[i + 1]] = (ushort)shady::Opcode.TYPE_STRUCT;
					// The member type ids, packed into the type's own slot in
					// `op_a` - a struct is the one type with a list, and one
					// id is enough to keep the others reachable.
					op_a[words[i + 1]] = (uint)(i + 2);
					op_b[words[i + 1]] = (uint)(length - 2);
				}
			case shady::Opcode.TYPE_POINTER:
				if (length >= 4 && words[i + 1] < bound)
				{
					type_op[words[i + 1]] = (ushort)shady::Opcode.TYPE_POINTER;
					op_a[words[i + 1]]    = words[i + 2]; // storage class
					op_b[words[i + 1]]    = words[i + 3]; // pointee
				}
			case shady::Opcode.CONSTANT:
				if (length >= 4 && words[i + 2] < bound) op_c[words[i + 2]] = words[i + 3];
			case shady::Opcode.DECORATE:
				if (length >= 4 && words[i + 1] < bound && words[i + 2] == (uint)shady::Decoration.ARRAY_STRIDE)
				{
					array_stride[words[i + 1]] = words[i + 3];
				}
			case shady::Opcode.MEMBER_DECORATE:
				if (length >= 5 && words[i + 1] < bound && words[i + 3] == (uint)shady::Decoration.MATRIX_STRIDE)
				{
					matrix_stride[words[i + 1]] = words[i + 4];
				}
			default:
		}
		i += length;
	}

	// The block's pointer, not the pointer to a member of it: a `@pushconstant`
	// struct is reached both ways, and the one whose pointee is a struct is the
	// block.
	i = 5;
	while (i < count)
	{
		uint word  = words[i];
		usz length = (usz)(word >> 16);
		if (length == 0 || i + length > count) break;

		if ((shady::Opcode)(word & 0xffff) == shady::Opcode.TYPE_POINTER
			&& length >= 4 && words[i + 1] < bound
			&& words[i + 2] == (uint)shady::StorageClass.PUSH_CONSTANT
			&& words[i + 3] < bound
			&& type_op[words[i + 3]] == (ushort)shady::Opcode.TYPE_STRUCT)
		{
			block_id[0] = words[i + 3];
		}
		i += length;
	}

	if (block_id[0] == 0 || block_id[0] >= bound) return 0;
	if (type_op[block_id[0]] != (ushort)shady::Opcode.TYPE_STRUCT) return 0;

	// The last member's offset plus its own size: the end of a block, which is
	// what a push range has to cover.
	uint member_count = op_b[block_id[0]];
	uint member_at    = op_a[block_id[0]];
	if (member_count == 0) return 0;

	uint last_offset = 0;
	bool offset_found = false;
	usz j = 5;
	while (j < count)
	{
		uint word   = words[j];
		usz length  = (usz)(word >> 16);
		if (length == 0 || j + length > count) break;

		if ((shady::Opcode)(word & 0xffff) == shady::Opcode.MEMBER_DECORATE
			&& length >= 5 && words[j + 1] == block_id[0]
			&& words[j + 3] == (uint)shady::Decoration.OFFSET
			&& words[j + 2] + 1 == member_count)
		{
			last_offset  = words[j + 4];
			offset_found = true;
		}
		j += length;
	}
	if (!offset_found) return 0;

	uint last_type = words[member_at + member_count - 1];
	return last_offset + type_size(last_type, type_op, op_a, op_b, op_c, array_stride, matrix_stride, bound, 0);
}

<*
 One type's size, with this module's strides.

 Scalars are four bytes - the only widths this emitter makes - and a struct is
 the largest end of any of its members. That is enough for the push blocks a
 compute shader writes: they hold counts, strides, scales and offsets, and the
 one member that could be an array or a matrix is what the strides above are
 for.
*>
fn uint type_size(
	uint id, ushort[] type_op, uint[] op_a, uint[] op_b, uint[] op_c,
	uint[] array_stride, uint[] matrix_stride, uint bound, uint depth) @local
{
	if (id >= bound || depth > 8) return 0;

	switch ((shady::Opcode)type_op[id])
	{
		case shady::Opcode.TYPE_VECTOR:
			return type_size(op_a[id], type_op, op_a, op_b, op_c, array_stride, matrix_stride, bound, depth + 1) * op_b[id];
		case shady::Opcode.TYPE_MATRIX:
		{
			uint column = matrix_stride[id] > 0
				? matrix_stride[id]
				: type_size(op_a[id], type_op, op_a, op_b, op_c, array_stride, matrix_stride, bound, depth + 1);
			return column * op_b[id];
		}
		case shady::Opcode.TYPE_ARRAY:
		{
			uint length = op_b[id] < bound ? op_c[op_b[id]] : 0;
			uint stride = array_stride[id] > 0
				? array_stride[id]
				: type_size(op_a[id], type_op, op_a, op_b, op_c, array_stride, matrix_stride, bound, depth + 1);
			return length * stride;
		}
		case shady::Opcode.TYPE_STRUCT:
		{
			// The end of its last member, which is what `assign_offsets` rounds
			// up to the struct's alignment - so this is an upper bound and a
			// fine one for a push range that only has to be big enough.
			uint member_count = op_b[id];
			uint member_at    = op_a[id];
			if (member_count == 0) return 0;
			return type_size(op_a[member_at + member_count - 1], type_op, op_a, op_b, op_c,
				array_stride, matrix_stride, bound, depth + 1);
		}
		default:
			return 4;
	}
}

<*
 `compile_shady`, with yesterday's answer if there is one.

 Same module, same layout, same diagnostics, same ownership as the uncached
 call. A cache that cannot be read, cannot be written, or does not agree byte for
 byte with what was asked for is invisible here.

 @param [out] compiled : `Set true when shady actually ran, false when the
 module came off disk. PipelineCache counts this, so a compile keeps meaning the
 compiler ran.`
 @param specs : `The spec-constant values the pipelines over this module are
 specialized with. Part of the cache key, so no two value sets share an entry.`
*>
macro ShaderModule compile_shady_cached(ShaderDef def, $Type, bool* compiled, ShaderSpec[] specs)
{
	return compile_shady_inner(def, $Type, compiled, specs);
}

macro ShaderModule compile_shady_inner(ShaderDef def, $Type, bool* compiled, ShaderSpec[] specs)
{
	DString source;
	source.tinit(64 * 1024);
	append_shader_def(&source, def, $Type);

	// The walked half: one field per C3 member, at the offset C3 gave it. The
	// names are compile-time literals here and copied onto `mem` below, where
	// the module owns them.
	List{ShaderField} walked;
	walked.init(mem, 8);

	var $align = 4;
	$foreach $m : $Type::members:
		var $offset = $m.offset;
		var $size = $m.size;
		walked.push({ .name = $m.name, .offset = (uint)$offset, .size = (uint)$size });
		$if wire_align($m.type) > $align:
			$align = wire_align($m.type);
		$endif
	$endforeach

	ShaderModule mod = compile_shady_cached_source(
		source.str_view(), def, walked.array_view(), (uint)$align, compiled, specs
	);
	walked.free();
	source.free();
	return mod;
}

<*
 The compile itself, with the walked half already in hand and the cache in
 front.
*>
fn ShaderModule compile_shady_cached_source(
	String source,
	ShaderDef def,
	ShaderField[] walked,
	uint walked_align,
	bool* compiled,
	ShaderSpec[] specs) @local
{
	if (compiled != null) *compiled = false;

	if (shader_cache_dir().len == 0)
	{
		if (compiled != null) *compiled = true;
		return compile_shady_source(source, def, walked, walked_align);
	}

	@pool()
	{
		ShaderCacheKey key = {
			// The compiler's name only; a moved revision is a cache clear.
			.compiler = "shady",
			.arguments = shader_cache_argument_blob(SHADY_ARGUMENTS[..]),
			.name = def.name,
			.specs = specs,
			.source = source,
		};

		ShaderModule loaded;
		if (shader_cache_try_load(key, &loaded)) return loaded;

		ShaderModule mod = compile_shady_source(source, def, walked, walked_align);
		if (compiled != null) *compiled = true;
		if (mod.ok) shader_cache_save(key, &mod);
		return mod;
	};
}

<*
 The alignment of a wire member, in the layout a generated module uses.

 Only two answers matter: a device address is 8, and everything else in a wire
 struct - scalars, vectors, matrices, their arrays - packs to 4 under C3's
 scalar layout. An array of addresses is the one recursive case, so it is asked
 rather than assumed.
*>
macro uint wire_align($Type)
{
	$switch $Type::kind:
		$case POINTER:
			return 8;
		$case ARRAY:
			$if is_pointer_type($Type::inner):
				return 8;
			$endif
			return 4;
		$default:
			return 4;
	$endswitch
}

macro bool is_pointer_type($Type)
{
	$switch $Type::kind:
		$case POINTER:
			return true;
		$default:
			return false;
	$endswitch
}

<*
 The compile itself, with the walked half already in hand.
*>
fn ShaderModule compile_shady_source(
	String source,
	ShaderDef def,
	ShaderField[] walked,
	uint walked_align) @local
{
	ShaderModule mod = { };
	mod.entries.init(mem, 4);
	mod.layout.bindings.init(mem, 8);
	// `push_fields` is not initialized here: it is the moved-in list below, and
	// a zeroed list is what every failure path leaves behind.

	List{ShaderField} fields;
	fields.init(mem, walked.len + 8);

	uint walked_end = 0;
	foreach (field : walked)
	{
		fields.push({ .name = field.name.copy(mem), .offset = field.offset, .size = field.size });
		if (field.offset + field.size > walked_end) walked_end = field.offset + field.size;
	}

	uint align = walked_align;
	uint push_size = align_up(walked_end, align);

	// What the generator appended above the walk. A spilled set is a pointer to
	// the table buffer; a set that fits is the struct itself, and its fields
	// land at the block offsets the host writes them through, by name.
	if (def.uniforms.len > 0)
	{
		if (def.uniforms_spilled)
		{
			uint at = align_up(walked_end, 8);
			if (align < 8) align = 8;
			fields.push({ .name = MATERIAL_TABLE_FIELD.copy(mem), .offset = at, .size = ulong::size });

			uint? table = shady_uniform_fields(&fields, def.uniforms, 0, true);
			if (catch table)
			{
				free_shader_fields(&fields);
				mod.ok = false;
				mod.diagnostic = "three: the emitted Uniforms region is not the shape append_shady_uniforms writes".copy(mem);
				return mod;
			}
			push_size = align_up(at + ulong::size, align);
		}
		else
		{
			uint at = align_up(walked_end, 4);
			uint? table = shady_uniform_fields(&fields, def.uniforms, at, false);
			if (catch table)
			{
				free_shader_fields(&fields);
				mod.ok = false;
				mod.diagnostic = "three: the emitted Uniforms region is not the shape append_shady_uniforms writes".copy(mem);
				return mod;
			}
			push_size = align_up(at + table, align);
		}
	}

	shady::Diagnostic diagnostic;
	shady::DiagnosticList warnings;
	warnings.init(mem, 4);

	char[]? compiled = shady::compile(source, &diagnostic, scalar_layout: true, warnings: &warnings);
	if (catch compiled)
	{
		foreach (warning : warnings) warning.free();
		warnings.free();

		mod.ok = false;
		mod.diagnostic = diagnostic.render(mem);
		diagnostic.free();
		free_shader_fields(&fields);
		return mod;
	}
	diagnostic.free();

	// A successful compile can still warn; `ShaderModule` carries that too.
	@pool()
	{
		DString notes;
		notes.tinit(256);
		foreach (warning : warnings)
		{
			if (notes.str_view().len > 0) notes.append_char('\n');
			notes.append_string(warning.to_string(tmem));
		}
		if (notes.str_view().len > 0) mod.diagnostic = notes.copy_str(mem);
	};
	foreach (warning : warnings) warning.free();
	warnings.free();

	if (compiled.len < 4 || compiled.len % 4 != 0 || *(uint*)compiled.ptr != SPIRV_MAGIC)
	{
		// Unreachable for this emitter, but a module that is not SPIR-V is
		// not something a pipeline can load.
		mod.ok = false;
		mod.diagnostic = "three: shady returned something that is not a SPIR-V module".copy(mem);
		alloc::free(mem, compiled);
		free_shader_fields(&fields);
		return mod;
	}
	mod.spirv = compiled;

	reflect_shady_module(mod.spirv, &mod.entries, &mod.layout.bindings, &mod.layout.set_count);
	mod.layout.stages = stage_union(mod.entries.array_view());
	mod.layout.push_size = push_size;
	mod.layout.push_fields = fields; // moved: the module owns the fields from here
	mod.ok = true;
	return mod;
}

fn void free_shader_fields(List{ShaderField}* fields) @local
{
	foreach (&field : *fields) if (field.name.ptr != null) field.name.free(mem);
	fields.free();
}

fn uint align_up(uint value, uint alignment) @local => (value + alignment - 1) / alignment * alignment;

<*
 The fields of the emitted `Uniforms` struct, at their offsets.

 The region is `append_shady_uniforms`' own output, so the grammar is the one
 that emitter writes and nothing else: a struct header, one `float`/`float2`/
 `float3`/`float4` member per uniform - `[rows]` when it is a column of the
 material table - then the closing brace and the fill.

 `base` is where the struct starts: the end of the walked block for a set that
 fits the push block, zero for one that spilled, whose fields live in the table
 buffer. `material_unused` is the reserved padding that keeps a material with no
 uniforms the same shape; it is not a name anything may resolve, so it takes
 space and produces no field.
*>
fn uint? shady_uniform_fields(
	List{ShaderField}* out,
	String region,
	uint base,
	bool spilled) @local
{
	usz at = 0;
	sz? found = region.index_of("struct Uniforms");
	if (catch found) return SHADY_UNIFORMS_UNREADABLE~;
	at = (usz)found;
	if (region.contains("struct Uniforms @address") != spilled) return SHADY_UNIFORMS_UNREADABLE~;

	usz brace = at;
	while (brace < region.len && region[brace] != '{') brace++;
	if (brace >= region.len) return SHADY_UNIFORMS_UNREADABLE~;

	uint offset = 0;
	usz line = brace + 1;
	while (line < region.len)
	{
		usz end = line;
		while (end < region.len && region[end] != '\n') end++;
		String row = region[line:end - line].trim();
		line = end + 1;

		if (row.len == 0) continue;
		if (row[0] == '}') break;
		if (!row.ends_with(";")) return SHADY_UNIFORMS_UNREADABLE~;
		row = row[:row.len - 1].trim();

		usz space = 0;
		sz? sep = row.index_of_char(' ');
		if (catch sep) return SHADY_UNIFORMS_UNREADABLE~;
		space = (usz)sep;
		String type_name = row[:space];
		String declaration = row[space + 1:row.len - space - 1].trim();

		if (!type_name.starts_with("float")) return SHADY_UNIFORMS_UNREADABLE~;
		uint components = type_name.len == 5 ? 1 : parse_decimal(type_name[5:type_name.len - 5]);
		if (components < 1 || components > 4) return SHADY_UNIFORMS_UNREADABLE~;

		uint rows = 1;
		usz bracket = 0;
		String name;
		sz? open = declaration.index_of_char('[');
		if (try open)
		{
			bracket = (usz)open;
			if (!declaration.ends_with("]")) return SHADY_UNIFORMS_UNREADABLE~;
			rows = parse_decimal(declaration[bracket + 1:declaration.len - bracket - 2]);
			name = declaration[:bracket].trim();
		}
		else
		{
			name = declaration;
		}
		if (name.len == 0 || rows == 0) return SHADY_UNIFORMS_UNREADABLE~;

		uint size = components * 4 * rows;
		if (name != "material_unused")
		{
			out.push({
				.name = name.copy(mem),
				.offset = base + offset,
				.size = size,
				.indirect = spilled,
			});
		}
		offset = align_up(offset + size, 4);
	}

	return offset;
}

fn uint parse_decimal(String digits) @local
{
	uint value = 0;
	foreach (c : digits)
	{
		if (c < '0' || c > '9') return 0;
		value = value * 10 + (uint)(c - '0');
	}
	return value;
}

<*
 What the module says about itself: its entry points and its descriptors.

 Read out of the SPIR-V that is about to run, so a binding in the layout cannot
 describe a different module than the one loaded. Only what the two consumers
 need is recovered: the entries' names and stages, and the descriptor
 variables' names, sets, bindings, counts and kinds.

 Push-constant variables carry the storage class that says they are not
 descriptors, so the push block walk is not disturbed by anything here.
*>
fn void reflect_shady_module(
	char[] spirv,
	List{ShaderEntry}* entries,
	List{ShaderBinding}* bindings,
	uint* set_count) @local
{
	usz count = spirv.len / 4;
	if (count < 5) return;
	uint* words = (uint*)spirv.ptr;
	uint bound = words[3];

	String[]     names           = alloc::new_array(mem, String, bound);
	bool[]       named           = alloc::new_array(mem, bool, bound);
	ShadyType[]  kinds           = alloc::new_array(mem, ShadyType, bound);
	uint[]       op_a            = alloc::new_array(mem, uint, bound);
	uint[]       op_b            = alloc::new_array(mem, uint, bound);
	bool[]       blocks          = alloc::new_array(mem, bool, bound);
	bool[]       has_set         = alloc::new_array(mem, bool, bound);
	uint[]       sets            = alloc::new_array(mem, uint, bound);
	bool[]       has_binding     = alloc::new_array(mem, bool, bound);
	uint[]       binding_numbers = alloc::new_array(mem, uint, bound);
	uint[]       constants       = alloc::new_array(mem, uint, bound);

	defer
	{
		alloc::free(mem, names);
		alloc::free(mem, named);
		alloc::free(mem, kinds);
		alloc::free(mem, op_a);
		alloc::free(mem, op_b);
		alloc::free(mem, blocks);
		alloc::free(mem, has_set);
		alloc::free(mem, sets);
		alloc::free(mem, has_binding);
		alloc::free(mem, binding_numbers);
		alloc::free(mem, constants);
	};

	List{ShadyVariable} variables;
	variables.init(mem, 8);
	defer variables.free();

	usz i = 5;
	while (i < count)
	{
		uint word = words[i];
		usz length = (usz)(word >> 16);
		if (length == 0 || i + length > count) break;

		switch ((shady::Opcode)(word & 0xffff))
		{
			case shady::Opcode.NAME:
				if (length >= 3)
				{
					uint id = words[i + 1];
					if (id < bound)
					{
						names[id] = spirv_string(words, i + 2, i + length);
						named[id] = true;
					}
				}
			case shady::Opcode.DECORATE:
				if (length >= 3)
				{
					uint id = words[i + 1];
					if (id >= bound) break;
					switch ((shady::Decoration)words[i + 2])
					{
						case shady::Decoration.BLOCK: // `OpDecorate %s Block` carries no operand
							blocks[id] = true;
						case shady::Decoration.DESCRIPTOR_SET:
							if (length < 4) break;
							sets[id] = words[i + 3];
							has_set[id] = true;
						case shady::Decoration.BINDING:
							if (length < 4) break;
							binding_numbers[id] = words[i + 3];
							has_binding[id] = true;
						default:
					}
				}
			case shady::Opcode.TYPE_IMAGE:
				if (length >= 8)
				{
					uint id = words[i + 1];
					if (id < bound)
					{
						kinds[id] = ShadyType.IMAGE_TYPE;
						op_b[id] = words[i + 7]; // the `sampled` operand
					}
				}
			case shady::Opcode.TYPE_SAMPLED_IMAGE:
				if (length >= 3 && words[i + 1] < bound) kinds[words[i + 1]] = ShadyType.SAMPLED_IMAGE_TYPE;
			case shady::Opcode.TYPE_SAMPLER:
				if (length >= 2 && words[i + 1] < bound) kinds[words[i + 1]] = ShadyType.SAMPLER_TYPE;
			case shady::Opcode.TYPE_ARRAY:
				if (length >= 4 && words[i + 1] < bound)
				{
					kinds[words[i + 1]] = ShadyType.ARRAY_TYPE;
					op_a[words[i + 1]] = words[i + 2];
					op_b[words[i + 1]] = words[i + 3];
				}
			case shady::Opcode.TYPE_RUNTIME_ARRAY:
				if (length >= 3 && words[i + 1] < bound)
				{
					kinds[words[i + 1]] = ShadyType.RUNTIME_ARRAY_TYPE;
					op_a[words[i + 1]] = words[i + 2];
				}
			case shady::Opcode.TYPE_STRUCT:
				if (length >= 2 && words[i + 1] < bound) kinds[words[i + 1]] = ShadyType.STRUCT_TYPE;
			case shady::Opcode.TYPE_POINTER:
				if (length >= 4 && words[i + 1] < bound)
				{
					kinds[words[i + 1]] = ShadyType.POINTER_TYPE;
					op_a[words[i + 1]] = words[i + 2]; // storage class
					op_b[words[i + 1]] = words[i + 3]; // pointee
				}
			case shady::Opcode.CONSTANT:
				if (length >= 4 && words[i + 2] < bound) constants[words[i + 2]] = words[i + 3];
			case shady::Opcode.VARIABLE:
				if (length >= 4) variables.push({ .id = words[i + 2], .pointer = words[i + 1], .storage = words[i + 3] });
			case shady::Opcode.ENTRY_POINT:
				if (length >= 4)
				{
					String name = spirv_string(words, i + 3, i + length);
					entries.push({
						.name = name.copy(mem),
						.stage = stage_of((shady::ExecutionModel)words[i + 1]),
					});
				}
			default:
		}
		i += length;
	}

	vk::ShaderStageFlags stages = stage_union(entries.array_view());
	uint highest = 0;

	foreach (variable : variables)
	{
		if (variable.storage != (uint)shady::StorageClass.UNIFORM_CONSTANT
			&& variable.storage != (uint)shady::StorageClass.UNIFORM
			&& variable.storage != (uint)shady::StorageClass.STORAGE_BUFFER) continue;
		if (variable.id >= bound || variable.pointer >= bound) continue;
		if (kinds[variable.pointer] != ShadyType.POINTER_TYPE) continue;

		// A runtime-sized array unwraps to its element - it is the one resource
		// this project binds whole, at set 1 - and a fixed one multiplies the
		// count the array's own length implies.
		uint pointee = op_b[variable.pointer];
		uint array_count = 1;
		while (pointee < bound)
		{
			if (kinds[pointee] == ShadyType.ARRAY_TYPE)
			{
				uint length_id = op_b[pointee];
				if (length_id < bound && constants[length_id] != 0) array_count *= constants[length_id];
			}
			else if (kinds[pointee] != ShadyType.RUNTIME_ARRAY_TYPE)
			{
				break;
			}
			pointee = op_a[pointee];
		}
		if (pointee >= bound) continue;

		vk::DescriptorType type = DESCRIPTOR_TYPE_UNBINDABLE;
		switch (kinds[pointee])
		{
			case ShadyType.SAMPLED_IMAGE_TYPE:
				type = DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
			case ShadyType.IMAGE_TYPE:
				type = op_b[pointee] == (uint)shady::SampledImage.STORAGE
					? DESCRIPTOR_TYPE_STORAGE_IMAGE
					: DESCRIPTOR_TYPE_SAMPLED_IMAGE;
			case ShadyType.SAMPLER_TYPE:
				type = DESCRIPTOR_TYPE_SAMPLER;
			case ShadyType.STRUCT_TYPE:
				type = blocks[pointee] && variable.storage == (uint)shady::StorageClass.UNIFORM
					? DESCRIPTOR_TYPE_UNIFORM_BUFFER
					: blocks[pointee] && variable.storage == (uint)shady::StorageClass.STORAGE_BUFFER
						? DESCRIPTOR_TYPE_STORAGE_BUFFER
						: DESCRIPTOR_TYPE_UNBINDABLE;
			default:
		}

		bindings.push({
			.name = (named[variable.id] ? names[variable.id] : "").copy(mem),
			.set = has_set[variable.id] ? sets[variable.id] : 0,
			.binding = has_binding[variable.id] ? binding_numbers[variable.id] : 0,
			.count = array_count,
			.type = type,
			.stages = stages,
		});
		uint set = has_set[variable.id] ? sets[variable.id] : 0;
		if (set + 1 > highest) highest = set + 1;
	}

	*set_count = highest;
}

<*
 The SPIR-V string literal starting at a word: UTF-8, null-terminated, padded to
 a word boundary. The result points into the module, which outlives the walk.
*>
fn String spirv_string(uint* words, usz first, usz limit) @local
{
	usz length = 0;
	for (usz word = first; word < limit; word++)
	{
		for (uint byte = 0; byte < 4; byte++)
		{
			if (((words[word] >> (8 * byte)) & 0xff) == 0) return (String)((char*)&words[first])[:length];
			length++;
		}
	}
	return "";
}

<*
 A shady execution model in the numbering `ShaderEntry.stage` uses.
*>
fn uint stage_of(shady::ExecutionModel model) @local
{
	switch (model)
	{
		case shady::ExecutionModel.VERTEX: return STAGE_VERTEX;
		case shady::ExecutionModel.FRAGMENT: return STAGE_FRAGMENT;
		case shady::ExecutionModel.GL_COMPUTE: return STAGE_COMPUTE;
		default: return 0;
	}
}
