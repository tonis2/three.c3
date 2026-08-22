<*
 The post-processing pass: what the agent's body is turned into, and what
 reaches the frame.

	`c3c test --trust=full --test-noleak --test-filter three_tests::post`

 Two halves, and the split is the same one `three_tests::material` makes.

 **The assembly half needs no GPU.** `post_source` is string work and
 `compile_slang` needs Slang and nothing else, so the `#line` arithmetic, the
 reserved names, the budget and the push contract are all answerable in
 milliseconds. That matters because the loop these protect is an agent editing a
 post body and asking again.

 **The engine half needs a device**, and it is where the barriers are. Image A
 goes COLOR_ATTACHMENT → SHADER_READ_ONLY and `target.color` goes UNDEFINED →
 COLOR_ATTACHMENT → TRANSFER_SRC inside one command buffer, none of which has a
 pixel symptom on this driver — a missing barrier renders correctly here and is
 a race everywhere else. So the engine checks run under the validation layer and
 assert on its silence, which is the only instrument that sees them.

 The headline is `an_identity_post_pass_leaves_the_frame_where_it_was`. It pins
 three separate decisions at once and each of them fails visibly if it is wrong:
 image A being `_SRGB` (a `_UNORM` A double-encodes and shifts the mid-tones),
 the post viewport being positive (a negative one flips the frame top to bottom
 and no validation layer objects), and the sample being a straight `uv` with no
 flip anywhere in `shaders/post.slang`.
*>
module three_tests::post;

import three;
import vk;
import image;
import slang;
import std::core::test;
import std::io;
import std::math;
import std::collections::list;

// A global rather than a function returning a slice literal: a slice literal is
// backed by the stack frame that made it, and c3c says so.
const three::ShaderEntry[2] BOTH_STAGES = {
	{ "vertexMain", slang::STAGE_VERTEX },
	{ "fragmentMain", slang::STAGE_FRAGMENT },
};

macro three::ShaderEntry[] both_stages() => BOTH_STAGES[..];

// The smallest body that is a post pass: hand the frame back unchanged.
const String IDENTITY = `float3 post(Post p) { return p.color; }`;

// Three lines, so line 3 is a line an agent can point at. `notAFunction` is not
// declared anywhere, which is a Slang error and not a preprocessor one — the
// distinction matters, because a preprocessor error is reported against the
// physical file and would pass this check for the wrong reason.
const String BAD_BODY = `float3 post(Post p)
{
	return notAFunction(p.uv);
}`;

const uint W = 96;
const uint H = 72;

// ============================================================================
// Helpers
// ============================================================================

<*
 The 1-based physical line of the first line containing `needle`, or zero.

 The restore `#line` names an absolute line in the assembled module, so a test
 that hardcoded the number would pass for as long as nobody edited the
 template's header comment. This finds it the way the assembler counts it.
*>
fn uint line_containing(String source, String needle)
{
	uint line = 1;
	usz start = 0;
	while (start < source.len)
	{
		usz end = start;
		while (end < source.len && source[end] != '\n') end++;
		if (source[start:end - start].contains(needle)) return line;
		line++;
		start = end + 1;
	}
	return 0;
}

<*
 The `n`th line of `source`, 1-based, or the empty string.
*>
fn String line_at(String source, uint n)
{
	uint line = 1;
	usz start = 0;
	while (start < source.len)
	{
		usz end = start;
		while (end < source.len && source[end] != '\n') end++;
		if (line == n) return source[start:end - start];
		line++;
		start = end + 1;
	}
	return "";
}

macro @with_pass(; @body(three::Renderer* renderer))
{
	vk::Instance instance = three::create_instance(false, headless: true)!!;
	defer instance.free();

	three::Renderer renderer;
	renderer.init(instance, (vk::SurfaceKHR)null, W, H)!!;
	defer renderer.free();

	renderer.pass.init(&renderer.gpu, &renderer.target)!!;

	@body(&renderer);
}

<*
 The same, with the Khronos layer loaded — the only instrument that sees a
 missing barrier on this driver.
*>
macro @with_validating_pass(; @body(three::Renderer* renderer))
{
	vk::Instance instance = three::create_instance(true, headless: true)!!;
	defer instance.free();

	three::Renderer renderer;
	renderer.init(instance, (vk::SurfaceKHR)null, W, H, validate: true)!!;
	defer renderer.free();

	renderer.pass.init(&renderer.gpu, &renderer.target)!!;

	@body(&renderer);
}

<*
 A frame with a top and a bottom that are not the same.

 A plane filling the view, and a smaller one over the upper half of it in a
 different colour. Asymmetry is the whole point: a check that the post pass left
 the frame alone is worth nothing against a picture that is its own mirror
 image, which is exactly what a full-frame flat plane is.
*>
fn void asymmetric_scene(three::Renderer* renderer)
{
	three::AssetId plane = renderer.pass.assets.primitive(&renderer.gpu, three::plane_shape(2, 2))!!;

	three::NodeId back = renderer.pass.scene.add_mesh(plane, 0);
	renderer.pass.scene.set_color(back, { 0.1, 0.1, 0.6, 1.0 });

	three::NodeId patch = renderer.pass.scene.add_mesh(plane, 0);
	// Exactly the upper half of the plane behind it: scaled to half height and
	// lifted by half, so the frame is one colour above the middle and another
	// below it. A patch that only covered part of a band would make the means
	// below a mixture, and a mixture is what a flipped frame also produces.
	renderer.pass.scene.set_scale(patch, { 1.0, 0.5, 1.0 });
	renderer.pass.scene.set_position(patch, { 0, 0.5, 0.2 });
	renderer.pass.scene.set_color(patch, { 0.9, 0.15, 0.05, 1.0 });

	renderer.pass.frame_camera();
}

// The mean of one channel over the top third and over the bottom third.
fn float band_mean(image::Image* img, uint channel, bool top)
{
	sz bpp = img.bytes_per_pixel();
	sz third = (sz)img.height / 3;
	sz first = top ? 0 : (sz)img.height - third;
	double total = 0;
	sz count = 0;
	for (sz y = first; y < first + third; y++)
	{
		for (sz x = 0; x < (sz)img.width; x++)
		{
			total += (double)img.pixels[(y * (sz)img.width + x) * bpp + channel];
			count++;
		}
	}
	return count == 0 ? 0 : (float)(total / (double)count);
}

// The largest per-channel difference between two frames of the same size.
fn int worst_channel_delta(image::Image* a, image::Image* b)
{
	if (a.width != b.width || a.height != b.height) return 255;
	int worst = 0;
	sz bpp = a.bytes_per_pixel();
	for (sz i = 0; i < a.pixels.len; i++)
	{
		// Alpha is forced opaque by `Target.decode_readback` on both sides, so it
		// carries no information and is skipped rather than trusted.
		if (i % bpp == 3) continue;
		int delta = math::abs((int)a.pixels[i] - (int)b.pixels[i]);
		if (delta > worst) worst = delta;
	}
	return worst;
}

fn image::Image copy_of(image::Image* img)
{
	char[] pixels = mem::new_array(char, img.pixels.len);
	pixels[..] = img.pixels[..];
	return {
		.width = img.width,
		.height = img.height,
		.bit_depth = img.bit_depth,
		.format = img.format,
		.pixels = pixels,
		.allocator = mem,
	};
}

// ============================================================================
// Assembly — the string the agent's four lines become
// ============================================================================

