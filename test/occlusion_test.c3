<*
 Ambient occlusion is a depth prepass whose result belongs only to indirect
 light. These checks keep both halves of that contract: a real corner must be
 darkened, while direct light, emissive colour, and the scene clear must remain
 byte-identical when the pass is toggled.

	`c3c test --trust=full --test-noleak --test-filter three_tests::occlusion`
*>
module three_tests::occlusion;

import three;
import three_tests::device;
import image;
import std::core::test;
import std::math;
import vk;
import slang;

const uint W = 192;
const uint H = 144;

const three::ShaderEntry[2] AO_BOTH_STAGES = {
	{ "vertexMain", slang::STAGE_VERTEX },
	{ "fragmentMain", slang::STAGE_FRAGMENT },
};

macro @with_js(; @body(three::JsRuntime* run, three::Renderer* renderer))
{
	three::Renderer* renderer = device::borrow(W, H);
	defer device::release();

	three::JsRuntime runtime;
	runtime.open(&renderer.pass, renderer)!!;
	defer runtime.close();

	@body(&runtime, renderer);
}

fn sz differing_rgb_bytes(image::Image* a, image::Image* b)
{
	if (a.width != b.width || a.height != b.height) return sz::max;
	sz bpp = a.bytes_per_pixel();
	sz changed = 0;
	for (sz i = 0; i < a.pixels.len; i++)
	{
		if (i % bpp != 3 && a.pixels[i] != b.pixels[i]) changed++;
	};
	return changed;
}

fn long rgb_sum(image::Image* img)
{
	sz bpp = img.bytes_per_pixel();
	long sum = 0;
	for (sz i = 0; i < img.pixels.len; i++)
	{
		if (i % bpp != 3) sum += (long)img.pixels[i];
	}
	return sum;
}

const String CORNER = `
	const scene = new three.Scene();
	scene.background = 0x101820;
	three.light.intensity = 0;
	three.light.ambient = 0.85;
	const material = MATERIAL;
	const floor = new three.Mesh(new three.BoxGeometry(10, .2, 10), material);
	floor.position.y = -.1;
	scene.add(floor);
	const wall = new three.Mesh(new three.BoxGeometry(.25, 3, 7), material);
	wall.position.set(-1.0, 1.5, 0);
	scene.add(wall);
	const block = new three.Mesh(new three.BoxGeometry(2, 2, 2), material);
	block.position.set(.1, 1, 0);
	scene.add(block);
	three.camera.target.set(0, .7, 0);
	three.camera.orbit(35, 24, 9);
`;

fn void check_corner(String material_name, String material_source)
{
	@with_js(; three::JsRuntime* run, three::Renderer* renderer)
	{
		@pool()
		{
			String source = CORNER.treplace("MATERIAL", material_source);
			three::RunResult built = run.run(source);
			defer built.free();
			test::@check(built.ok, "%s corner built: %s", material_name, built.error);

			image::Image open = renderer.capture()!!;
			defer open.free();

			three::RunResult enabled = run.run(`
				three.light.occlusion = { enabled: true, radius: 1, intensity: 1, bias: 0.02 };
			`);
			defer enabled.free();
			test::@check(enabled.ok, "%s AO enabled: %s", material_name, enabled.error);

			image::Image occluded = renderer.capture()!!;
			defer occluded.free();
			sz changed = differing_rgb_bytes(&open, &occluded);
			test::@check(changed > 150,
				"%s has enough changed pixels to prove the corner was sampled, got %d bytes", material_name, changed);
			test::@check(changed < (sz)W * (sz)H * 2,
				"%s AO is local rather than a whole-frame tint, got %d changed bytes", material_name, changed);
			test::@check(rgb_sum(&occluded) + 300 < rgb_sum(&open),
				"%s AO darkens the ambient corner: %d then %d", material_name,
				rgb_sum(&open), rgb_sum(&occluded));
		};
	};
}

fn void ambient_corners_darken_in_builtin_materials() @test
{
	check_corner("built-in", `new three.MeshLambertMaterial({ color: 0xd0d0d0 })`);
}

fn void ambient_corners_darken_in_layered_materials() @test
{
	check_corner("LayeredMaterial", `new three.LayeredMaterial({ layers: [{ tint: [0.8, 0.8, 0.8] }] })`);
}

