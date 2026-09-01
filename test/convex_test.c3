<*
 The convex hull: what it is shaped like, which way round it faces, and when two
 clouds are one asset.

	`c3c test --trust=full --test-noleak --test-filter three_tests::convex`

 **No GPU anywhere in this file**, for `primitive_test.c3`'s reason: `build_convex`
 fills a `GeometryBuilder` and knows nothing about a device, so every check below
 runs in microseconds. The complement — that a hull reaches the screen, and that a
 hundred of them are one draw call — is in `js_test.c3`, where there is a device.

 ## What a picture cannot check here, and this can

 Two things, and both of them are invisible in a render.

 The first is the **winding**, which is `primitive_test.c3`'s argument verbatim:
 under `CULL_MODE_BACK_BIT` an inverted face is a hole rather than a dark patch,
 and a hull is where it is most likely to go wrong, because the winding is not
 written down in this project at all — it comes out of `collision::quickhull`.
 `build_convex` therefore fixes each face against the hull's own centroid rather
 than trusting the convention, and `every_hull_face_points_outward` is the
 assertion that the fix works. If quickhull's convention ever flips, that is a
 test failure here and not a rock somebody can see through in six months.

 The second is that the surface is actually the **hull** — that every input point
 is inside it. A cloud whose farthest point was dropped still renders as a
 plausible rock, and nothing about the picture says a vertex is missing.
 `every_input_point_is_inside_the_hull` states the defining property directly,
 which is the only check that can tell a hull from a shape that merely looks like
 one.
*>
module three_tests::convex;

import three;
import collision;
import std::core::test;
import std::math;
import std::math::vector;

alias Vec3 = float[<3>];

<*
 Build a hull into arrays, run the body over it, and free it.
*>
macro @hulled(Vec3[] points; @body(three::GeometryBuilder* geometry))
{
	three::GeometryBuilder geometry;
	geometry.init();
	defer geometry.free();
	three::build_convex(&geometry, points);
	@body(&geometry);
}

fn sz triangle_count(three::GeometryBuilder* geometry) => geometry.indices.len() / 3;

<*
 A triangle's normal, taken from the order of its own indices — which is what
 makes it a check on the winding rather than on the normal stream beside it.

 Not normalised: every use here is a sign test.
*>
fn Vec3 face_normal(three::GeometryBuilder* geometry, sz triangle)
{
	Vec3 a = geometry.positions[geometry.indices[triangle * 3]];
	Vec3 b = geometry.positions[geometry.indices[triangle * 3 + 1]];
	Vec3 c = geometry.positions[geometry.indices[triangle * 3 + 2]];
	return (b - a).cross(c - a);
}

fn Vec3 face_centre(three::GeometryBuilder* geometry, sz triangle)
{
	Vec3 a = geometry.positions[geometry.indices[triangle * 3]];
	Vec3 b = geometry.positions[geometry.indices[triangle * 3 + 1]];
	Vec3 c = geometry.positions[geometry.indices[triangle * 3 + 2]];
	return (a + b + c) / 3.0f;
}

fn Vec3 centroid(three::GeometryBuilder* geometry)
{
	Vec3 total = { 0, 0, 0 };
	foreach (position : geometry.positions) total += position;
	return total / (float)geometry.positions.len();
}

<*
 A deterministic pseudo-random cloud. `Math.random` has no place in a test, and
 a fixed sequence means a failure is reproducible from the seed alone.
*>
fn Vec3[] cloud(uint seed, uint count, float radius, Allocator allocator)
{
	Vec3[] points = alloc::new_array(allocator, Vec3, (sz)count);
	uint state = seed;
	for (uint i = 0; i < count; i++)
	{
		for (usz axis = 0; axis < 3; axis++)
		{
			state = state * 1664525 + 1013904223;
			points[i][axis] = ((float)(state >> 8) / (float)(1 << 24) - 0.5f) * 2.0f * radius;
		}
	}
	return points;
}

Vec3[8] cube_corners = {
	{ -1, -1, -1 }, { 1, -1, -1 }, { 1, 1, -1 }, { -1, 1, -1 },
	{ -1, -1, 1 }, { 1, -1, 1 }, { 1, 1, 1 }, { -1, 1, 1 },
};

// ============================================================================