<*
 The smallest post body compiles, and the module it produces is a whole shader.

 The floor everything else stands on: `shaders/post.slang` is a template and not
 valid Slang as it sits on disk, so nothing else in this file means anything
 until the assembled version of it is known to compile.

 **Proved by injection.** `//@shade` deleted from `shaders/post.slang`, so the
 body is never inserted: "it compiled: error[E30015]: undefined identifier".
 Restored, green again.
*>
fn void the_smallest_post_body_compiles() @test
{
	three::MaterialUniform[] none = {};
	String source = three::post_source(IDENTITY, none)!!;
	defer source.free(mem);

	three::ShaderModule mod = three::compile_slang(source, "post.slang", both_stages())!!;
	defer mod.free();

	test::@check(mod.ok, "it compiled: %s", mod.diagnostic);
	test::@check(mod.spirv.len > 0, "and produced a module");
	test::@check(mod.spirv.len % 4 == 0, "which is a whole number of words");
	test::@check(mod.diagnostic.len == 0, "with nothing to say about it: %s", mod.diagnostic);
	test::@check(mod.entries.len() == 2, "two entry points, got %d", mod.entries.len());
	test::@check(!source.contains(`\n`), "no literal backslash-n survived into the module");
}

<*
 A bad post body reports the line the agent wrote, in the agent's own file.

 The headline of the assembly half, and the whole reason `shader/assemble.c3`
 exists rather than a second copy of the marker walk. The agent wrote three
 lines and got back a two-hundred-line module; a diagnostic naming a line in the
 two hundred is a loop that does not close.

 Both halves are asserted. `post:` is the file name the `#line` directive gives
 the body, and `3` is the line inside it — either one alone would pass for a
 diagnostic that named the right file at the wrong line, which is the failure an
 off-by-one in the `#line` arithmetic produces.

 **Proved by injection.** `assemble_shader`'s body directive changed from
 `#line 1` to `#line 0`, so every line of the body is reported one short: "the
 diagnostic does not name post:3 — error[E30015]: undefined identifier".
 Restored, green again.
*>
fn void the_line_a_bad_post_body_reports_is_the_line_the_agent_wrote() @test
{
	three::MaterialUniform[] none = {};
	String source = three::post_source(BAD_BODY, none)!!;
	defer source.free(mem);

	three::ShaderModule mod = three::compile_slang(source, "post.slang", both_stages())!!;
	defer mod.free();

	test::@check(!mod.ok, "a body calling a function that does not exist compiled anyway");
	test::@check(
		mod.diagnostic.contains("post:3") || mod.diagnostic.contains("post(3)"),
		"the diagnostic does not name post:3 — %s",
		mod.diagnostic
	);
}

<*
 The restore directive names the line that really follows it, for both
 templates.

 The subtlest half of the `#line` arithmetic and the reason it may exist only
 once: `#line N "three.post"` numbers the line *after* itself, and N is the
 physical line of that text in a module whose height nothing upstream of the
 assembler knows. An off-by-one here does not fail anything — it silently points
 Slang's `candidate:` notes one line away from where they belong, for ever.

 Checked on a material and on a post pass through the one walk that now serves
 both, because the whole risk of sharing it is getting it right for one caller
 and wrong for the other.

 **Proved by injection.** `physical + 2` in `assemble_shader` changed to
 `physical + 1`: "three.post: the restore directive says 117 and the line after
 it is 118". Restored, green again.
*>
fn void the_restore_directive_names_the_line_that_follows_it() @test
{
	three::MaterialUniform[2] uniforms = { { "tint", 3, 1 }, { "speed", 1, 1 } };

	String post = three::post_source(IDENTITY, uniforms[..])!!;
	defer post.free(mem);
	check_restore_line(post, "three.post");

	String material = three::material_source(
		`float3 shade(Surface s) { return s.albedo * tint * speed; }`,
		uniforms[..]
	)!!;
	defer material.free(mem);
	check_restore_line(material, "three.material");
}

<*
 The restore `#line` in `source` says the number of the line beneath it.

 A function rather than a macro because nothing here needs the caller's frame,
 and the failure text names which of the two templates it was looking at.
*>
fn void check_restore_line(String source, String preamble)
{
	@pool()
	{
		String needle = string::tformat(`"%s"`, preamble);
		uint at = line_containing(source, needle);
		test::@check(at > 0, "%s: no restore directive at all", preamble);
		if (at == 0) return;

		// `#line 148 "three.post"` — the number between the directive and the name.
		String directive = line_at(source, at).trim();
		String[] parts = directive.tsplit(" ");
		test::@check(parts.len >= 3, "%s: the restore directive is '%s'", preamble, directive);
		if (parts.len < 3) return;

		uint claimed = parts[1].to_uint()!!;
		test::@check(
			claimed == at + 1,
			"%s: the restore directive says %d and the line after it is %d",
			preamble,
			claimed,
			at + 1
		);
	};
}

<*
 The push block is `info` at 0+16 and the agent's uniforms after it.

 The check that makes a post shader safe to draw with. `MeshPipeline.init_post`
 requires `info` at exactly 0+16 through `POST_PUSH_FIELDS`, so a uniform
 inserted before it would move the resolution and the clock the pass writes
 every frame — and the failure would not be a compile error, it would be a
 shader reading the frame's width out of the middle of somebody's colour.

 The offsets are asserted as *reflected*, never assumed: scalar layout is a
 property of the flags `compile_slang` passes, and a build that lost
 `-force-glsl-scalar-layout` would lay this block out differently while
 compiling perfectly.

 **Proved by injection.** `//@uniforms` moved above `float4 info;` in
 `shaders/post.slang`, so one uniform of any width displaces it: "'info' is at
 16+16 and POST_PUSH_FIELDS has it at 0+16". Restored, green again.
*>
fn void the_post_push_block_is_info_and_then_the_uniforms() @test
{
	three::MaterialUniform[2] uniforms = { { "tint", 3, 1 }, { "speed", 1, 1 } };

	String source = three::post_source(
		`float3 post(Post p) { return p.color * tint * speed; }`,
		uniforms[..]
	)!!;
	defer source.free(mem);

	three::ShaderModule mod = three::compile_slang(source, "post.slang", both_stages())!!;
	defer mod.free();
	test::@check(mod.ok, "it compiled: %s", mod.diagnostic);

	foreach (expected : three::POST_PUSH_FIELDS)
	{
		three::ShaderField* found = mod.layout.field_of(expected.name);
		test::@check(found != null, "the post block has an '%s' field", expected.name);
		if (found == null) continue;
		test::@check(
			found.offset == expected.offset && found.size == expected.size,
			"'%s' is at %d+%d and POST_PUSH_FIELDS has it at %d+%d",
			expected.name, found.offset, found.size, expected.offset, expected.size
		);
	}

	uint start = three::POST_PUSH_START;
	three::ShaderField* tint = mod.layout.field_of("tint");
	three::ShaderField* speed = mod.layout.field_of("speed");
	test::@check(tint != null && speed != null, "both uniforms are in the block");
	if (tint == null || speed == null) return;

	test::@check(tint.offset == start && tint.size == 12,
		"tint is at %d+12, got %d+%d", start, tint.offset, tint.size);
	test::@check(speed.offset == start + 12 && speed.size == 4,
		"speed is at %d+4, got %d+%d", start + 12, speed.offset, speed.size);
	test::@check(mod.layout.push_size == start + 16,
		"the block is %d bytes, got %d", start + 16, mod.layout.push_size);
}

