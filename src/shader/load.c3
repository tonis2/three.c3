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
import shady;

faultdef SHADER_NOT_FOUND;

<*
 Where a source file is looked for: `shaders/` and `build/shaders/`.

 Both candidates are relative to the working directory, because `c3c run`, a
 shell at the project root and `c3c test` all start there.

 @return ? SHADER_NOT_FOUND : `No shader by that name on the search path.`
*>
fn String? find_shader(ShaderFile file, alloc::Allocator allocator = mem)
{
	@pool()
	{
		String[2] candidates = {
			string::tformat("shaders/%s", file.name),
			string::tformat("build/shaders/%s", file.name),
		};
		foreach (candidate : candidates)
		{
			if (file::is_file(candidate)) return candidate.copy(allocator);
		}
		return SHADER_NOT_FOUND~;
	};
}

<*
 The Slang templates, carried in the binary. Paths are relative to this source
 file. About 95 KB of text against an 8.7 MB executable.
*>
const char[*] EMBED_MESH     = $embed("../../shaders/mesh.slang");
const char[*] EMBED_MATERIAL = $embed("../../shaders/material.slang");
const char[*] EMBED_POST     = $embed("../../shaders/post.slang");
const char[*] EMBED_SHADOW   = $embed("../../shaders/shadow.slang");
const char[*] EMBED_SKIN     = $embed("../../shaders/skin.slang");
const char[*] EMBED_CLUSTER  = $embed("../../shaders/cluster.slang");
const char[*] EMBED_SKY      = $embed("../../shaders/sky.slang");
const char[*] EMBED_SURFACE  = $embed("../../shaders/surface.slang");
const char[*] EMBED_LIGHTING = $embed("../../shaders/lighting.slang");

// The shady modules, which are whole programs rather than templates: a def names
// the file and gets its text, and nothing splices anything into it. They are
// small next to the Slang library above.
const char[*] EMBED_SKY_SHADY             = $embed("../../shaders/sky.shady");
const char[*] EMBED_MESH_SHADY            = $embed("../../shaders/mesh.shady");
const char[*] EMBED_SKINNING_SHADY        = $embed("../../shaders/skinning.shady");
const char[*] EMBED_SKIN_SHADY            = $embed("../../shaders/skin.shady");
const char[*] EMBED_CLUSTER_SHADY         = $embed("../../shaders/cluster.shady");
const char[*] EMBED_SHADOW_SHADY          = $embed("../../shaders/shadow.shady");
const char[*] EMBED_SHADOW_CUTOUT_SHADY   = $embed("../../shaders/shadow_cutout.shady");
const char[*] EMBED_POST_SHADY            = $embed("../../shaders/post.shady");
const char[*] EMBED_LIGHTING_SHADY        = $embed("../../shaders/lighting.shady");
const char[*] EMBED_LIGHTING_LTC_SHADY    = $embed("../../shaders/lighting_ltc.shady");
const char[*] EMBED_LIGHTING_REFERENCE_SHADY = $embed("../../shaders/lighting_reference.shady");
const char[*] EMBED_MATERIAL_SHADY        = $embed("../../shaders/material.shady");
const char[*] EMBED_SURFACE_SHADY         = $embed("../../shaders/surface.shady");

<*
 Every shader source that ships: one member per file, carrying the name it has on
 disk and the copy embedded in the binary.

 This enum is the list `EMBEDDED` used to be, and the only place a shader file is
 named. `load_source` derives the path from `name`, so a typo is a compile error
 rather than a fault at startup.

 `NONE` is not a file: a `ShaderSource` that carries it holds text a caller
 spliced instead. The members below it are the shady modules and the Slang
 templates the port has not replaced.
*>
enum ShaderFile : int (String name, String text)
{
	NONE                 { "", "" },

