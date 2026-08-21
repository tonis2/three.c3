<*
 Slang at runtime: the compile, the diagnostic, the reflection and the cache.

	`c3c test --trust=full --test-noleak --test-filter three_tests::shader`

 **Most of this needs no GPU**, which is the point of keeping the compiler and
 the reflection walk separate from pipeline creation. A shader that fails to
 compile, a diagnostic that carries a line number, and a descriptor layout
 derived from a module are all answerable without a device, and they run in
 milliseconds.

 `plan.md` §7 asks for four things here by name: that a known-good shader
 compiles to non-empty SPIR-V, that a known-bad one produces a diagnostic
 containing the line number, that the pipeline cache returns the identical handle
 for identical source, and that a shader with known bindings produces the
 expected descriptor layout. All four are below.
*>
module three_tests::shader;

import three;
import vk;
import image;
import slang;
import std::core::test;
import std::io;

const String MESH_PATH = "shaders/mesh.slang";

<*
 A shader with one binding of every kind this pass can translate, in two sets.

 Deliberately not `mesh.slang`: the real shader has exactly one descriptor, so a
 reflection walk that only ever looked at binding range zero would pass every
 check against it. This one has six, including an array and a separate sampler,
 and it is the case that tells `Texture2D` from `Sampler2D` — the distinction
 that is invisible at two of Slang's three levels of reflection.
*>
const String RICH_SOURCE = `
struct Params { float4 tint; float time; };
[vk::binding(0, 0)] ConstantBuffer<Params> params;
[vk::binding(1, 0)] Sampler2D albedo;
[vk::binding(2, 0)] Texture2D extras[4];
[vk::binding(3, 0)] SamplerState linearSampler;
[vk::binding(0, 1)] StructuredBuffer<float4> points;

struct PushBlock { float4x4 mvp; uint flags; };
[vk_push_constant] const PushBlock pc;

struct VOut { float2 uv : TEXCOORD0; float4 sv_position : SV_Position; };

[shader("vertex")]
VOut vertexMain(uint vid : SV_VertexID)
{
	VOut o;
	o.sv_position = mul(pc.mvp, points[vid]);
	o.uv = float2(0, 0);
	return o;
}

[shader("fragment")]
float4 fragmentMain(VOut i) : SV_Target
{
	float3 c = albedo.Sample(i.uv).rgb * params.tint.rgb;
	c += extras[1].Sample(linearSampler, i.uv).rgb * params.time;
	return float4(c, 1.0);
}
`;

// A global rather than a function returning `three::MESH_ENTRIES[..]`: a slice
// literal is backed by the stack frame that made it, and c3c says so.
const three::ShaderEntry[2] BOTH_STAGES = {
	{ "vertexMain", slang::STAGE_VERTEX },
	{ "fragmentMain", slang::STAGE_FRAGMENT },
};

macro three::ShaderEntry[] both_stages() => BOTH_STAGES[..];

// ============================================================================
// Compiling
// ============================================================================

<*
 A known-good shader compiles to non-empty SPIR-V (`plan.md` §7).

 The magic number is checked by `compile_slang` itself, so a module that is not
 SPIR-V arrives as a fault rather than as bytes — which is why this asserts on
 the length and on `ok` rather than re-reading the first four bytes.
*>
fn void the_mesh_shader_compiles_from_a_string() @test
{
	String source = three::load_source(MESH_PATH)!!;
	defer source.free(mem);

	three::ShaderModule mod = three::compile_slang(source, "mesh.slang", both_stages())!!;
	defer mod.free();

	test::@check(mod.ok, "it compiled: %s", mod.diagnostic);
	test::@check(mod.spirv.len > 0, "and produced a module");
	test::@check(mod.spirv.len % 4 == 0, "which is a whole number of words");
	test::@check(mod.diagnostic.len == 0, "with nothing to say about it: %s", mod.diagnostic);
}

