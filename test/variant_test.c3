<*
 `material.uvVariants` — one uv transform per copy, on the channel that already
 varies per copy.

	`c3c test --trust=full --test-noleak --test-filter three_tests::variant`

 `plan.md` §27 is the entry. The claim is narrow and the checks are about
 exactly it: copies of one mesh sharing one material draw once, and the
 `variant` a script sets picks which part of the material's image each of them
 wears. Everything else about a variant — its meaning inside a `ShaderMaterial`
 body's uniform table — is unchanged and is `three_tests::material`'s.

 ## Why a two-colour image and not a gradient

 Every check below reads one pixel and asks which half of the image it came
 from. A gradient would let a check pass on a uv that is merely *near* the right
 place, and a uv transform composed in the wrong order — rotate after the repeat
 rather than before it, offset in texture units rather than in the mesh's — lands
 near the right place all the time. Two flat halves and a hard edge make the
 wrong answer the other colour.

 The image is split **along u**, which is what lets one image test all three
 parts of a row: a slide moves the edge, a mirror swaps the halves, and a
 quarter turn takes the edge from vertical to horizontal, so the frame stops
 splitting left-to-right and starts splitting top-to-bottom.

 ## Proved by injection

 Each check was re-run against the mistake it is aimed at, and the message in the
 quote is what the broken build actually produced:

 - `variant_uv` reading `turns` off `row.w` instead of `row.z`, which is the two
   small integers of a row swapped: "a quarter turn split the frame the other
   way: left red and right green" — no turn happened at all, and the frame still
   splits the way the image does.
 - the row index written as a constant 0 rather than
   `min(instance.variant, uv_variant_count - 1)`, which is the clamp both gone
   and wrong at once: three checks fail together, and the plainest is "one slide
   of one whole face crossed the image: variant 0 is red, variant 1 is red".
 - `begin_material_uv_variants` not clearing the count: "and one row over four is
   one row, got 20 numbers" — five rows, because the new row landed on the end of
   the old table instead of replacing it.

*>
module three_tests::variant;

import three;
import three_tests::device;
import vk;
import image;
import std::core::test;
import std::math;

const uint W = 120;
const uint H = 90;

// Where the probes go, as fractions of the frame.
//
// Inside the plane rather than at the quarters: `frame_camera` fits a 2x2 plane
// into a 4:3 frame with room around it, so a quarter of the way across is
// background and reads as neither half of the image. And off the middle line,
// which is where the image's own edge lands — a probe there is a coin toss under
// a nearest filter and a blend of both halves under any other.
const float LEFT  = 0.4;
const float RIGHT = 0.6;
const float ABOVE = 0.35;
const float BELOW = 0.65;

macro @with_pass(; @body(three::Renderer* renderer))
{
	three::Renderer* renderer = device::borrow(W, H);
	defer device::release();

	@body(renderer);
}

// Red on the left half, green on the right, at four texels a side so each half
// is two texels and a sample inside one cannot be filtered out of the other.
fn image::Image split_image()
{
	char[] pixels = mem::new_array(char, 4 * 4 * 4);
	for (uint y = 0; y < 4; y++)
	{
		for (uint x = 0; x < 4; x++)
		{
			sz i = (sz)(y * 4 + x) * 4;
			bool right = x >= 2;
			pixels[i] = right ? (char)0 : (char)255;
			pixels[i + 1] = right ? (char)255 : (char)0;
			pixels[i + 2] = 0;
			pixels[i + 3] = 255;
		}
	}
	return {
		.width = 4, .height = 4, .bit_depth = 8,
		.format = image::PixelFormat.RGBA, .pixels = pixels, .allocator = mem,
	};
}

// A plane filling the frame, wearing that image, lit straight down its own
// normal so the albedo arrives at full strength and a channel reads as which
// half of the image the texel came from.
fn three::NodeId lit_plane(three::Renderer* renderer, uint material)
{
	three::AssetId plane = renderer.pass.assets.primitive(&renderer.gpu, three::plane_shape(2, 2))!!;
	three::NodeId node   = renderer.pass.scene.add_mesh(plane, 0);
	renderer.pass.scene.set_material(node, material);
	renderer.pass.frame_camera();
	renderer.pass.lighting = {
		.count = 1,
		.ambient = 0,
		.lights = { { .direction = { 0, 0, 1, 0 }, .color = { 1, 1, 1, 1 } }, { }, { }, { } },
	};
	return node;
}

