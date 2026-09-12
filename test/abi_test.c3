<*
 The shader ABI, emitted from the C3 wire structs.

 Every declaration below is cut out of the shader that declares it today and
 compared, comments and whitespace removed from both sides, against what the
 emitter produces. Once the Slang templates are replaced there is only one
 declaration and nothing to compare; until then this is what holds the emitter
 to the wire format the running engine writes.

 `DrawRecord` is the one that cannot be compared this way - the Slang text calls
 it `Draw` and inlines its uv table as `float4` rows where the C3 struct says
 `UvVariant` - so it is pinned on its own below.
*>
module three_tests::abi;

import three;
import std::core::test;
import std::io;

<*
 Everything between a declaration's braces, cut at the first `}`. These
 declarations never nest one inside another.
*>
fn String body_of(String declaration)
{
	sz? open = declaration.index_of("{");
	if (catch open) return "";
	sz? close = declaration[open..].index_of("}");
	if (catch close) return "";
	return declaration[open + 1 : close - 1];
}

<*
 A declaration without its comments, whitespace or semicolons, so two spellings
 of the same struct compare equal or differ in something that matters.
*>
fn String stripped(String text)
{
	DString out;
	out.tinit();
	usz i = 0;
	while (i < text.len)
	{
		if (i + 1 < text.len && text[i] == '/' && text[i + 1] == '/')
		{
			while (i < text.len && text[i] != '\n') i++;
			continue;
		}
		char c = text[i++];
		if (c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == ';') continue;
		out.append_char(c);
	}
	return out.str_view();
}

// The text starting at `header`, or "" when the source does not contain it.
fn String declaration_at(String source, String header)
{
	sz? start = source.index_of(header);
	if (catch start) return "";
	return source[start..];
}

fn void same_declaration(String abi, String shader, String abi_header, String shader_header, String what)
{
	// The Slang text calls the record `Draw` where the emitter uses the C3 name
	// - `the_record_keeps_the_c3_names` pins that difference - so the name is
	// folded away here and everything else has to match.
	String generated = stripped(body_of(declaration_at(abi, abi_header))).treplace("DrawRecord", "Draw");
	String declared  = stripped(body_of(declaration_at(shader, shader_header)));
	test::@check(generated.len > 0, "%s: the emitter produced a declaration", what);
	test::@check(generated == declared,
		"%s: the emitted declaration should be the shader's, field for field;\nemitted:  %s\ndeclared: %s",
		what, generated, declared);
}

fn void the_emitted_declarations_are_what_the_shaders_declare() @test
{
	DString out;
	out.tinit(8192);
	three::append_shader_abi(&out);
	String abi = out.str_view();

	String mesh = three::load_source("shaders/mesh.slang")!!;
	defer mesh.free(mem);
	same_declaration(abi, mesh, "struct Light", "struct Light", "Light");
	same_declaration(abi, mesh, "struct ShadowGpuView", "struct ShadowGpuView", "ShadowGpuView");
	same_declaration(abi, mesh, "struct Instance", "struct Instance", "Instance");
	same_declaration(abi, mesh, "struct SkinnedVertex", "struct SkinnedVertex", "SkinnedVertex");
	same_declaration(abi, mesh, "struct MorphDelta", "struct MorphDelta", "MorphDelta");
	same_declaration(abi, mesh, "struct FrameBlock", "struct FrameBlock", "FrameBlock");
	same_declaration(abi, mesh, "struct MeshPush", "struct PushData", "MeshPush");

	String skin = three::load_source("shaders/skin.slang")!!;
	defer skin.free(mem);
	same_declaration(abi, skin, "struct SkinPush", "struct SkinPush", "SkinPush");

	String cluster = three::load_source("shaders/cluster.slang")!!;
	defer cluster.free(mem);
	same_declaration(abi, cluster, "struct ClusterPush", "struct ClusterPush", "ClusterPush");

	String sky = three::load_source("shaders/sky.slang")!!;
	defer sky.free(mem);
	same_declaration(abi, sky, "struct SkyPush", "struct SkyPush", "SkyPush");

	String shadow = three::load_source("shaders/shadow.slang")!!;
	defer shadow.free(mem);
	same_declaration(abi, shadow, "struct ShadowPush", "struct PushData", "ShadowPush");
}

<*
 The record the Slang text spells differently, so the differences are stated
 rather than assumed away.

 The C3 name is what a ported shader will use - `DrawRecord`, not `Draw`, since
 the emitter would otherwise need a rename table and a rename table is where the
 ABI would start drifting. The uv table is `UvVariant`, whose four floats are
 the rows `surface.slang` reads, rather than the `float4[8]` the Slang text
 inlined to say the same thing.
*>
fn void the_record_keeps_the_c3_names() @test
{
	DString out;
	out.tinit(4096);
	three::append_shader_abi(&out);
	String abi = out.str_view();

	String record = declaration_at(abi, "struct DrawRecord");
	test::@check(record.contains("float3* positions;"), "the geometry streams point at their own type");
	test::@check(record.contains("uint4* joints;"), "so do the joint and weight streams");
	test::@check(record.contains("UvVariant uv_variants[8];"),
		"the uv table is the C3 struct rather than the float4 rows Slang inlined");
	test::@check(record.contains("uint texture_index[24];"), "and an array stays an array");
}
