<*
 A shape with holes, swept along +z: what it is shaped like, which way round
 it faces, and when two of them are one asset.

	`c3c test --trust=full --test-noleak --test-filter three_tests::extrude`

 **No GPU anywhere in the first half of this file**, `primitive_test.c3`'s and
 `convex_test.c3`'s reason: `build_extrude` fills a `GeometryBuilder` with
 plain arrays and knows nothing about a device. The second half needs one —
 `Assets.extrude`'s dedup and `scene.export`'s round trip both live below the
 asset table, which is JavaScript's job to reach.

 ## What a picture cannot check here, and this can

 A hole that triangulated into the solid instead of out of it still fills a
 silhouette that reads as a wall with a window — the window would just be
 opaque. `no_cap_triangle_lands_inside_the_hole` is the statement a screenshot
 cannot make and this can: the triangulation actually excludes the hole's
 interior, not merely draws something that looks like it does from the one
 angle a render happens to use.

 The winding is `primitive_test.c3`'s and `convex_test.c3`'s argument again,
 with a third direction added: a hole's sides have to face the *opposite* way
 from the outline's, into the material rather than out of it, or a window
 frame would cull away and show the sky through the wrong face.

 And a mesh with a hole in it is the one shape here whose "did the triangles
 actually close up" is not obvious from the vertex and index counts the way a
 box or a hull's is — `every_edge_is_shared_by_exactly_two_triangles` is the
 general statement that a box's six quads and a hull's flat shading both
 happen to satisfy for simpler reasons.
*>
module three_tests::extrude;

import three;
import three_tests::device;
import vk;
import std::core::test;
import std::math;
import std::math::vector;
import std::io::file;

alias Vec3 = float[<3>];
alias Vec2 = float[<2>];

// ============================================================================
// Host level — no device
// ============================================================================

<*
 Build a shape into arrays, run the body over it, and free it.
*>
macro @extruded(Vec2[] outline, Vec2[] holes, uint[] hole_counts, float depth; @body(three::GeometryBuilder* geometry))
{
	three::GeometryBuilder geometry;
	geometry.init();
	defer geometry.free();
	three::build_extrude(&geometry, outline, holes, hole_counts, depth);
	@body(&geometry);
}

fn sz triangle_count(three::GeometryBuilder* geometry) => geometry.indices.len() / 3;

fn Vec2 xy(Vec3 v) => { v.x, v.y };

fn bool near(float a, float b, float tolerance = 1e-4f) => math::abs(a - b) < tolerance;

fn bool same_point(Vec3 a, Vec3 b) => (a - b).length() < 1e-5f;

fn bool same_edge(Vec3 a0, Vec3 a1, Vec3 b0, Vec3 b1) =>
	(same_point(a0, b0) && same_point(a1, b1)) || (same_point(a0, b1) && same_point(a1, b0));

<*
 A point-in-polygon test over a simple ring, by the standard even-odd ray cast.
 Used against the outline and the hole both, so the L-shaped outline's own
 concave corner is checked with the same code the rectangular hole is.
*>
fn bool point_in_polygon(Vec2 p, Vec2[] poly)
{
	bool inside = false;
	usz n = poly.len;
	usz j = n - 1;
	for (usz i = 0; i < n; i++)
	{
		Vec2 a = poly[i];
		Vec2 b = poly[j];
		if ((a.y > p.y) != (b.y > p.y))
		{
			float x = a.x + (p.y - a.y) / (b.y - a.y) * (b.x - a.x);
			if (p.x < x) inside = !inside;
		}
		j = i;
	}
	return inside;
}

<*
 Every edge in the index buffer, matched by position rather than by index —
 flat shading duplicates a vertex per corner, so two triangles that share a
 geometric edge never share an index — appears in exactly two (triangle,
 corner) slots: itself and the one triangle on its other side. A mesh with a
 gap has an edge that appears once; a mesh with an overlap or a degenerate
 sliver has one that appears more than twice.
