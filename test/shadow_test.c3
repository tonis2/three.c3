<*
 Shadows: the fit, the pass, and that a shadow is of the pose rather than of the
 bind box.

	`c3c test --trust=full --test-noleak --test-filter three_tests::shadow`

 **What is worth asserting here is not "is the picture darker somewhere".** A
 shadow map that is a frame late, that is fitted to the wrong box, that reads
 itself back mirrored, or that draws the bind pose of an animated character all
 produce a darker patch on the ground and all of them are wrong. So the checks
 are built around things that distinguish those:

 - The fit is asserted **by projecting the scene's own corners through it** and
   requiring every one of them inside the clip box. That is the property the
   whole pass depends on and it needs no device at all.
 - The picture checks compare **the same scene with the pass on and off**, at a
   pixel the caster cannot reach and at one it can — so "everything got darker"
   and "nothing changed" both fail.
 - The pose check moves the character between two frames of one clip and requires
   the shadow to move with it. A bind-pose shadow is stationary and would pass
   every other check in this file.
 - The two skinning paths are required to produce the **byte-identical frame**,
   which is the same standard `three_tests::skinning` holds them to for the
   colour pass.
*>
module three_tests::shadow;

import three;
import vk;
import image;
import std::core::test;
import std::io;
import std::math;
import std::math::vector;
import std::math::matrix;
import collision;

const String FIXTURE = "test/fixtures/skinned.glb";

const uint W = 240;
const uint H = 180;

macro @with_js(; @body(three::JsRuntime* run, three::Renderer* renderer))
{
	vk::Instance instance = three::create_instance(false, headless: true)!!;
	defer instance.free();

	three::Renderer renderer;
	renderer.init(instance, (vk::SurfaceKHR)null, W, H)!!;
	defer renderer.free();

	renderer.pass.init(&renderer.gpu, &renderer.target)!!;

	three::JsRuntime runtime;
	runtime.open(&renderer.pass, &renderer)!!;
	defer runtime.close();

	@body(&runtime, &renderer);
}

// One pixel, as rgb. The frame is `R8G8B8A8_SRGB` and the readback is a memcpy,
// so these are the bytes a PNG would carry.
fn char[3] pixel_at(image::Image* img, uint x, uint y)
{
	sz bpp = img.bytes_per_pixel();
	sz at = ((sz)y * (sz)img.width + (sz)x) * bpp;
	return { img.pixels[at], img.pixels[at + 1], img.pixels[at + 2] };
}

fn uint luma_at(image::Image* img, uint x, uint y)
{
	char[3] rgb = pixel_at(img, x, y);
	return (uint)rgb[0] + (uint)rgb[1] + (uint)rgb[2];
}

// How many bytes two frames of the same size disagree about.
fn sz differing_bytes(image::Image* a, image::Image* b)
{
	if (a.width != b.width || a.height != b.height) return sz::max;
	sz count = 0;
	foreach (i, byte : a.pixels)
	{
		if (byte != b.pixels[i]) count++;
	}
	return count;
}

// ============================================================================
// The fit, which needs no device
// ============================================================================

// A point through a column-major matrix, as the shaders do it. Written out
// rather than reached for, because the whole point of these checks is not to ask
// the same code the answer twice.
fn float[4] project(Matrix4f matrix, Vec3 point)
{
	float[<16>] m = matrix.m;
	return {
		m[0] * point.x + m[4] * point.y + m[8] * point.z + m[12],
		m[1] * point.x + m[5] * point.y + m[9] * point.z + m[13],
		m[2] * point.x + m[6] * point.y + m[10] * point.z + m[14],
		m[3] * point.x + m[7] * point.y + m[11] * point.z + m[15],
	};
}

<*
 Every corner of the scene's box lands inside the light's clip volume.

 **The property the whole pass rests on, and the one a picture cannot check.** A
 fit that is slightly too small produces a shadow map with a hole in it, which
 looks like geometry that stopped casting; one with the near and far the wrong
 way round produces an empty map, which looks like shadows being off. Neither
 says anything.

 So this asks the question directly: eight corners, through the matrix `fit`
 produced, all of them within x and y of [-1, 1] and z of [0, 1] — Vulkan's clip
 box, which is what `matrix::ortho` targets and what `shadow_factor` assumes when
 it treats an out-of-range z as "not covered".

 Asserted over several light directions rather than one, including the two
 degenerate ones: straight down, where `look_at`'s +Y up vector is parallel to
 the view and produces a matrix of NaNs if nothing swaps it; and zero, which is
 refused at the JS door and defended again in `fit` because this is the only
 place it would be silent.
*>
fn void the_fit_holds_the_whole_scene() @test
{
	collision::Aabb3 bounds = { .min = { -6, -1, -3 }, .max = { 4, 5, 9 } };

	float[4][*] directions = {
		{ 0.35, 0.80, 0.45, 0 },
		{ 0.0, 1.0, 0.0, 0 },      // straight down: the up-vector degeneracy
		{ 0.0, -1.0, 0.0, 0 },     // and straight up, which is the same one
		{ 1.0, 0.0, 0.0, 0 },      // horizontal, where the near plane is tightest
		{ -0.7, 0.2, -0.6, 0 },
		{ 0.0, 0.0, 0.0, 0 },      // refused elsewhere, survivable here
	};

	foreach (light : directions)
	{
		three::ShadowMap shadows;
		shadows.defaults();
		shadows.size = 1024;
		shadows.fit(light, bounds);

		for (uint corner = 0; corner < 8; corner++)
		{
			Vec3 point = {
				(corner & 1) != 0 ? bounds.max.x : bounds.min.x,
				(corner & 2) != 0 ? bounds.max.y : bounds.min.y,
				(corner & 4) != 0 ? bounds.max.z : bounds.min.z,
			};
			float[4] clip = project(shadows.light_view_projection, point);

			test::@check(
				clip[3] > 0.0f,
				"light [%f %f %f]: corner %d has w = %f", light[0], light[1], light[2], corner, clip[3]
			);
			// A hair of slack, because the fit is exact by construction and float
			// arithmetic on an exact fit lands on the boundary from either side.
			const float EDGE = 1.0001f;
			test::@check(
				clip[0] >= -EDGE && clip[0] <= EDGE && clip[1] >= -EDGE && clip[1] <= EDGE,
				"light [%f %f %f]: corner %d is at x %f y %f, outside the map",
				light[0], light[1], light[2], corner, clip[0], clip[1]
			);
			test::@check(
				clip[2] >= -0.0001f && clip[2] <= EDGE,
				"light [%f %f %f]: corner %d is at depth %f, outside [0, 1]",
				light[0], light[1], light[2], corner, clip[2]
			);
		}
	}
}

<*
 The normal offset and the texel size come out of the fit, and both scale.

 **They are derived rather than set, and that is what makes shadows work at any
 scene size** — the offset that stops a surface shadowing itself is two texels of
 the map, and a texel is only a length once the box has been fitted. So a scene
 ten times bigger has to produce an offset ten times bigger, and a map twice as
 wide has to halve it.

 Both directions are asserted, because the two factors enter the same expression
 and a bug that used the wrong one is a number that still looks plausible.
