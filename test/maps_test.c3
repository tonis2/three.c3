<*
 The maps the built-in material shades with: a normal map, glTF's packed
 metallic-roughness pair, and an occlusion map.

	`c3c test --trust=full --test-noleak --test-filter three_tests::maps`

 All three loaded, uploaded and refcounted long before anything sampled them —
 `plan.md` §26 is the entry for that, and the sentence in it was that a script
 setting a normal map paid every cost of having one and got none of the picture.
 So the checks here are about *shading*: each one changes one map and measures
 the frame, because "the texture reached the GPU" was already true when the
 feature did nothing at all.

 ## Why the light is pinned and the plane faces it

 `plane_shape` builds its face along +z, and every check below puts the one light
 straight down that axis with the ambient floor at zero. Under that arrangement
 `n · l` is exactly the mapped normal's z, so a normal map that tilts the surface
 by a known angle darkens the plane by a number that can be predicted rather than
 compared. It is the same trick `three_tests::color` uses for the same reason: an
 inequality against a diagonal light proves much less.

 ## Proved by injection

 Each of the three was re-run against the mistake it is aimed at, and the number
 in the message is what the broken shader actually produced:

 - `mesh.slang`'s `FLAG_HAS_NORMAL_MAP` branch deleted: "a normal map tilted the
   surface away from the light: 199 flat, 199 with the map", and the script-side
   check fails beside it with the same pair.
 - The metallic-roughness sample read `.bg` instead of `.gb`, which is the
   channel order swapped: "the map's blue took the metalness away: 64 as metal,
   0 under the map" — the map made the surface *darker*, which is the green
   channel being read as metalness.
 - `lambert`'s `ambient * occlusion + (1 - ambient) * direct` changed to
   `(ambient + (1 - ambient) * direct) * occlusion`, which is the plausible
   mistake this file exists to keep out: "a fully occluded surface under a direct
   light is exactly as lit as it was: 0 against 199".
*>
module three_tests::maps;

import three;
import three_tests::device;
import vk;
import image;
import std::core::test;
import std::math;

const uint W = 120;
const uint H = 90;

macro @with_pass(; @body(three::Renderer* renderer))
{
	three::Renderer* renderer = device::borrow(W, H);
	defer device::release();

	@body(renderer);
}

macro @with_js(; @body(three::JsRuntime* run, three::Renderer* renderer))
{
	three::Renderer* renderer = device::borrow(W, H);
	defer device::release();

	three::JsRuntime runtime;
	runtime.open(&renderer.pass, renderer)!!;
	defer runtime.close();

	@body(&runtime, renderer);
}

<*
 A 4x4 image of one rgba value, owned by the caller.

 Flat on purpose, exactly as `three_tests::color`'s is: every check here measures
 a value at the centre of the frame, and a pattern would invite a check that is
 really about filtering.
*>
fn image::Image solid(char r, char g, char b)
{
	char[] pixels = mem::new_array(char, 4 * 4 * 4);
	for (sz i = 0; i < pixels.len; i += 4)
	{
		pixels[i] = r;
		pixels[i + 1] = g;
		pixels[i + 2] = b;
		pixels[i + 3] = 255;
	}
	return {
		.width = 4, .height = 4, .bit_depth = 8,
		.format = image::PixelFormat.RGBA, .pixels = pixels, .allocator = mem,
	};
}

<*
 A flat normal map that tilts every fragment by the same amount.

 `z` is the tangent-space normal's z, so it is also what `n · l` comes to under
 the light this file pins — 1 is no tilt at all and 0.31 is about 72 degrees. The
 x component takes up whatever is left, and its sign does not matter: the light
 is along the surface normal, so only z reaches the answer.

 Uploaded `LINEAR`, which is the whole of what a normal map needs from the
 loader — through an sRGB view the stored 0.5 arrives as 0.21 and every surface
 leans the same way.
