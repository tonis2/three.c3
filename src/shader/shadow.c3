<*
 The shadow pass, as a `ShaderDef`.

 Two modules come out of this pair of files, one per pipeline:

 - `shaders/shadow.shady` - the stage interface, `posed_clip`, and the vertex
   entry - is the depth-only module every ordinary caster uses;
 - `shaders/shadow_cutout.shady` - its own output struct, the uv the cutters
   need, the sampler that decides, and the fragment stage that discards - is the
   one that cuts.

 The cut-out module carries `shadow.shady`'s text as well, so the pose cannot
 drift between the pipeline every caster shares and the one that cuts; what it
 does not carry is a second copy of anything. `shaders/skinning.shady` is the
 pose itself, shared with the draw path.

 The push block is `ShadowPush`, walked from the struct the pass fills, and the
 streams it points at come from `abi.c3`.
*>
module three;

import shady;

macro ShaderDef shadow_def()
{
	ShaderSource[] sources = {
		{ "skinning", shader_source("skinning.shady", tmem)!! },
		{ "shadow", shader_source("shadow.shady", tmem)!! },
	};

	return (ShaderDef) { .name = "shadow", .sources = sources };
}

macro ShaderDef shadow_cutout_def()
{
	ShaderSource[] sources = {
		{ "skinning", shader_source("skinning.shady", tmem)!! },
		{ "shadow", shader_source("shadow.shady", tmem)!! },
		{ "shadow_cutout", shader_source("shadow_cutout.shady", tmem)!! },
	};

	return (ShaderDef) { .name = "shadow_cutout", .sources = sources };
}