*>
fn void the_offset_tracks_the_scene_and_the_map() @test
{
	float[4] light = { 0.35, 0.80, 0.45, 0 };
	collision::Aabb3 small = { .min = { -1, -1, -1 }, .max = { 1, 1, 1 } };
	collision::Aabb3 large = { .min = { -10, -10, -10 }, .max = { 10, 10, 10 } };

	three::ShadowMap a;
	a.defaults();
	a.size = 1024;
	a.fit(light, small);

	three::ShadowMap b;
	b.defaults();
	b.size = 1024;
	b.fit(light, large);

	three::ShadowMap c;
	c.defaults();
	c.size = 2048;
	c.fit(light, small);

	test::@check(a.normal_offset > 0.0f, "a fitted scene has an offset, got %f", a.normal_offset);
	test::@check(
		b.normal_offset > a.normal_offset * 9.0f && b.normal_offset < a.normal_offset * 11.0f,
		"a ten times larger scene offsets about ten times as far: %f against %f",
		b.normal_offset, a.normal_offset
	);
	test::@check(
		c.normal_offset > a.normal_offset * 0.45f && c.normal_offset < a.normal_offset * 0.55f,
		"twice the map halves it: %f against %f", c.normal_offset, a.normal_offset
	);
	test::@check(
		math::abs(a.texel - 1.0f / 1024.0f) < 1e-9f && math::abs(c.texel - 1.0f / 2048.0f) < 1e-9f,
		"and a texel is one over the side: %f, %f", a.texel, c.texel
	);
}

<*
 `params` is four zeroes until the pass is live, and `w` is the switch.

 The shader's first line is `if (params.w <= 0.0) return 1.0`, so this is the
 whole of what a frame with no shadow pass costs — and it is also what a script
 setting the intensity to zero produces, which is the same question from the
 other end. Checked because the alternative implementation, a separate flag,
 would leave two things that have to agree.
*>
fn void the_params_are_the_switch() @test
{
	three::ShadowMap shadows;
	shadows.defaults();
	shadows.size = 512;
	shadows.fit({ 0, 1, 0, 0 }, { .min = { -1, -1, -1 }, .max = { 1, 1, 1 } });

	float[4] off = shadows.params();
	test::@check(off[3] == 0.0f, "not live: intensity reads 0, got %f", off[3]);
	test::@check(off[0] == 0.0f && off[1] == 0.0f && off[2] == 0.0f, "and so does everything else");

	shadows.live = true;
	float[4] on = shadows.params();
	test::@check(on[3] == 1.0f, "live: the intensity, got %f", on[3]);
	test::@check(on[0] > 0.0f && on[2] > 0.0f, "with a texel and an offset, got %f and %f", on[0], on[2]);

	shadows.intensity = 0.0f;
	test::@check(
		shadows.params()[3] == 0.0f,
		"and an intensity of zero is the same answer as no pass at all"
	);
}

// ============================================================================
// The shader
// ============================================================================

<*
 The shadow shader is the mesh push contract, one stage, and no samplers.

 Three separate claims and each is load-bearing:

 - **The mesh contract.** `MeshPipeline.init_shadow` holds it to
   `MESH_PUSH_FIELDS`, which is what lets `record_shadow` push the same block the
   main pass pushes and point at the same three buffers. A shadow shader with its
   own push layout would read the instance array at the wrong offset and draw a
   map of geometry that is not in the scene.
 - **One entry point.** A `fragmentMain` here would be a fragment stage running
   over every caster and returning nothing.
 - **No samplers.** The empty descriptor set layout is a case
   `MeshPipeline.build_layouts` did not have until this module existed — the
   binding helper faults on an empty slice rather than producing the empty layout
   it looks like it would.
*>
fn void the_shadow_shader_is_the_mesh_contract() @test
{
	String path = three::find_shader("shadow.slang", mem)!!;
	defer path.free(mem);
	String source = three::load_source(path)!!;
	defer source.free(mem);

	three::ShaderModule mod = three::compile_slang(source, "shadow.slang", three::SHADOW_ENTRIES[..])!!;
	defer mod.free();
	test::@check(mod.ok, "it compiled: %s", mod.diagnostic);

	foreach (expected : three::MESH_PUSH_FIELDS)
	{
		three::ShaderField* found = mod.layout.field_of(expected.name);
		test::@check(found != null, "the push block has a '%s' field", expected.name);
		if (found == null) continue;
		test::@check(
			found.offset == expected.offset && found.size == expected.size,
			"'%s' is at %d+%d and the contract has it at %d+%d",
			expected.name, found.offset, found.size, expected.offset, expected.size
		);
	}
	test::@check(
		mod.layout.push_size == three::MeshPush::size,
		"and the block is the mesh contract and nothing else: %d bytes, want %d",
		mod.layout.push_size, three::MeshPush::size
	);

	test::@check(mod.entries.len() == 1, "one entry point, got %d", mod.entries.len());
	if (mod.entries.len() == 1)
	{
		test::@check(mod.entries[0].name == "vertexMain", "and it is vertexMain, got %s", mod.entries[0].name);
	}
	test::@check(mod.layout.bindings.len() == 0, "no samplers, got %d", mod.layout.bindings.len());
}

// ============================================================================
// The pass, from a script
// ============================================================================

// A ground plane and one box above it, lit from almost straight down so the
// shadow lands where the arithmetic below expects it. `SHADOW` is the ground
// just clear of the box; `LIT` is the far corner of the plane, which no caster
// can reach at this light angle.
const String SCENE = `
	const scene = new three.Scene();
	const ground = new three.Mesh(new three.PlaneGeometry(12, 12), new three.MeshLambertMaterial());
	ground.rotation.x = -Math.PI / 2;
	scene.add(ground);
	const box = new three.Mesh(new three.BoxGeometry(2, 2, 2), new three.MeshLambertMaterial());
	box.position.set(0, 2.4, 0);
	scene.add(box);
	three.light.set([0.12, 1.0, 0.12], 0.2);
	three.camera.frameAll();
	three.camera.orbit(0.0, 1.0, three.camera.distance * 0.85);
`;

<*
 The ground under a box is darker with the pass on, and the ground away from it
 is not.

 **Both halves, because either alone passes for the wrong reason.** A shadow that
 darkened everything — a lookup that always reports occluded, an intensity
 applied to the ambient floor as well as the direct term — makes the first check
 pass and the second fail. A pass that recorded nothing makes the second pass and
 the first fail.

 The frames are compared to each other rather than to a stored number, so this
 says nothing about what grey the ground is and everything about what the pass
 did to it.
