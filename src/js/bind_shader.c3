<*
 The material verbs: compiling a fragment body, and pointing a node at the result.

 The same flat-verb layer as `bind_scene.c3`: numbers and strings in, numbers
 out, and every Three.js-ism written in JavaScript where the language has them.

 ## Why the uniforms cross as two joined strings

 `new three.ShaderMaterial({ uniforms: { tint: [1, 0.5, 0.2], time: 0 }, ... })`
 hands the prelude an object, and the object cannot come here: the QuickJS shim
 this project vendors exposes `qjs_get_prop` by name and nothing that enumerates
 keys. A host verb can read `uniforms.tint` only if it already knows the word
 "tint".

 So `prelude.js` does the enumerating, in the language that can, and crosses with
 `("tint,time", "3,1")` — the same shape as `setTransform` taking eleven scalars
 rather than three objects. Comma is a safe separator because a uniform name that
 is not `[A-Za-z_][A-Za-z0-9_]*` is refused by `material_source` before it can
 reach a shader.
*>
module three;

import std::collections::list;
import qjs;

<*
 Registers the material verbs on the host object.

 Called from `install_bindings` rather than being installed separately, so there
 is exactly one place that lists what JavaScript can reach.
*>
fn void JsRuntime.bind_shader_verbs(&self, qjs::Value host)
{
	self.bind(host, "createMaterial", &js_create_material, 10);
	self.bind(host, "setMaterialTexture", &js_set_material_texture, 3);
	self.bind(host, "createTextureMaterial", &js_create_texture_material, 3);
	self.bind(host, "setUniform", &js_set_uniform, 9);
	self.bind(host, "setSide", &js_set_side, 2);
	self.bind(host, "setOpacity", &js_set_opacity, 2);
	self.bind(host, "getOpacity", &js_get_opacity, 1);
	self.bind(host, "setSurface", &js_set_surface, 5);
	self.bind(host, "getSurface", &js_get_surface, 1);
	self.bind(host, "setEmissive", &js_set_emissive, 5);
	self.bind(host, "getEmissive", &js_get_emissive, 1);
	self.bind(host, "setMap", &js_set_map, 2);
	self.bind(host, "setMaterialSlot", &js_set_material_slot, 3);
	self.bind(host, "getMaterialSlot", &js_get_material_slot, 2);
	self.bind(host, "setMaterialUv", &js_set_material_uv, 5);
	self.bind(host, "getMaterialUv", &js_get_material_uv, 1);
	self.bind(host, "beginUvVariants", &js_begin_uv_variants, 1);
	self.bind(host, "addUvVariant", &js_add_uv_variant, 5);
	self.bind(host, "getUvVariants", &js_get_uv_variants, 1);
	self.bind(host, "setStochastic", &js_set_stochastic, 2);
	self.bind(host, "getStochastic", &js_get_stochastic, 1);
	self.bind(host, "setMaterial", &js_set_material, 3);
	self.bind(host, "disposeMaterial", &js_dispose_material, 1);
	self.bind(host, "beginMaterialLayers", &js_begin_material_layers, 6);
	self.bind(host, "addMaterialLayer", &js_add_material_layer, 18);
}

<*
 Splits a comma-joined list into slices of the original.

 No copies: every slice points into `text`, which the caller owns for as long as
 the result is used. Empty input is an empty list rather than one empty field,
 because a material with no uniforms is the ordinary case and `"".split(",")`
 answering `[""]` would invent one called nothing.

 `@private` rather than `@local` because `bind_post.c3` splits the same two
 joined strings for the same reason.
*>
fn void split_commas(String text, List{String}* out) @private
{
	if (text.len == 0) return;

	usz start = 0;
	foreach (i, c : text)
	{
		if (c != ',') continue;
		out.push(text[start..(usz)i - 1]);
		start = (usz)i + 1;
	}
	out.push(text[start..]);
}

<*
 `three.ShaderMaterial` — compile a fragment body and answer with its index.

 Needs a device, because a material *is* a pipeline. Unlike `raycast`, there is
 no meaningful answer without one: a material that compiled nothing would fail
 later, somewhere else.
