<*
 The scripted material reaches the draw path's def.

 `MeshPass.init` and `MeshPass.create_material` are two pass rows, and this is
 the check that a script's `shade()` body is not routed through the built-in
 one: the body returns a colour no light can produce, and the frame has to show
 it. The scene cache is off, and the frame is read back as pixels rather than as
 SPIR-V, because the failure this guards is a body that compiled and was then
 ignored.

 `c3c test --trust=full --test-filter three_tests::mesh_shader`
*>
module three_tests::mesh_shader;

import three;
import three_tests::device;
import image;
import std::core::test;
import std::core::string;

const uint W = 240;
const uint H = 180;

<*
 A script's material is not the draw path's own.

 **The trap this suite exists beside.** `MeshPass.init` and
 `MeshPass.create_material` are two pass rows, so a script's `shade()` body
 must not be routed through the def's built-in body. The material row's own
 module is what has to find the body: the body returns a colour no light can
 produce, and the frame has to show it.
*>
fn void a_script_body_is_not_the_draw_paths_body() @test
{
	three::Renderer* renderer = device::borrow(W, H);
	defer device::release();
	renderer.clear = { 0.0f, 0.0f, 0.0f, 1.0f };

	three::JsRuntime runtime;
	runtime.open(&renderer.pass, renderer)!!;
	defer runtime.close();

	three::RunResult built = runtime.run(`
		const scene = new three.Scene();
		const plane = new three.Mesh(
			new three.PlaneGeometry(8, 8),
			new three.ShaderMaterial({ fragment: "fn float3 shade(Surface s) { return float3(0.0, 0.0, 1.0); }" })
		);
		scene.add(plane);
		three.camera.frameAll();
		return 1;
	`);
	defer built.free();
	test::@check(built.ok, "the scripted scene built: %s", built.error);

	image::Image shot = renderer.capture()!!;
	defer shot.free();

	// The default look cannot be flat pure blue under these lights, and the
	// clear is black, so a frame that found the body is at least a quarter blue.
	sz blue = 0;
	for (sz at = 0; at + 2 < shot.pixels.len; at += 4)
	{
		if ((uint)(char)shot.pixels[at + 2] > 200 && (uint)(char)shot.pixels[at] < 40) blue++;
	}
	test::@check(blue > (sz)W * H / 4,
		"the body's flat blue is in the frame: %d of %d pixels", blue, W * H);
}
