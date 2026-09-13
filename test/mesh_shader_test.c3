<*
 The draw path through both compilers, compared as pixels.

 `c3c test --trust=full --test-filter three_tests::mesh_shader`

 This is the first pass whose *material* half changed: `shaders/material.shady`
 carries the built-in look, and the fragment stage the geometry half declares is
 what the def splices a body into. The fixture therefore has to put the material
 maths in the picture - a roughness, a metalness and a reflectance away from
 their defaults - and the pose in it too, because the vertex path is where the
 shady half reads the same records through the same functions.

 Slang and shady emit different SPIR-V; what has to be identical is the frame.
 The module is compiled directly rather than through `MeshPass.init`, so both
 compilers' modules exist in one process at once, and the scene cache is off so
 a cache hit cannot hand the first compiler's frame back to compare with itself.
 The table's `MESH` row is on shady; this test still compiles both halves
 explicitly, because the Slang module has to exist beside it for the comparison.
 
 **The comparison is byte equality, not resemblance**, and it is only meaningful
 on a frame this half can reproduce whole: the lightmap and the environment are
 not in the fixture - no lightmap uvs, no sky - so they stay at their ported
 identity rather than at a difference this test cannot explain. What it does
 spend is the whole of what the half carries: a bent, turned, scaled skinned
 character, a uv carrying box with a uv variant table, a card whose COLOR_0 is a
 painted layer mask, the sun's shadow, the sun plus two clustered point lights
 and a clustered rectangle, a specular material, and both debug views as frames of
 their own.
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
 The scene both compilers draw.

 Every mesh is given the default material (`material = null`) so the built-in
 pipeline is the one that changes hands; a `MeshLambertMaterial` would be its own
 slot and the swap would have to find it too. No light names a shadow view, the
 character plays a clip in a non-trivial pose, and the box carries uvs so the
 vertex stage runs `variant_uv` on a real table.
*>
fn String scene_source()
{
	return `
		const scene = new three.Scene();
		const poser = (await three.load('test/fixtures/skinned.glb')).instantiate();
		poser.position.set(0.9, 0.15, -0.5);
		poser.rotation.y = 0.6;
		poser.scale.set(1.15, 1.15, 1.15);
		poser.color = [0.45, 0.7, 0.35, 1.0];
		poser.traverse(o => { if (o instanceof three.Mesh) o.material = null; });
		scene.add(poser);
		poser.play('Bend', { time: 0.9 });

		const box = new three.Mesh(new three.BoxGeometry(1.8, 1.8, 1.8));
		box.position.set(-1.3, 0.9, 0.5);
		box.rotation.set(0.4, 0.7, 0.15);
		box.color = [0.9, 0.55, 0.25, 1.0];
		scene.add(box);
		box.material = null;
		box.variant = 1;

		// A floor under both, so the sun's shadow has something to land on
		// that faces the light: without one the casters shadow empty space and
		// the comparison would be green with the lookup never read.
		const ground = new three.Mesh(new three.PlaneGeometry(14, 14));
		ground.rotation.x = -Math.PI / 2;
		ground.position.y = -1.0;
		ground.static = true;
		ground.material = null;
		scene.add(ground);

		// A mesh whose COLOR_0 is a painted layer mask. The built-in draw
		// path must not tint its albedo with that attribute, so a fold that
		// forgot FLAG_COLORS_ARE_MASK draws a green card here where Slang
		// draws a grey one - the failure no mesh without an attribute can show.
		const masked = (await three.load('test/fixtures/layered.glb')).instantiate();
		masked.position.set(1.7, 1.0, -1.5);
		masked.rotation.y = -0.6;
		masked.scale.set(0.5, 0.5, 1.0);
		masked.traverse(o => { if (o instanceof three.Mesh) o.material = null; });
		scene.add(masked);

		// The other side of the same flag: COLOR_0 as a plain tint. merge bakes
		// each copy's mesh.color into the merged geometry's COLOR_0, so this mesh
		// is one the built-in path *does* multiply the albedo by - the case the
		// mask card above cannot see. Slang tints it, so a fold that stopped
		// multiplying fails here.
		const left = new three.Mesh(new three.BoxGeometry(0.7, 0.7, 0.7));
		left.position.set(-1.9, 0.4, -1.2);
		left.color = [0.15, 0.9, 0.35, 0.5];
		const right = new three.Mesh(new three.BoxGeometry(0.7, 0.7, 0.7));
		right.position.set(-2.6, 0.4, -1.2);
		right.color = [0.95, 0.25, 0.1, 1.0];
		const tinted = new three.Mesh(three.merge([left, right]));
		tinted.material = null;
		scene.add(tinted);

		three.light.set([0.3, 1.0, 0.2], 0.6);
		// The sun's shadow is on, so the ported lookup is inside the compared
		// bytes: the character and the box both stand in the sun's way.
		three.light.shadow = true;
		// The screen-space crevice too, which needs the depth prepass the same
		// frame and darkens the ambient terms where the floor meets a caster.
		three.light.occlusion = true;
		three.light.ambient = 0.04;
		three.lights.add({ position: [2.5, 3.0, 1.0], range: 14, intensity: 40, color: 0xff7040 });
		three.lights.add({ position: [-2.0, 1.2, 2.5], range: 10, intensity: 25, color: 0x4080ff });
		// A rectangle, so the LTC fit is inside the compared bytes too: its
		// diffuse is the polygon form factor and its specular comes from the
		// two table reads, which a point light never reaches. Held by name so
		// the control below can switch it off.
		globalThis.area = three.lights.add({ shape: 'rectangle', position: [-0.6, 2.4, 0.4], right: [1, 0, 0], up: [0, 0, -1],
			width: 2.4, height: 1.4, range: 18, color: 0x66cc88, intensity: 60 });
		three.camera.frameAll();
		three.camera.orbit(0.4, 0.5, three.camera.distance);
		return 1;
	`;
}

