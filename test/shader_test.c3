<*
 The compiled module, the reflection it produces, and the two caches.

	`c3c test --trust=full --test-noleak --test-filter three_tests::shader`

 The modules here are the engine's own defs, compiled through `compile_shader`,
 so a diagnostic that carries a line number and a descriptor layout derived from
 a module are answerable without a device. What needs the GPU is the pipeline
 cache and the disk cache's interaction with it.

 The cache tests each say which cache they mean on their first line: the disk
 directory survives between runs, so a test about the in-memory cache disables it
 and a test about the disk cache points it at a scratch directory of its own.
*>
module three_tests::shader;

import three;
import three_tests::device;
import vk;
import std::core::test;
import std::io::file;
import std::io::path;



// A global rather than a function returning `three::MESH_ENTRIES[..]`: a slice
// literal is backed by the stack frame that made it, and c3c says so.
const three::ShaderEntry[2] BOTH_STAGES = {
	{ "vertexMain", three::STAGE_VERTEX },
	{ "fragmentMain", three::STAGE_FRAGMENT },
};

macro three::ShaderEntry[] both_stages() => BOTH_STAGES[..];

fn String function_body(String source, String header)
{
	sz? found = source.index_of(header);
	if (catch found) return "";
	usz open = (usz)found;
	while (open < source.len && source[open] != '{') open++;
	if (open == source.len) return "";

	int depth = 0;
	for (usz i = open; i < source.len; i++)
	{
		if (source[i] == '{') depth++;
		if (source[i] != '}') continue;
		depth--;
		if (depth == 0) return source[open : i + 1 - open];
	}
	return "";
}

fn usz occurrence_count(String source, String needle)
{
	usz count = 0;
	usz start = 0;
	while (start < source.len)
	{
		sz? found = source[start..].index_of(needle);
		if (catch found) break;
		count++;
		start += (usz)found + needle.len;
	}
	return count;
}

// ============================================================================
// Compiling
// ============================================================================






// ============================================================================
// Diagnostics
// ============================================================================



// ============================================================================
// Reflection
// ============================================================================






<*
 One struct declaration, with its comments and whitespace taken out.

 The temp arena, so the caller has nothing to free — every use is inside one
 check.
*>
fn String declaration_of(String source, String header)
{
	sz? start = source.index_of(header);
	if (catch start) return "";
	sz? end = source[start..].index_of("};");
	if (catch end) return "";

	DString out;
	out.tinit();
	String body = source[start : end];
	sz i = 0;
	while (i < body.len)
	{
		if (i + 1 < body.len && body[i] == '/' && body[i + 1] == '/')
		{
			while (i < body.len && body[i] != '\n') i++;
			continue;
		}
		char c = body[i++];
		if (c == ' ' || c == '\t' || c == '\n' || c == '\r') continue;
		out.append_char(c);
	}
	return out.str_view();
}

// ============================================================================
// The cache
// ============================================================================

macro @with_gpu(; @body(three::Gpu* gpu, three::Target* target))
{
	three::Renderer* renderer = device::borrow(64, 48, with_pass: false);
	defer device::release();

	@body(&renderer.gpu, &renderer.target);
}

<*
 The pipeline cache returns the identical handle for identical source — and
 skips the compile to do it.

 Both halves are asserted. The pointer alone would also be true of a cache that
 recompiled the shader and threw the result away, which is what must not happen:
 compilation is the expensive half, about 17 ms against roughly 1 ms for the
 pipeline.