*>
fn void js_create_material(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	if (self.renderer == null)
	{
		*out = js.raise("compiling a material needs a GPU device and this context has none");
		return;
	}

	@pool()
	{
		String fragment = arg_text(&js, argc, args, 0, tmem);
		String names    = arg_text(&js, argc, args, 1, tmem);
		String widths   = arg_text(&js, argc, args, 2, tmem);
		// A third joined list, for the same reason as the second: the shape of a
		// uniform is two numbers, and a table's row count has to cross with its
		// width or the shader declares a scalar where the script wrote a column.
		// Absent means every uniform is one row.
		String rows     = arg_text(&js, argc, args, 3, tmem);

		List{String} name_list;
		List{String} width_list;
		List{String} row_list;
		name_list.tinit(4);
		width_list.tinit(4);
		row_list.tinit(4);
		split_commas(names, &name_list);
		split_commas(widths, &width_list);
		split_commas(rows, &row_list);

		if (name_list.len() != width_list.len())
		{
			*out = js.raise("every uniform needs a value — a name arrived without one");
			return;
		}
		if (row_list.len() > 0 && row_list.len() != name_list.len())
		{
			*out = js.raise("every uniform needs a row count when any of them has one");
			return;
		}

		List{MaterialUniform} uniforms;
		uniforms.tinit(4);
		foreach (i, name : name_list)
		{
			int components = width_list[i].to_int() ?? 0;
			if (components < 1 || components > 4)
			{
				*out = js.raise(
					string::tformat("uniform '%s' must be a number or an array of two, three or four numbers", name)
				);
				return;
			}

			int declared_rows = row_list.len() > 0 ? (row_list[i].to_int() ?? 0) : 1;
			if (declared_rows < 1)
			{
				*out = js.raise(string::tformat("uniform '%s' is a table with no rows in it", name));
				return;
			}

			uniforms.push(
				{
					.name = name,
					.components = (uint)components,
					.rows = (uint)declared_rows,
				}
			);
		}

		// The diagnostic is the product here, not a side effect: a bad shader has
		// to throw a JS error carrying the Slang text, so it is collected whether
		// the compile failed or only warned, and the warning path logs rather than
		// throws.
		// 
		// Absent `side` means `SIDE_FRONT`, which is what every material meant
		// before a side could be named — `cull_for_side` maps anything it does not
		// know there too, and the prelude has already refused an unknown value.
		int side     = argc > 4 ? arg_int(&js, argc, args, 4) : SIDE_FRONT;
		// Absent means `BLENDING_NONE`, which is what every material meant before
		// one could ask to blend — and what `Material._resolveBlending` answers for
		// a script that named neither `transparent` nor `blending`.
		int blending = argc > 5 ? arg_int(&js, argc, args, 5) : BLENDING_NONE;

		// The samplers, as a fourth and fifth joined list: the names the body
		// declares, and the texture each one starts bound to. Two lists rather than
		// one because a name with no image is legal here — `-1` is `NO_TEXTURE`,
		// which is what `textures: { noise_map: null }` means: the sampler exists,
		// the body may read it, and white is what comes back.
		String texture_names = arg_text(&js, argc, args, 6, tmem);
		String texture_ids   = arg_text(&js, argc, args, 7, tmem);

		List{String} texture_name_list;
		List{String} texture_id_list;
		texture_name_list.tinit(4);
		texture_id_list.tinit(4);
		split_commas(texture_names, &texture_name_list);
		split_commas(texture_ids, &texture_id_list);

		if (texture_name_list.len() != texture_id_list.len())
		{
			*out = js.raise("every texture needs a value — a name arrived without one");
			return;
		}

		List{MaterialTexture} textures;
		textures.tinit(4);
		foreach (name : texture_name_list) textures.push({ .name = name });

		// The vertex body and how far it moves things. Absent means the identity
		// and a margin of zero. The pair travels together because a displacement
		// nobody declared a bound for is geometry that culls wrong.
		String vertex = argc > 8 ? arg_text(&js, argc, args, 8, tmem) : "";
		float bounds  = argc > 9 ? arg_float(&js, argc, args, 9) : 0;

		String diagnostic;
		uint? made = self.pass.create_material(
			&self.renderer.gpu,
			&self.renderer.target,
			fragment,
			uniforms.array_view(),
			side,
			blending,
			textures.array_view(),
			vertex,
			bounds, // Named, so an argument arriving between the bounds and the diagnostic
			// does not have to be threaded through here.
			diagnostic: &diagnostic
		);
		defer if (diagnostic.ptr != null) diagnostic.free(mem);

		if (catch err = made)
		{
			// Only built on the failure path, and only to be quoted back — see
			// `material_failure`'s note on the one diagnostic that is not enough on
			// its own.
			DString declared;
			declared.tinit();
			foreach (uniform : uniforms)
			{
				if (declared.len() > 0) declared.append_string(", ");
				declared.append_string(uniform.name);
			}
			*out = js.raise(material_failure(err, diagnostic, declared.str_view()));
			return;
		}

		if (diagnostic.len > 0)
		{
			self.log.append_string("shader: ");
			self.log.append_string(diagnostic);
			if (!diagnostic.ends_with("\n")) self.log.append_char('\n');
		}

		// Filled after the compile, because a binding index is something only the
		// compiled module knows: the names went in as a list and come back as a
		// reflected layout, and `set_material_texture` is the join.
		// 
		// A failure here disposes the material it just made. The script is about to
		// be thrown at, so nothing will ever hold the handle — and a material nobody
		// can name still holds a pipeline until the process ends.
		foreach (i, name : texture_name_list)
		{
			int texture = texture_id_list[i].to_int() ?? NO_TEXTURE;
			if (catch err = self.pass.set_material_texture(&self.renderer.gpu, made, name, texture))
			{
				// Discarded rather than `!!`: the only way this can fail is a
				// material that is not there, which is the state the dispose was
				// asking for anyway — and a panic on the failure path of a *script
				// error* would take the process down over a typed texture name.
				@catch(self.pass.dispose_material(&self.renderer.gpu, made));
				*out = js.raise(material_texture_failure(err, name));
				return;
			}
		}

		*out = qjs::int_value((int)made);
	};
}