<*
 How many pixels are not the black clear, and how many colours there are. A
 frame that is all clear proves the draw did not happen; a frame of one flat
 colour proves a shading term collapsed. Both are ways this comparison could
 pass while comparing nothing.
*>
fn void frame_spread(image::Image* shot, sz* lit, uint* colours)
{
	*lit = 0;
	*colours = 0;
	uint[4096] seen;
	foreach (&slot : seen) *slot = 0;
	for (sz at = 0; at + 2 < shot.pixels.len; at += 4)
	{
		uint r = (uint)(char)shot.pixels[at];
		uint g = (uint)(char)shot.pixels[at + 1];
		uint b = (uint)(char)shot.pixels[at + 2];
		if (r + g + b <= 12) continue;
		(*lit)++;
		uint packed = (r << 16) | (g << 8) | b;
		uint slot = (packed * 2654435761u) % 4096;
		uint seen_at = seen[slot];
		if (seen_at == 0) { seen[slot] = packed + 1; (*colours)++; continue; }
		// A collision is rare and only makes the count conservative; walk on.
	}
	// A slot can be claimed by two different colours with the same bucket; the
	// count is a floor, which is what the check needs.
}

<*
 Move every material riding `from` onto `to`, and answer how many moved.

 The fixture's meshes all share the pass's own built-in pipeline, so a swap of
 those pointers is the whole of handing a capture to the other compiler.
*>
fn sz swap_materials(three::Renderer* renderer, three::MeshPipeline* from, three::MeshPipeline* to)
{
	sz moved = 0;
	foreach (&material : renderer.pass.materials)
	{
		if (material.pipeline != from) continue;
		material.pipeline = to;
		moved++;
	}
	return moved;
}

