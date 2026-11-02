<*
 The material verbs: compiling a fragment body, and pointing a node at the result.

 The same flat-verb layer as `bind_scene.c3`: numbers and strings in, numbers
 out, and every Three.js-ism written in JavaScript where the language has them.

 The uniforms arrive as `{ tint: [3, 1], time: [1, 1] }` — each name with its
 width and row count, worked out by `uniformShape` in `prelude/shader.js`, which
 owns the sentences a badly shaped value gets. The samplers arrive as
 `{ noise_map: textureIndex }`, with `NO_TEXTURE` for one that starts white.
*>
module three;

import std::collections::list;
import std::math;
import fastjs::js;

<*
 Registers the material verbs on the host object.

 Called from `install_bindings` rather than being installed separately, so there
 is exactly one place that lists what JavaScript can reach.
*>
fn void? JsRuntime.bind_shader_verbs(&self, js::Value host)
{
	self.js.@bind(host, "createMaterial", &js_create_material, self)!;
	self.js.@bind(host, "setMaterialTexture", &js_set_material_texture, self)!;
	self.js.@bind(host, "createTextureMaterial", &js_create_texture_material, self)!;
	self.js.@bind(host, "setUniform", &js_set_uniform, self)!;
	self.js.@bind(host, "setSide", &js_set_side, self)!;
	self.js.@bind(host, "setOpacity", &js_set_opacity, self)!;
	self.js.@bind(host, "getOpacity", &js_get_opacity, self)!;
	self.js.@bind(host, "setSurface", &js_set_surface, self)!;
	self.js.@bind(host, "getSurface", &js_get_surface, self)!;
	self.js.@bind(host, "setEmissive", &js_set_emissive, self)!;
	self.js.@bind(host, "getEmissive", &js_get_emissive, self)!;
	self.js.@bind(host, "setRelief", &js_set_relief, self)!;
	self.js.@bind(host, "getRelief", &js_get_relief, self)!;
	self.js.@bind(host, "setMap", &js_set_map, self)!;
	self.js.@bind(host, "setMaterialSlot", &js_set_material_slot, self)!;
	self.js.@bind(host, "setMaterialUv", &js_set_material_uv, self)!;
	self.js.@bind(host, "getMaterialUv", &js_get_material_uv, self)!;
	self.js.@bind(host, "beginUvVariants", &js_begin_uv_variants, self)!;
	self.js.@bind(host, "addUvVariant", &js_add_uv_variant, self)!;
	self.js.@bind(host, "getUvVariants", &js_get_uv_variants, self)!;
	self.js.@bind(host, "setStochastic", &js_set_stochastic, self)!;
	self.js.@bind(host, "getStochastic", &js_get_stochastic, self)!;
	self.js.@bind(host, "setMaterial", &js_set_material, self)!;
	self.js.@bind(host, "disposeMaterial", &js_dispose_material, self)!;
	self.js.@bind(host, "beginMaterialLayers", &js_begin_material_layers, self)!;
	self.js.@bind(host, "addMaterialLayer", &js_add_material_layer, self)!;
}

<*
 Throws `what needs a GPU device` when the context has none.

 @return? js::THREW
*>
fn void? JsRuntime.require_gpu(&self, String what)
{
	if (self.renderer == null) return self.js.fail("%s needs a GPU device and this context has none", what)~;
}

<*
 `{ name: [width, rows] }` as the uniform list a shader is assembled from, in
 declaration order. The names are temp memory, valid for the call.

 @param tables : `false for a post pass, which has no instances and so every uniform is one row.`
 @return? js::THREW
