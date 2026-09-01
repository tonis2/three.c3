<*
 The three things a scene sits in: the depth range, the colour behind it, and
 which faces of a surface exist.

	`c3c test --trust=full --test-noleak --test-filter three_tests::environment`

 **The question this suite answers:** all three of these were decided by the
 host and invisible to the script, and all three of them were wrong for the
 town-square scene in the same way — not by producing a bad picture, but by
 producing a picture with something missing from it and no way to ask why.

 A far plane derived from the orbit distance alone deleted the sky at some zoom
 levels and not others. A clear colour fixed at near-black put a night sky behind
 a daylight scene, and the only way round it was to build a sky out of geometry.
 A cull mode fixed at back-faces made a sphere invisible from inside, so that
 geometry had to be five inward-facing planes rather than a dome.

 The three checks that matter most are the ones that render: `the_frame_is_cleared`
 `_to_the_background_that_was_set`, `the_far_plane_reaches_the_scene_it_was_shown`
 and `backside_is_what_makes_a_dome_visible_from_inside`. Everything else here
 confirms a number came back; those three confirm a pixel changed.
*>
module three_tests::environment;

import three;
import vk;
import std::core::test;
import std::math;
import image;

<*
 A runtime with a headless device, and the renderer beside it.

 The renderer is handed to the body as well as to the runtime, unlike
 `bounds_test`'s harness, because half of this suite is about pixels: `capture`
 lives on the renderer and the clear colour it uses is a field on it.
*>
macro @with_render(; @body(three::JsRuntime* run, three::Renderer* renderer))
{
	vk::Instance instance = three::create_instance(false, headless: true)!!;
	defer instance.free();

	three::Renderer renderer;
	renderer.init(instance, (vk::SurfaceKHR)null, 120, 90)!!;
	defer renderer.free();

	renderer.pass.init(&renderer.gpu, &renderer.target)!!;

	three::JsRuntime runtime;
	runtime.open(&renderer.pass, &renderer)!!;
	defer runtime.close();

	@body(&runtime, &renderer);
}

<*
 The pixel in the middle of the rendered image, as three bytes.

 The middle rather than a corner, because that is where a camera aimed at the
 origin puts whatever it is looking at — and because a corner would also answer
 for the background in the one test where the background is not the subject.
*>
fn char[3] centre_pixel(image::Image* img)
{
	sz bpp = img.bytes_per_pixel();
	sz at = ((sz)(img.height / 2) * (sz)img.width + (sz)(img.width / 2)) * bpp;
	return { img.pixels[at], img.pixels[at + 1], img.pixels[at + 2] };
}

// ============================================================================
// The depth range
// ============================================================================