fn void the_draw_path_is_the_same_pixels_through_both_compilers() @test
{
	three::Renderer* renderer = device::borrow(W, H);
	defer device::release();
	// The sun's 16 MB depth and static atlases, reserved before anything else
	// fragments the warmed pages - the shadow has to actually run for this
	// comparison to spend it.
	device::reserve_sun_shadow_pages(renderer);
	defer three::shader_overrides_clear();
	defer renderer.scene_cache_disabled = false;
	renderer.scene_cache_disabled = true;
	renderer.clear = { 0.0f, 0.0f, 0.0f, 1.0f };

	three::JsRuntime runtime;
	runtime.open(&renderer.pass, renderer)!!;
	defer runtime.close();

	three::RunResult built = runtime.run(scene_source());
	defer built.free();
	test::@check(built.ok, "the fixture built: %s", built.error);

	// Away from the defaults, so the specular lobe and the emissive add are both
	// inside the compared bytes rather than terms that collapse to nothing.
	if (catch renderer.pass.set_material_surface(0, 0.35f, 0.45f, 0.8f))
	{
		test::@check(false, "the default material took a surface");
	}
	if (catch renderer.pass.set_material_emissive(0, 0.03f, 0.05f, 0.08f, 0.5f))
	{
		test::@check(false, "and an emissive");
	}
	// The box is the copy on row 1, so a quarter turn, a flip and a slide are in
	// `variant_uv` for both halves rather than the identity next door.
	if (catch renderer.pass.begin_material_uv_variants(0))
	{
		test::@check(false, "the default material took a uv variant table");
	}
	if (catch renderer.pass.add_material_uv_variant(0, 0.25f, 0.0f, 1.0f, 2.0f))
	{
		test::@check(false, "one row");
	}
	if (catch renderer.pass.add_material_uv_variant(0, 0.0f, 0.5f, 3.0f, 1.0f))
	{
		test::@check(false, "and a second");
	}

	String source = three::shader_source(three::ShaderFile.MESH_SLANG, mem)!!;
	defer source.free(mem);

	three::shader_override(three::ShaderPass.MESH, three::ShaderCompiler.SLANG);
	three::ShaderModule slang_mod = three::compile_shader(
		three::ShaderPass.MESH, source, three::ShaderFile.MESH_SLANG.name, three::MESH_ENTRIES[..])!!;
	defer slang_mod.free();
	test::@check(slang_mod.ok, "the Slang draw path compiles: %s", slang_mod.diagnostic);

	three::shader_override(three::ShaderPass.MESH, three::ShaderCompiler.SHADY);
	three::ShaderModule shady_mod = three::compile_shader(
		three::ShaderPass.MESH, source, three::ShaderFile.MESH_SLANG.name, three::MESH_ENTRIES[..])!!;
	defer shady_mod.free();
	test::@check(shady_mod.ok, "the shady draw path compiles: %s", shady_mod.diagnostic);

	// The contract the pipeline builder holds the module to, from the module
	// that is about to run.
	if (catch three::check_entry_points(&shady_mod))
	{
		test::@check(false, "the shady module has vertexMain and fragmentMain");
	}
	if (catch three::check_push_block(&shady_mod.layout, three::MESH_PUSH_FIELDS[..]))
	{
		test::@check(false, "the shady module's push block matches the mesh contract");
	}
	test::@check(shady_mod.layout.push_size == 32,
		"the block is 24 walked bytes plus the empty uniforms, got %d", shady_mod.layout.push_size);

	three::MeshPipeline slang_pipe;
	slang_pipe.init(&renderer.gpu, &renderer.target, &slang_mod, three::SOLID_STATE)!!;
	defer slang_pipe.free(&renderer.gpu);
	three::MeshPipeline shady_pipe;
	shady_pipe.init(&renderer.gpu, &renderer.target, &shady_mod, three::SOLID_STATE)!!;
	defer shady_pipe.free(&renderer.gpu);

	// Every material the fixture draws with is the built-in one. Moving those
	// pointers for a capture is the whole swap; they go back below, because the
	// pass releases its own pipeline when it is freed.
	sz moved = swap_materials(renderer, renderer.pass.pipeline, &slang_pipe);
	test::@check(moved > 0,
		"the fixture draws with the built-in pipeline, %d materials moved", moved);

	image::Image through_slang = renderer.capture()!!;
	defer through_slang.free();

	// **The control.** If the sun's shadow were inert, the comparison below
	// would be green with the ported lookup never running - which is the way a
	// byte comparison fails quietly. Turning the shadow off has to change the
	// frame, and the count is the proof it was on.
	three::RunResult unshadowed = runtime.run("three.light.shadow = false; return 1;");
	defer unshadowed.free();
	test::@check(unshadowed.ok, "the shadow could be turned off: %s", unshadowed.error);
	image::Image without_shadow = renderer.capture()!!;
	defer without_shadow.free();

	sz shadow_bytes = 0;
	for (sz at = 0; at < through_slang.pixels.len; at++)
	{
		if (through_slang.pixels[at] != without_shadow.pixels[at]) shadow_bytes++;
	}
	test::@check(shadow_bytes > 0,
		"the fixture's shadow reaches the frame: %d of %d bytes differ without it",
		shadow_bytes, through_slang.pixels.len);

	three::RunResult reshadowed = runtime.run("three.light.shadow = true; return 1;");
	defer reshadowed.free();
	test::@check(reshadowed.ok, "and back on: %s", reshadowed.error);

	// The same control for the crevice: off has to change the frame, or the
	// ported occlusion never ran inside the comparison either.
	three::RunResult unoccluded = runtime.run("three.light.occlusion = false; return 1;");
	defer unoccluded.free();
	test::@check(unoccluded.ok, "the occlusion could be turned off: %s", unoccluded.error);
	image::Image without_occlusion = renderer.capture()!!;
	defer without_occlusion.free();

	sz occlusion_bytes = 0;
	for (sz at = 0; at < through_slang.pixels.len; at++)
	{
		if (through_slang.pixels[at] != without_occlusion.pixels[at]) occlusion_bytes++;
	}
	test::@check(occlusion_bytes > 0,
		"the fixture's crevice reaches the frame: %d of %d bytes differ without it",
		occlusion_bytes, through_slang.pixels.len);

	three::RunResult reoccluded = runtime.run("three.light.occlusion = true; return 1;");
	defer reoccluded.free();
	test::@check(reoccluded.ok, "and back on: %s", reoccluded.error);

	// The same control for the area emitter: zeroing it has to change the
	// frame, or the LTC fit was never inside the comparison either.
	three::RunResult unlit_area = runtime.run("area.intensity = 0; return 1;");
	defer unlit_area.free();
	test::@check(unlit_area.ok, "the area light could be turned off: %s", unlit_area.error);
	image::Image without_area = renderer.capture()!!;
	defer without_area.free();

	sz area_bytes = 0;
	for (sz at = 0; at < through_slang.pixels.len; at++)
	{
		if (through_slang.pixels[at] != without_area.pixels[at]) area_bytes++;
	}
	test::@check(area_bytes > 0,
		"the fixture's area light reaches the frame: %d of %d bytes differ without it",
		area_bytes, through_slang.pixels.len);

	three::RunResult relit_area = runtime.run("area.intensity = 60; return 1;");
	defer relit_area.free();
	test::@check(relit_area.ok, "and back on: %s", relit_area.error);

	swap_materials(renderer, &slang_pipe, &shady_pipe);
	image::Image through_shady = renderer.capture()!!;
	defer through_shady.free();

	swap_materials(renderer, &shady_pipe, renderer.pass.pipeline);

	sz lit = 0;
	uint colours = 0;
	frame_spread(&through_slang, &lit, &colours);
	test::@check(lit > (sz)W * H / 8,
		"the compared frame draws geometry: %d of %d pixels are not the clear", lit, W * H);
	test::@check(colours > 64,
		"and is not one flat colour: %d distinct colours", colours);

	sz differing = 0;
	sz first = through_slang.pixels.len;
	for (sz at = 0; at < through_slang.pixels.len; at++)
	{
		if (through_slang.pixels[at] == through_shady.pixels[at]) continue;
		if (differing == 0) first = at;
		differing++;
	}
	test::@check(differing == 0,
		"the draw path is byte-identical through both compilers, %d of %d bytes differ, first at byte %d (pixel %d, %d)",
		differing, through_slang.pixels.len, first, first / 4 % W, first / 4 / W);

	// **The debug views.** The comparison above runs with the view off, so the
	// ported `debug_view` is compiled into both modules but never answers. Each
	// view is a frame of its own: 'shadow' is the lookup's factor as greyscale,
	// and 'shadowMap' reads the map itself through the un-filtered binding 17 -
	// the two branches of the function, and the one resource the compared scene
	// never reads. The control beside each says the view changed the frame, or
	// a view that silently did nothing would compare equal to itself.
	String[2] views = { "shadow", "shadowMap" };
	foreach (view_name : views)
	{
		three::RunResult viewed = runtime.run(
			string::tformat("three.debug.view = '%s'; return 1;", view_name)
		);
		defer viewed.free();
		test::@check(viewed.ok, "the %s view could be selected: %s", view_name, viewed.error);

		swap_materials(renderer, renderer.pass.pipeline, &slang_pipe);
		image::Image view_slang = renderer.capture()!!;
		defer view_slang.free();
		swap_materials(renderer, &slang_pipe, &shady_pipe);
		image::Image view_shady = renderer.capture()!!;
		defer view_shady.free();
		swap_materials(renderer, &shady_pipe, renderer.pass.pipeline);

		sz view_differing = 0;
		sz view_first = view_slang.pixels.len;
		for (sz at = 0; at < view_slang.pixels.len; at++)
		{
			if (view_slang.pixels[at] == view_shady.pixels[at]) continue;
			if (view_differing == 0) view_first = at;
			view_differing++;
		}
		test::@check(view_differing == 0,
			"the %s view is byte-identical through both compilers, %d of %d bytes differ, first at byte %d (pixel %d, %d)",
			view_name, view_differing, view_slang.pixels.len, view_first, view_first / 4 % W, view_first / 4 / W);

		sz against_scene = 0;
		for (sz at = 0; at < view_slang.pixels.len; at++)
		{
			if (view_slang.pixels[at] != through_slang.pixels[at]) against_scene++;
		}
		test::@check(against_scene > 0,
			"the %s view changes the frame: %d of %d bytes differ from the scene",
			view_name, against_scene, view_slang.pixels.len);
	}
	three::RunResult view_off = runtime.run("three.debug.view = 'off'; return 1;");
	defer view_off.free();
	test::@check(view_off.ok, "and the view goes back off: %s", view_off.error);
}

