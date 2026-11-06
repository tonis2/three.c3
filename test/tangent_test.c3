<*
 A mesh's own TANGENT stream, and the normal map being read in the frame it was
 baked in.

	`c3c test --trust=full --test-noleak --test-filter three_tests::tangents`

 `test/fixtures/tangents.glb` is three unit planes facing +z, all wearing the same
 normal map — a flat tilt of 45 degrees toward +x in tangent space — with
 `u` running along +x. They differ only in the tangent they carry:

 - `float` has TANGENT as float32, `(+1, 0, 0, +1)`: the direction `u` increases
   in, which is what glTF says the map's red channel is measured along.
 - `bytes` has the same attribute stored as normalized signed bytes under
   `KHR_mesh_quantization`, and pointing the other way, `(-127, 0, 0, +127)`.
 - `bare` has no TANGENT at all, so its map is read in the frame the fragment stage
   rebuilds from derivatives — which has to come out where the baked one does.

 So with a light 45 degrees off the normal toward +x, the mapped normal of the
 first lands on the light and the second lands 90 degrees from it. That is the
 whole measurement: bright against dark, with nothing to compare to but the other
 plane. It fails if the stream is not read, if the bytes are read as the bits of a
 float, if the sign is dropped on the way, or if the shader never looks at it.
*>
module three_tests::tangents;

import three;
import three_tests::device;
import vk;
import image;
import std::core::test;

const uint W = 120;
const uint H = 90;
const String FIXTURE = "test/fixtures/tangents.glb";

// Where the three planes' centres land in a 120x90 frame, looking at them straight
// on from five metres: `float` on the left, `bare` between, `bytes` on the right.
const uint LEFT   = 38;
const uint MIDDLE = 62;
const uint RIGHT  = 86;
const uint ROW    = 45;

macro @with_js(; @body(three::JsRuntime* run, three::Renderer* renderer))
{
	three::Renderer* renderer = device::borrow(W, H);
	defer device::release();

	three::JsRuntime runtime;
	runtime.open(&renderer.pass, renderer)!!;
	defer runtime.close();

	@body(&runtime, renderer);
}

// The red channel at one pixel of the frame. The planes are white and the light is
// white, so any of the three would do.
fn uint pixel(three::Renderer* renderer, uint x, uint y)
{
	image::Image shot = renderer.capture()!!;
	defer shot.free();
	sz bpp = shot.bytes_per_pixel();
	return shot.pixels[((sz)y * (sz)shot.width + (sz)x) * bpp];
}

<*
 Both encodings come off the file as tangents, and neither is dropped.

 Read off the uploaded mesh rather than the picture, so this is the half that says
 the stream arrived and the picture below says what it did there.
*>
fn void the_loader_reads_a_tangent_at_either_width() @test
{
	three::Renderer* renderer = device::borrow(W, H);
	defer device::release();

	// Placed, which is what puts the meshes on the device: a loaded file is read
	// lazily and a mesh nothing draws has no stream to look at.
	renderer.pass.load(&renderer.gpu, FIXTURE)!!;
	three::AssetId id   = renderer.pass.assets.load(&renderer.gpu, FIXTURE)!!;
	three::Asset* asset = renderer.pass.assets.slot(id);
	test::@check(asset.meshes.len() == 3, "the fixture has three planes, got %d", asset.meshes.len());
	foreach (i, &mesh : asset.meshes)
	{
		// Index 2 is the plane with none.
		test::@check(mesh.has_tangents == (i != 2), "mesh %d: has_tangents is %s", i, mesh.has_tangents);
		if (!mesh.has_tangents) continue;
		test::@check(mesh.tangents.size == 4 * 16, "and it is four float4s on the device, got %d bytes", mesh.tangents.size);
	}
}

<*
 The file's tangent decides which way the map tilts the surface.

 Bright on the left, where `u`'s own direction is the tangent; dark on the right,
 where the quantized tangent points the other way. The pixels are read at the
 centre of each plane.