// Render an asymmetric mesh so equality cannot be won by accidentally drawing
// only the clear colour. The centre block also ensures the depth prepass works.
fn void check_unchanged(String name, String lighting, String material)
{
	@with_js(; three::JsRuntime* run, three::Renderer* renderer)
	{
		@pool()
		{
			String source = string::tformat(`
				const scene = new three.Scene();
				scene.background = 0x19334d;
				%s
				const m = %s;
				const ground = new three.Mesh(new three.BoxGeometry(8, .2, 6), m);
				ground.position.y = -.1; scene.add(ground);
				const box = new three.Mesh(new three.BoxGeometry(1.5, 2, 1.5), m);
				box.position.set(.5, 1, 0); scene.add(box);
				three.camera.target.set(0, .6, 0); three.camera.orbit(32, 22, 8);
			`, lighting, material);
			three::RunResult built = run.run(source);
			defer built.free();
			test::@check(built.ok, "%s scene built: %s", name, built.error);

			image::Image off = renderer.capture()!!;
			defer off.free();
			three::RunResult enabled = run.run(`three.light.occlusion.enabled = true`);
			defer enabled.free();
			test::@check(enabled.ok, "%s AO toggle worked: %s", name, enabled.error);
			image::Image on = renderer.capture()!!;
			defer on.free();

			test::@check(differing_rgb_bytes(&off, &on) == 0,
				"%s is outside ambient occlusion, but %d RGB bytes changed",
				name, differing_rgb_bytes(&off, &on));
		};
	};
}

fn void direct_light_is_not_occluded() @test
{
	check_unchanged("direct light", `three.light.set([.3, 1, .4], 0);`,
		`new three.MeshLambertMaterial({ color: 0xc0a070 })`);
}

fn void emissive_light_is_not_occluded() @test
{
	check_unchanged("emissive colour", `three.light.ambient = 0; three.light.intensity = 0;`,
		`new three.MeshLambertMaterial({ color: 0x000000, emissive: 0xd06020, emissiveIntensity: 1 })`);
}

fn void direct_and_emissive_layered_shading_are_not_occluded() @test
{
	check_unchanged("LayeredMaterial direct light",
		`three.light.set([.3, 1, .4], 0);`,
		`new three.LayeredMaterial({ layers: [{ tint: [0.75, 0.6, 0.4] }] })`);
	check_unchanged("LayeredMaterial emissive",
		`three.light.ambient = 0; three.light.intensity = 0;`,
		`new three.LayeredMaterial({ layers: [{ emissive: new three.DataTexture(
			new Uint8Array([220, 90, 30, 255]), 1, 1, { colorSpace: three.SRGBColorSpace }) }] })`);
}

fn void a_fully_cut_out_card_does_not_occlude_the_floor() @test
{
	@with_js(; three::JsRuntime* run, three::Renderer* renderer)
	{
		three::RunResult built = run.run(`
			const scene = new three.Scene();
			scene.background = 0x101820;
			three.light.intensity = 0; three.light.ambient = 0.8;
			const floor = new three.Mesh(new three.BoxGeometry(8, .2, 8));
			floor.position.y = -.1; scene.add(floor);
			const clear = new three.DataTexture(new Uint8Array([255, 255, 255, 0]), 1, 1, {
				colorSpace: three.LinearSRGBColorSpace, generateMipmaps: false,
			});
			const leaf = new three.MeshLambertMaterial({ map: clear, alphaTest: 0.5 });
			const card = new three.Mesh(new three.PlaneGeometry(4, 4), leaf);
			card.rotation.x = -Math.PI / 2; card.position.y = 0.6; scene.add(card);
			three.camera.target.set(0, 0, 0); three.camera.orbit(25, 55, 8);
		`);
		defer built.free();
		test::@check(built.ok, "cutout AO scene built: %s", built.error);

		image::Image off = renderer.capture()!!;
		defer off.free();
		three::RunResult enabled = run.run(`
			three.light.occlusion = { enabled: true, radius: 1, intensity: 1, bias: 0.02 };
		`);
		defer enabled.free();
		test::@check(enabled.ok, "AO enabled for the cutout: %s", enabled.error);
		image::Image on = renderer.capture()!!;
		defer on.free();

		// The positive corner tests prove that this pass normally changes a frame.
		// Here the only possible blocker is discarded by alphaTest in both passes.
		test::@check(differing_rgb_bytes(&off, &on) == 0,
			"a fully transparent card entered AO depth and changed %d RGB bytes",
			differing_rgb_bytes(&off, &on));
	};
}

