<*
 The sky pass, as a `ShaderDef`.

 `shaders/sky.shady` is the module - its stage interface, its binding, its two
 entry points and its code. This file holds the only part that is not in it: the
 push block, which is `SkyPush` from `render/sky.c3`, walked rather than declared
 a second time.

 The vertex stage is three vertices and no geometry, so the pipeline is created
 with no vertex input state at all; `VertexIn` exists only because an entry point
 takes a struct, which is shady's rule for every stage.
*>
module three;

import shady;

macro ShaderDef sky_def()
{
	ShaderSource[] sources = {
		{ "sky", shader_source("sky.shady", tmem)!! },
	};

	return (ShaderDef) { .name = "sky", .sources = sources };
}