*>
fn void? JsRuntime.read_uniform_shapes(&self, js::Value shapes, List{MaterialUniform}* out, bool tables = true)
{
	// `keys` rather than `@each`: the names have to outlive the loop, and `@each`
	// gives each one back to its own pool.
	foreach (key : self.js.keys(shapes)!)
	{
		String name = self.js.key_text(key);
		js::Value shape = self.js.get(shapes, key)!;
		if (self.js.length(shape)! < 1) return self.js.fail("every uniform needs a value — a name arrived without one")~;

		double width = self.js.get_number(shape, 0)!;
		if (!(width >= 1 && width <= 4) || width != math::floor(width))
		{
			return self.js.fail("uniform '%s' must be a number or an array of two, three or four numbers", name)~;
		}
		double rows = tables ? self.js.get_number(shape, 1, 1)! : 1;
		if (!(rows >= 1)) return self.js.fail("uniform '%s' is a table with no rows in it", name)~;

		out.push({ .name = name, .components = (uint)width, .rows = (uint)rows });
	}
}

<*
 `{ name: textureIndex }` as the sampler names a body declares, in order, and the
 texture each starts bound to.

 @return? js::THREW
*>
fn void? JsRuntime.read_texture_ids(&self, js::Value ids, List{MaterialTexture}* names, List{int}* bound)
{
	foreach (key : self.js.keys(ids)!)
	{
		js::Value id = self.js.get(ids, key)!;
		if (!id.is_number()) return self.js.fail("every texture needs a value — a name arrived without one")~;
		names.push({ .name = self.js.key_text(key) });
		bound.push((int)self.js.number(id)!);
	}
}

<*
 `three.ShaderMaterial` — compile a fragment body and answer with its index.

 Needs a device, because a material *is* a pipeline. Unlike `raycast`, there is
 no meaningful answer without one: a material that compiled nothing would fail
 later, somewhere else.

 @param uniform_shapes : `{ name: [width, rows] }.`
 @param texture_ids : `{ name: textureIndex }, with NO_TEXTURE for a sampler that starts white.`
 @param vertex : `The vertex body; empty is the identity.`
 @param bounds : `How far the vertex body moves things. It travels with the body because a displacement nobody declared a bound for is geometry that culls wrong.`
 @return? js::THREW
*>
fn uint? js_create_material(
	JsRuntime* self,
	String fragment,
	js::Value uniform_shapes,
	int side,
	int blending,
	js::Value texture_ids,
	String vertex,
	float bounds
)
{
	self.require_gpu("compiling a material")!;

	List{MaterialUniform} uniforms;
	uniforms.tinit(4);
	self.read_uniform_shapes(uniform_shapes, &uniforms)!;

	List{MaterialTexture} textures;
	List{int} bound;
	textures.tinit(4);
	bound.tinit(4);
	self.read_texture_ids(texture_ids, &textures, &bound)!;

	// The diagnostic is the product here, not a side effect: a bad shader has
	// to throw a JS error carrying the compiler's text, so it is collected whether
	// the compile failed or only warned, and the warning path logs rather than
	// throws.
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
		bounds,
		diagnostic: &diagnostic
	);
	defer if (diagnostic.ptr != null) diagnostic.free(mem);

	if (catch err = made) return self.js.fail("%s", material_failure(err, diagnostic, textures.array_view()))~;

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
	foreach (i, texture : textures)
	{
		if (catch err = self.pass.set_material_texture(&self.renderer.gpu, made, texture.name, bound[i]))
		{
			// Discarded rather than `!!`: the only way this can fail is a
			// material that is not there, which is the state the dispose was
			// asking for anyway — and a panic on the failure path of a *script
			// error* would take the process down over a typed texture name.
			@catch(self.pass.dispose_material(&self.renderer.gpu, made));
			return self.js.fail("%s", texture_failure(err, texture.name, "this material's shader", "the material's"))~;
		}
	}

	return made;
}

<*
 Turns a sampler fault into a sentence an agent can act on, for a material or a
 post pass.

 The `MATERIAL_SAMPLER_UNKNOWN` case is the one worth the words: a sampler is
 reached by the name the body declares, so a name that is not in the
 declaration list has nowhere to bind. A declared texture the body never samples
 is not this case — the module keeps every declaration.

 @param shader : `What has the samplers, as the sentence names it: "this material's shader".`
 @param owner : `Whose declared textures they are: "the material's".`
