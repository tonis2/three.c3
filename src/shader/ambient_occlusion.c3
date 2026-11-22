<*
 The ambient occlusion pass, as a `ShaderDef`. `shaders/ambient_occlusion.shady`
 is the module; the push block is `AoPush` from `render/ambient_occlusion.c3`.
*>
module three;

import shady;

macro ShaderDef ambient_occlusion_def()
{
	ShaderSource[] sources = {
		{ .name = "ambient_occlusion", .file = ShaderFile.AMBIENT_OCCLUSION_SHADY },
	};

	return (ShaderDef) { .name = "ambient_occlusion", .sources = sources };
}
