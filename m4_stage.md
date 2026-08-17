# M4 — Slang at runtime

The step-by-step record of what M4 built, where it departed from `plan.md`, and
what was actually run to believe any of it. `base_stage.md` is the same document
for M0/M1, `m2_stage.md` for M2 and `m3_stage.md` for M3.

**The done condition, from `plan.md` §5: the same shader that M1 compiled offline
compiles from a string at startup, and the descriptor layout is derived rather
than declared.** Both are met, and the first one turned out to be true in a
stronger sense than the wording asked for — the runtime compile produces the
**byte-identical module**:

    $ md5 /tmp/app_compiled.spv /tmp/slangc_reference.spv
    85217c3a16c2694a0564bcd6f0d36ea2
    85217c3a16c2694a0564bcd6f0d36ea2

6908 bytes each. The left one came out of `three::compile_slang` at test time;
the right one out of `slangc -target spirv -emit-spirv-directly
-fvk-use-entrypoint-name -force-glsl-scalar-layout`, which is the command line
`mesh.slang`'s header has carried since M1. There is now no second invocation to
drift from, because the offline one is gone.

There is no `shaders` prepare target, no `slangc` anywhere in the project, and no
`.spv` on disk. Editing `shaders/mesh.slang` and re-running shows the change with
nothing rebuilt.

## The steps

### S1 — the flat C API, and no shim (`lib/slang.c3l`)

`plan.md` §3 predicted this would be "much easier than expected" because Slang
exports a flat C API alongside its COM one, and that held. Every `sp*` function
takes and returns scalars and pointers — there is nothing passed by value that
would make the C3 side guess at an ABI, so unlike `quickjs.c3l` there is no shim
and no C source at all. `lib/slang.c3l` is one `.c3` file and a manifest.

Three things §3 did not know:

- **The `sp*` family is formally deprecated.** It lives in `slang-deprecated.h`,
  whose header says it is kept for source and binary compatibility and will be
  dropped over time. All 258 symbols are exported by the SDK here and the
  seventeen this project calls were each checked present. The exposure is one
  file; if a future SDK drops them, `lib/slang.c3l` is what gets rewritten
  against the COM surface and nothing above it changes.
- **`spGetEntryPointCode` returns nothing under `-emit-spirv-directly`.** §3
  named it as the function to use and it is the wrong one: it answers with a null
  pointer and a length of zero, and reports no error. The emitted module holds
  every entry point together, so the whole program is one artifact —
  `spGetCompileRequestCode` is the flat, non-COM function that returns it.
- **Casing is inconsistent within the family.** `spReflection_GetParameterCount`
  is capitalised and `spReflection_getEntryPointCount` is not, five lines apart
  in the same header. A wrong guess is a link error, but one naming a symbol that
  looks exactly right.

### S2 — two dylibs, not one, and not five

§3 asked whether `libslang-llvm.dylib` (102 MB) could be omitted for a SPIR-V-only
build. It can. But **`libslang-glslang` cannot**, which the same paragraph did not
anticipate: Slang loads it as the downstream `spirv-opt`, and without it every
compile fails with

    error[E00100]: failed to load downstream compiler 'spirv-opt'
    note[E99996]: failed to load dynamic library 'slang-glslang-2026.12.2'

which reads like a missing binary rather than a missing library. Measured by
building against a directory holding one dylib at a time: the required set is
`libslang-compiler` (27 MB) and `libslang-glslang` (8 MB), and the output is
byte-identical to a build against the full SDK.

**Nothing machine-specific is recorded anywhere.**
`lib/slang.c3l/native/stage-slang.sh` symlinks those two out of an installed SDK
into `lib/<target>/`, finding it through `$SLANG_SDK`, then `slangc` on `PATH`,
then a short list of usual places. The symlinks are gitignored. The manifest
names only `slang` and two *relative* rpaths — one for a binary in `build/` inside
a checkout, one for the dylibs copied beside a shipped binary.