<*
 The two entry points come back named, with their stages — in reflection *and*
 in the module.

 Both halves matter and they are different claims. Reflection is what
 `check_entry_points` reads; the module's own `OpEntryPoint` names are what
 `vkCreateGraphicsPipelines` looks up, and a module whose stages are both called
 `main` fails there with no mention of a name.

 This is deliberately *not* presented as the check on
 `-fvk-use-entrypoint-name`. On the SDK this was built against that flag turns
 out to be a no-op — removing it produces a byte-identical module — so a test
 claiming to catch its removal would be an assumption. See `SLANG_ARGUMENTS`.
*>
fn void the_entry_points_keep_their_names() @test
{
	String source = three::load_source(MESH_PATH)!!;
	defer source.free(mem);

	three::ShaderModule mod = three::compile_slang(source, "mesh.slang", both_stages())!!;
	defer mod.free();

	test::@check(mod.entries.len() == 2, "two entry points, got %d", mod.entries.len());

	bool vertex = false;
	bool fragment = false;
	foreach (entry : mod.entries)
	{
		if (entry.name == "vertexMain" && entry.stage == slang::STAGE_VERTEX) vertex = true;
		if (entry.name == "fragmentMain" && entry.stage == slang::STAGE_FRAGMENT) fragment = true;
	}
	test::@check(vertex, "vertexMain is a vertex shader");
	test::@check(fragment, "fragmentMain is a fragment shader");

	// `OpEntryPoint` carries the name as a literal string, so the module itself
	// can be asked rather than only the reflection that describes it.
	String module_bytes = (String)mod.spirv;
	test::@check(module_bytes.contains("vertexMain"), "and the module names vertexMain");
	test::@check(module_bytes.contains("fragmentMain"), "and fragmentMain");
}

<*
 **Matrices are column-major**, which `slangc` defaults to and the compile-request
 API does not.

 This is the M4 bug that cost the most, and it is worth a check of its own
 because of how it failed: every matrix in the frame block and the instance
 array was read transposed, the truck rendered a completely convincing picture,
 and only the built-in triangle collapsed to fourteen pixels. Nothing reported an
 error at any layer.

 Asserted on the type name Slang emits into the module, which is the cheapest
 signal that does not need a device. The two checks that would also catch it —
 `instances_land_where_their_transforms_say` and
 `the_shader_rotates_normals_per_instance` — both need a GPU and both did fail
 when this was wrong, so this is the fast tripwire rather than the only one.
*>
fn void matrices_are_column_major() @test
{
	String source = three::load_source(MESH_PATH)!!;
	defer source.free(mem);

	three::ShaderModule mod = three::compile_slang(source, "mesh.slang", both_stages())!!;
	defer mod.free();

	test::@check(
		((String)mod.spirv).contains("ColMajor"),
		"the module declares column-major matrix storage — without it every transform is read transposed"
	);
}

<*
 Two compiles of the same source produce the same bytes.

 Not a curiosity: the pipeline cache is keyed on source, so a compiler that
 answered differently for the same input would mean a cache hit and a cache miss
 are not the same pipeline.
*>
fn void the_same_source_compiles_to_the_same_bytes() @test
{
	String source = three::load_source(MESH_PATH)!!;
	defer source.free(mem);

	three::ShaderModule first = three::compile_slang(source, "mesh.slang", both_stages())!!;
	defer first.free();
	three::ShaderModule second = three::compile_slang(source, "mesh.slang", both_stages())!!;
	defer second.free();

	test::@check(first.spirv.len == second.spirv.len, "same length: %d and %d", first.spirv.len, second.spirv.len);
	test::@check(first.spirv == second.spirv, "and the same bytes");
}

// ============================================================================
// Diagnostics
// ============================================================================

<*
 A known-bad shader produces a diagnostic containing the line number
 (`plan.md` §7).

 The line number is what is asserted rather than the message, because the message
 is Slang's to change and the line is what an agent uses to fix the script. The
 error is deliberately on line 6 of a 9-line shader, so a diagnostic that reported
 line 1 — or the first line of the *file* rather than of the source string —
 would not accidentally pass.
