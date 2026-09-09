<*
 Forward+ lighting regressions.

 `c3c test --trust=full --test-filter three_tests::cluster`
*>
module three_tests::cluster;

import three;
import three_tests::device;
import image;
import std::core::test;
import std::core::string;

const uint W = 160;
const uint H = 120;

fn void scene(three::Renderer* renderer)
{
	three::AssetId plane = renderer.pass.assets.primitive(&renderer.gpu, three::plane_shape(12, 9))!!;
	renderer.pass.scene.add_mesh(plane, 0);
	renderer.pass.camera.target = { 0, 0, 0 };
	renderer.pass.camera.distance = 7;
	renderer.pass.camera.yaw = 0;
	renderer.pass.camera.pitch = 0;
	renderer.pass.lighting = { .count = 1, .next_light_id = 2, .ambient = 0,
		.lights = { [0] = { .direction = { 0, 0, 1, 0 }, .color = { 0, 0, 0, 0 },
			.meta = { 1, 0xffffffff, 0, 0 } } } };
}

fn void points(three::Renderer* renderer, uint count, bool overlap)
{
	for (uint i = 0; i < count; i++)
	{
		float x = overlap ? 0.0f : ((float)(i % 7) - 3.0f) * 0.7f;
		float y = overlap ? 0.0f : ((float)((i / 7) % 5) - 2.0f) * 0.55f;
		renderer.pass.lighting.lights[i + 1] = {
			.direction = { x, y, 2.0f + (float)(i % 3) * 0.15f, overlap ? 20.0f : 4.5f },
			.color = { 0.018f, 0.014f, 0.011f, 1 },
			.meta = { i + 2, 0xffffffff, 1, 0 },
		};
	}
	renderer.pass.lighting.count = count + 1;
	renderer.pass.lighting.next_light_id = count + 2;
}

fn uint max_rgb_difference(image::Image* a, image::Image* b)
{
	uint largest = 0;
	sz bpp = a.bytes_per_pixel();
	for (sz p = 0; p < a.pixels.len; p += bpp)
	{
		for (sz c = 0; c < 3; c++)
		{
			uint av = (uint)(char)a.pixels[p + c];
			uint bv = (uint)(char)b.pixels[p + c];
			uint difference = av > bv ? av - bv : bv - av;
			if (difference > largest) largest = difference;
		}
	}
	return largest;
}

fn sz differing_rgb(image::Image* a, image::Image* b)
{
	sz changed = 0;
	sz bpp = a.bytes_per_pixel();
	for (sz p = 0; p < a.pixels.len; p += bpp)
	{
		if (a.pixels[p] != b.pixels[p] || a.pixels[p + 1] != b.pixels[p + 1]
			|| a.pixels[p + 2] != b.pixels[p + 2]) changed++;
	}
	return changed;
}

fn long rgb_sum(image::Image* shot)
{
	long sum = 0;
	sz bpp = shot.bytes_per_pixel();
	for (sz p = 0; p < shot.pixels.len; p += bpp)
	{
		sum += (long)(char)shot.pixels[p];
		sum += (long)(char)shot.pixels[p + 1];
		sum += (long)(char)shot.pixels[p + 2];
	}
	return sum;
}

<*
 A small caster still makes a measurable contact shadow at both ends of a local
 light's useful depth range. The far case uses a LayeredMaterial because its
 generated shading body has a separate copy of the shared lighting template.

 Bias zero exercises the automatic projection-aware offset. Comparing the same
 frame with sampling disabled isolates the shadow from inverse-square
 attenuation and tone mapping.
