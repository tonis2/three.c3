<*
 Shader source from disk.

 **Never `$embed`, and at M4 that stopped being a preference and became free.**

 M1's reason was crig's: `c3c build shaders` without `--trust=full` skips the
 exec, reports the target as built, leaves the `.spv` untouched, and `$embed`
 picks up the previous binary — a shader edit that compiles cleanly and changes
 nothing on screen, which is the most expensive kind of failure because it looks
 like a rendering bug.

 M4 removes the build step entirely. There is no `.spv`, no prepare target and no
 `slangc` invocation anywhere in this project; `shader/compile.c3` compiles
 `mesh.slang` at startup. Editing the shader and re-running now shows the change
 with no rebuild of anything — not of the shader, not of the app.

 That is also why the source is read rather than embedded, unlike `js/prelude.js`
 next door, which is `$embed`-ed. The prelude *defines* an API that must exist
 wherever the binary runs; a shader is content the loop iterates on.

 **The consequence, stated plainly: this binary runs from its checkout.** There
 was a `--shader <path>` on the command line that read as a way out of that, and
 it was not one — it could only name `mesh.slang`, while `material.slang`,
 `post.slang`, `shadow.slang` and `skin.slang` came through this function
 regardless, so a run from elsewhere drew the built-in triangle and then failed
 on the first `ShaderMaterial`. Rather than grow the flag into a directory, the
 search path below is the whole answer, and `three --help` says so.
*>
module three;

import std::io;
import std::io::file;
import std::io::path;

faultdef SHADER_NOT_FOUND;

<*
 Where a template is looked for: `mesh.slang` and the four beside it.

 Both candidates are relative to the working directory, because `c3c run`, a
 shell at the project root and `c3c test` all start there, and that is where the
 edit-and-rerun loop lives. Nothing overrides them, and the header has why the
 flag that used to is gone.

 @return? SHADER_NOT_FOUND : `No shader by that name on the search path. Run from the project root.`
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
 Read shader source.

 There is no format check here and there was one in M1's `load_spirv`, which
 checked the SPIR-V magic number to catch a stale or truncated build. That check
 did not disappear; it moved to `shader/compile.c3`, where it now guards what the
 compiler returned rather than what a build step wrote. Anything wrong with the
 *text* is a Slang diagnostic with a line and a column, which is a better error
 than anything this function could produce.

 @return? SHADER_NOT_FOUND : `No such file.`
 @return `The source, owned by the caller.`
*>
fn String? load_source(String path, alloc::Allocator allocator = mem)
{
	if (!file::is_file(path)) return SHADER_NOT_FOUND~;
	char[] bytes = file::load(allocator, path)!;
	return (String)bytes;
}