fn uint textured_material(three::Renderer* renderer)
{
	image::Image made = split_image();
	defer made.free();
	// Nearest, and mips off: this image is two flat halves and every check is
	// about *which* one, so a filter that blends across the edge would turn a
	// wrong uv into a plausible colour instead of the other one.
	int texture = renderer.pass.assets.claim_texture(
		&renderer.gpu, made, three::ColorSpace.SRGB, false, true
	)!!;
	return renderer.pass.create_texture_material(texture)!!;
}

// The rgb at a fraction across and down the frame. Fractions rather than pixels
// because the checks are about halves of a picture and W and H are this file's
// own numbers.
fn char[3] at(three::Renderer* renderer, float across, float down)
{
	image::Image shot = renderer.capture()!!;
	defer shot.free();
	sz bpp = shot.bytes_per_pixel();
	sz x   = (sz)(across * (float)shot.width);
	sz y   = (sz)(down * (float)shot.height);
	sz i   = (y * (sz)shot.width + x) * bpp;
	return { shot.pixels[i], shot.pixels[i + 1], shot.pixels[i + 2] };
}

// Which half of the image a pixel came from, as a word, so a failure message
// says what was seen rather than three numbers.
fn String half(char[3] rgb)
{
	if (rgb[0] > 128 && rgb[1] < 128) return "red";
	if (rgb[1] > 128 && rgb[0] < 128) return "green";
	return "neither";
}

<*
 With no table, nothing moves.

 The identity check, and the one that says every material written before this
 feature existed renders exactly as it did: `uv_variant_count` is zero, both
 shaders skip the table, and a plane wearing a split image shows the split.
*>
fn void a_material_with_no_variants_is_unchanged() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		uint material = textured_material(renderer);
		lit_plane(renderer, material);

		char[3] left  = at(renderer, LEFT, 0.5f);
		char[3] right = at(renderer, RIGHT, 0.5f);
		test::@check(
			half(left) == "red" && half(right) == "green",
			"a plane with no uv variants wears the image as it is: left %s, right %s",
			half(left),
			half(right)
		);
	};
}

<*
 A slide is in the mesh's own uv, and it is what an atlas is read with.

 `repeat` of 0.5 puts the whole plane inside the left half of the image, so it is
 red everywhere; a slide of one whole face moves it into the right half, so it is
 green everywhere. That the offset is *one* and not *one half* is the check
 inside the check — a row that slid in texture units would need 0.5 here and
 would leave this frame half red.
*>
fn void a_variant_slides_the_map_by_whole_faces() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		uint material = textured_material(renderer);
		three::NodeId node = lit_plane(renderer, material);
		renderer.pass.set_material_uv(material, 0.5f, 1.0f, 0, 0)!!;

		renderer.pass.begin_material_uv_variants(material)!!;
		renderer.pass.add_material_uv_variant(material, 0, 0, 0, 0)!!;
		renderer.pass.add_material_uv_variant(material, 1, 0, 0, 0)!!;

		renderer.pass.scene.set_variant(node, 0);
		char[3] first = at(renderer, 0.5f, 0.5f);
		renderer.pass.scene.set_variant(node, 1);
		char[3] second = at(renderer, 0.5f, 0.5f);

		test::@check(
			half(first) == "red" && half(second) == "green",
			"one slide of one whole face crossed the image: variant 0 is %s, variant 1 is %s",
			half(first),
			half(second)
		);
	};
}

<*
 A mirror swaps the halves and nothing else.

 The narrowest of the three transforms and the one with no arithmetic to get
 wrong, which is why it is worth its own check: if `flip` is read off the wrong
 component of the row, or masked as a boolean rather than as two bits, this is
 the frame that says so.
