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

faultdef SHADER_NOT_FOUND;

<*
 Where a template is looked for: `mesh.slang` and the six beside it.

 Both candidates are relative to the working directory, because `c3c run`, a
 shell at the project root and `c3c test` all start there.

 @return ? SHADER_NOT_FOUND : `No shader by that name on the search path.`
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
 The seven templates, carried in the binary. Paths are relative to this source
 file. About 95 KB of text against an 8.7 MB executable.
*>
const char[*] EMBED_MESH     = $embed("../../shaders/mesh.slang");
const char[*] EMBED_MATERIAL = $embed("../../shaders/material.slang");
const char[*] EMBED_POST     = $embed("../../shaders/post.slang");
const char[*] EMBED_SHADOW   = $embed("../../shaders/shadow.slang");
const char[*] EMBED_SKIN     = $embed("../../shaders/skin.slang");
const char[*] EMBED_SKY      = $embed("../../shaders/sky.slang");
const char[*] EMBED_SURFACE  = $embed("../../shaders/surface.slang");

struct EmbeddedShader
{
	String name;
	String source;
}

const EmbeddedShader[7] EMBEDDED = {
	{ "mesh.slang", (String)EMBED_MESH[..] },
	{ "material.slang", (String)EMBED_MATERIAL[..] },
	{ "post.slang", (String)EMBED_POST[..] },
	{ "shadow.slang", (String)EMBED_SHADOW[..] },
	{ "skin.slang", (String)EMBED_SKIN[..] },
	{ "sky.slang", (String)EMBED_SKY[..] },
	{ SHARED_TEMPLATE, (String)EMBED_SURFACE[..] },
};

<*
 The line a template writes where the shared surface maths should go, and the
 file those come from.

 One marker rather than a Slang `import`: nothing here compiles from a path — a
 shipped binary has no `shaders/` directory and hands Slang a string — so an
 include would have to be resolved against a virtual file system this project's
 bindings do not expose. Splicing text is the same mechanism `//@shade` already
 is, one layer earlier.
*>
const String MARKER_SHARED   = "//@shared";
const String SHARED_TEMPLATE = "surface.slang";

<*
 A template by name — the disk first, then the copy in the binary, with the
 shared surface maths spliced into it.

 What the render passes and `shader/assemble.c3` ask for, and the reason none of
 them needs to know whether a `shaders/` directory exists. A name that is neither
 on the search path nor embedded is a typo, not a deployment problem.

 A template with no `//@shared` line comes back exactly as it was read, so
 `post.slang`, `shadow.slang`, `skin.slang` and `sky.slang` are untouched by
 this.

 @param name : `A file name, not a path: "mesh.slang".`
 @param renumbered : `True for a caller that renumbers the text itself — the assembler, whose own #line directives are absolute against the module it generates. False puts the template's numbering back after the splice, which is what a template compiled as it stands wants.`
 @return ? SHADER_NOT_FOUND : `No such template, on disk or in the binary — or the shared block it asks for is missing, which is the same fault for the same reason.`
 @return `The source, owned by the caller.`
*>
fn String? shader_source(String name, alloc::Allocator allocator = mem, bool renumbered = false)
{
	@pool()
	{
		String template = template_source(name, tmem)!;
		if (!template.contains(MARKER_SHARED)) return template.copy(allocator);

		String shared = template_source(SHARED_TEMPLATE, tmem)!;

		DString out;
		out.tinit(template.len + shared.len + 64);

		// The template's own line numbering, counted so the restore directive
		// below can hand it back. The splice is one line in and N lines out, and
		// without the restore every diagnostic in the rest of the file would be
		// off by N — which does not fail, it points at the wrong line for ever.
		uint line = 0;
		usz start = 0;
		while (start < template.len)
		{
			usz end = start;
			while (end < template.len && template[end] != '\n') end++;
			String text = template[start:end - start];
			start = end + 1;
			line++;

			if (text.trim() != MARKER_SHARED)
			{
				out.append_string(text);
				out.append_char('\n');
				continue;
			}

			out.append_string(shared);
			if (shared.len > 0 && shared[shared.len - 1] != '\n') out.append_char('\n');
			// Nothing for a template the assembler is going to renumber: its own
			// restores are absolute against the module it generates, and a template
			// line number in the middle would leave the preamble numbered two ways.
			if (renumbered) continue;
			// **No filename.** The directive numbers the line that follows it —
			// the template line after the marker — and leaving the name out keeps
			// whatever the compile unit is called, which is the name a diagnostic
			// should carry. A filename here would be a third spelling of `mesh.slang`
			// in the same message.
			out.appendf("#line %d", line + 1)!!;
			out.append_char('\n');
		}

		return out.copy_str(allocator);
	};
}

<*
 One template's text, as it is stored: the search path first, then the copy in
 the binary.

 Split out of `shader_source` because the splice above needs the *unspliced*
 read for the shared block itself, and because saying "from disk" twice for one
 template would be one line of noise per shader.
*>
fn String? template_source(String name, alloc::Allocator allocator) @local
{
	@pool()
	{
		if (try path = find_shader(name, tmem))
		{
			// Said out loud, always. A template read off disk instead of out of the
			// binary changes what the GPU runs, and when it is the wrong file the
			// failure names a push block rather than a path — so the one line that
			// would have explained it has to be printed before it can fail.
			io::printfn("three: %s from %s (not the built-in)", name, path);
			return load_source(path, allocator);
		}
	};

	foreach (entry : EMBEDDED)
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

 @return ? SHADER_NOT_FOUND : `No such file.`
 @return `The source, owned by the caller.`
*>
fn String? load_source(String path, alloc::Allocator allocator = mem)
{
	if (!file::is_file(path)) return SHADER_NOT_FOUND~;
	char[] bytes = file::load(allocator, path)!;
	return (String)bytes;
}