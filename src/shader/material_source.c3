<*
 A material, as a string: the agent's fragment body and everything Slang needs
 around it.

 `plan.md` §4's tier 2 is one sentence — "three.c3 supplies the vertex stage, the
 `Surface` struct, the descriptor layout and the uniform block; the agent writes
 the shading body" — and this file is the half of it that is not the compiler.
 Nothing here compiles, creates a pipeline or touches the GPU. It reads
 `shaders/material.slang`, replaces three marker lines, and hands back a
 self-contained module.

 **The marker walk itself lives in `shader/assemble.c3`**, which
 `shaders/post.slang` goes through as well. What stays here is everything a
 *material* is: the mesh contract it appends to, the uniform table, the reserved
 names and the budget. What moved is the line counting, because it is the one
 half of the two that must not exist twice.

 ## Why the line numbers are the interesting part

 The agent wrote four lines and gets back a four-hundred-line module. A
 diagnostic that says `material.slang:312` names a file the agent has never seen,
 at a line it did not write, and the loop that `plan.md` §4 calls "the whole
 contract" stalls on the agent trying to find line 312.

 So the body is bracketed by `#line` directives:

	#line 1 "material"
	float3 shade(Surface s)
	{
	    return s.albedo * notAFunction(s.uv);
	}
	#line 141 "three.material"

 and Slang then reports `material:3:24`, echoing the agent's own text under the
 caret. The restore directive is not decoration either: on an arity or overload
 failure Slang emits a `note[E40011]: candidate:` record pointing back into the
 preamble, and `three.material:141` at least says plainly that the line is not
 the agent's. Suppressing that note would be worse — it is usually the half that
 says "expected 2".

 Three things about `#line` were established by experiment rather than assumed,
 and each of them is a way to get this wrong:

 - The filename **must** be a double-quoted string literal. `#line 1 material`
   is `E15102`, a hard preprocessor error that kills the compile. Nothing
   interpolated into a directive can contain a quote or a backslash, which is one
   of the things `MATERIAL_RESERVED`'s identifier check is really for.
 - The directive numbers the line that *follows* it, so the body starts at `1`
   and not `0`. `0` is accepted and faithfully reported as `:0:`.
 - The restore number is the physical line of the text after the directive,
   which nothing but the assembler can know — it is counted rather than
   computed, because every marker replacement changes it.

 All three are now stated where they are implemented, in `shader/assemble.c3`.
*>
module three;

import std::io;

faultdef MATERIAL_NAME_INVALID, MATERIAL_TOO_MANY_UNIFORMS, MATERIAL_BODY_EMPTY, MATERIAL_TOO_MANY_TEXTURES;

<*
 One sampler the agent asked for, as the JS side named it.

 There is no width, no type and no binding index here, and each absence is the
 point. A texture is a `Sampler2D` because that is the only image kind this
 project binds; and its binding index is **generated from the position of this
 entry in the array** rather than carried on it, which is what keeps the number
 out of every layer above `shader/assemble.c3`. See `MATERIAL_BINDING_FIRST`.

 So a material's textures are, end to end, a list of names: the script writes
 them, the assembler numbers them, reflection reads the numbers back, and
 `Material.set_texture` resolves a name to a binding through the reflected
 layout. The number exists in exactly one file.
*>
struct MaterialTexture
{
	String name;  // borrowed from the caller
}

<*
 One material uniform, as the JS side described it.

 `rows` is what makes a uniform a **column of a table** rather than a single
 value: one row is `float3 tint;` and three rows are `float3 tint[3];`, indexed
 in the body by `s.variant` — the per-instance row selector in `scene/scene.c3`.
 That is the whole of "one material, many appearances, one draw call": the
 pipeline and the push block are bucket state and cannot vary per copy, so the
 variation has to be a *lookup* the copies do rather than a value they carry.

 Every column of one material must have the same number of rows. It is a table,
 not a bag of arrays — and it is also what makes `s.variant`'s clamp exact, since
 there is then one row count to clamp against instead of one per column.
