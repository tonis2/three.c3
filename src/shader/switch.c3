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
	MESH_REFERENCE,
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

 `MESH` is the built-in draw path - `MeshPass.init`'s four pipelines - and it
 is on shady: `lighting_ltc.shady`, one file of `lighting` beside the shared
 `lighting.shady`, defines the `AreaAlgorithm` members the shared walk calls and
 carries the punctual and area lights with the LTC fit, and `material.shady` the
 built-in look, the base colour map and alpha test, shadows, occlusion, the
 lightmap, the environment, the debug views and the vertex colours.

 `MESH_REFERENCE` is the same files with the numeric area integration instead of
 the fit: `mesh_def`'s `reference` picks `lighting_reference.shady`, the other
 file of `lighting`, so the module declares no `ltc_lut` binding. It is the
 answer `three.pass.area_reference`
 draws with - the reference the fit is measured against - and a module of its
 own rather than a preprocessor branch because the two do not declare the same
 resources.

 `MESH_MATERIAL` is the same files assembled around a script's `shade()` body,
 and it is on shady: the body is spliced as its own region, the declared uniforms
 are emitted into the `Uniforms` the push block carries, and every declared
 texture is a name the body reads. **A body is shady text now** - `fn float3
 shade(Surface s)`, its uniforms through `s.uniforms`, a declared texture as
 `name().Sample(uv)` - which the engine's own generators emit and a user's script
 spells for itself. The two helpers a script body reached for are ported: the
 diffuse is `lambert(s, normal[, occlusion])` because the file-scope values the
 original read are `Surface` fields here, and the highlight is `specular(s)`.
 The scripted bake is this row's own second module (`bake: true`).

 `LIGHTMAP_MATERIAL` is the same half compiled as a lightmap bake: the same
 files with `MATERIAL_LIGHTMAP_BAKE` on, so `standard` answers with the baked
 lights' direct diffuse and the vertex stage places the triangle by its chart.
 It is a second module rather than a spec constant because both of those change
 the interface.

 `POST` is the post pass's scripted half - `fn float3 post(Post p)`, its
 uniforms through `p.uniforms`, its samplers declared by the def - and it is on
 shady. `TONEMAP` is the same preamble with the *engine's* own curve rather than
 a script's, and its body is passed in both spellings.

 `SHADOW_CUTOUT` is the cut-out caster and is on shady: `shadow_cutout_def`
 carries `shadow.shady`'s pose whole and adds the sampler and the fragment stage
 that cut. `LIGHTMAP` is the built-in mesh's own lightmap bake and is on shady
 too: `mesh_def` with `lightmap: true` and `built_in: true`, so the default look
 rasterises in the chart's own coordinate. It carries the LTC area file, which
 imports the shared half, because its `area_diffuse` is the polygon form factor
 the original's bake integrates; the fit table that file declares is one the
 bake never reads.
