<*
 Slang, at runtime, from a string.

 This is what M1's `load_spirv` became. The shape of the swap was predicted in
 that file's header and held: `MeshPass.init` still asks for one thing and gets
 SPIR-V back, and everything downstream of it is unchanged.

 What is new is the second return value. A compile does not only produce bytes —
 it produces a *diagnostic*, and on the failure path that diagnostic is the whole
 product. Slang's are unusually good:

     error[E30015]: undefined identifier
       --> mesh.slang:10:26
        |
     10 | output.sv_position = notAFunction(vid);
        |                      ^^^^^^^^^^^^ undefined identifier 'notAFunction'.

 A line, a column, the source line and a caret span. `plan.md` §3 says routing
 that verbatim into the thrown JS exception is most of what makes the agent loop
 work, and §6 says a compile that fails quietly and keeps the previous pipeline
 is the runtime version of crig's `$embed` trap. So `ShaderModule` carries the
 diagnostic on **both** paths — a warning on a successful compile is worth as
 much as an error on a failed one — and nothing here falls back to anything.

 ## One session, for the life of the process

 `spCreateSession` costs about 55 ms and a compile costs about 17 ms, so a
 session per compile would be four parts setup to one part work. There is one,
 made on first use.

 **It is never destroyed**, and that is deliberate rather than overlooked.
 Nothing owns it: `MeshPass`, the JS runtime and the test harness all compile,
 all outlive each other in different orders, and the only correct owner would be
 `main` — which would then have to be right on every early-return path for a
 teardown whose entire benefit is returning memory to a process that is exiting.
 Slang allocates it with `malloc`, not through C3's allocator, so a leak-tracked
 test run does not see it either. `slang::Session.free` exists in the binding and
 is exercised by the standalone tests there.
*>
module three;

import std::io;
import std::collections::list;
import slang;

faultdef
	SHADER_COMPILE_FAILED,
	SHADER_NOT_SPIRV,
	SLANG_UNAVAILABLE;

<*
 The flags every compile in this project passes, in one place.

 `plan.md` §6 has the trap this closes: `project.json`'s `slangc` line was
 missing `-force-glsl-scalar-layout` while `mesh.slang`'s header said to pass it,
 which is two different SPIR-V modules and no error either way. There is now no
 offline invocation to disagree with — the prepare target is gone — so this array
 is the only place the target is configured and drift has nowhere to happen.

 They are passed through `spProcessCommandLineArguments`, which takes the same
 argv `slangc` does, rather than mapped onto `spSetCodeGenTarget` and friends by
 hand. That is `plan.md` §3's suggestion and it is the right one: a flag that
 gains a setter in a future SDK still works spelled this way.
*>
const String[*] SLANG_ARGUMENTS = {
	"-target", "spirv",
	// Straight to SPIR-V rather than through GLSL. The via-GLSL path loses the
	// physical-storage-buffer pointers this project's whole geometry model is.
	"-emit-spirv-directly",
	// Keeps `vertexMain` called `vertexMain` in the module rather than `main`,
	// which is what `gpu/pipeline.c3` names its stages by.
	//
	// **It is a no-op on the SDK this was built against**, measured rather than
	// assumed: the module is byte-identical with and without it, through both
	// this API and `slangc`. Kept because it is in the documented invocation,
	// because it costs nothing, and because a default that changed once can
	// change back — but the claim that it is load-bearing was not true here,
	// and `the_entry_points_keep_their_names` does not fail when it is removed.
	"-fvk-use-entrypoint-name",
	// Not optional and not decoration: without it the tightly packed float3 and
	// float2 streams uploaded by `gpu/buffer.c3` are read at std430 strides, and
	// geometry arrives a third of the way off with nothing reporting an error.
	"-force-glsl-scalar-layout",
	// **`slangc` defaults to this and the compile-request API does not.**
	//
	// It is not in `mesh.slang`'s documented command line and it did not need to
	// be, because it was the CLI's default; the API's default is row-major, so
	// passing the documented flags verbatim still produced a different module.
	// Every matrix in the frame block and the instance array is then read
	// transposed. The truck still rendered — a plausible, wrong picture — and
	// only the built-in triangle collapsed to fourteen pixels and said so.
	//
	// The generalisation is worse than `plan.md` §6's version of this trap: it
	// is not enough for two invocations to pass the same flags, because the
	// defaults underneath them differ.
	"-matrix-layout-column-major",
};

// The SPIR-V magic number, little-endian. M1 checked this against a file on
// disk, where it caught a stale or truncated build. Checked here against what
// the compiler just returned, where it catches a Slang that reported success and
// produced something else — which has a precedent worth respecting:
// `spGetEntryPointCode` answers with a null pointer and a length of zero under
// `-emit-spirv-directly` and reports no error at all.
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
	// **On the pointer, not the length.** `m3_stage.md`'s last verification row
	// is this exact bug in `RunResult.free`: an allocator hands back a non-null
	// pointer for an empty string, and a `len > 0` guard leaks it — one byte per
	// compile, invisible without leak tracking, unbounded in an agent loop.
	if (self.spirv.ptr != null) alloc::free(mem, self.spirv);
	if (self.diagnostic.ptr != null) self.diagnostic.free(mem);
	self.layout.free();
	foreach (entry : self.entries) if (entry.name.ptr != null) entry.name.free(mem);
	self.entries.free();
	*self = {};
}

// The process-wide session. See the header for why it is a global and why it is
// never destroyed.
slang::Session shared_session @local = null;

<*
 The Slang session, started on first use.

 @return? SLANG_UNAVAILABLE : `Slang would not start. There is no compile request to ask for a diagnostic yet, so the usual cause is a libslang that cannot find the downstream compiler it loads for SPIR-V — see lib/slang.c3l/native/stage-slang.sh.`
*>
fn slang::Session? slang_session()
{
	if (shared_session == null) shared_session = slang::session()!;
	return shared_session;
}

<*
 Compile Slang source to a SPIR-V module and reflect it.

 **A shader that does not compile is not a fault.** It is the ordinary answer
 this function exists to give, and it comes back as `ok: false` with the
 diagnostic attached. A fault would throw the diagnostic away and leave the
 caller with nothing to print, which is the failure mode `plan.md` §6 calls the
 runtime version of the `$embed` trap.

 The faults below are for the cases where there is nothing to report *about the
 shader*: Slang did not start, or it reported success and handed back something
 that is not a module.

 @param name : `What the source is called in diagnostics. Not a path and never opened.`
 @param entries : `Named rather than discovered. A shader whose entry point is spelled differently is then an error with a sentence attached, instead of a module the pipeline cannot use.`
 @return? SLANG_UNAVAILABLE : `The session would not start.`
 @return? SHADER_NOT_SPIRV : `Slang reported success and returned no module, or one that does not begin with the SPIR-V magic number.`
*>
fn ShaderModule? compile_slang(String source, String name, ShaderEntry[] entries)
{
	slang::Session session = slang_session()!;

	slang::Entry[] wanted = alloc::new_array(mem, slang::Entry, entries.len);
	defer alloc::free(mem, wanted);
	foreach (i, entry : entries) wanted[i] = { .name = entry.name, .stage = entry.stage };

	slang::Compiled compiled = session.compile({
		.name = name,
		.source = source,
		.entries = wanted,
		.arguments = SLANG_ARGUMENTS[..],
	})!;
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
 Compile the source at `path`.

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