<*
 The hull of a cube's corners is that cube.

 The tightest statement available about correctness, because every number in it
 is known in advance: eight corners, six square faces, twelve triangles, and a
 bounding box of exactly the corners handed over. A hull that lost a corner, kept
 an interior point or triangulated a face twice fails on the count alone.
*>
fn void the_hull_of_a_cubes_corners_is_that_cube() @test
{
	@hulled(cube_corners[..]; three::GeometryBuilder* geometry)
	{
		test::@check(triangle_count(geometry) == 12, "a cube is twelve triangles, got %d", triangle_count(geometry));

		collision::Aabb3 box = three::bounds_of(geometry.positions.array_view());
		for (usz axis = 0; axis < 3; axis++)
		{
			test::@check(
				math::abs(box.min[axis] + 1.0f) < 1e-5f && math::abs(box.max[axis] - 1.0f) < 1e-5f,
				"axis %d spans %f..%f, wanted -1..1", axis, box.min[axis], box.max[axis]
			);
		}
	};
}

<*
 Points inside the hull do not reach the mesh.

 This is the half of "a point cloud is a description, not a buffer" that is
 testable without a device: a thousand points inside a cube plus its eight
 corners is still twelve triangles, because a hull is defined by what it
 encloses. It is also what makes the API safe to hand a scan to — the triangle
 count follows the *shape*, not the size of the input.
*>
fn void interior_points_do_not_reach_the_mesh() @test
{
	@pool()
	{
		// A cloud strictly inside the unit cube, with the corners appended.
		Vec3[] inside = cloud(97, 1000, 0.9f, tmem);
		Vec3[] points = alloc::new_array(tmem, Vec3, (sz)(inside.len + 8));
		points[:inside.len] = inside[..];
		points[inside.len..] = cube_corners[..];

		@hulled(points; three::GeometryBuilder* geometry)
		{
			test::@check(
				triangle_count(geometry) == 12,
				"a thousand points inside a cube is still twelve triangles, got %d", triangle_count(geometry)
			);
		};
	};
}

<*
 Every face points away from the inside.

 `primitive_test.c3` can test this against the origin because its five shapes are
 star-shaped about it. A hull is not centred on anything in particular, so the
 reference is its own centroid — which is strictly inside a convex body, so the
 statement is exact rather than approximate for every cloud below.

 The last cloud is the one that matters: an off-centre one, where a hull built
 with the winding assumed rather than checked would still pass a test written
 against the origin.
*>
fn void every_hull_face_points_outward() @test
{
	@pool()
	{
		Vec3[][4] clouds = {
			cube_corners[..],
			cloud(1, 40, 1.0f, tmem),
			cloud(2, 200, 3.0f, tmem),
			cloud(3, 60, 1.0f, tmem),
		};
		// Push the last one well away from the origin.
		foreach (&point : clouds[3]) *point += (Vec3){ 20, -8, 13 };

		foreach (index, points : clouds)
		{
			@hulled(points; three::GeometryBuilder* geometry)
			{
				test::@check(triangle_count(geometry) > 0, "cloud %d produced no triangles", index);
				Vec3 inside = centroid(geometry);
				for (sz t = 0; t < triangle_count(geometry); t++)
				{
					Vec3 normal = face_normal(geometry, t);
					Vec3 outward = face_centre(geometry, t) - inside;
					test::@check(
						normal.dot(outward) > 0,
						"triangle %d of cloud %d faces inward: normal %s, outward %s",
						t, index, normal, outward
					);
				}
			};
		}
	};
}

<*
 The normal stream agrees with the winding, and is the same for all three
 corners of a face.

 Both halves are the flat shading: a hull that inherited smoothed normals would
 pass the first check and fail the second, and it would look like a badly
 tessellated sphere rather than like a stone.