*>
struct MaterialUniform
{
	String name;      // borrowed from the caller
	uint components;  // 1..4 floats
	uint rows;        // 1 for a plain uniform, N for a column of an N-row table
}

<*
 Bytes of push block available to material uniforms, after the mesh contract.

 128 is the push size every Vulkan implementation must offer and `PUSH_BUDGET`
 treats it as a budget rather than a limit to grow into; the eight fields
 `MESH_PUSH_FIELDS` pins take 76 of it. What is left is what a material may
 spend, and it is spelled here as a number rather than derived from
 `MeshPush::size` on purpose: `MeshPush` is 80 bytes and only 76 of them reflect,
 the difference being C3 tail padding, so deriving it would quietly hand out four
 bytes that the shader's layout does not contain.

 **This was 68 and is now 52**, because `uv_transform` was added to the mesh
 contract. That is four rows of four floats down to three, or five rows of three
 down to four, and it was not free — the trade was made deliberately. Material
 uniforms are a `ShaderMaterial` feature and nothing else; the uv transform is
 needed most by a ground plane wearing a `MeshLambertMaterial`, which has no
 uniform block to put it in. Spending a shared 16 bytes so that every material
 can tile is worth more than a fourth row for the ones that compile a body.

 The way past this for either of them is the same and is written down in
 `plan.md` §2: a device buffer behind a BDA in the push block, at which point the
 budget stops being 128 bytes and starts being memory.
*>
const uint MATERIAL_UNIFORM_BUDGET = 52;

<*
 How many samplers of its own a material may declare, on top of `map`.

 A budget rather than a device limit, the same way `PUSH_BUDGET` is. The real
 ceiling is `maxPushDescriptors`, which every implementation that offers the
 extension must report as at least 32 — so eight plus the base colour map cannot
 be refused by a device, and nothing here has to query anything or have a
 fallback path for a machine that says a smaller number.

 **This was four and is now eight, and the thing that moved it is a layer
 stack.** Four was chosen against what a hand-written effect uses — a pattern, a
 ramp and a mask, with the fourth there so three was not a cap anybody hit on
 their first attempt. A `LayeredMaterial` is not hand-written: `js/prelude/layers.js`
 generates one sampler per layer plus one for the packed mask, so four bought
 three layers over the base and no room for a normal map on any of them. Eight
 buys a mask, up to seven detail maps, or a mix of maps and normals — which is
 the difference between the extension being representable and being *usable*.

 What it costs is real and is per draw: the descriptors are pushed **per
 bucket**, so every declared sampler is command traffic on every material that
 declares one. Eight is still short of the 32 floor, and a material wanting more
 images than this wants an atlas or a texture array — both of which are one
 binding, and neither of which exists here yet.
*>
const uint MATERIAL_TEXTURE_LIMIT = 8;

// The template, looked up the same way `mesh.slang` is — `shaders/` first, then
// `build/shaders/`, both relative to the working directory.
const String MATERIAL_TEMPLATE = "material.slang";

<*
 What the agent's own lines are called in a diagnostic.

 Short and lower case because it is read by whoever wrote the body, not by
 whoever wrote the compiler: `material:3:24` is a coordinate in the string the
 agent typed.
*>
const String MATERIAL_BODY_NAME = "material";

<*
 What the agent's *vertex* lines are called in a diagnostic.

 A second name rather than a second file: both bodies are spliced into one module
 and Slang reports one coordinate, so `vertex:3:12` against `material:3:12` is the
 only thing that says which of the two an error is in. An agent that wrote both
 and got `material:3` for a mistake in its vertex body would look at the wrong
 four lines.
*>
const String MATERIAL_VERTEX_NAME = "vertex";

<*
 What everything three.c3 generated is called in a diagnostic.

 Deliberately self-describing rather than short. Slang's `candidate:` notes point
 into the preamble whatever the body did, and an agent that sees
 `three.material:141` can tell at a glance that the line is not one of its own —
 which is the only thing it needs to conclude from it.
*>
const String MATERIAL_PREAMBLE_NAME = "three.material";

