<*
 The post verbs: compiling shaders over the whole finished frame, and pointing
 them at new values.

 `bind_shader.c3` for the pass that has no geometry. Everything about the
 crossing is the same: the uniforms arrive as `{ name: [width, 1] }` and the
 samplers as `{ name: textureIndex }`.

 ## Why these are verbs and not a class

 There is one *chain*. A constructible `three.PostPass` would imply an assignment
 target — something to hold two of, something to swap between — and there is not
 one: the chain is the renderer's, `PostPass.set` replaces whatever was in it,
 and the previous pipelines go to the deletion queue in the same call. So the
 surface is `three.setPost(spec)`, `three.addPass(spec)` and
 `three.setPost(null)`, and the object a script gets back is a handle onto one
 live pass rather than a thing it owns.

 ## Two verbs, one path

 `setPost` and `addPass` differ by one bool all the way down: the first replaces
 the chain and the second appends to it. They cross with identical arguments and
 share `post_verb` below, because two copies of the uniform and texture
 unpacking is two chances for the two doors to disagree about what a spec is.

 What `addPass` adds is a stage index, which every uniform and texture write now
 carries. `setPost` leaves exactly one stage, so a script that never calls
 `addPass` addresses stage 0 forever and cannot tell the difference.

 ## What a failure leaves behind

 Nothing. `PostPass.set` and `.add` build the new pipeline before they touch the
 chain, so a body that does not compile throws here with the compiler's text and the
 frame keeps rendering through whatever was already running.
*>
module three;

import std::collections::list;
import fastjs::js;

<*
 Registers the post verbs on the host object.

 Called from `install_bindings` beside `bind_shader_verbs`, so there is still
 exactly one place that lists what JavaScript can reach.
*>
fn void? JsRuntime.bind_post_verbs(&self, js::Value host)
{
	self.js.@bind(host, "setPost", &js_set_post, self)!;
	self.js.@bind(host, "addPass", &js_add_pass, self)!;
	self.js.@bind(host, "clearPost", &js_clear_post, self)!;
	self.js.@bind(host, "setPostUniform", &js_set_post_uniform, self)!;
	self.js.@bind(host, "setPostTexture", &js_set_post_texture, self)!;
	self.js.@bind(host, "toneMapGet", &js_tone_map_get, self)!;
	self.js.@bind(host, "toneMapSet", &js_tone_map_set, self)!;
}

// Which kind of pass, by the name `postSpec` gives it: 'fragment' or 'compute'.
struct PostKindName
{
	PostKind kind;
}

<*
 @return? js::THREW
*>
fn void? PostKindName.from_js(&self, js::Call* c, int at)
{
	@pool()
	{
		switch (c.text(at))
		{
			case "fragment": self.kind = FRAGMENT;
			case "compute": self.kind = COMPUTE;
			default: return c.type_error(at, "'fragment' or 'compute'")~;
		}
	};
}

<*
 `three.setPost({ fragment, uniforms })` — compile a post shader and make it the
 whole chain.

 Needs a device, for `js_create_material`'s reason and one more: a post pass is a
 pipeline *and* a full-size attachment, and there is neither without one.

 @return? js::THREW
*>
fn uint? js_set_post(
	JsRuntime* self,
	String body,
	js::Value uniform_shapes,
	js::Value texture_ids,
	int tap,
	PostKindName kind,
	int threads_x,
	int threads_y,
	js::Value images
)
{
	return self.post_verb(body, uniform_shapes, texture_ids, tap, kind.kind, { whole(threads_x), whole(threads_y) }, images, false);
}

<*
 `three.addPass({ fragment, uniforms })` — compile a post shader and put it at
 the end of the chain.

 The pass reads what the one before it wrote, and image A as `scene`. That is the
 whole dependency declaration and it is adjacency — `render/chain.c3` argues why
 a list is the right shape and what would make it the wrong one.

 @return `The stage index, which is what a handle carries to address its own uniforms.`
 @return? js::THREW