*>
fn int tilt_map(three::Renderer* renderer, float z)
{
	float x = math::sqrt(math::max(1.0f - z * z, 0.0f));
	image::Image made = solid(
		(char)(uint)math::round((x * 0.5f + 0.5f) * 255.0f),
		(char)128,
		(char)(uint)math::round((z * 0.5f + 0.5f) * 255.0f)
	);
	defer made.free();
	return renderer.pass.assets.claim_texture(&renderer.gpu, made, three::ColorSpace.LINEAR)!!;
}

// A plane filling the frame, lit straight down its own normal with no ambient
// floor — see the header. Hands back the node so the caller can give it a
// material.
fn three::NodeId lit_plane(three::Renderer* renderer)
{
	three::AssetId plane = renderer.pass.assets.primitive(&renderer.gpu, three::plane_shape(2, 2))!!;
	three::NodeId node   = renderer.pass.scene.add_mesh(plane, 0);
	renderer.pass.frame_camera();
	renderer.pass.lighting = {
		.count = 1,
		.ambient = 0,
		.lights = { { .direction = { 0, 0, 1, 0 }, .color = { 1, 1, 1, 1 } }, { }, { }, { } },
	};
	return node;
}

// The green channel at the centre of the frame — the subject, and nothing else.
fn uint centre(three::Renderer* renderer)
{
	image::Image shot = renderer.capture()!!;
	defer shot.free();
	sz bpp = shot.bytes_per_pixel();
	sz at  = ((sz)(shot.height / 2) * (sz)shot.width + (sz)(shot.width / 2)) * bpp;
	return shot.pixels[at + 1];
}

// ============================================================================
// The normal map
// ============================================================================

<*
 A normal map bends the light, and putting it back is putting the picture back.

 The one measurement this feature exists for. A plane lit head-on is at its
 brightest; a map that tilts its normal 72 degrees away from the light has to
 take most of that away, and clearing the map has to give all of it back — which
 is the half that says the flag is read per draw rather than latched at
 construction.

 The number is not compared against a constant, because the albedo it is a
 fraction of is `PRIMITIVE_COLOR` through an sRGB encode. It is compared against
 the same surface a moment earlier, which is the only thing that isolates the
 map.
*>
fn void a_normal_map_bends_the_light() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		uint material     = renderer.pass.create_texture_material(three::NO_TEXTURE)!!;
		three::NodeId lit = lit_plane(renderer);
		renderer.pass.scene.set_material(lit, material);

		uint flat = centre(renderer);
		test::@check(flat > 150, "a plane lit down its own normal is bright, got %d", flat);

		int tilted = tilt_map(renderer, 0.31f);
		renderer.pass.set_material_slot(&renderer.gpu, material, three::MATERIAL_SLOT_NORMAL, tilted)!!;

		uint bent = centre(renderer);
		test::@check(
			bent * 4 < flat * 3,
			"a normal map tilted the surface away from the light: %d flat, %d with the map",
			flat,
			bent
		);

		renderer.pass.set_material_slot(
			&renderer.gpu, material, three::MATERIAL_SLOT_NORMAL, three::NO_TEXTURE
		)!!;
		uint cleared = centre(renderer);
		test::@check(
			cleared == flat,
			"and clearing it puts the surface back: %d against %d",
			cleared,
			flat
		);
	};
}

<*
 A normal map that says "no tilt" changes nothing at all.

 The other end of the same measurement, and the one that catches the decode being
 wrong rather than absent. A texel of (0.5, 0.5, 1) is the identity, so a surface
 wearing it must render exactly as one wearing nothing — and it does not if the
 map is read through an sRGB view, if the `* 2 - 1` is missing, or if the frame is
 built from the wrong pair of derivatives.