<*
 Names a material uniform may not take.

 Two groups, and they are refused for different reasons. The first is everything
 `shaders/material.slang` declares or names in a line the `#define`s can reach: a
 uniform called `shade` or `push` produces a substitution that breaks the
 template, and the resulting diagnostic points at generated code the agent cannot
 see. The second is Slang and HLSL's own vocabulary, where `#define float ...`
 is legal, silent, and turns the rest of the module into something no error
 message will explain.

 The list is not complete and cannot be — Slang's standard library is thousands
 of names, and reserving all of them would refuse `time` and `tint` along the
 way. It covers what the template touches and the keywords worth a sentence, and
 anything past it fails as an ordinary Slang diagnostic at `material:<line>`,
 which is where the agent can act on it. That is the trade: a short list of
 collisions turned into a good message, and a long tail turned into a normal one.
*>
const String[*] MATERIAL_RESERVED @local = {
	// What the template declares.
	"push", "s", "shade", "Surface", "VertexOutput", "PushData", "FrameBlock",
	"Instance", "vertexMain", "fragmentMain", "base_color_map", "lambert",
	"srgb_to_linear",
	// The vertex half of the same contract. `v` and `displace` are the body's own
	// parameter and function, exactly as `s` and `shade` are the fragment body's;
	// `Vertex` is the struct both of them name.
	"v", "displace", "Vertex",
	"FLAG_HAS_NORMALS", "FLAG_HAS_UVS", "MATERIAL_ROWS",
	// The eight push fields the mesh contract pins.
	"frame", "instances", "positions", "normals", "uvs", "base_color", "flags",
	"uv_transform",
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

// Long enough for any message below with the offending name spelled in full and
// short enough to be a global. A name longer than this is refused before it can
// be quoted anyway.
<*
 The field names of `Surface` and `Vertex`, which a uniform may not take either.

 **A different refusal from `MATERIAL_RESERVED`, because it is a different
 mistake and it breaks in a place the reserved list's message would not explain.**
 A uniform is a `#define` live across the agent's own lines, so a uniform called
 `normal` rewrites the `s.normal` *in the body that declared it* into
 `s.(push.normal)` — a syntax error inside generated code, reported at a line in
 the preamble, about a member access the agent wrote correctly.

 It is worth its own sentence for the same reason: "the shader already uses it" is
 true and useless here, because the thing using it is the struct the agent is
 reading five characters away.

 This was live before the vertex stage existed and had no test — `uniforms: { time
 : 1 }` on a post pass, which is the single most likely uniform anybody writes,
 failed with `three.post:134` under a caret pointing at a `#define`. The vertex
 body only made it easier to hit, because `Vertex` has seven fields and a body
 touches most of them.
*>
const String[*] MATERIAL_CONTRACT_FIELDS @local = {
	// Surface.
	"albedo", "normal", "uv", "position", "color", "variant",
	// Vertex adds these two; the rest it shares with Surface.
	"local", "index",
};

const usz MATERIAL_DIAGNOSTIC_MAX @local = 512;

// The message the last refusal carried. See `material_diagnostic`.
char[MATERIAL_DIAGNOSTIC_MAX] material_message @local;
usz material_message_len @local;

<*
 What the last `material_source` refused, in words.

 **A value rather than a line on stderr**, which is the same decision
 `compile_slang` made about Slang's diagnostics and for the same reason:
 `plan.md` §4 wants the text inside the thrown JS exception, and a script cannot
 read a file descriptor. A fault on its own says which rule was broken and
 nothing about which uniform broke it, which is not something an agent can fix.

 A fixed buffer rather than an allocation because the caller reads this on the
 failure path, where there is no owned value to free and no allocator in scope to
 free it with.

 @return `A view valid until the next call to material_source. Empty if the last call succeeded.`
*>
fn String material_diagnostic() => (String)material_message[:material_message_len];

fn void material_note(String message) @local
{
	material_message_len = shader_note_into(material_message[..], message);
}

<*
 What the uniforms cost in the push block.

 `sum(components) * 4`, and no alignment arithmetic: the compile passes
 `-force-glsl-scalar-layout`, under which a float3 is twelve bytes at four-byte
 alignment and every field here is a multiple of four. **The offsets are still
 not computed anywhere** — reflection reads them back off the module that will
 run, which is the only version of them that cannot be wrong.
*>
fn uint material_uniform_bytes(MaterialUniform[] uniforms)
{
	uint total = 0;
	foreach (uniform : uniforms) total += uniform.components * uniform_rows_of(uniform) * 4;
	return total;
}

<*
 How many rows this material's table has, or 1 when it declared none.

 Generated into the module as `MATERIAL_ROWS` and used to clamp `s.variant`, so
 every `column[s.variant]` in a body is in bounds by construction. A material
 with no arrays gets 1 and therefore a variant of 0 for every copy, which is the
 truth: there is no table for a variant to select from.
*>
fn uint material_rows(MaterialUniform[] uniforms)
{
	uint rows = 1;
	foreach (uniform : uniforms)
	{
		uint declared = uniform_rows_of(uniform);
		if (declared > rows) rows = declared;
	}
	return rows;
}

<*
 Everything that can be refused before a line of Slang is written.

 Order matters to the message rather than to the outcome: the body is checked
 first because a material with no body has nothing for the uniforms to be used
 by, and the budget last because "these seventeen floats do not fit" is only
 useful once each of them is known to be a real uniform.

 @return? MATERIAL_BODY_EMPTY : `The fragment body is empty or only whitespace.`
 @return? MATERIAL_NAME_INVALID : `A uniform or texture name is not an identifier, is one the template already uses, is a Slang keyword, is repeated, or is not 1 to 4 floats wide.`
 @return? MATERIAL_TOO_MANY_UNIFORMS : `The uniforms want more of the push block than the mesh contract leaves.`
 @return? MATERIAL_TOO_MANY_TEXTURES : `More samplers than MATERIAL_TEXTURE_LIMIT.`
*>
fn void? validate_material(String fragment, MaterialUniform[] uniforms, MaterialTexture[] textures) @local
{
	@pool()
	{
		if (fragment.trim().len == 0)
		{
			material_note("material: the fragment body is empty; it must define `float3 shade(Surface s)`");
			return MATERIAL_BODY_EMPTY~;
		}

		foreach (i, uniform : uniforms)
		{
			if (!is_identifier(uniform.name))
			{
				material_note(string::tformat(
					"material: uniform name '%s' is not an identifier; a name must match [A-Za-z_][A-Za-z0-9_]*",
					uniform.name
				));
				return MATERIAL_NAME_INVALID~;
			}

			foreach (reserved : MATERIAL_RESERVED)
			{
				if (uniform.name != reserved) continue;
				material_note(string::tformat(
					"material: uniform name '%s' is reserved; the shader three.c3 generates around your body already uses it",
					uniform.name
				));
				return MATERIAL_NAME_INVALID~;
			}

			foreach (field : MATERIAL_CONTRACT_FIELDS)
			{
				if (uniform.name != field) continue;
				material_note(string::tformat(
					"material: uniform name '%s' is a field of Surface and Vertex, so it would rewrite s.%s and v.%s in your own body — rename the uniform",
					uniform.name,
					uniform.name,
					uniform.name
				));
				return MATERIAL_NAME_INVALID~;
			}

			foreach (j, earlier : uniforms)
			{
				if (j >= i) break;
				if (earlier.name != uniform.name) continue;
				material_note(string::tformat(
					"material: uniform '%s' is declared twice",
					uniform.name
				));
				return MATERIAL_NAME_INVALID~;
			}

			if (uniform.components < 1 || uniform.components > 4)
			{
				material_note(string::tformat(
					"material: uniform '%s' is %d floats wide; a uniform is 1 to 4",
					uniform.name,
					uniform.components
				));
				return MATERIAL_NAME_INVALID~;
			}

			// One table, not a bag of arrays — see `MaterialUniform`. Checked
			// against the first column that has more than one row rather than
			// against the maximum, so the message can name both of them.
			uint rows = uniform_rows_of(uniform);
			foreach (other : uniforms)
			{
				uint other_rows = uniform_rows_of(other);
				if (other_rows == 1 || rows == 1 || other_rows == rows) continue;
				material_note(string::tformat(
					"material: '%s' has %d rows and '%s' has %d; every array in one material is a column of the same table and they must agree",
					uniform.name,
					rows,
					other.name,
					other_rows
				));
				return MATERIAL_NAME_INVALID~;
			}
		}

		// After the uniforms, because a texture name is checked *against* them:
		// the collision that matters most here is a sampler sharing a uniform's
		// name, and `texture_problem` can only report it once both lists are known
		// to be individually sound.
		String texture_note = texture_problem(
			MATERIAL_BODY_NAME, textures, uniforms, MATERIAL_RESERVED[..], MATERIAL_TEXTURE_LIMIT
		);
		if (texture_note.len > 0)
		{
			material_note(texture_note);
			// The count is its own fault because it is the one a caller fixes
			// differently — every other sentence here is answered by renaming
			// something, and this one is answered by asking for fewer images.
			return textures.len > MATERIAL_TEXTURE_LIMIT ? MATERIAL_TOO_MANY_TEXTURES~ : MATERIAL_NAME_INVALID~;
		}

		uint wanted = material_uniform_bytes(uniforms);
		if (wanted > MATERIAL_UNIFORM_BUDGET)
		{
			material_note(string::tformat(
				"material: the uniforms want %d bytes of push block and %d are free; the mesh contract takes the other %d of the 128 every device offers",
				wanted,
				MATERIAL_UNIFORM_BUDGET,
				PUSH_BUDGET - MATERIAL_UNIFORM_BUDGET
			));
			return MATERIAL_TOO_MANY_UNIFORMS~;
		}

		material_note("");
	};
}

<*
 Assemble the full Slang module for a material.

 The result is self-contained: it declares its own `PushData`, its own binding
 and both entry points, so it goes to `compile_slang` as a string with nothing
 else beside it, the same way `mesh.slang` does. Nothing is compiled here and no
 GPU is involved.

 @param fragment : `The agent's body. Must define float3 shade(Surface s); everything else is theirs.`
 @param uniforms : `Names and widths, in the order they should be laid out. Reached from the body as bare names.`
 @param textures : `Samplers the body wants, in declaration order. Bindings 1..N, generated from that order.`
 @return `The whole module, allocated from allocator and owned by the caller.`
 @return? MATERIAL_BODY_EMPTY : `The body is empty. material_diagnostic() has the sentence.`
 @return? MATERIAL_NAME_INVALID : `A uniform or texture name, or a uniform width, is one this cannot generate. material_diagnostic() names it.`
 @return? MATERIAL_TOO_MANY_UNIFORMS : `The uniforms do not fit in what the mesh contract leaves of the push block.`
 @return? MATERIAL_TOO_MANY_TEXTURES : `More samplers than MATERIAL_TEXTURE_LIMIT. material_diagnostic() has the count.`
 @return? SHADER_NOT_FOUND : `shaders/material.slang is not on the search path — the same condition, and the same fix, as a missing mesh.slang.`
*>
fn String? material_source(
	String fragment,
	MaterialUniform[] uniforms,
	alloc::Allocator allocator = mem,
	// **After the allocator**, which reads wrong and is deliberate: every caller
	// that predates textures passes the allocator positionally, and putting this
	// where it belongs would silently turn one of those into a texture list. The
	// project already makes this trade for `create_material`'s `diagnostic`.
	MaterialTexture[] textures = {},
	String vertex = ""
)
{
	validate_material(fragment, uniforms, textures)!;
	return assemble_shader(
		MATERIAL_TEMPLATE,
		fragment,
		uniforms,
		textures,
		vertex,
		MATERIAL_BODY_NAME,
		MATERIAL_VERTEX_NAME,
		MATERIAL_PREAMBLE_NAME,
		MATERIAL_BINDING_FIRST,
		allocator
	);
}
