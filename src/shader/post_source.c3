<*
 A post pass's declarations, checked before a module is generated around them.

 `material_source.c3`'s counterpart, applied to the frame instead of to a
 surface: the body is `fn float3 post(Post p)`, its uniforms are reached through
 `p.uniforms`, and its samplers are declared beside the four the engine reserves.

 `info` is a `float4` at offset 0: the target's extent in `xy`, seconds since the
 shader was set in `z`, and a fourth component reserved rather than removed. A
 scalar-layout block wants four-byte alignment and nothing more, so the fourth
 float is free — a fifth *field* would not be, since every uniform after it would
 move and `POST_PUSH_FIELDS` pins `info` at 0+16. That leaves 104 of the 128
 every device must offer for a script's own uniforms.

 The diagnostic is a value rather than a line on stderr, so the text can go
 inside the exception a script catches. It uses a separate buffer from the
 material one, so a post shader refused while a material's diagnostic is still
 unread does not overwrite an answer somebody is about to print.
*>
module three;

import shady;
import std::collections::list;


faultdef POST_NAME_INVALID, POST_TOO_MANY_UNIFORMS, POST_BODY_EMPTY, POST_TOO_MANY_TEXTURES;
faultdef POST_TAP_UNKNOWN;
faultdef POST_COMPUTE_BODY, POST_IMAGE_INVALID, POST_TOO_MANY_IMAGES, POST_PASS_WRITES_NOTHING, POST_TAP_SIDE_PASS,
	POST_IMAGE_CONFLICT;

<*
 Which kind of pass a body is: a function the fragment template calls once per
 pixel, or a compute entry point the engine dispatches over the frame.
*>
enum PostKind : char
{
	FRAGMENT,
	COMPUTE,
}

<*
 One storage image a post pass declares for itself: the name the body uses, the
 format it is declared as, and its size - zero for the frame's own, which is
 what a history or a mask wants and what follows the frame when it resizes.

 `per_frame` clears it to zero at the start of every frame, for an image that is
 an accumulator *within* a frame - a histogram - rather than across frames.
*>
struct PostImageDecl
{
	String name;
	String format;
	uint width;
	uint height;
	bool per_frame;
}

<*
 How many samplers of its own a post pass may declare, on top of `prev` and
 `scene`.

 `MATERIAL_TEXTURE_LIMIT`'s argument minus the half about per-bucket traffic —
 there is one post draw in a frame, so a binding here is paid for once. It has
 not moved with that limit because the other half holds and the pressure does
 not: a stack of terrain layers is a material and never a post pass, and five
 images in one pass is an atlas or an array, neither of which this project has.
*>
const uint POST_TEXTURE_LIMIT = 4;

<*
 Bytes of push block available to post uniforms, after `info`.

 Spelled as a number and checked against `POST_PUSH_FIELDS` by the `$assert`
 below, for `MATERIAL_UNIFORM_BUDGET`'s reason: deriving it from a C3 struct
 would hand out that struct's tail padding, which the shader's layout does not
 contain.
*>
const uint POST_UNIFORM_BUDGET = 104;

<*
 Where a post pass's uniforms begin in the push block.

 `info` and `planes` are the whole contract below this, so the number is 24 —
 derived from `POST_PUSH_FIELDS` by assertion rather than copied. It was 16
 until `p.depth` arrived and the camera's planes had to reach the shader, which
 costs a body two floats of a budget nothing has come close to.
*>
const uint POST_PUSH_START = 24;

$assert POST_PUSH_FIELDS[POST_PUSH_FIELDS.len - 1].offset + POST_PUSH_FIELDS[POST_PUSH_FIELDS.len - 1].size
	== POST_PUSH_START : "`info` moved; post uniforms no longer start where the post contract ends";
$assert POST_PUSH_START + POST_UNIFORM_BUDGET == PUSH_BUDGET : "the post uniform budget and the push budget disagree";

// What the agent's own lines are called in a diagnostic: `post:3:24` is a
// coordinate in the string the agent typed.
const String POST_BODY_NAME = "post";

// What everything three.c3 generated is called. Self-describing rather than
// short, because a note from inside the generated module names this file
// whatever the body did.
const String POST_PREAMBLE_NAME = "three.post";

const usz POST_DIAGNOSTIC_MAX @local = 512;

char[POST_DIAGNOSTIC_MAX] post_message @local;
usz post_message_len @local;

<*
 What the last `validate_post` refused, in words.

 @return `A view valid until the next call to validate_post. Empty if the last call succeeded.`