*>
fn void a_caster_darkens_the_ground_under_it() @test
{
	@with_js(; three::JsRuntime* run, three::Renderer* renderer)
	{
		three::RunResult lit_run = run.run(SCENE);
		defer lit_run.free();
		test::@check(lit_run.ok, "the scene built: %s", lit_run.error);

		image::Image lit = renderer.capture()!!;
		defer lit.free();

		three::RunResult on = run.run(`three.light.shadow = true; three.stats().shadowDraws`);
		defer on.free();
		test::@check(on.ok, "shadows went on: %s", on.error);

		image::Image shadowed = renderer.capture()!!;
		defer shadowed.free();

		// Just below the middle of the frame, where the box's shadow falls with the
		// light nearly overhead and the camera looking down at it.
		uint under_x = W / 2;
		uint under_y = (uint)(H * 0.62f);
		// The near edge of the plane, which the box cannot shade from directly
		// above and which is still ground rather than background.
		uint clear_x = W / 2;
		uint clear_y = (uint)(H * 0.92f);

		uint under_before = luma_at(&lit, under_x, under_y);
		uint under_after = luma_at(&shadowed, under_x, under_y);
		uint clear_before = luma_at(&lit, clear_x, clear_y);
		uint clear_after = luma_at(&shadowed, clear_x, clear_y);

		test::@check(
			under_after + 30 < under_before,
			"the ground under the box went from %d to %d", under_before, under_after
		);
		test::@check(
			clear_after == clear_before,
			"and the ground away from it did not move: %d to %d", clear_before, clear_after
		);
	};
}

<*
 Turning the pass off puts the frame back exactly as it was.

 **The claim that shadows cost nothing when they are off**, asserted as byte
 equality rather than as a resemblance. It covers more than it looks like: the
 draw list is built differently while shadows are on (no camera frustum), the
 frame block carries different numbers, and binding 1 carries a different image —
 so a frame that came back merely *similar* would mean one of those three did not
 go back.
*>
fn void turning_the_pass_off_restores_the_frame() @test
{
	@with_js(; three::JsRuntime* run, three::Renderer* renderer)
	{
		three::RunResult built = run.run(SCENE);
		defer built.free();
		test::@check(built.ok, "the scene built: %s", built.error);

		image::Image before = renderer.capture()!!;
		defer before.free();

		three::RunResult on = run.run(`three.light.shadow = true`);
		defer on.free();
		image::Image during = renderer.capture()!!;
		defer during.free();

		three::RunResult off = run.run(`three.light.shadow = false`);
		defer off.free();
		image::Image after = renderer.capture()!!;
		defer after.free();

		test::@check(differing_bytes(&before, &during) > 0, "the pass changed something");
		test::@check(
			differing_bytes(&before, &after) == 0,
			"and turning it off changed it back, %d bytes still differ",
			differing_bytes(&before, &after)
		);
	};
}

<*
 A transparent material casts nothing, and neither does a debug helper.

 Counted through `stats().shadowDraws` rather than looked for in the picture,
 because "no shadow appeared" is also what a broken pass produces. The count says
 which buckets were recorded, and the arithmetic is exact: two opaque meshes cast,
 the glass and the helper do not.
*>
fn void glass_and_helpers_cast_nothing() @test
{
	@with_js(; three::JsRuntime* run, three::Renderer* renderer)
	{
		three::RunResult result = run.run(`
			const scene = new three.Scene();
			const ground = new three.Mesh(new three.PlaneGeometry(12, 12), new three.MeshLambertMaterial());
			ground.rotation.x = -Math.PI / 2;
			scene.add(ground);
			const solid = new three.Mesh(new three.BoxGeometry(2, 2, 2), new three.MeshLambertMaterial());
			solid.position.set(-2, 2, 0);
			scene.add(solid);
			const glass = new three.Mesh(
				new three.BoxGeometry(2, 2, 2),
				new three.MeshLambertMaterial({ transparent: true, opacity: 0.4 })
			);
			glass.position.set(2, 2, 0);
			scene.add(glass);
			scene.add(new three.BoxHelper(solid));
			three.light.shadow = true;
			three.camera.frameAll();
			three.render();
			const s = three.stats();
			return [s.drawCalls, s.shadowDraws].join(',');
		`);
		defer result.free();

		test::@check(result.ok, "the script ran: %s", result.error);
		test::@check(
			result.value == `"4,2"`,
			"four buckets, two of them casters, got '%s'", result.value
		);
	};
}

// ============================================================================
// Skinning, which is what a second geometry pass is hardest on
// ============================================================================

<*
 A character's shadow is of the pose it is in, not of the pose it was authored
 in.

 **The check the whole shadow-of-a-skinned-mesh question comes down to.** A
 shadow pass that skipped the blend draws the bind pose into the map: the picture
 still has a shadow in it, it is still in the right place, and it simply never
 moves. So the character is posed at two different points of one clip and the
 shadow is required to differ between them — while the frame with shadows off at
 those same two times is required to differ too, which is what rules out "the
 clip did nothing" as the explanation.
*>
fn void the_shadow_follows_the_pose() @test
{
	@with_js(; three::JsRuntime* run, three::Renderer* renderer)
	{
		three::RunResult built = run.run(`
			const scene = new three.Scene();
			const ground = new three.Mesh(new three.PlaneGeometry(8, 8), new three.MeshLambertMaterial());
			ground.rotation.x = -Math.PI / 2;
			ground.position.y = -0.02;
			scene.add(ground);
			globalThis.actor = (await three.load('test/fixtures/skinned.glb')).instantiate();
			scene.add(actor);
			three.light.set([0.3, 1.0, 0.2], 0.2);
			three.camera.frameAll();
			three.camera.orbit(0.2, 0.9, three.camera.distance);
		`);
		defer built.free();
		test::@check(built.ok, "the scene built: %s", built.error);

		three::RunResult rest = run.run(`actor.play('Bend', { time: 0 })`);
		defer rest.free();
		image::Image unshadowed_rest = renderer.capture()!!;
		defer unshadowed_rest.free();

		three::RunResult bent = run.run(`actor.play('Bend', { time: 0.9 })`);
		defer bent.free();
		image::Image unshadowed_bent = renderer.capture()!!;
		defer unshadowed_bent.free();

		test::@check(
			differing_bytes(&unshadowed_rest, &unshadowed_bent) > 0,
			"the clip moves the character at all"
		);

		three::RunResult on = run.run(`three.light.shadow = true; actor.play('Bend', { time: 0 })`);
		defer on.free();
		image::Image shadow_rest = renderer.capture()!!;
		defer shadow_rest.free();

		three::RunResult moved = run.run(`actor.play('Bend', { time: 0.9 })`);
		defer moved.free();
		image::Image shadow_bent = renderer.capture()!!;
		defer shadow_bent.free();

		// The mesh itself moved in both pairs, so the shadowed pair differing is
		// not on its own the claim. What is: the *difference between the pairs* has
		// to grow, because the shadow moved as well as the character.
		sz without = differing_bytes(&unshadowed_rest, &unshadowed_bent);
		sz with = differing_bytes(&shadow_rest, &shadow_bent);
		test::@check(
			with > without,
			"the shadow moved with the pose: %d bytes changed with the pass on, %d with it off",
			with, without
		);
	};
}