*>
fn uint? js_add_pass(
	JsRuntime* self,
	String body,
	js::Value uniform_shapes,
	js::Value texture_ids,
	int tap,
	PostKindName kind,
	int threads_x,
	int threads_y,
	js::Value images
)
{
	return self.post_verb(body, uniform_shapes, texture_ids, tap, kind.kind, { whole(threads_x), whole(threads_y) }, images, true);
}

<*
 `[{ name, format, size: [w, h], clear }]` as the pass's own image declarations.
 `postSpec` has already refused a malformed entry; a size of zero is the frame's.

 @return? js::THREW
*>
fn void? JsRuntime.read_post_images(&self, js::Value list, List{PostImageDecl}* out)
{
	long count = self.js.length(list)!;
	for (long i = 0; i < count; i++)
	{
		js::Value image = self.js.get(list, i)!;
		js::Value format = self.js.get(image, "format")!;
		js::Value size = self.js.get(image, "size")!;
		if (format.is_nullish() || self.js.length(size)! != 2)
		{
			return self.js.fail("every post image needs a format and a size — one arrived without them")~;
		}
		out.push({
			.name = self.js.text(self.js.get(image, "name")!, tmem),
			.format = self.js.text(format, tmem),
			.width = whole((int)self.js.get_number(size, 0)!),
			.height = whole((int)self.js.get_number(size, 1)!),
			.per_frame = self.js.text(self.js.get(image, "clear")!, tmem) == "frame",
		});
	}
}

<*
 Both verbs, which differ by `append` and nothing else.

 No row counts: a post pass has no instances to select a row with —
 `validate_post` refuses a table by name and `prelude.js` refuses one before it
 gets here.

 @param tap : `An earlier pass this one also reads, or -1. postSpec checked the shape; the range is the chain's to check.`
 @param append : `false replaces the chain (setPost), true appends to it (addPass).`
 @return `The stage index, so a handle knows which pass it is. Always 0 for setPost.`
 @return? js::THREW
*>
fn uint? JsRuntime.post_verb(
	&self,
	String fragment,
	js::Value uniform_shapes,
	js::Value texture_ids,
	int tap,
	PostKind kind,
	uint[2] threads,
	js::Value image_list,
	bool append
)
{
	self.require_gpu("compiling a post shader")!;

	List{MaterialUniform} uniforms;
	uniforms.tinit(4);
	self.read_uniform_shapes(uniform_shapes, &uniforms, tables: false)!;

	List{MaterialTexture} textures;
	List{int} bound;
	textures.tinit(4);
	bound.tinit(4);
	self.read_texture_ids(texture_ids, &textures, &bound)!;

	List{PostImageDecl} images;
	images.tinit(4);
	self.read_post_images(image_list, &images)!;

	// Collected whether the compile failed or only warned, exactly as
	// `js_create_material` collects it: the warning path logs and the failure
	// path throws, and an agent who never sees a warning writes the same mistake
	// twice.
	String diagnostic;
	uint stage = 0;
	// `@catch` rather than `if (catch ...)` around the call itself, because the
	// diagnostic has to be freed on both paths and a `defer` cannot be placed
	// inside the `catch` arm that needs it.
	fault err;
	if (append)
	{
		uint? added = self.renderer.post.add(
			&self.renderer.gpu,
			&self.renderer.target,
			fragment,
			uniforms.array_view(),
			textures.array_view(),
			tap,
			diagnostic: &diagnostic,
			kind: kind,
			images: images.array_view(),
			threads: threads
		);
		err = @catch(added);
		if (!err) stage = added!!;
	}
	else
	{
		// The table is where the outgoing chain's images go back to. It belongs to
		// the mesh pass and the chain belongs to the renderer, so this is the
		// layer that has both.
		err = @catch(
			self.renderer.post.set(
				&self.renderer.gpu,
				&self.renderer.target,
				fragment,
				uniforms.array_view(),
				textures.array_view(),
				&self.pass.assets,
				diagnostic: &diagnostic,
				kind: kind,
				images: images.array_view(),
				threads: threads
			)
		);
	}
	defer if (diagnostic.ptr != null) diagnostic.free(mem);

	if (err) return self.js.fail("%s", post_failure(err, diagnostic))~;

	if (diagnostic.len > 0)
	{
		self.log.append_string("post: ");
		self.log.append_string(diagnostic);
		if (!diagnostic.ends_with("\n")) self.log.append_char('\n');
	}

	// After the compile, because a binding index is something only the compiled
	// module knows. A failure here does not need to undo anything: the script is
	// about to be thrown at, and the pass that is running is the one it just
	// asked for with a sampler still showing white.
	foreach (i, texture : textures)
	{
		if (catch bind_err = self.renderer.post.set_texture(&self.renderer.gpu, &self.pass.assets, texture.name, bound[i], stage))
		{
			return self.js.fail("%s", texture_failure(bind_err, texture.name, "this post shader", "the pass's"))~;
		}
	}

	return stage;
}