*>
fn String post_diagnostic() => (String)post_message[:post_message_len];

fn void post_note(String message) @local
{
	post_message_len = shader_note_into(post_message[..], message);
}

<*
 What the uniforms cost in the push block.

 `sum(components) * 4`, with no alignment arithmetic: the compile passes
 `-force-glsl-scalar-layout` and every field here is a multiple of four. The
 offsets are still never computed — reflection reads them back off the module
 that will run.
*>
fn uint post_uniform_bytes(MaterialUniform[] uniforms)
{
	uint total = 0;
	foreach (uniform : uniforms) total += uniform.components * 4;
	return total;
}

<*
 Every name the post template declares at the top level, plus the two the def
 generates beside it, read off the shipped (or on-disk) file. Allocated from
 tmem; empty if the template does not parse, which the compile then reports.
*>
fn String[] post_template_names(PostKind kind = PostKind.FRAGMENT) @local
{
	String? text = load_source(kind == PostKind.COMPUTE ? ShaderFile.POST_COMPUTE_SHADY : ShaderFile.POST_SHADY, tmem);
	if (catch text) return {};
	String[]? names = shady::top_level_names(text, tmem);
	if (catch names) return {};
	List{String} all;
	all.tinit(names.len + 3);
	foreach (name : names) all.push(name);
	all.push("Uniforms");
	all.push("material_uniforms");
	all.push("material_unused");
	return all.array_view();
}

<*
 Everything that can be refused before a module is generated.

 The body first, then each name, then the budget — `validate_material`'s order
 and its argument: "these thirty floats do not fit" is only useful once each of
 them is known to be a real uniform.

 @return ? POST_BODY_EMPTY : `The fragment body is empty or only whitespace.`
 @return ? POST_NAME_INVALID : `A uniform or texture name is not an identifier, is one the generated module already uses, is a keyword, is repeated, is not 1 to 4 floats wide, or asked for more than one row.`
 @return ? POST_TOO_MANY_UNIFORMS : `The uniforms want more of the push block than info leaves.`
 @return ? POST_TOO_MANY_TEXTURES : `More samplers than POST_TEXTURE_LIMIT.`
 @return ? POST_COMPUTE_BODY : `A compute body that is not whole functions with a @compute entry point among them.`
 @return ? POST_IMAGE_INVALID : `An image whose name is not an identifier or is taken, whose format is not a storage format, or whose size is half given.`
 @return ? POST_TOO_MANY_IMAGES : `More images than POST_IMAGE_LIMIT.`