fn void the_background_is_not_occluded() @test
{
	@with_js(; three::JsRuntime* run, three::Renderer* renderer)
	{
		three::RunResult built = run.run(`
			const scene = new three.Scene();
			scene.background = 0x2868a0;
			three.light.occlusion.enabled = false;
		`);
		defer built.free();
		test::@check(built.ok, "background scene built: %s", built.error);
		image::Image off = renderer.capture()!!;
		defer off.free();

		three::RunResult enabled = run.run(`three.light.occlusion.enabled = true`);
		defer enabled.free();
		test::@check(enabled.ok, "AO enabled over an empty scene: %s", enabled.error);
		image::Image on = renderer.capture()!!;
		defer on.free();
		test::@check(differing_rgb_bytes(&off, &on) == 0,
			"the clear colour changed in %d bytes", differing_rgb_bytes(&off, &on));
	};
}

fn void disabled_ao_allocates_nothing_and_enable_builds_the_target_extent() @test
{
	@with_js(; three::JsRuntime* run, three::Renderer* renderer)
	{
		three::RunResult built = run.run(`
			const scene = new three.Scene();
			scene.add(new three.Mesh(new three.BoxGeometry(2, 2, 2)));
			three.camera.frameAll();
		`);
		defer built.free();
		test::@check(built.ok, "lifecycle scene built: %s", built.error);

		renderer.capture()!!.free();
		three::AmbientOcclusion* ao = &renderer.pass.ambient_occlusion;
		vk::Image before = ao.image;
		usz before_bytes = ao.bytes();
		test::@check(!ao.live, "disabled AO reported a live pass");

		three::RunResult enabled = run.run(`three.light.occlusion.enabled = true`);
		defer enabled.free();
		test::@check(enabled.ok, "lifecycle AO toggle worked: %s", enabled.error);
		renderer.capture()!!.free();
		test::@check(ao.image != null, "enabled AO did not create its depth image");
		test::@check(ao.live, "enabled AO did not record a depth pass");
		test::@check(ao.extent.width == W && ao.extent.height == H,
			"AO depth extent is %dx%d, target is %dx%d", ao.extent.width, ao.extent.height, W, H);

		three::RunResult disabled = run.run(`three.light.occlusion.enabled = false`);
		defer disabled.free();
		renderer.capture()!!.free();
		test::@check(!ao.live, "turning AO off still records its pass");
		test::@check(ao.image != null, "toggle discarded the reusable AO allocation");
		test::@check(before == null || before == ao.image || before_bytes == ao.bytes(),
			"disabled AO replaced an existing reusable allocation");
	};
}

fn void settings_are_independent_and_scene_local() @test
{
	@with_js(; three::JsRuntime* run, three::Renderer* renderer)
	{
		three::RunResult defaults = run.run(`
			const o = three.light.occlusion;
			return [o.enabled, o.radius, o.intensity, o.bias].join(',');
		`);
		defer defaults.free();
		test::@check(defaults.ok, "defaults read: %s", defaults.error);
		test::@check(defaults.value == `"false,1,1,0.019999999552965164"` || defaults.value == `"false,1,1,0.02"`,
			"AO defaults are false,1,1,.02, got %s", defaults.value);

		three::RunResult changed = run.run(`
			three.light.occlusion = { enabled: true, radius: 2 };
			three.light.occlusion.intensity = 0.5;
			three.light.occlusion.bias = 0.03125;
			const o = three.light.occlusion;
			return [o.enabled, o.radius, o.intensity, o.bias].join(',');
		`);
		defer changed.free();
		test::@check(changed.ok, "settings changed independently: %s", changed.error);
		test::@check(changed.value == `"true,2,0.5,0.03125"`, "settings survived each other: %s", changed.value);

		three::RunResult reset = run.run(`
			new three.Scene();
			const o = three.light.occlusion;
			return [o.enabled, o.radius, o.intensity, o.bias].join(',');
		`);
		defer reset.free();
		test::@check(reset.ok, "new scene reset AO: %s", reset.error);
		test::@check(reset.value == defaults.value, "new Scene restores defaults: %s then %s", defaults.value, reset.value);
	};
}

fn void invalid_settings_are_refused_without_partial_changes() @test
{
	@with_js(; three::JsRuntime* run, three::Renderer* renderer)
	{
		three::RunResult result = run.run(`
			const refused = [];
			for (const set of [
				() => three.light.occlusion = { radius: 0 },
				() => three.light.occlusion.radius = NaN,
				() => three.light.occlusion.intensity = -0.01,
				() => three.light.occlusion.intensity = 1.01,
				() => three.light.occlusion.bias = -0.01,
				() => three.light.occlusion.bias = Infinity,
			]) {
				try { set(); refused.push(false); } catch (_) { refused.push(true); }
			}
			const o = three.light.occlusion;
			return refused.join(',') + '|' + [o.enabled, o.radius, o.intensity, o.bias].join(',');
		`);
		defer result.free();
		test::@check(result.ok, "invalid-setting probes ran: %s", result.error);
		test::@check(result.value == `"true,true,true,true,true,true|false,1,1,0.019999999552965164"`
			|| result.value == `"true,true,true,true,true,true|false,1,1,0.02"`,
			"invalid AO values throw and preserve defaults, got %s", result.value);
	};
}

