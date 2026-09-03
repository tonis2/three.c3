<*
 `s.origin` — where this copy is, as a body sees it.

	`c3c test --trust=full --test-noleak --test-filter three_tests::origin`

 `plan.md` §27. One value per copy, read off the instance's model matrix, and the
 seed every per-copy trick wants: a tint that drifts per copy, a macro noise that
 does not restart at every piece of a kit, a wave whose phase is the tree rather
 than the leaf.

 ## What the checks are really about

 Two claims, and neither is "the number arrives".

 **It is the copy's origin and not the fragment's position.** A body handed
 `s.position` already has something world-space that varies; what it does not
 have is something that is *the same across a whole copy and different between
 two of them*. So the first check reads two points of one surface and requires
 them to agree, and the second reads two copies and requires them to differ —
 and a body wired to `s.position` by mistake passes the second and fails the
 first.

 **It survives the vertex stage.** `Vertex.origin` is an input beside `local` and
 `index`, and `fragmentMain` takes the varying rather than recomputing it, so a
 body that displaces a vertex still knows where the copy it belongs to stands.

 ## Proved by injection

 - `s.origin = input.origin` changed to `s.origin = input.world`, which is the
   plausible confusion of the copy's origin with the fragment's position: "one
   copy has one origin: 241 at the top of the plane, 241 at the bottom, 235 at
   the left, 245 at the right" — it varies across the surface, which is the whole
   thing it must not do. (It varies only left to right, because the body paints
   x; the check reads both axes so a body painting y is caught too.)
 - `v.origin` left at zero in `vertexMain`: "two copies two units apart disagree
   about where they are: 188 and 188", and the vertex-body check fails beside it
   with 127 and 127.

 One injection that does *not* fail is worth recording: recomputing
 `output.origin` from `v.position` in the vertex stage still passes, because the
 varying is `nointerpolation` and every fragment of a triangle then reads the
 provoking vertex's value — constant across the triangle, which is most of what
 these checks ask for. That is why the fragment-stage injection is the one
 quoted: it is the one the flat varying cannot hide.
*>
module three_tests::origin;

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

// A body that paints its copy's x, mapped into 0..1 over a few units either side
// of the origin so the answer is a grey and not a clipped one.
const String PAINT_ORIGIN_X =
	"float3 shade(Surface s) { float k = saturate(s.origin.x * 0.125 + 0.5); return float3(k, k, k); }";

// The same, from the vertex stage — written into the copy's colour, which the
// fragment stage carries whatever the body does afterwards.
const String CARRY_ORIGIN_FROM_VERTEX =
	"void displace(inout Vertex v) { float k = saturate(v.origin.x * 0.125 + 0.5); v.color = float4(k, k, k, 1.0); }";

fn uint painted_material(three::Renderer* renderer, String fragment, String vertex = "")
{
	return renderer.pass.create_material(
		&renderer.gpu,
		&renderer.target,
		fragment,
		{ },
		vertex: vertex,
		// A vertex body that only writes a colour still moves nothing, but the
		// renderer has no way to know that, and a bounds of zero on a material
		// with a `displace` is what the culler reads as "this may not move".
		bounds: 0
	)!!;
}

// A plane at `x`, wearing `material`. Two of these is the whole arrangement.
fn void plane_at(three::Renderer* renderer, uint material, float x)
{
	three::AssetId plane = renderer.pass.assets.primitive(&renderer.gpu, three::plane_shape(2, 2))!!;
	three::NodeId node   = renderer.pass.scene.add_mesh(plane, 0);
	renderer.pass.scene.set_material(node, material);
	renderer.pass.scene.set_position(node, { x, 0, 0 });
}

fn void look_at_it(three::Renderer* renderer)
{
	renderer.pass.frame_camera();
	renderer.pass.lighting = {
		.count = 1,
		.ambient = 1,
		.lights = { { .direction = { 0, 0, 1, 0 }, .color = { 1, 1, 1, 1 } }, { }, { }, { } },
	};
}

// The green channel at a fraction across and down the frame.
fn uint at(three::Renderer* renderer, float across, float down)
{
	image::Image shot = renderer.capture()!!;
	defer shot.free();
	sz bpp = shot.bytes_per_pixel();
	sz x   = (sz)(across * (float)shot.width);
	sz y   = (sz)(down * (float)shot.height);
	return shot.pixels[(y * (sz)shot.width + x) * bpp + 1];
}

<*
 One copy has one origin.

 The half that says this is not `s.position` under another name: every fragment
 of one plane reads the same value, however far apart on it they are.
*>
fn void one_copy_has_one_origin() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		uint material = painted_material(renderer, PAINT_ORIGIN_X);
		plane_at(renderer, material, 3.0f);
		look_at_it(renderer);

		uint top    = at(renderer, 0.5f, 0.35f);
		uint bottom = at(renderer, 0.5f, 0.65f);
		uint left   = at(renderer, 0.42f, 0.5f);
		uint right  = at(renderer, 0.58f, 0.5f);

		test::@check(
			top == bottom && left == right,
			"one copy has one origin: %d at the top of the plane, %d at the bottom, "
				"%d at the left, %d at the right",
			top,
			bottom,
			left,
			right
		);
	};
}

<*
 Two copies have two.

 The other half, and the whole point: two copies of one mesh sharing one material
 disagree about where they are, with no channel set on either of them and no
 second material anywhere.
*>
fn void two_copies_have_two_origins() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		uint material = painted_material(renderer, PAINT_ORIGIN_X);
		plane_at(renderer, material, -1.1f);
		plane_at(renderer, material, 1.1f);
		look_at_it(renderer);

		uint left  = at(renderer, 0.3f, 0.5f);
		uint right = at(renderer, 0.7f, 0.5f);
		test::@check(
			left < right && right - left > 20,
			"two copies two units apart disagree about where they are: %d and %d",
			left,
			right
		);

		three::SceneStats stats = renderer.pass.stats();
		test::@check(
			stats.draw_calls == 1 && stats.instances == 2,
			"and they are still one draw call: %d calls, %d instances",
			stats.draw_calls,
			stats.instances
		);
	};
}

<*
 A vertex body reads the same origin.

 It is an input there beside `local` and `index`, which is what a displacement
 keyed on the copy rather than on the vertex needs — a wave whose phase is the
 tree and not the leaf. Carried out through `v.color` because that is the one
 channel a vertex body can write and a default fragment body will show.
*>
fn void a_vertex_body_reads_the_origin() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		uint material = painted_material(
			renderer,
			"float3 shade(Surface s) { return s.color.rgb; }",
			CARRY_ORIGIN_FROM_VERTEX
		);
		plane_at(renderer, material, -1.1f);
		plane_at(renderer, material, 1.1f);
		look_at_it(renderer);

		uint left  = at(renderer, 0.3f, 0.5f);
		uint right = at(renderer, 0.7f, 0.5f);
		test::@check(
			left < right && right - left > 20,
			"a vertex body reads the copy's origin: %d and %d",
			left,
			right
		);
	};
}
