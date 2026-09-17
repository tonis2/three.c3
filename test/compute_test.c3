<*
Compute, end to end with no window: buffers in, a kernel dispatched, the
answer read back and compared.

 The point of the suite is the seam rather than the arithmetic. A dispatch that
 works here has crossed every boundary the JS API will later sit on - shady
 compiling a `@storage` block, the reflection reading it back, the pipeline
 being built against a push descriptor layout, the buffers being bound by
 binding number, and the result surviving the trip out through a staging copy.
*>
module three_tests::compute;

import three;
import three_tests::device;
import std::core::test;
import std::math;

// `out[i] = in[i] * scale + bias`, the smallest kernel with a push block and
// two buffers: one read, one written, and constants that would be wrong if the
// block were laid out differently from the struct.
const String SCALE_BIAS = `
float source[];
float destination[];

struct Push @pushconstant
{
    float scale;
    float bias;
}
Push push;

struct ComputeIn { uint3 thread @builtin(global_invocation_id); }

fn void main(ComputeIn input) @compute @threads(64, 1, 1)
{
    uint i = input.thread.x;
    if (i >= 64u) return;
    destination[i] = source[i] * push.scale + push.bias;
}
`;

struct ScaleBias
{
	float scale;
	float bias;
}

fn void a_kernel_reads_and_writes_through_two_buffers() @test
{
	three::Renderer* renderer = device::borrow(with_pass: false);
	defer device::release();
	three::Compute* compute = &renderer.compute;

	three::ShaderModule shader = three::compile_compute_shader("scale_bias", SCALE_BIAS);
	defer shader.free();
	test::@check(shader.ok, "the shader should compile: %s", shader.diagnostic);

	three::ComputeKernel kernel;
	kernel.create(compute, &shader, "scale_bias")!!;
	defer kernel.free(renderer.gpu.handle);

	test::@check(kernel.binding_count == 2, "the kernel should bind two buffers, got %d", kernel.binding_count);

	// 64 floats in, 64 out, which is one workgroup of the declared size.
	float[64] values;
	for (uint i = 0; i < 64; i++) values[i] = (float)i;

	three::StorageBuffer source;
	source.create(&renderer.gpu, 64 * 4, &values)!!;
	defer source.free();

	three::StorageBuffer destination;
	destination.create(&renderer.gpu, 64 * 4)!!;
	defer destination.free();

	// The push block is the shader's own struct, laid out std430: two floats at
	// 0 and 4.
	ScaleBias push = { .scale = 2.0f, .bias = 1.0f };

	compute.dispatch(&kernel, { source, destination }, &push, 1)!!;
	compute.submit()!!;

	char[256] bytes;
	destination.read(compute, 0, bytes[..])!!;
	float[] result = ((float*)&bytes)[:64];

	bool all_correct = true;
	for (uint i = 0; i < 64; i++)
	{
		if (math::abs(result[i] - ((float)i * 2.0f + 1.0f)) > 0.0001f) all_correct = false;
	}
	test::@check(all_correct, "every element should be 2i+1; first mismatch at %d: %f", 0, result[0]);
}

<*
 A buffer written after its kernel was built is what the GPU reads.

 The order is the whole contract of `submit`: a write is a submission of its
 own, and a dispatch recorded before it but submitted after it sees the new
 bytes. A test that only ever wrote buffers at creation would pass on an
 implementation that uploaded in the wrong order.
*>
fn void a_write_lands_before_the_dispatch_that_reads_it() @test
{
	three::Renderer* renderer = device::borrow(with_pass: false);
	defer device::release();
	three::Compute* compute = &renderer.compute;

	three::ShaderModule shader = three::compile_compute_shader("scale_bias", SCALE_BIAS);
	defer shader.free();

	three::ComputeKernel kernel;
	kernel.create(compute, &shader, "scale_bias")!!;
	defer kernel.free(renderer.gpu.handle);

	three::StorageBuffer source;
	source.create(&renderer.gpu, 64 * 4)!!;
	defer source.free();

	three::StorageBuffer destination;
	destination.create(&renderer.gpu, 64 * 4)!!;
	defer destination.free();

	compute.submit()!!;

	float[64] values;
	for (uint i = 0; i < 64; i++) values[i] = 3.0f;
	source.write(compute, 0, &values, 64 * 4)!!;

	ScaleBias push = { .scale = 1.0f, .bias = 0.0f };
	compute.dispatch(&kernel, { source, destination }, &push, 1)!!;
	compute.submit()!!;

	char[256] bytes;
	destination.read(compute, 0, bytes[..])!!;
	float[] result = ((float*)&bytes)[:64];
	test::@check(math::abs(result[0] - 3.0f) < 0.0001f, "the write should be what the kernel read: %f", result[0]);
}

<*
 A shader that does not compile is a message, not a crash.
*>
fn void a_bad_shader_answers_with_a_diagnostic() @test
{
	three::ShaderModule shader = three::compile_compute_shader("broken", "fn void main() @compute @threads(8, 1, 1) { this is not shady }");
	defer shader.free();

	test::@check(!shader.ok, "a broken source should not compile");
	test::@check(shader.diagnostic.len > 0, "the diagnostic should say something");
}

<*
 The push block's size is read back out of the module rather than assumed,
 which is what the `@pushconstant` struct depends on.
*>
fn void the_push_block_size_is_read_from_the_module() @test
{
	three::ShaderModule shader = three::compile_compute_shader("scale_bias", SCALE_BIAS);
	defer shader.free();

	test::@check(shader.ok, "the shader should compile: %s", shader.diagnostic);
	test::@check(shader.layout.push_size == 8, "two floats are 8 bytes, got %d", shader.layout.push_size);
}

<*
 A kernel built for one shader refuses a module without that entry point.

 Named rather than silently dispatching the wrong function, which is a wrong
 answer with no symptom.
*>
fn void a_missing_entry_point_is_refused() @test
{
	three::Renderer* renderer = device::borrow(with_pass: false);
	defer device::release();

	three::ShaderModule shader = three::compile_compute_shader("scale_bias", SCALE_BIAS);
	defer shader.free();

	three::ComputeKernel kernel;
	if (catch kernel.create(&renderer.compute, &shader, "scale_bias", entry: "nope"))
	{
		return;
	}
	test::@check(false, "a missing entry should be refused rather than built");
}