*>
fn void local_bias_keeps_near_and_far_contact_shadows_in_both_material_templates() @test
{
	three::Renderer* renderer = device::borrow(W, H);
	defer device::release();
	three::JsRuntime runtime;
	runtime.open(&renderer.pass, renderer)!!;
	defer runtime.close();

	three::RunResult built = runtime.run(`
		const scene = new three.Scene();
		globalThis.contactPlain = new three.MeshLambertMaterial({ color: 0xb8b8b8 });
		globalThis.contactLayered = new three.LayeredMaterial({
			layers: [{ name: 'soil', tint: [0.72, 0.72, 0.72], opacity: 0.35 }]
		});
		globalThis.contactGround = new three.Mesh(new three.PlaneGeometry(18, 18), contactPlain);
		contactGround.rotation.x = -Math.PI / 2; scene.add(contactGround);
		globalThis.contactCaster = new three.Mesh(new three.BoxGeometry(0.7, 0.7, 0.7),
			new three.MeshLambertMaterial({ color: 0x909090 }));
		contactCaster.position.set(0, 0.35, 0); scene.add(contactCaster);
		three.light.intensity = 0; three.light.ambient = 0;
		globalThis.contactLamp = three.lights.add({ shape: 'spot', position: [2, 3, 1],
			direction: [-2, -3, -1], range: 30, innerAngle: 0.75, outerAngle: 1.05,
			intensity: 80 });
		globalThis.contactPoint = three.lights.add({ position: [6, 12, 3], range: 30, intensity: 0 });
		globalThis.contactArea = three.lights.add({ shape: 'rectangle', position: [4, 8, 2],
			right: [1, 0, 0], up: [0, 0, -1], width: 0.75, height: 0.75,
			range: 30, intensity: 0 });
		three.lights.shadow = { enabled: true, size: 512, bias: 0, intensity: 1 };
		three.camera.target.set(0, 0, 0); three.camera.orbit(28, 24, 8);
	`);
	defer built.free();
	test::@check(built.ok, "the local contact-shadow scene built: %s", built.error);

	String[4] setup = {
		`contactGround.material=contactPlain;contactPoint.intensity=0;contactArea.intensity=0;contactLamp.intensity=80`,
		`contactGround.material=contactLayered;contactPoint.intensity=0;contactArea.intensity=0;
		 three.lights.remove(contactLamp);contactLamp=three.lights.add({shape:'spot',position:[6,12,3],
		 direction:[-6,-12,-3],range:30,innerAngle:0.75,outerAngle:1.05,intensity:1280})`,
		`contactGround.material=contactPlain;contactLamp.intensity=0;contactArea.intensity=0;contactPoint.intensity=1280`,
		`contactGround.material=contactPlain;contactLamp.intensity=0;contactPoint.intensity=0;contactArea.intensity=700`,
	};
	String[4] distance = { "near spot", "far spot", "far point", "area" };
	for (uint i = 0; i < 4; i++)
	{
		three::RunResult placed = runtime.run(setup[i]);
		defer placed.free();
		test::@check(placed.ok, "the %s contact-shadow case was placed: %s", distance[i], placed.error);
		image::Image shadowed = renderer.capture()!!;
		defer shadowed.free();
		three::RunResult off = runtime.run(`three.lights.shadow.enabled=false`);
		defer off.free();
		test::@check(off.ok, "local shadows were disabled: %s", off.error);
		image::Image open = renderer.capture()!!;
		defer open.free();
		long darkening = rgb_sum(&open) - rgb_sum(&shadowed);
		sz changed = differing_rgb(&open, &shadowed);
		test::@check(changed > 20,
			"the %s local shadow changes receiver pixels, got %d", distance[i], changed);
		test::@check(darkening > 600,
			"the %s local contact shadow measurably darkens the receiver, got %d", distance[i], darkening);
		three::RunResult on = runtime.run(`three.lights.shadow.enabled=true;contactCaster.visible=false`);
		defer on.free();
		test::@check(on.ok, "local shadows were restored: %s", on.error);
		image::Image bare_shadowed = renderer.capture()!!;
		defer bare_shadowed.free();
		three::RunResult bare_off = runtime.run(`three.lights.shadow.enabled=false`);
		defer bare_off.free();
		test::@check(bare_off.ok, "the bare receiver's shadows were disabled: %s", bare_off.error);
		image::Image bare_open = renderer.capture()!!;
		defer bare_open.free();
		test::@check(max_rgb_difference(&bare_shadowed, &bare_open) <= 1,
			"the %s bare receiver does not self-shadow (largest channel error %d)",
			distance[i], max_rgb_difference(&bare_shadowed, &bare_open));
		three::RunResult restore = runtime.run(`three.lights.shadow.enabled=true;contactCaster.visible=true`);
		defer restore.free();
		test::@check(restore.ok, "the contact caster was restored: %s", restore.error);
	}
}

<*
 Static caching changes how depth is assembled, not the image. Reclassifying the
 same caster as dynamic must therefore leave every receiver pixel unchanged.
*>
fn void cached_and_dynamic_local_contact_shadows_are_identical() @test
{
	three::Renderer* renderer = device::borrow(W, H);
	defer device::release();
	three::JsRuntime runtime;
	runtime.open(&renderer.pass, renderer)!!;
	defer runtime.close();
	three::RunResult built = runtime.run(`
		const scene = new three.Scene();
		const ground = new three.Mesh(new three.PlaneGeometry(12, 12));
		ground.rotation.x = -Math.PI / 2; ground.static = true; scene.add(ground);
		globalThis.cacheContact = new three.Mesh(new three.BoxGeometry(0.8, 0.8, 0.8));
		cacheContact.position.y = 0.4; cacheContact.static = true; scene.add(cacheContact);
		three.light.intensity = 0; three.light.ambient = 0;
		three.lights.add({ shape: 'spot', position: [3, 7, 2], direction: [-3, -7, -2],
			range: 18, innerAngle: 0.7, outerAngle: 1.0, intensity: 420 });
		three.lights.shadow = { enabled: true, size: 512, bias: 0, intensity: 1 };
		three.camera.target.set(0, 0, 0); three.camera.orbit(32, 22, 7);
	`);
	defer built.free();
	test::@check(built.ok, "the cache-equivalence scene built: %s", built.error);
	renderer.capture()!!.free();
	image::Image cached = renderer.capture()!!;
	defer cached.free();
	three::RunResult dynamic = runtime.run(`cacheContact.static=false`);
	defer dynamic.free();
	test::@check(dynamic.ok, "the caster became dynamic: %s", dynamic.error);
	image::Image overlaid = renderer.capture()!!;
	defer overlaid.free();
	test::@check(differing_rgb(&cached, &overlaid) == 0,
		"cached and dynamic local contact shadows are byte-identical");
}

fn void clustered_matches_the_all_light_oracle_past_eight_and_at_edges() @test
{
	three::Renderer* renderer = device::borrow(W, H);
	defer device::release();
	scene(renderer);
	points(renderer, 31, false);
	// A rotated view exercises clip-plane extraction rather than a world-axis
	// projected-radius shortcut. The spread reaches both screen edges and several
	// logarithmic depth slices.
	renderer.pass.camera.yaw = 37;
	renderer.pass.camera.pitch = 13;
	renderer.pass.cluster_bruteforce = true;
	image::Image reference = renderer.capture()!!;
	defer reference.free();
	renderer.pass.cluster_bruteforce = false;
	image::Image clustered = renderer.capture()!!;
	defer clustered.free();
	test::@check(max_rgb_difference(&reference, &clustered) <= 2,
		"31 clustered lights match the all-light image (largest channel error %d)",
		max_rgb_difference(&reference, &clustered));
}

<*
 Screen rows and clip-space Y run in opposite numeric directions under the
 geometry pass's negative-height viewport. Small lights above and below centre
 catch a cluster builder that mirrors them vertically. Both surface templates
 read the same cluster lists and must match the all-light oracle.
