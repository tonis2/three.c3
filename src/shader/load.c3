<*
 SPIR-V from disk.

 **Never `$embed`.** crig embeds its shader and pays for it: `c3c build shaders`
 without `--trust=full` skips the exec, reports the target as built, leaves the
 `.spv` untouched, and `$embed` picks up the previous binary. The result is a
 shader edit that compiles cleanly and changes nothing on screen, which is the
 most expensive kind of failure because it looks like a rendering bug. Reading
 the file removes the trap entirely and makes iteration a re-run rather than a
 rebuild.

 It is also what makes M4 cheap: `load_spirv(path)` becomes
 `compile_slang(source)` and nothing above this file changes. The whole point of
 keeping the loading behind one function is that the runtime compiler slots into
 the same hole.
*>
module three;

import std::io;
import std::io::file;
import std::io::path;

faultdef SHADER_NOT_FOUND, SHADER_NOT_SPIRV;

// The SPIR-V magic number, little-endian. Checked because the failure it
// catches — a stale, truncated or wrong-format file — otherwise surfaces as a
// driver error message about an invalid module, several layers from the cause.
const uint SPIRV_MAGIC = 0x07230203;

<*
 Where `mesh.spv` is looked for when nothing says otherwise.

 Both candidates are relative to the working directory, because `c3c run`, a
 shell at the project root and `c3c test` all start there, and that is where
 the edit-and-rerun loop lives. `--shader <path>` is the way to point somewhere
 else; a binary carried away from its checkout needs it.

 @return? SHADER_NOT_FOUND : `Build it with c3c --trust=full build shaders, or run slangc by hand. The .spv is not embedded and a plain c3c build does not produce it.`
*>
fn String? find_shader(String name, alloc::Allocator allocator = mem)
{
	@pool()
	{
		String[2] candidates = {
			string::tformat("shaders/%s", name),
			string::tformat("build/shaders/%s", name),
		};
		foreach (candidate : candidates)
		{
			if (file::is_file(candidate)) return candidate.copy(allocator);
		}
		return SHADER_NOT_FOUND~;
	};
}

<*
 Read a SPIR-V module.

 @return? SHADER_NOT_SPIRV : `The file is not a multiple of four bytes long, or does not start with the SPIR-V magic number — a stale or truncated build.`
 @return? SHADER_NOT_FOUND : `No such file.`
 @return `The module's bytes, owned by the caller.`
*>
fn char[]? load_spirv(String path, alloc::Allocator allocator = mem)
{
	if (!file::is_file(path)) return SHADER_NOT_FOUND~;

	char[] bytes = file::load(allocator, path)!;
	if (bytes.len < 4 || bytes.len % 4 != 0)
	{
		alloc::free(allocator, bytes);
		return SHADER_NOT_SPIRV~;
	}

	uint magic = *(uint*)bytes.ptr;
	if (magic != SPIRV_MAGIC)
	{
		alloc::free(allocator, bytes);
		return SHADER_NOT_SPIRV~;
	}

	return bytes;
}