<*
 Turns a sampler fault into a sentence an agent can act on.

 The `MATERIAL_SAMPLER_UNKNOWN` case is the one worth the words. It has two
 causes that look identical from here — a name that is not in the body at all,
 and a name that is in the body and never sampled, which Slang is free to drop
 from the module before reflection sees it — and the fix differs: one is a typo
 and the other is a line of shader that has to actually read the texture.
*>
fn String material_texture_failure(fault err, String name) @local
{
	switch (err)
	{
		case MATERIAL_SAMPLER_UNKNOWN:
			return string::tformat(
				"this material's shader has no sampler called '%s' — either the name is not the one the body uses, "
					"or the body never samples it and Slang dropped it from the module",
				name
			);
		case MATERIAL_TEXTURE_UNKNOWN:
			return string::tformat("the texture for '%s' was disposed, or came from another renderer", name);
		default:
			return string::tformat("'%s' could not be bound: %s", name, err);
	}
}

<*
 `material.textures.<name> = texture` — put an image in one of the samplers the
 body declared.

 `js_set_map` for the bindings above zero. A separate verb rather than `setMap`
 growing a name argument, because the two resolve differently: binding 0 is the
 template's and is reached through the property Three.js already calls `map`,
 while these are the agent's own and are reached by the name the agent wrote.
*>
fn void js_set_material_texture(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	@pool()
	{
		uint material = (uint)arg_int(&js, argc, args, 0);
		String name   = arg_text(&js, argc, args, 1, tmem);
		int texture   = arg_int(&js, argc, args, 2);

		Gpu* gpu = self.renderer != null ? &self.renderer.gpu : null;
		if (catch err = self.pass.set_material_texture(gpu, material, name, texture))
		{
			*out = js.raise(
				err
					== MATERIAL_UNKNOWN ? "that material cannot take a texture — it is the default material or it was disposed"
					: material_texture_failure(err, name)
			);
			return;
		}
	};
}

<*
 Turns a material fault into a sentence an agent can act on.

 The Slang diagnostic goes through verbatim when there is one — it already names
 the file, the line and the column, and `#line` has already made that line the
 one the agent wrote rather than one in the generated preamble. The validation
 faults have no diagnostic behind them, so they carry their own sentence.

 ## The one case where verbatim is not enough

 A diagnostic that still points at `three.material` is pointing at a line the
 agent did not write, and there is exactly one ordinary way to make that happen:
 every uniform is spliced in as `#define <name> (push.<name>)`, live across the
 whole module, so a helper's parameter or a local named after one of the
 material's own uniforms is rewritten and the error lands on the `#define`.

 The measured instance: a helper written `float3 ripple(float2 q, float t)` in a
 material with a `t` uniform, reported as `error[E20001]: unexpected token -->
 three.material:512:16 | #define t (push.t)` — a line the author never typed and
 a construct they never wrote. The refusals in `material_source.c3` cannot catch
 it: they check the *uniform's* name against the shader's own vocabulary, and
 this is the agent's own vocabulary colliding with the uniform, which needs the
 body parsed to see.

 So the diagnostic is kept whole and a sentence is added after it, naming the
 uniforms this material actually declares. It costs nothing on every other
 failure, because those have already been mapped onto the agent's own lines.
