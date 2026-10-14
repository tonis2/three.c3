<*
`three.compute`, from a script: buffers, a kernel, a dispatch, an answer.

 The C3 suite (`compute_test.c3`) checks the host side of this — the reflection,
 the pipeline, the bindings. What is here is the layer above it: whether the
 shape a script writes is the shape a person would want to write, and whether
 the numbers come back right through the handle, the view and the read.

 `c3c test --trust=full --test-noleak --test-filter three_tests::js_compute`
*>
module three_tests::js_compute;

import three;
import three_tests::device;
import std::core::test;
import std::io::file;
import image;

<*
 A runtime with a headless device and no scene pipeline.

 `with_pass: false` because none of this draws anything — compute needs the
 device and nothing else, and a pass would only compile shaders on the way in.
 What a runtime over a bare pass still needs is the scene list, because opening
 a context reads the rendered scene's stats whether or not a script asks; that
 is `init_scenes` and `free_scenes`, which is how `js_test.c3`'s no-device
 macro does it too.
*>
macro @with_compute_js(; @body(three::JsRuntime* run))
{
	three::Renderer* renderer = device::borrow(with_pass: false);
	defer device::release();
	renderer.pass.init_scenes();
	defer renderer.pass.free_scenes();
	renderer.pass.camera = three::default_camera();

	three::JsRuntime runtime;
	runtime.open(&renderer.pass, renderer)!!;
	defer runtime.close();

	@body(&runtime);
}

<*
 The smallest useful kernel: `out[i] = a[i] * scale`, one buffer in, one out.

 Its push block's field order is what `run({ push: {...} })` packs against, and
 the `@storage` array names are what `run({ a, result })` binds against.
*>
const String SCALE = `
float a[];
float result[];

struct Push @pushconstant
{
    float scale;
}
Push push;

struct ComputeIn { uint3 thread @builtin(global_invocation_id); }

fn void main(ComputeIn input) @compute @threads(64, 1, 1)
{
    uint i = input.thread.x;
    if (i >= 64u) return;
    result[i] = a[i] * push.scale;
}
`;

<*
 The shader as a JavaScript string literal.

 The source is multi-line, so a raw splice into the script is a syntax error
 the moment it contains a newline — which every kernel does. Quoting it is the
 same thing a person writing a script by hand does, one level up.
*>
fn String js_literal(String text)
{
	DString out;
	out.tinit(text.len + 16);
	out.append_char('"');
	foreach (c : text)
	{
		switch (c)
		{
			case '"':  out.append_string("\\\"");
			case '\\': out.append_string("\\\\");
			case '\n': out.append_string("\\n");
			case '\r': out.append_string("\\r");
			case '\t': out.append_string("\\t");
			default:   out.append_char(c);
		}
	}
	out.append_char('"');
	return out.copy_str(tmem);
}


// `out[i] = a[i] * 2` for the first `push.n` elements: the bound is the whole
// check, so a push block read as floats leaves the wrong elements written.
const String COUNTED = `
float a[];
float result[];

struct Push @pushconstant
{
    uint n;
}
Push push;

struct ComputeIn { uint3 thread @builtin(global_invocation_id); }

fn void main(ComputeIn input) @compute @threads(64, 1, 1)
{
    uint i = input.thread.x;
    if (i >= push.n) return;
    result[i] = a[i] * 2.0;
}
`;

fn void a_script_runs_a_kernel_and_reads_the_answer() @test
{
	@with_compute_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(string::tformat(`
const a = three.compute.f32(64);
for (let i = 0; i < 64; i++) a.bytes[i] = i;
a.write(a.bytes);
const out = three.compute.f32(64);

const kernel = three.compute.kernel(%s, { name: 'scale', pushFields: ['scale'] });
kernel.run({ a, result: out }, { threads: 64, push: { scale: 2 } });
out.read();

return out.f32(5);
`, js_literal(SCALE)));
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == "10", "element 5 should be 5 * 2, got '%s'", result.value);
	};
}


