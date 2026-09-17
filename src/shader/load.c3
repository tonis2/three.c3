<*
 Shader source from disk, falling back to the copy in the binary.

 There is no `.spv` anywhere in this project and no build step for shaders: the
 defs compile their `.shady` sources at startup. Editing a shader and re-running
 shows the change with nothing rebuilt.

 `read_shader_source` answers from the search path when there is something there
 and from `$embed` when there is not. Both halves matter:

 - Embedded, so a shipped `three` is one file. The search path is relative to
 the working directory, so without this every shipped copy would need a
 `shaders/` beside it and a launcher to cd there.
 - Disk first, so the edit-and-rerun loop in a checkout is untouched.

 This is not the `$embed` staleness trap described in `src/js/runtime.c3`. That
 trap needs a *generated* artifact whose build step can be silently skipped. A
 `.shady` file is hand-written source with no build step, so it is exactly as
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

// The shady modules, carried in the binary. Paths are relative to this source
// file. A def names the file and gets its text, with nothing spliced into it,
// so every file here is a whole program or a piece one imports.
const char[*] EMBED_SKY_SHADY             = $embed("../../shaders/sky.shady");
const char[*] EMBED_MESH_SHADY            = $embed("../../shaders/mesh.shady");
const char[*] EMBED_SKINNING_SHADY        = $embed("../../shaders/skinning.shady");
const char[*] EMBED_SKIN_SHADY            = $embed("../../shaders/skin.shady");
const char[*] EMBED_SKIN_MATH_SHADY       = $embed("../../shaders/skin_math.shady");
const char[*] EMBED_CLUSTER_SHADY         = $embed("../../shaders/cluster.shady");
const char[*] EMBED_SHADOW_SHADY          = $embed("../../shaders/shadow.shady");
const char[*] EMBED_SHADOW_CUTOUT_SHADY   = $embed("../../shaders/shadow_cutout.shady");
const char[*] EMBED_POST_SHADY            = $embed("../../shaders/post.shady");
const char[*] EMBED_LIGHTING_SHADY        = $embed("../../shaders/lighting.shady");
const char[*] EMBED_LIGHTING_LTC_SHADY    = $embed("../../shaders/lighting_ltc.shady");
const char[*] EMBED_LIGHTING_REFERENCE_SHADY = $embed("../../shaders/lighting_reference.shady");
const char[*] EMBED_MATERIAL_SHADY        = $embed("../../shaders/material.shady");
const char[*] EMBED_NOISE_SHADY           = $embed("../../shaders/noise.shady");
const char[*] EMBED_SURFACE_SHADY         = $embed("../../shaders/surface.shady");

<*
 Every shader source that ships: one member per file, carrying the name it has on
 disk and the copy embedded in the binary.

 This enum is the list `EMBEDDED` used to be, and the only place a shader file is
 named. `load_source` derives the path from `name`, so a typo is a compile error
 rather than a fault at startup.

 `NONE` is not a file: a `ShaderSource` that carries it holds text a caller
 spliced instead.
*>
enum ShaderFile : int (String name, String text)
{
	NONE                 { "", "" },

	// The shady modules.
	SKY_SHADY            { "sky.shady", EMBED_SKY_SHADY },
	MESH_SHADY           { "mesh.shady", EMBED_MESH_SHADY },
	SKINNING_SHADY       { "skinning.shady", EMBED_SKINNING_SHADY },
	SKIN_SHADY           { "skin.shady", EMBED_SKIN_SHADY },
	SKIN_MATH_SHADY      { "skin_math.shady", EMBED_SKIN_MATH_SHADY },
	CLUSTER_SHADY        { "cluster.shady", EMBED_CLUSTER_SHADY },
	SHADOW_SHADY         { "shadow.shady", EMBED_SHADOW_SHADY },
	SHADOW_CUTOUT_SHADY  { "shadow_cutout.shady", EMBED_SHADOW_CUTOUT_SHADY },
	POST_SHADY           { "post.shady", EMBED_POST_SHADY },
	LIGHTING_SHADY       { "lighting.shady", EMBED_LIGHTING_SHADY },
	LIGHTING_LTC_SHADY   { "lighting_ltc.shady", EMBED_LIGHTING_LTC_SHADY },
	LIGHTING_REFERENCE_SHADY { "lighting_reference.shady", EMBED_LIGHTING_REFERENCE_SHADY },
	MATERIAL_SHADY       { "material.shady", EMBED_MATERIAL_SHADY },
	NOISE_SHADY          { "noise.shady", EMBED_NOISE_SHADY },
	SURFACE_SHADY        { "surface.shady", EMBED_SURFACE_SHADY },
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
		// A source read off disk instead of out of the binary changes what the GPU
		// runs, and when it is the wrong file the failure names a push block
		// rather than a path — so this line is the one that explains it. It is a
		// `--debug` line because a checkout reads a dozen sources this way before
		// the first frame, and a dozen of them is the whole output of an ordinary
		// run.
		@debug_log("three: %s from %s (not the built-in)", file.name, path);
		return read_source(path, allocator);
	}

	return file.text.copy(allocator);
}

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
 Reads shader source from a path, with no search path and no fallback.

 No format check: anything wrong with the text is a compiler diagnostic with a
 line and a column, which beats anything this function could say. The SPIR-V
 magic number check lives in `shader/adapter.c3`, guarding what the compiler
 returned.

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