fn void the_camera_reports_the_planes_it_derived() @test
{
	@with_render(; three::JsRuntime* run, three::Renderer* renderer)
	{
		three::RunResult result = run.run(`
			new three.Scene();
			three.camera.orbit(0, 0, 10);
			const { near, far } = three.camera;
			return [near > 0, far > near, near < 1, far >= 80];
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(
			result.value == "[true,true,true,true]",
			"an empty scene at distance 10 derives a near under 1 and a far of at least 8x, got '%s'",
			result.value
		);
	};
}

<*
 The regression this phase exists for.

 The town square's sky was a shell about 190 units from the origin and the
 camera orbited between 24 and 40. At 40 it rendered; at 26 the sky vanished,
 because the far plane was `distance * 8` and had followed the camera down to
 208 and then to 160. What that looks like is a skybox that works sometimes,
 which reads as a winding bug rather than as a camera setting — and the first
 diagnosis was wrong twice before `Camera.derive_planes` was read.

 The numbers here are the same shape and the arithmetic is spelled out: a 400-unit
 cube has a bounding sphere of radius `sqrt(3) * 200`, about 346, so a camera 20
 units from its centre needs to see 366 units to see all of it. `distance * 8` is
 160 and would clip 200 units of it away — and cull it too, which is why
 `culledLastFrame` is asserted on rather than only the plane.
*>
fn void the_far_plane_reaches_the_scene_it_was_shown() @test
{
	@with_render(; three::JsRuntime* run, three::Renderer* renderer)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			scene.add(new three.Mesh(new three.BoxGeometry(400, 400, 400)));
			three.camera.orbit(0, 0, 20);
			three.render(scene);
			return [three.camera.far, scene.stats().culledLastFrame];
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(
			result.value.contains("366") || result.value.contains("367"),
			"the far plane clears the far side of a 400-unit box seen from 20 (about 366), got '%s'",
			result.value
		);
		test::@check(
			result.value.ends_with(",0]"),
			"nothing is culled when the far plane reaches the geometry, got '%s'",
			result.value
		);
	};
}

<*
 The floor is still the floor.

 A scene smaller than the orbit distance must not pull the far plane in behind
 it — `derive_planes` takes the larger of the two, and a test that only proved
 the scene-derived half would pass on an implementation that had replaced the
 multiple rather than floored it.
*>
fn void a_small_scene_does_not_shrink_the_far_plane() @test
{
	@with_render(; three::JsRuntime* run, three::Renderer* renderer)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			scene.add(new three.Mesh(new three.BoxGeometry(1, 1, 1)));
			three.camera.orbit(0, 0, 10);
			return three.camera.far;
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == "80", "a one-unit box at distance 10 still derives 8x, got '%s'", result.value);
	};
}

<*
 A derived value refuses assignment out loud.

 Not a style point. A script is not evaluated in strict mode, so a getter with no
 setter accepts `camera.far = 500` and discards it silently — the same failure
 mode `an_undeclared_uniform_cannot_be_assigned` was written to catch, and
 exactly the one that makes an invisible plane cost a session.
*>
fn void writing_a_derived_plane_says_which_verb_moves_it() @test
{
	@with_render(; three::JsRuntime* run, three::Renderer* renderer)
	{
		three::RunResult result = run.run(`
			new three.Scene();
			three.camera.orbit(0, 0, 10);
			const before = three.camera.far;
			let said = '';
			try { three.camera.far = 500; } catch (e) { said = e.message; }
			return [said.includes('derived'), said.includes('frameAll'), three.camera.far === before];
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(
			result.value == "[true,true,true]",
			"assigning far throws, names the verb that does move it, and changes nothing, got '%s'",
			result.value
		);
	};
}

fn void the_turntable_angles_refuse_assignment_too() @test
{
	@with_render(; three::JsRuntime* run, three::Renderer* renderer)
	{
		three::RunResult result = run.run(`
			new three.Scene();
			three.camera.orbit(10, 20, 30);
			const said = [];
			for (const k of ['yaw', 'pitch', 'distance']) {
				try { three.camera[k] = 1; said.push(''); } catch (e) { said.push(e.message); }
			}
			return said.map(m => m.includes('orbit'));
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(
			result.value == "[true,true,true]",
			"yaw, pitch and distance each name orbit() rather than accepting a write, got '%s'",
			result.value
		);
	};
}

<*
 The target is live, unlike everything else `cameraGet` answers with.

 `camera.target` used to hand back a detached Vector3, so `three.camera.target.y = 2`
 edited a copy and moved nothing. That is the same silence as the setters above
 and is fixed the other way round — by making the vector real — because there is
 already a verb behind it and `mesh.position` sets the precedent.
*>
fn void the_camera_target_is_a_live_vector() @test
{
	@with_render(; three::JsRuntime* run, three::Renderer* renderer)
	{
		three::RunResult result = run.run(`
			new three.Scene();
			three.camera.lookAt(0, 0, 0);
			three.camera.target.y = 2;
			const a = three.camera.target.toArray();
			three.camera.target = { x: 1, y: 1, z: 1 };
			return [a, three.camera.target.toArray()];
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(
			result.value == "[[0,2,0],[1,1,1]]",
			"writing a component and assigning the whole vector both move the target, got '%s'",
			result.value
		);
	};
}

// ============================================================================
// The colour behind it
// ============================================================================

fn void the_background_round_trips_as_components() @test
{
	@with_render(; three::JsRuntime* run, three::Renderer* renderer)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			scene.background = [0.25, 0.5, 0.75];
			return scene.background.map(v => Math.round(v * 100));
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == "[25,50,75]", "the components come back as they went in, got '%s'", result.value);
	};
}

<*
 A hex value is divided by 255 and not de-gamma'd.

 The same contract `mesh.color` has, and it is asserted here rather than assumed
 because two doors that spell one conversion differently is the drift that
 renders fine and is wrong. 0x8040c0 is 128, 64, 192.
*>
fn void a_hex_background_is_divided_by_255() @test
{
	@with_render(; three::JsRuntime* run, three::Renderer* renderer)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			scene.background = 0x8040c0;
			return scene.background.map(v => Math.round(v * 255));
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == "[128,64,192]", "0x8040c0 is 128, 64, 192, got '%s'", result.value);
	};
}

<*
 `scene.background = null` restores exactly the constant the renderer starts on.

 Compared against `DEFAULT_CLEAR` itself rather than against three numbers typed
 into this file, because the point of the check is that the prelude's copy and
 the host's have not drifted — and a third copy here would drift with them.
*>
fn void the_default_background_is_the_renderer_clear() @test
{
	@with_render(; three::JsRuntime* run, three::Renderer* renderer)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			scene.background = 0xff0000;
			scene.background = null;
			return scene.background.map(v => Math.round(v * 1000));
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);

		String expected = string::tformat(
			"[%d,%d,%d]",
			(int)math::round(three::DEFAULT_CLEAR[0] * 1000.0f),
			(int)math::round(three::DEFAULT_CLEAR[1] * 1000.0f),
			(int)math::round(three::DEFAULT_CLEAR[2] * 1000.0f)
		);
		test::@check(
			result.value == expected,
			"null restores DEFAULT_CLEAR — expected '%s', got '%s'",
			expected,
			result.value
		);
	};
}

<*
 A new Scene starts on the default, unlike materials and assets, which survive.

 Three.js's `background` is a property of the Scene, so a fresh one having the
 last one's sky would be the half-match `plan.md` §4 rules out.
