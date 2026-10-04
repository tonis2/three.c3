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
 built-in draw path applies the record's COLOR_0 to the albedo as the built-in
 look in `material.shady` does, and a scripted module hands the attribute to its
 body instead, which decides. The def writes that choice out as `MATERIAL_BUILT_IN`
 above the half that reads it, so it is part of the module's text and therefore
 of its pipeline's identity.

`reference` replaces the area-light algorithm: the same files with the numeric
quadrature instead of the LTC fit, and without the fit table's descriptor. It
is a def-level variant rather than a constant because the two modules do not
declare the same resources.
*>
module three;

import shady;

macro ShaderDef mesh_def(
	String fragment_code = "",
	MaterialUniform[] uniforms = {},
	String vertex_code = "",
	bool built_in = false,
	MaterialTexture[] textures = {},
	bool bake = false,
	bool lightmap = false,
	bool reference = false)
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
		// as `material.shady`'s built-in look does, because it has no body to
		// decide; a scripted module has one, so the attribute reaches it as a
		// field and the body chooses. A plain constant rather than a spec
		// constant: these are two texts with different pipelines, so the
		// pipeline cache stays keyed by the source that produced it.
		{ .name = "three.builtin", .source = built_in
			? "const bool MATERIAL_BUILT_IN = true;\n"
			: "const bool MATERIAL_BUILT_IN = false;\n" },

		{ .name = "three.material", .file = ShaderFile.MATERIAL_SHADY },
		{ .name = "mesh", .file = ShaderFile.MESH_SHADY },
	};

	// **The bodies are the template's holes**, filled after everything else:
	// `shade` and `displace` are `@fallback`s in `material.shady`, so a material
	// that wrote neither is the built-in look and one that wrote a vertex body
	// alone keeps the default shading. Each is its own region, so a fault in it
	// names `material` or `vertex` and the line the author typed.
	HoleFill[] fills = {
		{ .hole = "shade", .region = "material", .text = fragment_code },
		{ .hole = "displace", .region = "vertex", .text = vertex_code },
	};

	return (ShaderDef) {
		.name = reference ? "mesh_reference" : (bake ? "mesh_bake" : "mesh"),
		// Every mesh module has the set, the built-in one included: `Surface`
		// carries `Uniforms` whatever the material, so a material without
		// declarations gets the reserved empty one rather than a second struct.
		.uniform_form = material_spills(uniforms) ? UniformForm.SPILLED : UniformForm.PUSHED,
		.uniforms = uniforms,
		.texture_form = TextureForm.MAPS,
		.textures = textures,
		.texture_first = MATERIAL_BINDING_FIRST,
		.sources = sources,
		.fills = fills,
	};
}
