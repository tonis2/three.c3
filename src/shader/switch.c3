<*
 The one compile call the passes go through.

 Every pass compiles a `ShaderDef` through shady, and the switch below is the
 mapping from a pass to that def and the push block it walks. There is no
 per-pass compiler choice left: the switch's table collapsed when the last pass
 moved and the Slang implementation was deleted, so a pass names the module it
 wants and there is nothing to select. `ShaderPass` is still the vocabulary the
 call sites and tests use, and `compile_shader` is the only door a pass compiles
 through.

 ## What each def is

 `MESH` is the built-in draw path - `MeshPass.init`'s four pipelines -
 assembled from the shaded files: `lighting_ltc.shady`, one file of `lighting`
 beside the shared `lighting.shady`, defines the `AreaAlgorithm` members the
 shared walk calls and carries the punctual and area lights with the LTC fit,
 and `material.shady` the built-in look, the base colour map and alpha test,
 shadows, occlusion, the lightmap, the environment, the debug views and the
 vertex colours.

 `MESH_REFERENCE` is the same files with the numeric area integration instead of
 the fit: `mesh_def`'s `reference` picks `lighting_reference.shady`, the other
 file of `lighting`, so the module declares no `ltc_lut` binding. It is the
 answer `three.pass.area_reference` draws with - the reference the fit is
 measured against - and a module of its own rather than a preprocessor branch
 because the two do not declare the same resources.

 `MESH_MATERIAL` is the same files assembled around a script's `shade()` body:
 the body is spliced as its own region, the declared uniforms are emitted into
 the `Uniforms` the push block carries, and every declared texture is a name the
 body reads. A body is shady text - `fn float3 shade(Surface s)`, its uniforms
 through `s.uniforms`, a declared texture as `name().Sample(uv)` - which the
 engine's own generators emit and a user's script spells for itself. The two
 helpers a script body reaches for are ported: the diffuse is
 `lambert(s, normal[, occlusion])` because the file-scope values the original
 read are `Surface` fields here, and the highlight is `specular(s)`. The
 scripted bake is this row's own second module (`bake: true`).

 `LIGHTMAP_MATERIAL` is the same half compiled as a lightmap bake: the same
 files with `MATERIAL_LIGHTMAP_BAKE` on, so `standard` answers with the baked
 lights' direct diffuse and the vertex stage places the triangle by its chart.
 It is a second module rather than a spec constant because both of those change
 the interface.

 `POST` is the post pass's scripted half - `fn float3 post(Post p)`, its
 uniforms through `p.uniforms`, its samplers declared by the def - and
 `TONEMAP` is the same preamble with the *engine's* own curve rather than a
 script's.

 `SHADOW_CUTOUT` is the cut-out caster: `shadow_cutout_def` carries
 `shadow.shady`'s pose whole and adds the sampler and the fragment stage that
 cut. `LIGHTMAP` is the built-in mesh's own lightmap bake: `mesh_def` with
 `lightmap: true` and `built_in: true`, so the default look rasterises in the
 chart's own coordinate. It carries the LTC area file, which imports the shared
 half, because its `area_diffuse` is the polygon form factor the original's
 bake integrates; the fit table that file declares is one the bake never reads.
*>
module three;

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

faultdef SHADY_PASS_UNWIRED;

<*
 Compiles one pass.

 `body` and `body_shady` are the two spellings of a spliced body for POST and
 TONEMAP - a script's or the engine's own - and empty `body_shady` takes `body`.
 `uniforms` and `textures` are the declared lists the def emits the regions a
 body reads by name from. `bake` is the scripted bake's second module: the
 material row compiles the same body with `MATERIAL_BAKE` on, which rasterises
 the mesh in uv space and shades it unlit. `specs` are the spec-constant values
 the pipelines over this module are specialized with; they are part of the disk
 cache key, so two value sets never share an entry. When `compiled` is given it
 answers whether the compiler actually ran, which is what `PipelineCache`
 counts.
*>
fn ShaderModule? compile_shader(
	ShaderPass pass,
	bool* compiled = null,
	String body = "",
	String body_shady = "",
	MaterialUniform[] uniforms = {},
	MaterialTexture[] textures = { },
	String vertex = "",
	bool bake = false,
	ShaderSpec[] specs = { })
{
	// One case per pass: the def, and the push block it walks.
	switch (pass)
	{
		case ShaderPass.CLUSTER:
			ShaderModule cluster = compile_shady_cached(cluster_def(), ClusterPush, compiled, specs);
			return cluster;
		case ShaderPass.SKIN:
			ShaderModule skin = compile_shady_cached(skin_def(), SkinPush, compiled, specs);
			return skin;
		case ShaderPass.SHADOW:
			ShaderModule shadow = compile_shady_cached(shadow_def(), ShadowPush, compiled, specs);
			return shadow;
		case ShaderPass.SHADOW_CUTOUT:
			ShaderModule cutout = compile_shady_cached(shadow_cutout_def(), ShadowPush, compiled, specs);
			return cutout;
		case ShaderPass.SKY:
			ShaderModule sky = compile_shady_cached(sky_def(), SkyPush, compiled, specs);
			return sky;
		case ShaderPass.MESH:
		{
			// The built-in material: no script wrote a body, so the spliced
			// half is `standard(s)` and the uniform set is the reserved empty
			// one every material without a declaration emits. `built_in` is
			// what makes the half fold COLOR_0 the way the original does,
			// which a script's body would decide for itself.
			DString emitted;
			emitted.tinit(64);
			append_shady_uniforms(&emitted, {});
			ShaderModule mesh = compile_shady_cached(
				mesh_def(DEFAULT_SHADE_SHADY, emitted.str_view(), built_in: true),
				MeshPush, compiled, specs);
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
			ShaderModule reference = compile_shady_cached(
				mesh_def(DEFAULT_SHADE_SHADY, emitted.str_view(), built_in: true, reference: true),
				MeshPush, compiled, specs);
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
			ShaderModule lightmap = compile_shady_cached(
				mesh_def(DEFAULT_SHADE_SHADY, emitted.str_view(), built_in: true, lightmap: true),
				MeshPush, compiled, specs);
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
			ShaderModule mesh = compile_shady_cached(def, MeshPush, compiled, specs);
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
			ShaderModule post = compile_shady_cached(
				post_def(spliced, emitted.str_view(), declared.str_view()),
				PostPush, compiled, specs);
			declared.free();
			emitted.free();
			return post;
		}
		default:
			@advise("three: no module is wired for pass %d", (int)pass);
			return SHADY_PASS_UNWIRED~;
	}
}
