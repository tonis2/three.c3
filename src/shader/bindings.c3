<*
 The binding numbers the engine reserves, on both sides of the shader boundary.

 These are numbers rather than names for one reason: only the pass knows what an
 image *is*, and resolving it by name would let a material claim it by declaring
 a texture called `shadow_map`. They are also the numbers from which a script's
 own declared samplers are numbered, so the two families meet at a documented
 seam rather than by coincidence.
*>
module three;

<*
 The binding index the first agent-declared sampler gets, per kind of shader.

 Two numbers that happen to be equal, and writing them as one constant is the
 mistake this comment exists to prevent. They were 1 and 1 while both shaders
 reserved one binding; 1 and 2 once a post pass reserved `prev` and `scene`; 2
 and 4 once a material reserved `base_color_map` and `shadow_map`; 3 and 4 now
 that `environment_map` is beside those two. A shared constant would mean every
 material sampler being silently renumbered by whichever *other* shader moved —
 reflection agreeing with itself the whole way, and the only symptom being
 textures arriving in the wrong slots of shaders nobody had touched.

 Nothing outside the declaration list chooses a binding index. The declaration
 order the caller passed is the binding order, generated from whichever base the
 kind of shader uses, and resolved by *name* everywhere above — which makes
 inserting a texture at the front of the list a non-event.
*>
const uint MATERIAL_BINDING_FIRST = 5;

// Where a post pass's own samplers begin: after `prev` at 0, `scene` at 1, the
// frame's depth buffer at 2 and `tap_image` at 3 — see MATERIAL_BINDING_FIRST.
// Moving this constant is the whole of a renumbering: every sampler above it is
// generated from declaration order and resolved by name.
const uint POST_BINDING_FIRST = 4;

// The third source, and a number rather than a name for `SHADOW_BINDING`'s
// reason: only the chain knows which image this is, and resolving it by name
// would let a body claim it by declaring a texture called `tap_image`.
// `POST_RESERVED` is what stops that.
const uint POST_TAP_BINDING = 3;

<*
 Where the shadow map is bound, in every shader that shades a surface.

 A number rather than a name, unlike everything a material declares, and for the
 reason `base_color_map` is reached at 0 by hand: only the pass knows what this
 image *is*, and resolving it by name would let a material claim it by declaring
 a texture called `shadow_map`. `pipeline_declares_binding` asks the reflected
 layout whether it is there, because a compiler may drop a sampler a linked
 program never reads.
*>
const uint SHADOW_BINDING = 1;

<*
 Where the environment map is bound, in every shader that shades a surface.

 `SHADOW_BINDING`'s argument, one binding along: only the pass knows this image
 is the scene's sky, and a material that declared a texture called
 `environment_map` would otherwise claim it.

 Like the shadow map it is always bound and is white when there is no sky —
 `FrameBlock.environment.x` is what says whether to read it, so shading with an
 environment and shading without one are one pipeline.
*>
const uint ENVIRONMENT_BINDING = 2;

// A six-face 2D-array depth sampler reserved for the opt-in point-light shadow pass.
const uint POINT_SHADOW_BINDING = 3;
const uint AMBIENT_OCCLUSION_BINDING = 4;
const uint SHADOW_ATLAS_BINDING = 17;
// The same atlas image again, through a depth-compare sampler. Two bindings
// because one combined image sampler is either a comparison sampler or not, and
// the debug view still wants the raw depth.
const uint SHADOW_ATLAS_COMPARE_BINDING = 18;
// The linearly transformed cosine table for area lights, uploaded once by
// `render/ltc.c3` and never per scene. Reserved on the same terms as the two
// above: a number rather than a name, so a material cannot claim it.
const uint LTC_LUT_BINDING = 19;
// The baked static light cache, one atlas for the whole scene, sampled through
// `Instance.lightmap`. Reserved on the same terms as the three above.
const uint LIGHTMAP_BINDING = 20;
const uint SHADOW_ATLAS_STATIC_COMPARE_BINDING = 21;

<*
 How many descriptors a material declares in its own set, whatever a body asks
 for.

 Seven, and all seven belong to the *frame* rather than to the surface:
 `environment_map` (2), `ambient_occlusion_depth` (4), `shadow_atlas` (17),
 `shadow_atlas_compare` (18), `ltc_lut` (19), `lightmap_atlas` (20), and the
 static shadow comparison atlas (21). Every image a material wears —
 `material.map` and everything a body declared — is a slot of the device-wide
 array at set 1 and costs this nothing.

 `shadow_atlas` is in here rather than dropped because the material half reads
 it: `shadow_debug_depth` wants the raw depth, which the comparison sampler at
 18 cannot give, and `debug_view` calls it in every linked material.

 Well inside the sixteen sampled images a conformant device must offer, and it
 stays there however large a stack gets — which is the whole claim, and what
 `three_tests::occlusion` walks nine maps to nineteen to hold down.