*>
fn void a_bad_shader_says_which_line() @test
{
	String source = `struct VOut { float4 sv_position : SV_Position; };

[shader("vertex")]
VOut vertexMain(uint vid : SV_VertexID)
{
	VOut o;
	o.sv_position = notAFunction(vid);
	return o;
}`;

	three::ShaderModule mod = three::compile_slang(source, "bad.slang", both_stages())!!;
	defer mod.free();

	test::@check(!mod.ok, "it did not compile");
	test::@check(mod.spirv.len == 0, "and produced no module");
	test::@check(mod.diagnostic.len > 0, "and said something");
	test::@check(mod.diagnostic.contains("bad.slang:7"), "naming line 7: %s", mod.diagnostic);
	test::@check(mod.diagnostic.contains("notAFunction"), "and the identifier that is wrong");
}

<*
 A shader missing an entry point the caller named is an error, not a smaller
 module.

 `compile_slang` names its entry points rather than letting `[shader(...)]`
 attributes discover them, precisely so this is a diagnostic instead of a module
 the pipeline cannot use.
*>
fn void a_missing_entry_point_is_a_diagnostic() @test
{
	String source = `struct VOut { float4 sv_position : SV_Position; };
[shader("vertex")]
VOut vertexMain(uint vid : SV_VertexID) { VOut o; o.sv_position = float4(0,0,0,1); return o; }`;

	three::ShaderModule mod = three::compile_slang(source, "half.slang", both_stages())!!;
	defer mod.free();

	test::@check(!mod.ok, "a module without fragmentMain does not compile");
	test::@check(mod.diagnostic.contains("fragmentMain"), "and says which one is missing: %s", mod.diagnostic);
}

// ============================================================================
// Reflection
// ============================================================================

<*
 A shader with known bindings produces the descriptor layout it declared
 (`plan.md` §7).

 Every field is asserted, because each of them is derived from a different corner
 of Slang's reflection and each has its own way of being quietly wrong: the type
 comes from the binding range, the index from the descriptor-set view, the count
 from the range's descriptor count, and the set from the space offset.
*>
fn void a_shader_with_known_bindings_reflects_them() @test
{
	three::ShaderModule mod = three::compile_slang(RICH_SOURCE, "rich.slang", both_stages())!!;
	defer mod.free();
	test::@check(mod.ok, "the fixture compiles: %s", mod.diagnostic);

	test::@check(mod.layout.bindings.len() == 5, "five descriptors, got %d", mod.layout.bindings.len());
	test::@check(mod.layout.set_count == 2, "in two sets, got %d", mod.layout.set_count);

	three::ShaderBinding* params = mod.layout.binding_of("params");
	test::@check(params != null, "params is there");
	if (params != null)
	{
		test::@check(params.type == DESCRIPTOR_TYPE_UNIFORM_BUFFER, "params is a uniform buffer");
		test::@check(params.set == 0 && params.binding == 0, "at 0,0 — got %d,%d", params.set, params.binding);
		test::@check(params.count == 1, "one of it");
	}

	// The distinction the whole reflection walk exists for: a Sampler2D and a
	// Texture2D have the same type kind and the same parameter category.
	three::ShaderBinding* albedo = mod.layout.binding_of("albedo");
	test::@check(albedo != null, "albedo is there");
	if (albedo != null)
	{
		test::@check(
			albedo.type == DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
			"a Sampler2D is a combined image sampler, not a sampled image"
		);
		test::@check(albedo.binding == 1, "at binding 1, got %d", albedo.binding);
	}

	three::ShaderBinding* extras = mod.layout.binding_of("extras");
	test::@check(extras != null, "extras is there");
	if (extras != null)
	{
		test::@check(extras.type == DESCRIPTOR_TYPE_SAMPLED_IMAGE, "a Texture2D is a sampled image");
		// One binding of four, not four bindings — an array that arrived as
		// count 1 would allocate a descriptor set the shader overruns.
		test::@check(extras.count == 4, "an array of four, got %d", extras.count);
	}

	three::ShaderBinding* sampler = mod.layout.binding_of("linearSampler");
	test::@check(sampler != null && sampler.type == DESCRIPTOR_TYPE_SAMPLER, "a SamplerState is a sampler");

	three::ShaderBinding* points = mod.layout.binding_of("points");
	test::@check(points != null, "points is there");
	if (points != null)
	{
		test::@check(points.type == DESCRIPTOR_TYPE_STORAGE_BUFFER, "a StructuredBuffer is a storage buffer");
		test::@check(points.set == 1, "in set 1, got %d", points.set);
	}

	// The push block is a constant buffer at reflection level and must not have
	// been counted as a descriptor. `bindings.len() == 5` above is that check
	// from the other side; this names it.
	test::@check(mod.layout.binding_of("pc") == null, "the push block is not a descriptor");
	test::@check(mod.layout.push_size == 68, "the push block is 68 bytes, got %d", mod.layout.push_size);
}