*>
fn String material_failure(fault err, String diagnostic, String uniforms = "") @local
{
	if (diagnostic.len > 0)
	{
		if (uniforms.len > 0 && diagnostic.contains(MATERIAL_PREAMBLE_NAME))
		{
			return string::tformat(
				"%s\n\nthat line is generated, not yours. Each uniform is spliced in as "
					"`#define <name> (push.<name>)` across the whole module, so a parameter, a local "
					"or a helper named after one of this material's uniforms (%s) is rewritten and "
					"breaks the line it was spliced into. Rename it.",
				diagnostic,
				uniforms
			);
		}
		return diagnostic;
	}

	// `material_source` leaves a sentence naming what it refused and why — which
	// uniform, which byte count — and that is strictly better than re-deriving one
	// from the fault alone.
	String noted = material_diagnostic();
	if (noted.len > 0) return noted;

	switch (err)
	{
		case MATERIAL_BODY_EMPTY:
			return "a ShaderMaterial needs a fragment body — `fragment` was empty";
		case MATERIAL_NAME_INVALID:
			return "a uniform name must be a plain identifier and must not shadow the shader's own";
		case MATERIAL_TOO_MANY_UNIFORMS:
			// Spelled from the constant rather than written out: this said "68
			// bytes, 17 floats" for as long as the budget had been 52, because a
			// number in a sentence has nothing to keep it honest.
			return string::tformat(
				"those uniforms do not fit the push block — a material has %d bytes, %d floats",
				MATERIAL_UNIFORM_BUDGET,
				MATERIAL_UNIFORM_BUDGET / 4
			);
		case MATERIAL_TOO_MANY_TEXTURES:
			return string::tformat("a material may declare %d textures of its own", MATERIAL_TEXTURE_LIMIT);
		case SHADER_COMPILE_FAILED:
			return "the material shader failed to compile and Slang said nothing about why";
		default:
			return string::tformat("the material could not be built: %s", err);
	}
}

<*
 `material.uniforms.<name> = value` — write one uniform's bytes.

 Arity nine: material, name, four floats, the count of them, and the row and row
 count for a table column. The count is passed rather than inferred from trailing
 zeroes, because `[0, 0, 0]` is a perfectly ordinary colour and guessing would
 make it a one-component write; the row count is passed for
 `Material.set_uniform`'s reason — it is what keeps the width check exact once a
 field can hold more than one value.
*>
fn void js_set_uniform(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	uint index         = (uint)arg_int(&js, argc, args, 0);
	Material* material = self.pass.material(index);
	if (material == null)
	{
		*out = js.raise("that material is not in this context");
		return;
	}

	@pool()
	{
		String name = arg_text(&js, argc, args, 1, tmem);
		float[4] values = {
			arg_float(&js, argc, args, 2),
			arg_float(&js, argc, args, 3),
			arg_float(&js, argc, args, 4),
			arg_float(&js, argc, args, 5),
		};
		int count = arg_int(&js, argc, args, 6);
		if (count < 1 || count > 4)
		{
			*out = js.raise(string::tformat("uniform '%s' wants one to four numbers", name));
			return;
		}

		// Absent means the plain case, so a caller that predates tables — a script
		// reaching for `__three.setUniform` itself — still writes the one value it
		// means to.
		int row  = argc > 7 ? arg_int(&js, argc, args, 7) : 0;
		int rows = argc > 8 ? arg_int(&js, argc, args, 8) : 1;
		if (rows < 1) rows = 1;
		if (row < 0 || row >= rows)
		{
			*out = js.raise(
				string::tformat(
					"uniform '%s' has %d row%s and row %d is not one of them",
					name,
					rows,
					rows == 1 ? "" : "s",
					row
				)
			);
			return;
		}

		if (catch err = material.set_uniform(name, values[:count], (uint)row, (uint)rows))
		{
			*out = js.raise(
				err == MATERIAL_UNIFORM_WIDTH ? string::tformat(
					"uniform '%s' was declared with a different number of components",
					name
				)
					: string::tformat("this material has no uniform called '%s'", name)
			);
			return;
		}
	};
}

<*
 `material.side = ...` — change which faces this material keeps.

 A verb rather than a uniform because which faces survive is render state and not
 a byte in the push block — but it needs no device and can build nothing, because
 the cull mode is dynamic. A material's side is one `vk::cmdSetCullMode` at
 record time, so flipping it in an animation callback costs nothing.
*>
fn void js_set_side(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	uint index = (uint)arg_int(&js, argc, args, 0);
	int side   = arg_int(&js, argc, args, 1);

	if (catch self.pass.set_material_side(index, side))
	{
		*out = js.raise("that material is not in this context");
		return;
	}
}

<*
 `material.opacity = 0.5` — how much of what is behind this material shows
 through it.

 A verb rather than a uniform, and unlike `material.side` it is not render state
 either: it is one float in the push block, written into `base_color.a` at record
 time. So it is free to animate — no pipeline, no device, no rebuild — which is
 the whole reason it is settable while `blending` is not.

 It does nothing unless the material was built transparent. An opaque pipeline
 discards the alpha the fragment writes, so setting this on a material that never
 asked to blend changes a number and no pixels. That is the hardware's answer
 rather than a rule anybody chose, and it is Three.js's behaviour as well;
 refusing the write instead would make the two APIs disagree about a line an
 agent is very likely to write from memory.

 The prelude has already refused a value outside 0..1 by name.