*>
const uint MATERIAL_FRAME_SAMPLERS = 7;

<*
 Where the built-in material's other four maps are bound, in the built-in draw
 module and nowhere else.

 **The same numbers `MATERIAL_BINDING_FIRST` hands to an agent's first samplers,
 and that is not a collision.** A binding is only ever resolved against the
 pipeline that declared it — `render/bind.c3` walks the *reflected* layout of the
 material's own shader — so binding 3 is a normal map on the built-in pipeline
 and whatever a body called its first texture on a generated one. The two never
 meet, because no material is both.

 By index rather than by name, which is `SHADOW_BINDING`'s argument again: only
 the pass knows that binding 3 is "the material's normal map", and a name would
 make `normal_map` part of the script-facing API. `MeshPass.set_material_slot` is
 the one door, and `MATERIAL_SLOT_*` is what a script names instead.
*>
const uint NORMAL_MAP_BINDING              = 5;
const uint METALNESS_ROUGHNESS_MAP_BINDING = 6;
const uint OCCLUSION_MAP_BINDING           = 7;
const uint EMISSIVE_MAP_BINDING            = 8;

// A declared row count of zero means "not a table", which is the same thing as
// one row. Written once here because the budget arithmetic, the clamp and the
// generated declaration must all agree about it.
fn uint uniform_rows_of(MaterialUniform uniform) => uniform.rows < 1 ? 1 : uniform.rows;

<*
 Is this a name a generated declaration can safely carry?

 The check is `[A-Za-z_][A-Za-z0-9_]*`. Nothing interpolated into a `#line`
 directive or a declaration may carry a quote or a backslash, and a uniform name
 reaches both.
*>
fn bool is_identifier(String name)
{
	if (name.len == 0) return false;
	foreach (i, c : name)
	{
		bool alpha = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_';
		bool digit = c >= '0' && c <= '9';
		if (!alpha && !(digit && i > 0)) return false;
	}
	return true;
}

<*
 Everything a list of sampler names can be refused for, as a sentence.

 Shared by both validators rather than written twice: the uniform rules
 genuinely differ between a material and a post pass (one has tables and a
 104-byte budget, the other neither) while these rules are the same rules with
 a different word in front of them.

 The name must not collide with a *uniform* either, which is the one check that
 could not be inferred from either list alone: a texture the module declares
 under a uniform's name is a duplicate identifier in the generated module, and
 the diagnostic would name a line of generated code the agent never wrote.

 @param prefix : `"material" or "post" — what the sentence calls the thing being built.`
 @param reserved : `The generated module's own vocabulary, which a sampler may not take either.`
 @param limit : `How many samplers this kind of shader may declare.`
 @return `The empty string when the names are usable, or the sentence to refuse them with. Allocated from tmem.`
*>
fn String texture_problem(
	String prefix,
	MaterialTexture[] textures,
	MaterialUniform[] uniforms,
	String[] reserved,
	uint limit
)
{
	// Counted first, so a script that passed eight names is told the number rather
	// than being told about the first one that also happened to be misspelled.
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

		foreach (word : reserved)
		{
			if (texture.name != word) continue;
			return string::tformat(
				"%s: texture name '%s' is reserved; the shader three.c3 generates around your body already uses it",
				prefix,
				texture.name
			);
		}

		foreach (j, earlier : textures)
		{
			if (j >= i) break;
			if (earlier.name != texture.name) continue;
			return string::tformat("%s: texture '%s' is declared twice", prefix, texture.name);
		}

		foreach (uniform : uniforms)
		{
			if (uniform.name != texture.name) continue;
			return string::tformat(
				"%s: '%s' is both a uniform and a texture; both names reach the generated module, so one would shadow the other",
				prefix,
				texture.name
			);
		}
	}

	return "";
}

<*
 Copies a refusal sentence into a fixed buffer and says how long it ended up.

 A fixed buffer rather than an allocation because the caller reads this on the
 failure path, where there is no owned value to free and no allocator in scope to
 free it with. Truncation rather than a fault: a message that is too long is
 still a better answer than no message.

 @return `How many bytes of buffer the message took.`
*>
fn usz shader_note_into(char[] buffer, String message)
{
	usz n = message.len < buffer.len ? message.len : buffer.len;
	buffer[:n] = message[:n];
	return n;
}