*>
fn void a_new_scene_starts_on_the_default_background() @test
{
	@with_render(; three::JsRuntime* run, three::Renderer* renderer)
	{
		three::RunResult result = run.run(`
			new three.Scene().background = [1, 0, 0];
			const fresh = new three.Scene();
			return fresh.background.map(v => Math.round(v * 255))[0] < 128;
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == "true", "the red did not survive the reset, got '%s'", result.value);
	};
}

<*
 A scene brings its background, its light and its shadow settings back with it.

 **The regression this exists for is a level that does not look like itself the
 second time.** These three used to be the renderer's alone and went back to
 their defaults on every `activate()`, so a game that swapped to a menu scene and
 back came home to the default sky, the default light and shadows switched off —
 a scene that had been set up correctly rendering wrongly, with nothing in the
 script to point at. They live on `Scene.look` now and the renderer keeps the
 live copy of whichever scene is on screen.

 The `fresh` half is the other side of it, and it is what stops the fix from
 becoming "the last scene's look leaks into the next one": a scene nobody has set
 up still starts on the defaults.

 Proved by injection: put `DEFAULT_CLEAR`, `DEFAULT_LIGHT` and
 `shadows.defaults()` back into `activate_scene` and everything after `fresh`
 comes back as the default rather than as what the first scene set.
*>
fn void a_scene_brings_its_look_back_when_activated() @test
{
	@with_render(; three::JsRuntime* run, three::Renderer* renderer)
	{
		three::RunResult result = run.run(`
			const first = new three.Scene();
			first.background = [1, 0, 0];
			three.light.set([0, 1, 0], 0.9);
			three.light.shadow.enabled = true;
			three.light.shadow.size = 512;

			// A second scene is a second world, and it starts on the defaults
			// rather than on the first one's look.
			const second = new three.Scene();
			const fresh = [
				second.background.map(v => Math.round(v * 255))[0] < 128,
				three.light.shadow.enabled,
				three.light.shadow.size,
			];

			first.activate();
			const d = three.light.direction;
			return {
				fresh,
				background: first.background.map(v => Math.round(v * 255)),
				direction: [d.x, d.y, d.z],
				ambient: Math.round(three.light.ambient * 100),
				shadow: [three.light.shadow.enabled, three.light.shadow.size],
			};
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(
			result.value == `{"fresh":[true,false,2048],"background":[255,0,0],"direction":[0,1,0],"ambient":90,"shadow":[true,512]}`,
			"the first scene's look came back with it, got '%s'",
			result.value
		);
	};
}

<*
 Setting the background of a scene nobody is looking at paints nothing.

 **The regression this exists for is the level being built repainting the level
 on screen.** `scene.background` names a scene in the script, and it used to
 write the renderer's one clear colour whichever scene it was spelled on — so
 dressing the next level while the current one runs changed the sky the player
 was under, one frame after the assignment and with nothing to say why.

 Proved by injection: drop the `scene == self.pass.scene` test in
 `JsRuntime.set_clear` and the middle pixel comes back red.
*>
fn void a_background_set_on_an_inactive_scene_does_not_paint_the_frame() @test
{
	@with_render(; three::JsRuntime* run, three::Renderer* renderer)
	{
		three::RunResult result = run.run(`
			const first = new three.Scene();
			const second = new three.Scene();
			// first is not the scene being rendered.
			first.background = 0xff0000;
			second.background = 0x2060a0;
			three.render(second);
			return first.background.map(v => Math.round(v * 255));
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == "[255,0,0]", "the inactive scene kept its own red, got '%s'", result.value);

		image::Image shot = renderer.capture()!!;
		defer shot.free();

		char[3] px = centre_pixel(&shot);
		test::@check(
			math::abs((int)px[0] - 0x20) <= 1 && math::abs((int)px[1] - 0x60) <= 1
				&& math::abs((int)px[2] - 0xa0) <= 1,
			"the frame is the active scene's colour, got %d, %d, %d", px[0], px[1], px[2]
		);
	};
}

<*
 The number reached the pixel.

 Everything above proves a value round-tripped through the host. This is the one
 that proves the host does anything with it: an empty scene is nothing but its
 clear colour, so the middle pixel *is* the background.
*>
fn void the_frame_is_cleared_to_the_background_that_was_set() @test
{
	@with_render(; three::JsRuntime* run, three::Renderer* renderer)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			scene.background = 0x2060a0;
			three.render(scene);
			return 1;
		`);
		defer result.free();
		test::@check(result.ok, "the script succeeded: %s", result.error);

		image::Image shot = renderer.capture()!!;
		defer shot.free();

		char[3] px = centre_pixel(&shot);
		// Within one of 0x20, 0x60, 0xa0 — the clear goes through a float and
		// back, and an exact compare would be asserting on the rounding.
		test::@check(
			math::abs((int)px[0] - 0x20) <= 1 && math::abs((int)px[1] - 0x60) <= 1
				&& math::abs((int)px[2] - 0xa0) <= 1,
			"an empty scene is its background — expected about 32,96,160, got %d,%d,%d",
			(int)px[0], (int)px[1], (int)px[2]
		);
	};
}

// ============================================================================
// Which faces exist
// ============================================================================

// A fragment body that ignores everything and answers with one colour, so a
// pixel test is about which faces were drawn and not about lighting.
const String FLAT_RED = `float3 shade(Surface s) { return float3(1.0, 0.0, 0.0); }`;

fn void a_material_keeps_its_front_faces_unless_told_otherwise() @test
{
	@with_render(; three::JsRuntime* run, three::Renderer* renderer)
	{
		three::RunResult result = run.run(`
			new three.Scene();
			const m = new three.ShaderMaterial({ fragment: 'float3 shade(Surface s) { return float3(1, 0, 0); }' });
			return [m.side === three.FrontSide, three.FrontSide, three.BackSide, three.DoubleSide];
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(
			result.value == "[true,0,1,2]",
			"FrontSide is the default and the constants are Three.js's own numbers, got '%s'",
			result.value
		);
	};
}

fn void an_unknown_side_is_refused_by_name() @test
{
	@with_render(; three::JsRuntime* run, three::Renderer* renderer)
	{
		three::RunResult result = run.run(`
			new three.Scene();
			const body = 'float3 shade(Surface s) { return float3(1, 0, 0); }';
			const said = [];
			try { new three.ShaderMaterial({ fragment: body, side: 7 }); } catch (e) { said.push(e.message); }
			const m = new three.ShaderMaterial({ fragment: body });
			try { m.side = 'back'; } catch (e) { said.push(e.message); }
			return [said.length, said.every(s => s.includes('three.BackSide')), m.side];
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(
			result.value == "[2,true,0]",
			"both doors refuse an unknown side by name and leave the material alone, got '%s'",
			result.value
		);
	};
}

<*
 The check this whole third of the phase exists for.

 A camera *inside* a sphere sees only its back faces. Under the default cull mode
 that is not a dark dome, it is no dome at all — the middle pixel is the
 background — and scaling the sphere by -1 does not help, because a negative
 scale does not reverse a triangle's winding. That is why the town square's sky
 ended up as five inward-facing planes.

 Two renders, one material, one line between them. If `cull_for_side` had the
 inversion the wrong way round — `BackSide` culling the back faces — this test
 would fail in the second half rather than pass in a way that looked plausible.
*>
fn void backside_is_what_makes_a_dome_visible_from_inside() @test
{
	@with_render(; three::JsRuntime* run, three::Renderer* renderer)
	{
		three::RunResult first = run.run(`
			const scene = new three.Scene();
			scene.background = 0x000000;
			globalThis.sky = new three.ShaderMaterial({
				fragment: 'float3 shade(Surface s) { return float3(1, 0, 0); }',
			});
			scene.add(new three.Mesh(new three.SphereGeometry(10, 32, 16), globalThis.sky));
			// Inside it: the eye is 4 units from the centre of a sphere of radius 10.
			three.camera.lookAt(0, 0, 0);
			three.camera.orbit(0, 0, 4);
			three.render(scene);
			return 1;
		`);
		defer first.free();
		test::@check(first.ok, "the first script succeeded: %s", first.error);

		image::Image front = renderer.capture()!!;
		defer front.free();
		char[3] outside_in = centre_pixel(&front);
		test::@check(
			outside_in[0] < 64,
			"under FrontSide a sphere seen from inside draws nothing — expected the background, got %d,%d,%d",
			(int)outside_in[0], (int)outside_in[1], (int)outside_in[2]
		);

		three::RunResult second = run.run(`
			globalThis.sky.side = three.BackSide;
			three.render();
			return globalThis.sky.side;
		`);
		defer second.free();
		test::@check(second.ok, "the second script succeeded: %s", second.error);
		test::@check(second.value == "1", "the side stuck, got '%s'", second.value);

		image::Image back = renderer.capture()!!;
		defer back.free();
		char[3] inside_out = centre_pixel(&back);
		test::@check(
			inside_out[0] > 200 && inside_out[1] < 64,
			"under BackSide the same sphere is red from inside, got %d,%d,%d",
			(int)inside_out[0], (int)inside_out[1], (int)inside_out[2]
		);
	};
}

<*
 A side costs neither a compile nor a pipeline.

 The cull mode is dynamic state — `vk::cmdSetCullMode`, once per bucket — so
 changing a material's side writes a field and nothing else. That is what makes
 it safe to flip inside an animation callback, which is where a script would want
 to: under the first version of this, which baked the cull mode into the
 pipeline, twelve assignments cost two Slang compiles and two `VkPipeline`
 builds, and a frame that first asked for a new side would drop about 17 ms.

 Both counters are asserted because they fail differently. `compiles` rising
 means the pipeline cache has gone back to keying SPIR-V on the render state;
 `builds` rising means the cull mode has gone back into `PipelineState`. Neither
 shows up in a picture — the render is correct either way, just slower — so a
 pixel test could not catch this and wall time would be flaky.
*>
fn void flipping_a_side_costs_no_compile_and_no_pipeline() @test
{
	// `compiles` means Slang, not the disk cache — see
	// `the_pipeline_cache_skips_the_compile` in shader_test.c3 for the convention.
	three::shader_cache_set_dir("");

	@with_render(; three::JsRuntime* run, three::Renderer* renderer)
	{
		three::RunResult made = run.run(`
			new three.Scene();
			globalThis.m = new three.ShaderMaterial({
				fragment: 'float3 shade(Surface s) { return float3(1, 0, 0); }',
			});
			return 1;
		`);
		defer made.free();
		test::@check(made.ok, "the script succeeded: %s", made.error);

		uint compiles = renderer.pass.pipelines.compiles;
		uint builds = renderer.pass.pipelines.builds;

		three::RunResult flip = run.run(`
			for (let i = 0; i < 4; i++) {
				globalThis.m.side = three.BackSide;
				globalThis.m.side = three.DoubleSide;
				globalThis.m.side = three.FrontSide;
			}
			return globalThis.m.side;
		`);
		defer flip.free();
		test::@check(flip.ok, "the flipping script succeeded: %s", flip.error);
		test::@check(flip.value == "0", "it ended on FrontSide, got '%s'", flip.value);

		test::@check(
			renderer.pass.pipelines.compiles == compiles,
			"Slang was not called again for a side change, got %d more",
			renderer.pass.pipelines.compiles - compiles
		);
		test::@check(
			renderer.pass.pipelines.builds == builds,
			"and no pipeline was built for one either, got %d more",
			renderer.pass.pipelines.builds - builds
		);
	};
}

// ============================================================================
// The light
// ============================================================================

<*
 The light reaches the shader, asserted on pixels rather than on a number
 coming back.

 One plane facing +z, filling the frame, with the ambient floor at zero so the
 direction is the only thing deciding anything. Point the light at the plane and
 it is lit; point it away and it is black. A getter that answered correctly
 while `FrameBlock` carried the old value would pass every round-trip check and
 fail this one, which is the whole reason it renders.
*>
fn void the_light_direction_reaches_the_shader() @test
{
	@with_render(; three::JsRuntime* run, three::Renderer* renderer)
	{
		three::RunResult result = run.run(`
			globalThis.scene = new three.Scene();
			scene.add(new three.Mesh(new three.PlaneGeometry(2, 2)));
			three.camera.frameAll();
			three.light.ambient = 0;
			three.light.direction = [0, 0, 1];
			three.render(scene);
			return 1;
		`);
		defer result.free();
		test::@check(result.ok, "the script succeeded: %s", result.error);

		image::Image lit = renderer.capture()!!;
		defer lit.free();
		char[3] front = centre_pixel(&lit);

		three::RunResult away = run.run(`
			three.light.direction = [0, 0, -1];
			three.render(scene);
			return 1;
		`);
		defer away.free();
		test::@check(away.ok, "the second script succeeded: %s", away.error);

		image::Image dark = renderer.capture()!!;
		defer dark.free();
		char[3] back = centre_pixel(&dark);

		test::@check(front[0] > 150,
			"a plane facing the light should be bright, got %d,%d,%d", (int)front[0], (int)front[1], (int)front[2]);
		test::@check(back[0] < 10,
			"turned away from it with no ambient it should be black, got %d,%d,%d", (int)back[0], (int)back[1], (int)back[2]);
	};
}

<*
 The ambient floor is the darkest a face gets, and at 1 it is the only thing
 that decides anything.

 The half that catches a binding which wrote the direction and dropped `w` —
 which would still pass the check above, because that one only ever sets
 ambient to zero.
*>
fn void the_ambient_floor_is_what_a_face_turned_away_gets() @test
{
	@with_render(; three::JsRuntime* run, three::Renderer* renderer)
	{
		three::RunResult result = run.run(`
			globalThis.scene = new three.Scene();
			scene.add(new three.Mesh(new three.PlaneGeometry(2, 2)));
			three.camera.frameAll();
			// Pointing away, so nothing but the floor can be reaching the face.
			three.light.set([0, 0, -1], 1);
			three.render(scene);
			return 1;
		`);
		defer result.free();
		test::@check(result.ok, "the script succeeded: %s", result.error);

		image::Image full = renderer.capture()!!;
		defer full.free();
		char[3] px = centre_pixel(&full);

		// PRIMITIVE_COLOR is 0.78, 0.78, 0.80 in sRGB, and at ambient 1 the
		// shading term is exactly 1, so the plane is that colour and no other.
		test::@check(math::abs((int)px[0] - 199) <= 2 && math::abs((int)px[2] - 204) <= 2,
			"at ambient 1 a face turned away is still its own colour — expected about 199,199,204, got %d,%d,%d",
			(int)px[0], (int)px[1], (int)px[2]
		);
	};
}

<*
 The direction is not normalized on the way in, and the vector it hands back is
 live.

 Two separate traps in one check. A binding that normalized would answer with
 numbers the script never wrote, and `three.light.direction.y = -1` on a detached
 copy would silently do nothing — the same failure `three.camera` refuses by
 throwing on assignment rather than by pretending.
*>
fn void the_light_direction_round_trips_and_writes_through() @test
{
	@with_render(; three::JsRuntime* run, three::Renderer* renderer)
	{
		three::RunResult result = run.run(`
			three.light.direction = [0, 4, 0];
			const kept = [three.light.direction.x, three.light.direction.y, three.light.direction.z];
			three.light.direction.y = -2;
			const live = three.light.direction.y;
			three.light.ambient = 0.4;
			return { kept, live, ambient: three.light.ambient };
		`);
		defer result.free();
		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value.contains(`"kept":[0,4,0]`),
			"a direction of [0,4,0] should come back as [0,4,0], not normalized: %s", result.value);
		test::@check(result.value.contains(`"live":-2`),
			"assigning through the returned Vector3 should reach the host: %s", result.value);
		test::@check(result.value.contains(`"ambient":0.4`),
			"the ambient floor should round trip: %s", result.value);
	};
}

<*
 A zero direction is refused by name rather than rendering a NaN.

 `normalize` of a zero vector is a NaN, the lambert term is a NaN with it, and
 what reaches the screen is black or undefined depending on the driver — a
 failure with nothing anywhere pointing back at the light.
*>
fn void a_light_with_no_direction_is_refused() @test
{
	@with_render(; three::JsRuntime* run, three::Renderer* renderer)
	{
		three::RunResult result = run.run(`
			try { three.light.direction = [0, 0, 0]; return "accepted"; }
			catch (e) { return e.message; }
		`);
		defer result.free();
		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value.contains("cannot be zero"),
			"a zero direction should be refused and say why, got '%s'", result.value);
	};
}

