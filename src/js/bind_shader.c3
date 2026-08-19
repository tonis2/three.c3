<*
 The material verbs: compiling a fragment body, and pointing a node at the result.

 `plan.md`'s source tree has carried a line for this file since M0 —
 "js/bind_shader.c3, the material/shader surface (tier 2, §4)". It is the same
 flat-verb layer as `bind_scene.c3`: numbers and strings in, numbers out, and
 every Three.js-ism written in JavaScript where the language has them.

 ## Why the uniforms cross as two joined strings

 `new three.ShaderMaterial({ uniforms: { tint: [1, 0.5, 0.2], time: 0 }, ... })`
 hands the prelude an object, and the object cannot come here: the QuickJS shim
 this project vendors exposes `qjs_get_prop` by name and nothing that enumerates
 keys — no `JS_GetOwnPropertyNames`, no atom iteration. A host verb can read
 `uniforms.tint` only if it already knows the word "tint".

 So `prelude.js` does the enumerating, in the language that can, and crosses with
 `("tint,time", "3,1")`. That is the same shape as `setTransform` taking eleven
 scalars rather than three objects, and for the same reason. Comma is a safe
 separator because a uniform name that is not `[A-Za-z_][A-Za-z0-9_]*` is
 refused by `material_source` before it can reach a shader.
*>
module three;

import std::collections::list;
import std::io;
import qjs;

<*
 Register the material verbs on the host object.

 Called from `install_bindings` rather than being installed separately, so there
 is exactly one place that lists what JavaScript can reach.
*>
fn void JsRuntime.bind_shader_verbs(&self, qjs::Value host)
{
	self.bind(host, "createMaterial", &js_create_material, 5);
	self.bind(host, "setUniform", &js_set_uniform, 9);
	self.bind(host, "setSide", &js_set_side, 2);
	self.bind(host, "setMaterial", &js_set_material, 3);
}

<*
 Split a comma-joined list into slices of the original.

 No copies: every slice points into `text`, which the caller owns for as long as
 the result is used. Empty input is an empty list rather than one empty field,
 because a material with no uniforms is the ordinary case and `"".split(",")`
 answering `[""]` would invent one called nothing.
*>
fn void split_commas(String text, List{String}* out) @local
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

 Needs a device, because a material *is* a pipeline and there is no pipeline
 without one. Unlike `raycast`, there is no meaningful answer to give without it:
 a material that compiled nothing would fail later, somewhere else, which is the
 shape of error this milestone exists to remove.
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
		String names = arg_text(&js, argc, args, 1, tmem);
		String widths = arg_text(&js, argc, args, 2, tmem);
		// A third joined list, for the same reason as the second: the shape of a
		// uniform is now two numbers, and a table's row count has to cross with
		// its width or the shader declares a scalar where the script wrote a
		// column. Absent means every uniform is one row, which is what every
		// material written before tables existed meant.
		String rows = arg_text(&js, argc, args, 3, tmem);

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
					string::tformat(
						"uniform '%s' must be a number or an array of two, three or four numbers",
						name
					)
				);
				return;
			}

			int declared_rows = row_list.len() > 0 ? (row_list[i].to_int() ?? 0) : 1;
			if (declared_rows < 1)
			{
				*out = js.raise(
					string::tformat("uniform '%s' is a table with no rows in it", name)
				);
				return;
			}

			uniforms.push({
				.name = name,
				.components = (uint)components,
				.rows = (uint)declared_rows,
			});
		}

		// The diagnostic is the product here, not a side effect. `plan.md` §5's
		// done condition for M5 is that a bad shader throws a JS error carrying
		// the Slang text — so it is collected whether the compile failed or only
		// warned, and the warning path logs rather than throws.
		// Absent means `SIDE_FRONT`, which is what every material meant before a
		// side could be named — `cull_for_side` maps anything it does not know
		// there too, and the prelude has already refused an unknown value by name.
		int side = argc > 4 ? arg_int(&js, argc, args, 4) : SIDE_FRONT;

		String diagnostic;
		uint? made = self.pass.create_material(
			&self.renderer.gpu,
			&self.renderer.target,
			fragment,
			uniforms.array_view(),
			side,
			&diagnostic
		);
		defer if (diagnostic.ptr != null) diagnostic.free(mem);

		if (catch err = made)
		{
			*out = js.raise(material_failure(err, diagnostic));
			return;
		}

		if (diagnostic.len > 0)
		{
			self.log.append_string("shader: ");
			self.log.append_string(diagnostic);
			if (!diagnostic.ends_with("\n")) self.log.append_char('\n');
		}

		*out = qjs::int_value((int)made);
	};
}