<*
 Both stages are in the derived stage mask.
*>
fn void the_stage_mask_covers_both_stages() @test
{
	three::ShaderModule mod = three::compile_slang(RICH_SOURCE, "rich.slang", both_stages())!!;
	defer mod.free();

	test::@check((mod.layout.stages & SHADER_STAGE_VERTEX_BIT) != (vk::ShaderStageFlags)0, "vertex is in the mask");
	test::@check((mod.layout.stages & SHADER_STAGE_FRAGMENT_BIT) != (vk::ShaderStageFlags)0, "fragment is in the mask");
}

<*
 The mesh shader's push block is exactly what `MeshPush` says it is.

 This is the check that was a comment until M4. `gpu/pipeline.c3`'s header has
 carried a table of these offsets since M1, and a table in a comment is worth
 what `project.json`'s `slangc` line was worth in M2 — which is to say it was
 wrong for a whole milestone and nothing noticed.
*>
fn void the_mesh_push_block_matches_the_struct() @test
{
	String source = three::load_source(MESH_PATH)!!;
	defer source.free(mem);

	three::ShaderModule mod = three::compile_slang(source, "mesh.slang", both_stages())!!;
	defer mod.free();
	test::@check(mod.ok, "it compiled: %s", mod.diagnostic);

	foreach (expected : three::MESH_PUSH_FIELDS)
	{
		three::ShaderField* found = mod.layout.field_of(expected.name);
		test::@check(found != null, "the shader has a '%s' field", expected.name);
		if (found == null) continue;
		test::@check(
			found.offset == expected.offset && found.size == expected.size,
			"'%s' is at %d+%d in the shader and %d+%d in MeshPush",
			expected.name, found.offset, found.size, expected.offset, expected.size
		);
	}

	// 76 used of the 80 the C3 struct occupies. The difference is tail padding
	// and is the reason `record` pushes the reflected size rather than
	// `MeshPush::size` — see the comment there.
	//
	// Against `MATERIAL_PUSH_START` rather than a literal: that constant is
	// derived from the last entry of `MESH_PUSH_FIELDS`, so adding a ninth
	// pinned field moves both together and this check keeps meaning what it
	// says. It was a literal 60 until `uv_transform` arrived and made it a 76.
	test::@check(mod.layout.push_size == three::MATERIAL_PUSH_START,
		"the block is %d bytes, got %d", three::MATERIAL_PUSH_START, mod.layout.push_size);
	test::@check(mod.layout.push_size <= three::MeshPush::size, "and fits inside MeshPush");

	// One descriptor, and it is the texture. Derived, not declared — until M4
	// this was a literal in `MeshPipeline.init`.
	test::@check(mod.layout.bindings.len() == 1, "one descriptor, got %d", mod.layout.bindings.len());
	three::ShaderBinding* map = mod.layout.binding_of("base_color_map");
	test::@check(map != null, "and it is base_color_map");
	if (map != null)
	{
		test::@check(map.type == DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, "a combined image sampler");
		test::@check(map.set == 0 && map.binding == 0, "at 0,0 — got %d,%d", map.set, map.binding);
	}
}

// ============================================================================
// The cache
// ============================================================================

macro @with_gpu(; @body(three::Gpu* gpu, three::Target* target))
{
	vk::Instance instance = three::create_instance(false, headless: true)!!;
	defer instance.free();

	three::Renderer renderer;
	renderer.init(instance, (vk::SurfaceKHR)null, 64, 48)!!;
	defer renderer.free();

	@body(&renderer.gpu, &renderer.target);
}