<*
 A compute-skinned character and a vertex-skinned one cast the same shadow.

 The two paths do the same arithmetic in different places, and
 `three_tests::skinning` holds them to a byte-identical *colour* frame for that
 reason. This is the same standard with the shadow pass on — which is the
 stronger claim, because the shadow pass reads the compute pass's output through
 a second pipeline and a barrier that the colour pass alone does not prove
 anything about.

 It is also where the compute path stops being strictly more work: one blend, two
 passes reading it. `plan.md` §3 predicted this pass by name as the thing that
 would make it break even.
*>
fn void the_two_skinning_paths_cast_the_same_shadow() @test
{
	@with_js(; three::JsRuntime* run, three::Renderer* renderer)
	{
		three::RunResult vertex = run.run(`
			const scene = new three.Scene();
			const ground = new three.Mesh(new three.PlaneGeometry(8, 8), new three.MeshLambertMaterial());
			ground.rotation.x = -Math.PI / 2;
			ground.position.y = -0.02;
			scene.add(ground);
			const actor = (await three.load('test/fixtures/skinned.glb')).instantiate();
			scene.add(actor);
			actor.play('Bend', { time: 0.6 });
			three.light.set([0.3, 1.0, 0.2], 0.2);
			three.light.shadow = true;
			three.camera.frameAll();
			three.camera.orbit(0.2, 0.9, 6);
			return three.stats().preskinnedInstances;
		`);
		defer vertex.free();
		test::@check(vertex.ok, "the vertex-skinned scene built: %s", vertex.error);
		test::@check(vertex.value == "0", "and is not routed through compute, got '%s'", vertex.value);

		image::Image through_vertex = renderer.capture()!!;
		defer through_vertex.free();

		three::RunResult compute = run.run(`
			const scene = new three.Scene();
			const ground = new three.Mesh(new three.PlaneGeometry(8, 8), new three.MeshLambertMaterial());
			ground.rotation.x = -Math.PI / 2;
			ground.position.y = -0.02;
			scene.add(ground);
			const actor = (await three.load('test/fixtures/skinned.glb'))
				.instantiate(undefined, { skinning: 'compute' });
			scene.add(actor);
			actor.play('Bend', { time: 0.6 });
			three.light.set([0.3, 1.0, 0.2], 0.2);
			three.light.shadow = true;
			three.camera.frameAll();
			three.camera.orbit(0.2, 0.9, 6);
			return three.stats().preskinnedInstances;
		`);
		defer compute.free();
		test::@check(compute.ok, "the compute-skinned scene built: %s", compute.error);
		test::@check(compute.value != "0", "and is routed through compute, got '%s'", compute.value);

		image::Image through_compute = renderer.capture()!!;
		defer through_compute.free();

		test::@check(
			differing_bytes(&through_vertex, &through_compute) == 0,
			"the two paths draw the same shadowed frame, %d bytes differ",
			differing_bytes(&through_vertex, &through_compute)
		);
	};
}

// ============================================================================
// Materials
// ============================================================================

<*
 A `ShaderMaterial` whose body is the default draws the **byte-identical shadowed
 frame** that no material at all draws.

 **This is the check `g_shadow` exists to make passable.** `lambert(s.normal)` is
 how every material in this project, in `getApiDocs` and in `examples/` asks for
 the built-in light, so the shadow had to reach all of them — which is why it went
 inside `lambert` rather than into its signature. The failure that would otherwise
 be silent is a `ShaderMaterial` standing in its own light: the surface renders,
 the body is unchanged, and it is the one thing in the scene that ignores the
 shadow map.

 Asserted as byte equality rather than as a resemblance, which is stronger than it
 needs to be and is free: the template's header claims a material is a change of
 *shading* and not a second renderer, and two pipelines computing the same
 arithmetic on one device produce the same bytes. It was already true before
 shadows and nothing checked it at the pixel level; it is checked now because
 shadows are the first thing that could have broken it invisibly.

 The third frame is what stops this passing for the wrong reason: with shadows off
 the two materials also agree, so the scene has to be one where the pass actually
 changed something.

 **The pitch is set before `frameAll` and the distance is never scaled**, which
 matters here in a way it would not in a script: the camera survives
 `new three.Scene()` by design, so the second scene starts from wherever the first
 left it — and `frameAll` fits against the *current* angle, so fitting first and
 turning afterwards gives two different distances for two identical scenes. Both
 halves of that were got wrong the first time this was written, and both produced
 frames that differ for a reason with nothing to do with the materials.
*>
fn void a_shader_material_draws_the_same_shadowed_frame() @test
{
	String scene = `
		const scene = new three.Scene();
		const ground = new three.Mesh(new three.PlaneGeometry(12, 12), MATERIAL);
		ground.rotation.x = -Math.PI / 2;
		scene.add(ground);
		const box = new three.Mesh(new three.BoxGeometry(2, 2, 2), new three.MeshLambertMaterial());
		box.position.set(0, 3, 0);
		scene.add(box);
		three.light.set([0.25, 1.0, 0.35], 0.2);
		three.camera.orbit(0, 45);
		three.camera.frameAll();
	`;

	@with_js(; three::JsRuntime* run, three::Renderer* renderer)
	{
		@pool()
		{
			String plain_source = scene.treplace("MATERIAL", "new three.MeshLambertMaterial()");
			String custom_source = scene.treplace(
				"MATERIAL",
				`new three.ShaderMaterial({ fragment: "float3 shade(Surface s) { return s.albedo * lambert(s.normal); }" })`
			);

			three::RunResult plain = run.run(plain_source);
			defer plain.free();
			test::@check(plain.ok, "the plain scene built: %s", plain.error);

			image::Image unshadowed = renderer.capture()!!;
			defer unshadowed.free();

			three::RunResult on = run.run(`three.light.shadow = true`);
			defer on.free();
			image::Image with_lambert = renderer.capture()!!;
			defer with_lambert.free();

			test::@check(
				differing_bytes(&unshadowed, &with_lambert) > 0,
				"the scene is one the shadow pass changes"
			);

			three::RunResult custom = run.run(custom_source);
			defer custom.free();
			test::@check(custom.ok, "the ShaderMaterial scene built: %s", custom.error);

			three::RunResult again = run.run(`three.light.shadow = true`);
			defer again.free();
			image::Image with_body = renderer.capture()!!;
			defer with_body.free();

			test::@check(
				differing_bytes(&with_lambert, &with_body) == 0,
				"and a body of `s.albedo * lambert(s.normal)` draws it identically, %d bytes differ",
				differing_bytes(&with_lambert, &with_body)
			);
		};
	};
}

// ============================================================================
// What the settings do, and what they cost when they are off
// ============================================================================

<*
 A frame with shadows off allocates no image and compiles no shader.

 The opt-in claim, asserted on the two expensive things rather than on the
 setting. `ShadowMap.enabled` being false is what a script wrote; `created` being
 0 and `pipeline_ready` being false is what it bought.