*>
fn void asymmetric_vertical_clusters_match_both_material_oracles() @test
{
	three::Renderer* renderer = device::borrow(W, H);
	defer device::release();
	three::JsRuntime runtime;
	runtime.open(&renderer.pass, renderer)!!;
	defer runtime.close();
	three::RunResult built = runtime.run(`
		const scene=new three.Scene();
		globalThis.clusterPlain=new three.MeshLambertMaterial({color:0xffffff});
		globalThis.clusterLayered=new three.LayeredMaterial({
			layers:[{name:'base',tint:[1,1,1],opacity:1}]
		});
		globalThis.clusterPlane=new three.Mesh(new three.PlaneGeometry(10,8),clusterPlain);
		scene.add(clusterPlane);
		three.light.intensity=0;three.light.ambient=0;
		three.lights.add({position:[-2.5,2.7,1],range:2.2,color:0xff3010,intensity:8});
		three.lights.add({position:[2.5,-2.7,1],range:2.2,color:0x1030ff,intensity:8});
		three.camera.target.set(0,0,0);three.camera.orbit(0,0,7);
	`);
	defer built.free();
	test::@check(built.ok, "the asymmetric cluster scene built: %s", built.error);

	String[2] materials = { "clusterPlain", "clusterLayered" };
	foreach (name : materials)
	{
		three::RunResult selected = runtime.run(
			string::tformat("clusterPlane.material=%s", name));
		defer selected.free();
		test::@check(selected.ok, "%s was selected: %s", name, selected.error);
		renderer.pass.cluster_bruteforce = true;
		image::Image reference = renderer.capture()!!;
		defer reference.free();
		renderer.pass.cluster_bruteforce = false;
		image::Image clustered = renderer.capture()!!;
		defer clustered.free();
		test::@check(max_rgb_difference(&reference, &clustered) <= 2,
			"%s oracle differs by %d", name,
			max_rgb_difference(&reference, &clustered));
	}
}

fn void partial_viewport_conservatively_matches_the_all_light_oracle() @test
{
	three::Renderer* renderer = device::borrow(W, H);
	defer device::release();
	scene(renderer);
	points(renderer, 31, false);
	renderer.pass.camera.yaw = 29;
	renderer.pass.camera.pitch = -11;
	renderer.pass.view_rect = { 0.15, 0.1, 0.7, 0.8 };
	renderer.pass.cluster_bruteforce = true;
	image::Image reference = renderer.capture()!!;
	defer reference.free();
	renderer.pass.cluster_bruteforce = false;
	image::Image partial = renderer.capture()!!;
	defer partial.free();
	test::@check(max_rgb_difference(&reference, &partial) <= 2,
		"a partial viewport uses the conservative all-light path (largest channel error %d)",
		max_rgb_difference(&reference, &partial));
}

fn void cluster_overflow_falls_back_instead_of_dropping_lights() @test
{
	three::Renderer* renderer = device::borrow(W, H);
	defer device::release();
	scene(renderer);
	points(renderer, 80, true);
	renderer.pass.cluster_bruteforce = true;
	image::Image reference = renderer.capture()!!;
	defer reference.free();
	renderer.pass.cluster_bruteforce = false;
	image::Image clustered = renderer.capture()!!;
	defer clustered.free();
	test::@check(max_rgb_difference(&reference, &clustered) <= 2,
		"overflow uses the all-light fallback (largest channel error %d)",
		max_rgb_difference(&reference, &clustered));
	// The host-visible count is collected when this frame slot is reused.
	image::Image advance0 = renderer.capture()!!;
	advance0.free();
	image::Image advance1 = renderer.capture()!!;
	advance1.free();
	test::@check(renderer.pass.stats().cluster_overflow > 0, "overflow is explicit in stats");
}

fn void unchanged_cluster_inputs_are_reused_per_frame_slot() @test
{
	three::Renderer* renderer = device::borrow(W, H);
	defer device::release();
	scene(renderer);
	points(renderer, 12, false);

	// Populate both frames in flight, then revisit both slots with only values
	// consumed by fragment shading changed.
	renderer.capture()!!.free();
	renderer.capture()!!.free();
	uint populated = renderer.pass.cluster_dispatches;
	renderer.pass.lighting.lights[1].color[0] *= 2;
	renderer.pass.lighting.lights[1].meta[3] ^= 0x10000;
	renderer.capture()!!.free();
	renderer.capture()!!.free();
	test::@check(renderer.pass.cluster_dispatches == populated,
		"colour and shadow metadata reuse both slots' cluster lists");
}

fn void cluster_bounds_type_and_camera_changes_invalidate_each_slot() @test
{
	three::Renderer* renderer = device::borrow(W, H);
	defer device::release();
	scene(renderer);
	points(renderer, 12, false);
	renderer.capture()!!.free();
	renderer.capture()!!.free();
	uint dispatches = renderer.pass.cluster_dispatches;

	renderer.pass.lighting.lights[1].direction[3] += 1;
	renderer.capture()!!.free();
	renderer.capture()!!.free();
	test::@check(renderer.pass.cluster_dispatches == dispatches + 2,
		"changed light bounds invalidate both frame slots");
	dispatches += 2;

	renderer.pass.lighting.lights[1].meta[2] = 2;
	renderer.capture()!!.free();
	renderer.capture()!!.free();
	test::@check(renderer.pass.cluster_dispatches == dispatches + 2,
		"changed light type invalidates both frame slots");
	dispatches += 2;

	renderer.pass.camera.yaw += 3;
	renderer.capture()!!.free();
	renderer.capture()!!.free();
	test::@check(renderer.pass.cluster_dispatches == dispatches + 2,
		"changed camera invalidates both frame slots");
}