<*
 The pipeline cache returns the identical handle for identical source
 (`plan.md` §7) — and skips the Slang call to do it (`plan.md` §3).

 Both halves are asserted. The pointer alone would also be true of a cache that
 recompiled the shader and threw the result away, which is the one thing §3 says
 must not happen: compilation is the expensive half, about 17 ms against roughly
 1 ms for the pipeline.
*>
fn void the_pipeline_cache_skips_the_compile() @test
{
	@with_gpu(; three::Gpu* gpu, three::Target* target)
	{
		String source = three::load_source(MESH_PATH)!!;
		defer source.free(mem);

		three::PipelineCache cache;
		cache.init();
		defer cache.free(gpu);

		three::MeshPipeline* first = cache.acquire(gpu, target, source, "mesh.slang", three::SOLID_STATE)!!;
		test::@check(cache.compiles == 1, "the first acquire compiled");
		test::@check(cache.hits == 0, "and was not a hit");

		three::MeshPipeline* second = cache.acquire(gpu, target, source, "mesh.slang", three::SOLID_STATE)!!;
		test::@check(second == first, "the same pipeline came back");
		test::@check(cache.compiles == 1, "and Slang was not called again");
		test::@check(cache.hits == 1, "it was a hit");
	};
}

<*
 A different render state is a different pipeline, from the same source — and
 **not** a different compile.

 Both halves are easy to get wrong in opposite directions. Keying the pipeline on
 source alone hands a caller that asked for lines a pipeline built for triangles,
 which draws a wireframe index buffer three indices at a time and produces
 nothing recognisable. Keying the *compile* on the render state as well — which
 is what this cache did until M6 — calls Slang again for SPIR-V it already has,
 at about seventeen times the cost of the pipeline it was trying to avoid
 rebuilding.

 The state used to vary by cull mode. It cannot any more: the cull mode is
 dynamic, so two sides of one material are one pipeline, and topology is what is
 left that a pipeline has to be rebuilt for. `PipelineState` has the argument.
*>
fn void a_different_render_state_is_a_different_pipeline() @test
{
	@with_gpu(; three::Gpu* gpu, three::Target* target)
	{
		String source = three::load_source(MESH_PATH)!!;
		defer source.free(mem);

		three::PipelineCache cache;
		cache.init();
		defer cache.free(gpu);

		three::MeshPipeline* culled = cache.acquire(gpu, target, source, "mesh.slang", three::SOLID_STATE)!!;
		three::MeshPipeline* both = cache.acquire(gpu, target, source, "mesh.slang", three::LINE_STATE)!!;

		test::@check(culled != both, "two render states, two pipelines");
		test::@check(culled.handle != both.handle, "and two Vulkan handles");
		test::@check(cache.builds == 2, "two VkPipelines were built");
		// **One compile, not two.** This line read `compiles == 2` until M6, which
		// recorded the behaviour rather than objecting to it — nothing in the
		// product asked for a second render state, so nobody paid. Debug lines and
		// `material.side` both ask, and Slang emits byte-identical SPIR-V for every
		// one of them: topology, cull mode and the depth flags are pipeline fields
		// the shader never sees. See `CachedModule`.
		test::@check(cache.compiles == 1, "and shared one compile between them");
		test::@check(cache.modules.len() == 1, "because there is one module under both");
	};
}

<*
 A shader that does not compile is a fault out of the cache, and the cache keeps
 nothing.

 The failure path is where a cache is most likely to leave a half-built entry
 behind — and a cached failure would then be handed back to the next caller as
 though it were a pipeline.
*>
fn void a_broken_shader_leaves_the_cache_empty() @test
{
	@with_gpu(; three::Gpu* gpu, three::Target* target)
	{
		three::PipelineCache cache;
		cache.init();
		defer cache.free(gpu);

		three::MeshPipeline*? broken = cache.acquire(
			gpu, target, "this is not a shader", "broken.slang", three::SOLID_STATE
		);
		test::@check(@catch(broken), "it failed");
		test::@check(cache.entries.len() == 0, "and cached nothing");

		String source = three::load_source(MESH_PATH)!!;
		defer source.free(mem);
		three::MeshPipeline* good = cache.acquire(gpu, target, source, "mesh.slang", three::SOLID_STATE)!!;
		test::@check(good != null, "and the cache still works afterwards");
		test::@check(cache.entries.len() == 1, "with one entry");
	};
}

