<*
 Material layers: `CUSTOM_materials_layers` from a file, and the shading body a
 stack generates.

	`c3c test --trust=full --test-noleak --test-filter three_tests::layers`

 The fixture is `test/fixtures/layered.glb`, written by `make_layered.py` and
 checked in beside it so that what the binary holds is readable. Three of its
 pieces are load-bearing in a way their names do not say, and each has a check
 here that fails when it is removed:

 - **The three masked layers all read one image**, differing only in channel, so
   `hoist_shared_mask` has something to hoist. Without the hoist the file still
   renders correctly and spends four sampler bindings where it needs one — which
   is invisible until a fifth layer is refused for a budget that was never really
   full.
 - **`weathered` masks itself with the image `terrain` uses as its base colour**,
   so image 0 is decoded once as sRGB and once as linear. That is the only thing
   in the suite that fails when `ImageMemo.space` is deleted, and it fails as two
   slots collapsing into one rather than as an error.
 - **One layer's mask is `VERTEX_COLOR`**, reading a channel of a COLOR_0 the mesh
   carries. Both halves have to survive the import — the source and the channel —
   and a loader that dropped either leaves a layer with no mask, which covers
   everything and reads as the blend modes being broken. The two meshes that carry
   the attribute store it at two different widths, because the reader has a branch
   per width and only one of them is what an exporter writes.

 The JS half is asserted on the *generated source* rather than on pixels, which is
 the opposite of `three_tests::texture`'s rule and is deliberate: a layer stack's
 output is one lerp chain and a wrong blend mode produces a perfectly plausible
 picture, while the text says in one line which mode was emitted. The stack is
 compiled as well — `createMaterial` runs Slang on it — so "it generates" and "it
 is valid Slang" are both covered without a frame being rendered.
*>
module three_tests::layers;

import three;
import vk;
import image;
import std::core::test;
import std::io;
import std::math;

const String FIXTURE = "test/fixtures/layered.glb";

const uint W = 200;
const uint H = 150;

macro @with_js_gpu(; @body(three::JsRuntime* run))
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

	@body(&runtime);
}

<*
 Run one script and hand back what it returned, failing the test if it threw.

 The scripts below are long enough that a bare `run` plus two checks at every call
 site would be most of the file. `what` names the check in the failure so a red
 line says which script broke rather than only which assertion.
*>
macro String? script(three::JsRuntime* run, String what, String source)
{
	three::RunResult result = run.run(source);
	defer result.free();
	if (!result.ok)
	{
		test::@check(false, "%s: %s", what, result.error);
		return "";
	}
	return result.value.copy(mem);
}

<*
 How many pixels are close to a colour — `js_test`'s `count_near`, which is in
 another module and is the same three subtractions.

 The tolerance is wide for the same reason it is there: what is asserted is which
 value reached the shader, not what the encode did to its last few bits.
*>
fn uint near(image::Image* shot, int r, int g, int b, int tolerance = 24)
{
	uint found = 0;
	for (sz i = 0; i < shot.pixels.len; i += 4)
	{
		int dr = (int)shot.pixels[i] - r;
		int dg = (int)shot.pixels[i + 1] - g;
		int db = (int)shot.pixels[i + 2] - b;
		if (math::abs(dr) <= tolerance && math::abs(dg) <= tolerance && math::abs(db) <= tolerance) found++;
	}
	return found;
}

// How many times `needle` occurs in `haystack`. `String.contains` answers whether
// a line was emitted; the checks below need to know that it was emitted *once*.
fn uint count_of(String haystack, String needle)
{
	uint found = 0;
	for (sz i = 0; i + needle.len <= haystack.len; i++)
	{
		if (haystack[i:needle.len] == needle) found++;
	}
	return found;
}

// ============================================================================
// The importer
// ============================================================================

<*
 A file authored with the extension arrives as a stack, and one without it does
 not arrive as an empty stack.

 The two answers have to be different. `null` means the material never carried the
 extension and `[]` would mean it carried one with nothing in it — and a script
 deciding whether to build a `LayeredMaterial` at all reads exactly this.