fn uint centre_green(image::Image* shot)
{
	sz at = ((sz)(shot.height / 2) * shot.width + shot.width / 2) * shot.bytes_per_pixel();
	return (uint)(char)shot.pixels[at + 1];
}

fn uint centre_alpha(image::Image* shot)
{
	sz at = ((sz)(shot.height / 2) * shot.width + shot.width / 2) * shot.bytes_per_pixel();
	return (uint)(char)shot.pixels[at + 3];
}

fn void rectangle_disk_and_spot_are_not_point_fallbacks() @test
{
	three::Renderer* renderer = device::borrow(W, H);
	defer device::release();
	scene(renderer);
	three::Light area = { .direction = { 0, 0, 2, 12 }, .color = { 0.5, 1, 0.5, 180 },
		.area_right = { 1, 0, 0, 2 }, .area_up = { 0, 1, 0, 1 },
		.meta = { 2, 0xffffffff, 2, 0 } };
	renderer.pass.lighting.lights[1] = area;
	renderer.pass.lighting.count = 2;
	image::Image rectangle = renderer.capture()!!;
	defer rectangle.free();
	renderer.pass.ambient_occlusion.apply({ .enabled = true, .radius = 1, .intensity = 1, .bias = 0.02 });
	image::Image occluded = renderer.capture()!!;
	defer occluded.free();
	test::@check(centre_green(&rectangle) == centre_green(&occluded),
		"AO does not multiply direct area illumination");
	test::@check(centre_alpha(&rectangle) == 255 && centre_alpha(&occluded) == 255,
		"area lighting and AO preserve material alpha");
	renderer.pass.ambient_occlusion.apply(three::DEFAULT_AMBIENT_OCCLUSION);
	renderer.pass.lighting.lights[1].meta[2] = 3;
	image::Image disk = renderer.capture()!!;
	defer disk.free();
	test::@check(centre_green(&rectangle) > 20 && centre_green(&disk) > 20,
		"both finite emitters illuminate the receiving face");
	test::@check(max_rgb_difference(&rectangle, &disk) > 0,
		"disk integration is not the rectangle or a point-light fallback");

	three::Light spot = { .direction = { 0, 0, 2, 10 }, .color = { 1, 1, 1, 20 },
		.area_right = { 0, 0, -1, 0.8 }, .area_up = { 0, 0, 0, 0.95 },
		.meta = { 2, 0xffffffff, 4, 0 } };
	renderer.pass.lighting.lights[1] = spot;
	image::Image aimed = renderer.capture()!!;
	defer aimed.free();
	renderer.pass.lighting.lights[1].area_right[2] = 1;
	image::Image away = renderer.capture()!!;
	defer away.free();
	test::@check(centre_green(&aimed) > centre_green(&away) + 10,
		"the spot cone direction gates illumination");
}

<*
 The combined area-light walk used by standard shading agrees with the two
 single-lobe walks exposed to custom bodies. Head-on near and far views exercise
 emitter distance across the plane; the oblique view exercises the GGX lobe at
 grazing angles.
*>
fn void combined_area_lobes_match_the_separate_helpers_across_views() @test
{
	three::Renderer* renderer = device::borrow(W, H);
	defer device::release();
	three::JsRuntime runtime;
	runtime.open(&renderer.pass, renderer)!!;
	defer runtime.close();

	three::RunResult built = runtime.run(`
		const scene = new three.Scene();
		globalThis.combined = new three.MeshLambertMaterial({
			color: 0xb07040, roughness: 0.3, metalness: 0.4, reflectance: 0.8
		});
		globalThis.separate = new three.ShaderMaterial({
			color: 0xb07040, roughness: 0.3, metalness: 0.4, reflectance: 0.8,
			fragment: "float3 shade(Surface s) { return s.albedo * lambert(s.normal) * (1.0 - s.metalness) + specular(s); }"
		});
		globalThis.areaPlane = new three.Mesh(new three.PlaneGeometry(12, 9), combined);
		scene.add(areaPlane);
		three.light.intensity = 0;
		three.light.ambient = 0;
		three.lights.add({ shape: 'rectangle', position: [0, 0, 2.5], range: 30,
			right: [1, 0, 0], up: [0, 1, 0], width: 4, height: 2,
			color: [0.7, 0.9, 1.0], intensity: 220 });
		three.camera.target.set(0, 0, 0);
	`);
	defer built.free();
	test::@check(built.ok, "the area comparison scene built: %s", built.error);

	float[3] yaw = { 0, 76, 0 };
	float[3] distance = { 3.5, 8, 20 };
	String[3] view = { "near", "grazing", "far" };
	for (uint i = 0; i < 3; i++)
	{
		renderer.pass.camera.yaw = yaw[i];
		renderer.pass.camera.pitch = 0;
		renderer.pass.camera.distance = distance[i];

		three::RunResult use_combined = runtime.run(`areaPlane.material = combined`);
		defer use_combined.free();
		test::@check(use_combined.ok, "the combined material was selected: %s", use_combined.error);
		image::Image standard = renderer.capture()!!;
		defer standard.free();

		three::RunResult use_separate = runtime.run(`areaPlane.material = separate`);
		defer use_separate.free();
		test::@check(use_separate.ok, "the separate helpers were selected: %s", use_separate.error);
		image::Image helpers = renderer.capture()!!;
		defer helpers.free();

		test::@check(
			max_rgb_difference(&standard, &helpers) <= 1,
			"the %s view differs by at most one channel level, got %d",
			view[i], max_rgb_difference(&standard, &helpers)
		);
	}
}

fn double mean_rgb_difference(image::Image* a, image::Image* b)
{
	long total = 0;
	sz bpp = a.bytes_per_pixel();
	sz channels = 0;
	for (sz p = 0; p < a.pixels.len; p += bpp)
	{
		for (sz c = 0; c < 3; c++)
		{
			int av = (int)(uint)(char)a.pixels[p + c];
			int bv = (int)(uint)(char)b.pixels[p + c];
			total += (long)(av > bv ? av - bv : bv - av);
			channels++;
		}
	}
	return channels == 0 ? 0.0 : (double)total / (double)channels;
}