	// The shady modules.
	SKY_SHADY            { "sky.shady", EMBED_SKY_SHADY },
	MESH_SHADY           { "mesh.shady", EMBED_MESH_SHADY },
	SKINNING_SHADY       { "skinning.shady", EMBED_SKINNING_SHADY },
	SKIN_SHADY           { "skin.shady", EMBED_SKIN_SHADY },
	CLUSTER_SHADY        { "cluster.shady", EMBED_CLUSTER_SHADY },
	SHADOW_SHADY         { "shadow.shady", EMBED_SHADOW_SHADY },
	SHADOW_CUTOUT_SHADY  { "shadow_cutout.shady", EMBED_SHADOW_CUTOUT_SHADY },
	POST_SHADY           { "post.shady", EMBED_POST_SHADY },
	LIGHTING_SHADY       { "lighting.shady", EMBED_LIGHTING_SHADY },
	LIGHTING_LTC_SHADY   { "lighting_ltc.shady", EMBED_LIGHTING_LTC_SHADY },
	LIGHTING_REFERENCE_SHADY { "lighting_reference.shady", EMBED_LIGHTING_REFERENCE_SHADY },
	MATERIAL_SHADY       { "material.shady", EMBED_MATERIAL_SHADY },
	SURFACE_SHADY        { "surface.shady", EMBED_SURFACE_SHADY },

	// The Slang templates.
	MESH_SLANG           { "mesh.slang", EMBED_MESH },
	MATERIAL_SLANG       { "material.slang", EMBED_MATERIAL },
	POST_SLANG           { "post.slang", EMBED_POST },
	SHADOW_SLANG         { "shadow.slang", EMBED_SHADOW },
	SKIN_SLANG           { "skin.slang", EMBED_SKIN },
	CLUSTER_SLANG        { "cluster.slang", EMBED_CLUSTER },
	SKY_SLANG            { "sky.slang", EMBED_SKY },
	SURFACE_SLANG        { "surface.slang", EMBED_SURFACE },
	LIGHTING_SLANG       { "lighting.slang", EMBED_LIGHTING },
}

<*
 The line a template writes where the shared surface maths should go, and the
 file those come from.

 Text markers rather than a Slang `import`: nothing here compiles from a path — a
 shipped binary has no `shaders/` directory and hands Slang a string — so an
 include would have to be resolved against a virtual file system this project's
 bindings do not expose. Splicing text is the same mechanism `//@shade` already
 is, one layer earlier.
*>
const String MARKER_SHARED   = "//@shared";
const String MARKER_LIGHTING = "//@lighting";

<*
 A source file's text, with its imports resolved.

 The disk-first/embed rule is `read_shader_source`'s, and every imported name
 goes through the `ShaderFile` enum - the one list of what ships. A name the
 enum does not have is a fault, never a read from a `shaders/` directory a
 shipped binary would not have beside it.

 Resolution is recursive and each file keeps a `#line` region of its own, so a
 diagnostic from an imported file names that file and its own line.

 @return ? SHADER_NOT_FOUND : `A file named by an import is not a ShaderFile member, or a file the search path named was not there.`
 @return `The source, owned by the caller.`
*>
fn String? load_source(ShaderFile file, alloc::Allocator allocator = mem)
{
	String raw = read_shader_source(file, allocator)!;
	String? resolved = shady::resolve_imports(raw, file.name, &load_import, allocator: allocator);
	if (catch err = resolved)
	{
		alloc::free(allocator, raw.ptr);
		return err~;
	}
	// `raw` is the caller's until this call built the closure; free it with
	// the allocator it came from, which may be a temporary.
	alloc::free(allocator, raw.ptr);
	return resolved;
}

<*
 An import's text.

 The name must be a `ShaderFile` member: the enum is the only list of what a
 build carries, so `import "x.shady";` for a file nobody embedded is refused
 here rather than quietly read from disk and missing from a shipped binary.

 @return ? SHADER_NOT_FOUND : `No member of the enum has that name.`