*>
fn void shadows_off_build_nothing() @test
{
	@with_js(; three::JsRuntime* run, three::Renderer* renderer)
	{
		three::RunResult built = run.run(SCENE);
		defer built.free();
		test::@check(built.ok, "the scene built: %s", built.error);

		image::Image shot = renderer.capture()!!;
		defer shot.free();

		three::ShadowMap* shadows = &renderer.pass.shadows;
		test::@check(!shadows.enabled, "shadows are off by default");
		test::@check(shadows.created == 0, "no image was created, got one of %d", shadows.created);
		test::@check(!shadows.pipeline_ready, "and no shadow shader was compiled");

		three::RunResult on = run.run(`three.light.shadow = true`);
		defer on.free();
		image::Image with = renderer.capture()!!;
		defer with.free();

		test::@check(shadows.created == shadows.size, "turning them on created the map at %d", shadows.size);
		test::@check(shadows.pipeline_ready, "and compiled the shader");
	};
}

<*
 The size is clamped and rounded to a power of two, and reads back as what will
 be allocated.

 A shadow map is a memory footprint, and a script that asks for 3000 and is
 quietly given 4096 has been told the wrong number about its own budget. Rounding
 *down* rather than to the nearest, because the surprise a script can absorb is
 slightly blockier shadows and not twice the memory.
*>
fn void the_size_is_clamped_and_rounded() @test
{
	@with_js(; three::JsRuntime* run, three::Renderer* renderer)
	{
		three::RunResult result = run.run(`
			const sizes = [];
			for (const want of [1, 200, 256, 300, 1023, 2048, 100000]) {
				three.light.shadow.size = want;
				sizes.push(three.light.shadow.size);
			}
			return sizes.join(',');
		`);
		defer result.free();

		test::@check(result.ok, "the script ran: %s", result.error);
		test::@check(
			result.value == `"256,256,256,256,512,2048,8192"`,
			"clamped to 256..8192 and rounded down to a power of two, got '%s'", result.value
		);
	};
}

<*
 The four settings are independent, and `new three.Scene()` puts them back.

 The independence is what the all-four-at-once host call has to be checked for:
 `shadowSet` takes the lot every time, so a setter that read one of the other
 three back wrongly would quietly reset it. The reset is the rule
 `three.light.direction` and `scene.background` already follow — a scene that sets
 something and a scene that does not have to render the same first frame.
*>
fn void the_settings_are_independent_and_a_new_scene_resets_them() @test
{
	@with_js(; three::JsRuntime* run, three::Renderer* renderer)
	{
		// The bias is a power of two so that it survives the round trip through a
		// `float` and back into a JS double unchanged. 0.002 comes back as
		// 0.0020000000949949026, which is a true statement about float32 and a
		// terrible thing to write in an expected value.
		three::RunResult set = run.run(`
			three.light.shadow.enabled = true;
			three.light.shadow.size = 1024;
			three.light.shadow.bias = 0.0009765625;
			three.light.shadow.intensity = 0.5;
			const s = three.light.shadow;
			return [s.enabled, s.size, s.bias, s.intensity].join(',');
		`);
		defer set.free();
		test::@check(set.ok, "the script ran: %s", set.error);
		test::@check(
			set.value == `"true,1024,0.0009765625,0.5"`,
			"all four survived each other, got '%s'", set.value
		);

		three::RunResult object_form = run.run(`
			three.light.shadow = { size: 512 };
			const s = three.light.shadow;
			return [s.enabled, s.size, s.bias, s.intensity].join(',');
		`);
		defer object_form.free();
		test::@check(object_form.ok, "the object form ran: %s", object_form.error);
		test::@check(
			object_form.value == `"true,512,0.0009765625,0.5"`,
			"and an object sets only what it names, got '%s'", object_form.value
		);

		three::RunResult reset = run.run(`
			new three.Scene();
			const s = three.light.shadow;
			return [s.enabled, s.size, s.bias, s.intensity].join(',');
		`);
		defer reset.free();
		test::@check(reset.ok, "the reset ran: %s", reset.error);
		test::@check(
			reset.value == `"false,2048,0,1"`,
			"a new Scene restores the defaults, got '%s'", reset.value
		);
	};
}

<*
 The camera keeps its cull while the pass is on, and the casters it dropped are
 still in the shadow pass's list.

 **This is §18.2, and it replaces a test that pinned the opposite.** Until the
 second draw list existed, one uncalled list served both passes and
 `culledLastFrame` read 0 whenever shadows were on — honest, because nothing was
 dropped, and useless, because it said nothing about the camera. The old test
 asserted that zero. What is asserted now is that the number does not move at
 all: the same scene culls the same copies with the pass on and with it off, so
 turning shadows on costs the colour pass nothing.

 The three numbers together are what make this more than "culling still works":

 - `culledLastFrame` is the same on and off, so the camera's list is unchanged.
 - `shadowCulled` is **more than zero and fewer than `culledLastFrame`**, which is
   the whole shape of two lists in one number. Zero would mean the light's box is
   still the whole scene — the pre-§18.1 fit. Equal to `culledLastFrame` would
   mean the camera's frustum had been applied to both passes, which is the
   mistake this item is one line away from. Between them is a shadow list that is
   larger than the colour list and smaller than everything.
 - `shadowDraws` is 1, so the pass did record the bucket holding them.

 The exact number is not asserted, and deliberately: it is a property of where
 §18.1's square landed on the texel grid, and a fixture pinned to it would fail
 on a change to the snapping that was an improvement.

 The scene puts most of its copies outside the camera's view so that there is
 something to cull. It leaves the camera's target alone rather than aiming it:
 `three.camera.lookAt([0, 0, 0])` puts the turntable's focus at NaN, every
 frustum plane follows it, and nothing is culled — a failure that looks exactly
 like the one this test is here to detect.

 **Proved by injection.** `Scene.update` passing the *camera's* frustum as the
 light's — the one-line version of "give the shadow pass a cull too", and the
 mistake this whole item is one edit away from: "every dropped copy is still a
 caster, got '39'". `culledLastFrame` and `shadowDraws` are both unchanged by it,
 which is the argument for asserting all three. Restored, green again.

 Passing `null` for the light frustum instead — a second list threaded through
 the signature and not through the call — leaves every check here green, because
 then nothing is kept for the light and `shadowCulled` is never counted. That
 failure is caught in pixels by the test below, and the pair is deliberate: this
 one says the *lists* are two, that one says the *shadow* is still right.