<*
 The fitted area-light integration answers what the numeric one answers.

 `three.pass.area_reference` swaps the two in one build, so this is the same
 frame twice rather than two builds compared by hand — which is also how the bake
 keeps the numeric answer while the frame uses the fit.

 The tolerances are what the approximation is worth rather than what it happened
 to score: the fit is a few percent off ground truth, so a mean of a couple of
 8-bit levels over a lit plane is the right order and half a level would be
 asserting that an approximation is not one. Measured 2.7, 1.2 and 1.0 levels
 with a worst pixel of 32, at the terminator where the fit's horizon term is
 weakest. Total energy is the claim that matters for a scene — the fit must not
 change how bright the frame is — and 3% is tighter than any per-pixel number;
 the three views come out at 1.2%, 0.8% and 1.2%.

 The grazing view is here for the two failures that would not show head-on: a
 horizon artefact on the far half of the plane, and a specular streak where the
 lobe is widest.
*>
fn void the_fitted_area_lights_match_the_numeric_integration() @test
{
	three::Renderer* renderer = device::borrow(W, H);
	defer device::release();
	three::JsRuntime runtime;
	runtime.open(&renderer.pass, renderer)!!;
	defer runtime.close();

	three::RunResult built = runtime.run(`
		const scene = new three.Scene();
		scene.add(new three.Mesh(new three.PlaneGeometry(12, 9), new three.MeshLambertMaterial({
			color: 0xb07040, roughness: 0.3, metalness: 0.4, reflectance: 0.8
		})));
		three.light.intensity = 0;
		three.light.ambient = 0;
		three.lights.add({ shape: 'rectangle', position: [-2.2, 0, 2.5], range: 30,
			right: [1, 0, 0], up: [0, 1, 0], width: 3, height: 1.6,
			color: [1.0, 0.9, 0.8], intensity: 200 });
		three.lights.add({ shape: 'disk', position: [2.4, 0.4, 2.0], range: 30,
			right: [1, 0, 0], up: [0, 1, 0], width: 2.2, height: 2.2,
			color: [0.7, 0.9, 1.0], intensity: 200 });
		three.camera.target.set(0, 0, 0);
	`);
	defer built.free();
	test::@check(built.ok, "the rectangle-and-disk scene built: %s", built.error);

	float[3] yaw = { 0, 74, 0 };
	float[3] distance = { 4.5, 8, 16 };
	String[3] view = { "near", "grazing", "far" };
	for (uint i = 0; i < 3; i++)
	{
		renderer.pass.camera.yaw = yaw[i];
		renderer.pass.camera.pitch = 0;
		renderer.pass.camera.distance = distance[i];

		renderer.pass.area_reference = false;
		image::Image fitted = renderer.capture()!!;
		defer fitted.free();
		test::@check(renderer.pass.ltc.live, "the fit is on the device");

		renderer.pass.area_reference = true;
		image::Image numeric = renderer.capture()!!;
		defer numeric.free();

		test::@check(differing_rgb(&fitted, &numeric) > 0,
			"the %s view is actually integrated two different ways", view[i]);
		double mean = mean_rgb_difference(&fitted, &numeric);
		test::@check(mean < 3.5,
			"the %s view differs by %.2f channel levels on average", view[i], mean);
		test::@check(max_rgb_difference(&fitted, &numeric) < 48,
			"and by at most %d anywhere", max_rgb_difference(&fitted, &numeric));
		long lit = rgb_sum(&numeric);
		double energy = lit == 0 ? 0.0 : (double)(rgb_sum(&fitted) - lit) / (double)lit;
		test::@check(lit > 0 && energy > -0.03 && energy < 0.03,
			"and carries %.3f of the numeric frame's energy", 1.0 + energy);
	}

	renderer.pass.area_reference = false;
}

fn void a_held_light_tracks_its_stable_id_across_remove() @test
{
	three::Renderer* renderer = device::borrow(W, H);
	defer device::release();
	three::JsRuntime runtime;
	runtime.open(&renderer.pass, renderer)!!;
	defer runtime.close();
	three::RunResult result = runtime.run(`
		const first = three.lights.add({position:[1,0,0],range:4,color:0xff0000});
		const held = three.lights.add({position:[2,0,0],range:4,color:0x00ff00});
		three.lights.remove(first);
		held.intensity = 7;
		return [held.index, held.position.x, held.intensity, three.lights[1].color];
	`);
	defer result.free();
	test::@check(result.ok, "stable handle script succeeds: %s", result.error);
	test::@check(result.value == `[1,2,7,[0,1,0]]`, "held handle follows its light, got %s", result.value);
}

