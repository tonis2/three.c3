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
*>
module three;

import shady;

macro ShaderDef mesh_def(String fragment_code, String uniforms = "", String vertex_code = "")
{
	ShaderSource[] sources = {
		// The library first: `Surface`, `Vertex`, the two body declarations and
		// the built-in look. It is generated code and carries the `three.` name
		// the rest of the prologue does, which is how a diagnostic tells it from
		// the body below.
		{ "three.lighting", shader_source("lighting.shady", tmem)!! },
		{ "three.material", shader_source("material.shady", tmem)!! },

		// **The body is its own region.** `append_shader_source` brackets it
		// with `#line 1 "material"`, so a fault in it names `material` and the
		// line the author typed - not the line of the module it was spliced
		// into. The vertex body is the second one, and a material that wrote
		// none gets the empty function, so the call in `mesh.shady` is
		// unconditional and there is no second vertex path.
		{ "material", fragment_code },
		{ "vertex", vertex_code.len > 0 ? vertex_code : IDENTITY_DISPLACE_SHADY },

		{ "skinning", shader_source("skinning.shady", tmem)!! },
		{ "mesh", shader_source("mesh.shady", tmem)!! },
	};

	return (ShaderDef) { .name = "mesh", .uniforms = uniforms, .sources = sources };
}

<*
 What a material with no vertex body gets instead of one.

 An empty function rather than an absent one, so `mesh_vertex` calls `displace`
 unconditionally the way the fragment entry calls `mesh_fragment` - and every
 compiler folds the call away, so a material that moves nothing costs nothing.
 The fragment half's default is not empty (`standard(s)`), which is why this one
 is generated here and that one is a body a caller writes.
*>
const String IDENTITY_DISPLACE_SHADY @private = "fn void displace(inout Vertex v)\n{\n}\n";