// A count from a script, where a negative one means none.
fn uint whole(int value) @local => value < 0 ? 0 : (uint)value;

<*
 `post.textures.<name> = texture` — put an image in one of the samplers one
 pass's body declared.

 `js_set_material_texture` for the pass with no geometry. The stage index is the
 handle's own number, and a script that only ever called `setPost` always sends 0.

 @return? js::THREW
*>
fn void? js_set_post_texture(JsRuntime* self, String name, int texture, int stage)
{
	if (self.renderer == null) return self.js.fail("there is no post pass in this context — it has no GPU device")~;

	if (catch err = self.renderer.post.set_texture(&self.renderer.gpu, &self.pass.assets, name, texture, whole(stage)))
	{
		if (err == MATERIAL_UNKNOWN)
		{
			return self.js.fail("there is no post shader running — three.setPost({ fragment, textures }) first")~;
		}
		return self.js.fail("%s", texture_failure(err, name, "this post shader", "the pass's"))~;
	}
}

<*
 Turns a post fault into a sentence an agent can act on.

 `material_failure`'s three steps against the post pass's own diagnostic buffer:
 the compiler's text if there is any, then whatever `post_source` refused in words, then
 a sentence per fault for the ones that reach here with neither.

 The compiler's text goes through verbatim because `#line` has already made its
 coordinates the agent's own — `post:3:24` is line 3 of the body they typed.
*>
fn String post_failure(fault err, String diagnostic) @local
{
	if (diagnostic.len > 0) return diagnostic;

	// `post_source` leaves a sentence naming what it refused and why — which
	// uniform, how many bytes — and that is strictly better than re-deriving one
	// from the fault alone. Empty after a successful assembly, which is what makes
	// the switch below reachable.
	String noted = post_diagnostic();
	if (noted.len > 0) return noted;

	switch (err)
	{
		case POST_BODY_EMPTY:
			return "a post pass needs a fragment body — `fragment` was empty";
		case POST_NAME_INVALID:
			return "a post uniform name must be a plain identifier and not a shady keyword, and a post texture must not take a name the post template declares";
		case POST_TOO_MANY_UNIFORMS:
			return string::tformat(
				"those uniforms do not fit the push block — a post pass has %d bytes, %d floats",
				POST_UNIFORM_BUDGET,
				POST_UNIFORM_BUDGET / 4
			);
		case POST_TOO_MANY_TEXTURES:
			return string::tformat("a post pass may declare %d textures of its own", POST_TEXTURE_LIMIT);
		case POST_COMPUTE_BODY:
			return "a compute pass is whole functions with a `@compute @threads(x, y, 1)` entry point among them";
		case POST_PASS_WRITES_NOTHING:
			return "this compute pass writes nothing — store to `output[px]`, or to an image the pass declares";
		case POST_TAP_SIDE_PASS:
			return "`reads` names a side pass, which writes no frame to read";
		case POST_TOO_MANY_IMAGES:
			return string::tformat("a post pass may declare %d images of its own", POST_IMAGE_LIMIT);
		case POST_IMAGE_INVALID:
		case POST_IMAGE_CONFLICT:
			return "a post image is declared wrongly, or differently from a pass already in the chain";
		case STORAGE_FORMAT_UNSUPPORTED:
			return "a post image asks for a format this device cannot store to";
		case SHADER_COMPILE_FAILED:
			return "the post shader failed to compile and no diagnostic came back";
		default:
			return string::tformat("the post pass could not be built: %s", err);
	}
}