<*
 The descriptor set layout the pipeline was built with came from the shader.

 M4's done condition, asserted on the pipeline rather than on the reflection:
 what `MeshPipeline` carries is what `mesh.slang` declared, and nothing in
 `gpu/pipeline.c3` names `base_color_map` any more.
*>
fn void the_pipeline_layout_is_derived_from_the_shader() @test
{
	@with_gpu(; three::Gpu* gpu, three::Target* target)
	{
		String source = three::load_source(MESH_PATH)!!;
		defer source.free(mem);

		three::PipelineCache cache;
		cache.init();
		defer cache.free(gpu);

		three::MeshPipeline* pipeline = cache.acquire(gpu, target, source, "mesh.slang", three::SOLID_STATE)!!;

		test::@check(pipeline.descriptor_layout != null, "a descriptor set layout was created");
		test::@check(pipeline.shader.bindings.len() == 1, "from one reflected binding");
		test::@check(pipeline.shader.binding_of("base_color_map") != null, "named by the shader");
		test::@check(pipeline.shader.push_size == three::MATERIAL_PUSH_START,
			"with the shader's push size of %d, got %d", three::MATERIAL_PUSH_START, pipeline.shader.push_size);
	};
}

// ============================================================================
// Eviction
// ============================================================================

<*
 A released pipeline is kept, not destroyed.

 `PipelineCache.release` gives a borrow back and the entry is only *evictable*
 afterwards — the same distinction `texture.dispose()` draws. Asserted because
 the obvious implementation is the wrong one: destroying on the last release
 turns this into a refcounted allocator, and a script that disposes a material
 and builds the same one again — which is what an agent iterating on a scene
 does every run — would rebuild a pipeline the cache was still holding.

 **Proved by injection.** `trim` evicting whenever anything is unreferenced,
 rather than when the unreferenced ones outgrow the cap: "the entry stayed: 0".
*>
fn void a_released_pipeline_is_kept_for_the_next_acquire() @test
{
	@with_gpu(; three::Gpu* gpu, three::Target* target)
	{
		String source = three::load_source(MESH_PATH)!!;
		defer source.free(mem);

		three::PipelineCache cache;
		cache.init();
		defer cache.free(gpu);

		three::MeshPipeline* first = cache.acquire(gpu, target, source, "mesh.slang", three::SOLID_STATE)!!;
		cache.release(gpu, first);

		test::@check(cache.entries.len() == 1, "the entry stayed: %d", (int)cache.entries.len());
		test::@check(cache.evictions == 0, "and nothing was evicted: %d", cache.evictions);

		three::MeshPipeline* again = cache.acquire(gpu, target, source, "mesh.slang", three::SOLID_STATE)!!;
		test::@check(again == first, "the same pipeline came back");
		test::@check(cache.builds == 1, "and no second VkPipeline was built: %d", cache.builds);
		test::@check(cache.compiles == 1, "nor a second compile: %d", cache.compiles);
	};
}

<*
 The cache stops growing.

 `plan.md` §1's defect, and the whole reason any of this exists: an agent
 iterating on a shader accumulated one `VkPipeline` per distinct source for the
 life of the process, because nothing ever came off the list.

 Ten entries over five sources, which is two render states each and so five
 compiles rather than ten — the split `a_different_render_state_is_a_different_pipeline`
 pins, reused here to buy the entry count cheaply. Releasing all ten leaves two
 over `MAX_UNUSED_PIPELINES`, and the two that go are the two released first.

 **The module count is the second half and the more easily forgotten one.** Both
 of source zero's entries are evicted, so nothing holds its SPIR-V any more, and
 a cache that dropped the pipelines while keeping the compiles would have half
 of §1's accumulation still running.

 ## Proved by injection

 - **`trim` returning immediately**, which is the cache as `plan.md` §1 found
   it: "the cache trimmed to its cap of 8, and holds 10".
 - **`evict_at` not dropping the module at zero references:** "and the module
   nothing was built from any more went with them: 5". The entry count still
   comes back to 8, which is why both are asserted.