<*
 A new Scene puts the light back, exactly as it puts the background back.

 For the same reason, which is worth having a check for rather than a comment:
 a script that sets a light and a script that does not must render the same
 first frame, or "it looked right when I ran it on its own" becomes something
 people say about this engine.
*>
fn void a_new_scene_restores_the_default_light() @test
{
	@with_render(; three::JsRuntime* run, three::Renderer* renderer)
	{
		three::RunResult result = run.run(`
			three.light.set([0, 0, -1], 0.9);
			const changed = three.light.ambient;
			new three.Scene();
			return { changed, back: three.light.ambient, dir: three.light.direction.y };
		`);
		defer result.free();
		test::@check(result.ok, "the script succeeded: %s", result.error);
		// 0.89 rather than 0.9: the host keeps a float, so 0.9 comes back as
		// 0.8999999761581421 and an exact match would be asserting on binary32.
		test::@check(result.value.contains(`"changed":0.89`), "the ambient was set: %s", result.value);
		test::@check(result.value.contains(`"back":0.25`),
			"a new Scene should restore DEFAULT_LIGHT's ambient of 0.25: %s", result.value);
		test::@check(result.value.contains(`"dir":0.8`),
			"and its direction: %s", result.value);
	};
}

// ============================================================================
// The light list
// ============================================================================

