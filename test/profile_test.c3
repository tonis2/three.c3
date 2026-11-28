module three_tests::profile;

import std::core::test;
import vk;
import three;
import three_tests::device;

fn void presets_set_platform_defaults() @test
{
	three::RenderProfile desk = three::render_profile(DESKTOP);
	test::@check(desk.configured && desk.preset == DESKTOP, "desktop preset configured");
	test::@check(desk.views == 1 && desk.msaa == 1, "desktop is 1 view, 1x MSAA");
	test::@check(desk.depth_prepass && desk.shadow_filter == FOUR_TAP, "desktop uses prepass and 4-tap shadows");
	test::@check(desk.frame_skip && desk.scene_cache && !desk.lazy_post_images, "desktop keeps frame skip and scene cache");

	three::RenderProfile pcvr = three::render_profile(PCVR);
	test::@check(pcvr.views == 2 && pcvr.msaa == three::XR_MSAA, "pcvr is stereo MSAA");
	test::@check(pcvr.shadow_filter == FOUR_TAP && !pcvr.foveation, "pcvr keeps 4-tap shadows and off foveation");
	test::@check(!pcvr.frame_skip && !pcvr.scene_cache && pcvr.lazy_post_images, "pcvr skips desktop caching and defers post images");

	three::RenderProfile quest = three::render_profile(QUEST);
	test::@check(quest.views == 2 && quest.msaa == three::XR_MSAA, "quest is stereo MSAA");
	test::@check(!quest.depth_prepass && quest.shadow_filter == ONE_TAP, "quest disables prepass and uses 1-tap shadows");
	test::@check(quest.foveation && quest.foveation_level == MEDIUM, "quest enables medium foveation");
	test::@check(quest.xr_layer_filter == SUPER && quest.lazy_post_images, "quest uses Super Resolution and lazy post");
}

fn void override_parser_applies_valid_values_and_rejects_bad_ones() @test
{
	three::RenderProfile p = three::render_profile(DESKTOP);
	test::@check(p.apply_tune("profile=quest"), "switching preset via tune works");
	test::@check(p.preset == QUEST && p.shadow_filter == ONE_TAP, "preset switch applied");

	test::@check(p.apply_tune("msaa=2"), "msaa=2 accepted");
	test::@check(p.msaa == 2, "msaa updated to 2");
	test::@check(!p.apply_tune("msaa=8"), "unsupported msaa rejected");
	test::@check(p.msaa == 2, "rejected msaa leaves value unchanged");

	test::@check(p.apply_tune("xr_scale=0.85"), "xr_scale accepted");
	test::@check(p.xr_render_scale > 0.84f && p.xr_render_scale < 0.86f, "xr_scale updated");
	test::@check(!p.apply_tune("xr_scale=3.0"), "out-of-range xr_scale rejected");

	test::@check(p.apply_tune("shadow_filter=4tap") && p.shadow_filter == FOUR_TAP, "shadow_filter=4tap");
	test::@check(p.apply_tune("prepass=1") && p.depth_prepass, "prepass=1");
	test::@check(p.apply_tune("direct_eyes=0") && p.direct_eyes == NEVER, "direct_eyes=0 -> NEVER");
	test::@check(p.apply_tune("direct_eyes=1") && p.direct_eyes == ALWAYS, "direct_eyes=1 -> ALWAYS");
	test::@check(p.apply_tune("foveation=high") && p.foveation && p.foveation_level == HIGH, "foveation=high");
	test::@check(p.apply_tune("foveation=off") && !p.foveation && p.foveation_level == OFF, "foveation=off");
	test::@check(!p.apply_tune("no_equals_sign"), "malformed tune rejected");
	test::@check(!p.apply_tune("unknown_key=1"), "unknown tune rejected");
}

fn void options_resolve_profile_for_vr_and_quest_preview() @test
{
	three::Options vr_opts = { .vr = true };
	vr_opts.tune_list[0] = "msaa=2";
	vr_opts.tune_list[1] = "shadow_filter=1tap";
	vr_opts.tune_count = 2;
	three::RenderProfile vr = vr_opts.resolve_profile();
	test::@check(vr.preset == PCVR && vr.views == 2 && vr.msaa == 2 && vr.shadow_filter == ONE_TAP,
		"vr options resolve to PCVR with tune overrides");

	three::Options preview_opts = { .quest = 0.8f };
	three::RenderProfile preview = preview_opts.resolve_profile();
	test::@check(preview.preset == QUEST && preview.views == 1 && preview.headset_density > 0.0f
		&& !preview.lazy_post_images, "quest preview keeps single-view flat target with headset density");
}