<*
 An integer push field, which is the one place the packer has to be told
 something the value cannot say: `n: 64` is a float 64.0 or the uint 64, and a
 shader reading the wrong one of those computes a garbage bound. The script
 says `three.compute.uint(n)` and the shader's `uint n;` gets 64.
*>
fn void an_integer_push_field_arrives_as_bits() @test
{
	@with_compute_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(string::tformat(`
const a = three.compute.f32(64);
const out = three.compute.f32(64);
for (let i = 0; i < 64; i++) { a.bytes[i] = i; out.bytes[i] = 100 + i; }
a.write(a.bytes);
out.write(out.bytes);

const kernel = three.compute.kernel(%s, { name: 'counted' });
kernel.run({ a, result: out }, { threads: 64, push: { n: three.compute.uint(33) } });
out.read();

// 33 was doubled and 40 was left where the script put it: the bound is what
// tells the two packings apart, so both ends of it are checked.
return { inside: out.f32(32), outside: out.f32(40) };
`, js_literal(COUNTED)));
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == `{"inside":64,"outside":140}`,
			"32 should be 32 * 2 and 40 should still hold 140, got '%s'", result.value);
	};
}

<*
 A chain of dispatches reaches the GPU as one submission when the script says
 `dispatch` twice and submits once — the shape a pipeline has, and the reason
 `run` and `dispatch` are two verbs.
*>
fn void a_chain_of_dispatches_submits_once() @test
{
	@with_compute_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(string::tformat(`
const a = three.compute.f32(64);
for (let i = 0; i < 64; i++) a.bytes[i] = 1;
a.write(a.bytes);
const mid = three.compute.f32(64);
const result = three.compute.f32(64);

const kernel = three.compute.kernel(%s, { name: 'scale', pushFields: ['scale'] });

kernel.dispatch({ a, result: mid }, { threads: 64, push: { scale: 3 } });
kernel.dispatch({ a: mid, result }, { threads: 64, push: { scale: 4 } });
three.compute.submit();

result.read();
return result.f32(0);
`, js_literal(SCALE)));
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == "12", "1 * 3 * 4 should be 12, got '%s'", result.value);
	};
}

<*
 Writing a buffer after it was made, which is the whole point of a weights
 buffer: the kernel's input does not have to be known when the buffer is.
*>
fn void a_buffer_can_be_written_after_it_is_made() @test
{
	@with_compute_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(string::tformat(`
const a = three.compute.f32(64);
const result = three.compute.f32(64);
const kernel = three.compute.kernel(%s, { name: 'scale', pushFields: ['scale'] });

a.write([8, 0, 0, 0]);
kernel.run({ a, result }, { threads: 64, push: { scale: 0.5 } });
result.read();

return result.f32(0);
`, js_literal(SCALE)));
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == "4", "8 * 0.5 should be 4, got '%s'", result.value);
	};
}

<*
 A shader that does not compile is an exception carrying the compiler's line
 and column, not a kernel that dispatches nothing.
*>
fn void a_refused_shader_throws_the_diagnostic() @test
{
	@with_compute_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
three.compute.kernel("this is not a shader", { name: 'broken' });
return 'unreachable';
`);
		defer result.free();

		test::@check(!result.ok, "the script should have thrown");
		test::@check(result.error.contains("broken"), "the error should name the kernel: %s", result.error);
	};
}

<*
 A buffer handed to the wrong binding count is refused by the host rather than
 read as a stale descriptor.
*>
fn void a_dispatch_with_the_wrong_buffers_throws() @test
{
	@with_compute_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(string::tformat(`
const a = three.compute.f32(64);
const result = three.compute.f32(64);
const kernel = three.compute.kernel(%s, { name: 'scale', pushFields: ['scale'] });
kernel.run([a], { threads: 64, push: { scale: 2 } });
return 'unreachable';
`, js_literal(SCALE)));
		defer result.free();

		test::@check(!result.ok, "a dispatch with one buffer for two bindings should throw");
		test::@check(result.error.contains("binds 2"), "and say how many it wanted: %s", result.error);
	};
}

<*
 A buffer handle kept past its `dispose()` is refused rather than reaching
 whatever was made in its place.
*>
fn void a_disposed_buffer_is_refused_by_name() @test
{
	@with_compute_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
const a = three.compute.f32(64);
a.dispose();
a.read();
return 'unreachable';
`);
		defer result.free();

		test::@check(!result.ok, "reading a disposed buffer should throw");
		test::@check(result.error.contains("disposed"), "and say that it was: %s", result.error);
	};
}


