<*
 Slang, at runtime, from a string.

 A compile produces two things: SPIR-V, and a *diagnostic*. On the failure path
 the diagnostic is the whole product, and Slang's are unusually good:

 error[E30015]: undefined identifier
 --> mesh.slang:10:26
 |
 10 | output.sv_position = notAFunction(vid);
 |                      ^^^^^^^^^^^^ undefined identifier 'notAFunction'.

 A line, a column, the source line and a caret span. Routing that verbatim into
 the thrown JS exception is most of what makes shader iteration work, so
 `ShaderModule` carries the diagnostic on *both* paths — a warning on a
 successful compile is worth as much as an error on a failed one — and nothing
 here falls back to anything. A compile that fails quietly and keeps the
 previous pipeline is the worst possible outcome.

 ## One session, for the life of the process

 `spCreateSession` costs about 55 ms and a compile about 17 ms, so a session per
 compile would be four parts setup to one part work. There is one, made on first
 use, and it is never destroyed. Nothing owns it: `MeshPass`, the JS runtime and
 the test harness all compile and all outlive each other in different orders,
 and the only correct owner would be `main` — which would have to be right on
 every early-return path for a teardown whose entire benefit is returning memory
 to an exiting process. Slang allocates it with `malloc` rather than through
 C3's allocator, so leak-tracked test runs do not see it either.
*>
module three;

import std::io;
import std::collections::list;
import slang;

faultdef
	SHADER_COMPILE_FAILED, SHADER_NOT_SPIRV, SLANG_UNAVAILABLE;

<*
 The flags every compile in this project passes, in one place.

 There is no offline `slangc` invocation to disagree with — nothing is compiled
 ahead of time — so this array is the only place the target is configured.

 They go through `spProcessCommandLineArguments`, which takes the same argv
 `slangc` does, rather than being mapped onto `spSetCodeGenTarget` and friends
 by hand: a flag that gains a setter in a future SDK still works spelled this
 way.
*>
const String[*] SLANG_ARGUMENTS = {
	"-target",
	"spirv", // Straight to SPIR-V rather than through GLSL. The via-GLSL path loses the
	// physical-storage-buffer pointers this project's whole geometry model is.
	"-emit-spirv-directly", // Keeps `vertexMain` called `vertexMain` in the module rather than `main`,
	// which is what `gpu/pipeline.c3` names its stages by.
	//
	// It is a no-op on the SDK this was built against — the module is
	// byte-identical with and without it, through both this API and `slangc` —
	// and `the_entry_points_keep_their_names` does not fail when it is removed.
	// Kept because it is in the documented invocation, costs nothing, and a
	// default that changed once can change back.
	"-fvk-use-entrypoint-name", // Not optional: without it the tightly packed float3 and float2 streams
	// uploaded by `gpu/buffer.c3` are read at std430 strides, and geometry
	// arrives a third of the way off with nothing reporting an error.
	"-force-glsl-scalar-layout", // `slangc` defaults to this and the compile-request API does not.
	//
	// It is not in `mesh.slang`'s documented command line because it was the
	// CLI's default; the API's default is row-major, so passing the documented
	// flags verbatim still produced a different module. Every matrix in the
	// frame block and the instance array is then read transposed — the truck
	// still rendered a plausible, wrong picture, and only the built-in triangle
	// collapsed to fourteen pixels and said so.
	//
	// Two invocations passing the same flags is not enough when the defaults
	// underneath them differ.
	"-matrix-layout-column-major", // Slang's default is -O1, and at -O1 it hands the SPIR-V it just generated
	// to `spirv-opt` — which lives inside libslang-glslang and is loaded by
	// name at runtime, not linked. -emit-spirv-directly does not change that:
	// it picks the codegen path, and the optimiser runs after codegen either
	// way. -O0 is the only way to compile without that second library present.
	//
	// It costs almost nothing here. Measured on these shaders: mesh.slang is
	// 28700 bytes at -O0 against 28728 at -O1 — spirv-opt makes it *bigger* —
	// and shadow.slang 11776 against 10320. Drivers optimise SPIR-V themselves
	// before it reaches the GPU.
	"-O0",
};