*>
fn void? validate_post(String fragment, MaterialUniform[] uniforms, MaterialTexture[] textures,
	PostKind kind = PostKind.FRAGMENT, PostImageDecl[] images = {})
{
	@pool()
	{
		if (fragment.trim().len == 0)
		{
			post_note(kind == PostKind.COMPUTE
				? "post: the compute body is empty; it must define `fn void main(PostThread t) @compute @threads(8, 8, 1)`"
				: "post: the fragment body is empty; it must define `float3 post(Post p)`");
			return POST_BODY_EMPTY~;
		}

		// A compute body is the entry point itself, so it cannot be the statements
		// of one: there is no signature to wrap them in, because the workgroup the
		// signature carries is the author's to choose.
		if (kind == PostKind.COMPUTE)
		{
			// A body that does not parse is let through: the compile has the better
			// message for it.
			bool whole = shady::defines_functions(fragment) ?? true;
			if (!whole || !fragment.contains("@compute"))
			{
				post_note("post: a compute pass is whole functions with one entry point among them, "
					"`fn void main(PostThread t) @compute @threads(8, 8, 1) { ... }` - "
					"`t.id.xy` is the pixel, and `output[px] = ...` writes it");
				return POST_COMPUTE_BODY~;
			}
		}

		foreach (i, uniform : uniforms)
		{
			if (!is_identifier(uniform.name))
			{
				post_note(
					string::tformat(
						"post: uniform name '%s' is not an identifier; a name must match [A-Za-z_][A-Za-z0-9_]*",
						uniform.name
					)
				);
				return POST_NAME_INVALID~;
			}

			// A uniform is a field of `Uniforms`, read as `p.uniforms.name`, so
			// `time`, `info` and `color` are all free; only the language's own
			// words are not.
			if (shady::is_keyword(uniform.name))
			{
				post_note(string::tformat("post: uniform name '%s' is a shady keyword", uniform.name));
				return POST_NAME_INVALID~;
			}

			foreach (j, earlier : uniforms)
			{
				if (j >= i) break;
				if (earlier.name != uniform.name) continue;
				post_note(string::tformat("post: uniform '%s' is declared twice", uniform.name));
				return POST_NAME_INVALID~;
			}

			if (uniform.components < 1 || uniform.components > 4)
			{
				post_note(
					string::tformat(
						"post: uniform '%s' is %d floats wide; a uniform is 1 to 4",
						uniform.name,
						uniform.components
					)
				);
				return POST_NAME_INVALID~;
			}

			// The one rule a material has that this inverts. A material's arrays
			// are a table indexed by `Surface.variant`, the per-instance row
			// selector — and a post pass draws one triangle over the whole frame,
			// so there is no instance for a row to belong to and the generated
			// module has no row bound to clamp against. Refused with the reason
			// rather than silently flattened, because a caller asking for four
			// rows believes it can index them.
			if (uniform_rows_of(uniform) > 1)
			{
				post_note(
					string::tformat(
						"post: uniform '%s' asked for %d rows; a post pass draws one triangle over the whole frame, so there are no instances to select a row with",
						uniform.name,
						uniform_rows_of(uniform)
					)
				);
				return POST_NAME_INVALID~;
			}
		}

		// A post pass's samplers are module-level resources, so unlike a uniform
		// they share the template's namespace: a sampler may not take a name the
		// template already declares - `scene`, `prev`, `tap_image`, a helper.
		// Read off the template itself, so the list cannot fall behind it.
		String[] template = post_template_names(kind);
		String texture_note = texture_problem(POST_BODY_NAME, textures, template, POST_TEXTURE_LIMIT);
		if (texture_note.len > 0)
		{
			post_note(texture_note);
			return textures.len > POST_TEXTURE_LIMIT ? POST_TOO_MANY_TEXTURES~ : POST_NAME_INVALID~;
		}

		if (images.len > POST_IMAGE_LIMIT)
		{
			post_note(string::tformat("post: %d images declared, and a pass may declare %d", images.len, POST_IMAGE_LIMIT));
			return POST_TOO_MANY_IMAGES~;
		}
		foreach (i, image : images)
		{
			String problem = post_image_problem(image, i, images, textures, template);
			if (problem.len > 0)
			{
				post_note(problem);
				return POST_IMAGE_INVALID~;
			}
		}

		uint wanted = post_uniform_bytes(uniforms);
		if (wanted > POST_UNIFORM_BUDGET)
		{
			post_note(
				string::tformat(
					"post: the uniforms want %d bytes of push block and %d are free; `info` and `planes` take the other %d of the 128 every device offers",
					wanted,
					POST_UNIFORM_BUDGET,
					PUSH_BUDGET - POST_UNIFORM_BUDGET
				)
			);
			return POST_TOO_MANY_UNIFORMS~;
		}

		post_note("");
	};
}

<*
 What is wrong with one image declaration, as a sentence, or "".

 An image is a module-level resource like a sampler, so it shares the
 template's namespace and the textures': `output`, `prev` and a texture the same
 pass declared are all taken.
*>
fn String post_image_problem(PostImageDecl image, sz index, PostImageDecl[] images, MaterialTexture[] textures,
	String[] template) @local
{
	if (!is_identifier(image.name) || shady::is_keyword(image.name))
	{
		return string::tformat("post: image name '%s' is not an identifier this module can declare", image.name);
	}
	foreach (name : template)
	{
		if (name == image.name) return string::tformat("post: image name '%s' is one the post template already declares", image.name);
	}
	foreach (texture : textures)
	{
		if (texture.name == image.name) return string::tformat("post: '%s' is declared as both a texture and an image", image.name);
	}
	foreach (j, earlier : images)
	{
		if (j >= index) break;
		if (earlier.name == image.name) return string::tformat("post: image '%s' is declared twice", image.name);
	}
	if (catch storage_format_named(image.format))
	{
		String hint = storage_format_hint(image.format);
		return hint.len > 0
			? string::tformat("post: image '%s' asks for '%s', which is not a storage format - did you mean %s?",
				image.name, image.format, hint)
			: string::tformat("post: image '%s' asks for '%s', which is not a storage format - rgba16f, rgba8, r32f "
				"and r32ui are the common ones", image.name, image.format);
	}
	if ((image.width == 0) != (image.height == 0))
	{
		return string::tformat("post: image '%s' is %dx%d - give both sides, or neither for the frame's own size",
			image.name, image.width, image.height);
	}
	return "";
}