<*
 A kernel from a module that is already SPIR-V: compiled here, saved, and then
 loaded and dispatched by the script rather than compiled by it.

 That is the shape a shipped pipeline kernel has - the heavy kernels come from
 another compiler and are files next to the binary - and it is the one path
 where the host has nothing to fall back on: no source to compile, and no
 source to read the workgroup size out of.
*>
fn void a_script_dispatches_a_compiled_module() @test
{
	three::ShaderModule shader = three::compile_compute_shader("spirv_kernel", SCALE);
	defer shader.free();
	test::@check(shader.ok, "the shader should compile: %s", shader.diagnostic);

	if (catch file::save("build/js_spirv_kernel.spv", shader.spirv))
	{
		test::@check(false, "could not save the module");
		return;
	}

	@with_compute_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
const module = three.compute.spirv('build/js_spirv_kernel.spv');
const kernel = three.compute.kernel(module, { name: 'scale', pushFields: ['scale'] });

const a = three.compute.f32(64);
for (let i = 0; i < 64; i++) a.bytes[i] = i;
a.write(a.bytes);
const out = three.compute.f32(64);
kernel.run({ a, result: out }, { threads: 64, push: { scale: 3 } });
out.read();

return [out.f32(5), kernel.threads[0], kernel.threads[1], kernel.threads[2]];
`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == "[15,64,1,1]",
			"element 5 should be 5 * 3 and the threads should come from the module, got '%s'", result.value);
	};
}


<*
 A module from another compiler, dispatched as it is.

 This is what a kernel from elsewhere is: `test/fixtures/scale_module.spv` is
 assembled from `scale_module.spvasm`, a two-buffer kernel as another compiler
 wrote it, and nothing here compiles it - the reflection reads its bindings by the names it carries, its
 push block by the offsets it carries, and its workgroup size out of its own
 `LocalSize`.

 The binding is by name, so this also checks that a module that is not this
 compiler\'s still answers to the names a script binds against.
*>
fn void a_script_dispatches_a_module_from_another_compiler() @test
{
	@with_compute_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
const kernel = three.compute.kernel(three.compute.spirv('test/fixtures/scale_module.spv'), { name: 'scaled' });

const a = three.compute.f32(64);
for (let i = 0; i < 64; i++) a.bytes[i] = i;
a.write(a.bytes);
const out = three.compute.f32(64);
kernel.run({ source: a, destination: out }, { threads: 64, push: { scale: 4 } });
out.read();

return [out.f32(5), kernel.threads[0]];
`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == "[20,64]",
			"element 5 should be 5 * 4 and the threads should come from the module, got '%s'", result.value);
	};
}

// `values[i] += 1`, in place: one binding, which is the shape the old per-
// dispatch readback of `buffers[1]` could not survive.
const String INCREMENT = `
float values[];

struct ComputeIn { uint3 thread @builtin(global_invocation_id); }

fn void main(ComputeIn input) @compute @threads(64, 1, 1)
{
    uint i = input.thread.x;
    if (i >= 64u) return;
    values[i] = values[i] + 1.0;
}
`;

<*
 A thousand dispatches recorded and submitted once: the shape one denoising
 step of a pipeline has. Nothing reaches the GPU until the script says so - the
 count of recorded commands is still all thousand when the script stops short of
 the submit - and each one sees the one before it.