*>
fn void js_set_opacity(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	uint index = (uint)arg_int(&js, argc, args, 0);
	if (catch self.pass.set_material_opacity(index, arg_float(&js, argc, args, 1)))
	{
		// `js_dispose_material`'s sentence, because it is the same pair of mistakes:
		// an index this context never handed out, or one of the two built-ins, which
		// belong to every node that never asked for a material.
		*out = js.raise("that material is not in this context, or it is a built-in one that every node shares");
		return;
	}
}

<*
 `material.opacity` — what it reads back as.

 An index that names nothing answers 1.0 rather than throwing, which is
 `getMaterialUv`'s rule: a getter should answer what a material that was never
 asked for anything would answer. The prelude's `_index()` has already thrown for
 a disposed handle before this is reached.
*>
fn void js_get_opacity(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	*out = qjs::number_value((double)self.pass.material_opacity((uint)arg_int(&js, argc, args, 0)));
}

<*
 `material.roughness` / `.metalness` / `.reflectance` — how the light behaves
 where it lands, as opposed to what colour it finds there.

 One verb for the three, because they are one `float4` in the draw record and
 setting them separately would be three crossings to write one value. Free to
 animate for `js_set_opacity`'s reason — nothing is rebuilt.

 **A material nobody touches is `{1, 0, 0}`, and that is a surface with no
 highlight at all.** The specular term is off until a script asks; the argument
 for that default is in `scene/material.c3` and it is the same argument shadows
 being off by default rests on.

 The prelude has already refused a value outside 0..1 by name.
*>
fn void js_set_surface(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	uint index = (uint)arg_int(&js, argc, args, 0);
	if (catch self.pass.set_material_surface(
		index,
		arg_float(&js, argc, args, 1),
		arg_float(&js, argc, args, 2),
		arg_float(&js, argc, args, 3),
		arg_float(&js, argc, args, 4)
	))
	{
		*out = js.raise("that material is not in this context, or it is a built-in one that every node shares");
	}
}

<*
 `material.roughness`, `.metalness`, `.reflectance` and `.alphaTest` — what they
 read back as, as `[roughness, metalness, reflectance, alphaTest]`.

 An index that names nothing answers the defaults rather than throwing, which is
 `getOpacity`'s rule.
*>
fn void js_get_surface(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	float[4] surface = self.pass.material_surface((uint)arg_int(&js, argc, args, 0));
	qjs::Value list  = js.array();
	// All four, which is the whole record field: `alphaTest` is `w` and is read
	// back exactly as the other three are.
	for (uint i = 0; i < 4; i++) js.set_index(list, i, qjs::number_value(surface[i]));
	*out = list;
}

<*
 `material.emissive` and `material.emissiveIntensity` — what this surface gives
 off regardless of any light.

 One verb for the four, for `js_set_surface`'s reason: they are one `float4` in
 the draw record, and a lamp is a colour and how bright it is rather than two
 unrelated statements.

 The prelude has already refused a colour outside 0..1. The intensity is not
 clamped and that is the point of having it: a colour is a colour, and this is how
 something goes brighter than white.
*>
fn void js_set_emissive(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	uint index = (uint)arg_int(&js, argc, args, 0);
	if (catch self.pass.set_material_emissive(
		index,
		arg_float(&js, argc, args, 1),
		arg_float(&js, argc, args, 2),
		arg_float(&js, argc, args, 3),
		arg_float(&js, argc, args, 4)
	))
	{
		*out = js.raise("that material is not in this context, or it is a built-in one that every node shares");
	}
}

<*
 `material.emissive` and `.emissiveIntensity`, as `[r, g, b, intensity]`.

 An index that names nothing answers black at strength 1, which is
 `getSurface`'s rule.
*>
fn void js_get_emissive(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	float[4] emissive = self.pass.material_emissive((uint)arg_int(&js, argc, args, 0));
	qjs::Value list   = js.array();
	for (uint i = 0; i < 4; i++) js.set_index(list, i, qjs::number_value(emissive[i]));
	*out = list;
}

<*
 `material.repeat = [u, v]` / `material.offset = [u, v]` — how the image is laid
 across the surface.

 One verb for both, because they are one `float4` in the push block and setting
 them separately would be two host crossings to write two halves of the same
 sixteen bytes.

 It is a material property rather than a texture property because textures here
 are deduplicated by content across every file, so a transform on the texture
 would reach every unrelated surface that happened to use the same image.
*>
fn void js_set_material_uv(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	uint index = (uint)arg_int(&js, argc, args, 0);
	if (catch err = self.pass.set_material_uv(
		index,
		arg_float(&js, argc, args, 1),
		arg_float(&js, argc, args, 2),
		arg_float(&js, argc, args, 3),
		arg_float(&js, argc, args, 4)
	))
	{
		if (err == MATERIAL_REPEAT_IS_ZERO)
		{
			*out = js.raise(
				"material.repeat cannot be zero — every point of the surface would sample the same texel. "
					"1 is once across, 4 is four times"
			);
			return;
		}
		*out = js.raise("that material is not in this context");
		return;
	}
}

