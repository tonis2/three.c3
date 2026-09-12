<*
 The draw path, as a `ShaderDef`.

 `shaders/mesh.shady` is the module: the stage interface the two halves share,
 the declaration of the material half, the entry points, and the geometry code.
 The material half is `shaders/lighting.shady` and `shaders/material.shady`, and
 the one part of it that has an author - the script's `shade()` body - arrives as
 text and gets a source region of its own, so a fault in it is reported at the
 line the script wrote rather than at a line in the assembled module.

 The pose is `shaders/skinning.shady`, shared with the shadow pass so a character
 cannot be lit in one place and shadowed in another, and the push block is
 `MeshPush`, walked from the C3 struct the pass fills.

 `built_in` is the one thing the material half cannot know about itself: the
 built-in draw path applies the record's COLOR_0 to the albedo the way
 `mesh.slang` does, and a scripted module hands the attribute to its body
 instead, which decides. The def writes that choice out as `MATERIAL_BUILT_IN`
 above the half that reads it, so it is part of the module's text and therefore
 of its pipeline's identity.
*>
module three;

import shady;

macro ShaderDef mesh_def(String fragment_code, String uniforms = "", String vertex_code = "", bool built_in = false)
{
	ShaderSource[] sources = {
		// The library first: the lighting `shade_lights` reads, the pose and
		// the flag bits, the texture array a map lives in, and then the
		// record and built-in look in `three.material`. The order is the
		// dependency order - `material.shady` reads the flags `skinning.shady`
		// declares and the `Map` `surface.shady` declares, and a constant is
		// not a forward reference the way a function is.
		{ "three.lighting", shader_source("lighting.shady", tmem)!! },
		{ "skinning", shader_source("skinning.shady", tmem)!! },
		{ "three.surface", shader_source("surface.shady", tmem)!! },

		// **The one line that tells the material half which program it is.**
		// The built-in draw path's fragment stage applies COLOR_0 to the albedo
		// the way `mesh.slang` does, because it has no body to decide; a
		// scripted module has one, so the attribute reaches it as a field and
		// the body chooses. A plain constant rather than a spec constant: these
		// are two texts with different pipelines, so the pipeline cache stays
		// keyed by the source that produced it.
		{ "three.builtin", built_in
			? "const bool MATERIAL_BUILT_IN = true;\n"
			: "const bool MATERIAL_BUILT_IN = false;\n" },

		{ "three.material", shader_source("material.shady", tmem)!! },

		// **The body is its own region.** `append_shader_source` brackets it
		// with `#line 1 "material"`, so a fault in it names `material` and the
		// line the author typed - not the line of the module it was spliced
		// into. The vertex body is the second one, and a material that wrote
		// none gets the empty function, so the call in `mesh.shady` is
		// unconditional and there is no second vertex path.
		{ "material", fragment_code },
		{ "vertex", vertex_code.len > 0 ? vertex_code : IDENTITY_DISPLACE_SHADY },

		{ "mesh", shader_source("mesh.shady", tmem)!! },
	};

	return (ShaderDef) { .name = "mesh", .uniforms = uniforms, .sources = sources };
}

<*
 What a material with no script gets as its `shade()` body: the built-in look,
 which is what `mesh.slang` computes for itself when nothing replaces it. It is
 passed with `built_in: true`, because the fragment half has to fold the record's
 COLOR_0 into the albedo and the alpha for exactly that shader's answer.
*>
const String DEFAULT_SHADE_SHADY @private = "fn float3 shade(Surface s)\n{\n\treturn standard(s);\n}\n";

<*
 What a material with no vertex body gets instead of one.

 An empty function rather than an absent one, so `mesh_vertex` calls `displace`
 unconditionally the way the fragment entry calls `mesh_fragment` - and every
 compiler folds the call away, so a material that moves nothing costs nothing.
 The fragment half's default is not empty (`standard(s)`), which is why this one
 is generated here and that one is a body a caller writes.
*>
const String IDENTITY_DISPLACE_SHADY @private = "fn void displace(inout Vertex v)\n{\n}\n";