<*
 A second light lights what the first one cannot.

 **The regression this exists for is a shading loop that runs once.** Everything
 about a list of lights can be right — the slot, the getter, the frame block —
 while the shader still reads `lights[0]` and nothing else, and the symptom is a
 scene that is exactly as lit as it was before the list existed. Only a pixel can
 tell the difference.

 The sun is pointed *away* from the plane and the ambient floor is zero, so every
 photon in the frame has to have come through slot one.

 Proved by injection: change the loop bound in `lambert` from `count` to `1u` and
 the plane comes back black.
*>
fn void a_second_light_lights_what_the_first_cannot() @test
{
	@with_render(; three::JsRuntime* run, three::Renderer* renderer)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			scene.add(new three.Mesh(new three.PlaneGeometry(2, 2)));
			three.camera.frameAll();
			three.light.ambient = 0;
			three.light.direction = [0, 0, -1];
			three.render(scene);
			return three.lights.length;
		`);
		defer result.free();
		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == "1", "one light so far: %s", result.value);

		image::Image dark = renderer.capture()!!;
		defer dark.free();
		char[3] unlit = centre_pixel(&dark);

		three::RunResult second = run.run(`
			three.lights.add([0, 0, 1]);
			three.render(three.scene);
			return three.lights.length;
		`);
		defer second.free();
		test::@check(second.ok, "the second script succeeded: %s", second.error);
		test::@check(second.value == "2", "and two after the add: %s", second.value);

		image::Image lit = renderer.capture()!!;
		defer lit.free();
		char[3] filled = centre_pixel(&lit);

		test::@check(unlit[0] < 10,
			"with the sun turned away and no floor the plane is black, got %d", (int)unlit[0]);
		test::@check(filled[0] > 150,
			"and the second light lights it, got %d,%d,%d",
			(int)filled[0], (int)filled[1], (int)filled[2]);
	};
}

<*
 Every light carries its own colour, and they add.

 **The regression this exists for is a colour that is really one white factor.**
 A `Light.color` written into the frame block but read as a scalar — or read from
 slot zero for every light — renders a plausible picture: lit is lit. Two lights
 of two different colours on one surface is the arrangement where a single factor
 cannot produce the right answer at all.

 Red from the sun and blue from slot one, both square on to the plane, so the
 result is magenta and neither channel can have come from the other light.

 Proved by injection: read `lights[0].color` inside the loop instead of
 `lights[i].color` and the blue channel goes to the red one's value.
*>
fn void every_light_carries_its_own_colour() @test
{
	@with_render(; three::JsRuntime* run, three::Renderer* renderer)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			scene.add(new three.Mesh(new three.PlaneGeometry(2, 2)));
			three.camera.frameAll();
			three.light.ambient = 0;
			three.light.set([0, 0, 1]);
			three.light.color = [1, 0, 0];
			three.lights.add([0, 0, 1], 0x0000ff);
			three.render(scene);
			return { sun: three.light.color, fill: three.lights[1].color };
		`);
		defer result.free();
		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value.contains(`"sun":[1,0,0]`), "the sun reads back red: %s", result.value);
		test::@check(result.value.contains(`"fill":[0,0,1]`), "and the fill blue: %s", result.value);

		image::Image shot = renderer.capture()!!;
		defer shot.free();
		char[3] pixel = centre_pixel(&shot);

		test::@check(pixel[0] > 150 && pixel[2] > 150 && pixel[1] < 10,
			"two lights of two colours make magenta, got %d,%d,%d",
			(int)pixel[0], (int)pixel[1], (int)pixel[2]);
	};
}

