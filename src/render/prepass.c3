module three;

import vk;

<*
 The depth prepass: the opaque and cut-out buckets drawn depth-only before the
 scene pass, so the expensive fragment shader runs once per pixel instead of once
 per layer of overdraw.

 It draws with `shaders/shadow.shady` — the same depth-only vertex path the
 shadow map uses, against the camera's view-projection rather than a light's, so
 a vertex lands in exactly the place `shaders/mesh.shady` and `shaders/material.shady` put it.
 The two pipelines here differ from the shadow map's in one thing only: the cull
 mode is dynamic. A prepass that drew a face the colour pass culls would leave
 depth in front of geometry the colour pass never covers, which reads as a hole
 rather than as a saving.

 `MeshPass.prepassed` is the other half — which materials the prepass can speak
 for, and therefore which ones the scene pass draws with the depth test on EQUAL
 and no depth write.
*>
struct DepthPrepass
{
	// `three.depthPrepass`. On by default; a script turns it off to compare.
	bool enabled;
	// Both pipelines this frame's buckets may need are built and the pass has
	// something to draw with. Recomputed by `MeshPass.prepare`.
	bool live;
	MeshPipeline pipeline;
	MeshPipeline cutout_pipeline;
	bool ready;
	bool cutout_ready;
	// A compile that failed once is not retried every frame — the pass falls back
	// to drawing everything the way it did before the prepass existed.
	bool refused;
	bool cutout_refused;
	vk::Format format;
	// Last frame's draw calls, which is what `stats().prepassDraws` reports.
	uint draws;
}

<*
 Compiles the depth program — `shaders/shadow.shady`, depth-only or cut out —
 and builds one pipeline from it.

 Shared with `ShadowMap.build_pipeline` and `ShadowMap.build_cutout_pipeline`,
 which is the whole reason it is a free function: the shadow map and the prepass
 want the same two programs and differ only in the cull mode and the format.

 @param cutout : `The alpha-tested variant — a fragment stage that discards below material.alphaTest, and the base colour map at binding 0.`
 @param dynamic_cull : `Honour the material's own side per draw. The prepass needs it; the shadow map deliberately does not.`
 @return ? SHADER_MISSING_ENTRY_POINT : `The shader would not compile. The diagnostic is printed.`
*>
fn void? build_depth_pipeline(Gpu* gpu, MeshPipeline* pipeline, vk::Format format,
	bool cutout = false, bool dynamic_cull = false)
{
	ShaderPass pass = cutout ? ShaderPass.SHADOW_CUTOUT : ShaderPass.SHADOW;
	// Entry names are how the host tells stages apart. The cut-out module carries
	// `shadow.shady`'s depth-only `vertexMain` beside its own `cutoutVertexMain`,
	// so the list the pipeline is built from is the list the module is held to
	// and linked under.
	ShaderEntry[] entries = cutout ? SHADOW_CUTOUT_SHADY_ENTRIES[..] : SHADOW_ENTRIES[..];

	ShaderModule mod = compile_shader(pass)!;
	defer mod.free();
	if (!mod.ok)
	{
		@advise("three: the depth shader would not compile: %s", mod.diagnostic);
		return SHADER_MISSING_ENTRY_POINT~;
	}

	pipeline.init_shadow(gpu, &mod, format, entries, dynamic_cull: dynamic_cull)!;
}

<*
 Builds whichever of the two pipelines this frame still needs.

 @param cutouts : `Whether anything in the scene is drawn with material.alphaTest. The second pipeline is a compile charged to the first frame that actually asks.`
*>
fn void DepthPrepass.ensure(&self, Gpu* gpu, vk::Format format, bool cutouts)
{
	self.live = false;
	if (!self.enabled) return;

	// A format change retires both — the target is recreated on a resize and the
	// depth format could in principle follow it.
	if (self.format != format && (self.ready || self.cutout_ready))
	{
		self.free(gpu);
	}
	self.format = format;

	if (!self.ready && !self.refused)
	{
		if (catch build_depth_pipeline(gpu, &self.pipeline, format, dynamic_cull: true)) { self.refused = true; }
		else { self.ready = true; }
	}
	if (!self.ready) return;

	if (cutouts && !self.cutout_ready && !self.cutout_refused)
	{
		if (catch build_depth_pipeline(gpu, &self.cutout_pipeline, format, cutout: true, dynamic_cull: true))
		{
			self.cutout_refused = true;
		}
		else
		{
			self.cutout_ready = true;
		}
	}
	self.live = true;
}

fn void DepthPrepass.free(&self, Gpu* gpu)
{
	if (self.ready) self.pipeline.free(gpu);
	if (self.cutout_ready) self.cutout_pipeline.free(gpu);
	bool enabled = self.enabled;
	*self = { };
	self.enabled = enabled;
}
