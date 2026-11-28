<*
 The binding numbers the engine reserves, on both sides of the shader boundary.

 Numbers rather than names, because only the pass knows what each image is: a name
 would let a material or a post body take one by declaring a texture called
 `shadow_map` or `scene`. A script's own textures are numbered from its table's
 `FIRST_DECLARED`, in declaration order, and resolved by name everywhere above, so
 adding a reserved binding means moving one number in one table.
*>
module three;

import shady;

<* What every surface shader's set 0 holds for the frame. *>
constset FrameBinding : inline uint
{
	SHADOW                      = 1,
	ENVIRONMENT                 = 2,    // the sky: always bound, white without one, read when FrameBlock.environment.x says so
	POINT_SHADOW                = 3,    // six-face 2D-array depth, for the opt-in point-light shadow pass
	AMBIENT_OCCLUSION           = 4,
	SHADOW_ATLAS                = 17,   // raw depth, which the debug view reads
	SHADOW_ATLAS_COMPARE        = 18,   // the same atlas through a depth-compare sampler
	LTC_LUT                     = 19,   // the area-light table, uploaded once by render/ltc.c3
	LIGHTMAP                    = 20,   // the baked static light, one atlas per scene, sampled through Instance.lightmap
	SHADOW_ATLAS_STATIC_COMPARE = 21,
}

<*
 Rows of `DrawRecord.texture_index` that a material's images use. They are not
 descriptors: every image a material wears is a slot of the device-wide array at set 1.

 The built-in pipeline's maps and a generated pipeline's declared textures share the
 rows from 5. A row is only resolved against the pipeline that declared it, and no
 material is both.
*>
constset MaterialBinding : inline uint
{
	FIRST_DECLARED          = 5,    // a material body's first texture
	NORMAL_MAP              = 5,    // the built-in material's maps, past its base colour at 0
	METALNESS_ROUGHNESS_MAP = 6,
	OCCLUSION_MAP           = 7,
	EMISSIVE_MAP            = 8,
	HEIGHT_MAP              = 9,
}

<* Is this one of the built-in material's maps, which `set_material_slot` may write? *>
fn bool MaterialBinding.is_built_in_map(self) => self >= NORMAL_MAP && self <= HEIGHT_MAP;

<*
 A post pass's own set: the chain's sources, the pass's declared samplers, a compute
 pass's output, and the pass's storage images.

 `shaders/post_compute.shady` writes `OUTPUT` down too, and
 `the_post_compute_def_declares_output_at_its_binding` holds the two together.
*>
constset PostBinding : inline uint
{
	PREV           = 0,
	SCENE          = 1,
	DEPTH          = 2,                                     // the frame's depth buffer
	TAP            = 3,                                     // the third source: whichever pass this one names
	FIRST_DECLARED = 4,                                     // the body's samplers, POST_TEXTURE_LIMIT of them
	OUTPUT         = FIRST_DECLARED + POST_TEXTURE_LIMIT,   // a compute pass's `output` storage image
	IMAGE_FIRST    = OUTPUT + 1,                            // the pass's storage images, POST_IMAGE_LIMIT of them
}

<*
 How many storage images a post pass may declare.

 Four, because that is what Vulkan promises per stage. A compute pass's `output`
 spends one, so a portable pass that writes the frame has three; the device's own
 count is checked when the pipeline is built.
*>
const uint POST_IMAGE_LIMIT = 4;

$assert PostBinding.IMAGE_FIRST + POST_IMAGE_LIMIT <= MAX_SAMPLED_BINDINGS
	: "a post pass's images are pushed through SampledBindings, which is MAX_SAMPLED_BINDINGS wide";

<*
 How many descriptors a material declares in its own set 0, whatever its body asks for.

 All seven are the frame's: `ENVIRONMENT`, `AMBIENT_OCCLUSION`, and the five from
 `SHADOW_ATLAS` up. `SHADOW_ATLAS` counts because `debug_view` reads its raw depth in
 every linked material. Seven is well inside the sixteen sampled images a conformant
 device must offer, and `three_tests::occlusion` holds it there.
*>
const uint MATERIAL_FRAME_SAMPLERS = 7;

