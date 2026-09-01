<*
 The heightfield: the surface, the query, and that they are the same numbers —
 `src/scene/terrain.c3`, `plan.md` §18.4.

	`c3c test --trust=full --test-noleak --test-filter three_tests::terrain`

 **What is worth asserting here is not "does it produce triangles".** The three
 failures this shape exists to prevent all produce a mesh that draws:

 - A query that disagrees with the mesh. That is the whole reason the height
   function moved into the engine, and it is invisible in a screenshot until
   something is standing a metre under the ground.
 - Normals taken from the triangles rather than from the grid, which is a
   staircase that shades like a staircase — the defect the box tiles had.
 - A height array read at the wrong stride, which is a plausible-looking
   diagonal ripple and nothing that says why.

 So the checks are built around those: the query is compared against the mesh's
 own bounds and against closed-form values of the function that generated it, the
 normals are compared against the analytic gradient of a known slope, and the
 stride is checked by making the field deliberately asymmetric in x and z.
*>
module three_tests::terrain;

import three;
import vk;
import std::core::test;
import std::math;
import std::math::vector;
import std::collections::list;

alias Vec3 = float[<3>];

const uint W = 96;
const uint H = 72;

macro @with_pass(; @body(three::Renderer* renderer))
{
	vk::Instance instance = three::create_instance(false, headless: true)!!;
	defer instance.free();

	three::Renderer renderer;
	renderer.init(instance, (vk::SurfaceKHR)null, W, H)!!;
	defer renderer.free();

	renderer.pass.init(&renderer.gpu, &renderer.target)!!;

	@body(&renderer);
}

<*
 A field over `width` x `depth` at `segments` cells, sampled from `f`.

 A function pointer rather than a macro body, because these fixtures are the
 *closed forms* the queries are checked against and a named function is what lets
 the check and the sampling name the same one.

 The caller keeps the list; `Assets.terrain` copies it onto the asset.
*>
alias HeightFn = fn float(float x, float z);

fn three::Heightfield make_field(float width, float depth, uint segments, HeightFn f)
{
	three::Heightfield field = { .width = width, .depth = depth, .segments = segments };
	uint side = segments + 1;
	field.heights.init(mem, (usz)side * (usz)side);
	for (uint j = 0; j < side; j++)
	{
		float z = -depth * 0.5f + (float)j / (float)segments * depth;
		for (uint i = 0; i < side; i++)
		{
			float x = -width * 0.5f + (float)i / (float)segments * width;
			field.heights.push(f(x, z));
		}
	}
	return field;
}

// A plane, steeper in x than in z: the one surface bilinear interpolation is
// exact on, so any error at all is a real error.
fn float tilted_plane(float x, float z) => x * 0.25f + z * 0.05f + 3.0f;
// A ramp with no z component, whose unit normal is (-0.5, 1, 0) normalized.
fn float ramp(float x, float z) => x * 0.5f;
// A dome, where a grid normal and a triangle normal genuinely differ.
fn float dome(float x, float z) => 20.0f - (x * x + z * z) * 0.02f;
// A shallow slope for the asset checks.
fn float shallow(float x, float z) => x * 0.1f;

<*
 The query reproduces the function the grid was sampled from, everywhere.

 **A plane, because a plane is the one surface where bilinear interpolation is
 exact.** Any error at all is then a real error rather than the interpolation's
 own — no tolerance to argue about, no "close enough at the cell centres". The
 plane is deliberately steeper in x than in z and the field is deliberately
 rectangular, so a query that swapped the axes, or that read the array at the
 wrong stride, lands somewhere else entirely.

 Sampled off the grid on purpose: at cell centres, at thirds, and at the exact
 corners. A `height_at` that snapped to the nearest sample passes at the corners
 and fails everywhere between.
*>
fn void the_query_is_the_surface() @test
{
	three::Heightfield field = make_field(40.0f, 20.0f, 16, &tilted_plane);
	defer field.heights.free();

	for (int i = 0; i <= 37; i++)
	{
		float x = -20.0f + (float)i * (40.0f / 37.0f);
		for (int j = 0; j <= 23; j++)
		{
			float z = -10.0f + (float)j * (20.0f / 23.0f);
			float want = x * 0.25f + z * 0.05f + 3.0f;
			float got = field.height_at(x, z);
			test::@check(
				math::abs(got - want) < 1e-3f,
				"height_at(%f, %f) is %f, the plane says %f", x, z, got, want
			);
			if (math::abs(got - want) >= 1e-3f) return;
		}
	}
}

<*
 Off the map, the edge extends outwards rather than dropping to zero.

 The alternative is a character walking off the world and falling through the
 floor at the boundary, which is what an unclamped index or a zero default both
 produce — and both of them look like the physics failing rather than like the
 query answering a question about somewhere that does not exist.