*>
fn void a_layered_material_reaches_the_script_and_a_plain_one_does_not() @test
{
	@with_js_gpu(; three::JsRuntime* run)
	{
		String answer = script(run, "the stack imports", `
			const asset = three.load("test/fixtures/layered.glb");
			const stack = asset.mesh("terrain").layers;
			return ({
				meshes: asset.meshes,
				plain: asset.mesh("plain").layers,
				count: stack.layers.length,
				names: stack.layers.map(l => l.name),
				blends: stack.layers.map(l => l.blend),
			});
		`)!!;
		defer answer.free(mem);

		test::@check(answer.contains(`"plain":null`), "a material with no extension has no stack: %s", answer);
		test::@check(answer.contains(`"count":5`), "every layer crosses, disabled ones included: %s", answer);
		test::@check(
			answer.contains(`["rock","moss","snow","off","painted"]`),
			"in the file's own order, with the file's own names: %s",
			answer
		);
		// The ordinals are `gltf.c3l`'s and the names are the prelude's, so this is
		// the one check that the two ends of that translation agree.
		test::@check(
			answer.contains(`["mix","multiply","screen","add","overlay"]`),
			"and each blend mode is named from its ordinal: %s",
			answer
		);
	};
}

<*
 Every layer masked by one image reads one sampler, not one each.

 The hoist. Three layers name texture 1 and differ only in `channel`, which is the
 arrangement the extension's channel field exists for — so the stack carries the
 mask and the layers carry `null`. A file that got this wrong would render
 identically and spend three bindings of the eight a material has.
*>
fn void one_mask_read_by_three_layers_is_one_texture() @test
{
	@with_js_gpu(; three::JsRuntime* run)
	{
		String answer = script(run, "the mask hoists", `
			const stack = three.load("test/fixtures/layered.glb").mesh("terrain").layers;
			return ({
				shared: stack.mask !== null,
				space: stack.mask.colorSpace,
				own: stack.layers.map(l => l.maskTexture === null),
				channels: stack.layers.map(l => l.mask),
				sources: stack.layers.map(l => l.maskSource),
				inverted: stack.layers.map(l => l.invert),
			});
		`)!!;
		defer answer.free(mem);

		test::@check(answer.contains(`"shared":true`), "the stack carries the shared mask: %s", answer);
		// A mask is a weight rather than a colour. Through an sRGB view every one
		// of them is read through a transfer function it was never encoded with.
		test::@check(
			answer.contains(`"space":"srgb-linear"`),
			"and it was uploaded linear, because its channels are numbers: %s",
			answer
		);
		test::@check(
			answer.contains(`"own":[true,true,true,true,true]`),
			"so no layer holds a mask of its own: %s",
			answer
		);
		test::@check(
			answer.contains(`"channels":["r","g","b","a","g"]`),
			"each layer keeps the channel it read: %s",
			answer
		);
		// The channel and the source are two fields, so the last layer's `g` is the
		// green of the mesh's colour attribute and the second layer's is the green
		// of the shared image. A translation that folded them into one would have to
		// pick, and the picture is wrong either way it picks.
		test::@check(
			answer.contains(`"sources":["texture","texture","texture","texture","vertexColor"]`),
			"and where it read it from: %s",
			answer
		);
		test::@check(answer.contains(`"inverted":[false,false,true,false,false]`), "and its invert: %s", answer);
	};
}

<*
 One glTF image read as a colour and as a mask is two texture slots.

 **The check that fails when `ImageMemo.space` is deleted**, and it fails silently
 in the worst way: the memo answers the mask with the sRGB slot, the picture is
 right, nothing errors, and every weight in the stack is wrong by the sRGB
 transfer curve. `claim_texture` already treated the colourspace as part of a
 texture's identity; the memo standing in front of it did not.

 `weathered` exists in the fixture for this and nothing else — the two readings
 have to come from different primitives, because the memo is per file.