fn void shadow_update_budget_defers_new_work_but_keeps_valid_cache() @test
{
	three::Renderer* renderer = device::borrow(W, H);
	defer device::release();
	device::reserve_sun_shadow_pages(renderer);
	three::JsRuntime runtime;
	runtime.open(&renderer.pass, renderer)!!;
	defer runtime.close();
	three::RunResult built = runtime.run(`
		const scene=new three.Scene();
		const ground=new three.Mesh(new three.PlaneGeometry(12,12));
		ground.rotation.x=-Math.PI/2;ground.static=true;scene.add(ground);
		const box=new three.Mesh(new three.BoxGeometry(2,2,2));box.position.set(0,2.4,0);box.static=true;scene.add(box);
		three.light.set([0.12,1,0.12],0.2);three.camera.frameAll();three.camera.orbit(0,1,three.camera.distance*0.85);
	`);
	defer built.free();
	test::@check(built.ok, "the budget shadow scene built: %s", built.error);
	image::Image open = renderer.capture()!!;
	defer open.free();
	three::RunResult deferred = runtime.run(`three.light.shadow=true;three.shadows.budget={maxUpdates:0}`);
	defer deferred.free();
	image::Image no_update = renderer.capture()!!;
	defer no_update.free();
	test::@check(differing_rgb(&open,&no_update)==0, "an unscheduled new view shades as unshadowed");
	three::RunResult restored = runtime.run(`three.shadows.budget={maxUpdates:64}`);
	defer restored.free();
	image::Image updated = renderer.capture()!!;
	defer updated.free();
	test::@check(differing_rgb(&open,&updated)>50, "restoring update budget renders the shadow");
	three::RunResult frozen = runtime.run(`three.shadows.budget={maxUpdates:0}`);
	defer frozen.free();
	image::Image cached = renderer.capture()!!;
	defer cached.free();
	test::@check(differing_rgb(&updated,&cached)==0, "a valid cached view costs no update budget");
}

fn void a_deferred_combined_view_keeps_its_last_complete_depth() @test
{
	three::Renderer* renderer = device::borrow(W, H);
	defer device::release();
	three::JsRuntime runtime;
	runtime.open(&renderer.pass, renderer)!!;
	defer runtime.close();
	three::RunResult built = runtime.run(`
		const scene = new three.Scene();
		const floor = new three.Mesh(new three.PlaneGeometry(12, 12));
		floor.rotation.x = -Math.PI / 2; floor.static = true; scene.add(floor);
		const wall = new three.Mesh(new three.BoxGeometry(2, 2, 2));
		wall.position.y = 1; wall.static = true; scene.add(wall);
		globalThis.deferredMover = new three.Mesh(new three.BoxGeometry(1, 1, 1));
		scene.add(deferredMover);
		three.light.set([.2, 1, .1], .2);
		three.lights.add({ position: [3, 3, 2], range: 12, intensity: 20 });
		three.light.shadow = { enabled: true, size: 1024, follow: false, distance: 20 };
		three.lights.shadow = { enabled: true, size: 256 };
		three.camera.target.set(0, 0, 0); three.camera.orbit(35, 18, 10);
	`);
	defer built.free();
	test::@check(built.ok, "the mixed cached-shadow scene built: %s", built.error);
	renderer.capture()!!.free();
	renderer.capture()!!.free();

	three::RunResult limited = runtime.run(`
		three.light.direction = [.6, 1, .2];
		deferredMover.position.x = .5;
		three.shadows.budget = { maxUpdates: 64, maxUpdateTexels: 2097152 };
	`);
	defer limited.free();
	test::@check(limited.ok, "the sun rebuild budget was set: %s", limited.error);
	renderer.capture()!!.free();
	test::@check(renderer.pass.stats().shadow_deferred >= 1,
		"the sun rebuild defers each affected point-light face");

	uint slot = renderer.pass.shadow_manager.frame_slot;
	uint local = three::SHADOW_VIEW_NONE;
	uint point_id = renderer.pass.lighting.lights[1].meta[0];
	for (uint at = 0; at < renderer.pass.shadow_view_set.count; at++)
	{
		three::ShadowView* view = &renderer.pass.shadow_view_set.views[at];
		if (view.live && view.key.light == point_id && renderer.pass.shadow_manager.overlay[at]
			&& !renderer.pass.shadow_manager.scheduled[at])
		{
			local = renderer.pass.shadow_manager.gpu_indices[at];
			break;
		}
	}
	three::ShadowGpuView* uploaded = (three::ShadowGpuView*)renderer.pass.shadow_view_buffers[slot].data();
	test::@check(local != three::SHADOW_VIEW_NONE && uploaded[local].params[3] > 0,
		"a deferred affected local view retains its complete live shadow");
}

fn void moving_one_local_light_invalidates_only_its_six_cached_views() @test
{
	three::Renderer* renderer = device::borrow(W, H);
	defer device::release();
	three::JsRuntime runtime;
	runtime.open(&renderer.pass, renderer)!!;
	defer runtime.close();
	three::RunResult built = runtime.run(`
		const scene=new three.Scene();
		const ground=new three.Mesh(new three.PlaneGeometry(14,14));
		ground.rotation.x=-Math.PI/2;ground.static=true;scene.add(ground);
		const box=new three.Mesh(new three.BoxGeometry(2,2,2));
		box.position.set(0,1.5,0);box.static=true;scene.add(box);
		three.light.intensity=0;
		three.lights.shadow={enabled:true,size:256};
		globalThis.cacheLampA=three.lights.add({position:[-2,4,1],range:10,intensity:18});
		globalThis.cacheLampB=three.lights.add({position:[2,4,1],range:10,intensity:18});
		three.camera.frameAll();
	`);
	defer built.free();
	test::@check(built.ok, "the local-light cache scene built: %s", built.error);
	image::Image warm = renderer.capture()!!;
	warm.free();
	test::@check(renderer.pass.stats().shadow_updates == 12,
		"warming two point lights updates twelve cube faces");
	image::Image cached = renderer.capture()!!;
	cached.free();
	test::@check(renderer.pass.stats().shadow_updates == 0,
		"both unchanged local lights remain cached");
	three::RunResult moved = runtime.run(`cacheLampA.position.x=-1.5`);
	defer moved.free();
	test::@check(moved.ok, "moving one local light succeeds: %s", moved.error);
	image::Image changed = renderer.capture()!!;
	changed.free();
	test::@check(renderer.pass.stats().shadow_updates == 6,
		"moving one point light updates its six views while the other stays cached");
}

