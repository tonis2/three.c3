<*
 The Slang capture, held against the shady path that replaced it.

 `test/fixtures/shader_abi.txt` is what the Slang path reported for every module
 the engine compiles: entry points, descriptors with set/binding/count/type, push
 fields with offsets and sizes, push size, and the wire structs behind the push
 block's pointers. It was captured before the templates were deleted, and this
 test is what the capture was for: every variant is compiled again through the
 engine's own shady defs, serialized the same way, and compared.

 ## The port's deliberate differences

 Where the port changed the ABI on purpose, the difference is a `Delta` below,
 not a silent allowance: the fixture still records Slang, the delta names the
 line the shady module reports instead, and the reason it moved. A delta that is
 never observed is a failure too, so a stale entry cannot hide a return to the
 old shape.

 ## What the fixture cannot compare, and what this test does about it

 - **`MESH_REFERENCE` has no section.** Its Slang call site compiled a cache key
   rather than a template, so the capture has no counterpart. The shady module
   exists and is checked here on its own terms; the absence is asserted so the
   gap is not quietly filled by a fixture that grows a section nobody captured.
 - **A script's own names were never captured.** A script's uniform and texture
   names are not enumerable, so the scripted rows are compiled with one fixed
   body and declaration list each — the *template*'s shape, which is what the
   fixture records.
 - **Per-binding stages and member types are not recorded.** A `descriptor` line
   has no stage and a `struct_field` line has no type, so neither is compared
   here; the layout's stage union and the emitted types are pinned by
   `shader_adapter_test.c3` and the C3 structs themselves.
 - **The `source` lines are not compared.** They name the Slang template and the
   defines a variant was assembled from; the shady module is a def, not a file,
   so there is no counterpart line for the port to report.

 ## The struct sections

 The shady path reports no struct layouts — nothing in a SPIR-V module behind a
 push pointer carries one — so the fixture's `struct` and `struct_field` lines
 are checked against the C3 structs the generator emits them from. That is the
 same layout: `append_shader_abi` walks these types member for member, and the
 C3 side is measured rather than declared. `PushData` and `MaterialTable` are
 skipped because they are not C3 wire types: a push block is compared through
 the compiled module's own `push_field` and `push_size` lines above, and the
 spilled table through the material that declares it.

 `c3c test --trust=full --test-filter three_tests::shader_abi`
*>
module three_tests::shader_abi;

import three;
import vk;
import std::core::test;
import std::collections::list;
import std::io;
import std::io::file;

const String FIXTURE_PATH = "test/fixtures/shader_abi.txt";

// The built-in material's body, as `mesh.c3` holds it. A copy rather than a
// reference because the original is private to the def that returns it.
const String DEFAULT_SHADE = "fn float3 shade(Surface s) { return standard(s); }";

// The scripted rows' fixed bodies, one per fixture section. Every name a body
// reads is declared beside it below.
const String MATERIAL_PLAIN_BODY = "fn float3 shade(Surface s) { return s.albedo; }";
const String MATERIAL_DECLARED_BODY =
	"fn float3 shade(Surface s) { return s.albedo * s.uniforms.tint * s.uniforms.swatches[s.variant].rgb * noise_map().Sample(s.uv).rgb; }";
const String MATERIAL_VERTEX_BODY = "fn float3 shade(Surface s) { return s.albedo * s.uniforms.tint; }";
const String MATERIAL_VERTEX_DISPLACE = "fn void displace(inout Vertex v) { v.position.y += 0.01; }";
const String MATERIAL_SPILLED_BODY =
	"fn float3 shade(Surface s) { return s.albedo * s.uniforms.tint * s.uniforms.swatches[s.variant].rgb; }";
const String POST_BODY = "fn float3 post(Post p) { return p.color; }";
const String POST_DECLARED_BODY =
	"fn float3 post(Post p) { return p.color * tint_map.Sample(p.uv).rgb * p.uniforms.gain; }";

fn String stage_name(uint stage)
{
	switch (stage)
	{
		case three::STAGE_VERTEX: return "vertex";
		case three::STAGE_HULL: return "hull";
		case three::STAGE_DOMAIN: return "domain";
		case three::STAGE_GEOMETRY: return "geometry";
		case three::STAGE_FRAGMENT: return "fragment";
		case three::STAGE_COMPUTE: return "compute";
		default: return "stage-unknown";
	}
}