<*
 A post pass with no uniforms is exactly `info`, and the budget is the rest.

 The floor of the previous check, and what makes `POST_UNIFORM_BUDGET`'s 112 a
 derived number rather than one somebody chose: with nothing appended the block
 is the 16 bytes `info` occupies, and 128 minus 16 is the budget.

 **Proved by injection.** `float pad;` added to `PushData` in
 `shaders/post.slang` — the shape of any future field creeping into the pass's
 own half of the block: "16 bytes, got 20". `POST_UNIFORM_BUDGET` itself cannot
 be injected into, because the two `$assert`s beside it refuse to compile a
 budget that does not add up to 128. Restored, green again.
*>
fn void a_post_pass_without_uniforms_is_exactly_info() @test
{
	three::MaterialUniform[] none = {};
	String source = three::post_source(IDENTITY, none)!!;
	defer source.free(mem);

	three::ShaderModule mod = three::compile_slang(source, "post.slang", both_stages())!!;
	defer mod.free();
	test::@check(mod.ok, "it compiled: %s", mod.diagnostic);

	test::@check(mod.layout.push_size == three::POST_PUSH_START,
		"%d bytes, got %d", three::POST_PUSH_START, mod.layout.push_size);
	test::@check(
		mod.layout.push_fields.len() == three::POST_PUSH_FIELDS.len,
		"and %d fields, got %d",
		three::POST_PUSH_FIELDS.len,
		mod.layout.push_fields.len()
	);
	test::@check(
		three::POST_UNIFORM_BUDGET == three::PUSH_BUDGET - mod.layout.push_size,
		"the budget is what is left of the 128: %d",
		three::POST_UNIFORM_BUDGET
	);
}

<*
 The names `shaders/post.slang` uses for itself are refused, with the reason.

 Four of them, because they break in four different ways. `info` is a second
 member of the struct the uniforms are appended to. `push` and `p` are rewritten
 by their own `#define` across the agent's lines. `post` is the body's own
 function name, so a uniform by that name makes the signature unparseable.
 Every one of them fails as a Slang error pointing at generated code the agent
 cannot see, which is why they are refused before Slang is reached.

 **Proved by injection.** `"info"` removed from `POST_RESERVED`: "a uniform
 called 'info' was accepted" — and what the agent would have got instead is a
 duplicate-member error against a line of the preamble it has never seen, which
 is the outcome the list exists to prevent. Restored, green again.
*>
fn void a_post_uniform_the_template_already_uses_is_refused() @test
{
	String[4] taken = { "info", "push", "p", "post" };
	foreach (name : taken)
	{
		three::MaterialUniform[1] mine = { { name, 1, 1 } };
		String? refused = three::post_source(IDENTITY, mine[..]);
		fault why = @catch(refused);

		test::@check(why == three::POST_NAME_INVALID, "a uniform called '%s' was accepted", name);
		test::@check(
			three::post_diagnostic().contains(name) && three::post_diagnostic().contains("reserved"),
			"the refusal for '%s' should name it and say reserved: %s",
			name,
			three::post_diagnostic()
		);
	}
}

<*
 A post uniform cannot be a table, and the refusal says why.

 The one rule a material has that this inverts. A material's arrays are a column
 indexed by `Surface.variant`, the per-instance row selector — and a post pass
 draws one triangle over the whole frame, so there is no instance for a row to
 belong to and `shaders/post.slang` deliberately has no `//@rows` marker.

 Refused rather than flattened, because a caller asking for four rows believes
 it can index them: silently generating `float3 tint;` would compile, and the
 body's `tint[2]` would then be the diagnostic instead.

 **Proved by injection.** The rows check removed from `validate_post`: "a
 4-row uniform was accepted" — and the assembled module compiles either way,
 since the shared walk emits `float3 tint[4];` perfectly well. Restored, green
 again.
*>
fn void a_post_uniform_cannot_be_a_table() @test
{
	three::MaterialUniform[1] table = { { "tint", 3, 4 } };
	String? refused = three::post_source(IDENTITY, table[..]);
	fault why = @catch(refused);

	test::@check(why == three::POST_NAME_INVALID, "a 4-row uniform was accepted");
	test::@check(
		three::post_diagnostic().contains("tint") && three::post_diagnostic().contains("row"),
		"the refusal should name the uniform and the rows: %s",
		three::post_diagnostic()
	);
}

<*
 112 bytes fit and 128 do not, which is the budget stated as behaviour.

 Both sides on purpose. The upper bound alone would pass for a budget of one
 byte, and the lower bound alone would pass for a budget of the whole 128 — and
 128 is precisely the wrong answer, because `info` is already in the block and
 the overflow would be a validation error at pipeline creation rather than a
 sentence here.

 **Proved by injection.** `validate_post`'s comparison changed from
 `POST_UNIFORM_BUDGET` to `PUSH_BUDGET` — the mistake of forgetting that `info`
 is already in the block: "128 bytes of uniforms were accepted". Restored, green
 again.
*>
fn void post_uniforms_are_held_to_what_info_leaves() @test
{
	@pool()
	{
		// Seven float4s is 112 bytes exactly — the budget, to the byte.
		three::MaterialUniform[] exact = alloc::new_array(tmem, three::MaterialUniform, 7);
		foreach (i, &uniform : exact) *uniform = { string::tformat("u%d", i), 4, 1 };

		test::@check(
			three::post_uniform_bytes(exact) == three::POST_UNIFORM_BUDGET,
			"seven float4s should be the whole budget, got %d",
			three::post_uniform_bytes(exact)
		);

		String fits = three::post_source(IDENTITY, exact, tmem)!!;
		test::@check(fits.len > 0, "the budget exactly was refused: %s", three::post_diagnostic());

		three::MaterialUniform[] over = alloc::new_array(tmem, three::MaterialUniform, 8);
		foreach (i, &uniform : over) *uniform = { string::tformat("u%d", i), 4, 1 };

		String? refused = three::post_source(IDENTITY, over);
		fault why = @catch(refused);
		test::@check(why == three::POST_TOO_MANY_UNIFORMS, "128 bytes of uniforms were accepted");
		test::@check(
			three::post_diagnostic().contains("128") && three::post_diagnostic().contains("112"),
			"the refusal should name what was wanted and what is free: %s",
			three::post_diagnostic()
		);
	};
}

<*
 The shared walk still writes the material module it always wrote, byte for
 byte.

 The regression pin for `shader/assemble.c3` being extracted out of
 `material_source.c3`. A refactor that produces a *nearly* identical module is
 the dangerous one — every existing material test would still pass on an extra
 blank line or a shifted `#undef`, and the thing that would break is the
 `#line` restore number that nothing else looks at.

 The expectation is built here rather than stored as a golden file, and built
 from the template rather than from the assembler: every line of
 `shaders/material.slang` except the four markers, with each marker replaced by
 the block it is documented to produce. So this survives an edit to the
 template's prose — which a stored snapshot would not — and still fails on any
 change to what the markers turn into.

 The one number that cannot be written literally is the restore `#line`, since
 it is the physical line of the text after it. It is filled in from the position
 the expectation itself puts it at, which is the definition rather than a copy of
 the arithmetic.

 **Proved by injection.** `#define %s (push.%s)` in `assemble_shader` changed to
 `#define %s push.%s` — legal, compiles, and wrong the first time a body writes
 `tint.x * 2`: "the assembled material is 11434 bytes and the expectation is
 11440". Restored, green again.
