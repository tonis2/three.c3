<*
 Shader source from disk, falling back to the copy in the binary.

 There is no `.spv` anywhere in this project and no build step for shaders:
 `shader/compile.c3` compiles `mesh.slang` at startup. Editing a shader and
 re-running shows the change with nothing rebuilt.

 `shader_source` answers from the search path when there is something there and
 from `$embed` when there is not. Both halves matter:

 - Embedded, so a shipped `three` is one file plus the Slang libraries. The
   search path is relative to the working directory, so without this every
   shipped copy would need a `shaders/` beside it and a launcher to cd there.
 - Disk first, so the edit-and-rerun loop in a checkout is untouched.

 This is not the `$embed` staleness trap described in `src/js/runtime.c3`. That
 trap needs a *generated* artifact whose build step can be silently skipped. A
 `.slang` file is hand-written source with no build step, so it is exactly as
 stale as the `.c3` files beside it — and since the disk copy wins, an edited
 checkout is not even that.
*>
module three;

import std::io;
import std::io::file;
import std::io::path;

faultdef SHADER_NOT_FOUND;

<*
 Where a template is looked for: `mesh.slang` and the four beside it.

 Both candidates are relative to the working directory, because `c3c run`, a
 shell at the project root and `c3c test` all start there.

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
 The five templates, carried in the binary. Paths are relative to this source
 file. About 90 KB of text against an 8.7 MB executable.
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

 What the render passes and `shader/assemble.c3` ask for, and the reason none of
 them needs to know whether a `shaders/` directory exists. A name that is neither
 on the search path nor embedded is a typo, not a deployment problem.

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
 Reads shader source.

 No format check: anything wrong with the text is a Slang diagnostic with a line
 and a column, which beats anything this function could say. The SPIR-V magic
 number check lives in `shader/compile.c3`, guarding what the compiler returned.

 @return? SHADER_NOT_FOUND : `No such file.`
 @return `The source, owned by the caller.`
*>
fn String? load_source(String path, alloc::Allocator allocator = mem)
{
	if (!file::is_file(path)) return SHADER_NOT_FOUND~;
	char[] bytes = file::load(allocator, path)!;
	return (String)bytes;
}