<*
 `three.setPost(null)` — stop post-processing.

 A no-op on a runtime with no device and a no-op on a pass that was never set, so
 a script can call it unconditionally. `PostPass.clear` makes the same promise
 one layer down.
*>
fn void js_clear_post(JsRuntime* self)
{
	if (self.renderer == null) return;
	// With the table, so the shader's images are given back rather than held by a
	// pass that is no longer running.
	self.renderer.post.clear(&self.renderer.gpu, &self.pass.assets);
}

// ============================================================================
// The tonemap — the engine's own pass, which is not one of the script's
// ============================================================================

// The modes by the names a script writes, in `ToneMap` order.
const String[3] TONE_MAP_NAMES = { "none", "agx", "agx-blender" };

// A tonemap mode argument, by name.
struct ToneMapName
{
	ToneMap mode;
}

<*
 A typo is the whole failure mode of a string enum, so an unknown name is refused
 with the list rather than quietly rendering as the identity.

 @return? js::THREW
*>
fn void? ToneMapName.from_js(&self, js::Call* c, int at)
{
	@pool()
	{
		String name = c.text(at);
		foreach (i, known : TONE_MAP_NAMES)
		{
			if (name != known) continue;
			self.mode = ToneMap::from_ordinal(i);
			return;
		}
		return c.js.fail_with(TYPE_ERROR, "three.toneMapping: unknown mode '%s' — one of %s", name,
			"none, agx, agx-blender")~;
	};
}

struct ToneMapRead
{
	String mode;
	float exposure;
}

<*
 `toneMapGet()` — the tonemap, as `{ mode, exposure }`.

 Answers with the defaults on a runtime with no device, rather than raising.
 Reading `three.toneMapping` is harmless where there is nothing to tone map, and
 a getter that throws would make the property unreadable in a script that never
 asked for a device.
*>
fn ToneMapRead js_tone_map_get(JsRuntime* self)
{
	if (self.renderer == null) return { TONE_MAP_NAMES[0], 1.0 };
	return {
		TONE_MAP_NAMES[self.renderer.post.tonemap_mode.ordinal],
		self.renderer.post.tonemap_exposure,
	};
}

<*
 `toneMapSet(mode, exposure)` — the curve, and what it multiplies by.

 Both at once for `shadowSet`'s reason: two properties over one pair of verbs is
 one crossing per write and one place where the two can be read back consistent
 with each other.

 The mode is the expensive half — it retires a pipeline and compiles a new one,
 and with no script pass in the chain it also allocates image A — so it goes
 through `PostPass.set_tonemap`, which does nothing at all when the mode has not
 moved. The exposure is a 4-byte write and always cheap.

 Needs a device, for `post_verb`'s reason: the tonemap is a pipeline and a
 full-size attachment, and there is neither without one.

 @return? js::THREW
*>
fn void? js_tone_map_set(JsRuntime* self, ToneMapName mode, float exposure)
{
	if (self.renderer == null)
	{
		return self.js.fail("the tonemap is a shader over the finished frame, and this context has no GPU device")~;
	}
	self.renderer.post.set_tonemap_exposure(exposure);
	if (catch err = self.renderer.post.set_tonemap(&self.renderer.gpu, &self.renderer.target, mode.mode))
	{
		return self.js.fail("the tonemap could not be built: %s", err)~;
	}
}

<*
 `post.uniforms.<name> = value` — write one post uniform's bytes.

 `setUniform` without the row and row count, because there is no table.

 @param values : `An array of one to four numbers; its length is the width.`
 @return? js::THREW
*>
fn void? js_set_post_uniform(JsRuntime* self, String name, js::Value values, int stage)
{
	if (self.renderer == null) return self.js.fail("there is no post pass in this context — it has no GPU device")~;

	float[4] numbers;
	usz count = self.uniform_numbers(values, &numbers, name)!;

	if (catch err = self.renderer.post.set_uniform(name, numbers[:count], whole(stage)))
	{
		if (err == MATERIAL_UNIFORM_WIDTH)
		{
			return self.js.fail("uniform '%s' was declared with a different number of components", name)~;
		}
		return self.js.fail("the post pass has no uniform called '%s'", name)~;
	}
}
