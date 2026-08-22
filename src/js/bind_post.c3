<*
 The post verbs: compiling one shader over the whole finished frame, and
 pointing it at new values.

 `bind_shader.c3` for the pass that has no geometry. Everything about the
 crossing is the same — the uniforms arrive as two comma-joined strings because
 the QuickJS shim this project vendors can read a property by name and cannot
 enumerate one, so `prelude.js` does the enumerating in the language that can —
 and what differs is what there is only one of.

 ## Why these are verbs and not a class

 There is one post slot. A constructible `three.PostPass` would imply an
 assignment target — something to hold two of, something to swap between — and
 there is not one: `PostPass.set` replaces whatever was running, and the
 previous pipeline goes to the deletion queue in the same call. So the surface
 is `three.setPost(spec)` and `three.setPost(null)`, and the object the script
 gets back is a handle onto the one live pass rather than a thing it owns.

 ## What a failure leaves behind

 Nothing. `PostPass.set` builds the new pipeline before it retires the old one,
 so a body that does not compile throws here with Slang's text and the frame
 keeps rendering through the shader that was already running. That is what makes
 an editing loop safe to hold a window open through, and it is why this file
 raises rather than clearing.
*>
module three;

import std::collections::list;
import std::io;
import qjs;

<*
 Register the post verbs on the host object.

 Called from `install_bindings` beside `bind_shader_verbs`, so there is still
 exactly one place that lists what JavaScript can reach.
*>
fn void JsRuntime.bind_post_verbs(&self, qjs::Value host)
{
	self.bind(host, "setPost", &js_set_post, 3);
	self.bind(host, "clearPost", &js_clear_post, 0);
	self.bind(host, "setPostUniform", &js_set_post_uniform, 6);
}

<*
 `three.setPost({ fragment, uniforms })` — compile a post shader and run the
 frame through it.

 Needs a device, for `js_create_material`'s reason and one more: a post pass is
 a pipeline *and* a full-size attachment, and there is neither without one.

 The uniforms cross as `("gain,tint", "1,3")` and no row counts, because a post
 pass has no instances to select a row with — `validate_post` refuses a table by
 name and `prelude.js` refuses one before it gets here, so the widths are the
 whole shape.
*>
fn void js_set_post(
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
		*out = js.raise("compiling a post shader needs a GPU device and this context has none");
		return;
	}

	@pool()
	{
		String fragment = arg_text(&js, argc, args, 0, tmem);
		String names = arg_text(&js, argc, args, 1, tmem);
		String widths = arg_text(&js, argc, args, 2, tmem);

		List{String} name_list;
		List{String} width_list;
		name_list.tinit(4);
		width_list.tinit(4);
		split_commas(names, &name_list);
		split_commas(widths, &width_list);

		if (name_list.len() != width_list.len())
		{
			*out = js.raise("every uniform needs a value — a name arrived without one");
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

			// Always one row. There is no `rows` argument to this verb at all,
			// rather than one that is always 1: a post pass has no instances, so a
			// row count is not a thing a caller could mean here.
			uniforms.push({ .name = name, .components = (uint)components, .rows = 1 });
		}

		// Collected whether the compile failed or only warned, exactly as
		// `js_create_material` collects it: the warning path logs and the failure
		// path throws, and an agent who never sees a warning writes the same
		// mistake twice.
		String diagnostic;
		// `@catch` rather than `if (catch ...)` around the call itself, because
		// the diagnostic has to be freed on both paths and a `defer` cannot be
		// placed inside the `catch` arm that needs it.
		fault err = @catch(self.renderer.post.set(
			&self.renderer.gpu,
			&self.renderer.target,
			fragment,
			uniforms.array_view(),
			diagnostic: &diagnostic
		));
		defer if (diagnostic.ptr != null) diagnostic.free(mem);

		if (err)
		{
			*out = js.raise(post_failure(err, diagnostic));
			return;
		}

		if (diagnostic.len > 0)
		{
			self.log.append_string("post: ");
			self.log.append_string(diagnostic);
			if (!diagnostic.ends_with("\n")) self.log.append_char('\n');
		}
	};
}

<*
 Turn a post fault into a sentence an agent can act on.

 `material_failure`'s three steps, against the post pass's own diagnostic
 buffer: Slang's text if there is any, then whatever `post_source` refused in
 words, then a sentence per fault for the ones that reach here with neither.

 The Slang text goes through verbatim because `#line` has already made its
 coordinates the agent's own — `post:3:24` is line 3 of the body they typed, not
 line 3 of the module three.c3 generated around it.
*>
fn String post_failure(fault err, String diagnostic) @local
{
	if (diagnostic.len > 0) return diagnostic;

	// `post_source` leaves a sentence naming what it refused and why — which
	// uniform, how many bytes — and that is strictly better than re-deriving one
	// from the fault alone. Empty after a successful assembly, which is what
	// makes the switch below reachable.
	String noted = post_diagnostic();
	if (noted.len > 0) return noted;

	switch (err)
	{
		case POST_BODY_EMPTY:
			return "a post pass needs a fragment body — `fragment` was empty";
		case POST_NAME_INVALID:
			return "a post uniform name must be a plain identifier and must not shadow the shader's own";
		case POST_TOO_MANY_UNIFORMS:
			return string::tformat(
				"those uniforms do not fit the push block — a post pass has %d bytes, %d floats",
				POST_UNIFORM_BUDGET,
				POST_UNIFORM_BUDGET / 4
			);
		case SHADER_COMPILE_FAILED:
			return "the post shader failed to compile and Slang said nothing about why";
		default:
			return string::tformat("the post pass could not be built: %s", err);
	}
}

<*
 `three.setPost(null)` — stop post-processing.

 A no-op on a runtime with no device and a no-op on a pass that was never set,
 so a script can call it unconditionally without asking first whether there is
 anything to clear. `PostPass.clear` makes the same promise one layer down.
*>
fn void js_clear_post(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	if (self.renderer == null) return;
	self.renderer.post.clear(&self.renderer.gpu);
}

<*
 `post.uniforms.<name> = value` — write one post uniform's bytes.

 Arity six against `setUniform`'s nine: name, four floats and the count of them,
 and no row or row count, because there is no table. The count is passed rather
 than inferred from trailing zeroes for `js_set_uniform`'s reason — `[0, 0, 0]`
 is a perfectly ordinary colour and guessing would make it a one-component
 write.
*>
fn void js_set_post_uniform(
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
		*out = js.raise("there is no post pass in this context — it has no GPU device");
		return;
	}

	@pool()
	{
		String name = arg_text(&js, argc, args, 0, tmem);
		float[4] values = {
			arg_float(&js, argc, args, 1),
			arg_float(&js, argc, args, 2),
			arg_float(&js, argc, args, 3),
			arg_float(&js, argc, args, 4),
		};
		int count = arg_int(&js, argc, args, 5);
		if (count < 1 || count > 4)
		{
			*out = js.raise(string::tformat("uniform '%s' wants one to four numbers", name));
			return;
		}

		if (catch err = self.renderer.post.set_uniform(name, values[:count]))
		{
			*out = js.raise(
				err == MATERIAL_UNIFORM_WIDTH
					? string::tformat(
						"uniform '%s' was declared with a different number of components", name
					)
					: string::tformat("the post pass has no uniform called '%s'", name)
			);
			return;
		}
	};
}
