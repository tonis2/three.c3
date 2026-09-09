<*
 The Slang the templates will use once the material bodies read the texture
 array, compiled through this project's own compiler.

 Nothing in the engine samples through `TextureTable` yet. These checks are the
 contract the migration is written against, pinned before it starts: if a spelling
 here stops compiling — or stops reflecting the way `MeshPipeline.build_layouts`
 needs it to — that is a change to the templates and not a surprise inside them.

	`c3c test --trust=full --test-filter bindless`
*>
module three_tests::bindless;

import three;
import three_tests::device;
import image;
import std::core::test;
import slang;
import vk;

const three::ShaderEntry[2] BOTH_STAGES = {
	{ "vertexMain", slang::STAGE_VERTEX },
	{ "fragmentMain", slang::STAGE_FRAGMENT },
};

<*
 The declarations, the accessor and every spelling a generated body uses.

 A wrapper struct rather than a `#define` per map, because a body writes
 `name.Sample(uv)`, `name.SampleGrad(uv, gx, gy)` and `name.SampleLevel(uv, 0)`
 against the same name, and helpers like `stochastic_sample(image, uv)` take one
 *by parameter* — which a macro cannot be. The methods carry
 `NonUniformResourceIndex`, so a read inside a divergent branch is correct
 wherever it appears without a body ever spelling it.
*>
const String BINDLESS_PROBE = `
[vk::binding(0, 1)] Sampler2D three_textures[];

struct PushData
{
    uint4 rows[2];
};
[vk::push_constant] PushData push;

// What every map in a generated body becomes: an index into the one array, with
// the four spellings a body can use.
struct Map
{
    // Which row of the draw record's index table, *not* the array index itself:
    // that is what lets a declared texture be a compile-time constant global.
    uint at;

    uint slot() { return push.rows[at >> 2u][at & 3u]; }

    float4 Sample(float2 uv) { return three_textures[NonUniformResourceIndex(slot())].Sample(uv); }
    float4 SampleGrad(float2 uv, float2 gx, float2 gy)
    {
        return three_textures[NonUniformResourceIndex(slot())].SampleGrad(uv, gx, gy);
    }
    float4 SampleLevel(float2 uv, float lod)
    {
        return three_textures[NonUniformResourceIndex(slot())].SampleLevel(uv, lod);
    }
    float4 SampleBias(float2 uv, float bias)
    {
        return three_textures[NonUniformResourceIndex(slot())].SampleBias(uv, bias);
    }
};

Map map_at(uint at) { Map m; m.at = at; return m; }

// What the assembler writes for a texture a body declared: a compile-time
// constant global, so a body's name shadows nothing and is shadowed by nothing.
static const Map declared_map = { 5u };

// A helper taking a map by parameter, which is what stochastic_sample and
// triplanar_tap are today.
float4 stochastic_sample(Map image, float2 uv)
{
    float2 dx = ddx(uv);
    float2 dy = ddy(uv);
    return image.SampleGrad(uv, dx, dy) * 0.5 + image.SampleGrad(uv + 0.25, dx, dy) * 0.5;
}

struct VertexOutput
{
    float4 position : SV_Position;
    float2 uv : TEXCOORD0;
};

[shader("vertex")]
VertexOutput vertexMain(uint vertex_id : SV_VertexID)
{
    VertexOutput out;
    out.position = float4(float(vertex_id), 0.0, 0.0, 1.0);
    out.uv = float2(0.5, 0.5);
    return out;
}

[shader("fragment")]
float4 fragmentMain(VertexOutput in) : SV_Target
{
    // A body's own spelling, unchanged from what it writes against a Sampler2D.
    Map base_color_map = map_at(0);
    Map normal_map     = declared_map;

    float4 c = base_color_map.Sample(in.uv);
    c += normal_map.SampleLevel(in.uv, 0.0);
    c += stochastic_sample(base_color_map, in.uv);

    // A read inside a branch that differs between lanes — the case
    // NonUniformResourceIndex exists for.
    if (in.uv.x > 0.5)
    {
        c += map_at(6).SampleGrad(in.uv, ddx(in.uv), ddy(in.uv));
    }
    return c;
}
`;