*>
fn void the_camera_keeps_its_cull_while_the_pass_is_on() @test
{
	@with_js(; three::JsRuntime* run, three::Renderer* renderer)
	{
		three::RunResult culled = run.run(`
			const scene = new three.Scene();
			const geometry = new three.BoxGeometry(1, 1, 1);
			const material = new three.MeshLambertMaterial();
			for (let i = 0; i < 40; i++) {
				const box = new three.Mesh(geometry, material);
				box.position.set((i - 20) * 6, 0, 0);
				scene.add(box);
			}
			// Degrees, and the target is left where it starts.
			three.camera.orbit(0, 20, 8);
			three.render();
			return three.stats().culledLastFrame;
		`);
		defer culled.free();
		test::@check(culled.ok, "the script ran: %s", culled.error);
		test::@check(culled.value != "0", "the camera culls something to begin with, got '%s'", culled.value);

		three::RunResult lit = run.run(`
			three.light.shadow = true;
			three.render();
			const s = three.stats();
			return [s.culledLastFrame, s.shadowCulled, s.shadowDraws].join(',');
		`);
		defer lit.free();
		test::@check(lit.ok, "the second script ran: %s", lit.error);

		String[] parts = lit.value.trim(`"`).tsplit(",");
		test::@check(parts.len == 3, "three numbers came back: %s", lit.value);
		if (parts.len != 3) return;

		test::@check(
			parts[0] == culled.value,
			"the camera culls the same %s copies with the pass on, got '%s'", culled.value, parts[0]
		);
		int camera_dropped = culled.value.to_int() ?? -1;
		int both_dropped = parts[1].to_int() ?? -1;
		test::@check(
			both_dropped > 0,
			"the light's box drops something of its own, got '%s' — is the fit still the whole scene?", parts[1]
		);
		test::@check(
			both_dropped < camera_dropped,
			"and keeps casters the camera dropped: %d of %d went to neither pass", both_dropped, camera_dropped
		);
		test::@check(parts[2] == "1", "and the pass recorded the bucket, got '%s'", parts[2]);

		three::RunResult again = run.run(`
			three.light.shadow = false;
			three.render();
			const s = three.stats();
			return [s.culledLastFrame, s.shadowCulled].join(',');
		`);
		defer again.free();
		test::@check(again.ok, "the third script ran: %s", again.error);
		test::@check(
			again.value.contains(culled.value),
			"and it culls the same afterwards, got '%s'", again.value
		);
		test::@check(
			again.value.ends_with(`,0"`) || again.value.ends_with(",0"),
			"with no light box to be outside of, got '%s'", again.value
		);
	};
}

<*
 A caster the camera cannot see still darkens the ground it can.

 **The regression §18.2 could have introduced, asserted in pixels.** Giving the
 shadow pass a cull is one line away from giving it the *camera's* cull, and the
 result is a scene whose shadows appear and vanish as the caster crosses the edge
 of the frame — which is the single most conspicuous failure a shadow map has,
 and no counter in `stats()` would show it.

 The fixture is built so that the caster cannot be in shot: a post 8 units tall
 at x = 20, with the camera looking down at the origin from 7 units away, is
 outside the frustum by a wide margin — and `culledLastFrame` is asserted to be
 1, so a fixture that accidentally framed it fails rather than passing for the
 wrong reason. The sun is 14 degrees above the horizon on the +x side, which
 throws a streak roughly thirty units long back across the origin.

 The two frames are the same scene with the pass off and on, compared at one
 pixel the streak lands on and one it does not, exactly as
 `a_caster_darkens_the_ground_under_it` does — so "the whole frame got darker"
 fails too. The streak runs along z = 0 and is two units wide, so the two
 samples are one *column* apart in z rather than in x: the whole of the middle
 row is inside it.

 **Proved by injection**, twice, and this is the check that catches both:

 - `Scene.update` passing the camera's frustum as the light's: "the ground under
   the off-screen caster went from 411 to 411".
 - `Scene.update` passing `null` for the light frustum while the pass is live,
   which the counter test above cannot see at all: the same 411 to 411.

 The picture is otherwise unchanged in both, and every other test in this file
 stays green, which is the argument for asserting this in pixels. Restored,
 green again.
*>
fn void a_caster_outside_the_frustum_still_casts() @test
{
	@with_js(; three::JsRuntime* run, three::Renderer* renderer)
	{
		three::RunResult built = run.run(`
			const scene = new three.Scene();
			const ground = new three.Mesh(new three.PlaneGeometry(80, 80), new three.MeshLambertMaterial());
			ground.rotation.x = -Math.PI / 2;
			scene.add(ground);

			const post = new three.Mesh(new three.BoxGeometry(2, 8, 2), new three.MeshLambertMaterial());
			post.position.set(20, 4, 0);
			scene.add(post);

			// Low from +x, so the post's shadow is thrown back across the origin.
			three.light.set([0.97, 0.24, 0.0], 0.25);
			three.camera.lookAt(0, 0, 0);
			three.camera.orbit(0, 70, 7);
			three.render();
			return three.stats().culledLastFrame;
		`);
		defer built.free();
		test::@check(built.ok, "the scene built: %s", built.error);
		test::@check(built.value == "1", "the caster is out of frame to begin with, got '%s'", built.value);

		image::Image before = renderer.capture()!!;
		defer before.free();

		three::RunResult on = run.run(`three.light.shadow = true; three.render();`);
		defer on.free();
		test::@check(on.ok, "the pass turned on: %s", on.error);

		image::Image after = renderer.capture()!!;
		defer after.free();

		// The streak covers the middle band of the picture — measured, y 63 to 117
		// of 180 — so the centre is inside it and a sixth of the way down is not.
		uint shaded_before = luma_at(&before, W / 2, H / 2);
		uint shaded_after  = luma_at(&after,  W / 2, H / 2);
		uint clear_before  = luma_at(&before, W / 2, H / 6);
		uint clear_after   = luma_at(&after,  W / 2, H / 6);

		test::@check(
			shaded_after + 30 < shaded_before,
			"the ground under the off-screen caster went from %d to %d", shaded_before, shaded_after
		);
		test::@check(
			clear_after == clear_before,
			"and the ground away from it did not move: %d to %d", clear_before, clear_after
		);
	};
}

// ============================================================================
// Validation
// ============================================================================

macro @with_validating_js(; @body(three::JsRuntime* run, three::Renderer* renderer))
{
	// `sync: true` for the reason `three_tests::skinning` asks for it: without it
	// this is a check about the pass's arguments and not about its barriers.
	vk::Instance instance = three::create_instance(true, headless: true, sync: true)!!;
	defer instance.free();

	three::Renderer renderer;
	renderer.init(instance, (vk::SurfaceKHR)null, W, H, validate: true)!!;
	defer renderer.free();

	renderer.pass.init(&renderer.gpu, &renderer.target)!!;

	three::JsRuntime runtime;
	runtime.open(&renderer.pass, &renderer)!!;
	defer runtime.close();

	@body(&runtime, &renderer);
}