*>
fn void a_variant_mirrors_the_map() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		uint material = textured_material(renderer);
		three::NodeId node = lit_plane(renderer, material);

		renderer.pass.begin_material_uv_variants(material)!!;
		renderer.pass.add_material_uv_variant(material, 0, 0, 0, 1)!!;
		renderer.pass.scene.set_variant(node, 0);

		char[3] left  = at(renderer, LEFT, 0.5f);
		char[3] right = at(renderer, RIGHT, 0.5f);
		test::@check(
			half(left) == "green" && half(right) == "red",
			"a mirrored u put the halves the other way round: left %s, right %s",
			half(left),
			half(right)
		);
	};
}

<*
 A quarter turn turns the picture, and the order it is applied in is what makes
 that true.

 The image splits along u, so a plane wearing it splits left-to-right; a quarter
 turn has to make it split top-to-bottom instead. **This is the check that pins
 the composition order.** A turn applied after `material.repeat` would be a turn
 in the tiled space, and with a repeat of 1 that is a turn about the wrong centre
 — the edge comes back vertical and the two sides of the frame still disagree.
*>
fn void a_quarter_turn_turns_the_map() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		uint material = textured_material(renderer);
		three::NodeId node = lit_plane(renderer, material);

		renderer.pass.begin_material_uv_variants(material)!!;
		renderer.pass.add_material_uv_variant(material, 0, 0, 1, 0)!!;
		renderer.pass.scene.set_variant(node, 0);

		// Off the middle line in both directions. After a quarter turn the map
		// varies with v, so two probes at one height have to agree and two at one
		// x have to differ — and neither pair may sit *on* the middle, which after
		// the turn is the image's own edge and is a coin toss under a nearest
		// filter.
		char[3] left   = at(renderer, LEFT, ABOVE);
		char[3] right  = at(renderer, RIGHT, ABOVE);
		char[3] top    = at(renderer, 0.5f, ABOVE);
		char[3] bottom = at(renderer, 0.5f, BELOW);

		test::@check(
			half(left) == half(right) && half(left) != "neither",
			"a quarter turn split the frame the other way: left %s and right %s",
			half(left),
			half(right)
		);
		test::@check(
			half(top) != half(bottom) && half(top) != "neither" && half(bottom) != "neither",
			"and the split it made runs across it: top %s, bottom %s",
			half(top),
			half(bottom)
		);
	};
}

<*
 A variant past the last row is the last row.

 The same rule a `ShaderMaterial`'s uniform table follows, and it has to be
 enforced against *this* table's length rather than against `MATERIAL_ROWS` —
 they are two tables indexed by one channel and there is no reason for them to be
 the same size. Without the clamp this is a read off the end of the record.
*>
fn void a_variant_past_the_table_is_the_last_row() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		uint material = textured_material(renderer);
		three::NodeId node = lit_plane(renderer, material);
		renderer.pass.set_material_uv(material, 0.5f, 1.0f, 0, 0)!!;

		renderer.pass.begin_material_uv_variants(material)!!;
		renderer.pass.add_material_uv_variant(material, 0, 0, 0, 0)!!;
		renderer.pass.add_material_uv_variant(material, 1, 0, 0, 0)!!;

		renderer.pass.scene.set_variant(node, 1);
		char[3] last = at(renderer, 0.5f, 0.5f);
		renderer.pass.scene.set_variant(node, 200);
		char[3] past = at(renderer, 0.5f, 0.5f);

		test::@check(
			half(past) == half(last) && half(last) == "green",
			"a variant past the last row is the last row: row 1 is %s, row 200 is %s",
			half(last),
			half(past)
		);
	};
}

<*
 A shorter table is shorter.

 `begin_material_uv_variants` clears the count, so assigning two rows over four
 leaves two — and the third copy falls back to the second rather than to whatever
 the old table had there. The failure this exists for is a script that swaps a
 material's variation set at runtime and gets the tail of the previous one.