fn String vk_descriptor_name(vk::DescriptorType type)
{
	switch (type)
	{
		case DESCRIPTOR_TYPE_SAMPLER: return "SAMPLER";
		case DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER: return "COMBINED_IMAGE_SAMPLER";
		case DESCRIPTOR_TYPE_SAMPLED_IMAGE: return "SAMPLED_IMAGE";
		case DESCRIPTOR_TYPE_STORAGE_IMAGE: return "STORAGE_IMAGE";
		case DESCRIPTOR_TYPE_UNIFORM_TEXEL_BUFFER: return "UNIFORM_TEXEL_BUFFER";
		case DESCRIPTOR_TYPE_STORAGE_TEXEL_BUFFER: return "STORAGE_TEXEL_BUFFER";
		case DESCRIPTOR_TYPE_UNIFORM_BUFFER: return "UNIFORM_BUFFER";
		case DESCRIPTOR_TYPE_STORAGE_BUFFER: return "STORAGE_BUFFER";
		case DESCRIPTOR_TYPE_INPUT_ATTACHMENT: return "INPUT_ATTACHMENT";
		default: return "UNKNOWN";
	}
}

<*
 The text one compiled module reports, in the fixture's own vocabulary.
*>
fn void append_module(DString* out, String variant, three::ShaderModule* mod)
{
	out.appendf("[variant %s]\n", variant)!!;
	test::@check(mod.ok, "the %s module compiles: %s", variant, mod.diagnostic);
	if (!mod.ok) return;

	foreach (entry : mod.entries) out.appendf("entry %s %s\n", entry.name, stage_name(entry.stage))!!;
	foreach (binding : mod.layout.bindings)
	{
		out.appendf(
			"descriptor %s set=%d binding=%d count=%d type=%s\n",
			binding.name,
			binding.set,
			binding.binding,
			binding.count,
			vk_descriptor_name(binding.type)
		)!!;
	}
	out.appendf("push_size %d\n", mod.layout.push_size)!!;
	foreach (member : mod.layout.push_fields)
	{
		out.appendf(
			"push_field %s offset=%d size=%d indirect=%s\n",
			member.name,
			member.offset,
			member.size,
			member.indirect ? "yes" : "no"
		)!!;
	}
}

<*
 The built-in draw path, its reference half, and the lightmap bake: one body and
 the defs around it, with the empty uniform set every material carries.
*>
fn void append_built_in(DString* out, String variant, bool lightmap = false, bool reference = false)
{
	DString emitted;
	emitted.tinit(64);
	three::append_shady_uniforms(&emitted, {});
	defer emitted.free();

	three::ShaderDef def = three::mesh_def(
		DEFAULT_SHADE,
		emitted.str_view(),
		built_in: true,
		lightmap: lightmap,
		reference: reference
	);
	three::ShaderModule mod = three::compile_shady(def, three::MeshPush);
	defer mod.free();
	append_module(out, variant, &mod);
}

<*
 A scripted material or lightmap bake: the body plus its declared uniforms and
 textures, assembled exactly as the switch assembles them.
*>
fn void append_material(
	DString* out,
	String variant,
	String body,
	three::MaterialUniform[] uniforms,
	three::MaterialTexture[] textures,
	String vertex = "",
	bool bake = false,
	bool lightmap = false
)
{
	bool spilled = three::material_spills(uniforms);

	DString emitted;
	emitted.tinit(512);
	three::append_shady_uniforms(&emitted, uniforms, spilled);
	defer emitted.free();

	DString declared;
	declared.tinit(256);
	three::append_shady_textures(&declared, textures, three::MATERIAL_BINDING_FIRST, true);
	defer declared.free();

	three::ShaderDef def = three::mesh_def(
		body,
		emitted.str_view(),
		vertex,
		built_in: false,
		textures: declared.str_view(),
		bake: bake,
		lightmap: lightmap
	);
	def.uniforms_spilled = spilled;
	three::ShaderModule mod = three::compile_shady(def, three::MeshPush);
	defer mod.free();
	append_module(out, variant, &mod);
}

<*
 A post body or the engine's own tonemap: the same def with the four reserved
 samplers and a uniform set the body reads through `p.uniforms`.