*>
fn void one_image_used_as_a_colour_and_as_a_mask_is_two_uploads() @test
{
	@with_js_gpu(; three::JsRuntime* run)
	{
		String answer = script(run, "the colourspaces split", `
			const asset = three.load("test/fixtures/layered.glb");
			// terrain's base colour is image 0, read sRGB. weathered masks itself
			// with the same image, read linear.
			const terrain = asset.mesh("terrain").layers;
			const weathered = asset.mesh("weathered").layers;
			return ({
				maskSpace: weathered.mask.colorSpace,
				maskSize: [weathered.mask.width, weathered.mask.height],
				// The stack's own mask is texture 1 and weathered's is image 0, so
				// two different slots is the answer either way; what this asserts is
				// that the *linear* one exists at all.
				sharedIsOther: terrain.mask.width !== weathered.mask.width
					|| terrain.mask.colorSpace === weathered.mask.colorSpace,
				layer: weathered.layers[0].blend,
			});
		`)!!;
		defer answer.free(mem);

		test::@check(
			answer.contains(`"maskSpace":"srgb-linear"`),
			"the same image read as a mask comes back linear: %s",
			answer
		);
		test::@check(answer.contains(`"maskSize":[8,8]`), "and it is the image it named: %s", answer);
		test::@check(answer.contains(`"layer":"multiply"`), "with its layer intact: %s", answer);
	};
}

<*
 A layer's own alpha and its opacity are one number by the time a script sees it.

 The extension carries both — `baseColorFactor.a` is the layer material's
 transparency and `opacity` is how much of the layer is applied — and they always
 appear together. Folding them at the boundary means the generated shader has one
 multiply rather than two, and means a script reading `opacity` back gets the
 number that is actually in effect.

 0.5 and 0.6 in the fixture, because 0.3 is a value neither of them has alone: a
 loader that dropped either one would produce a plausible number.
*>
fn void a_layers_alpha_and_its_opacity_are_folded_together() @test
{
	@with_js_gpu(; three::JsRuntime* run)
	{
		String answer = script(run, "the opacities fold", `
			const stack = three.load("test/fixtures/layered.glb").mesh("terrain").layers;
			const moss = stack.layers[1];
			return ({ folded: Math.round(moss.opacity * 1000) / 1000, tint: moss.tint.map(c => Math.round(c * 100) / 100) });
		`)!!;
		defer answer.free(mem);

		test::@check(answer.contains(`"folded":0.3`), "0.5 opacity times 0.6 alpha is 0.3: %s", answer);
		test::@check(answer.contains(`"tint":[0.2,0.6,0.25]`), "and the rgb is the factor's: %s", answer);
	};
}

<*
 The per-layer PBR half of the extension is dropped by the importer rather than
 carried.

 There is a specular term now, and it reads one roughness and one metalness for a
 whole material — `material.roughness` and `material.metalness`. A *layer's* pair
 still has nothing behind it, and subsurface, height and bump have nothing behind
 them at all. The fixture writes a metallicFactor and a roughnessFactor on its
 first layer and a heightTexture on the base; none of them may appear in what a
 script is handed, because an API surface that provably changes no pixel costs
 more to discover than it is worth.
*>
fn void the_parts_with_no_equation_behind_them_do_not_cross() @test
{
	@with_js_gpu(; three::JsRuntime* run)
	{
		String answer = script(run, "the pbr half is dropped", `
			const stack = three.load("test/fixtures/layered.glb").mesh("terrain").layers;
			return Object.keys(stack.layers[0]).sort();
		`)!!;
		defer answer.free(mem);

		String[5] absent = { "metal", "rough", "subsurface", "height", "bump" };
		foreach (gone : absent)
		{
			test::@check(!answer.contains(gone), "'%s' is not a field a layer has: %s", gone, answer);
		}
		test::@check(answer.contains("blend") && answer.contains("tint"), "what is left is what shades: %s", answer);
	};
}