<*
 The numeric area reference through both compilers, compared as pixels.

 The fitted draw path already compares byte for byte next door; this is the
 variant the fit is measured against, and it is a module of its own because it
 declares no fit table. Slang gets `mesh.slang` with `THREE_AREA_REFERENCE` -
 the original's own spelling - and shady gets `mesh_def`'s reference variant.
 Both live in this process and both feed a pipeline the fixture's default
 material draws through.

 Two controls sit beside the equality, because equality alone cannot say the
 fixture spent the reference: turning the area light off has to change the
 frame, and the fitted module has to draw a *different* frame. The two
 integrations are supposed to agree within the fit's error rather than exactly,
 so a variant that silently drew the fit would pass the comparison and fail
 this control.
*>
fn void the_area_reference_is_the_same_pixels_through_both_compilers() @test
{
	three::Renderer* renderer = device::borrow(W, H);
	defer device::release();
	device::reserve_sun_shadow_pages(renderer);
	defer three::shader_overrides_clear();
	defer renderer.scene_cache_disabled = false;
	renderer.scene_cache_disabled = true;
	renderer.clear = { 0.0f, 0.0f, 0.0f, 1.0f };

	three::JsRuntime runtime;
	runtime.open(&renderer.pass, renderer)!!;
	defer runtime.close();

	three::RunResult built = runtime.run(scene_source());
	defer built.free();
	test::@check(built.ok, "the fixture built: %s", built.error);

	String source = three::shader_source(three::ShaderFile.MESH_SLANG, mem)!!;
	defer source.free(mem);
	DString reference_source;
	reference_source.tinit(source.len + 64);
	defer reference_source.free();
	reference_source.append_string("#define THREE_AREA_REFERENCE 1\n#line 1\n");
	reference_source.append_string(source);

	three::shader_override(three::ShaderPass.MESH, three::ShaderCompiler.SLANG);
	three::ShaderModule slang_mod = three::compile_shader(
		three::ShaderPass.MESH, reference_source.str_view(), three::ShaderFile.MESH_SLANG.name, three::MESH_ENTRIES[..])!!;
	three::shader_overrides_clear();
	defer slang_mod.free();
	test::@check(slang_mod.ok, "the Slang reference draw path compiles: %s", slang_mod.diagnostic);

	three::shader_override(three::ShaderPass.MESH_REFERENCE, three::ShaderCompiler.SHADY);
	three::ShaderModule shady_mod = three::compile_shader(
		three::ShaderPass.MESH_REFERENCE, "", "three.mesh_reference", three::MESH_ENTRIES[..])!!;
	three::shader_overrides_clear();
	defer shady_mod.free();
	test::@check(shady_mod.ok, "the shady reference draw path compiles: %s", shady_mod.diagnostic);
	test::@check(shady_mod.layout.binding_of("ltc_lut") == null,
		"and declares no fit table");

	three::MeshPipeline slang_pipe;
	slang_pipe.init(&renderer.gpu, &renderer.target, &slang_mod, three::SOLID_STATE)!!;
	defer slang_pipe.free(&renderer.gpu);
	three::MeshPipeline shady_pipe;
	shady_pipe.init(&renderer.gpu, &renderer.target, &shady_mod, three::SOLID_STATE)!!;
	defer shady_pipe.free(&renderer.gpu);

	// The fixture draws with the pass's built-in pipeline; moving those
	// pointers for a capture is the whole swap, and they go back below.
	sz moved = swap_materials(renderer, renderer.pass.pipeline, &slang_pipe);
	test::@check(moved > 0, "the fixture draws with the built-in pipeline, %d materials moved", moved);

	image::Image through_slang = renderer.capture()!!;
	defer through_slang.free();

	swap_materials(renderer, &slang_pipe, &shady_pipe);
	image::Image through_shady = renderer.capture()!!;
	defer through_shady.free();

	swap_materials(renderer, &shady_pipe, renderer.pass.pipeline);

	// The same scene through the fitted module: the reference is only worth
	// comparing if the fixture can tell the two integrations apart at all.
	image::Image through_fit = renderer.capture()!!;
	defer through_fit.free();

	sz fit_bytes = 0;
	for (sz at = 0; at < through_slang.pixels.len; at++)
	{
		if (through_slang.pixels[at] != through_fit.pixels[at]) fit_bytes++;
	}
	test::@check(fit_bytes > 0,
		"the fixture tells the two integrations apart: %d of %d bytes differ",
		fit_bytes, through_slang.pixels.len);

	// The area light itself is inside the compared bytes: with it off, the
	// reference frame has to change. A scene whose numeric path never ran would
	// compare equal to itself.
	three::RunResult unlit = runtime.run("area.intensity = 0; return 1;");
	defer unlit.free();
	test::@check(unlit.ok, "the area light could be turned off: %s", unlit.error);
	swap_materials(renderer, renderer.pass.pipeline, &slang_pipe);
	image::Image without_area = renderer.capture()!!;
	defer without_area.free();
	swap_materials(renderer, &slang_pipe, renderer.pass.pipeline);

	sz area_bytes = 0;
	for (sz at = 0; at < through_slang.pixels.len; at++)
	{
		if (through_slang.pixels[at] != without_area.pixels[at]) area_bytes++;
	}
	test::@check(area_bytes > 0,
		"the fixture's area light reaches the reference frame: %d of %d bytes differ without it",
		area_bytes, through_slang.pixels.len);

	three::RunResult relit = runtime.run("area.intensity = 60; return 1;");
	defer relit.free();
	test::@check(relit.ok, "and back on: %s", relit.error);

	sz lit = 0;
	uint colours = 0;
	frame_spread(&through_slang, &lit, &colours);
	test::@check(lit > (sz)W * H / 8,
		"the compared frame draws geometry: %d of %d pixels are not the clear", lit, W * H);
	test::@check(colours > 64,
		"and is not one flat colour: %d distinct colours", colours);

	sz differing = 0;
	sz first = through_slang.pixels.len;
	for (sz at = 0; at < through_slang.pixels.len; at++)
	{
		if (through_slang.pixels[at] == through_shady.pixels[at]) continue;
		if (differing == 0) first = at;
		differing++;
	}
	test::@check(differing == 0,
		"the numeric area reference is byte-identical through both compilers, %d of %d bytes differ, first at byte %d (pixel %d, %d)",
		differing, through_slang.pixels.len, first, first / 4 % W, first / 4 / W);

	// **The engine's own door.** Coming after the comparison on purpose: the
	// proof has to be the byte count, and a wiring fault that aborts the test
	// earlier would hide it. `three.pass.area_reference` is what the cluster
	// suite's agreement test draws the numeric side with, so the frame it
	// produces has to be the module this test compiled rather than a second way
	// to integrate. The lazy build and the selection are both asked.
	renderer.pass.area_reference = true;
	image::Image through_flag = renderer.capture()!!;
	defer through_flag.free();
	test::@check(renderer.pass.reference_ready, "the flag built the reference pipelines");
	test::@check(renderer.pass.draw_pipeline(renderer.pass.pipeline) == renderer.pass.reference_pipeline,
		"and the built-in draw path now binds the reference module's pipeline");
	renderer.pass.area_reference = false;

	sz flag_differing = 0;
	for (sz at = 0; at < through_slang.pixels.len; at++)
	{
		if (through_slang.pixels[at] != through_flag.pixels[at]) flag_differing++;
	}
	test::@check(flag_differing == 0,
		"the engine's own reference frame is the module's, %d of %d bytes differ",
		flag_differing, through_slang.pixels.len);
}