*>
fn void append_post(
	DString* out,
	String variant,
	String body,
	three::MaterialUniform[] uniforms = {},
	three::MaterialTexture[] textures = {}
)
{
	DString emitted;
	emitted.tinit(256);
	three::append_shady_uniforms(&emitted, uniforms);
	defer emitted.free();

	DString declared;
	declared.tinit(256);
	three::append_shady_textures(&declared, textures, three::POST_BINDING_FIRST, false);
	defer declared.free();

	three::ShaderModule mod = three::compile_shady(
		three::post_def(body, emitted.str_view(), declared.str_view()),
		three::PostPush
	);
	defer mod.free();
	append_module(out, variant, &mod);
}

<*
 Every fixture variant, compiled through the def the switch gives its pass.
*>
fn String actual_text()
{
	DString out;
	out.tinit(64 * 1024);

	{
		three::ShaderModule mod = three::compile_shady(three::cluster_def(), three::ClusterPush);
		defer mod.free();
		append_module(&out, "cluster", &mod);
	}
	{
		three::ShaderModule mod = three::compile_shady(three::skin_def(), three::SkinPush);
		defer mod.free();
		append_module(&out, "skin", &mod);
	}
	{
		three::ShaderModule mod = three::compile_shady(three::shadow_def(), three::ShadowPush);
		defer mod.free();
		append_module(&out, "shadow", &mod);
	}
	{
		three::ShaderModule mod = three::compile_shady(three::shadow_cutout_def(), three::ShadowPush);
		defer mod.free();
		append_module(&out, "shadow_cutout", &mod);
	}
	{
		three::ShaderModule mod = three::compile_shady(three::sky_def(), three::SkyPush);
		defer mod.free();
		append_module(&out, "sky", &mod);
	}

	append_built_in(&out, "mesh");
	append_built_in(&out, "mesh_lightmap", lightmap: true);
	// The one variant with no fixture section: Slang never compiled a module for
	// it. Checked on its own below, and named here so the gap stays visible.
	append_built_in(&out, "mesh_reference", reference: true);

	{
		three::MaterialUniform[] none = { };
		three::MaterialTexture[] no_textures = { };
		append_material(&out, "material_plain", MATERIAL_PLAIN_BODY, none, no_textures);

		three::MaterialUniform[2] declared = {
			{ .name = "tint", .components = 3, .rows = 1 },
			{ .name = "swatches", .components = 4, .rows = 4 },
		};
		three::MaterialTexture[1] noise = { { .name = "noise_map" } };
		append_material(&out, "material_declared", MATERIAL_DECLARED_BODY, declared[..], noise[..]);

		three::MaterialUniform[1] tint = { { .name = "tint", .components = 3, .rows = 1 } };
		append_material(
			&out,
			"material_vertex",
			MATERIAL_VERTEX_BODY,
			tint[..],
			no_textures,
			vertex: MATERIAL_VERTEX_DISPLACE
		);

		three::MaterialUniform[2] spilled = {
			{ .name = "tint", .components = 3, .rows = 1 },
			{ .name = "swatches", .components = 4, .rows = 8 },
		};
		append_material(&out, "material_spilled", MATERIAL_SPILLED_BODY, spilled[..], no_textures);

		append_material(&out, "material_bake", MATERIAL_PLAIN_BODY, none, no_textures, bake: true);
		append_material(&out, "lightmap_material", MATERIAL_PLAIN_BODY, none, no_textures, lightmap: true);
	}

	{
		three::MaterialUniform[] none = { };
		three::MaterialTexture[] no_textures = { };
		append_post(&out, "post", POST_BODY);

		three::MaterialUniform[1] gain = { { .name = "gain", .components = 1, .rows = 1 } };
		three::MaterialTexture[1] tint_map = { { .name = "tint_map" } };
		append_post(&out, "post_declared", POST_DECLARED_BODY, gain[..], tint_map[..]);

		append_post(&out, "tonemap_none", three::tonemap_body_shady(three::ToneMap.NONE), none, no_textures);
		three::MaterialUniform[1] exposure = { { .name = "exposure", .components = 1, .rows = 1 } };
		append_post(&out, "tonemap_agx", three::tonemap_body_shady(three::ToneMap.AGX), exposure[..]);
		append_post(
			&out,
			"tonemap_agx_blender",
			three::tonemap_body_shady(three::ToneMap.AGX_BLENDER),
			exposure[..]
		);
	}

	return out.copy_str(mem);
}

// ============================================================================
// The fixture, parsed
// ============================================================================