// The SPIR-V magic number, little-endian. Checked against what the compiler just
// returned, where it catches a Slang that reported success and produced
// something else — which happens: `spGetEntryPointCode` answers with a null
// pointer and a length of zero under `-emit-spirv-directly` and reports no error
// at all.
const uint SPIRV_MAGIC = 0x07230203;

<*
 One compiled shader: the module, what it needs bound, and what Slang said.

 Everything here is owned and must be freed with `ShaderModule.free`.
*>
struct ShaderModule
{
	bool ok;
	char[] spirv;
	String diagnostic;
	ShaderLayout layout;
	// The entry points the module really contains, read back from reflection
	// rather than from what was asked for.
	List{ShaderEntry} entries;
}

<*
 An entry point: the name in the module, and which stage it is.
*>
struct ShaderEntry
{
	String name;
	uint stage; // slang::STAGE_*
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

// The process-wide session. See the header for why it is a global and why it is
// never destroyed.
slang::Session shared_session @local = null;

<*
 The Slang session, started on first use.

 @return ? SLANG_UNAVAILABLE : `Slang would not start. Slang is linked into the binary, so this is not a missing library; there is no compile request to ask for a diagnostic yet either, which is what makes it opaque.`
*>
fn slang::Session? slang_session()
{
	if (shared_session == null) shared_session = slang::session()!;
	return shared_session;
}

<*
 Compiles Slang source to a SPIR-V module and reflects it.

 A shader that does not compile is not a fault. It is the ordinary answer this
 function exists to give, and it comes back as `ok: false` with the diagnostic
 attached; a fault would throw the diagnostic away and leave the caller with
 nothing to print.

 The faults below are for the cases where there is nothing to report *about the
 shader*: Slang did not start, or it reported success and handed back something
 that is not a module.

 @param name : `What the source is called in diagnostics. Not a path and never opened.`
 @param entries : `Named rather than discovered. A shader whose entry point is spelled differently is then an error with a sentence attached, instead of a module the pipeline cannot use.`
 @return ? SLANG_UNAVAILABLE : `The session would not start.`
 @return ? SHADER_NOT_SPIRV : `Slang reported success and returned no module, or one that does not begin with the SPIR-V magic number.`
*>
fn ShaderModule? compile_slang(String source, String name, ShaderEntry[] entries)
{
	slang::Session session = slang_session()!;

	slang::Entry[] wanted = alloc::new_array(mem, slang::Entry, entries.len);
	defer alloc::free(mem, wanted);
	foreach (i, entry : entries) wanted[i] = { .name = entry.name, .stage = entry.stage };

	slang::Compiled compiled = session.compile(
		{
			.name = name,
			.source = source,
			.entries = wanted,
			.arguments = SLANG_ARGUMENTS[..],
		}
	)!;
	// Everything `compiled` points at is interior to the request and the next
	// request reuses the address, so this runs after the copies below.
	defer compiled.free();

	ShaderModule out;
	out.ok = compiled.ok;
	out.diagnostic = compiled.diagnostic.copy(mem);
	out.entries.init(mem, 4);

	if (!out.ok) return out;

	if (compiled.spirv.len < 4 || compiled.spirv.len % 4 != 0)
	{
		out.free();
		return SHADER_NOT_SPIRV~;
	}
	if (*(uint*)compiled.spirv.ptr != SPIRV_MAGIC)
	{
		out.free();
		return SHADER_NOT_SPIRV~;
	}

	out.spirv = alloc::new_array(mem, char, compiled.spirv.len);
	out.spirv[..] = compiled.spirv[..];

	@pool()
	{
		List{slang::Entry} found;
		found.tinit(4);
		compiled.reflection.entry_points(&found);
		foreach (entry : found)
		{
			out.entries.push({ .name = entry.name.copy(mem), .stage = entry.stage });
		}
	};

	out.layout = reflect_layout(compiled.reflection, out.entries.array_view());
	return out;
}

<*
 Compiles the source at `path`.

 @param name : `Overrides what diagnostics call the source; defaults to the path.`
*>
fn ShaderModule? compile_shader_file(String path, ShaderEntry[] entries, String name = "")
{
	@pool()
	{
		String source = load_source(path, tmem)!;
		return compile_slang(source, name.len > 0 ? name : path, entries);
	};
}