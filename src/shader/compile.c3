<*
 One compiled shader: the SPIR-V, and what the compiler said about it.

 The module is produced by `shader/adapter.c3`, which compiles a `ShaderDef`
 through shady and reflects the module's entries and descriptors. This file
 holds the type every pass shares and the stage numbering its entries carry.
*>
module three;

import std::collections::list;

faultdef SHADER_COMPILE_FAILED;

// The SPIR-V magic number, little-endian. Checked against what the compiler just
// returned, where it catches a compiler that reported success and produced
// something else.
const uint SPIRV_MAGIC = 0x07230203;

// The stage numbering `ShaderEntry.stage` carries. The values are the Slang-era
// ones, kept so the entry tables and the adapter's mapping did not have to be
// renumbered; `stage_flag_of` is what turns one into a Vulkan stage flag.
const uint STAGE_VERTEX   = 1;
const uint STAGE_HULL     = 2;
const uint STAGE_DOMAIN   = 3;
const uint STAGE_GEOMETRY = 4;
const uint STAGE_FRAGMENT = 5;
const uint STAGE_COMPUTE  = 6;

struct ShaderModule
{
	bool ok;
	char[] spirv;
	String diagnostic;
	ShaderLayout layout;
	// The entry points the module really contains, read back from the module
	// rather than from what was asked for.
	List{ShaderEntry} entries;
	// The compute entry point's workgroup size, from its own `OpExecutionMode
	// LocalSize`. Zero when the module declares none - which is a module that
	// cannot be dispatched, not one to guess a size for.
	uint[3] local_size;
}

<*
 An entry point: the name in the module, and which stage it is.
*>
struct ShaderEntry
{
	String name;
	uint stage; // STAGE_*
}

fn void ShaderModule.free(&self)
{
	// Guarded on the pointer, not the length: an allocator hands back a non-null
	// pointer for an empty string, and a `len > 0` guard leaks it — one byte per
	// compile, invisible without leak tracking, unbounded in an agent loop.
	if (self.spirv.ptr != null) alloc::free(mem, self.spirv);
	if (self.diagnostic.ptr != null) self.diagnostic.free(mem);
	self.layout.free();
	foreach (entry : self.entries) if (entry.name.ptr != null) entry.name.free(mem);
	self.entries.free();
	*self = { };
}