*>
fn void a_thousand_dispatches_are_one_submission() @test
{
	@with_compute_js(; three::JsRuntime* run)
	{
		three::RunResult recorded = run.run(string::tformat(`
const values = three.compute.f32(64);
globalThis.values = values;
const kernel = three.compute.kernel(%s, { name: 'increment' });
globalThis.increment = kernel;
for (let i = 0; i < 1000; i++) kernel.dispatch([values], { threads: 64 });
return 'recorded';
`, js_literal(INCREMENT)));
		defer recorded.free();
		test::@check(recorded.ok, "the recording script succeeded: %s", recorded.error);
		// A thousand dispatches and the new buffer's zero fill.
		test::@check(run.renderer.compute.pending == 1001,
			"all thousand should still be waiting for a submit, found %d", run.renderer.compute.pending);

		three::RunResult result = run.run(`
three.compute.submit();
values.read();
return [values.f32(0), values.f32(63)];
`);
		defer result.free();
		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == "[1000,1000]", "each dispatch should have added one, got '%s'", result.value);
		test::@check(run.renderer.compute.pending == 0, "the submit should have taken all of them");
	};
}

<*
 Ranges of one buffer bound as two bindings, a GPU-side copy, a fill, and the
 offset forms of `write` and `readBytes`: the pieces a KV cache and a CFG
 latent save are made of.
*>
fn void views_copies_and_fills_stay_in_order() @test
{
	@with_compute_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(string::tformat(`
const kernel = three.compute.kernel(%s, { name: 'scale', pushFields: ['scale'] });

// 64 floats in, 64 floats out, both in one 512-byte buffer. 256 is the largest
// binding alignment Vulkan allows, so it is a legal offset everywhere.
const pool = three.compute.f32(128);
const input = new Float32Array(64);
for (let i = 0; i < 64; i++) input[i] = i;
pool.write(input);

kernel.dispatch({ a: pool.view(0, 256), result: pool.view(256, 256) }, { threads: 64, push: { scale: 2 } });

// Saved on the GPU, then the pool's output half cleared, then restored.
const saved = three.compute.f32(64);
three.compute.copy(pool, saved, { srcOffset: 256, size: 256 });
three.compute.zero(pool, { offset: 256, size: 256 });
const cleared = new Float32Array(pool.readBytes(256 + 4 * 10, 4).buffer)[0];
three.compute.copy(saved, pool, { dstOffset: 256 });

// A part-write, then a part-read of the same words.
pool.write(new Float32Array([-1, -2]), 4 * 3);
const head = new Float32Array(pool.readBytes(0, 4 * 5).buffer);

pool.read();
return {
	doubled: pool.f32(64 + 10),
	cleared,
	head: Array.from(head),
};
`, js_literal(SCALE)));
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == `{"doubled":20,"cleared":0,"head":[0,1,2,-1,-2]}`,
			"got '%s'", result.value);
	};
}

<*
 Dispatches marked independent skip their barrier, and a later barrier covers
 them: three kernels writing three buffers from one input, then one that reads
 all three.
*>
fn void independent_dispatches_meet_at_a_barrier() @test
{
	@with_compute_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(string::tformat(`
const kernel = three.compute.kernel(%s, { name: 'scale', pushFields: ['scale'] });
const a = three.compute.f32(64, new Array(64).fill(1));
const outs = [three.compute.f32(64), three.compute.f32(64), three.compute.f32(64)];
outs.forEach((result, i) =>
	kernel.dispatch({ a, result }, { threads: 64, push: { scale: i + 2 }, independent: true }));
three.compute.barrier();
const last = three.compute.f32(64);
kernel.dispatch({ a: outs[2], result: last }, { threads: 64, push: { scale: 10 } });
last.read();
outs[0].read();
return [outs[0].f32(0), last.f32(0)];
`, js_literal(SCALE)));
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == "[2,40]", "got '%s'", result.value);
	};
}

<*
 A binding that starts off the device's alignment is refused by name, and the
 limits a script chooses kernels by are there to read.