// ============================================================================
// The generator
// ============================================================================

<*
 A stack imported from a file compiles, and the body says what it did.

 The whole five-layer stack, as the file wrote it. Every assertion here is on a
 line of Slang that is only there if one specific thing was carried across
 correctly.
*>
fn void an_imported_stack_generates_the_shader_it_describes() @test
{
	@with_js_gpu(; three::JsRuntime* run)
	{
		String answer = script(run, "an imported stack compiles", `
			const stack = three.load("test/fixtures/layered.glb").mesh("terrain").layers;
			const mat = new three.LayeredMaterial(stack);
			return mat.fragment;
		`)!!;
		defer answer.free(mem);

		// One sample of the shared mask for the whole stack, read by channel.
		test::@check(answer.contains("float4 mask = layer_mask.Sample(s.uv);"), "the mask is sampled once: %s", answer);
		test::@check(answer.contains("float w0 = mask.r;"), "layer 0 reads red: %s", answer);
		test::@check(answer.contains("float w2 = 1.0 - mask.b;"), "and layer 2 reads blue, inverted: %s", answer);

		// The blend mode is the choice of expression rather than a runtime compare.
		test::@check(answer.contains("c = lerp(c, b0, w0);"), "MIX is the layer itself: %s", answer);
		test::@check(answer.contains("c = lerp(c, c * b1, w1);"), "MULTIPLY is a multiply: %s", answer);
		test::@check(
			answer.contains("c = lerp(c, 1.0 - (1.0 - c) * (1.0 - b2), w2);"),
			"SCREEN is a screen: %s",
			answer
		);

		// The disabled layer emitted nothing at all — no sampler, no lerp.
		test::@check(!answer.contains("b3"), "the disabled layer is absent rather than multiplied by zero: %s", answer);

		// A normal map anywhere in the stack means one decode at the bottom.
		test::@check(answer.contains("mapped_normal(s, nt)"), "one cotangent frame for the stack: %s", answer);
		test::@check(answer.contains("+ e;"), "and the emissive is added after the light: %s", answer);
	};
}

<*
 A vertex-colour mask reads the attribute, and costs no binding to do it.

 This was a refusal until the draw buffer, and the refusal was honest: the meshes
 here carried positions, normals and uvs, and the fourth stream could not be added
 because the geometry contract was pushed per draw against the 128 bytes every
 material's uniforms were also spending. Moving the contract into a `DrawRecord`
 is what paid for it.

 Two things are checked and the second is the one that would rot: the weight comes
 from `s.vertex_color`, and the layer declares **no sampler** for it. A mask that
 quietly took a binding would work, look right, and cost one of the eight a
 material has — which is exactly the failure `hoist_shared_mask` exists to prevent
 one field along.
*>
fn void a_vertex_colour_mask_reads_the_attribute() @test
{
	@with_js_gpu(; three::JsRuntime* run)
	{
		String answer = script(run, "the vertex mask generates", `
			const stack = three.load("test/fixtures/layered.glb").mesh("terrain").layers;
			const fromFile = new three.LayeredMaterial(stack);
			const byHand = new three.LayeredMaterial({
				layers: [{ tint: [1, 0, 0], maskSource: "vertexColor", invert: true }],
			});
			return ({
				file: fromFile.fragment,
				samplers: Object.keys(fromFile.textures),
				hand: byHand.fragment,
				handSamplers: Object.keys(byHand.textures),
			});
		`)!!;
		defer answer.free(mem);

		// The file's own `painted` layer, which named channel G.
		test::@check(
			answer.contains(`float w4 = s.vertex_color.g;`),
			"the file's vertex mask reads the channel it named: %s",
			answer
		);
		test::@check(
			!answer.contains("layer4_mask"),
			"and declares no sampler to do it: %s",
			answer
		);
		// By hand, with no channel given: red, and inverted.
		test::@check(
			answer.contains(`float w0 = 1.0 - s.vertex_color.r;`),
			"a source with no channel reads red, and invert still applies: %s",
			answer
		);
		test::@check(
			answer.contains(`"handSamplers":[]`),
			"a stack masked only by the attribute binds nothing at all: %s",
			answer
		);
	};
}