> **After M4: the library moved to its own repository,
> [`slang.c3`](https://github.com/tonis2/slang.c3), and the staging script stayed.**
>
> Bundling the two dylibs into that repository instead — the trade `quickjs.c3l`
> makes for its archives — was built, pushed, measured and reverted. What it
> bought: a clone that builds with nothing installed, verified by cloning with
> `SLANG_SDK` unset and a stripped `PATH`. What it cost: **13.9 MiB of pack per
> SDK version, permanently**, since no later commit can remove a blob from
> history. quickjs's archives are 1.3 MB and freeze a *build*; libslang is 27 MB
> and freezes an *SDK*, so the repository would gain a Slang release every time
> Slang had one. The initial commit was rewritten rather than amended over, so
> those blobs are in no clone — 22 KiB now.
>
> Measured while checking what "forgot to run the script" actually does, and
> worth keeping: **it does not reliably fail at the linker.** This machine has a
> Slang 2026.8 in `/usr/local/lib` from an installer package, so `-lslang` found
> that, linked, and died at startup with
>
>     Library not loaded: @rpath/libslang-compiler.0.2026.8.dylib
>
> naming a version nothing here asked for. The staged build is unaffected —
> `lib/<target>/` precedes the default search path, and `otool` confirms
> 2026.12.2 bound and `dyld` confirms the SDK's file loaded — but the *failure*
> is one step further from its cause than "library not found" would be. Now
> documented in three places rather than discovered a third time.

`project.json` gained `"macos-min-version": "15.0"`, because c3c defaults to 11.0
and the SDK is built for 15.0, so every link drew a "building for macOS-11.0, but
linking with dylib built for newer version" warning. A binary that links libslang
cannot honestly claim to run where libslang will not load, and a warning on every
build is how a real one gets missed.

### S3 — a failed compile is not a fault (`src/shader/compile.c3`)

`compile_slang` returns `ShaderModule { ok, spirv, diagnostic, layout, entries }`
and a shader that does not compile comes back with `ok: false` and the diagnostic
attached. A fault would throw away the one thing worth returning.

Slang's diagnostics are the reason this matters:

    error[E30015]: undefined identifier
      --> bad.slang:7:18
       |
     7 | o.sv_position = notAFunction(vid);
       |                 ^^^^^^^^^^^^ undefined identifier 'notAFunction'.

A line, a column, the source line and a caret span — which is what `plan.md` §3
means by routing it verbatim into the thrown JS exception at M5. The diagnostic
comes back on the **success** path too, because that is where warnings arrive.

**One session for the process, never destroyed.** `spCreateSession` costs 55 ms
against 17 ms for a compile, so a session per compile would be four parts setup
to one part work. Nothing owns it — `MeshPass`, the JS runtime and the test
harness all compile and outlive each other in different orders — so the only
candidate owner is `main`, which would then have to be right on every
early-return path for a teardown whose whole benefit is returning memory to an
exiting process. Slang allocates it with `malloc`, so a leak-tracked run does not
see it either. Repeated create/destroy was measured safe anyway (eight cycles,
stable at ~65 ms), and `slang::Session.free` exists for callers who want it.

### S4 — the descriptor layout is derived (`src/shader/reflect.c3`)

§3 is right that reflection, not compilation, is the actual requirement: without
it every agent-written shader needs a hand-authored descriptor declaration beside
it and "just write the shader" dies on contact.

**A `Sampler2D` and a `Texture2D` are indistinguishable at two of the three levels
Slang exposes.** Both have type kind `RESOURCE`; both have parameter category
`DESCRIPTOR_TABLE_SLOT`. Only the *binding range type* separates
`COMBINED_TEXTURE_SAMPLER` from `TEXTURE`. Deriving a layout from either of the
first two produces a `SAMPLED_IMAGE` where the shader wants a combined image
sampler — `plan.md` §7's "getting this wrong produces a black screen, not an
error", exactly.

The binding *index* comes from a fourth view again, the descriptor-set one,
because that is the view that knows about `[vk::binding(n, m)]`. A binding
range's own index is its position in declaration order, which is the same number
often enough to look correct.

Push-constant ranges are skipped by *category*, not by name or type: a push block
reflects as a constant buffer exactly like `ConstantBuffer<T>` does, and putting
one in a set layout is a validation error naming a binding the shader never
declared.

Stage flags are the **union** of the entry points' stages rather than the precise
per-binding truth. `spIsParameterLocationUsed` would give the latter, and being
wrong about it in the tight direction is a descriptor the shader reads and the
layout does not declare — reported by nothing. A wider flag is legal, free, and
cannot be wrong. It is still derived; the entry points come from reflection.

### S5 — the comment became a check (`src/gpu/pipeline.c3`)

`gpu/pipeline.c3`'s header has carried a table of push-block offsets since M1.
It is now `MESH_PUSH_FIELDS`, and `check_push_block` compares it against what
Slang reflects out of the module that is about to run. A field added to one side
and not the other is a sentence at startup instead of geometry read at the wrong
address.

This is the same class of failure `plan.md` §6 already records — a build step and
its documented equivalent drifting — one level in: a comment is worth exactly
what `project.json`'s `slangc` line was worth in M2, which is to say it was wrong
for a whole milestone and nothing noticed.

### S6 — the cache owns the pipelines

`PipelineCache` is keyed on `hash(source, render state)` and **a hit skips the
Slang call**, not just the pipeline creation — 17 ms against roughly 1 ms, so the
compile is the expensive half (§3). Entries are heap-allocated and handed out by
pointer, so a later acquire that grows the list does not move a pipeline
something is already drawing with; `MeshPass.pipeline` became a borrowed
`MeshPipeline*`.

On a hash hit the **source is compared** before the pipeline is returned.
`gpu/texture.c3` compares dimensions before believing its content hash for the
same reason, and §6 states the rule generally: compare identity, not a proxy for
it. A 64-bit collision here would bind a pipeline compiled from different source,
which renders something plausible and wrong.

The counters `compiles` and `hits` are not diagnostics — they are what
`the_pipeline_cache_skips_the_compile` asserts on, because "the same pointer came
back" would also be true of a cache that recompiled and threw the result away.

## What was wrong before M4 and is fixed now

- **The push constant range and the push call disagreed**, and this is M4's own
  bug rather than an inherited one: reflection reports the 60 bytes the shader
  uses and `MeshPush::size` is 64 with tail padding. Both now read the same
  reflected field. See the verification section for how it fails, which is not
  how it sounds.
- **`shaders/mesh.spv` is deleted** and so is the prepare target that built it.

## Where this departed from `plan.md`

- **`spGetEntryPointCode` is not used**; `spGetCompileRequestCode` is. §3 names
  the former. See S1.
- **`spProcessCommandLineArguments` is used as §3 suggested**, and it was the
  right call — but it is not sufficient on its own. See the finding below.
- **`js/bind_shader.c3` is still not written.** It is the tier-2 material
  surface, which is M5. M4 built what it needs and nothing more.
- **`shader/load.c3` was not replaced, only narrowed.** §3's source tree says it
  "becomes compile_slang"; what happened is that `load_spirv` became
  `load_source` and the compiler went in a new file beside it. The SPIR-V magic
  check moved with the compiler, where it now guards what Slang returned rather
  than what a build step wrote.

## The finding that cost the most

**`slangc` defaults to column-major matrices and the compile-request API does
not.**

`-matrix-layout-column-major` is not in `mesh.slang`'s documented command line
and never needed to be, because it is the CLI's default. Passing that command
line verbatim through `spProcessCommandLineArguments` therefore produced a
*different module*: every matrix in the frame block and the instance array read
transposed.

How it presented is the part worth writing down. The truck rendered — 40% of the
frame covered, 1546 distinct colours, a completely convincing picture. Nothing at
any layer reported anything. The only thing that broke visibly was the built-in
triangle, which collapsed to fourteen lit pixels, and the four tests that use it.

`plan.md` §6 already warns that a build step and its documented equivalent can
drift silently. This is worse than that: **it is not enough for two invocations
to pass the same flags, because the defaults underneath them differ.** The check
that closes it is `matrices_are_column_major`, and the byte-identical md5 above
is the same claim stated once for the whole flag set.

A smaller finding in the same family, pointing the other way:
**`-fvk-use-entrypoint-name` is a no-op on this SDK.** Removing it produces a
byte-identical module through both the API and `slangc`. It is kept — it is in
the documented invocation, it costs nothing, and a default that changed once can
change back — but the claim that it is load-bearing was not true here, and the
comment saying so has been corrected rather than left as folklore.

## Verification

    c3c build --trust=full                               clean
    c3c test --trust=full --test-noleak                  72 passed, 0 failed
    c3c test --trust=full                                72 passed, leak-clean
    three --validate (truck, and the triangle)           no validation output

Thirteen of those are new, all in `three_tests::shader`. Nine need no GPU: the
compile, the diagnostics, the reflection walk and the push-block check are all
answerable without a device, which is the argument for keeping the compiler and
the reflection separate from pipeline creation.

`plan.md` §7 asks for four things here by name, and all four are asserted: a
known-good shader compiles to non-empty SPIR-V, a known-bad one produces a
diagnostic containing the line number, the pipeline cache returns the identical
handle for identical source, and a shader with known bindings produces the
descriptor layout it declared. The last one runs against a fixture with six
bindings across two sets — an array, a separate sampler, a storage buffer, a
uniform buffer and a combined sampler — rather than against `mesh.slang`, which
has exactly one descriptor and would pass any walk that only ever looked at
binding range zero.

**Every regression test claimed here was checked by re-introducing the bug it
catches** (`plan.md` §7: an unexercised regression test is an assumption). Each
was injected by a script that asserts the patch applied before running anything —
M3 had two injections silently fail to apply — and restores the file with a
checksum comparison afterwards.

| bug injected | test that caught it | result |
|---|---|---|
| no `-matrix-layout-column-major` | `matrices_are_column_major` | caught |
| the diagnostic is dropped | `a_bad_shader_says_which_line` | caught |
| a combined sampler is mapped as a sampled image | `a_shader_with_known_bindings_reflects_them` | caught |
| an array binding counts as one | `a_shader_with_known_bindings_reflects_them` | caught |
| the push block is treated as a descriptor | `the_mesh_push_block_matches_the_struct` | caught |
| the cache is never consulted | `the_pipeline_cache_skips_the_compile` | caught |
| the render state is not part of the key | `a_different_cull_mode_is_a_different_pipeline` | caught |
| a failed build still leaves an entry | `a_broken_shader_leaves_the_cache_empty` | caught |
| the C3 struct's size is pushed, not the shader's | — | **not caught** |

Two of those rows say something the table alone does not.

**The render-state row needed two edits, not one.** The cull mode is mixed into
the hash *and* compared on a hit, so removing either alone changes nothing — the
first attempt at this injection passed, and the honest reading was that the guard
is redundant rather than that the test is weak. The injection now removes both.

**The last row is a real gap and is left standing.** With the push size wrong the
picture is *pixel-identical* — 2238 lit pixels either way, byte for byte — so no
test here can see it. What sees it is the validation layer:

    ERROR: vkCmdPushConstants(): is called with
      stageFlags (VERTEX|FRAGMENT), offset (0), size (64)
    but VkPipelineLayout doesn't have any valid VkPushConstantRange:
      stageFlags (VERTEX|FRAGMENT), offset (0), size (60) [invalid because outside the range]

`plan.md` §4 already says to run the validation layers whenever a script is
executing and route what they say into the thrown JS exception; that is an M5
item and this is one more argument for it. Until then the mitigation is
structural rather than tested: the pipeline's range and the push call read the
same reflected field, so they cannot diverge without an edit that deliberately
hardcodes one of them.

Also run by hand:

| what | result |
|---|---|
| `--grid 1000` on `truck.glb` | 4 draw calls, 4000 instances, 2 856 000 triangles |
| the tier-1 example over a real socket, port 8813 | `drawCalls: 1`, `instances: 12`, a 2351-byte PNG |
| startup, headless, compile included | 0.23 s, stable across three runs |
| a shader with a deliberate error | the diagnostic above, no pipeline, no fallback |