*>
fn String? load_import(String file_name, alloc::Allocator allocator = mem)
{
	ShaderFile? found = ShaderFile::lookup_field(name, file_name);
	if (catch found) return SHADER_NOT_FOUND~;

	ShaderFile file = found;
	return read_shader_source(file, allocator);
}

<*
 A source file as written: the search path first, then the copy in the binary.

 The returned text is allocated from `allocator` outside the pool, so a caller
 may hand in a temporary that has a pool of its own above; the temporary path is
 the only thing the pool owns.

 @return ? SHADER_NOT_FOUND : `A file the search path named was not there when it was read. Every shipped source is embedded, so this is a race, not a missing member.`
 @return `The source, owned by the caller.`
*>
fn String? read_shader_source(ShaderFile file, alloc::Allocator allocator = mem)
{
	String path = "";
	@pool()
	{
		String[2] candidates = {
			string::tformat("shaders/%s", file.name),
			string::tformat("build/shaders/%s", file.name),
		};
		foreach (candidate : candidates)
		{
			if (!file::is_file(candidate)) continue;
			path = candidate.copy(mem);
			break;
		}
	};

	if (path.len)
	{
		defer free(path);
		// Said out loud, always. A source read off disk instead of out of the
		// binary changes what the GPU runs, and when it is the wrong file the
		// failure names a push block rather than a path - so the one line that
		// would have explained it has to be printed before it can fail.
		io::printfn("three: %s from %s (not the built-in)", file.name, path);
		return read_source(path, allocator);
	}

	return file.text.copy(allocator);
}
<*
 A template — the disk first, then the copy in the binary, with its requested
 shared maths spliced into it.

 What the render passes and `shader/assemble.c3` ask for, and the reason none of
 them needs to know whether a `shaders/` directory exists. A template with no
 `//@shared` line comes back exactly as it was read, so `post.slang`,
 `shadow.slang`, `skin.slang` and `sky.slang` are untouched by this.

 @param file : `The template: a ShaderFile member.`
 @param renumbered : `True for a caller that renumbers the text itself — the assembler, whose own #line directives are absolute against the module it generates. False puts the template's numbering back after the splice, which is what a template compiled as it stands wants.`
 @return ? SHADER_NOT_FOUND : `A file the search path named was not there when it was read — the condition load_source describes.`
 @return `The source, owned by the caller.`
*>
fn String? shader_source(ShaderFile file, alloc::Allocator allocator = mem, bool renumbered = false)
{
	@pool()
	{
		String template = load_source(file, tmem)!;
		if (!template.contains(MARKER_SHARED) && !template.contains(MARKER_LIGHTING)) return template.copy(allocator);

		String shared = load_source(ShaderFile.SURFACE_SLANG, tmem)!;
		String lighting = load_source(ShaderFile.LIGHTING_SLANG, tmem)!;

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

			String marker = text.trim();
			if (marker != MARKER_SHARED && marker != MARKER_LIGHTING)
			{
				out.append_string(text);
				out.append_char('\n');
				continue;
			}

			String insertion = marker == MARKER_SHARED ? shared : lighting;
			out.append_string(insertion);
			if (insertion.len > 0 && insertion[insertion.len - 1] != '\n') out.append_char('\n');
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
 Reads shader source from a path, with no search path and no fallback.

 No format check: anything wrong with the text is a Slang diagnostic with a line
 and a column, which beats anything this function could say. The SPIR-V magic
 number check lives in `shader/compile.c3`, guarding what the compiler returned.

 A test that wants the file as written — rather than the file as compiled —
 reaches for this; everything that ships goes through `load_source`.

 @return ? SHADER_NOT_FOUND : `No such file.`
 @return `The source, owned by the caller.`
*>
fn String? read_source(String path, alloc::Allocator allocator = mem)
{
	if (!file::is_file(path)) return SHADER_NOT_FOUND~;
	char[] bytes = file::load(allocator, path)!;
	return (String)bytes;
}