<*
 `[repeat_u, repeat_v, offset_u, offset_v]` for a material.
*>
fn void js_get_material_uv(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	float[4] uv     = self.pass.material_uv((uint)arg_int(&js, argc, args, 0));
	qjs::Value four = js.array();
	for (uint i = 0; i < 4; i++) js.set_index(four, i, qjs::number_value((double)uv[i]));
	*out = four;
}

<*
 `material.uvVariants = [...]` — start the table over.

 Two verbs and not one, which is `beginMaterialLayers` and `addMaterialLayer`'s
 shape and for its reason: eight rows of four numbers is thirty-two arguments,
 and a host verb takes scalars. Clearing first is what makes assigning a shorter
 list actually shorter rather than a shorter list with somebody else's tail on
 the end of it.
*>
fn void js_begin_uv_variants(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	if (catch self.pass.begin_material_uv_variants((uint)arg_int(&js, argc, args, 0)))
	{
		*out = js.raise("that material is not in this context");
	}
}

<*
 One row of it: `[offsetU, offsetV, turns, flip]`.

 @param [in] args : `(material, offsetU, offsetV, turns, flip).`
*>
fn void js_add_uv_variant(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	if (catch self.pass.add_material_uv_variant(
		(uint)arg_int(&js, argc, args, 0),
		arg_float(&js, argc, args, 1),
		arg_float(&js, argc, args, 2),
		arg_float(&js, argc, args, 3),
		arg_float(&js, argc, args, 4)
	))
	{
		*out = js.raise("that material is not in this context");
	}
}

<*
 The table back, flat: four numbers a row, and an empty array for a material with
 no table. The prelude cuts it back into rows.
*>
fn void js_get_uv_variants(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	@pool()
	{
		float[] rows   = self.pass.material_uv_variants((uint)arg_int(&js, argc, args, 0));
		qjs::Value list = js.array();
		foreach (i, value : rows) js.set_index(list, (uint)i, qjs::number_value((double)value));
		*out = list;
	};
}

<*
 `material.stochastic = true` — sample this material's maps so they stop
 repeating.

 @param [in] args : `(material, on).`
*>
fn void js_set_stochastic(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	if (catch self.pass.set_material_stochastic(
		(uint)arg_int(&js, argc, args, 0),
		arg_int(&js, argc, args, 1) != 0
	))
	{
		*out = js.raise("that material is not in this context");
	}
}

<*
 What it reads back as.
*>
fn void js_get_stochastic(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	*out = qjs::bool_value(self.pass.material_stochastic((uint)arg_int(&js, argc, args, 0)));
}

<*
 `new three.MeshLambertMaterial({ map })` — the built-in shader, with an image.

 Needs no device *for a compile*, because there is nothing to compile: the
 pipeline is the one the pass built at startup. It still needs one to have got
 here at all, since the only source of a texture index is `three.texture`, which
 refuses a runtime with no GPU by name. So the check below is about the texture
 and not about the device.

 @param [in] args : `(texture, side, blending).`
*>
fn void js_create_texture_material(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	int texture  = arg_int(&js, argc, args, 0);
	// Absent means `SIDE_FRONT`, matching `js_create_material`.
	int side     = argc > 1 ? arg_int(&js, argc, args, 1) : SIDE_FRONT;
	// And absent means `BLENDING_NONE`, for the same reason. The pass has all
	// three variants of the built-in pipeline built already.
	int blending = argc > 2 ? arg_int(&js, argc, args, 2) : BLENDING_NONE;

	uint? made = self.pass.create_texture_material(texture, side, blending);
	if (catch made)
	{
		*out = js.raise("that texture is not in this context — it was disposed, or it came from another renderer");
		return;
	}

	*out = qjs::int_value((int)made);
}

<*
 `material.dispose()` — give back the reference the script's handle holds.

 The prelude has already refused a second call on the same handle, so what
 reaches here is either a live material or a mistake. The mistake it can still be
 is a built-in one, refused with `setSide`'s sentence for `setSide`'s reason:
 `DEFAULT_MATERIAL` belongs to every node that never asked for a material.

 What this does *not* do is free anything on its own. See
 `MeshPass.dispose_material`.
*>
fn void js_dispose_material(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	uint index = (uint)arg_int(&js, argc, args, 0);

	Gpu* gpu = self.renderer == null ? null : &self.renderer.gpu;
	if (catch self.pass.dispose_material(gpu, index))
	{
		*out = js.raise("that material is not in this context, or it is a built-in one that every node shares");
		return;
	}
}