*>
fn void assert_closed_mesh(three::GeometryBuilder* geometry, String what)
{
	sz tri = triangle_count(geometry);
	for (sz t = 0; t < tri; t++)
	{
		for (sz e = 0; e < 3; e++)
		{
			Vec3 a0 = geometry.positions[geometry.indices[t * 3 + e]];
			Vec3 a1 = geometry.positions[geometry.indices[t * 3 + (e + 1) % 3]];
			int matches = 0;
			for (sz u = 0; u < tri; u++)
			{
				for (sz f = 0; f < 3; f++)
				{
					Vec3 b0 = geometry.positions[geometry.indices[u * 3 + f]];
					Vec3 b1 = geometry.positions[geometry.indices[u * 3 + (f + 1) % 3]];
					if (same_edge(a0, a1, b0, b1)) matches++;
				}
			}
			test::@check(
				matches == 2,
				"%s: edge %d of triangle %d is shared by %d edges, not 2", what, e, t, matches
			);
		}
	}
}

// --- a rectangle with a rectangular hole -----------------------------------

Vec2[4] wall_outline = { { 0, 0 }, { 3, 0 }, { 3, 1.6 }, { 0, 1.6 } };
Vec2[4] wall_hole     = { { 1.1, 0.4 }, { 1.9, 0.4 }, { 1.9, 1.4 }, { 1.1, 1.4 } };
uint[1] wall_hole_counts = { 4 };
const float WALL_DEPTH = 0.2;