*>
const PassCompiler[ShaderPass.COUNT] PASS_COMPILERS = {
	[ShaderPass.CLUSTER] = { .compiler = ShaderCompiler.SHADY, .name = "cluster", .def = "cluster_def" },
	[ShaderPass.SKIN] = { .compiler = ShaderCompiler.SHADY, .name = "skin", .def = "skin_def" },
	[ShaderPass.SHADOW] = { .compiler = ShaderCompiler.SHADY, .name = "shadow", .def = "shadow_def" },
	[ShaderPass.SHADOW_CUTOUT] = { .compiler = ShaderCompiler.SHADY, .name = "shadow_cutout", .def = "shadow_cutout_def" },
	[ShaderPass.SKY] = { .compiler = ShaderCompiler.SHADY, .name = "sky", .def = "sky_def" },
	[ShaderPass.MESH] = { .compiler = ShaderCompiler.SHADY, .name = "mesh", .def = "mesh_def" },
	[ShaderPass.MESH_REFERENCE] = { .compiler = ShaderCompiler.SHADY, .name = "mesh_reference", .def = "mesh_def" },
	[ShaderPass.MESH_MATERIAL] = { .compiler = ShaderCompiler.SHADY, .name = "material", .def = "mesh_def" },
	[ShaderPass.POST] = { .compiler = ShaderCompiler.SHADY, .name = "post", .def = "post_def" },
	[ShaderPass.TONEMAP] = { .compiler = ShaderCompiler.SHADY, .name = "tonemap", .def = "post_def" },
	[ShaderPass.LIGHTMAP] = { .compiler = ShaderCompiler.SHADY, .name = "lightmap", .def = "mesh_def" },
	[ShaderPass.LIGHTMAP_MATERIAL] = { .compiler = ShaderCompiler.SHADY, .name = "lightmap_material", .def = "mesh_def" },
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
 sources in the def and never reads `source`. `body` and `body_shady` are the
 same story from the other side: POST and TONEMAP splice a body that is not in a
 file - a script's or the engine's - into the post def, and the two compilers
 spell a body differently often enough that the shady text is passed beside the
 Slang one. Empty `body_shady` takes `body`. `uniforms` and `textures` are the
 declared lists the def emits the regions a body reads by name from. `bake` is
 the scripted bake's second module: the material row compiles the same body with
 `MATERIAL_BAKE` on, which rasterises the mesh in uv space and shades it unlit,
 and it is the material row rather than one of its own because the body's
 spelling and the compiler are one decision. When `compiled` is given it answers
 whether a compiler actually ran, which is what `PipelineCache` counts.
*>
fn ShaderModule? compile_shader(
	ShaderPass pass,
	String source,
	String name,
	ShaderEntry[] entries,
	bool* compiled = null,
	String body = "",
	String body_shady = "",
	MaterialUniform[] uniforms = {},
	MaterialTexture[] textures = { },
	String vertex = "",
	bool bake = false)
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
				// one every material without a declaration emits. `built_in` is
				// what makes the half fold COLOR_0 the way `mesh.slang` does,
				// which a script's body would decide for itself.
				DString emitted;
				emitted.tinit(64);
				append_shady_uniforms(&emitted, {});
				ShaderModule mesh = compile_shady(
					mesh_def(DEFAULT_SHADE_SHADY, emitted.str_view(), built_in: true),
					MeshPush);
				emitted.free();
				return mesh;
			}
			case ShaderPass.MESH_REFERENCE:
			{
				// The same built-in module with the area algorithm's numeric
				// half: no fit table, no binding for one, and the quadrature the
				// fit is measured against. A module of its own because that is a
				// resource difference rather than a value.
				DString emitted;
				emitted.tinit(64);
				append_shady_uniforms(&emitted, {});
				ShaderModule reference = compile_shady(
					mesh_def(DEFAULT_SHADE_SHADY, emitted.str_view(), built_in: true, reference: true),
					MeshPush);
				emitted.free();
				return reference;
			}
			case ShaderPass.LIGHTMAP:
			{
				// The built-in material's lightmap bake: the default body, the
				// chart-space vertex stage, and the LTC half - whose
				// `area_diffuse` is the polygon form factor the original's bake
				// stores. The fit table that half declares is never read, and
				// the bake's descriptor walk binds the shared white to every
				// sampler a module declares.
				DString emitted;
				emitted.tinit(64);
				append_shady_uniforms(&emitted, {});
				ShaderModule lightmap = compile_shady(
					mesh_def(DEFAULT_SHADE_SHADY, emitted.str_view(), built_in: true, lightmap: true),
					MeshPush);
				emitted.free();
				return lightmap;
			}
			case ShaderPass.MESH_MATERIAL:
			case ShaderPass.LIGHTMAP_MATERIAL:
			{
				// A script's own half: the same files as the built-in path,
				// with `built_in: false` so the record's COLOR_0 reaches the
				// body instead of being folded into the albedo. The uniforms
				// decide their storage once - `material_spills` - and the
				// region and the push block are passed the same answer.
				//
				// The lightmap row is the same half compiled as a lightmap
				// bake: `MATERIAL_LIGHTMAP_BAKE` makes `standard` answer with
				// the baked lights' direct diffuse, and the vertex stage places
				// the triangle by its chart instead of by the camera. It is a
				// second module rather than a spec constant because both of
				// those are interface changes.
				bool as_lightmap = pass == ShaderPass.LIGHTMAP_MATERIAL;
				bool spilled = material_spills(uniforms);

				DString emitted;
				emitted.tinit(512);
				append_shady_uniforms(&emitted, uniforms, spilled);

				DString declared;
				declared.tinit(256);
				append_shady_textures(&declared, textures, MATERIAL_BINDING_FIRST, true);

				ShaderDef def = mesh_def(
					body,
					emitted.str_view(),
					vertex,
					built_in: false,
					textures: declared.str_view(),
					bake: bake && !as_lightmap,
					lightmap: as_lightmap
				);
				def.uniforms_spilled = spilled;
				ShaderModule mesh = compile_shady(def, MeshPush);
				declared.free();
				emitted.free();
				return mesh;
			}
			case ShaderPass.POST:
			case ShaderPass.TONEMAP:
			{
				// The one def whose body is not a file: a script's `post` for
				// POST, the engine's own curve for TONEMAP, spliced in ahead of
				// the fixed half. The `Uniforms` struct the body reads is emitted
				// from the declared list, the same region the walker parses, and
				// `body_shady` is the spelling to splice when the two languages
				// disagree about a body.
				DString emitted;
				emitted.tinit(256);
				append_shady_uniforms(&emitted, uniforms);

				DString declared;
				declared.tinit(256);
				append_shady_textures(&declared, textures, POST_BINDING_FIRST, false);

				String spliced = body_shady.len > 0 ? body_shady : body;
				ShaderModule post = compile_shady(
					post_def(spliced, emitted.str_view(), declared.str_view()),
					PostPush);
				declared.free();
				emitted.free();
				return post;
			}
			default:
				@advise("three: %s is set to shady but no module is wired for it", PASS_COMPILERS[pass].name);
				return SHADY_PASS_UNWIRED~;
		}
	}

	if (compiled == null) return compile_slang(source, name, entries);
	return compile_slang_cached(source, name, entries, compiled);
}