<*
 The array, the non-uniform index and all four sample spellings compile.

 This is the whole of what the migration needs from the compiler. `-O0`,
 `-emit-spirv-directly` and `-force-glsl-scalar-layout` are what
 `SLANG_ARGUMENTS` passes, and no capability flag is added for this — if one is
 ever needed, this is the check that says so.
*>
fn void the_bindless_declarations_compile_through_this_compiler() @test
{
	three::ShaderModule mod = three::compile_slang(BINDLESS_PROBE, "bindless.slang", BOTH_STAGES[..])!!;
	defer mod.free();
	test::@check(mod.ok, "the bindless probe does not compile: %s", mod.diagnostic);
}

<*
 The module asks for the SPIR-V capabilities the descriptor array needs.

 `RuntimeDescriptorArray` for the unsized array, `ShaderNonUniform` and
 `SampledImageArrayNonUniformIndexing` for the index. It emits **SPIR-V 1.5**,
 where all three are core — so there is no `OpExtension SPV_EXT_descriptor_indexing`
 in the module and none is wanted; the extension spelling is what a 1.0-to-1.3
 target would need. `SLANG_ARGUMENTS` passes no capability flag for any of this
 and none turns out to be needed.
*>
fn void the_module_declares_the_descriptor_indexing_capabilities() @test
{
	three::ShaderModule mod = three::compile_slang(BINDLESS_PROBE, "bindless.slang", BOTH_STAGES[..])!!;
	defer mod.free();
	test::@check(mod.ok, "the bindless probe does not compile: %s", mod.diagnostic);

	// Word 1 of the header. 1.5 is what makes the three capabilities below core.
	uint version = ((uint*)mod.spirv.ptr)[1];
	test::@check(version >= 0x00010500, "the module is SPIR-V %x, below the 1.5 that has these in core", version);

	test::@check(spirv_declares_capability(mod.spirv, CAPABILITY_RUNTIME_DESCRIPTOR_ARRAY),
		"the module does not declare RuntimeDescriptorArray");
	test::@check(spirv_declares_capability(mod.spirv, CAPABILITY_SHADER_NON_UNIFORM),
		"the module does not declare ShaderNonUniform");
	test::@check(
		spirv_declares_capability(mod.spirv, CAPABILITY_SAMPLED_IMAGE_ARRAY_NON_UNIFORM_INDEXING),
		"the module does not declare SampledImageArrayNonUniformIndexing"
	);
}

<*
 Reflection puts the array in set 1, as one binding of a combined image sampler.

 The two facts `MeshPipeline.build_layouts` will act on: it creates *one*
 descriptor set layout today and refuses a module whose bindings fall into more
 than one, so the migration's first renderer change is to leave set 1 to
 `TextureTable` rather than to build a layout for it.
*>
fn void the_array_reflects_as_one_binding_in_set_one() @test
{
	three::ShaderModule mod = three::compile_slang(BINDLESS_PROBE, "bindless.slang", BOTH_STAGES[..])!!;
	defer mod.free();
	test::@check(mod.ok, "the bindless probe does not compile: %s", mod.diagnostic);

	three::ShaderBinding* array = mod.layout.binding_of("three_textures");
	test::@check(array != null, "reflection dropped the texture array");
	if (array == null) return;

	test::@check(array.set == three::TEXTURE_TABLE_SET,
		"the array reflects in set %d and the table is bound at %d", array.set, three::TEXTURE_TABLE_SET);
	test::@check(array.binding == three::TEXTURE_TABLE_BINDING,
		"the array reflects at binding %d and the table declares %d",
		array.binding,
		three::TEXTURE_TABLE_BINDING);
	test::@check(array.type == DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
		"the array is not a combined image sampler, which is what the table holds");
	test::@check(mod.layout.set_count == 2, "the probe declares %d sets, expected two", mod.layout.set_count);
}