<*
 An intensity of zero is how a light is turned off, which is the only way to turn
 the sun off.

 **The regression this exists for is an intensity the shader never multiplies
 in.** It reads back from the host either way, and a scene lit by one light at
 full strength looks entirely reasonable — so the check is a light whose intensity
 is the only thing standing between the frame and black.

 It is also the sentence `lightRemove` points at: slot zero cannot be removed
 because the shadow map is fitted around it, so "no sun" has to mean something.

 Proved by injection: drop the `* light.color.w` from `lambert` and the plane
 stays lit.
*>
fn void an_intensity_of_zero_turns_a_light_off() @test
{
	@with_render(; three::JsRuntime* run, three::Renderer* renderer)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			scene.add(new three.Mesh(new three.PlaneGeometry(2, 2)));
			three.camera.frameAll();
			three.light.ambient = 0;
			three.light.direction = [0, 0, 1];
			three.light.intensity = 0;
			three.render(scene);
			const refused = (() => {
				try { three.lights.remove(0); return "removed"; } catch (e) { return e.message; }
			})();
			return { intensity: three.light.intensity, refused };
		`);
		defer result.free();
		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value.contains(`"intensity":0`), "it reads back as zero: %s", result.value);
		test::@check(result.value.contains("cannot be removed"),
			"and removing the sun is refused, pointing at this: %s", result.value);

		image::Image shot = renderer.capture()!!;
		defer shot.free();
		char[3] pixel = centre_pixel(&shot);
		test::@check(pixel[0] < 10,
			"a light at zero intensity delivers nothing, got %d,%d,%d",
			(int)pixel[0], (int)pixel[1], (int)pixel[2]);
	};
}

<*
 The list is four slots long, a fifth is refused, and removing one closes the gap.

 **The regression this exists for is a fifth light that renders as nothing.** The
 frame block holds four; a script that added five and got no error would be
 describing a scene the renderer is not drawing, with nothing anywhere naming the
 light that went missing.

 The gap closing is the other half and is what makes `three.lights[i]` mean the
 i-th light rather than the i-th slot ever filled — `Array.prototype.splice`'s
 rule, and the one an index held across a remove has always had.

 Proved by injection: let `js_light_add` write past `MAX_LIGHTS` and the refusal
 becomes a buffer overrun instead of a message.
*>
fn void the_list_is_four_long_and_closes_its_gaps() @test
{
	@with_render(; three::JsRuntime* run, three::Renderer* renderer)
	{
		three::RunResult result = run.run(`
			three.lights.add([1, 0, 0], 0xff0000);
			three.lights.add([0, 1, 0], 0x00ff00);
			three.lights.add([0, 0, 1], 0x0000ff);
			const full = (() => {
				try { three.lights.add([1, 1, 1]); return "added"; } catch (e) { return e.message; }
			})();
			const before = three.lights.length;
			three.lights.remove(three.lights[1]);
			const colours = [...three.lights].map((l) => l.color);
			return { max: three.lights.max, before, full, after: three.lights.length, colours };
		`);
		defer result.free();
		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value.contains(`"max":4`), "four slots: %s", result.value);
		test::@check(result.value.contains(`"before":4`), "all four filled: %s", result.value);
		test::@check(result.value.contains("all of them are in use"),
			"a fifth is refused by name: %s", result.value);
		test::@check(result.value.contains(`"after":3`), "and removing one leaves three: %s", result.value);
		// The green one was slot 1; blue moves down into it rather than a hole
		// staying where it was.
		test::@check(result.value.contains(`"colours":[[1,1,1],[0,1,0],[0,0,1]]`),
			"the slots above the removed one moved down: %s", result.value);
	};
}

<*
 The whole list travels with the scene, not just the sun.

 **The regression this exists for is a `SceneLook` that carries light zero.**
 `activate()` restoring one light out of four is a level that comes back half lit,
 and it is exactly what a switch written before the list existed would do.

 Proved by injection: copy only `lights[0]` in `activate_scene` and `back` comes
 back as one light.
*>
fn void every_light_travels_with_the_scene() @test
{
	@with_render(; three::JsRuntime* run, three::Renderer* renderer)
	{
		three::RunResult result = run.run(`
			const first = new three.Scene();
			three.lights.add([1, 0, 0], 0xff0000, 0.5);
			const set = { count: three.lights.length, colour: three.lights[1].color };

			const second = new three.Scene();
			const fresh = three.lights.length;

			first.activate();
			return {
				set, fresh,
				back: three.lights.length,
				colour: three.lights[1].color,
				intensity: three.lights[1].intensity,
			};
		`);
		defer result.free();
		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value.contains(`"count":2`), "two lights were set: %s", result.value);
		test::@check(result.value.contains(`"fresh":1`),
			"a new scene starts on one: %s", result.value);
		test::@check(result.value.contains(`"back":2`),
			"and activating the first brings both back: %s", result.value);
		test::@check(result.value.contains(`"colour":[1,0,0]`),
			"with the colour it had: %s", result.value);
		test::@check(result.value.contains(`"intensity":0.5`),
			"and the strength: %s", result.value);
	};
}

// ============================================================================
// The specular term
// ============================================================================

<*
 `reflectance` is the switch on the highlight, and at zero there is not a small
 one.

 **The regression this exists for is every scene in this project quietly gaining
 a sheen.** Schlick's Fresnel climbs to 1 at a grazing angle whatever `f0` is, so
 a specular term written the obvious way puts a rim of light on every surface
 already authored against a Lambert renderer — a change nobody asked for, in every
 frame, that reads as "the lighting looks different now" rather than as a bug.
 Filament's `f90` is what collapses it, and this is what says so.

 A plane square on to both the camera and the light, so the centre fragment is
 the mirror direction and gets the whole lobe.

 Proved by injection: write the plain `f0 + (1 - f0) * pow(...)` Fresnel in
 `specular_light` and `off` stops matching `plain`.
*>
fn void reflectance_is_the_switch_on_the_highlight() @test
{
	@with_render(; three::JsRuntime* run, three::Renderer* renderer)
	{
		three::RunResult result = run.run(`
			globalThis.scene = new three.Scene();
			globalThis.material = new three.MeshLambertMaterial();
			scene.add(new three.Mesh(new three.PlaneGeometry(2, 2), material));
			// Square on, and the angle before the fit — a highlight is the one thing
			// here that depends on where the camera is, and frameAll fits against
			// whatever angle it finds.
			three.camera.orbit(0, 0);
			three.camera.frameAll();
			three.light.ambient = 0;
			three.light.direction = [0, 0, 1];
			three.render(scene);
			return material.reflectance;
		`);
		defer result.free();
		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == "0", "a material starts with no reflectance: %s", result.value);

		image::Image plain = renderer.capture()!!;
		defer plain.free();
		char[3] matte = centre_pixel(&plain);

		three::RunResult polished = run.run(`
			material.roughness = 0.1;
			material.reflectance = 1;
			three.render(scene);
			return [material.roughness, material.reflectance];
		`);
		defer polished.free();
		test::@check(polished.ok, "the second script succeeded: %s", polished.error);

		image::Image shiny = renderer.capture()!!;
		defer shiny.free();
		char[3] highlight = centre_pixel(&shiny);

		test::@check(highlight[0] > (int)matte[0] + 30,
			"reflectance puts a highlight on it: %d against %d", (int)highlight[0], (int)matte[0]);

		// And back to nothing, byte for byte — which is the half that says the term
		// is off rather than merely faint.
		three::RunResult off = run.run(`
			material.reflectance = 0;
			three.render(scene);
			return 1;
		`);
		defer off.free();
		test::@check(off.ok, "the third script succeeded: %s", off.error);

		image::Image again = renderer.capture()!!;
		defer again.free();
		char[3] back = centre_pixel(&again);

		test::@check(back[0] == matte[0] && back[1] == matte[1] && back[2] == matte[2],
			"and at zero it is the matte pixel exactly, %d,%d,%d against %d,%d,%d",
			(int)back[0], (int)back[1], (int)back[2], (int)matte[0], (int)matte[1], (int)matte[2]);
	};
}

<*
 A metal has no diffuse, and with nothing to reflect it is dark.

 **The regression this exists for is `metalness` that only adds.** A specular term
 that gives a metal its highlight without taking away its diffuse renders a
 brighter surface rather than a metallic one, and the mistake is invisible in a
 scene with an environment map — which this renderer does not have, so it is
 invisible nowhere.

 The darkness is the honest answer rather than a broken one: a mirror with nothing
 around it reflects nothing. `plan.md` §4's sky is what changes it, and until then
 this is what the doc comments promise.

 Proved by injection: drop the `(1 - s.metalness)` from `standard` and the metal
 comes back as bright as the matte surface.
*>
fn void a_metal_has_no_diffuse() @test
{
	@with_render(; three::JsRuntime* run, three::Renderer* renderer)
	{
		three::RunResult result = run.run(`
			globalThis.scene = new three.Scene();
			globalThis.material = new three.MeshLambertMaterial();
			scene.add(new three.Mesh(new three.PlaneGeometry(2, 2), material));
			three.camera.frameAll();
			three.light.ambient = 0;
			three.light.direction = [0, 0, 1];
			three.render(scene);
			return 1;
		`);
		defer result.free();
		test::@check(result.ok, "the script succeeded: %s", result.error);

		image::Image plain = renderer.capture()!!;
		defer plain.free();
		char[3] matte = centre_pixel(&plain);

		three::RunResult metal = run.run(`
			material.metalness = 1;
			three.render(scene);
			return material.metalness;
		`);
		defer metal.free();
		test::@check(metal.ok, "the second script succeeded: %s", metal.error);
		test::@check(metal.value == "1", "it reads back: %s", metal.value);

		image::Image shot = renderer.capture()!!;
		defer shot.free();
		char[3] dark = centre_pixel(&shot);

		test::@check((int)dark[0] * 2 < (int)matte[0],
			"a metal with nothing to reflect is far darker than the matte surface, %d against %d",
			(int)dark[0], (int)matte[0]);
	};
}

<*
 The three surface numbers round-trip and refuse what is out of range.

 The boundary half of the pair above: a value the host clamped silently would read
 back as something the script did not write, and one it accepted out of range
 would put a NaN through `pow` in the Fresnel term.
*>
fn void the_surface_numbers_round_trip_and_refuse_by_name() @test
{
	@with_render(; three::JsRuntime* run, three::Renderer* renderer)
	{
		three::RunResult result = run.run(`
			const material = new three.MeshLambertMaterial({
				roughness: 0.25, metalness: 0.5, reflectance: 0.75,
			});
			const refuse = (fn) => { try { fn(); return "accepted"; } catch (e) { return e.message; } };
			return {
				read: [material.roughness, material.metalness, material.reflectance],
				high: refuse(() => { material.roughness = 2; }),
				low: refuse(() => { material.metalness = -1; }),
				text: refuse(() => { material.reflectance = "shiny"; }),
			};
		`);
		defer result.free();
		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value.contains(`"read":[0.25,0.5,0.75]`),
			"the three read back as written: %s", result.value);
		test::@check(result.value.contains("`roughness` wants a number from 0 to 1"),
			"above the range is refused by name: %s", result.value);
		test::@check(result.value.contains("`metalness` wants a number from 0 to 1"),
			"and below it: %s", result.value);
		test::@check(result.value.contains("`reflectance` wants a number from 0 to 1"),
			"and so is a string: %s", result.value);
	};
}