*>
fn void the_pipeline_cache_evicts_what_nothing_uses() @test
{
	@with_gpu(; three::Gpu* gpu, three::Target* target)
	{
		String source = three::load_source(MESH_PATH)!!;
		defer source.free(mem);

		three::PipelineCache cache;
		cache.init();
		defer cache.free(gpu);

		three::MeshPipeline*[10] held;
		@pool()
		{
			for (int i = 0; i < 5; i++)
			{
				// A trailing comment is a different source and the same shader:
				// the cache keys on content, so this is the cheapest way to ask
				// for a compile it has not seen.
				String variant = string::tformat("%s\n// %d\n", source, i);
				held[i * 2] = cache.acquire(gpu, target, variant, "mesh.slang", three::SOLID_STATE)!!;
				held[i * 2 + 1] = cache.acquire(gpu, target, variant, "mesh.slang", three::LINE_STATE)!!;
			}
		};

		test::@check(cache.entries.len() == 10, "ten entries went in: %d", (int)cache.entries.len());
		test::@check(cache.modules.len() == 5, "over five modules: %d", (int)cache.modules.len());
		test::@check(cache.evictions == 0, "and nothing was evicted while they were held: %d", cache.evictions);

		foreach (pipeline : held) cache.release(gpu, pipeline);

		test::@check(cache.entries.len() == (sz)three::MAX_UNUSED_PIPELINES,
			"the cache trimmed to its cap of %d, and holds %d", three::MAX_UNUSED_PIPELINES, (int)cache.entries.len());
		test::@check(cache.evictions == 2, "two entries were evicted: %d", cache.evictions);
		test::@check(cache.modules.len() == 4,
			"and the module nothing was built from any more went with them: %d", (int)cache.modules.len());
	};
}

<*
 A pipeline something still holds is not evicted, however cold it is.

 The first entry is retained a second time, so releasing every entry once leaves
 it at one borrow while its nine neighbours reach zero. It was also the *first*
 released, which is exactly the one the eviction order would reach for — so a
 cache that trimmed by age without consulting the count would take the one
 pipeline still being drawn with.

 Its module survives with it, and that is the same claim from the other side:
 the sibling entry over the same source *is* evicted, and the SPIR-V has to
 outlive that because something is still built from it.

 **Proved by injection.** `trim` not consulting `refs` when it picks: "one entry
 was evicted rather than two: 2" — the retained pipeline is the second one
 destroyed, and every material still drawing with it would then bind freed
 memory.
*>
fn void a_pipeline_something_still_holds_survives_the_eviction() @test
{
	@with_gpu(; three::Gpu* gpu, three::Target* target)
	{
		String source = three::load_source(MESH_PATH)!!;
		defer source.free(mem);

		three::PipelineCache cache;
		cache.init();
		defer cache.free(gpu);

		three::MeshPipeline*[10] held;
		@pool()
		{
			for (int i = 0; i < 5; i++)
			{
				String variant = string::tformat("%s\n// %d\n", source, i);
				held[i * 2] = cache.acquire(gpu, target, variant, "mesh.slang", three::SOLID_STATE)!!;
				held[i * 2 + 1] = cache.acquire(gpu, target, variant, "mesh.slang", three::LINE_STATE)!!;
			}
		};

		// The second borrow, standing in for a material that still draws with it.
		cache.retain(held[0]);

		foreach (pipeline : held) cache.release(gpu, pipeline);

		test::@check(cache.evictions == 1, "one entry was evicted rather than two: %d", cache.evictions);
		test::@check(cache.entries.len() == 9, "leaving nine: %d", (int)cache.entries.len());
		test::@check(cache.modules.len() == 5, "and every module still has a pipeline: %d", (int)cache.modules.len());

		// Not merely present — the same pointer, still usable. `entry_for` is a
		// pointer comparison, so a cache that had rebuilt this entry would answer
		// a different address and this would fail.
		bool kept = false;
		foreach (entry : cache.entries)
		{
			if (&entry.pipeline == held[0]) kept = true;
		}
		test::@check(kept, "and the held pipeline is the one that stayed");

		cache.release(gpu, held[0]);
	};
}