*>
fn void the_file_tangent_decides_which_way_the_map_tilts() @test
{
	@with_js(; three::JsRuntime* run, three::Renderer* renderer)
	{
		three::RunResult result = run.run(
			`const scene = new three.Scene();
			three.light.set([0.7071, 0, 0.7071], 0);
			const asset = three.load('test/fixtures/tangents.glb');
			scene.add(asset.instantiate('t', { materials: true }));
			three.camera.lookAt(0, 0, 0);
			three.camera.orbit(0, 0, 5);
			return 'built';`
		);
		defer result.free();
		test::@check(result.ok, "the scene was built: %s", result.error);

		uint along    = pixel(renderer, LEFT, ROW);
		uint against  = pixel(renderer, RIGHT, ROW);
		test::@check(
			along > 200,
			"the map tilts toward the light along the file's tangent, got %d",
			along
		);
		test::@check(
			against < 40,
			"and away from it along the quantized one that points the other way, got %d",
			against
		);
	};
}

<*
 A mesh with no tangent is mapped in the frame the fragment stage builds, and that
 frame agrees with the baked one.

 The middle plane carries none. Its map tilts toward +u as the left one's does, so
 it has to be as bright as it — and it was not, before the frame's cross products
 were ordered for a framebuffer whose y grows downward: both axes came out
 negated and it was as dark as the plane tangent'd the wrong way.
*>
fn void the_derived_frame_tilts_toward_u_like_the_baked_one() @test
{
	@with_js(; three::JsRuntime* run, three::Renderer* renderer)
	{
		three::RunResult result = run.run(
			`const scene = new three.Scene();
			three.light.set([0.7071, 0, 0.7071], 0);
			const asset = three.load('test/fixtures/tangents.glb');
			scene.add(asset.instantiate('t', { materials: true }));
			three.camera.lookAt(0, 0, 0);
			three.camera.orbit(0, 0, 5);
			return 'built';`
		);
		defer result.free();
		test::@check(result.ok, "the scene was built: %s", result.error);

		uint baked   = pixel(renderer, LEFT, ROW);
		uint derived = pixel(renderer, MIDDLE, ROW);
		test::@check(baked > 200, "the baked frame is lit along +u, got %d", baked);
		test::@check(derived > 200, "and so is the derived one, got %d", derived);
	};
}

<*
 The same for green, on a mesh of each uv convention.

 A map tilted toward +y in tangent space has to light a surface toward +y when the
 surface's bitangent points up. On a glTF plane v runs down the image, so the
 bitangent is the direction v decreases in; on a generated plane v runs up and it
 is the direction v increases in. Both are read off the fragment stage's frame,
 and a sign slip in either puts the bump on the wrong side of every pebble.
*>
fn void the_derived_frame_tilts_toward_v_on_both_uv_conventions() @test
{
	@with_js(; three::JsRuntime* run, three::Renderer* renderer)
	{
		three::RunResult result = run.run(
			`const scene = new three.Scene();
			three.light.set([0, 0.7071, 0.7071], 0);
			const px = new Uint8Array(4 * 4 * 4);
			for (let i = 0; i < 16; i++) {
				px[i * 4] = 128; px[i * 4 + 1] = 218; px[i * 4 + 2] = 218; px[i * 4 + 3] = 255;
			}
			const tilt = new three.DataTexture(px, 4, 4, { colorSpace: three.LinearSRGBColorSpace });

			// The file's own material is shared by its three planes, so the map is
			// put on the one with no tangent and the other two are not looked at.
			const asset = three.load('test/fixtures/tangents.glb');
			const root = asset.instantiate('t', { materials: true });
			scene.add(root);
			root.getObjectByName('bare').material.normalMap = tilt;

			// A generated plane, three.js's convention, a little to one side.
			const made = new three.Mesh(new three.PlaneGeometry(1, 1), new three.MeshLambertMaterial({ normalMap: tilt }));
			made.position.set(0, -1.5, 0);
			scene.add(made);

			three.camera.lookAt(0, -0.75, 0);
			three.camera.orbit(0, 0, 6);
			return 'built';`
		);
		defer result.free();
		test::@check(result.ok, "the scene was built: %s", result.error);

		image::Image shot = renderer.capture()!!;
		defer shot.free();
		sz bpp = shot.bytes_per_pixel();
		// From six metres the row of three planes is at y = 30, the bare one
		// among them at x = 60, and the generated plane is below it at y = 60.
		uint glb  = shot.pixels[((sz)30 * (sz)shot.width + 60) * bpp];
		uint made = shot.pixels[((sz)60 * (sz)shot.width + 60) * bpp];
		test::@check(glb > 200, "a glTF plane's map tilts toward +y with its bitangent, got %d", glb);
		test::@check(made > 150, "and a generated plane's does the same, got %d", made);
	};
}