*>
fn void the_shared_walk_writes_the_same_material_it_always_did() @test
{
	three::MaterialUniform[3] uniforms = { { "tint", 3, 1 }, { "time", 1, 1 }, { "palette", 3, 2 } };
	String body = `float3 shade(Surface s)
{
	float3 c = s.albedo * tint * (0.5 + 0.5 * sin(time));
	return c * palette[s.variant];
}`;

	String assembled = three::material_source(body, uniforms[..])!!;
	defer assembled.free(mem);

	@pool()
	{
		String template = three::load_source("shaders/material.slang", tmem)!!;

		List{String} want;
		want.tinit(512);

		usz start = 0;
		while (start < template.len)
		{
			usz end = start;
			while (end < template.len && template[end] != '\n') end++;
			String line = template[start:end - start];
			start = end + 1;

			switch (line.trim())
			{
				case "//@uniforms":
					want.push("    float3 tint;");
					want.push("    float time;");
					want.push("    float3 palette[2];");
				case "//@rows":
					want.push("static const uint MATERIAL_ROWS = 2u;");
				case "//@vdefines":
					// Nothing: this material declared no vertex body, so the
					// uniform macros are not opened over `vertexMain` at all.
					break;
				case "//@vertex":
					// The identity, which is what a material without a `vertex:`
					// gets — one line, and the same one every time.
					want.push("void displace(inout Vertex v) { }");
				case "//@textures":
					// Nothing: this material declared no samplers, and a marker with
					// nothing to generate is replaced by zero lines rather than left
					// in place. Spelled as an empty case rather than left to
					// `default`, because falling through to `default` would push the
					// marker line itself and the byte comparison below would say
					// twelve bytes and not why.
					break;
				case "//@defines":
					want.push("#define tint (push.tint)");
					want.push("#define time (push.time)");
					want.push("#define palette (push.palette)");
				case "//@shade":
					want.push(`#line 1 "material"`);
					foreach (body_line : body.tsplit("\n")) want.push(body_line);
					// Filled in below: the restore directive names the line that
					// follows it, and its own position is not known until the list
					// is complete.
					want.push("");
					want.push("#undef tint");
					want.push("#undef time");
					want.push("#undef palette");
				default:
					want.push(line);
			}
		}

		sz restore_at = 0;
		foreach (i, line : want) if (line.len == 0 && i > 0 && want[i - 1].starts_with("}")) restore_at = i;
		test::@check(restore_at > 0, "the expectation has no restore slot");
		if (restore_at == 0) return;
		// `restore_at` is a 0-based index; the directive is on line `restore_at + 1`
		// and numbers the line beneath it.
		want[restore_at] = string::tformat(`#line %d "three.material"`, restore_at + 2);

		DString expected;
		expected.tinit(assembled.len + 64);
		foreach (line : want)
		{
			expected.append_string(line);
			expected.append_char('\n');
		}

		String want_str = expected.str_view();
		test::@check(
			want_str.len == assembled.len,
			"the assembled material is %d bytes and the expectation is %d",
			assembled.len,
			want_str.len
		);

		usz shortest = want_str.len < assembled.len ? want_str.len : assembled.len;
		usz differs = shortest;
		for (usz i = 0; i < shortest; i++)
		{
			if (want_str[i] != assembled[i]) { differs = i; break; }
		}
		if (differs < shortest)
		{
			uint at = 1;
			for (usz i = 0; i < differs; i++) if (assembled[i] == '\n') at++;
			test::@check(false,
				"the assembled material differs at line %d: expected '%s', got '%s'",
				at,
				line_at(want_str, at),
				line_at(assembled, at)
			);
		}
	};
}

// ============================================================================
// The engine — image A, the barriers and the pixels
// ============================================================================

<*
 An identity post pass leaves the frame exactly where it was.

 **The headline**, and it pins three decisions at once that have nothing else
 holding them:

 - **Image A is `_SRGB`.** The scene's linear floats are encoded into A, the
   sampler decodes them back to linear, the body returns them and the `_SRGB`
   target re-encodes — a round trip that closes by format. Under a `_UNORM` A
   the sample arrives encoded, is treated as linear and is encoded again, which
   leaves black and white alone and shifts everything between them.
 - **The post viewport is positive.** Everywhere else in this project it is
   negative, to undo Vulkan's Y-down NDC for a glm-convention projection. There
   is no projection here, so the flip would be a flip: the frame would come back
   upside down, and no validation layer says a word about it.
 - **`shaders/post.slang` needs no `uv` flip**, which is the same claim from the
   shader's side.

 The fixture is asymmetric top to bottom and this asserts that it is, because a
 mirror-symmetric frame would satisfy the comparison with the picture upside
 down — a green check that had quietly stopped asking the question.

 One channel level of tolerance, because the identity runs through eight bits
 twice and the encode/decode pair is not exactly invertible at every value. The
 failures above are 30 levels and 200 levels respectively.

 **Proved by injection.** The post viewport's height negated to match every
 other viewport in the project: "the identity post pass changed the frame by 130
 levels". Separately, image A and its view created `FORMAT_R8G8B8A8_UNORM`:
 "changed the frame by 69 levels" — a mid-tone shift with black and white
 untouched, and the asymmetry check green throughout, which is why the delta is
 asserted rather than the format. Restored, green again.
*>
fn void an_identity_post_pass_leaves_the_frame_where_it_was() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		asymmetric_scene(renderer);

		image::Image plain = renderer.capture()!!;
		defer plain.free();

		float top = band_mean(&plain, 0, true);
		float bottom = band_mean(&plain, 0, false);
		test::@check(
			math::abs(top - bottom) > 20.0,
			"the fixture is not asymmetric enough to catch a flip: top red %f, bottom red %f",
			top, bottom
		);

		renderer.post.set(&renderer.gpu, &renderer.target, IDENTITY, {})!!;

		image::Image posted = renderer.capture()!!;
		defer posted.free();

		int delta = worst_channel_delta(&plain, &posted);
		test::@check(delta <= 1, "the identity post pass changed the frame by %d levels", delta);
	};
}

<*
 A post pass reaches the pixels, and clearing it puts them back.

 The other direction from the identity check: this one asserts the pass can
 *change* the frame, with a body whose effect is unmistakable — `p.color.bgr`
 swaps red and blue, so a red-dominant band becomes a blue-dominant one. The
 clear afterwards has to restore the original frame byte for byte, because
 `PostPass.clear` claims to return the renderer to the path it was on before
 any shader was set rather than to something equivalent to it.

 **Proved by injection.** The `if (posted)` branch removed from
 `Renderer.record_scene`'s tail, so the scene is drawn into image A and nothing
 ever reads it: "the post pass did not reach the frame: red 65.803818 ->
 65.803818" — the two frames identical, which is also what a post pass that
 silently did nothing would look like. Restored, green again.
*>
fn void a_post_pass_reaches_the_pixels_and_clearing_puts_them_back() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		asymmetric_scene(renderer);

		image::Image plain = renderer.capture()!!;
		defer plain.free();
		image::Image before = copy_of(&plain);
		defer before.free();

		float red_before = band_mean(&plain, 0, true);
		float blue_before = band_mean(&plain, 2, true);
		test::@check(red_before > blue_before + 20.0,
			"the fixture's top band is not red enough to see a swap: red %f, blue %f", red_before, blue_before);

		renderer.post.set(&renderer.gpu, &renderer.target, `float3 post(Post p) { return p.color.bgr; }`, {})!!;

		image::Image swapped = renderer.capture()!!;
		defer swapped.free();

		float red_after = band_mean(&swapped, 0, true);
		float blue_after = band_mean(&swapped, 2, true);
		test::@check(
			red_after < red_before - 20.0,
			"the post pass did not reach the frame: red %f -> %f",
			red_before, red_after
		);
		test::@check(
			blue_after > blue_before + 20.0,
			"and blue should have taken red's place: blue %f -> %f",
			blue_before, blue_after
		);

		renderer.post.clear(&renderer.gpu);

		image::Image restored = renderer.capture()!!;
		defer restored.free();
		test::@check(
			worst_channel_delta(&before, &restored) == 0,
			"clearing the post pass did not restore the frame: %d levels",
			worst_channel_delta(&before, &restored)
		);
	};
}