*>
fn void a_misaligned_view_is_refused_and_limits_are_readable() @test
{
	@with_compute_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(string::tformat(`
const limits = three.compute.limits;
if (!(limits.subgroupSize > 0) || !(limits.bindingAlignment > 0) || !(limits.maxSharedMemory >= 16384))
	return 'bad limits ' + JSON.stringify(limits);
if (limits.bindingAlignment <= 4) return 'binds at 4 on this device';
const kernel = three.compute.kernel(%s, { name: 'scale', pushFields: ['scale'] });
const pool = three.compute.f32(256);
try {
	kernel.dispatch({ a: pool.view(4, 256), result: pool.view(512, 256) }, { threads: 64, push: { scale: 1 } });
} catch (e) {
	return String(e.message);
}
return 'accepted';
`, js_literal(SCALE)));
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value.contains("multiples of") || result.value.contains("binds at 4"),
			"a misaligned binding should be refused by name, got '%s'", result.value);
	};
}

<*
 One entry of a module that holds two, each with its own buffers and push
 block. The kernel is described by the entry it was made for - one binding and
 a sixteen-byte push block for `affine`, where `scaled` in the same module has
 two bindings and four bytes - rather than by whichever of them the module
 declares last. (`test/fixtures/two_entries.spvasm` is the source.)