struct Line
{
	String variant;
	String text;
}

struct Parsed
{
	List{String} variants;
	List{Line} lines;
}

fn void Parsed.free(&self)
{
	self.variants.free();
	self.lines.free();
}

fn Parsed parse(String text)
{
	Parsed out;
	out.variants.init(mem, 16);
	out.lines.init(mem, 256);

	String current = "";
	usz at = 0;
	while (at < text.len)
	{
		usz start = at;
		while (at < text.len && text[at] != '\n') at++;
		String line = text[start:at - start];
		if (at < text.len) at++;
		if (line.len > 0 && line[line.len - 1] == '\r') line = line[:line.len - 1];
		if (line.len == 0 || line[0] == '#') continue;
		// The fixture's `source` line names the Slang text a variant came from —
		// a template and its defines. The shady module is a def, not a file, so
		// there is nothing on the port's side to compare it with.
		if (line.starts_with("source ")) continue;
		// Struct sections are not module report lines: `check_structs` reads
		// them against the C3 declarations directly, which is the only side that
		// can produce a struct layout.
		if (line.starts_with("struct ") || line.starts_with("struct_field ")) continue;
		if (line.starts_with("[variant ") && line.ends_with("]"))
		{
			current = line[9 : line.len - 10];
			out.variants.push(current);
			continue;
		}
		out.lines.push({ .variant = current, .text = line });
	}
	return out;
}

fn void lines_of(List{Line}* lines, String variant, List{String}* out)
{
	foreach (line : *lines) if (line.variant == variant) out.push(line.text);
}

fn bool has_variant(List{String}* variants, String name)
{
	foreach (variant : *variants) if (variant == name) return true;
	return false;
}

// ============================================================================
// The port's deliberate differences
// ============================================================================

<*
 One line the shady module reports where the Slang capture says something else.

 `expected` is the fixture's line, the empty string when the fixture could not
 name the line at all; `actual` is what the port reports instead, and `reason`
 is the sentence a reader gets when either side moves. A delta that is never
 seen in both texts is a failure.
*>
struct Delta
{
	String variant;
	String expected;
	String actual;
	String reason;
}

fn void delta(List{Delta}* out, String variant, String expected, String actual, String reason)
{
	out.push({ .variant = variant, .expected = expected, .actual = actual, .reason = reason });
}

<*
 The block a built-in module carries: the walk plus the emitted `Uniforms` member
 that keeps `Surface.uniforms` the same type for every material.
*>
const String EMPTY_UNIFORMS_REASON =
	"the port's built-in half always declares the empty Uniforms member, and the block rounds up to its alignment";