<*
 The +z cap's own area — summed over its triangles, which are individually
 counter-clockwise by construction (see `scene/extrude.c3`'s header) so a
 plain sum of `0.5 * cross` is already the signed area and needs no
 `abs` — equals the outline's area less the hole's, 3 x 1.6 minus 0.8 x 1.
*>
fn void the_cap_area_is_the_outline_less_the_hole() @test
{
	@extruded(wall_outline[..], wall_hole[..], wall_hole_counts[..], WALL_DEPTH; three::GeometryBuilder* geometry)
	{
		float area = 0;
		sz tri = triangle_count(geometry);
		for (sz t = 0; t < tri; t++)
		{
			Vec3 a = geometry.positions[geometry.indices[t * 3]];
			Vec3 b = geometry.positions[geometry.indices[t * 3 + 1]];
			Vec3 c = geometry.positions[geometry.indices[t * 3 + 2]];
			if (!(near(a.z, WALL_DEPTH) && near(b.z, WALL_DEPTH) && near(c.z, WALL_DEPTH))) continue;
			Vec2 ab = xy(b) - xy(a);
			Vec2 ac = xy(c) - xy(a);
			area += ab.cross(ac) * 0.5f;
		}
		float expected = 3.0f * 1.6f - 0.8f * 1.0f;
		test::@check(
			math::abs(area - expected) < 1e-5f,
			"the +z cap's area is %f, wanted %f", area, expected
		);
	};
}

fn void the_wall_is_a_closed_mesh() @test
{
	@extruded(wall_outline[..], wall_hole[..], wall_hole_counts[..], WALL_DEPTH; three::GeometryBuilder* geometry)
	{
		assert_closed_mesh(geometry, "the wall");
	};
}

fn void no_cap_triangle_lands_inside_the_hole() @test
{
	@extruded(wall_outline[..], wall_hole[..], wall_hole_counts[..], WALL_DEPTH; three::GeometryBuilder* geometry)
	{
		sz tri = triangle_count(geometry);
		int caps_checked = 0;
		for (sz t = 0; t < tri; t++)
		{
			Vec3 a = geometry.positions[geometry.indices[t * 3]];
			Vec3 b = geometry.positions[geometry.indices[t * 3 + 1]];
			Vec3 c = geometry.positions[geometry.indices[t * 3 + 2]];
			bool is_cap = near(a.z, b.z) && near(b.z, c.z);
			if (!is_cap) continue;
			caps_checked++;
			Vec2 centroid = (xy(a) + xy(b) + xy(c)) / 3.0f;
			test::@check(
				!point_in_polygon(centroid, wall_hole[..]),
				"triangle %d's centroid %s lands inside the hole", t, centroid
			);
		}
		test::@check(caps_checked > 0, "no cap triangles were found at all");
	};
}

fn void every_normal_is_unit_length() @test
{
	@extruded(wall_outline[..], wall_hole[..], wall_hole_counts[..], WALL_DEPTH; three::GeometryBuilder* geometry)
	{
		test::@check(geometry.normals.len() > 0, "no normals were produced");
		foreach (i, normal : geometry.normals)
		{
			float len = normal.length();
			test::@check(math::abs(len - 1.0f) < 1e-3f, "normal %d has length %f, not 1", i, len);
		}
	};
}

<*
 The outline's own sides face away from the wall's centre; the hole's face
 toward the hole's own centre, into the window rather than out of the wall —
 `scene/extrude.c3`'s header derives why a clockwise ring gives the same
 outward-facing formula the opposite answer.
*>
fn void side_normals_face_out_of_the_wall_and_into_the_hole() @test
{
	@extruded(wall_outline[..], wall_hole[..], wall_hole_counts[..], WALL_DEPTH; three::GeometryBuilder* geometry)
	{
		Vec2 wall_center = { 1.5f, 0.8f };
		Vec2 hole_center = { 1.5f, 0.9f };
		sz tri = triangle_count(geometry);
		int outline_sides = 0;
		int hole_sides = 0;
		for (sz t = 0; t < tri; t++)
		{
			Vec3 a = geometry.positions[geometry.indices[t * 3]];
			Vec3 b = geometry.positions[geometry.indices[t * 3 + 1]];
			Vec3 c = geometry.positions[geometry.indices[t * 3 + 2]];
			bool is_side = !(near(a.z, b.z) && near(b.z, c.z));
			if (!is_side) continue;

			Vec2 p = xy(a);
			bool on_hole    = near(p.x, 1.1f) || near(p.x, 1.9f) || near(p.y, 0.4f) || near(p.y, 1.4f);
			bool on_outline = near(p.x, 0) || near(p.x, 3) || near(p.y, 0) || near(p.y, 1.6f);

			Vec3 normal = geometry.normals[geometry.indices[t * 3]];
			Vec2 n = xy(normal);

			if (on_hole)
			{
				hole_sides++;
				test::@check(
					n.dot(hole_center - p) > 0,
					"triangle %d is a hole side at %s with normal %s, which does not face the hole", t, p, n
				);
			}
			else if (on_outline)
			{
				outline_sides++;
				test::@check(
					n.dot(p - wall_center) > 0,
					"triangle %d is an outline side at %s with normal %s, which does not face outward", t, p, n
				);
			}
		}
		test::@check(outline_sides > 0, "no outline side triangles were found");
		test::@check(hole_sides > 0, "no hole side triangles were found");
	};
}

// --- concave outlines, no holes ---------------------------------------------

<*
 Builds `outline` with no holes and checks the shape every concave-outline
 test here wants: each cap triangulates to exactly `n - 2` triangles, no cap
 triangle's centroid lands outside the outline, and the mesh closes.

 Shared rather than repeated per shape, because the interesting cases below
 are exactly the ones that put a reflex vertex on an exact diagonal between
 two other vertices — a symmetric L, a plus sign — and the point of asking the
 same three questions of all of them is that none gets a check the others
 do not.
*>
fn void assert_concave_outline_triangulates_cleanly(Vec2[] outline, float depth, String what)
{
	@pool()
	{
		Vec2[] no_holes = alloc::new_array(tmem, Vec2, 0);
		uint[] no_hole_counts = alloc::new_array(tmem, uint, 0);

		@extruded(outline, no_holes, no_hole_counts, depth; three::GeometryBuilder* geometry)
		{
			sz tri = triangle_count(geometry);
			sz n = (sz)outline.len;
			int top_caps = 0;
			int bottom_caps = 0;
			for (sz t = 0; t < tri; t++)
			{
				Vec3 a = geometry.positions[geometry.indices[t * 3]];
				Vec3 b = geometry.positions[geometry.indices[t * 3 + 1]];
				Vec3 c = geometry.positions[geometry.indices[t * 3 + 2]];
				if (near(a.z, depth) && near(b.z, depth) && near(c.z, depth))
				{
					top_caps++;
					Vec2 centroid = (xy(a) + xy(b) + xy(c)) / 3.0f;
					test::@check(
						point_in_polygon(centroid, outline),
						"%s: top cap triangle %d has centroid %s outside the outline", what, t, centroid
					);
				}
				else if (near(a.z, 0) && near(b.z, 0) && near(c.z, 0))
				{
					bottom_caps++;
				}
			}
			test::@check(
				(sz)top_caps == n - 2,
				"%s: an outline of %d points caps to %d - 2 triangles, got %d", what, n, n, top_caps
			);
			test::@check((sz)bottom_caps == n - 2, "%s: and the same on the -z cap, got %d", what, bottom_caps);
			assert_closed_mesh(geometry, what);
		};
	};
}

// A wide, asymmetric L: no three of its points are exactly collinear.
Vec2[6] l_shape = { { 0, 0 }, { 3, 0 }, { 3, 1 }, { 1.2, 1 }, { 1.2, 2 }, { 0, 2 } };

fn void the_l_shape_triangulates_to_n_minus_2_triangles_per_cap() @test
{
	assert_concave_outline_triangulates_cleanly(l_shape[..], 1.0f, "the wide L");
}

<*
 The 2x1/1x2 L Three.js's own `ExtrudeGeometry` examples draw: symmetric,
 which puts its reflex corner (1, 1) exactly on the diagonal from (2, 0) to
 (0, 2). A kit is made of round numbers, and this is the shape that used to
 catch `ear_clip` clipping straight across the notch along that diagonal
 before `point_in_triangle` counted its own boundary as inside.
*>
Vec2[6] symmetric_l_shape = { { 0, 0 }, { 2, 0 }, { 2, 1 }, { 1, 1 }, { 1, 2 }, { 0, 2 } };

fn void the_symmetric_l_triangulates_cleanly_despite_its_reflex_corner_on_the_diagonal() @test
{
	assert_concave_outline_triangulates_cleanly(symmetric_l_shape[..], 1.0f, "the symmetric L");
}

<*
 A plus sign: four reflex corners, every one of them exactly on a diagonal
 between two other vertices, the same way the symmetric L's one is — a 3x3
 square with its four unit corners removed, area 5.
*>
Vec2[12] plus_shape = {
	{ 1, 0 }, { 2, 0 }, { 2, 1 }, { 3, 1 }, { 3, 2 }, { 2, 2 },
	{ 2, 3 }, { 1, 3 }, { 1, 2 }, { 0, 2 }, { 0, 1 }, { 1, 1 },
};

fn void the_plus_shape_triangulates_cleanly_with_four_reflex_corners_on_diagonals() @test
{
	assert_concave_outline_triangulates_cleanly(plus_shape[..], 1.0f, "the plus sign");
}

// --- symmetric holes: the window case with everything on a diagonal --------

<*
 A rectangle with a centred square hole, both symmetric about the same
 centre — the window case where the outer diagonals the hole's own corners
 sit nearest to are the ones a bridge is most likely to be tempted across.
*>
Vec2[4] symmetric_outline = { { 0, 0 }, { 4, 0 }, { 4, 4 }, { 0, 4 } };
Vec2[4] symmetric_hole    = { { 1, 1 }, { 3, 1 }, { 3, 3 }, { 1, 3 } };
uint[1] symmetric_hole_counts = { 4 };

fn void a_centred_square_hole_in_a_square_outline_triangulates_cleanly() @test
{
	@extruded(
		symmetric_outline[..], symmetric_hole[..], symmetric_hole_counts[..], 1.0f;
		three::GeometryBuilder* geometry
	)
	{
		float area = 0;
		sz tri = triangle_count(geometry);
		int top_caps = 0;
		for (sz t = 0; t < tri; t++)
		{
			Vec3 a = geometry.positions[geometry.indices[t * 3]];
			Vec3 b = geometry.positions[geometry.indices[t * 3 + 1]];
			Vec3 c = geometry.positions[geometry.indices[t * 3 + 2]];
			if (!(near(a.z, 1.0f) && near(b.z, 1.0f) && near(c.z, 1.0f))) continue;
			top_caps++;
			Vec2 centroid = (xy(a) + xy(b) + xy(c)) / 3.0f;
			test::@check(
				!point_in_polygon(centroid, symmetric_hole[..]),
				"triangle %d's centroid %s lands inside the centred hole", t, centroid
			);
			Vec2 ab = xy(b) - xy(a);
			Vec2 ac = xy(c) - xy(a);
			area += ab.cross(ac) * 0.5f;
		}
		test::@check(top_caps > 0, "no cap triangles were found at all");
		float expected = 4.0f * 4.0f - 2.0f * 2.0f;
		test::@check(
			math::abs(area - expected) < 1e-5f, "the +z cap's area is %f, wanted %f", area, expected
		);
		assert_closed_mesh(geometry, "the centred square hole");
	};
}

<*
 A wall wide enough for two windows side by side — two holes, so two calls
 into `bridge_hole` against the same, and by the second call already
 once-bridged, outer ring. A malformed second bridge shows up as an unclosed
 mesh or a cap triangle landing inside either window.
*>
Vec2[4] wall_outline_wide = { { 0, 0 }, { 3, 0 }, { 3, 1.6 }, { 0, 1.6 } };
Vec2[4] left_window       = { { 0.4, 0.3 }, { 1.0, 0.3 }, { 1.0, 1.3 }, { 0.4, 1.3 } };
Vec2[4] right_window      = { { 2.0, 0.3 }, { 2.6, 0.3 }, { 2.6, 1.3 }, { 2.0, 1.3 } };
uint[2] two_window_counts = { 4, 4 };

fn void a_wall_with_two_windows_side_by_side_triangulates_cleanly() @test
{
	@pool()
	{
		Vec2[] two_holes = alloc::new_array(tmem, Vec2, 8);
		two_holes[0..3] = left_window[..];
		two_holes[4..7] = right_window[..];

		@extruded(
			wall_outline_wide[..], two_holes, two_window_counts[..], 0.2f;
			three::GeometryBuilder* geometry
		)
		{
			sz tri = triangle_count(geometry);
			int top_caps = 0;
			for (sz t = 0; t < tri; t++)
			{
				Vec3 a = geometry.positions[geometry.indices[t * 3]];
				Vec3 b = geometry.positions[geometry.indices[t * 3 + 1]];
				Vec3 c = geometry.positions[geometry.indices[t * 3 + 2]];
				if (!(near(a.z, 0.2f) && near(b.z, 0.2f) && near(c.z, 0.2f))) continue;
				top_caps++;
				Vec2 centroid = (xy(a) + xy(b) + xy(c)) / 3.0f;
				test::@check(
					!point_in_polygon(centroid, left_window[..]),
					"triangle %d's centroid %s lands inside the left window", t, centroid
				);
				test::@check(
					!point_in_polygon(centroid, right_window[..]),
					"triangle %d's centroid %s lands inside the right window", t, centroid
				);
			}
			test::@check(top_caps > 0, "no cap triangles were found at all");
			assert_closed_mesh(geometry, "the wall with two windows");
		};
	};
}

// --- degenerate inputs are refused ------------------------------------------

fn void degenerate_shapes_build_nothing() @test
{
	@pool()
	{
		Vec2[] no_holes = alloc::new_array(tmem, Vec2, 0);
		uint[] no_hole_counts = alloc::new_array(tmem, uint, 0);

		// Fewer than 3 outline points.
		Vec2[2] too_few = { { 0, 0 }, { 1, 0 } };
		@extruded(too_few[..], no_holes, no_hole_counts, 1.0f; three::GeometryBuilder* geometry)
		{
			test::@check(geometry.indices.len() == 0, "2 outline points built %d indices", geometry.indices.len());
		};

		// Collinear outline: no area.
		Vec2[3] collinear = { { 0, 0 }, { 1, 0 }, { 2, 0 } };
		@extruded(collinear[..], no_holes, no_hole_counts, 1.0f; three::GeometryBuilder* geometry)
		{
			test::@check(
				geometry.indices.len() == 0, "a collinear outline built %d indices", geometry.indices.len()
			);
		};

		// A valid outline, a hole with fewer than 3 points.
		Vec2[2] tiny_hole = { { 1, 1 }, { 2, 1 } };
		uint[1] one_hole_count = { 2 };
		@extruded(wall_outline[..], tiny_hole[..], one_hole_count[..], WALL_DEPTH; three::GeometryBuilder* geometry)
		{
			test::@check(
				geometry.indices.len() == 0, "a 2-point hole built %d indices", geometry.indices.len()
			);
		};
	};
}

// ============================================================================
// JavaScript level and export level — a device
// ============================================================================

macro @with_js(; @body(three::JsRuntime* run))
{
	three::Renderer* renderer = device::borrow(200, 150);
	defer device::release();

	three::JsRuntime runtime;
	runtime.open(&renderer.pass, renderer)!!;
	defer runtime.close();

	@body(&runtime);
}

const String WALL_SCRIPT = `
	function wallWithWindow(depth) {
		const shape = new three.Shape();
		shape.moveTo(0, 0).lineTo(3, 0).lineTo(3, 1.6).lineTo(0, 1.6).closePath();
		const hole = new three.Path();
		hole.moveTo(1.1, 0.4).lineTo(1.9, 0.4).lineTo(1.9, 1.4).lineTo(1.1, 1.4).closePath();
		shape.holes.push(hole);
		return new three.ExtrudeGeometry(shape, { depth });
	}
`;

<*
 A `Shape` built from `moveTo`/`lineTo`/`closePath` plus a hole `Path`, added
 to a scene, has the bounds the outline and the depth say it should — and two
 shapes with the same points and the same depth share an asset, while a
 different depth does not, the same identity rule `ConvexGeometry`'s bit-exact
 key gives a point cloud.
*>
fn void a_shape_with_a_hole_has_the_expected_bounds_and_is_deduped() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(string::tformat(
			`
				%s
				const scene = new three.Scene();
				const geometry = wallWithWindow(0.2);
				scene.add(new three.Mesh(geometry));
				const b = geometry.bounds;

				const same = wallWithWindow(0.2);
				const different = wallWithWindow(0.5);

				return {
					bounds: [b.min.x, b.min.y, b.min.z, b.max.x, b.max.y, b.max.z],
					sameAsset: geometry.asset === same.asset,
					differentDepthIsDifferentAsset: geometry.asset === different.asset,
				};
			`,
			WALL_SCRIPT
		));
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(
			result.value.contains(`"bounds":[0,0,0,3,1.6`),
			"bounds run 0..3, 0..1.6, 0..0.2; got %s", result.value
		);
		test::@check(result.value.contains(`"sameAsset":true`), "two identical shapes share an asset: %s", result.value);
		test::@check(
			result.value.contains(`"differentDepthIsDifferentAsset":false`),
			"a different depth is a different asset: %s", result.value
		);
	};
}