<*
 `material.map = texture` — or `material.map = null`, which is `NO_TEXTURE`.

 The two refusals are told apart in the message rather than flattened into one,
 because they are different mistakes: a built-in material is one a script may not
 texture at all, and a dead texture is one it may not texture *with*.
*>
fn void js_set_map(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	uint index  = (uint)arg_int(&js, argc, args, 0);
	// The prelude sends `NO_TEXTURE` for a cleared map, so absent and cleared are
	// the same thing here and neither is a texture index.
	int texture = argc > 1 ? arg_int(&js, argc, args, 1) : NO_TEXTURE;

	Gpu* gpu = self.renderer == null ? null : &self.renderer.gpu;
	if (catch err = self.pass.set_material_map(gpu, index, texture))
	{
		*out = js.raise(
			err
				== MATERIAL_TEXTURE_UNKNOWN ? "that texture is not in this context — it was disposed, or it came from another renderer"
				: "that material is not in this context, or it is a built-in one that every node shares"
		);
		return;
	}
}

<*
 `material.normalMap = texture`, `.metalnessRoughnessMap` and `.aoMap` — the
 built-in material's three maps past its base colour.

 One verb for the three, keyed by a slot number, because they differ only in
 which binding they land in — `MATERIAL_SLOT_*` in `scene/material.c3` is what
 the prelude names and `NORMAL_MAP_BINDING` is where those become bindings.

 The three refusals are told apart in the message, because they are three
 different mistakes: a dead texture is one the material may not use, a built-in
 material is one a script may not touch at all, and a `ShaderMaterial` is one
 whose samplers belong to the body its author wrote.

 @param [in] args : `(material, slot, texture).`
*>
fn void js_set_material_slot(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	uint index  = (uint)arg_int(&js, argc, args, 0);
	int slot    = arg_int(&js, argc, args, 1);
	// The prelude sends `NO_TEXTURE` for a cleared map, exactly as `setMap` does.
	int texture = argc > 2 ? arg_int(&js, argc, args, 2) : NO_TEXTURE;

	Gpu* gpu = self.renderer == null ? null : &self.renderer.gpu;
	if (catch err = self.pass.set_material_slot(gpu, index, slot, texture))
	{
		if (err == MATERIAL_TEXTURE_UNKNOWN)
		{
			*out = js.raise(
				"that texture is not in this context — it was disposed, or it came from another renderer"
			);
			return;
		}
		if (err == MATERIAL_SAMPLER_UNKNOWN)
		{
			*out = js.raise(
				"normalMap, metalnessRoughnessMap and aoMap are the built-in material's — "
					"a ShaderMaterial declares its own samplers and fills them through material.textures"
			);
			return;
		}
		*out = js.raise("that material is not in this context, or it is a built-in one that every node shares");
		return;
	}
}

<*
 Which texture is in one of those three slots, or -1.
*>
fn void js_get_material_slot(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	uint index = (uint)arg_int(&js, argc, args, 0);
	int slot   = arg_int(&js, argc, args, 1);
	*out = qjs::int_value(self.pass.material_slot(index, slot));
}

<*
 `mesh.material = mat` — point a node at a material.

 The material index is validated here rather than in `Scene.set_material`: the
 scene graph has no view of `MeshPass.materials`, and giving it one would put the
 render pass inside the scene. The draw loop skips a bucket whose material does
 not resolve, so an index that slipped through would be silence rather than a
 crash.
*>
fn void js_set_material(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	NodeRef ref = arg_handle(self, &js, argc, args, 0, out);
	if (ref.scene == null) return;

	uint material = (uint)arg_int(&js, argc, args, 2);
	if (self.pass.material(material) == null)
	{
		*out = js.raise("that material is not in this context");
		return;
	}

	// Materials are the pass's and are shared by every scene, so only the node
	// side of this needs the scene it came from.
	ref.scene.set_material(ref.id, material);
}

<*
 `beginMaterialLayers(material, sharedMask)` — start recording what a
 `LayeredMaterial` *is*.

 Everything else on this file's surface crosses in one direction: a description
 goes in and a compiled pipeline comes out, and the description is not needed
 again. A layer stack is the exception, because `scene.export` has to write the
 stack back into a `.glb` and cannot get it out of the Slang the generator
 emitted — "this layer multiplies" is a choice of expression by then, and
 `CUSTOM_materials_layers` wants the word.

 So the stack crosses twice: once as a shader, through `createMaterial`, and once
 as a description, through this and `addMaterialLayer`. `ScriptLayer` in
 `scene/material.c3` is what the second crossing builds.

 Only `LayeredMaterial` calls this, and it calls it for every stack including an
 empty one. A hand-written `ShaderMaterial` that happens to sample four textures
 is not a layer stack and does not claim to be one.

 `sharedMask` is the sampler several layers read a channel of, or `""` for a
 stack where no two share one. `baseNormal` is the stack's base normal map, which
 becomes the glTF material's own `normalTexture` rather than any layer's, and
 `baseHeight` with the bump pair beside it is the relief under the whole stack —
 the extension's `base` object, which is the only place a height map can go
 because core glTF has no slot for one.