*>
fn void a_script_dispatches_one_entry_of_many() @test
{
	@with_compute_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
const module = three.compute.spirv('test/fixtures/two_entries.spv');
const affine = three.compute.kernel(module, { name: 'affine', entry: 'affine' });
const scaled = three.compute.kernel(module, { name: 'scaled', entry: 'scaled' });

const data = three.compute.f32(40, new Array(40).fill(2));
affine.run([data], { threads: 40, push: { n: three.compute.uint(35), mul: 3, add: 1, pad: three.compute.uint(0) } });
const out = three.compute.f32(64);
scaled.run([data, out], { workgroups: 1, push: { scale: 0.5 } });
out.read();

return [out.f32(0), out.f32(36), affine.threads[0], scaled.threads[0]];
`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == "[3.5,1,32,64]",
			"affine should reach the first 35 elements only, then scaled halves them, got '%s'", result.value);
	};
}

// ============================================================================
// Images
// ============================================================================

<*
 A runtime over a full pass, for the checks that make images: an image is a
 texture, so it needs the scene's asset table, and the material checks draw.
*>
macro @with_image_js(; @body(three::JsRuntime* run))
{
	three::Renderer* renderer = device::borrow(64, 64);
	defer device::release();

	three::JsRuntime runtime;
	runtime.open(&renderer.pass, renderer)!!;
	defer runtime.close();

	@body(&runtime);
}

// Each texel is its own coordinates: x in red, y in green, and a constant blue,
// so a readback says where every value went as well as that one did.
const String GRADIENT = `
image2d<rgba16f> target;

struct ComputeIn { uint3 id @builtin(global_invocation_id); }

fn void main(ComputeIn at) @compute @threads(8, 8, 1)
{
    int2 size = target.size();
    int2 px = int2(at.id.xy);
    if (px.x >= size.x || px.y >= size.y) return;
    target[px] = float4(float(px.x), float(px.y), 0.5, 1.0);
}
`;

<*
 A kernel writes an image and a script reads the texels back as numbers.

 `rgba16f`, so the readback is the converted one - halves in the image, floats in
 the array - and the values are coordinates, so a transposed copy or a row
 stride read wrong lands a number in the wrong place rather than merely a wrong
 number. 0.5 is exact in a half, and so is every integer this small.
*>
fn void a_script_writes_an_image_and_reads_it_back() @test
{
	@with_image_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(string::tformat(`
const target = three.compute.image({ width: 20, height: 12, format: 'rgba16f' });
const kernel = three.compute.kernel(%s, { name: 'gradient' });
kernel.run({ target }, { threads: [20, 12] });
const texels = target.read();
const at = (x, y, c) => texels[(y * 20 + x) * 4 + c];
const answer = [texels.constructor.name, texels.length, at(0, 0, 0), at(19, 0, 0), at(3, 11, 1), at(7, 5, 2), at(19, 11, 3)];
target.dispose();
return answer.join(',');
`, js_literal(GRADIENT)));
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == "\"Float32Array,960,0,19,11,0.5,1\"",
			"the texels came back as floats at their own coordinates: '%s'", result.value);
	};
}

// Every thread adds one to the same texel. 64 x 64 threads, one answer.
const String COUNT = `
image2d<r32ui> counts;

struct ComputeIn { uint3 id @builtin(global_invocation_id); }

fn void main(ComputeIn at) @compute @threads(8, 8, 1)
{
    InterlockedAdd(counts[int2(1, 0)], 1u);
}
`;

<*
 An `r32ui` image counts atomically, and reads back as unsigned integers.

 4096 threads into one texel: a store that was not atomic would lose most of
 them, and a texel of the wrong width would put the count somewhere else. The
 image starts at zero, which is the other half of the claim - a fresh image is
 an accumulator without a clear.
*>
fn void an_image_kernel_counts_into_r32ui_atomically() @test
{
	@with_image_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(string::tformat(`
const counts = three.compute.image({ width: 4, height: 1, format: 'r32ui' });
three.compute.kernel(%s, { name: 'count' }).run({ counts }, { threads: [64, 64] });
const values = counts.read();
return [values.constructor.name, values[0], values[1], values[2]].join(',');
`, js_literal(COUNT)));
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == "\"Uint32Array,0,4096,0\"", "every thread was counted once: '%s'", result.value);
	};
}

// Reads one image and writes another, declared in the other order from the one
// the script names them in.
const String DOUBLE = `
image2d<r32f> field;
image2d<r32f> doubled;
struct ComputeIn { uint3 id @builtin(global_invocation_id); }
fn void main(ComputeIn at) @compute @threads(2, 2, 1)
{
    int2 px = int2(at.id.xy);
    doubled[px] = field[px] * 2.0;
}
`;

<*
 A readback written back is the image it came from, and a kernel sees what a
 script wrote: `write` and `read` are one layout.
*>
fn void a_script_writes_texels_a_kernel_reads() @test
{
	@with_image_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(string::tformat(`
const field = three.compute.image({ width: 2, height: 2, format: 'r32f', data: [1.5, -2, 3.25, 8] });
const doubled = three.compute.image({ width: 2, height: 2, format: 'r32f' });
three.compute.kernel(%s, { name: 'double' }).run({ doubled, field }, { workgroups: [1, 1] });
return Array.from(doubled.read()).join(',') + '|' + Array.from(field.read()).join(',');
`, js_literal(DOUBLE)));
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == "\"3,-4,6.5,16|1.5,-2,3.25,8\"",
			"the kernel read what the script wrote, bound by name in any order: '%s'", result.value);
	};
}

<*
 The image a kernel is handed must be the image the shader declared, and the
 refusal names the binding and both formats.

 Three ways to get it wrong, each a picture of reinterpreted bits if it were
 let through: the wrong format, an image where a buffer goes, and a buffer where
 an image goes.
*>
fn void a_wrong_image_is_refused_by_name() @test
{
	@with_image_js(; three::JsRuntime* run)
	{
		three::RunResult format = run.run(string::tformat(`
const target = three.compute.image({ width: 8, height: 8, format: 'rgba8' });
three.compute.kernel(%s, { name: 'gradient' }).run({ target }, { threads: [8, 8] });
`, js_literal(GRADIENT)));
		defer format.free();
		test::@check(!format.ok, "an rgba8 image in an rgba16f binding is refused");
		test::@check(format.error.contains("target") && format.error.contains("rgba16f") && format.error.contains("rgba8"),
			"naming the binding and both formats: %s", format.error);

		three::RunResult buffer_slot = run.run(string::tformat(`
const a = three.compute.image({ width: 64, height: 1, format: 'r32f' });
const result = three.compute.f32(64);
three.compute.kernel(%s, { name: 'scale', pushFields: ['scale'] }).run({ a, result }, { threads: 64, push: { scale: 2 } });
`, js_literal(SCALE)));
		defer buffer_slot.free();
		test::@check(!buffer_slot.ok, "an image in a buffer binding is refused");
		test::@check(buffer_slot.error.contains("'a'") && buffer_slot.error.contains("buffer"),
			"naming the binding: %s", buffer_slot.error);

		three::RunResult image_slot = run.run(string::tformat(`
const target = three.compute.f32(64);
three.compute.kernel(%s, { name: 'gradient' }).run({ target }, { threads: [8, 8] });
`, js_literal(GRADIENT)));
		defer image_slot.free();
		test::@check(!image_slot.ok, "a buffer in an image binding is refused");
		test::@check(image_slot.error.contains("'target'") && image_slot.error.contains("storage image"),
			"naming the binding: %s", image_slot.error);

		three::RunResult unknown = run.run(`three.compute.image({ width: 4, height: 4, format: 'rgb8' });`);
		defer unknown.free();
		test::@check(!unknown.ok && unknown.error.contains("rgba8"),
			"a format with no storage form is refused with the one it meant: %s", unknown.error);
	};
}

<*
 An integer image is not a texture: a material sampling it would read its
 integers as floats, so handing one to a material is refused at the line.
*>
fn void an_integer_image_cannot_be_a_texture() @test
{
	@with_image_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
const counts = three.compute.image({ width: 4, height: 4, format: 'r32ui' });
new three.MeshLambertMaterial({ map: counts });
`);
		defer result.free();
		test::@check(!result.ok, "an r32ui image as a map is refused");
		test::@check(result.error.contains("r32ui") && result.error.contains("cannot be a texture"),
			"saying why: %s", result.error);
	};
}