fn void collect_deltas(List{Delta}* out)
{
	// The empty uniform member, and the rounding Slang did not report: Slang's
	// push size is the last byte of the fields, the port's is the range size.
	delta(out, "mesh", "push_size 24", "push_size 32", EMPTY_UNIFORMS_REASON);
	delta(out, "mesh_lightmap", "push_size 24", "push_size 32", EMPTY_UNIFORMS_REASON);
	delta(out, "material_plain", "push_size 24", "push_size 32", EMPTY_UNIFORMS_REASON);
	delta(out, "material_bake", "push_size 24", "push_size 32", EMPTY_UNIFORMS_REASON);
	delta(out, "lightmap_material", "push_size 24", "push_size 32", EMPTY_UNIFORMS_REASON);
	delta(out, "post", "push_size 24", "push_size 28", EMPTY_UNIFORMS_REASON);
	delta(out, "tonemap_none", "push_size 24", "push_size 28", EMPTY_UNIFORMS_REASON);
	delta(out, "material_declared", "push_size 100", "push_size 104",
		"the block is rounded up to its 8-byte alignment; Slang reported the unrounded size");
	delta(out, "material_vertex", "push_size 36", "push_size 40",
		"the block is rounded up to its 8-byte alignment; Slang reported the unrounded size");

	// A spilled set is one storage in the port: the whole Uniforms struct is the
	// device-buffer table, so the scalars move with the columns and the block is
	// the walk plus the pointer Slang also carried.
	delta(out, "material_spilled", "push_size 44", "push_size 32",
		"the port spills the whole uniform struct, so the block keeps only the table pointer");
	delta(out, "material_spilled", "push_field swatches offset=0 size=128 indirect=yes",
		"push_field swatches offset=12 size=128 indirect=yes", "the scalar `tint` sits in the table before it");
	delta(out, "material_spilled", "push_field tint offset=32 size=12 indirect=no",
		"push_field tint offset=0 size=12 indirect=yes", "the port keeps one storage for a spilled set, scalars included");

	// Declarations Slang dropped from reflection as unread. The port emits every
	// declaration its files name; the passes bind the shared white to any an
	// image was not written for, so a declared-but-unread sampler is supported.
	const String UNREAD = "shady emits every declaration the shared files name; Slang dropped this one as unread";
	delta(out, "mesh_lightmap", "", "descriptor ltc_lut set=0 binding=19 count=1 type=COMBINED_IMAGE_SAMPLER",
		"the lightmap bake carries the LTC half, whose table declaration the capture does not list");
	delta(out, "mesh_lightmap", "", "descriptor ambient_occlusion_depth set=0 binding=4 count=1 type=COMBINED_IMAGE_SAMPLER", UNREAD);
	delta(out, "material_vertex", "", "descriptor ambient_occlusion_depth set=0 binding=4 count=1 type=COMBINED_IMAGE_SAMPLER", UNREAD);
	delta(out, "material_bake", "", "descriptor ltc_lut set=0 binding=19 count=1 type=COMBINED_IMAGE_SAMPLER",
		"the bake carries the LTC half alongside the built-in look");
	delta(out, "lightmap_material", "", "descriptor ltc_lut set=0 binding=19 count=1 type=COMBINED_IMAGE_SAMPLER",
		"the bake carries the LTC half");
	delta(out, "lightmap_material", "", "descriptor ambient_occlusion_depth set=0 binding=4 count=1 type=COMBINED_IMAGE_SAMPLER", UNREAD);
	delta(out, "lightmap_material", "", "descriptor lightmap_atlas set=0 binding=20 count=1 type=COMBINED_IMAGE_SAMPLER",
		"the port declares the lightmap atlas unconditionally, where the Slang shaping dropped it");

	// The cut-out module is `shadow.shady` plus its own vertex entry, so the pose
	// file's `vertexMain` reaches the module beside `cutoutVertexMain`.
	delta(out, "shadow_cutout", "", "entry cutoutVertexMain vertex",
		"the cut-out module is shadow.shady plus its own vertex entry, so it carries both");
}

// ============================================================================
// The comparison
// ============================================================================

<*
 Pairs the two line lists, consuming a delta wherever one applies.

 Anything left unmatched on either side is a failure naming the variant and the
 line. A delta whose two lines are not both found is a failure too, which is
 what stops this table from drifting away from the port.
*>
fn void compare_variant(
	String variant,
	List{String}* expected,
	List{String}* actual,
	List{Delta}* deltas,
	bool[] delta_used)
{
	sz expected_count = expected.len();
	sz actual_count = actual.len();
	bool[] expected_used = alloc::new_array(mem, bool, expected_count > 0 ? expected_count : 1);
	bool[] actual_used = alloc::new_array(mem, bool, actual_count > 0 ? actual_count : 1);
	defer
	{
		alloc::free(mem, expected_used);
		alloc::free(mem, actual_used);
	};

	foreach (i, &d : *deltas)
	{
		if (d.variant != variant) continue;

		if (d.expected.len > 0)
		{
			bool found = false;
			foreach (j, line : *expected)
			{
				if (expected_used[j] || line != d.expected) continue;
				expected_used[j] = true;
				found = true;
				break;
			}
			test::@check(found, "%s: the fixture records '%s' for the reason '%s'", variant, d.expected, d.reason);
		}

		bool found = false;
		foreach (j, line : *actual)
		{
			if (actual_used[j] || line != d.actual) continue;
			actual_used[j] = true;
			found = true;
			break;
		}
		test::@check(found, "%s: the port reports '%s' for the reason '%s'", variant, d.actual, d.reason);
		if (found) delta_used[i] = true;
	}

	foreach (i, want : *expected)
	{
		if (expected_used[i]) continue;
		bool found = false;
		foreach (j, got : *actual)
		{
			if (actual_used[j] || got != want) continue;
			actual_used[j] = true;
			found = true;
			break;
		}
		test::@check(found, "%s: the fixture records '%s', and the shady module does not", variant, want);
	}

	foreach (j, got : *actual)
	{
		if (actual_used[j]) continue;
		test::@check(false, "%s: the shady module reports '%s', which the fixture does not", variant, got);
	}
}