<*
 The shadow pass is well formed under the validation layer.

 What this covers, and it is most of what a second geometry pass can get wrong:
 the depth-only pipeline against a rendering that begins with no colour
 attachment, the empty descriptor set layout, the push range against a layout
 built from a module with no samplers in it, and — the two the pass owns
 outright — the image's transitions into DEPTH_STENCIL_ATTACHMENT_OPTIMAL and out
 to SHADER_READ_ONLY_OPTIMAL, every frame, against a descriptor that names the
 second of those.

 **What it does not cover is the two barriers, and that was measured rather than
 assumed.** Deleting either one of them — the opening transition in
 `ShadowMap.begin` or the read-side one in `ShadowMap.end` — leaves **every check
 in this file green**, the pictures included, with the ordinary layer and with
 synchronization validation requested through `create_instance(sync: true)`.

 That is worth more than the usual "the layer did not report it", because
 `plan.md` §13 says the layout bookkeeping *is* the instrument on this driver and
 offers the post chain as the measurement. The post chain still measures that way:
 commenting out `record_chain`'s `shader_read_barrier(self.scene.image)` produces

	VUID-vkCmdDraw-imageLayout-00344: ... specific layout
	VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL (specified by combined image
	sampler descriptor ... "prev" ... updated by vkCmdPushDescriptorSet) that
	doesn't match the previous known layout VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL

 and `three_tests::post` fails on it. So the instrument exists, it works through a
 push descriptor, and it does **not** fire for this image: a depth image, sampled
 through the same mechanism, left in DEPTH_STENCIL_ATTACHMENT_OPTIMAL while the
 descriptor claims SHADER_READ_ONLY_OPTIMAL. Both injections were run; the
 contrast is the finding.

 The barriers therefore rest on the specification and on review, exactly as
 `the_skinning_paths_are_silent_under_validation` says its compute→vertex barrier
 does. **A test named for something it does not do is worse than no test**, so
 this says so — and the injections above are what to repeat anywhere the layer is
 fuller.

 Both the compute skinning path and the post chain are run underneath it, because
 those are the two other things in a frame that begin and end a rendering or a
 dispatch, and the ordering between the three is exactly what `record_scene`'s
 sequence exists to fix.

 Skipped when the Khronos layer is not installed, like every other check here
 that needs it.
*>
fn void the_shadow_pass_is_silent_under_validation() @test
{
	@with_validating_js(; three::JsRuntime* run, three::Renderer* renderer)
	{
		if (!renderer.gpu.validation) return;

		three::RunResult built = run.run(`
			const scene = new three.Scene();
			globalThis.stage = scene;
			const ground = new three.Mesh(new three.PlaneGeometry(10, 10), new three.MeshLambertMaterial());
			ground.rotation.x = -Math.PI / 2;
			ground.position.y = -0.02;
			scene.add(ground);
			const asset = await three.load('test/fixtures/skinned.glb');
			const baked = asset.instantiate();
			scene.add(baked);
			baked.play('Bend', { loop: true });
			three.camera.frameAll();
		`);
		defer built.free();
		test::@check(built.ok, "the scene built: %s", built.error);

		// One frame before the sink is armed, so anything the layer objects to
		// afterwards belongs to the shadow pass rather than to the setup.
		image::Image warmup = renderer.capture()!!;
		warmup.free();

		renderer.gpu.begin_capture();

		three::RunResult on = run.run(`three.light.shadow = true`);
		defer on.free();
		image::Image first = renderer.capture()!!;
		first.free();

		// A second frame, which is the one that transitions an image the previous
		// frame left in SHADER_READ_ONLY_OPTIMAL rather than one that was never
		// used — the write-after-read the opening barrier exists for.
		image::Image second = renderer.capture()!!;
		second.free();

		// A compute-skinned character joining mid-scene, so the shadow pass reads a
		// buffer the dispatch wrote in the same submission.
		three::RunResult computed = run.run(`
			const asset = await three.load('test/fixtures/skinned.glb');
			const c = asset.instantiate(undefined, { skinning: 'compute' });
			stage.add(c);
			c.position.set(2, 0, 0);
			c.play('Bend', { loop: true });
		`);
		defer computed.free();
		test::@check(computed.ok, "the compute character joined: %s", computed.error);
		image::Image third = renderer.capture()!!;
		third.free();

		// And with a post chain running, which is the other stage that begins and
		// ends a rendering inside one frame.
		three::RunResult posted = run.run(`
			three.setPost({ fragment: 'float3 post(Post p) { return p.color.rgb * 1.1; }' })
		`);
		defer posted.free();
		test::@check(posted.ok, "the post pass compiled: %s", posted.error);
		image::Image fourth = renderer.capture()!!;
		fourth.free();

		// The other frame path, for the reason the post and skinning checks reach
		// for it: "they all go through one function" is a claim worth checking.
		renderer.render_offscreen()!!;

		String errors = renderer.gpu.sink.errors.str_view();
		String warnings = renderer.gpu.sink.warnings.str_view();
		renderer.gpu.end_capture();

		test::@check(errors.len == 0, "the shadow pass produced validation errors: %s", errors);
		test::@check(warnings.len == 0, "the shadow pass produced validation warnings: %s", warnings);
	};
}

<*
 The pass costs what `shadowMs` says it costs, and the scene pass does not pay
 for it.

 This is the check that makes the breakdown an instrument rather than a
 decoration, and `plan.md` §18.3 is the reason it exists: the first outdoor
 scene on this engine spent two thirds of its frame here, and finding that out
 meant rendering the same village six times with the scene edited between the
 runs. A number that moved when the pass was turned on but was charged to the
 wrong phase would have sent that investigation somewhere else.

 **Three claims.**

 - With the pass off, `shadow` is a rounding error against the frame: the mark
   is still recorded — `gpu/timing.c3` says why every mark is unconditional —
   and it bounds no commands.
 - With the pass on, `shadow` is milliseconds. A 2048-texel depth map over a
   scene this small is almost all fill, so this is the largest single number in
   the frame and not a marginal one.
 - **The growth lands in `shadow` and not in `total` alone.** A timer that
   charged the pass to whichever phase happened to be next reports the same
   `total` and the same "shadows are expensive", and a check on either of those
   would pass. So the last check is on the *increase in the frame* against the
   *increase in that one phase*, which is the property a breakdown is for.

 **Proved by injection.** The `FrameMark.SHADOW` write moved above
 `record_shadow` rather than below it — the whole of the mistake, and it changes
 nothing else about the frame: "a shadowed frame spent 0.000000 ms in the shadow
 pass, of 0.554708 (timestamps=true)". It lands on the second check rather than
 the third, because a misplaced mark leaves the phase at nothing rather than at
 a wrong number; the third check is what survives a shadow figure that is
 plausible. Restored, green again.
*>
fn void the_pass_is_charged_to_its_own_phase() @test
{
	@with_js(; three::JsRuntime* run, three::Renderer* renderer)
	{
		three::RunResult built = run.run(SCENE);
		defer built.free();
		test::@check(built.ok, "the scene built: %s", built.error);

		// Twice, so the reading is not the first frame on this slot and both
		// slots have a full run of marks behind them.
		renderer.render_offscreen()!!;
		renderer.render_offscreen()!!;
		three::FrameTiming off = renderer.timing();

		three::RunResult on = run.run(`three.light.shadow = true`);
		defer on.free();
		test::@check(on.ok, "the pass turned on: %s", on.error);

		renderer.render_offscreen()!!;
		renderer.render_offscreen()!!;
		three::FrameTiming lit = renderer.timing();

		test::@check(
			off.shadow < 0.01,
			"an unshadowed frame spent %f ms in the shadow pass, of %f", off.shadow, off.total
		);
		test::@check(
			lit.shadow > 0.01,
			"a shadowed frame spent %f ms in the shadow pass, of %f (timestamps=%s)",
			lit.shadow, lit.total, renderer.gpu.limits.timestamps
		);

		double frame_grew = lit.total - off.total;
		double phase_grew = lit.shadow - off.shadow;
		test::@check(
			phase_grew > frame_grew * 0.5,
			"the pass cost %f ms in shadowMs while the frame grew by %f ms",
			phase_grew, frame_grew
		);
	};
}


