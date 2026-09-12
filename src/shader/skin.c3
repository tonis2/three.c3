<*
 Compute skinning, as a `ShaderDef`.

 `shaders/skin.shady` is the module: the constants, the two functions, and the
 dispatch. This file holds the push block - `SkinPush`, walked - and the
 `SkinnedVertex` and `MorphDelta` streams come from `abi.c3`'s wire list, which
 is itself walked from the C3 structs.
*>
module three;

import shady;

macro ShaderDef skin_def()
{
	ShaderSource[] sources = {
		{ "skin", shader_source("skin.shady", tmem)!! },
	};

	return (ShaderDef) { .name = "skin", .sources = sources };
}