*>
fn void the_pipeline_cache_skips_the_compile() @test
{
	// **The convention for every test in this project that reads `compiles`.**
	//
	// The disk cache is on by default and its directory survives between runs,
	// so a second `c3c test` would answer this acquire off disk, leave
	// `compiles` at zero, and turn a test about the *in-memory* cache into a
	// test about the *disk* one — passing either way, asserting neither. Saying
	// so on the first line is the whole fix: `compiles` then means "the compiler
	// ran" and "the memory cache missed" again, which is what every line below
	// claims. `shader/disk_cache.c3` gets its own tests further down, and those
	// point the directory at a scratch of their own rather than disabling it.
	//
	// Set at the start rather than restored at the end: the test runner
	// longjmps out of a failed check and skips defers, so a restore is exactly
	// the line that does not run when it matters.
	three::shader_cache_set_dir("");

	@with_gpu(; three::Gpu* gpu, three::Target* target)
	{
		three::PipelineCache cache;
		cache.init();
		defer cache.free(gpu);

		three::MeshPipeline* first = cache.acquire(gpu, target, three::SOLID_STATE, three::ShaderPass.MESH)!!;
		test::@check(cache.compiles == 1, "the first acquire compiled");
		test::@check(cache.hits == 0, "and was not a hit");

		three::MeshPipeline* second = cache.acquire(gpu, target, three::SOLID_STATE, three::ShaderPass.MESH)!!;
		test::@check(second == first, "the same pipeline came back");
		test::@check(cache.compiles == 1, "and the compiler was not called again");
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
 is what this cache did until M6 — calls the compiler again for SPIR-V it already has,
 at about seventeen times the cost of the pipeline it was trying to avoid
 rebuilding.

 The state used to vary by cull mode. It cannot any more: the cull mode is
 dynamic, so two sides of one material are one pipeline, and topology is what is
 left that a pipeline has to be rebuilt for. `PipelineState` has the argument.
*>
fn void a_different_render_state_is_a_different_pipeline() @test
{
	// `compiles` means the compiler, not the disk cache — see `the_pipeline_cache_skips_the_compile`.
	three::shader_cache_set_dir("");

	@with_gpu(; three::Gpu* gpu, three::Target* target)
	{
		three::PipelineCache cache;
		cache.init();
		defer cache.free(gpu);

		three::MeshPipeline* culled = cache.acquire(gpu, target, three::SOLID_STATE, three::ShaderPass.MESH)!!;
		three::MeshPipeline* both = cache.acquire(gpu, target, three::LINE_STATE, three::ShaderPass.MESH)!!;

		test::@check(culled != both, "two render states, two pipelines");
		test::@check(culled.handle != both.handle, "and two Vulkan handles");
		test::@check(cache.builds == 2, "two VkPipelines were built");
		// **One compile, not two.** This line read `compiles == 2` until M6, which
		// recorded the behaviour rather than objecting to it — nothing in the
		// product asked for a second render state, so nobody paid. Debug lines and
		// `material.side` both ask, and the compiler emits byte-identical SPIR-V for every
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

		// A body that does not compile: the fault path of the cache.
		three::MeshPipeline*? broken = cache.acquire(
			gpu, target, three::SOLID_STATE, three::ShaderPass.MESH_MATERIAL,
			body: "fn float3 shade(Surface s) { return notAFunction(s.uv); }"
		);
		test::@check(@catch(broken), "it failed");
		test::@check(cache.entries.len() == 0, "and cached nothing");

		three::MeshPipeline* good = cache.acquire(gpu, target, three::SOLID_STATE, three::ShaderPass.MESH)!!;
		test::@check(good != null, "and the cache still works afterwards");
		test::@check(cache.entries.len() == 1, "with one entry");
	};
}

<*
 The descriptor set layout the pipeline was built with came from the shader.

 M4's done condition, asserted on the pipeline rather than on the reflection:
 what `MeshPipeline` carries is what the mesh def declared, and nothing in
 `gpu/pipeline.c3` names `base_color_map` any more.
*>
fn void the_pipeline_layout_is_derived_from_the_shader() @test
{
	// The bindings and the push size asserted below are the mesh def's, read
	// back off the module the pipeline is built from.
	@with_gpu(; three::Gpu* gpu, three::Target* target)
	{
		three::PipelineCache cache;
		cache.init();
		defer cache.free(gpu);

		three::MeshPipeline* pipeline = cache.acquire(gpu, target, three::SOLID_STATE, three::ShaderPass.MESH)!!;

		test::@check(pipeline.descriptor_layout != null, "a descriptor set layout was created");
		test::@check(pipeline.shader.bindings.len() == 8,
			"from eight reflected bindings — seven frame images and the texture array");
		test::@check(pipeline.shader.binding_of("shadow_atlas") != null, "the shared shadow atlas is named");
		test::@check(pipeline.shader.binding_of("environment_map") != null, "and the environment map");
		test::@check(pipeline.shader.binding_of("three_textures") != null, "and the device-wide texture array");
		test::@check(
			pipeline.shader.binding_of("normal_map") == null,
			"while the built-in material's own maps are slots of that array"
		);
		// The walk (24 bytes of pointers) plus the emitted empty Uniforms member,
		// rounded to the block's 8-byte alignment.
		test::@check(pipeline.shader.push_size == 32,
			"with the shader's push size of 32, got %d", pipeline.shader.push_size);
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
	// `compiles` means the compiler, not the disk cache — see `the_pipeline_cache_skips_the_compile`.
	three::shader_cache_set_dir("");

	@with_gpu(; three::Gpu* gpu, three::Target* target)
	{
		three::PipelineCache cache;
		cache.init();
		defer cache.free(gpu);

		three::MeshPipeline* first = cache.acquire(gpu, target, three::SOLID_STATE, three::ShaderPass.MESH)!!;
		cache.release(gpu, first);

		test::@check(cache.entries.len() == 1, "the entry stayed: %d", (int)cache.entries.len());
		test::@check(cache.evictions == 0, "and nothing was evicted: %d", cache.evictions);

		three::MeshPipeline* again = cache.acquire(gpu, target, three::SOLID_STATE, three::ShaderPass.MESH)!!;
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
		three::PipelineCache cache;
		cache.init();
		defer cache.free(gpu);

		three::MeshPipeline*[10] held;
		@pool()
		{
			for (int i = 0; i < 5; i++)
			{
				// A trailing comment is a different body and the same shading: the
				// cache keys on the inputs, so this is the cheapest way to ask for
				// a compile it has not seen.
				String variant = string::tformat("fn float3 shade(Surface s) { return s.albedo; } // %d", i);
				held[i * 2] = cache.acquire(gpu, target, three::SOLID_STATE,
					three::ShaderPass.MESH_MATERIAL, body: variant)!!;
				held[i * 2 + 1] = cache.acquire(gpu, target, three::LINE_STATE,
					three::ShaderPass.MESH_MATERIAL, body: variant)!!;
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
		three::PipelineCache cache;
		cache.init();
		defer cache.free(gpu);

		three::MeshPipeline*[10] held;
		@pool()
		{
			for (int i = 0; i < 5; i++)
			{
				String variant = string::tformat("fn float3 shade(Surface s) { return s.albedo; } // %d", i);
				held[i * 2] = cache.acquire(gpu, target, three::SOLID_STATE,
					three::ShaderPass.MESH_MATERIAL, body: variant)!!;
				held[i * 2 + 1] = cache.acquire(gpu, target, three::LINE_STATE,
					three::ShaderPass.MESH_MATERIAL, body: variant)!!;
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

// ============================================================================
// Blending
// ============================================================================

<*
 A body written twice, once opaque and once transparent, is **one** compile
 and **two** pipelines.

 The two halves fail in opposite directions and both are cheap mistakes to make.
 Leaving the blend mode out of `PipelineState.equals` hands the transparent
 material the opaque pipeline, which renders it solid — a bug that looks like the
 blending was never implemented. Folding the blend into the *module* key instead
 calls the compiler again for SPIR-V it already has, at about seventeen times
 the cost of the millisecond it was trying to save, on a device where the shader
 cannot see the blend state at all.

 It is `a_different_render_state_is_a_different_pipeline`'s claim over the axis
 that arrived with blending, and it is made through `create_material` rather than
 through a bare cache because the mapping from `blending` to a `PipelineState` is
 the half that could quietly stop varying.

 The counts are read as deltas over what `MeshPass.init` already built — the pass
 arrives holding the mesh module over four states. Absolute numbers here would
 be a second, weaker copy of `the_pass_prebuilds_the_blended_lambert_variants`,
 which is the test that owns that claim.

 **Proved by injection.** The blend folded into the module key — `create_material`
 appending `blend.ordinal` to the assembled source, which is what keying the
 compile on the render state amounts to: "one compile for both, got 2".
*>
fn void a_transparent_variant_of_one_source_is_one_compile() @test
{
	// `compiles` means the compiler, not the disk cache — see `the_pipeline_cache_skips_the_compile`.
	three::shader_cache_set_dir("");

	@with_gpu(; three::Gpu* gpu, three::Target* target)
	{
		three::MeshPass pass;
		pass.init(gpu, target)!!;
		defer pass.free(gpu);

		uint compiles = pass.pipelines.compiles;
		uint builds = pass.pipelines.builds;

		// One string, used twice. Two spellings of the same body would be two
		// modules whatever the blend did, and this check would pass against a
		// cache that had stopped sharing anything.
		String body = `fn float3 shade(Surface s) { return s.albedo * 0.5; }`;
		uint opaque = pass.create_material(gpu, target, body, {}, three::SIDE_FRONT, three::BLENDING_NONE)!!;
		uint glass = pass.create_material(gpu, target, body, {}, three::SIDE_FRONT, three::BLENDING_NORMAL)!!;

		test::@check(pass.pipelines.compiles - compiles == 1,
			"one compile for both, got %d", (int)(pass.pipelines.compiles - compiles));
		test::@check(pass.pipelines.builds - builds == 2,
			"and two VkPipelines over it, got %d", (int)(pass.pipelines.builds - builds));

		three::Material* solid = pass.material(opaque);
		three::Material* blended = pass.material(glass);
		test::@check(solid != null && blended != null, "both materials exist");
		if (solid != null && blended != null)
		{
			test::@check(solid.pipeline != blended.pipeline, "and they draw with different pipelines");
			test::@check(solid.blend == three::BlendMode.NONE, "the first is opaque, got %s", solid.blend);
			test::@check(blended.blend == three::BlendMode.ALPHA, "the second blends, got %s", blended.blend);
		}
	};
}

<*
 A transparent `MeshLambertMaterial` builds nothing, because `MeshPass.init`
 already did.

 `create_texture_material`'s doc block promises "no device, no compile and no new
 pipeline", and a blend mode is pipeline state on this device — so the promise
 and the feature are in direct conflict unless every variant exists before the
 script asks. That is what `init` acquiring four pipelines over one mesh module
 buys: four `VkPipeline` objects, one compile, about a millisecond each, at
 startup where nothing is waiting on a frame.

 The alternative is worth naming because it is what a reasonable person writes
 first: acquire on demand. It cannot be written here at all — this function takes
 no `Gpu` and no `Target` — and if it were given them, the cost would land inside
 whichever frame first said `transparent: true`, which is the one moment nobody
 is looking at a profiler.

 **Proved by injection.** The two prebuild acquires deleted from `MeshPass.init`
 with both fields pointed at `self.pipeline` — the nearest thing to "acquire it
 later" that can be written without a device at all: "the pass built four
 pipelines from one shader, got 2".
*>
fn void the_pass_prebuilds_the_blended_lambert_variants() @test
{
	// `compiles` means the compiler, not the disk cache — see `the_pipeline_cache_skips_the_compile`.
	three::shader_cache_set_dir("");

	@with_gpu(; three::Gpu* gpu, three::Target* target)
	{
		three::MeshPass pass;
		pass.init(gpu, target)!!;
		defer pass.free(gpu);

		// Four states over one source — solid, lines, alpha, additive — and the
		// sky, which is a fifth pipeline over a second source and so a second
		// compile. It is built here for the same reason the four are: a scene
		// that assigns a background should not pay a compile inside that frame.
		test::@check(pass.pipelines.builds == 5,
			"the pass built four pipelines from one shader and one from the sky, got %d",
			(int)pass.pipelines.builds);
		test::@check(pass.pipelines.compiles == 2,
			"with one compile for the mesh and one for the sky, got %d", (int)pass.pipelines.compiles);

		uint builds = pass.pipelines.builds;
		uint compiles = pass.pipelines.compiles;

		uint glass = pass.create_texture_material(three::NO_TEXTURE, three::SIDE_FRONT, three::BLENDING_NORMAL)!!;
		uint fire = pass.create_texture_material(three::NO_TEXTURE, three::SIDE_FRONT, three::BLENDING_ADDITIVE)!!;

		test::@check(pass.pipelines.builds == builds,
			"two blended materials built nothing, got %d", (int)(pass.pipelines.builds - builds));
		test::@check(pass.pipelines.compiles == compiles, "and compiled nothing");

		three::Material* blended = pass.material(glass);
		three::Material* additive = pass.material(fire);
		test::@check(blended != null && additive != null, "both materials exist");
		if (blended != null && additive != null)
		{
			// Identity, not merely "a pipeline": a variant acquired a second time
			// would be the same `VkPipeline` from the cache and would say nothing
			// about whether `init` had built it.
			test::@check(blended.pipeline == pass.alpha_pipeline, "and a transparent one takes the alpha pipeline");
			test::@check(additive.pipeline == pass.additive_pipeline, "an additive one takes the additive pipeline");
			test::@check(blended.pipeline != pass.pipeline, "and a transparent one is not the opaque pipeline");
			test::@check(blended.blend == three::BlendMode.ALPHA, "the mode reaches the material, got %s", blended.blend);
			test::@check(additive.blend == three::BlendMode.ADDITIVE, "for both of them, got %s", additive.blend);
		}
	};
}


// ============================================================================
// The disk cache
// ============================================================================

<*
 Where the tests below keep their caches.

 Under `build/` because it is gitignored and cwd-relative, which is the same
 reasoning `SHADER_CACHE_DEFAULT_DIR` and `find_shader` use — `c3c test` starts
 at the project root. **Not** the default directory: these tests count stores and
 loads, and a real cache warmed by the rest of the suite would answer their first
 compile and leave every counter one short.

 One subdirectory per test rather than one shared: the suite runs in a single
 process and nothing coordinates the order, so a shared directory would make each
 test's counters depend on which of its neighbours ran first.
*>
const String CACHE_SECOND_DIR = "build/shader-cache-test/second-compile";
const String CACHE_FAILURE_DIR = "build/shader-cache-test/failed-compile";
const String CACHE_WARNING_DIR = "build/shader-cache-test/warning";
const String CACHE_PIPELINE_DIR = "build/shader-cache-test/pipeline";
const String CACHE_CORRUPT_DIR = "build/shader-cache-test/corrupt";
const String CACHE_IDENTITY_DIR = "build/shader-cache-test/identity";
const String CACHE_KEY_DIR = "build/shader-cache-test/key";
const String CACHE_SPEC_DIR = "build/shader-cache-test/spec";
const String CACHE_SOURCE_EDIT_DIR = "build/shader-cache-test/source-edit";
const String CACHE_SHADY_DIR = "build/shader-cache-test/shady";
const String CACHE_SHADY_FAILURE_DIR = "build/shader-cache-test/shady-failure";
const String CACHE_FLIP_DIR = "build/shader-cache-test/flip";
const String CACHE_COMPILER_DIR = "build/shader-cache-test/compiler";
// The one directory in this list that must never exist. See
// `a_disabled_cache_neither_reads_nor_writes`.
const String CACHE_DISABLED_DIR = "build/shader-cache-test/disabled";

<*
 Point the disk cache at an empty directory of this test's own, and zero the
 counters.

 **Emptied, not merely created.** A `.shadymod` left by the previous run would
 answer this run's first compile, and `stores == 1` would fail for a reason that
 has nothing to do with the code under test.

 Called on the first line of every test below rather than restored on the last,
 for the reason spelled out at `the_pipeline_cache_skips_the_compile`: a failed
 `test::@check` longjmps out and skips defers, so a restore is precisely the line
 that does not run on the run that needed it. Every test in this suite that reads
 either cache says which one it means on its first line.
*>
fn void fresh_cache(String dir)
{
	@pool()
	{
		if (file::is_dir(dir))
		{
			PathList entries = path::ls(tmem, (Path)dir)!!;
			foreach (entry : entries) (void)file::delete(string::tformat("%s/%s", dir, (String)entry));
		}
	};
	three::shader_cache_set_dir(dir);
	three::shader_cache_reset_stats();
}

<*
 How many modules the cache directory holds.

 Filtered by extension rather than counted raw: a directory listing on macOS can
 contain a `.DS_Store` that nobody asked for, and "the cache stored nothing"
 must not depend on the Finder.
*>
fn usz cached_modules(String dir)
{
	if (!file::is_dir(dir)) return 0;
	@pool()
	{
		usz found = 0;
		PathList entries = path::ls(tmem, (Path)dir)!!;
		foreach (entry : entries) if (((String)entry).ends_with(".shadymod")) found++;
		return found;
	};
}

<*
 The one stored module's path, or the empty string.

 @return `Allocated from tmem — valid until the caller's pool is released.`
*>
fn String cached_module_path(String dir)
{
	if (!file::is_dir(dir)) return "";
	PathList entries = path::ls(tmem, (Path)dir)!!;
	foreach (entry : entries)
	{
		if (((String)entry).ends_with(".shadymod")) return string::tformat("%s/%s", dir, (String)entry);
	}
	return "";
}

<*
 Where the SPIR-V starts inside a stored module.

 Found by searching for the magic number rather than by parsing the header,
 because a test that re-implemented the format would pass against a loader that
 had drifted from it. The four bytes cannot occur earlier: everything before them
 is ASCII (the flags, the entry names, the source) or a length no file this size
 could have.

 @return `The offset, or zero — which is the file's own magic number and so never a real answer.`
*>
fn usz spirv_offset(char[] bytes)
{
	for (usz i = 0; i + 4 <= bytes.len; i++)
	{
		if (bytes[i] == 0x03 && bytes[i + 1] == 0x02 && bytes[i + 2] == 0x23 && bytes[i + 3] == 0x07) return i;
	}
	return 0;
}

<*
 The cache's door for a test-owned source.

 The parameter list is the old front door's, so the tests below read as they did:
 the entry list is ignored because a def's source carries its own entry points,
 and everything else goes through `compile_shady_cached` exactly as a pass would.
*>
fn three::ShaderModule? compile_cached(
	String source,
	String name,
	three::ShaderEntry[] entries,
	bool* compiled = null,
	three::ShaderSpec[] specs = { })
{
	three::ShaderDef def = { .name = name, .sources = { { .name = name, .source = source } } };
	return three::compile_shady_cached(def, three::MeshPush, compiled, specs);
}

// A shader for the cache tests and nothing else. Its own source, because the
// key is the source: sharing a def with the rest of the suite would mean these
// tests wrote to the same filename whenever a directory leaked between them.
const String CACHE_SOURCE = `
struct VertexIn
{
	uint vid @builtin(vertex_index);
}

struct VertexOutput
{
	float4 sv_position @position;
	float2 uv;
}

Sampler2D base_color_map @set(0) @binding(0);

fn VertexOutput vertexMain(VertexIn input) @vertex
{
	VertexOutput result;
	result.sv_position = float4(float(input.vid), 0.0, 0.0, 1.0);
	result.uv = float2(0.0, 0.0);
	return result;
}

fn float4 fragmentMain(VertexOutput input) @fragment
{
	return base_color_map.Sample(input.uv);
}
`;

<*
 The second compile of a source is answered from disk, and it is the same module.

 This is phase B's whole claim. Everything else in this section exists to stop it
 being true by accident.

 ## Why the third compile flips a byte

 Every equality check below would also pass against a loader that opened the
 file, threw it away and compiled again. The compiler is deterministic —
 `the_same_source_compiles_to_the_same_bytes` pins that — so "the same module
 came back" says nothing at all about where it came from, and `loads == 1` and
 `!ran` are both the implementation reporting on itself.

 So the stored file is edited between the second compile and the third: one byte
 inside the SPIR-V is inverted, and the module that comes back has to contain it.
 That is evidence rather than testimony — only bytes that were read can carry it.
 The flipped byte is word two of the SPIR-V header, past the magic number the
 loader re-checks, so the file stays well-formed and this is not a disguised test
 of the rejection path.

 **Proved by injection.** `compile_shady_cached` freeing what `cache_load` gave it
 and compiling anyway — one line, and the shape of every "load it, then compile
 to be safe" bug. It passes `!ran`, `loads == 1`, `stores == 0` and every
 field-for-field comparison in this test, and dies on the byte:
 "the third compile returned the byte that is on disk, got 0x00 rather than 0xff".
*>
fn void the_disk_cache_answers_the_second_compile_without_compiling() @test
{
	fresh_cache(CACHE_SECOND_DIR);

	bool ran = false;
	three::ShaderModule first = compile_cached(CACHE_SOURCE, "cache.shady", both_stages(), &ran)!!;
	defer first.free();

	three::ShaderCacheStats after_first = three::shader_cache_stats();
	test::@check(first.ok, "it compiles: %s", first.diagnostic);
	test::@check(ran, "the first compile ran");
	test::@check(after_first.misses == 1, "with nothing to read: %d", after_first.misses);
	test::@check(after_first.stores == 1, "and stored one module: %d", after_first.stores);
	test::@check(cached_modules(CACHE_SECOND_DIR) == 1,
		"which is one file in the directory: %d", (int)cached_modules(CACHE_SECOND_DIR));

	three::shader_cache_reset_stats();

	three::ShaderModule second = compile_cached(CACHE_SOURCE, "cache.shady", both_stages(), &ran)!!;
	defer second.free();

	three::ShaderCacheStats after_second = three::shader_cache_stats();
	test::@check(!ran, "the second compile did not run the compiler");
	test::@check(after_second.loads == 1, "it came off disk: %d", after_second.loads);
	test::@check(after_second.stores == 0, "and wrote nothing: %d", after_second.stores);
	test::@check(after_second.invalid == 0, "and refused nothing: %d", after_second.invalid);

	// Field for field, because a loader that dropped any one of these would
	// still produce a module that builds a pipeline — with the wrong descriptor
	// type, the wrong push offset, or no warning to print.
	test::@check(second.ok, "the loaded module is ok");
	test::@check(second.spirv.len == first.spirv.len,
		"the same number of bytes: %d and %d", second.spirv.len, first.spirv.len);
	test::@check(second.spirv == first.spirv, "and the same bytes");
	test::@check(second.diagnostic == first.diagnostic, "the same diagnostic: '%s'", second.diagnostic);

	test::@check(second.entries.len() == first.entries.len(),
		"the same entry points: %d and %d", second.entries.len(), first.entries.len());
	bool entries_match = second.entries.len() == first.entries.len();
	for (sz i = 0; i < second.entries.len() && i < first.entries.len(); i++)
	{
		if (second.entries[i].name != first.entries[i].name) entries_match = false;
		if (second.entries[i].stage != first.entries[i].stage) entries_match = false;
	}
	test::@check(entries_match, "named and staged as they were");

	test::@check(second.layout.push_size == first.layout.push_size,
		"the same push block: %d and %d", second.layout.push_size, first.layout.push_size);
	test::@check(second.layout.stages == first.layout.stages, "over the same stages");
	test::@check(second.layout.set_count == first.layout.set_count,
		"in the same number of sets: %d and %d", second.layout.set_count, first.layout.set_count);

	test::@check(second.layout.bindings.len() == first.layout.bindings.len(),
		"the same bindings: %d and %d", second.layout.bindings.len(), first.layout.bindings.len());
	bool bindings_match = second.layout.bindings.len() == first.layout.bindings.len();
	for (sz i = 0; i < second.layout.bindings.len() && i < first.layout.bindings.len(); i++)
	{
		three::ShaderBinding a = second.layout.bindings[i];
		three::ShaderBinding b = first.layout.bindings[i];
		if (a.name != b.name || a.set != b.set || a.binding != b.binding) bindings_match = false;
		if (a.count != b.count || a.type != b.type || a.stages != b.stages) bindings_match = false;
	}
	test::@check(bindings_match, "with their names, indices, counts and descriptor types");

	test::@check(second.layout.push_fields.len() == first.layout.push_fields.len(),
		"the same push fields: %d and %d", second.layout.push_fields.len(), first.layout.push_fields.len());
	bool fields_match = second.layout.push_fields.len() == first.layout.push_fields.len();
	for (sz i = 0; i < second.layout.push_fields.len() && i < first.layout.push_fields.len(); i++)
	{
		three::ShaderField a = second.layout.push_fields[i];
		three::ShaderField b = first.layout.push_fields[i];
		if (a.name != b.name || a.offset != b.offset || a.size != b.size) fields_match = false;
	}
	test::@check(fields_match, "at their names, offsets and sizes");

	// --- and now prove it really was read, rather than recompiled ---

	char original = 0;
	usz at = 0;
	@pool()
	{
		String path = cached_module_path(CACHE_SECOND_DIR);
		test::@check(path.len > 0, "the stored module is findable");
		char[] bytes = file::load(tmem, path)!!;
		at = spirv_offset(bytes);
		test::@check(at > 0, "and its SPIR-V is findable inside it");
		// Word two of the SPIR-V header — the generator magic. Past the module's
		// own magic number, which the loader re-checks, so the file stays valid.
		original = bytes[at + 8];
		bytes[at + 8] = original ^ 0xff;
		file::save(path, bytes)!!;
	};

	three::shader_cache_reset_stats();

	three::ShaderModule third = compile_cached(CACHE_SOURCE, "cache.shady", both_stages(), &ran)!!;
	defer third.free();

	test::@check(!ran, "the third compile did not run the compiler either");
	test::@check(three::shader_cache_stats().loads == 1, "and was a load");
	test::@check(third.spirv.len > 8, "the module is long enough to hold the edit");
	test::@check(third.spirv[8] == (char)(original ^ 0xff),
		"the third compile returned the byte that is on disk, got 0x%02x rather than 0x%02x",
		(int)third.spirv[8], (int)(char)(original ^ 0xff));
}

// A body that does not compile: an identifier that is declared nowhere.
const String CACHE_BROKEN_SOURCE = `
fn float4 fragmentMain() @fragment
{
	return notAFunction(1.0);
}
`;

<*
 A compile that failed is not written down.

 `PipelineCache.module_for` frees a failed module rather than keeping it, because
 "a cached failure would be handed to the next caller as though it were a shader,
 and the next caller is usually the agent having just fixed the typo". On disk
 that argument is stronger, not weaker: an in-memory cached failure lasts until
 the process exits, and a stored one lasts until somebody deletes a directory
 they do not know about.

 The diagnostic still reaches the caller — the failure path is not quieter for
 running through the cache — which is the second half and the one a store-first
 implementation would break by returning early.

 **Proved by injection.** The `if (mod.ok)` guard removed from
 `compile_shady_cached`, so every compile is stored: "nothing was written: 1".
*>
fn void only_a_successful_compile_is_stored() @test
{
	fresh_cache(CACHE_FAILURE_DIR);

	bool ran = false;
	three::ShaderModule broken = compile_cached(
		CACHE_BROKEN_SOURCE, "broken", both_stages(), &ran
	)!!;
	defer broken.free();

	test::@check(ran, "the compiler ran");
	test::@check(!broken.ok, "and refused the shader");
	test::@check(broken.diagnostic.len > 0, "with something to say about it");
	test::@check(broken.diagnostic.contains("broken:"), "which names the source and a line: %s", broken.diagnostic);

	three::ShaderCacheStats stats = three::shader_cache_stats();
	test::@check(stats.stores == 0, "nothing was written: %d", stats.stores);
	test::@check(cached_modules(CACHE_FAILURE_DIR) == 0,
		"and the directory is empty: %d", (int)cached_modules(CACHE_FAILURE_DIR));

	// The second attempt is a miss again, not a stored refusal handed back.
	three::ShaderModule again = compile_cached(
		CACHE_BROKEN_SOURCE, "broken", both_stages(), &ran
	)!!;
	defer again.free();
	test::@check(ran, "the retry reached the compiler too");
	test::@check(three::shader_cache_stats().loads == 0, "and read nothing");
}


<*
 A fresh `PipelineCache` over a seeded directory builds its pipeline without
 calling the compiler.

 `module_for` is where every pipeline in this renderer gets its SPIR-V, and a
 disk cache that nothing calls is 17 ms per process that nobody saves.

 Both counters are read because they fail in opposite directions.
 `compiles == 0` alone would be true of a cache that never got a module at all;
 `disk_hits == 1` alone would be true of a cache that loaded one *and* compiled
 it anyway. And the pipeline is built at the end because a loaded `ShaderLayout`
 has to survive `check_push_block` - the safety net under the loader, which
 re-validates every layout against the device that is actually present.
*>
fn void the_pipeline_cache_reads_the_disk_before_the_compiler() @test
{
	fresh_cache(CACHE_PIPELINE_DIR);

	@with_gpu(; three::Gpu* gpu, three::Target* target)
	{
		// What an agent's `ShaderMaterial` produces, rather than a hand-written
		// probe: the same def and the same body the acquire below asks for.
		String body = `fn float3 shade(Surface s) { return s.albedo * 0.5; }`;

		// Seeding rather than a first `acquire`: this test is about what a
		// *fresh* cache does with a directory somebody else filled, which is
		// what the second run of the binary is.
		bool wrote = false;
		three::ShaderModule seed = three::compile_shader(
			three::ShaderPass.MESH_MATERIAL, &wrote, body: body)!!;
		seed.free();
		test::@check(wrote && three::shader_cache_stats().stores == 1, "the directory was seeded");

		three::PipelineCache cache;
		cache.init();
		defer cache.free(gpu);

		three::MeshPipeline* pipeline = cache.acquire(
			gpu, target, three::SOLID_STATE, three::ShaderPass.MESH_MATERIAL, body: body
		)!!;

		test::@check(cache.compiles == 0 && cache.disk_hits == 1,
			"it read the module off disk rather than compiling it: %d compiles, %d disk hits",
			cache.compiles, cache.disk_hits);
		test::@check(cache.hits == 0, "and the in-memory cache had nothing to offer: %d", cache.hits);
		test::@check(cache.builds == 1, "one VkPipeline was built: %d", cache.builds);
		test::@check(pipeline.handle != null, "and it exists");
		test::@check(pipeline.shader.push_size == 32,
			"with the shader's push size of 32, got %d", pipeline.shader.push_size);
		test::@check(pipeline.shader.binding_of("environment_map") != null,
			"and the binding the shader named");
	};
}


<*
 The smallest shader the compiler will take: one vertex entry, no descriptors, no
 push block.

 Its size is the whole point. The three tests below edit a stored module and ask
 for it again, once per edit, and every edit that is refused costs a compile —
 so the compile has to be cheap. This one is about three milliseconds against
 the mesh def's seventeen, and it stores as a file of under a kilobyte, which is
 what makes a sweep over *every* truncation point affordable.

 No descriptors and no push fields is not laziness either: it puts the layout
 counts at the end of the file as zeros, where a single flipped byte turns one
 of them into four billion. That is the corruption the reader's `room_for`
 guards exist for, and a shader with two bindings would bury it.
*>
const String CACHE_TINY_SOURCE = `
struct TOut
{
	float4 sv_position @position;
}

fn TOut vertexMain() @vertex
{
	TOut result;
	result.sv_position = float4(0.0, 0.0, 0.0, 1.0);
	return result;
}
`;

// A global for `BOTH_STAGES`' reason: a slice literal is backed by the stack
// frame that made it.
const three::ShaderEntry[1] TINY_ENTRY = { { "vertexMain", three::STAGE_VERTEX } };

macro three::ShaderEntry[] tiny_entry() => TINY_ENTRY[..];

<*
 Where `needle` starts inside `bytes`, or `bytes.len` when it is not there.

 The tests below edit one field of a stored module in place, and they find the
 field by searching for bytes they know are in it rather than by walking the
 header — `spirv_offset`'s argument, which is that a test re-implementing the
 format would agree with a loader that had drifted away from it.
*>
fn usz byte_offset(char[] bytes, String needle)
{
	if (needle.len == 0 || needle.len > bytes.len) return bytes.len;
	for (usz i = 0; i + needle.len <= bytes.len; i++)
	{
		if (((String)bytes[i:needle.len]) == needle) return i;
	}
	return bytes.len;
}

<*
 Put `bytes` on disk in place of the stored module, ask for the module again,
 and check what came back.

 Every call is one lookup with a damaged file under it, and the claim is always
 the same three things: it answered, it answered with a module, and it did so by
 exactly one route. Where the file was refused there is a fourth and stronger
 one — the module is byte-for-byte what a clean compile produces, so the
 rejection really did end in a recompile rather than in a shrug.

 @param what : `Names the family of edit for the failure message. With the offset after it, "truncated at 240" is the whole diagnosis when one point of a sweep fails.`
 @param reference : `The SPIR-V a clean compile of the tiny source produces.`
*>
fn void probe_corrupt(String path, char[] bytes, char[] reference, String what, usz at)
{
	file::save(path, bytes)!!;
	three::shader_cache_reset_stats();

	three::ShaderModule? answered = compile_cached(CACHE_TINY_SOURCE, "tiny.shady", tiny_entry());
	test::@check(@ok(answered), "%s %d: it answered rather than faulting", what, (int)at);
	three::ShaderModule mod = answered!!;
	defer mod.free();

	test::@check(mod.ok, "%s %d: with a module", what, (int)at);

	three::ShaderCacheStats stats = three::shader_cache_stats();
	test::@check(stats.loads + stats.invalid + stats.misses == 1,
		"%s %d: by exactly one route, got %d loads, %d invalid, %d misses",
		what, (int)at, stats.loads, stats.invalid, stats.misses);

	if (stats.loads == 0)
	{
		test::@check(mod.spirv == reference,
			"%s %d: the refused file was recompiled to the real module, got %d bytes against %d",
			what, (int)at, mod.spirv.len, reference.len);
		test::@check(stats.stores == 1,
			"%s %d: and overwrote the bad file, got %d stores", what, (int)at, stats.stores);
	}
}

<*
 A stored module that has been damaged is recompiled — never trusted, never
 fatal.

 This is the test the format's bounds checking exists for. A cache on disk turns
 a bad millisecond into a permanent one: a torn write, a full disk, a process
 killed inside `file::save`, a `build/` directory restored from a backup that
 stopped halfway — each leaves bytes that parse far enough to be dangerous and no
 further, and each of them is there again tomorrow. The loader's answer to all of
 it has to be one recompile and an overwrite.

 ## What is swept

 Two families, each wide enough to be evidence rather than a spot check:

 - **Truncation at every eighth byte**, from an empty file to one byte short of
   the whole. Eight rather than one because every field in this format is a
   four-byte number or a four-byte length, so an eight-byte grid walks through
   both halves of the pattern; and every point is a rejection, because the format
   has no trailing slack — a cut anywhere removes something a later read wants.
 - **One flipped byte**: every seventh position across the file, and *every*
   position in the first and last thirty-two bytes. The two ends are exhaustive
   because that is where the numbers live — magic, version and the argument
   length at the front, the layout counts at the back — and a count is the single
   field a corruption can turn into an allocation rather than a bad read.

 A flip is not always a rejection and this does not pretend otherwise. A byte
 inside the SPIR-V payload, inside a binding's name, or inside `push_size` is not
 part of the identity check, so the loader accepts it and hands back a module
 carrying the damage. That is the design and not an oversight: checking the
 payload would mean a checksum, which is a different and much larger promise than
 "the arguments and the source are the ones you asked for". What holds either way
 is what `probe_corrupt` asserts — one lookup, one route, a module rather than a
 fault — plus, on every file that *was* refused, a module identical to a clean
 compile.

 ## Cost

 About three hundred iterations, each at most one compile of the tiny source,
 and the whole test runs in about six hundred milliseconds. That is affordable
 only because the shader is small; the same sweep over the mesh def would take
 the best part of a minute.

 **Proved by injection.** The bindings' guard removed from `cache_load` —
 `if (!reader.room_for(binding_count, 24)) return cache_reject();` — which is the
 one bounds check in the reader that is not about reading past the end but about
 a *count* that came out of the file. Flipping the high byte of the binding count
 turns nought into 0xff000000, and the next line asks the temp allocator for four
 billion of them. There is no assertion failure and no message, because there is
 no process left to print one: the line reads
 "Testing three_tests::shader::a_corrupt_cache_entry_recompiles_rather_than_crashes
 ... Program interrupted by signal 9." — killed asking for a hundred and seventy
 gigabytes, with no result for this test or for any test after it, and the file
 that did it still on disk for the next run to find. That is the whole argument
 for the guard: the loop underneath it is bounded and would have exited on the
 first bad read, so the crash is entirely in the allocation the count asked for.
*>
fn void a_corrupt_cache_entry_recompiles_rather_than_crashes() @test
{
	fresh_cache(CACHE_CORRUPT_DIR);

	three::ShaderModule reference = compile_cached(CACHE_TINY_SOURCE, "tiny.shady", tiny_entry())!!;
	defer reference.free();
	test::@check(three::shader_cache_stats().stores == 1, "one module was stored to damage");

	// The good file and its path, copied out of tmem's reach: every iteration
	// below starts from these and the loop outlives any one pool.
	String path;
	char[] good;
	@pool()
	{
		String found = cached_module_path(CACHE_CORRUPT_DIR);
		test::@check(found.len > 0, "and it is findable");
		char[] bytes = file::load(tmem, found)!!;
		good = alloc::new_array(mem, char, bytes.len);
		good[..] = bytes[..];
		path = found.copy(mem);
	};
	defer alloc::free(mem, good);
	defer path.free(mem);

	for (usz cut = 0; cut < good.len; cut += 8)
	{
		@pool()
		{
			probe_corrupt(path, good[:cut], reference.spirv, "truncated at", cut);
			// Every truncation is a refusal, which is the claim the doc block
			// makes and the reason this family needs no case analysis: the
			// format has no trailing slack, so a cut anywhere takes away a
			// field some later read wants. Flips are the family where that is
			// not true.
			test::@check(three::shader_cache_stats().loads == 0,
				"truncated at %d: a short file is never a hit", (int)cut);
		};
	}

	for (usz at = 0; at < good.len; at++)
	{
		// Every seventh byte, and both ends whole.
		if (at % 7 != 0 && at >= 32 && at + 32 < good.len) continue;
		@pool()
		{
			char[] flipped = alloc::new_array(tmem, char, good.len);
			flipped[..] = good[..];
			flipped[at] = good[at] ^ 0xff;
			probe_corrupt(path, flipped, reference.spirv, "flipping byte", at);
		};
	}

	test::@check(cached_modules(CACHE_CORRUPT_DIR) == 1,
		"the directory still holds one module and not a pile of them: %d",
		(int)cached_modules(CACHE_CORRUPT_DIR));
}

<*
 A file found under the right name whose stored source is not the source asked
 for is refused.

 The hash names a candidate; the file decides. This is the half of that rule
 nothing else here can reach: `the_disk_cache_answers_the_second_compile_without_compiling`
 proves a hit is really read, and `a_corrupt_cache_entry_recompiles_rather_than_crashes`
 proves a broken file is refused, but both of those work on files that are
 *about* the right shader. What a hash collision produces is a file that is
 perfectly well formed and about a different one — and the module inside it
 compiles, builds a pipeline, and draws somebody else's shader.

 Two edits are made to the stored file, both in place and both keeping every
 length exactly as it was, so what comes back is decided by the identity check
 and not by a reader running off the end:

 - one byte inside the stored **source**, which is what makes it a different
   shader;
 - one byte inside the stored **SPIR-V**, past the magic number, which is what
   makes the answer *evidence*. Without it a loader that skipped the identity
   check entirely would hand back this file's module — which is a compile of the
   same source, byte for byte — and every assertion here would pass.

 The file is then asked for again under the same name, and the module that comes
 back has to be the clean one. The last check reads the file off disk once more:
 the flipped SPIR-V byte is gone, so the recompile did not merely answer the
 caller, it replaced the file that would otherwise be refused again on every run
 forever.

 **Proved by injection.** The source half of the identity check removed from
 `cache_load` — `if (stored_source != source) return cache_reject();` — so the
 collision is answered from disk: "the module answered is a compile of the source
 that was asked for, byte 8 of its SPIR-V is 0xff rather than 0x00".
*>
fn void a_hash_hit_with_different_source_is_a_miss() @test
{
	fresh_cache(CACHE_IDENTITY_DIR);

	three::ShaderModule reference = compile_cached(CACHE_TINY_SOURCE, "tiny.shady", tiny_entry())!!;
	defer reference.free();
	test::@check(three::shader_cache_stats().stores == 1, "one module was stored");
	test::@check(reference.spirv.len > 8, "long enough to carry an edit");

	String path;
	@pool()
	{
		String found = cached_module_path(CACHE_IDENTITY_DIR);
		test::@check(found.len > 0, "and it is findable");
		path = found.copy(mem);

		char[] bytes = file::load(tmem, found)!!;

		// The stored source, found by a line of itself rather than by counting
		// header fields. One character of it changes — `0.0` becomes `1.0` —
		// which is a different shader by the only definition the cache has, and
		// the same number of bytes by construction.
		usz source_at = byte_offset(bytes, "float4(0.0, 0.0, 0.0, 1.0)");
		test::@check(source_at < bytes.len, "the stored source is in the file");
		bytes[source_at + 7] = '1';

		usz spirv_at = spirv_offset(bytes);
		test::@check(spirv_at > 0, "and so is the SPIR-V");
		bytes[spirv_at + 8] = bytes[spirv_at + 8] ^ 0xff;

		file::save(found, bytes)!!;
	};
	defer path.free(mem);

	three::shader_cache_reset_stats();

	bool ran = false;
	three::ShaderModule answered = compile_cached(
		CACHE_TINY_SOURCE, "tiny.shady", tiny_entry(), &ran
	)!!;
	defer answered.free();

	test::@check(answered.ok, "a module came back");
	test::@check(answered.spirv == reference.spirv,
		"the module answered is a compile of the source that was asked for, byte 8 of its SPIR-V is 0x%02x rather than 0x%02x",
		(int)answered.spirv[8], (int)reference.spirv[8]);

	three::ShaderCacheStats stats = three::shader_cache_stats();
	test::@check(ran, "the compiler ran");
	test::@check(stats.loads == 0, "nothing was loaded: %d", stats.loads);
	test::@check(stats.invalid == 1, "the file was refused rather than missing: %d", stats.invalid);
	test::@check(stats.stores == 1, "and one module was written: %d", stats.stores);
	test::@check(cached_modules(CACHE_IDENTITY_DIR) == 1,
		"over the same file, not beside it: %d", (int)cached_modules(CACHE_IDENTITY_DIR));

	@pool()
	{
		char[] bytes = file::load(tmem, path)!!;
		usz spirv_at = spirv_offset(bytes);
		test::@check(spirv_at > 0, "the rewritten file holds SPIR-V");
		test::@check(bytes[spirv_at + 8] == reference.spirv[8],
			"and it is the clean module, so the bad file is gone rather than refused forever: 0x%02x",
			(int)bytes[spirv_at + 8]);
	};
}

<*
 A stored module from another format version, built by another compiler, or
 built with other arguments, is not this process's module.

 All three are in the key — `cache_key` hashes the format version, the compiler
 name and the joined argument list before it hashes the source — and none can be
 observed through the key, because the key is a private function whose only
 visible effect is a filename nothing else knows how to predict. So what is
 tested here is the half that *is* observable and is the half that matters: what
 the loader does when a file arrives under the right name carrying the wrong
 ones.

 That is not a weaker test than one that compared two hashes. The key and the
 file are written from the same three values by the same function pair — the
 arguments `cache_store` writes as a blob are the arguments `cache_key` hashed,
 the compiler name likewise, and the version is a constant used by both — so a
 key that stopped covering any of them would still be caught here as an identity
 failure. The failure mode this rules out is the real one: a stale file being
 *believed*.

 ## Moving the compiler means clearing the cache

 The key names no compiler revision: the compiler is a submodule and its own
 sources move with a checkout, so two builds under the same name are
 indistinguishable here on purpose. **Clear `build/shader-cache` after moving the
 submodule** — the directory is the whole of "clear the cache". Skip it and the
 next run serves a module the old compiler built: "the shader still behaves the
 way it did before the move", true on a machine whose cache is warm and not
 reproducible on one whose cache is empty.

 The name check catches a file a *different* compiler wrote — this test patches a
 file to prove it — but it cannot tell two builds of the same name apart.
 `SHADER_CACHE_FORMAT_VERSION` is the lever when the format changes, and it only
 works if the loader actually checks the field — which is exactly what a version
 written into a file and never read again would silently stop doing.

 All three halves patch the file in place, keeping every length, and all three
 flip a SPIR-V byte alongside so that a module which came off disk can be told
 from one that was recompiled — `a_hash_hit_with_different_source_is_a_miss`
 explains why counters alone would not do it.

 **Proved by injection**, three times. The version check removed from
 `cache_load` — `if (reader.u32() != SHADER_CACHE_FORMAT_VERSION) return
 cache_reject();` cut to a bare `reader.u32();` — and the file from the future is
 believed: "a module built under this format version came back, byte 8 of its
 SPIR-V is 0xff rather than 0x00". The compiler check removed —
 `if (stored_compiler != compiler) return cache_reject();` — and the file from
 another compiler is believed the same way: "a module built by this compiler came
 back, byte 8 of its SPIR-V is 0xff rather than 0x00". And the argument check
 removed — `if (stored_args != args) return cache_reject();` — for the third:
 "a module built with these arguments came back, byte 8 of its SPIR-V is 0xff
 rather than 0x00".
*>
fn void the_cache_key_covers_the_compiler_the_arguments_and_the_format_version() @test
{
	fresh_cache(CACHE_KEY_DIR);

	three::ShaderModule reference = compile_cached(CACHE_TINY_SOURCE, "tiny.shady", tiny_entry())!!;
	defer reference.free();
	test::@check(three::shader_cache_stats().stores == 1, "one module was stored");

	String path;
	@pool()
	{
		String found = cached_module_path(CACHE_KEY_DIR);
		test::@check(found.len > 0, "and it is findable");
		path = found.copy(mem);
	};
	defer path.free(mem);

	// --- the format version ---

	@pool()
	{
		char[] bytes = file::load(tmem, path)!!;
		// The only two fields this file reads by position rather than by
		// content, and the only two whose position is fixed by definition: the
		// header is the magic and then the version, in that order, before
		// anything with a length. The magic is checked rather than assumed, so
		// a format that grew a field in front of the version fails here instead
		// of quietly patching a byte of something else.
		test::@check(bytes.len > 8, "the file has a header");
		test::@check(bytes[0] == 'T' && bytes[1] == '3' && bytes[2] == 'S' && bytes[3] == 'C',
			"which starts with the magic number");
		uint next = three::SHADER_CACHE_FORMAT_VERSION + 1;
		bytes[4] = (char)next;
		bytes[5] = (char)(next >> 8);
		bytes[6] = (char)(next >> 16);
		bytes[7] = (char)(next >> 24);

		usz spirv_at = spirv_offset(bytes);
		test::@check(spirv_at > 0, "and holds SPIR-V");
		bytes[spirv_at + 8] = bytes[spirv_at + 8] ^ 0xff;

		file::save(path, bytes)!!;
	};

	three::shader_cache_reset_stats();

	bool ran = false;
	three::ShaderModule after_version = compile_cached(
		CACHE_TINY_SOURCE, "tiny.shady", tiny_entry(), &ran
	)!!;
	defer after_version.free();

	test::@check(after_version.ok, "a module came back");
	test::@check(after_version.spirv == reference.spirv,
		"a module built under this format version came back, byte 8 of its SPIR-V is 0x%02x rather than 0x%02x",
		(int)after_version.spirv[8], (int)reference.spirv[8]);
	test::@check(ran, "the compiler ran");
	test::@check(three::shader_cache_stats().invalid == 1,
		"the file from another version was refused: %d", three::shader_cache_stats().invalid);
	test::@check(three::shader_cache_stats().loads == 0,
		"and not read: %d", three::shader_cache_stats().loads);

	// --- the compiler ---

	@pool()
	{
		char[] bytes = file::load(tmem, path)!!;
		// Found by its own text rather than at a fixed offset, where the format
		// puts it: a field located by position would keep patching *something*
		// if the header grew, and what it patched would no longer be the
		// compiler's name. The name this process writes is the name the file was
		// written with one compile ago, so a search for it is exact.
		String compiler = "shady";
		usz tag_at = byte_offset(bytes, compiler);
		test::@check(tag_at < bytes.len, "and the compiler's name is in the file");
		// Same length, different bytes — a shorter name would move every offset
		// after it and the loader would then be refusing a truncated file rather
		// than a foreign compiler.
		bytes[tag_at] = 'o';
		bytes[tag_at + 1] = 't';
		bytes[tag_at + 2] = 'h';
		bytes[tag_at + 3] = 'e';
		bytes[tag_at + 4] = 'r';

		usz spirv_at = spirv_offset(bytes);
		test::@check(spirv_at > 0, "and so is the SPIR-V");
		bytes[spirv_at + 8] = bytes[spirv_at + 8] ^ 0xff;

		file::save(path, bytes)!!;
	};

	three::shader_cache_reset_stats();

	three::ShaderModule after_compiler = compile_cached(
		CACHE_TINY_SOURCE, "tiny.shady", tiny_entry(), &ran
	)!!;
	defer after_compiler.free();

	test::@check(after_compiler.ok, "a module came back");
	test::@check(after_compiler.spirv == reference.spirv,
		"a module built by this compiler came back, byte 8 of its SPIR-V is 0x%02x rather than 0x%02x",
		(int)after_compiler.spirv[8], (int)reference.spirv[8]);
	test::@check(ran, "the compiler ran");
	test::@check(three::shader_cache_stats().invalid == 1,
		"the file from another SDK was refused: %d", three::shader_cache_stats().invalid);
	test::@check(three::shader_cache_stats().loads == 0,
		"and not read: %d", three::shader_cache_stats().loads);

	// --- the arguments ---

	@pool()
	{
		char[] bytes = file::load(tmem, path)!!;
		// The flag the adapter passes, found by its own text. A cache that
		// ignored the argument list would hand back a module built with a
		// different layout.
		usz args_at = byte_offset(bytes, "scalar-layout");
		test::@check(args_at < bytes.len, "the stored arguments are in the file");
		bytes[args_at] = 'S';

		usz spirv_at = spirv_offset(bytes);
		test::@check(spirv_at > 0, "and so is the SPIR-V");
		bytes[spirv_at + 8] = bytes[spirv_at + 8] ^ 0xff;

		file::save(path, bytes)!!;
	};

	three::shader_cache_reset_stats();

	three::ShaderModule after_args = compile_cached(
		CACHE_TINY_SOURCE, "tiny.shady", tiny_entry(), &ran
	)!!;
	defer after_args.free();

	test::@check(after_args.ok, "a module came back");
	test::@check(after_args.spirv == reference.spirv,
		"a module built with these arguments came back, byte 8 of its SPIR-V is 0x%02x rather than 0x%02x",
		(int)after_args.spirv[8], (int)reference.spirv[8]);
	test::@check(ran, "the compiler ran");
	test::@check(three::shader_cache_stats().invalid == 1,
		"the file built with other flags was refused: %d", three::shader_cache_stats().invalid);
	test::@check(cached_modules(CACHE_KEY_DIR) == 1,
		"and both refusals overwrote rather than accumulated: %d", (int)cached_modules(CACHE_KEY_DIR));
}

// The tiny source with one expression changed, so the two are the same shader
// in every way a reader cares about and a different string to the key.
const String CACHE_TINY_SOURCE_EDIT = `
struct TOut
{
	float4 sv_position @position;
}

fn TOut vertexMain() @vertex
{
	TOut result;
	result.sv_position = float4(1.0, 0.0, 0.0, 1.0);
	return result;
}
`;

// Two value sets that differ only under id 1, and the first listed the other
// way round. A global for `BOTH_STAGES`' reason: a slice literal is backed by
// the stack frame that made it.
const three::ShaderSpec[2] SPEC_TAPS_4 = {
	{ 1, three::ShaderSpecKind.UINT, 4 },
	{ 2, three::ShaderSpecKind.BOOL, 1 },
};
const three::ShaderSpec[2] SPEC_TAPS_8 = {
	{ 1, three::ShaderSpecKind.UINT, 8 },
	{ 2, three::ShaderSpecKind.BOOL, 1 },
};
const three::ShaderSpec[2] SPEC_TAPS_4_REVERSED = {
	{ 2, three::ShaderSpecKind.BOOL, 1 },
	{ 1, three::ShaderSpecKind.UINT, 4 },
};

<*
 One module, several value sets: the values are identity, not a comment.

 The key hashes the values by id in a canonical order, so the same set listed
 two ways is one entry and one changed value is another. The files here are the
 compiler's output and the source does not read a `@spec` constant — what is
 pinned is the key, which has to separate the values before a pass can rely on
 the separation.
*>
fn void a_changed_spec_value_is_a_different_module() @test
{
	fresh_cache(CACHE_SPEC_DIR);

	bool ran = false;
	three::ShaderModule four = compile_cached(
		CACHE_TINY_SOURCE, "tiny.shady", tiny_entry(), &ran, SPEC_TAPS_4[..]
	)!!;
	defer four.free();
	test::@check(ran, "the first value set compiled");
	three::ShaderCacheStats after_first = three::shader_cache_stats();
	test::@check(after_first.misses == 1 && after_first.stores == 1,
		"with one miss and one store: %d/%d", after_first.misses, after_first.stores);

	three::shader_cache_reset_stats();
	three::ShaderModule reversed = compile_cached(
		CACHE_TINY_SOURCE, "tiny.shady", tiny_entry(), &ran, SPEC_TAPS_4_REVERSED[..]
	)!!;
	defer reversed.free();
	test::@check(!ran, "the same values listed the other way came off disk");
	test::@check(three::shader_cache_stats().loads == 1, "which is a load");
	test::@check(reversed.spirv == four.spirv, "and it is the same module");

	three::shader_cache_reset_stats();
	three::ShaderModule eight = compile_cached(
		CACHE_TINY_SOURCE, "tiny.shady", tiny_entry(), &ran, SPEC_TAPS_8[..]
	)!!;
	defer eight.free();
	test::@check(ran, "one changed value is not the stored entry");
	three::ShaderCacheStats changed = three::shader_cache_stats();
	test::@check(changed.loads == 0 && changed.misses == 1 && changed.stores == 1,
		"it is a miss and its own file: %d loads, %d misses, %d stores",
		changed.loads, changed.misses, changed.stores);
	test::@check(cached_modules(CACHE_SPEC_DIR) == 2,
		"two value sets, two files: %d", (int)cached_modules(CACHE_SPEC_DIR));

	three::shader_cache_reset_stats();
	three::ShaderModule again = compile_cached(
		CACHE_TINY_SOURCE, "tiny.shady", tiny_entry(), &ran, SPEC_TAPS_4[..]
	)!!;
	defer again.free();
	test::@check(!ran && three::shader_cache_stats().loads == 1,
		"and the first set is still its own entry");
}

<*
 A changed source is a different module.

 The hash names a candidate and the file checks the identity, but a lookup only
 reaches that check when the hash moves: this asks for two sources under one
 name and expects the second to be a miss with a file of its own. The source is
 the same shader with one expression changed, so nothing about the name, the
 entry list or the compiler explains the difference.
*>
fn void a_changed_source_is_a_different_module() @test
{
	fresh_cache(CACHE_SOURCE_EDIT_DIR);

	bool ran = false;
	three::ShaderModule first = compile_cached(
		CACHE_TINY_SOURCE, "tiny.shady", tiny_entry(), &ran
	)!!;
	defer first.free();
	test::@check(ran && three::shader_cache_stats().stores == 1, "the first source was stored");

	three::shader_cache_reset_stats();
	three::ShaderModule edited = compile_cached(
		CACHE_TINY_SOURCE_EDIT, "tiny.shady", tiny_entry(), &ran
	)!!;
	defer edited.free();
	test::@check(ran, "the edited source missed");
	three::ShaderCacheStats stats = three::shader_cache_stats();
	test::@check(stats.loads == 0 && stats.misses == 1 && stats.stores == 1,
		"and was compiled into its own entry: %d loads, %d misses, %d stores",
		stats.loads, stats.misses, stats.stores);
	test::@check(cached_modules(CACHE_SOURCE_EDIT_DIR) == 2,
		"two sources, two files: %d", (int)cached_modules(CACHE_SOURCE_EDIT_DIR));

	three::shader_cache_reset_stats();
	three::ShaderModule again = compile_cached(
		CACHE_TINY_SOURCE, "tiny.shady", tiny_entry(), &ran
	)!!;
	defer again.free();
	test::@check(!ran && three::shader_cache_stats().loads == 1,
		"and the first source still comes off disk");
}

<*
 A compiled pass is cached, and under a key of its own.

 This is the wiring half: a pass compiles once and loads afterwards. The second
 half is the values and the file count — a different spec set is a second entry,
 not the entry that is already there.
*>
fn void a_pass_is_cached_under_its_own_key() @test
{
	fresh_cache(CACHE_SHADY_DIR);
	bool ran = false;
	three::ShaderModule first = three::compile_shader(three::ShaderPass.CLUSTER, &ran)!!;
	defer first.free();
	test::@check(first.ok, "the shady cluster compiles: %s", first.diagnostic);
	test::@check(ran, "the first compile ran shady");
	three::ShaderCacheStats after_first = three::shader_cache_stats();
	test::@check(after_first.misses == 1 && after_first.stores == 1,
		"with one miss and one store: %d/%d", after_first.misses, after_first.stores);
	test::@check(cached_modules(CACHE_SHADY_DIR) == 1,
		"one module is on disk: %d", (int)cached_modules(CACHE_SHADY_DIR));

	three::shader_cache_reset_stats();
	three::ShaderModule second = three::compile_shader(three::ShaderPass.CLUSTER, &ran)!!;
	defer second.free();
	test::@check(!ran, "the second compile did not run shady");
	test::@check(three::shader_cache_stats().loads == 1, "it came off disk");
	test::@check(second.spirv == first.spirv, "and is the same module");

	three::shader_cache_reset_stats();
	three::ShaderModule other = three::compile_shader(
		three::ShaderPass.CLUSTER, &ran, specs: SPEC_TAPS_8[..])!!;
	defer other.free();
	test::@check(ran, "a different value set is not the stored entry");
	test::@check(three::shader_cache_stats().stores == 1, "so it was stored under its own key");
	test::@check(cached_modules(CACHE_SHADY_DIR) == 2,
		"two value sets, two files: %d", (int)cached_modules(CACHE_SHADY_DIR));
}

<*
 A broken compile is a miss and no store.
*>
fn void a_broken_shady_compile_is_not_stored() @test
{
	fresh_cache(CACHE_SHADY_FAILURE_DIR);
	bool ran = false;
	three::ShaderModule broken = three::compile_shader(
		three::ShaderPass.POST, &ran,
		body: `fn float3 post(Post p) { return notAFunction(p.uv); }`
	)!!;
	defer broken.free();
	test::@check(ran, "shady ran");
	test::@check(!broken.ok, "and refused the body: %s", broken.diagnostic);
	test::@check(three::shader_cache_stats().stores == 0,
		"nothing was written: %d", three::shader_cache_stats().stores);
	test::@check(cached_modules(CACHE_SHADY_FAILURE_DIR) == 0,
		"and the directory is empty: %d", (int)cached_modules(CACHE_SHADY_FAILURE_DIR));

	three::shader_cache_reset_stats();
	three::ShaderModule again = three::compile_shader(
		three::ShaderPass.POST, &ran,
		body: `fn float3 post(Post p) { return notAFunction(p.uv); }`
	)!!;
	defer again.free();
	test::@check(ran, "the retry reached shady too");
	test::@check(three::shader_cache_stats().loads == 0, "and read nothing");
}


<*
 The stored compiler identity is checked.

 A file found under the right name is made to claim a compiler that did not
 write it - `shady` becomes `other`, the same length so nothing moves - and the
 loader has to refuse it rather than believe it.
*>
fn void the_stored_compiler_identity_is_checked() @test
{
	fresh_cache(CACHE_COMPILER_DIR);

	bool ran = false;
	three::ShaderModule reference = three::compile_shader(three::ShaderPass.CLUSTER, &ran)!!;
	defer reference.free();
	test::@check(ran && three::shader_cache_stats().stores == 1, "one module was stored");

	@pool()
	{
		String path = cached_module_path(CACHE_COMPILER_DIR);
		test::@check(path.len > 0, "and it is findable");
		char[] bytes = file::load(tmem, path)!!;
		usz at = byte_offset(bytes, "shady");
		test::@check(at < bytes.len, "whose stored identity names the compiler");
		bytes[at] = 'o';
		bytes[at + 1] = 't';
		bytes[at + 2] = 'h';
		bytes[at + 3] = 'e';
		bytes[at + 4] = 'r';
		file::save(path, bytes)!!;
	};

	three::shader_cache_reset_stats();
	three::ShaderModule again = three::compile_shader(three::ShaderPass.CLUSTER, &ran)!!;
	defer again.free();
	test::@check(ran, "the compile ran rather than trusting the file");
	test::@check(three::shader_cache_stats().invalid == 1 && three::shader_cache_stats().loads == 0,
		"the file claiming another compiler was refused: %d invalid, %d loads",
		three::shader_cache_stats().invalid, three::shader_cache_stats().loads);
	test::@check(again.spirv == reference.spirv, "and the clean module came back");
}

<*
 An empty cache directory is not a cache at all: nothing is read, nothing is
 written, and no directory appears.

 `shader_cache_set_dir("")` is what every test in this suite that counts
 `PipelineCache.compiles` uses to get the disk out of its way, so what it means
 is load-bearing well beyond this test — a disabled cache that still read files
 would make `the_pipeline_cache_skips_the_compile` and its four neighbours depend
 on whether somebody had run the binary that morning.

 Disabled means *before the lookup*, not "look and find nothing": all four
 counters stay at zero, including `misses`. A cache that counted a miss it never
 looked for would still be correct, and the counter would stop meaning what
 `ShaderCacheStats` says it means — "lookups with no file to read" — which is the
 number the double-run check in `plan.md` reads to decide whether the cache is
 working.

 The directory is the evidence for the writing half, and it is the reason this
 test owns a directory it never uses: `CACHE_DISABLED_DIR` is emptied and removed
 on the first line, and nothing that follows may bring it back.

 **Proved by injection.** The early return removed from `compile_shady_cached` —
 the `if (cache_dir.len == 0)` branch that answers straight from `compile_shady`
 — so a disabled cache walks the whole path with an empty directory name:
 "it did not count a lookup it never made: 2", one miss per compile, preceded on
 stderr by two of "shader cache: cannot create  (path::INVALID_PATH); compiling
 every run" — the store failing on a directory called nothing, which is the
 second half of the same bug and the reason the injection does not also show up
 as a stray file somewhere.
*>
fn void a_disabled_cache_neither_reads_nor_writes() @test
{
	// Empty it, then remove it, then turn the cache off. In that order: the
	// directory has to be gone *before* the two compiles for its absence
	// afterwards to mean anything.
	fresh_cache(CACHE_DISABLED_DIR);
	(void)path::rmdir((Path)CACHE_DISABLED_DIR);
	test::@check(!file::is_dir(CACHE_DISABLED_DIR), "the directory is gone to start with");

	three::shader_cache_set_dir("");

	bool ran = false;
	three::ShaderModule first = compile_cached(
		CACHE_TINY_SOURCE, "tiny.shady", tiny_entry(), &ran
	)!!;
	defer first.free();
	test::@check(ran, "the first compile ran the compiler");

	three::ShaderModule second = compile_cached(
		CACHE_TINY_SOURCE, "tiny.shady", tiny_entry(), &ran
	)!!;
	defer second.free();
	test::@check(ran, "and so did the second — a disabled cache remembers nothing");
	test::@check(second.spirv == first.spirv, "which is the same module twice");

	three::ShaderCacheStats stats = three::shader_cache_stats();
	test::@check(stats.misses == 0, "it did not count a lookup it never made: %d", stats.misses);
	test::@check(stats.loads == 0, "it read nothing: %d", stats.loads);
	test::@check(stats.invalid == 0, "it refused nothing: %d", stats.invalid);
	test::@check(stats.stores == 0, "and it wrote nothing: %d", stats.stores);

	test::@check(!file::is_dir(CACHE_DISABLED_DIR), "no directory was created");
	test::@check(cached_modules(CACHE_DISABLED_DIR) == 0,
		"and no module reached it: %d", (int)cached_modules(CACHE_DISABLED_DIR));
}