<*
 Is this a name a generated declaration can carry: `[A-Za-z_][A-Za-z0-9_]*`?

 A uniform name reaches a `#line` directive and a declaration, so it must not carry
 a quote or a backslash.

 @param [in] name : "The name to check"
*>
fn bool is_identifier(String name)
{
	if (name.len == 0 || name[0].is_digit()) return false;
	foreach (c : name)
	{
		if (!c.is_alnum() && c != '_') return false;
	}
	return true;
}

<*
 Everything a list of sampler names can be refused for, as a sentence.

 Shared by the material and post validators: their uniform rules differ, their
 texture rules don't. A texture and a uniform may share a name, because they never meet.

 @param [in] prefix : `"material" or "post": what the sentence calls the thing being built.`
 @param [in] textures : `The declared textures, in binding order.`
 @param [in] taken : `Names the template already declares where the samplers land; empty when they land in a struct of their own.`
 @param limit : `How many samplers this kind of shader may declare.`
 @return `The empty string when the names are usable, or the sentence to refuse them with. Allocated from tmem.`
*>
fn String texture_problem(String prefix, MaterialTexture[] textures, String[] taken, uint limit)
{
	// Counted first, so a script that passed eight names is told the number rather
	// than about the first one that also happened to be misspelled.
	if (textures.len > limit)
	{
		return string::tformat(
			"%s: %d textures were declared and a %s may have %d; a shader wanting more images than that wants an atlas, which is one texture",
			prefix,
			textures.len,
			prefix,
			limit
		);
	}

	foreach (i, texture : textures)
	{
		if (!is_identifier(texture.name))
		{
			return string::tformat(
				"%s: texture name '%s' is not an identifier; a name must match [A-Za-z_][A-Za-z0-9_]*",
				prefix,
				texture.name
			);
		}

		if (shady::is_keyword(texture.name))
		{
			return string::tformat("%s: texture name '%s' is a shady keyword", prefix, texture.name);
		}

		if (array::contains(taken, texture.name))
		{
			return string::tformat(
				"%s: texture name '%s' is reserved; the %s template already declares it",
				prefix,
				texture.name,
				prefix
			);
		}

		foreach (earlier : textures[:i])
		{
			if (earlier.name == texture.name) return string::tformat("%s: texture '%s' is declared twice", prefix, texture.name);
		}
	}

	return "";
}

<*
 Checks uniform names, uniqueness, and component widths shared by materials and
 post passes.

 @param [in] prefix : `"material" or "post": what the sentence calls the thing being built.`
 @param [in] uniforms : `The declared uniforms.`
 @return `The empty string when valid, or the refusal sentence in tmem.`
*>
fn String uniform_problem(String prefix, MaterialUniform[] uniforms)
{
	foreach (i, uniform : uniforms)
	{
		if (!is_identifier(uniform.name))
		{
			return string::tformat(
				"%s: uniform name '%s' is not an identifier; a name must match [A-Za-z_][A-Za-z0-9_]*",
				prefix,
				uniform.name
			);
		}
		if (shady::is_keyword(uniform.name))
		{
			return string::tformat("%s: uniform name '%s' is a shady keyword", prefix, uniform.name);
		}
		foreach (earlier : uniforms[:i])
		{
			if (earlier.name == uniform.name)
			{
				return string::tformat("%s: uniform '%s' is declared twice", prefix, uniform.name);
			}
		}
		if (uniform.components < 1 || uniform.components > 4)
		{
			return string::tformat(
				"%s: uniform '%s' is %d floats wide; a uniform is 1 to 4",
				prefix,
				uniform.name,
				uniform.components
			);
		}
	}
	return "";
}

<*
 Copy a refusal sentence into a fixed buffer, cut to fit.

 A fixed buffer because the caller reads it on the failure path, where there is no
 owned value to free and no allocator to free it with. A message cut short is still
 better than none.

 @param [out] buffer : "Where the message goes"
 @param [in] message : "The sentence to keep"
 @return "How many bytes of buffer the message took"
*>
fn sz shader_note_into(char[] buffer, String message)
{
	sz n = min(message.len, buffer.len);
	buffer[:n] = message[:n];
	return n;
}