*>
fn void js_begin_material_layers(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	@pool()
	{
		Material* material = self.pass.material((uint)arg_int(&js, argc, args, 0));
		if (material == null)
		{
			*out = js.raise("that material is not in this context");
			return;
		}

		String shared      = arg_text(&js, argc, args, 1, tmem);
		String base_normal = arg_text(&js, argc, args, 2, tmem);
		String base_height = arg_text(&js, argc, args, 3, tmem);
		material.begin_script_layers(
			shared.len == 0 ? 0 : material.binding_of_texture(shared),
			base_normal.len == 0 ? 0 : material.binding_of_texture(base_normal),
			base_height.len == 0 ? 0 : material.binding_of_texture(base_height),
			(float)arg_number(&js, argc, args, 4),
			(float)arg_number(&js, argc, args, 5)
		);
	};
}

<*
 `addMaterialLayer(material, name, samplers, blend, maskSource, maskChannel,
 invert, opacity, r, g, b, er, eg, eb, metallic, roughness, bumpStrength,
 bumpDistance)` — one layer of the stack.

 `samplers` is `"map,normal,emissive,mask,params,metallicRoughness,height"`, each
 field a sampler name the
 generator chose or empty for a slot the layer does not use — the same shape the
 uniforms take, and safe for the same reason: these are names
 `js/prelude/layers.js` generates as `layer3_map`, so a comma cannot appear in
 one. The layer's own `name` is a separate argument precisely because it *is*
 free text, and joining it with the rest is how a layer called "rock, wet" would
 have become two fields.

 Names rather than binding numbers, because the resolution belongs on this side:
 `Material.binding_of_texture` asks the material's own reflected pipeline, which
 is the only thing that actually knows.

 `params` is the uniform holding an `animated` layer's tint and opacity, resolved
 to a push offset once here and read live at export.

 The blend mode, mask source and mask channel arrive as `gltf.c3l`'s own
 ordinals, untranslated, exactly as `meshLayers` hands them the other way.
*>
fn void js_add_material_layer(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	@pool()
	{
		Material* material = self.pass.material((uint)arg_int(&js, argc, args, 0));
		if (material == null)
		{
			*out = js.raise("that material is not in this context");
			return;
		}

		List{String} samplers;
		samplers.init(tmem, 7);
		split_commas(arg_text(&js, argc, args, 2, tmem), &samplers);

		ScriptLayer layer = {
			.name = arg_text(&js, argc, args, 1, tmem),
			.map_binding = binding_at(material, &samplers, 0),
			.normal_binding = binding_at(material, &samplers, 1),
			.emissive_binding = binding_at(material, &samplers, 2),
			.mask_binding = binding_at(material, &samplers, 3),
			.params_offset = samplers.len() > 4 && samplers[4].len > 0 ? material.uniform_offset(samplers[4]) : -1,
			.mr_binding = binding_at(material, &samplers, 5),
			.height_binding = binding_at(material, &samplers, 6),
			.blend_mode = (uint)arg_int(&js, argc, args, 3),
			.mask_source = (uint)arg_int(&js, argc, args, 4),
			.mask_channel = (uint)arg_int(&js, argc, args, 5),
			.invert = arg_truth(&js, argc, args, 6),
			.opacity = (float)arg_number(&js, argc, args, 7),
			.tint = {
				(float)arg_number(&js, argc, args, 8),
				(float)arg_number(&js, argc, args, 9),
				(float)arg_number(&js, argc, args, 10),
			},
			.emissive_factor = {
				(float)arg_number(&js, argc, args, 11),
				(float)arg_number(&js, argc, args, 12),
				(float)arg_number(&js, argc, args, 13),
			},
			.metallic = (float)arg_number(&js, argc, args, 14),
			.roughness = (float)arg_number(&js, argc, args, 15),
			.bump_strength = (float)arg_number(&js, argc, args, 16),
			.bump_distance = (float)arg_number(&js, argc, args, 17),
		};
		material.add_script_layer(layer);
	};
}

// One sampler name of the joined list, as a binding. Zero for a field that is
// absent or empty, which is what `TextureSlots.at` reads as "no such sampler".
fn uint binding_at(Material* material, List{String}* names, sz at) @local
{
	if (at >= (sz)names.len() || names.get(at).len == 0) return 0;
	return material.binding_of_texture(names.get(at));
}