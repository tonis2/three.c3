<*
 The texture array the draw path binds, as the module that runs declares it.

 Every image a material wears is a slot of one device-wide array at set 1, and
 the module reads it through `map_at` with `NonUniformResourceIndex`. These are
 the facts `MeshPipeline.build_layouts` acts on: one set-1 binding of combined
 image samplers, and the SPIR-V capabilities a non-uniform index needs.

	`c3c test --trust=full --test-filter bindless`
*>
module three_tests::bindless;

import three;
import three_tests::device;
import image;
import std::core::test;
import vk;

<*
 The engine's own draw module compiles with the array in it, at the binding the
 table is bound to.
*>
fn void the_draw_module_declares_the_texture_array() @test
{
	three::ShaderModule mod = three::compile_shader(three::ShaderPass.MESH)!!;
	defer mod.free();
	test::@check(mod.ok, "the draw module does not compile: %s", mod.diagnostic);

	three::ShaderBinding* array = mod.layout.binding_of("three_textures");
	test::@check(array != null, "the module declares no texture array");
	if (array == null) return;

	test::@check(array.set == three::TEXTURE_TABLE_SET,
		"the array reflects in set %d and the table is bound at %d", array.set, three::TEXTURE_TABLE_SET);
	test::@check(array.binding == three::TEXTURE_TABLE_BINDING,
		"the array reflects at binding %d and the table declares %d",
		array.binding,
		three::TEXTURE_TABLE_BINDING);
	test::@check(array.type == DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
		"the array is not a combined image sampler, which is what the table holds");
	test::@check(mod.layout.set_count == 2, "the module declares %d sets, expected two", mod.layout.set_count);
}

<*
 The module asks for the SPIR-V capabilities the descriptor array needs.

 `RuntimeDescriptorArray` for the unsized array, `ShaderNonUniform` and
 `SampledImageArrayNonUniformIndexing` for the index, all core at SPIR-V 1.5.
*>
fn void the_module_declares_the_descriptor_indexing_capabilities() @test
{
	three::ShaderModule mod = three::compile_shader(three::ShaderPass.MESH)!!;
	defer mod.free();
	test::@check(mod.ok, "the draw module does not compile: %s", mod.diagnostic);

	// Word 1 of the header. 1.3 is the version this compiler targets, and the
	// capabilities below are declared rather than required to be core at it.
	uint version = ((uint*)mod.spirv.ptr)[1];
	test::@check(version >= 0x00010300, "the module is SPIR-V %x, older than the compiler's target", version);

	test::@check(spirv_declares_capability(mod.spirv, CAPABILITY_RUNTIME_DESCRIPTOR_ARRAY),
		"the module does not declare RuntimeDescriptorArray");
	test::@check(spirv_declares_capability(mod.spirv, CAPABILITY_SHADER_NON_UNIFORM),
		"the module does not declare ShaderNonUniform");
	// `SampledImageArrayNonUniformIndexing` is not declared: it is one of the
	// capabilities a higher SPIR-V version makes core, and the module validates
	// for Vulkan 1.3 without it — which is what `shader_adapter_test.c3` checks
	// with `spirv-val`.
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
				checks += 'ok = ok && abs(t' + i + '().Sample(s.uv).r - ' + (v / 255).toFixed(6) + ') < 0.01;';
			}
			const material = new three.ShaderMaterial({ textures, fragment:
				'fn float3 shade(Surface s) { bool ok = true;' + checks + ' return ok ? float3(0,1,0) : float3(1,0,0); }' });
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