fn void dynamic_shadow_overlays_only_refresh_views_the_caster_reaches() @test
{
	three::Renderer* renderer = device::borrow(W, H);
	defer device::release();
	three::JsRuntime runtime;
	runtime.open(&renderer.pass, renderer)!!;
	defer runtime.close();
	three::RunResult built = runtime.run(`
		const scene=new three.Scene();
		const floor=new three.Mesh(new three.PlaneGeometry(16,16));
		floor.rotation.x=-Math.PI/2;floor.static=true;scene.add(floor);
		globalThis.shadowMover=new three.Mesh(new three.BoxGeometry(1,1,1));
		shadowMover.position.set(0,1,0);scene.add(shadowMover);
		three.camera.target.set(0,0,0);three.camera.orbit(35,18,12);
		three.shadows.budget={maxViews:16,maxUpdates:16};
		three.light.set([.2,1,.1],.2);
		three.light.shadow={enabled:true,size:256,follow:false,distance:24};
		three.lights.shadow={enabled:true,size:256};
		three.lights.add({position:[-4,1,0],range:10,intensity:18});
		three.lights.add({shape:'disk',position:[0,6,0],right:[1,0,0],up:[0,0,-1],
			width:2,height:2,range:12,intensity:80});
	`);
	defer built.free();
	test::@check(built.ok, "the mixed per-view shadow scene built: %s", built.error);
	renderer.capture()!!.free();
	renderer.capture()!!.free();

	three::SceneStats stats = renderer.pass.stats();
	test::@check(stats.shadow_views == 8,
		"the directional, point and area lights keep all eight resident views");
	test::@check(stats.shadow_updates == 0,
		"an unchanged rigid caster keeps every dynamic overlay cached");
	test::@check(stats.shadow_update_texels == 0,
		"cached dynamic overlays submit no raster work");

	uint point_id = renderer.pass.lighting.lights[1].meta[0];
	uint point_scheduled = 0;
	uint point_cached = 0;
	for (uint at = 0; at < renderer.pass.shadow_view_set.count; at++)
	{
		three::ShadowView* view = &renderer.pass.shadow_view_set.views[at];
		if (!view.live || view.key.kind != three::ShadowViewKind.POINT || view.key.light != point_id) continue;
		if (renderer.pass.shadow_manager.scheduled[at]) point_scheduled++;
		if (view.live_valid) point_cached++;
	}
	test::@check(point_scheduled == 0, "the reached point-light face remains cached");
	test::@check(point_cached == 6, "the other five point faces retain complete cached depth");

	three::RunResult moved = runtime.run(`shadowMover.position.x=-7`);
	defer moved.free();
	test::@check(moved.ok, "the caster moved between point faces: %s", moved.error);
	image::Image partial = renderer.capture()!!;
	defer partial.free();
	stats = renderer.pass.stats();
	test::@check(stats.shadow_updates == 4,
		"the exited point face adds one cache cleanup to three overlays");
	test::@check(stats.shadow_update_texels == 3 * 256 * 256,
		"a cache-only cleanup adds no rasterized texels");
	point_scheduled = 0;
	uint point_overlaid = 0;
	uint point_cleared = 0;
	for (uint at = 0; at < renderer.pass.shadow_view_set.count; at++)
	{
		three::ShadowView* view = &renderer.pass.shadow_view_set.views[at];
		if (!view.live || view.key.kind != three::ShadowViewKind.POINT || view.key.light != point_id) continue;
		if (renderer.pass.shadow_manager.scheduled[at]) point_scheduled++;
		if (renderer.pass.shadow_manager.overlay[at]) point_overlaid++;
		if (renderer.pass.shadow_manager.scheduled[at] && !renderer.pass.shadow_manager.overlay[at]
			&& !view.live_dynamic) point_cleared++;
	}
	test::@check(point_scheduled == 2 && point_overlaid == 1 && point_cleared == 1,
		"the entered face is overlaid and the exited face is restored from static depth");
	test::@check(renderer.pass.shadow_manager.copied_texels > 0
		&& renderer.pass.shadow_manager.copied_texels < 4 * 256 * 256,
		"the combined update restores bounded rectangles: %d texels",
		renderer.pass.shadow_manager.copied_texels);
	for (uint at = 0; at < renderer.pass.shadow_view_set.count; at++)
	{
		if (!renderer.pass.shadow_view_set.views[at].live) continue;
		renderer.pass.shadow_view_set.views[at].live_valid = false;
		renderer.pass.shadow_view_set.views[at].dynamic_valid = false;
	}
	image::Image full = renderer.capture()!!;
	defer full.free();
	test::@check(max_rgb_difference(&partial, &full) == 0,
		"bounded static-atlas copies match a forced full-tile rebuild");
}