*>
fn void assigning_a_shorter_table_drops_the_tail() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		uint material = textured_material(renderer);
		three::NodeId node = lit_plane(renderer, material);
		renderer.pass.set_material_uv(material, 0.5f, 1.0f, 0, 0)!!;

		renderer.pass.begin_material_uv_variants(material)!!;
		for (uint i = 0; i < 4; i++) renderer.pass.add_material_uv_variant(material, 1, 0, 0, 0)!!;
		test::@check(
			renderer.pass.material_uv_variants(material).len == 16,
			"four rows is sixteen numbers, got %d", renderer.pass.material_uv_variants(material).len
		);

		renderer.pass.begin_material_uv_variants(material)!!;
		renderer.pass.add_material_uv_variant(material, 0, 0, 0, 0)!!;
		test::@check(
			renderer.pass.material_uv_variants(material).len == 4,
			"and one row over four is one row, got %d numbers",
			renderer.pass.material_uv_variants(material).len
		);

		// Row 3 of a one-row table is row 0, which is the identity — so the frame
		// is the left half of the image and not the right one the old table had.
		renderer.pass.scene.set_variant(node, 3);
		char[3] seen = at(renderer, 0.5f, 0.5f);
		test::@check(
			half(seen) == "red",
			"and the copies read the new table: %s",
			half(seen)
		);
	};
}

<*
 The ninth row is refused rather than written.

 The prelude refuses a longer list by name and with the limit in the message;
 this is the second line of defence, and what it is defending is the eight-row
 array in the draw record.
*>
fn void the_table_stops_at_eight_rows() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		uint material = textured_material(renderer);

		renderer.pass.begin_material_uv_variants(material)!!;
		for (uint i = 0; i < 20; i++) renderer.pass.add_material_uv_variant(material, (float)i, 0, 0, 0)!!;

		float[] rows = renderer.pass.material_uv_variants(material);
		test::@check(
			rows.len == (sz)three::UV_VARIANTS * 4,
			"twenty rows into an eight-row table is eight rows: got %d numbers",
			rows.len
		);
		test::@check(
			rows[(sz)(three::UV_VARIANTS - 1) * 4] == (float)(three::UV_VARIANTS - 1),
			"and the eight it kept are the first eight"
		);
	};
}

<*
 Two copies, two variants, one draw call.

 The whole reason this is a table on the material and an index on the copy rather
 than two materials. Two planes side by side wearing one material, one asset and
 one image, disagreeing about which half of that image they show — and
 `stats().draw_calls` still 1. Two materials would be the same picture and the
 number would be 2.
*>
fn void two_variants_of_one_mesh_are_one_draw_call() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		uint material        = textured_material(renderer);
		three::AssetId plane = renderer.pass.assets.primitive(&renderer.gpu, three::plane_shape(2, 2))!!;
		renderer.pass.set_material_uv(material, 0.5f, 1.0f, 0, 0)!!;
		renderer.pass.begin_material_uv_variants(material)!!;
		renderer.pass.add_material_uv_variant(material, 0, 0, 0, 0)!!;
		renderer.pass.add_material_uv_variant(material, 1, 0, 0, 0)!!;

		for (uint i = 0; i < 2; i++)
		{
			three::NodeId node = renderer.pass.scene.add_mesh(plane, 0);
			renderer.pass.scene.set_material(node, material);
			renderer.pass.scene.set_variant(node, i);
			renderer.pass.scene.set_position(node, { i == 0 ? -1.1f : 1.1f, 0, 0 });
		}

		renderer.pass.frame_camera();
		renderer.pass.lighting = {
			.count = 1,
			.ambient = 0,
			.lights = { { .direction = { 0, 0, 1, 0 }, .color = { 1, 1, 1, 1 } }, { }, { }, { } },
		};

		char[3] left  = at(renderer, 0.3f, 0.5f);
		char[3] right = at(renderer, 0.7f, 0.5f);
		test::@check(
			half(left) == "red" && half(right) == "green",
			"two copies of one mesh wore two parts of one image: left %s, right %s",
			half(left),
			half(right)
		);

		three::SceneStats stats = renderer.pass.stats();
		test::@check(
			stats.draw_calls == 1 && stats.instances == 2,
			"and they were one draw call: %d calls, %d instances",
			stats.draw_calls,
			stats.instances
		);
	};
}