fn void bevel_and_face_uv_are_refused() @test
{
	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(string::tformat(
			`
				%s
				const refuse = (fn) => { try { fn(); return "no throw"; } catch (e) { return e.message; } };
				const shape = new three.Shape();
				shape.moveTo(0, 0).lineTo(1, 0).lineTo(1, 1).lineTo(0, 1).closePath();
				return {
					bevel: refuse(() => new three.ExtrudeGeometry(shape, { depth: 1, bevelEnabled: true })),
					faceUv: refuse(() => new three.ExtrudeGeometry(shape, { depth: 1, uv: 'face' })),
				};
			`,
			WALL_SCRIPT
		));
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(
			!result.value.contains(`"bevel":"no throw"`), "bevelEnabled: true did not throw: %s", result.value
		);
		test::@check(
			!result.value.contains(`"faceUv":"no throw"`), "uv: 'face' did not throw: %s", result.value
		);
	};
}

<*
 A wall with a window comes back out of the export with the same triangle
 count it was built with — `scene/export.c3`'s generic "hull" fallback, the
 same path `a_hull_comes_back_out_of_the_picking_tree` in `export_test.c3`
 checks for `ConvexGeometry`: `Assets.extrude` uploads through `upload_built`
 exactly like `Assets.convex` does, so it keeps the same `hull_positions` /
 `hull_triangles` picking-tree copy the exporter already reads a hull from,
 with no extrude-specific code in `scene/export.c3` at all.
*>
fn void a_wall_with_a_window_exports_with_the_same_triangle_count() @test
{
	String path = "build/export_extrude.glb";
	defer (void)file::delete(path);

	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(string::tformat(
			`
				%s
				const scene = new three.Scene();
				scene.add(new three.Mesh(wallWithWindow(0.2)));
				const before = three.stats();
				scene.export("build/export_extrude.glb");

				new three.Scene();
				const asset = three.load("build/export_extrude.glb");
				const reloaded = new three.Scene();
				reloaded.add(asset.instantiate());
				const after = three.stats();
				return [before.triangles, after.triangles, before.vertices, after.vertices];
			`,
			WALL_SCRIPT
		));
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(
			result.value == "[32,32,96,96]",
			"32 triangles and 96 split vertices, out and back; got %s", result.value
		);
	};
}