*>
fn void a_flat_normal_map_is_the_identity() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		uint material     = renderer.pass.create_texture_material(three::NO_TEXTURE)!!;
		three::NodeId lit = lit_plane(renderer);
		renderer.pass.scene.set_material(lit, material);

		uint bare = centre(renderer);

		int identity = tilt_map(renderer, 1.0f);
		renderer.pass.set_material_slot(&renderer.gpu, material, three::MATERIAL_SLOT_NORMAL, identity)!!;

		uint mapped = centre(renderer);
		test::@check(
			math::abs((int)mapped - (int)bare) <= 1,
			"a flat normal map is the surface it was: %d without it, %d with",
			bare,
			mapped
		);
	};
}

// ============================================================================
// The metallic-roughness map
// ============================================================================

<*
 Metalness comes off the map's *blue* channel, and roughness off its green.
 
 glTF's packing, and the check is built so that a swap of the two fails rather
 than merely reading differently. A fully metallic surface has no diffuse at all
 and nothing here to reflect, so it is dark; the same material under a map whose
 blue says "not metal" is bright again.

 Both maps carry the same two values in opposite channels, so the only difference
 between the two frames is which channel the shader believed. Reading `.bg`
 instead of `.gb` reverses the inequality.
*>
fn void the_metallic_roughness_map_is_packed_gltfs_way() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		uint material     = renderer.pass.create_texture_material(three::NO_TEXTURE)!!;
		three::NodeId lit = lit_plane(renderer);
		renderer.pass.scene.set_material(lit, material);

		// Fully metallic, so the diffuse half is gone and the surface is dark —
		// `specular_light`'s header has why that is correct rather than broken.
		renderer.pass.set_material_surface(material, 1.0f, 1.0f, 0.5f)!!;
		uint metal = centre(renderer);

		// Green 255, blue 0: rough, and not metal. The map's blue multiplies the
		// material's metalness of 1 down to nothing, so the diffuse comes back.
		image::Image rough_not_metal = solid(0, 255, 0);
		defer rough_not_metal.free();
		int soft = renderer.pass.assets.claim_texture(
			&renderer.gpu, rough_not_metal, three::ColorSpace.LINEAR
		)!!;
		renderer.pass.set_material_slot(
			&renderer.gpu, material, three::MATERIAL_SLOT_METALNESS_ROUGHNESS, soft
		)!!;
		uint dielectric = centre(renderer);

		test::@check(
			dielectric > metal + 40,
			"the map's blue took the metalness away: %d as metal, %d under the map",
			metal,
			dielectric
		);

		// The same two numbers, in the other two channels. Under glTF's packing
		// this is "smooth metal" and stays dark; under a swapped read it would be
		// the bright one.
		image::Image smooth_metal = solid(0, 0, 255);
		defer smooth_metal.free();
		int hard = renderer.pass.assets.claim_texture(
			&renderer.gpu, smooth_metal, three::ColorSpace.LINEAR
		)!!;
		renderer.pass.set_material_slot(
			&renderer.gpu, material, three::MATERIAL_SLOT_METALNESS_ROUGHNESS, hard
		)!!;
		uint swapped = centre(renderer);

		test::@check(
			dielectric > swapped + 40,
			"and green is roughness rather than metalness: %d with blue at 0, %d with blue at 1",
			dielectric,
			swapped
		);
	};
}

// ============================================================================
// The occlusion map
// ============================================================================

<*
 **Occlusion darkens the ambient floor and never a light.**
 
 The mistake this is here to keep out is the plausible one: an AO map applied to
 everything looks like dirt in the crevices and is wrong, because an occlusion
 map records how much of the *sky* a point can see and says nothing at all about
 a lamp pointed into it. Both halves are measured in one check, because either
 alone is satisfied by an implementation that ignores the map.

 With the floor at zero every photon in the frame is direct, so a black
 occlusion map has to change nothing. With the floor at one there is no direct
 term left, so the same map has to take the surface to almost nothing.