// The three SPIR-V capability numbers this needs, from the core grammar.
const uint CAPABILITY_SHADER_NON_UNIFORM @local = 5301;
const uint CAPABILITY_RUNTIME_DESCRIPTOR_ARRAY @local = 5302;
const uint CAPABILITY_SAMPLED_IMAGE_ARRAY_NON_UNIFORM_INDEXING @local = 5307;

<*
 Does this module contain `OpCapability <what>`?

 A walk of the words rather than a disassembly: SPIR-V is a five-word header
 followed by instructions whose first word is `(length << 16) | opcode`, and
 `OpCapability` is opcode 17 with one operand. Every capability is declared in
 the first block of the module, so the walk stops at the first instruction that
 is not one.
*>
fn bool spirv_declares_capability(char[] spirv, uint what) @local
{
	if (spirv.len < 20) return false;
	uint* words = (uint*)spirv.ptr;
	usz count   = spirv.len / 4;

	for (usz at = 5; at + 1 < count;)
	{
		uint length = words[at] >> 16;
		uint opcode = words[at] & 0xffff;
		if (length == 0) return false;
		if (opcode != 17) return false;
		if (words[at + 1] == what) return true;
		at += length;
	}
	return false;
}

// ============================================================================
// End to end
// ============================================================================

const uint W @local = 96;
const uint H @local = 72;

macro @with_js(; @body(three::JsRuntime* run, three::Renderer* renderer)) @local
{
	three::Renderer* renderer = device::borrow(W, H);
	defer device::release();

	three::JsRuntime runtime;
	runtime.open(&renderer.pass, renderer)!!;
	defer runtime.close();

	@body(&runtime, renderer);
}

<*
 A material at the ceiling reads every one of its images, and each lands in the
 slot it was declared at.

 **The check the whole migration rests on.** A declared texture is an index in
 the draw record now, and an index that is off by one is not a compile error and
 not a validation error — it is the wrong picture, which is exactly the failure
 mode a per-draw descriptor set could not have. So the body checks its own maps:
 nineteen 1x1 images whose red channel is their own slot number, sampled and
 compared in the shader, green if every one of them is where it should be and red
 if any is not.

 Green against red rather than a colour comparison, because the answer has to
 survive tone mapping and the sRGB encode on the way to the framebuffer.
*>
fn void nineteen_declared_textures_each_land_in_their_own_slot() @test
{
	@with_js(; three::JsRuntime* run, three::Renderer* renderer)
	{
		three::RunResult built = run.run(`
			const N = 19;
			const textures = {};
			let checks = '';
			for (let i = 0; i < N; i++) {
				const v = i * 12;
				textures['t' + i] = new three.DataTexture(new Uint8Array([v, 0, 0, 255]), 1, 1,
					{ colorSpace: three.LinearSRGBColorSpace, generateMipmaps: false });
				checks += 'ok = ok && abs(t' + i + '.Sample(s.uv).r - ' + (v / 255).toFixed(6) + ') < 0.01;';
			}
			const material = new three.ShaderMaterial({ textures, fragment:
				'float3 shade(Surface s) { bool ok = true;' + checks + ' return ok ? float3(0,1,0) : float3(1,0,0); }' });
			const scene = new three.Scene();
			scene.add(new three.Mesh(new three.PlaneGeometry(2, 2), material));
			three.light.set([0, 0, 1], 1);
			three.camera.frameAll();
		`);
		defer built.free();
		test::@check(built.ok, "a nineteen-texture material built: %s", built.error);

		image::Image shot = renderer.capture()!!;
		defer shot.free();
		usz at = ((usz)(H / 2) * (usz)W + (usz)(W / 2)) * 4;
		char red   = shot.pixels[at];
		char green = shot.pixels[at + 1];
		test::@check(green > red,
			"a declared texture landed in the wrong slot — centre pixel is %d,%d,%d",
			red, green, shot.pixels[at + 2]);
	};
}