*>
fn void the_hull_is_flat_shaded() @test
{
	@pool()
	{
		@hulled(cloud(11, 80, 1.0f, tmem); three::GeometryBuilder* geometry)
		{
			test::@check(
				geometry.positions.len() == geometry.indices.len(),
				"flat shading is one vertex per corner: %d positions for %d indices",
				geometry.positions.len(), geometry.indices.len()
			);
			test::@check(
				geometry.normals.len() == geometry.positions.len(),
				"every position carries a normal: %d normals for %d positions",
				geometry.normals.len(), geometry.positions.len()
			);
			test::@check(
				geometry.uvs.len() == geometry.positions.len(),
				"every position carries a uv: %d uvs for %d positions",
				geometry.uvs.len(), geometry.positions.len()
			);

			for (sz t = 0; t < triangle_count(geometry); t++)
			{
				Vec3 geometric = face_normal(geometry, t).normalize();
				for (sz corner = 0; corner < 3; corner++)
				{
					Vec3 declared = geometry.normals[geometry.indices[t * 3 + corner]];
					test::@check(
						declared.dot(geometric) > 0.999f,
						"corner %d of triangle %d declares %s against a face normal of %s",
						corner, t, declared, geometric
					);
				}
			}
		};
	};
}

<*
 Every edge of every face is the same length in uv as it is in space.

 A separate function rather than a loop written twice, because it is asked of two
 hulls: one whose faces point every way and one whose faces are axis-aligned.
*>
fn void check_isometry(three::GeometryBuilder* geometry, String what)
{
	test::@check(triangle_count(geometry) > 0, "%s produced no triangles", what);
	for (sz t = 0; t < triangle_count(geometry); t++)
	{
		for (sz edge = 0; edge < 3; edge++)
		{
			uint from = geometry.indices[t * 3 + edge];
			uint to = geometry.indices[t * 3 + (edge + 1) % 3];
			float in_space = (geometry.positions[to] - geometry.positions[from]).length();
			float in_uv = (geometry.uvs[to] - geometry.uvs[from]).length();
			test::@check(
				math::abs(in_space - in_uv) < 1e-4f,
				"edge %d of triangle %d of %s is %f long in space and %f in uv",
				edge, t, what, in_space, in_uv
			);
		}
	}
}

<*
 The uvs are an isometry of each face, and coplanar faces agree across the edge
 they share.

 Both halves are what makes this a *projection* rather than a fabricated unwrap,
 and `scene/convex.c3`'s header claims both in those words.

 ## An isometry

 A face is flat and its basis is orthonormal, so projecting the face onto it
 cannot stretch, shear or shrink anything: the distance between two corners in uv
 is the distance between them in space, exactly. That is a much stronger property
 than "the uvs look plausible" and it is the one an agent relies on when it says
 a texture is applied at one unit per unit — a mapping that scaled per face would
 pass every check about ranges and still put a different texel density on every
 facet of the same rock.

 Checked over every edge of every face, against a cloud with faces pointing in
 every direction, so the `face_basis` seed-axis rule is exercised near all three
 of its branches rather than at one.

 ## Coplanar faces agree

 The cube's corners are the case, and they are the case a hull produces
 constantly: four flush points give two triangles in one plane, and the four
 pairs of them here are the cube's own faces. Because the projection is of the
 *position* rather than of anything per-triangle, a corner shared by both
 triangles gets the same uv from each — so a repeating texture crosses the
 diagonal without a seam down the middle of a flat wall.

 The two triangles of a cube face share two of their three corners, which is what
 makes "the same position under the same normal has the same uv" a real check
 here rather than a vacuous one.

 **Proved by injection**, twice. `face_basis`'s seed axis changed from "least
 aligned" to a constant `{ 0, 0, 1 }`: the two faces whose normal is ±z get a
 zero-length tangent, which `normalize` answers with zero rather than a NaN, so
 every uv on them collapses to the origin — "edge 0 of triangle 2 of the cube is
 1.414214 long in space and 0.000000 in uv". **That injection passes against the
 random cloud alone**, which is why the isometry half is asked of the cube too: a
 60-point cloud never lands a face normal exactly on an axis, so it never reaches
 the branch the seed rule exists for.

 And separately the projection taken from the corner's offset to the face centre
 rather than from the corner itself — the plausible-looking version of this,
 which centres each face's uvs on zero. The isometry half still passes, because
 subtracting a constant per face does not change a distance *within* the face,
 and the agreement half does not: "position 0 of triangle 3 has uv (-0.333333,
 -0.666667) where triangle 2 gave it (-0.666667, -0.333333)" — the two halves of
 one cube face, disagreeing by the difference between their centroids.