fn void a_partial_scene_view_conservatively_disables_ao() @test
{
	@with_js(; three::JsRuntime* run, three::Renderer* renderer)
	{
		three::RunResult built = run.run(CORNER.treplace("MATERIAL", `new three.MeshLambertMaterial()`));
		defer built.free();
		test::@check(built.ok, "partial-view scene built: %s", built.error);
		three::RunResult enabled = run.run(`three.light.occlusion.enabled = true`);
		defer enabled.free();

		renderer.pass.view_rect = { 0.1, 0.1, 0.8, 0.8 };
		renderer.capture()!!.free();
		test::@check(renderer.pass.scene_rect_partial, "the requested scene view was not partial");
		test::@check(!renderer.pass.ambient_occlusion.live,
			"AO sampled a full-frame depth image while drawing a partial scene view");
	};
}

const String TWELVE_SAMPLES = `float3 shade(Surface s) {
	float3 c = t0.Sample(s.uv).rgb * t1.Sample(s.uv).rgb * t2.Sample(s.uv).rgb;
	c *= t3.Sample(s.uv).rgb * t4.Sample(s.uv).rgb * t5.Sample(s.uv).rgb;
	c *= t6.Sample(s.uv).rgb * t7.Sample(s.uv).rgb * t8.Sample(s.uv).rgb;
	c *= t9.Sample(s.uv).rgb * t10.Sample(s.uv).rgb * t11.Sample(s.uv).rgb;
	return c * lambert(s.normal);
}`;

fn void twelve_live_material_samplers_keep_the_portable_layout_and_ao_fallback() @test
{
	three::MaterialTexture[12] textures;
	@pool()
	{
		for (uint i = 0; i < 12; i++) textures[i] = { string::tformat("t%d", i) };
		String source = three::material_source(TWELVE_SAMPLES, {}, mem, textures[..])!!;
		defer source.free(mem);
		three::ShaderModule mod = three::compile_slang(source, "material.slang", AO_BOTH_STAGES[..])!!;
		defer mod.free();
		test::@check(mod.ok, "twelve sampled textures plus lambert compile: %s", mod.diagnostic);
		uint samplers = 0;
		foreach (binding : mod.layout.bindings)
			if (binding.type == DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER) samplers += binding.count;
		test::@check(samplers <= 16,
			"portable material sampler count is %d, over 16", samplers);
	};

	@with_js(; three::JsRuntime* run, three::Renderer* renderer)
	{
		three::RunResult built = run.run(`
			const tex = new three.DataTexture(new Uint8Array([255,255,255,255]), 1, 1);
			const ts = {}; for (let i = 0; i < 12; i++) ts['t' + i] = tex;
			const material = new three.ShaderMaterial({ textures: ts, fragment:
				'float3 shade(Surface s) {'
				+ 'float3 c=t0.Sample(s.uv).rgb*t1.Sample(s.uv).rgb*t2.Sample(s.uv).rgb;'
				+ 'c*=t3.Sample(s.uv).rgb*t4.Sample(s.uv).rgb*t5.Sample(s.uv).rgb;'
				+ 'c*=t6.Sample(s.uv).rgb*t7.Sample(s.uv).rgb*t8.Sample(s.uv).rgb;'
				+ 'c*=t9.Sample(s.uv).rgb*t10.Sample(s.uv).rgb*t11.Sample(s.uv).rgb;'
				+ 'return c*lambert(s.normal);}' });
			const scene = new three.Scene();
			scene.add(new three.Mesh(new three.PlaneGeometry(2,2), material));
			three.light.set([0,0,1], .3); three.camera.frameAll();
		`);
		defer built.free();
		test::@check(built.ok, "twelve-sampler material rendered: %s", built.error);
		image::Image off = renderer.capture()!!;
		defer off.free();
		three::RunResult enabled = run.run(`three.light.occlusion.enabled = true`);
		defer enabled.free();
		image::Image on = renderer.capture()!!;
		defer on.free();
		test::@check(rgb_sum(&off) > 1000, "twelve-sampler control drew no visible material");
		test::@check(differing_rgb_bytes(&off, &on) == 0,
			"AO fallback changed a saturated twelve-sampler material by %d bytes",
			differing_rgb_bytes(&off, &on));
	};
}