*>
fn void off_the_map_keeps_the_edge() @test
{
	three::Heightfield field = make_field(20.0f, 20.0f, 8, &ramp);
	defer field.heights.free();

	float edge = field.height_at(10.0f, 0);
	float beyond = field.height_at(1000.0f, 0);
	test::@check(
		math::abs(beyond - edge) < 1e-3f,
		"a query 1000 units off the map answers %f, the edge is %f", beyond, edge
	);
	test::@check(edge > 0.0f, "and the edge is the real height, %f", edge);
}

<*
 Normals come from the grid, and they are the slope's.

 On a constant slope of `dy/dx = k` the unit normal is `(-k, 1, 0)` normalized,
 and that is asserted directly rather than as "points roughly up". A normal
 computed from a triangle's cross product on this same surface would be *right*
 here — a plane is a plane — which is why the second half matters: the same check
 on a surface with curvature in it, where the two differ, requires the normal at
 a sample to lean the way the neighbours do rather than the way one triangle
 does.
*>
fn void normals_are_the_slope() @test
{
	three::Heightfield slope = make_field(20.0f, 20.0f, 20, &ramp);
	defer slope.heights.free();

	Vec3 want = ((Vec3){ -0.5f, 1.0f, 0.0f }).normalize();
	Vec3 got = slope.normal_at(1.3f, -2.7f);
	test::@check(
		math::abs(got.x - want.x) < 1e-3f && math::abs(got.y - want.y) < 1e-3f && math::abs(got.z - want.z) < 1e-3f,
		"the ramp's normal is (%f, %f, %f), the slope says (%f, %f, %f)",
		got.x, got.y, got.z, want.x, want.y, want.z
	);

	// A dome: the normal has to lean away from the summit, and by more the
	// further out it is. A per-triangle normal on a coarse grid points along
	// whichever way its own diagonal happens to run and fails the second half.
	three::Heightfield hill = make_field(40.0f, 40.0f, 20, &dome);
	defer hill.heights.free();

	Vec3 near = hill.normal_at(4.0f, 0);
	Vec3 far = hill.normal_at(14.0f, 0);
	// Outward, so positive on the +x flank: the surface falls away to the east
	// there, and the upward normal is (-dy/dx, 1, 0) with dy/dx negative.
	test::@check(near.x > 0.0f && far.x > 0.0f, "the dome leans the wrong way: %f then %f", near.x, far.x);
	test::@check(far.x > near.x, "and it does not lean further out: %f then %f", near.x, far.x);
	test::@check(math::abs(near.z) < 1e-3f, "with no lean across the slope, %f", near.z);
}

<*
 The asset is one mesh, and the field it was built from comes back off it.

 **The half that makes `heightAt` reachable from a script**: the grid is kept on
 the asset slot, so a geometry handle answers questions after the upload. It is
 also the half that has to survive an unload — `Assets.free_slot` frees the list,
 and a query through a stale handle must find nothing rather than freed memory,
 which is what the generation check in `slot` already does for every other field.

 The bounds check is the stride check: the field is 40 wide and 20 deep with a
 skirt, so a mesh built with the axes swapped has a box 20 wide and 40 deep and
 nothing else about it looks wrong.
*>
fn void the_field_rides_on_the_asset() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Assets* assets = &renderer.pass.assets;

		three::Heightfield field = make_field(40.0f, 20.0f, 8, &shallow);
		defer field.heights.free();
		field.skirt = 2.0f;

		three::AssetId id = assets.terrain(&renderer.gpu, &field)!!;

		three::Heightfield* back = assets.terrain_field(id);
		test::@check(back != null, "the asset does not carry its field");
		if (back == null) return;

		test::@check(
			math::abs(back.height_at(12.0f, 3.0f) - field.height_at(12.0f, 3.0f)) < 1e-4f,
			"the field on the asset answers %f where the source answers %f",
			back.height_at(12.0f, 3.0f), field.height_at(12.0f, 3.0f)
		);

		three::GpuMesh* mesh = assets.mesh(id, 0);
		test::@check(mesh != null, "the terrain uploaded no mesh");
		if (mesh == null) return;

		float width = mesh.bounds.max.x - mesh.bounds.min.x;
		float depth = mesh.bounds.max.z - mesh.bounds.min.z;
		test::@check(math::abs(width - 40.0f) < 1e-3f, "the mesh is %f wide, the field is 40", width);
		test::@check(math::abs(depth - 20.0f) < 1e-3f, "the mesh is %f deep, the field is 20", depth);
		test::@check(mesh.has_normals && mesh.has_uvs, "the terrain lost a stream");

		// Identical fields are one asset, which is the dedup every generated
		// shape gets — arrived at here by hashing the heights, because a shape
		// carrying a quarter of a million numbers has no short key.
		three::Heightfield again = make_field(40.0f, 20.0f, 8, &shallow);
		defer again.heights.free();
		again.skirt = 2.0f;
		three::AssetId twice = assets.terrain(&renderer.gpu, &again)!!;
		test::@check(
			twice.index == id.index,
			"the same field uploaded twice made two assets, %d and %d", id.index, twice.index
		);
	};
}