*>
fn String texture_failure(fault err, String name, String shader, String owner)
{
	switch (err)
	{
		case MATERIAL_SAMPLER_UNKNOWN:
			return string::tformat("%s has no sampler called '%s' — the name is not one of %s declared textures",
				shader, name, owner);
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

 @return? js::THREW
*>
fn void? js_set_material_texture(JsRuntime* self, uint material, String name, int texture)
{
	Gpu* gpu = self.renderer != null ? &self.renderer.gpu : null;
	if (catch err = self.pass.set_material_texture(gpu, material, name, texture))
	{
		if (err == MATERIAL_UNKNOWN)
		{
			return self.js.fail("that material cannot take a texture — it is the default material or it was disposed")~;
		}
		return self.js.fail("%s", texture_failure(err, name, "this material's shader", "the material's"))~;
	}
}

<*
 Turns a material fault into a sentence an agent can act on.

 The compiler's diagnostic goes through verbatim when there is one — it already names
 the file, the line and the column, and `#line` has already made that line the
 one the agent wrote rather than one in the generated preamble. The validation
 faults have no diagnostic behind them, so they carry their own sentence.

 ## The one case where verbatim is not enough

 A body written before textures moved into `s.textures` calls one as a
 function - `noise_map().Sample(uv)` - and the compiler, rightly, answers
 "unknown function `noise_map`", or something stranger when the name is also an
 engine helper's. That is true and does not say what to write instead, so when
 the line quoted calls one of this material's own textures the sentence that
 does is added after the diagnostic.
*>
fn String material_failure(fault err, String diagnostic, MaterialTexture[] textures = {}) @local
{
	if (diagnostic.len > 0)
	{
		foreach (texture : textures)
		{
			// The rendered diagnostic quotes the offending line, so the old call
			// spelling is visible in it whatever the compiler made of the name -
			// "unknown function", or an overload of an engine helper that happens
			// to share it (`noise`).
			if (!diagnostic.contains(string::tformat("%s()", texture.name))) continue;
			return string::tformat(
				"%s\n\n`%s` is one of this material's textures, and a texture is a field rather than a "
					"function: read it as `s.textures.%s.Sample(uv)` in the fragment body, or "
					"`v.textures.%s.SampleLevel(uv, 0.0)` in the vertex body.",
				diagnostic,
				texture.name,
				texture.name,
				texture.name
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
			return "a uniform or texture name must be a plain identifier and not a shady keyword";
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
			return "the material shader failed to compile and no diagnostic came back";
		default:
			return string::tformat("the material could not be built: %s", err);
	}
}

<*
 Up to four numbers of a uniform write, from the array the prelude checked.

 @return? js::THREW
*>
fn usz? JsRuntime.uniform_numbers(&self, js::Value list, float[4]* values, String name)
{
	long count = self.js.length(list)!;
	if (count < 1 || count > 4) return self.js.fail("uniform '%s' wants one to four numbers", name)~;
	for (long i = 0; i < count; i++) (*values)[i] = (float)self.js.number(self.js.get(list, i)!)!;
	return (usz)count;
}

<*
 `material.uniforms.<name> = value` — write one uniform's bytes.

 `row` and `rows` select one row of a table column; the row count is passed for
 `Material.set_uniform`'s reason — it is what keeps the width check exact once a
 field can hold more than one value.

 @param values : `An array of one to four numbers. Its length is the width, so [0, 0, 0] stays a three-component write.`
 @return? js::THREW
*>
fn void? js_set_uniform(JsRuntime* self, uint index, String name, js::Value values, int row, int rows)
{
	Material* material = self.pass.material(index);
	if (material == null) return self.js.fail("that material is not in this context")~;

	float[4] numbers;
	usz count = self.uniform_numbers(values, &numbers, name)!;

	if (rows < 1) rows = 1;
	if (row < 0 || row >= rows)
	{
		return self.js.fail("uniform '%s' has %d row%s and row %d is not one of them",
			name, rows, rows == 1 ? "" : "s", row)~;
	}

	if (catch err = material.set_uniform(name, numbers[:count], (uint)row, (uint)rows))
	{
		if (err == MATERIAL_UNIFORM_WIDTH)
		{
			return self.js.fail("uniform '%s' was declared with a different number of components", name)~;
		}
		return self.js.fail("this material has no uniform called '%s'", name)~;
	}
}

<*
 `material.side = ...` — change which faces this material keeps.

 A verb rather than a uniform because which faces survive is render state and not
 a byte in the push block — but it needs no device and can build nothing, because
 the cull mode is dynamic. A material's side is one `vk::cmdSetCullMode` at
 record time, so flipping it in an animation callback costs nothing.

 @return? js::THREW
*>
fn void? js_set_side(JsRuntime* self, uint index, int side)
{
	if (catch self.pass.set_material_side(index, side)) return self.js.fail("that material is not in this context")~;
}

// The refusal every per-material write shares: an index this context never handed
// out, or one of the two built-ins, which belong to every node that never asked
// for a material.
const String NOT_A_SCRIPT_MATERIAL = "that material is not in this context, or it is a built-in one that every node shares";

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

 @return? js::THREW
*>
fn void? js_set_opacity(JsRuntime* self, uint index, float opacity)
{
	if (catch self.pass.set_material_opacity(index, opacity)) return self.js.fail(NOT_A_SCRIPT_MATERIAL)~;
}

<*
 `material.opacity` — what it reads back as.

 An index that names nothing answers 1.0 rather than throwing, which is
 `getMaterialUv`'s rule: a getter should answer what a material that was never
 asked for anything would answer. The prelude's `_index()` has already thrown for
 a disposed handle before this is reached.
*>
fn float js_get_opacity(JsRuntime* self, uint index) => self.pass.material_opacity(index);

<*
 `material.roughness` / `.metalness` / `.reflectance` / `.alphaTest` — how the
 light behaves where it lands, as opposed to what colour it finds there.

 One verb for the four, because they are one `float4` in the draw record and
 setting them separately would be four crossings to write one value. Free to
 animate for `js_set_opacity`'s reason — nothing is rebuilt.

 **A material nobody touches is `{1, 0, 0}`, and that is a surface with no
 highlight at all.** The specular term is off until a script asks; the argument
 for that default is in `scene/material.c3` and it is the same argument shadows
 being off by default rests on.

 The prelude has already refused a value outside 0..1 by name.

 @return? js::THREW
*>
fn void? js_set_surface(JsRuntime* self, uint index, float roughness, float metalness, float reflectance, float alpha_test)
{
	if (catch self.pass.set_material_surface(index, roughness, metalness, reflectance, alpha_test))
	{
		return self.js.fail(NOT_A_SCRIPT_MATERIAL)~;
	}
}

// `getSurface`: the record field `setSurface` writes, by name.
struct SurfaceRead
{
	float roughness;
	float metalness;
	float reflectance;
	float alpha_test;
}

<*
 What those four read back as. An index that names nothing answers the defaults
 rather than throwing, which is `getOpacity`'s rule.
*>
fn SurfaceRead js_get_surface(JsRuntime* self, uint index)
{
	float[4] s = self.pass.material_surface(index);
	return { s[0], s[1], s[2], s[3] };
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

 @return? js::THREW
*>
fn void? js_set_emissive(JsRuntime* self, uint index, float r, float g, float b, float intensity)
{
	if (catch self.pass.set_material_emissive(index, r, g, b, intensity)) return self.js.fail(NOT_A_SCRIPT_MATERIAL)~;
}

struct EmissiveRead
{
	Vec3 color;
	float intensity;
}

<*
 `material.emissive` and `.emissiveIntensity`. An index that names nothing
 answers black at strength 1, which is `getSurface`'s rule.
*>
fn EmissiveRead js_get_emissive(JsRuntime* self, uint index)
{
	float[4] e = self.pass.material_emissive(index);
	return { .color = { e[0], e[1], e[2] }, .intensity = e[3] };
}

<*
 `material.heightScale`, `.parallaxSteps` and `.parallaxShadow`, as one write.

 @return? js::THREW
*>
fn void? js_set_relief(JsRuntime* self, uint index, float scale, int steps, float shadow)
{
	if (catch self.pass.set_material_relief(index, scale, steps < 0 ? 0 : (uint)steps, shadow))
	{
		return self.js.fail(NOT_A_SCRIPT_MATERIAL)~;
	}
}

struct ReliefRead
{
	float scale;
	int steps;
	float shadow;
}

fn ReliefRead js_get_relief(JsRuntime* self, uint index)
{
	float[3] relief = self.pass.material_relief(index);
	return { relief[0], (int)relief[1], relief[2] };
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

 @return? js::THREW
*>
fn void? js_set_material_uv(JsRuntime* self, uint index, float repeat_u, float repeat_v, float offset_u, float offset_v)
{
	if (catch err = self.pass.set_material_uv(index, repeat_u, repeat_v, offset_u, offset_v))
	{
		if (err == MATERIAL_REPEAT_IS_ZERO)
		{
			return self.js.fail(
				"material.repeat cannot be zero — every point of the surface would sample the same texel. "
					"1 is once across, 4 is four times"
			)~;
		}
		return self.js.fail("that material is not in this context")~;
	}
}

struct UvRead
{
	Vec2 repeat;
	Vec2 offset;
}

fn UvRead js_get_material_uv(JsRuntime* self, uint index)
{
	float[4] uv = self.pass.material_uv(index);
	return { .repeat = { uv[0], uv[1] }, .offset = { uv[2], uv[3] } };
}

<*
 `material.uvVariants = [...]` — start the table over.

 Two verbs and not one, which is `beginMaterialLayers` and `addMaterialLayer`'s
 shape. Clearing first is what makes assigning a shorter list actually shorter
 rather than a shorter list with somebody else's tail on the end of it.

 @return? js::THREW
*>
fn void? js_begin_uv_variants(JsRuntime* self, uint index)
{
	if (catch self.pass.begin_material_uv_variants(index)) return self.js.fail("that material is not in this context")~;
}

<*
 One row of it: `[offsetU, offsetV, turns, flip]`.

 @return? js::THREW
*>
fn void? js_add_uv_variant(JsRuntime* self, uint index, float offset_u, float offset_v, float turns, float flip)
{
	if (catch self.pass.add_material_uv_variant(index, offset_u, offset_v, turns, flip))
	{
		return self.js.fail("that material is not in this context")~;
	}
}

<*
 The table back, as `[[offsetU, offsetV, turns, flip], ...]`; an empty array for
 a material with no table.

 @return? js::THREW
*>
fn js::Value? js_get_uv_variants(JsRuntime* self, uint index)
{
	@pool()
	{
		float[] flat = self.pass.material_uv_variants(index);
		js::Value rows = self.js.array((uint)(flat.len / 4))!;
		for (usz i = 0; i + 4 <= flat.len; i += 4)
		{
			self.js.push(rows, self.js.numbers({ flat[i], flat[i + 1], flat[i + 2], flat[i + 3] })!);
		}
		return rows;
	};
}

<*
 `material.stochastic = true` — sample this material's maps so they stop
 repeating.

 @return? js::THREW
*>
fn void? js_set_stochastic(JsRuntime* self, uint index, bool on)
{
	if (catch self.pass.set_material_stochastic(index, on)) return self.js.fail("that material is not in this context")~;
}

fn bool js_get_stochastic(JsRuntime* self, uint index) => self.pass.material_stochastic(index);

<*
 `new three.MeshLambertMaterial({ map })` — the built-in shader, with an image.

 Needs no device *for a compile*, because there is nothing to compile: the
 pipeline is the one the pass built at startup. It still needs one to have got
 here at all, since the only source of a texture index is `three.texture`, which
 refuses a runtime with no GPU by name. So the check below is about the texture
 and not about the device.

 @return? js::THREW
*>
fn uint? js_create_texture_material(JsRuntime* self, int texture, int side, int blending)
{
	uint? made = self.pass.create_texture_material(texture, side, blending);
	if (catch made)
	{
		return self.js.fail("that texture is not in this context — it was disposed, or it came from another renderer")~;
	}
	return made;
}

<*
 `material.dispose()` — give back the reference the script's handle holds.

 The prelude has already refused a second call on the same handle, so what
 reaches here is either a live material or a mistake. The mistake it can still be
 is a built-in one: `DEFAULT_MATERIAL` belongs to every node that never asked for
 a material.

 What this does *not* do is free anything on its own. See
 `MeshPass.dispose_material`.

 @return? js::THREW
*>
fn void? js_dispose_material(JsRuntime* self, uint index)
{
	Gpu* gpu = self.renderer == null ? null : &self.renderer.gpu;
	if (catch self.pass.dispose_material(gpu, index)) return self.js.fail(NOT_A_SCRIPT_MATERIAL)~;
}

const String DEAD_TEXTURE = "that texture is not in this context — it was disposed, or it came from another renderer";

<*
 `material.map = texture` — or `material.map = null`, which is `NO_TEXTURE`.

 The two refusals are told apart in the message rather than flattened into one,
 because they are different mistakes: a built-in material is one a script may not
 texture at all, and a dead texture is one it may not texture *with*.

 @return? js::THREW
*>
fn void? js_set_map(JsRuntime* self, uint index, int texture)
{
	Gpu* gpu = self.renderer == null ? null : &self.renderer.gpu;
	if (catch err = self.pass.set_material_map(gpu, index, texture))
	{
		return self.js.fail(err == MATERIAL_TEXTURE_UNKNOWN ? DEAD_TEXTURE : NOT_A_SCRIPT_MATERIAL)~;
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

 @return? js::THREW
*>
fn void? js_set_material_slot(JsRuntime* self, uint index, int slot, int texture)
{
	Gpu* gpu = self.renderer == null ? null : &self.renderer.gpu;
	if (catch err = self.pass.set_material_slot(gpu, index, slot, texture))
	{
		switch (err)
		{
			case MATERIAL_TEXTURE_UNKNOWN:
				return self.js.fail(DEAD_TEXTURE)~;
			case MATERIAL_SAMPLER_UNKNOWN:
				return self.js.fail(
					"normalMap, metalnessRoughnessMap and aoMap are the built-in material's — "
						"a ShaderMaterial declares its own samplers and fills them through material.textures"
				)~;
			default:
				return self.js.fail(NOT_A_SCRIPT_MATERIAL)~;
		}
	}
}

<*
 `mesh.material = mat` — point a node at a material.

 The material index is validated here rather than in `Scene.set_material`: the
 scene graph has no view of `MeshPass.materials`, and giving it one would put the
 render pass inside the scene. The draw loop skips a bucket whose material does
 not resolve, so an index that slipped through would be silence rather than a
 crash.

 @return? js::THREW
*>
fn void? js_set_material(JsRuntime* self, NodeRef ref, uint material)
{
	if (self.pass.material(material) == null) return self.js.fail("that material is not in this context")~;
	// Materials are the pass's and are shared by every scene, so only the node
	// side of this needs the scene it came from.
	ref.scene.set_material(ref.id, material);
}

<*
 `beginMaterialLayers(material, sharedMask, baseNormal, baseHeight, bumpStrength,
 bumpDistance)` — start recording what a `LayeredMaterial` *is*.

 Everything else on this file's surface crosses in one direction: a description
 goes in and a compiled pipeline comes out, and the description is not needed
 again. A layer stack is the exception, because `scene.export` has to write the
 stack back into a `.glb` and cannot get it out of the shader the generator
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

 @return? js::THREW
*>
fn void? js_begin_material_layers(
	JsRuntime* self,
	uint index,
	String shared,
	String base_normal,
	String base_height,
	float bump_strength,
	float bump_distance
)
{
	Material* material = self.pass.material(index);
	if (material == null) return self.js.fail("that material is not in this context")~;

	material.begin_script_layers(
		shared.len == 0 ? 0 : material.binding_of_texture(shared),
		base_normal.len == 0 ? 0 : material.binding_of_texture(base_normal),
		base_height.len == 0 ? 0 : material.binding_of_texture(base_height),
		bump_strength,
		bump_distance
	);
}

<*
 One layer of the stack.

 `samplers` is the layer's `{ map, normal, emissive, mask, params,
 metallicRoughness, height }`, each a sampler name the generator chose, absent
 for a slot the layer does not use. Names rather than binding numbers, because
 the resolution belongs on this side: `Material.binding_of_texture` asks the
 material's own declaration list, which is the only thing that actually knows.

 `params` is the uniform holding an `animated` layer's tint and opacity, resolved
 to a push offset once here and read live at export.

 The blend mode, mask source and mask channel arrive as `gltf.c3l`'s own
 ordinals, untranslated, exactly as `meshLayers` hands them the other way.

 @return? js::THREW
*>
fn void? js_add_material_layer(
	JsRuntime* self,
	uint index,
	String name,
	js::Value samplers,
	uint blend_mode,
	uint mask_source,
	uint mask_channel,
	bool invert,
	float opacity,
	Vec3 tint,
	Vec3 emissive,
	float metallic,
	float roughness,
	float bump_strength,
	float bump_distance,
	Vec2 uv_scale,
	Vec2 uv_offset
)
{
	Material* material = self.pass.material(index);
	if (material == null) return self.js.fail("that material is not in this context")~;

	String params = self.sampler_name(samplers, "params")!;
	ScriptLayer layer = {
		.name = name,
		.map_binding = self.sampler_binding(material, samplers, "map")!,
		.normal_binding = self.sampler_binding(material, samplers, "normal")!,
		.emissive_binding = self.sampler_binding(material, samplers, "emissive")!,
		.mask_binding = self.sampler_binding(material, samplers, "mask")!,
		.params_offset = params.len > 0 ? material.uniform_offset(params) : -1,
		.mr_binding = self.sampler_binding(material, samplers, "metallicRoughness")!,
		.height_binding = self.sampler_binding(material, samplers, "height")!,
		.blend_mode = blend_mode,
		.mask_source = mask_source,
		.mask_channel = mask_channel,
		.invert = invert,
		.opacity = opacity,
		.tint = { tint.x, tint.y, tint.z },
		.emissive_factor = { emissive.x, emissive.y, emissive.z },
		.metallic = metallic,
		.roughness = roughness,
		.bump_strength = bump_strength,
		.bump_distance = bump_distance,
		.uv_scale = { uv_scale.x, uv_scale.y },
		.uv_offset = { uv_offset.x, uv_offset.y },
	};
	material.add_script_layer(layer);
}

<*
 One slot of a layer's samplers, as a name; "" for one that is absent or null.

 @return? js::THREW
*>
fn String? JsRuntime.sampler_name(&self, js::Value samplers, String slot)
{
	js::Value v = self.js.get(samplers, slot)!;
	return v.is_nullish() ? "" : self.js.text(v, tmem);
}

<*
 One slot of a layer's samplers, as a binding. Zero for a slot that is absent or
 empty, which is what `TextureSlots.at` reads as "no such sampler".

 @return? js::THREW
*>
fn uint? JsRuntime.sampler_binding(&self, Material* material, js::Value samplers, String slot)
{
	String name = self.sampler_name(samplers, slot)!;
	return name.len == 0 ? 0 : material.binding_of_texture(name);
}
