<*
 The per-pass compiler table, and the one call both implementations go through.

 While the port runs, two compilers live in this binary and a pass moves between
 them one line at a time. Which one a pass uses is data - one row per compile
 call site in `PASS_COMPILERS` - so flipping a pass is a single table edit and
 an A/B run needs no rebuild. `--shady`/`--slang`, and their environment
 variables, override a row for one run; `shader_override` is the same door for
 a test.

 `compile_shader` is what the call sites call. It consults the table, then
 reaches `compile_slang` or `compile_shady` - and it is the only place either
 is reached from for a pass.

 ## The table

 `def` names the `ShaderDef` that replaces the call site, for the passes that
 have one. The wired half is the switch in `compile_shader`, where a ported
 pass names the def and the push type it walks. A row set to shady without that
 case is a fault rather than a quiet fall back to Slang, because an override
 that does nothing is worse than one that says why.
*>
module three;

import std::io;
import std::os::env;

enum ShaderPass : char
{
	CLUSTER,
	SKIN,
	SHADOW,
	SHADOW_CUTOUT,
	SKY,
	MESH,
	MESH_MATERIAL,
	POST,
	TONEMAP,
	LIGHTMAP,
	LIGHTMAP_MATERIAL,
	COUNT,
}

enum ShaderCompiler : char
{
	SLANG,
	SHADY,
}

<*
 One compile point and the compiler the table gives it.

 `name` is the spelling `--shady`/`--slang` and `THREE_SHADY`/`THREE_SLANG`
 take; `def` is the module that replaces the call site when it is ported, empty
 while there is none.
*>
struct PassCompiler
{
	ShaderCompiler compiler;
	String name;
	String def;
}

<*
 Which implementation compiles each pass.

 `MESH` is the built-in draw path - `MeshPass.init`'s four pipelines - and it is
 *wired but not flipped*: `shaders/material.shady` carries the punctual direct
 look only, so maps, shadows, occlusion, the lightmap, the environment and the
 debug views would stop rendering the moment the built-in template changed hands.
 `test/mesh_shader_test.c3` compares the ported subset through both compilers and
 the row moves when the material half is whole. `MESH_MATERIAL` is the same files
 assembled around a script's `shade()` body, which the shady half cannot take
 yet either. Every other row is still Slang, and each names the def that will
 replace it. See the file header for what a flip takes.
*>
const PassCompiler[ShaderPass.COUNT] PASS_COMPILERS = {
	[ShaderPass.CLUSTER] = { .compiler = ShaderCompiler.SHADY, .name = "cluster", .def = "cluster_def" },
	[ShaderPass.SKIN] = { .compiler = ShaderCompiler.SHADY, .name = "skin", .def = "skin_def" },
	[ShaderPass.SHADOW] = { .compiler = ShaderCompiler.SHADY, .name = "shadow", .def = "shadow_def" },
	[ShaderPass.SHADOW_CUTOUT] = { .compiler = ShaderCompiler.SLANG, .name = "shadow_cutout", .def = "shadow_cutout_def" },
	[ShaderPass.SKY] = { .compiler = ShaderCompiler.SHADY, .name = "sky", .def = "sky_def" },
	[ShaderPass.MESH] = { .compiler = ShaderCompiler.SLANG, .name = "mesh", .def = "mesh_def" },
	[ShaderPass.MESH_MATERIAL] = { .compiler = ShaderCompiler.SLANG, .name = "material", .def = "mesh_def" },
	[ShaderPass.POST] = { .compiler = ShaderCompiler.SLANG, .name = "post", .def = "post_def" },
	[ShaderPass.TONEMAP] = { .compiler = ShaderCompiler.SLANG, .name = "tonemap", .def = "post_def" },
	[ShaderPass.LIGHTMAP] = { .compiler = ShaderCompiler.SLANG, .name = "lightmap", .def = "" },
	[ShaderPass.LIGHTMAP_MATERIAL] = { .compiler = ShaderCompiler.SLANG, .name = "lightmap_material", .def = "" },
};

faultdef SHADER_PASS_UNKNOWN, SHADY_PASS_UNWIRED;

// The per-run overrides. Cleared before anything compiles and only written by
// `apply_shader_overrides`, a test, or a caller that wants the other build.
ShaderCompiler[ShaderPass.COUNT] overrides;
bool[ShaderPass.COUNT] overridden;

fn void shader_override(ShaderPass pass, ShaderCompiler compiler)
{
	overrides[pass] = compiler;
	overridden[pass] = true;
}

fn void shader_overrides_clear()
{
	foreach (&active : overridden) *active = false;
}