<*
 Turn a material fault into a sentence an agent can act on.

 The Slang diagnostic goes through verbatim when there is one — it already names
 the file, the line and the column, and `#line` has already been used to make
 that line the one the agent wrote rather than one in the generated preamble.
 Rewording it would only lose information. The validation faults have no
 diagnostic behind them, so they carry their own sentence.
*>
fn String material_failure(fault err, String diagnostic) @local
{
	if (diagnostic.len > 0) return diagnostic;

	// `material_source` leaves a sentence naming what it refused and why —
	// which uniform, which byte count — and that is strictly better than
	// re-deriving one from the fault alone.
	String noted = material_diagnostic();
	if (noted.len > 0) return noted;

	switch (err)
	{
		case MATERIAL_BODY_EMPTY:
			return "a ShaderMaterial needs a fragment body — `fragment` was empty";
		case MATERIAL_NAME_INVALID:
			return "a uniform name must be a plain identifier and must not shadow the shader's own";
		case MATERIAL_TOO_MANY_UNIFORMS:
			return "those uniforms do not fit the push block — a material has 68 bytes, 17 floats";
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
 make it a one-component write; the row count is passed for `Material.set_uniform`'s
 reason — it is what keeps the width check exact once a field can hold more than
 one value.
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

	uint index = (uint)arg_int(&js, argc, args, 0);
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

		// Absent means the plain case, so a caller that predates tables — a
		// script reaching for `__three.setUniform` itself — still writes the one
		// value it means to.
		int row = argc > 7 ? arg_int(&js, argc, args, 7) : 0;
		int rows = argc > 8 ? arg_int(&js, argc, args, 8) : 1;
		if (rows < 1) rows = 1;
		if (row < 0 || row >= rows)
		{
			*out = js.raise(string::tformat(
				"uniform '%s' has %d row%s and row %d is not one of them", name, rows, rows == 1 ? "" : "s", row
			));
			return;
		}

		if (catch err = material.set_uniform(name, values[:count], (uint)row, (uint)rows))
		{
			*out = js.raise(
				err == MATERIAL_UNIFORM_WIDTH
					? string::tformat(
						"uniform '%s' was declared with a different number of components", name
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
 the cull mode is dynamic. `PipelineState` has that argument; the short version
 is that a material's side is one `vk::cmdSetCullMode` at record time, so
 flipping it in an animation callback costs nothing at all.
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
	int side = arg_int(&js, argc, args, 1);

	if (catch self.pass.set_material_side(index, side))
	{
		*out = js.raise("that material is not in this context");
		return;
	}
}

<*
 `mesh.material = mat` — point a node at a material.

 The material index is validated here rather than in `Scene.set_material`: the
 scene graph has no view of `MeshPass.materials` and giving it one would put the
 render pass inside the scene. The draw loop skips a bucket whose material does
 not resolve, so an index that slipped through would be silence rather than a
 crash — which is exactly the failure this check exists to turn into a sentence.
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

	NodeId id = arg_handle(self, &js, argc, args, 0, out);
	if (!id.is_set()) return;

	uint material = (uint)arg_int(&js, argc, args, 2);
	if (self.pass.material(material) == null)
	{
		*out = js.raise("that material is not in this context");
		return;
	}

	self.pass.scene.set_material(id, material);
}