*>
fn void occlusion_darkens_the_ambient_floor_and_not_a_light() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		uint material     = renderer.pass.create_texture_material(three::NO_TEXTURE)!!;
		three::NodeId lit = lit_plane(renderer);
		renderer.pass.scene.set_material(lit, material);

		uint direct = centre(renderer);

		image::Image shut = solid(0, 0, 0);
		defer shut.free();
		int dark = renderer.pass.assets.claim_texture(&renderer.gpu, shut, three::ColorSpace.LINEAR)!!;
		renderer.pass.set_material_slot(&renderer.gpu, material, three::MATERIAL_SLOT_OCCLUSION, dark)!!;

		uint occluded = centre(renderer);
		test::@check(
			occluded == direct,
			"a fully occluded surface under a direct light is exactly as lit as it was: %d against %d",
			occluded,
			direct
		);

		// The floor alone now, so the map is the only thing left to darken.
		renderer.pass.lighting = {
			.count = 1,
			.ambient = 1.0f,
			.lights = { { .direction = { 0, 0, 1, 0 }, .color = { 1, 1, 1, 1 } }, { }, { }, { } },
		};
		uint floor_occluded = centre(renderer);

		renderer.pass.set_material_slot(
			&renderer.gpu, material, three::MATERIAL_SLOT_OCCLUSION, three::NO_TEXTURE
		)!!;
		uint floor_open = centre(renderer);

		test::@check(
			floor_occluded * 4 < floor_open,
			"and the ambient floor is what it does darken: %d occluded, %d open",
			floor_occluded,
			floor_open
		);
	};
}

// ============================================================================
// What holds the images, and who may name them
// ============================================================================

<*
 A material holds a reference to every map it names, and gives all of them back.

 `set_material_map`'s contract, three bindings further along: the material's
 reference is its own and is separate from whatever handle a script holds, so a
 texture named by a live material outlives a `dispose()` on the handle and goes
 when the material does.
*>
fn void a_material_holds_a_reference_to_every_map_it_names() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Assets* assets = &renderer.pass.assets;

		uint material = renderer.pass.create_texture_material(three::NO_TEXTURE)!!;
		int normal    = tilt_map(renderer, 0.5f);
		test::@check(assets.texture_refs(normal) == 1, "a fresh upload holds one reference");

		renderer.pass.set_material_slot(&renderer.gpu, material, three::MATERIAL_SLOT_NORMAL, normal)!!;
		test::@check(
			assets.texture_refs(normal) == 2,
			"a material naming it holds a second, got %d",
			assets.texture_refs(normal)
		);

		// Pointed somewhere else: the old image loses the material's reference in
		// the same call that gives the new one its own.
		int other = tilt_map(renderer, 0.25f);
		renderer.pass.set_material_slot(&renderer.gpu, material, three::MATERIAL_SLOT_NORMAL, other)!!;
		test::@check(
			assets.texture_refs(normal) == 1,
			"and re-pointing the slot gives it back, got %d",
			assets.texture_refs(normal)
		);
		test::@check(assets.texture_refs(other) == 2, "while the new one is held");

		// Nothing names the material, so disposing the handle collects it — and
		// the collection is what releases the map.
		renderer.pass.dispose_material(&renderer.gpu, material)!!;
		test::@check(
			assets.texture_refs(other) == 1,
			"a collected material gives its maps back, got %d",
			assets.texture_refs(other)
		);
	};
}

<*
 A ShaderMaterial's samplers are its own, and these three verbs cannot reach
 them.

 The one refusal worth having. `mesh.slang` numbers its normal map at binding 3
 and `material.slang` numbers an agent's *first* declared sampler at the same
 place, so a `normalMap` written onto a compiled material would put an image in
 whatever the body called its first texture and shade the scene with it. Refused
 by fault rather than by silence, because the picture that comes out of the other
 answer looks like a shader bug.