// ============================================================================
// The struct sections, against the C3 declarations the generator walks
// ============================================================================

struct C3Member
{
	String structure;
	String name;
	uint offset;
	uint size;
}

struct C3Struct
{
	String name;
	uint size;    // the C3 struct's storage size, which is a stride
	uint max_end; // the last byte any member occupies
	List{C3Member} members;
}

fn void C3Struct.free(&self)
{
	self.members.free();
}

macro @record_struct(List{C3Struct}* out, $Type, String name)
{
	C3Struct recorded;
	recorded.name = name;
	recorded.size = (uint)$Type::size;
	recorded.members.init(mem, $Type::members.len);
	var $max_end = 0;
	$foreach $m : $Type::members:
		recorded.members.push(
			{
				.structure = name,
				.name = $m.name,
				.offset = (uint)$m.offset,
				.size = (uint)$m.size,
			}
		);
		var $end = $m.offset + $m.size;
		$if $end > $max_end:
			$max_end = $end;
		$endif
	$endforeach
	recorded.max_end = (uint)$max_end;
	out.push(recorded);
}

fn void record_wire_structs(List{C3Struct}* out)
{
	@record_struct(out, three::Light, "Light");
	@record_struct(out, three::ShadowGpuView, "ShadowGpuView");
	@record_struct(out, three::Instance, "Instance");
	@record_struct(out, three::DrawRecord, "Draw");
	@record_struct(out, three::SkinnedVertex, "SkinnedVertex");
	@record_struct(out, three::MorphDelta, "MorphDelta");
	@record_struct(out, three::FrameBlock, "FrameBlock");
	@record_struct(out, three::ClusterPush, "ClusterPush");
	@record_struct(out, three::SkinPush, "SkinPush");
	@record_struct(out, three::SkyPush, "SkyPush");
}

fn C3Struct* find_struct(List{C3Struct}* all, String name)
{
	foreach (&known : *all) if (known.name == name) return known;
	return null;
}

fn uint uint_after(String line, String key)
{
	sz? at = line.index_of(key);
	if (catch at) return 0xFFFF_FFFF;
	usz i = (usz)at + key.len;
	uint value = 0;
	bool digits = false;
	while (i < line.len && line[i] >= '0' && line[i] <= '9')
	{
		value = value * 10 + (uint)(line[i] - '0');
		i++;
		digits = true;
	}
	return digits ? value : 0xFFFF_FFFF;
}

fn String text_at(String line, usz start, String terminator)
{
	usz end = start;
	while (end < line.len && !line[end..].starts_with(terminator)) end++;
	return line[start:end - start];
}

<*
 A `struct NAME size=… stride=…` line: the fixture's size is the last byte a
 field ends on, and its stride is the C3 struct's own storage size.
*>
fn void check_struct_line(List{C3Struct}* all, String line)
{
	String name = text_at(line, 7, " size=");
	C3Struct* known = find_struct(all, name);
	if (known == null) return; // PushData, MaterialTable: covered by the module's own lines.

	uint size = uint_after(line, "size=");
	uint stride = uint_after(line, "stride=");
	test::@check(
		size == known.max_end,
		"%s: the fixture records %d bytes of fields, the C3 struct ends at %d",
		name,
		size,
		known.max_end
	);
	test::@check(
		stride == known.size,
		"%s: the fixture records a %d-byte stride, the C3 struct is %d bytes",
		name,
		stride,
		known.size
	);
}

<*
 A `struct_field NAME.MEMBER offset=… size=…` line, matched to the C3 member.
*>
fn void check_member_line(List{C3Struct}* all, String line)
{
	usz at = "struct_field ".len;
	usz dot = at;
	while (dot < line.len && line[dot] != '.') dot++;
	String name = line[at:dot - at];
	String member = text_at(line, dot + 1, " offset=");

	C3Struct* known = find_struct(all, name);
	if (known == null) return;

	bool found = false;
	foreach (field : known.members)
	{
		if (field.name != member) continue;
		found = true;
		uint offset = uint_after(line, "offset=");
		uint size = uint_after(line, "size=");
		test::@check(
			offset == field.offset && size == field.size,
			"%s.%s: the fixture records %d+%d, the C3 member is %d+%d",
			name,
			member,
			offset,
			size,
			field.offset,
			field.size
		);
		break;
	}
	test::@check(found, "the fixture names %s.%s, which the C3 struct does not have", name, member);
}