<*
 A post uniform is live between frames.

 The claim the push block's layout is for: `set_uniform` writes into
 `PostPass.block` and `record` pushes it, so changing a value costs a memcpy of
 at most 16 bytes and no compile, no pipeline and no upload. Two renders, one
 value, two different frames.

 The refusals ride along because they are the same door: `info` resolves as a
 real push field and is refused anyway, since `record` rewrites it every frame
 and a setting that appears to work and then does not is worse than one that
 says no.

 **Proved by injection.** `set_uniform` writing at `block[0]` instead of at the
 reflected offset, so the value lands on `info` and the uniform stays zero: "the
 uniform did not reach the frame: 0.000000 vs 0.000000" — both frames black,
 which is what a body multiplying by an unwritten uniform produces. Restored,
 green again.
*>
fn void a_post_uniform_is_live_between_frames() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		asymmetric_scene(renderer);

		three::MaterialUniform[1] uniforms = { { "gain", 1, 1 } };
		renderer.post.set(
			&renderer.gpu,
			&renderer.target,
			`float3 post(Post p) { return p.color * gain; }`,
			uniforms[..]
		)!!;

		renderer.post.set_uniform("gain", (float[]) { 0.25 })!!;
		image::Image dim = renderer.capture()!!;
		defer dim.free();

		renderer.post.set_uniform("gain", (float[]) { 1.0 })!!;
		image::Image bright = renderer.capture()!!;
		defer bright.free();

		float dim_mean = band_mean(&dim, 2, false);
		float bright_mean = band_mean(&bright, 2, false);
		test::@check(
			bright_mean > dim_mean + 20.0,
			"the uniform did not reach the frame: %f vs %f",
			dim_mean, bright_mean
		);

		fault protected = @catch(renderer.post.set_uniform("info", (float[]) { 1, 2, 3, 4 }));
		test::@check(
			protected == three::MATERIAL_UNIFORM_UNKNOWN,
			"`info` was settable, and `record` overwrites it every frame"
		);
		fault too_wide = @catch(renderer.post.set_uniform("gain", (float[]) { 1, 2 }));
		test::@check(
			too_wide == three::MATERIAL_UNIFORM_WIDTH,
			"a two-float value was accepted for a one-float uniform"
		);
		fault unknown = @catch(renderer.post.set_uniform("nothing", (float[]) { 1 }));
		test::@check(
			unknown == three::MATERIAL_UNIFORM_UNKNOWN,
			"a uniform that does not exist was accepted"
		);
	};
}

<*
 Swapping the post shader retires the old pipeline rather than destroying it.

 The live-swap claim, and the reason `PostPass` owns a `MeshPipeline` outright
 instead of inventing storage of its own: the old pipeline may be bound by a
 frame still in flight, and `gpu/retire.c3` is the mechanism that already knows
 when it is not. Destroying it at the point of the swap is a use-after-free the
 validation layer catches only sometimes.

 The count is asserted at one rather than "more than zero", because a `set` that
 retired the *new* pipeline as well would also be greater than zero.

 **Proved by injection.** `gpu.retire_pipeline(self.pipeline)` in `PostPass.set`
 replaced with `self.pipeline.free(gpu)`: "the second set queued 0 pipelines".
 Restored, green again.
*>
fn void a_second_post_shader_retires_the_first() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		asymmetric_scene(renderer);

		renderer.post.set(&renderer.gpu, &renderer.target, IDENTITY, {})!!;
		image::Image first = renderer.capture()!!;
		defer first.free();

		sz queued_before = renderer.gpu.deletions.pipelines.len();

		renderer.post.set(&renderer.gpu, &renderer.target, `float3 post(Post p) { return p.color.bgr; }`, {})!!;
		test::@check(
			renderer.gpu.deletions.pipelines.len() == queued_before + 1,
			"the second set queued %d pipelines",
			(int)(renderer.gpu.deletions.pipelines.len() - queued_before)
		);

		// Two more frames is what `MAX_FRAMES_IN_FLIGHT` asks for, and the queue
		// draining is the other half of the claim: retired means destroyed later,
		// not kept for ever.
		image::Image second = renderer.capture()!!;
		defer second.free();
		image::Image third = renderer.capture()!!;
		defer third.free();

		test::@check(
			renderer.gpu.deletions.pipelines.len() == queued_before,
			"the retired pipeline was never destroyed: %d still queued",
			(int)renderer.gpu.deletions.pipelines.len()
		);
	};
}

<*
 A body that does not compile leaves the previous shader running, and hands back
 the diagnostic.

 Two claims and they are the same decision. The text has to reach the caller,
 because `plan.md` §5's condition is a JS error *carrying* the Slang output — a
 fault alone would leave a script with "it did not work". And the pass has to be
 either the old shader or the new one and never neither, because the natural
 caller is an agent editing a body inside a live frame loop, where a failed
 compile that also blanked the screen would be two problems instead of one.

 **Proved by injection.** The retire moved to the top of `PostPass.set`, before
 the compile — the natural way to write it, and the way that empties the screen
 on a typo: "a failed set left the pass inactive". Restored, green again.
*>
fn void a_post_shader_that_does_not_compile_leaves_the_last_one_running() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		asymmetric_scene(renderer);

		renderer.post.set(&renderer.gpu, &renderer.target, `float3 post(Post p) { return p.color.bgr; }`, {})!!;
		image::Image good = renderer.capture()!!;
		defer good.free();

		String diagnostic;
		fault refused = @catch(
			renderer.post.set(&renderer.gpu, &renderer.target, BAD_BODY, {}, diagnostic: &diagnostic)
		);
		defer if (diagnostic.ptr != null) diagnostic.free(mem);

		test::@check(
			refused == three::SHADER_COMPILE_FAILED,
			"a body calling a function that does not exist was accepted"
		);
		test::@check(diagnostic.len > 0, "the caller got no diagnostic at all");
		test::@check(
			diagnostic.contains("post:3") || diagnostic.contains("post(3)"),
			"and it does not name the agent's own line: %s",
			diagnostic
		);
		test::@check(renderer.post.active, "a failed set left the pass inactive");

		image::Image after = renderer.capture()!!;
		defer after.free();
		test::@check(
			worst_channel_delta(&good, &after) == 0,
			"the shader that was running before the failure stopped running: %d levels",
			worst_channel_delta(&good, &after)
		);
	};
}