*>
fn void a_shader_materials_samplers_are_its_own() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::MaterialTexture[1] declared = { { "noise_map" } };
		uint compiled = renderer.pass.create_material(
			&renderer.gpu,
			&renderer.target,
			"float3 shade(Surface s) { return noise_map.Sample(s.uv).rgb; }",
			{ },
			three::SIDE_FRONT,
			three::BLENDING_NONE,
			declared[..]
		)!!;

		int normal = tilt_map(renderer, 0.5f);
		if (catch err = renderer.pass.set_material_slot(
			&renderer.gpu, compiled, three::MATERIAL_SLOT_NORMAL, normal
		))
		{
			test::@check(
				err == three::MATERIAL_SAMPLER_UNKNOWN,
				"a compiled material refuses a built-in map with %s",
				err
			);
		}
		else
		{
			test::@check(false, "a normal map was written into a ShaderMaterial's own first sampler");
		}

		test::@check(
			renderer.pass.material_slot(compiled, three::MATERIAL_SLOT_NORMAL) == three::NO_TEXTURE,
			"and the getter says the same thing"
		);
	};
}

<*
 And the shader's own names are not a second door into those three slots.

 `mesh.slang` declares `normal_map`, so `material.textures.normal_map = tex`
 would otherwise resolve through the *name* — which is the thing
 `NORMAL_MAP_BINDING` argues against, because it makes the shader's spelling part
 of the API and leaves one slot with two ways to write it. The refusal is what
 keeps `set_material_slot` the only one.
*>
fn void the_built_in_shaders_own_names_are_not_a_door() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		uint material = renderer.pass.create_texture_material(three::NO_TEXTURE)!!;
		int normal    = tilt_map(renderer, 0.5f);

		if (catch err = renderer.pass.set_material_texture(&renderer.gpu, material, "normal_map", normal))
		{
			test::@check(
				err == three::MATERIAL_SAMPLER_UNKNOWN,
				"the built-in shader's sampler names are refused by name, got %s",
				err
			);
		}
		else
		{
			test::@check(false, "a built-in map was reachable by the name the shader happens to use");
		}

		test::@check(
			renderer.pass.material_slot(material, three::MATERIAL_SLOT_NORMAL) == three::NO_TEXTURE,
			"and nothing landed in the slot"
		);
		test::@check(
			renderer.pass.assets.texture_refs(normal) == 1,
			"and no reference was taken on the way"
		);
	};
}

// ============================================================================
// One copy of the frame, in two shaders
// ============================================================================

<*
 `mapped_normal_frame` is written once and spliced into both shaders.

 The GGX block is duplicated character for character between `mesh.slang` and
 `material.slang` and is held together by nothing but a comment, which is exactly
 what made a third copy the wrong answer here. So this asserts the mechanism
 rather than the agreement: neither template contains the maths, the shared file
 does, and what reaches Slang has it.

 `load_source` is the file as written and `shader_source` is the file as
 compiled — the difference between the two *is* the splice.
*>
fn void one_tangent_frame_reaches_both_shaders() @test
{
	// A line only the cotangent frame contains, so finding it is finding the
	// maths rather than finding a call to it.
	String maths = "float3 dp_dy_perp = cross(dp_dy, n);";

	String shared = three::shader_source("surface.slang", mem)!!;
	defer shared.free(mem);
	test::@check(shared.contains(maths), "the shared block is where the frame is built");

	String[2] names = { "mesh.slang", "material.slang" };
	foreach (name : names)
	{
		@pool()
		{
			String path = three::find_shader(name, tmem)!!;
			String file = three::load_source(path, tmem)!!;
			test::@check(
				!file.contains(maths),
				"%s does not carry its own copy of the frame",
				name
			);
			test::@check(has_marker_line(file), "%s asks for the shared block", name);
			String compiled = three::shader_source(name, tmem)!!;
			test::@check(
				compiled.contains(maths) && !has_marker_line(compiled),
				"and what is compiled has it spliced in: %s",
				name
			);
			test::@check(
				compiled.contains("mapped_normal_frame"),
				"%s can call mapped_normal_frame",
				name
			);
		};
	}
}