<*
 A focus box narrows the fit onto it, and the depth range still reaches the
 casters outside it.

 **§18.1, asserted as the two halves it has to get right at once.** Spending the
 texels on what the camera can see is easy; spending them there *without losing
 the casters standing outside the picture* is the part that is one mistake away,
 and the mistake is symmetrical — a fit that narrows the depth range along with
 the extent produces a map that is sharp and missing exactly the shadows that
 come from off-screen.

 - The focus corners land inside the clip box, as `the_fit_holds_the_whole_scene`
   requires of the scene corners. That is the fit still being a fit.
 - **A point in the scene but far outside the focus is outside x or y**, which is
   what says the texels moved. Without it, "narrowed" is satisfied by not
   narrowing.
 - **Every corner of the whole scene is still inside the depth range**, which is
   the half that keeps off-screen casters. In light space a caster and the ground
   it shadows share x and y and differ only in z, so this is exactly the property
   that makes culling against the light's box safe.
*>
fn void a_focus_box_narrows_the_fit_without_losing_the_depth() @test
{
	float[4] light = { 0.35, 0.80, 0.45, 0 };
	collision::Aabb3 bounds = { .min = { -100, -2, -100 }, .max = { 100, 20, 100 } };
	collision::Aabb3 focus  = { .min = { -10, -2, -10 },   .max = { 10, 8, 10 } };

	three::ShadowMap wide;
	wide.defaults();
	wide.size = 1024;
	wide.fit(light, bounds);

	three::ShadowMap near;
	near.defaults();
	near.size = 1024;
	near.fit(light, bounds, focus);

	test::@check(
		near.normal_offset < wide.normal_offset * 0.5f,
		"the focused fit has offset %f against the wide fit's %f — a texel did not get smaller",
		near.normal_offset, wide.normal_offset
	);

	for (uint corner = 0; corner < 8; corner++)
	{
		Vec3 inside = {
			(corner & 1) != 0 ? focus.max.x : focus.min.x,
			(corner & 2) != 0 ? focus.max.y : focus.min.y,
			(corner & 4) != 0 ? focus.max.z : focus.min.z,
		};
		float[4] clip = project(near.light_view_projection, inside);
		test::@check(
			clip[0] >= -1.0001f && clip[0] <= 1.0001f && clip[1] >= -1.0001f && clip[1] <= 1.0001f,
			"focus corner %d is at x %f y %f, outside the map it was fitted to", corner, clip[0], clip[1]
		);
	}

	// Far outside the focus and well inside the scene: the texels are elsewhere
	// now, which is the whole point of the item.
	float[4] away = project(near.light_view_projection, { 90, 0, 90 });
	test::@check(
		away[0] < -1.0f || away[0] > 1.0f || away[1] < -1.0f || away[1] > 1.0f,
		"a corner of the level is still on the map at x %f y %f, so nothing was narrowed",
		away[0], away[1]
	);

	// **The depth half.** Every corner of the scene, focused or not, is inside
	// [0, 1] — a caster over there is between the light and the ground here.
	for (uint corner = 0; corner < 8; corner++)
	{
		Vec3 point = {
			(corner & 1) != 0 ? bounds.max.x : bounds.min.x,
			(corner & 2) != 0 ? bounds.max.y : bounds.min.y,
			(corner & 4) != 0 ? bounds.max.z : bounds.min.z,
		};
		float[4] clip = project(near.light_view_projection, point);
		test::@check(
			clip[2] >= -0.0001f && clip[2] <= 1.0001f,
			"scene corner %d is at depth %f, so a caster outside the focus would be clipped",
			corner, clip[2]
		);
	}
}

<*
 The fit does not move for a camera that moved less than a texel, and does move
 for one that moved more.

 **This is the failure §18.1 was warned about**, and it is the reason the item is
 not a change of argument: a box that tracks the camera slides its texel grid
 under stationary geometry, and every shadow edge crawls. It is invisible in a
 screenshot and unmistakable in motion, which is precisely the kind of defect a
 test has to carry rather than an eye.

 So the property is asserted at the matrix, where it is exact: two fits whose
 focus boxes differ by a twentieth of a texel must produce **byte-identical**
 matrices. Only snapping can do that. A fit that merely re-bounds the focus
 produces two matrices that differ in the eighth decimal place — which is a
 shimmer, and which no tolerance-based check would call a failure.

 The second half is the one that stops the first from being satisfied by a fit
 that ignores the camera altogether: move by ten texels and the matrix must
 change.

 **Proved by injection.** The two `math::floor` calls dropped from `fit`: "a
 sub-texel move changed the fit". The whole-scene test and the focus test above
 both stayed green, which is the argument for this being its own check.
*>
fn void the_fit_snaps_to_whole_texels() @test
{
	float[4] light = { 0.35, 0.80, 0.45, 0 };
	collision::Aabb3 bounds = { .min = { -100, -2, -100 }, .max = { 100, 20, 100 } };
	collision::Aabb3 focus  = { .min = { -10, -2, -10 },   .max = { 10, 8, 10 } };

	three::ShadowMap first;
	first.defaults();
	first.size = 1024;
	first.fit(light, bounds, focus);

	// The world size of one texel, recovered from what the fit derived: the
	// offset is `per_texel * SHADOW_NORMAL_OFFSET_TEXELS`, so this is the one
	// number the test and the implementation cannot disagree about.
	float texel = first.normal_offset / (float)three::SHADOW_NORMAL_OFFSET_TEXELS;
	test::@check(texel > 0.0f, "the fit produced a texel size of %f", texel);

	float nudge = texel * 0.05f;
	collision::Aabb3 crept = { .min = focus.min + (Vec3) { nudge, 0, nudge }, .max = focus.max + (Vec3) { nudge, 0, nudge } };

	three::ShadowMap second;
	second.defaults();
	second.size = 1024;
	second.fit(light, bounds, crept);

	Matrix4f a = first.light_view_projection;
	Matrix4f b = second.light_view_projection;
	bool same = true;
	for (uint i = 0; i < 16; i++)
	{
		if (a.m[i] != b.m[i]) same = false;
	}
	test::@check(same, "a sub-texel move changed the fit");

	float stride = texel * 10.0f;
	collision::Aabb3 walked = { .min = focus.min + (Vec3) { stride, 0, stride }, .max = focus.max + (Vec3) { stride, 0, stride } };

	three::ShadowMap third;
	third.defaults();
	third.size = 1024;
	third.fit(light, bounds, walked);

	bool moved = false;
	for (uint i = 0; i < 16; i++)
	{
		if (a.m[i] != third.light_view_projection.m[i]) moved = true;
	}
	test::@check(moved, "a ten-texel move did not change the fit at all");
}