<*
 A height array of the wrong length is refused, not padded.

 The one mistake that would otherwise be silent and expensive: an array off by a
 row reads at the wrong stride, which produces a surface with a diagonal ripple
 running through it that looks like a bug in the noise function.
*>
fn void a_wrong_sized_field_is_refused() @test
{
	@with_pass(; three::Renderer* renderer)
	{
		three::Heightfield field = { .width = 10, .depth = 10, .segments = 4 };
		field.heights.init(mem, 16);
		defer field.heights.free();
		// 24 rather than the 25 a 4-segment field wants.
		for (uint i = 0; i < 24; i++) field.heights.push(0);

		fault why = @catch(renderer.pass.assets.terrain(&renderer.gpu, &field));
		test::@check(
			why == three::TERRAIN_HEIGHTS_WRONG_LENGTH,
			"a 24-height field for a 25-sample grid was accepted"
		);

		three::Heightfield flat = { .width = 0, .depth = 10, .segments = 4 };
		flat.heights.init(mem, 25);
		defer flat.heights.free();
		for (uint i = 0; i < 25; i++) flat.heights.push(0);
		fault sized = @catch(renderer.pass.assets.terrain(&renderer.gpu, &flat));
		test::@check(sized == three::TERRAIN_SIZE_INVALID, "a zero-width terrain was accepted");
	};
}

<*
 The skirt does not put a second copy of the unit square on top of the field.

 `Heightfield.build` promises the uv runs 0..1 across the whole field, and for a
 long time the wall broke it silently: each of the four strips ran its own u from
 0 to 1 and its own v from 0 at the top to 1 at the bottom, so a mesh with a
 skirt carried five overlapping copies of the unit square. A frame never noticed,
 because a wall is normally below the ground and out of sight.

 `scene.export({ bake: ... })` noticed at once. A bake rasterises a mesh **by its
 uv**, so the walls were drawn over the whole texture after the ground was, and a
 560 m beach came out as vertical stripes of the cliff behind it.

 The assertion is the property rather than the values: every wall vertex sits on
 the *edge* of the unit square, and the two ends of a wall column share one uv, so
 a strip has no area in uv at all and can overwrite nothing.
*>
fn void the_skirt_does_not_overlap_the_fields_uv() @test
{
	const uint SEGMENTS = 6;
	three::Heightfield field = make_field(40.0f, 20.0f, SEGMENTS, &shallow);
	defer field.heights.free();
	field.skirt = 2.0f;

	three::GeometryBuilder built;
	built.init();
	defer built.free();
	field.build(&built);

	// The grid comes first and the wall after it, which is what makes the split a
	// count rather than a search.
	sz side = (sz)SEGMENTS + 1;
	sz grid = side * side;
	test::@check(built.uvs.len() > grid, "the skirt wrote no vertices at all");

	sz off_edge = 0;
	sz mismatched = 0;
	for (sz i = grid; i < built.uvs.len(); i++)
	{
		float u = built.uvs[i][0];
		float v = built.uvs[i][1];
		bool on_edge = math::abs(u) < 1e-5f || math::abs(u - 1.0f) < 1e-5f
			|| math::abs(v) < 1e-5f || math::abs(v - 1.0f) < 1e-5f;
		if (!on_edge) off_edge++;
		// The strip is written as pairs — the top of a column, then its foot. The
		// parity is counted from where the wall starts, not from zero: the grid
		// above it has an odd vertex count whenever `side` is odd.
		if ((i - grid) % 2 == 1)
		{
			float pu = built.uvs[i - 1][0];
			float pv = built.uvs[i - 1][1];
			if (math::abs(u - pu) > 1e-5f || math::abs(v - pv) > 1e-5f) mismatched++;
		}
	}

	test::@check(off_edge == 0,
		"%d of the skirt's %d vertices have a uv inside the field's own square, which is a "
		"second copy of it laid over the first",
		off_edge, built.uvs.len() - grid);
	test::@check(mismatched == 0,
		"%d wall columns have a different uv at the foot than at the top, so the strip covers "
		"area in uv space and a bake would draw it over the ground",
		mismatched);
}