// ============================================================================
// From a script
// ============================================================================

// Is the marker still a line of its own in here?
//
// By line rather than by substring, because the shared block's own header
// mentions the marker in a sentence — and a check that could not tell a comment
// about the mechanism from the mechanism would fail on a rewording.
fn bool has_marker_line(String source)
{
	foreach (line : source.tsplit("\n")) if (line.trim() == "//@shared") return true;
	return false;
}

<*
 A normal map set from JavaScript reaches the GPU and changes the picture.

 The whole path in one check, because every layer under it is where this feature
 was already working: the texture uploaded, the reference was taken and
 `ref.material` reported it, and not one pixel moved. So the assertion is on the
 frame, either side of a single assignment made by a script.
*>
fn void a_normal_map_set_from_a_script_changes_the_frame() @test
{
	@with_js(; three::JsRuntime* run, three::Renderer* renderer)
	{
		three::RunResult built = run.run(
			`const scene = new three.Scene();
			three.light.set([0, 0, 1], 0);
			// A flat 72-degree tilt, as data rather than as a picture.
			const px = new Uint8Array(4 * 4 * 4);
			for (let i = 0; i < 16; i++) {
				px[i * 4] = 242; px[i * 4 + 1] = 128; px[i * 4 + 2] = 167; px[i * 4 + 3] = 255;
			}
			globalThis.BENT = new three.DataTexture(px, 4, 4, {
				colorSpace: three.LinearSRGBColorSpace,
			});
			globalThis.MAT = new three.MeshLambertMaterial({ });
			const plane = new three.Mesh(new three.PlaneGeometry(2, 2), globalThis.MAT);
			scene.add(plane);
			three.camera.frameAll();
			return globalThis.MAT.normalMap === null;`
		);
		defer built.free();
		test::@check(built.ok, "the scene was built: %s", built.error);
		test::@check(built.value == "true", "and starts with no normal map, got %s", built.value);

		uint flat = centre(renderer);

		three::RunResult set = run.run(`globalThis.MAT.normalMap = globalThis.BENT; return 'set';`);
		defer set.free();
		test::@check(set.ok, "the map was assigned: %s", set.error);

		uint bent = centre(renderer);
		test::@check(
			bent + 20 < flat,
			"and the frame changed: %d without the map, %d with it",
			flat,
			bent
		);
	};
}

<*
 A map loaded as a picture is refused by name.
 
 Every one of the three is *data*, and an sRGB view bends every value in it: a
 normal that means "no tilt" arrives leaning and a roughness of 0.5 arrives at
 0.21. The result reads as a badly authored file rather than as a mistake in the
 script, which is exactly the kind of failure worth spending a throw on — and the
 importer already loads all three linear, so nothing that came out of a `.glb`
 ever meets it.
*>
fn void a_map_loaded_as_a_picture_is_refused() @test
{
	@with_js(; three::JsRuntime* run, three::Renderer* renderer)
	{
		three::RunResult result = run.run(
			`const px = new Uint8Array(4 * 4 * 4).fill(200);
			const asPicture = new three.DataTexture(px, 4, 4);
			const mat = new three.MeshLambertMaterial({ });
			let threw = '';
			try { mat.normalMap = asPicture; } catch (e) { threw = e.message; }
			let split = '';
			try { mat.roughnessMap = asPicture; } catch (e) { split = e.message; }
			return {
				space: threw.includes('LinearSRGBColorSpace'),
				packed: split.includes('metalnessRoughnessMap'),
				unset: mat.normalMap === null,
			};`
		);
		defer result.free();

		test::@check(result.ok, "the script ran: %s", result.error);
		test::@check(
			result.value == `{"space":true,"packed":true,"unset":true}`,
			"an sRGB map and a split one are both refused by name: %s",
			result.value
		);
	};
}
