<*
 The draw path, as a `ShaderDef`.

 `shaders/mesh.shady` is the module: the stage interface the two halves share,
 the declaration of the material half, the entry points, and the geometry code.
 The material half is `shaders/lighting.shady`, one of its two area algorithm
 files (`lighting_ltc.shady` or `lighting_reference.shady`), and
 `shaders/material.shady`; the one part of it that has an author - the script's
 `shade()` body - arrives as text and gets a source region of its own, so a
 fault in it is reported at the line the script wrote rather than at a line in
 the assembled module.

 The pose is `shaders/skinning.shady`, shared with the shadow pass so a character
 cannot be lit in one place and shadowed in another, and the push block is
 `MeshPush`, walked from the C3 struct the pass fills.

 `built_in` is the one thing the material half cannot know about itself: the
 built-in draw path applies the record's COLOR_0 to the albedo the way
 `mesh.slang` does, and a scripted module hands the attribute to its body
 instead, which decides. The def writes that choice out as `MATERIAL_BUILT_IN`
 above the half that reads it, so it is part of the module's text and therefore
 of its pipeline's identity.

`reference` replaces the area-light algorithm: the same files with the numeric
quadrature instead of the LTC fit, and without the fit table's descriptor. It
is a def-level variant rather than a constant because the two modules do not
declare the same resources.
*>
module three;

import shady;

macro ShaderDef mesh_def(String fragment_code, String uniforms = "", String vertex_code = "", bool built_in = false, String textures = "", bool bake = false, bool lightmap = false, bool reference = false)
{
	ShaderSource[] sources = {
		// The lighting library first: the shared half and the one area
		// algorithm file that imports it. The def names a single file - the LTC
		// fit or the numeric reference - because that file's
		// `import "lighting.shady";` brings the shared half with it, and both
		// carry `module lighting;`, so the tail defines the declarations the
		// shared half writes. The two answer files differ by a descriptor, and
		// a spec constant cannot remove one, which is why the answer is not a
		// branch in the shared half.
		{ .name = "three.lighting", .file = reference
			? ShaderFile.LIGHTING_REFERENCE_SHADY
			: ShaderFile.LIGHTING_LTC_SHADY },

		// The pose and the flag bits, and then the record and built-in look in
		// `three.material`. The order is the dependency order - `material.shady`
		// reads the flags `skinning.shady` declares and the `Map`
		// `surface.shady` declares, and these constants are not forward
		// references the way a function is: `surface.shady` reads the lightmap
		// variant, so the switches stand above it.
		{ .name = "skinning", .file = ShaderFile.SKINNING_SHADY },

		// The bake and lightmap variants' own switches. A bake rasterises the
		// mesh in uv space and shades it unlit; a lightmap bake rasterises it
		// in its chart and stores the baked lights' direct diffuse. Each is a
		// module of its own - and the halves read these rather than a `#ifdef`
		// neither language has.
		{ .name = "three.bake", .source = bake
			? "const bool MATERIAL_BAKE = true;\n"
			: "const bool MATERIAL_BAKE = false;\n" },
		{ .name = "three.lightmap", .source = lightmap
			? "const bool MATERIAL_LIGHTMAP_BAKE = true;\n"
			: "const bool MATERIAL_LIGHTMAP_BAKE = false;\n" },

		{ .name = "three.surface", .file = ShaderFile.SURFACE_SHADY },

		// **The one line that tells the material half which program it is.**
		// The built-in draw path's fragment stage applies COLOR_0 to the albedo
		// the way `mesh.slang` does, because it has no body to decide; a
		// scripted module has one, so the attribute reaches it as a field and
		// the body chooses. A plain constant rather than a spec constant: these
		// are two texts with different pipelines, so the pipeline cache stays
		// keyed by the source that produced it.
		{ .name = "three.builtin", .source = built_in
			? "const bool MATERIAL_BUILT_IN = true;\n"
			: "const bool MATERIAL_BUILT_IN = false;\n" },

		{ .name = "three.material", .file = ShaderFile.MATERIAL_SHADY },

		// The names a script's textures are read by. A function per texture, so
		// the name is a `Map` built from `map_at` - a material's images are rows
		// of the device-wide table and never descriptors of their own.
		{ .name = "material_textures", .source = textures },

		// **The body is its own region.** `append_shader_source` brackets it
		// with `#line 1 "material"`, so a fault in it names `material` and the
		// line the author typed - not the line of the module it was spliced
		// into. The vertex body is the second one, and a material that wrote
		// none gets the empty function, so the call in `mesh.shady` is
		// unconditional and there is no second vertex path.
		{ .name = "material", .source = fragment_code },
		{ .name = "vertex", .source = vertex_code.len > 0 ? vertex_code : IDENTITY_DISPLACE_SHADY },

		{ .name = "mesh", .file = ShaderFile.MESH_SHADY },
	};

	return (ShaderDef) {
		.name = reference ? "mesh_reference" : (bake ? "mesh_bake" : "mesh"),
		.uniforms = uniforms,
		.sources = sources,
	};
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
