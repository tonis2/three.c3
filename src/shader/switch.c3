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
 through `s.uniforms`, a declared texture as `s.textures.name.Sample(uv)` - which the
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
	LIGHTMAP,
	LIGHTMAP_MATERIAL,
	// A script's compute post pass: `post_compute.shady` with the script's
	// entry point after it.
	POST_COMPUTE,
	// The half-resolution ambient occlusion the mesh shader reads.
	AMBIENT_OCCLUSION,
}

<*
 Compiles one pass.

 `body` is the spliced text for POST / POST_COMPUTE / MESH_MATERIAL.
 `uniforms` and `textures` are the declared lists the def emits the regions a
 body reads by name from. `bake` is the scripted bake's second module: the
 material row compiles the same body with `MATERIAL_BAKE` on, which rasterises
 the mesh in uv space and shades it unlit. `specs` are the spec-constant values
 the pipelines over this module are specialized with; they are part of the disk
 cache key, so two value sets never share an entry. When `compiled` is given it
 answers whether the compiler actually ran, which is what `PipelineCache`
 counts. `images` are a post pass's own storage images, emitted as
 `image2d<format>` declarations beside its samplers - see `ShaderDef.images`.
*>
fn ShaderModule? compile_shader(
	ShaderPass pass,
	bool* compiled = null,
	String body = "",
	MaterialUniform[] uniforms = {},
	MaterialTexture[] textures = { },
	String vertex = "",
	bool bake = false,
	ShaderSpec[] specs = { },
	ShaderImage[] images = { })
{
	// One case per pass: the def, and the push block it walks.
	switch (pass)
	{
		case ShaderPass.CLUSTER:
			return compile_shady_cached(cluster_def(), ClusterPush, compiled, specs);
		case ShaderPass.SKIN:
			return compile_shady_cached(skin_def(), SkinPush, compiled, specs);
		case ShaderPass.SHADOW:
			return compile_shady_cached(shadow_def(), ShadowPush, compiled, specs);
		case ShaderPass.SHADOW_CUTOUT:
			return compile_shady_cached(shadow_cutout_def(), ShadowPush, compiled, specs);
		case ShaderPass.SKY:
			return compile_shady_cached(sky_def(), SkyPush, compiled, specs);
		case ShaderPass.MESH:
			return compile_shady_cached(mesh_def(built_in: true), MeshPush, compiled, specs);
		case ShaderPass.MESH_REFERENCE:
			return compile_shady_cached(mesh_def(built_in: true, reference: true), MeshPush, compiled, specs);
		case ShaderPass.LIGHTMAP:
			return compile_shady_cached(mesh_def(built_in: true, lightmap: true), MeshPush, compiled, specs);
		case ShaderPass.MESH_MATERIAL:
		case ShaderPass.LIGHTMAP_MATERIAL:
			bool as_lightmap = pass == ShaderPass.LIGHTMAP_MATERIAL;
			return compile_shady_cached(
				mesh_def(
					body,
					uniforms,
					vertex,
					built_in: false,
					textures: textures,
					bake: bake && !as_lightmap,
					lightmap: as_lightmap
				),
				MeshPush, compiled, specs);
		case ShaderPass.POST:
			return compile_shady_cached(post_def(body, uniforms, textures, images), PostPush, compiled, specs);
		case ShaderPass.POST_COMPUTE:
			return compile_shady_cached(post_compute_def(body, uniforms, textures, images), PostPush, compiled, specs);
		case ShaderPass.AMBIENT_OCCLUSION:
			return compile_shady_cached(ambient_occlusion_def(), AoPush, compiled, specs);
	}
}