fn ShaderCompiler shader_compiler(ShaderPass pass)
{
	if (overridden[pass]) return overrides[pass];
	return PASS_COMPILERS[pass].compiler;
}

fn ShaderPass? shader_pass_by_name(String name)
{
	foreach (i, entry : PASS_COMPILERS)
	{
		if (entry.name == name) return (ShaderPass)i;
	}
	return SHADER_PASS_UNKNOWN~;
}

<*
 Forces `compiler` on the comma-separated passes in `names`.

 A name that is not in the table prints the names that are and faults: a typo
 that silently left a pass on the other compiler would make an A/B run a lie.
*>
fn void? shader_override_list(String names, ShaderCompiler compiler)
{
	usz start = 0;
	while (start <= names.len)
	{
		usz end = start;
		while (end < names.len && names[end] != ',') end++;
		String name = names[start:end - start].trim();
		start = end + 1;

		if (name.len > 0)
		{
			ShaderPass? pass = shader_pass_by_name(name);
			if (catch pass)
			{
				@pool()
				{
					DString known;
					known.tinit(128);
					foreach (i, entry : PASS_COMPILERS)
					{
						if (i > 0) known.append_string(", ");
						known.append_string(entry.name);
					}
					io::printfn("three: no shader pass is called '%s'; the passes are %s", name, known.str_view());
				};
				return SHADER_PASS_UNKNOWN~;
			}
			shader_override(pass, compiler);
		}
		if (end >= names.len) break;
	}
	return;
}

<*
 Applies the run's choices, from the environment first and the flags last so a
 flag wins over an inherited variable.

 Called before anything compiles: `run` builds the draw path's pipelines while
 opening the engine, and the first compile picks the implementation for good.
*>
fn void? apply_shader_overrides(String shady, String slang)
{
	@pool()
	{
		String? env_shady = env::tget_var("THREE_SHADY");
		if (try env_shady && env_shady.len > 0) shader_override_list(env_shady, ShaderCompiler.SHADY)!;
		String? env_slang = env::tget_var("THREE_SLANG");
		if (try env_slang && env_slang.len > 0) shader_override_list(env_slang, ShaderCompiler.SLANG)!;
	};
	shader_override_list(shady, ShaderCompiler.SHADY)!;
	return shader_override_list(slang, ShaderCompiler.SLANG);
}

<*
 Compiles one pass, through whichever implementation the table names.

 `source`, `name` and `entries` are the Slang path's arguments, so a call site
 keeps the text it already has; a pass compiled through shady names its own
 sources in the def and never reads `source`. When `compiled` is given it
 answers whether a compiler actually ran, which is what `PipelineCache` counts.
*>
fn ShaderModule? compile_shader(
	ShaderPass pass,
	String source,
	String name,
	ShaderEntry[] entries,
	bool* compiled = null)
{
	if (shader_compiler(pass) == ShaderCompiler.SHADY)
	{
		if (compiled != null) *compiled = true;

		// One case per ported pass: the def, and the push block it walks.
		switch (pass)
		{
			case ShaderPass.CLUSTER:
				ShaderModule cluster = compile_shady(cluster_def(), ClusterPush);
				return cluster;
			case ShaderPass.SKIN:
				ShaderModule skin = compile_shady(skin_def(), SkinPush);
				return skin;
			case ShaderPass.SHADOW:
				ShaderModule shadow = compile_shady(shadow_def(), ShadowPush);
				return shadow;
			case ShaderPass.SHADOW_CUTOUT:
				ShaderModule cutout = compile_shady(shadow_cutout_def(), ShadowPush);
				return cutout;
			case ShaderPass.SKY:
				ShaderModule sky = compile_shady(sky_def(), SkyPush);
				return sky;
			case ShaderPass.MESH:
			{
				// The built-in material: no script wrote a body, so the spliced
				// half is `standard(s)` and the uniform set is the reserved empty
				// one every material without a declaration emits.
				DString uniforms;
				uniforms.tinit(64);
				append_shady_uniforms(&uniforms, {});
				ShaderModule mesh = compile_shady(mesh_def(DEFAULT_SHADE_SHADY, uniforms.str_view()), MeshPush);
				uniforms.free();
				return mesh;
			}
			default:
				@advise("three: %s is set to shady but no module is wired for it", PASS_COMPILERS[pass].name);
				return SHADY_PASS_UNWIRED~;
		}
	}

	if (compiled == null) return compile_slang(source, name, entries);
	return compile_slang_cached(source, name, entries, compiled);
}
