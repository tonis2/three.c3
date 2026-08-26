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

 **That binary used to run only from its checkout, and no longer does.** There
 was a `--shader <path>` on the command line that read as a way out of that, and
 it was not one — it could only name `mesh.slang`, while `material.slang`,
 `post.slang`, `shadow.slang` and `skin.slang` came through this function
 regardless, so a run from elsewhere drew the built-in triangle and then failed
 on the first `ShaderMaterial`.

 ## The templates are now IN the binary, and the disk still wins

 `shader_source` is what the render passes ask, and it answers from the search
 path when there is something there and from `$embed` when there is not. Both
 halves are load-bearing:

 - **Embedded**, so a shipped `three` is one file plus the Slang libraries. The
   search path is relative to the WORKING DIRECTORY, which made every shipped
   copy need a `shaders/` beside it and a launcher to cd there first. A user who
   downloads a binary should be able to run the binary.
 - **Disk first**, so the edit-and-rerun loop this file was built around is
   untouched: `shaders/mesh.slang` in a checkout still overrides, still with no
   rebuild of anything.

 **This is not the `$embed` trap.** `src/js/runtime.c3` states the distinction
 and it applies unchanged here: the trap is a *generated* artifact, where a
 build step that is silently skipped leaves `$embed` picking up the previous
 output. A `.slang` file is hand-written source with no build step to skip, so
 it is exactly as stale as the `.c3` files beside it and no more — and because
 the disk copy wins, an edited checkout is not even that.
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
 The five templates, carried in the binary.

 Paths are relative to this source file, as `src/js/runtime.c3`'s are. About
 90 KB of text all told, against an 8.7 MB executable.
*>
const char[*] EMBED_MESH     = $embed("../../shaders/mesh.slang");
const char[*] EMBED_MATERIAL = $embed("../../shaders/material.slang");
const char[*] EMBED_POST     = $embed("../../shaders/post.slang");
const char[*] EMBED_SHADOW   = $embed("../../shaders/shadow.slang");
const char[*] EMBED_SKIN     = $embed("../../shaders/skin.slang");

struct EmbeddedShader
{
	String name;
	String source;
}

<*
 A template by name — the disk first, then the copy in the binary.

 This is what the render passes and `shader/assemble.c3` ask for, and it is the
 reason none of them needs to know whether there is a `shaders/` directory. A
 name that is neither on the search path nor embedded is the fault, which is a
 typo rather than a deployment problem.

 @param name : `A file name, not a path: "mesh.slang".`
 @return? SHADER_NOT_FOUND : `No such template, on disk or in the binary.`
 @return `The source, owned by the caller.`
*>
fn String? shader_source(String name, alloc::Allocator allocator = mem)
{
	@pool()
	{
		if (try path = find_shader(name, tmem)) return load_source(path, allocator);
	};

	EmbeddedShader[5] embedded = {
		{ "mesh.slang",     (String)EMBED_MESH[..] },
		{ "material.slang", (String)EMBED_MATERIAL[..] },
		{ "post.slang",     (String)EMBED_POST[..] },
		{ "shadow.slang",   (String)EMBED_SHADOW[..] },
		{ "skin.slang",     (String)EMBED_SKIN[..] },
	};
	foreach (entry : embedded)
	{
		if (entry.name == name) return entry.source.copy(allocator);
	}
	return SHADER_NOT_FOUND~;
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
