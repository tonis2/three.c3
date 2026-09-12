<*
 The draw path, as a `ShaderDef`.

 `shaders/mesh.shady` is the module: the stage interface the two halves share,
 the declaration of the material half, the entry points, and the geometry code.
 The fragment half is not this file's to write - it is the surface library, the
 material records and whichever `shade()` body a script attached - so it arrives
 as text, defines the function `mesh.shady` declares, and the def splices it in
 ahead of the module.

 The pose is `shaders/skinning.shady`, shared with the shadow pass so a character
 cannot be lit in one place and shadowed in another, and the push block is
 `MeshPush`, walked from the C3 struct the pass fills.
*>
module three;

import shady;

macro ShaderDef mesh_def(String fragment_code)
{
	ShaderSource[] sources = {
		// The material half first: it defines `mesh_fragment`, which the module's
		// fragment entry calls.
		{ "material", fragment_code },
		{ "skinning", shader_source("skinning.shady", tmem)!! },
		{ "mesh", shader_source("mesh.shady", tmem)!! },
	};

	return (ShaderDef) { .name = "mesh", .sources = sources };
}