*>
fn void the_hull_is_projected_face_by_face() @test
{
	@pool()
	{
		// --- an isometry, over faces pointing every way ---

		Vec3[8] corners = {
			{ -0.5, -0.5, -0.5 }, { 0.5, -0.5, -0.5 }, { -0.5, 0.5, -0.5 }, { 0.5, 0.5, -0.5 },
			{ -0.5, -0.5, 0.5 }, { 0.5, -0.5, 0.5 }, { -0.5, 0.5, 0.5 }, { 0.5, 0.5, 0.5 },
		};

		// Both clouds, and the second one is not decoration: a random cloud never
		// lands a face normal exactly on an axis, and the axis-aligned faces are
		// the whole reason `face_basis` picks its seed rather than fixing it.
		@hulled(cloud(29, 60, 1.0f, tmem); three::GeometryBuilder* geometry) { check_isometry(geometry, "the cloud"); };
		@hulled(corners[..]; three::GeometryBuilder* geometry) { check_isometry(geometry, "the cube"); };

		// --- coplanar faces agree ---

		@hulled(corners[..]; three::GeometryBuilder* geometry)
		{
			// Twelve triangles, two per face. Every corner of every one of them is
			// compared against every corner of every *other* triangle that shares
			// its plane: same position, same normal, so same uv or the projection
			// is not a projection.
			for (sz t = 0; t < triangle_count(geometry); t++)
			{
				for (sz u = 0; u < t; u++)
				{
					Vec3 nt = face_normal(geometry, t).normalize();
					Vec3 nu = face_normal(geometry, u).normalize();
					if (nt.dot(nu) < 0.999f) continue;

					for (sz i = 0; i < 3; i++)
					{
						uint a = geometry.indices[t * 3 + i];
						for (sz j = 0; j < 3; j++)
						{
							uint b = geometry.indices[u * 3 + j];
							if ((geometry.positions[a] - geometry.positions[b]).length() > 1e-5f) continue;
							Vec2 ua = geometry.uvs[a];
							Vec2 ub = geometry.uvs[b];
							test::@check(
								(ua - ub).length() < 1e-5f,
								"position %d of triangle %d has uv (%f, %f) where triangle %d gave it (%f, %f)",
								i, t, ua.x, ua.y, u, ub.x, ub.y
							);
						}
					}
				}
			}
		};
	};
}

<*
 Every point handed over is inside the surface that came back.

 The defining property of a hull, and the only check that separates one from a
 shape that merely looks plausible. A point outside any face would be a vertex
 quickhull dropped, which renders as a rock with a corner shaved off and nothing
 else.

 The tolerance is relative to how far the cloud reaches, because the test is a
 plane equation evaluated in floats and the error scales with the coordinates.
*>
fn void every_input_point_is_inside_the_hull() @test
{
	@pool()
	{
		Vec3[] points = cloud(23, 150, 2.5f, tmem);

		@hulled(points; three::GeometryBuilder* geometry)
		{
			float reach = 0;
			foreach (point : points) reach = math::max(reach, point.length());
			float tolerance = reach * 1e-4f;

			for (sz t = 0; t < triangle_count(geometry); t++)
			{
				Vec3 normal = face_normal(geometry, t).normalize();
				Vec3 on_face = face_centre(geometry, t);
				foreach (index, point : points)
				{
					float above = normal.dot(point - on_face);
					test::@check(
						above <= tolerance,
						"point %d is %f outside face %d, past a tolerance of %f",
						index, above, t, tolerance
					);
				}
			}
		};
	};
}

<*
 Nothing with no area is emitted.

 quickhull keeps zero-area triangles on purpose — a collision volume has to be
 closed — and `build_convex` drops them, because a triangle with no area has no
 normal to shade with, covers no pixels, and is one more BVH leaf no ray can hit.
 The cloud here is chosen to provoke them: points on a cube's edges and faces
 land exactly on the finished hull's boundary, which is the case that produces a
 seam of no width.
