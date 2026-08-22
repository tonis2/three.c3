<*
 A post-processing pass, as a string: the agent's `float3 post(Post p)` and
 everything Slang needs around it.

 `material_source.c3`'s second half, applied to the frame instead of to a
 surface. The two share `shader/assemble.c3` — the marker walk and the `#line`
 arithmetic — and share nothing else, because everything else about them is
 different:

	                  material                post
	 template         material.slang          post.slang
	 body             float3 shade(Surface)   float3 post(Post)
	 push block       76 bytes of mesh        16 bytes of `info`
	 budget           52 bytes                112 bytes
	 tables           yes, `//@rows`          no — there are no instances
	 bindings         the base colour map     the frame just rendered

 ## Why the budget is 112 and not 128

 `info` is a `float4` at offset 0: the target's extent in `xy`, seconds since
 the shader was set in `z`, and a fourth component that is reserved rather than
 removed. A scalar-layout block wants four-byte alignment and nothing more, so
 the fourth float is genuinely free — a fifth *field* would not be, because
 every uniform after it would move and `POST_PUSH_FIELDS` pins `info` at 0+16.

 That leaves 112 of the 128 every device must offer, against a material's 52.
 A post pass is the one shader in this project with almost the whole block to
 itself, which is the compensation for having no vertex data, no instance
 array and no scene at all.

 ## The diagnostic is a value, not a line on stderr

 Same decision as `material_diagnostic`, same reason: `plan.md` §4 wants the
 text inside the exception a script catches, and a script cannot read a file
 descriptor. **A separate buffer from the material one**, so that a post shader
 refused while a material's diagnostic is still unread does not overwrite an
 answer somebody is about to print.
*>
module three;

import std::io;

faultdef POST_NAME_INVALID, POST_TOO_MANY_UNIFORMS, POST_BODY_EMPTY;

<*
 Bytes of push block available to post uniforms, after `info`.

 Spelled as a number and checked against `POST_PUSH_FIELDS` by the `$assert`
 below, for `MATERIAL_UNIFORM_BUDGET`'s reason: deriving it from a C3 struct
 would hand out that struct's tail padding, which the shader's layout does not
 contain.
*>
const uint POST_UNIFORM_BUDGET = 112;

<*
 Where a post pass's uniforms begin in the push block.

 `info` is the whole of the contract below this, so the number is 16 — and it is
 derived from `POST_PUSH_FIELDS` by assertion rather than copied, the same shape
 `MATERIAL_PUSH_START` has against `MESH_PUSH_FIELDS`.
*>
const uint POST_PUSH_START = 16;

$assert POST_PUSH_FIELDS[POST_PUSH_FIELDS.len - 1].offset + POST_PUSH_FIELDS[POST_PUSH_FIELDS.len - 1].size == POST_PUSH_START :
	"`info` moved; post uniforms no longer start where post.slang puts them";
$assert POST_PUSH_START + POST_UNIFORM_BUDGET == PUSH_BUDGET :
	"the post uniform budget and the push budget disagree";

// The template, looked up the same way `mesh.slang` and `material.slang` are —
// `shaders/` first, then `build/shaders/`, both relative to the working
// directory.
const String POST_TEMPLATE = "post.slang";

// What the agent's own lines are called in a diagnostic: `post:3:24` is a
// coordinate in the string the agent typed.
const String POST_BODY_NAME = "post";

// What everything three.c3 generated is called. Self-describing rather than
// short, for `MATERIAL_PREAMBLE_NAME`'s reason: Slang's `candidate:` notes point
// into the preamble whatever the body did.
const String POST_PREAMBLE_NAME = "three.post";