<*
 The attribute reaches the pixels, at both widths a file may store it in.

 The one check here that is not about generated text, because the thing under test
 is not the generator: it is a stream uploaded per mesh, a flag bit, a pointer in
 the draw record and a varying. Every one of those can be wrong in a way that
 still compiles, and three of them produce a plausible picture.

 Three quads, one material, `return s.vertex_color.rgb`. `terrain` stores its
 colours as normalized unsigned bytes and `weathered` as floats — the two branches
 of `read_colors` — and `plain` carries no attribute at all, so the white it comes
 back as is the default the vertex stage writes rather than anything the file said.
 A stream read at the wrong width does not produce another flat colour; it
 produces noise, or nothing.
*>
fn void the_colour_attribute_reaches_the_pixels() @test
{
	@with_js_gpu(; three::JsRuntime* run)
	{
		String answer = script(run, "three quads render", `
			const asset = three.load("test/fixtures/layered.glb");
			const scene = new three.Scene();
			const paint = new three.ShaderMaterial({
				fragment: "float3 shade(Surface s) { return s.vertex_color.rgb; }",
			});
			for (const name of ["terrain", "weathered", "plain"]) {
				const mesh = new three.Mesh(asset.mesh(name));
				mesh.material = paint;
				scene.add(mesh);
			}
			three.camera.lookAt(0, 0, 0);
			three.camera.orbit(0, 0, 4);
			three.render(scene);
			return ({ drawn: three.stats().drawCalls });
		`)!!;
		defer answer.free(mem);

		image::Image shot = run.renderer.capture()!!;
		defer shot.free();

		// The target encodes on write, so a linear 0.251 arrives as 137 rather than
		// as 64. That is the same rule `s.albedo` follows and the reason COLOR_0 is
		// not decoded on the way in: glTF defines it linear.
		uint bytes = near(&shot, 0, 255, 137);
		uint floats = near(&shot, 255, 0, 0);
		uint absent = near(&shot, 255, 255, 255);

		test::@check(bytes > 200, "the byte-stored attribute is on screen, got %d pixels", bytes);
		test::@check(floats > 200, "the float-stored one too, got %d pixels", floats);
		test::@check(absent > 200, "and a mesh without one is white, got %d pixels", absent);
	};
}

<*
 A layer that states no colour leaves what is under it alone.

 White is what `baseColorFactor` defaults to in the file and what a script leaves
 out, so it is the *absence* of a statement about colour rather than a request for
 white paint. Emitting `lerp(c, white, w)` for it — which is what this did until
 the rule was written down — is wrong in two directions at once: a layer that only
 glows bleaches whatever is beneath it, and a layer that only adds surface detail
 does the same while looking like its mask is inverted.

 Four layers, one property each, and the assertion is on which lines exist.
*>
fn void a_layer_with_nothing_to_paint_paints_nothing() @test
{
	@with_js_gpu(; three::JsRuntime* run)
	{
		String answer = script(run, "the colourless layers generate", `
			const tex = new three.DataTexture(new Uint8Array([255, 255, 255, 255]), 1, 1);
			const one = (layer) => new three.LayeredMaterial({ layers: [layer] }).fragment;
			return ({
				glow: one({ emissive: tex }),
				bumpy: one({ normal: tex }),
				silent: one({ opacity: 0.5 }),
				tinted: one({ tint: [1, 0, 0] }),
			});
		`)!!;
		defer answer.free(mem);

		test::@check(answer.contains("e = lerp(e,"), "an emissive-only layer glows: %s", answer);
		test::@check(answer.contains("nt = lerp(nt,"), "a normal-only layer tilts the surface: %s", answer);
		// The one line none of the three may have emitted. `tinted` is the control:
		// it says something about colour, so it blends, and a rule that dropped it
		// too would pass every check above.
		test::@check(
			answer.contains("float3 b0 = float3(1.0, 0.0, 0.0);") && answer.contains("c = lerp(c, b0, w0);"),
			"a layer that states a colour still blends it: %s",
			answer
		);
		test::@check(
			count_of(answer, "c = lerp") == 1,
			"and it is the only one that does, got %d: %s",
			count_of(answer, "c = lerp"),
			answer
		);
		test::@check(
			answer.contains("nothing to apply"),
			"a layer with nothing at all says so in the source: %s",
			answer
		);
	};
}