*>
fn void nothing_degenerate_is_emitted() @test
{
	@pool()
	{
		// The corners, plus every edge midpoint and face centre of the same cube.
		Vec3[] points = alloc::new_array(tmem, Vec3, 8 + 12 + 6);
		points[:8] = cube_corners[..];
		Vec3[12] edges = {
			{ 0, -1, -1 }, { 0, 1, -1 }, { 0, -1, 1 }, { 0, 1, 1 },
			{ -1, 0, -1 }, { 1, 0, -1 }, { -1, 0, 1 }, { 1, 0, 1 },
			{ -1, -1, 0 }, { 1, -1, 0 }, { -1, 1, 0 }, { 1, 1, 0 },
		};
		Vec3[6] faces = { { -1, 0, 0 }, { 1, 0, 0 }, { 0, -1, 0 }, { 0, 1, 0 }, { 0, 0, -1 }, { 0, 0, 1 } };
		points[8:12] = edges[..];
		points[20:6] = faces[..];

		@hulled(points; three::GeometryBuilder* geometry)
		{
			test::@check(triangle_count(geometry) > 0, "the cube produced no triangles");
			for (sz t = 0; t < triangle_count(geometry); t++)
			{
				float area2 = face_normal(geometry, t).length();
				test::@check(
					area2 >= three::CONVEX_MIN_FACE_AREA2,
					"triangle %d has an area of %f, which is not a face", t, area2 * 0.5f
				);
			}
		};
	};
}

<*
 A cloud that encloses no volume builds nothing, rather than something thin.

 All four are what an agent generates by accident — a loop that varied one axis,
 a plane of points meant as a floor, a list that was shorter than it looked. Each
 has to come back empty so `Assets.convex` can answer with
 CONVEX_HULL_IS_DEGENERATE and the prelude can say which of the three it was.
*>
fn void a_cloud_that_encloses_no_volume_builds_nothing() @test
{
	Vec3[3] too_few = { { 0, 0, 0 }, { 1, 0, 0 }, { 0, 1, 0 } };
	Vec3[5] identical = { { 2, 2, 2 }, { 2, 2, 2 }, { 2, 2, 2 }, { 2, 2, 2 }, { 2, 2, 2 } };
	Vec3[5] collinear = { { 0, 0, 0 }, { 1, 1, 1 }, { 2, 2, 2 }, { 3, 3, 3 }, { 4, 4, 4 } };
	Vec3[6] coplanar = { { 0, 0, 0 }, { 1, 0, 0 }, { 0, 1, 0 }, { 1, 1, 0 }, { 2, 3, 0 }, { -1, 4, 0 } };

	Vec3[][4] flat = { too_few[..], identical[..], collinear[..], coplanar[..] };
	foreach (index, points : flat)
	{
		@hulled(points; three::GeometryBuilder* geometry)
		{
			test::@check(
				geometry.indices.len() == 0,
				"cloud %d encloses no volume and produced %d triangles", index, triangle_count(geometry)
			);
		};
	}
}

<*
 The key is the cloud: equal keys mean equal input.

 Three statements, and the third is the one worth writing down. Moving a point
 changes the key, which is what makes "equal keys mean equal geometry" true.
 *Reordering* the same points also changes it, which is a deliberate cost — the
 alternative is sorting every cloud before hashing it, which turns a repeated
 construction from a hash into a sort and buys dedup only for the case where an
 agent shuffled a cloud it already had.
*>
fn void the_key_is_the_cloud() @test
{
	@pool()
	{
		Vec3[] points = cloud(5, 32, 1.0f, tmem);
		String key = three::convex_key(points, tmem);

		test::@check(key == three::convex_key(points, tmem), "the same cloud keyed twice as %s", key);

		Vec3[] moved = alloc::new_array(tmem, Vec3, points.len);
		moved[..] = points[..];
		moved[7].y += 0.001f;
		test::@check(
			three::convex_key(moved, tmem) != key,
			"a moved point kept the key %s", key
		);

		Vec3[] shuffled = alloc::new_array(tmem, Vec3, points.len);
		shuffled[..] = points[..];
		Vec3 swap = shuffled[0];
		shuffled[0] = shuffled[1];
		shuffled[1] = swap;
		test::@check(
			three::convex_key(shuffled, tmem) != key,
			"the key is documented as order-dependent and this reorder kept it: %s", key
		);

		// The count is in the key in the clear, so a hash collision would still
		// have to be between two clouds of the same size.
		test::@check(
			key.contains("n=32"),
			"the key names the point count so a stats dump can read it, got %s", key
		);
	};
}