<*
 Setting, clearing and setting again is silent under the validation layer.

 The barriers are the whole reason this file has a device half. Image A goes
 COLOR_ATTACHMENT_OPTIMAL → SHADER_READ_ONLY_OPTIMAL before anything reads it,
 the ping-pong image the pass writes goes the same way before the tonemap reads
 it, and `target.color` goes UNDEFINED → COLOR_ATTACHMENT_OPTIMAL →
 TRANSFER_SRC_OPTIMAL around the tonemap, all inside one command buffer, and
 **none of it has a pixel symptom on this driver**. A missing barrier renders
 correctly here and is a race on hardware that reorders; a wrong layout is
 undefined contents that happen to be right.

 `a_chain_is_silent_under_validation` is the same instrument at N = 3. This one
 stays at N = 1 because that is the shape every script writes first and the one
 whose barriers are `record_chain`'s own rather than its loop's.

 The layer is the only instrument that sees any of it, so the assertion is on
 its silence — and the sequence is deliberately the awkward one: post, no post,
 post again, in one command stream each, so that image A is left in
 SHADER_READ_ONLY by one frame and re-opened from UNDEFINED by the next.

 Skipped when the Khronos layer is not installed, like the twelve other checks
 in this project that need it, because a machine with no Vulkan SDK must still
 run the suite.

 **Proved by injection.** `record_chain`'s opening
 `shader_read_barrier(self.scene.image)` removed: "VUID-vkCmdDraw-imageLayout-00344:
 vkCmdDraw(): Cannot use VkImage ... with specific layout
 VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL (specified by combined image sampler
 descriptor [Set 0, Binding 0, Index 0, variable 'prev']) that doesn't match the
 previous known layout VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL" — with every
 pixel check in this file still green, which is the whole argument for this check
 existing. Restored, green again.

 The variable is `prev` and not `scene` because on a chain of one both reserved
 bindings point at image A, and binding 0 is the one the layer names first.
*>
fn void the_post_pass_is_silent_under_validation() @test
{
	@with_validating_pass(; three::Renderer* renderer)
	{
		if (!renderer.gpu.validation) return;

		asymmetric_scene(renderer);

		// One frame before the sink is armed, so anything the layer objects to
		// afterwards belongs to the post pass and not to the setup.
		image::Image warmup = renderer.capture()!!;
		warmup.free();

		renderer.gpu.begin_capture();

		renderer.post.set(&renderer.gpu, &renderer.target, IDENTITY, {})!!;
		image::Image one = renderer.capture()!!;
		one.free();
		image::Image two = renderer.capture()!!;
		two.free();

		// `render()` from a script, which is the second of the three frame paths
		// and the one with no consumer after it. It reaches the post pass through
		// the same `record_scene`, and it is here rather than assumed because
		// "they all go through one function" is exactly the claim a check should
		// be holding rather than repeating.
		renderer.render_offscreen()!!;

		renderer.post.clear(&renderer.gpu);
		image::Image bare = renderer.capture()!!;
		bare.free();

		renderer.post.set(&renderer.gpu, &renderer.target, `float3 post(Post p) { return p.color.bgr; }`, {})!!;
		image::Image three_ = renderer.capture()!!;
		three_.free();

		String errors = renderer.gpu.sink.errors.str_view();
		String warnings = renderer.gpu.sink.warnings.str_view();
		renderer.gpu.end_capture();

		test::@check(errors.len == 0, "the post pass produced validation errors: %s", errors);
		test::@check(warnings.len == 0, "and warnings: %s", warnings);
	};
}

// ============================================================================
// Textures
//
// A post pass's own samplers. `material_test`'s texture section has the general
// claims — that the indices are generated, that they cost the push block
// nothing — and this is what is different here: binding 0 is the frame rather
// than a material's map, and there is a device at the end of it.
// ============================================================================

<*
 A declared texture is a binding beside `prev` and `scene`, not instead of
 either.

 The thing that would break silently: the chain binds the pass before this one at
 0 and image A at 1 (`PostStage.record`), so a generated declaration that landed
 on either would push a frame into the agent's sampler and leave the body reading
 its own lookup table as though it were the picture. `POST_BINDING_FIRST` is why
 it cannot, and this asserts both ends of that rather than the constant.

 **Two reserved bindings and not one**, which is the half that would break
 quietly the other way: raising the shared `TEXTURE_BINDING_FIRST` instead of
 giving the two kinds their own base would have renumbered every *material*
 sampler by one, and every material's reflection would still have agreed with
 itself. So the count is asserted, and `material_test`'s own binding check is the
 other end of it.
*>
fn void a_post_texture_is_a_binding_beside_the_scene() @test
{
	three::MaterialTexture[2] textures = { { "grade_lut" }, { "grain_map" } };

	String source = three::post_source(
		`float3 post(Post p)
		{
		    float3 graded = grade_lut.Sample(float2(p.color.r, 0.5)).rgb;
		    return graded + grain_map.Sample(p.uv).rgb * 0.05;
		}`,
		{},
		mem,
		textures[..]
	)!!;
	defer source.free(mem);

	three::ShaderModule mod = three::compile_slang(source, "post.slang", both_stages())!!;
	defer mod.free();
	test::@check(mod.ok, "it compiled: %s", mod.diagnostic);

	test::@check(mod.layout.bindings.len() == 4,
		"the two reserved and the two the body asked for, got %d", mod.layout.bindings.len());

	three::ShaderBinding* previous = mod.layout.binding_of("prev");
	test::@check(previous != null && previous.binding == 0, "the pass before this one is binding 0");

	three::ShaderBinding* frame = mod.layout.binding_of("scene");
	test::@check(frame != null && frame.binding == 1, "image A is binding 1");

	three::ShaderBinding* lut = mod.layout.binding_of("grade_lut");
	test::@check(lut != null, "the first declared texture is there by name");
	if (lut == null) return;
	test::@check(lut.binding == three::POST_BINDING_FIRST,
		"at %d, got %d", three::POST_BINDING_FIRST, lut.binding);
	test::@check(lut.type == DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
		"as a combined image sampler, got %d", (uint)lut.type);

	// `info` is 16 bytes and stays 16 bytes: a sampler is a descriptor, not push
	// data, so declaring two of them moves nothing in the block.
	test::@check(mod.layout.push_size == three::POST_PUSH_START,
		"and the push block is still just info, got %d", mod.layout.push_size);
}

<*
 `scene` cannot be taken by a post texture, and neither can a uniform's name.

 `scene` is the sampler the template declares, so a second one is a redefinition
 in generated code — and it is the one name in `POST_RESERVED` whose collision is
 specifically about a *texture* rather than about a `#define`.
*>
fn void a_post_texture_name_the_template_already_uses_is_refused() @test
{
	three::MaterialTexture[1] theirs = { { "scene" } };
	fault refused = @catch(three::post_source(IDENTITY, {}, mem, theirs[..]));
	test::@check(refused == three::POST_NAME_INVALID, "'scene' is refused, got %s", refused);
	test::@check(
		three::post_diagnostic().contains("scene") && three::post_diagnostic().contains("reserved"),
		"as reserved, by name: %s",
		three::post_diagnostic()
	);

	three::MaterialUniform[1] uniforms = { { "amount", 1, 1 } };
	three::MaterialTexture[1] clashing = { { "amount" } };
	fault both = @catch(three::post_source(IDENTITY, uniforms[..], mem, clashing[..]));
	test::@check(both == three::POST_NAME_INVALID, "a uniform's name is refused too, got %s", both);

	three::MaterialTexture[5] too_many = {
		{ "a_map" }, { "b_map" }, { "c_map" }, { "d_map" }, { "e_map" },
	};
	fault counted = @catch(three::post_source(IDENTITY, {}, mem, too_many[..]));
	test::@check(counted == three::POST_TOO_MANY_TEXTURES, "and five is too many, got %s", counted);
}

<*
 A one-pixel image, uploaded, for a test that needs a texture and does not care
 what is in it beyond its colour.
*>
fn int solid_texture(three::Renderer* renderer, char r, char g, char b)
{
	char[4] pixels = { r, g, b, 255 };
	image::Image one = {
		.width = 1,
		.height = 1,
		.bit_depth = 8,
		.format = image::PixelFormat.RGBA,
		// No allocator, left at the zero fill: `Image.free` frees nothing without
		// one, which is what makes a stack array safe to hand over here.
		.pixels = pixels[..],
	};
	return renderer.pass.assets.claim_texture(&renderer.gpu, one)!!;
}