<*
 The float literals are the shortest spelling that survives the round trip.

 A `baseColorFactor` read out of a glTF is a float widened to a double, so an
 opacity of 0.3 arrives as 0.30000001192092896 and printing it is both correct and
 unreadable. The generated body is the thing somebody reads when a stack looks
 wrong, and seventeen digits of noise per layer is what makes it unreadable.

 The device rounds to the same bits either way, which is what makes this free.
*>
fn void the_generated_numbers_are_readable() @test
{
	@with_js_gpu(; three::JsRuntime* run)
	{
		String answer = script(run, "the literals are short", `
			const stack = three.load("test/fixtures/layered.glb").mesh("terrain").layers;
			return new three.LayeredMaterial(stack).fragment;
		`)!!;
		defer answer.free(mem);

		test::@check(answer.contains("* 0.3;"), "0.5 * 0.6 prints as 0.3: %s", answer);
		test::@check(answer.contains("float3(0.2, 0.6, 0.25)"), "and a tint prints as its own numbers: %s", answer);
		test::@check(!answer.contains("0.30000001"), "rather than as a widened float: %s", answer);
	};
}

<*
 Everything the renderer cannot evaluate is refused by name.

 Each of these is a sentence somebody reads instead of spending an hour on the
 wrong file. The list was one longer until the draw buffer: a vertex-colour mask
 was refused for want of a COLOR_0 stream, and is now drawn — see
 `a_vertex_colour_mask_reads_the_attribute`. What is left are the parts of the
 extension this renderer genuinely has no equation for, and the ordinary mistakes.
*>
fn void a_stack_refuses_what_this_renderer_cannot_shade() @test
{
	@with_js_gpu(; three::JsRuntime* run)
	{
		String answer = script(run, "the refusals fire", `
			const refuse = (fn) => { try { fn(); return "NOT REFUSED"; } catch (e) { return e.message; } };
			const tex = new three.DataTexture(new Uint8Array([255, 0, 0, 255]), 1, 1);
			return ({
				roughness: refuse(() => new three.LayeredMaterial({ layers: [{ roughness: 0.5 }] })),
				metalness: refuse(() => new three.LayeredMaterial({ layers: [{ metalness: 1 }] })),
				metallicRoughness: refuse(() => new three.LayeredMaterial({ layers: [{ metallicRoughness: tex }] })),
				subsurface: refuse(() => new three.LayeredMaterial({ layers: [{ subsurface: 1 }] })),
				height: refuse(() => new three.LayeredMaterial({ layers: [{ height: tex }] })),
				typo: refuse(() => new three.LayeredMaterial({ layers: [{ uvscale: 4 }] })),
				blend: refuse(() => new three.LayeredMaterial({ layers: [{ blend: "burn" }] })),
				noMask: refuse(() => new three.LayeredMaterial({ layers: [{ mask: "r" }] })),
				source: refuse(() => new three.LayeredMaterial({ layers: [{ maskSource: "vertex" }] })),
				both: refuse(() => new three.LayeredMaterial({
					layers: [{ maskSource: "vertexColor", maskTexture: tex }]
				})),
			});
		`)!!;
		defer answer.free(mem);

		// The two ways of naming a weight that cannot both be meant.
		test::@check(answer.contains("'texture' or from 'vertexColor'"), "a misspelled source lists both: %s", answer);
		test::@check(answer.contains("drop whichever is not meant"), "and naming both is refused: %s", answer);
		// The ones that point at the lighting rather than at the caller. Roughness and
		// metalness stopped being missing when the specular term arrived and are
		// refused for a different reason now: the term reads one of each per
		// material, so the sentence has to send the script to the material.
		test::@check(answer.contains("set `roughness` on the LayeredMaterial"),
			"a layer's roughness names where the real one is: %s", answer);
		test::@check(answer.contains("set `metalness` on the LayeredMaterial"),
			"and so does a layer's metalness: %s", answer);
		test::@check(answer.contains("varies per texel"),
			"a metallic-roughness map says what this renderer's is instead: %s", answer);
		test::@check(answer.contains("light transport"), "subsurface names the gap: %s", answer);
		test::@check(answer.contains("displacement or parallax"), "height says what it needs: %s", answer);
		// The three that are ordinary mistakes.
		test::@check(answer.contains("uvScale"), "a misspelled option lists the real ones: %s", answer);
		test::@check(answer.contains("softLight"), "an unknown blend lists the modes: %s", answer);
		test::@check(answer.contains("`mask` texture was given"), "a channel with no mask says so: %s", answer);
		test::@check(!answer.contains("NOT REFUSED"), "every one of them refused: %s", answer);
	};
}