<*
 Names a post uniform may not take.

 The same two groups as `MATERIAL_RESERVED` and the same trade — a short list of
 collisions turned into a good message, a long tail left to fail as an ordinary
 Slang diagnostic at `post:<line>`, which is where the agent can act on it.

 The first group is what `shaders/post.slang` declares. Three of them are worth
 naming individually because they break in ways the message would not otherwise
 explain:

 - `info` is a *field* of the same struct the uniforms are appended to, so a
   second one is a duplicate member rather than a substitution problem.
 - `post` and `p` are the body's own function and parameter. A `#define p
   (push.p)` is live across exactly the lines the agent wrote, so it rewrites
   the signature they are declared in.
 - `scene` is the sampler. A body has no reason to touch it — `p.color` is that
   sample already — but a uniform by that name would make the template's own
   line unparseable.
*>
const String[*] POST_RESERVED @local = {
	// What the template declares.
	"push", "PushData", "info", "scene", "Post", "p", "VertexOutput",
	"vertexMain", "fragmentMain", "post", "output", "vid",
	// Types.
	"float", "float2", "float3", "float4", "float2x2", "float3x3", "float4x4",
	"int", "int2", "int3", "int4", "uint", "uint2", "uint3", "uint4",
	"bool", "bool2", "bool3", "bool4", "half", "double", "void",
	"Sampler2D", "Texture2D", "SamplerState",
	// Keywords.
	"return", "if", "else", "for", "while", "do", "switch", "case", "default",
	"break", "continue", "struct", "const", "static", "in", "out", "inout",
	"discard", "true", "false", "typedef", "namespace", "uniform", "cbuffer",
	"groupshared",
};

const usz POST_DIAGNOSTIC_MAX @local = 512;

char[POST_DIAGNOSTIC_MAX] post_message @local;
usz post_message_len @local;

<*
 What the last `post_source` refused, in words.

 @return `A view valid until the next call to post_source. Empty if the last call succeeded.`
*>
fn String post_diagnostic() => (String)post_message[:post_message_len];

fn void post_note(String message) @local
{
	post_message_len = shader_note_into(post_message[..], message);
}

<*
 What the uniforms cost in the push block.

 `sum(components) * 4`, and no alignment arithmetic, for the reason
 `material_uniform_bytes` gives: the compile passes `-force-glsl-scalar-layout`
 and every field here is a multiple of four. The offsets are still never computed
 — reflection reads them back off the module that will run.
*>
fn uint post_uniform_bytes(MaterialUniform[] uniforms)
{
	uint total = 0;
	foreach (uniform : uniforms) total += uniform.components * 4;
	return total;
}

<*
 Everything that can be refused before a line of Slang is written.

 The body first, then each name, then the budget — `validate_material`'s order
 and its argument: "these thirty floats do not fit" is only useful once each of
 them is known to be a real uniform.

 @return? POST_BODY_EMPTY : `The fragment body is empty or only whitespace.`
 @return? POST_NAME_INVALID : `A uniform name is not an identifier, is one the template already uses, is a Slang keyword, is repeated, is not 1 to 4 floats wide, or asked for more than one row.`
 @return? POST_TOO_MANY_UNIFORMS : `The uniforms want more of the push block than info leaves.`
*>
fn void? validate_post(String fragment, MaterialUniform[] uniforms) @local
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
				post_note(string::tformat(
					"post: uniform name '%s' is not an identifier; a name must match [A-Za-z_][A-Za-z0-9_]*",
					uniform.name
				));
				return POST_NAME_INVALID~;
			}

			foreach (reserved : POST_RESERVED)
			{
				if (uniform.name != reserved) continue;
				post_note(string::tformat(
					"post: uniform name '%s' is reserved; the shader three.c3 generates around your body already uses it",
					uniform.name
				));
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
				post_note(string::tformat(
					"post: uniform '%s' is %d floats wide; a uniform is 1 to 4",
					uniform.name,
					uniform.components
				));
				return POST_NAME_INVALID~;
			}

			// **The one rule a material has that this inverts.** A material's
			// arrays are a table indexed by `Surface.variant`, the per-instance
			// row selector — and a post pass draws one triangle over the whole
			// frame, so there is no instance for a row to belong to and
			// `post.slang` has no `//@rows` to generate a bound from. Refused
			// with the reason rather than silently flattened, because a caller
			// asking for four rows believes it can index them.
			if (uniform_rows_of(uniform) > 1)
			{
				post_note(string::tformat(
					"post: uniform '%s' asked for %d rows; a post pass draws one triangle over the whole frame, so there are no instances to select a row with",
					uniform.name,
					uniform_rows_of(uniform)
				));
				return POST_NAME_INVALID~;
			}
		}

		uint wanted = post_uniform_bytes(uniforms);
		if (wanted > POST_UNIFORM_BUDGET)
		{
			post_note(string::tformat(
				"post: the uniforms want %d bytes of push block and %d are free; `info` takes the other %d of the 128 every device offers",
				wanted,
				POST_UNIFORM_BUDGET,
				PUSH_BUDGET - POST_UNIFORM_BUDGET
			));
			return POST_TOO_MANY_UNIFORMS~;
		}

		post_note("");
	};
}

<*
 Assemble the full Slang module for a post pass.

 Self-contained, like `material_source`'s result: its own `PushData`, its own
 binding and both entry points, handed to `compile_slang_cached` as a string.
 Nothing is compiled here and no GPU is involved.

 @param fragment : `The agent's body. Must define float3 post(Post p); everything else is theirs.`
 @param uniforms : `Names and widths, in the order they should be laid out. Reached from the body as bare names. rows must be 0 or 1.`
 @return `The whole module, allocated from allocator and owned by the caller.`
 @return? POST_BODY_EMPTY : `The body is empty. post_diagnostic() has the sentence.`
 @return? POST_NAME_INVALID : `A uniform name, width or row count is one this cannot generate. post_diagnostic() names it.`
 @return? POST_TOO_MANY_UNIFORMS : `The uniforms do not fit in what info leaves of the push block.`
 @return? SHADER_NOT_FOUND : `shaders/post.slang is not on the search path — the same condition, and the same fix, as a missing mesh.slang.`
*>
fn String? post_source(String fragment, MaterialUniform[] uniforms, alloc::Allocator allocator = mem)
{
	validate_post(fragment, uniforms)!;
	return assemble_shader(POST_TEMPLATE, fragment, uniforms, POST_BODY_NAME, POST_PREAMBLE_NAME, allocator);
}