<*
 A post texture reaches the pixels, and swapping it reaches them again.

 **The end-to-end claim of the whole feature**, and the only test that exercises
 every layer of it at once: a name in a list becomes a generated
 `[vk::binding(1, 0)]`, comes back through reflection as a binding index, is
 pushed as a descriptor by `SampledBindings`, and is what the body samples. Any
 one of those failing is a frame that is not the colour of the texture.

 The body ignores `p.color` entirely, so the assertion does not have to reason
 about what the scene was: whatever the frame contained, it comes out the colour
 of the sampler — which is also what makes the swap unambiguous.

 **Proved by injection.** `SampledBindings.collect` returning without adding
 anything — the frame comes back white, because the binding the layout declares
 goes unwritten and the sampler reads the driver's idea of nothing. That is
 precisely the undefined behaviour `render/bind.c3`'s header describes, and it is
 why every declared binding is written every draw rather than only the filled
 ones.
*>
fn void a_post_texture_reaches_the_pixels_and_can_be_swapped() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		asymmetric_scene(renderer);

		int green = solid_texture(renderer, 20, 230, 40);
		int blue = solid_texture(renderer, 30, 40, 220);

		three::MaterialTexture[1] textures = { { "tint_map" } };
		renderer.post.set(
			&renderer.gpu,
			&renderer.target,
			`float3 post(Post p) { return tint_map.Sample(float2(0.5, 0.5)).rgb; }`,
			{},
			textures[..],
			&renderer.pass.assets
		)!!;
		renderer.post.set_texture(&renderer.gpu, &renderer.pass.assets, "tint_map", green)!!;

		image::Image tinted = renderer.capture()!!;
		defer tinted.free();
		float red_mean = band_mean(&tinted, 0, true);
		float green_mean = band_mean(&tinted, 1, true);
		float blue_mean = band_mean(&tinted, 2, true);
		test::@check(
			green_mean > red_mean + 40.0 && green_mean > blue_mean + 40.0,
			"the frame is the texture's green: r %f g %f b %f",
			red_mean, green_mean, blue_mean
		);

		// Live, with no compile: the same pipeline, a different descriptor.
		renderer.post.set_texture(&renderer.gpu, &renderer.pass.assets, "tint_map", blue)!!;

		image::Image swapped = renderer.capture()!!;
		defer swapped.free();
		test::@check(
			band_mean(&swapped, 2, true) > band_mean(&swapped, 1, true) + 40.0,
			"and swapping the texture swapped the frame: g %f b %f",
			band_mean(&swapped, 1, true), band_mean(&swapped, 2, true)
		);

		// A name the shader does not declare is refused rather than ignored — the
		// setter is where a typo is reported, because the getter cannot be.
		fault unknown = @catch(
			renderer.post.set_texture(&renderer.gpu, &renderer.pass.assets, "no_such_map", blue)
		);
		test::@check(unknown == three::MATERIAL_SAMPLER_UNKNOWN, "an unknown sampler is refused, got %s", unknown);

		// And the references are given back with the shader that held them, so a
		// pass that is cleared is not still pinning two images.
		test::@check(renderer.pass.assets.texture_refs(blue) == 2,
			"the pass holds the image it is showing plus this test's own reference: %d",
			renderer.pass.assets.texture_refs(blue));
		renderer.post.clear(&renderer.gpu, &renderer.pass.assets);
		test::@check(renderer.pass.assets.texture_refs(blue) == 1,
			"and clearing gave it back: %d", renderer.pass.assets.texture_refs(blue));
	};
}

// ============================================================================
// The chain
//
// Everything above this line is one pass, which is the chain's N = 1 case and
// says nothing about the other N. These are the checks that N > 1 exists: that
// the passes run in the order they were added, that a later one can still reach
// the frame the geometry left, that the ping-pong images are barriered, and
// that what travels between passes is float rather than eight bits.
// ============================================================================

<*
 A chain runs its passes in the order they were added.

 The two bodies are deliberately **not commutative**, because a check built on
 commutative ones would pass with the chain reversed, with the chain running
 twice, or with the list iterated backwards. Adding a quarter to red and then
 zeroing red is black; zeroing red and then adding a quarter is a quarter.

 The second body is also what makes this a check on the *ping-pong* rather than
 only on the list: pass 2 samples what pass 1 wrote, so a chain that handed every
 pass image A instead would leave the fixture's own red in place and answer with
 the fixture rather than with zero.
*>
fn void a_chain_runs_its_passes_in_order() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		asymmetric_scene(renderer);

		renderer.post.set(&renderer.gpu, &renderer.target,
			`float3 post(Post p) { return p.color + float3(0.25, 0, 0); }`, {})!!;
		uint second = renderer.post.add(&renderer.gpu, &renderer.target,
			`float3 post(Post p) { return p.color * float3(0, 1, 1); }`, {})!!;

		test::@check(second == 1, "the second pass took index 1, got %d", second);
		test::@check(renderer.post.count() == 2, "and the chain is two long, got %d", renderer.post.count());

		image::Image added = renderer.capture()!!;
		defer added.free();

		test::@check(band_mean(&added, 0, true) < 1.0,
			"red was added and then zeroed, so it is gone: %f", band_mean(&added, 0, true));
		test::@check(band_mean(&added, 2, true) > 20.0,
			"and blue came through both passes untouched: %f", band_mean(&added, 2, true));

		// The same two bodies the other way round, which is the whole control: if
		// order did not reach the GPU these two frames would be the same picture.
		renderer.post.set(&renderer.gpu, &renderer.target,
			`float3 post(Post p) { return p.color * float3(0, 1, 1); }`, {})!!;
		renderer.post.add(&renderer.gpu, &renderer.target,
			`float3 post(Post p) { return p.color + float3(0.25, 0, 0); }`, {})!!;

		image::Image reversed = renderer.capture()!!;
		defer reversed.free();

		test::@check(band_mean(&reversed, 0, true) > 100.0,
			"reversed, the quarter of red is the last thing that happened: %f",
			band_mean(&reversed, 0, true));
	};
}

<*
 A later pass can read the frame the geometry left, not only its predecessor.

 `p.scene` is the chain's one non-adjacent edge and the whole reason there are
 two reserved bindings rather than one — bloom is `blur(bright(scene)) + scene`,
 which wants the original picture three passes later. This is that, reduced to
 the smallest thing that cannot pass by accident: **pass 1 destroys the frame
 completely** and pass 2 rebuilds it from `p.scene`, so the result is the
 unposted frame if and only if binding 1 is image A.

 **Proved by injection.** Binding 1 wired to `io.prev` in `PostStage.record`:
 "the second pass read image A past a pass that returned black: 141 levels".
 Wired to nothing the sampler reads white, which is the same size of failure in
 the other direction — and that is why the first body returns black rather than
 something subtler.

 It also exercises the reflection guard on the reserved bindings: pass 1 never
 mentions `p.color` or `p.scene`, so Slang is free to drop both samplers from its
 layout, and pushing a descriptor for a binding the layout does not declare is a
 validation error. `pipeline_declares_binding` is why this is silent.
*>
fn void a_later_pass_reads_the_scene_and_not_only_its_predecessor() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		asymmetric_scene(renderer);

		image::Image plain = renderer.capture()!!;
		defer plain.free();

		renderer.post.set(&renderer.gpu, &renderer.target,
			`float3 post(Post p) { return float3(0, 0, 0); }`, {})!!;

		image::Image blacked = renderer.capture()!!;
		defer blacked.free();
		test::@check(band_mean(&blacked, 2, true) < 1.0,
			"the first pass really did destroy the frame: %f", band_mean(&blacked, 2, true));

		renderer.post.add(&renderer.gpu, &renderer.target,
			`float3 post(Post p) { return p.scene; }`, {})!!;

		image::Image restored = renderer.capture()!!;
		defer restored.free();

		int delta = worst_channel_delta(&plain, &restored);
		test::@check(delta <= 1,
			"the second pass read image A past a pass that returned black: %d levels", delta);
	};
}