<*
 The two budgets are refused in the caller's own vocabulary.

 The host refuses past both on its own and would say "9 textures were declared",
 which is true and is not the number the caller typed — they wrote layers. Being
 told the total without the thing that produced it is being told the answer to a
 sum you cannot see.

 `{ enabled: false }` is the way back under the sampler ceiling, so the check that
 it *is* a way back is here rather than beside the refusal: a disabled layer that
 still declared its sampler would make the advice in the message wrong.
*>
fn void the_sampler_and_uniform_budgets_are_refused_by_layer() @test
{
	@with_js_gpu(; three::JsRuntime* run)
	{
		String answer = script(run, "the budgets refuse", `
			const tex = new three.DataTexture(new Uint8Array([255, 0, 0, 255]), 1, 1);
			const refuse = (fn) => { try { fn(); return "NOT REFUSED"; } catch (e) { return e.message; } };
			const many = (n, extra) => ({
				mask: tex,
				layers: Array.from({ length: n }, (_, i) => ({ mask: "r", map: tex, ...extra })),
			});
			// Seven maps plus the shared mask is exactly eight, and eight is allowed.
			const full = new three.LayeredMaterial(many(7));
			// The eighth layer is the ninth sampler.
			const over = refuse(() => new three.LayeredMaterial(many(8)));
			// Turning one off gives its binding back.
			const off = many(8);
			off.layers[7].enabled = false;
			const recovered = new three.LayeredMaterial(off);
			// A float4 each, against 104 bytes: six fit and a seventh does not.
			const animated = refuse(() => new three.LayeredMaterial(many(7, { animated: true })));
			return ({ full: full.layers.length, over, recovered: recovered.layers.length, animated });
		`)!!;
		defer answer.free(mem);

		test::@check(answer.contains(`"full":7`), "seven layers over a shared mask is eight samplers: %s", answer);
		test::@check(answer.contains("needs 9 samplers"), "the ninth is refused with the count: %s", answer);
		test::@check(answer.contains("8 layers"), "in layers rather than only in textures: %s", answer);
		test::@check(answer.contains(`"recovered":7`), "and a disabled layer gives its binding back: %s", answer);
		test::@check(answer.contains("room for 6"), "seven animated layers do not fit in 104 bytes: %s", answer);
		test::@check(!answer.contains("NOT REFUSED"), "both budgets refused: %s", answer);
	};
}

<*
 An animated layer is settable and a baked one says how to become settable.

 The whole economy of this feature is that nothing costs push bytes unless it was
 asked for, which is only tolerable if the refusal for the other case is
 actionable. "No such uniform" would be true and useless: the caller did not
 misspell anything, they asked for a value that was compiled in as a literal.