<*
 The fixture's wire structs are the C3 structs the shady generator emits.

 `PushData` and `MaterialTable` are not C3 wire types and return early: the push
 block is compared through the compiled module's own fields above, and the
 spilled table through the material that declares it.
*>
fn void check_structs(String fixture_text)
{
	List{C3Struct} all;
	all.init(mem, 12);
	record_wire_structs(&all);
	defer
	{
		foreach (&known : all) known.free();
		all.free();
	};

	usz at = 0;
	while (at < fixture_text.len)
	{
		usz start = at;
		while (at < fixture_text.len && fixture_text[at] != '\n') at++;
		String line = fixture_text[start:at - start];
		if (at < fixture_text.len) at++;

		if (line.starts_with("struct_field "))
		{
			check_member_line(&all, line);
		}
		else if (line.starts_with("struct "))
		{
			check_struct_line(&all, line);
		}
	}
}

// ============================================================================
// The test
// ============================================================================

fn void the_fixture_is_what_the_shady_path_reports() @test
{
	char[]? loaded = file::load(mem, FIXTURE_PATH);
	if (catch loaded)
	{
		test::@check(false, "the checked-in fixture %s is readable", FIXTURE_PATH);
		return;
	}
	String fixture = (String)loaded;
	defer fixture.free(mem);

	test::@check(fixture.len > 0, "the fixture is not empty");

	Parsed expected = parse(fixture);
	defer expected.free();

	String actual_string = actual_text();
	defer actual_string.free(mem);
	Parsed actual = parse(actual_string);
	defer actual.free();

	// MESH_REFERENCE is the one pass Slang could not compile; the capture has no
	// section for it. Asserted rather than assumed, so a fixture grown a section
	// nobody captured is a failure and the gap stays named.
	test::@check(!has_variant(&expected.variants, "mesh_reference"),
		"the fixture has no MESH_REFERENCE section, as the capture could not make one");

	List{Delta} deltas;
	deltas.init(mem, 24);
	collect_deltas(&deltas);
	defer deltas.free();

	bool[] delta_used = alloc::new_array(mem, bool, deltas.len());
	defer alloc::free(mem, delta_used);

	foreach (variant : expected.variants)
	{
		List{String} want;
		want.init(mem, 48);
		List{String} got;
		got.init(mem, 48);
		lines_of(&expected.lines, variant, &want);
		lines_of(&actual.lines, variant, &got);

		test::@check(got.len() > 0, "the shady path compiled a %s module", variant);
		compare_variant(variant, &want, &got, &deltas, delta_used);

		want.free();
		got.free();
	}

	foreach (i, &d : deltas)
	{
		test::@check(delta_used[i], "%s: the documented difference was not seen: %s -> %s (%s)",
			d.variant, d.expected, d.actual, d.reason);
	}

	check_structs(fixture);
}

<*
 The reference module, which has no Slang counterpart to compare against.

 Its own facts are pinned here: the two entry points, the walk of `MeshPush` plus
 the empty uniform set, and no `ltc_lut` — the one resource difference from the
 fitted draw path.
*>
fn void the_reference_module_is_the_one_without_a_slang_counterpart() @test
{
	DString emitted;
	emitted.tinit(64);
	three::append_shady_uniforms(&emitted, {});
	defer emitted.free();

	three::ShaderDef def = three::mesh_def(DEFAULT_SHADE, emitted.str_view(), built_in: true, reference: true);
	three::ShaderModule mod = three::compile_shady(def, three::MeshPush);
	defer mod.free();

	test::@check(mod.ok, "the reference module compiles: %s", mod.diagnostic);
	if (!mod.ok) return;

	bool vertex = false;
	bool fragment = false;
	foreach (entry : mod.entries)
	{
		if (entry.name == "vertexMain" && entry.stage == three::STAGE_VERTEX) vertex = true;
		if (entry.name == "fragmentMain" && entry.stage == three::STAGE_FRAGMENT) fragment = true;
	}
	test::@check(vertex && fragment, "it has the draw path's two entry points");
	test::@check(mod.layout.push_size == 32, "its push block is the walk plus the empty uniforms, got %d", mod.layout.push_size);
	test::@check(mod.layout.binding_of("ltc_lut") == null, "and the numeric integration declares no fit table");
}