fn void all_dynamic_shadow_tiles_reuse_rigid_casters_and_clear_departures() @test
{
	three::Renderer* renderer = device::borrow(W, H);
	defer device::release();
	three::JsRuntime runtime;
	runtime.open(&renderer.pass, renderer)!!;
	defer runtime.close();
	three::RunResult built = runtime.run(`
		const scene=new three.Scene();
		globalThis.fullCacheFloor=new three.Mesh(new three.PlaneGeometry(16,16));
		fullCacheFloor.rotation.x=-Math.PI/2;scene.add(fullCacheFloor);
		globalThis.fullCacheMaterial=new three.ShaderMaterial({
			uniforms:{level:.2},
			fragment:'float3 shade(Surface s){return float3(level,level,level);}'
		});
		globalThis.fullCacheBox=new three.Mesh(new three.BoxGeometry(1,1,1),fullCacheMaterial);
		fullCacheBox.position.set(0,1,0);scene.add(fullCacheBox);
		three.camera.target.set(0,0,0);three.camera.orbit(35,18,12);
		three.light.intensity=0;
		three.lights.shadow={enabled:true,size:256,maxLocal:1};
		three.lights.add({position:[0,4,0],range:12,intensity:20});
	`);
	defer built.free();
	test::@check(built.ok, "the all-dynamic cache scene built: %s", built.error);
	renderer.capture()!!.free();
	image::Image dim = renderer.capture()!!;
	test::@check(renderer.pass.stats().shadow_updates == 0,
		"unchanged rigid casters reuse every full-map tile");
	three::RunResult shaded = runtime.run(`fullCacheMaterial.uniforms.level=.9`);
	defer shaded.free();
	test::@check(shaded.ok, "the opaque fragment uniform changed: %s", shaded.error);
	image::Image bright = renderer.capture()!!;
	defer dim.free();
	defer bright.free();
	test::@check(renderer.pass.stats().shadow_updates == 0,
		"an opaque fragment-only uniform does not invalidate cached depth");
	test::@check(max_rgb_difference(&dim, &bright) > 0,
		"the fragment-only uniform still changes the rendered surface");

	three::RunResult moved = runtime.run(`fullCacheBox.position.x=30`);
	defer moved.free();
	test::@check(moved.ok, "the rigid caster left the scene: %s", moved.error);
	image::Image partial = renderer.capture()!!;
	defer partial.free();
	test::@check(renderer.pass.stats().shadow_updates > 0,
		"a caster leaving cached views clears their old depth");
	usz updated = 0;
	for (uint at = 0; at < renderer.pass.shadow_view_set.count; at++)
	{
		if (!renderer.pass.shadow_manager.scheduled[at]) continue;
		three::ShadowRect rect = renderer.pass.shadow_manager.update_rects[at];
		updated += (usz)rect.width * rect.height;
		renderer.pass.shadow_view_set.views[at].live_valid = false;
		renderer.pass.shadow_view_set.views[at].dynamic_valid = false;
	}
	test::@check(updated > 0 && updated < 6 * 256 * 256,
		"the departure updates bounded rectangles instead of six whole faces: %d", updated);
	image::Image full = renderer.capture()!!;
	defer full.free();
	test::@check(max_rgb_difference(&partial, &full) == 0,
		"a bounded departure update is pixel-identical to a forced full-tile render");
}

fn void mixed_shadow_cache_stays_admitted_under_a_tight_byte_budget() @test
{
	three::Renderer* renderer = device::borrow(W, H);
	defer device::release();
	three::JsRuntime runtime;
	runtime.open(&renderer.pass, renderer)!!;
	defer runtime.close();
	three::RunResult built = runtime.run(`
		const scene=new three.Scene();
		const ground=new three.Mesh(new three.PlaneGeometry(14,14));
		ground.rotation.x=-Math.PI/2;ground.static=true;scene.add(ground);
		const box=new three.Mesh(new three.BoxGeometry(2,2,2));
		box.position.set(0,1.5,0);box.static=true;scene.add(box);
		three.camera.frameAll();
		three.shadows.budget={maxBytes:8*1024*1024,maxUpdates:64};
		three.light.shadow={enabled:true,size:1024,follow:false,distance:20};
		three.lights.shadow={enabled:true,size:256};
		three.lights.add({position:[2,4,1],range:10,intensity:18});
	`);
	defer built.free();
	test::@check(built.ok, "the tight-budget mixed shadow scene built: %s", built.error);
	for (uint frame = 0; frame < 3; frame++)
	{
		image::Image shot = renderer.capture()!!;
		shot.free();
		test::@check(renderer.pass.stats().shadow_bytes <= 8 * 1024 * 1024,
			"the shadow atlas stays inside its byte budget");
	}
	three::SceneStats stats = renderer.pass.stats();
	test::@check(stats.shadow_views >= 7,
		"the sun and all six point faces remain admitted under pressure");
	test::@check(stats.shadow_static_draws == 0,
		"warmed static shadows do not thrash and redraw on the third frame");
}

fn void sixty_four_shadow_views_record_without_crossing_the_plan_array() @test
{
	three::Renderer* renderer = device::borrow(W, H);
	defer device::release();
	three::JsRuntime runtime;
	runtime.open(&renderer.pass, renderer)!!;
	defer runtime.close();
	three::RunResult built = runtime.run(`
		const scene=new three.Scene();
		const ground=new three.Mesh(new three.PlaneGeometry(16,16));
		ground.rotation.x=-Math.PI/2;ground.static=true;scene.add(ground);
		const moving=new three.Mesh(new three.BoxGeometry(1,1,1));
		moving.position.set(0,1,0);scene.add(moving);
		three.camera.frameAll();
		three.shadows.budget={maxViews:64,maxUpdates:64};
		three.light.shadow={enabled:true,size:256,follow:false,distance:20};
		three.lights.shadow={enabled:true,size:256,maxLocal:64};
		for(let i=0;i<10;i++)three.lights.add({
			position:[(i%5-2)*2,3,Math.floor(i/5)*3-1.5],range:12,intensity:8
		});
		for(let i=0;i<3;i++)three.lights.add({
			shape:'spot',position:[(i-1)*3,4,2],direction:[0,-1,-0.4],
			range:12,outerAngle:0.8,innerAngle:0.4,intensity:8
		});
	`);
	defer built.free();
	test::@check(built.ok, "the 64-view boundary scene built: %s", built.error);
	image::Image warm = renderer.capture()!!;
	warm.free();
	test::@check(renderer.pass.stats().shadow_views == 64,
		"one sun, ten point lights and three spots admit exactly 64 views");
	image::Image cached = renderer.capture()!!;
	cached.free();
	three::SceneStats stats = renderer.pass.stats();
	test::@check(stats.shadow_views == 64, "all 64 views remain live on the next frame");
	test::@check(stats.shadow_static_draws == 0,
		"the static half of every view is cached while dynamic draws continue");
}