*>
fn void an_animated_layer_is_live_and_a_baked_one_says_why_not() @test
{
	@with_js_gpu(; three::JsRuntime* run)
	{
		String answer = script(run, "animation is opt-in", `
			const tex = new three.DataTexture(new Uint8Array([255, 0, 0, 255]), 1, 1);
			const mat = new three.LayeredMaterial({
				mask: tex,
				layers: [
					{ name: "live", mask: "r", tint: [1, 0, 0], opacity: 0.5, animated: true },
					{ name: "baked", mask: "g", tint: [0, 1, 0] },
				],
			});
			mat.layers[0].opacity = 0.25;
			mat.layers[0].tint = [0.1, 0.2, 0.3];
			let baked = "NOT REFUSED";
			try { mat.layers[1].opacity = 0.5; } catch (e) { baked = e.message; }
			return ({
				opacity: mat.layers[0].opacity,
				tint: mat.layers[0].tint,
				// The baked one is a literal in the source and the live one is not.
				literal: mat.fragment.includes("float3(0.0, 1.0, 0.0)"),
				uniform: mat.fragment.includes("layer0_params.rgb"),
				baked,
			});
		`)!!;
		defer answer.free(mem);

		test::@check(answer.contains(`"opacity":0.25`), "an animated opacity writes through: %s", answer);
		test::@check(answer.contains(`"tint":[0.1,0.2,0.3]`), "and so does its tint: %s", answer);
		test::@check(answer.contains(`"uniform":true`), "the live layer reads a uniform: %s", answer);
		test::@check(answer.contains(`"literal":true`), "and the baked one is a literal: %s", answer);
		test::@check(answer.contains("animated: true"), "which says how to make it live: %s", answer);
	};
}

<*
 A stack with no layers shades exactly as no stack at all.

 The property the extension is built around — the base material stays in core
 glTF, so a viewer that ignores the layers still renders correctly — surviving into
 this renderer. `s.albedo` is where the stack starts, so an empty one is the
 default look and not a black surface.
*>
fn void an_empty_stack_is_the_default_look() @test
{
	@with_js_gpu(; three::JsRuntime* run)
	{
		String answer = script(run, "an empty stack compiles", `
			return new three.LayeredMaterial({ layers: [] }).fragment;
		`)!!;
		defer answer.free(mem);

		test::@check(answer.contains("float3 c = s.albedo;"), "it starts at the base material: %s", answer);
		test::@check(answer.contains("return standard(s, c, n);"), "and returns the built-in shading: %s", answer);
		test::@check(!answer.contains("lerp"), "with nothing mixed over it: %s", answer);
	};
}

<*
 A layer's uv scale tiles its detail without tiling the mask.

 The whole trick of a splat map, and the one thing about the uv handling that is
 not obvious: the mask describes one specific surface and must be sampled once
 across it, while the detail maps are the things that repeat. Sampling both with
 the same transform would repeat the terrain.
*>
fn void a_layer_tiles_its_detail_and_not_its_mask() @test
{
	@with_js_gpu(; three::JsRuntime* run)
	{
		String answer = script(run, "the uv scale is per layer", `
			const tex = new three.DataTexture(new Uint8Array([255, 0, 0, 255]), 1, 1);
			return new three.LayeredMaterial({
				mask: tex,
				layers: [{ map: tex, mask: "r", uvScale: 8, uvOffset: [0.5, 0] }],
			}).fragment;
		`)!!;
		defer answer.free(mem);

		test::@check(
			answer.contains("layer_mask.Sample(s.uv)"),
			"the mask is sampled at the surface's own uv: %s",
			answer
		);
		test::@check(
			answer.contains("Sample(s.uv * float2(8.0, 8.0) + float2(0.5, 0.0))"),
			"and the detail at its own scale and offset: %s",
			answer
		);
	};
}