fn void sun_only_scene_skips_cluster_compute_until_local_light_added() @test
{
	three::Renderer* renderer = device::borrow(128, 128);
	defer device::release();

	three::JsRuntime runtime;
	runtime.open(&renderer.pass, renderer)!!;
	defer runtime.close();

	three::RunResult res = runtime.run(`
		const scene = new three.Scene();
		const m = new three.Mesh(new three.BoxGeometry(1, 1, 1), new three.MeshLambertMaterial({ color: 0x80a0c0 }));
		scene.add(m);
		three.camera.lookAt(0, 0, 0);
		three.camera.orbit(0, 0.2, 3);
	`);
	defer res.free();
	test::@check(res.ok, "scene built: %s", res.error);

	uint before = renderer.pass.cluster_dispatches;
	renderer.capture()!!.free();
	test::@check(renderer.pass.cluster_dispatches == before,
		"sun-only scene skipped cluster compute (was %d, now %d)", before, renderer.pass.cluster_dispatches);

	three::RunResult lit = runtime.run(`
		three.lights.add({ position: [1, 2, 1], range: 6, color: 0xffaa66, intensity: 2 });
	`);
	defer lit.free();
	test::@check(lit.ok, "point light added: %s", lit.error);

	renderer.capture()!!.free();
	test::@check(renderer.pass.cluster_dispatches > before,
		"adding a local light ran cluster compute");
}

fn void lazy_xr_target_defers_hdr_and_color_until_needed() @test
{
	three::Engine* engine = mem::new(three::Engine);
	defer mem::free(engine);
	defer engine.close();

	three::RenderProfile p = three::render_profile(QUEST);
	p.foveation = false;
	p.foveation_level = OFF;
	engine.open(128, 64, headless: true, views: 2, samples: 4, profile: p)!!;

	three::Renderer* r = &engine.renderer;
	if (r.target.views < 2) return;

	test::@check(r.target.color == null, "lazy XR target did not allocate target.color at init");
	test::@check(r.post.bytes() == 0, "lazy XR target did not allocate HDR post images at init");

	r.pass.load_triangle(&r.gpu)!!;
	vk::Extent2D eye = r.target.view_extent;
	three::LayeredImage eyes = r.gpu.create_layered_image(three::TARGET_COLOR_FORMAT, eye, 2,
		IMAGE_USAGE_COLOR_ATTACHMENT_BIT | IMAGE_USAGE_TRANSFER_DST_BIT)!!;
	defer eyes.destroy(&r.gpu);

	r.render_into(eyes.whole.image, eyes.whole.view, eye, eyes: true)!!;
	r.gpu.handle.waitIdle();
	test::@check(r.target.color == null, "direct-to-eyes frame kept target.color unallocated");
	test::@check(r.post.bytes() == 0, "direct-to-eyes frame kept HDR post images unallocated");
	test::@check(r.pass.frame_key == three::KEY_SEED, "direct-to-eyes frame skipped fold_frame_key");

	// Falling back to capture() allocates target.color and HDR post images seamlessly.
	r.capture()!!.free();
	test::@check(r.target.color != null, "capture allocated target.color on demand");
	test::@check(r.post.bytes() > 0, "capture allocated HDR post images on demand");
}

fn void js_platform_render_and_xr_scale_apis() @test
{
	three::Renderer* renderer = device::borrow(128, 128);
	defer device::release();
	defer
	{
		renderer.pass.one_tap_shadows = false;
		renderer.profile.shadow_filter = FOUR_TAP;
		renderer.profile.direct_eyes = AUTO;
		renderer.eyes_through_chain = false;
		renderer.xr_display = {};
	}

	three::JsRuntime runtime;
	runtime.open(&renderer.pass, renderer)!!;
	defer runtime.close();

	three::RunResult res = runtime.run(`
		const p = three.platform;
		if (!p.os || !p.profile || typeof p.tiler !== 'boolean' || typeof p.multiview !== 'boolean') {
			throw new Error('bad three.platform: ' + JSON.stringify(p));
		}
		if (three.tuning.shadowFilter !== '4tap') throw new Error('expected 4tap');
		three.tuning.shadowFilter = '1tap';
		if (three.tuning.shadowFilter !== '1tap') throw new Error('expected 1tap');

		three.tuning.directEyes = 'never';
		if (three.tuning.directEyes !== 'never') throw new Error('expected never');
		three.tuning.directEyes = 'auto';

		three.xr.renderScale = 0.85;
		if (Math.abs(three.xr.renderScale - 0.85) > 0.001) throw new Error('renderScale not stored');
		const size = three.xr.eyeSize;
		if (typeof size.width !== 'number' || typeof size.height !== 'number') throw new Error('bad eyeSize');

		let threw = false;
		try { three.xr.renderScale = 2.5; } catch (_) { threw = true; }
		if (!threw) throw new Error('out-of-range renderScale should throw');
		try { three.tuning.shadowFilter = 'bad'; threw = false; } catch (_) { threw = true; }
		if (!threw) throw new Error('invalid shadowFilter should throw');
		return p.profile;
	`);
	defer res.free();
	test::@check(res.ok, "JS platform/render/xr scale APIs failed: %s", res.error);
	test::@check(renderer.pass.one_tap_shadows, "shadowFilter='1tap' reached MeshPass.one_tap_shadows");
	test::@check(renderer.xr_display.scale_request > 0.84f && renderer.xr_display.scale_request < 0.86f,
		"three.xr.renderScale queued deferred scale_request");
}
