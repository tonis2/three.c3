<*
 The post-processing pass, as a `ShaderDef`.

 `shaders/post.shady` is the module: the header it pushes, the four reserved
 samplers, the triangle, the depth reconstruction, and the declaration of the
 body. The body itself arrives as text - it is the script's `fragment` - exactly
 as a material's does, and the def does not care how many pieces it is.

 The push block here is a *header* plus the agent's uniforms: `PostPush` holds
 `info` and `planes` - pinned by `POST_PUSH_FIELDS` in `gpu/pipeline.c3` - and
 the generator appends the `Uniforms` member the script's declared list
 emitted, which is what fills `Post.uniforms`. At the switchover the engine
 fills this block per pass; until then this is what a test needs.
*>
module three;

import shady;

struct PostPush
{
	// `float[4]` and `float[2]` rather than the engine's `Vec4`/`Vec2` spellings
	// because this struct is not the engine's: it exists so the walker has a type
	// to lay out for the port's own test, and `POST_PUSH_FIELDS` below is the
	// contract it has to keep. At the switchover the block stops being a struct at
	// all - a post pass pushes a header followed by whatever uniforms the script
	// declared, which is a `char[PUSH_BUDGET]` and offsets, not a type.
	float[4] info;
	float[2] planes;
}

// The same pin the mesh, skin and draw structs carry in `gpu/pipeline.c3`, kept
// here because the engine's own post path writes bytes rather than this struct.
$assert @layout_matches(PostPush, POST_PUSH_FIELDS) : "PostPush no longer lays out the way POST_PUSH_FIELDS says";

macro ShaderDef post_def(String body, MaterialUniform[] uniforms = {}, MaterialTexture[] textures = {})
{
	ShaderSource[] sources = {
		{ .name = "post", .file = ShaderFile.POST_SHADY },
	};

	// The body fills `post`, the hole the module's fragment entry calls - whole
	// functions, or only the statements of `post`'s body.
	HoleFill[] fills = {
		{ .hole = "post", .region = "post_body", .text = body },
	};

	return (ShaderDef) {
		.name = "post",
		.uniform_form = UniformForm.PUSHED,
		.uniforms = uniforms,
		// The script's own samplers are bindings of the pass's own set -
		// unlike a material's, which are rows of the device-wide table - so
		// they are ordinary resources the body reads by name.
		.texture_form = TextureForm.SAMPLERS,
		.textures = textures,
		.texture_first = POST_BINDING_FIRST,
		.sources = sources,
		.fills = fills,
	};
}
