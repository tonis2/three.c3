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


faultdef POST_NAME_INVALID, POST_TOO_MANY_UNIFORMS, POST_BODY_EMPTY, POST_TOO_MANY_TEXTURES;
faultdef POST_TAP_UNKNOWN;

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

<*
 Names a post uniform may not take.

 The same two groups as `MATERIAL_RESERVED`: a short list of collisions turned
 into a good message, with the long tail left to fail as an ordinary compiler
 diagnostic at `post:<line>`, where the agent can act on it.

 The first group is what the generated module declares. Three break in ways the
 message would not otherwise explain:

 - `info` is a *field* of the same struct the uniforms are appended to, so a
 second one is a duplicate member rather than a substitution problem.
 - `post` and `p` are the body's own function and parameter. A `#define p
 (push.p)` is live across exactly the lines the agent wrote, so it rewrites the
 signature they are declared in.
 - `prev` and `scene` are the two reserved samplers. A body has both as
 same-pixel samples already (`p.color`, `p.scene`) and reaches the globals only
 to sample a *different* pixel — a blur, a bloom combine — so a uniform by
 either name would make the template's own declaration unparseable.
*>
const String[*] POST_RESERVED @local = { // What the template declares.
	"push",
	"PushData",
	"info",
	"planes",
	"prev",
	"scene",
	"depth_buffer",
	"tap_image",
	"Post",
	"p",
	"VertexOutput",
	"vertexMain",
	"fragmentMain",
	"post",
	"output",
	"vid",
	"d",
	"near",
	"far",
	"span", // What the generators declare around the agent's uniforms: the struct a body
	// reads them through, the padding field a pass with no uniforms still gets,
	// and the function the material half fills them with. Reserved before the
	// switchover rather than at it, for `MATERIAL_RESERVED`'s reason: a name is
	// reservable exactly once.
	"Uniforms",
	"material_unused",
	"material_uniforms", // Types.
	"float",
	"float2",
	"float3",
	"float4",
	"float2x2",
	"float3x3",
	"float4x4",
	"int",
	"int2",
	"int3",
	"int4",
	"uint",
	"uint2",
	"uint3",
	"uint4",
	"bool",
	"bool2",
	"bool3",
	"bool4",
	"half",
	"double",
	"void",
	"Sampler2D",
	"Texture2D",
	"SamplerState", // Keywords.
	"return",
	"if",
	"else",
	"for",
	"while",
	"do",
	"switch",
	"case",
	"default",
	"break",
	"continue",
	"struct",
	"const",
	"static",
	"in",
	"out",
	"inout",
	"discard",
	"true",
	"false",
	"typedef",
	"namespace",
	"uniform",
	"cbuffer",
	"groupshared",
};

<*
 The field names of `Post`, which a uniform may not take either.

 `MATERIAL_CONTRACT_FIELDS`'s argument, and this is the list it was found on: a
 post pass's most natural uniform name is `time`, `Post` has a field called
 `time`, and `#define time (push.time)` turns the `p.time` in the agent's own
 body into `p.(push.time)` — a syntax error at a line of generated preamble,
 about a member access that was written correctly.

 `time` is worth refusing loudly rather than quietly renaming, because the
 uniform is usually redundant: `p.time` already carries seconds since the shader
 was set.
*>
const String[*] POST_CONTRACT_FIELDS @local = { "color", "scene", "uv", "resolution", "time", "depth", "tap", "uniforms" };

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
 Everything that can be refused before a module is generated.

 The body first, then each name, then the budget — `validate_material`'s order
 and its argument: "these thirty floats do not fit" is only useful once each of
 them is known to be a real uniform.

 @return ? POST_BODY_EMPTY : `The fragment body is empty or only whitespace.`
 @return ? POST_NAME_INVALID : `A uniform or texture name is not an identifier, is one the generated module already uses, is a keyword, is repeated, is not 1 to 4 floats wide, or asked for more than one row.`
 @return ? POST_TOO_MANY_UNIFORMS : `The uniforms want more of the push block than info leaves.`
 @return ? POST_TOO_MANY_TEXTURES : `More samplers than POST_TEXTURE_LIMIT.`
*>
fn void? validate_post(String fragment, MaterialUniform[] uniforms, MaterialTexture[] textures)
{
	@pool()
	{
		if (fragment.trim().len == 0)
		{
			post_note("post: the fragment body is empty; it must define `float3 post(Post p)`");
			return POST_BODY_EMPTY~;
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

			foreach (reserved : POST_RESERVED)
			{
				if (uniform.name != reserved) continue;
				post_note(
					string::tformat(
						"post: uniform name '%s' is reserved; the shader three.c3 generates around your body already uses it",
						uniform.name
					)
				);
				return POST_NAME_INVALID~;
			}

			foreach (field : POST_CONTRACT_FIELDS)
			{
				if (uniform.name != field) continue;
				post_note(
					string::tformat(
						"post: uniform name '%s' is a field of Post, so it would rewrite p.%s in your own body — rename the uniform%s",
						uniform.name,
						uniform.name,
						uniform.name == "time" ? " (and p.time is already the clock)" : ""
					)
				);
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

		// `validate_material`'s placement and reason: a sampler is checked
		// against the uniforms as well as against the template's own names, so
		// both lists have to be individually sound first.
		String texture_note = texture_problem(
			POST_BODY_NAME,
			textures,
			uniforms,
			POST_RESERVED[..],
			POST_TEXTURE_LIMIT
		);
		if (texture_note.len > 0)
		{
			post_note(texture_note);
			return textures.len > POST_TEXTURE_LIMIT ? POST_TOO_MANY_TEXTURES~ : POST_NAME_INVALID~;
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