<*
 A script's material is not the draw path's own.

 **The trap this suite exists beside.** `MeshPass.init` and
 `MeshPass.create_material` are two pass rows, so a script's `shade()` body
 must not be routed through the def's built-in body. The draw path is forced
 to shady for the run as it already is in the table, and the material row's
 own module is what has to find the body: the body returns a colour no light
 can produce, and the frame has to show it.
*>
fn void a_script_body_is_not_the_draw_paths_body() @test
{
	three::Renderer* renderer = device::borrow(W, H);
	defer device::release();
	defer three::shader_overrides_clear();
	// The whole point: if the scripted material rode the draw path's row, this is
	// the compiler it would reach, and the body below would be ignored.
	three::shader_override(three::ShaderPass.MESH, three::ShaderCompiler.SHADY);
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

<*
 A scripted material through both compilers, compared as pixels.

 `MESH_MATERIAL` is on shady; this is the assembly's own comparison: the same
 declared uniforms, the same declared texture and the same shading written twice
 - once in each spelling - drawn in one process. The template side names its
 compiler, the def side takes the row's own answer, and what the comparison
 proves is that a script's body, its uniform set and its texture rows reach the
 frame through the def exactly as they do through the template.
*>
fn void a_scripted_material_is_the_same_pixels_through_both_compilers() @test
{
	three::Renderer* renderer = device::borrow(W, H);
	defer device::release();
	defer three::shader_overrides_clear();
	renderer.scene_cache_disabled = true;
	renderer.clear = { 0.0f, 0.0f, 0.0f, 1.0f };

	three::MaterialUniform[1] uniforms = { { "tint", 4, 1 } };
	three::MaterialTexture[1] textures = { { "noise_map" } };

	String through_template = `
float3 shade(Surface s)
{
	return standard(s) * tint.rgb + noise_map.Sample(s.uv).rgb * 0.5;
}
`;
	String through_def = `
fn float3 shade(Surface s)
{
	return standard(s) * s.uniforms.tint.rgb + noise_map().Sample(s.uv).rgb * 0.5;
}
`;

	three::shader_override(three::ShaderPass.MESH_MATERIAL, three::ShaderCompiler.SLANG);
	uint from_slang = renderer.pass.create_material(
		&renderer.gpu, &renderer.target, through_template, uniforms[..],
		three::SIDE_DOUBLE, three::BLENDING_NONE, textures[..]
	)!!;
	three::shader_overrides_clear();
	uint from_shady = renderer.pass.create_material(
		&renderer.gpu, &renderer.target, through_def, uniforms[..],
		three::SIDE_DOUBLE, three::BLENDING_NONE, textures[..]
	)!!;
	three::shader_overrides_clear();

	// Two bodies, so two modules: a cache hit here would compare one build with
	// itself, and the compiler override alone would not say so.
	test::@check(
		renderer.pass.material(from_slang).pipeline != renderer.pass.material(from_shady).pipeline,
		"the two spellings are two pipelines"
	);

	char[4] pixels = { 30, 220, 60, 255 };
	image::Image one = {
		.width = 1,
		.height = 1,
		.bit_depth = 8,
		.format = image::PixelFormat.RGBA,
		// No allocator, left at the zero fill: `Image.free` frees nothing
		// without one, which is what makes a stack array safe here.
		.pixels = pixels[..],
	};
	int image = renderer.pass.assets.claim_texture(&renderer.gpu, one)!!;
	renderer.pass.set_material_texture(&renderer.gpu, from_slang, "noise_map", image)!!;
	renderer.pass.set_material_texture(&renderer.gpu, from_shady, "noise_map", image)!!;
	renderer.pass.material(from_slang).set_uniform("tint", (float[]) { 0.2, 0.4, 0.8, 1.0 })!!;
	renderer.pass.material(from_shady).set_uniform("tint", (float[]) { 0.2, 0.4, 0.8, 1.0 })!!;

	three::AssetId quad = renderer.pass.assets.primitive(&renderer.gpu, three::plane_shape(2, 2))!!;
	three::NodeId node = renderer.pass.scene.add_mesh(quad, 0);
	renderer.pass.scene.set_material(node, from_slang);
	renderer.pass.frame_camera();
	renderer.pass.lighting = {
		.count = 1,
		.ambient = 1,
		.lights = { [0] = { .direction = { 0, 0, 1, 0 }, .color = { 1, 1, 1, 1 } } },
	};

	image::Image through_slang = renderer.capture()!!;
	defer through_slang.free();

	// The fixture has to be a drawn surface, or two matching clear frames would
	// pass this comparison for the wrong reason.
	sz lit = 0;
	for (sz at = 0; at + 2 < through_slang.pixels.len; at += 4)
	{
		if ((int)through_slang.pixels[at] + (int)through_slang.pixels[at + 1] + (int)through_slang.pixels[at + 2] > 30) lit++;
	}
	test::@check(lit > (sz)W * H / 4, "the fixture draws a surface: %d of %d pixels", lit, W * H);

	renderer.pass.scene.set_material(node, from_shady);
	image::Image through_shady = renderer.capture()!!;
	defer through_shady.free();

	sz differing = 0;
	sz first = through_slang.pixels.len;
	for (sz at = 0; at < through_slang.pixels.len; at++)
	{
		if (through_slang.pixels[at] == through_shady.pixels[at]) continue;
		if (differing == 0) first = at;
		differing++;
	}
	test::@check(differing == 0,
		"a scripted material is byte-identical through both compilers, %d of %d bytes differ, first at byte %d (pixel %d, %d)",
		differing, through_slang.pixels.len, first, first / 4 % W, first / 4 / W);
}

<*
 A relief body through both compilers, compared as pixels.

 The fixture is a height map that moves the uv and a body that paints the move
 itself, so a sign, a transpose or a dropped fade is a different picture rather
 than a different shading. A third frame with the parallax call replaced by the
 flat uv proves the fixture can see relief at all: equality through the two
 compilers is meaningless if the height map moved nothing.
*>
fn void a_relief_body_is_the_same_pixels_through_both_compilers() @test
{
	three::Renderer* renderer = device::borrow(W, H);
	defer device::release();
	defer three::shader_overrides_clear();
	renderer.scene_cache_disabled = true;
	renderer.clear = { 0.0f, 0.0f, 0.0f, 1.0f };

	three::MaterialTexture[1] textures = { { "height_map" } };

	String through_template = `
float3 shade(Surface s)
{
	float2 puv = parallax_uv(s, s.uv, height_map.Sample(s.uv).r, 0.4);
	return float3((puv - s.uv) * 20.0 + 0.5, 0.0);
}
`;
	String through_def = `
fn float3 shade(Surface s)
{
	float2 puv = parallax_uv(s, s.uv, height_map().Sample(s.uv).r, 0.4);
	return float3((puv - s.uv) * 20.0 + 0.5, 0.0);
}
`;
	String through_flat = `
fn float3 shade(Surface s)
{
	return float3(0.5, 0.0, 0.0);
}
`;

	three::shader_override(three::ShaderPass.MESH_MATERIAL, three::ShaderCompiler.SLANG);
	uint from_slang = renderer.pass.create_material(
		&renderer.gpu, &renderer.target, through_template, {}, three::SIDE_DOUBLE,
		three::BLENDING_NONE, textures[..]
	)!!;
	three::shader_overrides_clear();
	uint from_shady = renderer.pass.create_material(
		&renderer.gpu, &renderer.target, through_def, {}, three::SIDE_DOUBLE,
		three::BLENDING_NONE, textures[..]
	)!!;
	uint from_flat = renderer.pass.create_material(
		&renderer.gpu, &renderer.target, through_flat, {}, three::SIDE_DOUBLE, three::BLENDING_NONE
	)!!;
	three::shader_overrides_clear();

	char[16] pixels = {
		0, 0, 0, 255,   255, 0, 0, 255,
		255, 0, 0, 255, 0, 0, 0, 255,
	};
	image::Image height = {
		.width = 2,
		.height = 2,
		.bit_depth = 8,
		.format = image::PixelFormat.RGBA,
		.pixels = pixels[..],
	};
	int map = renderer.pass.assets.claim_texture(&renderer.gpu, height)!!;
	renderer.pass.set_material_texture(&renderer.gpu, from_slang, "height_map", map)!!;
	renderer.pass.set_material_texture(&renderer.gpu, from_shady, "height_map", map)!!;

	three::AssetId quad = renderer.pass.assets.primitive(&renderer.gpu, three::plane_shape(2, 2))!!;
	three::NodeId node = renderer.pass.scene.add_mesh(quad, 0);
	renderer.pass.scene.set_material(node, from_slang);
	renderer.pass.frame_camera();
	image::Image through_slang = renderer.capture()!!;
	defer through_slang.free();

	renderer.pass.scene.set_material(node, from_shady);
	image::Image through_shady = renderer.capture()!!;
	defer through_shady.free();

	renderer.pass.scene.set_material(node, from_flat);
	image::Image flat = renderer.capture()!!;
	defer flat.free();

	// The fixture can see relief: the moved uv and the flat one are not the
	// same frame.
	sz moved = 0;
	for (sz at = 0; at < through_slang.pixels.len; at++)
	{
		if (through_slang.pixels[at] != flat.pixels[at]) moved++;
	}
	test::@check(moved > (sz)W * H / 4,
		"the height map moves the uv over a quarter of the frame: %d of %d bytes", moved, through_slang.pixels.len);

	sz differing = 0;
	sz first = through_slang.pixels.len;
	for (sz at = 0; at < through_slang.pixels.len; at++)
	{
		if (through_slang.pixels[at] == through_shady.pixels[at]) continue;
		if (differing == 0) first = at;
		differing++;
	}
	test::@check(differing == 0,
		"a relief body is byte-identical through both compilers, %d of %d bytes differ, first at byte %d (pixel %d, %d)",
		differing, through_slang.pixels.len, first, first / 4 % W, first / 4 / W);
}