<*
 What travels between two passes is linear float, not eight bits.

 **The check that pins `POST_CHAIN_FORMAT`**, and it is built the only way a
 clamp can be seen from the outside: multiply by sixteen and divide by sixteen
 again. Both are exact in half float, so an unclamped chain is the identity —
 while an 8-bit intermediate saturates every channel above 1/16 at 1.0 and hands
 the second pass 1/16 back for all of them, which is a visibly flat, dark frame.

 Powers of two on purpose. A factor like 3 would leave the identity claim
 resting on rounding as well as on range, and the failure this is about is range.

 **Sixteen and not four**, which was measured rather than chosen: this fixture is
 lit, so its linear values sit around a quarter, and ×4 puts them right at the
 clamp edge — the injection below reported 4 levels with it, which is a check that
 technically bites and would not survive a slightly darker scene.

 **Proved by injection.** `POST_CHAIN_FORMAT` set to `FORMAT_R8G8B8A8_SRGB`:
 "the chain clamped what passed between its two passes: 70 levels". Restored,
 green again — and worth knowing that every other check in this file stayed green
 throughout, including the identity one, because a chain of one never puts a
 value above 1.0 into a ping-pong image.
*>
fn void the_chain_carries_values_above_one_between_passes() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		asymmetric_scene(renderer);

		renderer.post.set(&renderer.gpu, &renderer.target, IDENTITY, {})!!;
		image::Image once = renderer.capture()!!;
		defer once.free();

		renderer.post.set(&renderer.gpu, &renderer.target,
			`float3 post(Post p) { return p.color * 16.0; }`, {})!!;
		renderer.post.add(&renderer.gpu, &renderer.target,
			`float3 post(Post p) { return p.color * 0.0625; }`, {})!!;

		image::Image amplified = renderer.capture()!!;
		defer amplified.free();

		int delta = worst_channel_delta(&once, &amplified);
		test::@check(delta <= 1, "the chain clamped what passed between its two passes: %d levels", delta);
	};
}

<*
 A chain of three is silent under the validation layer.

 `the_post_pass_is_silent_under_validation` for N > 1, and the barriers it adds
 are the ones nothing above it covers: **P0 and P1 go COLOR_ATTACHMENT_OPTIMAL →
 SHADER_READ_ONLY_OPTIMAL between passes and are re-opened from UNDEFINED by the
 pass after next**, which is the ping-pong reuse. Three passes rather than two so
 that P0 is written, sampled and written again inside one command buffer, which
 is the case a chain of two never reaches.

 Same instrument and same reason as the single-pass check: none of this has a
 pixel symptom on this driver. The frames are captured and dropped; the assertion
 is on the layer's silence.

 **Proved by injection.** The `shader_read_barrier(dst.image)` at the end of
 `record_chain`'s loop removed: "VUID-vkCmdDraw-imageLayout-00344: vkCmdDraw():
 Cannot use VkImage ... with specific layout
 VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL (specified by combined image sampler
 descriptor [Set 0, Binding 0, Index 0, variable 'prev']) that doesn't match the
 previous known layout VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL", with every
 pixel check in this file still green. Restored, green again.
*>
fn void a_chain_is_silent_under_validation() @test
{
	@with_validating_pass(; three::Renderer* renderer)
	{
		if (!renderer.gpu.validation) return;

		asymmetric_scene(renderer);

		image::Image warmup = renderer.capture()!!;
		warmup.free();

		renderer.gpu.begin_capture();

		renderer.post.set(&renderer.gpu, &renderer.target,
			`float3 post(Post p) { return p.color * 1.5; }`, {})!!;
		renderer.post.add(&renderer.gpu, &renderer.target,
			`float3 post(Post p) { return p.color.bgr; }`, {})!!;
		renderer.post.add(&renderer.gpu, &renderer.target,
			`float3 post(Post p) { return (p.color + p.scene) * 0.5; }`, {})!!;

		image::Image one = renderer.capture()!!;
		one.free();
		image::Image two = renderer.capture()!!;
		two.free();

		// The frame path with no consumer after it, for the single-pass check's
		// reason: "they all go through one function" is a claim worth holding down
		// rather than repeating.
		renderer.render_offscreen()!!;

		// Back to one pass and then to none, so the chain shrinks as well as
		// grows inside one captured span — the ping-pong image that pass 3 was
		// writing is left in SHADER_READ_ONLY by the frame before and must be
		// re-opened from UNDEFINED by the frame after.
		renderer.post.set(&renderer.gpu, &renderer.target, IDENTITY, {})!!;
		image::Image shrunk = renderer.capture()!!;
		shrunk.free();

		renderer.post.clear(&renderer.gpu);
		image::Image bare = renderer.capture()!!;
		bare.free();

		String errors = renderer.gpu.sink.errors.str_view();
		String warnings = renderer.gpu.sink.warnings.str_view();
		renderer.gpu.end_capture();

		test::@check(errors.len == 0, "the chain produced validation errors: %s", errors);
		test::@check(warnings.len == 0, "and warnings: %s", warnings);
	};
}

<*
 Every stage keeps its own uniforms, and setting one does not reach the other.

 The failure this is about is the quiet one: a chain whose uniform writes all
 landed on stage 0 would look completely correct on any script that only ever
 called `setPost`, and would silently ignore half of what a script using
 `addPass` asked for. Both passes here declare a uniform of the *same name*,
 which is what makes a shared block indistinguishable from a working one by any
 check that used different names.
*>
fn void each_stage_has_its_own_uniform_block() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		asymmetric_scene(renderer);

		three::MaterialUniform[1] gain = { { .name = "gain", .components = 1, .rows = 1 } };

		// Pass 1 scales, pass 2 scales again. With one shared block the second
		// write would overwrite the first and both passes would use it.
		renderer.post.set(&renderer.gpu, &renderer.target,
			`float3 post(Post p) { return p.color * gain; }`, gain[..])!!;
		renderer.post.add(&renderer.gpu, &renderer.target,
			`float3 post(Post p) { return p.color * gain; }`, gain[..])!!;

		// 4 then 0.25 is the identity; a shared block would make it 0.25 twice
		// (a sixteenth of the frame) or 4 twice (a clipped white one).
		renderer.post.set_uniform("gain", (float[]) { 4.0 }, 0)!!;
		renderer.post.set_uniform("gain", (float[]) { 0.25 }, 1)!!;

		image::Image scaled = renderer.capture()!!;
		defer scaled.free();

		renderer.post.set(&renderer.gpu, &renderer.target, IDENTITY, {})!!;
		image::Image plain = renderer.capture()!!;
		defer plain.free();

		int delta = worst_channel_delta(&plain, &scaled);
		test::@check(delta <= 1,
			"each stage used its own gain, so the two cancel: %d levels", delta);

		// And the stage index is checked rather than clamped: a write past the end
		// of the chain is a mistake with a name, not a write to the last pass.
		fault past = @catch(renderer.post.set_uniform("gain", (float[]) { 1.0 }, 7));
		test::@check(past == three::MATERIAL_UNIFORM_UNKNOWN,
			"a uniform written past the end of the chain is refused, got %s", past);
	};
}