<*
 What `limits` says about storage images is what the device has: the core
 formats are on every device, and the rest are the device's to list.
*>
fn void compute_limits_report_storage_image_features() @test
{
	@with_image_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
const limits = three.compute.limits;
const core = ['rgba32f', 'rgba16f', 'r32f', 'rgba8', 'r32ui', 'r32i'];
return [
	core.every((f) => limits.storageImageFormats.includes(f)),
	limits.maxStorageImages >= 4,
	limits.maxImageSize >= 4096,
	typeof limits.storageImageWriteWithoutFormat,
].join(',');
`);
		defer result.free();
		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == "\"true,true,true,boolean\"", "the limits describe storage images: '%s'", result.value);
	};
}

// Writes one colour over the whole image: what a material wearing it shows.
const String FILL = `
image2d<rgba8> target;

struct ComputeIn { uint3 id @builtin(global_invocation_id); }

struct Push @pushconstant { float4 colour; }
Push push;

fn void main(ComputeIn at) @compute @threads(8, 8, 1)
{
    int2 px = int2(at.id.xy);
    if (px.x >= target.size().x || px.y >= target.size().y) return;
    target[px] = push.colour;
}
`;

<*
 A mesh wears an image a kernel wrote, and a second kernel run reaches the next
 frame.

 The second half is the one that could go wrong quietly: nothing in the scene
 changes between the two frames, so a frame that compared its picture key and
 found it the same would show the old colour - which is what the compute image
 epoch in `picture_key` and the scene cache exists to prevent - and a frame whose
 sampling raced the kernel would show either.
*>
fn void a_mesh_wears_an_image_a_kernel_wrote() @test
{
	@with_image_js(; three::JsRuntime* run)
	{
		three::RunResult green = run.run(string::tformat(`
globalThis.paint = three.compute.image({ width: 16, height: 16, format: 'rgba8' });
globalThis.fill = three.compute.kernel(%s, { name: 'fill' });
fill.run({ target: paint }, { threads: [16, 16], push: { r: 0, g: 1, b: 0, a: 1 } });
globalThis.scene = new three.Scene();
const wall = new three.Mesh(new three.PlaneGeometry(8, 8), new three.MeshLambertMaterial({ map: paint }));
scene.add(wall);
three.camera.lookAt(0, 0, 0);
three.camera.orbit(0, 0, 4);
three.render(scene, three.camera);
`, js_literal(FILL)));
		defer green.free();
		test::@check(green.ok, "the scene was built: %s", green.error);

		image::Image first = run.renderer.capture()!!;
		defer first.free();
		uint greens = count_dominant(&first, 1);
		test::@check(greens > 3000, "the wall shows the kernel's green: %d of %d pixels", greens, 64 * 64);

		three::RunResult blue = run.run(`
fill.run({ target: paint }, { threads: [16, 16], push: { r: 0, g: 0, b: 1, a: 1 } });
three.render(scene, three.camera);
`);
		defer blue.free();
		test::@check(blue.ok, "the second fill ran: %s", blue.error);

		image::Image second = run.renderer.capture()!!;
		defer second.free();
		uint blues = count_dominant(&second, 2);
		test::@check(blues > 3000, "the next frame shows the second fill: %d blue, %d still green",
			blues, count_dominant(&second, 1));
	};
}

<*
 Pixels that are clearly one channel and nothing else: that channel bright, the
 other two dark. A lit material scales the colour by however much light lands,
 so this asks which colour it is rather than how bright.
*>
fn uint count_dominant(image::Image* shot, sz channel)
{
	uint found = 0;
	for (sz i = 0; i < shot.pixels.len; i += 4)
	{
		bool lit = shot.pixels[i + channel] > 60;
		bool alone = true;
		for (sz other = 0; other < 3; other++)
		{
			if (other != channel && shot.pixels[i + other] > 24) alone = false;
		}
		if (lit && alone) found++;
	}
	return found;
}

<*
 Everything an image goes through, with the Khronos layer watching: made,
 written by a kernel, worn by a material, drawn, rewritten while the frame that
 sampled it may still be in flight, drawn again, read back and written from the
 host, disposed.

 Each step is a layout or a barrier a mistake would leave out, and none of them
 would show in a picture on this driver: the image never leaves `GENERAL`, the
 kernel's submission orders itself after the frame's (`Compute.open_images`), and
 its writes are handed to the next frame by the barrier at the end of its own
 command buffer.
*>
fn void a_compute_image_is_silent_under_validation() @test
{
	three::Renderer* renderer = device::borrow(64, 64, validate: true);
	defer device::release();
	if (!renderer.gpu.validation) return;

	three::JsRuntime runtime;
	runtime.open(&renderer.pass, renderer)!!;
	defer runtime.close();

	three::RunResult setup = runtime.run(string::tformat(`
globalThis.paint = three.compute.image({ width: 16, height: 16, format: 'rgba8' });
globalThis.fill = three.compute.kernel(%s, { name: 'fill' });
globalThis.scene = new three.Scene();
scene.add(new three.Mesh(new three.PlaneGeometry(8, 8), new three.MeshLambertMaterial({ map: paint })));
three.camera.lookAt(0, 0, 0);
three.camera.orbit(0, 0, 4);
three.render(scene, three.camera);
`, js_literal(FILL)));
	defer setup.free();
	test::@check(setup.ok, "the scene was built: %s", setup.error);

	image::Image warmup = renderer.capture()!!;
	warmup.free();

	renderer.gpu.begin_capture();

	three::RunResult worked = runtime.run(`
fill.run({ target: paint }, { threads: [16, 16], push: { r: 1, g: 0, b: 0, a: 1 } });
three.render(scene, three.camera);
fill.dispatch({ target: paint }, { threads: [16, 16], push: { r: 0, g: 1, b: 0, a: 1 } });
three.compute.submitAsync();
three.render(scene, three.camera);
const texels = paint.read();
paint.write(texels);
three.render(scene, three.camera);
const counts = three.compute.image({ width: 2, height: 2, format: 'r32ui' });
counts.dispose();
return texels[1];
`);
	defer worked.free();
	image::Image shot = renderer.capture()!!;
	shot.free();

	String errors = renderer.gpu.sink.errors.str_view();
	String warnings = renderer.gpu.sink.warnings.str_view();
	renderer.gpu.end_capture();

	test::@check(worked.ok, "the script succeeded: %s", worked.error);
	test::@check(worked.value == "255", "the second fill was read back: %s", worked.value);
	test::@check(errors.len == 0, "a compute image produced validation errors: %s", errors);
	test::@check(warnings.len == 0, "and warnings: %s", warnings);
}
